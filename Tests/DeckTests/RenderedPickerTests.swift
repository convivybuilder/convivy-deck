import XCTest
@testable import Deck

/// What the pane does with the picker the mini actually read.
///
/// THE POINT OF THE WHOLE BLOCK IS THAT DECK STOPS GUESSING. `AskUserQuestion`'s
/// payload carries the options the model wrote and nothing the TUI adds at render
/// time, so which question is live and whether a free-text row exists were
/// inferences Deck kept and could not check. The mini now reads them off the
/// screen; these tests pin that an observation beats the inference, and that
/// absence of an observation is not read as absence of the thing.
///
/// The degradation is what most of this file is about, deliberately. `rendered`
/// disappears on a Claude Code release the mini's markers have not been checked
/// against, which is by design — so every one of these fields has to have a
/// working answer for `nil`, and the answer must never be "send a digit anyway".
final class RenderedPickerTests: XCTestCase {

    // MARK: - Decoding

    private func state(_ json: String) -> SessionState {
        SessionState.decode(Data(json.utf8), fallbackSession: "deck")
    }

    private func blockedGate(rendered: String?) -> SessionState {
        let block = rendered.map { ", \"rendered\": \($0)" } ?? ""
        return state("""
            {"session": "deck", "state": "blocked", "alive": true,
             "gate": {"kind": "question", "tool": "AskUserQuestion",
                      "questions": [{"question": "Which?", "options": [{"label": "A"}]},
                                    {"question": "And?", "options": [{"label": "B"}]}]\(block)}}
            """)
    }

    func testTheRenderedBlockDecodes() {
        let s = blockedGate(rendered: """
            {"questionIndex": 1, "freeTextRow": 3, "onSubmitTab": false,
             "multiSelectCommit": "submit", "claudeVersion": "2.1.220"}
            """)
        let r = s.gate?.rendered
        XCTAssertEqual(r?.questionIndex, 1)
        XCTAssertEqual(r?.freeTextRow, 3)
        XCTAssertEqual(r?.onSubmitTab, false)
        XCTAssertEqual(r?.multiSelectCommit, .submit)
        XCTAssertEqual(r?.claudeVersion, "2.1.220")
    }

    func testAGateWithNoRenderedBlockStillDecodes() {
        /// The case every mini produced before this shipped, and the case any mini
        /// produces on an unrecognised Claude Code version. The gate is the part
        /// Deck draws; losing the decoration must not cost it.
        let s = blockedGate(rendered: nil)
        XCTAssertEqual(s.gate?.questions.count, 2)
        XCTAssertNil(s.gate?.rendered)
    }

    func testAnEmptyRenderedBlockIsNotTheSameAsNone() {
        /// The mini omits the key entirely when it established nothing, so a block
        /// that IS there says the reader ran and the version matched. Keeping the
        /// distinction is what lets a future field be added without every older
        /// consumer reading "absent field" as "absent block".
        let s = blockedGate(rendered: "{}")
        XCTAssertNotNil(s.gate?.rendered)
        XCTAssertNil(s.gate?.rendered?.questionIndex)
    }

