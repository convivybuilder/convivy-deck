import XCTest
@testable import Deck
#if canImport(Darwin)
import Darwin
#endif

/// `KeelHTTPExchange`: the hand-rolled HTTP/1.1 layer under `KeelClient`.
///
/// TWO KINDS OF TEST IN THIS FILE, AND THEY ARE LABELLED. The `Pure`
/// section exercises `requestBytes`/`parse` against literal bytes — no
/// socket, no process, nothing that could be stale or flaky. The `Live`
/// section dials the REAL `run-register-api` socket this development machine
/// exposes at `~/.local/run/run-register-api.sock` — confirmed present and
/// answering by hand before this file was written (`curl --unix-socket`).
/// This is a genuine live exercise of rules 1 and 2 from
/// `platform/contracts/deck-keel-wire`, but it is scoped to the
/// socket-and-HTTP layer only: nothing here goes over an ssh forward — see
/// `KeelForwardTests`' header for why that hop stays fixture/argv-tested in
/// this environment.
final class KeelHTTPExchangeTests: XCTestCase {

    /// The one real thing every live test in this file depends on: a Keel
    /// or Keel-adjacent process actually listening at this path. If this
    /// fails, every `Live` test below is meaningless (it would report
    /// `.transport` whether or not the transport code is correct), so it
    /// is checked first and skips the rest of the suite loudly rather than
    /// letting them pass for the wrong reason.
    private static let liveSocketPath =
        NSHomeDirectory() + "/.local/run/run-register-api.sock"

    private func requireLiveSocket(file: StaticString = #filePath, line: UInt = #line) throws {
        guard FileManager.default.fileExists(atPath: Self.liveSocketPath) else {
            throw XCTSkip(
                "no `run-register-api` socket at \(Self.liveSocketPath) on this machine — "
                + "skipping the live half of KeelHTTPExchangeTests", file: file, line: line)
        }
    }

    // MARK: - Pure: requestBytes

    func testRequestBytesCarryTheRequestLineAndHostHeader() {
        let data = KeelHTTPExchange.requestBytes(
            method: "GET", host: "localhost", path: "/runs", headers: [:], body: nil)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /runs HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: localhost\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    /// Every request carries `Connection: close` — the whole reason
    /// `KeelHTTPExchange.exchange` is allowed to read until EOF rather than
    /// needing a real keep-alive-aware parser.
    func testRequestBytesAlwaysCarryConnectionClose() {
        let data = KeelHTTPExchange.requestBytes(
            method: "GET", host: "localhost", path: "/runs", headers: [:], body: nil)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Connection: close\r\n"))
    }

    /// A body adds `Content-Length` and the raw bytes after the header
    /// terminator — no body means no `Content-Length` header at all.
    func testRequestBytesCarryContentLengthOnlyWhenThereIsABody() {
        let noBody = KeelHTTPExchange.requestBytes(
            method: "GET", host: "localhost", path: "/runs", headers: [:], body: nil)
        XCTAssertFalse(String(decoding: noBody, as: UTF8.self).lowercased().contains("content-length"))

        let payload = Data(#"{"session":"crew-1"}"#.utf8)
        let withBody = KeelHTTPExchange.requestBytes(
            method: "POST", host: "localhost", path: "/sessions", headers: [:], body: payload)
        let text = String(decoding: withBody, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Length: \(payload.count)\r\n"))
        XCTAssertTrue(withBody.suffix(payload.count) == payload)
    }

    /// A caller-supplied header (`Authorization`) survives into the raw
    /// bytes — this is what `KeelClient` depends on to attach a caller's
    /// token.
    func testRequestBytesCarryCallerSuppliedHeaders() {
        let data = KeelHTTPExchange.requestBytes(
            method: "GET", host: "localhost", path: "/runs",
            headers: ["Authorization": "Bearer secret-token-value"], body: nil)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Authorization: Bearer secret-token-value\r\n"))
    }

    // MARK: - Pure: parse

    func testParseReadsStatusAndBodyByContentLength() throws {
        let raw = Data(
            "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"ok\": true}\nEXTRA"
                .utf8)
        let response = try KeelHTTPExchange.parse(raw)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "{\"ok\": true}\n")
    }

    /// No `Content-Length` at all — the shape `readAllUntilClosed` produces
    /// when the peer simply stops writing and closes. `parse` reads
    /// whatever followed the header block in that case rather than
    /// truncating to nothing.
    func testParseReadsTheWholeRemainderWhenThereIsNoContentLength() throws {
        let raw = Data("HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nno length declared here".utf8)
        let response = try KeelHTTPExchange.parse(raw)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "no length declared here")
    }

    func testParseThrowsOnANonHTTPStatusLine() {
        let raw = Data("<html><body>not http at all</body></html>\r\n\r\n".utf8)
        XCTAssertThrowsError(try KeelHTTPExchange.parse(raw))
    }

    /// No header/body terminator at all — a truncated or malformed
    /// response. Throws rather than guessing where the body starts.
    func testParseThrowsWhenThereIsNoHeaderTerminator() {
        let raw = Data("HTTP/1.0 200 OK\r\nContent-Length: 5".utf8)
        XCTAssertThrowsError(try KeelHTTPExchange.parse(raw))
    }

    func testParseReadsA404StatusAndItsBody() throws {
        // The exact bytes measured against the live `run-register-api` socket
        // (`curl --unix-socket ... http://localhost/nope`, 2026-08-29).
        let raw = Data(
            """
            HTTP/1.0 404 Not Found\r
            Server: BaseHTTP/0.6 Python/3.11.15\r
            Content-Type: application/json; charset=utf-8\r
            Content-Length: 22\r
            \r
            {"error": "not found"}
            """.utf8)
        let response = try KeelHTTPExchange.parse(raw)
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "{\"error\": \"not found\"}")
    }

