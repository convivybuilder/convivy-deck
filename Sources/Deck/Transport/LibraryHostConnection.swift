import Foundation
import Security

/// What `LibraryHostConnection` needs from its ssh forward: the local port
/// its mutual-TLS requests dial, and a way to tear it down. `LibraryForward`
/// is the one production conformer; a test fake conforms too, so the
/// connection's own session and heartbeat behaviour is testable with no real
/// ssh process at all.
protocol LibraryForwarding: AnyObject {
    var localPort: UInt16 { get }
    func stop()
}

extension LibraryForward: LibraryForwarding {}

/// One host's mutual-TLS forward, the bearer token read over it, and the one
/// `URLSession` every request on this host reuses. CQ·162's "read from the
/// host over ssh into memory once per host connection and is never written
/// to disk on the laptop" is why the token is cached here; CQ·198's "hold
/// one mutual-TLS `URLSession` per Library host connection" is why the
/// session is too — the connection, not the request, is the unit both are
/// cached against, so every request this host's forward carries while it
/// stays open reuses the one read and the one TLS handshake.
/// `@unchecked Sendable`: `lock` is the actual synchronization for
/// `cachedTokens`, the same discipline `SSHConnectionGate` and `TransportLog`
/// already use for the identical shape.
final class LibraryHostConnection: @unchecked Sendable {
    let forward: LibraryForwarding
    private let target: SSHTarget
    /// Keyed by token file rather than holding one string, because
    /// `LibraryClient` reads two different credentials
    /// (`WorkingCopyStore.libraryTokenFile` and `.libraryApprovalTokenFile`)
    /// over the same forward — see that file's doc for why the two must
    /// never be confused.
    private var cachedTokens: [String: String] = [:]
    private let lock = NSLock()

    private let sessionHolder: LibraryMutualTLSSessionHolder
    /// The heartbeat's own request, injected so a test can fire the
    /// scheduler's tick with no real network or ssh call underneath it.
    /// `LibraryHostConnection.defaultHeartbeatRequest` is the only
    /// production value.
    private let sendHeartbeatRequest: (LibraryHostConnection, LibraryMutualTLSSession) throws -> Void
    /// Called with this connection when the heartbeat itself fails the
    /// transport — the same treatment a request failure already gets in
    /// `LibraryTransportDispatch.runMutualTLS` (`LibraryHostConnectionPool
    /// .close`). Defaults to a no-op only for a connection built with no
    /// pool behind it (none in production; `LibraryHostConnectionPool`
    /// always supplies one).
    private let onHeartbeatFailure: (LibraryHostConnection) -> Void

    init(
        target: SSHTarget, forward: LibraryForwarding,
        heartbeatScheduler: LibraryHeartbeatScheduling = LibraryDispatchHeartbeatScheduler.shared,
        sendHeartbeatRequest: @escaping (LibraryHostConnection, LibraryMutualTLSSession) throws -> Void =
            LibraryHostConnection.defaultHeartbeatRequest,
        onHeartbeatFailure: @escaping (LibraryHostConnection) -> Void = { _ in }
    ) {
        self.target = target
        self.forward = forward
        self.sessionHolder = LibraryMutualTLSSessionHolder(heartbeatScheduler: heartbeatScheduler)
        self.sendHeartbeatRequest = sendHeartbeatRequest
        self.onHeartbeatFailure = onHeartbeatFailure
    }

    /// The one `URLSession` this host's requests share — built on first use
    /// with the given identity/anchors, returned unchanged on every later
    /// call until `close()` invalidates it. Also starts this connection's
    /// 45 s heartbeat, which stops when `close()` invalidates the session.
    func session(identity: SecIdentity, anchors: [SecCertificate]) -> LibraryMutualTLSSession {
        sessionHolder.session(
            make: { LibraryMutualTLSClient.makeSession(identity: identity, anchors: anchors) },
            heartbeat: { [weak self] session in self?.sendHeartbeat(on: session) })
    }

    /// A transport failure here gets the same treatment a request failure
    /// already does: the connection is closed through the pool, so the next
    /// call opens a fresh forward and a fresh session.
    private func sendHeartbeat(on session: LibraryMutualTLSSession) {
        do {
            try sendHeartbeatRequest(self, session)
        } catch is LibraryMutualTLSError {
            onHeartbeatFailure(self)
        } catch {
            // A token that could not be read over ssh says nothing about this
            // TLS connection, and `runMutualTLS` keeps its connection on the
            // same failure.
        }
    }

    /// One cheap authenticated `GET /whoami` on the shared session, so the
    /// Library's 120 s idle timer never fires while this connection is open.
    /// `/whoami` rather than any `LibraryClient` route because it changes
    /// nothing and every mutual-TLS host already carries a bearer token
    /// `LibraryClient` itself uses for its own requests.
    static func defaultHeartbeatRequest(connection: LibraryHostConnection, session: LibraryMutualTLSSession) throws {
        guard let baseURL = URL(string: "https://localhost:\(connection.forward.localPort)") else {
            throw LibraryMutualTLSError.transportFailed("could not build a URL for the heartbeat")
        }
        let token = try connection.bearerToken(tokenFile: WorkingCopyStore.libraryTokenFile)
        _ = try LibraryMutualTLSClient.perform(
            method: "GET", baseURL: baseURL, path: "/whoami",
            headers: ["Library-Protocol": "1", "Authorization": "Bearer \(token)"],
            body: nil, session: session)
    }

