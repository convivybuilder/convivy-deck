import XCTest
@testable import Deck

/// `Slate.decode`/`SlateCard.decode` — what `session-agent slate` answers.
/// Shapes pinned against macstudio's live `session-agent` (agent-platform#752,
/// CQ-358); see issue_01M3WPYD8M0P8PD20Y3ZBNGBWG's PR body for exactly what
/// was run to confirm them.
final class SlateTests: XCTestCase {

    private func decode(_ json: String, session: String = "deck") -> Slate? {
        Slate.decode(Data(json.utf8), fallbackSession: session)
    }

    func testEmptyCardsDecodesToAnEmptyList() {
        let slate = decode(#"{"ok": true, "session": "deck", "cards": []}"#)
        XCTAssertEqual(slate?.session, "deck")
        XCTAssertEqual(slate?.cards, [])
    }

    /// The definition of done's own test case: a question holding quotes,
    /// `$`, backticks and a newline must decode exactly, byte for byte, with
    /// no escaping or interpretation left in it.
    func testAnAskQuestionDecodesByteForByte() {
        let question = "A question holding quotes \"like this\", a $VAR, `backticks`, and\na newline."
        let raw = try! JSONSerialization.data(withJSONObject: [
            "ok": true, "session": "deck",
            "cards": [[
                "id": "a-dd5np4", "kind": "ask", "state": "open",
                "question": question, "answer_draft": NSNull(), "answer": NSNull(),
            ]],
        ])
        let slate = Slate.decode(raw, fallbackSession: "deck")
        guard case .ask(let ask) = slate?.cards.first else {
            return XCTFail("expected one ask card")
        }
        XCTAssertEqual(ask.question, question)
        XCTAssertEqual(ask.id, "a-dd5np4")
        XCTAssertEqual(ask.state, .open)
        XCTAssertNil(ask.answerDraft)
        XCTAssertNil(ask.answer)
    }

    func testAnAnsweredAskCarriesItsDraftAndAnswer() {
        let slate = decode("""
            {"ok": true, "session": "deck", "cards": [
              {"id": "a-1", "kind": "ask", "state": "answered", "question": "q",
               "answer_draft": "latest draft", "answer": "sent answer"}
            ]}
            """)
        guard case .ask(let ask) = slate?.cards.first else {
            return XCTFail("expected one ask card")
        }
        XCTAssertEqual(ask.state, .answered)
        XCTAssertEqual(ask.answerDraft, "latest draft")
        XCTAssertEqual(ask.answer, "sent answer")
    }

    /// A closed set agreed with the Bosun — anything else decodes to
    /// `.unrecognized` rather than a guess at the nearest known state.
    func testAnUnrecognisedAskStateIsUnrecognizedNotAGuess() {
        let slate = decode("""
            {"ok": true, "session": "deck", "cards": [
              {"id": "a-1", "kind": "ask", "state": "pondering", "question": "q"}
            ]}
            """)
        guard case .ask(let ask) = slate?.cards.first else {
            return XCTFail("expected one ask card")
        }
        XCTAssertEqual(ask.state, .unrecognized("pondering"))
    }

    func testANoteCardDecodesItsText() {
        let slate = decode("""
            {"ok": true, "session": "deck", "cards": [
              {"id": "n-1", "kind": "note", "state": "draft", "text": "hold this"}
            ]}
            """)
        guard case .note(let note) = slate?.cards.first else {
            return XCTFail("expected one note card")
        }
        XCTAssertEqual(note.text, "hold this")
        XCTAssertEqual(note.state, .draft)
    }

    // MARK: - "an unreadable card shows as state unknown and is never dropped"

    func testACardWithNoKindIsUnknownButKeepsItsId() {
        let slate = decode("""
            {"ok": true, "session": "deck", "cards": [
              {"id": "x-1", "state": "open"}
            ]}
            """)
        XCTAssertEqual(slate?.cards, [.unknown(id: "x-1")])
    }

    func testAnUnrecognisedKindIsUnknown() {
        let slate = decode("""
            {"ok": true, "session": "deck", "cards": [
              {"id": "x-1", "kind": "reminder"}
            ]}
            """)
        XCTAssertEqual(slate?.cards, [.unknown(id: "x-1")])
    }

    func testAnAskMissingTheQuestionIsUnknown() {
        let slate = decode("""
            {"ok": true, "session": "deck", "cards": [
              {"id": "a-1", "kind": "ask", "state": "open"}
            ]}
            """)
        XCTAssertEqual(slate?.cards, [.unknown(id: "a-1")])
    }

    func testANoteMissingTheTextIsUnknown() {
        let slate = decode("""
            {"ok": true, "session": "deck", "cards": [
              {"id": "n-1", "kind": "note", "state": "draft"}
            ]}
            """)
        XCTAssertEqual(slate?.cards, [.unknown(id: "n-1")])
    }

    /// SECURITY: the id reaches ssh argv verbatim in
    /// `SessionAgent.slateEditArguments`/`slateSendArguments`, so a card id
    /// holding shell metacharacters must never decode into an `.ask`/`.note`
    /// — it demotes the whole card to `.unknown(id: nil)`, the same as a
    /// missing `question`/`text`, rather than carrying the hostile value
    /// forward. Raised in review.
    func testAHostileIdDemotesTheCardToUnknown() {
        let slate = decode("""
            {"ok": true, "session": "deck", "cards": [
              {"id": "a-1; rm -rf ~", "kind": "ask", "state": "open", "question": "q"}
            ]}
            """)
        XCTAssertEqual(slate?.cards, [.unknown(id: nil)])
    }

    func testANonObjectCardEntryIsUnknownWithNoId() {
        let slate = decode("""
            {"ok": true, "session": "deck", "cards": ["not an object"]}
            """)
        XCTAssertEqual(slate?.cards, [.unknown(id: nil)])
    }

    /// A bad card costs only itself — the entries around it still decode,
    /// exactly the per-field degrade this type exists for.
    func testOneUnreadableCardDoesNotCostItsNeighbours() {
        let slate = decode("""
            {"ok": true, "session": "deck", "cards": [
              {"id": "a-1", "kind": "ask", "state": "open", "question": "q1"},
              {"id": "x-2", "state": "mystery"},
              {"id": "a-3", "kind": "ask", "state": "open", "question": "q3"}
            ]}
            """)
        XCTAssertEqual(slate?.cards.count, 3)
        guard case .ask(let first) = slate?.cards[0] else { return XCTFail("expected an ask") }
        XCTAssertEqual(first.question, "q1")
        XCTAssertEqual(slate?.cards[1], .unknown(id: "x-2"))
        guard case .ask(let third) = slate?.cards[2] else { return XCTFail("expected an ask") }
        XCTAssertEqual(third.question, "q3")
    }

    // MARK: - The envelope itself

    func testUnparseableOutputDecodesToNil() {
        XCTAssertNil(decode("not json at all"))
    }

    func testAnEnvelopeWithNoSessionFallsBackToTheAskedName() {
        let slate = decode(#"{"ok": true, "cards": []}"#, session: "hollis")
        XCTAssertEqual(slate?.session, "hollis")
    }

    func testAMissingCardsArrayDecodesToAnEmptyList() {
        let slate = decode(#"{"ok": true, "session": "deck"}"#)
        XCTAssertEqual(slate?.cards, [])
    }
}
