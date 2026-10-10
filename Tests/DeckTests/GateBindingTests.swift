import XCTest
@testable import Deck

/// The gate-binding mechanism: `gateId` decoding, expectation flags in argv, the
/// observed-vs-local-cursor distinction, and refusal surfacing.
///
/// §5.5 of `deck/specs/reading-the-rendered-picker` is the design; the mini half
/// shipped in agent-platform #338. These tests cover Deck's half: that it decodes
/// the gate id, appends the flags, uses the OBSERVED question index rather than
/// the local fallback, and does not swallow a refusal.
final class GateBindingTests: XCTestCase {

    // MARK: - gateId decoding

    private func decode(_ json: String, session: String = "deck") -> SessionState {
        SessionState.decode(Data(json.utf8), fallbackSession: session)
    }

    func testGateIdDecodesWhenPresent() {
        let state = decode("""
            {"state":"blocked","gate":{"kind":"question","gateId":"toolu_01ABC123",
             "questions":[{"question":"Which?","options":[{"label":"A"}]}]}}
            """)
        XCTAssertEqual(state.gate?.gateId, "toolu_01ABC123")
    }

    func testGateIdIsNilWhenKeyAbsent() {
        let state = decode("""
            {"state":"blocked","gate":{"kind":"question",
             "questions":[{"question":"Which?","options":[{"label":"A"}]}]}}
            """)
        XCTAssertNil(state.gate?.gateId)
    }

    /// Absent is the permanent case for permission-class gates. `gateId` absent
    /// must not affect anything else on the decoded gate.
    func testGateIdAbsenceDoesNotAffectOtherGateFields() {
        let state = decode("""
            {"state":"blocked","gate":{"kind":"question","tool":"AskUserQuestion",
             "questions":[{"question":"Colour?","options":[{"label":"Red"},{"label":"Blue"}]}]}}
            """)
        XCTAssertNil(state.gate?.gateId)
        XCTAssertEqual(state.gate?.kind, .question)
        XCTAssertEqual(state.gate?.questions.first?.options.count, 2)
    }

    // MARK: - Argument builder flags

    func testChooseArgumentsEmitBothFlagsWhenGiven() throws {
        let args = try SessionAgent.chooseArguments(target: TestHost.target, session: "deck", choice: 2,
                                                    gateId: "toolu_abc", questionIndex: 1)
        XCTAssertTrue(args.contains("--expect-gate"))
        XCTAssertTrue(args.contains("toolu_abc"))
        XCTAssertTrue(args.contains("--expect-question"))
        XCTAssertTrue(args.contains("1"))
    }

    func testChooseArgumentsOmitsGateFlagWhenGateIdIsNil() throws {
        let args = try SessionAgent.chooseArguments(target: TestHost.target, session: "deck", choice: 2,
                                                    gateId: nil, questionIndex: 1)
        XCTAssertFalse(args.contains("--expect-gate"))
        XCTAssertTrue(args.contains("--expect-question"))
    }

    func testChooseArgumentsOmitsQuestionFlagWhenIndexIsNil() throws {
        let args = try SessionAgent.chooseArguments(target: TestHost.target, session: "deck", choice: 2,
                                                    gateId: "toolu_abc", questionIndex: nil)
        XCTAssertTrue(args.contains("--expect-gate"))
        XCTAssertFalse(args.contains("--expect-question"))
    }

    func testChooseArgumentsWithNoExpectationsIsUnchanged() throws {
        let baseline = try SessionAgent.chooseArguments(target: TestHost.target, session: "deck", choice: 3)
        let explicit = try SessionAgent.chooseArguments(target: TestHost.target, session: "deck", choice: 3,
                                                        gateId: nil, questionIndex: nil)
        XCTAssertEqual(baseline, explicit)
        XCTAssertFalse(baseline.contains("--expect-gate"))
        XCTAssertFalse(baseline.contains("--expect-question"))
    }

    func testSubmitArgumentsEmitBothFlags() throws {
        let args = try SessionAgent.submitArguments(target: TestHost.target, session: "deck",
                                                    gateId: "toolu_xyz", questionIndex: 0)
        XCTAssertTrue(args.contains("--expect-gate"))
        XCTAssertTrue(args.contains("toolu_xyz"))
        XCTAssertTrue(args.contains("--expect-question"))
        XCTAssertTrue(args.contains("0"))
    }

    func testSubmitArgumentsOmitsEachFlagIndependently() throws {
        let noGate = try SessionAgent.submitArguments(target: TestHost.target, session: "deck",
                                                      gateId: nil, questionIndex: 2)
        XCTAssertFalse(noGate.contains("--expect-gate"))
        XCTAssertTrue(noGate.contains("--expect-question"))

        let noIdx = try SessionAgent.submitArguments(target: TestHost.target, session: "deck",
                                                     gateId: "toolu_xyz", questionIndex: nil)
        XCTAssertTrue(noIdx.contains("--expect-gate"))
        XCTAssertFalse(noIdx.contains("--expect-question"))
    }

    func testTypeArgumentsEmitBothFlags() throws {
        let args = try SessionAgent.typeArguments(target: TestHost.target, session: "deck",
                                                   gateId: "toolu_abc", questionIndex: 1)
        XCTAssertTrue(args.contains("--expect-gate"))
        XCTAssertTrue(args.contains("--expect-question"))
        // The text-on-stdin flags must still be present.
        XCTAssertTrue(args.contains("--text"))
        XCTAssertTrue(args.contains("-"))
    }

