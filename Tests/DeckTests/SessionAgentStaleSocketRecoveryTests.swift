import XCTest
@testable import Deck

/// `SessionAgent.run`'s stale-socket recovery, wired end to end: a
/// transport-shaped failure (a timeout, here) triggers `SSHControlSocket`'s
/// check-then-clear-then-retry-once dance rather than the raw
/// `SSHProcessRunner`/`SSHControlSocket` pieces `SSHProcessRunnerTests`
/// exercises directly. This is the actual regression guard for the
/// 2026-08-17 incident: a caller that opted in via `staleSocketRecovery`
/// must get a THROWN ERROR back within a bounded time, never a hang, against
/// the real wedged-socket reproduction.
final class SessionAgentStaleSocketRecoveryTests: XCTestCase {
    private var tempDir: URL!
    private let target = SSHTarget(user: "someuser", host: "203.0.113.5")

    override func setUpWithError() throws {
        // Short on purpose: AF_UNIX socket paths are capped at ~104 bytes on
        // macOS, and `FileManager.default.temporaryDirectory` alone eats
        // most of that budget — see `SSHProcessRunnerTests.setUpWithError`.
        tempDir = URL(fileURLWithPath: "/tmp/dcs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// THE END-TO-END REPRODUCTION. A wedged control socket used to mean
    /// `SessionAgent.state`/`states`/`discoveredSessions` never returned at
    /// all — no thrown error, no timeout, nothing for `SessionPaneModel` or
    /// `RailStateModel` to show. With the watchdog and recovery wired in,
    /// the same fixture must produce a THROWN error within a bounded time:
    /// the initial attempt's timeout, plus the bounded `-O check` (also
    /// wedged, so it burns its own `SSHControlSocket.checkTimeout`), plus one
    /// bounded retry — every step bounded, so the whole call is bounded.
    func testWedgedSocketProducesABoundedThrownErrorNotAHang() throws {
        let socket = try WedgedControlSocket(directory: tempDir)
        defer { socket.stop() }

        let argv = try SessionAgent.arguments(
            target: target, session: "deck", verb: ["state"], controlPath: socket.path)

        let started = Date()
        XCTAssertThrowsError(
            try SessionAgent.run(
                argv, timeout: 1.5,
                staleSocketRecovery: (target: target, controlPath: socket.path))
        ) { error in
            guard case SessionAgent.AgentError.failed = error else {
                return XCTFail("expected a transport failure, got \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        // Two 1.5s attempts plus one bounded (5s) socket check — generous
        // slack on top for process spawn/teardown overhead, but nowhere near
        // the multi-minute hang this reproduces the fix for.
        XCTAssertLessThan(elapsed, 20,
                          "recovery must stay bounded even when every step it tries is also wedged")
    }

    /// The recovery attempt must actually have DELETED the wedged socket
    /// file by the time it gives up — not merely diagnosed it. A future
    /// poll's `ControlMaster=auto` finds nothing at this path and opens a
    /// fresh master, rather than tripping over the same wedged file again.
    func testWedgedSocketFileIsRemovedAfterRecoveryGivesUp() throws {
        let socket = try WedgedControlSocket(directory: tempDir)
        defer { socket.stop() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))

        let argv = try SessionAgent.arguments(
            target: target, session: "deck", verb: ["state"], controlPath: socket.path)
        _ = try? SessionAgent.run(
            argv, timeout: 1.5, staleSocketRecovery: (target: target, controlPath: socket.path))

        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path),
                       "the wedged socket file should have been cleared during recovery")
    }

    /// A caller that does NOT opt into recovery (every verb but `state`,
    /// `states`, `discoveredSessions`) still gets the timeout — it just
    /// skips the extra `-O check` round trip. This is what keeps a one-off
    /// action (send a key, stop a session) from paying for a socket check it
    /// has no plan to retry against.
    func testACallerWithNoRecoveryStillTimesOutBoundedRatherThanHanging() throws {
        let socket = try WedgedControlSocket(directory: tempDir)
        defer { socket.stop() }

        let argv = try SessionAgent.arguments(
            target: target, session: "deck", verb: ["state"], controlPath: socket.path)

        let started = Date()
        XCTAssertThrowsError(try SessionAgent.run(argv, timeout: 1.5))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5, "with no recovery opted in, only the one bounded attempt should run")
    }
}
