import XCTest
@testable import Deck

/// `FindBarState` holds only the two things shared across a surface switch —
/// whether the bar is open and what is typed into it — plus the focus token
/// `FindBarRow` watches to reclaim focus on a repeat ⌘F. The actual search
/// driving lives on `ConversationScrollState`/`TerminalSearchController`
/// themselves and is covered there; what's testable here without hosting a
/// view is this type's own state machine.
@MainActor
final class FindBarStateTests: XCTestCase {
    func testOpenPresentsTheBar() {
        let state = FindBarState()
        state.open()
        XCTAssertTrue(state.isPresented)
    }

    /// A repeat ⌘F while the bar is already open must still tell
    /// `FindBarRow` to reclaim focus — `isPresented` alone would not change,
    /// since it is already `true`, so nothing would fire the `onChange`
    /// that regrabs it from wherever focus drifted.
    func testOpenTwiceTogglesTheFocusTokenEachTime() {
        let state = FindBarState()
        state.open()
        let firstToken = state.focusToken
        state.open()
        XCTAssertNotEqual(state.focusToken, firstToken)
    }

    func testCloseAndClearDismissesAndEmptiesTheTerm() {
        let state = FindBarState()
        state.open()
        state.term = "widget"
        state.closeAndClear()
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.term, "")
    }

    /// The case that must keep failing to reopen: closing does not leave
    /// the bar presentable again on its own — only a fresh `open()` (⌘F)
    /// does, which is what keeps ⌘G/⇧⌘G's own view-tree scoping honest.
    func testCloseAndClearLeavesTheBarClosedRatherThanReadyToReopen() {
        let state = FindBarState()
        state.open()
        state.closeAndClear()
        XCTAssertFalse(state.isPresented)
    }
}
