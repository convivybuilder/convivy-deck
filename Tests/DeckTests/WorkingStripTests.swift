import XCTest
@testable import Deck

/// The co's working-on sentence, decoding aside (see `SessionAgentTests`'s
/// `working_on` section). Drawn by `PaneStatusBar`, above the conversation.
/// What is tested here is the two consumer rules that are the point of the
/// feature: a stale line is never shown without its age, and a missing
/// `since` never grows one from `age`. Deck has no view-level test target, so
/// these pin the logic the view draws from rather than the pixels.
final class WorkingStripTests: XCTestCase {

    private func workingOn(text: String = "chasing the pagination bug",
                            age: Double? = nil, stale: Bool? = nil,
                            since: Double? = nil) -> SessionState.WorkingOn {
        SessionState.WorkingOn(text: text, age: age, stale: stale, since: since)
    }

    private func dispatch(text: String = "rebase PR #318",
                           derivedFrom: String = SessionState.WorkingOnDerived.dispatchTaskSource,
                           age: Double? = nil, since: Double? = nil) -> SessionState.WorkingOnDerived {
        SessionState.WorkingOnDerived(text: text, derivedFrom: derivedFrom, age: age, since: since)
    }

    // MARK: - CQ-167: the strip's fallback to the last dispatch

    /// A fresh authored line wins outright — the dispatch record is never
    /// even consulted while the co's own line is current.
    func testFreshAuthoredWinsOverADispatchRecord() {
        let presentation = WorkingStrip.presentation(
            workingOn: workingOn(stale: false), workingOnDerived: dispatch())
        XCTAssertEqual(presentation, .authored(workingOn(stale: false)))
    }

    /// A stale authored line with no dispatch record at all still draws —
    /// with its age, the same as it did before CQ-167. Dropping it was the
    /// regression this precedence fixes: the contract's `working_on` section
    /// requires a stale line be drawn, never silently dropped.
    func testStaleAuthoredWithNoDispatchRecordShowsTheAuthoredLine() {
        let presentation = WorkingStrip.presentation(
            workingOn: workingOn(age: 10_800, stale: true), workingOnDerived: nil)
        XCTAssertEqual(presentation, .authored(workingOn(age: 10_800, stale: true)))
    }

    /// A stale authored line beside an OLDER dispatch record keeps showing
    /// the authored line — the dispatch only replaces it when it is the
    /// newer of the two readings.
    func testStaleAuthoredWithAnOlderDispatchRecordShowsTheAuthoredLine() {
        let presentation = WorkingStrip.presentation(
            workingOn: workingOn(age: 300, stale: true),
            workingOnDerived: dispatch(age: 9_000))
        XCTAssertEqual(presentation, .authored(workingOn(age: 300, stale: true)))
    }

    /// A stale authored line beside a NEWER dispatch record is replaced by
    /// it, labelled as such.
    func testStaleAuthoredWithANewerDispatchRecordShowsTheDispatch() {
        let presentation = WorkingStrip.presentation(
            workingOn: workingOn(age: 9_000, stale: true),
            workingOnDerived: dispatch(age: 300))
        XCTAssertEqual(presentation, .dispatch(dispatch(age: 300)))
    }

    /// No authored line at all, but a dispatch record — the dispatch shows:
    /// there is no older authored age for it to lose to.
    func testAbsentAuthoredPlusADispatchRecordShowsTheDispatch() {
        let presentation = WorkingStrip.presentation(workingOn: nil, workingOnDerived: dispatch())
        XCTAssertEqual(presentation, .dispatch(dispatch()))
    }

    /// A stale authored line with only a `UserPromptSubmit` record behind
    /// it keeps showing the authored line — the operator's own latest
    /// message (often what that record holds, such as a
    /// `<task-notification>` envelope) is never echoed back; the session
    /// window already shows it, so it is not a usable dispatch at all.
    func testStaleAuthoredPlusAPromptRecordShowsTheAuthoredLine() {
        let presentation = WorkingStrip.presentation(
            workingOn: workingOn(age: 10_800, stale: true),
            workingOnDerived: dispatch(
                text: "<task-notification>do the thing</task-notification>",
                derivedFrom: "UserPromptSubmit", age: 5))
        XCTAssertEqual(presentation, .authored(workingOn(age: 10_800, stale: true)))
    }

    /// Neither reading has anything to show: the slot draws nothing.
    func testNeitherReadingShowsNothing() {
        XCTAssertEqual(WorkingStrip.presentation(workingOn: nil, workingOnDerived: nil), .none)
    }

    // MARK: - The two consumer rules

    /// A stale recording is drawn WITH its age. Never the text alone — a
    /// sentence from hours ago shown as current is the exact failure this
    /// field exists to prevent.
    func testStaleDrawsTheAgeNotTheTextAlone() {
        let suffix = WorkingStrip.durationSuffix(
            for: workingOn(age: 10_800, stale: true, since: 10_800))
        XCTAssertNotNil(suffix)
        XCTAssertTrue(suffix!.contains("3h"), suffix!)
        XCTAssertTrue(suffix!.contains("ago"), suffix!)
    }

    /// The same age, not stale, draws `since` instead of `age`'s "ago" form
    /// — the boundary between the two branches is `stale`, not the numbers.
    func testNotStaleDrawsSinceRatherThanAge() {
        let suffix = WorkingStrip.durationSuffix(
            for: workingOn(age: 1_201, stale: false, since: 600))
        XCTAssertEqual(suffix, "· 10m")
    }

