import XCTest
import SwiftUI
@testable import Deck

/// `CockpitView`'s pure derivations — the ones a redraw of already-decoded
/// data can get wrong without any network call being involved. Everything
/// else in `CockpitView` is SwiftUI layout with no return value to assert
/// on; `childProgress` is pulled out as a `static func` for exactly this
/// reason, the same discipline `RailRow.summonsInk` follows.
final class CockpitViewTests: XCTestCase {

    private func item(_ id: String, state: String?) -> LibraryClient.ChildItem {
        LibraryClient.ChildItem(id: id, title: "item \(id)", type: "task", state: state, parentId: "issue_EPIC")
    }

    // MARK: - childProgress

    /// The epic's own row shows how many of its already-fetched children
    /// have passed — "1/4" reads directly off `isCompleted`, the same
    /// vocabulary a child's own row draws with.
    func testChildProgressCountsCompletedAgainstTotal() {
        let items: [LibraryClient.ChildItem] = [
            item("A", state: "fixed"),
            item("B", state: "open"),
            item("C", state: "open"),
            item("D", state: "open"),
        ]
        let progress = CockpitView.childProgress(.loaded(items))
        XCTAssertEqual(progress?.done, 1)
        XCTAssertEqual(progress?.total, 4)
    }

    /// Never fetched (the row has not been expanded) draws no count — the
    /// spec's "omit it otherwise" rather than a misleading "0/0".
    func testChildProgressIsNilWhenNeverFetched() {
        XCTAssertNil(CockpitView.childProgress(nil))
    }

    /// Still in flight draws no count either; the loading spinner under the
    /// expanded row already says as much once it is open.
    func testChildProgressIsNilWhileLoading() {
        XCTAssertNil(CockpitView.childProgress(.loading))
    }

    /// A failed fetch draws no count — `unreachableLine` under the expanded
    /// row is where that failure belongs, not a stale or fabricated ratio.
    func testChildProgressIsNilOnFailure() {
        XCTAssertNil(CockpitView.childProgress(.failed("connection reset")))
    }

    /// Fetched, but the epic has no children at all (the fleet-wide steady
    /// state today) — also omitted, since "0/0" reads as a stuck fetch
    /// rather than as "nothing filed here", which is what the epic's own
    /// expanded "no work items filed" line already says.
    func testChildProgressIsNilWhenLoadedButEmpty() {
        XCTAssertNil(CockpitView.childProgress(.loaded([])))
    }

    /// Every child fixed reads as fully passed, not omitted — the count is
    /// still informative once an epic is entirely done.
    func testChildProgressWithAllCompleted() {
        let items = [item("A", state: "fixed"), item("B", state: "wontfix")]
        let progress = CockpitView.childProgress(.loaded(items))
        XCTAssertEqual(progress?.done, 2)
        XCTAssertEqual(progress?.total, 2)
    }

    // MARK: - A fixed child draws differently from an open one

    /// The mechanical cause this redraw fixes: `state` reaching the glyph
    /// at all. `isCompleted` is what `childItemRow` branches its
    /// glyph/strikethrough/colour on, so this pins the fact a `fixed` child
    /// and an `open` child now disagree on it — the bug was that they never
    /// did.
    func testAFixedChildAndAnOpenChildDisagreeOnCompletion() {
        let fixed = item("A", state: "fixed")
        let open = item("B", state: "open")
        XCTAssertTrue(fixed.isCompleted)
        XCTAssertFalse(open.isCompleted)
        XCTAssertNotEqual(fixed.isCompleted, open.isCompleted)
    }

    // MARK: - showsTypeChips

    private func item(_ id: String, type: String?) -> LibraryClient.ChildItem {
        LibraryClient.ChildItem(id: id, title: "item \(id)", type: type, state: "open", parentId: "issue_EPIC")
    }

    /// Every item filed under today's epics is `task` — the column of
    /// identical grey pills the design review flagged. All-uniform draws no
    /// chips.
    func testShowsTypeChipsIsFalseWhenAllItemsShareOneType() {
        let items = [item("A", type: "task"), item("B", type: "task"), item("C", type: "task")]
        XCTAssertFalse(CockpitView.showsTypeChips(items))
    }

    /// A genuinely mixed epic is where the chip earns its place.
    func testShowsTypeChipsIsTrueWhenTypesDiffer() {
        let items = [item("A", type: "task"), item("B", type: "bug")]
        XCTAssertTrue(CockpitView.showsTypeChips(items))
    }

    /// `compactMap` drops a `nil` type before the dedup, so an untyped item
    /// alongside a single named type is still one distinct type — no chip.
    func testShowsTypeChipsIsFalseWhenAnUntypedItemJoinsOneNamedType() {
        let items = [item("A", type: "task"), item("B", type: nil)]
        XCTAssertFalse(CockpitView.showsTypeChips(items))
    }

    /// All `nil` is uniform too — no named types at all is not a mix.
    func testShowsTypeChipsIsFalseWhenAllItemsHaveNoType() {
        let items = [item("A", type: nil), item("B", type: nil)]
        XCTAssertFalse(CockpitView.showsTypeChips(items))
    }

    /// Case is not a type distinction — `"Task"` and `"task"` are one type.
    func testShowsTypeChipsIgnoresCase() {
        let items = [item("A", type: "Task"), item("B", type: "task")]
        XCTAssertFalse(CockpitView.showsTypeChips(items))
    }

    /// A single-item epic is trivially uniform.
    func testShowsTypeChipsIsFalseForASingleItem() {
        XCTAssertFalse(CockpitView.showsTypeChips([item("A", type: "task")]))
    }

    // MARK: - rowTreatment — the C2 state table, as a pure function

    func testOpenReadsAsAhead() {
        XCTAssertEqual(CockpitView.rowTreatment(state: "open", resolution: nil), .ahead)
    }

    func testNoStateAtAllAlsoReadsAsAhead() {
        XCTAssertEqual(CockpitView.rowTreatment(state: nil, resolution: nil), .ahead)
    }

    func testClaimedReadsAsInProgress() {
        XCTAssertEqual(CockpitView.rowTreatment(state: "claimed", resolution: nil), .inProgress)
    }

    /// `pr-open` collapses into `.inProgress` — its own honesty lives in
    /// `.help`, not a distinct glyph (C2).
    func testPROpenCollapsesIntoInProgress() {
        XCTAssertEqual(CockpitView.rowTreatment(state: "pr-open", resolution: nil), .inProgress)
    }

    func testFixedReadsAsDone() {
        XCTAssertEqual(CockpitView.rowTreatment(state: "fixed", resolution: "fixed"), .done)
    }

    /// **The deliberate collapse.** `wontfix`, `duplicate` and `redirected`
    /// share one mark: at a glance the question is "is this still ahead of
    /// me", and all three answer no.
    func testWontfixDuplicateAndRedirectedAllCollapseIntoClosedNotDone() {
        for resolution in ["wontfix", "duplicate", "redirected"] {
            XCTAssertEqual(CockpitView.rowTreatment(state: resolution, resolution: resolution),
                           .closedNotDone, "resolution \(resolution)")
        }
    }

    /// A `ChildItem` carries no `resolution` — `state` alone must decide it,
    /// the terminal-state path exercised the same way `isCompleted` reads it.
    func testATerminalStateWithNoResolutionStillReadsAsTerminal() {
        XCTAssertEqual(CockpitView.rowTreatment(state: "fixed", resolution: nil), .done)
        XCTAssertEqual(CockpitView.rowTreatment(state: "redirected", resolution: nil), .closedNotDone)
    }

