import XCTest
@testable import Deck

/// The gate that decides whether a poll redraws the conversation.
///
/// It is worth its own file because getting it wrong is invisible in both
/// directions and expensive in both. Too tight and the pane freezes while the
/// session works — which happened, and sent the operator back to the raw terminal the
/// pane exists to replace. Too loose and every 2s poll reloads the document,
/// throwing away the scroll position and the rows the reader had expanded.
final class RenderGateTests: XCTestCase {
    private func state(
        phase: SessionState.Phase = .working,
        lastEvent: String? = "PreToolUse",
        mtime: Double? = 1_000.0,
        gate: SessionState.Gate? = nil,
        held: SessionState.HeldCount? = nil
    ) -> SessionState {
        var s = SessionState(session: "deck", phase: phase, gate: gate, alive: true,
                             reason: nil, lastEvent: lastEvent, transcriptMTime: mtime)
        s.held = held
        return s
    }

    // MARK: - The bug

    func testAGrowingTranscriptRedrawsEvenWhenNothingElseMoves() {
        // THE CASE THAT WAS BROKEN. A working turn emits `PreToolUse` after
        // `PreToolUse`; phase stays `.working` and there is no gate. Every
        // signal the old gate had compares equal, for the whole turn.
        let before = state(mtime: 1_000.0)
        let after = state(mtime: 1_000.5)

        XCTAssertTrue(SessionPaneModel.shouldRender(from: before, to: after),
                      "the transcript grew and the pane did not redraw")
    }

    func testAnIdenticalPollDoesNotRedraw() {
        // The other half. A poll that found nothing must not reload the
        // document under a reader who is scrolled up reading history.
        XCTAssertFalse(SessionPaneModel.shouldRender(from: state(), to: state()))
    }

    // MARK: - The fallbacks, which still have to work

    func testAMissingMTimeFallsBackToTheOlderSignals() {
        // A mini that cannot stat the transcript, or one predating the field.
        // Both must leave the older signals deciding — nil is not "unchanged".
        let before = state(lastEvent: "PreToolUse", mtime: nil)
        let after = state(lastEvent: "Stop", mtime: nil)

        XCTAssertTrue(SessionPaneModel.shouldRender(from: before, to: after))
        XCTAssertFalse(SessionPaneModel.shouldRender(from: before, to: before))
    }

    func testTheMTimeDisappearingIsNotTreatedAsAChange() {
        // Going from a known mtime to none means the mini stopped being able to
        // answer, not that the conversation moved. Rendering on it would reload
        // the document every poll for as long as the stat keeps failing.
        let before = state(mtime: 1_000.0)
        let after = state(mtime: nil)

        XCTAssertFalse(SessionPaneModel.shouldRender(from: before, to: after))
    }

    func testAPhaseChangeStillRedraws() {
        XCTAssertTrue(SessionPaneModel.shouldRender(
            from: state(phase: .working, mtime: 1_000.0),
            to: state(phase: .idle, mtime: 1_000.0)))
    }

    /// `issue_01M3NWD9SFBS9DT434MVM0D663`: a queued message stopped showing in
    /// the session pane, though the raw tmux pane still drew it. The mini
    /// populates `held` unconditionally alongside `transcript_mtime` — both
    /// come from the same read — so in practice the two move together and
    /// this case is narrow. But `shouldRender` had exactly one signal wired
    /// to detect a queue change (mtime, a proxy) and none wired to the fact
    /// itself, which `SessionState` already decodes. A gate with only one
    /// path to a fact has one point of failure for it; this gives it two.
    func testAHeldCountChangeStillRedrawsEvenWhenNothingElseMoved() {
        let before = state(mtime: 1_000.0, held: nil)
        let after = state(mtime: 1_000.0, held: .count(1))

        XCTAssertTrue(SessionPaneModel.shouldRender(from: before, to: after),
                      "a message joined the queue and the pane did not redraw")
    }

