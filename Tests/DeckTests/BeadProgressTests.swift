import XCTest
@testable import Deck

/// `BeadProgress.compute` — the arithmetic behind the rail's bead-progress
/// pane. Pure, so every case here is checked with no ssh round trip and no
/// view-level test target (Deck has none — `deck/bead/deck` §6.5).
final class BeadProgressTests: XCTestCase {

    private func epic(
        id: String = "epic_1", state: String? = "open", resolution: String? = nil,
        createdAt: String?, resolvedAt: String? = nil
    ) -> LibraryClient.Epic {
        LibraryClient.Epic(id: id, state: state, resolution: resolution,
                           createdAt: createdAt, resolvedAt: resolvedAt)
    }

    // MARK: - Revision date parsing

    func testParsesAWellFormedRevisionDate() {
        XCTAssertNotNil(BeadProgress.parseRevisionDate("2026-08-24"))
    }

    func testAnUnparseableRevisionDateReturnsNil() {
        XCTAssertNil(BeadProgress.parseRevisionDate("not-a-date"))
        XCTAssertNil(BeadProgress.parseRevisionDate("2026-13-45"))
        XCTAssertNil(BeadProgress.parseRevisionDate("2026/08/24"))
        XCTAssertNil(BeadProgress.parseRevisionDate(""))
    }

    // MARK: - compute: the top-level "never invent a denominator" guard

    /// Decision 3: a missing `last_reviewed` draws the title and no meter —
    /// `revision: nil` reaches `compute` when the bead document carried none.
    func testAMissingLastReviewedReturnsNilRatherThanAGuess() {
        let epics = [epic(createdAt: "2026-08-01T00:00:00Z")]
        XCTAssertNil(BeadProgress.compute(epics: epics, revision: nil))
    }

    /// Decision 3's other half: `last_reviewed` present but not a real
    /// date — same nil result, same reason.
    func testAnUnparseableLastReviewedReturnsNilRatherThanAGuess() {
        let epics = [epic(createdAt: "2026-08-01T00:00:00Z")]
        XCTAssertNil(BeadProgress.compute(epics: epics, revision: "garbage"))
    }

    func testZeroEpicsIsAZeroOverZeroResultRatherThanNil() {
        let result = BeadProgress.compute(epics: [], revision: "2026-08-24")
        XCTAssertEqual(result, BeadProgress.Result(closed: 0, total: 0))
    }

    /// `Result.fraction` must not trap dividing by a zero total.
    func testZeroTotalFractionIsZeroNotATrap() {
        let result = BeadProgress.Result(closed: 0, total: 0)
        XCTAssertEqual(result.fraction, 0)
    }

    // MARK: - compute: the required cases (deck-coder-put-the-project's-bead-in-the-rail spec)

    /// Decision 1: `last_reviewed` is a DATE, taken as 00:00:00 UTC that
    /// day, so an epic resolved ANY TIME on the revision day still counts
    /// as closed since it.
    func testAnEpicResolvedExactlyOnTheRevisionDateCountsAsClosed() {
        let epics = [epic(resolution: "fixed", createdAt: "2026-08-01T00:00:00Z",
                          resolvedAt: "2026-08-24T23:59:59Z")]
        let result = BeadProgress.compute(epics: epics, revision: "2026-08-24")
        XCTAssertEqual(result, BeadProgress.Result(closed: 1, total: 1))
    }

    /// An epic both created and resolved after the revision counts in BOTH
    /// numbers — work the plan took on and finished, per the spec's own
    /// example.
    func testAnEpicCreatedAndResolvedBothAfterCountsInBothNumbers() {
        let epics = [epic(resolution: "fixed", createdAt: "2026-08-25T00:00:00Z",
                          resolvedAt: "2026-08-26T00:00:00Z")]
        let result = BeadProgress.compute(epics: epics, revision: "2026-08-24")
        XCTAssertEqual(result, BeadProgress.Result(closed: 1, total: 1))
    }