    // MARK: - Pure: readAllUntilClosed's errno mapping

    /// A closed, invalid fd makes `read()` fail with `EBADF` — deterministic
    /// and immediate, no timing dependency, and an errno a genuine read
    /// timeout (`EAGAIN`/`EWOULDBLOCK`) never produces. Before the fix this
    /// pins, EVERY negative `read()` was reported as `.timedOut` with "...
    /// failed or timed out" in the message regardless of the actual errno,
    /// which is exactly what this asserts against.
    func testReadAllUntilClosedDoesNotClaimTimedOutForANonTimeoutErrno() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        Darwin.close(fds[0])
        Darwin.close(fds[1])
        XCTAssertThrowsError(try KeelHTTPExchange.readAllUntilClosed(fd: fds[0])) { error in
            let text = "\(error)"
            XCTAssertFalse(
                text.lowercased().contains("timed out"),
                "EBADF must not be reported as a timeout: \(text)")
            XCTAssertTrue(
                text.lowercased().contains("bad file descriptor"),
                "the real errno text should still reach the message: \(text)")
        }
    }

    /// The other side of the same mapping: a read that genuinely times out
    /// (`SO_RCVTIMEO` firing on a socket nothing ever writes to) still comes
    /// back as `.timedOut` — confirming the fix narrows the case rather than
    /// removing it.
    func testReadAllUntilClosedStillReportsTimedOutOnARealReadTimeout() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
        }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        XCTAssertEqual(
            setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)), 0)
        XCTAssertThrowsError(try KeelHTTPExchange.readAllUntilClosed(fd: fds[0])) { error in
            guard case KeelSocketError.timedOut = error else {
                return XCTFail("expected .timedOut, got \(error)")
            }
        }
    }

    // MARK: - Live: the real `run-register-api` socket

    /// THE BASELINE LIVE CHECK: a real request over a real unix-domain
    /// socket, with no envelope-shape assumptions at all, must come back
    /// with SOMETHING — this is what proves `KeelSocket.connect` +
    /// `KeelHTTPExchange.exchange` genuinely dial, write, and read over a
    /// live AF_UNIX file descriptor, before any of the transport
    /// classification tests below build on that.
    func testLiveRunsEndpointAnswersOverARealUnixSocket() throws {
        try requireLiveSocket()
        let fd = try KeelSocket.connect(.unixSocket(path: Self.liveSocketPath), timeout: 5)
        let response = try KeelHTTPExchange.exchange(
            fd: fd, method: "GET", host: "localhost", path: "/runs",
            headers: [:], body: nil, timeout: 5)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("generated_at"))
    }

    /// Confirmed by hand before this test existed (`curl --unix-socket ...
    /// /runs`, 2026-08-29): the real `/runs` response is well-formed JSON
    /// with NO `ok` field — `{"generated_at": ..., "runs": [...]}`. This is
    /// the live half of rule 2 ("a body that arrives but doesn't decode is
    /// `transport`, not an unrecognised kind") at the layer below
    /// `KeelClient`: this file doesn't decode a `KeelEnvelope` at all, but
    /// it does confirm the body genuinely lacks an `ok` key rather than the
    /// assumption being untested.
    func testLiveRunsBodyHasNoOkField() throws {
        try requireLiveSocket()
        let fd = try KeelSocket.connect(.unixSocket(path: Self.liveSocketPath), timeout: 5)
        let response = try KeelHTTPExchange.exchange(
            fd: fd, method: "GET", host: "localhost", path: "/runs",
            headers: [:], body: nil, timeout: 5)
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertNotNil(object)
        XCTAssertNil(object?["ok"], "the live /runs body was expected to carry no \"ok\" field")
    }

    /// A route `run-register-api` does not serve answers 404 with
    /// `{"error": "not found"}` — confirmed by hand, and not a Keel
    /// envelope shape either (no `ok`, no `kind`).
    func testLiveUnknownRouteAnswers404WithNoEnvelopeShape() throws {
        try requireLiveSocket()
        let fd = try KeelSocket.connect(.unixSocket(path: Self.liveSocketPath), timeout: 5)
        let response = try KeelHTTPExchange.exchange(
            fd: fd, method: "GET", host: "localhost", path: "/nope",
            headers: [:], body: nil, timeout: 5)
        XCTAssertEqual(response.status, 404)
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertNil(object?["ok"])
    }

    /// A socket path nothing is listening on must fail fast as a connect
    /// error, never hang — `KeelConnection.unixSocket` with a path this
    /// machine genuinely has no listener on.
    func testConnectingToAnAbsentSocketPathFailsRatherThanHanging() {
        let start = Date()
        XCTAssertThrowsError(
            try KeelSocket.connect(.unixSocket(path: "/tmp/keel-transport-test-no-such-socket.sock"), timeout: 5))
        // Well under the 5s timeout budget — an absent AF_UNIX path refuses
        // at connect() immediately (ENOENT), the same way a TCP port with
        // nothing listening refuses immediately rather than needing the
        // full timeout to elapse.
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// The other absent-transport shape named in the task: a TCP port with
    /// nothing listening (the shape a dead or not-yet-started
    /// `KeelForward` leaves behind) also fails fast rather than hanging.
    func testConnectingToATCPPortWithNothingListeningFailsRatherThanHanging() {
        let start = Date()
        // Port 1 is a real, always-unused-by-anything-Deck-owns loopback
        // port in the well-known reserved range — nothing binds it.
        XCTAssertThrowsError(try KeelSocket.connect(.forwardedPort(1), timeout: 5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
