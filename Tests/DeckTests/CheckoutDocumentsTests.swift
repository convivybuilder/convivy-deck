import XCTest
@testable import Deck

/// `CheckoutDocuments.decode`, its grouping by kind, and the model that reads
/// it for the cockpit's Checkout panel.
///
/// The cases that matter are the ones where a wrong reading would draw a
/// wrong claim: a named reason decoded as an empty list says the checkout
/// brought nothing, and a slow reply landing under the next session draws one
/// session's documents under another.
final class CheckoutDocumentsTests: XCTestCase {

    private func decode(_ json: String) -> CheckoutDocuments? {
        CheckoutDocuments.decode(Data(json.utf8))
    }

    private func doc(_ id: String, _ kind: String) -> CheckoutDocuments.Document {
        .init(id: id, kind: kind)
    }

    // MARK: - decode

    func testDecodesTheListShapeInTheOrderSent() {
        let out = decode("""
        {"session": "orient", "profile": "orient/daytime", "materialized_at": "2026-09-14T20:00:00Z",
         "documents": [{"id": "orient/bead/orient", "kind": "bead"},
                       {"id": "platform/decisions/0002-x", "kind": "decision"}]}
        """)
        XCTAssertEqual(out, .listed(profile: "orient/daytime", documents: [
            doc("orient/bead/orient", "bead"), doc("platform/decisions/0002-x", "decision"),
        ]))
    }

