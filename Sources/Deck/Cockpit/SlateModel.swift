import Combine
import Foundation

/// A send in flight, keyed by the crew it was sent for and the card it sends. The
/// crew is part of the key, so crew B never sees a send that belongs to crew A.
struct InFlightSend: Hashable {
    let session: String
    let target: SSHTarget
    let key: String
}

/// The sends in flight across every Slate sheet the app has shown. A send
/// outlives the sheet that started it: closing the sheet drops its model, but the
/// send's task still runs and still holds its card. Reopening the crew builds a
/// new model, which reads this registry rather than an empty set of its own, so
/// Send, edit and Delete stay refused for that card until the send settles.
///
/// `shared` lives for the process, so a send also outlives the window: closing
/// the window discards `ContentView`'s state, and a reopened window must still
/// see the send. Each send removes its own entry when it ends, whichever model
/// is current then.
@MainActor
final class SlateSendRegistry: ObservableObject {
    static let shared = SlateSendRegistry()

    @Published private var inFlight: Set<InFlightSend> = []
    /// The host id a draft's send is delivering to, once its create returns. A
    /// draft's send is keyed by the draft's local key, which a rebuilt model has
    /// never seen: it lists the note under its host id. The send answers to both.
    @Published private var hostIDs: [InFlightSend: String] = [:]

    func begin(_ send: InFlightSend) { inFlight.insert(send) }
    func end(_ send: InFlightSend) {
        inFlight.remove(send)
        hostIDs[send] = nil
    }
    /// Records the host id the draft behind `send` now has.
    func adopt(_ send: InFlightSend, hostID: String) {
        guard inFlight.contains(send) else { return }
        hostIDs[send] = hostID
    }

    /// The card keys with a send in flight on crew `session` at `target`,
    /// including the host id of each draft whose note the host has created.
    func keys(session: String?, target: SSHTarget?) -> Set<String> {
        guard let session, let target else { return [] }
        let mine = inFlight.filter { $0.session == session && $0.target == target }
        return Set(mine.map(\.key)).union(mine.compactMap { hostIDs[$0] })
    }
}

/// Drives one crew's Slate sheet: polls `session-agent slate`, holds the
/// operator's in-progress answers, and writes them back through
/// `slate-edit`/`slate-send`. One instance per open `SlatePane`.
///
/// EVERY REMOTE CALL IS OFF THE MAIN ACTOR, the same split `SessionPaneModel`
/// and `CockpitModel` make, so an ssh round trip never freezes the sheet.
@MainActor
final class SlateModel: ObservableObject {
    @Published private(set) var slate: Slate?
    /// Why the last read did not land, in the mini's own words, or `nil`
    /// while the last read succeeded (or none has run yet). This is the
    /// sheet's "state unknown" — set on a transport failure, a host whose
    /// `session-agent` predates the verb, or an envelope `Slate.decode`
    /// could not read at all.
    @Published private(set) var readError: String?

    /// The operator's editable text for each open ask, keyed by id — seeded
    /// once from the server's own `answer_draft` and never overwritten by a
    /// later poll. See `seedDrafts`'s doc.
    @Published private(set) var answerDrafts: [String: String] = [:]
    /// The operator's editable text for each draft note, keyed by the note's
    /// key on the sheet — same "seeded once" discipline as `answerDrafts`.
    /// A local draft's key is its `localKey`; a note the host holds is keyed
    /// by its host id.
    @Published private(set) var noteDrafts: [String: String] = [:]
    /// The draft notes New Note opened that still have a row on the sheet, in
    /// the order they were opened. A draft stays here after the host creates
    /// its note, so its row keeps its place and its editor until the note is
    /// sent, deleted, or confirmed gone — see `retireDraft`.
    @Published private(set) var localNoteIDs: [String] = []
    /// The host id of each draft's note, keyed by the draft's local key, once
    /// the host has created that note. The draft's row draws this id above its
    /// editor, so the operator sees the handle without reopening the sheet. Set
    /// by `adopt`, which every create path reaches, and by `keepSentNote` for a
    /// host note kept after its send; cleared by `start`.
    @Published private(set) var draftHostIDs: [String: String] = [:]
    /// Which asks or notes have a send in flight on the crew now on the sheet, so
    /// Send disables for exactly that card rather than the whole sheet. Read from the
    /// shared registry, so a send started on an earlier sheet for this crew still counts,
    /// and a send for another crew never disables this crew's cards.
    var sendingIDs: Set<String> {
        sends.keys(session: session, target: target)
    }
    /// The registry every sheet for the window shares. See `SlateSendRegistry`.
    private let sends: SlateSendRegistry
    /// Forwards the registry's changes, so a send that starts or ends on another
    /// sheet redraws this one.
    private var sendsObservation: AnyCancellable?
    /// Which notes have a delete in flight, so Delete disables for exactly
    /// that card rather than the whole sheet.
    @Published private(set) var deletingIDs: Set<String> = []
    /// Why the last send, edit, create or delete for a card did not land, kept
    /// under the card's key so the card can show it; cleared at the start of
    /// the next attempt for that key.
    @Published private(set) var sendErrors: [String: String] = [:]
    /// Why a sent answer went out unsigned, shown on its card. The answer was
    /// delivered, so this is a notice, not an error: this Mac has no signing key
    /// while the host verifies answers. Set only when a send delivers, so a send
    /// that fails leaves it unset. Cleared at the start of the next send for the
    /// same key, and when a kept row is retired.
    @Published private(set) var sendNotices: [String: String] = [:]

    private var session: String?
    private var target: SSHTarget?
    private var pollTask: Task<Void, Never>?

    /// `sends` is the registry the window's sheets share. A model built without one,
    /// as the tests do, gets a registry of its own.
    init(sends: SlateSendRegistry = SlateSendRegistry()) {
        self.sends = sends
        sendsObservation = sends.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    /// The write chain's own tail for each card key. A new write for a key
    /// always awaits whichever write is already pending or in flight for that
    /// same key before sending — see `editAnswer` — so two writes for one card
    /// can never land on the server out of order, no matter which one's
    /// network round trip happens to finish first. Raised in review, the same
    /// class of bug `SessionPaneModel.renderGeneration` closes for renders.
    ///
    /// EVERY LINK MUST AWAIT ITS PREDECESSOR UNCONDITIONALLY, even a link
    /// that ends up not writing because its own debounce was cancelled —
    /// otherwise a coalesced link breaks the chain for whoever reads it
    /// next, and the wait on a genuinely in-flight older write stops
    /// propagating past it. `send` installs its own edit+send as this tail
    /// too, not only `editAnswer`'s debounce, so an edit typed while a send
    /// is outstanding still waits on it. Raised in round 2 review.
    ///
    /// A draft's create is a link like any other, so a Send or Delete pressed
    /// while that create is in flight waits on it and then writes to the host
    /// id it returned, never a second create.
    ///
    /// A link leaves this map once its write lands on the host, unless a later
    /// link has replaced it (see `finishEdit`). A link whose write failed stays,
    /// so a later `stop()` sends its text again. A landed write is never sent
    /// again by a later `stop()`.
    private var editTasks: [String: EditLink] = [:]
    /// The newest link in `id`'s write chain, or nil once no link is registered.
    /// A link whose write failed stays registered. Tests wait on the returned
    /// task so a debounced edit, and any flush queued behind it, has finished.
    func editChain(for id: String) -> Task<Void, Never>? {
        editTasks[draftKey(for: id)]?.task
    }
    /// The serial the newest link was installed under. See `EditLink.serial`.
    private var editSerial = 0
    /// Which ask or note keys have already been seeded into `answerDrafts` or
    /// `noteDrafts` — see `seedDrafts`.
    private var seededIDs: Set<String> = []

    /// A draft note New Note opened, and the host id of its note once the host
    /// has created it. Every draft keeps its entry for the life of the model,
    /// since a link queued behind a create still needs to know it is a draft.
    ///
    /// `@MainActor` so the chain's links can read `hostID` after their
    /// predecessor lands without a second copy of it to keep in step.
    @MainActor
    private final class DraftNote {
        let localKey: String
        /// `nil` until the host creates the note from this draft's first
        /// non-empty text. Until then the draft is never written under
        /// `localKey`, which the host has never heard of.
        var hostID: String?
        /// Set while the draft's create cannot be confirmed, or once a read has
        /// settled that the host did not record it. While set, nothing is sent
        /// for this draft; see `Hold`.
        var hold: Hold?
        /// The text of this draft's create while the host has been sent it and
        /// its reply has not come back, otherwise `nil`. `persist` sets it just
        /// before the host call and clears it as the reply lands. A held draft
        /// cannot tell a note this create may still claim from its own, so
        /// `resolveHeldDrafts` counts it as a claimant.
        var creating: String?
        /// The creates whose outcome is unknown and whose note no adoption has
        /// taken. The draft keeps them when its row is deleted or closed, when it
        /// is retried, and when a fetch settles it absent, so a note one of them
        /// may have made stays claimed. Only adoption releases them; see
        /// `resolveHeldDrafts`.
        var claims: [Claim] = []

        init(localKey: String) { self.localKey = localKey }
    }

    /// A create whose reply never came back, and which may have made a host
    /// note with `text`. `knownIDs` holds the host note ids its read saw, so a
    /// note with that text and an id outside the set is one the create could
    /// have made. The claim covers every such note until adoption releases it.
    /// A host write can land after any read, so no read ends the claim.
    private struct Claim {
        let text: String
        let knownIDs: Set<String>

        /// Compares text through `hostText`, since the host trims a created
        /// note's text and the draft's own text is untrimmed.
        func covers(_ note: SlateCard.Note) -> Bool {
            SlateModel.hostText(note.text) == SlateModel.hostText(text) && !knownIDs.contains(note.id)
        }
    }

    /// The text the host stores for a note. The host trims a note's text when it
    /// creates the note (`platform/contracts/session-agent-api`, the Note table's
    /// `text` row), and `agent-platform`'s `slate.py` does the trimming with
    /// Python's `str.strip()`. That removes the characters `str.isspace` accepts,
    /// which is Foundation's `whitespacesAndNewlines` plus U+001C to U+001F, less
    /// U+200B, which Foundation includes and Python does not. Every match between
    /// a draft and a host note compares through this trim, and so does every
    /// check that a text is empty, since the host refuses a text this trim empties.
    nonisolated static func hostText(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .subtracting(CharacterSet(charactersIn: "\u{200B}"))
            .union(CharacterSet(charactersIn: "\u{1C}\u{1D}\u{1E}\u{1F}")))
    }

