import XCTest
@testable import Deck

/// The corrections queue's sort control — `LibraryClient.QueueSortOrder`,
/// `LibraryClient.orderedQueueItems`, and the choice's persistence through
/// `ThemeConfiguration`/`ThemeStore`. issue_01M2P9ZPBA5114PE875BHHT8NR.
final class QueueSortOrderTests: XCTestCase {
    private func item(
        _ id: String, severity: String? = nil, state: String? = "open", topics: [String] = []
    ) -> LibraryClient.QueueItem {
        LibraryClient.QueueItem(id: id, title: id, severity: severity, state: state, topics: topics)
    }

    // MARK: - The three orders are genuinely distinct

    /// **THE DEFECT AN EARLIER READING OF THIS ISSUE WOULD HAVE BUILT.**
    /// "Filed order" and "area" looked like two options but were the same
    /// one — `sortedQueueItems` groups by topic, it never reads the
    /// Library's raw arrival order. This fixture pins that area and arrival
    /// disagree, and that severity disagrees with both.
    func testAllThreeOrdersProduceDifferentSequencesOnOneFixture() {
        let items = [
            item("b-low", severity: "low", topics: ["b-topic"]),
            item("a-high", severity: "high", topics: ["a-topic"]),
            item("c-pr", severity: "medium", state: "pr-open", topics: ["c-topic"]),
        ]
        let severityOrdered = LibraryClient.orderedQueueItems(items, order: .severity).map(\.id)
        let areaOrdered = LibraryClient.orderedQueueItems(items, order: .area).map(\.id)
        let arrivalOrdered = LibraryClient.orderedQueueItems(items, order: .arrival).map(\.id)

        XCTAssertEqual(severityOrdered, ["a-high", "c-pr", "b-low"])
        XCTAssertEqual(areaOrdered, ["a-high", "b-low", "c-pr"])
        XCTAssertEqual(arrivalOrdered, ["b-low", "a-high", "c-pr"])

        XCTAssertNotEqual(severityOrdered, areaOrdered)
        XCTAssertNotEqual(areaOrdered, arrivalOrdered)
        XCTAssertNotEqual(severityOrdered, arrivalOrdered)
    }

    /// `.area` is exactly `sortedQueueItems` — today's behaviour, kept as
    /// its own named choice rather than silently redefined.
    func testAreaOrderMatchesTodaysTopicGrouping() {
        let items = [
            item("automation-pr", state: "pr-open", topics: ["automation"]),
            item("lock-open", state: "open", topics: ["lock"]),
            item("lock-pr", state: "pr-open", topics: ["lock"]),
        ]
        XCTAssertEqual(
            LibraryClient.orderedQueueItems(items, order: .area).map(\.id),
            ["automation-pr", "lock-pr", "lock-open"])
    }

    // MARK: - isAwaitingPR, ruled per mode (steward, 2026-09-16)

    /// Under severity, a pr-open item leads its own severity band but never
    /// jumps a higher one — severity is the primary key, `isAwaitingPR` only
    /// the tie-break within it.
    func testSeverityOrderLeadsAPROpenItemOnlyWithinItsSeverityBand() {
        let items = [
            item("open-high", severity: "high", state: "open"),
            item("pr-medium", severity: "medium", state: "pr-open"),
            item("open-medium", severity: "medium", state: "open"),
        ]
        XCTAssertEqual(
            LibraryClient.orderedQueueItems(items, order: .severity).map(\.id),
            ["open-high", "pr-medium", "open-medium"])
    }

    /// Under arrival, `isAwaitingPR` is dropped entirely — a pr-open item
    /// does not jump ahead of an item that simply arrived first, however
    /// much higher its severity.
    func testArrivalOrderLeavesTheMergedListUntouched() {
        let items = [
            item("open-high", severity: "high", state: "open"),
            item("pr-low", severity: "low", state: "pr-open"),
        ]
        XCTAssertEqual(
            LibraryClient.orderedQueueItems(items, order: .arrival).map(\.id),
            ["open-high", "pr-low"])
    }

    // MARK: - Unset severity, the common case (92 of the live table's items)

    /// A missing severity sorts last under severity order, same as
    /// `LibraryClientTests.testMissingOrUnknownSeveritySortsLast` pins for
    /// area order — asserted here rather than inherited, since Orient holds
    /// the matching rule independently and the two must agree.
    func testUnsetSeveritySortsLastUnderSeverityOrder() {
        let items = [
            item("i-unset", severity: nil),
            item("i-high", severity: "high"),
            item("i-medium", severity: "medium"),
        ]
        let ordered = LibraryClient.orderedQueueItems(items, order: .severity)
        XCTAssertEqual(ordered.map(\.id), ["i-high", "i-medium", "i-unset"])
    }

    /// A literal, unrecognised severity word (not just an absent field)
    /// sorts last the same way, and still renders rather than being dropped.
    func testAnUnrecognisedSeverityWordSortsLastUnderSeverityOrder() {
        let items = [
            item("i-weird", severity: "urgent-ish"),
            item("i-high", severity: "high"),
        ]
        let ordered = LibraryClient.orderedQueueItems(items, order: .severity)
        XCTAssertEqual(ordered.map(\.id), ["i-high", "i-weird"])
    }

    /// Two items of equal severity keep their arrival order under severity
    /// mode — the same stability guarantee area mode already relies on, and
    /// what keeps a row from jumping position on every refresh.
    func testEqualSeverityItemsKeepArrivalOrderUnderSeverityMode() {
        let items = [
            item("i-newer", severity: "high"),
            item("i-older", severity: "high"),
        ]
        XCTAssertEqual(
            LibraryClient.orderedQueueItems(items, order: .severity).map(\.id),
            ["i-newer", "i-older"])
    }

    // MARK: - The default

    func testTheDefaultIsSeverity() {
        XCTAssertEqual(LibraryClient.QueueSortOrder.default, .severity)
    }

    // MARK: - Persistence: survives a refresh and a relaunch

    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-queuesort-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    func testAnAbsentChoiceLoadsAsSeverity() throws {
        let file = url()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"sessions": {}}"#.write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(ThemeConfiguration.load(from: file).queueSortOrder, .severity)
    }

    /// The same per-field degradation every other setting in this file
    /// gets: a hand-edited or stale value this client does not recognise
    /// must not cost the user their session mapping.
    func testAnUnrecognisedChoiceLoadsAsSeverityRatherThanFailingTheWholeFile() throws {
        let file = url()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"queueSortOrder": "priority", "sessions": {"vivy": "azure"}}"#
            .write(to: file, atomically: true, encoding: .utf8)

        let loaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(loaded.queueSortOrder, .severity)
        XCTAssertEqual(loaded.sessions[SessionRef(host: nil, name: "vivy")], "azure")
    }

    func testTheChoiceSurvivesSaveAndLoad() throws {
        let file = url()
        var configuration = ThemeConfiguration.empty
        configuration.queueSortOrder = .arrival
        try configuration.save(to: file)

        XCTAssertEqual(ThemeConfiguration.load(from: file).queueSortOrder, .arrival)
    }

    @MainActor
    func testTheStoreWritesTheChangeThrough() throws {
        let file = url()
        let store = ThemeStore(fileURL: file)
        XCTAssertEqual(store.configuration.queueSortOrder, .severity)

        store.setQueueSortOrder(.area)

        XCTAssertEqual(store.configuration.queueSortOrder, .area)
        XCTAssertEqual(ThemeConfiguration.load(from: file).queueSortOrder, .area,
                       "the choice applied in memory but was not persisted")
    }
}
