import XCTest
@testable import Deck

/// `TmuxWindowControl` builds argv for the two tmux mechanics a window leaf
/// needs: `select-window` and `move-window`. Pure argv construction, the
/// same split every other `SessionAgent`/`TmuxWindowControl` argv builder
/// gets — exercised without an ssh round trip.
final class TmuxWindowControlTests: XCTestCase {
    // MARK: - validateWindowNumber

    func testValidateWindowNumberAcceptsTheOrdinaryRange() throws {
        XCTAssertEqual(try TmuxWindowControl.validateWindowNumber(1), 1)
        XCTAssertEqual(try TmuxWindowControl.validateWindowNumber(999), 999)
    }

    func testValidateWindowNumberRejectsZero() {
        XCTAssertThrowsError(try TmuxWindowControl.validateWindowNumber(0))
    }

    func testValidateWindowNumberRejectsNegative() {
        XCTAssertThrowsError(try TmuxWindowControl.validateWindowNumber(-1))
    }

    func testValidateWindowNumberRejectsAboveTheBudget() {
        XCTAssertThrowsError(try TmuxWindowControl.validateWindowNumber(1000))
    }

    // MARK: - selectWindowArguments

    func testSelectWindowArgumentsTargetTheRightSessionAndWindow() throws {
        let args = try TmuxWindowControl.selectWindowArguments(target: TestHost.target, session: "ask--research", window: 2)
        XCTAssertEqual(args.suffix(4), ["tmux", "select-window", "-t", "ask--research:2"])
    }

    func testSelectWindowArgumentsCarryTheControlMaster() throws {
        let args = try TmuxWindowControl.selectWindowArguments(target: TestHost.target, session: "ask", window: 2)
        XCTAssertTrue(args.contains("ControlMaster=auto"))
    }

    func testSelectWindowArgumentsRejectAnInvalidSessionName() {
        XCTAssertThrowsError(try TmuxWindowControl.selectWindowArguments(target: TestHost.target, session: "bad name", window: 2))
    }

    func testSelectWindowArgumentsRejectAnInvalidWindowNumber() {
        XCTAssertThrowsError(try TmuxWindowControl.selectWindowArguments(target: TestHost.target, session: "ask", window: 0))
    }

    /// Phase 6b: a window leaf's crew may live on a host other than the
    /// mini, and "move to its own session"/`ctrl-A <n>`'s follow-select
    /// must reach the SAME box the rail poll and the terminal attach do —
    /// see `deck/specs/multiple-sessions-per-project` §"What must follow
    /// the host". A non-default target reaches the destination token.
    func testSelectWindowArgumentsHonourANonDefaultTarget() throws {
        let laptop = SSHTarget(user: "operator", host: "10.0.0.5")
        let args = try TmuxWindowControl.selectWindowArguments(target: laptop, session: "vivy", window: 2)
        XCTAssertTrue(args.contains("operator@10.0.0.5"))
    }

    /// Defence in depth, the same discipline `sshArguments` and every
    /// `SessionAgent` argv builder already apply to their own `target` —
    /// this function threads a real, config-resolved target for the first
    /// time as of phase 6b, so the gate is newly load-bearing rather than
    /// moot.
    func testSelectWindowArgumentsRejectAnInjectionShapedTargetUser() {
        let evil = SSHTarget(user: "-oProxyCommand=touch /tmp/pwned;", host: "10.0.0.5")
        XCTAssertThrowsError(try TmuxWindowControl.selectWindowArguments(target: evil, session: "ask", window: 2))
    }

    func testSelectWindowArgumentsRejectAnInjectionShapedTargetAddress() {
        let evil = SSHTarget(user: "operator", host: "-oProxyCommand=touch /tmp/pwned;")
        XCTAssertThrowsError(try TmuxWindowControl.selectWindowArguments(target: evil, session: "ask", window: 2))
    }

    // MARK: - moveWindowArguments

    /// The trailing colon on `-t` is tmux's own syntax for "a new session by
    /// this name, seeded from this window" — dropping it would target an
    /// existing window inside a session named `newSessionName` instead of
    /// creating one.
    func testMoveWindowArgumentsUseTheTrailingColonSyntax() throws {
        let args = try TmuxWindowControl.moveWindowArguments(target: TestHost.target, 
            session: "ask", window: 2, newSessionName: "ask--window-2")
        XCTAssertEqual(args.suffix(6),
                       ["tmux", "move-window", "-s", "ask:2", "-t", "ask--window-2:"])
    }

    func testMoveWindowArgumentsRejectAnInvalidNewSessionName() {
        XCTAssertThrowsError(
            try TmuxWindowControl.moveWindowArguments(target: TestHost.target, session: "ask", window: 2, newSessionName: "bad name"))
    }

    func testMoveWindowArgumentsRejectAnInvalidSourceSessionName() {
        XCTAssertThrowsError(
            try TmuxWindowControl.moveWindowArguments(target: TestHost.target, session: "bad name", window: 2, newSessionName: "ask--w2"))
    }

    func testMoveWindowArgumentsRejectAnInvalidWindowNumber() {
        XCTAssertThrowsError(
            try TmuxWindowControl.moveWindowArguments(target: TestHost.target, session: "ask", window: -1, newSessionName: "ask--w2"))
    }

    /// The same host-following requirement as `selectWindowArguments`, for
    /// the promotion path.
    func testMoveWindowArgumentsHonourANonDefaultTarget() throws {
        let laptop = SSHTarget(user: "operator", host: "10.0.0.5")
        let args = try TmuxWindowControl.moveWindowArguments(
            target: laptop, session: "vivy", window: 2, newSessionName: "vivy--w2")
        XCTAssertTrue(args.contains("operator@10.0.0.5"))
    }

    func testMoveWindowArgumentsRejectAnInjectionShapedTargetUser() {
        let evil = SSHTarget(user: "-oProxyCommand=touch /tmp/pwned;", host: "10.0.0.5")
        XCTAssertThrowsError(try TmuxWindowControl.moveWindowArguments(
            target: evil, session: "ask", window: 2, newSessionName: "ask--w2"))
    }

    func testMoveWindowArgumentsRejectAnInjectionShapedTargetAddress() {
        let evil = SSHTarget(user: "operator", host: "-oProxyCommand=touch /tmp/pwned;")
        XCTAssertThrowsError(try TmuxWindowControl.moveWindowArguments(
            target: evil, session: "ask", window: 2, newSessionName: "ask--w2"))
    }
}