    /// Why a draft holds its writes. A create whose reply never came back may
    /// still have landed on the host, so sending it again could put a second
    /// copy of the note on the Slate. The draft waits for a read to say
    /// whether the note exists, and for an explicit Retry if it does not.
    private enum Hold: Equatable {
        /// The create's outcome is unknown, and its claim is in
        /// `DraftNote.claims`. `afterGeneration` is `fetchGeneration` when the
        /// create failed. `resolveHeldDrafts` adopts a note this draft's claim
        /// covers only when no other draft could have made it too.
        case unconfirmed(afterGeneration: Int)
        /// A fetch that began after the failure found no host note this draft
        /// could have made. Only Retry creates the note now. Its claims stay,
        /// since a host write can still land after that fetch.
        case absent
        /// A fetch found more than one note this draft could have made, or a
        /// note another claim could also have made, so Deck cannot tell which
        /// one this draft's create made. Only Retry creates a note now, and it
        /// adds one more. The claims stay, since the notes they cover remain
        /// unowned.
        case ambiguous
        /// The create was never sent, because the read that had to come first
        /// did not land. The host has not seen the note. Only Retry creates it.
        case unread
    }

    /// One write a chain link made. `.nothing` is a draft with no non-empty
    /// text yet, which the host must never be sent. `.held` is a draft whose
    /// create is unconfirmed, so nothing was sent at all. `.unread` is a create
    /// Deck did not send because the read it makes first failed.
    private enum DraftWrite {
        case nothing
        case held
        case created(Result<SlateCard.Note, Error>)
        /// A create whose outcome is unknown: it threw, or answered without a
        /// readable note. The host may have recorded it.
        case unconfirmed(text: String, knownIDs: Set<String>)
        case unread
        case edited(Result<SessionAgent.SlateWriteOutcome, Error>)
    }

    /// A card `createNote`'s draft landed as, held until a fetch agrees —
    /// either by carrying the card (confirmed created) or, once a fetch
    /// that began after the create's own write returned still lacks it,
    /// by confirming its absence instead: the card was removed by something
    /// else (a direct `slate-delete`, the co, another reader) before Deck's
    /// own `deleteNote` ever ran. `confirmedAfterGeneration` is
    /// `fetchGeneration`'s value at the moment the create returned, so
    /// `reconcile` can tell a fetch that simply has not reached the server
    /// yet apart from one guaranteed to reflect whatever happened after —
    /// without it, an entry dropped only on confirmed presence is never
    /// dropped at all once the card is gone for good, and resurrects on
    /// every poll forever. Raised in round 2 review.
    private struct PendingCreate {
        let card: SlateCard
        let confirmedAfterGeneration: Int
    }

    /// Cards a draft's create landed as, keyed by host id, and host ids
    /// `deleteNote` removed locally — both until a fetch confirms the server
    /// agrees. A poll's own ssh call is an independent process, unordered
    /// against a create's or delete's own call, so a `fetched` slate whose
    /// read began before the local mutation reached the server can still omit
    /// the new card, or still carry the one just deleted. `reconcile`
    /// re-applies each pending entry on top of every `fetched` slate until
    /// `fetched` itself agrees, so a create racing a poll tick can never show
    /// twice and a delete racing one can never resurrect the card, whichever
    /// of the two ssh round trips happens to land first. Raised in round 1
    /// review.
    private var pendingCreates: [String: PendingCreate] = [:]
    private var pendingDeletes: Set<String> = []
    /// Maps a host id a draft's create returned to that draft's `localKey`.
    /// The sheet draws that host note through the draft's row, so it is
    /// hidden from the card list (see `sheetCards`) and every write for it
    /// goes through the draft. A host note kept after a send with a notice
    /// maps to its own id, so it is hidden from the list the same way.
    private var draftKeyByHostID: [String: String] = [:]
    /// The draft behind each local key, including every draft already
    /// created on the host. See `DraftNote`.
    private var draftNotes: [String: DraftNote] = [:]
    /// Bumped at the start of every fetch, before its ssh call is even
    /// dispatched — `reconcile`'s own clock for telling a fetch that began
    /// before a given write returned apart from one that began after. Never
    /// read for freshness the way `SessionPaneModel.renderGeneration` is;
    /// only ever compared against a `PendingCreate`'s own stamp.
    private var fetchGeneration = 0
    /// Bumped by `start` on every crew switch. A send carries the value it began
    /// under, and `finishSend` drops its outcome when the value has moved on. The
    /// crew name alone cannot do this: a column that goes A, B, then A again
    /// returns to the same name, and a send from the first A would land on the second.
    private var crewGeneration = 0

    /// The cockpit's existing cadence — see `SessionPaneModel.pollInterval`'s
    /// doc for why this reuses that value rather than a second literal.
    static let refreshInterval = SessionPaneModel.pollInterval
    /// How long `editAnswer` waits after the last keystroke before writing
    /// `slate-edit` — short enough that quitting Deck mid-sentence rarely
    /// loses anything, long enough that a fast typist does not open one ssh
    /// round trip per character.
    static let editDebounce = Duration.milliseconds(400)