    func testStrikethroughAppliesOnlyToTheTwoTerminalTreatments() {
        XCTAssertFalse(CockpitView.RowTreatment.ahead.strikethrough)
        XCTAssertFalse(CockpitView.RowTreatment.inProgress.strikethrough)
        XCTAssertTrue(CockpitView.RowTreatment.done.strikethrough)
        XCTAssertTrue(CockpitView.RowTreatment.closedNotDone.strikethrough)
    }

    // MARK: - accessibilityLabel

    func testAccessibilityLabelPrefixesByState() {
        XCTAssertEqual(CockpitView.accessibilityLabel(
            title: "Ship the thing", treatment: .ahead), "ahead, Ship the thing")
        XCTAssertEqual(CockpitView.accessibilityLabel(
            title: "Ship the thing", treatment: .inProgress),
            "in progress, Ship the thing")
        XCTAssertEqual(CockpitView.accessibilityLabel(
            title: "Ship the thing", treatment: .done), "done, Ship the thing")
        XCTAssertEqual(CockpitView.accessibilityLabel(
            title: "Ship the thing", treatment: .closedNotDone),
            "closed without change, Ship the thing")
    }

    /// **C6.** The progress count reads "settled", not "done" — a settled
    /// count may include a `wontfix`.
    func testAccessibilityLabelRelabelsProgressAsSettled() {
        XCTAssertEqual(CockpitView.accessibilityLabel(
            title: "Cockpit epic", treatment: .inProgress,
            progress: (done: 1, total: 4)),
            "in progress, Cockpit epic, 1 of 4 settled")
    }

    /// **C5's blocked companion.** Appends only when the row's own
    /// `blocked` boolean is `true` — never derived from `prerequisites`
    /// here, since the label reads exactly the flag it's given.
    func testAccessibilityLabelAppendsBlockedWhenTrue() {
        XCTAssertEqual(CockpitView.accessibilityLabel(
            title: "Cockpit epic", treatment: .ahead, blocked: true),
            "ahead, Cockpit epic, blocked")
        XCTAssertEqual(CockpitView.accessibilityLabel(
            title: "Cockpit epic", treatment: .ahead, blocked: false),
            "ahead, Cockpit epic")
    }

    // MARK: - needsFirstText / needsFirstPlainText (ADR-0074, comment 2261)

    /// An empty prerequisites list draws nothing — the caller's `if let`
    /// skips the line entirely rather than drawing an empty caption.
    func testNeedsFirstTextIsNilForAnEmptyList() {
        XCTAssertNil(CockpitView.needsFirstText([]))
    }

    /// A readable item shows its served state beside its title and strikes
    /// through once that state is one of `LibraryClient.terminalWorkStates`
    /// — the same vocabulary `rowTreatment` reads for every other row.
    func testPrerequisiteFragmentStrikesThroughATerminalItem() {
        // `Text("Blocker")` (a string literal) and `Text(title)` (a `String`
        // variable) build different storage cases — `.verbatim` versus
        // `.anyTextStorage(LocalizedTextStorage)` — that compare unequal even
        // over identical text, so the expectation must go through a
        // variable too, matching how `prerequisiteFragment` builds its own.
        let title = "Blocker"
        let fixedLabel = "\(title) (fixed)"
        let openLabel = "\(title) (open)"
        let resolved = CockpitView.prerequisiteFragment(.item(id: "issue_A", title: title, state: "fixed"))
        XCTAssertEqual(resolved, Text(fixedLabel).strikethrough())
        let unresolved = CockpitView.prerequisiteFragment(.item(id: "issue_A", title: title, state: "open"))
        XCTAssertEqual(unresolved, Text(openLabel))
        XCTAssertNotEqual(unresolved, resolved)
    }

    /// A readable item with no served state at all shows only its title —
    /// there is nothing to put in parentheses.
    func testPrerequisiteFragmentShowsTitleAloneWhenStateIsAbsent() {
        let title = "Blocker"
        XCTAssertEqual(CockpitView.prerequisiteFragment(.item(id: "issue_A", title: title, state: nil)),
                       Text(title))
    }

    /// **Comment 2261: "draw it as a blocker that can't be opened."** No
    /// title or state to show, so the fixed label draws instead — and this
    /// entry is never dropped from the list, unlike every other malformed
    /// shape this file degrades away.
    func testPrerequisiteFragmentDrawsTheFixedLabelForAMissingItem() {
        XCTAssertEqual(CockpitView.prerequisiteFragment(.missingItem(id: "issue_HIDDEN")),
                       Text(CockpitView.missingPrerequisiteLabel))
    }

    /// A text entry strikes through once `met` is `true`.
    func testPrerequisiteFragmentStrikesThroughAMetTextEntry() {
        let condition = "the review happens"
        let met = CockpitView.prerequisiteFragment(
            .text(text: condition, met: true, judgedBy: nil, judgedAt: nil))
        XCTAssertEqual(met, Text(condition).strikethrough())
        let unmet = CockpitView.prerequisiteFragment(
            .text(text: condition, met: false, judgedBy: nil, judgedAt: nil))
        XCTAssertEqual(unmet, Text(condition))
    }

    /// Several entries join comma-separated, each keeping its own
    /// strikethrough — a joined line is one `Text` value, not a `ForEach`.
    func testNeedsFirstTextJoinsSeveralEntriesWithCommas() {
        let openTitle = "Open blocker"
        let doneTitle = "Done blocker"
        let openLabel = "\(openTitle) (open)"
        let doneLabel = "\(doneTitle) (fixed)"
        let joined = CockpitView.needsFirstText([
            .item(id: "issue_A", title: openTitle, state: "open"),
            .item(id: "issue_B", title: doneTitle, state: "fixed"),
        ])
        XCTAssertEqual(joined, Text(openLabel) + Text(", ") + Text(doneLabel).strikethrough())
    }

    /// The plain-string form feeds `clampedCaption`'s tooltip — a readable
    /// item shows its title with its served state alongside, a missing
    /// item shows the fixed label, and a plain unmet text entry with no
    /// judgment shows just its own text.
    func testNeedsFirstPlainTextRendersEachShape() {
        XCTAssertEqual(CockpitView.needsFirstPlainText([
            .item(id: "issue_A", title: "Blocker", state: "open"),
            .missingItem(id: "issue_B"),
            .text(text: "a condition", met: false, judgedBy: nil, judgedAt: nil),
        ]), "Blocker (open), \(CockpitView.missingPrerequisiteLabel), a condition")
    }

    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    private let posix = Locale(identifier: "en_US_POSIX")
    /// 2026-09-16T06:30:00Z, which is 2026-09-16 12:00 in `kolkata`.
    private let now = Date(timeIntervalSince1970: 1_789_540_200)

    /// **Comment 2261: "`judged_by` and `judged_at` belong in the
    /// tooltip."** The plain-text form is what feeds the tooltip, so a met,
    /// judged text entry carries both there — the rich `Text` caption never
    /// draws this detail. `judged_at` draws in the reader's own zone rather
    /// than the raw UTC instant the Library served; same day as `now`
    /// carries a clock reading alone.
    func testNeedsFirstPlainTextCarriesJudgmentForAMetTextEntry() {
        XCTAssertEqual(CockpitView.needsFirstPlainText([
            .text(text: "the review happens", met: true, judgedBy: "agent-x", judgedAt: "2026-09-16T04:23:33Z"),
        ], now: now, timeZone: kolkata, locale: posix),
        "the review happens (met, judged by agent-x, 9:53\u{202F}AM)")
    }

    /// A `judged_at` on an earlier local day than `now` carries the date
    /// too.
    func testNeedsFirstPlainTextJudgmentOnAnEarlierDayCarriesTheDate() {
        XCTAssertEqual(CockpitView.needsFirstPlainText([
            .text(text: "the review happens", met: true, judgedBy: "agent-x", judgedAt: "2026-09-14T20:00:00Z"),
        ], now: now, timeZone: kolkata, locale: posix),
        "the review happens (met, judged by agent-x, Sep 15 at 1:30\u{202F}AM)")
    }

