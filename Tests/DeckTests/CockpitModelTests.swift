import Foundation
import XCTest
@testable import Deck

/// A thread-safe call counter for the `fetchChildItems` fakes below — a
/// plain `var` is not safe to mutate from the `@Sendable` closure the seam
/// requires, since `CockpitModel` runs it off the main actor
/// (`fetchedChildrenState`'s `Task.detached`).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private func epic(_ id: String, maturity: String?) -> LibraryClient.Epic {
    LibraryClient.Epic(id: id, state: "open", resolution: nil, createdAt: nil, resolvedAt: nil,
                       title: "Epic \(id)", maturity: maturity)
}

/// One PUT the model made: `(courseId, version, entries)`.
private struct OrderWrite: Equatable {
    let courseId: String
    let version: Int
    let entries: [String]
}

/// The Library's answer to a reorder sent with an out-of-date version. File
/// scope, since a main-actor static cannot be read from the model's
/// `@Sendable` write closure.
private let staleOrderRefusal = LibraryClient.FetchError.libraryRefused(status: 409, body: """
{"error":"version mismatch: this Course changed since you read it","your_version":4,"current_version":5,"current_entries":["c","b","a"]}
""")

/// `DispatchSemaphore.wait` is unavailable inside an async closure; a sync
/// function is not.
private func blockOn(_ semaphore: DispatchSemaphore) { semaphore.wait() }

private func courseEntry(_ id: String) -> LibraryClient.CourseEntry {
    LibraryClient.CourseEntry(id: id, title: "Epic \(id)")
}

/// An append-only list safe to write from the `@Sendable` closures the model
/// runs off the main actor.
private final class LockedList<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// `CockpitModel`'s guard clauses — the paths that must never reach the
/// network. `refresh` with a real target spawns a `SessionAgent.run` ssh
/// round trip the way `WorkingCopyStore.fetch` does everywhere else in this
/// suite; nothing here calls that path; see `LibraryClientTests` for the
/// pure argv/decode pieces that path is built from.
@MainActor
final class CockpitModelTests: XCTestCase {

