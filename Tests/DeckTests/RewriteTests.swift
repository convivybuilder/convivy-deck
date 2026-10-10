import SwiftUI
import XCTest
@testable import Deck

/// Rewrite: up-arrow in an empty composer pulls the session's queued messages
/// back out for editing. `SessionPaneModel.rewriteTriggers` is the predicate
/// that decides whether the keystroke takes effect — the same one the button's
/// enabled state consults — split out as a pure function of the draft and the
/// held count so the property that makes the gesture safe (it never fires over
/// a live edit) is testable without a keystroke. See
/// `deck/specs/session-pane-input-channel`'s M1-M5.
final class RewriteTriggersTests: XCTestCase {

    func testAnEmptyComposerWithHeldMessagesTriggers() {
        XCTAssertTrue(SessionPaneModel.rewriteTriggers(draft: "", held: .count(1)))
        XCTAssertTrue(SessionPaneModel.rewriteTriggers(draft: "", held: .count(3)))
    }

    /// Whitespace is not content — a composer holding only spaces or a
    /// trailing newline is empty for this purpose, same as `canSend`'s trim.
    func testAWhitespaceOnlyComposerCountsAsEmpty() {
        XCTAssertTrue(SessionPaneModel.rewriteTriggers(draft: "   \n", held: .count(1)))
    }

    /// THE PROPERTY THAT MAKES THE GESTURE SAFE. Up-arrow in a non-empty
    /// composer is an ordinary text-editor cursor move; triggering Rewrite
    /// there would destroy whatever the reader was typing, the same failure
    /// M5 documents for the raw keystroke against a live TUI box.
    func testANonEmptyComposerNeverTriggers() {
        XCTAssertFalse(SessionPaneModel.rewriteTriggers(draft: "still typing", held: .count(1)))
        XCTAssertFalse(SessionPaneModel.rewriteTriggers(draft: "still typing", held: .count(0)))
        XCTAssertFalse(SessionPaneModel.rewriteTriggers(draft: "still typing", held: nil))
    }

    func testAZeroCountDoesNotTrigger() {
        XCTAssertFalse(SessionPaneModel.rewriteTriggers(draft: "", held: .count(0)))
    }

    /// `nil` (not read) and `.unknown` (read and could not tell) both decline
    /// rather than guess — offering the gesture over an unestablished count
    /// would let the reader trigger something the session cannot honour.
    func testAnUnestablishedCountDoesNotTrigger() {
        XCTAssertFalse(SessionPaneModel.rewriteTriggers(draft: "", held: nil))
        XCTAssertFalse(SessionPaneModel.rewriteTriggers(draft: "", held: .unknown))
    }
}

/// Where a Rewrite's result actually lands, which is a different question from
/// whether the gesture fires. The predicate above proves the composer empty at
/// the moment of the press; this covers what happens when it is no longer empty
/// by the time the answer comes back.
final class ComposerAfterRewriteTests: XCTestCase {

    func testAnEmptyComposerTakesTheQueueVerbatim() {
        let landed = SessionPaneModel.composerAfterRewrite(
            pulled: ["first", "second"], typed: "")
        XCTAssertEqual(landed.text, "first\nsecond")
        XCTAssertNil(landed.note, "nothing surprising happened, so nothing to explain")
    }

    func testWhitespaceInTheComposerIsNotContent() {
        let landed = SessionPaneModel.composerAfterRewrite(pulled: ["only"], typed: "  \n")
        XCTAssertEqual(landed.text, "only")
        XCTAssertNil(landed.note)
    }

    /// THE RACE. `unqueue` is an ssh round trip — a couple of hundred
    /// milliseconds on the pop path, up to the verb's whole deadline on the
    /// slow ones — and the reader can type into the composer throughout. The
    /// pulled messages are already out of the session's queue and this is
    /// their only copy, so neither side may be dropped.
    func testTypingDuringTheRoundTripLosesNeitherSide() {
        let landed = SessionPaneModel.composerAfterRewrite(
            pulled: ["queued one", "queued two"], typed: "something I just typed")
        XCTAssertTrue(landed.text.contains("queued one"))
        XCTAssertTrue(landed.text.contains("queued two"))
        XCTAssertTrue(landed.text.contains("something I just typed"))
        XCTAssertEqual(landed.text, "queued one\nqueued two\nsomething I just typed",
                       "the queued messages were written first, so they go first")
        XCTAssertNotNil(landed.note, "text arriving above the cursor needs explaining")
    }

