import Foundation
import XCTest
@testable import Deck

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private struct PlacementFailure: Error {}

/// `CockpitModel.reveal` — what a click on an issue id does inside the
/// cockpit. Every case that must fall back to the Item pane is pinned as hard
/// as the case that reveals, since a click that does nothing is the failure
/// this exists to prevent.
@MainActor
final class CockpitRevealTests: XCTestCase {
    private let product = "convivy-deck"

    /// Course order matters for the collapsed-run tests: `coursePartition`
    /// hides all but the last two of a trailing run of unstarted epics.
    private func entries(_ ids: [(String, String)]) -> [LibraryClient.CourseEntry] {
        ids.map { LibraryClient.CourseEntry(id: $0.0, title: $0.0, type: "epic", state: $0.1) }
    }

    private func model(
        entries epicEntries: [LibraryClient.CourseEntry],
        queueItems: [LibraryClient.QueueItem] = [],
        childParents: [String: String] = [:],
        placement: @escaping @Sendable (String) throws -> LibraryClient.CorrectionDetail = { id in
            throw PlacementFailure()
        },
        placementCalls: Counter = Counter()
    ) async -> CockpitModel {
        let model = CockpitModel()
        let course = LibraryClient.Course(id: "course_1", product: product, title: nil, entries: epicEntries)
        let queue = LibraryClient.CorrectionsQueue(
            items: queueItems, total: queueItems.count, truncated: false, childParents: childParents)
        model.fetchCourse = { _, _ in course }
        model.fetchQueue = { _, _ in queue }
        model.fetchChildItems = { _, _ in [] }
        model.fetchItemPlacement = { _, id in
            _ = placementCalls.next()
            return try placement(id)
        }
        await model.refresh(target: TestHost.unreachableTarget, product: product)
        return model
    }

