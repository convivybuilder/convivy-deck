import XCTest
@testable import Deck

/// `SessionSurface.choose` — the pane-choice rule from
/// `deck/specs/multiple-sessions-per-project` §"Windows created by hand",
/// extended here from a hand-made window to a whole discovered session
/// (Deck fix, 2026-08-14): a discovered session with no agent must draw the
/// raw terminal rather than `StartSessionView`, because Deck has no
/// directory or command to launch one with.
///
/// Two of the four cases below are pinned as UNAFFECTED on purpose — the
/// fix narrows one specific combination, and a predicate that moved either
/// of these would be a regression rather than the fix.
final class SessionSurfaceTests: XCTestCase {
    /// UNAFFECTED. A crew or pinned child Deck configured itself still
    /// offers to start it — this is the whole point of `StartSessionView`.
    func testConfiguredRowStoppedOffersStart() {
        XCTAssertEqual(
            SessionSurface.choose(isDiscovered: false, isStopped: true, hasReading: true),
            .start)
    }

    /// UNAFFECTED. A discovered session with an agent keeps its
    /// conversation pane — finding one of these is what discovery is for.
    func testDiscoveredSessionWithAnAgentGetsTheConversationPane() {
        XCTAssertEqual(
            SessionSurface.choose(isDiscovered: true, isStopped: false, hasReading: true),
            .conversationPane)
    }

    /// UNAFFECTED. A discovered session with no reading yet is not "no
    /// agent" — `RailStateModel.isStopped` already reads false here — so
    /// this must resolve exactly as it did before the fix, not fall
    /// forward into `.terminalOnly` on the strength of `isDiscovered` alone.
    func testDiscoveredSessionWithNoReadingYetGetsTheConversationPane() {
        XCTAssertEqual(
            SessionSurface.choose(isDiscovered: true, isStopped: false, hasReading: false),
            .conversationPane)
    }

    /// THE FIX. A discovered session the mini has confirmed has no agent
    /// draws the raw terminal, not `StartSessionView` — offering to start a
    /// plain shell someone is already typing in was the bug.
    func testDiscoveredSessionConfirmedStoppedIsTerminalOnly() {
        XCTAssertEqual(
            SessionSurface.choose(isDiscovered: true, isStopped: true, hasReading: true),
            .terminalOnly)
    }

    /// A configured row that is alive keeps its conversation pane, the same
    /// as any other selection with an agent — included for the same reason
    /// `LaunchPlaceholderTests` runs every combination of its own booleans:
    /// a rule that only held for the documented cases would be true by
    /// accident.
    func testConfiguredRowAliveGetsTheConversationPane() {
        XCTAssertEqual(
            SessionSurface.choose(isDiscovered: false, isStopped: false, hasReading: true),
            .conversationPane)
    }

    /// THE FIX (`issue_01M1KXWJDHMDATQM5K57FQ2PE7`). A stopped crew or
    /// pinned child with no `workingDirectory` must not offer Start:
    /// starting it would create the tmux session at `$HOME`, outside every
    /// crew's directory, which `SessionGrouping`'s path rule can never claim
    /// back — an unowned session created in the one place guaranteeing it
    /// stays unowned.
    func testConfiguredRowStoppedWithNoDirectoryRefusesStart() {
        XCTAssertEqual(
            SessionSurface.choose(
                isDiscovered: false, isStopped: true, hasReading: true, hasDirectory: false),
            .missingDirectory)
    }

    /// `hasDirectory` must not matter for a discovered session — that branch
    /// never has a directory of its own to check, and a regression that
    /// started reading it there would resolve a real "OTHER SESSIONS" row to
    /// `.missingDirectory`, a case `StartSessionView` never draws for a
    /// discovered row (see `testDiscoveredSessionConfirmedStoppedIsTerminalOnly`).
    func testDiscoveredSessionIgnoresHasDirectory() {
        XCTAssertEqual(
            SessionSurface.choose(
                isDiscovered: true, isStopped: true, hasReading: true, hasDirectory: false),
            .terminalOnly)
    }