    /// The release side of the same gap: the queue draining is exactly as
    /// significant as it filling, and the pane must ask for a delta so the
    /// mini's `removed` list can take the held row back off the page.
    func testAHeldCountClearingStillRedraws() {
        let before = state(mtime: 1_000.0, held: .count(1))
        let after = state(mtime: 1_000.0, held: .count(0))

        XCTAssertTrue(SessionPaneModel.shouldRender(from: before, to: after),
                      "the queue drained and the pane did not redraw")
    }

    func testAGateAppearingStillRedraws() {
        let asking = SessionState.Gate(
            kind: .question, tool: nil,
            questions: [.init(question: "which?", header: nil, options: [])],
            hasSuggestions: false)

        XCTAssertTrue(SessionPaneModel.shouldRender(
            from: state(mtime: 1_000.0),
            to: state(mtime: 1_000.0, gate: asking)))
    }

    // MARK: - The wire

    func testTheMTimeIsDecodedFromTheMini() throws {
        let json = #"{"session":"deck","state":"working","alive":true,"transcript_mtime":1784950000.123}"#
        let decoded = SessionState.decode(Data(json.utf8), fallbackSession: "deck")

        XCTAssertEqual(decoded.transcriptMTime ?? 0, 1_784_950_000.123, accuracy: 0.0005)
    }

    func testAStateWithoutTheFieldStillDecodes() throws {
        // The compatibility rule this decoder is built on: a Deck that refused
        // to parse a state missing a key would go blind against an older mini.
        let json = #"{"session":"deck","state":"idle","alive":true}"#
        let decoded = SessionState.decode(Data(json.utf8), fallbackSession: "deck")

        XCTAssertNil(decoded.transcriptMTime)
        XCTAssertEqual(decoded.phase, .idle)
    }
}

/// The working pulse: motion while the session is working, and a quiet timer
/// once the silence is long enough to worry about. The operator: "a pulse when claude is
/// working but no output is coming to the session surface."
final class WorkingPulseTests: XCTestCase {
    func testTheLivenessFieldsAreDecoded() {
        let json = """
        {"session":"vivy","state":"working","alive":true,
         "progressing":true,"last_event_age":42.5}
        """
        let decoded = SessionState.decode(Data(json.utf8), fallbackSession: "vivy")

        XCTAssertEqual(decoded.progressing, true)
        XCTAssertEqual(decoded.lastEventAge ?? 0, 42.5, accuracy: 0.01)
    }

    func testAStateWithoutThemStillDecodes() {
        // An older mini, or a state that could not establish them.
        let json = #"{"session":"vivy","state":"idle","alive":true}"#
        let decoded = SessionState.decode(Data(json.utf8), fallbackSession: "vivy")

        XCTAssertNil(decoded.progressing)
        XCTAssertNil(decoded.lastEventAge)
    }

    func testSilenceIsCountedInSecondsThenMinutesThenHours() {
        // Seconds while a reader is still counting; minutes once they are not;
        // hours once minutes stop being legible. 165 minutes is the operator's report
        // (2026-09-05) — with no hour tier this rendered "quiet 165m" and, at
        // the VitalsRow call site, wrapped a `lineLimit`-less Text and grew
        // the row's height.
        XCTAssertEqual(SessionPaneView.quietLabel(25), "quiet 25s")
        XCTAssertEqual(SessionPaneView.quietLabel(89), "quiet 89s")
        XCTAssertEqual(SessionPaneView.quietLabel(120), "quiet 2m")
        XCTAssertEqual(SessionPaneView.quietLabel(600), "quiet 10m")
        XCTAssertEqual(SessionPaneView.quietLabel(5_400), "quiet 2h")
        XCTAssertEqual(SessionPaneView.quietLabel(165 * 60), "quiet 3h")
    }

