import Foundation
import XCTest
@testable import Deck

/// An append-only list safe to write from the `@Sendable` closures the model
/// runs off the main actor — `CockpitModelTests`' own `LockedList`, repeated
/// here since that one is file-private.
private final class LockedList<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ value: T) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// `DispatchSemaphore.wait` is unavailable inside an async closure; a sync
/// function is not — `CockpitModelTests`' own `blockOn`, repeated here since
/// that one is file-private.
private func blockOn(_ semaphore: DispatchSemaphore) { semaphore.wait() }

/// The characters Python's `str.strip()` removes, which is the set the host's
/// note text is trimmed with. Foundation's `whitespacesAndNewlines` also holds
/// U+200B, which Python does not strip, so it is taken out here.
private let pythonStripSet = CharacterSet.whitespacesAndNewlines
    .subtracting(CharacterSet(charactersIn: "\u{200B}"))
    .union(CharacterSet(charactersIn: "\u{1C}\u{1D}\u{1E}\u{1F}"))

private let testTarget = SSHTarget(user: "operator", host: "macstudio")

private func askCard(id: String, state: SlateCard.Ask.State = .open, question: String = "q",
                     answerDraft: String? = nil, answer: String? = nil) -> SlateCard {
    .ask(SlateCard.Ask(id: id, state: state, question: question, answerDraft: answerDraft, answer: answer))
}

private func noteCard(id: String, state: SlateCard.Note.State = .draft, text: String = "") -> SlateCard {
    .note(SlateCard.Note(id: id, state: state, text: text))
}

/// An in-memory stand-in for the host's Slate verbs. It refuses what the host
/// refuses: a note whose text is empty or whitespace-only (`agent-platform`'s
/// `slate.py` `create_note`, which raises "a note must not be empty"), and a
/// write to an id it does not hold. Every call is logged, so a test can assert
/// which writes reached the host at all.
private final class FakeSlateHost: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [SlateCard.Note] = []
    private var sequence = 0
    private var log: [String] = []
    private var createRefusal: String?

    /// Every write the host has received, in arrival order.
    var calls: [String] { locked { log } }
    /// Every note the host holds, sent ones included.
    var heldNotes: [SlateCard.Note] { locked { notes } }

    /// Makes every create refuse with `message`, the way a full Slate does.
    func refuseCreates(with message: String) { locked { createRefusal = message } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// A read lists draft notes only, as `slate` does without `--all`.
    func fetch(session: String) -> Slate {
        locked { Slate(session: session, cards: notes.filter { $0.state == .draft }.map(SlateCard.note)) }
    }

    /// Trims the text the way the host does on create, with Python's
    /// `str.strip()` set (`agent-platform`'s `slate.py`), so a note holds exactly
    /// what the contract's Note table says it holds.
    func create(text: String) -> SessionAgent.SlateWriteOutcome {
        locked {
            log.append("create:\(text)")
            if let createRefusal { return .refused(createRefusal) }
            let stored = text.trimmingCharacters(in: pythonStripSet)
            guard !stored.isEmpty else {
                return .refused("a note must not be empty")
            }
            sequence += 1
            let note = SlateCard.Note(id: "n-\(sequence)", state: .draft, text: stored)
            notes.append(note)
            return .card(.note(note))
        }
    }

    func edit(id: String, text: String) -> SessionAgent.SlateWriteOutcome {
        locked {
            log.append("edit:\(id):\(text)")
            guard let index = notes.firstIndex(where: { $0.id == id }) else { return .refused("no card \(id)") }
            notes[index].text = text
            return .card(.note(notes[index]))
        }
    }

    func send(id: String) -> SessionAgent.SlateWriteOutcome {
        locked {
            log.append("send:\(id)")
            guard let index = notes.firstIndex(where: { $0.id == id }) else { return .refused("no card \(id)") }
            notes[index].state = .sent
            return .card(.note(notes[index]))
        }
    }

    func delete(id: String) -> SessionAgent.SlateDeleteOutcome {
        locked {
            log.append("delete:\(id)")
            guard let index = notes.firstIndex(where: { $0.id == id }) else { return .refused("no card \(id)") }
            notes.remove(at: index)
            return .deleted(id: id)
        }
    }
}

/// Points a model's read and every write at `host`, the way the live verbs
/// reach a crew's board.
@MainActor
private func wire(_ model: SlateModel, to host: FakeSlateHost) {
    model.fetchSlate = { _, session in host.fetch(session: session) }
    model.writeCreateNote = { _, _, text in host.create(text: text) }
    model.writeEdit = { _, _, id, text in host.edit(id: id, text: text) }
    model.writeSend = { _, _, id, _ in host.send(id: id) }
    model.writeDeleteNote = { _, _, id in host.delete(id: id) }
}

/// Set by a main-actor task once a write chain has finished, read by `settle`.
@MainActor private final class Flag {
    var isSet = false
}

/// `SlateModel` — the Slate sheet's polling, draft-preserving and
/// flush-before-send behaviour. The ssh/decode seam itself is
/// `SessionAgentTests`'/`SlateTests`' job; what is testable here is that the
/// model never lets a poll clobber an in-progress edit, and never lets a send
/// race its own debounced write.
@MainActor
final class SlateModelTests: XCTestCase {

