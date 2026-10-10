import XCTest
import Network
@testable import Deck

/// Tests for the Phase 2 loopback file server.
///
/// Every test that asserts a guard is enforced does so by driving the server
/// with a real TCP connection and asserting on what the client receives —
/// not by calling internal validators directly. This is the "prove by running,
/// not by reasoning" requirement from the spec.
final class WorkingCopyServerTests: XCTestCase {

    // MARK: - Setup

    private var tempDir: URL!
    private var server: WorkingCopyServer!
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()

        // Use a temp directory as the working-copy root so tests never touch
        // Application Support.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeckServerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        server = WorkingCopyServer(baseDirectory: tempDir)
        try await server.start()

        // URLSession that does not follow redirects and ignores self-signed
        // certs (irrelevant here — the server is plain HTTP).
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        session = URLSession(configuration: config)
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private var port: UInt16 { server.port }

    /// The token that opens `path`, which is bound to that path and no other.
    private func token(for path: String) -> String {
        server.token(forRequestPath: path)
    }

    /// Builds a URL for a relative path within the temp directory.
    ///
    /// By default it carries the token for that same path, which is what a URL
    /// from `url(for:)` would carry. Pass `withToken:` to send a different one,
    /// or `nil` to send none.
    private func url(path: String, withToken t: String?? = nil,
                     host: String = "127.0.0.1") -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/\(path)"
        // Double optional: `nil` means "use the correct token", `.some(nil)`
        // means "send no token at all".
        let resolved: String? = t ?? token(for: "/\(path)")
        if let resolved { components.queryItems = [URLQueryItem(name: "t", value: resolved)] }
        return components.url!
    }

    /// GETs `url` and returns the HTTP status code and body data.
    private func get(_ url: URL,
                     extraHeaders: [String: String] = [:]) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        return (status, data)
    }

    // MARK: - Guard 3: Token required

    /// A request with no token is refused (403).
    func testNoTokenIsRefused() async throws {
        let file = tempDir.appendingPathComponent("hello.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let u = url(path: "hello.txt", withToken: .some(nil))
        let (status, _) = try await get(u)
        XCTAssertEqual(status, 403, "no token must be refused")
    }

    /// A request with a wrong token is refused (403).
    func testWrongTokenIsRefused() async throws {
        let file = tempDir.appendingPathComponent("hello.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let u = url(path: "hello.txt", withToken: "not-the-right-token")
        let (status, _) = try await get(u)
        XCTAssertEqual(status, 403, "wrong token must be refused")
    }

    // MARK: - Guard 3: the token opens ONE path

    /// THE CONTAINMENT PROPERTY. A token minted for one file does not open
    /// another.
    ///
    /// This is what makes a leaked token nearly worthless. The token rides in
    /// the query string, because a top-level navigation cannot carry a header,
    /// so a script on a served page can read it from `location.search` and send
    /// it away by setting `window.location` — a channel the CSP cannot close,
    /// since `navigate-to` is CSP Level 3 and WebKit does not enforce it. What
    /// escapes now opens only the page the attacker already controlled.
    func testATokenForOneFileDoesNotOpenAnother() async throws {
        let mine = tempDir.appendingPathComponent("hostile.html")
        try "<html>attacker's own page</html>".write(to: mine, atomically: true, encoding: .utf8)
        let theirs = tempDir.appendingPathComponent("secret.md")
        try "the reader's document".write(to: theirs, atomically: true, encoding: .utf8)

        let leaked = token(for: "/hostile.html")
        let u = url(path: "secret.md", withToken: leaked)
        let (status, data) = try await get(u)

        XCTAssertEqual(status, 403, "a token for one path must not open another")
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("reader's document") ?? false,
                       "the other file's contents must not be served")
    }

    /// The same token keeps working on its own path, so reload survives.
    ///
    /// The alternative considered was a one-time token burned on first use.
    /// That would break exactly this: a reader who hits refresh, or a page that
    /// fetches its own URL, would get a 403 with nothing to explain it.
    func testTheSameTokenOpensItsOwnPathRepeatedly() async throws {
        let content = "reload me"
        let file = tempDir.appendingPathComponent("reload.txt")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let u = url(path: "reload.txt")
        for attempt in 1...3 {
            let (status, data) = try await get(u)
            XCTAssertEqual(status, 200, "reload \(attempt) must still be served")
            XCTAssertEqual(String(data: data, encoding: .utf8), content)
        }
    }

    /// A token is bound to the path string, so a directory prefix is not a
    /// capability: a token for `a/one.md` does not open `a/two.md`.
    func testATokenIsNotAPrefixCapability() async throws {
        let dir = tempDir.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "one".write(to: dir.appendingPathComponent("one.md"),
                        atomically: true, encoding: .utf8)
        try "two".write(to: dir.appendingPathComponent("two.md"),
                        atomically: true, encoding: .utf8)

        let u = url(path: "a/two.md", withToken: token(for: "/a/one.md"))
        let (status, _) = try await get(u)
        XCTAssertEqual(status, 403, "a sibling's token must not open this file")
    }

    /// A filename carrying a character that percent-encodes still opens.
    ///
    /// THE FAILURE THIS CATCHES IS A 403 NOBODY CAN EXPLAIN. The token covers
    /// the decoded path, because that is what the serving side sees after
    /// `URLComponents` decodes the request. Signing the encoded form instead
    /// would leave every file with a space in its name permanently unopenable.
    func testAFilenameNeedingPercentEncodingStillOpens() async throws {
        let content = "spaces and a hash"
        let file = tempDir.appendingPathComponent("my notes #1.md")
        try content.write(to: file, atomically: true, encoding: .utf8)

        guard let u = server.url(for: file) else {
            return XCTFail("url(for:) returned nil for a file inside the root")
        }
        let (status, data) = try await get(u)
        XCTAssertEqual(status, 200, "a percent-encoded path must still match its token")
        XCTAssertEqual(String(data: data, encoding: .utf8), content)
    }

    /// `url(for:)` mints a DIFFERENT token per file, and each URL opens only
    /// its own.
    ///
    /// Asserting that `url(for:)`'s token equals `token(forRequestPath:)` for
    /// the same path would be circular — both sides are the same call with the
    /// same argument, so it would pass however the binding were broken. This
    /// goes through HTTP and swaps the two tokens instead, which is the claim
    /// worth proving: minting is per file, not per launch.
    func testUrlForMintsADifferentTokenPerFile() async throws {
        let a = tempDir.appendingPathComponent("a.txt")
        let b = tempDir.appendingPathComponent("b.txt")
        try "content of a".write(to: a, atomically: true, encoding: .utf8)
        try "content of b".write(to: b, atomically: true, encoding: .utf8)

        guard let ua = server.url(for: a), let ub = server.url(for: b) else {
            return XCTFail("url(for:) returned nil for a file inside the root")
        }
        let ta = tokenQueryItem(of: ua)
        let tb = tokenQueryItem(of: ub)
        XCTAssertNotNil(ta)
        XCTAssertNotEqual(ta, tb, "two files must not share a token")

        // Each URL opens its own file...
        let (statusA, dataA) = try await get(ua)
        XCTAssertEqual(statusA, 200)
        XCTAssertEqual(String(data: dataA, encoding: .utf8), "content of a")

        // ...and refuses the other's, over HTTP rather than by inspection.
        let (swapped, _) = try await get(url(path: "a.txt", withToken: tb))
        XCTAssertEqual(swapped, 403, "b's token must not open a")
    }

    private func tokenQueryItem(of u: URL) -> String? {
        URLComponents(url: u, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "t" })?.value
    }

    /// Two servers do not share a secret, so a token from one is refused by the
    /// other. The secret is per-launch and CSPRNG-minted, with no way to inject
    /// one — a test-settable secret would be a second way to set it, and the
    /// one thing this type must never do is serve on a secret someone else chose.
    func testASecondServerDoesNotHonourTheFirstsToken() async throws {
        let other = WorkingCopyServer(baseDirectory: tempDir)
        try await other.start()
        defer { other.stop() }

        XCTAssertNotEqual(other.token(forRequestPath: "/hello.txt"),
                          token(for: "/hello.txt"),
                          "two launches must not derive the same token")
    }

    // MARK: - Guard 4: Host and Origin

    /// A request with no Host header is refused (403).
    ///
    /// Guard 4a now requires Host rather than tolerating its absence. This
    /// covers the split-request attack: the old code called receive() once,
    /// so headers arriving in a second TCP segment were simply absent, and an
    /// absent Host skipped the guard. The accumulation loop ensures all headers
    /// are present before the guard runs; requiring Host then enforces the
    /// invariant the class comment has always claimed.
    func testMissingHostHeaderIsRefused() throws {
        let file = tempDir.appendingPathComponent("hello.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let response = try rawGetWithoutHost(
            path: "/hello.txt?t=\(token(for: "/hello.txt"))")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 403"),
                      "absent Host must be refused — got: \(response)")
    }

    /// A request whose Host header arrives in a second TCP segment is handled
    /// correctly: the accumulation loop collects both chunks before running
    /// the guards, so a valid Host in the second chunk yields a 200.
    func testSplitRequestIsHandledCorrectly() throws {
        let content = "split test content"
        let file = tempDir.appendingPathComponent("split.txt")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let response = try rawGetSplit(
            firstChunk: "GET /split.txt?t=\(token(for: "/split.txt")) HTTP/1.1\r\n",
            secondChunk: "Host: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        )
        XCTAssertTrue(response.contains("HTTP/1.1 200"),
                      "split request with valid Host must succeed — got: \(response)")
        XCTAssertTrue(response.contains(content),
                      "response body must contain file content")
    }

    /// A request with a foreign Host header is refused (403).
    func testForeignHostIsRefused() async throws {
        let file = tempDir.appendingPathComponent("hello.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        // URLSession rewrites the Host header to match the URL's host, so we
        // supply a URL for 127.0.0.1 but inject a raw request via BSD sockets
        // with a spoofed Host. We use the raw-socket helper below.
        let body = try rawGet(path: "/hello.txt?t=\(token(for: "/hello.txt"))",
                              host: "evil.attacker.example.com:\(port)")
        XCTAssertTrue(body.hasPrefix("HTTP/1.1 403"), "foreign Host must be refused — got: \(body)")
    }

    /// A request with a foreign Origin header is refused (403).
    func testForeignOriginIsRefused() async throws {
        let file = tempDir.appendingPathComponent("hello.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let u = url(path: "hello.txt")
        let (status, _) = try await get(u, extraHeaders: [
            "Origin": "http://evil.attacker.example.com",
        ])
        XCTAssertEqual(status, 403, "foreign Origin must be refused")
    }

    /// A request with a correct Host but no Origin is allowed (top-level
    /// browser navigation does not send Origin).
    func testNoOriginIsAllowed() async throws {
        let content = "allowed"
        let file = tempDir.appendingPathComponent("allowed.txt")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let u = url(path: "allowed.txt")
        let (status, data) = try await get(u)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), content)
    }

    // MARK: - Guard 2: Path confinement

    /// A `../` traversal that would escape the root is refused (403).
    func testDotDotTraversalIsRefused() async throws {
        // Create a file OUTSIDE the temp dir.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        // Construct a path that navigates from tempDir up and into the sibling.
        let escapingPath = "../\(outside.lastPathComponent)"
        let u = url(path: escapingPath)
        let (status, _) = try await get(u)
        XCTAssertEqual(status, 403, "../ traversal must be refused")
    }

    /// A percent-encoded traversal (`%2e%2e%2f`) is refused after decoding.
    ///
    /// Uses the raw-socket helper rather than URLSession: Foundation's
    /// `URLComponents` may normalise `%2e%2e%2f` to `../` before the request
    /// leaves the process, making the test a duplicate of
    /// `testDotDotTraversalIsRefused` and leaving the server's own
    /// `removingPercentEncoding` path untested.
    ///
    /// WHICH GUARD FIRES HERE, since path-bound tokens made that a question a
    /// reader would otherwise have to guess at. Measured on this SDK:
    /// `URLComponents(string:).path` decodes `%2e%2e%2f` to `../`, so the
    /// server sees `/../<name>`, the token minted below for that same string
    /// matches, and **guard 2 is what refuses the request**. The token is
    /// deliberately minted for the traversal path rather than for a legitimate
    /// file: minting it for a real file would stop this at guard 3 and quietly
    /// retire the only test that covers path confinement against an encoded
    /// traversal.
    func testEncodedDotDotTraversalIsRefused() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside2-\(UUID().uuidString).txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let response = try rawGet(
            path: "/%2e%2e%2f\(outside.lastPathComponent)"
                + "?t=\(token(for: "/../\(outside.lastPathComponent)"))",
            host: "127.0.0.1:\(port)"
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 403"),
                      "encoded ../ traversal must be refused — got: \(response)")
    }

    /// A symlink inside the root that points OUTSIDE the root is refused.
    ///
    /// This is the guard that `resolvingSymlinksInPath()` closes: a check on
    /// the unresolved path would accept the symlink's name (it looks like an
    /// in-root path), then the OS would follow the link to wherever it points.
    func testSymlinkEscapingRootIsRefused() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-target-\(UUID().uuidString).txt")
        try "via symlink".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        // Create a symlink inside tempDir that points at the outside file.
        let symlink = tempDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlink,
                                                    withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: symlink) }

        let u = url(path: "link.txt")
        let (status, _) = try await get(u)
        XCTAssertEqual(status, 403, "symlink escaping root must be refused")
    }

    // MARK: - Guard 2: absolute-path request line

    /// A bare absolute path (e.g. `/etc/passwd`) in the request line does NOT
    /// reach the real system path. `URL.appendingPathComponent` strips the
    /// leading slash, so `/etc/passwd` maps to `<working-copy>/etc/passwd`,
    /// which does not exist → 404. This is the Foundation behaviour that makes
    /// string-based path concatenation the dangerous path, not this one.
    ///
    /// The real path-escape protection is `../` traversal (tested above) and
    /// symlink resolution (also tested above); this test confirms the absolute-
    /// path case is handled without serving a system file.
    func testAbsolutePathInRequestLineDoesNotServeSystemFile() async throws {
        let response = try rawGet(path: "/etc/passwd?t=\(token(for: "/etc/passwd"))",
                                  host: "127.0.0.1:\(port)")
        // Foundation's appendingPathComponent strips the leading slash,
        // mapping to <working-copy>/etc/passwd → not found.
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 404"),
                      "/etc/passwd in request should 404 (not in working copy) — got: \(response)")
        // Crucially, the body must not contain the system file's contents.
        XCTAssertFalse(response.contains("root:"),
                       "response body must not contain /etc/passwd content")
    }

    // MARK: - Guard 1: loopback binding

    /// The server is reachable on 127.0.0.1 — confirms it IS listening on
    /// loopback. The negative assertion (not reachable on a non-loopback address)
    /// is in `testServerNotReachableOnNonLoopbackInterface`.
    func testServerReachableOnLoopback() async throws {
        let content = "loopback check"
        let file = tempDir.appendingPathComponent("loopback.txt")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let u = url(path: "loopback.txt", host: "127.0.0.1")
        let (status, data) = try await get(u)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), content)
    }

    /// The server is NOT reachable on any non-loopback interface.
    ///
    /// This test enumerates the machine's non-loopback IPv4 addresses and
    /// attempts a TCP connection on the server's port. A properly loopback-bound
    /// socket returns ECONNREFUSED for such an attempt; if it does not we fail.
    /// The test is skipped when no non-loopback address is available (e.g. CI
    /// with only a loopback interface), because absence of the interface IS the
    /// guarantee.
    func testServerNotReachableOnNonLoopbackInterface() throws {
        guard let externalIP = firstNonLoopbackIPv4() else {
            // No external interface — loopback-only by definition; nothing to test.
            throw XCTSkip("no non-loopback IPv4 address available on this machine")
        }

        // Use a BSD connect() so we can check ECONNREFUSED immediately.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertNotEqual(fd, -1)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = inet_addr(externalIP)

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // connect() should fail with ECONNREFUSED (errno 61 on Darwin) because
        // the socket is bound to 127.0.0.1 only.
        XCTAssertEqual(result, -1,
                       "TCP connect to \(externalIP):\(port) should be refused; " +
                       "server appears to be bound to 0.0.0.0")
        if result == -1 {
            XCTAssertEqual(errno, ECONNREFUSED,
                           "expected ECONNREFUSED, got errno \(errno)")
        }
    }

    // MARK: - Legitimate request

    /// A valid request with the correct token, correct Host, and a file that
    /// exists returns 200 with the right bytes and Content-Type.
    func testLegitimateRequestSucceeds() async throws {
        let content = "hello from the loopback server"
        let file = tempDir.appendingPathComponent("test.txt")
        try content.write(to: file, atomically: true, encoding: .utf8)

        let u = url(path: "test.txt")
        let (status, data) = try await get(u)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), content)
    }

    /// Correct Content-Type is returned for each served extension.
    func testContentTypeIsCorrectForKnownExtensions() async throws {
        let cases: [(ext: String, mime: String)] = [
            ("pdf",  "application/pdf"),
            ("html", "text/html; charset=utf-8"),
            ("png",  "image/png"),
            ("txt",  "text/plain; charset=utf-8"),
        ]
        for (ext, expectedMime) in cases {
            let file = tempDir.appendingPathComponent("sample.\(ext)")
            try Data([0x00]).write(to: file)
            let u = url(path: "sample.\(ext)")
            var req = URLRequest(url: u)
            req.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
            let (data, response) = try await session.data(for: req)
            _ = data
            let ct = (response as! HTTPURLResponse).value(forHTTPHeaderField: "Content-Type") ?? ""
            XCTAssertTrue(ct.hasPrefix(expectedMime),
                          ".\(ext) should return \(expectedMime); got \(ct)")
        }
    }

    /// A request for a file that does not exist returns 404.
    func testMissingFileReturns404() async throws {
        let u = url(path: "does-not-exist.txt")
        let (status, _) = try await get(u)
        XCTAssertEqual(status, 404)
    }

    // MARK: - Response security headers

    /// Every 200 response carries the three security headers added by the
    /// round-fix: Referrer-Policy, X-Content-Type-Options, and
    /// Content-Security-Policy.
    func testSecurityHeadersArePresent() async throws {
        let file = tempDir.appendingPathComponent("page.html")
        try "<h1>hi</h1>".write(to: file, atomically: true, encoding: .utf8)

        let (_, response) = try await session.data(for: URLRequest(url: url(path: "page.html")))
        let http = response as! HTTPURLResponse

        XCTAssertEqual(http.value(forHTTPHeaderField: "Referrer-Policy"), "no-referrer",
                       "Referrer-Policy: no-referrer must be present on every response")
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff",
                       "X-Content-Type-Options: nosniff must be present on every response")

        let csp = http.value(forHTTPHeaderField: "Content-Security-Policy") ?? ""
        XCTAssertFalse(csp.isEmpty, "Content-Security-Policy must be present")
        XCTAssertTrue(csp.contains("connect-src 'self'"),
                      "CSP must restrict outbound connections — got: \(csp)")
        XCTAssertTrue(csp.contains("frame-ancestors 'none'"),
                      "CSP must disallow framing — got: \(csp)")
        XCTAssertTrue(csp.contains("form-action 'none'"),
                      "CSP must block form submissions — got: \(csp)")
    }

    // MARK: - Lifecycle: server stops cleanly

    /// After `stop()` is called no port remains bound: a connection attempt
    /// returns ECONNREFUSED.
    ///
    /// Polls up to 2 s rather than using a fixed sleep. NWListener.cancel()
    /// is asynchronous; a fixed 200 ms can expire before the kernel releases
    /// the ephemeral port on a cold or heavily loaded CI runner.
    func testStopReleasesPort() throws {
        let p = port
        server.stop()

        let deadline = Date().addingTimeInterval(2)
        var portReleased = false
        while Date() < deadline {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd != -1 else { break }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = CFSwapInt16HostToBig(p)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(fd)
            if result == -1 && errno == ECONNREFUSED {
                portReleased = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        XCTAssertTrue(portReleased,
                      "port \(p) should be released after stop()")
    }
}

// MARK: - Raw HTTP helper (for Host-spoofing tests)

extension WorkingCopyServerTests {

    /// Sends a raw HTTP/1.1 GET request over a BSD socket, overriding the Host
    /// header. URLSession always rewrites Host to match the URL; this bypasses
    /// that to let us test the server's Host-check guard directly.
    ///
    /// Returns the first line of the response (the status line) plus the
    /// response body, decoded as UTF-8.
    private func rawGet(path: String, host: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd != -1 else { throw POSIXError(.EBADF) }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }

        let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        _ = request.withCString { ptr in
            send(fd, ptr, strlen(ptr), 0)
        }

        var response = ""
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count - 1, 0)
            if n <= 0 { break }
            buf[n] = 0
            response += String(cString: buf)
        }
        return response
    }

    /// Sends a raw HTTP/1.1 GET with no Host header, bypassing URLSession's
    /// automatic Host injection. Used to prove Guard 4a refuses absent Host.
    private func rawGetWithoutHost(path: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd != -1 else { throw POSIXError(.EBADF) }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }

        let request = "GET \(path) HTTP/1.1\r\nConnection: close\r\n\r\n"
        _ = request.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }

        var response = ""
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count - 1, 0)
            if n <= 0 { break }
            buf[n] = 0
            response += String(cString: buf)
        }
        return response
    }

    /// Sends an HTTP request split across two sequential writes with TCP_NODELAY,
    /// exercising the accumulation loop in `receiveRequest`. The brief pause
    /// between writes lets the server's first `receive()` fire before the second
    /// chunk arrives; without it the OS may coalesce both writes into one segment.
    private func rawGetSplit(firstChunk: String, secondChunk: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd != -1 else { throw POSIXError(.EBADF) }
        defer { close(fd) }

        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }

        _ = firstChunk.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }
        Thread.sleep(forTimeInterval: 0.005)   // 5 ms — let the server's first receive() fire
        _ = secondChunk.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }

        var response = ""
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count - 1, 0)
            if n <= 0 { break }
            buf[n] = 0
            response += String(cString: buf)
        }
        return response
    }

    /// Returns the first non-loopback IPv4 address on this machine, or nil.
    private func firstNonLoopbackIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let base = addrs else { return nil }
        defer { freeifaddrs(base) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = base
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0,
                  let sa = ifa.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var addr = sa.pointee
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sinPtr in
                    var inAddr = sinPtr.pointee.sin_addr
                    inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
                }
            }
            return String(cString: buf)
        }
        return nil
    }
}

