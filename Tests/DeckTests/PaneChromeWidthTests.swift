import XCTest
@testable import Deck

/// `ContentView.mainPaneChromeWidth`: the Main pane picker's box width in
/// `paneChrome`'s two-box split, tested the way `ColumnWidthTests` tests
/// `clampedColumnWidth` — directly, with no view hosted. This is the
/// arithmetic; `paneChrome`'s actual on-screen alignment at three widths is
/// verified by hand and reported in the PR body, since a rendered-pixel
/// measurement of a `Picker(.segmented)` inside `ContentView` would need the
/// same fragile bitmap-scan `SettingsLayoutTests` warns about, for a control
/// this test already pins the position of.
///
/// `chromeRowWidth` USED TO BE A `PreferenceKey`-TO-`@State` ROUND TRIP, and
/// on #212 a hosted reading of it never advanced past its initial `0` across
/// 20 layout passes, in a bare `NSHostingView` with no real `App`/`Scene`.
/// That was read at the time as a harness limitation and the PR shipped on
/// hand arithmetic instead — but `mainPaneChromeWidth(chromeRowWidth: 0, ...)`
/// floors at `0`, which is exactly the far-left picker an operator kept seeing on
/// build 608 (`issue_01M249YXQESGX3D74AJMN1H5XN`). The stuck-at-`0` reading
/// was the bug reproducing, not the harness failing to reproduce it: the
/// preference was set on `paneChrome`'s `Group`, whose content is
/// `_ConditionalContent` from an `if`/`else`, and a `PreferenceKey` behind
/// `_ConditionalContent` does not reliably reach `.onPreferenceChange` when
/// hosted without a real `App`/`Scene`. `paneChrome` now takes `rowWidth` as
/// a plain value from a `GeometryReader` hoisted above it (`ContentView.swift`
/// `body`), so there is no preference and no round trip left to fail.
final class PaneChromeWidthTests: XCTestCase {
    private let chromeRowWidth: Double = 1_000

    /// At the default column width, the box should end exactly at the
    /// divider: `chromeRowWidth - columnWidth`.
    func testAtTheDefaultColumnWidthTheBoxEndsAtTheDivider() {
        let stored = ThemeConfiguration.minimumColumnWidth + 40
        XCTAssertEqual(
            ContentView.mainPaneChromeWidth(chromeRowWidth: chromeRowWidth,
                                            dragging: nil, stored: stored),
            chromeRowWidth - stored)
    }

    /// Dragging the divider must move the box's width with it, not leave it
    /// pinned to the stored value the drag has not committed yet.
    func testADragInFlightMovesTheBoxWithIt() {
        XCTAssertEqual(
            ContentView.mainPaneChromeWidth(chromeRowWidth: chromeRowWidth,
                                            dragging: 500, stored: 320),
            500)
    }

    /// Reuses `effectiveColumnWidth`'s own clamping rather than re-deriving
    /// it, so a proposal past the column's floor still yields a sane, matching
    /// box width instead of a negative or degenerate one.
    func testAColumnWidthPastItsFloorStillYieldsAMatchingBoxWidth() {
        let clampedColumn = ContentView.effectiveColumnWidth(
            dragging: 9_999, stored: 320, totalWidth: chromeRowWidth)
        XCTAssertEqual(
            ContentView.mainPaneChromeWidth(chromeRowWidth: chromeRowWidth,
                                            dragging: 9_999, stored: 320),
            chromeRowWidth - clampedColumn)
    }

    /// A degenerate row narrower than both floors combined must not go
    /// negative — `max(0, ...)` is what a `.frame(width:)` requires.
    func testADegenerateRowWidthClampsToZeroRatherThanGoingNegative() {
        let tiny = ThemeConfiguration.minimumColumnWidth - 50
        XCTAssertEqual(
            ContentView.mainPaneChromeWidth(chromeRowWidth: tiny, dragging: nil, stored: 320),
            0)
    }
}