    private func waitForChildren(_ model: CockpitModel, _ epicID: String) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let state = model.childrenByEntry[epicID], state != .loading { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Reveals

    /// An unresolved child is in the queue read's `childParents`, so the
    /// common click costs no request.
    func testAChildTheQueueReadListedRevealsWithNoFetch() async {
        let calls = Counter()
        let model = await model(entries: entries([("epic_A", "claimed"), ("epic_B", "claimed")]),
                                childParents: ["issue_kid": "epic_B"], placementCalls: calls)
        let outcome = await model.reveal(itemID: "issue_kid")
        XCTAssertEqual(outcome, .revealed)
        XCTAssertEqual(model.expandedEntries, ["epic_B"], "only the item's own epic opens")
        XCTAssertEqual(model.highlightedItemID, "issue_kid")
        XCTAssertEqual(calls.count, 0)
        await waitForChildren(model, "epic_B")
    }

    /// A child of an epic the reader already opened is answered from the
    /// children cache, which also covers a resolved child the queue omits.
    func testAChildOfAnAlreadyLoadedEpicRevealsWithNoFetch() async {
        let calls = Counter()
        let model = await model(entries: entries([("epic_A", "claimed")]), placementCalls: calls)
        model.fetchChildItems = { _, _ in [LibraryClient.ChildItem(id: "issue_done", title: "t", state: "resolved")] }
        model.toggleExpansion(for: "epic_A")
        await waitForChildren(model, "epic_A")
        let outcome = await model.reveal(itemID: "issue_done")
        XCTAssertEqual(outcome, .revealed)
        XCTAssertEqual(model.highlightedItemID, "issue_done")
        XCTAssertEqual(calls.count, 0)
    }

    /// An id no cached read knows costs exactly one request, which is also how
    /// its product is learned.
    func testAnUnknownIdIsResolvedByOneFetchAndReveals() async {
        let calls = Counter()
        let product = product
        let model = await model(
            entries: entries([("epic_A", "claimed")]),
            placement: { id in LibraryClient.CorrectionDetail(id: id, product: product, parentId: "epic_A") },
            placementCalls: calls)
        let outcome = await model.reveal(itemID: "issue_resolved_child")
        XCTAssertEqual(outcome, .revealed)
        XCTAssertEqual(model.expandedEntries, ["epic_A"])
        XCTAssertEqual(model.highlightedItemID, "issue_resolved_child")
        XCTAssertEqual(calls.count, 1)
    }

    func testRevealingAnEpicThatIsAlreadyOpenLeavesItOpen() async {
        let model = await model(entries: entries([("epic_A", "claimed")]), childParents: ["issue_kid": "epic_A"])
        model.toggleExpansion(for: "epic_A")
        _ = await model.reveal(itemID: "issue_kid")
        XCTAssertEqual(model.expandedEntries, ["epic_A"], "a reveal must not toggle an open epic shut")
    }

    // MARK: - Falls back to the Item pane

    func testAnItemFromAnotherProductDoesNotReveal() async {
        let model = await model(
            entries: entries([("epic_A", "claimed")]),
            placement: { id in LibraryClient.CorrectionDetail(id: id, product: "vivy", parentId: "epic_A") })
        let outcome = await model.reveal(itemID: "issue_elsewhere")
        XCTAssertEqual(outcome, .notInCockpit)
        XCTAssertTrue(model.expandedEntries.isEmpty, "another project's parent id must not open this project's epic")
        XCTAssertNil(model.highlightedItemID)
    }

    func testAnItemWithNoParentDoesNotReveal() async {
        let product = product
        let model = await model(
            entries: entries([("epic_A", "claimed")]),
            placement: { id in LibraryClient.CorrectionDetail(id: id, product: product, parentId: nil) })
        let outcome = await model.reveal(itemID: "issue_orphan")
        XCTAssertEqual(outcome, .notInCockpit)
        XCTAssertTrue(model.expandedEntries.isEmpty)
        XCTAssertNil(model.highlightedItemID)
    }

    func testAnItemWhoseEpicIsNotACourseEntryDoesNotReveal() async {
        let product = product
        let model = await model(
            entries: entries([("epic_A", "claimed")]),
            placement: { id in LibraryClient.CorrectionDetail(id: id, product: product, parentId: "epic_not_in_course") })
        let outcome = await model.reveal(itemID: "issue_kid")
        XCTAssertEqual(outcome, .notInCockpit)
        XCTAssertTrue(model.expandedEntries.isEmpty)
        XCTAssertNil(model.highlightedItemID)
    }

    /// A queue item has no parent by construction and a Course entry is the
    /// epic itself; both are answered from the cockpit's own reads, with no
    /// request.
    func testAQueueItemAndACourseEntryFallBackWithNoFetch() async {
        let calls = Counter()
        let model = await model(
            entries: entries([("epic_A", "claimed")]),
            queueItems: [LibraryClient.QueueItem(id: "issue_queued", title: "q")],
            placementCalls: calls)
        let queued = await model.reveal(itemID: "issue_queued")
        let epic = await model.reveal(itemID: "epic_A")
        XCTAssertEqual(queued, .notInCockpit)
        XCTAssertEqual(epic, .notInCockpit)
        XCTAssertEqual(calls.count, 0)
        XCTAssertTrue(model.expandedEntries.isEmpty)
    }

    func testAFailedLookupFallsBackRatherThanThrowing() async {
        let model = await model(entries: entries([("epic_A", "claimed")]))
        let outcome = await model.reveal(itemID: "issue_unreachable")
        XCTAssertEqual(outcome, .notInCockpit)
        XCTAssertNil(model.highlightedItemID)
    }

    func testAnEpicInsideACollapsedRunDoesNotReveal() async {
        // Four unstarted epics at the tail: the view shows the first two of the
        // run and folds the rest.
        let epics = entries([("epic_A", "claimed"), ("epic_B", "open"), ("epic_C", "open"),
                             ("epic_D", "open"), ("epic_E", "open")])
        let partition = CockpitView.coursePartition(epics)
        XCTAssertEqual(partition.hiddenTail.map(\.id), ["epic_D", "epic_E"], "the fixture must actually hide epic_D")
        let model = await model(entries: epics, childParents: ["issue_hidden": "epic_D", "issue_shown": "epic_B"])
        let hidden = await model.reveal(itemID: "issue_hidden")
        XCTAssertEqual(hidden, .notInCockpit)
        XCTAssertFalse(model.expandedEntries.contains("epic_D"))
        let shown = await model.reveal(itemID: "issue_shown")
        XCTAssertEqual(shown, .revealed, "the visible head of the same run still reveals")
    }

    func testRevealWithNoResolvedProjectFallsBack() async {
        let model = CockpitModel()
        let outcome = await model.reveal(itemID: "issue_x")
        XCTAssertEqual(outcome, .notInCockpit)
        XCTAssertNil(model.highlightedItemID)
    }

    // MARK: - Highlight lifetime

    func testCollapsingTheEpicClearsTheHighlightButCollapsingAnotherDoesNot() async {
        let model = await model(entries: entries([("epic_A", "claimed"), ("epic_B", "claimed")]),
                                childParents: ["issue_kid": "epic_A"])
        model.toggleExpansion(for: "epic_B")
        _ = await model.reveal(itemID: "issue_kid")
        model.toggleExpansion(for: "epic_B")
        XCTAssertEqual(model.highlightedItemID, "issue_kid")
        model.toggleExpansion(for: "epic_A")
        XCTAssertNil(model.highlightedItemID)
    }

    func testASecondRevealReplacesTheHighlight() async {
        let model = await model(entries: entries([("epic_A", "claimed")]),
                                childParents: ["issue_1": "epic_A", "issue_2": "epic_A"])
        _ = await model.reveal(itemID: "issue_1")
        _ = await model.reveal(itemID: "issue_2")
        XCTAssertEqual(model.highlightedItemID, "issue_2")
    }

    func testAFailedRevealLeavesAnEarlierHighlightAlone() async {
        let model = await model(entries: entries([("epic_A", "claimed")]), childParents: ["issue_1": "epic_A"])
        _ = await model.reveal(itemID: "issue_1")
        _ = await model.reveal(itemID: "issue_unknown")
        XCTAssertEqual(model.highlightedItemID, "issue_1")
    }

    func testFollowingADifferentProjectClearsTheHighlight() async {
        let model = await model(entries: entries([("epic_A", "claimed")]), childParents: ["issue_1": "epic_A"])
        _ = await model.reveal(itemID: "issue_1")
        await model.refresh(target: TestHost.unreachableTarget, product: "vivy")
        XCTAssertNil(model.highlightedItemID)
        await model.refresh(target: nil, product: nil)
        XCTAssertNil(model.highlightedItemID)
    }
}
