import XCTest
@testable import Deck

/// `HostProbe.outcome(forProbedName:)` — the pure classification the Test
/// button's landed probe runs through, on the actual path `HostProbe.test`
/// calls rather than a duplicate. See `deck/specs/multiple-sessions-per-project`
/// §"Crews on different hosts".
final class HostProbeTests: XCTestCase {
    func testCleanNameClassifiesAsReachableUnchanged() {
        XCTAssertEqual(HostProbe.outcome(forProbedName: "guests-mini"),
                       .reachable(machineName: "guests-mini"))
    }

    func testEmptyNameClassifiesAsRefused() {
        XCTAssertEqual(HostProbe.outcome(forProbedName: ""),
                       .refused("hostname -s returned nothing"))
    }

    /// The finding this pins: a mini that answers with Markdown link syntax
    /// (or anything else outside the charset gate) must not reach the badge
    /// or detail text unsanitized — it's replaced with `HostDisplay`'s
    /// placeholder, same as any other machine name that fails the gate.
    /// Mutation check: delete the `HostDisplay.machineLabel` call in
    /// `HostProbe.outcome(forProbedName:)` (return `.reachable(machineName: name)`
    /// directly) and this goes red.
    func testMarkdownLinkSyntaxIsReplacedWithPlaceholder() {
        XCTAssertEqual(HostProbe.outcome(forProbedName: "[click me](https://evil.example)"),
                       .reachable(machineName: HostDisplay.placeholder))
    }

    func testOverlongNameIsReplacedWithPlaceholder() {
        let tooLong = String(repeating: "a", count: HostDisplay.maximumMachineLength + 1)
        XCTAssertEqual(HostProbe.outcome(forProbedName: tooLong),
                       .reachable(machineName: HostDisplay.placeholder))
    }
}

// MARK: - classify(envelope:) / classify(fetchError:) — pure, no socket

/// `HostProbe.classify(envelope:)`/`classify(fetchError:)`: which server
/// kinds fall back to ssh and which surface as a failure, pinned without a
/// socket or an ssh process.
final class HostProbeKeelClassificationTests: XCTestCase {
    func testOkEnvelopeClassifiesAsTheHostName() {
        let envelope: KeelEnvelope<HostProbe.HostNameResult> =
            .ok(HostProbe.HostNameResult(hostName: "fixture-host"))
        XCTAssertEqual(HostProbe.classify(envelope: envelope), .hostName("fixture-host"))
    }

    /// An empty but successfully decoded name is still `.hostName("")`, not
    /// a fallback trigger — `probe`'s own tests confirm the fallback closure
    /// is never called for this case; this pins the classification it rests
    /// on.
    func testOkEnvelopeWithEmptyNameClassifiesAsTheEmptyHostName() {
        let envelope: KeelEnvelope<HostProbe.HostNameResult> =
            .ok(HostProbe.HostNameResult(hostName: ""))
        XCTAssertEqual(HostProbe.classify(envelope: envelope), .hostName(""))
    }

    func testNoSuchMethodClassifiesAsFallBackToSSH() {
        let envelope: KeelEnvelope<HostProbe.HostNameResult> =
            .error(kind: .noSuchMethod, message: "the endpoint does not serve this verb", detail: nil)
        XCTAssertEqual(HostProbe.classify(envelope: envelope), .fallBackToSSH)
    }

    /// Every other server-told kind fails outright — no fallback. One test
    /// per kind named in the task, plus an unrecognised one, rather than a
    /// single parameterized case, so a future kind added to only one branch
    /// of `classify` is caught by name.
    func testForbiddenDoesNotFallBack() {
        let envelope: KeelEnvelope<HostProbe.HostNameResult> =
            .error(kind: .forbidden, message: "no capability", detail: nil)
        XCTAssertEqual(HostProbe.classify(envelope: envelope),
                       .failed(.server(kind: .forbidden, message: "no capability", detail: nil)))
    }

    func testUnavailableDoesNotFallBack() {
        let envelope: KeelEnvelope<HostProbe.HostNameResult> =
            .error(kind: .unavailable, message: "cannot serve this now", detail: nil)
        XCTAssertEqual(HostProbe.classify(envelope: envelope),
                       .failed(.server(kind: .unavailable, message: "cannot serve this now", detail: nil)))
    }