    /// The token at `tokenFile`, read over ssh exactly once for the life of
    /// this connection and held in memory only — never written to a file on
    /// this Mac, matching `WorkingCopyStore.libraryTokenFile`'s own doc for
    /// why the existing path already avoids argv but still reads the file
    /// fresh on the host each time; this path additionally avoids the
    /// repeat read, since a mutual-TLS connection is long-lived rather than
    /// one ssh invocation per request.
    func bearerToken(tokenFile: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedTokens[tokenFile] { return cached }
        let data = try SessionAgent.run(
            try Self.readTokenArguments(target: target, tokenFile: tokenFile), classifyMissingCommand: false)
        let token = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cachedTokens[tokenFile] = token
        return token
    }

    /// `tokenFile` is one of two compiled-in constants, never operator text,
    /// so it reaches this remote command the same way `remoteGETCommand`
    /// embeds it in a heredoc — safe for the identical reason that function
    /// states.
    /// The user and address are validated before they reach the destination
    /// token, the same check `libraryForwardArguments` and `sshArguments`
    /// run, so a config-sourced host cannot smuggle an option in.
    static func readTokenArguments(
        target: SSHTarget, tokenFile: String, controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        return withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            "cat \(tokenFile) 2>/dev/null",
        ], home: home)
    }

    /// Invalidates the shared session and stops its heartbeat, then tears
    /// down the forward — `-O cancel`, never a bare process kill, per
    /// `LibraryForward.stop()`'s own doc. The next request on this host
    /// opens a fresh forward and a fresh session.
    func close() {
        sessionHolder.close()
        forward.stop()
    }
}

/// One `LibraryHostConnection` per host, created on first use and reused by
/// every later call against the same target — the "one host connection" a
/// bearer token is cached per, and the one ssh forward a host's requests
/// multiplex onto rather than opening a new one per call.
/// `@unchecked Sendable`, same reason as `LibraryHostConnection` above.
final class LibraryHostConnectionPool: @unchecked Sendable {
    static let shared = LibraryHostConnectionPool()

    private var connections: [SSHTarget: LibraryHostConnection] = [:]
    private let lock = NSLock()
    private let startForward: (SSHTarget) throws -> LibraryForwarding
    private let heartbeatScheduler: LibraryHeartbeatScheduling
    private let sendHeartbeatRequest: (LibraryHostConnection, LibraryMutualTLSSession) throws -> Void

    init(
        startForward: @escaping (SSHTarget) throws -> LibraryForwarding = { try LibraryForward.start(target: $0) },
        heartbeatScheduler: LibraryHeartbeatScheduling = LibraryDispatchHeartbeatScheduler.shared,
        sendHeartbeatRequest: @escaping (LibraryHostConnection, LibraryMutualTLSSession) throws -> Void =
            LibraryHostConnection.defaultHeartbeatRequest
    ) {
        self.startForward = startForward
        self.heartbeatScheduler = heartbeatScheduler
        self.sendHeartbeatRequest = sendHeartbeatRequest
    }

    func connection(for target: SSHTarget) throws -> LibraryHostConnection {
        lock.lock()
        defer { lock.unlock() }
        if let existing = connections[target] { return existing }
        let made = LibraryHostConnection(
            target: target, forward: try startForward(target),
            heartbeatScheduler: heartbeatScheduler, sendHeartbeatRequest: sendHeartbeatRequest,
            onHeartbeatFailure: { [weak self] failed in self?.close(target, ifCurrent: failed) })
        connections[target] = made
        return made
    }

    /// Torn down when the host goes away (`ThemeStore.removeHost`), when a
    /// request through the forward fails at the transport, or when the
    /// connection's own heartbeat does — a forward riding a master that died
    /// or was cleared is gone with it either way. The next call then opens a
    /// fresh forward, a fresh session, and reads the token again.
    func close(_ target: SSHTarget) {
        lock.lock()
        defer { lock.unlock() }
        connections.removeValue(forKey: target)?.close()
    }

    /// Closes `connection` only if it is still this host's current one. A
    /// heartbeat or request running when its connection closed fails once the
    /// forward stops, and by then the host may have a newer connection that
    /// failure says nothing about. Every failure path closes through this.
    func close(_ target: SSHTarget, ifCurrent connection: LibraryHostConnection) {
        lock.lock()
        defer { lock.unlock() }
        guard connections[target] === connection else { return }
        connections.removeValue(forKey: target)?.close()
    }

    func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        let existing = connections
        connections.removeAll()
        existing.values.forEach { $0.close() }
    }
}