    func testTheThresholdLeavesAnOrdinaryTurnUncluttered() {
        // A responsive turn should carry no ticking number; the timer is for the
        // wait that has gone on long enough to wonder about.
        XCTAssertGreaterThanOrEqual(SessionPaneView.quietThreshold, 10)
        XCTAssertLessThanOrEqual(SessionPaneView.quietThreshold, 60)
    }
}

extension WorkingPulseTests {
    /// `Int(_:)` on a Double traps beyond Int's range, and the age is
    /// mini-supplied. JSONSerialization refuses NaN and Infinity — measured —
    /// but `1e30` parses, and its minutes exceed Int.max, which would crash the
    /// app over a clock skew rather than anything hostile.
    func testAnAbsurdAgeDoesNotTrap() {
        for age in [1e30, 1e300, .greatestFiniteMagnitude, -1, -1e30] as [Double] {
            let label = SessionPaneView.quietLabel(age)
            XCTAssertFalse(label.isEmpty, "\(age)")
        }
    }

    func testAnAgeIsClampedToSomethingAReaderCanUse() {
        // Past a day the exact number tells nobody anything.
        XCTAssertEqual(SessionPaneView.quietLabel(1e30), SessionPaneView.quietLabel(86_400))
        XCTAssertEqual(SessionPaneView.quietLabel(-5), "quiet 0s")
    }
}

/// Cmd-+/- moved the terminal and did nothing visible in the session pane — a
/// shortcut that fires and changes nothing reads as broken, not as inapplicable.
final class PaneTextScaleTests: XCTestCase {
    func testTheDefaultSizeAsksForNoScaling() throws {
        // An untouched Deck must send nothing, so the page renders exactly as
        // the mini ships it.
        let argv = try SessionAgent.renderArguments(
            target: TestHost.target, session: "vivy", appearance: .dark, scale: 1)
        XCTAssertFalse(argv.contains("--scale"))
    }

    func testAChangedSizeIsSent() throws {
        let argv = try SessionAgent.renderArguments(
            target: TestHost.target, session: "vivy", appearance: .dark, scale: 1.4)
        XCTAssertEqual(argv[argv.firstIndex(of: "--scale")! + 1], "1.400")
    }

    func testAValueTheMiniWouldRefuseIsNotSent() throws {
        // Mirrored rather than argued about: a scale it would drop is not worth
        // sending, and a Deck that sent one would show an unchanged page with no
        // hint why.
        for bad in [0.1, 5.0, -1, .nan, .infinity] as [Double] {
            let argv = try SessionAgent.renderArguments(
                target: TestHost.target, session: "vivy", appearance: .dark, scale: bad)
            XCTAssertFalse(argv.contains("--scale"), "\(bad)")
        }
    }

    // `testTheScaleTracksTheTerminalsOwnSize` lived here and is deliberately
    // gone. It documented the coupling — "the terminal is sized in points and
    // the page in a multiplier, so they share a RATIO" — that the four-surface
    // typography work removed: the session's scale is its own preference now.
    //
    // It kept passing because it only did arithmetic on a constant, asserting
    // nothing about the code, while describing behaviour that no longer exists.
    // It would also have failed the moment the terminal default moved to 12 —
    // loudly, for a reason unrelated to anything it claimed to guard, which is a
    // tripwire that cries wolf. The decoupling is asserted for real by
    // `DeckTypographyTests.testMovingTheTerminalNoLongerMovesTheSession`.
}