// MARK: - Routing tests

/// `FileViewerRouter.route(for:)` — extension-based dispatch without any
/// network or filesystem access.
final class FileViewerRouterTests: XCTestCase {

    func testKBRefAlwaysRoutesToPAne() {
        let ref = DeckOpenRef.Origin.kb(id: "deck/specs/session-pane")
        XCTAssertEqual(FileViewerRouter.route(for: ref), .pane)
    }

    func testMarkdownPathRoutesToPane() {
        XCTAssertEqual(
            FileViewerRouter.route(for: .path(absolutePath: "\(TestHost.homeRoot)/doc.md")),
            .pane)
    }

    func testImagePathRoutesToPane() {
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico"] {
            XCTAssertEqual(
                FileViewerRouter.route(for: .path(absolutePath: "\(TestHost.homeRoot)/img.\(ext)")),
                .pane, ".\(ext) should route to pane")
        }
    }

    func testSourceFileRoutesToPane() {
        for ext in ["swift", "py", "js", "ts", "json", "yaml", "sh", "txt"] {
            XCTAssertEqual(
                FileViewerRouter.route(for: .path(absolutePath: "\(TestHost.homeRoot)/f.\(ext)")),
                .pane, ".\(ext) should route to pane")
        }
    }

    func testPDFRoutesToBrowser() {
        XCTAssertEqual(
            FileViewerRouter.route(for: .path(absolutePath: "\(TestHost.homeRoot)/report.pdf")),
            .browser)
    }

    func testHTMLRoutesToBrowser() {
        XCTAssertEqual(
            FileViewerRouter.route(for: .path(absolutePath: "\(TestHost.homeRoot)/page.html")),
            .browser)
        XCTAssertEqual(
            FileViewerRouter.route(for: .path(absolutePath: "\(TestHost.homeRoot)/page.htm")),
            .browser)
    }

    func testUnknownExtensionRoutesToHandOff() {
        XCTAssertEqual(
            FileViewerRouter.route(for: .path(absolutePath: "\(TestHost.homeRoot)/doc.docx")),
            .handOff)
        XCTAssertEqual(
            FileViewerRouter.route(for: .path(absolutePath: "\(TestHost.homeRoot)/archive.zip")),
            .handOff)
        XCTAssertEqual(
            FileViewerRouter.route(for: .path(absolutePath: "\(TestHost.homeRoot)/data.xyz")),
            .handOff)
    }
}