    /// The no-project case: no crew selected, or a selected crew naming no
    /// Library product. Never reaches the network — the guard is what makes
    /// that true, checked here by asserting nothing gets left over from a
    /// previous state.
    func testRefreshWithNoTargetClearsTheCockpit() async {
        let model = CockpitModel()
        await model.refresh(target: nil, product: "convivy-deck")
        XCTAssertNil(model.course)
        XCTAssertNil(model.courseError)
        XCTAssertNil(model.queue)
        XCTAssertNil(model.queueError)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.proposedEpics.isEmpty)
        XCTAssertNil(model.proposedEpicsError)
        XCTAssertTrue(model.allWorkItems.isEmpty)
        XCTAssertNil(model.approvalRefusal)
    }

    /// The chip join's own read lands on `allWorkItems` alongside the Course
    /// and queue (issue_01M3WPNJ1ESJVCVJ85FVNQHNKC).
    func testFetchPopulatesAllWorkItems() async {
        let model = CockpitModel()
        model.fetchCourse = { _, _ in nil }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        model.fetchEpics = { _, _ in [] }
        model.fetchAllItems = { _, _ in
            [LibraryClient.WorkItemRecord(id: "issue_1", title: "An item", key: "CQ·1",
                                          pr: "9", prRepo: "o/r")]
        }
        await model.refresh(target: TestHost.unreachableTarget, product: "convivy-deck")
        XCTAssertEqual(model.allWorkItems.map(\.id), ["issue_1"])
    }

    /// **A FAILED CHIP-JOIN READ DRAWS NO CHIPS AND NEVER FAILS THE PANEL** —
    /// the item's own spec. `allWorkItems` clears to `[]` rather than keeping
    /// a stale read, and the Course, queue and proposals all still land.
    func testFetchClearsAllWorkItemsOnFailureWithoutFailingTheRest() async {
        let model = CockpitModel()
        let course = LibraryClient.Course(id: "c", product: nil, title: nil, entries: [])
        model.fetchCourse = { _, _ in course }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        model.fetchEpics = { _, _ in [] }
        model.fetchAllItems = { _, _ in
            throw LibraryClient.FetchError.unexpectedResponse("ssh: timed out")
        }
        await model.refresh(target: TestHost.unreachableTarget, product: "convivy-deck")
        XCTAssertTrue(model.allWorkItems.isEmpty)
        XCTAssertEqual(model.course?.id, "c")
        XCTAssertNil(model.courseError)
    }

    func testRefreshWithAnEmptyProductClearsTheCockpit() async {
        let model = CockpitModel()
        await model.refresh(target: TestHost.target, product: "")
        XCTAssertNil(model.course)
        XCTAssertNil(model.queue)
        XCTAssertTrue(model.proposedEpics.isEmpty)
    }

    func testRefreshWithNoProductAndNoTargetClearsTheCockpit() async {
        let model = CockpitModel()
        await model.refresh(target: nil, product: nil)
        XCTAssertNil(model.course)
        XCTAssertNil(model.queue)
        XCTAssertTrue(model.proposedEpics.isEmpty)
    }

    // MARK: - Reordering the Course

    /// A model that has read `reads[0]` as the Course, with each later Course
    /// read answering the next element (the last repeats), and every PUT
    /// recorded and answered by `write`.
    private func modelReordering(
        reads: [LibraryClient.Course],
        writes: LockedList<OrderWrite>,
        write: @escaping @Sendable () throws -> Void = {}
    ) async -> (CockpitModel, CallCounter) {
        let model = CockpitModel()
        let counter = CallCounter()
        model.fetchCourse = { _, _ in reads[min(counter.next() - 1, reads.count - 1)] }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        model.fetchEpics = { _, _ in [] }
        model.reorderCourse = { _, courseId, version, entries in
            writes.append(OrderWrite(courseId: courseId, version: version, entries: entries))
            try write()
        }
        await model.refresh(target: TestHost.unreachableTarget, product: "convivy-deck")
        return (model, counter)
    }

    private func course(_ served: [String], resolved: [String]? = nil, version: Int? = 4) -> LibraryClient.Course {
        LibraryClient.Course(
            id: "course_1", product: "convivy-deck", title: "T",
            entries: (resolved ?? served).map(courseEntry), version: version, servedEntryIds: served)
    }

    /// **THE HAZARD, END TO END.** The Library serves `ghost`, Deck cannot
    /// resolve it and does not draw it, and the drop still writes it back, in
    /// place, with the version the screen was drawn from.
    func testADropWritesTheServedArrayIncludingAnIdThatResolvesToNoItem() async {
        let writes = LockedList<OrderWrite>()
        let before = course(["a", "ghost", "b", "c"], resolved: ["a", "b", "c"])
        let after = course(["ghost", "b", "a", "c"], resolved: ["b", "a", "c"], version: 5)
        let (model, _) = await modelReordering(reads: [before, after], writes: writes)
        XCTAssertEqual(model.course?.entries.map(\.id), ["a", "b", "c"])

        await model.moveCourseEntry("a", onto: "b")

        XCTAssertEqual(writes.values, [OrderWrite(courseId: "course_1", version: 4,
                                                  entries: ["ghost", "b", "a", "c"])])
        XCTAssertNil(model.courseReorderRefusal)
        XCTAssertFalse(model.isReorderingCourse)
        XCTAssertEqual(model.course?.entries.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(model.course?.version, 5, "the next move must send the version the write produced")
    }

    /// A stale version is refused and the Library's order shown. The move is
    /// written once and never replayed onto the newer order.
    func testAStaleVersionIsRefusedNotRebasedAndTheLibrarysOrderIsShown() async {
        let writes = LockedList<OrderWrite>()
        let mine = course(["a", "b", "c"])
        let theirs = course(["c", "b", "a"], version: 5)
        let (model, reads) = await modelReordering(
            reads: [mine, theirs], writes: writes, write: { throw staleOrderRefusal })

        await model.moveCourseEntry("a", onto: "c")

        XCTAssertEqual(writes.values.count, 1, "no retry against the newer version")
        XCTAssertEqual(reads.next(), 3, "the Course was re-read exactly once after the refusal")
        XCTAssertEqual(model.course?.entries.map(\.id), ["c", "b", "a"], "the server's order, not the operator's move")
        XCTAssertEqual(model.course?.version, 5)
        let message = model.courseReorderRefusal ?? ""
        XCTAssertTrue(message.contains("Someone else reordered the Course"))
        XCTAssertTrue(message.contains("your move was not applied"))
        XCTAssertFalse(model.isReorderingCourse)
    }

    /// If the re-read after a stale refusal fails too, the panel must not be
    /// left showing the operator's unwritten move.
    func testAStaleRefusalWithAFailedReReadRestoresThePriorOrder() async {
        let writes = LockedList<OrderWrite>()
        let mine = course(["a", "b", "c"])
        let model = CockpitModel()
        let reads = CallCounter()
        model.fetchCourse = { _, _ in
            if reads.next() == 1 { return mine }
            throw LibraryClient.FetchError.unexpectedResponse("ssh: timed out")
        }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        model.fetchEpics = { _, _ in [] }
        model.reorderCourse = { _, id, version, entries in
            writes.append(OrderWrite(courseId: id, version: version, entries: entries))
            throw staleOrderRefusal
        }
        await model.refresh(target: TestHost.unreachableTarget, product: "convivy-deck")

        await model.moveCourseEntry("a", onto: "c")

        XCTAssertEqual(model.course?.entries.map(\.id), ["a", "b", "c"])
        XCTAssertNotNil(model.courseError)
        XCTAssertFalse(model.isReorderingCourse)
        // The prior order is what is drawn, so the message must not call it
        // the Library's.
        let message = model.courseReorderRefusal ?? ""
        XCTAssertTrue(message.contains("your move was not applied"))
        XCTAssertTrue(message.contains("could not be refreshed"))
        XCTAssertFalse(message.contains("now the Library's"))
    }

    /// A drop made while a write is out writes nothing, and the flag clears
    /// when the first write finishes, so the next drop goes through.
    func testADropWhileAWriteIsOutMakesNoSecondWrite() async {
        let writes = LockedList<OrderWrite>()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let (model, _) = await modelReordering(
            reads: [course(["a", "b", "c"])], writes: writes, write: {
                started.signal()
                release.wait()
            })

        let first = Task { await model.moveCourseEntry("a", onto: "b") }
        await Task.detached { blockOn(started) }.value
        XCTAssertTrue(model.isReorderingCourse)

        await model.moveCourseEntry("c", onto: "a")
        XCTAssertEqual(writes.values.count, 1, "the second drop must not write while the first is out")

        release.signal()
        await first.value
        XCTAssertFalse(model.isReorderingCourse)
        XCTAssertEqual(writes.values.count, 1)

        // The flag cleared on the success path; a later drop is accepted.
        release.signal()
        await model.moveCourseEntry("c", onto: "a")
        XCTAssertEqual(writes.values.count, 2)
        XCTAssertFalse(model.isReorderingCourse)
    }

    /// Any other refusal puts the rows back and says the Library's words,
    /// without a second read: nothing changed on the server.
    func testAnotherRefusalRestoresTheRowsAndSpeaksTheLibrarysWords() async {
        let writes = LockedList<OrderWrite>()
        let mine = course(["a", "b"])
        let (model, reads) = await modelReordering(reads: [mine], writes: writes, write: {
            throw LibraryClient.FetchError.libraryRefused(status: 400, body: """
            {"error":"no such work item, or none this identity may see","unknown":["ghost"]}
            """)
        })

        await model.moveCourseEntry("a", onto: "b")

        XCTAssertEqual(model.course?.entries.map(\.id), ["a", "b"])
        XCTAssertEqual(model.courseReorderRefusal, "no such work item, or none this identity may see (ghost)")
        XCTAssertEqual(reads.next(), 2, "no re-read: only the initial one happened")
        XCTAssertFalse(model.isReorderingCourse)
    }

    /// The refusal belongs to the attempt that earned it.
    func testTheRefusalClearsOnTheNextAttempt() async {
        let writes = LockedList<OrderWrite>()
        let attempts = CallCounter()
        let (model, _) = await modelReordering(reads: [course(["a", "b"])], writes: writes, write: {
            if attempts.next() == 1 {
                throw LibraryClient.FetchError.libraryRefused(status: 400, body: #"{"error":"nope"}"#)
            }
        })
        await model.moveCourseEntry("a", onto: "b")
        XCTAssertEqual(model.courseReorderRefusal, "nope")
        await model.moveCourseEntry("a", onto: "b")
        XCTAssertNil(model.courseReorderRefusal)
    }

    /// The cases that must write nothing: no version to check against, a drop
    /// on the row itself, and an id the Course does not hold.
    func testNothingIsWrittenWithoutAVersionOrForAMoveThatChangesNothing() async {
        let writes = LockedList<OrderWrite>()
        let (versionless, _) = await modelReordering(
            reads: [course(["a", "b"], version: nil)], writes: writes)
        await versionless.moveCourseEntry("a", onto: "b")
        XCTAssertTrue(writes.values.isEmpty)
        XCTAssertNotNil(versionless.courseReorderRefusal)
        XCTAssertEqual(versionless.course?.entries.map(\.id), ["a", "b"])

        let (model, _) = await modelReordering(reads: [course(["a", "b"])], writes: writes)
        await model.moveCourseEntry("a", onto: "a")
        await model.moveCourseEntry("stranger", onto: "b")
        await model.moveCourseEntry("a", onto: "stranger")
        XCTAssertTrue(writes.values.isEmpty)
        XCTAssertNil(model.courseReorderRefusal)
    }

    func testAMoveWithNoResolvedCourseDoesNothing() async {
        let model = CockpitModel()
        model.reorderCourse = { _, _, _, _ in XCTFail("the write must not run without a Course") }
        await model.moveCourseEntry("a", onto: "b")
        XCTAssertNil(model.courseReorderRefusal)
    }


    // MARK: - Proposals: approving an epic

    /// A model that has fetched for `convivy-deck`, with the Course and queue
    /// stubbed empty and `epics` supplying each successive epics read, so a
    /// test can tell the read before an Approve from the one after it.
    /// `approve` takes `(itemId, actingHuman)`, so a test can assert on the
    /// operator label the model sent as well as the id.
    private func modelFetching(
        epics: @escaping @Sendable (Int) -> [LibraryClient.Epic],
        approve: @escaping @Sendable (String, String) throws -> Void
    ) async -> CockpitModel {
        let model = CockpitModel()
        let reads = CallCounter()
        model.fetchCourse = { _, _ in nil }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        model.fetchEpics = { _, _ in epics(reads.next()) }
        model.approveEpic = { _, id, actingHuman in try approve(id, actingHuman) }
        await model.refresh(target: TestHost.unreachableTarget, product: "convivy-deck")
        return model
    }

    /// With no project ever resolved (`lastFetched` is nil), Approve is a
    /// guarded no-op that never reaches the network.
    func testApproveWithNoResolvedTargetDoesNothing() async {
        let model = CockpitModel()
        model.approveEpic = { _, _, _ in XCTFail("the write must not run without a target") }
        await model.approve(epic("issue_01ABC", maturity: "proposed"))
        XCTAssertNil(model.approvalRefusal)
        XCTAssertNil(model.approvingEpicID)
    }

    func testTheRegionHoldsTheProposedEpicsAndNothingElse() async {
        let model = await modelFetching(
            epics: { _ in [epic("a", maturity: "proposed"), epic("b", maturity: "approved"),
                           epic("c", maturity: nil)] },
            approve: { _, _ in })
        XCTAssertEqual(model.proposedEpics.map(\.id), ["a"])
        XCTAssertNil(model.proposedEpicsError)
    }

    /// A proposal row's `Open` control names the epic it sits on, and that is
    /// the id Approve writes for the same row, so a row cannot open one epic
    /// and approve another. The row itself is private view code, so this pins
    /// the id the row hands to `onSelectCorrection` (`proposalOpenTarget`)
    /// against the id the write receives.
    func testAProposalRowOpensTheSameEpicItApproves() async {
        let written = LockedList<String>()
        let model = await modelFetching(
            epics: { _ in [epic("a", maturity: "proposed"), epic("b", maturity: "proposed")] },
            approve: { id, _ in written.append(id) })
        let second = model.proposedEpics[1]
        XCTAssertEqual(CockpitView.proposalOpenTarget(second), "b")
        XCTAssertNotEqual(CockpitView.proposalOpenTarget(second), CockpitView.proposalOpenTarget(model.proposedEpics[0]))
        await model.approve(second)
        XCTAssertEqual(written.values, [CockpitView.proposalOpenTarget(second)])
    }

    /// The write goes to the epic that was clicked, and the row leaves on the
    /// refetch: the second epics read no longer lists it as proposed.
    func testApprovingWritesThatEpicAndTheRowLeavesOnTheRefetch() async {
        let written = LockedList<String>()
        let model = await modelFetching(
            epics: { read in
                read == 1 ? [epic("a", maturity: "proposed"), epic("b", maturity: "proposed")]
                          : [epic("a", maturity: "approved"), epic("b", maturity: "proposed")]
            },
            approve: { id, _ in written.append(id) })
        XCTAssertEqual(model.proposedEpics.map(\.id), ["a", "b"])
        await model.approve(model.proposedEpics[0])
        XCTAssertEqual(written.values, ["a"])
        XCTAssertEqual(model.proposedEpics.map(\.id), ["b"])
        XCTAssertNil(model.approvalRefusal)
        XCTAssertNil(model.approvingEpicID)
    }

    /// **THE ACTOR THIS EPIC EXISTS TO NAME.** The Library records whatever
    /// string reaches it as `acting_human` with no way to check it, so the
    /// model sending anything other than `DeckOperator.label()` — the macOS
    /// session Deck is running in — would misattribute every approval with
    /// no refusal to catch it. This is the one seam that can assert on it
    /// short of the live actor check in `LibraryClientTests`.
    func testApproveSendsDeckOperatorLabelAsActingHuman() async {
        let sent = LockedList<String>()
        let model = await modelFetching(
            epics: { _ in [epic("a", maturity: "proposed")] },
            approve: { _, actingHuman in sent.append(actingHuman) })
        await model.approve(model.proposedEpics[0])
        XCTAssertEqual(sent.values, [DeckOperator.label()])
    }

    /// An agent holds the epic, so the Library answers 409 and the row must
    /// say who has it and until when, and stay where it is. Silence here is
    /// the failure this test exists to catch.
    func testAHeldEpicSurfacesItsHolderAndStaysInTheRegion() async {
        let held = """
        {"error":"issue_01ABC is held by co-convivy-deck-pickup, not deck","reason":"held",
         "lease":{"holder":"co-convivy-deck-pickup","expires_at":"2026-09-20T22:41:38Z"}}
        """
        let model = await modelFetching(
            epics: { _ in [epic("issue_01ABC", maturity: "proposed")] },
            approve: { _, _ in throw LibraryClient.FetchError.libraryRefused(status: 409, body: held) })
        await model.approve(model.proposedEpics[0])
        let refusal = try? XCTUnwrap(model.approvalRefusal)
        XCTAssertEqual(refusal?.epicID, "issue_01ABC")
        XCTAssertTrue(refusal?.message.contains("co-convivy-deck-pickup") == true, refusal?.message ?? "nil")
        XCTAssertEqual(model.proposedEpics.map(\.id), ["issue_01ABC"])
        XCTAssertNil(model.approvingEpicID)
    }

    /// A specification/definition-of-done gap answers 400 with `missing`
    /// naming which. The epic stays in the region with its control — it is
    /// refused as it stands, never opened for an in-Deck edit.
    func testAMissingSpecificationSurfacesOnTheRowAndStaysInTheRegion() async {
        let gap = """
        {"error":"an epic cannot be approved while it has no specification or definition_of_done",
         "missing":["specification","definition_of_done"],
         "hint":"approving an epic is approving its specification"}
        """
        let model = await modelFetching(
            epics: { _ in [epic("issue_01ABC", maturity: "proposed")] },
            approve: { _, _ in throw LibraryClient.FetchError.libraryRefused(status: 400, body: gap) })
        await model.approve(model.proposedEpics[0])
        let refusal = try? XCTUnwrap(model.approvalRefusal)
        XCTAssertEqual(refusal?.epicID, "issue_01ABC")
        XCTAssertTrue(refusal?.message.contains("no specification") == true, refusal?.message ?? "nil")
        XCTAssertEqual(model.proposedEpics.map(\.id), ["issue_01ABC"], "refused as it stands, not removed")
    }

    /// A credential missing `epic.approve` or `course.write` answers 403
    /// naming the capability (`refusals.forbidden`) — distinct from the
    /// held-lease 409 and the spec-gap 400 above, and the row must say which
    /// one happened rather than a generic failure.
    func testAMissingCapabilitySurfacesOnTheRow() async {
        let model = await modelFetching(
            epics: { _ in [epic("issue_01ABC", maturity: "proposed")] },
            approve: { _, _ in
                throw LibraryClient.FetchError.libraryRefused(
                    status: 403, body: #"{"error":"this identity lacks 'epic.approve'"}"#)
            })
        await model.approve(model.proposedEpics[0])
        let refusal = try? XCTUnwrap(model.approvalRefusal)
        XCTAssertEqual(refusal?.epicID, "issue_01ABC")
        XCTAssertTrue(refusal?.message.contains("epic.approve") == true, refusal?.message ?? "nil")
        XCTAssertEqual(model.proposedEpics.map(\.id), ["issue_01ABC"])
    }

    /// A product with no live Course answers 409 `reason: "no_live_course"`,
    /// not the `held` shape — distinct from `testAHeldEpicSurfacesItsHolderAndStaysInTheRegion`,
    /// which is the other 409 this route can send.
    func testANoLiveCourseRefusalSurfacesOnTheRow() async {
        let noCourse = """
        {"error":"convivy-deck has no live Course, so issue_01ABC cannot be approved: approving an epic puts it on the Course",
         "reason":"no_live_course",
         "hint":"create the product's Course (POST /courses), then approve"}
        """
        let model = await modelFetching(
            epics: { _ in [epic("issue_01ABC", maturity: "proposed")] },
            approve: { _, _ in throw LibraryClient.FetchError.libraryRefused(status: 409, body: noCourse) })
        await model.approve(model.proposedEpics[0])
        let refusal = try? XCTUnwrap(model.approvalRefusal)
        XCTAssertEqual(refusal?.epicID, "issue_01ABC")
        XCTAssertTrue(refusal?.message.contains("no live Course") == true, refusal?.message ?? "nil")
        XCTAssertEqual(model.proposedEpics.map(\.id), ["issue_01ABC"])
    }

    /// The next attempt starts clean, so a stale refusal never sits beside a
    /// row that has since been approved.
    func testARefusalClearsWhenTheNextApproveSucceeds() async {
        let attempts = CallCounter()
        let model = await modelFetching(
            epics: { read in read < 2 ? [epic("a", maturity: "proposed")] : [] },
            approve: { _, _ in
                if attempts.next() == 1 {
                    throw LibraryClient.FetchError.libraryRefused(
                        status: 400, body: #"{"error":"an epic cannot be approved while it has no specification"}"#)
                }
            })
        await model.approve(model.proposedEpics[0])
        XCTAssertEqual(model.approvalRefusal?.message, "an epic cannot be approved while it has no specification")
        await model.approve(model.proposedEpics[0])
        XCTAssertNil(model.approvalRefusal)
        XCTAssertTrue(model.proposedEpics.isEmpty)
    }

    // MARK: - Expansion is per entry

    /// The bug this guards against: expansion tracked as a single flag
    /// (or keyed wrong) would open every row, or the wrong row, together.
    /// With no `lastFetched` set (no project ever resolved), `toggleExpansion`
    /// still records the open/closed state and never reaches the network —
    /// the guard that makes that true is exercised here the same way
    /// `testRefreshWithNoTargetClearsTheCockpit` exercises `refresh`'s.
    func testExpandingOneEntryDoesNotExpandAnother() {
        let model = CockpitModel()
        model.toggleExpansion(for: "issue_A")
        XCTAssertTrue(model.expandedEntries.contains("issue_A"))
        XCTAssertFalse(model.expandedEntries.contains("issue_B"))
    }

    func testTogglingAnExpandedEntryCollapsesIt() {
        let model = CockpitModel()
        model.toggleExpansion(for: "issue_A")
        model.toggleExpansion(for: "issue_A")
        XCTAssertFalse(model.expandedEntries.contains("issue_A"))
    }

    /// With no target ever resolved, opening a row must not attempt a
    /// fetch — `childrenByEntry` stays untouched rather than flipping to
    /// `.loading` for a request that can never complete.
    func testExpandingWithNoResolvedTargetRecordsNoChildrenState() {
        let model = CockpitModel()
        model.toggleExpansion(for: "issue_A")
        XCTAssertNil(model.childrenByEntry["issue_A"])
    }

    // MARK: - Manual refresh (issue_01M1HVTD8QXXZF9ADZGRWRFEYW)
    //
    // `TestHost.unreachableTarget` lets `refresh`/`fetch` run for real and
    // fail fast (a DNS lookup failure, not a live connect attempt) rather
    // than going through a seam — only `fetchChildItems` is faked here, so
    // `lastFetched` gets set by an actual (failing) round trip the same way
    // production traffic sets it.

    /// Polls until `entryId`'s children have settled out of `.loading` — the
    /// fetch `toggleExpansion` kicks off is an unstructured `Task`, so a test
    /// has to wait for it rather than assume it already landed.
    private func waitForChildren(_ model: CockpitModel, _ entryId: String) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let state = model.childrenByEntry[entryId], state != .loading { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The manual path's whole point: it must bypass `refresh`'s
    /// `key != lastFetched` guard and re-fetch an expanded row's children
    /// rather than leave `childrenByEntry`'s cached entry sitting there. A
    /// counting fake tells a genuine second fetch apart from a cache hit,
    /// since a stale cache and a real re-fetch of the same fixture would
    /// otherwise settle on an identical value either way.
    func testManualRefreshRefetchesChildrenForAnExpandedEntry() async {
        let model = CockpitModel()
        let counter = CallCounter()
        model.fetchChildItems = { _, _ in
            let call = counter.next()
            return [LibraryClient.ChildItem(id: "item_\(call)", title: "call \(call)")]
        }

        await model.refresh(target: TestHost.unreachableTarget, product: "convivy-deck")
        model.toggleExpansion(for: "issue_A")
        await waitForChildren(model, "issue_A")
        XCTAssertEqual(
            model.childrenByEntry["issue_A"],
            .loaded([LibraryClient.ChildItem(id: "item_1", title: "call 1")]))

        await model.manualRefresh()

        XCTAssertEqual(
            model.childrenByEntry["issue_A"],
            .loaded([LibraryClient.ChildItem(id: "item_2", title: "call 2")]),
            "a second, distinct fetch must have run — the first fixture value surviving would mean the cache was reused")
        XCTAssertTrue(model.expandedEntries.contains("issue_A"), "manual refresh must not collapse an open row")
    }

    /// The regression guard for the rule the issue calls out by name: the
    /// slow timer must keep leaving `childrenByEntry` alone. `fetch` is
    /// exactly what `init`'s `timerTask` calls on every tick, so this calls
    /// it directly rather than waiting on `CockpitModel.refreshInterval`
    /// (600s) — and would fail if `fetch` were ever changed to clear or
    /// re-populate the cache the way `manualRefresh` now deliberately does.
    /// A counting fake, as in the manual-refresh test above, is required
    /// here too: a constant fixture makes a stale cache and a genuine
    /// second fetch settle on the same value, so the assertion below would
    /// pass whether or not `fetch` actually re-fetched.
    func testFetchNeverTouchesTheChildrenCache() async {
        let model = CockpitModel()
        let counter = CallCounter()
        model.fetchChildItems = { _, _ in
            let call = counter.next()
            return [LibraryClient.ChildItem(id: "item_\(call)", title: "call \(call)")]
        }

        await model.refresh(target: TestHost.unreachableTarget, product: "convivy-deck")
        model.toggleExpansion(for: "issue_A")
        await waitForChildren(model, "issue_A")
        let before = model.childrenByEntry["issue_A"]
        XCTAssertEqual(
            before, .loaded([LibraryClient.ChildItem(id: "item_1", title: "call 1")]))

        await model.fetch(target: TestHost.unreachableTarget, product: "convivy-deck")

        XCTAssertEqual(
            model.childrenByEntry["issue_A"], before,
            "a second fetch would have produced item_2 — the cached first-call value must survive untouched")
        XCTAssertTrue(model.expandedEntries.contains("issue_A"))
    }

    // MARK: - revealFromPullRequestChip (issue_01M2P5D0D4EQEQX7BSRNFT5QGJ)

    private func modelForChipReveal(
        entries epicEntries: [LibraryClient.CourseEntry],
        queueItems: [LibraryClient.QueueItem] = []
    ) async -> CockpitModel {
        let model = CockpitModel()
        let course = LibraryClient.Course(id: "course_1", product: "convivy-deck", title: nil, entries: epicEntries)
        let queue = LibraryClient.CorrectionsQueue(
            items: queueItems, total: queueItems.count, truncated: false, childParents: [:])
        model.fetchCourse = { _, _ in course }
        model.fetchQueue = { _, _ in queue }
        await model.refresh(target: TestHost.unreachableTarget, product: "convivy-deck")
        return model
    }

    /// An epic chip's click sets the scroll id and counts it, with no
    /// change to the queue — the Course is self-contained, so it does not
    /// need the queue expanded first the way a correction might.
    func testRevealFromPRChipSetsTheScrollTargetForAnEpic() async {
        let model = await modelForChipReveal(entries: [courseEntry("issue_EPIC")])
        XCTAssertEqual(model.chipScrollCount, 0)
        model.revealFromPullRequestChip(itemID: "issue_EPIC", isEpic: true)
        XCTAssertEqual(model.chipScrollID, "issue_EPIC")
        XCTAssertEqual(model.chipScrollCount, 1)
        XCTAssertFalse(model.isQueueExpanded)
    }

    /// A correction chip's click expands the queue first — a correction
    /// outside the default five-row slice has no row to scroll to otherwise.
    func testRevealFromPRChipExpandsTheQueueForACorrection() async {
        let item = LibraryClient.QueueItem(id: "issue_CQ", title: "A correction", state: "pr-open")
        let model = await modelForChipReveal(entries: [], queueItems: [item])
        XCTAssertFalse(model.isQueueExpanded)
        model.revealFromPullRequestChip(itemID: "issue_CQ", isEpic: false)
        XCTAssertEqual(model.chipScrollID, "issue_CQ")
        XCTAssertEqual(model.chipScrollCount, 1)
        XCTAssertTrue(model.isQueueExpanded)
    }

    /// An id neither the Course nor the queue currently holds is a no-op —
    /// a stale click from before a refresh, or a join that resolved to an
    /// id this project no longer carries.
    func testRevealFromPRChipIsANoOpForAnUnknownID() async {
        let model = await modelForChipReveal(entries: [courseEntry("issue_EPIC")])
        model.revealFromPullRequestChip(itemID: "issue_GHOST", isEpic: true)
        XCTAssertNil(model.chipScrollID)
        XCTAssertEqual(model.chipScrollCount, 0)
    }

    /// Each click counts, including a repeat of the same id — the same
    /// "count, not id" guard `revealCount` already documents, so a second
    /// click on an already-scrolled-to chip still re-centers its row.
    func testRevealFromPRChipCountsEveryClickEvenForTheSameID() async {
        let model = await modelForChipReveal(entries: [courseEntry("issue_EPIC")])
        model.revealFromPullRequestChip(itemID: "issue_EPIC", isEpic: true)
        XCTAssertEqual(model.chipScrollCount, 1)
        model.revealFromPullRequestChip(itemID: "issue_EPIC", isEpic: true)
        XCTAssertEqual(model.chipScrollCount, 2)
    }

    // MARK: - isPullRequestsExpanded

    /// `togglePullRequestsExpansion`'s own name: flips, and flips back.
    func testTogglePullRequestsExpansionFlipsState() {
        let model = CockpitModel()
        XCTAssertFalse(model.isPullRequestsExpanded)
        model.togglePullRequestsExpansion()
        XCTAssertTrue(model.isPullRequestsExpanded)
        model.togglePullRequestsExpansion()
        XCTAssertFalse(model.isPullRequestsExpanded)
    }

    /// A project switch collapses the closed tier again — `isQueueExpanded`'s
    /// own reset, so an expanded panel from a prior crew doesn't carry into
    /// one that never asked to see it.
    func testRefreshResetsPullRequestsExpansion() async {
        let model = CockpitModel()
        model.fetchCourse = { _, _ in nil }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        model.togglePullRequestsExpansion()
        XCTAssertTrue(model.isPullRequestsExpanded)
        await model.refresh(target: TestHost.unreachableTarget, product: "convivy-deck")
        XCTAssertFalse(model.isPullRequestsExpanded)
    }
}