    func testAnUnknownCommitWordDecodesToNothing() {
        /// This field gates whether Deck offers to finish a multiselect at all, so a
        /// word this build does not know has to mean "do not offer". Decoding it as
        /// anything else would send a digit on the strength of a string nobody here
        /// recognises.
        let s = blockedGate(rendered: #"{"multiSelectCommit": "whatever"}"#)
        XCTAssertNotNil(s.gate?.rendered)
        XCTAssertNil(s.gate?.rendered?.multiSelectCommit)
        XCTAssertNil(SessionPaneModel.choiceCommit(in: s.gate))
    }

    // MARK: - The cursor is an observation where there is one

    private func gate(_ count: Int, kind: SessionState.Gate.Kind = .question,
                      multiSelect: Bool = false,
                      rendered: SessionState.Rendered? = nil) -> SessionState.Gate {
        SessionState.Gate(
            kind: kind, tool: nil,
            questions: (1...count).map {
                SessionState.Question(question: "Q\($0)", header: nil,
                                      options: [SessionState.Option(label: "A", detail: nil)],
                                      multiSelect: multiSelect)
            },
            hasSuggestions: false, rendered: rendered)
    }

    func testTheObservedIndexBeatsTheLocalCursor() {
        /// The desync this closes: somebody answers in the terminal, the gate's
        /// payload does not change, and Deck's own cursor stays where it was for the
        /// rest of the gate. With the tab bar read every poll it corrects itself.
        let g = gate(3, rendered: SessionState.Rendered(questionIndex: 2))
        XCTAssertEqual(SessionPaneModel.question(at: 2, in: g)?.question, "Q3")
        XCTAssertEqual(g.rendered?.questionIndex, 2)
    }

    func testAnObservedIndexPastTheEndIsNotTakenAsACursor() {
        /// One past the last question means the review tab, which `isAwaitingSubmit`
        /// answers. Taking it as a cursor would draw the last question's options over
        /// a review screen, where `2` is Cancel — the hazard #56 fixed.
        let g = gate(2, rendered: SessionState.Rendered(questionIndex: 2))
        XCTAssertNil(SessionPaneModel.question(at: 2, in: g))
    }

    // MARK: - The review tab, observed

    func testTheObservedReviewTabOverrulesACursorBehindIt() {
        /// Somebody answered the last question in the terminal, so the TUI is on the
        /// review tab while Deck's cursor is still on a question.
        XCTAssertTrue(SessionPaneModel.isAwaitingSubmit(
            index: 0, in: gate(2), observed: true))
    }

    func testTheObservedReviewTabOverrulesACursorAheadOfIt() {
        /// And the other direction, which a one-way override would miss: the user
        /// tabbed BACK to a question after Deck's cursor had run to the end. Drawing
        /// the review panel then offers to submit a gate that is showing a question.
        XCTAssertFalse(SessionPaneModel.isAwaitingSubmit(
            index: 2, in: gate(2), observed: false))
    }

    func testWithoutAnObservationTheCursorStillDecides() {
        XCTAssertTrue(SessionPaneModel.isAwaitingSubmit(index: 2, in: gate(2)))
        XCTAssertFalse(SessionPaneModel.isAwaitingSubmit(index: 1, in: gate(2)))
    }

    func testAnObservationCannotTalkAPermissionGateIntoAReviewPanel() {
        /// The guard §7.9 asks for. On a permission-class gate the digit this panel
        /// sends, `1`, means "Yes, allow the tool call" — so an observation claiming
        /// a review tab must not reach it. Kind is checked at this boundary rather
        /// than trusted from upstream.
        XCTAssertFalse(SessionPaneModel.isAwaitingSubmit(
            index: 0, in: gate(2, kind: .permission), observed: true))
    }

    func testASingleQuestionGateHasNoReviewTabToBeOn() {
        XCTAssertFalse(SessionPaneModel.isAwaitingSubmit(
            index: 0, in: gate(1), observed: true))
    }

    // MARK: - Finishing a multiselect

    func testASingleQuestionGateNeedsNoObservation() {
        /// It is trivially on its last question, so the mini's `Right` can only land
        /// on the review tab. This is what shipped and it holds with the reader
        /// blind, which is why it is not gated on `rendered`.
        XCTAssertEqual(SessionPaneModel.choiceCommit(in: gate(1, multiSelect: true)),
                       .submit)
    }

    func testAMultiQuestionGateOnItsLastQuestionEndsTheGate() {
        /// `submit` is the TUI's own button saying this is the last question, so the
        /// mini's `Right` lands on the review tab and its trailing `1` takes
        /// "Submit answers". The pane calls this one "Send answer".
        let ok = gate(3, multiSelect: true,
                      rendered: SessionState.Rendered(multiSelectCommit: .submit))
        XCTAssertEqual(SessionPaneModel.choiceCommit(in: ok), .submit)
    }

    func testAMultiQuestionGateBeforeItsLastQuestionSavesAndAdvances() {
        /// THE BUG THE OPERATOR HIT, driving a live two-question gate: this returned "may
        /// not", so the pane drew "finishing this answer has to be done in the
        /// terminal" on question 1 and there was no way to send the ticks from Deck.
        ///
        /// The dangerous keystroke was never the `Right` — that is the commit, and
        /// the ticks are already recorded. It was the trailing `1`, which off an
        /// earlier question answers it with its first option. `submit_choices` reads
        /// this same field and returns before sending that digit when it says
        /// `next`, so the pane withheld an action the mini had already made safe.
        let advancing = gate(3, multiSelect: true,
                             rendered: SessionState.Rendered(multiSelectCommit: .next))
        XCTAssertEqual(SessionPaneModel.choiceCommit(in: advancing), .next)
    }

    func testWithNoObservationAMultiQuestionGateGoesToTheTerminal() {
        /// The degradation, and the direction matters: absent means "may not",
        /// because the alternative is sending a digit on a guess about which
        /// question is on screen.
        XCTAssertNil(SessionPaneModel.choiceCommit(in: gate(3, multiSelect: true)))
        XCTAssertNil(SessionPaneModel.choiceCommit(
            in: gate(3, multiSelect: true, rendered: SessionState.Rendered())))
    }

    // MARK: - The free-text row, offered on both kinds of question again

    /// A SINGLE-SELECT QUESTION IS UNTOUCHED THROUGHOUT. §7.7's sequence — the
    /// digit focuses without confirming, the paste fills, `Enter` commits — was
    /// observed there and has held across the withdrawal and the restoration alike.
    func testTheFreeTextRowIsOfferedOnASingleSelectQuestion() {
        let g = gate(2, multiSelect: false,
                     rendered: SessionState.Rendered(freeTextRow: 4))
        XCTAssertEqual(SessionPaneModel.freeTextRow(in: g, at: 0), 4)
    }

    /// RESTORED ON A MULTISELECT, which #60 withheld and this reverses.
    ///
    /// The withdrawal was never about the ROW; it was about the SEQUENCE. On a
    /// multiselect the digit ticks the row instead of focusing it, so the paste was
    /// swallowed and the `Enter` after it ticked whatever row the highlight was
    /// still on — a phantom answer nobody chose, which reached the payload in the
    /// observation. `answerWithText` now walks the highlight onto the row through
    /// `focus-free-text` and commits through the button, so the row is usable and
    /// the card comes back.
    ///
    /// This function only decides whether a row exists to answer on. What makes
    /// that safe is `answerWithText`'s branch, pinned in `SessionAgentTests`.
    func testTheFreeTextRowIsOfferedOnAMultiselectQuestion() {
        let g = gate(2, multiSelect: true,
                     rendered: SessionState.Rendered(freeTextRow: 4))
        XCTAssertEqual(SessionPaneModel.freeTextRow(in: g, at: 0), 4)
    }

    /// The row is read off whichever question is ON SCREEN, not off the gate. A
    /// gate may mix the two kinds, and this stayed per-question through the
    /// withdrawal so that the restoration did not have to reintroduce it.
    func testTheRowFollowsTheQuestionOnScreenRatherThanTheGate() {
        let mixed = SessionState.Gate(
            kind: .question, tool: nil,
            questions: [
                SessionState.Question(question: "Which toppings?", header: nil,
                                      options: [SessionState.Option(label: "Olives", detail: nil)],
                                      multiSelect: true),
                SessionState.Question(question: "What size?", header: nil,
                                      options: [SessionState.Option(label: "Small", detail: nil)],
                                      multiSelect: false),
            ],
            hasSuggestions: false,
            rendered: SessionState.Rendered(freeTextRow: 3))
        XCTAssertEqual(SessionPaneModel.freeTextRow(in: mixed, at: 0), 3)
        XCTAssertEqual(SessionPaneModel.freeTextRow(in: mixed, at: 1), 3)
    }

    /// THE DEGRADATION IS UNCHANGED BY THE RESTORATION, and it is the guard that
    /// matters most now that the card is drawn on a multiselect: without
    /// `rendered` the mini has no picker reader, `focus-free-text` refuses, and a
    /// card offering a sequence that cannot run is worse than no card.
    func testAMultiselectCardNeedsAnObservationLikeEverythingElse() {
        XCTAssertNil(SessionPaneModel.freeTextRow(in: gate(2, multiSelect: true), at: 0))
        XCTAssertNil(SessionPaneModel.freeTextRow(
            in: gate(2, multiSelect: true, rendered: SessionState.Rendered()), at: 0))
    }

    // MARK: - The two sequences a free-text answer goes out as

    /// §7.7's sequence, unchanged. The digit focuses without confirming, the paste
    /// fills the field, `Enter` commits it.
    func testASingleSelectAnswerChoosesTheRowThenCommitsWithEnter() {
        XCTAssertEqual(SessionPaneModel.freeTextSequence(multiSelect: false, row: 4),
                       [.choose(4), .type, .key("enter")])
    }

    /// §7.11's sequence, and every step differs. The highlight is walked rather
    /// than chosen, and the commit goes through the button.
    func testAMultiselectAnswerWalksTheHighlightThenCommitsThroughTheButton() {
        XCTAssertEqual(SessionPaneModel.freeTextSequence(multiSelect: true, row: 4),
                       [.focusFreeText, .type, .submit])
    }

    /// THE SAFETY PROPERTY, and it is the whole reason #60 withdrew this card.
    ///
    /// On a multiselect a digit TICKS the row it names and `Enter` ticks whatever
    /// row the highlight sits on. Either one recorded here is an answer nobody
    /// chose, attributed to the user, on a gate that can be submitted before anyone
    /// reads the review tab — and it cannot be undone from the pane. So neither may
    /// appear in the multiselect sequence at any row.
    func testAMultiselectAnswerNeverSendsADigitOrAnEnter() {
        for row in 1...9 {
            for step in SessionPaneModel.freeTextSequence(multiSelect: true, row: row) {
                switch step {
                case .choose, .key:
                    XCTFail("\(step) ticks a row nobody chose on a multiselect")
                case .focusFreeText, .type, .submit:
                    break
                }
            }
        }
    }

    // MARK: - One commit per question, carrying the ticks and the typed words

    /// A QUESTION ANSWERED ONLY IN WORDS IS ANSWERED, and requiring a tick would
    /// strand it. The picker returns the free text comma-joined with the ticks, so
    /// the field is an input to this answer exactly as the checkboxes are.
    func testTypedWordsAloneCanCommitAMultiselect() {
        XCTAssertTrue(SessionPaneModel.canCommitQuestion(tickCount: 0, freeText: "olives, sparingly"))
    }

    func testTicksAloneStillCommit() {
        XCTAssertTrue(SessionPaneModel.canCommitQuestion(tickCount: 2, freeText: ""))
    }

    /// Nothing to send is nothing to send, and whitespace is not an answer — the
    /// same trim guards this and `answerWithText`, so a field of spaces cannot
    /// enable a button that would then refuse.
    func testAnEmptyQuestionCannotBeCommitted() {
        XCTAssertFalse(SessionPaneModel.canCommitQuestion(tickCount: 0, freeText: ""))
        XCTAssertFalse(SessionPaneModel.canCommitQuestion(tickCount: 0, freeText: "   \n "))
        XCTAssertFalse(SessionPaneModel.commitCarriesText("  \t "))
    }

    /// THE FINDING THIS CLOSES, and it came from the pane rather than from here.
    ///
    /// Restoring the free-text card put two committing buttons on a multiselect
    /// panel — the ticks button and the card's own — with nothing saying which
    /// carried the typed text. the operator pressed one and asked which they were meant to
    /// press; the top one would have discarded what he had typed. There is now one
    /// button, and its hint has to say when the words are going with it, because
    /// that is the part a reader cannot see from the ticks alone.
    func testTheCommitHintSaysWhenTheTypedWordsAreGoingToo() {
        XCTAssertEqual(SessionPaneModel.commitHint(tickCount: 1, freeText: "just checking"),
                       "1 selected, plus your own words")
        XCTAssertEqual(SessionPaneModel.commitHint(tickCount: 0, freeText: "just checking"),
                       "Sending your own words.")
    }

    /// With nothing typed the hint keeps the wording it shipped with, and the
    /// empty-state line now names both ways in rather than only ticking.
    func testTheCommitHintWithNothingTyped() {
        XCTAssertEqual(SessionPaneModel.commitHint(tickCount: 2, freeText: ""), "2 selected")
        XCTAssertEqual(SessionPaneModel.commitHint(tickCount: 0, freeText: ""),
                       "Tick what applies, or answer in your own words.")
    }

    /// The row reaches the mini only where a digit is what focuses the field. On a
    /// multiselect the mini finds the row itself by reading the pane, because the
    /// option list wraps and a row computed here would be one nobody verified.
    func testTheRowIsCarriedOnlyOnTheSingleSelectPath() {
        XCTAssertTrue(SessionPaneModel.freeTextSequence(multiSelect: false, row: 7)
            .contains(.choose(7)))
        XCTAssertFalse(SessionPaneModel.freeTextSequence(multiSelect: true, row: 7)
            .contains { if case .choose = $0 { return true } else { return false } })
    }

    /// Absent is still absent, and a cursor past the end draws nothing rather than
    /// reading a row off a question that is not there.
    func testAnUnestablishedRowStaysUnestablished() {
        XCTAssertNil(SessionPaneModel.freeTextRow(in: gate(2), at: 0))
        XCTAssertNil(SessionPaneModel.freeTextRow(in: nil, at: 0))
        XCTAssertNil(SessionPaneModel.freeTextRow(
            in: gate(2, rendered: SessionState.Rendered(freeTextRow: 4)), at: 9))
    }

    func testAPermissionGateMayNeverBeFinishedHere() {
        XCTAssertNil(SessionPaneModel.choiceCommit(
            in: gate(1, kind: .permission, multiSelect: true)))
        XCTAssertNil(SessionPaneModel.choiceCommit(
            in: gate(3, kind: .permission, multiSelect: true,
                     rendered: SessionState.Rendered(multiSelectCommit: .submit))))
    }

    // MARK: - The verbs the free-text answer is driven with

    func testTypePastesOverStdinAndNeverArgv() throws {
        /// An answer is the user's words, and an argv is visible in the process
        /// table. `send`'s text goes the same way for the same reason.
        let argv = try SessionAgent.typeArguments(target: TestHost.target, session: "deck")
        XCTAssertEqual(argv.suffix(2), ["--text", "-"])
        XCTAssertTrue(argv.contains("type"))
    }

    func testKeyNamesTheKeyAndLetsTheMiniJudgeIt() throws {
        let argv = try SessionAgent.keyArguments(target: TestHost.target, session: "deck", key: "enter")
        XCTAssertEqual(argv.last, "enter")
        XCTAssertTrue(argv.contains("key"))
    }
}
