@preconcurrency import Foundation
import CryptoKit
import Network
import Security

/// A loopback HTTP file server that serves files from WorkingCopyStore.baseDirectory.
///
/// ALL FOUR GUARDS ARE ENFORCED ON EVERY REQUEST. None is optional.
///
/// 1. **Loopback binding**: The listener binds to the loopback interface only via
///    `NWParameters.requiredLocalEndpoint = "127.0.0.1:.any"`. No tailnet or LAN
///    address is ever bound; the OS refuses connections from other interfaces.
///
/// 2. **Root confinement**: Request paths are resolved through symlinks first, then
///    checked against `resolvedBase`. An unresolved check is the classic bypass —
///    this one happens after `resolvingSymlinksInPath()`.
///
/// 3. **Capability token, bound to one path**: A per-launch secret is minted
///    from `SecRandomCopyBytes` and kept in memory only (never written to a
///    file, plist, or child process environment — ARCH-146/342). The token in a
///    URL is `HMAC-SHA256(secret, requestPath)`, so it opens **that path and no
///    other**. Every request must carry it as `?t=<token>`, compared in constant
///    time to prevent timing-based oracle attacks.
///
///    THE TOKEN IS PER-PATH BECAUSE IT LEAKS, and the CSP cannot stop that. A
///    token rides in the query string because a top-level navigation cannot
///    carry a header, so any script running on a served page can read it out of
///    `location.search` and send it away by setting `window.location`. The CSP
///    closes `fetch`, `sendBeacon`, `<a ping>`, WebSocket, image beacons, form
///    posts, external script and framing; it does not close navigation, because
///    the directive for that is `navigate-to`, which WebKit does not enforce.
///    Binding the token to a path makes the leak worthless: what escapes opens
///    only the page the attacker already controlled, rather than the whole
///    working copy for the rest of the session.
///
///    Deliberately NOT expiring. An expiry would bound the window, and it would
///    also 403 a tab the reader left open and came back to, which is a real cost
///    against a leak that path binding has already emptied of value.
///
/// 4. **Host + Origin check**: `Host` is required (HTTP/1.1 mandates it) and
///    must identify our loopback origin; an absent or foreign value is refused.
///    This closes DNS rebinding: a page the user visits cannot resolve an
///    attacker domain to 127.0.0.1 and reach this port, because the `Host` it
///    sends will carry the attacker domain. `Origin` is checked when present, to
///    cover cross-origin fetch() calls from a page already open.
///
/// The server is not a daemon. `DeckApp` starts it; `deinit` calls `stop()` to
/// cancel the `NWListener` when the server object is released with the app. The
/// server is injected as an environment object so `ContentView` can build browser
/// URLs without coupling to the server internals.
///
/// NWListener is in the SDK. No package dependency is added for this.
final class WorkingCopyServer: ObservableObject, @unchecked Sendable {

    // MARK: - Public state

    /// Per-launch secret the path tokens are derived from, minted from CSPRNG.
    ///
    /// Never leaves this object and never appears in a URL. Set once in `init`
    /// and never changes, so it is safe to read from any thread.
    private let secret: SymmetricKey

    /// The ephemeral port the server is bound to, or 0 before `start()`.
    var port: UInt16 { lock.withLock { _port } }

    /// Set when `start()` throws. ContentView observes this to show an alert.
    @Published var bindError: Error?

    // MARK: - Private state

    private let lock = NSLock()
    private var _port: UInt16 = 0
    private var listener: NWListener?

    /// The serial queue on which NWListener delivers new connections and
    /// connection data. Connection handling runs entirely on this queue.
    private let queue = DispatchQueue(label: "deck.viewer.server", qos: .utility)

    /// The resolved (symlinks expanded) path of the working-copy root.
    /// Set once in `init` and read from multiple threads — safe because it
    /// is a `let` after init completes.
    private let resolvedBase: String

    // MARK: - Init

    init() {
        secret = WorkingCopyServer.mintSecret()
        resolvedBase = WorkingCopyStore.baseDirectory
            .resolvingSymlinksInPath().path
    }

    /// Testing initializer: overrides the base directory so tests can control
    /// which files are served without touching Application Support.
    ///
    /// The secret stays CSPRNG-minted even here. A test-injectable secret would
    /// be a second way to set it, and the one thing this type must never do is
    /// serve on a secret someone else chose.
    init(baseDirectory: URL) {
        self.secret = WorkingCopyServer.mintSecret()
        self.resolvedBase = baseDirectory.resolvingSymlinksInPath().path
    }