    func testUnrecognizedKindDoesNotFallBack() {
        let envelope: KeelEnvelope<HostProbe.HostNameResult> =
            .error(kind: .unrecognized("something-future"), message: "?", detail: nil)
        XCTAssertEqual(HostProbe.classify(envelope: envelope),
                       .failed(.server(kind: .unrecognized("something-future"), message: "?", detail: nil)))
    }

    func testUnauthenticatedDoesNotFallBack() {
        let envelope: KeelEnvelope<HostProbe.HostNameResult> =
            .error(kind: .unauthenticated, message: "no identity", detail: nil)
        XCTAssertEqual(HostProbe.classify(envelope: envelope),
                       .failed(.server(kind: .unauthenticated, message: "no identity", detail: nil)))
    }

    func testRefusedDoesNotFallBack() {
        let envelope: KeelEnvelope<HostProbe.HostNameResult> =
            .error(kind: .refused, message: "declined", detail: nil)
        XCTAssertEqual(HostProbe.classify(envelope: envelope),
                       .failed(.server(kind: .refused, message: "declined", detail: nil)))
    }

    func testTransportFetchErrorClassifiesAsFallBackToSSH() {
        XCTAssertEqual(HostProbe.classify(fetchError: .transport("forward never came up")),
                       .fallBackToSSH)
    }
}

// MARK: - probe(target:fetchKeelHostName:fetchHostNameFallback:) — fakes for the transport, no network

/// `HostProbe.probe`'s own fallback decision, exercised end to end with
/// fakes standing in for both the Keel call and the ssh fallback — neither
/// a real socket nor a real ssh process runs in this file.
final class HostProbeTransportFallbackTests: XCTestCase {
    private let target = SSHTarget(user: "orchard", host: "fleet-host")

    /// Fails the test if the ssh fallback is ever invoked — used by every
    /// case below that must not fall back.
    private func failingSSHFallback(file: StaticString = #filePath, line: UInt = #line) -> (SSHTarget) throws -> String {
        { _ in
            XCTFail("the ssh fallback must not run here", file: file, line: line)
            return "unreachable"
        }
    }

    func testHostNameSuccessReturnsTheName() throws {
        let name = try HostProbe.probe(
            target: target,
            fetchKeelHostName: { _ in .ok(HostProbe.HostNameResult(hostName: "fixture-host")) },
            fetchHostNameFallback: failingSSHFallback())
        XCTAssertEqual(name, "fixture-host")
    }

    /// A decoded success with an empty name is returned as-is — the
    /// fallback is not a retry-on-anything-unexpected mechanism.
    func testEmptyDecodedNameDoesNotFallBack() throws {
        let name = try HostProbe.probe(
            target: target,
            fetchKeelHostName: { _ in .ok(HostProbe.HostNameResult(hostName: "")) },
            fetchHostNameFallback: failingSSHFallback())
        XCTAssertEqual(name, "")
    }

    func testNoSuchMethodFallsBackToSSH() throws {
        let name = try HostProbe.probe(
            target: target,
            fetchKeelHostName: { _ in
                .error(kind: .noSuchMethod, message: "the endpoint does not serve this verb", detail: nil)
            },
            fetchHostNameFallback: { _ in "ssh-answered-host" })
        XCTAssertEqual(name, "ssh-answered-host")
    }

    func testTransportFailureFallsBackToSSH() throws {
        let name = try HostProbe.probe(
            target: target,
            fetchKeelHostName: { _ in throw KeelError.transport("forward never came up") },
            fetchHostNameFallback: { _ in "ssh-answered-host" })
        XCTAssertEqual(name, "ssh-answered-host")
    }

    func testForbiddenDoesNotFallBackAndThrows() {
        XCTAssertThrowsError(try HostProbe.probe(
            target: target,
            fetchKeelHostName: { _ in .error(kind: .forbidden, message: "no capability", detail: nil) },
            fetchHostNameFallback: failingSSHFallback())
        ) { error in
            guard case KeelError.server(.forbidden, _, _) = error else {
                return XCTFail("expected a forbidden server error, got \(error)")
            }
        }
    }