    /// UNAFFECTED, restated with `hasDirectory` explicit rather than relying
    /// on its default — a configured row WITH a directory still offers
    /// Start, which is the case `hasDirectory` exists to distinguish from.
    func testConfiguredRowStoppedWithDirectoryOffersStart() {
        XCTAssertEqual(
            SessionSurface.choose(
                isDiscovered: false, isStopped: true, hasReading: true, hasDirectory: true),
            .start)
    }

    /// THE FIX (`issue_01M1N7EXJ80BS3B0B8QB9MJRPJ`, gap 2). A directory that
    /// is present but that `validateWorkingDirectory` rejects is no more
    /// usable than a missing one: the start throws on it. Each case below is
    /// one the Folder field in Settings can save.
    func testOnlyAValidatedDirectoryIsUsable() {
        XCTAssertTrue(SessionSurface.isUsableDirectory("\(TestHost.secondaryHomeRoot)/Convivy/deck"))
        XCTAssertTrue(SessionSurface.isUsableDirectory("~/Convivy/deck"))
        XCTAssertFalse(SessionSurface.isUsableDirectory(nil))
        XCTAssertFalse(SessionSurface.isUsableDirectory("Convivy/deck"), "relative")
        XCTAssertFalse(SessionSurface.isUsableDirectory("\(TestHost.secondaryHomeRoot)/my deck"), "space")
        XCTAssertFalse(SessionSurface.isUsableDirectory("\(TestHost.secondaryHomeRoot)/../deck"), "..")
        XCTAssertFalse(SessionSurface.isUsableDirectory("\(TestHost.secondaryHomeRoot)/deck;ls"), "shell character")
    }

    /// The row an invalid folder used to leave offering a Start that could
    /// only fail now draws the refusal, the same as a missing folder.
    func testConfiguredRowStoppedWithAnInvalidDirectoryRefusesStart() {
        XCTAssertEqual(
            SessionSurface.choose(
                isDiscovered: false, isStopped: true, hasReading: true,
                hasDirectory: SessionSurface.isUsableDirectory("Convivy/deck")),
            .missingDirectory)
    }

    /// THE FIX (`issue_01M1KXVY8MNNNG53NFBT8SY58Z`). BEFORE THE FIRST POLL,
    /// `hasTmuxSession` reads false for every configured row regardless of
    /// whether a session actually exists — the same reason
    /// `PinnedRowLiveness.choose` gates on `hasPolled` before trusting it.
    /// Without that gate carried through here, every crew and pinned row
    /// would flash `.stale` for the length of the first poll, on every
    /// launch, exactly as `PinnedRowLivenessTests
    /// .testAnUnpolledSessionIsOrdinaryEvenWithNoTmuxSessionReported` pins
    /// one layer down.
    func testUnpolledConfiguredRowStaysAsToday() {
        XCTAssertEqual(
            SessionSurface.choose(
                isDiscovered: false, isStopped: true, hasReading: true,
                hasPolled: false, hasTmuxSession: false),
            .start)
    }

    /// THE FIX. A crew's own row or a pinned child, polled and confirmed to
    /// have no tmux session behind it — the stale-pin bug
    /// (`issue_01M1KXVY8MNNNG53NFBT8SY58Z`): attaching or opening the
    /// terminal both run `tmux new-session -A -D`, silently recreating the
    /// session under its old name. `isStopped: false` here on purpose — the
    /// bug's own reading was a cached "not stopped" state left standing
    /// after the tmux session was killed out from under it, which is
    /// exactly the case `.stale` must catch regardless of what `isStopped`
    /// says.
    func testPolledConfiguredRowWithNoTmuxSessionIsStale() {
        XCTAssertEqual(
            SessionSurface.choose(
                isDiscovered: false, isStopped: false, hasReading: false,
                hasPolled: true, hasTmuxSession: false),
            .stale)
    }

