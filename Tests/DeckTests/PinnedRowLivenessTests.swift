import XCTest
@testable import Deck

/// `PinnedRowLiveness.choose` — `RailView.childRow`'s decision for whether a
/// pinned session's row should read as stale or needs its own Stop control,
/// pulled out pure so both regressions it fixes are pinned without a view.
final class PinnedRowLivenessTests: XCTestCase {
    /// THE FIRST REGRESSION THIS LOCKS (issue_01M1KXVY8MNNNG53NFBT8SY58Z): a
    /// pinned row whose tmux session is gone must read `.stale` — attaching
    /// to it runs `tmux new-session -A -D`, which creates a fresh session
    /// under the old name rather than resuming anything.
    func testAPolledSessionWithNoTmuxSessionIsStale() {
        XCTAssertEqual(
            PinnedRowLiveness.choose(hasPolled: true, isStopped: true, hasTmuxSession: false),
            .stale)
    }

    /// THE SECOND REGRESSION THIS LOCKS (issue_01M1MVNJWW15VV7Z3MV4SQWEX0): a
    /// pinned session whose tmux session is alive but has no agent — the
    /// shape an adopted, agent-less "OTHER SESSIONS" row lands in — needs
    /// its own Stop, since its pane shows a Start affordance and offers
    /// none.
    func testAPolledSessionWithATmuxSessionButNoAgentNeedsARowStop() {
        XCTAssertEqual(
            PinnedRowLiveness.choose(hasPolled: true, isStopped: true, hasTmuxSession: true),
            .needsRowStop)
    }

    /// The ordinary case: an agent is running, so the pane already carries
    /// its own Stop and the row needs nothing extra.
    func testAPolledSessionWithAnAgentIsOrdinary() {
        XCTAssertEqual(
            PinnedRowLiveness.choose(hasPolled: true, isStopped: false, hasTmuxSession: true),
            .ordinary)
    }

    /// BEFORE THE FIRST POLL, `RailStateModel.discovered` is still empty, so
    /// `hasTmuxSession` reads false for every pinned row regardless of
    /// whether a session actually exists. Without `hasPolled` gating this,
    /// every pin would flash `.stale` for the length of the first poll on
    /// every launch — this is the case that catches a rule that dropped the
    /// gate.
    func testAnUnpolledSessionIsOrdinaryEvenWithNoTmuxSessionReported() {
        XCTAssertEqual(
            PinnedRowLiveness.choose(hasPolled: false, isStopped: true, hasTmuxSession: false),
            .ordinary)
    }
}