    /// A message the reader typed must survive verbatim, not merely appear —
    /// a join that trimmed or reflowed it would still pass a `contains` check.
    func testTheTypedTextSurvivesExactly() {
        let typed = "  leading and trailing spaces preserved  "
        let landed = SessionPaneModel.composerAfterRewrite(pulled: ["q"], typed: typed)
        XCTAssertTrue(landed.text.hasSuffix(typed))
    }
}

/// The mirror of `ComposerAfterRewriteTests`. `rewrite()` was taught not to
/// assign over a reader's typing; this covers the other mutator, where a failed
/// `send()` restores its text on top of a pull that landed while it was out.
final class ComposerAfterFailedSendTests: XCTestCase {

    /// The ordinary case: `send` cleared the box on the way out and nothing
    /// else wrote to it, so the text simply comes back.
    func testTheTextComesBackWhenNothingElseLanded() {
        let restored = SessionPaneModel.composerAfterFailedSend(
            returning: "what I tried to send", landed: "")
        XCTAssertEqual(restored.text, "what I tried to send")
        XCTAssertFalse(restored.mergedWithALanding)
    }

    func testWhitespaceIsNotALanding() {
        let restored = SessionPaneModel.composerAfterFailedSend(
            returning: "mine", landed: "  \n ")
        XCTAssertEqual(restored.text, "mine")
        XCTAssertFalse(restored.mergedWithALanding)
    }

    /// THE INTERLEAVING deck-reviewer traced. A `rewrite()` already in flight
    /// lands its pulled messages into the box `send` had just emptied; the
    /// send then fails. Those messages are off the session's queue via
    /// `popAll` and exist nowhere else, so restoring over them destroys them.
    func testAPullThatLandedDuringTheSendIsNotOverwritten() {
        let restored = SessionPaneModel.composerAfterFailedSend(
            returning: "typed just before Send",
            landed: "pulled one\npulled two")
        XCTAssertTrue(restored.text.contains("pulled one"))
        XCTAssertTrue(restored.text.contains("pulled two"))
        XCTAssertTrue(restored.text.contains("typed just before Send"))
        XCTAssertEqual(restored.text, "pulled one\npulled two\ntyped just before Send",
                       "the pulled messages were queued first, so they go first")
        XCTAssertTrue(restored.mergedWithALanding,
                      "the caller needs to know, or it flips isRewrite off over queue content")
    }
}

/// What the pane says after a Rewrite lands. A failure that arrived while the
/// pull was in flight must survive whatever the Rewrite has to report — the
/// reader needs to know their message did not go out, and the note about
/// queued messages coming back is not a substitute for that.
final class RewriteReportTests: XCTestCase {

    func testANoteAloneIsTheReport() {
        XCTAssertEqual(SessionPaneModel.report("nothing waiting", keeping: nil),
                       "nothing waiting")
    }

    func testNothingToSayReportsNothing() {
        XCTAssertNil(SessionPaneModel.report(nil, keeping: nil))
    }

    /// A pull that succeeds cleanly still must not bury a send that failed
    /// underneath it — the success branch leaves no note of its own.
    func testAFailureDuringTheCallSurvivesASilentSuccess() {
        XCTAssertEqual(SessionPaneModel.report(nil, keeping: "the send failed"),
                       "the send failed")
    }

