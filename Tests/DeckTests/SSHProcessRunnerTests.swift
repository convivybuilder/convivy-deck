import XCTest
@testable import Deck

/// `SSHProcessRunner.run`, exercised against REAL reproductions of every
/// control-socket state found while chasing the 2026-08-17 incident — a
/// laptop whose rail and both panes went blank with no stderr, no crash, and
/// no log line for several minutes, caused by a stale `~/.ssh/deck-cm-*`
/// socket. Nothing here is a guess about what ssh does: each fixture is the
/// literal socket-file shape reproduced by hand while diagnosing the
/// incident (see the PR body for the manual transcript), turned into a test
/// so a regression here fails loudly instead of reintroducing an unbounded
/// hang.
///
/// `WedgedControlSocket` simulates the one shape that actually mattered: a
/// ControlMaster process that is alive enough to `accept()` a new mux
/// client's connection — so `ControlMaster=auto`'s own "stale socket,
/// unlinking" recovery never fires, since as far as ssh can tell something
/// IS listening — but is blocked and never completes the mux protocol
/// handshake, because its underlying transport to the real host died out
/// from under it (a sleep/wake that dropped the TCP session before the
/// master noticed). That is the one socket state that hangs both a normal
/// ssh connection attempt and `ssh -O check` indefinitely; every other state
/// (missing file, wrong file type, orphaned socket with no listener) fails
/// fast on its own, which the fast-path tests below confirm.
final class SSHProcessRunnerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        // A SHORT BASE PATH, DELIBERATELY. AF_UNIX socket paths are capped at
        // ~104 bytes on macOS (`sizeof(sockaddr_un.sun_path)`), and
        // `FileManager.default.temporaryDirectory` resolves to something like
        // `/private/var/folders/zh/<hash>/T/`, which already eats most of
        // that budget before a UUID-named subdirectory and a filename are
        // even added — `bind()` fails with `AF_UNIX path too long` before any
        // of the behaviour under test runs. `/tmp` is short enough to leave
        // real room.
        tempDir = URL(fileURLWithPath: "/tmp/dcs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - The failure that actually hung Deck

    /// THE REPRODUCTION. Without `SSHProcessRunner`'s watchdog, this call
    /// hangs forever — verified by hand (see PR body) with `timeout 8 ssh -O
    /// check ...` against the identical fixture, which `timeout` had to kill.
    /// `run` must return on its own, bounded, with `timedOut == true` and no
    /// stdout/stderr to show for it, which is exactly the silence the operator saw.
    func testWedgedSocketTimesOutRatherThanHangingForever() throws {
        let socket = try WedgedControlSocket(directory: tempDir)
        defer { socket.stop() }

        let argv = try sshControlSocketCheckArguments(
            target: SSHTarget(user: "someuser", host: "203.0.113.5"),
            controlPath: socket.path)

        let started = Date()
        let outcome = try SSHProcessRunner.run(argv, timeout: 1.5)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(outcome.timedOut, "a wedged socket must be reported as a timeout")
        // Bounded near the requested timeout, not near whatever ssh's own
        // internal retry/backoff would have taken (minutes, per the manual
        // reproduction) — this is the actual regression guard: a watchdog
        // that silently failed to fire would still return eventually (when
        // the OS itself gave up), just far too late for this assertion.
        XCTAssertLessThan(elapsed, 5, "the watchdog must bound the hang near the requested timeout")
    }

    /// The same fixture, run through the exact shape of argv
    /// `SessionAgent.state` sends (`arguments(target:session:verb:controlPath:)`
    /// with `verb: ["state"]`) — end to end from the caller's perspective,
    /// not just the `-O check` probe.
    func testWedgedSocketBoundsAnOrdinarySessionAgentCallToo() throws {
        let socket = try WedgedControlSocket(directory: tempDir)
        defer { socket.stop() }

        let argv = try SessionAgent.arguments(
            target: SSHTarget(user: "someuser", host: "203.0.113.5"), session: "deck",
            verb: ["state"], controlPath: socket.path)

        let outcome = try SSHProcessRunner.run(argv, timeout: 1.5)
        XCTAssertTrue(outcome.timedOut)
    }

    // MARK: - Every state `ControlMaster=auto` already recovers from on its own

    /// A missing socket file fails immediately with ssh's own "No such file"
    /// — reproduced by hand: 0.014s against a real target. No watchdog is
    /// needed for this shape; it is here so the boundary between "already
    /// fine" and "needed a fix" is pinned by a test, not by memory.
    func testMissingSocketFileFailsFastNotViaTimeout() throws {
        let missing = tempDir.appendingPathComponent("never-created").path
        let argv = try sshControlSocketCheckArguments(
            target: SSHTarget(user: "someuser", host: "203.0.113.5"), controlPath: missing)

        let outcome = try SSHProcessRunner.run(argv, timeout: 10)
        XCTAssertFalse(outcome.timedOut)
        XCTAssertNotEqual(outcome.terminationStatus, 0)
    }

    /// A control path pointing at an ordinary file (not a socket at all)
    /// also fails fast — "Socket operation on non-socket", reproduced by
    /// hand in well under a tenth of a second.
    func testWrongFileTypeAtControlPathFailsFastNotViaTimeout() throws {
        let path = tempDir.appendingPathComponent("not-a-socket").path
        try "not a socket".write(toFile: path, atomically: true, encoding: .utf8)
        let argv = try sshControlSocketCheckArguments(
            target: SSHTarget(user: "someuser", host: "203.0.113.5"), controlPath: path)

        let outcome = try SSHProcessRunner.run(argv, timeout: 10)
        XCTAssertFalse(outcome.timedOut)
        XCTAssertNotEqual(outcome.terminationStatus, 0)
    }

    /// A socket file with nothing listening behind it — bound then
    /// immediately closed, the classic "master process exited without
    /// cleaning up" shape — also fails fast, with "Connection refused".
    func testOrphanedSocketWithNoListenerFailsFastNotViaTimeout() throws {
        let path = tempDir.appendingPathComponent("orphaned").path
        try OrphanedSocket.create(at: path)
        let argv = try sshControlSocketCheckArguments(
            target: SSHTarget(user: "someuser", host: "203.0.113.5"), controlPath: path)

        let outcome = try SSHProcessRunner.run(argv, timeout: 10)
        XCTAssertFalse(outcome.timedOut)
        XCTAssertNotEqual(outcome.terminationStatus, 0)
    }
}

