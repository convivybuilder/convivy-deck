import XCTest
import SwiftUI
import AppKit
@testable import Deck

/// The in-session picker: the cursor through a multi-question gate, and whether
/// an option's text stays reachable. Two things, not the three #54 claimed.
///
/// Both faults were the same shape — the pane could not do something the TUI
/// could, so the answer was "use the terminal". The operator: "multi choice questions
/// need the user to switch to terminal, which should be an emergency backup,
/// not regular operating procedure."
///
/// A third, a free-text note, was shipped and removed: the mini refuses a
/// message while a session is blocked, because a picker eats a paste and the
/// paste's Enter answers whichever row is highlighted. `SessionPaneModel` keeps
/// the reasoning where the field used to be.
final class PickerTests: XCTestCase {

    private func option(_ label: String, _ detail: String? = nil) -> SessionState.Option {
        SessionState.Option(label: label, detail: detail)
    }

    private func gate(_ questions: [SessionState.Question]) -> SessionState.Gate {
        SessionState.Gate(kind: .question, tool: nil, questions: questions,
                          hasSuggestions: false)
    }

    private func question(_ text: String, multiSelect: Bool = false,
                          options: Int = 2) -> SessionState.Question {
        SessionState.Question(
            question: text, header: nil,
            options: (1...options).map { option("Option \($0)", "Why option \($0)") },
            multiSelect: multiSelect)
    }

    // MARK: - The cursor

    func testTheCursorStartsOnTheFirstQuestion() {
        let g = gate([question("First"), question("Second")])
        XCTAssertEqual(SessionPaneModel.question(at: 0, in: g)?.question, "First")
        XCTAssertEqual(SessionPaneModel.questionsRemaining(after: 0, in: g), 1)
    }

    /// THE FIX. The pane used to answer `questions.first` and send everything
    /// after it to the terminal, because the payload never says which question
    /// the TUI advanced to. It does not have to: the pane sent the digit that
    /// advanced it.
    func testAnsweringAQuestionMovesToTheNext() {
        let g = gate([question("First"), question("Second"), question("Third")])
        let after = SessionPaneModel.nextIndex(after: 0, in: g)
        XCTAssertEqual(after, 1)
        XCTAssertEqual(SessionPaneModel.question(at: after, in: g)?.question, "Second")
        XCTAssertEqual(SessionPaneModel.questionsRemaining(after: after, in: g), 1)
    }

    /// THIS TEST USED TO ASSERT THE DEFECT, and it is worth leaving a marker
    /// where it happened. It read:
    ///
    ///     XCTAssertEqual(SessionPaneModel.nextIndex(after: 1, in: g), 1)
    ///
    /// justified by a comment claiming "answering the last question resolves the
    /// whole gate and the next poll clears it". That is false for a
    /// multi-question gate — the TUI advances to a review tab and the gate stays
    /// open — so the assertion pinned the pane to a question the picker had left,
    /// and the reasoning I wrote to defend it was the reasoning that shipped the
    /// bug. See `testTheCursorRunsOnPastTheLastQuestionToTheReviewTab`.
    ///
    /// What survives is the count, which was always right.
    func testNoQuestionsRemainAfterTheLastOne() {
        let g = gate([question("First"), question("Second")])
        XCTAssertEqual(SessionPaneModel.questionsRemaining(after: 1, in: g), 0)
    }

    func testASingleQuestionGateNeverAdvances() {
        let g = gate([question("Only one")])
        XCTAssertEqual(SessionPaneModel.nextIndex(after: 0, in: g), 0)
        XCTAssertEqual(SessionPaneModel.questionsRemaining(after: 0, in: g), 0)
    }

    /// An index past the end draws nothing rather than trapping. The cursor is
    /// Deck's guess at where the TUI is, and a guess that crashes the pane when
    /// it turns out wrong is worse than one that draws an empty beat.
    func testAnOutOfRangeCursorIsSurvivable() {
        let g = gate([question("First")])
        XCTAssertNil(SessionPaneModel.question(at: 5, in: g))
        XCTAssertNil(SessionPaneModel.question(at: -1, in: g))
        XCTAssertNil(SessionPaneModel.question(at: 0, in: nil))
        XCTAssertEqual(SessionPaneModel.questionsRemaining(after: 0, in: nil), 0)
        XCTAssertEqual(SessionPaneModel.nextIndex(after: 3, in: nil), 3)
    }

    // MARK: - The review tab, and the submit that answers the wrong question

