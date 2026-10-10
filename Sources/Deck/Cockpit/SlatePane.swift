import SwiftUI

/// The Slate sheet: one crew's asks, where the operator answers and sends
/// each one — issue_01M3WPYD8M0P8PD20Y3ZBNGBWG, built to the Bosun's
/// contract in issue_01M3WPXY03HBB1NZWT0JYRQQ9D (CQ-358).
///
/// NATIVE, NOT A WEB PANE: this is chrome — live controls the operator
/// types and clicks into, not a rendered document — so it sits on the
/// native side of the boundary rule the same way `RunDetailPane` does.
///
/// Draws both `kind: ask` and `kind: note` cards — note cards are
/// issue_01M3WPYKPX8M9ZDFCNVTD36FJZ's own slice. The pane never passes
/// `--all`, and `slate` hides sent notes without it, so a host note leaves
/// the sheet on its own the moment `send` marks it sent. The exception is a
/// note whose send set a notice ("Sent unsigned"), whether drafted on this
/// sheet or already on the host: it keeps its row, with Send off and its text
/// read-only, until the sheet closes or it is deleted, so the notice stays readable.
///
/// THE SHEET TAKES ITS COLOURS RESOLVED, NOT FROM THE WINDOW. `ContentView`
/// resolves the crew's canvas, its band colours and its place line from the
/// session the sheet was opened for, and the shell's appearance, so this view
/// reads neither a theme nor `colorScheme`. The card ids take the place-line
/// ink solved against the canvas they sit on.
struct SlatePane: View {
    let session: String
    let target: SSHTarget
    let onClose: () -> Void
    /// The crew's conversation canvas, which the cards sit on.
    let canvas: RGB
    /// The band's colours: the crew's identity, drawn in the header.
    let bandColours: ColumnBandColours
    /// The band's place line, such as `deck-coder on macstudio`.
    let place: String

    /// The crew machine's name from the host probe, read when an answer is sent,
    /// since the probe may land after the sheet opens. A signed answer needs it.
    private let probedName: (SSHTarget) -> String?
    @StateObject private var model: SlateModel
    @State private var expandedIDs: Set<String>
    /// The draft note awaiting the operator's confirmation before
    /// `deleteNote` runs — the item's own "A draft is deletable, with a
    /// confirmation."
    @State private var noteIDPendingDelete: String?

    /// `sends` is the window's shared send registry, which `ContentView` passes so a
    /// send outlives this sheet. `model` and `initiallyExpanded` exist only so
    /// `SlatePaneRenderTests` can seed fixture cards and force a card open before the
    /// first frame — the real `ContentView` call site passes neither, so both default
    /// to what `start(session:target:)` and an untouched disclosure already give every
    /// real sheet.
    init(session: String, target: SSHTarget, onClose: @escaping () -> Void,
         canvas: RGB, bandColours: ColumnBandColours, place: String,
         sends: SlateSendRegistry = SlateSendRegistry(), model: SlateModel? = nil,
         initiallyExpanded: Set<String> = [],
         probedName: @escaping (SSHTarget) -> String? = { _ in nil }) {
        self.session = session
        self.target = target
        self.probedName = probedName
        self.onClose = onClose
        self.canvas = canvas
        self.bandColours = bandColours
        self.place = place
        _model = StateObject(wrappedValue: model ?? SlateModel(sends: sends))
        _expandedIDs = State(initialValue: initiallyExpanded)
    }

    private var refreshKey: String { "\(target.user)@\(target.host)|\(session)" }

