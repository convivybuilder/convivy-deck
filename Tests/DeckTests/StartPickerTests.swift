import XCTest
@testable import Deck

/// `StartPicker` — the reachable logic behind option C's `START` picker
/// (`design/start-section/index.html`, `issue_01M1SV8QKJ7ADH87PCNC0Q0YE8`).
/// `StartPickerView` itself is not reachable without a view-level test
/// target, so this pins the filter's matching, the ↑↓ arithmetic, the
/// running-entry exclusion, and the foot label — the four pieces that can
/// be wrong without a screenshot showing it.
final class StartPickerTests: XCTestCase {
    private func entry(_ id: String, _ name: String? = nil) -> LaunchableSession {
        LaunchableSession(id: id, displayName: name ?? id)
    }

    // MARK: - availableEntries: the running-entry routing fix

    /// The one correctness fix the issue ties to option C: a catalog entry
    /// that is already running must not be offered to start again — it
    /// belongs under `OTHER SESSIONS` (`RailView.otherSessions`) once
    /// `RailView`'s own catalog-id filter there is gone, not here.
    func testAvailableEntriesExcludesARunningEntry() {
        let hollis = entry("hollis", "Hollis")
        let keel = entry("keel", "Keel")
        let result = StartPicker.availableEntries([hollis, keel]) { $0.id == "hollis" }
        XCTAssertEqual(result.map(\.id), ["keel"])
    }

    func testAvailableEntriesKeepsEveryEntryWhenNoneAreRunning() {
        let entries = [entry("hollis"), entry("keel")]
        let result = StartPicker.availableEntries(entries) { _ in false }
        XCTAssertEqual(result.map(\.id), ["hollis", "keel"])
    }

    func testAvailableEntriesIsEmptyWhenEveryEntryIsRunning() {
        let entries = [entry("hollis"), entry("keel")]
        let result = StartPicker.availableEntries(entries) { _ in true }
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - filter: the filter field's matching

    func testFilterWithAnEmptyQueryReturnsEveryEntry() {
        let entries = [entry("hollis", "Hollis"), entry("keel", "Keel")]
        XCTAssertEqual(StartPicker.filter(entries, query: "").map(\.id), ["hollis", "keel"])
    }

    func testFilterWithAWhitespaceOnlyQueryReturnsEveryEntry() {
        let entries = [entry("hollis", "Hollis"), entry("keel", "Keel")]
        XCTAssertEqual(StartPicker.filter(entries, query: "   ").map(\.id), ["hollis", "keel"])
    }

    func testFilterMatchesASubstringCaseInsensitively() {
        let entries = [entry("hollis", "Hollis"), entry("keel", "Keel")]
        XCTAssertEqual(StartPicker.filter(entries, query: "OLL").map(\.id), ["hollis"])
    }

    func testFilterWithNoMatchReturnsEmpty() {
        let entries = [entry("hollis", "Hollis")]
        XCTAssertTrue(StartPicker.filter(entries, query: "zzz").isEmpty)
    }

    // MARK: - move: the ↑↓ arithmetic

    func testMoveWithNoCurrentSelectionMovingDownStartsAtTheFirstRow() {
        let entries = [entry("a"), entry("b"), entry("c")]
        XCTAssertEqual(StartPicker.move(current: nil, in: entries, delta: 1), "a")
    }

    func testMoveWithNoCurrentSelectionMovingUpStartsAtTheLastRow() {
        let entries = [entry("a"), entry("b"), entry("c")]
        XCTAssertEqual(StartPicker.move(current: nil, in: entries, delta: -1), "c")
    }

    func testMoveAdvancesByOneRow() {
        let entries = [entry("a"), entry("b"), entry("c")]
        XCTAssertEqual(StartPicker.move(current: "a", in: entries, delta: 1), "b")
    }

    /// Clamps at the end rather than wrapping — the same "stop at the edge"
    /// behaviour a `List(selection:)` gives for free.
    func testMoveClampsAtTheLastRow() {
        let entries = [entry("a"), entry("b"), entry("c")]
        XCTAssertEqual(StartPicker.move(current: "c", in: entries, delta: 1), "c")
    }

    func testMoveClampsAtTheFirstRow() {
        let entries = [entry("a"), entry("b"), entry("c")]
        XCTAssertEqual(StartPicker.move(current: "a", in: entries, delta: -1), "a")
    }

    /// A filter can narrow the list out from under the current id — this is
    /// exactly `StartPickerView`'s `onChange(of: query)` case, exercised at
    /// the pure layer.
    func testMoveWithACurrentIdNoLongerInTheListStartsOver() {
        let entries = [entry("a"), entry("b")]
        XCTAssertEqual(StartPicker.move(current: "vanished", in: entries, delta: 1), "a")
    }

    func testMoveOnAnEmptyListReturnsNil() {
        XCTAssertNil(StartPicker.move(current: "a", in: [], delta: 1))
    }

    // MARK: - footLabel

    func testFootLabelAtRestNamesTheTotal() {
        XCTAssertEqual(StartPicker.footLabel(matchCount: 16, totalCount: 16), "16 not running")
    }

    func testFootLabelWhileFilteredNamesBothCounts() {
        XCTAssertEqual(StartPicker.footLabel(matchCount: 6, totalCount: 16), "6 of 16")
    }
}