    func testDecodesEveryNamedReason() {
        XCTAssertEqual(decode(#"{"session": "x", "reason": "no_such_session"}"#), .unavailable(.noSuchSession))
        XCTAssertEqual(decode(#"{"session": "x", "reason": "not_materialized"}"#), .unavailable(.notIndividuated))
        XCTAssertEqual(decode(#"{"session": "x", "reason": "no_document_record"}"#), .unavailable(.noDocumentRecord))
        XCTAssertEqual(decode(#"{"session": "x", "reason": "unreadable_record"}"#), .unavailable(.unreadableRecord))
    }

    /// A reason this build does not know still reaches the panel in the
    /// host's words, never as an empty list.
    func testAnUnknownReasonIsKeptVerbatim() {
        let out = decode(#"{"session": "x", "reason": "profile_moved"}"#)
        XCTAssertEqual(out, .unavailable(.other("profile_moved")))
        XCTAssertTrue(CheckoutDocuments.Reason.other("profile_moved").explanation.contains("profile_moved"))
    }

    /// The run pane names `instruction-block` in full; the Checkout panel's
    /// title for that kind must not change with it.
    func testTheCheckoutPanelsTitleForInstructionBlocksIsUnchanged() {
        XCTAssertEqual(CheckoutDocuments.groupTitle(kind: "instruction-block"), "Instruction-block")
    }

    /// The verb exits 0 for everything, so a reply with neither shape has to
    /// fail here rather than decode to something plausible.
    func testAReplyWithNeitherShapeDoesNotDecode() {
        XCTAssertNil(decode(#"{"session": "x"}"#))
        XCTAssertNil(decode("not json"))
        XCTAssertNil(decode("[]"))
    }

    func testAnEntryWithNoIdIsDroppedAndOneWithNoKindIsKept() {
        let out = decode("""
        {"profile": "p", "documents": [{"kind": "bead"}, {"id": "", "kind": "bead"}, {"id": "a/b/c"}]}
        """)
        XCTAssertEqual(out, .listed(profile: "p", documents: [doc("a/b/c", "")]))
    }

    func testAnEmptyListDecodesAsAnEmptyListNotAReason() {
        XCTAssertEqual(decode(#"{"profile": "p", "documents": []}"#), .listed(profile: "p", documents: []))
    }

    func testTheSlugIsTheIdsLastSegment() {
        XCTAssertEqual(doc("deck/decisions/0002-verbs", "decision").slug, "0002-verbs")
    }

    // MARK: - groups

    /// The orienting kinds lead and open; the known long kinds follow,
    /// collapsed; unrecognised kinds come last, alphabetically.
    func testGroupsOrderKindsAndOpenOnlyTheOrientingOnes() {
        let documents = [
            doc("a/agents/z", "agent"), doc("a/decisions/1", "decision"), doc("a/zines/1", "zine"),
            doc("a/overviews/1", "overview"), doc("a/bead/a", "bead"), doc("a/x/1", ""),
            doc("a/architecture/1", "architecture"), doc("a/decisions/2", "decision"),
        ]
        let groups = CheckoutDocuments.groups(documents)
        XCTAssertEqual(groups.map(\.kind), ["bead", "overview", "architecture", "decision", "agent", "", "zine"])
        XCTAssertEqual(groups.map(\.isExpandedByDefault), [true, true, true, false, false, false, false])
        XCTAssertEqual(groups.first { $0.kind == "decision" }?.documents.map(\.id), ["a/decisions/1", "a/decisions/2"])
    }

    func testGroupTitles() {
        XCTAssertEqual(CheckoutDocuments.groupTitle(kind: "decision"), "Decisions")
        XCTAssertEqual(CheckoutDocuments.groupTitle(kind: ""), "Other")
        XCTAssertEqual(CheckoutDocuments.groupTitle(kind: "zine"), "Zine")
    }

    // MARK: - the panel index count

    func testTheIndexCountsOnlyALoadedList() {
        let listed = CheckoutDocumentsModel.State.loaded(.listed(profile: nil, documents: [doc("a/b/c", "bead")]))
        XCTAssertEqual(CockpitView.checkoutDocumentCount(listed), 1)
        XCTAssertNil(CockpitView.checkoutDocumentCount(.loaded(.unavailable(.noDocumentRecord))))
        XCTAssertNil(CockpitView.checkoutDocumentCount(.loading))
        XCTAssertNil(CockpitView.checkoutDocumentCount(.failed("x")))
        XCTAssertNil(CockpitView.checkoutDocumentCount(nil))
        XCTAssertEqual(CockpitView.panelIndexCount(
            id: CockpitView.checkoutPanelID, agentRuns: nil, proposalCount: 0, courseEntries: nil,
            queueTotal: nil, checkoutDocumentCount: 147), "147")
    }

    func testTheCockpitDrawsTheCheckoutPanelAndTheBoardDoesNot() {
        XCTAssertTrue(CockpitView.panelOrder.contains(CockpitView.checkoutPanelID))
        XCTAssertFalse(CockpitView.boardPanelIDs.contains(CockpitView.checkoutPanelID))
    }

    // MARK: - failure sentences

    /// An older session-agent refuses the verb through argparse, and the
    /// panel says the host is too old rather than printing usage text.
    func testAnOldSessionAgentGetsItsOwnSentence() {
        let error = SessionAgent.AgentError.failed(
            "session-agent: error: argument verb: invalid choice: 'documents' (choose from 'state', 'states')")
        XCTAssertTrue(CheckoutDocumentsModel.failureSentence(error).contains("too old"))
        XCTAssertTrue(CheckoutDocumentsModel.failureSentence(SessionAgent.AgentError.failed("timed out"))
            .contains("timed out"))
    }

    // MARK: - the model

    private let target = SSHTarget(user: "operator", host: "mini")

    @MainActor
    func testRefreshLoadsTheSessionAndClearsOnNil() async {
        let model = CheckoutDocumentsModel()
        model.fetchDocuments = { _, session in .listed(profile: session, documents: []) }
        await model.refresh(target: target, session: "orient")
        XCTAssertEqual(model.state, .loaded(.listed(profile: "orient", documents: [])))
        await model.refresh(target: nil, session: nil)
        XCTAssertEqual(model.state, .idle)
    }

    @MainActor
    func testAFailedFetchIsAFailureNotAnEmptyList() async {
        let model = CheckoutDocumentsModel()
        model.fetchDocuments = { _, _ in throw SessionAgent.AgentError.failed("unreachable") }
        await model.refresh(target: target, session: "orient")
        guard case .failed(let sentence) = model.state else {
            return XCTFail("expected a failure, got \(model.state)")
        }
        XCTAssertTrue(sentence.contains("unreachable"))
    }

    /// A slow reply for a session the operator has since left must not land
    /// under the session now selected.
    @MainActor
    func testAReplyForASessionNoLongerSelectedIsDropped() async {
        let model = CheckoutDocumentsModel()
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        model.fetchDocuments = { _, session in
            if session == "slow" {
                entered.signal()
                gate.wait()
            }
            return .listed(profile: session, documents: [])
        }
        let target = self.target
        let slow = Task { await model.refresh(target: target, session: "slow") }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }
        await model.refresh(target: target, session: "fast")
        gate.signal()
        await slow.value
        XCTAssertEqual(model.state, .loaded(.listed(profile: "fast", documents: [])))
    }
}
