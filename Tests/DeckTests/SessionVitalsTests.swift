import XCTest
@testable import Deck

/// The status area, carried into a frame that is not the terminal.
///
/// The operator asked for these because living in the session pane meant losing them: the
/// context gauge, which subscription is billed, whether the phone can reach the
/// session, what is running under it and which model is answering were all one
/// terminal away.
///
/// WHAT THESE PIN. Every field is optional and every one of them means it. A
/// session that has not taken a turn has no reading at all, and any single field
/// can leave in a Claude Code release — so the assertions are mostly about what
/// happens when something is missing, because a number invented to fill a gap
/// would be indistinguishable from a measured one.
final class SessionVitalsTests: XCTestCase {

    private func decode(_ json: String) -> SessionState {
        SessionState.decode(Data(json.utf8), fallbackSession: "deck")
    }

    /// Captured 2026-07-24 from `session-agent state picker2`, a live co session.
    func testDecodesRealVitalsFromTheMini() {
        let state = decode("""
            {"state":"idle","vitals":{"age":16.76,"agents":[],"ctx_pct":4,
             "ctx_tokens":41965,"ctx_window":1000000,"fleet_wide":false,
             "model":"Opus 4.8 (1M context)",
             "remote_control":{"name":"convivy-deck-e2","on":true},
             "stale":false,"sub":"nyh (example-account)","tier":"ok"}}
            """)
        let vitals = state.vitals
        XCTAssertEqual(vitals?.model, "Opus 4.8 (1M context)")
        XCTAssertEqual(vitals?.contextTokens, 41965)
        XCTAssertEqual(vitals?.contextWindow, 1_000_000)
        XCTAssertEqual(vitals?.tier, .ok)
        XCTAssertEqual(vitals?.sub, "nyh (example-account)")
        XCTAssertEqual(vitals?.remoteControlOn, true)
        XCTAssertEqual(vitals?.remoteName, "convivy-deck-e2")
        XCTAssertEqual(vitals?.stale, false)
    }