    /// A `judged_at` the client cannot parse draws unchanged.
    func testNeedsFirstPlainTextUnparseableJudgmentDrawsTheRawString() {
        XCTAssertEqual(CockpitView.needsFirstPlainText([
            .text(text: "the review happens", met: true, judgedBy: "agent-x", judgedAt: "not-a-date"),
        ], now: now, timeZone: kolkata, locale: posix),
        "the review happens (met, judged by agent-x, not-a-date)")
    }

    // MARK: - childHelpText

    /// **C2's `pr-open` case.** A row's own honesty lives in `.help` as the
    /// raw state word, since the glyph has already collapsed it into
    /// `.inProgress`.
    func testChildHelpTextIsTheRawStateWord() {
        let prOpen = item("B", state: "pr-open")
        XCTAssertEqual(CockpitView.childHelpText(prOpen), "pr-open")
    }

    // MARK: - queueClaimMetaText

    private func queueItem(_ id: String, state: String?, claimedBy: String?, claimExpired: Bool) -> LibraryClient.QueueItem {
        LibraryClient.QueueItem(id: id, title: "item \(id)", type: "bug", severity: nil,
                                state: state, claimedBy: claimedBy, claimExpired: claimExpired)
    }

    /// **THE ROW `issue_01M1Y7AKMRQ4S7K9CX5R99ZMPQ` FIXES.** A live claim
    /// names its holder; a lapsed one says "claim expired" instead — never
    /// the holder, since the row's point is that the item is free again.
    func testQueueClaimMetaTextNamesTheHolderWhenLive() {
        let live = queueItem("i-live", state: "claimed", claimedBy: "agent-x", claimExpired: false)
        XCTAssertEqual(CockpitView.queueClaimMetaText(live), "claimed · agent-x")
    }

    func testQueueClaimMetaTextSaysExpiredNotTheHolder() {
        let expired = queueItem("i-expired", state: "claimed", claimedBy: "agent-y", claimExpired: true)
        XCTAssertEqual(CockpitView.queueClaimMetaText(expired), "claim expired")
    }

    /// An `open` or `pr-open` row carries no `claimedBy` at all, so the row
    /// draws no caption rather than a blank or fabricated one.
    func testQueueClaimMetaTextIsNilWhenNotClaimed() {
        let open = queueItem("i-open", state: "open", claimedBy: nil, claimExpired: false)
        XCTAssertNil(CockpitView.queueClaimMetaText(open))
    }

    // MARK: - libraryTooltip and the bounds on what reaches a tooltip
    //
    // PR #171: `.help` became the escape hatch for every clamped line in the
    // epic expansion, which put Library-served strings in front of AppKit's
    // tooltip layout. The Library bounds none of these fields at the write
    // path, so the bound has to be here — and it has to survive a caller who
    // forgets, which is exactly how `childHelpText` was found unguarded.

    /// A Character-count cut alone is NOT a bound: one grapheme cluster can
    /// carry unboundedly many scalars, so sanitising has to come first.
    /// `libraryTooltip` is the single place both happen, in that order.
    func testLibraryTooltipBoundsScalarsAndNotOnlyCharacters() {
        let cluster = "e" + String(repeating: "\u{0301}", count: 4000)
        let bounded = CockpitView.libraryTooltip(cluster)
        XCTAssertLessThanOrEqual(bounded.unicodeScalars.count, 16 * WaypointRibbon.tooltipCharacterLimit,
                                 "a single cluster must not carry unbounded scalars through the bound")
    }

    func testLibraryTooltipBoundsALongPlainString() {
        let long = String(repeating: "a", count: WaypointRibbon.tooltipCharacterLimit * 3)
        XCTAssertLessThanOrEqual(CockpitView.libraryTooltip(long).count,
                                 WaypointRibbon.tooltipCharacterLimit + 1)
    }

    func testLibraryTooltipLeavesAShortStringAlone() {
        XCTAssertEqual(CockpitView.libraryTooltip("blocked on another crew"),
                       "blocked on another crew")
    }

    /// **The gap `deck-reviewer` found on PR #171.** Clamping the child title
    /// without giving it a tooltip removed the only way to read a long one:
    /// `childHelpText` returns the state, never the title.
    func testChildTitleHelpTextCarriesTheTitleAndTheState() {
        let prOpen = item("B", state: "pr-open")
        XCTAssertEqual(CockpitView.childTitleHelpText(prOpen), "item B — pr-open")
    }

    /// Both halves are bounded and the join is not re-cut, so a long title
    /// cannot push the state off the end.
    func testChildTitleHelpTextKeepsTheStateBehindALongTitle() {
        let long = LibraryClient.ChildItem(id: "C", title: String(repeating: "t", count: 4000),
                                           type: "task", state: "pr-open", parentId: "issue_EPIC")
        XCTAssertTrue(CockpitView.childTitleHelpText(long).hasSuffix("— pr-open"))
    }

    // MARK: - coursePartition
    //
    // issue_01M1CCYWG8409VA4PT4W1QBB5D: the Course has no bounded height, so
    // a long trailing run of unstarted epics (or a long leading run of
    // closed ones) pushes the panels below it off the pane. Both collapses
    // are runs anchored to `rowTreatment`, not a filter over the whole list
    // — asserted here on the partition itself, never on rendered text.

    private func entry(_ id: String, state: String?, resolution: String? = nil) -> LibraryClient.CourseEntry {
        LibraryClient.CourseEntry(id: id, title: "epic \(id)", state: state, resolution: resolution)
    }

    private func ids(_ entries: [LibraryClient.CourseEntry]) -> [String] {
        entries.map(\.id)
    }

    /// Two unstarted at the tail is short of the "more than 2" threshold —
    /// nothing collapses.
    func testFewerThanThreeUnstartedAtTailCollapsesNothing() {
        let entries = [entry("A", state: "fixed", resolution: "fixed"),
                        entry("B", state: nil), entry("C", state: "open")]
        let partition = CockpitView.coursePartition(entries)
        XCTAssertTrue(partition.hiddenHead.isEmpty)
        XCTAssertTrue(partition.hiddenTail.isEmpty)
        XCTAssertEqual(ids(partition.visible), ["A", "B", "C"])
    }

    /// Exactly three trailing unstarted epics is where the rule first bites
    /// — two stay, one hides.
    func testExactlyThreeUnstartedAtTailHidesOne() {
        let entries = [entry("A", state: "fixed", resolution: "fixed"),
                        entry("B", state: nil), entry("C", state: "open"), entry("D", state: "open")]
        let partition = CockpitView.coursePartition(entries)
        XCTAssertTrue(partition.hiddenHead.isEmpty)
        XCTAssertEqual(ids(partition.visible), ["A", "B", "C"])
        XCTAssertEqual(ids(partition.hiddenTail), ["D"])
    }

    /// A started epic sitting between two runs of unstarted ones stops the
    /// tail rule where it sits — the earlier run, on the far side of it,
    /// must never collapse alongside the trailing one.
    func testAStartedEpicBetweenTwoUnstartedRunsStopsTheTailRuleThere() {
        let entries = [entry("A", state: "open"), entry("B", state: "open"), entry("C", state: "open"),
                        entry("D", state: "claimed"),
                        entry("E", state: "open"), entry("F", state: "open"), entry("G", state: "open")]
        let partition = CockpitView.coursePartition(entries)
        XCTAssertTrue(partition.hiddenHead.isEmpty)
        XCTAssertEqual(ids(partition.visible), ["A", "B", "C", "D", "E", "F"])
        XCTAssertEqual(ids(partition.hiddenTail), ["G"])
    }