    /// Sends one card. Both Send buttons call this, so an ask and a note read the
    /// host name the signature needs the same way, at the press.
    static func sendCard(_ model: SlateModel, id: String, target: SSHTarget,
                         probedName: (SSHTarget) -> String?) async {
        await model.send(id: id, host: probedName(target))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                content
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(canvas))
        }
        // Every read-only line on the sheet inherits selection from here, so a
        // new line is copyable without its own modifier. Buttons are exempt
        // from the inherited setting, so Send, Delete and New Note still click.
        .textSelection(.enabled)
        .task(id: refreshKey) { model.start(session: session, target: target) }
        .onDisappear { model.stop() }
        .alert("Delete this note?", isPresented: Binding(
            get: { noteIDPendingDelete != nil },
            set: { isPresented in if !isPresented { noteIDPendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = noteIDPendingDelete { Task { await model.deleteNote(id: id) } }
                noteIDPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { noteIDPendingDelete = nil }
        } message: {
            Text("This draft is deleted for good, never sent.")
        }
    }

    private var header: some View {
        ColumnBand(title: "Slate", icon: "list.bullet.clipboard.fill", place: place,
                   colours: bandColours) {
            Button("New Note") { model.createNote() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Close and return to the cockpit")
        }
    }

    /// The host's cards, then the drafts New Note opened. Drafts sit outside
    /// the read-state branches so an operator's typed text stays on screen
    /// through a read error or a read still in progress.
    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let readError = model.readError {
                // THE SHEET'S "STATE UNKNOWN" — a host whose `session-agent`
                // lacks the verb, or an unreachable one, lands here rather than
                // an empty list that would read as "no asks" when the truth is
                // "could not tell".
                Text("This crew's Slate state is unknown: \(readError)")
                    .frameFont(.body).foregroundStyle(.secondary)
            } else if model.slate != nil {
                if model.sheetCards.isEmpty && model.localNoteIDs.isEmpty {
                    Text("Nothing on the Slate.").frameFont(.body).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.sheetCards.enumerated()), id: \.offset) { _, card in
                        cardRow(card)
                    }
                }
            } else if model.localNoteIDs.isEmpty {
                Text("Reading this crew's Slate…").frameFont(.body).foregroundStyle(.secondary)
            }
            ForEach(model.localNoteIDs, id: \.self) { localKey in
                noteCard(id: localKey, shownID: model.draftHostIDs[localKey])
            }
        }
    }

    @ViewBuilder
    private func cardRow(_ card: SlateCard) -> some View {
        switch card {
        case .ask(let ask):
            askCard(ask)
        case .note(let note):
            noteCard(id: note.id, shownID: note.id)
        case .unknown(let id):
            unknownRow(id: id)
        }
    }

    private func unknownRow(id: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            Text(id.map { "Card \($0): state unknown" } ?? "A card's state is unknown")
                .frameFont(.body).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// One ask, collapsible — `DisclosureGroup`'s label always shows
    /// `question` (clipped to one line while collapsed; the underlying
    /// string is never altered), and the expanded body shows it again in
    /// full alongside the answer field and Send.
    private func askCard(_ ask: SlateCard.Ask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            cardIDLine(ask.id)
            DisclosureGroup(isExpanded: Binding(
                get: { expandedIDs.contains(ask.id) },
                set: { isOn in
                    if isOn { expandedIDs.insert(ask.id) } else { expandedIDs.remove(ask.id) }
                }
            )) {
                askBody(ask)
            } label: {
                // The label is the tap that expands the card. Inherited selection
                // would start a text selection on the click instead, which is how
                // `RunDetailPane`'s tappable rows lost their tap (build 773). The
                // full question is selectable once the card is open.
                HStack(spacing: 6) {
                    Text(ask.question).frameFont(.body).lineLimit(1)
                    Spacer(minLength: 0)
                    if ask.state == .answered {
                        Text("Answered").frameFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .textSelection(.disabled)
            }
        }
    }

    /// The card's id, in a small monospaced line above its content. This is
    /// the handle the operator gives the co (`[slate <id>]`). The id passed
    /// `SessionAgent.validateCardId` at decode, so it draws as plain text.
    private func cardIDLine(_ id: String) -> some View {
        Text(id)
            .frameFont(.caption)
            .monospaced()
            .foregroundStyle(Color(ThemeRecipe.placeLineInk(on: canvas)))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The expanded body of an ask: the question, the answer field, and Send.
    private func askBody(_ ask: SlateCard.Ask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Plain `Text(String)`, never Markdown or `AttributedString`
            // — the item's own rule, so quotes, `$`, backticks and a
            // newline in the question all draw byte for byte.
            Text(ask.question)
                .frameFont(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: Binding(
                get: { model.answerDrafts[ask.id] ?? "" },
                set: { model.editAnswer(id: ask.id, text: $0) }
            ))
            .frameFont(.body)
            // An answer whose send is in flight is locked until that send settles (see `canEditAnswer`).
            .disabled(!model.canEditAnswer(id: ask.id))
            .frame(minHeight: 60, maxHeight: 140)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            if let error = model.sendErrors[ask.id] {
                Text(error).frameFont(.caption).foregroundStyle(.red)
            }
            if let notice = model.sendNotices[ask.id] {
                Text(notice).frameFont(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(ask.state == .answered ? "Send Again" : "Send") {
                    Task { await Self.sendCard(model, id: ask.id, target: target, probedName: probedName) }
                }
                // Disabled while the answer is empty or whitespace, so
                // the operator never sends a request `slate-send` would
                // itself refuse — the contract
                // (platform/contracts/session-agent-api,
                // issue_01M3WPYD8M0P8PD20Y3ZBNGBWG's thread) has it
                // strip and refuse an empty or whitespace answer.
                .disabled(!model.canSend(id: ask.id) || model.sendingIDs.contains(ask.id))
            }
        }
        .padding(.top, 6)
    }

    /// One draft note — not collapsible, unlike an ask: there is no question
    /// to summarise, only the operator's own text, so the editor shows at
    /// once. Always a draft (the pane's own doc explains why), so there is
    /// no "Answered"-style state badge to draw. `id` is the key the card reads
    /// and writes under: the host id for a note the host holds, or the draft's
    /// local key for a draft. `shownID` is the id the card draws above its
    /// editor, or `nil` for none — a draft draws its host id only once the host
    /// has created its note.
    private func noteCard(id: String, shownID: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let shownID { cardIDLine(shownID) }
            // Plain `Text(String)` binding, never Markdown or
            // `AttributedString` — the item's own rule, so quotes, `$`,
            // backticks and a newline all round-trip byte for byte.
            TextEditor(text: Binding(
                get: { model.noteDrafts[id] ?? "" },
                set: { model.editNote(id: id, text: $0) }
            ))
            .frameFont(.body)
            // A kept sent note's text is what the host delivered, and a note whose send
            // is in flight is locked until that send settles (see `canEditNote`).
            .disabled(!model.canEditNote(id: id))
            .frame(minHeight: 60, maxHeight: 140)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            if let error = model.sendErrors[id] {
                Text(error).frameFont(.caption).foregroundStyle(.red)
            }
            if let notice = model.sendNotices[id] {
                Text(notice).frameFont(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Delete") { noteIDPendingDelete = id }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.deletingIDs.contains(id) || model.sendingIDs.contains(id))
                Spacer()
                if model.canRetryCreate(id: id) {
                    Button("Retry") { model.retryCreate(id: id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!model.canSend(id: id))
                }
                Button("Send") { Task { await Self.sendCard(model, id: id, target: target, probedName: probedName) } }
                    // Disabled while the draft is empty or whitespace, so
                    // the operator never sends a request `slate-send` would
                    // itself refuse — the contract
                    // (platform/contracts/session-agent-api, this item's own
                    // body) has it strip and refuse an empty or whitespace
                    // answer the same way for a note. A kept row whose send set a
                    // notice is already sent, so its Send stays off, and its text is
                    // read-only (see `canEditNote`).
                    .disabled(!model.sendEnabled(id: id))
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator.opacity(0.5)))
    }
}