    /// THE INTERLEAVING. Up-arrow starts the pull; the reader types and sends;
    /// the send fails while the pull is still out; the pull then lands with a
    /// note. Reporting only the note tells them their queued messages came
    /// back and never tells them their message did not go.
    func testBothAreShownWithTheFailureFirst() {
        let shown = SessionPaneModel.report("Your queued messages came back above what you were typing.",
                                            keeping: "the send failed")
        XCTAssertTrue(shown!.hasPrefix("the send failed"),
                      "the failure is the part that needs acting on")
        XCTAssertTrue(shown!.contains("queued messages came back"))
    }
}

/// `lastErrorWrites` is what lets `send` and `rewrite` tell "somebody reported
/// something while my call was out" from "nothing happened". Counting writes
/// rather than comparing values is the point: two identical strings compare
/// equal, so a live failure worded the same as the stale one already on screen
/// would otherwise read as nothing at all.
@MainActor
final class LastErrorWriteCountingTests: XCTestCase {

    private func model() -> SessionPaneModel {
        SessionPaneModel(session: "probe", target: TestHost.target)
    }

    /// The blind spot the counter exists to close: the same error twice.
    func testRewritingTheSameValueStillCountsAsAWrite() {
        let m = model()
        m.reportForTesting("ssh: connection refused")
        let after = m.lastErrorWrites
        m.reportForTesting("ssh: connection refused")
        XCTAssertGreaterThan(m.lastErrorWrites, after,
                             "an identical second failure is still a second failure")
    }

    func testClearingCountsAsAWriteToo() {
        let m = model()
        m.reportForTesting("something")
        let after = m.lastErrorWrites
        m.reportForTesting(nil)
        XCTAssertGreaterThan(m.lastErrorWrites, after)
    }

    func testNotWritingDoesNotAdvanceTheCount() {
        let m = model()
        let before = m.lastErrorWrites
        XCTAssertEqual(m.lastErrorWrites, before)
    }
}

/// The up-arrow handler's modifier guard, which shipped dead.
///
/// `press.modifiers.isEmpty` never matches an arrow key on macOS — the event
/// carries `.numericPad`, and usually `.function` — so the guard was false on
/// every press and the keystroke did nothing while the Rewrite button beside
/// it worked. Found by driving the composer by hand; the predicate underneath
/// was correct and passing throughout, so no test in this file could see it
/// until the guard was pulled out of the closure.
final class UpArrowModifierGuardTests: XCTestCase {

    /// THE REGRESSION, in one assertion. A bare arrow press still arrives
    /// carrying the hardware flags that say which key it is.
    func testTheHardwareFlagsAnArrowAlwaysCarriesDoNotBlockIt() {
        XCTAssertTrue(SessionPaneModel.upArrowTakesTheKey(modifiers: .numericPad, canRewrite: true))
        XCTAssertTrue(SessionPaneModel.upArrowTakesTheKey(modifiers: [.numericPad, .function],
                                                      canRewrite: true))
    }

    func testABareArrowTakesTheKey() {
        XCTAssertTrue(SessionPaneModel.upArrowTakesTheKey(modifiers: [], canRewrite: true))
    }

    /// The editor's own gestures must still reach it: Shift-Up selects,
    /// Option-Up jumps, Command-Up goes to the top.
    func testTheEditorsOwnGesturesFallThrough() {
        for modifier: EventModifiers in [.shift, .option, .command, .control] {
            XCTAssertFalse(SessionPaneModel.upArrowTakesTheKey(modifiers: modifier, canRewrite: true),
                           "\(modifier) means the editor's gesture, not Rewrite")
            XCTAssertFalse(SessionPaneModel.upArrowTakesTheKey(modifiers: [modifier, .numericPad],
                                                           canRewrite: true),
                           "a real press carries .numericPad alongside the modifier")
        }
    }

    /// The safety property is unchanged: nothing fires when Rewrite is not
    /// available, whatever the modifiers say.
    func testNothingFiresWhenRewriteIsUnavailable() {
        XCTAssertFalse(SessionPaneModel.upArrowTakesTheKey(modifiers: [], canRewrite: false))
        XCTAssertFalse(SessionPaneModel.upArrowTakesTheKey(modifiers: .numericPad, canRewrite: false))
    }
}
