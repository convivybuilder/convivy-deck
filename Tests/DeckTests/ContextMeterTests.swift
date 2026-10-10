import XCTest
@testable import Deck

/// The rail's context meter as a pure value: what each rollover state draws,
/// and which overrides each state's row offers.
final class ContextMeterTests: XCTestCase {

    private func rollover(_ state: SessionState.Rollover.State,
                          reason: String? = nil,
                          calls: Int? = nil, cap: Int? = nil,
                          vetoedUntil: String? = nil, seek: Double? = nil) -> SessionState.Rollover {
        SessionState.Rollover(state: state, reason: reason, callsSeeking: calls, cap: cap,
                              vetoedUntil: vetoedUntil,
                              policy: seek.map { SessionState.Rollover.Policy(seekPercent: $0) })
    }

    /// A mini that predates both fields draws nothing, rather than an empty
    /// track that would read as 0%.
    func testNothingToDrawWithoutAReading() {
        XCTAssertNil(ContextMeter.resolve(contextPercent: nil, rollover: nil))
    }

    func testAnOrdinarySessionFillsTheTrackInNeutralInk() throws {
        let meter = try XCTUnwrap(ContextMeter.resolve(contextPercent: 49, rollover: rollover(.ok)))
        XCTAssertEqual(meter.fill, 0.49)
        XCTAssertEqual(meter.ink, .neutral)
        XCTAssertEqual(meter.glyph, .none)
        XCTAssertFalse(meter.summons)
        XCTAssertEqual(meter.help, "49% of context")
        XCTAssertEqual(meter.rolloverState, .ok)
    }

    /// DECK DRAWS THE BOSUN'S DECISION. A session past 70% whose hook still
    /// says `none` stays neutral; the amber comes from `seeking`, not from a
    /// threshold Deck compares against.
    func testAmberFollowsTheHooksStateNotThePercentage() throws {
        let pastButNotSeeking = try XCTUnwrap(ContextMeter.resolve(contextPercent: 85, rollover: rollover(.ok)))
        XCTAssertEqual(pastButNotSeeking.ink, .neutral)
        let seeking = try XCTUnwrap(ContextMeter.resolve(contextPercent: 65, rollover: rollover(.seeking)))
        XCTAssertEqual(seeking.ink, .attention)
    }

    func testSeekingNamesTheCallsSpentAndTheCap() throws {
        let capped = try XCTUnwrap(ContextMeter.resolve(contextPercent: 77, rollover: rollover(.seeking, calls: 12, cap: 40)))
        XCTAssertEqual(capped.help, "77% of context, looking for a moment to roll over (12 of 40 calls)")
        let uncapped = try XCTUnwrap(ContextMeter.resolve(contextPercent: 77, rollover: rollover(.seeking, calls: 12)))
        XCTAssertEqual(uncapped.help, "77% of context, looking for a moment to roll over (12 calls so far)")
    }

    /// The first firing after a session crosses the threshold reports one
    /// call, which is the reading a row shows most often — and it read
    /// "1 calls so far" until this, seen live on a real session's row.
    func testOneCallReadsAsOneCall() throws {
        let first = try XCTUnwrap(ContextMeter.resolve(contextPercent: 37, rollover: rollover(.seeking, calls: 1)))
        XCTAssertEqual(first.help, "37% of context, looking for a moment to roll over (1 call so far)")
        let capped = try XCTUnwrap(ContextMeter.resolve(contextPercent: 37, rollover: rollover(.seeking, calls: 1, cap: 40)))
        XCTAssertEqual(capped.help, "37% of context, looking for a moment to roll over (1 of 40 calls)")
    }

    func testRollNowPulsesAndCarriesItsGlyph() throws {
        let meter = try XCTUnwrap(ContextMeter.resolve(contextPercent: 93, rollover: rollover(.rollNow)))
        XCTAssertEqual(meter.ink, .attentionPulsing)
        XCTAssertEqual(meter.glyph, .rollNow)
    }

    /// While rolling, the predecessor's reading describes a context that is
    /// about to be gone, so the track is dropped for the glyph.
    func testRollingDropsTheTrack() throws {
        let meter = try XCTUnwrap(ContextMeter.resolve(contextPercent: 93, rollover: rollover(.rolling)))
        XCTAssertNil(meter.fill)
        XCTAssertEqual(meter.glyph, .rolling)
        XCTAssertEqual(meter.help, "Rolling over to a new session")
    }

    func testAVetoNamesTheLimitItHoldsUntil() throws {
        let floor = try XCTUnwrap(ContextMeter.resolve(contextPercent: 74, rollover: rollover(.vetoed, vetoedUntil: "floor_pct")))
        XCTAssertEqual(floor.ink, .neutral)
        XCTAssertEqual(floor.glyph, .vetoed)
        XCTAssertEqual(floor.help, "74% of context, rollover vetoed until it reaches the hard floor")
        let open = try XCTUnwrap(ContextMeter.resolve(contextPercent: 74, rollover: rollover(.vetoed)))
        XCTAssertEqual(open.help, "74% of context, rollover vetoed until you lift it")
    }

