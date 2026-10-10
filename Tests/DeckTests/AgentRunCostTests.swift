import XCTest
@testable import Deck

/// The in-flight cost on a dispatched run: how it decodes, and how it draws.
///
/// The rule under test is the operator's condition for serving a list-price figure at
/// all (2026-09-15): an estimate never draws as though it were metered spend.
final class AgentRunCostTests: XCTestCase {

    private func decodeRun(_ json: String) throws -> SessionState.AgentRun {
        let state = SessionState.decode(Data(json.utf8), fallbackSession: "x")
        return try XCTUnwrap(state.agentRuns?.first)
    }

    private func run(_ usd: Double, _ wire: String) throws -> SessionState.AgentRun {
        try decodeRun("""
        {"agent_runs": [{"run_id": "run-1", "agent": "platform-coder",
                         "usd": \(usd), "cost_source": "\(wire)",
                         "written_at": "2026-09-16T04:23:33Z"}]}
        """)
    }

    // MARK: - Decode

    /// The live shape, taken from a real payload on 2026-09-16.
    func testDecodesTheServedShape() throws {
        let decoded = try run(1.162, "estimate_fallback")
        let cost = try XCTUnwrap(decoded.cost)
        XCTAssertEqual(cost.usd, 1.162)
        XCTAssertEqual(cost.source, .estimate)
        XCTAssertEqual(cost.writtenAt, "2026-09-16T04:23:33Z")
    }

    func testMeteredSpendDecodesAsExact() throws {
        let cost = try XCTUnwrap(try run(4, "gateway_spend_log").cost)
        XCTAssertEqual(cost.source, .metered)
        XCTAssertTrue(cost.source.isExact)
    }

    /// A figure with no source is DROPPED rather than drawn bare — the
    /// client half of the producer's own pairing rule, so no path can carry
    /// an amount without its marking.
    func testAnAmountWithoutASourceIsDropped() throws {
        let decoded = try decodeRun(#"{"agent_runs": [{"agent": "a", "usd": 2.5}]}"#)
        XCTAssertNil(decoded.cost)
        let empty = try decodeRun(#"{"agent_runs": [{"agent": "a", "usd": 2.5, "cost_source": ""}]}"#)
        XCTAssertNil(empty.cost)
    }

    /// A row saying "-$4.00" is worse than a row saying nothing.
    func testANegativeOrUnreadableAmountIsDropped() throws {
        XCTAssertNil(try run(-4, "gateway_spend_log").cost)
        let text = try decodeRun(#"{"agent_runs": [{"agent": "a", "usd": "lots", "cost_source": "gateway_spend_log"}]}"#)
        XCTAssertNil(text.cost)
    }

    /// The fields the panel already drew keep working when no cost arrives —
    /// a record missing a field demotes that field, never the row.
    func testARunWithNoCostStillDecodes() throws {
        let decoded = try decodeRun(#"{"agent_runs": [{"agent": "a", "model": "claude-opus-5"}]}"#)
        XCTAssertEqual(decoded.agent, "a")
        XCTAssertNil(decoded.cost)
    }

    // MARK: - Drawing

    func testMeteredDrawsPlainAndEstimateDrawsMarked() {
        XCTAssertEqual(CockpitView.agentRunCostLabel(.init(usd: 1.162, source: .metered)), "$1.16")
        XCTAssertEqual(CockpitView.agentRunCostLabel(.init(usd: 1.162, source: .estimate)), "≈$1.16")
    }

    /// An unknown provenance is not a metered one, so it draws approximate.
    func testAnUnrecognisedSourceDrawsMarked() {
        let cost = SessionState.AgentRun.RunCost(usd: 9, source: .unrecognized("ledger_v2"))
        XCTAssertEqual(CockpitView.agentRunCostLabel(cost), "≈$9.00")
        XCTAssertFalse(cost.source.isExact)
    }

    func testTheRowCarriesCostAfterModelAndRuntime() {
        let started = Date().timeIntervalSince1970 - 120
        let run = SessionState.AgentRun(runId: "r", agent: "a", task: nil, startedAt: started,
                                        repo: nil, model: "claude-opus-5",
                                        cost: .init(usd: 1.162, source: .estimate))
        let trailing = CockpitView.agentRunTrailingMetadata(run, now: Date())
        XCTAssertEqual(trailing?.hasSuffix("≈$1.16"), true)
        XCTAssertEqual(trailing?.contains(" · "), true)
    }

    // MARK: - `Cost read:` in the reader's own zone

    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    private let posix = Locale(identifier: "en_US_POSIX")
    /// 2026-09-16T06:30:00Z, which is 2026-09-16 12:00 in `kolkata`.
    private let now = Date(timeIntervalSince1970: 1_789_540_200)

    /// The tooltip says in words what the glyph says in one character, and
    /// `written_at` draws in the reader's own zone rather than the raw UTC
    /// instant the mini served — same day as `now` carries a clock reading
    /// alone.
    func testTheTooltipNamesTheKindAndWhenItWasRead() {
        let estimate = SessionState.AgentRun.RunCost(usd: 1.162, source: .estimate,
                                                     writtenAt: "2026-09-16T04:23:33Z")
        let lines = CockpitView.agentRunCostHelpLines(estimate, now: now, timeZone: kolkata, locale: posix)
        XCTAssertEqual(lines.first, "Cost: ≈$1.16 — list-price estimate, not the billed total")
        XCTAssertEqual(lines.last, "Cost read: 9:53\u{202F}AM")
        let metered = CockpitView.agentRunCostHelpLines(.init(usd: 4, source: .metered))
        XCTAssertEqual(metered, ["Cost: $4.00 — metered spend"])
    }

    /// A `written_at` on an earlier local day than `now` carries the date
    /// too, the same today/earlier-day rule `expiryText` uses for a lease
    /// expiry.
    func testCostReadOnAnEarlierDayCarriesTheDate() {
        let cost = SessionState.AgentRun.RunCost(usd: 1, source: .metered,
                                                 writtenAt: "2026-09-14T20:00:00Z")
        let lines = CockpitView.agentRunCostHelpLines(cost, now: now, timeZone: kolkata, locale: posix)
        XCTAssertEqual(lines.last, "Cost read: Sep 15 at 1:30\u{202F}AM")
    }

    /// A `written_at` the client cannot parse draws unchanged rather than
    /// being dropped or crashing — a format drift on the mini's side costs
    /// only the pretty time.
    func testUnparseableCostReadDrawsTheRawString() {
        let cost = SessionState.AgentRun.RunCost(usd: 1, source: .metered, writtenAt: "not-a-date")
        let lines = CockpitView.agentRunCostHelpLines(cost, now: now, timeZone: kolkata, locale: posix)
        XCTAssertEqual(lines.last, "Cost read: not-a-date")
    }
}