    /// A Course that is entirely unstarted collapses everything past the
    /// first two into the tail run — there is no non-`.ahead` entry to stop
    /// it early.
    func testACourseEntirelyUnstartedCollapsesAtTheTail() {
        let entries = (1...5).map { entry("E\($0)", state: "open") }
        let partition = CockpitView.coursePartition(entries)
        XCTAssertTrue(partition.hiddenHead.isEmpty)
        XCTAssertEqual(ids(partition.visible), ["E1", "E2"])
        XCTAssertEqual(ids(partition.hiddenTail), ["E3", "E4", "E5"])
    }

    /// A Course that is entirely closed collapses everything past the first
    /// two into the head run — the mirror case, with no trailing unstarted
    /// run for the tail rule to find.
    func testACourseEntirelyClosedCollapsesAtTheHead() {
        let entries = (1...5).map { entry("E\($0)", state: "fixed", resolution: "fixed") }
        let partition = CockpitView.coursePartition(entries)
        XCTAssertEqual(ids(partition.hiddenHead), ["E1", "E2", "E3"])
        XCTAssertEqual(ids(partition.visible), ["E4", "E5"])
        XCTAssertTrue(partition.hiddenTail.isEmpty)
    }

    /// An empty Course partitions into three empty runs — no crash, nothing
    /// to hide.
    func testAnEmptyCourseCollapsesNothing() {
        let partition = CockpitView.coursePartition([])
        XCTAssertTrue(partition.hiddenHead.isEmpty)
        XCTAssertTrue(partition.visible.isEmpty)
        XCTAssertTrue(partition.hiddenTail.isEmpty)
    }

    /// Two closed epics leading is short of the "more than 2" threshold —
    /// nothing collapses at the head.
    func testFewerThanThreeClosedAtHeadCollapsesNothing() {
        let entries = [entry("A", state: "fixed", resolution: "fixed"),
                        entry("B", state: "redirected", resolution: "redirected"),
                        entry("C", state: "open")]
        let partition = CockpitView.coursePartition(entries)
        XCTAssertTrue(partition.hiddenHead.isEmpty)
        XCTAssertEqual(ids(partition.visible), ["A", "B", "C"])
    }

    /// Both collapses fire at once on the same Course, independently — a
    /// leading run of closed epics and a trailing run of unstarted ones,
    /// each obeying its own threshold, with the untouched middle in
    /// between.
    func testBothCollapsesActiveAtOnceOnTheSameCourse() {
        let entries = [entry("A", state: "fixed", resolution: "fixed"),
                        entry("B", state: "wontfix", resolution: "wontfix"),
                        entry("C", state: "fixed", resolution: "fixed"),
                        entry("D", state: "claimed"),
                        entry("E", state: "open"), entry("F", state: "open"),
                        entry("G", state: "open"), entry("H", state: "open")]
        let partition = CockpitView.coursePartition(entries)
        XCTAssertEqual(ids(partition.hiddenHead), ["A"])
        XCTAssertEqual(ids(partition.visible), ["B", "C", "D", "E", "F"])
        XCTAssertEqual(ids(partition.hiddenTail), ["G", "H"])
    }

    /// A `pr-open` epic reads as `.inProgress`, which must never collapse
    /// at the tail — it is "MUST STAY" in both columns, so it both stays
    /// visible itself and stops the trailing run from reaching past it.
    func testAPROpenEpicNeverCollapsesAndStopsTheTailRun() {
        let entries = [entry("A", state: "open"), entry("B", state: "open"), entry("C", state: "open"),
                        entry("D", state: "pr-open"), entry("E", state: "open")]
        let partition = CockpitView.coursePartition(entries)
        XCTAssertTrue(partition.hiddenTail.isEmpty)
        XCTAssertEqual(ids(partition.visible), ["A", "B", "C", "D", "E"])
    }

    // MARK: - topmostVisiblePanelID — the panel index's "here" entry
    //
    // A pure function over already-measured geometry: given a panel order,
    // each panel's last-reported frame, and the viewport's height, which one
    // is "here". No view is constructed anywhere in this section —
    // ContentView-level view wiring is not reachable from XCTest in this
    // repo (convivy-deck#153).

    private let viewportHeight: CGFloat = 600

    private func frame(y: CGFloat, height: CGFloat = 100) -> CGRect {
        CGRect(x: 0, y: y, width: 280, height: height)
    }

    /// Dispatched has scrolled fully past (`maxY <= 0`) and is excluded;
    /// of the two that remain, proposals — its top already above the
    /// viewport's own top edge — is more "topmost" than Course, whose top
    /// has not yet reached it.
    func testTheTopmostPanelInTheViewportIsHere() {
        let frames: [String: CGRect] = [
            "dispatched": frame(y: -150), "proposals": frame(y: -50, height: 200), "course": frame(y: 150, height: 500),
        ]
        let here = CockpitView.topmostVisiblePanelID(
            order: CockpitView.panelOrder, frames: frames, viewportHeight: viewportHeight)
        XCTAssertEqual(here, "proposals")
    }

    /// Scrolled past everything above it, the reader's queue view names the
    /// queue as "here" even though nothing else is measured within bounds.
    func testAPanelScrolledToTheTopOfAFarDownViewportIsHere() {
        let frames: [String: CGRect] = [
            "dispatched": frame(y: -900), "proposals": frame(y: -800), "course": frame(y: -700, height: 650),
            "correctionsQueue": frame(y: -50),
        ]
        let here = CockpitView.topmostVisiblePanelID(
            order: CockpitView.panelOrder, frames: frames, viewportHeight: viewportHeight)
        XCTAssertEqual(here, "correctionsQueue")
    }

    /// A panel entirely above the viewport (`maxY <= 0`) or entirely below
    /// it (`minY >= viewportHeight`) never counts as "here".
    func testAPanelWhollyOutsideTheViewportIsNeverHere() {
        let frames: [String: CGRect] = ["course": frame(y: -200, height: 100), "correctionsQueue": frame(y: 700)]
        let here = CockpitView.topmostVisiblePanelID(
            order: ["course", "correctionsQueue"], frames: frames, viewportHeight: viewportHeight)
        XCTAssertNil(here)
    }

    /// No measured frame yet reads as "haven't measured it", not as a guess.
    func testNoFramesMeasuredYetHasNoHerePanel() {
        let here = CockpitView.topmostVisiblePanelID(
            order: CockpitView.panelOrder, frames: [:], viewportHeight: viewportHeight)
        XCTAssertNil(here)
    }

    /// A collapsed panel's shrunken frame can still be "here" — collapsing
    /// is not scrolling away from it. Whether it draws struck is a separate
    /// concern the view layer applies from `collapsedPanelIDs` directly.
    func testACollapsedPanelsFrameCanStillBeHere() {
        let frames: [String: CGRect] = ["course": frame(y: 0, height: 24), "correctionsQueue": frame(y: 24)]
        let here = CockpitView.topmostVisiblePanelID(
            order: ["course", "correctionsQueue"], frames: frames, viewportHeight: viewportHeight)
        XCTAssertEqual(here, "course")
    }

    // MARK: - panelIndexCount — each index entry's number

    func testDispatchedCountsAgentRuns() {
        let count = CockpitView.panelIndexCount(
            id: "dispatched", agentRuns: [agentRun("a"), agentRun("b")],
            proposalCount: 0, courseEntries: nil, queueTotal: nil)
        XCTAssertEqual(count, "2")
    }

    /// `nil` agent runs — a mini that predates `agent_runs` — draws no
    /// number rather than a misleading zero.
    func testDispatchedDrawsNoCountWhenAgentRunsIsNil() {
        let count = CockpitView.panelIndexCount(
            id: "dispatched", agentRuns: nil, proposalCount: 0, courseEntries: nil, queueTotal: nil)
        XCTAssertNil(count)
    }