    /// **`seek_pct` IS WHAT A LIVE VETO RETURNS**, and it was the one limit
    /// with no case, so the operator read the raw wire word. Measured
    /// 2026-09-18 against a real session under `mode: enforce` with
    /// `floor_pct: 88`: `session-agent rollover <name> veto` answered
    /// `vetoed_until: "seek_pct"`. Every fixture until then used `floor_pct`
    /// or nil, which is why the passthrough case was never seen on screen.
    /// No "again": a veto set while the session is below the threshold — 8%
    /// here, and `vetoed_until` names `seek_pct` precisely when the session
    /// was at `none` — has no prior crossing to repeat, and the sibling
    /// limits carry no such word either.
    func testAVetoHeldUntilTheSeekThresholdReadsAsEnglish() throws {
        let meter = try XCTUnwrap(ContextMeter.resolve(contextPercent: 8, rollover: rollover(.vetoed, vetoedUntil: "seek_pct")))
        XCTAssertEqual(meter.help, "8% of context, rollover vetoed until it reaches the seek threshold")
        XCTAssertFalse(meter.help.contains("seek_pct"), "the wire word must not reach the operator")
    }

    /// A parked session asks for a person whichever reason parked it — the
    /// needs-you bar is the ask, and it does not depend on the reason being
    /// one Deck recognises.
    func testParkedCarriesTheNeedsYouBarForEveryReason() throws {
        for reason in ["spawn_error", "verify_up_failed", "declined", "seeking_loop", nil,
                       "a_word_deck_has_never_seen"] {
            let meter = try XCTUnwrap(ContextMeter.resolve(contextPercent: 83, rollover: rollover(.parked, reason: reason)))
            XCTAssertTrue(meter.summons, "reason \(reason ?? "nil")")
            XCTAssertEqual(meter.ink, .attention, "reason \(reason ?? "nil")")
        }
    }

    /// **EACH REASON SAYS ONLY WHAT THE HOOK SAW.** The old copy said "the
    /// new session failed to start" for all four, asserting a successor on
    /// reasons where none was spawned. A real parked session read `declined`
    /// and then `verify_up_failed` on 2026-09-18
    /// (`issue_01M2HNWAJVK8MHMSNWE0RT1A6C`).
    func testParkedSaysWhichOfTheFourReasonsStoppedIt() throws {
        func help(_ reason: String?) throws -> String {
            try XCTUnwrap(ContextMeter.resolve(contextPercent: 83, rollover: rollover(.parked, reason: reason))).help
        }
        XCTAssertEqual(try help("spawn_error"), "83% of context, the new session could not be started")
        XCTAssertEqual(try help("verify_up_failed"), "83% of context, the new session was started but never came up")
        XCTAssertEqual(try help("declined"), "83% of context, it was told to roll over and did not")
        XCTAssertEqual(try help("seeking_loop"),
                       "83% of context, it ended its turn repeatedly when told to look for a rollover moment")

        XCTAssertFalse(try help("declined").contains("new session"),
                       "declined is N re-issues with no /rollover invoked, so no successor was spawned")
    }

    /// **`seeking_loop` MUST NOT CLAIM THE SESSION NEVER ROLLED OVER**, and an
    /// earlier draft of this text did. `_park_stuck`'s docstring says such a
    /// session "has not necessarily decided anything" — the shape is a loop
    /// the hook is driving — and its filed body names a rollover that already
    /// succeeded without recording state as the first thing to rule out,
    /// adding that this is what the one measured instance turned out to be.
    /// So the text must describe the turn endings the hook counted and stop.
    func testSeekingLoopDescribesWhatTheHookSawAndClaimsNothingMore() throws {
        let help = try XCTUnwrap(ContextMeter.resolve(contextPercent: 83, rollover: rollover(.parked, reason: "seeking_loop"))).help
        XCTAssertFalse(help.contains("new session"), "no successor is established either way")
        XCTAssertFalse(help.contains("never took"), "a seeking_loop session may already have rolled over")
    }

    /// **NO PARKED TEXT PROMISES AN ISSUE IS WAITING.** The old copy did, and
    /// none existed: a query for the Bosun's operator-facing items returned
    /// zero against both live parked readings on 2026-09-18. Deck shows the
    /// needs-you bar and says what happened; whether an item was filed is the
    /// platform's to make true before Deck asserts it.
    func testNoParkedTextClaimsAnIssueIsWaiting() throws {
        for reason in ["spawn_error", "verify_up_failed", "declined", "seeking_loop", nil, "a_word_deck_has_never_seen"] {
            let meter = try XCTUnwrap(ContextMeter.resolve(contextPercent: 83, rollover: rollover(.parked, reason: reason)))
            XCTAssertFalse(meter.help.contains("issue"), "reason \(reason ?? "nil") must not promise a filed issue")
        }
    }

