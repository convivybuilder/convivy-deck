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