    func testProposalsCountsTheProposalList() {
        let count = CockpitView.panelIndexCount(
            id: "proposals", agentRuns: nil, proposalCount: 3, courseEntries: nil, queueTotal: nil)
        XCTAssertEqual(count, "3")
    }

    /// `nil` proposal count — a Proposals panel with no project resolved,
    /// the same state `courseEntries: nil` draws for Course — reads as no
    /// measurement, never the misleading "0" `model.proposedEpics.count`
    /// would give were it read straight through without the same gating
    /// `courseUnresolvedReason` gets.
    func testProposalsDrawsNoCountWhenUnresolved() {
        let count = CockpitView.panelIndexCount(
            id: "proposals", agentRuns: nil, proposalCount: nil, courseEntries: nil, queueTotal: nil)
        XCTAssertNil(count)
    }

    func testCourseCountsSettledOverTotalUsingRowTreatment() {
        let entries = [
            entry("A", state: nil, resolution: "fixed"), entry("B", state: "open", resolution: nil),
            entry("C", state: nil, resolution: "wontfix"), entry("D", state: "claimed", resolution: nil),
        ]
        let count = CockpitView.panelIndexCount(
            id: "course", agentRuns: nil, proposalCount: 0, courseEntries: entries, queueTotal: nil)
        // A and C settle (done, closedNotDone); B (ahead) and D (claimed, in progress) do not.
        XCTAssertEqual(count, "2/4")
    }

    func testCourseDrawsNoCountWhenNoCourseIsLoaded() {
        let count = CockpitView.panelIndexCount(
            id: "course", agentRuns: nil, proposalCount: 0, courseEntries: nil, queueTotal: nil)
        XCTAssertNil(count)
    }

    /// A loaded-but-empty Course returns the same `nil` as an unmeasured
    /// one — `panelIndexEntry` draws both as the "—" glyph. "0/0" would
    /// claim there is a Course with zero entries to count, rather than no
    /// Course to count at all.
    func testCourseDrawsNoCountWhenCourseIsLoadedAndEmpty() {
        let count = CockpitView.panelIndexCount(
            id: "course", agentRuns: nil, proposalCount: 0, courseEntries: [], queueTotal: nil)
        XCTAssertNil(count)
    }

    func testCorrectionsQueueCountsItsTotal() {
        let count = CockpitView.panelIndexCount(
            id: "correctionsQueue", agentRuns: nil, proposalCount: 0, courseEntries: nil, queueTotal: 23)
        XCTAssertEqual(count, "23")
    }

    func testCorrectionsQueueDrawsNoCountWhenNoQueueReadingExists() {
        let count = CockpitView.panelIndexCount(
            id: "correctionsQueue", agentRuns: nil, proposalCount: 0, courseEntries: nil, queueTotal: nil)
        XCTAssertNil(count)
    }

    /// "ready/total" — the same "settled/total" shape Course uses, so a
    /// reader never mistakes "how many need a decision" for "how many
    /// exist".
    func testPullRequestsCountsReadyOverTotal() {
        let count = CockpitView.panelIndexCount(
            id: "pullRequests", agentRuns: nil, proposalCount: 0, courseEntries: nil, queueTotal: nil,
            pullRequestCount: 4, pullRequestTotalCount: 8)
        XCTAssertEqual(count, "4/8")
    }

    /// Zero ready among real rows draws "0/8", never a bare "0" that would
    /// read as "no pull requests at all" beside eight open rows — the
    /// deliberate choice `pullRequestsCount`'s doc calls out.
    func testPullRequestsDrawsZeroReadyOverTotalRatherThanABareZero() {
        let count = CockpitView.panelIndexCount(
            id: "pullRequests", agentRuns: nil, proposalCount: 0, courseEntries: nil, queueTotal: nil,
            pullRequestCount: 0, pullRequestTotalCount: 8)
        XCTAssertEqual(count, "0/8")
    }

    func testPullRequestsDrawsNoCountWhenNilPassed() {
        let count = CockpitView.panelIndexCount(
            id: "pullRequests", agentRuns: nil, proposalCount: 0, courseEntries: nil, queueTotal: nil)
        XCTAssertNil(count)
    }

    /// A loaded, genuinely empty panel (total `0`) draws no count, the same
    /// choice `testCourseDrawsNoCountWhenCourseIsLoadedAndEmpty` makes for
    /// an empty Course — "0/0" would claim there is a real ratio to report.
    func testPullRequestsDrawsNoCountWhenTotalIsZero() {
        let count = CockpitView.panelIndexCount(
            id: "pullRequests", agentRuns: nil, proposalCount: 0, courseEntries: nil, queueTotal: nil,
            pullRequestCount: 0, pullRequestTotalCount: 0)
        XCTAssertNil(count)
    }

    // MARK: - pullRequestsCount — how many rows are .readyToMerge

    func testPullRequestsCountIsNilWithNoPanel() {
        XCTAssertNil(CockpitView.pullRequestsCount(nil))
    }

    func testPullRequestsCountIsNilOnAFetchError() {
        let panel = CockpitView.PullRequestsPanel(result: nil, fetchError: "boom", isLoading: false)
        XCTAssertNil(CockpitView.pullRequestsCount(panel))
    }

    func testPullRequestsCountIsNilOnAWholePanelDegrade() {
        let panel = CockpitView.PullRequestsPanel(
            result: .degraded(reason: "the Library is unreachable"), fetchError: nil, isLoading: false)
        XCTAssertNil(CockpitView.pullRequestsCount(panel))
    }

    private func ladderRow(_ number: Int, position: PRLadder.Position) -> PRLadder.LadderResult {
        PRLadder.LadderResult(
            repo: "convivy/convivy-deck", number: number, title: nil, author: nil,
            position: position, staleReviewCount: 0, updatedAt: nil)
    }

    /// Counts only the rows waiting on a decision, not every row the panel
    /// draws — the distinction the issue exists to fix.
    func testPullRequestsCountCountsOnlyReadyToMergeRows() {
        let rows = [
            ladderRow(1, position: .readyToMerge),
            ladderRow(2, position: .inReview),
            ladderRow(3, position: .readyToMerge),
            ladderRow(4, position: .failedCI),
        ]
        let panel = CockpitView.PullRequestsPanel(
            result: .ladder(rows, truncated: false), fetchError: nil, isLoading: false)
        XCTAssertEqual(CockpitView.pullRequestsCount(panel), 2)
    }

    /// A panel with real rows and none of them ready is a real zero, not a
    /// missing measurement.
    func testPullRequestsCountIsZeroWhenNoRowIsReadyToMerge() {
        let rows = [ladderRow(1, position: .inReview), ladderRow(2, position: .inCI)]
        let panel = CockpitView.PullRequestsPanel(
            result: .ladder(rows, truncated: false), fetchError: nil, isLoading: false)
        XCTAssertEqual(CockpitView.pullRequestsCount(panel), 0)
    }

    /// `.readyToMerge` is always open, so the recent-closed cut can never
    /// drop one — a ready row still counts even once enough closed rows
    /// exist to trigger `orderedForDisplay`'s truncation.
    func testPullRequestsCountStillCountsAReadyRowPastTheRecentClosedCut() {
        var rows = [ladderRow(1, position: .readyToMerge)]
        rows += (2...(PRLadder.recentClosedLimit + 3)).map { ladderRow($0, position: .closed(.merged)) }
        let panel = CockpitView.PullRequestsPanel(
            result: .ladder(rows, truncated: false), fetchError: nil, isLoading: false)
        XCTAssertEqual(CockpitView.pullRequestsCount(panel), 1)
    }

    // MARK: - pullRequestsTotalCount — the panel's own row count, after the recent-closed cut

