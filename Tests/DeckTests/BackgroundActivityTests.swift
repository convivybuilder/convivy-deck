import XCTest
@testable import Deck

/// The "working in the background" signal: the transcript still moving while the
/// main agent's phase reads idle or waiting — a subagent churning while the
/// session looks like it is your turn.
final class BackgroundActivityTests: XCTestCase {

    private func state(_ phase: SessionState.Phase, mtime: Double?) -> SessionState {
        SessionState(session: "x", phase: phase, gate: nil, alive: true,
                     reason: nil, lastEvent: nil, transcriptMTime: mtime)
    }

    func testWaitingWithAMovingTranscriptIsBackgroundActivity() {
        // The main agent nudged and waits; a subagent keeps writing, so the
        // transcript advances between polls.
        XCTAssertTrue(SessionPaneModel.backgroundActive(
            from: state(.waiting, mtime: 1_000), to: state(.waiting, mtime: 1_002)))
        XCTAssertTrue(SessionPaneModel.backgroundActive(
            from: state(.idle, mtime: 1_000), to: state(.idle, mtime: 1_005)))
    }

    func testAStillTranscriptIsNotActivity() {
        // Idle and genuinely quiet: the mtime held across the poll.
        XCTAssertFalse(SessionPaneModel.backgroundActive(
            from: state(.waiting, mtime: 1_000), to: state(.waiting, mtime: 1_000)))
    }

    func testWorkingIsNotBackgroundActivity() {
        // The phase pulse already says busy; this signal is only for the states
        // that look done.
        XCTAssertFalse(SessionPaneModel.backgroundActive(
            from: state(.working, mtime: 1_000), to: state(.working, mtime: 1_002)))
    }

    func testBlockedAndEndedAndUnknownAreNotBackgroundActivity() {
        for phase in [SessionState.Phase.blocked, .ended, .unknown] {
            XCTAssertFalse(SessionPaneModel.backgroundActive(
                from: state(phase, mtime: 1_000), to: state(phase, mtime: 1_002)), "\(phase)")
        }
    }

    func testAMissingMTimeOnEitherSideIsNotActivity() {
        // Nothing to compare — a mini that predates the field, or a poll that
        // could not stat the transcript. Absence is not motion.
        XCTAssertFalse(SessionPaneModel.backgroundActive(
            from: state(.waiting, mtime: nil), to: state(.waiting, mtime: 1_002)))
        XCTAssertFalse(SessionPaneModel.backgroundActive(
            from: state(.waiting, mtime: 1_000), to: state(.waiting, mtime: nil)))
    }

    func testANaNMTimeIsNotActivity() {
        // NaN != NaN would otherwise report motion forever. The isFinite guard,
        // the same one shouldRender carries.
        XCTAssertFalse(SessionPaneModel.backgroundActive(
            from: state(.waiting, mtime: 1_000), to: state(.waiting, mtime: .nan)))
    }
}
