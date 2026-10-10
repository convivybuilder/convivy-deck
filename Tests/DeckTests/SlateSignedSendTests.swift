import CryptoKit
import Foundation
import XCTest
@testable import Deck

/// A software key for the send path. Its messages are logged so a test can see
/// whether a send ever reached the key, and `failure` makes `sign` throw.
private final class RecordingAnswerKey: SigningKey, @unchecked Sendable {
    let key = P256.Signing.PrivateKey()
    var failure: Error?
    private let lock = NSLock()
    private var messages: [Data] = []

    var signedMessages: [Data] { lock.lock(); defer { lock.unlock() }; return messages }
    var publicKeyX963: Data { key.publicKey.x963Representation }
    var dataRepresentation: Data { key.rawRepresentation }

    func sign(_ message: Data) throws -> Data {
        lock.lock()
        messages.append(message)
        lock.unlock()
        if let failure { throw failure }
        return try key.signature(for: message).derRepresentation
    }
}

/// An append-only list written from the `@Sendable` closures the model runs off
/// the main actor.
private final class SentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(id: String, sig: String?)] = []
    func append(id: String, sig: String?) { lock.lock(); storage.append((id, sig)); lock.unlock() }
    var values: [(id: String, sig: String?)] { lock.lock(); defer { lock.unlock() }; return storage }
}

private let target = SSHTarget(user: "operator", host: "macstudio")
private let signedAt = Date(timeIntervalSince1970: 1_780_000_000)

private func ask(id: String, state: SlateCard.Ask.State = .open, answer: String? = nil) -> SlateCard {
    .ask(SlateCard.Ask(id: id, state: state, question: "q", answerDraft: nil, answer: answer))
}

/// The text the fake host holds for the one card a test uses. Its reads return
/// it and every saved edit replaces it, the way the real Slate does, so a read
/// after a save sees the saved text.
private final class HostText: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String?) { self.value = value }
    var text: String? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ text: String?) { lock.lock(); value = text; lock.unlock() }
}

/// A model pointed at crew `deck` whose host lists `capabilities`, with one open
/// ask `a-1`. Each test swaps in the key, the host name and the write it needs.
@MainActor
private func modelWithAsk(capabilities: [String], sent: SentLog,
                          writeEdit: (@Sendable (SSHTarget, String, String, String) throws -> SessionAgent.SlateWriteOutcome)? = nil,
                          sends: SlateSendRegistry = SlateSendRegistry()) async -> SlateModel {
    let model = SlateModel(sends: sends)
    let held = HostText(nil)
    model.fetchSlate = { _, session in
        Slate(session: session, cards: [.ask(SlateCard.Ask(
            id: "a-1", state: .open, question: "q", answerDraft: held.text, answer: nil))],
              capabilities: capabilities)
    }
    let save = writeEdit ?? { _, _, id, text in .card(.ask(SlateCard.Ask(
        id: id, state: .open, question: "q", answerDraft: text, answer: nil))) }
    model.writeEdit = { target, session, id, text in
        let outcome = try save(target, session, id, text)
        if case .card(.ask(let ask)) = outcome { held.set(ask.answerDraft) }
        return outcome
    }
    model.writeSend = { _, _, id, sig in
        sent.append(id: id, sig: sig)
        return .card(ask(id: id, state: .answered, answer: "the answer"))
    }
    model.clock = { signedAt }
    model.start(session: "deck", target: target)
    await model.refresh()
    return model
}

/// A model pointed at crew `deck` whose host lists `capabilities`, with one operator
/// note `n-1`. Each test swaps in the key, the host name and the write it needs.
@MainActor
private func modelWithNote(capabilities: [String], sent: SentLog,
                           writeEdit: (@Sendable (SSHTarget, String, String, String) throws -> SessionAgent.SlateWriteOutcome)? = nil,
                           sends: SlateSendRegistry = SlateSendRegistry()) async -> SlateModel {
    let model = SlateModel(sends: sends)
    let held = HostText("a note")
    model.fetchSlate = { _, session in
        Slate(session: session, cards: [.note(SlateCard.Note(id: "n-1", state: .draft, text: held.text ?? ""))],
              capabilities: capabilities)
    }
    let save = writeEdit ?? { _, _, id, text in .card(.note(SlateCard.Note(id: id, state: .draft, text: text))) }
    model.writeEdit = { target, session, id, text in
        let outcome = try save(target, session, id, text)
        if case .card(.note(let note)) = outcome { held.set(note.text) }
        return outcome
    }
    model.writeSend = { _, _, id, sig in
        sent.append(id: id, sig: sig)
        return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a note")))
    }
    model.clock = { signedAt }
    model.start(session: "deck", target: target)
    await model.refresh()
    return model
}

@MainActor
final class SlateSignedSendTests: XCTestCase {