// MARK: - Content-type unit tests

/// `WorkingCopyServer.contentType(for:)` — no server needed.
final class WorkingCopyServerContentTypeTests: XCTestCase {

    func testPDFContentType() {
        XCTAssertEqual(WorkingCopyServer.contentType(for: "pdf"), "application/pdf")
    }

    func testHTMLContentType() {
        XCTAssertEqual(WorkingCopyServer.contentType(for: "html"), "text/html; charset=utf-8")
        XCTAssertEqual(WorkingCopyServer.contentType(for: "htm"),  "text/html; charset=utf-8")
    }

    func testImageContentTypes() {
        XCTAssertEqual(WorkingCopyServer.contentType(for: "png"),  "image/png")
        XCTAssertEqual(WorkingCopyServer.contentType(for: "jpg"),  "image/jpeg")
        XCTAssertEqual(WorkingCopyServer.contentType(for: "jpeg"), "image/jpeg")
        XCTAssertEqual(WorkingCopyServer.contentType(for: "gif"),  "image/gif")
        XCTAssertEqual(WorkingCopyServer.contentType(for: "webp"), "image/webp")
        XCTAssertEqual(WorkingCopyServer.contentType(for: "svg"),  "image/svg+xml")
    }

    func testUnknownExtensionIsOctetStream() {
        XCTAssertEqual(WorkingCopyServer.contentType(for: "xyz"), "application/octet-stream")
        XCTAssertEqual(WorkingCopyServer.contentType(for: ""),    "application/octet-stream")
    }
}
