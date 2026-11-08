import XCTest
@testable import Deck

/// `StartPicker` — the reachable logic behind option C's `START` picker
/// (`design/start-section/index.html`, `issue_01M1SV8QKJ7ADH87PCNC0Q0YE8`).
/// `StartPickerView` itself is not reachable without a view-level test
/// target, so this pins the filter's matching, the ↑↓ arithmetic, the
/// choose-vs-launch routing, and the foot label — the four pieces that can
/// be wrong without a screenshot showing it.
final class StartPickerTests: XCTestCase {
    private func entry(_ id: String, _ name: String? = nil) -> LaunchableSession {
        LaunchableSession(id: id, displayName: name ?? id)
    }

    // MARK: - choose: the select-vs-launch routing fix

    /// `issue_01M5MME44FPVHRQB4KDBXZA5YR`: a catalog entry already running
    /// selects its own ref, the same one `RailView.otherSessions` now
    /// excludes it from the other side of, rather than launching a second
    /// session.
    func testChooseOfARunningEntrySelectsItsRef() {
        let quarry = entry("quarry", "Quarry")
        XCTAssertEqual(StartPicker.choose(quarry, isRunning: true), .select(quarry.ref))
    }

    /// The earlier defect this must not bring back
    /// (`issue_01M1SV8QKJ7ADH87PCNC0Q0YE8`): launching a catalog entry
    /// still selects the ref it is about to start, so the pane that
    /// attaches once it comes up is the same row the operator chose.
    func testChooseOfAStoppedEntryLaunchesIt() {
        let quarry = entry("quarry", "Quarry")
        XCTAssertEqual(StartPicker.choose(quarry, isRunning: false), .launch(quarry))
    }

    // MARK: - filter: the filter field's matching

    func testFilterWithAnEmptyQueryReturnsEveryEntry() {
        let entries = [entry("quarry", "Quarry"), entry("keel", "Keel")]
        XCTAssertEqual(StartPicker.filter(entries, query: "").map(\.id), ["quarry", "keel"])
    }

    func testFilterWithAWhitespaceOnlyQueryReturnsEveryEntry() {
        let entries = [entry("quarry", "Quarry"), entry("keel", "Keel")]
        XCTAssertEqual(StartPicker.filter(entries, query: "   ").map(\.id), ["quarry", "keel"])
    }

    func testFilterMatchesASubstringCaseInsensitively() {
        let entries = [entry("quarry", "Quarry"), entry("keel", "Keel")]
        XCTAssertEqual(StartPicker.filter(entries, query: "UAR").map(\.id), ["quarry"])
    }

    func testFilterWithNoMatchReturnsEmpty() {
        let entries = [entry("quarry", "Quarry")]
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
        XCTAssertEqual(StartPicker.footLabel(matchCount: 16, totalCount: 16), "16 sessions")
    }

    /// The singular form, for the one-entry catalog — distinct from the
    /// plural so the wording reads naturally at either count.
    func testFootLabelAtRestWithOneEntryUsesTheSingular() {
        XCTAssertEqual(StartPicker.footLabel(matchCount: 1, totalCount: 1), "1 session")
    }

    func testFootLabelWhileFilteredNamesBothCounts() {
        XCTAssertEqual(StartPicker.footLabel(matchCount: 6, totalCount: 16), "6 of 16")
    }
}