    // MARK: - Lifecycle

    /// Starts the listener and waits until it is ready to accept connections.
    ///
    /// Binds to 127.0.0.1 on an ephemeral port. Throws on bind failure (e.g.
    /// no loopback interface, which should never happen in practice).
    func start() async throws {
        let params = NWParameters.tcp
        // Guard 1: bind to 127.0.0.1 only — never 0.0.0.0 or a LAN address.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: .any)

        let newListener = try NWListener(using: params)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // `StartGate` wraps the continuation so the one-shot invariant is
            // enforced by a lock rather than by a local `var resumed`, which
            // Swift 6 correctly rejects when captured in a concurrent closure.
            let gate = StartGate(continuation: cont)

            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let p = newListener.port?.rawValue ?? 0
                    self?.lock.withLock { self?._port = p }
                    gate.resume(with: .success(()))
                case .failed(let error):
                    gate.resume(with: .failure(error))
                case .cancelled:
                    gate.resume(with: .failure(CancellationError()))
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }

            self.lock.withLock { self.listener = newListener }
            newListener.start(queue: queue)
        }
    }

    /// Stops the listener. After this returns, no new connections are accepted
    /// and the port is released back to the OS.
    func stop() {
        lock.withLock {
            listener?.cancel()
            listener = nil
        }
    }

    deinit {
        stop()
    }

    // MARK: - URL construction

    /// Returns the loopback URL for a working-copy file, with a token that opens
    /// that path and no other. Returns nil if the server has not started, or if
    /// `localURL` does not fall under the working-copy root.
    ///
    /// This is the only place a token is minted. `handleRequest` recomputes the
    /// expected token from the path it was asked for, so the two agree by
    /// derivation rather than by a shared value either could drift from.
    func url(for localURL: URL) -> URL? {
        let currentPort = port
        guard currentPort > 0 else { return nil }

        let filePath = localURL.resolvingSymlinksInPath().path
        let base = resolvedBase
        guard filePath.hasPrefix(base + "/") else { return nil }
        let relative = String(filePath.dropFirst(base.count + 1))

        // The token covers the DECODED path, which is what `URLComponents`
        // hands back on the serving side after it decodes the percent-escapes
        // it is about to add here. A file named `my doc.md` is signed as
        // `/my doc.md` and requested as `/my%20doc.md`; both sides see the
        // former, so a space in a filename does not silently 403.
        let requestPath = "/" + relative

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(currentPort)
        components.path = requestPath
        components.queryItems = [
            URLQueryItem(name: "t", value: token(forRequestPath: requestPath)),
        ]
        return components.url
    }

    /// The token that opens exactly `requestPath`.
    ///
    /// Internal rather than private so the tests can assert the binding — that
    /// a token for one path does not open another — which is the whole property
    /// this change exists to add.
    func token(forRequestPath requestPath: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(requestPath.utf8), using: secret)
        return Data(mac)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection)
    }

    /// Receives request data until the header block terminator (`\r\n\r\n`)
    /// is complete, accumulating across multiple TCP segments. Cancels the
    /// connection if the header block exceeds 16 KB or no data arrives within
    /// 10 seconds of the first receive call.
    private func receiveRequest(_ connection: NWConnection,
                                accumulated: Data = Data(),
                                deadline: DispatchTime = .now() + 10) {
        let remaining = 16_384 - accumulated.count
        guard remaining > 0 else {
            respond(connection, status: 400, body: "Bad Request")
            return
        }

        // Both this work item and the receive callback run on the serial server
        // queue, so they cannot race: whichever fires first wins cleanly.
        let timeoutItem = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: deadline, execute: timeoutItem)

        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {
            [weak self] data, _, _, error in
            timeoutItem.cancel()
            guard let self else { connection.cancel(); return }
            if let error {
                print("[WorkingCopyServer] receive error: \(error)")
                connection.cancel()
                return
            }
            guard let data, !data.isEmpty else { connection.cancel(); return }
            let buffer = accumulated + data
            if buffer.range(of: WorkingCopyServer.headerTerminator) != nil {
                self.handleRequest(data: buffer, connection: connection)
            } else {
                self.receiveRequest(connection, accumulated: buffer, deadline: deadline)
            }
        }
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private func handleRequest(data: Data, connection: NWConnection) {
        guard let text = String(data: data, encoding: .utf8) else {
            respond(connection, status: 400, body: "Bad Request")
            return
        }

        // The header block ends at the first blank line (\r\n\r\n).
        let headerSection = text.components(separatedBy: "\r\n\r\n").first ?? ""
        let lines = headerSection.components(separatedBy: "\r\n")

        guard let requestLine = lines.first else {
            respond(connection, status: 400, body: "Bad Request")
            return
        }

        // Parse "GET /path?query HTTP/1.1"
        let tokens = requestLine.components(separatedBy: " ")
        guard tokens.count >= 2 else {
            respond(connection, status: 400, body: "Bad Request")
            return
        }
        let rawPath = tokens[1]

        // Collect headers into a lowercase-keyed dictionary.
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let currentPort = port

        // Guard 4a: Host header required. HTTP/1.1 mandates Host; an absent or
        // foreign value is refused. receiveRequest accumulates until \r\n\r\n
        // arrives, so by this point the header block is complete — a missing
        // Host is a malformed request, not a split-segment artefact.
        guard let host = headers["host"],
              host == "127.0.0.1:\(currentPort)"
                  || host == "localhost:\(currentPort)" else {
            respond(connection, status: 403, body: "Forbidden")
            return
        }

        // Guard 4b: Origin header. A missing Origin is normal for top-level
        // navigation. "null" is what browsers send from a local-file context.
        // Any other value must be one of our loopback origins.
        if let origin = headers["origin"], origin != "null" {
            guard origin == "http://127.0.0.1:\(currentPort)"
                    || origin == "http://localhost:\(currentPort)" else {
                respond(connection, status: 403, body: "Forbidden")
                return
            }
        }

        // Parse path and query string.
        guard let urlComponents = URLComponents(string: "http://127.0.0.1\(rawPath)") else {
            respond(connection, status: 400, body: "Bad Request")
            return
        }

        let requestPath = urlComponents.path
        let providedToken = urlComponents.queryItems?
            .first(where: { $0.name == "t" })?.value ?? ""

        // Guard 3: Capability token for THIS path (constant-time comparison).
        //
        // Checked before path confinement below, and that order is deliberate:
        // `resolveAndValidate` distinguishes 403 from 404, so running it first
        // would answer "does this file exist" for a caller holding no token at
        // all. Binding the token to the requested path is what lets the check
        // stay here — the expected value is derived from the path string, with
        // no need to resolve it on disk first.
        guard constantTimeEqual(providedToken, token(forRequestPath: requestPath)) else {
            respond(connection, status: 403, body: "Forbidden")
            return
        }

        // Guard 2: Path confinement after symlink resolution.
        // A path that escapes the root → 403 (access denied).
        // A path that is within the root but no file exists → 404.
        switch resolveAndValidate(requestPath) {
        case .forbidden:
            respond(connection, status: 403, body: "Forbidden")
            return
        case .notFound:
            respond(connection, status: 404, body: "Not Found")
            return
        case .found(let fileURL):
            let ct = Self.contentType(for: fileURL.pathExtension.lowercased())
            guard let fileData = try? Data(contentsOf: fileURL) else {
                respond(connection, status: 404, body: "Not Found")
                return
            }
            respond(connection, status: 200, data: fileData, contentType: ct)
            return
        }
    }

    private enum PathResult {
        case forbidden  // path escaped the root, or is malformed
        case notFound   // path is within the root but no regular file exists there
        case found(URL) // resolved file URL ready to serve
    }

    /// Resolves `requestPath` (a URL path component) relative to `resolvedBase`,
    /// expands symlinks, and classifies the result.
    ///
    /// Symlink expansion happens BEFORE the prefix check. An unresolved check
    /// is the classic escape bypass: the symlink name looks in-root, but the
    /// target is outside. Resolving first closes that.
    private func resolveAndValidate(_ requestPath: String) -> PathResult {
        guard let decoded = requestPath.removingPercentEncoding,
              !decoded.isEmpty else { return .forbidden }

        // Build the candidate by appending to the base. Never treat `decoded`
        // as an absolute path — that would let `/../../../etc/passwd` escape.
        let candidate = URL(fileURLWithPath: resolvedBase)
            .appendingPathComponent(decoded)

        // Resolve symlinks now, before the prefix check.
        let resolved = candidate.resolvingSymlinksInPath()
        let resolvedPath = resolved.path

        // Trailing slash on `resolvedBase + "/"` prevents a sibling directory
        // named `resolvedBase + "extra"` from passing the prefix check.
        guard resolvedPath.hasPrefix(resolvedBase + "/") else { return .forbidden }

        // Path is within the root. Now check whether a regular file is there.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir),
              !isDir.boolValue else { return .notFound }

        return .found(resolved)
    }

    // MARK: - HTTP response

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        respond(connection, status: status,
                data: Data(body.utf8), contentType: "text/plain")
    }

    private func respond(_ connection: NWConnection, status: Int,
                         data: Data, contentType: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        default:  statusText = "Error"
        }
        // CSP allows inline script and same-origin resources (needed for
        // ES-module pages the agent produces) while blocking outbound fetch,
        // image beacons, sendBeacon, forms, and framing. A page that loads a
        // CDN font or external script will break; that is accepted, because the
        // working copy holds agent-produced files rather than pages from the
        // open web.
        //
        // IT DOES NOT CLOSE NAVIGATION, and this comment used to claim the
        // token could not leave. A hostile page can still set `window.location`
        // to an external host with the token in the query string; the directive
        // that would stop it is `navigate-to`, which WebKit does not enforce.
        // What contains that leak is guard 3 binding the token to one path, so
        // what escapes opens only the page the attacker already controlled.
        let headerBlock =
            "HTTP/1.1 \(status) \(statusText)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(data.count)\r\n" +
            "Cache-Control: no-store\r\n" +
            "Referrer-Policy: no-referrer\r\n" +
            "X-Content-Type-Options: nosniff\r\n" +
            "Content-Security-Policy: default-src 'self' 'unsafe-inline' data:; " +
                "connect-src 'self'; img-src 'self' data:; " +
                "form-action 'none'; frame-ancestors 'none'\r\n" +
            "Connection: close\r\n\r\n"
        var response = Data(headerBlock.utf8)
        response.append(data)
        connection.send(content: response,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Helpers

    /// Constant-time comparison for equal-length byte sequences. Returns early
    /// on a length mismatch, but the token length (43 chars) is fixed and
    /// visible in any URL the server hands out, so that early exit reveals
    /// nothing exploitable.
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        return zip(aBytes, bBytes).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// MIME type for a file extension. Exposed `internal` so tests can assert
    /// the Content-Type without making a live request.
    static func contentType(for ext: String) -> String {
        switch ext {
        case "pdf":          return "application/pdf"
        case "html", "htm":  return "text/html; charset=utf-8"
        case "css":          return "text/css"
        case "js":           return "application/javascript"
        case "json":         return "application/json"
        case "png":          return "image/png"
        case "jpg", "jpeg":  return "image/jpeg"
        case "gif":          return "image/gif"
        case "webp":         return "image/webp"
        case "svg":          return "image/svg+xml"
        case "txt", "md":    return "text/plain; charset=utf-8"
        default:             return "application/octet-stream"
        }
    }

    /// The per-launch HMAC secret.
    ///
    /// `SecRandomCopyBytes` can fail, and a zero-filled key would make every
    /// token forgeable by anyone who read this file — a silent, total loss of
    /// guard 3. There is no safe way to continue without entropy, so this traps
    /// rather than serving on a predictable secret.
    private static func mintSecret() -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess,
                     "SecRandomCopyBytes failed (\(status)); refusing to serve "
                     + "on a predictable capability secret")
        return SymmetricKey(data: Data(bytes))
    }
}

// MARK: - StartGate

/// One-shot continuation wrapper used by `WorkingCopyServer.start()`.
///
/// NWListener's `stateUpdateHandler` may fire multiple times. `CheckedContinuation`
/// must be resumed exactly once. `StartGate` enforces this with a lock: only the
/// first caller's `resume(with:)` goes through; subsequent calls are dropped.
///
/// Using a class rather than a local `var resumed` avoids the Swift 6 error
/// "reference to captured var in concurrently-executing code" that arises when
/// a mutable local variable is shared between a `withCheckedThrowingContinuation`
/// body and a closure that executes on a dispatch queue.
private final class StartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }
}