    /// The read `refresh` makes, stored for the reason `CockpitModel`'s
    /// fetch closures are: a test substitutes a fake and never reaches ssh.
    var fetchSlate: @Sendable (SSHTarget, String) throws -> Slate? = { target, session in
        try SessionAgent.slate(target: target, session: session)
    }
    /// The write `editAnswer`'s debounce and `send`'s flush both make.
    var writeEdit: @Sendable (SSHTarget, String, String, String) throws -> SessionAgent.SlateWriteOutcome = {
        target, session, id, text in
        try SessionAgent.slateEdit(target: target, session: session, id: id, text: text)
    }
    /// The write `send` makes. `sig` is the `--sig` value, or `nil` for an unsigned send.
    var writeSend: @Sendable (SSHTarget, String, String, String?) throws -> SessionAgent.SlateWriteOutcome = {
        target, session, id, sig in
        try SessionAgent.slateSend(target: target, session: session, id: id, sig: sig)
    }
    /// The Secure Enclave key an answer is signed with, or `nil` on a Mac that has
    /// none. Loading reads a file and never prompts. Signing is the call that
    /// raises Touch ID.
    var loadSigningKey: @Sendable () throws -> SigningKey? = {
        try SigningKeyStore(fileURL: SigningKeyStore.defaultFileURL(),
                            factory: SecureEnclaveSigningKeyFactory()).load()
    }
    /// The clock a signed answer's `ts` is read from.
    var clock: @Sendable () -> Date = { Date() }
    /// The write that creates a draft's note on the host, from its first
    /// non-empty text. The host refuses empty text, so this is never called
    /// with one.
    var writeCreateNote: @Sendable (SSHTarget, String, String) throws -> SessionAgent.SlateWriteOutcome = {
        target, session, text in
        try SessionAgent.slateNote(target: target, session: session, text: text)
    }
    /// The write `deleteNote` makes.
    var writeDeleteNote: @Sendable (SSHTarget, String, String) throws -> SessionAgent.SlateDeleteOutcome = {
        target, session, id in
        try SessionAgent.slateDelete(target: target, session: session, id: id)
    }

