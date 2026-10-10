import XCTest
@testable import Deck

/// The ribbon's "you are here" resolution. The drawing is not testable —
/// Deck has no view-level target (`deck/bead/deck` §6.5) — but which entry
/// counts as current is pure logic and is the part that was wrong.
final class WaypointRibbonTests: XCTestCase {

    private func entry(_ id: String, state: String?, resolution: String? = nil)
        -> LibraryClient.CourseEntry {
        LibraryClient.CourseEntry(id: id, title: "epic \(id)", type: "epic",
                                  state: state, maturity: nil, resolution: resolution)
    }

    private func titled(_ title: String, short: String? = nil) -> LibraryClient.CourseEntry {
        LibraryClient.CourseEntry(id: "x", title: title, shortDescription: short)
    }

    private func ribbon(_ entries: [LibraryClient.CourseEntry]) -> WaypointRibbon {
        WaypointRibbon(course: LibraryClient.Course(
            id: "c", product: "convivy-deck", title: "A course", entries: entries))
    }

    /// The case that sent this in as a bug: every entry filed and none
    /// claimed, which is the ORDINARY shape of a Course rather than an edge.
    /// Keyed on `isInProgress` alone, this drew no current waypoint at all.
    func testTheFirstUnfinishedEntryIsCurrentWhenNothingIsClaimed() {
        let r = ribbon([entry("a", state: "fixed", resolution: "fixed"),
                        entry("b", state: "open"),
                        entry("c", state: "open")])
        XCTAssertEqual(r.currentId, "b")
    }

    /// A claimed epic outranks the next-unfinished fallback — otherwise the
    /// route would point at something nobody is doing while work is underway.
    func testAClaimedEntryWinsOverTheFallback() {
        let r = ribbon([entry("a", state: "fixed", resolution: "fixed"),
                        entry("b", state: "open"),
                        entry("c", state: "claimed")])
        XCTAssertEqual(r.currentId, "c")
    }

    /// A finished route labels nothing rather than labelling its last stop,
    /// which would read as "you are here" on a place already passed.
    func testAFullyCompletedCourseHasNoCurrentWaypoint() {
        let r = ribbon([entry("a", state: "fixed", resolution: "fixed"),
                        entry("b", state: "wontfix", resolution: "wontfix")])
        XCTAssertNil(r.currentId)
    }

    /// A resolution marks an entry passed even when its state does not, so it
    /// must not be picked up as the next unfinished one.
    func testAResolvedEntryIsNotCurrentEvenWithANonTerminalState() {
        let r = ribbon([entry("a", state: "claimed", resolution: "duplicate"),
                        entry("b", state: "open")])
        XCTAssertEqual(r.currentId, "b")
    }

    func testNoCourseHasNoCurrentWaypoint() {
        XCTAssertNil(WaypointRibbon(course: nil).currentId)
    }

    func testAnEmptyCourseHasNoCurrentWaypoint() {
        XCTAssertNil(ribbon([]).currentId)
    }

    // MARK: - The label every waypoint now carries

    /// The point of the field: an authored short form wins over the title,
    /// and survives past the fallback budget. `labelCharacterLimit` governs
    /// how much of a TITLE to keep, not how much of a label somebody wrote to
    /// fit — so a value a little over budget is drawn as written.
    func testAServedShortDescriptionWinsAndSurvivesPastTheFallbackBudget() {
        XCTAssertEqual(WaypointRibbon.label(for: titled("A very long epic title indeed",
                                                        short: "Cockpit")),
                       "Cockpit")
        let overBudget = "A short description over the fallback budget"
        XCTAssertGreaterThan(overBudget.count, WaypointRibbon.labelCharacterLimit)
        XCTAssertLessThanOrEqual(overBudget.count, WaypointRibbon.servedLabelCeiling)
        XCTAssertEqual(WaypointRibbon.label(for: titled("t", short: overBudget)), overBudget)
    }