    /// THE DEFECT THIS FIXES, observed against Claude Code 2.1.220. After the
    /// last question of a multi-question gate is answered the TUI advances to a
    /// `✔ Submit` review tab and the gate stays OPEN. The cursor used to stop at
    /// the last question, so the pane went on drawing that question's cards at a
    /// picker that had moved on — and the review tab reads `1. Submit answers` /
    /// `2. Cancel`, so a click on what the pane called option 2 discarded every
    /// answer.
    func testTheCursorRunsOnPastTheLastQuestionToTheReviewTab() {
        let g = gate([question("First"), question("Second")])
        let afterFirst = SessionPaneModel.nextIndex(after: 0, in: g)
        XCTAssertEqual(afterFirst, 1)
        XCTAssertFalse(SessionPaneModel.isAwaitingSubmit(index: afterFirst, in: g))

        let afterLast = SessionPaneModel.nextIndex(after: afterFirst, in: g)
        XCTAssertEqual(afterLast, 2, "the cursor stopped on the last question again")
        XCTAssertTrue(SessionPaneModel.isAwaitingSubmit(index: afterLast, in: g))
        XCTAssertNil(SessionPaneModel.question(at: afterLast, in: g),
                     "a stale question is drawn over the review tab")
    }

    /// A single-question gate resolves on its digit and shows no review tab, so
    /// the cursor must not run past it and offer a submit that answers nothing.
    func testASingleQuestionGateNeverAwaitsSubmit() {
        let g = gate([question("Only one")])
        let after = SessionPaneModel.nextIndex(after: 0, in: g)
        XCTAssertEqual(after, 0)
        XCTAssertFalse(SessionPaneModel.isAwaitingSubmit(index: after, in: g))
        XCTAssertFalse(SessionPaneModel.isAwaitingSubmit(index: 5, in: g),
                       "even a runaway index must not offer submit on one question")
    }

    func testTheCursorDoesNotRunPastTheReviewTab() {
        let g = gate([question("First"), question("Second")])
        XCTAssertEqual(SessionPaneModel.nextIndex(after: 2, in: g), 2)
        XCTAssertEqual(SessionPaneModel.nextIndex(after: 9, in: g), 2)
    }

    /// A SINGLE-QUESTION GATE COMMITS WITH NO OBSERVATION AT ALL, and a
    /// multi-question one commits only where the mini read the TUI's button. The
    /// unread case is the degradation: the pane cannot tell which question is on
    /// screen, and `submit_choices` would press `Right` into whatever is next.
    /// #54 broke this by answering every question in the pane.
    func testTheMultiselectCommitNeedsAReadButtonInAMultiQuestionGate() {
        XCTAssertEqual(SessionPaneModel.choiceCommit(
            in: gate([question("Only one", multiSelect: true)])), .submit)
        XCTAssertNil(SessionPaneModel.choiceCommit(
            in: gate([question("First", multiSelect: true), question("Second")])),
            "with the button unread the pane cannot tell which question is live")
        XCTAssertNil(SessionPaneModel.choiceCommit(in: nil))
    }

    /// A PERMISSION GATE'S DIGITS DO NOT MEAN WHAT A QUESTION'S DIGITS MEAN.
    /// On a permission prompt `1` is "Yes, allow the tool call", so neither the
    /// review panel nor the multiselect submit may be offered for one.
    ///
    /// Raised by security review as PLAUSIBLE rather than exploitable: the mini
    /// normalises permission gates to a single question, so the count tests
    /// already reject them. That is a fact about the mini, not about this code,
    /// and the `kind` field was decoded and going unread.
    func testAPermissionGateOffersNeitherSubmitPath() {
        let permission = SessionState.Gate(
            kind: .permission, tool: "Bash",
            questions: [question("Do you want to proceed?", multiSelect: true),
                        question("Second")],
            hasSuggestions: true)

        XCTAssertFalse(SessionPaneModel.isAwaitingSubmit(index: 2, in: permission),
                       "a review panel on a permission gate would send `1` = allow")
        XCTAssertNil(SessionPaneModel.choiceCommit(in: permission))

        // The same shapes on a question gate still work, so the guard is not a
        // blanket refusal.
        let asking = gate([question("First", multiSelect: true), question("Second")])
        XCTAssertTrue(SessionPaneModel.isAwaitingSubmit(index: 2, in: asking))
        XCTAssertEqual(SessionPaneModel.choiceCommit(
            in: gate([question("Only one", multiSelect: true)])), .submit)
    }