    func testRefreshPublishesTheFetchedSlate() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [askCard(id: "a-1")]) }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        XCTAssertEqual(model.slate?.cards.count, 1)
        XCTAssertNil(model.readError)
    }

    /// The sheet's own "state unknown": a transport failure sets `readError`
    /// rather than leaving the last good read looking current.
    func testAFailedFetchSetsReadError() async {
        let model = SlateModel()
        model.fetchSlate = { _, _ in throw SessionAgent.AgentError.failed("unreachable") }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        XCTAssertNil(model.slate)
        XCTAssertEqual(model.readError, "unreachable")
    }

    /// `nil` is `Slate.decode`'s own "the envelope itself could not be read" —
    /// a host whose `session-agent` predates the verb, or sent unreadable
    /// JSON. Same "state unknown" outcome as a thrown error.
    func testANilSlateAlsoSetsReadError() async {
        let model = SlateModel()
        model.fetchSlate = { _, _ in nil }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        XCTAssertNotNil(model.readError)
    }

    /// "Restore the field from `answer_draft` on launch" — seeded once.
    func testAnAnswerDraftIsSeededFromTheFirstRead() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [askCard(id: "a-1", answerDraft: "from the server")])
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        XCTAssertEqual(model.answerDrafts["a-1"], "from the server")
    }

    /// THE CASE THIS FIELD EXISTS FOR: once seeded, a later poll must never
    /// overwrite what the operator is typing, even when the server's own
    /// `answer_draft` (not yet caught up with Deck's own debounced write)
    /// still reads the old value.
    func testALaterPollNeverOverwritesALocalEdit() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in
            Slate(session: session, cards: [askCard(id: "a-1", answerDraft: "server's stale copy")])
        }
        model.writeEdit = { _, _, _, _ in .card(askCard(id: "a-1")) }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editAnswer(id: "a-1", text: "what the operator is typing right now")
        await model.refresh()
        XCTAssertEqual(model.answerDrafts["a-1"], "what the operator is typing right now")
    }

    func testCanSendIsFalseForEmptyOrWhitespace() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [askCard(id: "a-1")]) }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        XCTAssertFalse(model.canSend(id: "a-1"))
        model.editAnswer(id: "a-1", text: "   \n\t  ")
        XCTAssertFalse(model.canSend(id: "a-1"))
        model.editAnswer(id: "a-1", text: "an answer")
        XCTAssertTrue(model.canSend(id: "a-1"))
    }

    /// `slate-send` delivers the server's own `answer_draft`, not whatever
    /// Deck's field shows — so a send must flush the latest typed text
    /// through `slate-edit` and WAIT for it before calling `slate-send`,
    /// rather than racing the debounce already scheduled from `editAnswer`.
    func testSendFlushesTheLatestEditBeforeSending() async {
        let model = SlateModel()
        let calls = LockedList<String>()
        model.fetchSlate = { _, session in Slate(session: session, cards: [askCard(id: "a-1")]) }
        model.writeEdit = { _, _, id, text in
            calls.append("edit:\(id):\(text)")
            return .card(askCard(id: id, state: .open, answerDraft: text))
        }
        model.writeSend = { _, _, id, _ in
            calls.append("send:\(id)")
            return .card(askCard(id: id, state: .answered, answerDraft: "the answer", answer: "the answer"))
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1")
        XCTAssertEqual(calls.values, ["edit:a-1:the answer", "send:a-1"],
                       "the flush must land before the send, carrying the latest text")
    }

    /// "After Send, the card shows as answered" — within the action, not
    /// waiting on the next poll.
    func testASuccessfulSendAppliesTheReturnedCardAtOnce() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [askCard(id: "a-1")]) }
        model.writeEdit = { _, _, id, text in .card(askCard(id: id, answerDraft: text)) }
        model.writeSend = { _, _, id, _ in
            .card(askCard(id: id, state: .answered, answerDraft: "the answer", answer: "the answer"))
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1")
        guard case .ask(let ask) = model.slate?.cards.first else { return XCTFail("expected the ask card") }
        XCTAssertEqual(ask.state, .answered)
        XCTAssertEqual(ask.answer, "the answer")
        XCTAssertNil(model.sendErrors["a-1"])
    }

    /// "A card changes state only after delivery succeeds" — on a refusal the
    /// card is left exactly as it was, and the error surfaces under it.
    func testARefusedSendLeavesTheCardUnchanged() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [askCard(id: "a-1")]) }
        model.writeEdit = { _, _, id, text in .card(askCard(id: id, answerDraft: text)) }
        model.writeSend = { _, _, _, _ in .refused("no claude process found in any pane of 'deck'") }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editAnswer(id: "a-1", text: "the answer")
        await model.send(id: "a-1")
        guard case .ask(let ask) = model.slate?.cards.first else { return XCTFail("expected the ask card") }
        XCTAssertEqual(ask.state, .open)
        XCTAssertEqual(model.sendErrors["a-1"], "no claude process found in any pane of 'deck'")
    }

    /// Disabled while empty: `send` must be a no-op rather than deliver
    /// whitespace to a server that would itself refuse it.
    /// Polls until `condition` is true, up to `timeout` — the pending write
    /// this exercises is an unstructured `Task`, so a test has to wait for
    /// it rather than assume it already landed (`CockpitModelTests`'
    /// `waitForChildren` is the same shape).
    private func wait(upTo timeout: TimeInterval = 2, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits until `id`'s write chain has finished, or two seconds pass. Fails
    /// the test when no chain is registered for `id`, since that means the
    /// write the test meant to wait on was never queued, and when the chain is
    /// still running after the wait, such as a write blocked on a test's
    /// semaphore. So a negative assertion after `settle` cannot pass vacuously.
    private func settle(_ model: SlateModel, _ id: String,
                        file: StaticString = #filePath, line: UInt = #line) async {
        guard let chain = model.editChain(for: id) else {
            return XCTFail("no write chain is registered for '\(id)'", file: file, line: line)
        }
        let finished = Flag()
        Task { await chain.value; finished.isSet = true }
        await wait { finished.isSet }
        XCTAssertTrue(finished.isSet, "the write chain for '\(id)' did not finish within the wait",
                      file: file, line: line)
    }

    /// Waits for `id`'s write chain if one is registered, and asserts nothing
    /// when none is. Use it only where a chain may legitimately be absent, such
    /// as a stop that has nothing left to flush.
    private func drainChain(_ model: SlateModel, _ id: String) async {
        guard let chain = model.editChain(for: id) else { return }
        let finished = Flag()
        Task { await chain.value; finished.isSet = true }
        await wait { finished.isSet }
    }

    /// Closing the sheet (`stop()`) within the 400ms debounce window must
    /// still deliver the typed text rather than cancel it — the epic's own
    /// "nothing is lost" guarantee extended from quitting Deck to closing
    /// one sheet. Raised in review.
    func testStopFlushesAPendingDebouncedEditInsteadOfDroppingIt() async {
        let model = SlateModel()
        let calls = LockedList<String>()
        model.fetchSlate = { _, session in Slate(session: session, cards: [askCard(id: "a-1")]) }
        model.writeEdit = { _, _, id, text in
            calls.append(text)
            return .card(askCard(id: id, answerDraft: text))
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editAnswer(id: "a-1", text: "typed just before closing")
        model.stop()
        await wait { !calls.values.isEmpty }
        XCTAssertEqual(calls.values, ["typed just before closing"])
    }

    /// Previously swallowed by `try?`: a debounced `slate-edit` that fails
    /// must surface under the card the way a failed `send` already does,
    /// rather than leaving the operator with no sign their edit never
    /// saved. Raised in review.
    func testAFailedDebouncedEditSurfacesUnderTheCard() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [askCard(id: "a-1")]) }
        model.writeEdit = { _, _, _, _ in throw SessionAgent.AgentError.failed("unreachable") }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editAnswer(id: "a-1", text: "an answer")
        await wait { model.sendErrors["a-1"] != nil }
        XCTAssertEqual(model.sendErrors["a-1"], "unreachable")
    }

    /// Cancelling the debounce task only stops it while it is still asleep;
    /// once a write is already executing, cancellation is a no-op on the
    /// in-flight call, so a slow older write could otherwise land after a
    /// faster newer one and silently overwrite it. The write for an id must
    /// always wait on whichever write that id already had pending or in
    /// flight, so two writes for the same id land in schedule order no
    /// matter which one's network round trip happens to finish first.
    /// Raised in review, the same class of bug
    /// `SessionPaneModel.renderGeneration` closes for renders.
    func testAnOlderInFlightEditCanNeverLandAfterANewerOne() async {
        let model = SlateModel()
        let calls = LockedList<String>()
        let started = LockedList<String>()
        model.fetchSlate = { _, session in Slate(session: session, cards: [askCard(id: "a-1")]) }
        model.writeEdit = { _, _, id, text in
            started.append(text)
            // "A"'s own write is deliberately the slow one — long enough to
            // still be in flight once "B"'s entire debounce has elapsed —
            // so only the chain, not timing luck, keeps the order correct.
            if text == "A" { Thread.sleep(forTimeInterval: 0.6) }
            calls.append(text)
            return .card(askCard(id: id, answerDraft: text))
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editAnswer(id: "a-1", text: "A")
        // Wait for evidence "A"'s write has actually begun — i.e. it is
        // already past the point cancellation could stop it — rather than
        // guessing a wall-clock margin past its debounce, which a busy test
        // run can blow through before "A" ever wakes.
        await wait(upTo: 3) { started.values.contains("A") }
        model.editAnswer(id: "a-1", text: "B")
        await wait(upTo: 3) { calls.values.count >= 2 }
        XCTAssertEqual(calls.values, ["A", "B"],
                       "B must never land before A, even though A's call started first and runs longer")
    }

    /// Three or more keystrokes against one slow in-flight write must still
    /// land in order. Fails against a561a10: there, a chain link cancelled
    /// while still asleep in its own debounce returned before awaiting its
    /// predecessor, so the wait on a genuinely in-flight older write stopped
    /// propagating past it. Concrete repro, matching round 2 review: "A"
    /// starts a slow in-flight write; "B" chains onto "A" and is cancelled,
    /// still asleep in its own debounce, the instant "C" arrives; "C" must
    /// still end up waiting on "A" through "B", even though "B" itself never
    /// performs its own write.
    func testThreeGenerationsAgainstOneSlowInFlightEditStillLandInOrder() async {
        let model = SlateModel()
        let calls = LockedList<String>()
        let started = LockedList<String>()
        model.fetchSlate = { _, session in Slate(session: session, cards: [askCard(id: "a-1")]) }
        model.writeEdit = { _, _, id, text in
            started.append(text)
            if text == "A" { Thread.sleep(forTimeInterval: 0.6) }
            calls.append(text)
            return .card(askCard(id: id, answerDraft: text))
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editAnswer(id: "a-1", text: "A")
        await wait(upTo: 3) { started.values.contains("A") }
        // "B" and "C" arrive back to back, with no await between them, so
        // "B" is cancelled while still asleep in its own debounce — it never
        // reaches the point of awaiting "A" on its own behalf.
        model.editAnswer(id: "a-1", text: "B")
        model.editAnswer(id: "a-1", text: "C")
        await wait(upTo: 3) { calls.values.count >= 2 }
        XCTAssertEqual(calls.values, ["A", "C"],
                       "C must never land before A, even through a cancelled middle generation")
    }

    /// Send pressed while an earlier edit is still on the chain must go out after
    /// that edit lands. "A" is in flight and slow when "B" is typed, so "B" is
    /// still asleep in its debounce when Send is pressed. Send carries "B", the
    /// text on screen, and its own flush and send must wait for "A" to land
    /// before they run. Fails when `send` does not wait on the link it chains
    /// behind: the flush of "B" and the send would then go out while "A" is
    /// still writing, so the calls read `["edit:B", "send:a-1"]` when checked.
    func testASendPressedWhileAnEditIsOnTheChainWaitsForIt() async {
        let model = SlateModel()
        let calls = LockedList<String>()
        let started = LockedList<String>()
        model.fetchSlate = { _, session in Slate(session: session, cards: [askCard(id: "a-1")]) }
        model.writeEdit = { _, _, id, text in
            started.append(text)
            if text == "A" { Thread.sleep(forTimeInterval: 0.6) }
            calls.append("edit:\(text)")
            return .card(askCard(id: id, answerDraft: text))
        }
        model.writeSend = { _, _, id, _ in
            calls.append("send:\(id)")
            return .card(askCard(id: id, state: .answered, answerDraft: "B", answer: "B"))
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editAnswer(id: "a-1", text: "A")
        await wait(upTo: 3) { started.values.contains("A") }
        model.editAnswer(id: "a-1", text: "B")
        await model.send(id: "a-1")
        XCTAssertEqual(calls.values, ["edit:A", "edit:B", "send:a-1"],
                       "a send pressed while an earlier edit is on the chain must go out after that edit lands")
    }

    func testSendDoesNothingWhileTheAnswerIsEmpty() async {
        let model = SlateModel()
        let calls = LockedList<String>()
        model.fetchSlate = { _, session in Slate(session: session, cards: [askCard(id: "a-1")]) }
        model.writeSend = { _, _, id, _ in calls.append("send:\(id)"); return .malformed }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        await model.send(id: "a-1")
        XCTAssertTrue(calls.values.isEmpty)
    }

    // MARK: - Notes

    /// "A 'New note' control creates a draft" — a row on the sheet that writes
    /// nothing to the host until the operator types. The host refuses empty
    /// notes, so a New Note that created one would fail on the spot.
    func testNewNoteOpensADraftAndWritesNothingToTheHost() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        XCTAssertEqual(model.localNoteIDs.count, 1)
        XCTAssertTrue(model.sheetCards.isEmpty)
        XCTAssertTrue(host.calls.isEmpty, "New Note must not reach the host before the operator types")
    }

    /// The first non-empty text creates the note on the host, through the
    /// debounced path; later text edits the id the host returned.
    func testTheFirstNonEmptyTextCreatesTheNoteAndLaterTextEditsIt() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "h")
        await wait { model.slate?.cards.map(\.id) == ["n-1"] }
        XCTAssertEqual(host.calls, ["create:h"])
        XCTAssertEqual(model.localNoteIDs, [key], "the draft keeps its row once the host holds the note")
        XCTAssertTrue(model.sheetCards.isEmpty, "the host's copy is drawn through the draft, not twice")
        model.editNote(id: key, text: "hello")
        await wait { host.calls.count >= 2 }
        XCTAssertEqual(host.calls, ["create:h", "edit:n-1:hello"])
        XCTAssertEqual(host.heldNotes.map(\.text), ["hello"])
    }

    /// A draft's card draws the host id once the host creates its note, on the
    /// same sheet with no reopen: `draftHostIDs` is the observed state the card
    /// reads. Before the create lands the draft has no host id to draw, and a
    /// create the host refuses never gives it one.
    func testADraftsHostIDAppearsOnItsRowOnceTheCreateLands() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        XCTAssertNil(model.draftHostIDs[key], "no id is drawn before the host holds the note")
        model.editNote(id: key, text: "h")
        await wait { model.draftHostIDs[key] == "n-1" }
        XCTAssertEqual(model.draftHostIDs[key], "n-1", "the row draws the id the host returned")
        XCTAssertEqual(model.localNoteIDs, [key], "the same row keeps its place and editor")
        XCTAssertTrue(model.sheetCards.isEmpty, "the host's copy is still drawn through the draft")
    }

    /// The negative direction of the id test: a create the host refuses leaves
    /// no host note, so the draft keeps drawing no id.
    func testARefusedCreateGivesTheDraftNoHostID() async {
        let host = FakeSlateHost()
        host.refuseCreates(with: "the Slate is full")
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "h")
        await wait { model.sendErrors[key] != nil }
        XCTAssertNil(model.draftHostIDs[key])
    }

    /// Whitespace-only text is not a first write, since the host refuses it.
    /// The draft is typed into twice. The blank draft's write chain is awaited
    /// to its end before the positive control, so an absent create means the
    /// blank text was never sent, not that its debounce has not fired yet.
    func testAWhitespaceOnlyDraftNeverReachesTheHost() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let blankKey = model.localNoteIDs[0]
        model.editNote(id: blankKey, text: "  \n\t ")
        await settle(model, blankKey)
        XCTAssertTrue(host.calls.isEmpty, "whitespace-only text must never be created on the host")

        model.createNote()
        model.editNote(id: model.localNoteIDs[1], text: "ok")
        await wait { host.calls.count >= 1 }
        XCTAssertEqual(host.calls, ["create:ok"], "the positive control: a real draft still creates")
    }

    /// Text made only of U+001C to U+001F is empty to the host, which trims
    /// those characters too. So Deck never creates it, Send is disabled for it,
    /// and closing the sheet drops it. Fails against d5ba54e, where the create
    /// was sent and the host refused it. The second draft shows that the same
    /// separators around real text still create the note.
    func testAControlSeparatorOnlyDraftIsTreatedAsEmpty() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        model.editNote(id: model.localNoteIDs[0], text: "\u{1C}\u{1D}\u{1E}\u{1F}")
        XCTAssertFalse(model.canSend(id: model.localNoteIDs[0]))

        model.createNote()
        let keptKey = model.localNoteIDs[1]
        model.editNote(id: keptKey, text: "\u{1C}ok\u{1D}")
        // Wait until the create's reply is adopted, not merely received: a close
        // during the reply round trip flushes an edit onto that note.
        await wait { model.slate?.cards.map(\.id) == ["n-1"] }
        model.stop()
        // The create landed before the stop, so nothing is left to flush and no
        // chain may be registered. The positive asserts below still prove the send.
        await drainChain(model, keptKey)
        XCTAssertEqual(model.localNoteIDs, [keptKey], "the separator-only draft is dropped on close")
        XCTAssertEqual(host.calls, ["create:\u{1C}ok\u{1D}"],
                       "only the draft with real text reaches the host")
    }

    /// A draft closed while still empty is dropped, and nothing was written.
    func testAnEmptyDraftClosedIsDiscardedWithNothingWritten() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        model.stop()
        XCTAssertTrue(model.localNoteIDs.isEmpty)
        XCTAssertTrue(host.calls.isEmpty)
    }

    /// A draft typed into and closed within the debounce window is flushed to
    /// the host, so a reopened sheet shows it with its text.
    func testATypedDraftClosedMidDebounceSurvivesReopening() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        model.editNote(id: model.localNoteIDs[0], text: "keep me")
        model.stop()
        await wait { !host.calls.isEmpty }

        let reopened = SlateModel()
        wire(reopened, to: host)
        reopened.start(session: "deck", target: testTarget)
        await reopened.refresh()
        guard case .note(let note) = reopened.slate?.cards.first else { return XCTFail("expected the note card") }
        XCTAssertEqual(note.text, "keep me")
        XCTAssertEqual(reopened.noteDrafts[note.id], "keep me")
    }

    /// Send on a draft the host has not seen creates the note with its text,
    /// then sends it — once, with no second create from the debounce it
    /// superseded.
    func testSendOfADraftCreatesItOnceThenSendsIt() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "send me")
        await model.send(id: key)
        XCTAssertEqual(host.calls, ["create:send me", "send:n-1"])
        XCTAssertEqual(host.heldNotes.map(\.state), [.sent])
        XCTAssertNil(model.sendErrors[key])
        XCTAssertTrue(model.localNoteIDs.isEmpty, "a delivered draft leaves the sheet")
    }

    /// Send pressed while the draft's create is still in flight waits for that
    /// create, then edits and sends the id it returned. It never creates a
    /// second note.
    func testSendDuringAnInFlightCreateNeverCreatesASecondNote() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        model.stop()
        await model.send(id: key)
        XCTAssertEqual(host.calls, ["create:x", "edit:n-1:x", "send:n-1"])
    }

    /// Delete of a draft whose create is still in flight waits for the create,
    /// then deletes the note it made.
    func testDeletingADraftWhileItsCreateIsInFlightRemovesTheHostNote() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        model.stop()
        await model.deleteNote(id: key)
        XCTAssertEqual(host.calls, ["create:x", "delete:n-1"])
        XCTAssertTrue(host.heldNotes.isEmpty)
        XCTAssertTrue(model.localNoteIDs.isEmpty)
        XCTAssertTrue(model.sheetCards.isEmpty)
    }

    /// Delete of a draft the host never received only drops the row.
    func testDeletingAnEmptyDraftNeverReachesTheHost() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        await model.deleteNote(id: key)
        XCTAssertTrue(model.localNoteIDs.isEmpty)
        XCTAssertTrue(host.calls.isEmpty)
    }

    /// A refused create surfaces under the draft, and the draft stays so the
    /// operator can change the text and try again.
    func testAFirstWriteRefusedByTheHostShowsUnderTheDraft() async {
        let host = FakeSlateHost()
        host.refuseCreates(with: "the Slate is full")
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        await wait { model.sendErrors[key] != nil }
        XCTAssertEqual(model.sendErrors[key], "the Slate is full")
        XCTAssertEqual(model.localNoteIDs, [key])
        XCTAssertTrue(host.heldNotes.isEmpty)
    }

    /// Restores a note's `text` into the editable field once per id, the
    /// same "seeded once" rule `answerDrafts` follows for an ask.
    func testANoteDraftIsSeededFromTheFirstRead() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1", text: "from the server")]) }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        XCTAssertEqual(model.noteDrafts["n-1"], "from the server")
    }

    /// THE SAME CASE `testALaterPollNeverOverwritesALocalEdit` EXISTS FOR
    /// ASKS, extended to notes through `editNote`: a later poll must never
    /// overwrite what the operator is typing into a note.
    func testALaterPollNeverOverwritesALocalNoteEdit() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1", text: "server's stale copy")]) }
        model.writeEdit = { _, _, _, _ in .card(noteCard(id: "n-1")) }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editNote(id: "n-1", text: "what the operator is typing right now")
        await model.refresh()
        XCTAssertEqual(model.noteDrafts["n-1"], "what the operator is typing right now")
    }

    func testCanSendIsFalseForAnEmptyOrWhitespaceNoteDraft() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1")]) }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        XCTAssertFalse(model.canSend(id: "n-1"))
        model.editNote(id: "n-1", text: "   \n\t  ")
        XCTAssertFalse(model.canSend(id: "n-1"))
        model.editNote(id: "n-1", text: "a note")
        XCTAssertTrue(model.canSend(id: "n-1"))
    }

    /// `send` is the one implementation for both card kinds — this exercises
    /// it against a note, the same flush-before-send guarantee
    /// `testSendFlushesTheLatestEditBeforeSending` pins for an ask.
    func testSendingANoteFlushesTheLatestEditFirst() async {
        let model = SlateModel()
        let calls = LockedList<String>()
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1")]) }
        model.writeEdit = { _, _, id, text in
            calls.append("edit:\(id):\(text)")
            return .card(noteCard(id: id, text: text))
        }
        model.writeSend = { _, _, id, _ in
            calls.append("send:\(id)")
            return .card(noteCard(id: id, state: .sent, text: "the note"))
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editNote(id: "n-1", text: "the note")
        await model.send(id: "n-1")
        XCTAssertEqual(calls.values, ["edit:n-1:the note", "send:n-1"],
                       "the flush must land before the send, carrying the latest text")
    }

    /// "After Send, the card is marked sent" — applied within the action.
    /// Leaving the sheet is the server's own job on the next poll (`slate`
    /// hides a sent note without `--all`), not something this model forces.
    func testASuccessfulNoteSendMarksTheCardSentAtOnce() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1")]) }
        model.writeEdit = { _, _, id, text in .card(noteCard(id: id, text: text)) }
        model.writeSend = { _, _, id, _ in .card(noteCard(id: id, state: .sent, text: "the note")) }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editNote(id: "n-1", text: "the note")
        await model.send(id: "n-1")
        guard case .note(let note) = model.slate?.cards.first else { return XCTFail("expected the note card") }
        XCTAssertEqual(note.state, .sent)
        XCTAssertNil(model.sendErrors["n-1"])
    }

    /// "A card changes state only after delivery succeeds" — a refused note
    /// send leaves the draft exactly as it was.
    func testARefusedNoteSendLeavesTheCardUnchanged() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1")]) }
        model.writeEdit = { _, _, id, text in .card(noteCard(id: id, text: text)) }
        model.writeSend = { _, _, _, _ in .refused("no claude process found in any pane of 'deck'") }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editNote(id: "n-1", text: "the note")
        await model.send(id: "n-1")
        guard case .note(let note) = model.slate?.cards.first else { return XCTFail("expected the note card") }
        XCTAssertEqual(note.state, .draft)
        XCTAssertEqual(model.sendErrors["n-1"], "no claude process found in any pane of 'deck'")
    }

    /// "A draft is deletable" — removed from the sheet, and its draft text
    /// with it, within the action.
    func testDeleteNoteRemovesTheCardAndItsDraftOnSuccess() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1", text: "scrap")]) }
        model.writeDeleteNote = { _, _, id in .deleted(id: id) }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        await model.deleteNote(id: "n-1")
        XCTAssertEqual(model.slate?.cards.count, 0)
        XCTAssertNil(model.noteDrafts["n-1"])
    }

    /// Matching the Bosun's own refusal shape (a sent note or an ask):
    /// deletion has no "state" to revert, so the card simply stays.
    func testARefusedDeleteLeavesTheCardOnTheSheet() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1", text: "scrap")]) }
        model.writeDeleteNote = { _, _, _ in .refused("n-1 is not a draft") }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        await model.deleteNote(id: "n-1")
        XCTAssertEqual(model.slate?.cards.count, 1)
        XCTAssertEqual(model.sendErrors["n-1"], "n-1 is not a draft")
    }

    /// Previously swallowed by `try?` for edits — `deleteNote` must surface
    /// a failed delivery the same way, rather than leaving the card looking
    /// untouched with no explanation.
    func testAFailedDeleteSurfacesUnderTheCard() async {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1")]) }
        model.writeDeleteNote = { _, _, _ in throw SessionAgent.AgentError.failed("unreachable") }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        await model.deleteNote(id: "n-1")
        XCTAssertEqual(model.slate?.cards.count, 1)
        XCTAssertEqual(model.sendErrors["n-1"], "unreachable")
    }

    /// Delete chains onto a genuinely in-flight edit the same way `send`
    /// does, rather than racing it — the per-card serial ordering the item's
    /// own body requires for "create, debounced edit, delete, flush-on-close
    /// and send" together.
    func testDeleteWaitsForAnInFlightEditRatherThanRacingIt() async {
        let model = SlateModel()
        let calls = LockedList<String>()
        let started = LockedList<String>()
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1")]) }
        model.writeEdit = { _, _, id, text in
            started.append(text)
            Thread.sleep(forTimeInterval: 0.6)
            calls.append("edit:\(text)")
            return .card(noteCard(id: id, text: text))
        }
        model.writeDeleteNote = { _, _, id in
            calls.append("delete:\(id)")
            return .deleted(id: id)
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editNote(id: "n-1", text: "A")
        await wait(upTo: 3) { started.values.contains("A") }
        await model.deleteNote(id: "n-1")
        XCTAssertEqual(calls.values, ["edit:A", "delete:n-1"],
                       "the delete must wait for the in-flight edit to land first")
    }

    /// Closing the sheet mid-debounce on a note must flush the same way it
    /// does for an ask's answer — `stop()`'s own chain is generic over which
    /// drafts dictionary an id belongs to.
    func testStopFlushesAPendingDebouncedNoteEditInsteadOfDroppingIt() async {
        let model = SlateModel()
        let calls = LockedList<String>()
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1")]) }
        model.writeEdit = { _, _, id, text in
            calls.append(text)
            return .card(noteCard(id: id, text: text))
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editNote(id: "n-1", text: "typed just before closing")
        model.stop()
        await wait { !calls.values.isEmpty }
        XCTAssertEqual(calls.values, ["typed just before closing"])
    }

    /// Moving the column from one crew's Slate to another's re-points this
    /// model without tearing it down, so `onDisappear` never runs. An edit
    /// still debouncing on the old crew must reach that crew at the re-point,
    /// not 400ms later through its debounce, and must not reach the new one.
    /// The timing bound is what separates the two: without the flush in
    /// `start`, the old crew's write still lands, but only after the debounce.
    /// The two crews sit on different hosts, so the write must carry the old
    /// crew's target as well as its session: a session name alone cannot say
    /// which host the edit belongs to.
    func testRepointingToAnotherCrewSendsAPendingEditToTheCrewItWasTypedFor() async {
        let model = SlateModel()
        let calls = LockedList<String>()
        let alphaTarget = SSHTarget(user: "operator", host: "macstudio")
        let betaTarget = SSHTarget(user: "operator", host: "macmini")
        model.fetchSlate = { _, session in Slate(session: session, cards: [askCard(id: "a-1")]) }
        model.writeEdit = { target, session, id, text in
            calls.append("\(session)@\(target.host)|\(text)")
            return .card(askCard(id: id, answerDraft: text))
        }
        model.start(session: "alpha", target: alphaTarget)
        await model.refresh()
        model.editAnswer(id: "a-1", text: "typed on alpha")
        model.start(session: "beta", target: betaTarget)
        await wait(upTo: 0.2) { !calls.values.isEmpty }
        XCTAssertEqual(calls.values, ["alpha@macstudio|typed on alpha"])
    }

    /// A close after the edit has already landed must not send it again. The
    /// finished write leaves `editTasks`, so the next `stop()` has nothing to
    /// flush. Fails against d5ba54e, where each `stop()` re-sent the edit.
    func testTwoStopsAfterAnEditLandedSendTheEditOnce() async {
        let model = SlateModel()
        let calls = LockedList<String>()
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1")]) }
        model.writeEdit = { _, _, id, text in
            calls.append(text)
            return .card(noteCard(id: id, text: text))
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.editNote(id: "n-1", text: "written once")
        // Stopping before the edit lands would find its link still registered
        // and re-send the text, which `stop()` does for a write not yet landed.
        await settle(model, "n-1")
        XCTAssertNil(model.editChain(for: "n-1"), "the landed edit leaves no link")
        model.stop()
        model.stop()
        await drainChain(model, "n-1")
        XCTAssertEqual(calls.values, ["written once"])
    }

    /// A debounced edit the host fails keeps its link in `editTasks`, so the
    /// close that follows sends its text again and the host ends with it. Fails
    /// against 8816d16, where the link was pruned whatever its outcome, so
    /// `stop()` had nothing to flush and the host kept the older text.
    func testAFailedEditIsSentAgainOnStop() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        // The first write to the host is the create that makes the note, so the
        // edit under test is the first call to `writeEdit`, and it fails.
        let edits = LockedList<String>()
        model.writeEdit = { _, _, id, text in
            edits.append(text)
            if edits.values.count == 1 { throw SessionAgent.AgentError.failed("watchdog") }
            return host.edit(id: id, text: text)
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "first")
        await wait { host.heldNotes.map(\.text) == ["first"] }
        model.editNote(id: key, text: "draft text")
        await wait { model.sendErrors[key] != nil }
        XCTAssertEqual(edits.values, ["draft text"])
        model.stop()
        await wait { host.heldNotes.map(\.text) == ["draft text"] }
        XCTAssertEqual(edits.values, ["draft text", "draft text"], "stop() sends the failed edit again")
        XCTAssertEqual(host.heldNotes.map(\.text), ["draft text"])
    }

    // MARK: - A poll racing a create or delete (round 1 finding)

    /// `createNote` appends a card locally, but each `session-agent` call is
    /// an independent ssh process, unordered against the 2s poll — a fetch
    /// whose read began before this create reached the server must not make
    /// the new note vanish when it lands, nor show it twice once a later
    /// fetch does know about it. Fails against bc6ae10, where `refresh`
    /// overwrote `slate = fetched` unconditionally.
    func testARefreshBegunBeforeACreateNeitherDropsNorDuplicatesIt() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.stop()

        // This fetch's own read began before the create below — it comes
        // back not yet knowing about the new note, the way a poll tick that
        // started first but lost the ssh race against the create would.
        model.fetchSlate = { _, session in
            started.signal()
            release.wait()
            return Slate(session: session, cards: [])
        }
        let refreshTask = Task { await model.refresh() }
        await Task.detached { blockOn(started) }.value

        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "first")
        model.stop()
        await wait { model.slate?.cards.map(\.id) == ["n-1"] }
        XCTAssertEqual(model.slate?.cards.map(\.id), ["n-1"], "the create must show at once")

        release.signal()
        await refreshTask.value
        XCTAssertEqual(model.slate?.cards.map(\.id), ["n-1"],
                       "a fetch that began before the create must not drop it")

        // The next poll, once the server has caught up, must not show the
        // note twice just because `fetched` now also carries it.
        model.fetchSlate = { _, session in host.fetch(session: session) }
        await model.refresh()
        XCTAssertEqual(model.slate?.cards.map(\.id), ["n-1"],
                       "once the fetch itself shows the note, it must not duplicate")
    }

    /// Same finding, the delete side: a fetch whose read began before this
    /// delete reached the server must not resurrect the card once the
    /// delete has already removed it locally. Fails against bc6ae10.
    func testARefreshBegunBeforeADeleteDoesNotResurrectTheCard() async {
        let model = SlateModel()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        model.fetchSlate = { _, session in Slate(session: session, cards: [noteCard(id: "n-1", text: "scrap")]) }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.stop()

        // This fetch's own read began before the delete below — it still
        // carries the card, the way a poll tick that started first but lost
        // the ssh race against `deleteNote` would.
        model.fetchSlate = { _, session in
            started.signal()
            release.wait()
            return Slate(session: session, cards: [noteCard(id: "n-1", text: "scrap")])
        }
        model.writeDeleteNote = { _, _, id in .deleted(id: id) }

        let refreshTask = Task { await model.refresh() }
        await Task.detached { blockOn(started) }.value
        await model.deleteNote(id: "n-1")
        XCTAssertEqual(model.slate?.cards.count, 0, "the delete must remove it at once")

        release.signal()
        await refreshTask.value
        XCTAssertEqual(model.slate?.cards.count, 0,
                       "a fetch that began before the delete must not resurrect the card")
    }

    // MARK: - A pending create expiring on confirmed absence (round 2 finding)

    /// A fetch that began AFTER `createNote`'s own write returned is
    /// guaranteed to reflect whatever happened on the server since — so if
    /// it still lacks the card, something other than Deck's own `deleteNote`
    /// removed it (a direct `slate-delete`, the co, another reader), and the
    /// card must disappear for good rather than being forced back on every
    /// poll. Fails against 32b2976, where `reconcile` only ever dropped a
    /// pending create on confirmed presence.
    func testAPendingCreateConfirmedAbsentByALaterFetchDisappearsForGood() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.stop()

        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        model.stop()
        await wait { model.slate?.cards.map(\.id) == ["n-1"] }
        XCTAssertEqual(model.slate?.cards.map(\.id), ["n-1"], "the create must show at once")

        // This fetch began after the create above already returned, and it
        // does not carry the card.
        model.fetchSlate = { _, session in Slate(session: session, cards: []) }
        await model.refresh()
        XCTAssertEqual(model.slate?.cards.count, 0,
                       "an absence confirmed after the create returned must not be forced back")
        XCTAssertTrue(model.localNoteIDs.isEmpty, "the draft's row goes with the note it made")

        // And it must stay gone — not a one-poll fluke.
        await model.refresh()
        XCTAssertEqual(model.slate?.cards.count, 0,
                       "a dropped pending create must stay gone on later polls too")
    }

    /// Delete is Deck's own way to clean up a card the operator no longer
    /// wants, including a ghost card a pending create left behind once
    /// something else removed it first — `slate-delete` then refuses
    /// because there is nothing left to delete. That refusal must still
    /// drop the pending create, or Deck's own cleanup attempt becomes the
    /// thing that keeps forcing the ghost back. Fails against 32b2976.
    func testARefusedDeleteOfAPendingCreateStopsForcingItBack() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.stop()

        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        model.stop()
        await wait { model.slate?.cards.map(\.id) == ["n-1"] }
        XCTAssertEqual(model.slate?.cards.map(\.id), ["n-1"])

        model.writeDeleteNote = { _, _, _ in .refused("n-1 does not exist") }
        await model.deleteNote(id: key)
        XCTAssertEqual(model.slate?.cards.map(\.id), ["n-1"],
                       "a refusal leaves the card exactly as it was, for this action")
        XCTAssertEqual(model.sendErrors[key], "n-1 does not exist")

        // But the pending create must no longer force the card back once a
        // fetch shows it gone.
        model.fetchSlate = { _, session in Slate(session: session, cards: []) }
        await model.refresh()
        XCTAssertEqual(model.slate?.cards.count, 0,
                       "a refused delete must drop the pending create so it stops resurrecting the card")
    }

    // MARK: - A create whose reply is lost (round 1 review)

    /// A create that throws after the host already recorded the note: the
    /// operator must not get a second copy from the next keystroke or Send.
    /// The next read finds the host's note and adopts it. Fails against the
    /// round-1 head, where a thrown create left `hostID` nil and every later
    /// write created again.
    func testACreateThatThrowsAfterTheHostRecordedItIsNeverRepeated() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.writeCreateNote = { _, _, text in
            _ = host.create(text: text)
            throw HostReplyLost()
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        await wait { model.sendErrors[key] != nil }
        XCTAssertEqual(host.calls, ["create:x"], "the positive control: the create did run and fail")

        model.editNote(id: key, text: "x more")
        await settle(model, key)
        await model.send(id: key)
        XCTAssertEqual(host.calls, ["create:x"], "a held draft must never be created again")

        await model.refresh()
        XCTAssertTrue(model.sheetCards.isEmpty, "the fetch adopts the host's note under the draft")
        XCTAssertNil(model.sendErrors[key])
        await wait { host.calls.contains("edit:n-1:x more") }
        XCTAssertEqual(host.calls, ["create:x", "edit:n-1:x more"],
                       "text typed while held is written to the adopted note, never created as a second one")
        XCTAssertEqual(host.heldNotes.map(\.text), ["x more"])
    }

    /// A create that throws before the host recorded anything: the next read
    /// shows no such note, so the draft waits for an explicit Retry, and a
    /// keystroke in the meantime does not create it. Retry creates it once.
    func testAnUnrecordedCreateWaitsForAnExplicitRetry() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        let attempts = LockedList<String>()
        model.writeCreateNote = { _, _, text in
            attempts.append(text)
            throw HostReplyLost()
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        await wait { model.sendErrors[key] != nil }
        XCTAssertEqual(attempts.values, ["x"])

        await model.refresh()
        XCTAssertTrue(model.canRetryCreate(id: key), "a read after the failure settles that the host has no note")

        model.editNote(id: key, text: "y")
        await settle(model, key)
        XCTAssertEqual(attempts.values, ["x"], "a keystroke must not create a held draft's note")

        model.writeCreateNote = { _, _, text in
            attempts.append(text)
            return host.create(text: text)
        }
        model.retryCreate(id: key)
        await wait { host.calls.contains("create:y") }
        XCTAssertEqual(attempts.values, ["x", "y"], "Retry creates from the draft's current text, once")
        XCTAssertFalse(model.canRetryCreate(id: key))
        XCTAssertNil(model.sendErrors[key])
    }

    /// A refused create is confirmed, not unknown: the host did not record the
    /// note, so the next keystroke creates it as before and nothing is held.
    func testARefusedCreateIsRetriedByTheNextKeystroke() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.writeCreateNote = { _, _, _ in .refused("the Slate is full") }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        await wait { model.sendErrors[key] == "the Slate is full" }
        XCTAssertFalse(model.canRetryCreate(id: key), "a refusal is confirmed, so nothing is held")

        model.writeCreateNote = { _, _, text in host.create(text: text) }
        model.editNote(id: key, text: "x2")
        await wait { model.slate?.cards.map(\.id) == ["n-1"] }
        XCTAssertEqual(host.calls, ["create:x2"], "the next keystroke creates the note once")
    }

    /// A create answered after a fetch already carries its note must not
    /// append the note a second time. The fetch lands while the create is
    /// still in flight, so the create's own write is what adopts the note.
    /// Fails against the round-1 head, where `adopt` always appended.
    func testAnAdoptedCreateNeverDuplicatesACardAFetchAlreadyCarries() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        model.writeCreateNote = { _, _, text in
            let outcome = host.create(text: text)
            started.signal()
            release.wait()
            return outcome
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        await Task.detached { blockOn(started) }.value

        await model.refresh()
        XCTAssertEqual(model.slate?.cards.map(\.id), ["n-1"], "the fetch carries the host's note")

        release.signal()
        // A later edit chains behind the create, so its host call proves the
        // create's own write, and the adoption inside it, has finished.
        model.editNote(id: key, text: "x y")
        await wait { host.calls.contains("edit:n-1:x y") }
        XCTAssertEqual(model.slate?.cards.map(\.id), ["n-1"],
                       "adopt must not append a card the fetch already carries")
    }

    /// The create's reply is lost and the host never recorded it, but the
    /// operator had typed an identical note on the host before Deck sent the
    /// create. The next read must not adopt that older note: the draft stays
    /// held for Retry, and nothing is written to the older note.
    /// Fails against 38a5234, where any text match was adopted.
    func testAPreExistingNoteWithTheSameTextIsNeverAdopted() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        _ = host.create(text: "x")
        model.writeCreateNote = { _, _, _ in throw HostReplyLost() }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        await wait { model.sendErrors[key] != nil }
        let before = host.calls

        await model.refresh()
        XCTAssertTrue(model.canRetryCreate(id: key),
                      "the only identical note predates the create, so the draft stays held for Retry")
        XCTAssertEqual(model.sheetCards.map(\.id), ["n-1"], "the older note stays on the sheet as its own card")

        model.editNote(id: key, text: "x2")
        await settle(model, key)
        XCTAssertEqual(host.calls, before, "nothing is written to the older note or created again")
    }

    /// The same as above, except the create did land as `n-2`. The draft
    /// adopts `n-2`, the note its own create made, and never the older `n-1`.
    /// Fails against 38a5234, which adopted the first match, `n-1`.
    func testTheCreatesOwnNoteIsAdoptedRatherThanAnOlderIdenticalOne() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        _ = host.create(text: "x")
        model.writeCreateNote = { _, _, text in
            _ = host.create(text: text)
            throw HostReplyLost()
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        await wait { model.sendErrors[key] != nil }

        await model.refresh()
        XCTAssertFalse(model.canRetryCreate(id: key), "exactly one new note matches, so the draft is settled")
        XCTAssertEqual(model.sheetCards.map(\.id), ["n-1"], "the create's note n-2 is drawn by its draft, not as a card")

        model.editNote(id: key, text: "x y")
        await wait { host.calls.contains("edit:n-2:x y") }
        XCTAssertEqual(host.calls, ["create:x", "create:x", "edit:n-2:x y"],
                       "later text is written to the create's own note")
    }

    /// The create's reply is lost after the host recorded its note, and the
    /// operator types the same text on the host before the next read. Both
    /// notes are new since the create was sent, so Deck cannot tell which one
    /// the create made. The draft must adopt neither and stay held for Retry.
    /// Fails against 38a5234, which adopted the first match.
    func testTwoNewNotesWithTheSameTextKeepTheDraftHeld() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.writeCreateNote = { _, _, text in
            _ = host.create(text: text)
            throw HostReplyLost()
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        await wait { model.sendErrors[key] != nil }
        _ = host.create(text: "x")
        let before = host.calls

        await model.refresh()
        XCTAssertTrue(model.canRetryCreate(id: key), "two new notes match, so the draft stays held for Retry")
        XCTAssertEqual(model.sheetCards.map(\.id), ["n-1", "n-2"], "neither match is adopted under the draft")

        model.editNote(id: key, text: "x2")
        await settle(model, key)
        XCTAssertEqual(host.calls, before, "nothing is written to either note while the draft is held")
    }

    /// New Note is pressed and text typed before the first read has landed,
    /// and the host already holds an identical note. The create has no read
    /// behind it yet, so it reads the Slate first and records that note as
    /// known. Its reply is lost and the host never recorded it, so the next
    /// read must not adopt the older note. Fails against 22db219, where the
    /// create went out with an empty known set and the read adopted the note.
    func testACreateBeforeTheFirstReadNeverAdoptsAPreExistingNote() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        _ = host.create(text: "x")
        let attempts = LockedList<String>()
        model.writeCreateNote = { _, _, text in
            attempts.append(text)
            throw HostReplyLost()
        }
        // Holds the poll's own first read, so no read has landed when the
        // operator presses New Note. Later reads are not held.
        let firstReadStarted = DispatchSemaphore(value: 0)
        let releaseFirstRead = DispatchSemaphore(value: 0)
        let reads = LockedList<Int>()
        model.fetchSlate = { _, session in
            if reads.values.isEmpty {
                reads.append(1)
                firstReadStarted.signal()
                releaseFirstRead.wait()
            }
            return host.fetch(session: session)
        }
        model.start(session: "deck", target: testTarget)
        await Task.detached { blockOn(firstReadStarted) }.value

        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        await wait { model.sendErrors[key] != nil }
        XCTAssertEqual(attempts.values, ["x"], "the positive control: the create was sent, and its reply was lost")

        releaseFirstRead.signal()
        await model.refresh()
        XCTAssertTrue(model.canRetryCreate(id: key),
                      "the only identical note predates the create, so the draft waits for Retry")
        XCTAssertEqual(model.sheetCards.map(\.id), ["n-1"], "the older note stays on the sheet as its own card")

        model.editNote(id: key, text: "x2")
        await settle(model, key)
        XCTAssertEqual(attempts.values, ["x"], "a held draft is not created again")
        XCTAssertEqual(host.calls, ["create:x"], "nothing is written to the older note")
    }

    /// New Note is pressed before any read has landed, and the read the create
    /// makes first fails. The create is not sent, the draft is held with its
    /// error, and Retry is the only way to create the note. Fails against
    /// 22db219, where the create was sent without a read.
    func testACreateWhoseFirstReadFailsIsNotSentUntilRetry() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        let attempts = LockedList<String>()
        model.writeCreateNote = { _, _, text in
            attempts.append(text)
            return host.create(text: text)
        }
        model.fetchSlate = { _, _ in nil }
        model.start(session: "deck", target: testTarget)
        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x")
        await wait { model.sendErrors[key] != nil }
        XCTAssertEqual(attempts.values, [], "no create is sent while the read before it has failed")
        XCTAssertTrue(model.canRetryCreate(id: key), "the draft is held with Retry offered")

        model.fetchSlate = { _, session in host.fetch(session: session) }
        model.retryCreate(id: key)
        await wait { host.calls.contains("create:x") }
        XCTAssertEqual(attempts.values, ["x"], "Retry creates the note once, after a read lands")
        XCTAssertFalse(model.canRetryCreate(id: key))
    }

    /// Two drafts with the same text. Draft A's create threw before the host
    /// recorded anything, so A is held. Draft B's create reached the host, and
    /// its reply is still in flight when a read sees B's note. B's reply can
    /// name that note, so A is not its sole claimant: A goes ambiguous and
    /// writes nothing to it. B adopts its own note once its reply lands.
    /// Fails against 3cc464b, where A adopted the note and B's reply rebound it.
    func testAHeldDraftNeverAdoptsANoteAnInFlightSiblingCanClaim() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        let attempts = LockedList<String>()
        let bRecorded = DispatchSemaphore(value: 0)
        let releaseB = DispatchSemaphore(value: 0)
        model.writeCreateNote = { _, _, text in
            attempts.append(text)
            if attempts.values.count == 1 { throw HostReplyLost() }
            let outcome = host.create(text: text)
            bRecorded.signal()
            releaseB.wait()
            return outcome
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()

        model.createNote()
        let keyA = model.localNoteIDs[0]
        model.editNote(id: keyA, text: "x")
        await wait { model.sendErrors[keyA] != nil }
        XCTAssertEqual(attempts.values, ["x"], "positive control: A's create threw before the host")

        model.createNote()
        let keyB = model.localNoteIDs[1]
        model.editNote(id: keyB, text: "x")
        await Task.detached { blockOn(bRecorded) }.value
        XCTAssertEqual(host.heldNotes.map(\.id), ["n-1"], "positive control: B's note is on the host, its reply still in flight")

        await model.refresh()
        XCTAssertTrue(model.canRetryCreate(id: keyA),
                      "B's in-flight create can claim the new note, so A is ambiguous and waits for Retry")
        model.editNote(id: keyA, text: "a")
        await settle(model, keyA)
        XCTAssertEqual(host.calls, ["create:x"], "nothing is written to B's note under A")

        releaseB.signal()
        model.editNote(id: keyB, text: "x y")
        await wait { host.calls.contains("edit:n-1:x y") }
        XCTAssertEqual(host.calls, ["create:x", "edit:n-1:x y"], "B's own note is the one it writes to")
        XCTAssertTrue(model.canRetryCreate(id: keyA), "A stays ambiguous after B adopts its note")
    }

    /// Two drafts with the same text, and both creates' replies are lost. The
    /// earlier draft's create fails before the host records anything; the
    /// later draft's create lands. Both are held and neither knows the host's
    /// note, so either could have made it. Neither adopts it: both go
    /// ambiguous, and the note is drawn as an ordinary card. Fails against
    /// 3cc464b, where the earlier draft adopted the note and the later one
    /// settled absent, so its Retry would have created a duplicate.
    func testTwoHeldDraftsWithTheSameTextNeverAdoptTheSameNote() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        let attempts = LockedList<String>()
        model.writeCreateNote = { _, _, text in
            attempts.append(text)
            // The earlier draft fails before the host. The later one lands, and its reply is lost.
            if attempts.values.count == 1 { throw HostReplyLost() }
            _ = host.create(text: text)
            throw HostReplyLost()
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()

        model.createNote()
        let keyEarlier = model.localNoteIDs[0]
        model.editNote(id: keyEarlier, text: "x")
        await wait { model.sendErrors[keyEarlier] != nil }

        model.createNote()
        let keyLater = model.localNoteIDs[1]
        model.editNote(id: keyLater, text: "x")
        await wait { model.sendErrors[keyLater] != nil }
        XCTAssertEqual(host.heldNotes.map(\.id), ["n-1"], "positive control: the later create landed, and its reply was lost")

        await model.refresh()
        XCTAssertTrue(model.canRetryCreate(id: keyEarlier),
                      "the note could be either draft's, so the earlier draft is ambiguous and waits for Retry")
        XCTAssertTrue(model.canRetryCreate(id: keyLater),
                      "the note could be either draft's, so the later draft is ambiguous and waits for Retry")
        XCTAssertEqual(model.sheetCards.map(\.id), ["n-1"], "no draft owns the note, so it is drawn as a card")

        model.editNote(id: keyEarlier, text: "x y")
        await settle(model, keyEarlier)
        XCTAssertEqual(host.calls, ["create:x"], "nothing is written to the note under either draft")
    }

    /// Two drafts with the same text. Draft A's create reached the host, and its
    /// reply was lost. Draft B's create failed before the host, so B is held and
    /// owns no note. The operator deletes A, which drops its row with no host
    /// call. A's create may still own the note, so the next read must not let B
    /// adopt it: B goes ambiguous and writes nothing to it. Fails against
    /// ac751ba, where a deleted draft stopped counting as a claimant.
    func testADeletedHeldDraftStillClaimsItsNoteAgainstASibling() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        let attempts = LockedList<String>()
        model.writeCreateNote = { _, _, text in
            attempts.append(text)
            if attempts.values.count == 1 {
                _ = host.create(text: text)
                throw HostReplyLost()
            }
            throw HostReplyLost()
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()

        model.createNote()
        let keyA = model.localNoteIDs[0]
        model.editNote(id: keyA, text: "x")
        await wait { model.sendErrors[keyA] != nil }
        XCTAssertEqual(host.heldNotes.map(\.id), ["n-1"], "positive control: A's create landed, and its reply was lost")

        model.createNote()
        let keyB = model.localNoteIDs[1]
        model.editNote(id: keyB, text: "x")
        await wait { model.sendErrors[keyB] != nil }
        XCTAssertEqual(attempts.values, ["x", "x"], "positive control: B's create was sent and never reached the host")

        await model.deleteNote(id: keyA)
        XCTAssertEqual(model.localNoteIDs, [keyB], "positive control: A's row is gone")

        await model.refresh()
        XCTAssertTrue(model.canRetryCreate(id: keyB),
                      "A's create may own the note, so B is ambiguous and waits for Retry")
        XCTAssertEqual(model.sheetCards.map(\.id), ["n-1"], "no draft adopted the note, so it is drawn as a card")

        model.editNote(id: keyB, text: "x y")
        await settle(model, keyB)
        XCTAssertEqual(host.calls, ["create:x"], "nothing is written to the note under B")
    }

    /// Three drafts with the same text. Draft A's create reached the host and
    /// its reply was lost. Draft B's create is in flight when a read sees A's
    /// note, so A goes ambiguous. B's own reply is then lost and the host never
    /// recorded it, so A still may own the note and B must not adopt it. Draft
    /// C's create then lands as its own note, which no held draft can claim.
    /// Fails against ac751ba, where an ambiguous draft stopped claiming its
    /// note and B adopted A's.
    func testAnAmbiguousDraftStillClaimsItsNoteAgainstASibling() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        let attempts = LockedList<String>()
        let bInFlight = DispatchSemaphore(value: 0)
        let releaseB = DispatchSemaphore(value: 0)
        model.writeCreateNote = { _, _, text in
            attempts.append(text)
            switch attempts.values.count {
            case 1:
                _ = host.create(text: text)
                throw HostReplyLost()
            case 2:
                bInFlight.signal()
                releaseB.wait()
                throw HostReplyLost()
            default:
                return host.create(text: text)
            }
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()

        model.createNote()
        let keyA = model.localNoteIDs[0]
        model.editNote(id: keyA, text: "x")
        await wait { model.sendErrors[keyA] != nil }
        XCTAssertEqual(host.heldNotes.map(\.id), ["n-1"], "positive control: A's create landed, and its reply was lost")

        model.createNote()
        let keyB = model.localNoteIDs[1]
        model.editNote(id: keyB, text: "x")
        await Task.detached { blockOn(bInFlight) }.value

        await model.refresh()
        XCTAssertTrue(model.canRetryCreate(id: keyA), "B's create is in flight and can claim A's note, so A is ambiguous")

        releaseB.signal()
        await wait { model.sendErrors[keyB] != nil }
        XCTAssertEqual(host.heldNotes.map(\.id), ["n-1"], "positive control: B's create never reached the host")

        await model.refresh()
        XCTAssertTrue(model.canRetryCreate(id: keyB),
                      "A's ambiguous create may own the note, so B is ambiguous too and waits for Retry")
        XCTAssertEqual(model.sheetCards.map(\.id), ["n-1"], "no draft adopted the note")

        model.createNote()
        let keyC = model.localNoteIDs[2]
        model.editNote(id: keyC, text: "x")
        await wait { model.slate?.cards.count == 2 }
        XCTAssertEqual(host.heldNotes.map(\.id), ["n-1", "n-2"], "positive control: C's own note is on the host")
        XCTAssertEqual(model.sheetCards.map(\.id), ["n-1"], "C's note is its own row, and n-1 is still no one's")

        model.editNote(id: keyB, text: "x y")
        await settle(model, keyB)
        XCTAssertEqual(host.calls, ["create:x", "create:x"], "nothing is written to n-1 under B")
    }

    /// A draft whose text ends in a newline has its create land, with the reply
    /// lost. The host stores the note trimmed, so the draft's claim must compare
    /// trimmed text to find its own note. Without that, the draft settles absent
    /// and only Retry is left, which would create a second note. Fails against
    /// beb1198, where the untrimmed claim text never matched the host's "x".
    func testADraftWithTrailingWhitespaceAdoptsItsOwnLostNote() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.writeCreateNote = { _, _, text in
            _ = host.create(text: text)
            throw HostReplyLost()
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()

        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x\n")
        await wait { model.sendErrors[key] != nil }
        XCTAssertEqual(host.heldNotes.map(\.text), ["x"], "positive control: the host stored the note trimmed, and its reply was lost")

        await model.refresh()
        XCTAssertFalse(model.canRetryCreate(id: key), "the note is the draft's only candidate, so the draft adopts it")
        XCTAssertEqual(model.sheetCards.map(\.id), [], "the adopted note is drawn through the draft's row")

        model.editNote(id: key, text: "x y")
        await wait { host.calls.contains("edit:n-1:x y") }
        XCTAssertTrue(host.calls.contains("edit:n-1:x y"), "the draft writes to its own note")
        XCTAssertEqual(host.heldNotes.map(\.id), ["n-1"], "no second note was created")
    }

    /// Two drafts with the same text, one ending in a newline. A's create lands
    /// as the host's trimmed "x", and both replies are lost. Both claims match
    /// that note once each side is trimmed, so neither draft adopts it: both go
    /// ambiguous and write nothing to it. Fails against beb1198, where A's
    /// untrimmed claim missed the note and B adopted it.
    func testASiblingWithTheSameTrimmedTextNeverAdoptsADraftsLostNote() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        let attempts = LockedList<String>()
        model.writeCreateNote = { _, _, text in
            attempts.append(text)
            // A's create lands. B's create fails before the host records anything.
            if attempts.values.count == 1 { _ = host.create(text: text) }
            throw HostReplyLost()
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()

        model.createNote()
        let keyA = model.localNoteIDs[0]
        model.editNote(id: keyA, text: "x\n")
        await wait { model.sendErrors[keyA] != nil }
        XCTAssertEqual(host.heldNotes.map(\.id), ["n-1"], "positive control: A's create landed, and its reply was lost")

        model.createNote()
        let keyB = model.localNoteIDs[1]
        model.editNote(id: keyB, text: "x")
        await wait { model.sendErrors[keyB] != nil }
        XCTAssertEqual(attempts.values, ["x\n", "x"], "positive control: B's create was sent and never reached the host")

        await model.refresh()
        XCTAssertTrue(model.canRetryCreate(id: keyA), "B's trimmed claim matches A's note too, so A is ambiguous")
        XCTAssertTrue(model.canRetryCreate(id: keyB), "A's claim matches the note too, so B is ambiguous")
        XCTAssertEqual(model.sheetCards.map(\.id), ["n-1"], "no draft adopted the note, so it is drawn as a card")

        model.editNote(id: keyB, text: "x y")
        await settle(model, keyB)
        XCTAssertEqual(host.calls, ["create:x\n"], "nothing is written to n-1 under either draft")
    }

    /// Draft A's create lands as n-1 and its reply is lost. The operator deletes
    /// A before any read, and the first read after A's failure shows n-1 as a
    /// card. Draft B then sends the same text. Its read already holds n-1, its
    /// create lands as n-2, and its reply is lost. A's claim is unbounded, so it
    /// still covers n-2 as well as n-1. B therefore goes ambiguous and writes
    /// nothing to n-2. Fails against 50956aa, where A's claim had sealed to n-1,
    /// so B adopted n-2.
    func testADeletedDraftsClaimKeepsALaterSameTextDraftAmbiguous() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.writeCreateNote = { _, _, text in
            _ = host.create(text: text)
            throw HostReplyLost()
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()

        model.createNote()
        let keyA = model.localNoteIDs[0]
        model.editNote(id: keyA, text: "x")
        await wait { model.sendErrors[keyA] != nil }
        await model.deleteNote(id: keyA)
        XCTAssertEqual(model.localNoteIDs, [], "positive control: A's row is gone")

        await model.refresh()
        XCTAssertEqual(model.sheetCards.map(\.id), ["n-1"], "positive control: the first read after A's failure shows n-1 as a card")

        model.createNote()
        let keyB = model.localNoteIDs[0]
        model.editNote(id: keyB, text: "x")
        await wait { model.sendErrors[keyB] != nil }
        XCTAssertEqual(host.heldNotes.map(\.id), ["n-1", "n-2"], "positive control: B's create landed as n-2, and its reply was lost")

        await model.refresh()
        XCTAssertTrue(model.canRetryCreate(id: keyB),
                      "A's claim covers n-2 too, so B is ambiguous and waits for Retry")
        XCTAssertEqual(model.sheetCards.map(\.id), ["n-1", "n-2"], "no draft adopted either note")

        model.editNote(id: keyB, text: "x y")
        await settle(model, keyB)
        XCTAssertEqual(host.calls, ["create:x", "create:x"], "nothing is written to n-2 under B")
    }

    /// A host note whose text ends in U+001F. Python's `str.strip()` removes that
    /// character, so the host stores "x". The draft's claim must trim the same
    /// way to find its own note. Without U+001F in `hostText`, the draft settles
    /// absent and only Retry is left. Fails against 50956aa, where the draft
    /// held the untrimmed text and settled absent.
    func testADraftEndingInUnitSeparatorAdoptsItsOwnLostNote() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        model.writeCreateNote = { _, _, text in
            _ = host.create(text: text)
            throw HostReplyLost()
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()

        model.createNote()
        let key = model.localNoteIDs[0]
        model.editNote(id: key, text: "x\u{1F}")
        await wait { model.sendErrors[key] != nil }
        XCTAssertEqual(host.heldNotes.map(\.text), ["x"], "positive control: the host stripped U+001F, and its reply was lost")

        await model.refresh()
        XCTAssertFalse(model.canRetryCreate(id: key), "the note is the draft's only candidate, so the draft adopts it")
        XCTAssertEqual(model.sheetCards.map(\.id), [], "the adopted note is drawn through the draft's row")

        model.editNote(id: key, text: "x y")
        await wait { host.calls.contains("edit:n-1:x y") }
        XCTAssertTrue(host.calls.contains("edit:n-1:x y"), "the draft writes to its own note")
        XCTAssertEqual(host.heldNotes.map(\.id), ["n-1"], "no second note was created")
    }

    /// The security review's late-write trace. Draft B's create fails with its
    /// host write still in flight, and the first read that began after the
    /// failure does not show the note. The write lands after that read, and then
    /// draft A's create fails without reaching the host. A later read shows the
    /// note, so A is its only candidate unless B's claim still covers it. A
    /// host write can land after any read, so no read may end B's claim. Fails
    /// against 50956aa, where A adopted the note.
    func testALateHostWriteNeverLetsASiblingAdoptTheDraftsNote() async {
        let host = FakeSlateHost()
        let model = SlateModel()
        wire(model, to: host)
        let attempts = LockedList<String>()
        model.writeCreateNote = { _, _, text in
            attempts.append(text)
            throw HostReplyLost()
        }
        model.start(session: "deck", target: testTarget)
        await model.refresh()

        model.createNote()
        let keyB = model.localNoteIDs[0]
        model.editNote(id: keyB, text: "x")
        await wait { model.sendErrors[keyB] != nil }
        await model.refresh()
        XCTAssertEqual(host.heldNotes.map(\.id), [], "positive control: B's create never reached the host before the read")

        _ = host.create(text: "x")
        XCTAssertEqual(host.heldNotes.map(\.id), ["n-1"], "positive control: B's write landed after the read")

        model.createNote()
        let keyA = model.localNoteIDs[1]
        model.editNote(id: keyA, text: "x")
        await wait { model.sendErrors[keyA] != nil }
        XCTAssertEqual(attempts.values, ["x", "x"], "positive control: A's create was sent and failed without a host write")

        await model.refresh()
        XCTAssertEqual(model.slate?.cards.compactMap(\.id), ["n-1"], "positive control: the read carries the late note")
        XCTAssertTrue(model.canRetryCreate(id: keyA),
                      "B's create may have made n-1, so A is ambiguous and waits for Retry")

        model.editNote(id: keyA, text: "x y")
        await settle(model, keyA)
        XCTAssertEqual(host.calls, ["create:x"], "nothing is written to n-1 under A")
    }
}

/// The error a create throws when its reply never comes back, as an ssh
/// timeout does.
private struct HostReplyLost: Error {}
