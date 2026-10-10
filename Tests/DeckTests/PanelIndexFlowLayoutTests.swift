import XCTest
@testable import Deck

/// `PanelIndexFlowLayout.rows` — whole entries wrap to a new line instead of
/// being squeezed until their labels break mid-word.
final class PanelIndexFlowLayoutTests: XCTestCase {

    private func size(_ width: CGFloat) -> CGSize { CGSize(width: width, height: 16) }

    func testEntriesThatFitShareOneRow() {
        let rows = PanelIndexFlowLayout.rows(sizes: [size(60), size(60), size(60)], maxWidth: 200, spacing: 10)
        XCTAssertEqual(rows.map(\.indices), [[0, 1, 2]])
        XCTAssertEqual(rows.first?.width, 200)
    }

    func testTheEntryThatWouldOverflowStartsTheNextRow() {
        let rows = PanelIndexFlowLayout.rows(sizes: [size(80), size(80), size(80)], maxWidth: 200, spacing: 10)
        XCTAssertEqual(rows.map(\.indices), [[0, 1], [2]])
    }

    func testAnEntryWiderThanTheRowGetsARowToItself() {
        let rows = PanelIndexFlowLayout.rows(sizes: [size(300), size(40)], maxWidth: 200, spacing: 10)
        XCTAssertEqual(rows.map(\.indices), [[0], [1]])
    }

    func testNoEntriesIsNoRows() {
        XCTAssertEqual(PanelIndexFlowLayout.rows(sizes: [], maxWidth: 200, spacing: 10), [])
    }
}