    /// Points the model at a crew and starts polling. A no-op when already
    /// pointed at the same (session, host) pair, so `SlatePane`'s `.task(id:)`
    /// firing again on an unrelated view update does not restart the poll
    /// and lose `answerDrafts`.
    ///
    /// Re-pointing at a different pair first runs `stop()` on the old one, so
    /// its pending edits reach the old crew the same way closing the sheet
    /// sends them. The column can swap one crew's Slate for another's without
    /// tearing this model down, so `onDisappear` never runs for it, and this
    /// is the only flush that path gets.
    func start(session: String, target: SSHTarget) {
        guard self.session != session || self.target != target else { return }
        stop()
        self.session = session
        self.target = target
        crewGeneration += 1
        slate = nil
        readError = nil
        answerDrafts = [:]
        noteDrafts = [:]
        localNoteIDs = []
        draftHostIDs = [:]
        seededIDs = []
        sendErrors = [:]
        sendNotices = [:]
        deletingIDs = []
        pendingCreates = [:]
        pendingDeletes = []
        draftKeyByHostID = [:]
        draftNotes = [:]
        fetchGeneration = 0
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: SlateModel.refreshInterval)
            }
        }
    }

    /// Stops polling, drops any draft closed while still empty, and flushes
    /// every pending debounced write. Called when the sheet closes — the X
    /// button, or the column switching to a different occupant.
    ///
    /// FLUSHED, NOT CANCELLED: closing the sheet within the 400ms debounce
    /// window is an ordinary "keep this draft for later" moment, not
    /// abandoning the edit, and the epic's own "nothing is lost" guarantee
    /// for quitting Deck mid-sentence has to hold for closing one sheet too.
    /// Raised in review.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        discardEmptyDrafts()
        flushPendingEdits()
    }

    /// Sends every pending debounced edit immediately rather than losing it.
    /// Each flush is chained onto whatever write for that key is already
    /// pending or in flight, same as `editAnswer`'s own chain, so it can
    /// never overtake it. The write itself runs through `persist`, which
    /// never touches `self`, so it still lands even though this model may be
    /// deallocated the instant the sheet's view disappears.
    ///
    /// Each flush stays as its key's chain tail until it finishes: a Send or
    /// Delete pressed after the sheet reopens must still wait behind a create
    /// that is in flight, or it would create the note a second time. A flush
    /// task checks no cancellation, so `deinit` cancelling it changes nothing.
    ///
    /// A key whose send is in flight is flushed behind that send. The flush saves
    /// only when the send did not deliver and its own save did not land. A delivered
    /// send carries its text to the host whatever its save did, so a save after
    /// delivery would edit a note the host already holds. An undelivered send whose
    /// save failed holds text the host may never have received, and nothing else
    /// would save it once the sheet is gone.
    private func flushPendingEdits() {
        guard let session, let target else { editTasks = [:]; return }
        for key in Array(editTasks.keys) {
            guard let text = draftText(id: key) else { continue }
            let draft = draftNotes[key]
            let previous = editTasks[key]?.task
            let save = editTasks[key]?.save
            // Inert for an in-flight send: nothing in the send path checks cancellation.
            previous?.cancel()
            let read = fetchSlate
            let edit = writeEdit
            let create = writeCreateNote
            installLink(key, save: save) { [weak self] in
                _ = await previous?.value
                if save?.landed == true { return true }
                let hostID = draft == nil ? key : draft?.hostID
                let write = await SlateModel.persist(
                    text: text, hostID: hostID, draft: draft, target: target, session: session,
                    knownIDs: self?.knownNoteIDs, read: read, edit: edit, create: create)
                SlateModel.stamp(write, on: draft)
                let landed = SlateModel.landed(write)
                save?.landed = landed
                self?.recordWrite(write, key: key, draft: draft, session: session, target: target)
                return landed
            }
        }
    }

    /// One link of a key's write chain, held in `editTasks` while it is pending,
    /// in flight, or finished without its write landing.
    private struct EditLink {
        let task: Task<Void, Never>
        /// Distinguishes this link from any link installed later for the same
        /// key, so `finishEdit` removes only the link that finished.
        let serial: Int
        /// The save a send's link carries, and the flush chained behind it carries
        /// on. Nil for a debounced edit or a create.
        let save: SaveLanding?
    }

    /// Whether the text a send carries has reached the host, or the send has
    /// delivered it. The send sets it when its own save lands or when the host
    /// confirms the send, and a flush chained behind the send reads it. A flush
    /// that saves sets it too, so a later flush does not save the same text again.
    /// A class so the links share one value without touching the model. It is
    /// main-actor isolated like the links that write it, so `EditLink` stays
    /// Sendable for `deinit`.
    @MainActor
    private final class SaveLanding {
        var landed = false
    }

    /// Makes `work` the chain tail for `key`, replacing the previous tail. The
    /// caller reads that tail (`editTasks[key]?.task`) and cancels it before
    /// calling, since installing replaces it. `work` returns whether its write
    /// landed on the host; when it returns, `finishEdit` removes this link only
    /// in that case, and only if a later link has not replaced it.
    @discardableResult
    private func installLink(_ key: String, save: SaveLanding? = nil,
                             _ work: @escaping @MainActor () async -> Bool) -> Task<Void, Never> {
        editSerial += 1
        let serial = editSerial
        let task = Task { [weak self] in
            let landed = await work()
            self?.finishEdit(key, serial: serial, landed: landed)
        }
        editTasks[key] = EditLink(task: task, serial: serial, save: save)
        return task
    }

    /// Removes `key`'s entry once the link installed under `serial` has finished
    /// with its write landed. A failed link keeps its entry, so `stop()` flushes
    /// its text again. A link that finished after a later link replaced it leaves
    /// that later link's entry alone.
    private func finishEdit(_ key: String, serial: Int, landed: Bool) {
        guard landed, editTasks[key]?.serial == serial else { return }
        editTasks[key] = nil
    }

    /// Whether a write reached the host and was confirmed. Only such a write
    /// prunes its link from `editTasks`.
    private static func landed(_ write: DraftWrite) -> Bool {
        switch write {
        case .created(.success), .edited(.success(.card)): return true
        default: return false
        }
    }

    deinit {
        pollTask?.cancel()
        for link in editTasks.values { link.task.cancel() }
    }

    /// One read, exposed directly (not only through the poll loop) so a test
    /// can exercise it without waiting on `refreshInterval` — the same split
    /// `CockpitModel.fetch` is kept separate from its own timer for.
    func refresh() async {
        guard let session, let target else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        let read = fetchSlate
        do {
            let fetched = try await Task.detached { try read(target, session) }.value
            guard self.session == session, self.target == target else { return }
            guard let fetched else {
                readError = "This crew's Slate could not be read."
                return
            }
            let merged = reconcile(fetched, fetchGeneration: generation)
            slate = merged
            resolveHeldDrafts(merged, session: session, fetchGeneration: generation)
            retireAbsentDrafts(merged)
            readError = nil
            seedDrafts(from: fetched)
        } catch {
            guard self.session == session, self.target == target else { return }
            readError = "\(error)"
        }
    }

    /// `refresh`'s own merge against `pendingCreates`/`pendingDeletes`: a
    /// fetch whose read began before a local create or delete reached the
    /// server does not yet show it, so this re-applies each pending entry on
    /// top of `fetched` rather than letting `fetched` stand as the whole
    /// truth. A pending delete drops out once `fetched` itself agrees the
    /// card is gone, so `pendingDeletes` shrinks back to empty as soon as
    /// the server catches up.
    ///
    /// A pending create drops out the same way on confirmed presence, but
    /// ALSO on confirmed absence: once `fetchGeneration` (this fetch's own
    /// generation, stamped before its ssh call was dispatched) is past the
    /// generation the create's own write had already reached when it
    /// returned, this fetch is guaranteed to reflect whatever happened on
    /// the server after that write landed — so if it still does not carry
    /// the card, that absence is the server's answer, not a race `reconcile`
    /// should paper over. Without the second branch, a card removed by
    /// anything other than Deck's own `deleteNote` (a direct `slate-delete`,
    /// the co, another reader) before any fetch ever confirmed it present
    /// would resurrect on every poll forever, since the first branch alone
    /// never fires. Raised in round 2 review.
    private func reconcile(_ fetched: Slate, fetchGeneration: Int) -> Slate {
        var merged = fetched
        for (id, pending) in pendingCreates {
            if merged.cards.contains(where: { $0.id == id }) {
                pendingCreates[id] = nil
            } else if fetchGeneration > pending.confirmedAfterGeneration {
                pendingCreates[id] = nil
            } else {
                merged.cards.append(pending.card)
            }
        }
        for id in pendingDeletes {
            if let index = merged.cards.firstIndex(where: { $0.id == id }) {
                merged.cards.remove(at: index)
            } else {
                pendingDeletes.remove(id)
            }
        }
        return merged
    }

    /// The host note ids the Slate holds at the moment a create is sent: the
    /// cards `slate` carries, which reads replace, `adopt` appends to, and a
    /// confirmed delete removes from. `nil` until a read has landed, and then
    /// `persist` reads before it creates, so the record is never empty by
    /// accident.
    private var knownNoteIDs: Set<String>? {
        slate.map { Set($0.cards.compactMap(\.id)) }
    }

    /// Settles each draft a create left unconfirmed, from a fetch that has just
    /// landed. A host note is a candidate for a draft when one of the draft's
    /// claims covers it: the note is new since that create was sent, so its id
    /// is outside the claim's `knownIDs`, and no draft has adopted it yet. A
    /// note the operator typed on the host or in another pane before the
    /// create, with the same text, is not a candidate.
    ///
    /// Claimants come from every draft's claims, including drafts whose rows
    /// were deleted or closed and drafts gone ambiguous, since a create whose
    /// reply was lost may still have made the note. Two more kinds of claimant
    /// count: a draft whose create with that text is still in flight, since its
    /// reply can name the same note, and nothing else. A candidate is adopted
    /// only when this draft is its sole claimant. When the draft has more than
    /// one candidate, or a candidate has another claimant, the draft goes
    /// ambiguous and waits for Retry, which adds another note. When no candidate
    /// matches, a fetch that began after the failure settles the draft absent:
    /// it waits for Retry, and its claims stay.
    ///
    /// Claims are never ended by a read. A host write can land after the read
    /// that began after a failure, so a note with a claimed text stays claimed
    /// until adoption takes it. The cost is that a later same-text draft can go
    /// ambiguous, and Retry is its only exit.
    ///
    /// The claimants and candidates are read from the state as it stood before
    /// this fetch's changes, so one draft's adoption cannot change another's
    /// decision: an adopted note has exactly one claimant, so no other held
    /// draft offered it.
    private func resolveHeldDrafts(_ merged: Slate, session: String, fetchGeneration: Int) {
        let held = localNoteIDs.compactMap { key -> (key: String, draft: DraftNote, afterGeneration: Int)? in
            guard let draft = draftNotes[key], case .unconfirmed(let afterGeneration)? = draft.hold
            else { return nil }
            return (key, draft, afterGeneration)
        }
        guard !held.isEmpty else { return }
        let claimSets = draftNotes.values.map(\.claims)
        let inFlightTexts = draftNotes.values.compactMap(\.creating)
        let unowned = merged.cards.compactMap { card -> SlateCard.Note? in
            guard case .note(let note) = card, draftKeyByHostID[note.id] == nil else { return nil }
            return note
        }
        func claimants(of note: SlateCard.Note) -> Int {
            claimSets.filter { $0.contains { $0.covers(note) } }.count
                + inFlightTexts.filter { SlateModel.hostText($0) == SlateModel.hostText(note.text) }.count
        }
        for (key, draft, afterGeneration) in held {
            let candidates = unowned.filter { note in draft.claims.contains { $0.covers(note) } }
            if candidates.count > 1 || candidates.contains(where: { claimants(of: $0) > 1 }) {
                draft.hold = .ambiguous
                sendErrors[key] = "The Slate holds a new note with this text that another draft "
                    + "may own, so Deck cannot tell which is this draft's. Retry adds another."
            } else if let note = candidates.first {
                // The sole candidate is this draft's only possible note, so the
                // claims that cover it are settled by the adoption.
                draft.claims.removeAll { $0.covers(note) }
                draft.hold = nil
                draft.hostID = note.id
                sendErrors[key] = nil
                adopt(note, draft: draft, session: session)
                let typed = noteDrafts[key] ?? ""
                if SlateModel.hostText(typed) != SlateModel.hostText(note.text) {
                    scheduleDebouncedEdit(id: key, text: typed, drafts: \.noteDrafts)
                }
            } else if fetchGeneration > afterGeneration {
                draft.hold = .absent
                sendErrors[key] = "The Slate did not record this note. Retry creates it."
            }
        }
    }

    /// Retires a draft whose host note a fetch has confirmed gone. By the time
    /// `reconcile` drops a create's pending entry on confirmed absence, the
    /// note is gone for good, so its draft row goes with it rather than
    /// lingering as text that can only fail to send.
    private func retireAbsentDrafts(_ merged: Slate) {
        for (hostID, key) in draftKeyByHostID where localNoteIDs.contains(key) {
            // A sent note whose send set a notice keeps its row until the sheet
            // closes, so the notice stays on screen after the host stops listing it.
            guard sendNotices[key] == nil,
                  pendingCreates[hostID] == nil,
                  !merged.cards.contains(where: { $0.id == hostID }) else { continue }
            retireDraft(key)
        }
    }

    /// Restores an ask's `answer_draft`, or a note's `text`, into the
    /// editable field once per id — the item's own "Restore the field from
    /// `answer_draft` on launch," extended to notes the same way. A poll
    /// after that never overwrites what the operator is typing: once an id
    /// is seeded, Deck is the only writer of that text (through
    /// `editAnswer`/`editNote`'s debounced `slate-edit`), so a later poll
    /// reporting the same text back is confirmation, not news a fresher read
    /// should win over the operator's own keystrokes. A host note a local
    /// draft created is seeded by `adopt` instead, so the draft's text is
    /// never reset to the host's copy.
    private func seedDrafts(from slate: Slate) {
        for card in slate.cards {
            switch card {
            case .ask(let ask):
                guard !seededIDs.contains(ask.id) else { continue }
                seededIDs.insert(ask.id)
                answerDrafts[ask.id] = ask.answerDraft ?? ""
            case .note(let note):
                guard !seededIDs.contains(note.id) else { continue }
                seededIDs.insert(note.id)
                noteDrafts[note.id] = note.text
            case .unknown:
                continue
            }
        }
    }

    /// The cards the sheet draws from the host's list: every card except a
    /// host note that a local draft created, which the draft's own row draws
    /// instead.
    var sheetCards: [SlateCard] {
        (slate?.cards ?? []).filter { card in
            guard let id = card.id else { return true }
            return draftKeyByHostID[id] == nil
        }
    }

    /// The key a card is written under: a host note a draft created resolves
    /// to the draft's `localKey`, and every other id is its own key.
    private func draftKey(for id: String) -> String {
        draftKeyByHostID[id] ?? id
    }

    /// The operator's current text for an id, whichever draft dictionary it
    /// lives in — an ask's `answerDrafts` entry and a note's `noteDrafts`
    /// entry never collide, since the Bosun's ids are prefixed `a-`/`n-` by
    /// kind, and a local key never collides with a host id. `nil` only when
    /// neither dictionary has seeded this id yet.
    private func draftText(id: String) -> String? {
        let key = draftKey(for: id)
        return answerDrafts[key] ?? noteDrafts[key]
    }

    /// The operator typed. Updates the field at once, and schedules a
    /// debounced `slate-edit`.
    ///
    /// Chained onto whichever write this id already has pending or in
    /// flight (`previous.value`, below) rather than firing independently:
    /// cancelling `previous` only stops it while it is still asleep in its
    /// OWN debounce window. Once a write has started executing, cancelling
    /// it is a no-op on the in-flight ssh call, so without this chain a slow
    /// round trip for an older keystroke could complete after a newer one
    /// and overwrite it with no detection — raised in review, the same
    /// class of bug `SessionPaneModel.renderGeneration` closes for renders.
    ///
    /// The wait on `previous` happens BEFORE the "did my own debounce
    /// survive" check, not after: a generation whose own sleep gets
    /// cancelled by a later keystroke still has to propagate the wait on
    /// its predecessor to whoever chains off it next, or the chain is only
    /// transitive for two generations and breaks for three or more. Round 2
    /// review's concrete repro: A starts a slow in-flight write; B chains
    /// onto A and is still asleep in its own debounce when C arrives and
    /// cancels B; without this ordering, B returns without ever awaiting A,
    /// so C's wait on B resolves at once and C can land before A.
    func editAnswer(id: String, text: String) {
        guard canEditAnswer(id: id) else { return }
        scheduleDebouncedEdit(id: id, text: text, drafts: \.answerDrafts)
    }

    /// Whether the ask's answer can still be edited. An answer with a send in
    /// flight is read-only from the moment Send is pressed until the send settles,
    /// so text typed during the Touch ID prompt or the ssh round trip cannot reach
    /// the host under a signature that covers the text captured at press time.
    /// `SlatePane` disables the answer editor with this same value.
    func canEditAnswer(id: String) -> Bool {
        !sendingIDs.contains(draftKey(for: id))
    }

    /// The operator typed into a note. Same debounce, same write chain, same
    /// "never land out of order" guarantee as `editAnswer` — `slate-edit`
    /// serves a note's `text` and an ask's `answer_draft` through the one
    /// verb, so the two editors differ only in which drafts dictionary shows
    /// the field's current value. For a local draft the first non-empty text
    /// creates the note on the host instead, through the same link.
    func editNote(id: String, text: String) {
        guard canEditNote(id: id) else { return }
        scheduleDebouncedEdit(id: id, text: text, drafts: \.noteDrafts)
    }

    /// `editAnswer`/`editNote`'s shared core. See `editAnswer`'s own doc for
    /// why the wait on `previous` happens unconditionally and before the
    /// cancellation check.
    private func scheduleDebouncedEdit(
        id: String, text: String, drafts: ReferenceWritableKeyPath<SlateModel, [String: String]>
    ) {
        let key = draftKey(for: id)
        self[keyPath: drafts][key] = text
        let draft = draftNotes[key]
        let previous = editTasks[key]?.task
        previous?.cancel()
        guard let session, let target else { return }
        let read = fetchSlate
        let edit = writeEdit
        let create = writeCreateNote
        installLink(key) { [weak self] in
            try? await Task.sleep(for: SlateModel.editDebounce)
            let shouldWrite = !Task.isCancelled
            _ = await previous?.value
            guard shouldWrite else { return false }
            let hostID = draft == nil ? key : draft?.hostID
            let write = await SlateModel.persist(
                text: text, hostID: hostID, draft: draft, target: target, session: session,
                knownIDs: self?.knownNoteIDs, read: read, edit: edit, create: create)
            SlateModel.stamp(write, on: draft)
            self?.recordWrite(write, key: key, draft: draft, session: session, target: target)
            return SlateModel.landed(write)
        }
    }

    /// The one write a chain link makes for a card, after its predecessor has
    /// landed. A draft with no host id yet is created from its first non-empty
    /// text, and nothing is sent while the text is empty or whitespace. Every
    /// other write edits `hostID`. A held draft sends nothing at all.
    ///
    /// Only a create the host answers with a note, or refuses outright, is
    /// settled. A create that throws, or answers with anything else, is
    /// `.unconfirmed`: the host may have recorded the note, so `recordWrite`
    /// holds the draft instead of creating it again.
    ///
    /// A create made before any read has landed (`knownIDs` nil) reads the
    /// Slate first and records that read's ids as its known set. If the read
    /// fails, the create is not sent and the write is `.unread`.
    ///
    /// Static and `@MainActor` only because the class is: the ssh calls run in
    /// detached tasks, so nothing here touches `self`. The read is passed in as
    /// a closure for the same reason `edit` and `create` are, so a chain link
    /// still reads and creates after this model is gone.
    private static func persist(
        text: String, hostID: String?, draft: DraftNote?, target: SSHTarget, session: String,
        knownIDs: Set<String>?,
        read: @escaping @Sendable (SSHTarget, String) throws -> Slate?,
        edit:@escaping @Sendable (SSHTarget, String, String, String) throws -> SessionAgent.SlateWriteOutcome,
        create: @escaping @Sendable (SSHTarget, String, String) throws -> SessionAgent.SlateWriteOutcome
    ) async -> DraftWrite {
        if draft?.hold != nil { return .held }
        guard let hostID else {
            guard !hostText(text).isEmpty else { return .nothing }
            let known: Set<String>
            if let knownIDs {
                known = knownIDs
            } else {
                let outcome = await Task.detached { () -> Slate? in try? read(target, session) }.value
                guard let fetched = outcome else { return .unread }
                known = Set(fetched.cards.compactMap { $0.id })
            }
            draft?.creating = text
            let result = await run { try create(target, session, text) }
            draft?.creating = nil
            switch result {
            case .success(.card(.note(let note))):
                return .created(.success(note))
            case .success(.refused(let message)):
                return .created(.failure(SessionAgent.AgentError.failed(message)))
            case .success, .failure:
                return .unconfirmed(text: text, knownIDs: known)
            }
        }
        return .edited(await run { try edit(target, session, hostID, text) })
    }

    /// Stamps the host id a create returned onto its draft, so every later
    /// link writes to it. Done on the chain rather than in `adopt`, because a
    /// create can land after the model is gone and the links queued behind it
    /// still need the id.
    private static func stamp(_ write: DraftWrite, on draft: DraftNote?) {
        if case .created(.success(let note)) = write { draft?.hostID = note.id }
    }

    /// Runs a write off the main actor without depending on `self`, so a
    /// write chained from `flushPendingEdits` still completes even once
    /// this model has been deallocated. Captures the thrown error (if any)
    /// into the result rather than discarding it with `try?` — previously
    /// swallowed silently; raised in review.
    private static func run(
        _ work: @escaping @Sendable () throws -> SessionAgent.SlateWriteOutcome
    ) async -> Result<SessionAgent.SlateWriteOutcome, Error> {
        await Task.detached { () -> Result<SessionAgent.SlateWriteOutcome, Error> in
            Result { try work() }
        }.value
    }

    /// Records a chain link's write the way `send` records a send's, so a
    /// refused or failed save shows under the card instead of vanishing
    /// silently. A successful save clears any error a previous attempt left
    /// behind. A create that landed becomes a host card (see `adopt`); a
    /// create that failed leaves the draft and its error under its own row.
    private func recordWrite(_ write: DraftWrite, key: String, draft: DraftNote?,
                             session: String, target: SSHTarget) {
        guard self.session == session, self.target == target else { return }
        switch write {
        case .nothing, .held:
            return
        case .created(.success(let note)):
            if let draft { adopt(note, draft: draft, session: session) }
        case .created(.failure(let error)):
            sendErrors[key] = "\(error)"
        case .unconfirmed(let text, let knownIDs):
            guard let draft else { return }
            draft.claims.append(Claim(text: text, knownIDs: knownIDs))
            draft.hold = .unconfirmed(afterGeneration: fetchGeneration)
            sendErrors[key] = "The Slate did not confirm this note, so Deck will not create it again on its own."
        case .unread:
            guard let draft else { return }
            draft.hold = .unread
            sendErrors[key] = "The Slate could not be read before this note was created, so Deck did not create it. Retry creates it."
        case .edited(let result):
            recordEditResult(result, id: key, session: session, target: target)
        }
    }

    /// Records a debounced edit's outcome the way `send` already records a
    /// send's, so a refused or failed save shows under the card instead of
    /// vanishing silently. A successful save clears any error a previous
    /// attempt left behind.
    private func recordEditResult(_ result: Result<SessionAgent.SlateWriteOutcome, Error>,
                                   id: String, session: String, target: SSHTarget) {
        guard self.session == session, self.target == target else { return }
        switch result {
        case .success(let outcome):
            switch outcome {
            case .card:
                sendErrors[id] = nil
            case .refused(let message):
                sendErrors[id] = message
            case .malformed:
                sendErrors[id] = "The Slate did not confirm the save."
            }
        case .failure(let error):
            sendErrors[id] = "\(error)"
        }
    }

    /// Adds a note a draft's create just made to `slate.cards`, so the host's
    /// copy is what `reconcile` and the next fetch see. The draft row keeps
    /// drawing it (see `sheetCards`), and `pendingCreates` holds it until a
    /// fetch agrees, the same rule a create always followed.
    private func adopt(_ note: SlateCard.Note, draft: DraftNote, session: String) {
        draftKeyByHostID[note.id] = draft.localKey
        draftHostIDs[draft.localKey] = note.id
        seededIDs.insert(note.id)
        let card = SlateCard.note(note)
        // Before any read has landed there is no Slate to append to. A Slate
        // holding only this card would make `knownNoteIDs` incomplete for the
        // next create, so the first read picks the card up from `pendingCreates`.
        if var current = slate {
            // A fetch may already carry this id, having landed while the create was
            // still in flight. Appending it again would draw the note twice.
            if !current.cards.contains(where: { $0.id == note.id }) { current.cards.append(card) }
            slate = current
        }
        // Held until a fetch itself agrees, either way — see `reconcile` — so
        // a poll whose read began before this create reached the server
        // cannot drop it from the sheet, and one that began after can still
        // confirm it gone.
        pendingCreates[note.id] = PendingCreate(card: card, confirmedAfterGeneration: fetchGeneration)
    }

    /// Whether Send should be enabled for an ask or a note — disabled while
    /// its text is empty or whitespace, so the operator never sends a
    /// request `slate-send` would itself refuse: the contract
    /// (platform/contracts/session-agent-api, knowledge#725) has `slate-send`
    /// strip the answer of surrounding whitespace, refuse the send when
    /// nothing is left, and store the trimmed text as the answer. This is
    /// the backstop to that server check, not a substitute for it (the
    /// Bosun's own ruling, carried in
    /// issue_01M3WPYD8M0P8PD20Y3ZBNGBWG's thread and restated for notes in
    /// issue_01M3WPYKPX8M9ZDFCNVTD36FJZ's body).
    func canSend(id: String) -> Bool {
        !SlateModel.hostText(draftText(id: id) ?? "").isEmpty
    }

    /// Whether the card's Send button is enabled. A kept sent note is already
    /// delivered and keeps its row only to show its notice, so its Send stays
    /// off; pressing it would send a note the host no longer lists. The view
    /// reads this in place of `canSend` and `sendingIDs`.
    func sendEnabled(id: String) -> Bool {
        let key = draftKey(for: id)
        return canSend(id: id) && !sendingIDs.contains(key) && !isKeptSentNote(key)
    }

    /// Whether the note's text can still be edited. A kept sent note is read-only:
    /// its text is what the host delivered, so an edit must not reach the host. A
    /// note with a send in flight is read-only too, from the moment Send is pressed
    /// until the send settles, so text typed during the Touch ID prompt or the ssh
    /// round trip cannot write to a note the host is about to receive or has received.
    /// `SlatePane` disables the editor with this same value.
    func canEditNote(id: String) -> Bool {
        let key = draftKey(for: id)
        return !isKeptSentNote(key) && !sendingIDs.contains(key)
    }

    /// A note whose send delivered with a notice and whose row is kept on the
    /// sheet. `key` is the key the row is written under.
    private func isKeptSentNote(_ key: String) -> Bool {
        localNoteIDs.contains(key) && sendNotices[key] != nil
    }

    /// Sends an ask's answer, or a note. Flushes the operator's latest text
    /// first and waits for it, rather than racing the debounced write already
    /// pending: `slate-send` delivers whatever text is on disk, not whatever
    /// Deck's field currently shows, so sending while an edit is still in
    /// flight could deliver stale text. For a draft whose host note does not
    /// exist yet, the flush is its create, and the send then goes to the id
    /// that create returned. One implementation for both card kinds —
    /// `slate-send` already takes only an id, generic over what it delivers.
    ///
    /// Also waits on whichever write this key already had pending or in
    /// flight (`previous.value`) before sending its own flush — the same
    /// ordering `editAnswer`/`editNote` chain on, so a slow earlier edit
    /// cannot land after the flush this send just made.
    ///
    /// Installs its own edit+send as the new `editTasks[key]` tail BEFORE
    /// awaiting `previous`, rather than clearing the slot. Nothing chains onto
    /// the tail while the send is in flight: edits and Delete refuse a key in
    /// `sendingIDs`, and the sheet-close flush chains behind the send and saves
    /// only when the send did not deliver and its own save did not land (see
    /// `flushPendingEdits`).
    /// The tail's job is what remains after the send settles without its write
    /// landing. The entry then
    /// stays, so a `stop()` after the send flushes that text again instead of
    /// losing it. `text` is captured here, before any later edit can change the
    /// drafts dictionary, so the send always carries what was on screen when
    /// Send was pressed.
    /// `host` is the crew's machine name from the host probe. An ask's answer
    /// and a note are both signed, so a send with no name on a host that
    /// verifies them is refused rather than sent unsigned.
    func send(id: String, host: String? = nil) async {
        let key = draftKey(for: id)
        guard let session, let target, canSend(id: key), !sendingIDs.contains(key) else { return }
        // A held draft has no settled host id to send, and its error already
        // says what Deck is waiting for, so the press changes nothing.
        guard draftNotes[key]?.hold == nil else { return }
        let generation = crewGeneration
        let flight = InFlightSend(session: session, target: target, key: key)
        sends.begin(flight)
        if let hostID = draftNotes[key]?.hostID { sends.adopt(flight, hostID: hostID) }
        sendErrors[key] = nil
        sendNotices[key] = nil
        let draft = draftNotes[key]
        let previous = editTasks[key]?.task
        previous?.cancel()
        let text = draftText(id: key) ?? ""
        let read = fetchSlate
        let edit = writeEdit
        let create = writeCreateNote
        let send = writeSend
        let loadKey = loadSigningKey
        let now = clock
        let saved = SaveLanding()
        // Captured directly, not through `self`, so the entry ends even after the sheet
        // that started this send has closed and its model is gone.
        let registry = sends
        let task = installLink(key, save: saved) { [weak self] in
            defer { registry.end(flight) }
            _ = await previous?.value
            // A create already in flight when Send was pressed stamps the draft's
            // host id while this link waits on it, so record it now; this send's
            // own create is recorded after `persist`. Both go on the registry, not
            // only on `self`, so a sheet rebuilt after this one closed still sees
            // the note locked under its host id.
            if let id = draft?.hostID { registry.adopt(flight, hostID: id) }
            let hostID = draft == nil ? key : draft?.hostID
            let write = await SlateModel.persist(
                text: text, hostID: hostID, draft: draft, target: target, session: session,
                knownIDs: self?.knownNoteIDs, read: read, edit: edit, create: create)
            SlateModel.stamp(write, on: draft)
            saved.landed = SlateModel.landed(write)
            if let draft, case .created(.success(let note)) = write {
                registry.adopt(flight, hostID: note.id)
                self?.adopt(note, draft: draft, session: session)
            }
            // The write's outcome decides whether this link leaves `editTasks`,
            // whatever the send after it does.
            let landed = SlateModel.landed(write)
            do {
                let sendID: String
                switch write {
                case .nothing, .held:
                    self?.finishSend(flight, generation: generation, outcome: nil, error: nil)
                    return landed
                case .unconfirmed, .unread:
                    self?.recordWrite(write, key: key, draft: draft, session: session, target: target)
                    self?.finishSend(flight, generation: generation, outcome: nil, error: nil)
                    return landed
                case .created(let result):
                    sendID = try result.get().id
                case .edited(let result):
                    // A failed edit throws, and that stops every send here. A refused
                    // edit returns normally with no saved card. `signSend` then refuses
                    // the send on a host that lists the capability, whether or not this
                    // Mac has a key, because the saved-text check runs before the key is
                    // loaded. On a host without the capability the unsigned send goes on.
                    _ = try result.get()
                    sendID = hostID ?? key
                }
                let signing = await SlateModel.signSend(
                    id: sendID, text: text, host: host, session: session, target: target,
                    saved: SlateModel.savedText(write),
                    read: read, loadKey: loadKey, now: now)
                var sig: String?
                var notice: String?
                switch signing {
                case .signed(let value):
                    sig = value
                case .unsigned(let unsignedNotice):
                    notice = unsignedNotice
                case .refused(let message):
                    throw SessionAgent.AgentError.failed(message)
                }
                let argument = sig
                let outcome = try await Task.detached { try send(target, session, sendID, argument) }.value
                // A delivered send carries the text the flush would save, so nothing may
                // save it again after delivery, whatever this send's own save did.
                if case .card = outcome { saved.landed = true }
                self?.finishSend(flight, generation: generation, outcome: outcome, error: nil,
                                 notice: notice)
            } catch {
                self?.finishSend(flight, generation: generation, outcome: nil, error: error)
            }
            return landed
        }
        await task.value
    }

    /// What `signSend` decided for one send.
    private enum AnswerSignature {
        case signed(String)
        /// Send unsigned. `notice` is set when the host verifies answers but this
        /// Mac has no key, and it says so on the card. It is `nil` when the host
        /// does not verify answers at all.
        case unsigned(notice: String?)
        /// Send nothing. The reason shows on the card.
        case refused(String)
    }

    /// The text the Slate holds for the card a flushed save returned, which is
    /// the text `slate-send` will deliver: an ask's `answer_draft` or a note's
    /// `text`. `nil` when the save did not come back as a card. A note that this
    /// send's own flush created is judged by the text its create returned.
    private static func savedText(_ write: DraftWrite) -> String? {
        switch write {
        case .created(.success(let note)): return note.text
        case .edited(.success(.card(.ask(let ask)))): return ask.answerDraft ?? ""
        case .edited(.success(.card(.note(let note)))): return note.text
        default: return nil
        }
    }

    /// The text a read holds for card `id`: an ask's `answer_draft` or a note's
    /// `text`. `nil` when the read does not list the card.
    nonisolated private static func heldText(of id: String, in slate: Slate) -> String? {
        guard let card = slate.cards.first(where: { $0.id == id }) else { return nil }
        switch card {
        case .ask(let ask): return ask.answerDraft ?? ""
        case .note(let note): return note.text
        case .unknown: return nil
        }
    }

    /// Decides how a send is signed, and signs it. Runs off the main actor: the
    /// read is an ssh round trip, and `sign` raises Touch ID.
    ///
    /// The host is read here, not taken from the poll's last value, so the send
    /// is judged by what the host lists now. A host that lists `slate-sig-v1`
    /// gets a signed send, except that a Mac with no signing key sends unsigned
    /// and the card says so. An unreadable Slate, an unknown host name, an
    /// unsaved text, a saved text that differs from the text signed, a text the
    /// read no longer holds, a cancelled prompt and a failed signature all refuse
    /// the send.
    private static func signSend(
        id: String, text: String, host: String?, session: String, target: SSHTarget,
        saved: String?,
        read: @escaping @Sendable (SSHTarget, String) throws -> Slate?,
        loadKey: @escaping @Sendable () throws -> SigningKey?,
        now: @escaping @Sendable () -> Date
    ) async -> AnswerSignature {
        await Task.detached { () -> AnswerSignature in
            guard let fetched = try? read(target, session) else {
                return .refused("The Slate could not be read, so Deck cannot tell whether this host verifies answers. Nothing was sent.")
            }
            guard fetched.capabilities.contains(SlateAnswerSignature.capability) else {
                return .unsigned(notice: nil)
            }
            guard let saved else {
                return .refused("The Slate did not save this text, so nothing was sent.")
            }
            // `slate-send` delivers what the Slate saved, so the signature must cover
            // that text. A mismatch means the Slate holds other text than the text
            // Deck would sign.
            guard SlateAnswerSignature.pythonStrip(saved) == SlateAnswerSignature.pythonStrip(text) else {
                return .refused("The Slate saved different text from the text Deck signed, so nothing was sent.")
            }
            // The flush's return is only as fresh as that save. This read runs before
            // the Touch ID prompt, so a change made during the prompt is not caught,
            // and neither is one made after the read and before `slate-send`. A card
            // the read no longer lists counts as changed.
            guard let held = heldText(of: id, in: fetched),
                  SlateAnswerSignature.pythonStrip(held) == SlateAnswerSignature.pythonStrip(text) else {
                return .refused("The Slate's text for this card changed before signing, so nothing was sent.")
            }
            guard let host else {
                return .refused("Deck does not know this host's name yet, so it cannot sign the send. Nothing was sent.")
            }
            let key: SigningKey?
            do {
                key = try loadKey()
            } catch {
                return .refused("Deck could not load its signing key, so nothing was sent: \(error.localizedDescription)")
            }
            guard let key else {
                return .unsigned(notice: "Sent unsigned: this Mac has no signing key.")
            }
            let payload = SlateAnswerSignature.payload(
                card: id, crew: session, host: host,
                text: SlateAnswerSignature.pythonStrip(text),
                nonce: SlateAnswerSignature.randomNonce(), ts: now())
            do {
                return .signed(try SlateAnswerSignature.sign(payload, with: key))
            } catch SigningKeyError.cancelled {
                return .refused("The Touch ID prompt was cancelled. Nothing was sent.")
            } catch {
                return .refused("Deck could not sign the answer, so nothing was sent: \(error.localizedDescription)")
            }
        }.value
    }

    /// Applies a send's outcome (or records its failure) and clears the send's
    /// in-flight entry, the way `recordEditResult` does for a debounced edit —
    /// split out of `send` so the chain-tail `Task` installed in
    /// `editTasks[key]` can call it through `self` without depending on
    /// `send`'s own stack frame still being alive.
    ///
    /// `notice` is the "Sent unsigned" notice `signSend` chose, and it is written
    /// here, on a delivered send only, so a refused or failed send never shows a
    /// notice for a note the host does not have. It is written behind the same
    /// generation guard as the outcome, so a send that finishes after the column
    /// has moved to another crew, even back to the crew it began on, cannot put
    /// its notice or kept row on the sheet now showing.
    ///
    /// The in-flight entry is not removed here. The send's link ends it on the shared
    /// registry whatever model is current, so a send that finishes after the column
    /// has moved to another crew still unlocks its note.
    ///
    /// A delivered note leaves the sheet at once, unless its send set a notice. A
    /// note whose send set a notice keeps its row, so the notice draws under the
    /// sent text, and no poll retires that row; `sendEnabled` keeps its Send off
    /// and `canEditNote` keeps its text read-only. The row leaves when the sheet
    /// closes or the operator deletes it. A note that was not drafted on this sheet
    /// gets its row from `keepSentNote`.
    private func finishSend(_ flight: InFlightSend, generation: Int,
                             outcome: SessionAgent.SlateWriteOutcome?, error: Error?,
                             notice: String? = nil) {
        let id = flight.key
        guard generation == crewGeneration else { return }
        if let outcome {
            apply(outcome, id: id)
            if case .card(let card) = outcome {
                if let notice {
                    sendNotices[id] = notice
                    if case .note(let note) = card { keepSentNote(key: id, hostID: note.id) }
                } else if draftNotes[id] != nil {
                    retireDraft(id)
                }
            }
        } else if let error {
            sendErrors[id] = "\(error)"
        }
    }

    /// Keeps a sent note's row on the sheet, under `key`, so its notice stays
    /// readable. A note drafted on this sheet already has its row, so this adds a
    /// row only for a note the host listed: `draftKeyByHostID` hides the host's
    /// copy from `sheetCards`, and `draftHostIDs` draws the id above the row.
    private func keepSentNote(key: String, hostID: String) {
        if !localNoteIDs.contains(key) { localNoteIDs.append(key) }
        draftKeyByHostID[hostID] = key
        draftHostIDs[key] = hostID
    }

    /// Applies a send's outcome. On success the returned card replaces the
    /// one Deck is holding — see `applyCard` — so the card shows as answered
    /// within the action rather than waiting for the next poll, the item's
    /// own "After Send, the card shows as answered." On a refusal "the card
    /// stays exactly as it was" (the Bosun's own contract), so only
    /// `sendErrors` is written.
    private func apply(_ outcome: SessionAgent.SlateWriteOutcome, id: String) {
        switch outcome {
        case .card(let card):
            applyCard(card)
        case .refused(let message):
            sendErrors[id] = message
        case .malformed:
            sendErrors[id] = "The Slate did not confirm the send."
        }
    }

    private func applyCard(_ card: SlateCard) {
        guard var current = slate, let id = card.id,
              let index = current.cards.firstIndex(where: { $0.id == id }) else { return }
        current.cards[index] = card
        slate = current
    }

    /// Opens a draft note on the sheet. Nothing is written to the host: the
    /// note is created there with its first non-empty text, through the same
    /// debounced path edits use, or when Send is pressed, whichever comes
    /// first. The host therefore never sees an empty note.
    func createNote() {
        guard session != nil, target != nil else { return }
        let localKey = "local-\(UUID().uuidString)"
        draftNotes[localKey] = DraftNote(localKey: localKey)
        localNoteIDs.append(localKey)
        noteDrafts[localKey] = ""
    }

    /// Whether Retry is offered for a draft: a read has settled that the host
    /// did not record its create, that the host holds more than one note the
    /// create could have made, or that the read before the create failed so
    /// the create was never sent. Only Retry creates it now.
    func canRetryCreate(id: String) -> Bool {
        let hold = draftNotes[draftKey(for: id)]?.hold
        return hold == .absent || hold == .ambiguous || hold == .unread
    }

    /// Creates a draft the host did not record, from its current text. Goes
    /// through the same debounced write an edit uses, so the create waits for
    /// the operator to stop typing.
    func retryCreate(id: String) {
        let key = draftKey(for: id)
        guard let draft = draftNotes[key], canRetryCreate(id: key) else { return }
        draft.hold = nil
        sendErrors[key] = nil
        scheduleDebouncedEdit(id: key, text: noteDrafts[key] ?? "", drafts: \.noteDrafts)
    }

    /// Deletes a note. A draft the host has not created yet has nothing on the
    /// host to delete, so it is only dropped from the sheet. Chains onto
    /// whichever write this card already had pending or in flight, same
    /// ordering `send` uses, so a debounced edit still typing when Delete is
    /// pressed lands (or is superseded) before the delete rather than racing
    /// it — and installs itself as the new `editTasks[key]` tail BEFORE
    /// awaiting that predecessor, the same reason `send` does, so a stray
    /// edit arriving mid-delete chains onto the delete rather than slipping
    /// in ahead of it.
    ///
    /// A kept sent row never reaches the host. Its note is already delivered, and
    /// the contract refuses `slate-delete` on a sent note, so the row is retired
    /// here and no delete call is made.
    ///
    /// A note whose send is in flight is refused, so Delete cannot race the send
    /// through the Touch ID prompt or the ssh round trip. Once the send settles the
    /// note is deletable again.
    func deleteNote(id: String) async {
        let key = draftKey(for: id)
        guard let session, let target, !deletingIDs.contains(key), !sendingIDs.contains(key) else { return }
        if isKeptSentNote(key) {
            retireDraft(key)
            return
        }
        deletingIDs.insert(key)
        sendErrors[key] = nil
        let draft = draftNotes[key]
        let previous = editTasks[key]?.task
        previous?.cancel()
        let delete = writeDeleteNote
        let task = installLink(key) { [weak self] in
            _ = await previous?.value
            // Read only now, after the predecessor: a create it made is the
            // note this delete has to remove.
            guard let hostID = draft == nil ? key : draft?.hostID else {
                self?.retireDraft(key)
                self?.deletingIDs.remove(key)
                return false
            }
            do {
                let outcome = try await Task.detached { try delete(target, session, hostID) }.value
                self?.finishDelete(key: key, hostID: hostID, session: session, target: target,
                                         outcome: outcome, error: nil)
                if case .deleted = outcome { return true }
                return false
            } catch {
                self?.finishDelete(key: key, hostID: hostID, session: session, target: target,
                                         outcome: nil, error: error)
                return false
            }
        }
        await task.value
    }

    /// Applies a delete's outcome (or records its failure) and clears
    /// `deletingIDs`, the way `finishSend` does for a send. On success the
    /// card and its draft leave the sheet at once, the same "within the
    /// action, not waiting on the next poll" rule `applyCard` follows for a
    /// send. On a refusal the card itself is left exactly as it was,
    /// matching the Bosun's own "a card changes state only after delivery
    /// succeeds" — deletion is the one state change with no "state" to
    /// revert, so the card simply stays on the sheet.
    ///
    /// EVERY NON-SUCCESS CASE ALSO DROPS A PENDING CREATE FOR THIS HOST ID, not
    /// only the success case. A refusal or a failed delivery most often
    /// means the card does not exist to delete in the first place — exactly
    /// the state a pending create left unconfirmed (see `reconcile`) can end
    /// up in once something else removes the card first. Leaving the entry
    /// in place there would have Deck's own attempt to clean up a ghost
    /// card be the one thing that keeps forcing it back. Raised in round 2
    /// review.
    private func finishDelete(key: String, hostID: String, session: String, target: SSHTarget,
                               outcome: SessionAgent.SlateDeleteOutcome?, error: Error?) {
        deletingIDs.remove(key)
        guard self.session == session, self.target == target else { return }
        switch (outcome, error) {
        case (.deleted, _):
            if var current = slate {
                current.cards.removeAll { $0.id == hostID }
                slate = current
            }
            // A kept host note's row goes with it, as a draft's row does.
            retireDraft(key)
            // Held until a fetch itself omits this id — see `reconcile` — so
            // a poll whose read began before this delete reached the server
            // cannot resurrect the card. A pending create for the same id is
            // dropped rather than held: it was never confirmed, so
            // re-applying it on top of a fetch that has not caught up would
            // bring back a card this delete already removed.
            pendingCreates[hostID] = nil
            pendingDeletes.insert(hostID)
        case (.refused(let message), _):
            sendErrors[key] = message
            pendingCreates[hostID] = nil
        case (.malformed, _):
            sendErrors[key] = "The Slate did not confirm the delete."
            pendingCreates[hostID] = nil
        case (nil, let error?):
            sendErrors[key] = "\(error)"
            pendingCreates[hostID] = nil
        case (nil, nil):
            break
        }
    }

    /// Removes a draft's row from the sheet and clears what it was showing,
    /// including its notice. Its `DraftNote` stays, since the host note it may
    /// have created is still the chain's target for any write queued behind it,
    /// and its `claims` stay, since a held draft's create may have made a note no
    /// other draft may adopt. Delete and close both come through here, so neither
    /// releases a claim.
    private func retireDraft(_ key: String) {
        localNoteIDs.removeAll { $0 == key }
        noteDrafts[key] = nil
        sendErrors[key] = nil
        sendNotices[key] = nil
    }

    /// Closing the sheet drops every draft still empty, since nothing was ever
    /// written for it. A draft with text is left for the flush to create.
    private func discardEmptyDrafts() {
        for key in localNoteIDs where draftNotes[key]?.hostID == nil {
            if SlateModel.hostText(noteDrafts[key] ?? "").isEmpty {
                retireDraft(key)
            }
        }
    }
}