    /// A draft note's first send creates the note, then signs and sends the id the
    /// create returned, so the payload's `card` is that host id.
    func testADraftNoteIsSignedUnderTheIdItsCreateReturned() async throws {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.writeCreateNote = { _, _, text in .card(.note(SlateCard.Note(id: "n-9", state: .draft, text: text))) }
        // The host holds the note its create made, so the read before signing finds it.
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [
                .note(SlateCard.Note(id: "n-1", state: .draft, text: "a note")),
                .note(SlateCard.Note(id: "n-9", state: .draft, text: "a draft note")),
            ], capabilities: [SlateAnswerSignature.capability])
        }
        model.loadSigningKey = { key }
        model.createNote()
        let local = try XCTUnwrap(model.localNoteIDs.first)
        model.editNote(id: local, text: "a draft note")
        await model.send(id: local, host: "macstudio")

        XCTAssertEqual(sent.values.map { $0.id }, ["n-9"])
        XCTAssertNotNil(sent.values.first?.sig)
        let payload = try XCTUnwrap(key.signedMessages.first)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(fields["card"] as? String, "n-9")
        XCTAssertEqual(fields["text"] as? String, "a draft note")
    }

    /// A host that lists the capability gets `--sig`, and the signed payload carries
    /// the card, crew, host and stripped text the crew will receive.
    func testASupportingHostReceivesASignatureOverTheStrippedAnswer() async throws {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithAsk(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { key }
        model.editAnswer(id: "a-1", text: "  the answer\n\t")
        await model.send(id: "a-1", host: "macstudio")

        let entry = try XCTUnwrap(sent.values.first)
        XCTAssertEqual(entry.id, "a-1")
        let sig = try XCTUnwrap(entry.sig, "a capable host must receive --sig")
        let parts = sig.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 2)
        let payload = try XCTUnwrap(key.signedMessages.first)
        let base64 = parts[0].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        XCTAssertEqual(Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)), payload,
                       "the value passed to --sig carries the exact bytes that were signed")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(fields["card"] as? String, "a-1")
        XCTAssertEqual(fields["crew"] as? String, "deck")
        XCTAssertEqual(fields["host"] as? String, "macstudio")
        XCTAssertEqual(fields["text"] as? String, "the answer", "the signed text is answer_draft.strip()")
        XCTAssertEqual(fields["v"] as? Int, 1)
        XCTAssertNil(model.sendErrors["a-1"])
        XCTAssertNil(model.sendNotices["a-1"])
    }

    /// The negative direction for the capability: a host that does not list it gets
    /// an unsigned send, and the key is never raised, even when this Mac has one.
    func testAHostWithoutTheCapabilityGetsNoSignatureAndNoPrompt() async {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithAsk(capabilities: [], sent: sent)
        model.loadSigningKey = { key }
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1", host: "macstudio")

        XCTAssertEqual(sent.values.map { $0.sig }, [nil])
        XCTAssertTrue(key.signedMessages.isEmpty, "no signature was asked for, so no Touch ID prompt")
    }

    /// A cancelled prompt sends nothing: no write reaches the host, the card does not
    /// change, and the card shows the error. It must not fall back to unsigned.
    func testACancelledPromptSendsNothingAndShowsTheCardError() async {
        let key = RecordingAnswerKey()
        key.failure = SigningKeyError.cancelled
        let sent = SentLog()
        let model = await modelWithAsk(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { key }
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1", host: "macstudio")

        XCTAssertTrue(sent.values.isEmpty, "a cancelled prompt must not send, signed or not")
        XCTAssertEqual(model.sendErrors["a-1"], "The Touch ID prompt was cancelled. Nothing was sent.")
        guard case .ask(let card) = model.slate?.cards.first else { return XCTFail("expected the ask card") }
        XCTAssertEqual(card.state, .open)
    }

    /// No key on a supporting host: the answer goes unsigned and the card says so.
    func testNoKeyOnASupportingHostSendsUnsignedAndSaysSo() async {
        let sent = SentLog()
        let model = await modelWithAsk(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { nil }
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1", host: "macstudio")

        XCTAssertEqual(sent.values.map { $0.sig }, [nil])
        XCTAssertEqual(model.sendNotices["a-1"], "Sent unsigned: this Mac has no signing key.")
    }

    /// A supporting host with no probed name is refused, never sent unsigned.
    func testAnUnknownHostNameRefusesTheSendOnASupportingHost() async {
        let sent = SentLog()
        let model = await modelWithAsk(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { RecordingAnswerKey() }
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1", host: nil)

        XCTAssertTrue(sent.values.isEmpty)
        XCTAssertEqual(model.sendErrors["a-1"],
                       "Deck does not know this host's name yet, so it cannot sign the send. Nothing was sent.")
    }

    /// An answer whose flush the Slate refused is not signed, because the Slate
    /// would deliver its old text and the signature would cover text it did not send.
    func testARefusedSaveStopsASignedSend() async {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithAsk(capabilities: [SlateAnswerSignature.capability], sent: sent,
                                       writeEdit: { _, _, _, _ in .refused("the card is resolved") })
        model.loadSigningKey = { key }
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1", host: "macstudio")

        XCTAssertTrue(sent.values.isEmpty)
        XCTAssertTrue(key.signedMessages.isEmpty)
        XCTAssertEqual(model.sendErrors["a-1"], "The Slate did not save this text, so nothing was sent.")
    }

    /// The Slate saved different text from the text Deck would sign: the send is
    /// refused on the card, nothing is signed, and nothing reaches the host.
    func testASavedAnswerThatDiffersFromTheSignedTextRefusesTheSend() async {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithAsk(
            capabilities: [SlateAnswerSignature.capability], sent: sent,
            writeEdit: { _, _, id, _ in .card(.ask(SlateCard.Ask(
                id: id, state: .open, question: "q", answerDraft: "a different answer", answer: nil))) })
        model.loadSigningKey = { key }
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1", host: "macstudio")

        XCTAssertTrue(sent.values.isEmpty)
        XCTAssertTrue(key.signedMessages.isEmpty)
        XCTAssertEqual(model.sendErrors["a-1"],
                       "The Slate saved different text from the text Deck signed, so nothing was sent.")
    }

    /// A saved answer that differs from the signed text only by surrounding
    /// whitespace is the same text once stripped, so the send goes out signed.
    func testASavedAnswerThatMatchesAfterStripStillSends() async {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithAsk(
            capabilities: [SlateAnswerSignature.capability], sent: sent,
            writeEdit: { _, _, id, _ in .card(.ask(SlateCard.Ask(
                id: id, state: .open, question: "q", answerDraft: "\n the answer \t", answer: nil))) })
        model.loadSigningKey = { key }
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1", host: "macstudio")

        XCTAssertEqual(sent.values.map { $0.sig == nil }, [false])
        XCTAssertNil(model.sendErrors["a-1"])
    }

    /// An unreadable Slate on the read that decides the capability refuses the send:
    /// Deck cannot tell whether the host verifies, so it sends nothing.
    func testAnUnreadableSlateRefusesRatherThanSendingUnsigned() async {
        let sent = SentLog()
        let model = await modelWithAsk(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.fetchSlate = { _, _ in nil }
        model.loadSigningKey = { RecordingAnswerKey() }
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1", host: "macstudio")

        XCTAssertTrue(sent.values.isEmpty)
        XCTAssertEqual(model.sendErrors["a-1"],
                       "The Slate could not be read, so Deck cannot tell whether this host verifies answers. Nothing was sent.")
    }

    /// A note is signed like an answer: the payload's `card` is the note id, and
    /// the signed text is the stripped note text the Slate saved.
    func testASupportingHostReceivesASignatureOverANote() async throws {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { key }
        model.editNote(id: "n-1", text: "  a note\n")
        await model.send(id: "n-1", host: "macstudio")

        let entry = try XCTUnwrap(sent.values.first)
        XCTAssertEqual(entry.id, "n-1")
        XCTAssertNotNil(entry.sig, "a capable host must receive --sig for a note too")
        let payload = try XCTUnwrap(key.signedMessages.first)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(fields["card"] as? String, "n-1")
        XCTAssertEqual(fields["text"] as? String, "a note")
        XCTAssertEqual(fields["host"] as? String, "macstudio")
        XCTAssertNil(model.sendErrors["n-1"])
    }

    /// A host that does not list the capability gets a note unsigned, with no prompt.
    func testANoteOnAHostWithoutTheCapabilityIsSentUnsignedWithNoPrompt() async {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [], sent: sent)
        model.loadSigningKey = { key }
        model.editNote(id: "n-1", text: "a note")
        await model.send(id: "n-1", host: "macstudio")

        XCTAssertEqual(sent.values.map { $0.sig }, [nil])
        XCTAssertTrue(key.signedMessages.isEmpty)
    }

    /// The Slate saved a note whose text differs from the signed text: the send is
    /// refused, and nothing is signed or sent.
    func testASavedNoteThatDiffersFromTheSignedTextRefusesTheSend() async {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithNote(
            capabilities: [SlateAnswerSignature.capability], sent: sent,
            writeEdit: { _, _, id, _ in .card(.note(SlateCard.Note(id: id, state: .draft, text: "something else"))) })
        model.loadSigningKey = { key }
        model.editNote(id: "n-1", text: "a note")
        await model.send(id: "n-1", host: "macstudio")

        XCTAssertTrue(sent.values.isEmpty)
        XCTAssertTrue(key.signedMessages.isEmpty)
        XCTAssertEqual(model.sendErrors["n-1"],
                       "The Slate saved different text from the text Deck signed, so nothing was sent.")
    }

    /// The note card's Send passes the probed host name, so a signing host accepts a
    /// signed note. A missing name refuses it, and nothing is sent unsigned.
    func testTheNoteCardSendSignsWithTheProbedHostName() async throws {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { key }
        model.editNote(id: "n-1", text: "a note")
        await SlatePane.sendCard(model, id: "n-1", target: target, probedName: { _ in "macstudio" })

        XCTAssertEqual(sent.values.map { $0.id }, ["n-1"])
        XCTAssertNotNil(sent.values.first?.sig)
        let payload = try XCTUnwrap(key.signedMessages.first)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(fields["host"] as? String, "macstudio")
        XCTAssertNil(model.sendErrors["n-1"])
    }

    /// The same call site with no probed name: the supporting host refuses the note.
    func testTheNoteCardSendRefusesWithoutAProbedHostName() async {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { key }
        model.editNote(id: "n-1", text: "a note")
        await SlatePane.sendCard(model, id: "n-1", target: target, probedName: { _ in nil })

        XCTAssertTrue(sent.values.isEmpty)
        XCTAssertTrue(key.signedMessages.isEmpty)
        XCTAssertEqual(model.sendErrors["n-1"],
                       "Deck does not know this host's name yet, so it cannot sign the send. Nothing was sent.")
    }

    /// A note sent unsigned for want of a key says so, the way an ask does.
    func testANoteWithNoKeyOnASupportingHostSendsUnsignedAndSaysSo() async {
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { nil }
        model.editNote(id: "n-1", text: "a note")
        await model.send(id: "n-1", host: "macstudio")

        XCTAssertEqual(sent.values.map { $0.sig }, [nil])
        XCTAssertEqual(model.sendNotices["n-1"], "Sent unsigned: this Mac has no signing key.")
    }

    /// A local draft sent unsigned for want of a key keeps its row, and the notice draws
    /// under that row. The row is the one the sheet draws for the draft, keyed by its
    /// local key, so the notice is visible where the operator is looking.
    func testADraftNoteSentWithNoKeyShowsTheNoticeOnTheRowTheSheetDraws() async throws {
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.writeCreateNote = { _, _, text in .card(.note(SlateCard.Note(id: "n-9", state: .draft, text: text))) }
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [
                .note(SlateCard.Note(id: "n-1", state: .draft, text: "a note")),
                .note(SlateCard.Note(id: "n-9", state: .draft, text: "a draft note")),
            ], capabilities: [SlateAnswerSignature.capability])
        }
        model.loadSigningKey = { nil }
        model.createNote()
        let local = try XCTUnwrap(model.localNoteIDs.first)
        model.editNote(id: local, text: "a draft note")
        await model.send(id: local, host: "macstudio")

        XCTAssertEqual(sent.values.map { $0.id }, ["n-9"])
        XCTAssertEqual(sent.values.map { $0.sig }, [nil])
        let row = try XCTUnwrap(model.localNoteIDs.first, "the sent draft's row must stay on the sheet")
        XCTAssertEqual(row, local)
        XCTAssertEqual(model.sendNotices[row], "Sent unsigned: this Mac has no signing key.")
    }

    /// A sent draft whose notice is showing keeps its row when a poll no longer lists
    /// its host note, so the notice stays on the row the sheet draws.
    func testASentDraftWithANoticeKeepsItsRowThroughAPollThatNoLongerListsIt() async throws {
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.writeCreateNote = { _, _, text in .card(.note(SlateCard.Note(id: "n-9", state: .draft, text: text))) }
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [
                .note(SlateCard.Note(id: "n-1", state: .draft, text: "a note")),
                .note(SlateCard.Note(id: "n-9", state: .draft, text: "a draft note")),
            ], capabilities: [SlateAnswerSignature.capability])
        }
        model.loadSigningKey = { nil }
        model.createNote()
        let local = try XCTUnwrap(model.localNoteIDs.first)
        model.editNote(id: local, text: "a draft note")
        await model.send(id: local, host: "macstudio")
        // The host now lists only n-1, as it does once a sent note is hidden from the read.
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [.note(SlateCard.Note(id: "n-1", state: .draft, text: "a note"))],
                  capabilities: [SlateAnswerSignature.capability])
        }
        await model.refresh()

        XCTAssertFalse(model.slate?.cards.contains { $0.id == "n-9" } ?? true, "the read no longer lists the sent note")
        XCTAssertEqual(model.localNoteIDs, [local], "a poll must not retire a row whose notice is showing")
        XCTAssertEqual(model.sendNotices[local], "Sent unsigned: this Mac has no signing key.")
    }

    /// A kept sent draft's Send is off, since pressing it would send a note the host no
    /// longer lists. Before the send, the same row's Send is on.
    func testASentDraftWithANoticeHasItsSendTurnedOff() async throws {
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.writeCreateNote = { _, _, text in .card(.note(SlateCard.Note(id: "n-9", state: .draft, text: text))) }
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [
                .note(SlateCard.Note(id: "n-1", state: .draft, text: "a note")),
                .note(SlateCard.Note(id: "n-9", state: .draft, text: "a draft note")),
            ], capabilities: [SlateAnswerSignature.capability])
        }
        model.loadSigningKey = { nil }
        model.createNote()
        let local = try XCTUnwrap(model.localNoteIDs.first)
        model.editNote(id: local, text: "a draft note")
        XCTAssertTrue(model.sendEnabled(id: local), "an unsent draft with text can be sent")

        await model.send(id: local, host: "macstudio")

        XCTAssertNotNil(model.sendNotices[local])
        XCTAssertFalse(model.sendEnabled(id: local), "a kept sent draft must not offer Send again")
    }

    /// An ask keeps its Send Again after its own notice, since its card stays on the
    /// sheet as an answered card the operator can send again.
    func testAnAskWithANoticeKeepsItsSendAgain() async {
        let sent = SentLog()
        let model = await modelWithAsk(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { nil }
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1", host: "macstudio")

        XCTAssertNotNil(model.sendNotices["a-1"])
        XCTAssertTrue(model.sendEnabled(id: "a-1"))
    }

    /// A draft whose send failed has no notice, so a poll that no longer lists its host
    /// note still retires the row.
    func testADraftWithNoNoticeIsRetiredByAPollThatNoLongerListsIt() async throws {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.writeCreateNote = { _, _, text in .card(.note(SlateCard.Note(id: "n-9", state: .draft, text: text))) }
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [
                .note(SlateCard.Note(id: "n-1", state: .draft, text: "a note")),
                .note(SlateCard.Note(id: "n-9", state: .draft, text: "a draft note")),
            ], capabilities: [SlateAnswerSignature.capability])
        }
        model.loadSigningKey = { key }
        model.writeSend = { _, _, _, _ in throw SessionAgent.AgentError.failed("the Slate is busy") }
        model.createNote()
        let local = try XCTUnwrap(model.localNoteIDs.first)
        model.editNote(id: local, text: "a draft note")
        await model.send(id: local, host: "macstudio")

        XCTAssertNil(model.sendNotices[local])
        XCTAssertEqual(model.localNoteIDs, [local], "the failed send leaves the row on the sheet")
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [.note(SlateCard.Note(id: "n-1", state: .draft, text: "a note"))],
                  capabilities: [SlateAnswerSignature.capability])
        }
        await model.refresh()

        XCTAssertTrue(model.localNoteIDs.isEmpty, "a row with no notice goes when the host stops listing its note")
    }

    /// A host that lists the capability refuses a send whose flush the Slate refused,
    /// even on a Mac with no key: the saved-text check runs before the key is loaded.
    func testARefusedEditOnASupportingHostRefusesTheSendWithNoKey() async {
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent,
                                        writeEdit: { _, _, _, _ in .refused("the note is resolved") })
        model.loadSigningKey = { nil }
        model.editNote(id: "n-1", text: "a note")
        await model.send(id: "n-1", host: "macstudio")

        XCTAssertTrue(sent.values.isEmpty, "a refused flush on a capable host must send nothing")
        XCTAssertEqual(model.sendErrors["n-1"], "The Slate did not save this text, so nothing was sent.")
        XCTAssertNil(model.sendNotices["n-1"])
    }

    /// A sheet-drafted note whose unsigned send the host refuses. Nothing reached the
    /// host, so the row shows the error, shows no notice, and keeps Send on for a retry.
    func testAFailedUnsignedDraftSendLeavesNoNoticeAndSendEnabled() async throws {
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: SentLog())
        model.writeCreateNote = { _, _, text in .card(.note(SlateCard.Note(id: "n-9", state: .draft, text: text))) }
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [
                .note(SlateCard.Note(id: "n-1", state: .draft, text: "a note")),
                .note(SlateCard.Note(id: "n-9", state: .draft, text: "a draft note")),
            ], capabilities: [SlateAnswerSignature.capability])
        }
        model.loadSigningKey = { nil }
        model.writeSend = { _, _, _, _ in throw SessionAgent.AgentError.failed("the Slate is busy") }
        model.createNote()
        let local = try XCTUnwrap(model.localNoteIDs.first)
        model.editNote(id: local, text: "a draft note")
        await model.send(id: local, host: "macstudio")

        XCTAssertNil(model.sendNotices[local], "a send that delivered nothing has no notice to show")
        XCTAssertNotNil(model.sendErrors[local])
        XCTAssertEqual(model.localNoteIDs, [local], "the failed send leaves the row on the sheet")
        XCTAssertTrue(model.sendEnabled(id: local), "the operator can retry the send")
    }

    /// Holds a send's host write until the test releases it, so a test can move the
    /// column to another crew while the send is in flight.
    private final class SendGate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)
        func enter() { entered.signal(); released.wait() }
        func waitUntilEntered() { entered.wait() }
        func release() { released.signal() }
    }

    /// Text typed into an answer while its signed send is in flight changes nothing: the
    /// field keeps the text on screen when Send was pressed, and no write reaches the host.
    /// The controls are the answer before Send, where an edit does write, and the answer
    /// after the send, where it is editable again. The gate holds the host's send.
    func testAnAskCannotBeEditedWhileItsSendIsInFlight() async throws {
        let gate = SendGate()
        let writes = CallCount()
        let sent = SentLog()
        let model = await modelWithAsk(capabilities: [SlateAnswerSignature.capability], sent: sent, writeEdit: { _, _, id, text in
            writes.add()
            return .card(.ask(SlateCard.Ask(id: id, state: .open, question: "q", answerDraft: text, answer: nil)))
        })
        model.loadSigningKey = { RecordingAnswerKey() }
        model.writeSend = { _, _, id, sig in
            sent.append(id: id, sig: sig)
            gate.enter()
            return .card(ask(id: id, state: .answered, answer: "the answer"))
        }
        model.editAnswer(id: "a-1", text: "the answer")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(model.canEditAnswer(id: "a-1"), "control: the answer is editable before Send")
        XCTAssertEqual(writes.count, 1, "control: an edit before Send reaches the host")

        let sending = Task { await model.send(id: "a-1", host: "macstudio") }
        await Task.detached { gate.waitUntilEntered() }.value
        let beforeTyping = writes.count
        XCTAssertFalse(model.canEditAnswer(id: "a-1"), "the answer editor is disabled while the send is in flight")
        model.editAnswer(id: "a-1", text: "typed during the prompt")
        XCTAssertEqual(model.answerDrafts["a-1"], "the answer", "the text typed during the send does not land in the field")
        gate.release()
        await sending.value
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(sent.values.map { $0.id }, ["a-1"], "the send went out once")
        XCTAssertEqual(writes.count, beforeTyping, "no write may reach the answer once its send is delivered")
        XCTAssertTrue(model.canEditAnswer(id: "a-1"), "the answer is editable again once the send has settled")
    }

    /// A note sent unsigned for want of a key, with the column moved to another crew
    /// before the host replies. The notice belongs to the crew the send was for, so the
    /// crew now on the sheet, which lists a note with the same id, must not show it.
    func testACrewSwapMidSendLeavesNoNoticeOnTheNewCrew() async throws {
        let gate = SendGate()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: SentLog())
        model.loadSigningKey = { nil }
        model.writeSend = { _, _, id, _ in
            gate.enter()
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a note")))
        }
        let sending = Task { await model.send(id: "n-1", host: "macstudio") }
        await Task.detached { gate.waitUntilEntered() }.value
        model.start(session: "other", target: target)
        gate.release()
        await sending.value

        XCTAssertNil(model.sendNotices["n-1"], "the notice must not land on the crew the column moved to")
        XCTAssertFalse(model.localNoteIDs.contains("n-1"), "no kept row may appear on the new crew's sheet")
    }

    /// A note the host already listed, sent unsigned with a notice, keeps its row when a
    /// poll no longer lists it, the same as a sheet-drafted note's row. Its Send stays off.
    func testASentHostNoteWithANoticeKeepsItsRowThroughAPollThatNoLongerListsIt() async throws {
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: SentLog())
        model.loadSigningKey = { nil }
        await model.send(id: "n-1", host: "macstudio")
        XCTAssertEqual(model.localNoteIDs, ["n-1"])

        model.fetchSlate = { _, session in
            Slate(session: session, cards: [], capabilities: [SlateAnswerSignature.capability])
        }
        await model.refresh()

        XCTAssertEqual(model.localNoteIDs, ["n-1"], "a poll must not retire a host row whose notice is showing")
        XCTAssertEqual(model.sendNotices["n-1"], "Sent unsigned: this Mac has no signing key.")
        XCTAssertFalse(model.sendEnabled(id: "n-1"), "a kept sent note must not offer Send again")
        XCTAssertTrue(model.sheetCards.isEmpty, "the kept row is the only place the note is drawn")
    }

    /// The other side of that rule: a host note sent signed has no notice, so it keeps no
    /// row, and a poll that stops listing it removes it as before.
    func testAHostNoteSentSignedKeepsNoRow() async throws {
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { RecordingAnswerKey() }
        await model.send(id: "n-1", host: "macstudio")

        XCTAssertNotNil(sent.values.first?.sig, "a key on a supporting host signs the send")
        XCTAssertTrue(model.localNoteIDs.isEmpty)
        XCTAssertNil(model.sendNotices["n-1"])
    }

    /// Deleting a kept host row removes the row and its notice, and never calls the host:
    /// the note was delivered, and the contract refuses `slate-delete` on a sent note. The
    /// host stub records any delete and refuses it, so a call would show as a count and an
    /// error on the row.
    func testDeletingAKeptHostNoteRetiresItsRowWithoutAHostCall() async throws {
        let deletes = CallCount()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: SentLog())
        model.loadSigningKey = { nil }
        model.writeDeleteNote = { _, _, _ in
            deletes.add()
            throw SessionAgent.AgentError.failed("slate-delete refused")
        }
        await model.send(id: "n-1", host: "macstudio")
        XCTAssertEqual(model.localNoteIDs, ["n-1"])

        await model.deleteNote(id: "n-1")

        XCTAssertEqual(deletes.count, 0, "a kept sent note must not reach the host")
        XCTAssertTrue(model.localNoteIDs.isEmpty, "the kept row is gone")
        XCTAssertNil(model.sendNotices["n-1"])
        XCTAssertNil(model.sendErrors["n-1"])
    }

    /// Deleting a host note that was not sent still calls the host, which removes it and
    /// the row goes with it. The control for the kept-row case above.
    func testDeletingAnUnsentHostNoteStillCallsTheHost() async throws {
        let deletes = CallCount()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: SentLog())
        model.writeDeleteNote = { _, _, id in
            deletes.add()
            return .deleted(id: id)
        }

        await model.deleteNote(id: "n-1")

        XCTAssertEqual(deletes.count, 1, "an unsent note is still deleted on the host")
        XCTAssertTrue(model.sheetCards.isEmpty)
    }

    /// Deleting a sheet-drafted row whose send kept it for its notice retires the row
    /// without a host call. The draft's host note is the one the send delivered.
    func testDeletingAKeptDraftRowRetiresItWithoutAHostCall() async throws {
        let deletes = CallCount()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: SentLog())
        model.writeCreateNote = { _, _, text in .card(.note(SlateCard.Note(id: "n-9", state: .draft, text: text))) }
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [
                .note(SlateCard.Note(id: "n-1", state: .draft, text: "a note")),
                .note(SlateCard.Note(id: "n-9", state: .draft, text: "a draft note")),
            ], capabilities: [SlateAnswerSignature.capability])
        }
        model.writeDeleteNote = { _, _, _ in
            deletes.add()
            throw SessionAgent.AgentError.failed("slate-delete refused")
        }
        model.loadSigningKey = { nil }
        model.createNote()
        let local = try XCTUnwrap(model.localNoteIDs.first)
        model.editNote(id: local, text: "a draft note")
        await model.send(id: local, host: "macstudio")
        XCTAssertEqual(model.localNoteIDs, [local])

        await model.deleteNote(id: local)

        XCTAssertEqual(deletes.count, 0, "a kept sent draft must not reach the host")
        XCTAssertTrue(model.localNoteIDs.isEmpty, "the kept row is gone")
        XCTAssertNil(model.sendNotices[local])
        XCTAssertNil(model.sendErrors[local])
    }

    /// Text typed while a note's send is in flight, through the Touch ID prompt and the ssh
    /// round trip, changes nothing: the editor's text stays, and no write reaches the note.
    /// The control is the note before Send, where the editor is open. The gate holds the
    /// host's send so the test can type during it.
    func testANoteCannotBeEditedWhileItsSendIsInFlight() async throws {
        let gate = SendGate()
        let writes = CallCount()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: SentLog())
        model.loadSigningKey = { RecordingAnswerKey() }
        model.writeEdit = { _, _, id, text in
            writes.add()
            return .card(.note(SlateCard.Note(id: id, state: .draft, text: text)))
        }
        model.writeSend = { _, _, id, _ in
            gate.enter()
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a note")))
        }
        XCTAssertTrue(model.canEditNote(id: "n-1"), "control: the note is editable before Send")

        let sending = Task { await model.send(id: "n-1", host: "macstudio") }
        await Task.detached { gate.waitUntilEntered() }.value
        let beforeTyping = writes.count
        XCTAssertFalse(model.canEditNote(id: "n-1"), "the editor is disabled while the send is in flight")
        model.editNote(id: "n-1", text: "typed during the prompt")
        XCTAssertEqual(model.noteDrafts["n-1"], "a note", "the text typed during the send does not land in the field")
        gate.release()
        await sending.value
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(writes.count, beforeTyping, "no write may reach the note once its send is delivered")
    }

    /// Delete pressed while a note's send is in flight does not reach the host, and the
    /// same note is deletable once the send settles. The attempt runs in its own task and
    /// is awaited only after the gate opens: a model that does not refuse it would wait on
    /// the send and then call the host, so the count is 1 at the check and the test fails.
    func testDeleteRequestedDuringAGatedSendDoesNotReachTheHostAndIsAllowedAfterItSettles() async throws {
        let gate = SendGate()
        let sent = SentLog()
        let deletes = CallCount()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { RecordingAnswerKey() }
        model.writeSend = { _, _, id, sig in
            sent.append(id: id, sig: sig)
            gate.enter()
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a note")))
        }
        model.writeDeleteNote = { _, _, id in
            deletes.add()
            return .deleted(id: id)
        }

        let sending = Task { await model.send(id: "n-1", host: "macstudio") }
        await Task.detached { gate.waitUntilEntered() }.value
        let attempt = Task { await model.deleteNote(id: "n-1") }
        gate.release()
        await sending.value
        await attempt.value
        XCTAssertEqual(deletes.count, 0, "a delete requested during the send must not reach the host")
        XCTAssertEqual(sent.values.count, 1, "the send itself goes out once")

        await model.deleteNote(id: "n-1")
        XCTAssertEqual(deletes.count, 1, "control: once the send has settled, the note deletes on the host")
    }

    /// Closing the sheet during a note's gated send saves the note's text once, inside the
    /// send, and never again after the send delivers it. The gate holds the send open
    /// across `stop()`, then opens it, and the sleep lets any flush chained behind the send
    /// run before the log is read.
    func testClosingTheSheetDuringAGatedSendMakesNoEditAfterTheDeliveredSend() async throws {
        let gate = SendGate()
        let sent = SentLog()
        let events = EventLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent, writeEdit: { _, _, id, text in
            events.append("edit:\(text)")
            return .card(.note(SlateCard.Note(id: id, state: .draft, text: text)))
        })
        model.loadSigningKey = { RecordingAnswerKey() }
        model.writeSend = { _, _, id, sig in
            events.append("send")
            sent.append(id: id, sig: sig)
            gate.enter()
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a note, revised")))
        }
        model.editNote(id: "n-1", text: "a note, revised")

        let sending = Task { await model.send(id: "n-1", host: "macstudio") }
        await Task.detached { gate.waitUntilEntered() }.value
        model.stop()
        gate.release()
        await sending.value
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(sent.values.count, 1, "exactly one send")
        XCTAssertEqual(events.values, ["edit:a note, revised", "send"],
                       "no edit may follow the delivered send")
    }

    /// Control for the test above: closing the sheet with an unsent edit and no send in
    /// flight still saves that edit, so the flush the gated test skips is a real write.
    func testClosingTheSheetWithAnUnsentEditStillSavesIt() async throws {
        let events = EventLog()
        let model = await modelWithNote(capabilities: [], sent: SentLog(), writeEdit: { _, _, id, text in
            events.append("edit:\(text)")
            return .card(.note(SlateCard.Note(id: id, state: .draft, text: text)))
        })
        model.editNote(id: "n-1", text: "a note, revised")
        model.stop()
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(events.values, ["edit:a note, revised"])
    }

    /// Closing the sheet while a note's send is still saving, with that save failing, saves
    /// the text once after the failure and sends nothing. The gate holds the first save open
    /// across `stop()`, and only that first save fails, so the save the flush makes lands.
    func testClosingTheSheetDuringAGatedSaveThatFailsSavesTheTextOnceAndSendsNothing() async throws {
        struct SaveRefused: Error {}
        let gate = SendGate()
        let sent = SentLog()
        let events = EventLog()
        let saves = CallCount()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent, writeEdit: { _, _, id, text in
            saves.add()
            if saves.count == 1 {
                gate.enter()
                events.append("save refused:\(text)")
                throw SaveRefused()
            }
            events.append("save:\(text)")
            return .card(.note(SlateCard.Note(id: id, state: .draft, text: text)))
        })
        model.loadSigningKey = { RecordingAnswerKey() }
        model.editNote(id: "n-1", text: "a note, revised")

        let sending = Task { await model.send(id: "n-1", host: "macstudio") }
        await Task.detached { gate.waitUntilEntered() }.value
        model.stop()
        gate.release()
        await sending.value
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(sent.values.count, 0, "a send whose save failed must not send")
        XCTAssertEqual(events.values, ["save refused:a note, revised", "save:a note, revised"],
                       "the text is saved exactly once, after the failed save")
    }

    /// A send whose save was refused, then whose send throws while the sheet closes. Nothing
    /// was delivered, so the close saves the text once more, and the send is not repeated.
    /// The refused save is the reason the close has a save to make: a save that landed would
    /// be skipped, as the delivered-send test above shows.
    func testClosingTheSheetDuringASendThatThrowsSavesTheTextOnceAndSendsNothingMore() async throws {
        struct SendDropped: Error {}
        let gate = SendGate()
        let events = EventLog()
        let saves = CallCount()
        let model = await modelWithNote(capabilities: [], sent: SentLog(), writeEdit: { _, _, id, text in
            saves.add()
            if saves.count == 1 {
                events.append("save refused:\(text)")
                return .refused("the Slate refused the save")
            }
            events.append("save:\(text)")
            return .card(.note(SlateCard.Note(id: id, state: .draft, text: text)))
        })
        model.loadSigningKey = { nil }
        model.writeSend = { _, _, _, _ in
            events.append("send")
            gate.enter()
            throw SendDropped()
        }
        model.editNote(id: "n-1", text: "a note, revised")

        let sending = Task { await model.send(id: "n-1", host: "macstudio") }
        await Task.detached { gate.waitUntilEntered() }.value
        model.stop()
        gate.release()
        await sending.value
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(events.values, ["save refused:a note, revised", "send", "save:a note, revised"],
                       "the text is saved once more after the throw, and the send is not repeated")
    }

    /// A note's send started on one sheet, which then closes: the send still locks its note
    /// on the next sheet for the same crew. The closed sheet's model is released by the test
    /// while the send is held. Its send task keeps it alive, as the sheet's Send button does,
    /// so only the sheet's own reference goes. The reopened sheet is a second model on the
    /// same registry. Send, edit and Delete are refused there until the send settles.
    func testASendStartedOnAClosedSheetStillLocksItsNoteOnTheNextSheet() async throws {
        let gate = SendGate()
        let sent = SentLog()
        let sends = SlateSendRegistry()
        let sendCalls = CallCount()
        let saves = CallCount()
        let edits = CallCount()
        let deletes = CallCount()
        var sheet: SlateModel? = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent, writeEdit: { _, _, id, text in
            saves.add()
            return .card(.note(SlateCard.Note(id: id, state: .draft, text: text)))
        }, sends: sends)
        sheet?.loadSigningKey = { RecordingAnswerKey() }
        sheet?.writeSend = { _, _, id, sig in
            sendCalls.add()
            sent.append(id: id, sig: sig)
            gate.enter()
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a note")))
        }
        let closing = sheet!
        let sending = Task { await closing.send(id: "n-1", host: "macstudio") }
        await Task.detached { gate.waitUntilEntered() }.value
        sheet = nil
        let savesBeforeDelivery = saves.count

        let reopened = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent, sends: sends)
        reopened.loadSigningKey = { RecordingAnswerKey() }
        reopened.writeEdit = { _, _, id, text in
            edits.add()
            return .card(.note(SlateCard.Note(id: id, state: .draft, text: text)))
        }
        reopened.writeSend = { _, _, id, sig in
            sendCalls.add()
            sent.append(id: id, sig: sig)
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a note")))
        }
        reopened.writeDeleteNote = { _, _, id in
            deletes.add()
            return .deleted(id: id)
        }
        XCTAssertEqual(reopened.sendingIDs, ["n-1"], "control: the reopened sheet sees the send still in flight")

        await reopened.send(id: "n-1", host: "macstudio")
        XCTAssertFalse(reopened.sendEnabled(id: "n-1"), "Send is refused on the reopened sheet while the send is in flight")
        XCTAssertFalse(reopened.canEditNote(id: "n-1"), "the editor is refused on the reopened sheet while the send is in flight")
        reopened.editNote(id: "n-1", text: "typed on the reopened sheet")
        XCTAssertEqual(reopened.noteDrafts["n-1"], "a note", "text typed on the reopened sheet does not land")
        await reopened.deleteNote(id: "n-1")
        XCTAssertEqual(deletes.count, 0, "Delete must not reach the host while the send is in flight")

        gate.release()
        await sending.value
        try await Task.sleep(for: .milliseconds(800))
        await reopened.refresh()

        XCTAssertEqual(sendCalls.count, 1, "exactly one writeSend")
        XCTAssertEqual(sent.values.count, 1, "slate-send ran once")
        XCTAssertEqual(saves.count, savesBeforeDelivery, "the send's own save was the last edit before delivery")
        XCTAssertEqual(edits.count, 0, "no writeEdit reaches the note after delivery")
        XCTAssertEqual(deletes.count, 0, "no Delete reaches the host")
        XCTAssertTrue(reopened.sendEnabled(id: "n-1"), "the note is sendable again once the send has settled")
        XCTAssertTrue(reopened.canEditNote(id: "n-1"), "the note is editable again once the send has settled")
    }

    /// A note drafted on a sheet, then sent and held mid-send while the sheet closes: the
    /// reopened sheet lists the note under the host id its create returned, never under the
    /// draft's local key, so the send must lock that host id too. Round 12 found the lock
    /// keyed only by the local key, which left Send, edit and Delete open on the reopened sheet.
    func testADraftSentFromAClosedSheetStillLocksItsHostNoteOnTheNextSheet() async throws {
        let gate = SendGate()
        let sent = SentLog()
        let sends = SlateSendRegistry()
        let sendCalls = CallCount()
        let edits = CallCount()
        let deletes = CallCount()
        let hostCards: @Sendable (String) -> Slate = { session in
            Slate(session: session, cards: [
                .note(SlateCard.Note(id: "n-1", state: .draft, text: "a note")),
                .note(SlateCard.Note(id: "n-9", state: .draft, text: "a draft note")),
            ], capabilities: [SlateAnswerSignature.capability])
        }
        var sheet: SlateModel? = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent, sends: sends)
        sheet?.writeCreateNote = { _, _, text in .card(.note(SlateCard.Note(id: "n-9", state: .draft, text: text))) }
        sheet?.fetchSlate = { _, session in hostCards(session) }
        sheet?.loadSigningKey = { RecordingAnswerKey() }
        sheet?.writeSend = { _, _, id, sig in
            sendCalls.add()
            sent.append(id: id, sig: sig)
            gate.enter()
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a draft note")))
        }
        sheet?.createNote()
        let local = try XCTUnwrap(sheet?.localNoteIDs.first)
        sheet?.editNote(id: local, text: "a draft note")
        let closing = sheet!
        let sending = Task { await closing.send(id: local, host: "macstudio") }
        await Task.detached { gate.waitUntilEntered() }.value
        sheet = nil

        let reopened = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent, sends: sends)
        reopened.fetchSlate = { _, session in hostCards(session) }
        await reopened.refresh()
        reopened.loadSigningKey = { RecordingAnswerKey() }
        reopened.writeEdit = { _, _, id, text in
            edits.add()
            return .card(.note(SlateCard.Note(id: id, state: .draft, text: text)))
        }
        reopened.writeSend = { _, _, id, sig in
            sendCalls.add()
            sent.append(id: id, sig: sig)
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a draft note")))
        }
        reopened.writeDeleteNote = { _, _, id in
            deletes.add()
            return .deleted(id: id)
        }
        XCTAssertTrue(reopened.sendingIDs.contains("n-9"), "the reopened sheet sees the draft's send under its host id")
        XCTAssertTrue(reopened.sendEnabled(id: "n-1"), "control: a note with no send in flight stays sendable")

        await reopened.send(id: "n-9", host: "macstudio")
        XCTAssertFalse(reopened.sendEnabled(id: "n-9"), "Send is refused on the reopened sheet while the send is in flight")
        XCTAssertFalse(reopened.canEditNote(id: "n-9"), "the editor is refused on the reopened sheet while the send is in flight")
        await reopened.deleteNote(id: "n-9")
        XCTAssertEqual(deletes.count, 0, "Delete must not reach the host while the send is in flight")
        reopened.editNote(id: "n-9", text: "typed on the reopened sheet")
        // Past the 400ms debounce, so an edit that was accepted would have written by now.
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(edits.count, 0, "no writeEdit reaches the note from the reopened sheet mid-send")

        gate.release()
        await sending.value
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(sendCalls.count, 1, "exactly one writeSend")
        XCTAssertEqual(sent.values.map(\.id), ["n-9"], "slate-send ran once, for the host id")
        XCTAssertEqual(edits.count, 0, "no writeEdit reaches the note from the reopened sheet")
        XCTAssertFalse(reopened.sendingIDs.contains("n-9"), "the host id is released when the send settles")
    }

    /// Send pressed while the draft's own debounced create is still in flight: the send
    /// waits on that create, which stamps the host id, and then takes the edit path, never
    /// a create of its own. Round 13 found that path never recorded the host id on the
    /// registry, so a sheet rebuilt mid-send listed the note unlocked.
    func testADraftSentWhileItsCreateIsInFlightStillLocksItsHostNoteOnTheNextSheet() async throws {
        let createGate = SendGate()
        let sendGate = SendGate()
        let sent = SentLog()
        let sends = SlateSendRegistry()
        let sendCalls = CallCount()
        let creates = CallCount()
        let edits = CallCount()
        let hostCards: @Sendable (String) -> Slate = { session in
            Slate(session: session, cards: [
                .note(SlateCard.Note(id: "n-1", state: .draft, text: "a note")),
                .note(SlateCard.Note(id: "n-9", state: .draft, text: "a draft note")),
            ], capabilities: [SlateAnswerSignature.capability])
        }
        var sheet: SlateModel? = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent, sends: sends)
        sheet?.writeCreateNote = { _, _, text in
            creates.add()
            createGate.enter()
            return .card(.note(SlateCard.Note(id: "n-9", state: .draft, text: text)))
        }
        sheet?.fetchSlate = { _, session in hostCards(session) }
        sheet?.loadSigningKey = { RecordingAnswerKey() }
        sheet?.writeSend = { _, _, id, sig in
            sendCalls.add()
            sent.append(id: id, sig: sig)
            sendGate.enter()
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a draft note")))
        }
        sheet?.createNote()
        let local = try XCTUnwrap(sheet?.localNoteIDs.first)
        sheet?.editNote(id: local, text: "a draft note")
        await Task.detached { createGate.waitUntilEntered() }.value
        let closing = sheet!
        let sending = Task { await closing.send(id: local, host: "macstudio") }
        // The send must install its link behind the create before the create returns,
        // or it never waits on it and the path under test is not reached. Wait for the
        // send to register rather than for a fixed time.
        let deadline = ContinuousClock.now + .seconds(5)
        while !closing.sendingIDs.contains(local) {
            guard ContinuousClock.now < deadline else { return XCTFail("the send never started") }
            try await Task.sleep(for: .milliseconds(10))
        }
        createGate.release()
        await Task.detached { sendGate.waitUntilEntered() }.value
        sheet = nil

        let reopened = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent, sends: sends)
        reopened.fetchSlate = { _, session in hostCards(session) }
        await reopened.refresh()
        reopened.writeEdit = { _, _, id, text in
            edits.add()
            return .card(.note(SlateCard.Note(id: id, state: .draft, text: text)))
        }
        reopened.writeSend = { _, _, id, sig in
            sendCalls.add()
            sent.append(id: id, sig: sig)
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a draft note")))
        }
        XCTAssertEqual(creates.count, 1, "control: the send waited on the draft's own create and made none")
        XCTAssertTrue(reopened.sendingIDs.contains("n-9"), "the reopened sheet sees the send under the host id")
        XCTAssertFalse(reopened.sendEnabled(id: "n-9"), "Send is refused on the reopened sheet while the send is in flight")
        XCTAssertFalse(reopened.canEditNote(id: "n-9"), "the editor is refused on the reopened sheet while the send is in flight")
        await reopened.send(id: "n-9", host: "macstudio")

        sendGate.release()
        await sending.value
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(sendCalls.count, 1, "exactly one writeSend")
        XCTAssertEqual(sent.values.map(\.id), ["n-9"], "slate-send ran once, for the host id")
        XCTAssertEqual(edits.count, 0, "no writeEdit reaches the note from the reopened sheet")
    }

    /// A send that began on crew `deck` and finishes after the column has gone to `other`
    /// and back to `deck` must not land its notice or kept row on the sheet now showing.
    /// The crew name matches again, so only the per-switch generation can tell the two
    /// sheets apart.
    func testASendFromCrewAThatFinishesAfterAToBToAHasNoEffectOnTheReturnedSheet() async throws {
        let gate = SendGate()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: SentLog())
        model.loadSigningKey = { nil }
        model.writeSend = { _, _, id, _ in
            gate.enter()
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a note")))
        }
        let sending = Task { await model.send(id: "n-1", host: "macstudio") }
        await Task.detached { gate.waitUntilEntered() }.value
        model.start(session: "other", target: target)
        model.start(session: "deck", target: target)
        await model.refresh()
        gate.release()
        await sending.value

        XCTAssertNil(model.sendNotices["n-1"], "the notice must not land on the sheet the column came back to")
        XCTAssertFalse(model.localNoteIDs.contains("n-1"), "no kept row may appear on the returned sheet")
    }

    /// A send still in flight when the column goes to crew `other` and back to `deck` keeps
    /// its note locked on `deck`: Delete, edit and Send are refused until the send settles.
    /// Crew `other` never sees `deck`'s in-flight note, so its Send is enabled. Only the first
    /// host write waits on the gate; the attempts made while it is held run in tasks, so a
    /// model that lets one through cannot hang the test. The count shows what reached the host.
    func testASendInFlightAcrossACrewRoundTripKeepsItsNoteLockedOnTheReturnedSheet() async throws {
        let gate = SendGate()
        let sent = SentLog()
        let sends = CallCount()
        let deletes = CallCount()
        let model = await modelWithNote(capabilities: [], sent: sent)
        model.loadSigningKey = { nil }
        model.writeSend = { _, _, id, sig in
            sends.add()
            sent.append(id: id, sig: sig)
            if sends.count == 1 { gate.enter() }
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a note")))
        }
        model.writeDeleteNote = { _, _, id in
            deletes.add()
            return .deleted(id: id)
        }

        let sending = Task { await model.send(id: "n-1", host: "macstudio") }
        await Task.detached { gate.waitUntilEntered() }.value

        model.start(session: "other", target: target)
        await model.refresh()
        XCTAssertTrue(model.sendEnabled(id: "n-1"), "crew other never sees deck's in-flight send")
        XCTAssertTrue(model.canEditNote(id: "n-1"), "crew other never sees deck's in-flight send")

        model.start(session: "deck", target: target)
        await model.refresh()
        XCTAssertFalse(model.sendEnabled(id: "n-1"), "control: Send is refused while the send is in flight")
        XCTAssertFalse(model.canEditNote(id: "n-1"), "the editor is refused while the send is in flight")

        let beforeAttempts = sends.count
        let typed = Task { model.editNote(id: "n-1", text: "typed after the round trip") }
        let deleting = Task { await model.deleteNote(id: "n-1") }
        let resending = Task { await model.send(id: "n-1", host: "macstudio") }
        _ = await typed.value
        XCTAssertEqual(model.noteDrafts["n-1"], "a note", "the text typed after the round trip does not land")

        gate.release()
        await sending.value
        await deleting.value
        await resending.value
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(sends.count, beforeAttempts, "a second Send must not reach the host")
        XCTAssertEqual(sent.values.count, 1, "slate-send ran once")
        XCTAssertEqual(deletes.count, 0, "Delete must not reach the host while the send is in flight")

        await model.refresh()
        XCTAssertTrue(model.canEditNote(id: "n-1"), "the note is editable again once the send has settled")
        XCTAssertTrue(model.sendEnabled(id: "n-1"), "the note is sendable again once the send has settled")
    }

    /// An append-only counter written from the `@Sendable` closures the model runs off
    /// the main actor.
    private final class CallCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// An append-only log of the writes a test saw, in the order they reached the host.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ event: String) { lock.lock(); storage.append(event); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// Polls until `condition` holds, for a write that runs after a debounce.
    private func pollUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A kept sent note's text is read-only at the seam the view uses: `canEditNote` is
    /// off for its row, and `editNote` leaves the text and schedules no write, so no edit
    /// reaches the note the host delivered. The control is the same row before its send,
    /// where an edit does reach the host, so the counter is shown to see writes.
    func testAKeptSentNoteCannotBeEdited() async throws {
        let writes = CallCount()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: SentLog())
        model.writeCreateNote = { _, _, text in
            writes.add()
            return .card(.note(SlateCard.Note(id: "n-9", state: .draft, text: text)))
        }
        model.writeEdit = { _, _, id, text in
            writes.add()
            return .card(.note(SlateCard.Note(id: id, state: .draft, text: text)))
        }
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [
                .note(SlateCard.Note(id: "n-1", state: .draft, text: "a note")),
                .note(SlateCard.Note(id: "n-9", state: .draft, text: "a draft note")),
            ], capabilities: [SlateAnswerSignature.capability])
        }
        model.loadSigningKey = { nil }
        model.createNote()
        let local = try XCTUnwrap(model.localNoteIDs.first)
        model.editNote(id: local, text: "a draft note")
        try await pollUntil { writes.count == 1 }
        XCTAssertEqual(writes.count, 1, "control: the row takes its text and writes it before the send")
        XCTAssertTrue(model.canEditNote(id: local))

        await model.send(id: local, host: "macstudio")
        let beforeEdit = writes.count
        XCTAssertFalse(model.canEditNote(id: local))
        model.editNote(id: local, text: "changed after the send")
        XCTAssertEqual(model.noteDrafts[local], "a draft note", "the kept row's text does not change")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(writes.count, beforeEdit, "no write may reach the note the host already delivered")
    }

    /// The other side of that rule: on a host without the capability, a refused flush
    /// still goes out unsigned, as it always has.
    func testARefusedEditOnAHostWithoutTheCapabilityStillSendsUnsigned() async {
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [], sent: sent,
                                        writeEdit: { _, _, _, _ in .refused("the note is resolved") })
        model.loadSigningKey = { nil }
        model.editNote(id: "n-1", text: "a note")
        await model.send(id: "n-1", host: "macstudio")

        XCTAssertEqual(sent.values.map { $0.id }, ["n-1"])
        XCTAssertEqual(sent.values.map { $0.sig }, [nil])
    }

    /// The sibling of the test above, with the sheet closed during the send. The refused
    /// save leaves nothing landed, but the unsigned send delivers the host text, so the
    /// flush behind it must not save again. The gate holds the send open across `stop()`.
    func testClosingTheSheetDuringAnUnsignedSendWithARefusedSaveMakesNoEditAfterTheDeliveredSend() async throws {
        let gate = SendGate()
        let sent = SentLog()
        let events = EventLog()
        let model = await modelWithNote(capabilities: [], sent: sent,
                                        writeEdit: { _, _, _, text in
                                            events.append("refused:\(text)")
                                            return .refused("the note is resolved")
                                        })
        model.loadSigningKey = { nil }
        model.writeSend = { _, _, id, sig in
            events.append("send")
            sent.append(id: id, sig: sig)
            gate.enter()
            return .card(.note(SlateCard.Note(id: id, state: .sent, text: "a note")))
        }
        model.editNote(id: "n-1", text: "a note, revised")

        let sending = Task { await model.send(id: "n-1", host: "macstudio") }
        await Task.detached { gate.waitUntilEntered() }.value
        model.stop()
        gate.release()
        await sending.value
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(sent.values.map { $0.sig }, [nil], "the send goes out unsigned")
        XCTAssertEqual(events.values, ["refused:a note, revised", "send"],
                       "no edit may follow the delivered send")
    }

    /// A card another writer changed before signing is refused, not signed as the old
    /// text. The flush saved "the answer"; the read before signing finds the card
    /// holding other text. That read runs before the Touch ID prompt, so a change made
    /// during the prompt is not caught; this test covers only a change the read sees.
    func testACardChangedBeforeSigningRefusesTheSend() async {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithAsk(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { key }
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [.ask(SlateCard.Ask(
                id: "a-1", state: .open, question: "q", answerDraft: "changed by someone else", answer: nil))],
                  capabilities: [SlateAnswerSignature.capability])
        }
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1", host: "macstudio")

        XCTAssertTrue(sent.values.isEmpty, "a changed card must not be sent")
        XCTAssertTrue(key.signedMessages.isEmpty, "no signature over text the card no longer holds")
        XCTAssertEqual(model.sendErrors["a-1"],
                       "The Slate's text for this card changed before signing, so nothing was sent.")
    }

    /// A card the read before signing no longer lists counts as changed.
    func testACardGoneBeforeSigningRefusesTheNoteSend() async {
        let key = RecordingAnswerKey()
        let sent = SentLog()
        let model = await modelWithNote(capabilities: [SlateAnswerSignature.capability], sent: sent)
        model.loadSigningKey = { key }
        model.fetchSlate = { _, session in Slate(session: session, cards: [], capabilities: [SlateAnswerSignature.capability]) }
        model.editNote(id: "n-1", text: "a note")
        await model.send(id: "n-1", host: "macstudio")

        XCTAssertTrue(sent.values.isEmpty)
        XCTAssertTrue(key.signedMessages.isEmpty)
        XCTAssertEqual(model.sendErrors["n-1"],
                       "The Slate's text for this card changed before signing, so nothing was sent.")
    }

    // MARK: The argv

    /// `--sig` follows the card id as its own argv pair, and only when given.
    func testSlateSendPassesTheSignatureOnlyWhenGiven() throws {
        let plain = try SessionAgent.slateSendArguments(target: target, session: "deck", id: "a-1")
        XCTAssertEqual(plain.suffix(3), ["slate-send", "deck", "a-1"])
        XCTAssertFalse(plain.contains("--sig"))

        let signed = try SessionAgent.slateSendArguments(target: target, session: "deck", id: "a-1",
                                                         sig: "AAAA.BBBB")
        XCTAssertEqual(signed.suffix(5), ["slate-send", "deck", "a-1", "--sig", "AAAA.BBBB"])
    }

    func testSlateSendRefusesAMalformedSignatureBeforeAnySSH() {
        XCTAssertThrowsError(
            try SessionAgent.slateSendArguments(target: target, session: "deck", id: "a-1", sig: "AA BB; rm -rf"))
    }

    // MARK: The capability on the Slate envelope

    func testTheCapabilityIsReadFromTheSlateEnvelope() {
        let listed = Slate.decode(Data(#"{"ok": true, "session": "deck", "cards": [], "capabilities": ["slate-sig-v1"]}"#.utf8),
                                  fallbackSession: "deck")
        XCTAssertEqual(listed?.capabilities, ["slate-sig-v1"])

        let absent = Slate.decode(Data(#"{"ok": true, "session": "deck", "cards": []}"#.utf8),
                                  fallbackSession: "deck")
        XCTAssertEqual(absent?.capabilities, [], "an older host lists none, so it reads as unsigned")
    }
}