    /// A state from a mini that predates the block, which is every mini until
    /// this ships. Absent is absent; the pane draws no badges and everything
    /// else about the session still decodes.
    func testNoVitalsBlockIsNilRatherThanEmptyNumbers() {
        let state = decode(#"{"state":"working","last_event":"PreToolUse"}"#)
        XCTAssertNil(state.vitals)
        XCTAssertEqual(state.phase, .working, "the rest of the state still reads")
    }

    /// The ordinary case for a session that has not taken a turn since the
    /// status line started recording. Remote control and the running agents
    /// resolve without a reading, so there is still something true to show.
    func testAVitalsBlockWithNoReadingStillCarriesWhatItHas() {
        let state = decode("""
            {"state":"idle","vitals":{"agents":["deck-reviewer"],"fleet_wide":false,
             "model":null,"ctx_tokens":null,"ctx_pct":null,"tier":null,"sub":null,
             "remote_control":{"on":true,"name":"convivy-deck-a1"}}}
            """)
        let vitals = state.vitals
        XCTAssertNotNil(vitals)
        XCTAssertNil(vitals?.contextTokens)
        XCTAssertNil(vitals?.contextLabel, "no reading must not render as a gauge")
        XCTAssertNil(vitals?.tier)
        XCTAssertEqual(vitals?.agents, ["deck-reviewer"])
        XCTAssertEqual(vitals?.remoteControlOn, true)
    }

    /// `nil` is "could not tell", and it must stay distinct from `false`. `co`
    /// passes `--remote-control` unconditionally, and the operator has lately had to turn
    /// it on by hand anyway — so an unreadable record rendered as "off" would be
    /// a confident answer to a question nothing answered.
    func testUnknownRemoteControlIsNotTheSameAsOff() {
        XCTAssertNil(decode(#"{"vitals":{"agents":[],"remote_control":{"on":null}}}"#)
            .vitals?.remoteControlOn)
        XCTAssertNil(decode(#"{"vitals":{"agents":[]}}"#).vitals?.remoteControlOn)
        XCTAssertEqual(decode(#"{"vitals":{"agents":[],"remote_control":{"on":false}}}"#)
            .vitals?.remoteControlOn, false)
    }

    func testAMalformedVitalsBlockDoesNotTakeTheStateWithIt() {
        for hostile in [#"{"state":"idle","vitals":"a string"}"#,
                        #"{"state":"idle","vitals":[1,2,3]}"#,
                        #"{"state":"idle","vitals":{"agents":"not a list","ctx_tokens":"lots"}}"#] {
            let state = decode(hostile)
            XCTAssertEqual(state.phase, .idle, hostile)
            XCTAssertNil(state.vitals?.contextTokens, hostile)
            XCTAssertEqual(state.vitals?.agents ?? [], [], hostile)
        }
    }

    // MARK: - The dispatched runs, which the rail draws with

    /// THE FIELD THAT HAD TO LEAVE `vitals`, and the reason it had to.
    ///
    /// The rail polls `session-agent states`, whose answers are `brief` and
    /// carry no vitals block at all. So a mark that depends on what is running
    /// behind a session could not be drawn on a rail row until this moved out
    /// here — which is the whole difference between a ready session and one
    /// listening while its agents work.
    func testTheTopLevelAgentsFieldIsWhatTheRailReads() {
        let state = decode("""
            {"state":"idle","agents":["deck-reviewer","deck-security-reviewer"],
             "agents_fleet_wide":false}
            """)
        XCTAssertEqual(state.liveAgents, ["deck-reviewer", "deck-security-reviewer"])
        XCTAssertEqual(state.mark, .listening)
    }

    /// Deck runs against a mini it does not control the deploy of, so the old
    /// shape has to keep working — otherwise the open pane loses a badge it has
    /// drawn for weeks the moment this ships, and gets it back only when the
    /// mini pulls.
    func testAMiniThatPredatesTheMoveIsReadFromVitalsInstead() {
        let state = decode(#"{"state":"waiting","vitals":{"agents":["coder"]}}"#)
        XCTAssertEqual(state.liveAgents, ["coder"])
        XCTAssertEqual(state.mark, .listening)
    }

    /// A mini older still, with neither. Empty rather than a guess, and the row
    /// goes quiet rather than claiming work that may not be running.
    func testNeitherSourceIsEmptyRatherThanUnknown() {
        let state = decode(#"{"state":"idle"}"#)
        XCTAssertEqual(state.liveAgents, [])
        XCTAssertEqual(state.mark, .ready)
    }

    /// The top-level field wins when both are present, including when it is the
    /// emptier answer — it is the fresher read, and a brief state has only it.
    func testTheTopLevelFieldOutranksTheCopyInVitals() {
        let state = decode("""
            {"state":"idle","agents":[],"vitals":{"agents":["a-run-that-has-since-exited"]}}
            """)
        XCTAssertEqual(state.liveAgents, [])
        XCTAssertEqual(state.mark, .ready)
    }

    func testAMalformedAgentsListCannotTakeTheStateWithIt() {
        for hostile in [#"{"state":"idle","agents":"not a list"}"#,
                        #"{"state":"idle","agents":[1,2,null]}"#,
                        #"{"state":"idle","agents":{"nested":true}}"#] {
            let state = decode(hostile)
            XCTAssertEqual(state.phase, .idle, hostile)
            XCTAssertEqual(state.liveAgents, [], hostile)
        }
    }

    // MARK: - Whether those agents are fleet-wide (issue_01M1JA0PSDWZPWBF6PJA0X2M7A)

    /// The top-level key, true — the steward's own shape.
    func testTopLevelFleetWideTrue() {
        let state = decode(#"{"state":"idle","agents_fleet_wide":true}"#)
        XCTAssertTrue(state.agentsAreFleetWide)
    }

    /// The top-level key, false — every non-steward session. Pinned
    /// separately from "absent" below: an inverted default would pass the
    /// absent case by accident while getting this one backwards.
    func testTopLevelFleetWideFalse() {
        let state = decode(#"{"state":"idle","agents_fleet_wide":false}"#)
        XCTAssertFalse(state.agentsAreFleetWide)
    }

    /// The top-level key absent, the deprecated copy inside `vitals`
    /// present — a mini that has not picked up the top-level field yet.
    /// THE CASE THAT WOULD OTHERWISE REGRESS SILENTLY: an `?? false`
    /// default with no fallback reads this exactly like a session that is
    /// not fleet-wide at all.
    func testFallsBackToTheVitalsCopyWhenTheTopLevelKeyIsAbsent() {
        let state = decode(#"{"state":"idle","vitals":{"agents":[],"fleet_wide":true}}"#)
        XCTAssertTrue(state.agentsAreFleetWide)
    }

    /// Neither present — a mini older still. `false`, the same honest
    /// "nothing to report" default `liveAgents` lands on.
    func testFalseWhenNeitherSourceIsPresent() {
        let state = decode(#"{"state":"idle"}"#)
        XCTAssertFalse(state.agentsAreFleetWide)
    }

    /// Both present and disagreeing — the top-level `false` must win over a
    /// stale `true` left behind in `vitals`. The four cases above each have
    /// only one source present, so a decode that reads `vitals` first and
    /// falls back to the top level would pass all of them by accident; this
    /// is the case that actually pins the order, matching
    /// `testTheTopLevelFieldOutranksTheCopyInVitals` for `liveAgents`.
    func testTopLevelFleetWideOutranksTheCopyInVitalsWhenTheyDisagree() {
        let state = decode("""
            {"state":"idle","agents_fleet_wide":false,
             "vitals":{"agents":[],"fleet_wide":true}}
            """)
        XCTAssertFalse(state.agentsAreFleetWide)
    }

    // MARK: - The gauge

    /// Formatted the way the status line formats it, so the terminal and the
    /// frame read as one number in two places rather than as two measurements.
    func testTheGaugeReadsAsTheStatusLineWritesIt() {
        func gauge(_ tokens: Int, _ window: Int, _ percent: Double) -> String? {
            SessionState.Vitals(contextTokens: tokens, contextWindow: window,
                                contextPercent: percent, agents: [],
                                agentsAreFleetWide: false).contextLabel
        }
        XCTAssertEqual(gauge(162_000, 1_000_000, 16.2), "162K/1M (16%)")
        XCTAssertEqual(gauge(481_000, 1_000_000, 48.1), "481K/1M (48%)")
        XCTAssertEqual(gauge(1_500_000, 2_000_000, 75), "1.5M/2M (75%)")
        XCTAssertEqual(gauge(900, 200_000, 0.45), "900/200K (0%)")
    }

    /// A window the mini could not establish drops out of the gauge rather than
    /// rendering as `/0` or `/?`, which would read as a measurement of nothing.
    func testAGaugeWithNoWindowStillShowsWhatItKnows() {
        let vitals = SessionState.Vitals(contextTokens: 41_965, contextWindow: nil,
                                         contextPercent: nil, agents: [],
                                         agentsAreFleetWide: false)
        XCTAssertEqual(vitals.contextLabel, "42K")
    }

    /// A percentage that is not a number must not reach the formatter. Nothing on
    /// the wire produces one today — JSONSerialization refuses NaN — which is
    /// exactly what would keep it quiet until the parsing path changes.
    func testANaNPercentageIsDroppedRatherThanRendered() {
        let vitals = SessionState.Vitals(contextTokens: 1_000, contextWindow: 200_000,
                                         contextPercent: .nan, agents: [],
                                         agentsAreFleetWide: false)
        XCTAssertEqual(vitals.contextLabel, "1K/200K")
    }

    /// `isFinite` admits every finite Double, including ones past `Int.max`, and
    /// `Int(_:)` precondition-traps on those — so a percentage of 1e100 would
    /// take the whole app down over a badge. The value comes from Claude Code's
    /// status-line payload, which is not ours to constrain.
    ///
    /// The pane paid for this once already in `quietLabel`. Caught here by
    /// deck-security-reviewer, because the NaN test that shipped alongside
    /// covered the neighbouring case rather than this one.
    func testAnAbsurdButFinitePercentageDoesNotTrap() {
        for percent in [1e100, -1e100, Double(Int.max) * 2, .greatestFiniteMagnitude] {
            let vitals = SessionState.Vitals(contextTokens: 1_000, contextWindow: 200_000,
                                             contextPercent: percent, agents: [],
                                             agentsAreFleetWide: false)
            XCTAssertNotNil(vitals.contextLabel, "\(percent)")
        }
        // And an ordinary reading is untouched by the clamp.
        XCTAssertEqual(
            SessionState.Vitals(contextTokens: 162_000, contextWindow: 1_000_000,
                                contextPercent: 16.2, agents: [],
                                agentsAreFleetWide: false).contextLabel,
            "162K/1M (16%)")
    }

    func testTheTierColoursTheGaugeRatherThanBeingRecomputedHere() {
        // The thresholds live on the mini, beside the numbers they judge. This
        // only pins that each verdict it can send has a distinct treatment.
        let tints = [SessionState.Vitals.Tier.ok, .soft, .hard, .corrupt].map {
            SessionState.Vitals(tier: $0, agents: [], agentsAreFleetWide: false).tierTint
        }
        XCTAssertEqual(Set(tints.map(String.init(describing:))).count, 4)
    }

    // MARK: - The PR chip

    func testTheWorkedOnPRIsDecoded() {
        let state = decode("""
            {"state":"working","vitals":{"agents":[],"fleet_wide":false,
             "pr":{"number":33,"url":"https://github.com/convivy/convivy-deck/pull/33"}}}
            """)
        let pr = state.vitals?.pr
        XCTAssertEqual(pr?.number, 33)
        XCTAssertEqual(pr?.url, "https://github.com/convivy/convivy-deck/pull/33")
    }

    /// The ordinary case: no PR yet for the branch, or it merged. The chip is
    /// simply absent, like every other vitals field that has nothing to say.
    func testNoPRIsNilRatherThanAnEmptyChip() {
        XCTAssertNil(decode(#"{"vitals":{"agents":[]}}"#).vitals?.pr)
        // A malformed pr object, or one with no number, is nil rather than half-set.
        XCTAssertNil(decode(#"{"vitals":{"agents":[],"pr":{"url":"x"}}}"#).vitals?.pr)
        XCTAssertNil(decode(#"{"vitals":{"agents":[],"pr":"not an object"}}"#).vitals?.pr)
    }

    // MARK: - Agents in flight

    func testTheAgentListNamesAFewAndCountsTheRest() {
        func label(_ agents: [String], fleetWide: Bool = false) -> String {
            SessionState.Vitals(agents: agents, agentsAreFleetWide: fleetWide)
                .agentsLabel(fleetWide: fleetWide)
        }
        XCTAssertEqual(label(["coder"]), "1 in flight: coder")
        XCTAssertEqual(label(["a", "b", "c", "d", "e"]), "5 in flight: a·b·c·+2")
        // The steward is the only session that dispatches across repos, and its
        // count is labelled so it cannot be read as this product's own.
        XCTAssertEqual(label(["coder"], fleetWide: true), "1 in flight (fleet): coder")
    }
}

/// The multiselect question, which is what "the buttons do nothing" was.
///
/// A digit answers a single-select question outright — measured 2026-07-24
/// against Claude Code 2.1.219, twice, on a live `co` session. On a multiselect
/// it only ticks a box, so Deck sent one digit and waited for a gate that was
/// never going to clear.
final class MultiSelectGateTests: XCTestCase {

    private func decode(_ json: String) -> SessionState {
        SessionState.decode(Data(json.utf8), fallbackSession: "deck")
    }

    /// Captured 2026-07-24 from `session-agent state picker2` while a multiselect
    /// picker was on screen.
    func testTheMultiSelectFlagIsCarriedRatherThanDropped() {
        let state = decode("""
            {"state":"blocked","gate":{"kind":"question","tool":"AskUserQuestion",
             "questions":[{"question":"Pick pets","header":"Pets","multiSelect":true,
              "options":[{"label":"Cat","description":"Pick cat."},
                         {"label":"Dog","description":"Pick dog."}]}]}}
            """)
        XCTAssertEqual(state.gate?.questions.first?.multiSelect, true)
        XCTAssertEqual(state.gate?.questions.first?.options.map(\.label), ["Cat", "Dog"])
    }

    /// Absent means single-select, which is both the common case and the safe
    /// default: it takes one digit and resolves, so a gate read this way gets
    /// answered rather than left standing.
    func testAQuestionWithNoFlagIsSingleSelect() {
        let state = decode("""
            {"state":"blocked","gate":{"kind":"question",
             "questions":[{"question":"Which?","options":[{"label":"Red"}]}]}}
            """)
        XCTAssertEqual(state.gate?.questions.first?.multiSelect, false)
    }

    /// A SECOND VERB RATHER THAN A FLAG ON `choose`: ticking a box and sending
    /// the answer are different acts, and folding them together would put a
    /// "finish now" argument on every tick but the last.
    func testSubmitIsItsOwnVerbAndCarriesTheSession() throws {
        let argv = try SessionAgent.submitArguments(target: TestHost.target, session: "deck")
        XCTAssertEqual(argv.suffix(2), ["submit", "deck"])
        XCTAssertTrue(argv.contains("session-agent"))
        XCTAssertFalse(argv.contains("choose"))
    }

    func testAnInvalidSessionNameNeverReachesTheSubmitArgv() {
        for hostile in ["deck; rm -rf /", "deck name", "", String(repeating: "d", count: 65)] {
            XCTAssertThrowsError(try SessionAgent.submitArguments(target: TestHost.target, session: hostile), hostile)
        }
    }
}