    /// `since` absent must never fall back to `age` — a recording from an
    /// older writer carries no start time, and reporting one derived from
    /// `age` would show hours-old work as freshly started.
    func testSinceNilProducesNoDurationEvenWithAgePresent() {
        XCTAssertNil(WorkingStrip.durationSuffix(
            for: workingOn(age: 45, stale: false, since: nil)))
    }

    /// Nothing recorded (`stale` and `since` both nil, the shape a state
    /// with no timestamps at all decodes to) draws no duration either — the
    /// text stands alone rather than growing a suffix from nowhere.
    func testNoTimestampsAtAllProducesNoDuration() {
        XCTAssertNil(WorkingStrip.durationSuffix(for: workingOn()))
    }

    // MARK: - The dispatch fallback row's own duration

    /// `since` is already a duration — no `now` to compute against, unlike
    /// `AgentRun.startedAt` — and it is formatted exactly as the authored
    /// row's own `since` branch is, with no "ago".
    func testDispatchDurationSuffixDrawsSinceAsADuration() {
        XCTAssertEqual(WorkingStrip.dispatchDurationSuffix(for: dispatch(since: 600)), "· 10m")
    }

    /// `since` absent must never fall back to `age` — the same rule
    /// `workingOn.since` follows, for the same reason.
    func testDispatchDurationSuffixNeverFallsBackToAge() {
        XCTAssertNil(WorkingStrip.dispatchDurationSuffix(for: dispatch(age: 45, since: nil)))
    }

    // MARK: - The dispatch fallback row's own text

    /// A parenthesised id goes with its parentheses, and the human key
    /// beside it stays.
    func testDispatchDisplayTextDropsAParenthesisedItemId() {
        XCTAssertEqual(
            WorkingStrip.dispatchDisplayText(
                "Implement CQ·169 (issue_01M5CRQ8GYVHDBXEEH0F9T0ZJB) in convivy-deck, the client"),
            "Implement CQ·169 in convivy-deck, the client")
    }

    /// Bare ids of both kinds go, with no doubled space or stray space
    /// before punctuation left behind.
    func testDispatchDisplayTextDropsBareIssueAndCorrectionQueueIds() {
        XCTAssertEqual(
            WorkingStrip.dispatchDisplayText(
                "Fix work item issue_01M5CZ5JF1X2W56FFMAQ1Y6E7D, under cq_01M4K1QD1RK67F691FG0NXBW67."),
            "Fix work item, under.")
    }

    /// Text with no id is drawn exactly as the sanitiser leaves it.
    func testDispatchDisplayTextLeavesTextWithoutIdsAlone() {
        let text = "Review convivy-deck#380 (CQ·169, child of epic E23)"
        XCTAssertEqual(WorkingStrip.dispatchDisplayText(text), CockpitView.sanitizedAgentField(text))
    }

    /// A word that only resembles an id (wrong length, lower case) stays.
    func testDispatchDisplayTextKeepsNearMisses() {
        XCTAssertEqual(WorkingStrip.dispatchDisplayText("see issue_123 and issue_01m5crq8gyvhdbxeeh0f9t0zjb"),
                       "see issue_123 and issue_01m5crq8gyvhdbxeeh0f9t0zjb")
    }

    /// Removing an id splices the clusters either side of it. Fifteen marks
    /// on a base, then an id whose last letter carries fifteen more: each
    /// cluster is within the bound before the cut, and the marks join the
    /// base's cluster after it unless the result is bounded again.
    func testDispatchDisplayTextBoundsAClusterJoinedByRemovingAnId() {
        let marks = String(repeating: "\u{0301}", count: 15)
        let input = "e" + marks + "issue_01M5CRQ8GYVHDBXEEH0F9T0ZJB" + marks + " tail"
        let out = WorkingStrip.dispatchDisplayText(input)
        for cluster in out {
            XCTAssertLessThanOrEqual(cluster.unicodeScalars.count, SessionPaneView.maxScalarsPerCluster,
                                     "a cluster of \(cluster.unicodeScalars.count) scalars survived")
        }
        XCTAssertTrue(out.hasSuffix(" tail"), out)
    }

    // MARK: - Duration formatting at a few magnitudes

    func testDurationLabelAtSecondsMinutesAndHours() {
        XCTAssertEqual(WorkingStrip.durationLabel(0), "0s")
        XCTAssertEqual(WorkingStrip.durationLabel(45), "45s")
        XCTAssertEqual(WorkingStrip.durationLabel(89), "89s")
        XCTAssertEqual(WorkingStrip.durationLabel(90), "2m")
        XCTAssertEqual(WorkingStrip.durationLabel(600), "10m")
        XCTAssertEqual(WorkingStrip.durationLabel(5_400), "2h")
        XCTAssertEqual(WorkingStrip.durationLabel(10_800), "3h")
    }

    /// A value beyond a week tells a reader nothing more than "a week ago"
    /// would, and clamping keeps the label off an absurd number rather than
    /// a crash — the same posture `SessionPaneView.quietLabel` takes on
    /// `lastEventAge`.
    func testDurationLabelClampsPastAWeek() {
        XCTAssertEqual(WorkingStrip.durationLabel(30 * 86_400),
                       WorkingStrip.durationLabel(7 * 86_400))
        XCTAssertEqual(WorkingStrip.durationLabel(-5), "0s")
    }
}
