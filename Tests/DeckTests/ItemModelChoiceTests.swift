import XCTest
@testable import Deck

/// The Item pane's model control: `POST /items/{id}/model`
/// (`platform/contracts/library-protocol` §6.2), the `model_choice` it reads
/// back, and the words a refusal or the record's attestation gets.
///
/// Modelled on the Approve tests in `LibraryClientTests`, including the
/// credential pin: this write must carry Deck's own token, the one that
/// resolves as actor `deck`.
final class ItemModelChoiceTests: XCTestCase {

    /// A write closure is `@Sendable`, so what it records goes through a lock.
    private final class Recorder<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
        var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func curlResponse(status: Int, body: String) -> Data {
        Data("\(body)\n\(status)".utf8)
    }

    // MARK: - Request construction

    func testTheWriteAddressesTheModelRouteOfTheNamedItem() {
        let command = LibraryClient.itemModelRemoteCommand(itemId: "issue_01ABC")
        XCTAssertTrue(command.contains("/items/issue_01ABC/model\""), command)
        XCTAssertTrue(command.contains("-X POST"), command)
        XCTAssertFalse(command.contains("/correct"), command)
        XCTAssertFalse(command.contains("/revision"), command)
    }

    /// The Library refuses `model_choice` on `/correct` and `/revision`, so
    /// the reserved route is the only one that can carry it.
    func testTheWriteCarriesTheProtocolHeaderAndNeverArgvsTheToken() {
        let command = LibraryClient.itemModelRemoteCommand(itemId: "issue_01ABC")
        XCTAssertTrue(command.contains("Library-Protocol: 1"))
        XCTAssertTrue(command.contains("Content-Type: application/json"))
        XCTAssertTrue(command.contains("--config -"))
        XCTAssertFalse(command.contains("-H \"Authorization"))
        XCTAssertFalse(command.contains("-H 'Authorization"))
        XCTAssertTrue(command.contains(#"data-binary = "@-""#))
        XCTAssertFalse(command.contains("acting_human"))
    }

    /// **THE CREDENTIAL IS DECK'S.** `agent-platform-token` is kind `agent`
    /// and cannot hold `item.model`; `library-client-token` resolves as actor
    /// `orient`. Either would make the record's `set_by_client` say the wrong
    /// client wrote the choice.
    func testTheWriteReadsTheDeckCredentialAndNoOther() {
        let command = LibraryClient.itemModelRemoteCommand(itemId: "issue_01ABC")
        XCTAssertTrue(command.contains("cat ~/.orient-control/deck-library-token"), command)
        XCTAssertFalse(command.contains("agent-platform-token"), command)
        XCTAssertFalse(command.contains("library-client-token"), command)
        XCTAssertEqual(WorkingCopyStore.libraryApprovalTokenFile, "~/.orient-control/deck-library-token")
    }

    func testSettingSendsModelReasonAndActingHumanAndNothingElse() throws {
        let body = try LibraryClient.itemModelBody(
            model: "claude-sonnet-5", reason: "cheaper for this one", actingHuman: "deck:operator@example.com")
        XCTAssertEqual(Set(body.keys), ["model", "reason", "acting_human"])
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(body["reason"] as? String, "cheaper for this one")
        XCTAssertEqual(body["acting_human"] as? String, "deck:operator@example.com")
    }

    /// `owner` names a checkout Deck does not take, and `person`-style keys
    /// would be a provenance claim Deck cannot back.
    func testTheBodyNeverCarriesAnOwner() throws {
        let body = try LibraryClient.itemModelBody(model: "m", reason: "r", actingHuman: "a")
        XCTAssertNil(body["owner"])
    }

    /// Clearing sends `model` as JSON null, present and not omitted: an
    /// absent `model` is a 400.
    func testClearingSendsAnExplicitNullModel() throws {
        let body = try LibraryClient.itemModelBody(model: nil, reason: nil, actingHuman: "deck:operator@example.com")
        XCTAssertTrue(body.keys.contains("model"))
        XCTAssertTrue(body["model"] is NSNull, "\(String(describing: body["model"]))")
        let data = try JSONSerialization.data(withJSONObject: body)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains(#""model":null"#), text)
        XCTAssertEqual(body["acting_human"] as? String, "deck:operator@example.com")
    }

    /// A blank reason is stored as absent by the Library; Deck omits it
    /// rather than send a value it knows is discarded.
    func testABlankReasonIsOmitted() throws {
        let body = try LibraryClient.itemModelBody(model: "m", reason: "   ", actingHuman: "a")
        XCTAssertNil(body["reason"])
    }

    func testTheBodyTrimsWhatItSends() throws {
        let body = try LibraryClient.itemModelBody(model: "  claude-opus-5 ", reason: " why \n", actingHuman: "a")
        XCTAssertEqual(body["model"] as? String, "claude-opus-5")
        XCTAssertEqual(body["reason"] as? String, "why")
    }

    /// Checked before anything reaches curl: the Library's own bounds are 64
    /// characters for `model` and 300 for `reason`, and a whitespace-only
    /// model is refused there as empty.
    func testTheBodyRefusesWhatTheLibraryWouldRefuse() {
        for badModel in ["", "   ", String(repeating: "m", count: LibraryClient.maxModelLength + 1)] {
            XCTAssertThrowsError(try LibraryClient.itemModelBody(model: badModel, reason: nil, actingHuman: "a"),
                                 "model \"\(badModel.prefix(10))\" was accepted") { error in
                guard case LibraryClient.FetchError.invalidModelChoice = error else {
                    return XCTFail("expected invalidModelChoice, got \(error)")
                }
            }
        }
        XCTAssertThrowsError(try LibraryClient.itemModelBody(
            model: "m", reason: String(repeating: "r", count: LibraryClient.maxModelReasonLength + 1),
            actingHuman: "a"))
        XCTAssertNoThrow(try LibraryClient.itemModelBody(
            model: String(repeating: "m", count: LibraryClient.maxModelLength),
            reason: String(repeating: "r", count: LibraryClient.maxModelReasonLength), actingHuman: "a"))
    }

    func testTheArgumentsRefuseAnIdThatCouldInjectIntoTheCommand() {
        for hostile in ["issue_01`whoami`", "a b", "x$(id)", "../model", "", "a;b"] {
            XCTAssertThrowsError(try LibraryClient.itemModelArguments(
                target: TestHost.target, itemId: hostile), "\(hostile) was accepted") { error in
                guard case LibraryClient.FetchError.invalidInput = error else {
                    return XCTFail("expected invalidInput for \(hostile), got \(error)")
                }
            }
        }
        let args = try? LibraryClient.itemModelArguments(target: TestHost.target, itemId: "issue_01ABC")
        XCTAssertTrue(args?.last?.contains("/items/issue_01ABC/model") == true)
    }

    /// `acting_human` comes from the same validator Approve uses, so a
    /// degenerate label refuses locally before any request is built.
    func testSettingRefusesADegenerateActingHumanLocally() {
        for degenerate in ["", "   ", String(repeating: "a", count: LibraryClient.maxActingHumanLength + 1)] {
            XCTAssertThrowsError(try LibraryClient.setItemModel(
                target: TestHost.unreachableTarget, itemId: "issue_01ABC",
                model: "m", reason: nil, actingHuman: degenerate)) { error in
                guard case LibraryClient.FetchError.invalidActingHuman(let reason) = error else {
                    return XCTFail("expected invalidActingHuman, got \(error)")
                }
                XCTAssertFalse(reason.contains("approval"), "the model control must not talk about an approval: \(reason)")
            }
        }
    }

    // MARK: - Decoding model_choice

    private func detail(modelChoiceJSON: String?) throws -> LibraryClient.CorrectionDetail {
        let field = modelChoiceJSON.map { #","model_choice":\#($0)"# } ?? ""
        let body = #"{"id":"issue_01ABC","title":"t","state":"open"\#(field)}"#
        return try LibraryClient.decodeCorrectionDetail(curlResponse(status: 200, body: body))
    }

    func testAFullChoiceDecodesEveryField() throws {
        let choice = try XCTUnwrap(detail(modelChoiceJSON: """
            {"model":"claude-sonnet-5","reason":"cheaper","set_by_client":"deck",
             "acting_human":"deck:operator@laptop","set_at":"2026-09-25T10:00:00Z"}
            """).modelChoice)
        XCTAssertEqual(choice.model, "claude-sonnet-5")
        XCTAssertEqual(choice.reason, "cheaper")
        XCTAssertEqual(choice.setByClient, "deck")
        XCTAssertEqual(choice.actingHuman, "deck:operator@laptop")
        XCTAssertEqual(choice.setAt, "2026-09-25T10:00:00Z")
    }

    /// The Bosun reads `null`, `{}` and `""` as no override
    /// (`work-item-model-override`, "Parsing what comes back"), and so does
    /// Deck. An absent key is the same answer.
    func testNullEmptyObjectEmptyStringAndAbsentAreNoChoice() throws {
        for json in ["null", "{}", #""""#, nil] {
            XCTAssertNil(try detail(modelChoiceJSON: json).modelChoice, "\(json ?? "absent")")
        }
    }

    /// A null reason is a choice with no reason, not a malformed one.
    func testANullReasonIsAChoiceWithoutAReason() throws {
        let choice = try XCTUnwrap(detail(modelChoiceJSON: """
            {"model":"m","reason":null,"set_by_client":"deck","acting_human":"a","set_at":"t"}
            """).modelChoice)
        XCTAssertNil(choice.reason)
        XCTAssertEqual(choice.model, "m")
    }

    /// A non-empty record that lacks `model` is still a record somebody
    /// wrote. Deck keeps it and each field degrades alone; it is never
    /// dropped as if no choice were set, since the Bosun refuses dispatch on
    /// exactly this shape.
    func testAMalformedNonEmptyChoiceIsKeptNotDropped() throws {
        let choice = try XCTUnwrap(detail(modelChoiceJSON: #"{"set_by_client":"deck"}"#).modelChoice)
        XCTAssertNil(choice.model)
        XCTAssertEqual(choice.setByClient, "deck")
        XCTAssertTrue(choice.isMalformed)
    }

    /// The Bosun refuses to dispatch on a choice of any shape but null, {}
    /// and "", so Deck must not read one as "No model set".
    func testAChoiceOfAnUnexpectedTypeIsMalformedNotNoChoice() throws {
        for json in ["42", "true", #"["deck"]"#, #""claude-sonnet-5""#] {
            let choice = try XCTUnwrap(detail(modelChoiceJSON: json).modelChoice, json)
            XCTAssertTrue(choice.isMalformed, json)
        }
    }

    // MARK: - What the pane says

    func testThePaneNamesTheClientAsAttestedAndThePersonAsClaimed() throws {
        let choice = try XCTUnwrap(detail(modelChoiceJSON: """
            {"model":"claude-sonnet-5","reason":"cheaper","set_by_client":"deck",
             "acting_human":"deck:operator@laptop","set_at":"2026-09-25T10:00:00Z"}
            """).modelChoice)
        let text = LibraryClient.modelChoiceLines(choice).joined(separator: "\n")
        XCTAssertTrue(text.contains("claude-sonnet-5"), text)
        XCTAssertTrue(text.contains("cheaper"), text)
        XCTAssertTrue(text.contains("deck"), text)
        XCTAssertTrue(text.contains("deck:operator@laptop"), text)
        XCTAssertTrue(text.contains("not verified"), text)
        XCTAssertFalse(text.contains("verified by"), text)
    }

    /// The person is never labelled verified, whatever the record holds.
    func testNoWordingCallsThePersonVerified() throws {
        let choice = try XCTUnwrap(detail(modelChoiceJSON: """
            {"model":"m","reason":null,"set_by_client":"deck","acting_human":"someone","set_at":"t"}
            """).modelChoice)
        let text = LibraryClient.modelChoiceLines(choice).joined(separator: " ").lowercased()
        XCTAssertFalse(text.contains("verified by"))
        XCTAssertFalse(text.contains("authenticated"))
        XCTAssertFalse(text.replacingOccurrences(of: "not verified", with: "").contains("verified"), text)
    }

    // MARK: - Terminal items

    func testTheControlIsAbsentOnEveryTerminalStateAndPresentOnTheOpenOnes() {
        for state in ["fixed", "wontfix", "duplicate", "redirected"] {
            XCTAssertFalse(LibraryClient.canSetModel(state: state), state)
        }
        for state in ["open", "claimed", "pr-open"] {
            XCTAssertTrue(LibraryClient.canSetModel(state: state), state)
        }
        XCTAssertFalse(LibraryClient.canSetModel(state: nil), "an item whose state is unknown is not offered a write")
    }

    // MARK: - Refusals

    private func refusal(_ status: Int, _ body: String) -> String {
        LibraryClient.modelChoiceRefusalMessage(LibraryClient.FetchError.libraryRefused(status: status, body: body))
    }

    func testARefusalShowsTheLibrarysOwnCause() {
        XCTAssertEqual(refusal(403, #"{"error":"this identity lacks 'item.model'"}"#),
                       "this identity lacks 'item.model'")
        XCTAssertEqual(refusal(400, #"{"error":"model must be at most 64 characters"}"#),
                       "model must be at most 64 characters")
    }

    func testATerminalItemRefusalShowsItsCause() {
        let message = refusal(409, #"{"error":"this item is fixed, so its model cannot be changed"}"#)
        XCTAssertEqual(message, "this item is fixed, so its model cannot be changed")
    }

    /// A held item names the holder, and the retry advice is about this
    /// control rather than Approve.
    func testAHeldRefusalNamesTheHolderWithoutTalkingAboutApprove() {
        let message = refusal(409, """
            {"error":"held","reason":"held","lease":{"holder":"deck-coder","expires_at":"not a date"}}
            """)
        XCTAssertTrue(message.contains("deck-coder"), message)
        XCTAssertFalse(message.contains("Approve"), message)
    }

    func testAnUnreadableRefusalStillSaysWhatTheLibraryAnswered() {
        XCTAssertEqual(refusal(503, "<html>"), "The Library refused (503): <html>")
    }

    func testALocalValidationFailureShowsItsReason() {
        XCTAssertEqual(
            LibraryClient.modelChoiceRefusalMessage(LibraryClient.FetchError.invalidModelChoice("Name a model.")),
            "Name a model.")
    }

    /// Approve's own wording is untouched by generalising the helper.
    func testApproveKeepsItsRetryWording() {
        let message = LibraryClient.approvalRefusalMessage(LibraryClient.FetchError.libraryRefused(
            status: 409, body: #"{"reason":"held","lease":{"holder":"x"}}"#))
        XCTAssertEqual(message, "Held by x. Approve again once they release it.")
    }

    // MARK: - The pane's model: which operator, which credential path

    @MainActor
    func testTheWriteSendsTheDeckOperatorLabelAndReloadsWhatTheLibraryReturns() async throws {
        let model = ItemDetailModel()
        struct Sent { let id: String; let model: String?; let reason: String?; let actingHuman: String }
        let recorder = Recorder<Sent>()
        model.writeModel = { _, id, chosen, reason, actingHuman in
            recorder.add(Sent(id: id, model: chosen, reason: reason, actingHuman: actingHuman))
        }
        model.fetchDetail = { _, id in
            LibraryClient.CorrectionDetail(
                id: id, state: "open",
                modelChoice: .init(model: "claude-sonnet-5", reason: "r", setByClient: "deck",
                                   actingHuman: "deck:x@y", setAt: "t"))
        }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        await model.load(id: "issue_01ABC", target: TestHost.target, appearance: .light)
        await model.setModel("claude-sonnet-5", reason: "r")

        let sent = recorder.all
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.id, "issue_01ABC")
        XCTAssertEqual(sent.first?.model, "claude-sonnet-5")
        XCTAssertEqual(sent.first?.actingHuman, DeckOperator.label())
        XCTAssertEqual(model.detail?.modelChoice?.model, "claude-sonnet-5")
        XCTAssertNil(model.modelWriteRefusal)
    }

    @MainActor
    func testClearingSendsNilAndAFailureShowsItsCauseWithoutChangingThePane() async {
        let model = ItemDetailModel()
        let recorder = Recorder<String?>()
        model.writeModel = { _, _, chosen, _, _ in
            recorder.add(chosen)
            throw LibraryClient.FetchError.libraryRefused(
                status: 409, body: #"{"error":"this item is fixed, so its model cannot be changed"}"#)
        }
        model.fetchDetail = { _, id in LibraryClient.CorrectionDetail(id: id, state: "open") }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        await model.load(id: "issue_01ABC", target: TestHost.target, appearance: .light)
        await model.clearModel(reason: nil)

        let sentModels = recorder.all
        XCTAssertEqual(sentModels.count, 1)
        XCTAssertNil(sentModels[0])
        XCTAssertEqual(model.modelWriteRefusal, "this item is fixed, so its model cannot be changed")
        XCTAssertFalse(model.isWritingModel)
    }

    /// Nothing loaded means no target and no item to write to: the write
    /// must not run.
    @MainActor
    func testNothingIsWrittenBeforeAnItemHasLoaded() async {
        let model = ItemDetailModel()
        model.writeModel = { _, _, _, _, _ in XCTFail("no item is loaded") }
        await model.setModel("m", reason: nil)
        XCTAssertNil(model.modelWriteRefusal)
    }

    /// A terminal item is never written, even if a caller reaches the model
    /// past the hidden control.
    @MainActor
    func testATerminalItemIsNeverWritten() async {
        let model = ItemDetailModel()
        model.writeModel = { _, _, _, _, _ in XCTFail("a terminal item must not be written") }
        model.fetchDetail = { _, id in LibraryClient.CorrectionDetail(id: id, state: "fixed") }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        await model.load(id: "issue_01ABC", target: TestHost.target, appearance: .light)
        await model.setModel("m", reason: nil)
        XCTAssertNotNil(model.modelWriteRefusal)
    }

    /// deck-reviewer, round 1 on #280: the pane is reused when another item
    /// opens, and a draft typed for one item was posted to the next.
    @MainActor
    func testOpeningAnotherItemDropsTheDraftAndTheOldItem() async {
        let model = ItemDetailModel()
        model.fetchDetail = { _, id in LibraryClient.CorrectionDetail(id: id, state: "open") }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        model.fetchModels = { _ in .unavailable }
        await model.load(id: "issue_01AAA", target: TestHost.target, appearance: .light)
        model.toggleEditing()
        model.draftModel = "claude-opus-5-5"
        model.draftReason = "for A"

        model.fetchDetail = { _, id in
            XCTAssertEqual(id, "issue_01BBB")
            throw LibraryClient.FetchError.libraryRefused(status: 503, body: "{}")
        }
        await model.load(id: "issue_01BBB", target: TestHost.target, appearance: .light)

        XCTAssertFalse(model.isEditingModel)
        XCTAssertEqual(model.draftModel, "")
        XCTAssertEqual(model.draftReason, "")
        XCTAssertNil(model.detail, "a failed load of B leaves no item, not A")
    }

    /// A write for item A that finishes after item B has opened must not
    /// draw A over B.
    @MainActor
    func testAWriteFinishingAfterASwitchLeavesTheNewItemAlone() async {
        let model = ItemDetailModel()
        model.fetchDetail = { _, id in LibraryClient.CorrectionDetail(id: id, state: "open") }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        await model.load(id: "issue_01AAA", target: TestHost.target, appearance: .light)

        let started = expectation(description: "the write for A has started")
        let release = DispatchSemaphore(value: 0)
        model.writeModel = { _, id, _, _, _ in
            XCTAssertEqual(id, "issue_01AAA")
            started.fulfill()
            release.wait()
        }
        let write = Task { await model.setModel("m", reason: nil) }
        await fulfillment(of: [started], timeout: 10)
        await model.load(id: "issue_01BBB", target: TestHost.target, appearance: .light)
        release.signal()
        await write.value

        XCTAssertEqual(model.detail?.id, "issue_01BBB")
        XCTAssertNil(model.modelWriteRefusal)
    }

    /// deck-reviewer, round 2 on #280: a load of A whose fetch returns after
    /// B has loaded must not draw A under B's model control.
    @MainActor
    func testASlowLoadOfTheOldItemDoesNotOverwriteTheNewOne() async {
        let model = ItemDetailModel()
        let started = expectation(description: "the fetch for A has started")
        let release = DispatchSemaphore(value: 0)
        model.fetchDetail = { _, id in
            if id == "issue_01AAA" {
                started.fulfill()
                release.wait()
            }
            return LibraryClient.CorrectionDetail(id: id, state: "open")
        }
        model.renderDetail = { detail, _, _ in "page for \(detail.id)" }
        let loadA = Task { await model.load(id: "issue_01AAA", target: TestHost.target, appearance: .light) }
        await fulfillment(of: [started], timeout: 10)
        await model.load(id: "issue_01BBB", target: TestHost.target, appearance: .light)
        release.signal()
        await loadA.value

        XCTAssertEqual(model.detail?.id, "issue_01BBB")
        XCTAssertEqual(model.html, "page for issue_01BBB")
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - The model list picker (`platform/contracts/agentctl-models`)

    /// The picker's own list is fetched only once the editor opens, and only
    /// once per item: it costs an ssh round trip, and nothing changes it
    /// between two opens of the same item's editor.
    @MainActor
    func testOpeningTheEditorFetchesTheModelListOnceAndMovesTheDraftOntoAServableModel() async {
        let model = ItemDetailModel()
        model.fetchDetail = { _, id in
            LibraryClient.CorrectionDetail(id: id, state: "open",
                modelChoice: .init(model: "claude-opus", reason: nil, setByClient: "deck",
                                   actingHuman: "a", setAt: "t"))
        }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        let calls = Recorder<SSHTarget>()
        model.fetchModels = { target in
            calls.add(target)
            return .models([
                AgentctlModels.ModelEntry(alias: "opus", model: "claude-opus-5", provider: "anthropic"),
                AgentctlModels.ModelEntry(alias: nil, model: "claude-opus-4-8", provider: "anthropic"),
            ])
        }
        await model.load(id: "issue_01ABC", target: TestHost.target, appearance: .light)
        XCTAssertNil(model.modelList, "not fetched until the editor opens")

        model.toggleEditing()
        await model.modelListFetchTask?.value

        XCTAssertEqual(calls.all.count, 1)
        guard case .models(let entries) = model.modelList else { return XCTFail("expected .models") }
        XCTAssertEqual(entries.map(\.model), ["claude-opus-5", "claude-opus-4-8"])
        // The stored choice ("claude-opus") is not one of the servable
        // models, so Set must never be pointed at it: the draft is moved
        // onto the first entry the host actually serves.
        XCTAssertEqual(model.draftModel, "claude-opus-5")

        model.toggleEditing()
        model.toggleEditing()
        await model.modelListFetchTask?.value
        XCTAssertEqual(calls.all.count, 1, "reopening the editor must not refetch")
    }

    /// No free-text fallback: an unavailable list leaves nothing Set can
    /// submit, whatever the operator typed into a draft field before this
    /// existed.
    @MainActor
    func testAnUnavailableListLeavesNothingSetCanSubmit() async {
        let model = ItemDetailModel()
        model.fetchDetail = { _, id in LibraryClient.CorrectionDetail(id: id, state: "open") }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        model.fetchModels = { _ in .unavailable }
        await model.load(id: "issue_01ABC", target: TestHost.target, appearance: .light)

        model.toggleEditing()
        await model.modelListFetchTask?.value

        XCTAssertEqual(model.modelList, .unavailable)
        model.draftModel = "claude-opus-5"
        XCTAssertFalse(model.canSubmitModel)
    }

    /// A resolved, non-empty list with the draft pointed at one of its
    /// entries is exactly the state Set requires.
    @MainActor
    func testASelectedServableModelMaySubmit() async {
        let model = ItemDetailModel()
        model.fetchDetail = { _, id in LibraryClient.CorrectionDetail(id: id, state: "open") }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        model.fetchModels = { _ in
            .models([AgentctlModels.ModelEntry(alias: "sonnet", model: "claude-sonnet-5", provider: "anthropic")])
        }
        await model.load(id: "issue_01ABC", target: TestHost.target, appearance: .light)

        model.toggleEditing()
        await model.modelListFetchTask?.value

        XCTAssertTrue(model.canSubmitModel)
        XCTAssertEqual(model.draftModel, "claude-sonnet-5")
    }

    // MARK: - The header's "not served" marking

    func testTheHeaderMarksAStoredChoiceNotServedOnlyWhenTheListSaysSo() {
        let choice = LibraryClient.ModelChoice(model: "claude-opus", reason: nil, setByClient: "deck",
                                               actingHuman: "a", setAt: "t")
        let servedList = AgentctlModels.Outcome.models([
            AgentctlModels.ModelEntry(alias: "opus", model: "claude-opus-5", provider: "anthropic"),
        ])
        XCTAssertEqual(
            ItemDetailPane.modelHeaderText(choice: choice, modelList: servedList),
            "claude-opus (not served)")

        let matchingChoice = LibraryClient.ModelChoice(model: "claude-opus-5", reason: nil, setByClient: "deck",
                                                        actingHuman: "a", setAt: "t")
        XCTAssertEqual(ItemDetailPane.modelHeaderText(choice: matchingChoice, modelList: servedList), "claude-opus-5")

        // Before the list is known, or while it is unavailable, the bare
        // choice is shown rather than a guess about whether it is servable.
        XCTAssertEqual(ItemDetailPane.modelHeaderText(choice: choice, modelList: nil), "claude-opus")
        XCTAssertEqual(ItemDetailPane.modelHeaderText(choice: choice, modelList: .unavailable), "claude-opus")
    }

    func testTheHeaderKeepsItsOtherWordingUntouched() {
        XCTAssertEqual(ItemDetailPane.modelHeaderText(choice: nil, modelList: nil), "No model set")
        let malformed = LibraryClient.ModelChoice(model: nil, reason: nil, setByClient: "deck",
                                                  actingHuman: nil, setAt: nil)
        XCTAssertEqual(ItemDetailPane.modelHeaderText(choice: malformed, modelList: nil), "Model choice unreadable")
    }

    // MARK: - The composed document shows the choice

    func testTheMarkdownAndFallbackPageCarryTheChoice() {
        let detail = LibraryClient.CorrectionDetail(
            id: "issue_01ABC", state: "open",
            modelChoice: .init(model: "claude-sonnet-5", reason: "cheaper", setByClient: "deck",
                               actingHuman: "deck:operator@laptop", setAt: "t"))
        XCTAssertTrue(ItemDetailPane.markdown(for: detail, nonce: "N").contains("claude-sonnet-5"))
        XCTAssertTrue(ItemDetailPane.page(for: detail, appearance: .light).contains("claude-sonnet-5"))
        let none = LibraryClient.CorrectionDetail(id: "issue_01ABC", state: "open")
        XCTAssertFalse(ItemDetailPane.markdown(for: none, nonce: "N").contains("Model"))
    }
}