    /// UNAFFECTED. A crew's own row or pinned child, polled and confirmed to
    /// still have its tmux session, resolves exactly as it did before
    /// `hasPolled`/`hasTmuxSession` existed — the new parameters only ever
    /// move a result away from this one.
    func testPolledConfiguredRowWithTmuxSessionIsUnchanged() {
        XCTAssertEqual(
            SessionSurface.choose(
                isDiscovered: false, isStopped: true, hasReading: true,
                hasPolled: true, hasTmuxSession: true),
            .start)
        XCTAssertEqual(
            SessionSurface.choose(
                isDiscovered: false, isStopped: false, hasReading: true,
                hasPolled: true, hasTmuxSession: true),
            .conversationPane)
    }

    /// UNAFFECTED. `hasPolled`/`hasTmuxSession` must not matter for a
    /// discovered row — that branch never reads them, the same way it
    /// already ignores `hasDirectory`
    /// (`testDiscoveredSessionIgnoresHasDirectory`). A regression that
    /// started reading them there would resolve a real "OTHER SESSIONS" row
    /// to `.stale`, a case `RailChildRow`'s discovered-row treatment never
    /// draws for.
    func testDiscoveredRowIgnoresHasPolledAndHasTmuxSession() {
        XCTAssertEqual(
            SessionSurface.choose(
                isDiscovered: true, isStopped: true, hasReading: true,
                hasPolled: true, hasTmuxSession: false),
            .terminalOnly)
    }
}

/// `SessionSurface.showsConversationPane` — the predicate
/// `ContentView.mainPane`'s `SessionPaneView` branch and the toolbar's
/// overflow-menu gate (`sessionPaneIsShowing`) both read, added after a
/// hand-copied second copy of this condition omitted the `isLaunching`
/// override and made the `⋯` menu vanish for the whole launch-in-flight
/// window (PR #182 review, finding 1).
final class SessionSurfaceShowsConversationPaneTests: XCTestCase {
    /// THE BUG THIS PREDICATE FIXES. `surface` still reads `.start` during
    /// the launch-in-flight window (the rail has not polled yet), but
    /// `mainPane` already falls through to `SessionPaneView` with
    /// `isLaunching: true` — the predicate must agree the pane is showing.
    func testStartSurfaceWhileLaunchingShowsThePane() {
        XCTAssertTrue(
            SessionSurface.start.showsConversationPane(
                hasSessionPane: true, isShowingTerminal: false, hasHostTarget: true,
                isLaunching: true))
    }

    /// The case that must still fail: `.start` with no launch in flight is
    /// `StartSessionView`, not the conversation pane.
    func testStartSurfaceNotLaunchingDoesNotShowThePane() {
        XCTAssertFalse(
            SessionSurface.start.showsConversationPane(
                hasSessionPane: true, isShowingTerminal: false, hasHostTarget: true,
                isLaunching: false))
    }

    func testConversationPaneSurfaceShowsThePane() {
        XCTAssertTrue(
            SessionSurface.conversationPane.showsConversationPane(
                hasSessionPane: true, isShowingTerminal: false, hasHostTarget: true,
                isLaunching: false))
    }

    func testTerminalOnlySurfaceNeverShowsThePane() {
        XCTAssertFalse(
            SessionSurface.terminalOnly.showsConversationPane(
                hasSessionPane: true, isShowingTerminal: false, hasHostTarget: true,
                isLaunching: false))
    }

    func testMissingDirectorySurfaceNeverShowsThePane() {
        XCTAssertFalse(
            SessionSurface.missingDirectory.showsConversationPane(
                hasSessionPane: true, isShowingTerminal: false, hasHostTarget: true,
                isLaunching: false))
    }

    func testStaleSurfaceNeverShowsThePane() {
        XCTAssertFalse(
            SessionSurface.stale.showsConversationPane(
                hasSessionPane: true, isShowingTerminal: false, hasHostTarget: true,
                isLaunching: false))
    }

    func testNoHostTargetNeverShowsThePane() {
        XCTAssertFalse(
            SessionSurface.conversationPane.showsConversationPane(
                hasSessionPane: true, isShowingTerminal: false, hasHostTarget: false,
                isLaunching: false))
    }

    func testShowingTerminalHidesThePane() {
        XCTAssertFalse(
            SessionSurface.conversationPane.showsConversationPane(
                hasSessionPane: true, isShowingTerminal: true, hasHostTarget: true,
                isLaunching: false))
    }
}