extension PaneTextScaleTests {
    /// Deck must never offer a scale the renderer would refuse.
    ///
    /// REPOINTED AT THE SESSION'S OWN RANGE. This used to divide the TERMINAL's
    /// point range by the terminal default, because the page's scale was derived
    /// from it. That derivation is gone, so the old form was measuring a
    /// relationship that no longer decides anything — and it would have moved
    /// with the terminal default for no reason.
    ///
    /// What still matters is that the slider a user can actually drag stays
    /// inside what `session-view` accepts: a value it refuses is dropped on the
    /// far side, leaving the page at a size nobody asked for and nothing to say
    /// why.
    func testTheTypographyRangeStaysInsideTheRendererRange() {
        let lowest = SessionTypography.minimumScale
        let highest = SessionTypography.maximumScale

        XCTAssertGreaterThanOrEqual(lowest, SessionAgent.minimumScale,
                                    "the smallest terminal size now scales past what the renderer takes")
        XCTAssertLessThanOrEqual(highest, SessionAgent.maximumScale,
                                 "the largest terminal size now scales past what the renderer takes")
    }
}

/// A render that fails must say so. It was `try?`, so a failure looked exactly
/// like a slow load — the pane sat on "Loading the conversation…" forever with
/// nothing to act on, which is how the operator experienced it.
final class RenderFailureTests: XCTestCase {
    func testTheFailurePageNamesTheReason() {
        let page = SessionPaneModel.failurePage("session-agent: not installed")
        XCTAssertTrue(page.contains("could not be rendered"))
        XCTAssertTrue(page.contains("session-agent: not installed"))
    }

    func testTheFailurePageOffersTheSurfaceThatCannotDrift() {
        // The terminal is the drift-proof fallback the contract names, so a pane
        // that cannot render should point at it rather than dead-end.
        XCTAssertTrue(SessionPaneModel.failurePage("x").contains("terminal"))
    }

    func testAReasonCannotInjectMarkupIntoTheFailurePage() {
        // The reason carries the remote's own words, so it is escaped like any
        // other untrusted text reaching this pane.
        let page = SessionPaneModel.failurePage("<script>alert(1)</script>")
        XCTAssertFalse(page.contains("<script>"))
        XCTAssertTrue(page.contains("&lt;script&gt;"))
    }
}

/// `SessionPaneView`'s composer falls back to a "cannot show you this, here's
/// the terminal" message for `.blocked` and `.unknown` rather than a
/// disabled `ComposerView` with nothing on it — `composerFallbackMessage`
/// is the pure function behind that branch, pulled out so the wording is
/// pinned by a test rather than living only in the view's body.
///
/// Neither phase had a test before this: the view's `composer` is a private
/// computed property of `SessionPaneView`, and hosting the view needs a
/// `SessionPaneModel` whose `state` is `private(set)`, so nothing exercised
/// this branch directly for either phase. This is the first coverage of
/// both.
final class ComposerFallbackMessageTests: XCTestCase {
    func testBlockedNamesTheSessionAsWaiting() {
        // Blocked is a clean read: the pane knows the session stopped for the
        // reader and just cannot draw what it is waiting on.
        let message = SessionPaneModel.composerFallbackMessage(for: .blocked)
        XCTAssertEqual(message, "This session is waiting on something the pane cannot show.")
    }

    func testUnknownSaysTheStateCannotBeRead() {
        // Unknown is not a clean read at all — the pane has no idea what the
        // session is doing, which is a different fact from "stopped and
        // waiting". Guessing "waiting" here would be dishonest.
        let message = SessionPaneModel.composerFallbackMessage(for: .unknown)
        XCTAssertEqual(message, "Deck cannot read this session's state.")
    }

    func testBlockedAndUnknownReadDifferently() {
        // The crux of the fix: the two phases must not collapse onto the same
        // sentence, or a reader loses the distinction between "I see this
        // clearly and it's stuck" and "I cannot read this at all".
        XCTAssertNotEqual(SessionPaneModel.composerFallbackMessage(for: .blocked),
                           SessionPaneModel.composerFallbackMessage(for: .unknown))
    }

    func testEveryOtherPhaseGetsTheOrdinaryComposerInstead() {
        for phase in [SessionState.Phase.idle, .working, .waiting, .ended] {
            XCTAssertNil(SessionPaneModel.composerFallbackMessage(for: phase), "\(phase)")
        }
    }
}