    func testPullRequestsTotalCountIsNilWithNoPanel() {
        XCTAssertNil(CockpitView.pullRequestsTotalCount(nil))
    }

    func testPullRequestsTotalCountIsNilOnAFetchError() {
        let panel = CockpitView.PullRequestsPanel(result: nil, fetchError: "boom", isLoading: false)
        XCTAssertNil(CockpitView.pullRequestsTotalCount(panel))
    }

    func testPullRequestsTotalCountIsNilOnAWholePanelDegrade() {
        let panel = CockpitView.PullRequestsPanel(
            result: .degraded(reason: "the Library is unreachable"), fetchError: nil, isLoading: false)
        XCTAssertNil(CockpitView.pullRequestsTotalCount(panel))
    }

    /// Matches `PRLadder.orderedForDisplay`'s own count, not the raw
    /// fetched-row count — the index and the panel body must never disagree
    /// about how many rows are actually drawn.
    func testPullRequestsTotalCountMatchesOrderedForDisplayAfterTheRecentClosedCut() {
        let closed = (1...(PRLadder.recentClosedLimit + 2)).map { ladderRow($0, position: .closed(.merged)) }
        let panel = CockpitView.PullRequestsPanel(
            result: .ladder(closed, truncated: false), fetchError: nil, isLoading: false)
        XCTAssertEqual(CockpitView.pullRequestsTotalCount(panel), PRLadder.recentClosedLimit)
    }

    // MARK: - pullRequestsAreTruncated — the truncation notice's own seam

    func testPullRequestsAreTruncatedWhenFetchLadderReportsTruncation() {
        let panel = CockpitView.PullRequestsPanel(
            result: .ladder([], truncated: true), fetchError: nil, isLoading: false)
        XCTAssertTrue(CockpitView.pullRequestsAreTruncated(panel))
    }

    func testPullRequestsAreNotTruncatedWhenFetchLadderReportsCompletion() {
        let panel = CockpitView.PullRequestsPanel(
            result: .ladder([], truncated: false), fetchError: nil, isLoading: false)
        XCTAssertFalse(CockpitView.pullRequestsAreTruncated(panel))
    }

    /// A whole-panel degrade already says its own thing about why the panel
    /// cannot be trusted — it must not also claim the unrelated truncation
    /// notice.
    func testPullRequestsAreNotTruncatedOnAWholePanelDegrade() {
        let panel = CockpitView.PullRequestsPanel(
            result: .degraded(reason: "the Library returned another repository's rows"),
            fetchError: nil, isLoading: false)
        XCTAssertFalse(CockpitView.pullRequestsAreTruncated(panel))
    }

    func testPullRequestsAreNotTruncatedWithNoPanel() {
        XCTAssertFalse(CockpitView.pullRequestsAreTruncated(nil))
    }

    // MARK: - pullRequestsStalenessText — issue_01M2P60KDY9KPXWMZ4C6G1CJ52 point 5

    private static let stalenessNow = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// A reading fetched this instant, nothing in flight, needs no caveat —
    /// the "permanently visible age becomes noise" case the issue calls out.
    func testStalenessTextIsNilJustAfterAFetchWithNothingInFlight() {
        let text = CockpitView.pullRequestsStalenessText(
            fetchedAt: Self.stalenessNow, isLoading: false, now: Self.stalenessNow)
        XCTAssertNil(text)
    }

    /// One second younger than the threshold: still no caveat. The boundary
    /// itself is `testStalenessTextAppearsTheInstantTheThresholdIsReached`.
    func testStalenessTextIsNilJustUnderTheThreshold() {
        let fetchedAt = Self.stalenessNow.addingTimeInterval(-(CockpitView.stalenessThreshold - 1))
        let text = CockpitView.pullRequestsStalenessText(
            fetchedAt: fetchedAt, isLoading: false, now: Self.stalenessNow)
        XCTAssertNil(text)
    }

    func testStalenessTextAppearsTheInstantTheThresholdIsReached() {
        let fetchedAt = Self.stalenessNow.addingTimeInterval(-CockpitView.stalenessThreshold)
        let text = CockpitView.pullRequestsStalenessText(
            fetchedAt: fetchedAt, isLoading: false, now: Self.stalenessNow)
        XCTAssertEqual(text, "15m old")
    }

    /// Rows a few minutes old — well under the threshold — with a refresh in
    /// flight still say so: a fetch in flight is its own fact, independent
    /// of whether the age alone would have earned a caveat.
    func testStalenessTextSaysRefreshingEvenWhenTheAgeAloneWouldSayNothing() {
        let fetchedAt = Self.stalenessNow.addingTimeInterval(-5 * 60)
        let text = CockpitView.pullRequestsStalenessText(
            fetchedAt: fetchedAt, isLoading: true, now: Self.stalenessNow)
        XCTAssertEqual(text, "refreshing…")
    }

    /// Old enough to matter, nothing in flight: the age alone, no
    /// "refreshing" suffix to falsely suggest a fetch is under way.
    func testStalenessTextIsAgeAloneWhenNothingIsInFlight() {
        let fetchedAt = Self.stalenessNow.addingTimeInterval(-73 * 60)
        let text = CockpitView.pullRequestsStalenessText(
            fetchedAt: fetchedAt, isLoading: false, now: Self.stalenessNow)
        XCTAssertEqual(text, "1h 13m old")
    }

    /// Old AND currently refreshing: both facts the issue asks for, in one
    /// line — the operator sees the reading is stale and that it is about
    /// to stop being stale.
    func testStalenessTextCombinesAgeAndRefreshingWhenBothApply() {
        let fetchedAt = Self.stalenessNow.addingTimeInterval(-73 * 60)
        let text = CockpitView.pullRequestsStalenessText(
            fetchedAt: fetchedAt, isLoading: true, now: Self.stalenessNow)
        XCTAssertEqual(text, "1h 13m old · refreshing")
    }

    /// An exact hour carries no "0m" remainder.
    func testStalenessTextDropsAZeroMinuteRemainder() {
        let fetchedAt = Self.stalenessNow.addingTimeInterval(-2 * 60 * 60)
        let text = CockpitView.pullRequestsStalenessText(
            fetchedAt: fetchedAt, isLoading: false, now: Self.stalenessNow)
        XCTAssertEqual(text, "2h old")
    }

    /// Past a day, the hour/minute form would read as a four-digit minute
    /// count — this steps up to whole days instead.
    func testStalenessTextStepsUpToDaysPastTwentyFourHours() {
        let fetchedAt = Self.stalenessNow.addingTimeInterval(-25 * 60 * 60)
        let text = CockpitView.pullRequestsStalenessText(
            fetchedAt: fetchedAt, isLoading: false, now: Self.stalenessNow)
        XCTAssertEqual(text, "1d old")
    }

    /// `fetchedAt == nil` — never fetched, or the last attempt failed
    /// (`PRLadderModel` clears it on failure) — is a real state, not a
    /// missing measurement: there is no second clock to guess an age from,
    /// so this draws nothing rather than inventing one.
    func testStalenessTextIsNilWithNoFetchedAt() {
        let text = CockpitView.pullRequestsStalenessText(
            fetchedAt: nil, isLoading: false, now: Self.stalenessNow)
        XCTAssertNil(text)
    }

    /// Even with no age to report, a fetch in flight still says so — the
    /// first attempt at a repo this session has never fetched before.
    func testStalenessTextSaysRefreshingWithNoFetchedAt() {
        let text = CockpitView.pullRequestsStalenessText(
            fetchedAt: nil, isLoading: true, now: Self.stalenessNow)
        XCTAssertEqual(text, "refreshing…")
    }

    // MARK: - showsRepoMark / mergedLadder — several repos, one panel
    // (issue_01M2P5JHM1G8XCMKM4HEHVJB2P)