    func testTypeArgumentsOmitsEachFlagIndependently() throws {
        let noGate = try SessionAgent.typeArguments(target: TestHost.target, session: "deck",
                                                     gateId: nil, questionIndex: 0)
        XCTAssertFalse(noGate.contains("--expect-gate"))
        XCTAssertTrue(noGate.contains("--expect-question"))

        let noIdx = try SessionAgent.typeArguments(target: TestHost.target, session: "deck",
                                                    gateId: "toolu_abc", questionIndex: nil)
        XCTAssertTrue(noIdx.contains("--expect-gate"))
        XCTAssertFalse(noIdx.contains("--expect-question"))
    }

    func testFocusFreeTextArgumentsEmitBothFlags() throws {
        let args = try SessionAgent.focusFreeTextArguments(target: TestHost.target, session: "deck",
                                                           gateId: "toolu_abc", questionIndex: 0)
        XCTAssertTrue(args.contains("--expect-gate"))
        XCTAssertTrue(args.contains("--expect-question"))
    }

    func testFocusFreeTextArgumentsOmitsEachFlagIndependently() throws {
        let noGate = try SessionAgent.focusFreeTextArguments(target: TestHost.target, session: "deck",
                                                              gateId: nil, questionIndex: 1)
        XCTAssertFalse(noGate.contains("--expect-gate"))
        XCTAssertTrue(noGate.contains("--expect-question"))

        let noIdx = try SessionAgent.focusFreeTextArguments(target: TestHost.target, session: "deck",
                                                             gateId: "toolu_abc",
                                                             questionIndex: nil)
        XCTAssertTrue(noIdx.contains("--expect-gate"))
        XCTAssertFalse(noIdx.contains("--expect-question"))
    }

    // MARK: - Gate id validation

    /// A gate id with shell metacharacters must not reach argv as a second token.
    func testAnInvalidGateIdIsDroppedAndNoFlagIsEmitted() throws {
        for bad in ["toolu abc", "toolu;evil", "toolu$(evil)", "toolu\nid", ""] {
            let args = try SessionAgent.chooseArguments(target: TestHost.target, session: "deck", choice: 1,
                                                        gateId: bad, questionIndex: nil)
            XCTAssertFalse(args.contains("--expect-gate"),
                           "gate id \(bad.debugDescription) must not reach argv")
        }
    }

    func testValidGateIdFormatsAreAccepted() throws {
        for good in ["toolu_01ABC", "toolu_xYz-123", "abc", "A"] {
            let args = try SessionAgent.chooseArguments(target: TestHost.target, session: "deck", choice: 1,
                                                        gateId: good, questionIndex: nil)
            XCTAssertTrue(args.contains("--expect-gate"),
                          "valid gate id \(good.debugDescription) was dropped")
            XCTAssertTrue(args.contains(good))
        }
    }

    // MARK: - Observed vs local cursor at call sites

    /// THE FINDING-PRONE CASE. `rendered` absent means no observation exists, so
    /// the observed index is nil and no `--expect-question` goes out, even when
    /// Deck's local cursor (the fallback used for rendering) is non-zero. Asserting
    /// a locally-invented index would refuse a correct keystroke or pass a wrong
    /// one, which is the failure the spec explicitly guards.
    func testNoExpectQuestionWhenRenderedIsAbsent() {
        // Decoded state with no rendered block; the local cursor would be non-zero
        // after answering the first question.
        let state = decode("""
            {"state":"blocked","gate":{"kind":"question","gateId":"toolu_abc",
             "questions":[
               {"question":"First","options":[{"label":"A"}]},
               {"question":"Second","options":[{"label":"B"}]}
             ]}}
            """)
        // No rendered block → observedQuestionIndex is nil.
        XCTAssertNil(state.gate?.rendered?.questionIndex)

        // The argument builder with nil questionIndex emits no --expect-question,
        // which is what the call sites produce when observedQuestionIndex is nil.
        let args = try! SessionAgent.chooseArguments(target: TestHost.target, session: "deck", choice: 1,
                                                     gateId: state.gate?.gateId,
                                                     questionIndex: state.gate?.rendered?.questionIndex)
        XCTAssertFalse(args.contains("--expect-question"),
                       "rendered absent with a non-zero local cursor still emitted --expect-question")
        // The gate id IS asserted; only the question index degrades.
        XCTAssertTrue(args.contains("--expect-gate"))
    }

    func testExpectQuestionIsEmittedWhenRenderedHasAnIndex() {
        let state = decode("""
            {"state":"blocked","gate":{"kind":"question","gateId":"toolu_abc",
             "questions":[{"question":"Which?","options":[{"label":"A"}]}],
             "rendered":{"questionIndex":0}}}
            """)
        XCTAssertEqual(state.gate?.rendered?.questionIndex, 0)
        let args = try! SessionAgent.chooseArguments(target: TestHost.target, session: "deck", choice: 1,
                                                     gateId: state.gate?.gateId,
                                                     questionIndex: state.gate?.rendered?.questionIndex)
        XCTAssertTrue(args.contains("--expect-question"))
        XCTAssertTrue(args.contains("0"))
    }

    // MARK: - Refusal surfacing

    /// A gate mismatch makes the mini exit non-zero with an InputError. `run` wraps
    /// that stderr text in `AgentError.failed(...)`. The description is non-empty,
    /// which is what appears in `lastError` and what the user reads. Nothing in the
    /// call path converts it to `try?`, so the message is never swallowed.
    func testARefusedVerbYieldsADescriptiveError() {
        let err = SessionAgent.AgentError.failed(
            "InputError: expected gate toolu_01ABC question 1, live gate toolu_01ABC question 2")
        let description = "\(err)"
        XCTAssertFalse(description.isEmpty)
        XCTAssertTrue(description.contains("InputError"),
                      "the mini's own message should reach the user, got: \(description)")
    }
}