/// `ContentView.pickerShowsTerminal`: the truth behind both `showsTerminal(for:)`
/// (what `mainPane` actually draws) and `isShowingTerminalForSelection` (the
/// Main pane picker's binding). Pinned directly, pure-function style, rather
/// than through a hosted `ContentView` — there is no view to host: the
/// defect this guards (`issue_01M2715540KEV1P6Z831R6TAWA`) was the picker's
/// binding disagreeing with this truth, not a layout question.
final class PickerShowsTerminalTests: XCTestCase {
    /// The lie the picker used to tell: a `.terminalOnly` session is never
    /// inserted into `showingTerminal` (there is no session pane to summon
    /// away from), yet its terminal draws regardless because
    /// `isTerminalOnlySurface` forces it — so the truth must be `true` here
    /// even with `isInShowingTerminalSet: false`, or the picker reports
    /// "Session" while a terminal is on screen.
    func testATerminalOnlySessionShowsTerminalEvenWhenNotInTheShowingTerminalSet() {
        XCTAssertTrue(ContentView.pickerShowsTerminal(
            hasSessionPane: true, isInShowingTerminalSet: false, isTerminalOnlySurface: true))
    }

    /// The ordinary case the picker gets right today: a session with a real
    /// pane, not summoned to the terminal, shows the conversation.
    func testAnOrdinarySessionWithNoTerminalSummonedShowsTheConversation() {
        XCTAssertFalse(ContentView.pickerShowsTerminal(
            hasSessionPane: true, isInShowingTerminalSet: false, isTerminalOnlySurface: false))
    }

    /// A user-summoned fallback: `showingTerminal` alone is still enough to
    /// force it for a session that does have a pane.
    func testAUserSummonedTerminalShowsTerminalForASessionWithAPane() {
        XCTAssertTrue(ContentView.pickerShowsTerminal(
            hasSessionPane: true, isInShowingTerminalSet: true, isTerminalOnlySurface: false))
    }

    /// No pane at all (the local shell, or a session `validateTmuxSessionName`
    /// rejects) is always the terminal, regardless of the other two facts.
    func testNoSessionPaneAlwaysShowsTerminal() {
        XCTAssertTrue(ContentView.pickerShowsTerminal(
            hasSessionPane: false, isInShowingTerminalSet: false, isTerminalOnlySurface: false))
    }
}

/// `ContentView.showsStaleGate`: the pure predicate behind `mainPane`'s
/// `.stale` branch and `isSearchableSurfaceShowing`'s matching guard —
/// whether a crew's own row or a pinned child, confirmed by a poll to have
/// no tmux session left, draws the refusal or is let through to attach.
/// Revised for `issue_01M1KXVY8MNNNG53NFBT8SY58Z`'s second half: the
/// original gate had no way through at all, which also meant no way to
/// reach the terminal fallback `StartSessionView` otherwise always offers.
final class ShowsStaleGateTests: XCTestCase {
    /// THE GATE. A polled row with no tmux session shows the refusal. The
    /// function takes no `showingTerminal`/picker reading at all, which is
    /// the point: the gate cannot be told apart from either side of the
    /// Session/Terminal picker, because it must preempt both — selecting a
    /// stale row with the picker already on Terminal must not attach any
    /// more than selecting it on Session does.
    func testStaleSurfaceShowsTheGate() {
        XCTAssertTrue(ContentView.showsStaleGate(surface: .stale, terminalRequested: false))
    }

    /// THE WAY THROUGH. An explicit "Open terminal" click on the refusal
    /// lowers the gate, so `mainPane` falls through to the real terminal
    /// attach below it.
    func testExplicitTerminalRequestLowersTheGate() {
        XCTAssertFalse(ContentView.showsStaleGate(surface: .stale, terminalRequested: true))
    }

    /// UNAFFECTED. Every other surface — an ordinary stopped row, a live
    /// conversation, a directory-less row, a discovered session with no
    /// agent — never shows this gate, whether or not a terminal was ever
    /// requested for it; `staleTerminalRequests` only ever holds a ref that
    /// was actually `.stale` at the time of the click
    /// (`ContentView.pruneStaleTerminalRequests`), so a real caller never
    /// exercises `terminalRequested: true` for these, but the predicate
    /// itself must not depend on that discipline to stay correct.
    func testNonStaleSurfacesNeverShowTheGate() {
        for surface: SessionSurface in [.start, .conversationPane, .terminalOnly, .missingDirectory] {
            XCTAssertFalse(ContentView.showsStaleGate(surface: surface, terminalRequested: false))
            XCTAssertFalse(ContentView.showsStaleGate(surface: surface, terminalRequested: true))
        }
    }
}