    private func multiRepoReading(
        owner: String, repoName: String, result: PRLadder.FetchResult?,
        fetchError: String? = nil, isLoading: Bool = false, fetchedAt: Date? = nil
    ) -> CockpitView.PullRequestsPanel.RepoReading {
        .init(owner: owner, repoName: repoName, result: result, fetchError: fetchError,
              isLoading: isLoading, fetchedAt: fetchedAt)
    }

    /// The gate the issue asks for: no mark for the common single-repo
    /// case, a mark once a crew follows more than one.
    func testShowsRepoMarkIsFalseForASingleRepoPanel() {
        let panel = CockpitView.PullRequestsPanel(result: .ladder([], truncated: false), fetchError: nil, isLoading: false)
        XCTAssertFalse(CockpitView.showsRepoMark(panel))
    }

    func testShowsRepoMarkIsTrueOnceACrewFollowsMoreThanOneRepo() {
        let panel = CockpitView.PullRequestsPanel(readings: [
            multiRepoReading(owner: "convivy", repoName: "selector", result: nil),
            multiRepoReading(owner: "convivy", repoName: "selector-backend", result: nil),
        ])
        XCTAssertTrue(CockpitView.showsRepoMark(panel))
    }

    func testShowsRepoMarkIsFalseWithNoPanel() {
        XCTAssertFalse(CockpitView.showsRepoMark(nil))
    }

    /// Two succeeding repos' rows concatenate into the merged panel —
    /// `mergeReadings`'s own coverage already pins the pure merge; this
    /// confirms `CockpitView` wires the panel's readings into it correctly.
    func testMergedLadderConcatenatesRowsAcrossRepos() {
        let panel = CockpitView.PullRequestsPanel(readings: [
            multiRepoReading(owner: "convivy", repoName: "selector",
                              result: .ladder([ladderRow(1, position: .inReview)], truncated: false)),
            multiRepoReading(owner: "convivy", repoName: "selector-backend",
                              result: .ladder([ladderRow(1, position: .readyToMerge)], truncated: false)),
        ])
        let merged = CockpitView.mergedLadder(panel)
        XCTAssertEqual(merged.results.count, 2)
        XCTAssertTrue(merged.failures.isEmpty)
    }

    /// The issue's own rule, exercised through the count helpers a crew's
    /// several repos actually drive: one repo failing still leaves a real,
    /// non-nil count from whichever repos succeeded.
    func testPullRequestsCountIsRealWhenOnlySomeFollowedReposSucceeded() {
        let panel = CockpitView.PullRequestsPanel(readings: [
            multiRepoReading(owner: "convivy", repoName: "selector",
                              result: .ladder([ladderRow(1, position: .readyToMerge)], truncated: false)),
            multiRepoReading(owner: "convivy", repoName: "selector-backend", result: nil, fetchError: "boom"),
        ])
        XCTAssertEqual(CockpitView.pullRequestsCount(panel), 1)
        XCTAssertEqual(CockpitView.pullRequestsTotalCount(panel), 1)
    }

    /// The other end of that rule: every followed repo failing (none ever
    /// produced a `.ladder`) is still "no real measurement," exactly like
    /// the single-repo fetch-error case.
    func testPullRequestsCountIsNilWhenEveryFollowedRepoFailed() {
        let panel = CockpitView.PullRequestsPanel(readings: [
            multiRepoReading(owner: "convivy", repoName: "selector", result: nil, fetchError: "boom"),
            multiRepoReading(owner: "convivy", repoName: "selector-backend",
                              result: .degraded(reason: "unreachable")),
        ])
        XCTAssertNil(CockpitView.pullRequestsCount(panel))
        XCTAssertNil(CockpitView.pullRequestsTotalCount(panel))
    }

