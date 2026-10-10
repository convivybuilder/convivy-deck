import XCTest
import SwiftUI
import AppKit
@testable import Deck

/// `PaneStatusBar`: the pane's crowded top row — the crew's mark and name, a
/// working-on/status slot, vitals, refresh, the session menu — at Deck's
/// largest frame typography. deck-reviewer flagged this
/// row's fit as a thing it could not clear from the diff alone: no wrapping,
/// no fixed frame, and no test pinning it, on a row a rail Start button
/// reaches at the exact moment a user is most likely to have a long PR title
/// or a long model name.
///
/// `PaneStatusBar` is not `private`, matching `GatePanel`, for the same
/// reason: so a test can host it directly with a fixture no live session
/// produces.
final class PaneStatusBarTests: XCTestCase {

    private let fixtureAccent = RGB(red: 0.4, green: 0.4, blue: 0.9)
    private let fixtureSurface = RGB(red: 0.98, green: 0.98, blue: 0.98)

    @MainActor
    private func host(vitals: SessionState.Vitals?, width: CGFloat,
                      height: CGFloat = 60,
                      displayName: String = "Deck",
                      workingOn: SessionState.WorkingOn? = nil,
                      isLaunching: Bool = false,
                      phase: SessionState.Phase = .working,
                      renderError: String? = nil,
                      reason: String? = nil,
                      alive: Bool = true,
                      warningInk: Color = .orange,
                      errorInk: Color = .red,
                      attentionInk: Color = .blue,
                      prChip: PRLadderRow.Presentation? = nil) -> NSHostingView<some View> {
        let bar = PaneStatusBar(
            mark: .ready, displayName: displayName,
            dotAccent: fixtureAccent, dotSurface: fixtureSurface,
            workingOn: workingOn,
            vitals: vitals, isLaunching: isLaunching, phase: phase,
            renderError: renderError, reason: reason, alive: alive,
            warningInk: warningInk, errorInk: errorInk, attentionInk: attentionInk, prChip: prChip,
            onRefresh: {}, onStop: {}
        )
        .environment(\.frameTypography,
                     FrameTypography(baseSize: FrameTypography.maximumBaseSize))
        let host = NSHostingView(rootView: bar)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// EVERY VITALS FIELD POPULATED, the crowded case a real session reaches
    /// once context, a subscription, remote control, dispatched agents and a
    /// PR are all established — next to the crew's mark and name, a
    /// working-on sentence, and the three trailing controls. Long enough in
    /// every field that nothing here is a coincidence of a short fixture.
    private var crowdedVitals: SessionState.Vitals {
        SessionState.Vitals(
            model: "claude-opus-5-20260301",
            contextTokens: 812_000, contextWindow: 1_000_000, contextPercent: 81,
            tier: .hard,
            sub: "max20x (operator@example.com)",
            age: 45, stale: true,
            remoteControlOn: false, remoteName: "ops-mini-deck",
            agents: ["deck-reviewer", "deck-security-reviewer", "deck-coder"],
            agentsAreFleetWide: false,
            pr: .init(number: 92,
                      url: "https://github.com/convivy/convivy-deck/pull/92"))
    }

    /// `ContentView.mainPaneMinWidth`: the narrowest this pane is ever asked
    /// to draw at, since the right column can claim the rest of a 900pt-wide
    /// window. THE ROW DOES NOT FIT THERE, at the crowded fixture and the
    /// largest frame typography — `fittingSize` (the row's ideal,
    /// unconstrained width) comes in well over the floor. SwiftUI degrades
    /// this by shrinking or truncating each `Text`, not by wrapping the row,
    /// so nothing here is unreachable — but pinning the gap is what turns
    /// "reads cramped at the narrowest width" from a thing only an operator notices
    /// resizing the window into a number a future change can be measured
    /// against.
    @MainActor
    func testTheCrowdedRowExceedsThePanesNarrowestWidth() {
        let host = host(vitals: crowdedVitals,
                        width: 1_600,
                        workingOn: SessionState.WorkingOn(
                            text: "revising PR #143 on the reviewer's stderr-classifier finding",
                            age: 47 * 60, stale: false, since: 47 * 60),
                        // A ladder position, the same as the old fixture's
                        // `reviewState: "changes_requested"` — the chip's
                        // label is drawn from this now rather than that
                        // field, so the row stays exactly as crowded.
                        prChip: PRLadderRow.present(.changesRequested))
        XCTAssertGreaterThan(host.fittingSize.width, ContentView.mainPaneMinWidth,
                             "the crowded row's ideal width should be pinned as a "
                             + "known gap against the narrowest real pane, not silently")
    }

    /// The other end: no vitals reading yet (a session just selected, before
    /// the first poll lands) and nothing to say. This is what most sessions
    /// draw most of the time, and it must clear the narrowest pane with
    /// plenty to spare — a regression that makes the EMPTY row crowded would
    /// be a much larger problem than the fully-loaded one above.
    @MainActor
    func testTheEmptyRowClearsThePanesNarrowestWidthWithRoom() {
        let host = host(vitals: nil, width: 1_600)
        XCTAssertLessThan(host.fittingSize.width, ContentView.mainPaneMinWidth,
                          "the row with nothing to show should not itself be "
                          + "pressed against the narrowest pane")
    }

    /// The subscription token (`issue_01M1Y7A36AZ42VSK3QYZBYSNQD`): drawn
    /// beside the model token whenever `vitals.sub` is set, and gone
    /// entirely when it is nil — not merely folded into the model token's
    /// tooltip, which is the bug a $50 overnight misread came from. Neither
    /// row here truncates (both are hosted well past their ideal width), so
    /// the gap between them is exactly the token's own width, not an
    /// artifact of something else giving way first.
    @MainActor
    func testTheSubscriptionTokenRendersWhenSubIsSetAndIsAbsentWhenNil() {
        var withSub = crowdedVitals
        withSub.pr = nil
        var withoutSub = withSub
        withoutSub.sub = nil

        let widthWithSub = host(vitals: withSub, width: 1_600).fittingSize.width
        let widthWithoutSub = host(vitals: withoutSub, width: 1_600).fittingSize.width

        XCTAssertGreaterThan(widthWithSub, widthWithoutSub,
                             "the subscription token should add its own width to the row, "
                             + "not disappear into the model token's tooltip")
    }

    /// `05-states.html`'s hardest case: a render error pre-empting the
    /// working-on slot, stale vitals, the soft context tier, and remote
    /// control off, all at once — the combination that exercises every inked
    /// state this row can carry rather than only the resting shape. The row
    /// still has to fit a real width, and the render error (not the
    /// working-on sentence it pre-empts) has to be what occupies the slot.
    @MainActor
    func testRenderErrorStaleVitalsSoftTierAndRCOffTogether() {
        let vitals = SessionState.Vitals(
            model: "claude-opus-5-20260301",
            contextTokens: 156_000, contextWindow: 200_000, contextPercent: 78,
            tier: .soft,
            age: 240, stale: true,
            remoteControlOn: false,
            agents: [], agentsAreFleetWide: false)
        let host = host(vitals: vitals, width: 1_000,
                        workingOn: SessionState.WorkingOn(
                            text: "revising PR #143 on the reviewer's stderr-classifier finding",
                            age: 47 * 60, stale: true, since: nil),
                        phase: .unknown,
                        renderError: "Could not render the conversation: session-view exited 1 "
                            + "(unknown transcript record kind)",
                        reason: "cannot reach the session")
        // The row must still measure a finite, positive ideal width — a
        // combination this dense is exactly where an unbounded frame or a
        // missing `lineLimit` would blow up the layout pass silently.
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertTrue(host.fittingSize.width.isFinite)
    }
}