    /// An epic resolved BEFORE the revision is settled work the bead
    /// already accounted for last time it was reviewed — neither number.
    func testAnEpicResolvedBeforeTheRevisionCountsInNeitherNumber() {
        let epics = [epic(resolution: "fixed", createdAt: "2026-08-01T00:00:00Z",
                          resolvedAt: "2026-08-10T00:00:00Z")]
        let result = BeadProgress.compute(epics: epics, revision: "2026-08-24")
        XCTAssertEqual(result, BeadProgress.Result(closed: 0, total: 0))
    }

    /// Decision 2: any resolution counts as closed, including `redirected`
    /// — Deck's own Course carries one today.
    func testARedirectedEpicCountsAsClosed() {
        let epics = [epic(resolution: "redirected", createdAt: "2026-08-01T00:00:00Z",
                          resolvedAt: "2026-08-25T00:00:00Z")]
        let result = BeadProgress.compute(epics: epics, revision: "2026-08-24")
        XCTAssertEqual(result, BeadProgress.Result(closed: 1, total: 1))
    }

    /// n of n: every epic closed since the revision, not a divide-by-zero
    /// and not a fraction that fails to read as complete.
    func testEveryEpicClosedIsNOfN() {
        let epics = [
            epic(id: "epic_1", resolution: "fixed", createdAt: "2026-08-01T00:00:00Z",
                resolvedAt: "2026-08-25T00:00:00Z"),
            epic(id: "epic_2", resolution: "wontfix", createdAt: "2026-08-02T00:00:00Z",
                resolvedAt: "2026-08-26T00:00:00Z"),
        ]
        let result = BeadProgress.compute(epics: epics, revision: "2026-08-24")
        XCTAssertEqual(result, BeadProgress.Result(closed: 2, total: 2))
        XCTAssertEqual(result?.fraction, 1.0)
    }

    // MARK: - compute: still-open work

    /// An epic filed before the revision and never resolved is part of the
    /// plan the revision listed — counted in the denominator, not the
    /// numerator.
    func testAnEpicStillOpenSinceBeforeTheRevisionCountsOnlyInTheDenominator() {
        let epics = [epic(state: "open", createdAt: "2026-08-01T00:00:00Z", resolvedAt: nil)]
        let result = BeadProgress.compute(epics: epics, revision: "2026-08-24")
        XCTAssertEqual(result, BeadProgress.Result(closed: 0, total: 1))
    }

    /// An epic filed after the revision and still open is work the plan
    /// took on since — also denominator-only.
    func testAnEpicOpenedAfterTheRevisionCountsOnlyInTheDenominator() {
        let epics = [epic(state: "open", createdAt: "2026-08-25T00:00:00Z", resolvedAt: nil)]
        let result = BeadProgress.compute(epics: epics, revision: "2026-08-24")
        XCTAssertEqual(result, BeadProgress.Result(closed: 0, total: 1))
    }

    // MARK: - compute: degraded epic-level fields

    /// An epic with no parseable `created_at` defaults to "created since
    /// the revision" — a data gap adds it to current work rather than
    /// silently dropping it from the plan.
    func testAnEpicWithNoCreatedAtDefaultsToCountedInTheDenominator() {
        let epics = [epic(state: "open", createdAt: nil)]
        let result = BeadProgress.compute(epics: epics, revision: "2026-08-24")
        XCTAssertEqual(result, BeadProgress.Result(closed: 0, total: 1))
    }

    /// A resolved epic with no parseable `resolved_at` cannot be confirmed
    /// closed since the revision, so it costs only the numerator — it still
    /// counts as outstanding work in the denominator.
    func testAResolvedEpicWithNoResolvedAtIsNotCountedClosed() {
        let epics = [epic(resolution: "fixed", createdAt: "2026-08-01T00:00:00Z", resolvedAt: nil)]
        let result = BeadProgress.compute(epics: epics, revision: "2026-08-24")
        XCTAssertEqual(result, BeadProgress.Result(closed: 0, total: 1))
    }

    // MARK: - Result

    func testFractionLabelReadsAsAFractionOfEpics() {
        XCTAssertEqual(BeadProgress.Result(closed: 3, total: 12).fractionLabel, "3 of 12 epics")
    }
}