    /// `oldestFetchedAt` reports the least-fresh repo's own age — the panel
    /// is only as fresh as its stalest followed repo.
    func testOldestFetchedAtIsTheLeastFreshRepo() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let panel = CockpitView.PullRequestsPanel(readings: [
            multiRepoReading(owner: "convivy", repoName: "selector", result: nil, fetchedAt: newer),
            multiRepoReading(owner: "convivy", repoName: "selector-backend", result: nil, fetchedAt: older),
        ])
        XCTAssertEqual(CockpitView.oldestFetchedAt(panel), older)
    }

    func testAnyReadingIsLoadingIsTrueWhenAnyOneRepoIsLoading() {
        let panel = CockpitView.PullRequestsPanel(readings: [
            multiRepoReading(owner: "convivy", repoName: "selector", result: nil, isLoading: false),
            multiRepoReading(owner: "convivy", repoName: "selector-backend", result: nil, isLoading: true),
        ])
        XCTAssertTrue(CockpitView.anyReadingIsLoading(panel))
    }

    // MARK: - panelOrder

    func testPanelOrderIncludesPullRequests() {
        XCTAssertTrue(CockpitView.panelOrder.contains(CockpitView.pullRequestsPanelID))
    }

    // MARK: - indexCountWeight — the queue's count carries the badge weight

    func testCorrectionsQueueCountIsSemibold() {
        XCTAssertEqual(CockpitView.indexCountWeight(id: "correctionsQueue"), .semibold)
    }

    func testAnotherPanelsCountIsRegular() {
        XCTAssertEqual(CockpitView.indexCountWeight(id: "course"), .regular)
    }

    private func agentRun(_ id: String) -> SessionState.AgentRun {
        SessionState.AgentRun(runId: id, agent: "a-\(id)", task: nil, startedAt: nil, repo: nil, model: nil)
    }

    // MARK: - Course drag: where the landing line draws

    /// The line is drawn where `reorderedEntryIds` will put the epic: below
    /// the row when dragged from above, above it when dragged from below.
    func testTheCourseDropLineSitsWhereTheEpicWillLand() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(CockpitView.courseDropEdge(entryIDs: ids, dragging: "a", over: "c"), .below)
        XCTAssertEqual(CockpitView.courseDropEdge(entryIDs: ids, dragging: "c", over: "a"), .above)
        XCTAssertEqual(CockpitView.courseDropEdge(entryIDs: ids, dragging: "b", over: "c"), .below)
    }

    /// No line where nothing would move, so the line never promises a change
    /// the drop will not make.
    func testTheCourseDropLineIsAbsentOverTheDraggedRowOrAStranger() {
        let ids = ["a", "b"]
        XCTAssertNil(CockpitView.courseDropEdge(entryIDs: ids, dragging: "a", over: "a"))
        XCTAssertNil(CockpitView.courseDropEdge(entryIDs: ids, dragging: "x", over: "a"))
        XCTAssertNil(CockpitView.courseDropEdge(entryIDs: ids, dragging: "a", over: "x"))
    }

    /// The line and the write agree: over every ordered pair, the edge the
    /// line draws is the side the dragged epic ends up on.
    func testTheCourseDropLineAgreesWithTheOrderTheWriteSends() {
        let ids = ["a", "b", "c", "d"]
        for dragged in ids {
            for target in ids where target != dragged {
                let moved = LibraryClient.reorderedEntryIds(ids, moving: dragged, onto: target)!
                let edge = CockpitView.courseDropEdge(entryIDs: ids, dragging: dragged, over: target)!
                let d = moved.firstIndex(of: dragged)!, t = moved.firstIndex(of: target)!
                XCTAssertEqual(edge == .below, d > t, "\(dragged) onto \(target)")
            }
        }
    }

    // MARK: - pullRequestWorkItemChips (issue_01M2P5D0D4EQEQX7BSRNFT5QGJ)

    private func courseEntry(
        _ id: String, title: String, key: String? = nil, pr: String? = nil, prRepo: String? = nil
    ) -> LibraryClient.CourseEntry {
        LibraryClient.CourseEntry(id: id, title: title, key: key, pr: pr, prRepo: prRepo)
    }

    private func workItem(
        _ id: String, title: String, type: String? = nil, parentId: String? = nil,
        key: String? = nil, pr: String? = nil, prRepo: String? = nil
    ) -> LibraryClient.WorkItemRecord {
        LibraryClient.WorkItemRecord(id: id, title: title, type: type, parentId: parentId,
                                     key: key, pr: pr, prRepo: prRepo)
    }

    /// An epic carrying its own PR joins on `repo#number`, the same pair
    /// `PRLadder.LadderResult.identityKey` is built from — the chip names
    /// the epic itself and a click would go to the Course.
    func testPullRequestWorkItemChipsJoinsAnEpicsOwnPR() {
        let items = [workItem("issue_EPIC", title: "The epic", type: "epic",
                               key: "E16", pr: "297", prRepo: "convivy/convivy-deck")]
        let chips = CockpitView.pullRequestWorkItemChips(allItems: items, course: nil)
        let chip = try? XCTUnwrap(chips["convivy/convivy-deck#297"])
        XCTAssertEqual(chip?.key, "E16")
        XCTAssertEqual(chip?.tooltip, "The epic")
        XCTAssertEqual(chip?.scrollTargetID, "issue_EPIC")
        XCTAssertEqual(chip?.isEpic, true)
    }

    /// A work item filed under an epic joins the same way, but the chip
    /// names the PARENT epic — hover and click both point at the epic, not
    /// at the child item carrying the PR. The epic's title comes from the
    /// same `/items` response, with no need for that epic's row to have
    /// been expanded this session (issue_01M3WPNJ1ESJVCVJ85FVNQHNKC).
    func testPullRequestWorkItemChipsJoinsAChildsPRToItsParentEpic() {
        let items = [
            workItem("issue_EPIC", title: "The epic", type: "epic"),
            workItem("issue_KID", title: "A filed item", parentId: "issue_EPIC",
                     key: "E9·4", pr: "298", prRepo: "convivy/convivy-deck"),
        ]
        let chips = CockpitView.pullRequestWorkItemChips(allItems: items, course: nil)
        let chip = try? XCTUnwrap(chips["convivy/convivy-deck#298"])
        XCTAssertEqual(chip?.key, "E9·4")
        XCTAssertEqual(chip?.tooltip, "The epic")
        XCTAssertEqual(chip?.scrollTargetID, "issue_EPIC")
        XCTAssertEqual(chip?.isEpic, true)
    }

    /// The parent epic falls outside the `/items` response (past its
    /// `limit=200`, say) but is still on the Course — the tooltip falls back
    /// to the Course's own copy of its title rather than going blank.
    func testPullRequestWorkItemChipsFallsBackToTheCourseForAnUnseenParentsTitle() {
        let course = LibraryClient.Course(id: "c", product: nil, title: nil, entries: [
            courseEntry("issue_EPIC", title: "The epic, from the Course"),
        ])
        let items = [workItem("issue_KID", title: "A filed item", parentId: "issue_EPIC",
                               key: "E9·4", pr: "298", prRepo: "convivy/convivy-deck")]
        let chips = CockpitView.pullRequestWorkItemChips(allItems: items, course: course)
        XCTAssertEqual(chips["convivy/convivy-deck#298"]?.tooltip, "The epic, from the Course")
    }

    /// A child whose parent is in neither the `/items` response nor the
    /// Course falls back to its own title rather than drawing a blank tooltip.
    func testPullRequestWorkItemChipsFallsBackToItsOwnTitleWhenTheParentIsNowhere() {
        let items = [workItem("issue_KID", title: "A filed item", parentId: "issue_GONE",
                               key: "E9·4", pr: "298", prRepo: "convivy/convivy-deck")]
        let chips = CockpitView.pullRequestWorkItemChips(allItems: items, course: nil)
        XCTAssertEqual(chips["convivy/convivy-deck#298"]?.tooltip, "A filed item")
    }

    /// A correction has no epic — the chip names its own title, and a click
    /// routes to the corrections queue (`isEpic: false`), not the Course.
    /// Nothing here depends on the correction still being in the queue: this
    /// is the same row whether it is open, `pr-open`, or already resolved
    /// (issue_01M3WPNJ1ESJVCVJ85FVNQHNKC) — the queue membership that used to
    /// gate a chip no longer does, and `CockpitModel.revealFromPullRequestChip`
    /// is what no-ops the click for a correction no longer in the queue.
    func testPullRequestWorkItemChipsJoinsACorrectionToItself() {
        let items = [workItem("issue_CQ", title: "A correction",
                               key: "CQ·63", pr: "299", prRepo: "convivy/convivy-deck")]
        let chips = CockpitView.pullRequestWorkItemChips(allItems: items, course: nil)
        let chip = try? XCTUnwrap(chips["convivy/convivy-deck#299"])
        XCTAssertEqual(chip?.key, "CQ·63")
        XCTAssertEqual(chip?.tooltip, "A correction")
        XCTAssertEqual(chip?.scrollTargetID, "issue_CQ")
        XCTAssertEqual(chip?.isEpic, false)
    }

    /// After the Library's one-home switch a correction's parent names its
    /// product's corrections queue. Its chip is still the correction's own:
    /// it must not draw as an epic child scrolling to an id on no list
    /// (issue_01M4J5T82F8GRQWYRZ71JE7CV7).
    func testPullRequestWorkItemChipsTreatsACorrectionsQueueParentAsACorrection() {
        let items = [workItem("issue_CQ", title: "A correction", parentId: "queue_A",
                               key: "CQ·63", pr: "299", prRepo: "convivy/convivy-deck")]
        let chips = CockpitView.pullRequestWorkItemChips(allItems: items, course: nil,
                                                         correctionsQueueIds: ["queue_A"])
        let chip = try? XCTUnwrap(chips["convivy/convivy-deck#299"])
        XCTAssertEqual(chip?.key, "CQ·63")
        XCTAssertEqual(chip?.tooltip, "A correction")
        XCTAssertEqual(chip?.scrollTargetID, "issue_CQ")
        XCTAssertEqual(chip?.isEpic, false)
    }

    /// A PR row with no matching work item draws no chip — normal, not a
    /// degrade, per the item's own spec.
    func testPullRequestWorkItemChipsHasNoEntryForAnUnmatchedPR() {
        let items = [workItem("issue_EPIC", title: "The epic", type: "epic",
                               key: "E16", pr: "297", prRepo: "convivy/convivy-deck")]
        let chips = CockpitView.pullRequestWorkItemChips(allItems: items, course: nil)
        XCTAssertNil(chips["convivy/convivy-deck#404"])
    }

    /// A failed fetch hands the join an empty list — no chip draws, and
    /// nothing throws (issue_01M3WPNJ1ESJVCVJ85FVNQHNKC: "a failed fetch
    /// draws nothing").
    func testPullRequestWorkItemChipsDrawsNothingForAnEmptyFetch() {
        let chips = CockpitView.pullRequestWorkItemChips(allItems: [], course: nil)
        XCTAssertTrue(chips.isEmpty)
    }

    /// An item missing `key`, `pr`, or `prRepo` joins nothing — a chip with
    /// no key would have nothing to draw, and a join with no repo or no
    /// parseable number has no identity to key on.
    func testPullRequestWorkItemChipsSkipsAnItemMissingAnyRequiredField() {
        let items = [
            workItem("no_key", title: "No key", pr: "1", prRepo: "o/r"),
            workItem("no_pr", title: "No PR", key: "E1"),
            workItem("bad_pr", title: "Unparseable PR", key: "E2", pr: "not-a-number", prRepo: "o/r"),
        ]
        let chips = CockpitView.pullRequestWorkItemChips(allItems: items, course: nil)
        XCTAssertTrue(chips.isEmpty)
    }
}
