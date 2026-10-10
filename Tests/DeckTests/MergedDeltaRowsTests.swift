import XCTest
@testable import Deck

/// `SessionPaneModel.mergedRows`' ordering: `applyDeltaBody` stacks rows in
/// array order, so the merged array decides where each row draws.
final class MergedDeltaRowsTests: XCTestCase {
    private func row(_ key: String, newest: Bool = false, html: String? = nil) -> SessionAgent.DeltaRow {
        SessionAgent.DeltaRow(key: key, html: html ?? "<div>\(key)</div>", newest: newest)
    }

    /// Round-3 review's case: the second fetch adds a transcript row beside a
    /// held message still held. The held row must stay after it, at the
    /// newest end, rather than keep its first-fetch slot above it.
    func testAHeldRowStaysAfterATranscriptRowALaterFetchAdded() {
        let merged = SessionPaneModel.mergedRows(
            existing: [row("a.0"), row("~held.0.x", newest: true)],
            incoming: [row("b.0"), row("~held.0.x", newest: true)],
            removed: [])
        XCTAssertEqual(merged.map(\.key), ["a.0", "b.0", "~held.0.x"])
    }

    /// A transcript row the later fetch resends keeps its earlier position and
    /// takes the later content.
    func testARepeatedTranscriptRowKeepsItsPositionAndTakesLaterContent() {
        let merged = SessionPaneModel.mergedRows(
            existing: [row("a.0", html: "old"), row("b.0")],
            incoming: [row("a.0", html: "new"), row("c.0")],
            removed: [])
        XCTAssertEqual(merged.map(\.key), ["a.0", "b.0", "c.0"])
        XCTAssertEqual(merged.first?.html, "new")
    }

    /// Two held messages keep the order the latest fetch gave them, and a
    /// removed key is dropped.
    func testHeldRowsFollowTheLatestFetchAndARemovedKeyIsDropped() {
        let merged = SessionPaneModel.mergedRows(
            existing: [row("~held.0.x", newest: true), row("~held.1.y", newest: true)],
            incoming: [row("b.0"), row("~held.0.y", newest: true)],
            removed: ["~held.0.x", "~held.1.y"])
        XCTAssertEqual(merged.map(\.key), ["b.0", "~held.0.y"])
    }
}