    func testUnavailableDoesNotFallBackAndThrows() {
        XCTAssertThrowsError(try HostProbe.probe(
            target: target,
            fetchKeelHostName: { _ in .error(kind: .unavailable, message: "cannot serve this now", detail: nil) },
            fetchHostNameFallback: failingSSHFallback())
        ) { error in
            guard case KeelError.server(.unavailable, _, _) = error else {
                return XCTFail("expected an unavailable server error, got \(error)")
            }
        }
    }

    func testUnrecognizedKindDoesNotFallBackAndThrows() {
        XCTAssertThrowsError(try HostProbe.probe(
            target: target,
            fetchKeelHostName: { _ in .error(kind: .unrecognized("something-future"), message: "?", detail: nil) },
            fetchHostNameFallback: failingSSHFallback())
        ) { error in
            guard case KeelError.server(.unrecognized("something-future"), _, _) = error else {
                return XCTFail("expected an unrecognised-kind server error, got \(error)")
            }
        }
    }
}

// MARK: - Live: a fixture Individuator stand-in over a real unix socket

/// `HostProbe.fetchHostNameOverKeel`'s own transport, exercised live —
/// `KeelSocket.connect` + `KeelHTTPExchange.exchange` + `KeelClient.call` +
/// `KeelEnvelope` decoding, the same stack `KeelHTTPExchangeTests`'s `Live`
/// section already runs against the real `run-register-api` socket.
///
/// NO REAL INDIVIDUATOR IS REACHABLE FROM THIS SANDBOX — CQ·688 deployed one
/// to the Keel host, not to wherever this suite runs — so this dials a fixture
/// stand-in instead, over a direct unix socket rather than `KeelForward`'s
/// ssh hop, for the same reason `KeelForwardTests`' own header gives for
/// staying argv-only: there is no live forward target this environment can
/// reach. What this DOES prove live: a real `POST /host-name` over a real
/// AF_UNIX socket, written in the wire contract's envelope shape, decodes to
/// exactly the `HostNameResult` `classify(envelope:)` expects.
final class HostProbeLiveKeelRoundTripTests: XCTestCase {
    func testLiveRoundTripAgainstAFixtureHostNameServer() throws {
        let tempDir = URL(fileURLWithPath: "/tmp/hp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let server = try FixtureHostNameServer(directory: tempDir, hostName: "fixture-host")
        defer { server.stop() }

        let envelope: KeelEnvelope<HostProbe.HostNameResult> = try KeelClient.call(
            connection: .unixSocket(path: server.path),
            method: "POST", path: "/host-name",
            caller: .operatorSession(KeelToken("")))
        XCTAssertEqual(HostProbe.classify(envelope: envelope), .hostName("fixture-host"))
    }
}

// MARK: - Fixtures

/// A minimal Individuator stand-in: one AF_UNIX listener that answers a
/// single `POST /host-name` with the envelope shape CQ·688's own outcome
/// note measured from the real one on the Keel host
/// (`{"ok":true,"result":{"host_name":"<name>"}}`), then exits. Backed by a
/// real `python3` subprocess, the same choice `WedgedControlSocket` makes in
/// `SSHProcessRunnerTests` and for the same reason: the socket behaves
/// exactly like a real server process rather than an approximation built
/// from Swift's own socket APIs.
final class FixtureHostNameServer {
    private let process: Process
    let path: String

    init(directory: URL, hostName: String) throws {
        path = directory.appendingPathComponent("fixture-keel.sock").path
        let script = """
        import socket, sys
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(sys.argv[1])
        s.listen(1)
        conn, _ = s.accept()
        conn.recv(65536)
        body = sys.argv[2].encode()
        response = (
            b"HTTP/1.0 200 OK\\r\\n"
            + b"Content-Type: application/json\\r\\n"
            + ("Content-Length: %d\\r\\n" % len(body)).encode()
            + b"\\r\\n"
            + body
        )
        conn.sendall(response)
        conn.close()
        s.close()
        """
        let body = #"{"ok":true,"result":{"host_name":"\#(hostName)"}}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, path, body]
        try process.run()
        self.process = process

        // The listener needs a moment to bind before a test connects to it
        // — the same readiness poll `WedgedControlSocket` uses, for the
        // same reason: a real check rather than a fixed sleep guessing at
        // one.
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline {
            usleep(10_000)
        }
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}