    // MARK: - The gate area, measured

    /// THE REPORTED FAULT, correctly stated. "The text runs out of the box and
    /// there's no way to see it" is vertical, not horizontal: an option's
    /// description wraps at whatever width the pane proposes either way, but a
    /// question with several long options grows taller than the composer's share
    /// of the pane, and the pane's `VStack` clipped the excess with nothing to
    /// scroll. "No way to see it" was the load-bearing half.
    ///
    /// I read it as horizontal first, and the first version of this test passed
    /// against the unfixed code — which is how I found out. `fittingSize` reports
    /// an IDEAL width (1017pt for one card), so the measurement wrapped
    /// regardless of the modifiers supposedly under test.
    ///
    /// WHAT THIS CAN AND CANNOT MEASURE. SwiftUI lays out inside its own
    /// `ScrollView`, so the AppKit `documentView` underneath is empty in a
    /// headless pass — content-versus-clip geometry is not readable here, and
    /// asserting on it would be asserting on zero. The guard is therefore
    /// structural: a scroller EXISTS, and the content is tall enough to need it.
    /// Those two together are what "reachable" means for this fault.
    @MainActor
    func testALongQuestionGetsAScrollerRatherThanBeingClipped() {
        let host = hostGate(optionCount: 6, detailLength: .long, height: 240)
        let scrollers = scrollViews(in: host)

        XCTAssertEqual(scrollers.count, 1,
                       "\(scrollers.count) scroll views in the gate; with none, every "
                       + "option past the composer's share of the height is clipped "
                       + "and cannot be reached by any means")

        XCTAssertEqual(
            host.fittingSize.height, GatePanel.maximumHeight, accuracy: 1,
            "the fixture did not reach the gate's ceiling, so it does not need a "
            + "scroller and proves nothing about one")
    }

    /// The gate does not grow without limit either: past its ceiling it scrolls,
    /// rather than squeezing the conversation above it to nothing.
    @MainActor
    func testTheGateStopsGrowingAtItsCeiling() {
        let host = hostGate(optionCount: 9, detailLength: .long, height: 900)
        XCTAssertLessThanOrEqual(host.fittingSize.height, GatePanel.maximumHeight + 1,
                                 "the gate would take the whole pane")
    }

    /// A short question must NOT need scrolling. The scroller is for the long
    /// case; a gate that scrolls when three lines would fit reads as broken.
    @MainActor
    func testAShortQuestionFitsWellWithinTheCeiling() {
        let host = hostGate(optionCount: 2, detailLength: .short, height: 340)
        XCTAssertLessThan(host.fittingSize.height, GatePanel.maximumHeight,
                          "a short question is filling the gate's whole allowance")
    }

    // MARK: - Hosting

    private enum DetailLength {
        case short, long
        var text: String {
            switch self {
            case .short: return "Short."
            case .long:
                return "The cell-width fix is on main but unreleased, so waiting keeps "
                     + "Deck on tagged releases, which is what the terminal pane's "
                     + "drift-proof-fallback role asks for, and the gain from not "
                     + "waiting is a single spacing fix nobody has asked for twice."
            }
        }
    }

    /// Somewhere for the panel's `freeText` binding to point in a host that has no
    /// model behind it. `.constant` would refuse the write the text field makes.
    @MainActor private static var hostedFreeText = ""

    @MainActor
    private func hostGate(optionCount: Int, detailLength: DetailLength,
                          height: CGFloat, freeTextRow: Int? = nil) -> NSHostingView<some View> {
        let q = SessionState.Question(
            question: "Which approach for the SwiftTerm bump, given the tag has not moved?",
            header: "SwiftTerm",
            options: (1...optionCount).map {
                SessionState.Option(label: "Option \($0)", detail: detailLength.text)
            },
            multiSelect: false)
        let panel = GatePanel(gate: gate([q]), question: q, questionIndex: 0,
                              questionsRemaining: 0, ticked: [],
                              isAwaitingSubmit: false, choiceCommit: .submit,
                              freeTextRow: freeTextRow,
                              freeText: Binding(
                                get: { PickerTests.hostedFreeText },
                                set: { PickerTests.hostedFreeText = $0 }),
                              onChoose: { _, _ in },
                              onSubmit: {}, onSubmitAnswers: {},
                              onAnswerWithText: {},
                              onFallBackToTerminal: {})
        let host = NSHostingView(rootView: panel)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let here = (view as? NSScrollView).map { [$0] } ?? []
        return here + view.subviews.flatMap(scrollViews)
    }

