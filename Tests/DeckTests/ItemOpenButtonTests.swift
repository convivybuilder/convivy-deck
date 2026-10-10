import XCTest
import SwiftUI
@testable import Deck

/// `ItemOpenButton` — the `Open` control on epic, child work-item and queue
/// rows. Its one layout promise is that revealing it never changes the space
/// it takes (the operator, 2026-09-04: a hover-conditional icon moved the wrap point
/// of a two-line title), so the tests measure that directly rather than
/// reading the modifier chain.
final class ItemOpenButtonTests: XCTestCase {

    @MainActor
    private func fittingSize<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// The case that must still work: hidden and revealed occupy the same
    /// space, so a row's title wraps identically before and after the
    /// pointer arrives.
    @MainActor
    func testRevealingTheControlDoesNotChangeTheSpaceItTakes() {
        let hidden = fittingSize(ItemOpenButton(isRevealed: false) {})
        let revealed = fittingSize(ItemOpenButton(isRevealed: true) {})
        XCTAssertGreaterThan(hidden.width, 0, "a hidden control must still reserve width")
        XCTAssertEqual(hidden, revealed)
    }

    /// The positive control for the test above: the conditional shape the
    /// repo already paid for DOES change size, so equal sizes above mean the
    /// control is reserved rather than that `fittingSize` cannot tell.
    @MainActor
    func testAConditionallyIncludedControlWouldChangeTheSpaceItTakes() {
        let hidden = fittingSize(HStack { if false { ItemOpenButton(isRevealed: true) {} } })
        let revealed = fittingSize(HStack { if true { ItemOpenButton(isRevealed: true) {} } })
        XCTAssertNotEqual(hidden.width, revealed.width)
    }

    /// The pressed action is what the row hands in, once per press. The
    /// control claims and writes nothing of its own.
    @MainActor
    func testTheActionIsTheRowsOwnClosure() {
        var opened: [String] = []
        let button = ItemOpenButton(isRevealed: true) { opened.append("issue_A") }
        button.action()
        XCTAssertEqual(opened, ["issue_A"])
    }

    /// The menu entry and the tooltip name the destination, so a reader
    /// without a pointer finds the same route.
    @MainActor
    func testTheMenuEntryAndTooltipNameTheItemPane() {
        XCTAssertTrue(ItemOpenButton.menuTitle.contains("Item pane"))
        XCTAssertTrue(ItemOpenButton.helpText.contains("Item pane"))
    }
}
