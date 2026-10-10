import XCTest
@testable import Deck

/// A rollover opens its successor as a new window in the same tmux session.
/// The rail labels that window's leaf, so the rotation reads as one event
/// rather than as an unexplained second window.
final class SuccessorWindowLeafTests: XCTestCase {

    func testTheSuccessorsLeafIsLabelled() {
        XCTAssertEqual(WindowLeafRow.title(window: 2, successorWindow: 2), "rolling over here")
    }

    func testEveryOtherLeafKeepsItsWindowNumber() {
        XCTAssertEqual(WindowLeafRow.title(window: 3, successorWindow: 2), "window 3")
        XCTAssertEqual(WindowLeafRow.title(window: 2, successorWindow: nil), "window 2")
    }

    func testOnlyARollingSessionNamesASuccessorWindow() {
        XCTAssertEqual(
            WindowLeafRow.successorWindow(of: SessionState.Rollover(state: .rolling, successorWindow: 2)), 2)
        XCTAssertNil(WindowLeafRow.successorWindow(of: nil))
    }

    /// A `successor_window` left behind on any other state, say after the
    /// rotation finished or failed, never labels a leaf.
    func testAStaleSuccessorWindowOnAnotherStateLabelsNothing() {
        for state: SessionState.Rollover.State in [.ok, .seeking, .rollNow, .vetoed, .parked, .unrecognized("x")] {
            XCTAssertNil(WindowLeafRow.successorWindow(of: SessionState.Rollover(state: state, successorWindow: 2)))
        }
    }
}