    /// **The clamp the security review asked for.** Nothing upstream bounds
    /// `short_description` (`issue_01M0XR0QSMKBSGBYD49CPTJ37E`), and this
    /// label renders at intrinsic width under `lineLimit(1)`, so an
    /// unclamped value is a hang of the operator's own frame rather than a
    /// wide label. Deck holds the ceiling itself.
    func testAServedShortDescriptionIsClampedAtTheCeiling() {
        let huge = String(repeating: "x", count: 10_000)
        let label = WaypointRibbon.label(for: titled("t", short: huge))
        XCTAssertLessThanOrEqual(label.count, WaypointRibbon.servedLabelCeiling + 1)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    /// A served value is held to a HIGHER ceiling than a truncated title, and
    /// the two limits must not collapse into one — that is the whole reason a
    /// label somebody authored is not cut at 25.
    func testTheServedCeilingSitsAboveTheFallbackBudget() {
        XCTAssertGreaterThan(WaypointRibbon.servedLabelCeiling,
                             WaypointRibbon.labelCharacterLimit)
    }

    /// **The reviewer's case.** A fixed word-boundary floor of 12, reused at
    /// the served ceiling of 50, let the walk-back discard 38 characters — so
    /// two short words followed by one long unbroken token collapsed to about
    /// the length raising the ceiling was meant to get past. The floor scales
    /// with the limit now, so this uses the room it was given.
    func testAHighCeilingIsNotCollapsedByTheWordBoundaryFloor() {
        let value = "Word one two " + String(repeating: "x", count: 60)
        let label = WaypointRibbon.condense(value, to: WaypointRibbon.servedLabelCeiling)
        XCTAssertGreaterThan(label.count, WaypointRibbon.labelCharacterLimit,
                             "collapsed to \(label.count) chars: \(label)")
        XCTAssertLessThanOrEqual(label.count, WaypointRibbon.servedLabelCeiling + 1)
    }

    /// The floor reproduces its tuned value exactly at the title budget, so
    /// scaling it moved the served path alone and left the fallback's
    /// behaviour untouched.
    func testTheWordBoundaryFloorIsUnchangedAtTheTitleBudget() {
        XCTAssertEqual(WaypointRibbon.minimumWordBoundary(for: WaypointRibbon.labelCharacterLimit), 12)
    }

    /// A tooltip is the escape hatch for a condensed label, so it is bounded
    /// far above any real title rather than left unbounded.
    func testTheTooltipIsBoundedWellAboveTheLabel() {
        XCTAssertGreaterThan(WaypointRibbon.tooltipCharacterLimit,
                             WaypointRibbon.servedLabelCeiling)
        let huge = String(repeating: "x", count: 10_000)
        XCTAssertLessThanOrEqual(
            WaypointRibbon.condense(huge, to: WaypointRibbon.tooltipCharacterLimit).count,
            WaypointRibbon.tooltipCharacterLimit + 1)
    }

    /// A limit of zero is the smallest legal one and must not trap — it is
    /// what a caller passing a computed bound could reach.
    func testAZeroLimitIsSafe() {
        XCTAssertEqual(WaypointRibbon.condense("anything", to: 0), "…")
        XCTAssertEqual(WaypointRibbon.condense("", to: 0), "")
    }

    /// A field the Library serves as empty or as whitespace is not a label,
    /// and drawing it would blank the waypoint. It falls back like an absent
    /// one — the same "field costs itself" posture `LibraryClient` takes.
    func testAnEmptyOrBlankShortDescriptionFallsBackToTheTitle() {
        XCTAssertEqual(WaypointRibbon.label(for: titled("Cockpit surface", short: "")),
                       "Cockpit surface")
        XCTAssertEqual(WaypointRibbon.label(for: titled("Cockpit surface", short: "   ")),
                       "Cockpit surface")
    }

    func testAShortTitleIsNotTouched() {
        XCTAssertEqual(WaypointRibbon.label(for: titled("Crew stats")), "Crew stats")
    }

    /// Exactly at the limit is under it — the guard is `>`, so a title that
    /// fits keeps its last character instead of losing it to an ellipsis.
    func testATitleExactlyAtTheLimitIsNotTruncated() {
        let exact = String(repeating: "a", count: WaypointRibbon.labelCharacterLimit)
        XCTAssertEqual(WaypointRibbon.label(for: titled(exact)), exact)
        XCTAssertEqual(WaypointRibbon.condense(exact).count, WaypointRibbon.labelCharacterLimit)
    }

    /// The cut walks back to a word boundary, so a label reads as an
    /// abbreviation rather than as a rendering fault.
    func testALongTitleIsCutAtAWordBoundary() {
        let label = WaypointRibbon.condense(
            "Deck's client side of the Deck-to-Keel wire interface")
        XCTAssertEqual(label, "Deck's client side of…")
        XCTAssertFalse(label.hasSuffix(" …"))
    }

    /// A first word longer than the limit has no boundary worth finding, and
    /// preferring one anyway would return a two-character label. It cuts hard.
    func testATitleWhoseFirstWordExceedsTheLimitIsCutHard() {
        let label = WaypointRibbon.condense("a Supercalifragilisticexpialidocious epic")
        XCTAssertEqual(label, "a Supercalifragilisticexp…")
        XCTAssertLessThanOrEqual(label.count, WaypointRibbon.labelCharacterLimit + 1)
    }

    /// Nothing the condenser returns exceeds the budget by more than the one
    /// character the ellipsis costs — checked across the real Course, since
    /// that is the corpus the limit was chosen against.
    func testNoCondensedLabelOverrunsTheBudget() {
        let titles = [
            "Deck runs for more than one operator — stop compiling one operator's environment into the binary",
            "The cockpit surface, and the panels Deck can already draw",
            "Deck's client side of the Deck-to-Keel wire interface — move the verbs off ssh argv, endpoint by endpoint",
            "Deck draws the project's plan and its corrections queue from the Chart House",
            "The cockpit shows where every PR actually stands, not just its review verdict",
            "Crew stats — a line per agent in flight, whatever individuated it",
            "A person merges or closes a PR from the cockpit, and the Keel performs it",
            "Deck gets a real release mechanism — signed, versioned builds a second operator installs",
            "A new installation is Convivy Builder, not Deck",
            "One session, several clients — and then several people in one session",
        ]
        for title in titles {
            let label = WaypointRibbon.condense(title)
            XCTAssertLessThanOrEqual(label.count, WaypointRibbon.labelCharacterLimit + 1,
                                     "overran on \(title)")
            XCTAssertFalse(label.isEmpty)
        }
    }

    /// Surrounding whitespace is not part of a label, and a title that is
    /// nothing but whitespace draws as nothing rather than as an ellipsis.
    func testWhitespaceIsTrimmedFromBothPaths() {
        XCTAssertEqual(WaypointRibbon.condense("  Crew stats  "), "Crew stats")
        XCTAssertEqual(WaypointRibbon.condense("   "), "")
    }

    /// Grapheme clusters rather than UTF-16 units, so an emoji costs one
    /// column's worth of budget rather than two — and the cut never lands
    /// inside a cluster, which would produce a replacement character.
    func testTheBudgetCountsGraphemeClusters() {
        let emoji = String(repeating: "🚀", count: 40)
        let label = WaypointRibbon.condense(emoji)
        XCTAssertLessThanOrEqual(label.count, WaypointRibbon.labelCharacterLimit + 1)
        XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertFalse(label.contains("\u{FFFD}"))
    }

    // MARK: - Scalar-bounding a title (condense alone is not a bound)

    /// **The bug.** `condense` cuts by `String.count` (Characters), and a
    /// grapheme cluster absorbs any number of combining scalars — so a title
    /// built as ONE cluster of thousands of marks reads as a single
    /// Character, passes `condense`'s limit untouched, and would reach
    /// AppKit whole. Both the visible label and the tooltip must run
    /// `SessionPaneView.displayable` first, which caps a cluster at 16
    /// scalars. Assert on `unicodeScalars.count`, not `count` — the Character
    /// count passes today even on the unfixed code and would not catch a
    /// regression back to it.
    func testALabelBuiltAsOneClusterOfCombiningMarksIsScalarBounded() {
        let pathological = "a" + String(repeating: "\u{0301}", count: 5_000)
        XCTAssertEqual(pathological.count, 1, "the attack's premise: one Character")

        let label = WaypointRibbon.label(for: titled(pathological))
        XCTAssertLessThan(label.unicodeScalars.count, 100,
                          "label carried \(label.unicodeScalars.count) scalars through condense alone")
    }

    /// The served-short-description path is the other branch through
    /// `label(for:)`, and needs the same bound.
    func testAServedShortDescriptionBuiltAsOneClusterIsScalarBounded() {
        let pathological = "a" + String(repeating: "\u{0301}", count: 5_000)
        let label = WaypointRibbon.label(for: titled("t", short: pathological))
        XCTAssertLessThan(label.unicodeScalars.count, 100)
    }

    /// The tooltip is the escape hatch for a condensed label and is bounded
    /// far more generously — but "generous" still has to mean scalars, not
    /// Characters, or the escape hatch is the unbounded one.
    func testATooltipBuiltAsOneClusterOfCombiningMarksIsScalarBounded() {
        let pathological = "a" + String(repeating: "\u{0301}", count: 5_000)
        let tooltip = WaypointRibbon.tooltip(titled(pathological))
        XCTAssertLessThan(tooltip.unicodeScalars.count, 100,
                          "tooltip carried \(tooltip.unicodeScalars.count) scalars through condense alone")
    }

    // MARK: - The heartbeat pulse

    private func working(_ text: String, stale: Bool?) -> SessionState.WorkingOn {
        SessionState.WorkingOn(text: text, age: nil, stale: stale, since: nil)
    }

    /// The pulse says the co is still working. A fresh recording is the whole
    /// signal — that is what makes it information rather than decoration.
    func testAFreshRecordingPulses() {
        XCTAssertTrue(WaypointRibbon.isWorkLive(working("chasing a bug", stale: false)))
    }

    /// Twenty minutes without confirmation and the co has gone quiet, which is
    /// exactly what a still dot should say.
    func testAStaleRecordingDoesNotPulse() {
        XCTAssertFalse(WaypointRibbon.isWorkLive(working("chasing a bug", stale: true)))
    }

    /// An older writer records no `stale` field at all. Absence says the
    /// producer did not compute it, NOT that the work stopped — the same
    /// reading `WorkingStrip.durationSuffix` takes with `stale != true`.
    func testAMissingStaleFieldCountsAsLive() {
        XCTAssertTrue(WaypointRibbon.isWorkLive(working("chasing a bug", stale: nil)))
    }

    /// Nothing recorded, nothing to pulse about.
    func testNoRecordingDoesNotPulse() {
        XCTAssertFalse(WaypointRibbon.isWorkLive(nil))
    }

    /// An empty or whitespace line draws no sentence above the conversation,
    /// so it must not drive a pulse below it either — the two surfaces read
    /// the same recording and have to agree about whether it says anything.
    func testAnEmptyOrBlankRecordingDoesNotPulse() {
        XCTAssertFalse(WaypointRibbon.isWorkLive(working("", stale: false)))
        XCTAssertFalse(WaypointRibbon.isWorkLive(working("   ", stale: false)))
    }

    /// **The two surfaces must agree about whether a recording says
    /// anything.** `PaneStatusBar` draws the sentence above the conversation
    /// and the ribbon's dot pulses below it, from ONE recording — so a value
    /// that draws no sentence must drive no pulse, and vice versa. They
    /// disagreed on whitespace-only text until the trim was added to both.
    func testTheStripAndThePulseAgreeOnWhetherARecordingSaysAnything() {
        for text in ["", "   ", "\n", " \t ", "chasing a bug", " padded "] {
            let recording = SessionState.WorkingOn(text: text, age: nil, stale: false, since: nil)
            let stripDraws = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            XCTAssertEqual(WaypointRibbon.isWorkLive(recording), stripDraws,
                           "disagreement on \(text.debugDescription)")
        }
    }
}