    // MARK: - The free-text card

    /// Editable text fields in the hierarchy. A `Text` renders as something else
    /// entirely, so this finds the card's input and not its label.
    @MainActor
    private func editableFields(in view: NSView) -> [NSTextField] {
        let here: [NSTextField]
        if let field = view as? NSTextField, field.isEditable { here = [field] } else { here = [] }
        return here + view.subviews.flatMap(editableFields)
    }

    @MainActor
    func testNoFreeTextCardWhenNobodyReadTheRow() {
        /// ABSENT IS NOT "NO SUCH ROW". The picker may well be offering one; what is
        /// missing is an observation of which row it sits on. Deck sends that number
        /// as a digit, so guessing it would answer a real option — drawing nothing is
        /// the only honest response, and the terminal is how it gets used.
        let host = hostGate(optionCount: 3, detailLength: .short, height: 300,
                            freeTextRow: nil)
        XCTAssertTrue(editableFields(in: host).isEmpty,
                      "a card was offered for a row nobody established")
    }

    @MainActor
    func testTheFreeTextCardAppearsOnceTheRowIsObserved() {
        let host = hostGate(optionCount: 3, detailLength: .short, height: 300,
                            freeTextRow: 4)
        XCTAssertEqual(editableFields(in: host).count, 1)
    }

    // NO TEST THAT THE CARD SHOWS ITS ROW NUMBER, and the reason is worth leaving
    // here so the obvious one does not get written again. The card does show it —
    // the row the picker uses, so a user moving between the pane and the terminal
    // mid-question does not have to re-map the numbering — but a SwiftUI `Text`
    // does not appear in this hierarchy as an `NSTextField`, unlike the editable
    // field above, so an introspection test for it asserts against something it
    // cannot see. It passed for the wrong reason before it was removed.

    // MARK: - ⌘1–9 selects the matching option

    /// BOUND TO POSITION, NOT LABEL. `shortcutKey` takes the same `number`
    /// `OptionCard` prints and `onChoose` sends, so there is no second path
    /// that could compute a different digit for the same card.
    func testShortcutKeyMatchesTheOptionsOwnNumber() {
        for n in 1...9 {
            XCTAssertEqual(OptionCard.shortcutKey(for: n)?.character, Character("\(n)"),
                           "option \(n) must bind to ⌘\(n), not some other digit")
        }
    }

    /// NINE IS THE CEILING because `SessionAgent` validates a choice in
    /// `1...9` — a tenth card must never carry a shortcut it cannot send.
    func testNoShortcutPastNine() {
        XCTAssertNil(OptionCard.shortcutKey(for: 10))
        XCTAssertNil(OptionCard.shortcutKey(for: 11))
    }

    /// Zero and negative aren't option numbers at all — `question.options`
    /// is enumerated from 1, but the guard holds for any input outside it.
    func testNoShortcutBelowOne() {
        XCTAssertNil(OptionCard.shortcutKey(for: 0))
        XCTAssertNil(OptionCard.shortcutKey(for: -1))
    }

    // MARK: - Committing a multiselect, and what the button is called

    /// THE BUG, at the surface an operator met it on. Question 1 of a two-question gate
    /// with the button read as `next` offered no way to commit at all — the pane
    /// drew only the line telling him to finish in the terminal — so the two names
    /// are the fix and the wording is worth holding.
    func testTheCommitButtonIsNamedForWhatItDoes() {
        XCTAssertEqual(SessionPaneModel.choiceCommitLabel(.submit), "Send answer")
        XCTAssertEqual(SessionPaneModel.choiceCommitLabel(.next),
                       "Save and go to the next question")
        XCTAssertNotEqual(SessionPaneModel.choiceCommitLabel(.next),
                          SessionPaneModel.choiceCommitLabel(.submit),
                          "one name for two different events tells the user the "
                          + "wrong thing on whichever it fits less")
    }

    // NO TEST THAT THE BUTTON IS ON SCREEN, for the reason the row-number note
    // above gives and for one more measured here: a SwiftUI `Button` inside an
    // `NSHostingView` surfaces as neither an `NSButton` nor an accessibility
    // element carrying a title. Both were tried against a hosted panel with a
    // commit present; both found an empty list, which would have made the
    // "no button when the commit is unread" case pass on a hierarchy that had no
    // buttons in it under any condition. What the pane does with the two cases is
    // held by `choiceCommit` and `choiceCommitLabel` instead.
}