/// `SSHControlSocket.check`/`.clear`, exercised against the same real
/// fixtures — the impure half `SSHControlSocketCheckTests` cannot reach,
/// since that file only pins the classification of an already-observed
/// outcome.
final class SSHControlSocketRecoveryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        // Short on purpose — see the identical comment in
        // `SSHProcessRunnerTests.setUpWithError`.
        tempDir = URL(fileURLWithPath: "/tmp/dcs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private let target = SSHTarget(user: "someuser", host: "203.0.113.5")

    func testCheckConfirmsDeadForAnOrphanedSocket() throws {
        let path = tempDir.appendingPathComponent("orphaned").path
        try OrphanedSocket.create(at: path)
        XCTAssertEqual(SSHControlSocket.check(target: target, controlPath: path), .confirmedDead)
    }

    /// THE END-TO-END REGRESSION GUARD for `SessionAgent.run`'s recovery
    /// path: given a socket `check` confirms dead, `clear` must actually
    /// remove the file ssh would otherwise keep tripping over — not merely
    /// report that it should be removed.
    func testClearActuallyDeletesAConfirmedDeadSocketFile() throws {
        let path = tempDir.appendingPathComponent("orphaned").path
        try OrphanedSocket.create(at: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        SSHControlSocket.clear(target: target, controlPath: path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "clear() must remove the socket file check confirmed dead")
    }

    /// A wedged (accepting-but-silent) master also resolves to `.unresponsive`
    /// through the real `check` path, end to end — not merely through the
    /// pure classifier in `SSHControlSocketCheckTests`.
    func testCheckIsUnresponsiveForAWedgedSocketRatherThanHanging() throws {
        let socket = try WedgedControlSocket(directory: tempDir)
        defer { socket.stop() }

        let started = Date()
        let result = SSHControlSocket.check(target: target, controlPath: socket.path)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result, .unresponsive)
        XCTAssertLessThan(elapsed, SSHControlSocket.checkTimeout + 5)
    }

    /// `clear` must not touch a socket file it never confirmed dead — the
    /// brief's own constraint ("do not clear it speculatively on a healthy
    /// connection"). This exercises `clear` directly rather than through
    /// `check`, since `clear` itself has no opinion on liveness; the
    /// guarantee lives in `SessionAgent.run` only calling it after
    /// `check.warrantsClearing`, which `SessionAgentStaleSocketRecoveryTests`
    /// covers.
    func testResolvingAndClearingDoesNothingWhenNothingIsThere() throws {
        let path = tempDir.appendingPathComponent("never-created").path
        // Must not throw, and must leave nothing behind — the "no file to
        // delete" case is a safe no-op, not an error.
        SSHControlSocket.clear(target: target, controlPath: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}

// MARK: - Fixtures

/// A listening AF_UNIX socket that `accept()`s a connection and then never
/// writes a byte back — the reproduction of a wedged ssh ControlMaster: a
/// process alive enough to look like a live master to a new mux client, but
/// blocked on something that will never resolve. Backed by a real `python3`
/// subprocess so the socket behaves exactly as the manual reproduction did,
/// rather than an approximation built from Swift's own socket APIs.
final class WedgedControlSocket {
    private let process: Process
    let path: String

    init(directory: URL) throws {
        path = directory.appendingPathComponent("wedged-cm").path
        let script = """
        import socket, sys
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(sys.argv[1])
        s.listen(1)
        while True:
            conn, _ = s.accept()
            # Accept and go silent — never write, never close. This is the
            # exact shape that hung `ssh -O check` for the PR this file
            # shipped in.
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, path]
        try process.run()
        self.process = process

        // The listener needs a moment to bind before a test connects to it.
        // Polling for the socket file's existence is a real readiness check,
        // not a fixed sleep guessing at one.
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

/// A socket file with nothing listening behind it — `bind()`, then close
/// immediately with no `listen()`/`accept()` ever called. This is what a
/// ControlMaster process leaves behind if it dies without running its own
/// cleanup, and `ControlMaster=auto` already recovers from it unaided (see
/// `SSHProcessRunnerTests.testOrphanedSocketWithNoListenerFailsFastNotViaTimeout`'s
/// sibling connection-level test) — it is reproduced here only so the
/// FAST-FAIL shape stays pinned as fast, not as another case needing a
/// watchdog.
enum OrphanedSocket {
    static func create(at path: String) throws {
        let script = """
        import socket, sys
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(sys.argv[1])
        s.close()
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, path]
        try process.run()
        process.waitUntilExit()
    }
}