    /// An unrecognised reason says only that it parked, and carries the word
    /// so an operator can quote it — the same posture `.unrecognized` takes.
    func testAnUnknownParkReasonSaysOnlyThatItParked() throws {
        let meter = try XCTUnwrap(ContextMeter.resolve(contextPercent: 83, rollover: rollover(.parked, reason: "wedged")))
        XCTAssertEqual(meter.help, "83% of context, its rollover stopped and it is parked (wedged)")
        let none = try XCTUnwrap(ContextMeter.resolve(contextPercent: 83, rollover: rollover(.parked)))
        XCTAssertEqual(none.help, "83% of context, its rollover stopped and it is parked")
    }

    func testAnUnrecognisedStateDrawsNeutralAndSaysSo() throws {
        let meter = try XCTUnwrap(ContextMeter.resolve(contextPercent: 50, rollover: rollover(.unrecognized("draining"))))
        XCTAssertEqual(meter.ink, .neutral)
        XCTAssertEqual(meter.glyph, .none)
        XCTAssertEqual(meter.help, "50% of context, rollover state not recognised (draining)")
    }

    /// The tick follows the policy the hook evaluated against, and falls back
    /// to ADR-0069's 70% only when the reading carries no policy.
    func testTheThresholdTickFollowsThePolicy() throws {
        XCTAssertEqual(try XCTUnwrap(ContextMeter.resolve(contextPercent: 40, rollover: rollover(.ok, seek: 60))).threshold, 0.6)
        XCTAssertEqual(try XCTUnwrap(ContextMeter.resolve(contextPercent: 40, rollover: nil)).threshold, 0.7)
    }

    /// A reading outside 0...100 is clamped rather than overflowing the track
    /// or trapping on `Int(_:)` in the hover text.
    func testAnOutOfRangeReadingIsClamped() throws {
        let over = try XCTUnwrap(ContextMeter.resolve(contextPercent: 1e20, rollover: nil))
        XCTAssertEqual(over.fill, 1)
        XCTAssertEqual(over.help, "100% of context")
        XCTAssertEqual(try XCTUnwrap(ContextMeter.resolve(contextPercent: -5, rollover: nil)).fill, 0)
    }

    /// A change that took effect says nothing; a refusal passes the mini's
    /// reason through; an unreadable answer is reported, never taken as success.
    func testRolloverFailureMessages() {
        XCTAssertNil(ContentView.rolloverFailure(.armed(nil)))
        XCTAssertNil(ContentView.rolloverFailure(.sent(nil)))
        XCTAssertEqual(ContentView.rolloverFailure(.refused("the composer holds a draft")), "the composer holds a draft")
        XCTAssertNotNil(ContentView.rolloverFailure(.malformed))
    }

    /// **NO MESSAGE DECK COMPOSES NAMES CONVIVY'S HARDWARE.** This one said
    /// "the mini", which is meaningless to an operator whose host is their
    /// own — the last such string in `Sources`, and the one Check 1 of
    /// `deck/specs/running-deck-as-someone-else` exists to keep out. A
    /// refusal passes the host's own words through untouched, so only the
    /// message Deck writes itself is pinned here.
    func testRolloverFailureNamesNoMachine() throws {
        let malformed = try XCTUnwrap(ContentView.rolloverFailure(.malformed))
        XCTAssertFalse(malformed.lowercased().contains("mini"))
        XCTAssertTrue(malformed.contains("host"), "it still says whose answer could not be read")
    }

    func testEachStateOffersOnlyTheOverridesThatMeanSomething() {
        XCTAssertEqual(ContextMeter.actions(for: nil), [])
        XCTAssertEqual(ContextMeter.actions(for: rollover(.ok)), [.veto, .seek, .force])
        XCTAssertEqual(ContextMeter.actions(for: rollover(.seeking)), [.veto, .force])
        XCTAssertEqual(ContextMeter.actions(for: rollover(.rollNow)), [.veto])
        XCTAssertEqual(ContextMeter.actions(for: rollover(.vetoed)), [.clear, .force])
        XCTAssertEqual(ContextMeter.actions(for: rollover(.rolling)), [])
        XCTAssertEqual(ContextMeter.actions(for: rollover(.parked)), [])
        XCTAssertEqual(ContextMeter.actions(for: rollover(.unrecognized("x"))), [])
    }

    /// A veto offered from `.ok` is pre-empting a rollover that has not
    /// started looking yet, so it reads as "the next" one; offered once
    /// `.seeking` or `.rollNow` is already under way, "this" one.
    func testVetoTitleNamesWhichRolloverDependingOnState() {
        XCTAssertEqual(ContextMeter.menuTitle(.veto, state: .ok), "Veto the Next Rollover")
        XCTAssertEqual(ContextMeter.menuTitle(.veto, state: .seeking), "Veto This Rollover")
        XCTAssertEqual(ContextMeter.menuTitle(.veto, state: .rollNow), "Veto This Rollover")
    }

    /// The other three titles never depend on state.
    func testOtherMenuTitlesDoNotDependOnState() {
        XCTAssertEqual(ContextMeter.menuTitle(.force, state: .ok), "Roll Over Now…")
        XCTAssertEqual(ContextMeter.menuTitle(.seek, state: .ok), "Start Looking for a Moment")
        XCTAssertEqual(ContextMeter.menuTitle(.clear, state: .vetoed), "Lift the Veto")
    }
}
