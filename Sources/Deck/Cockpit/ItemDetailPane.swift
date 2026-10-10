import SwiftUI

/// The item detail pane: a Library item's full body and comment thread, read
/// to peruse. Humans do not maintain these items, so the pane offers no way to
/// resolve, comment on or edit one (the operator, 2026-09-19). The one write it carries
/// is the model control (`modelControl`): set or clear the model a queued
/// item will run on (the operator, 2026-09-23), sent to the Library under Deck's own
/// credential. Deck does not decide whether the change is permitted and
/// dispatches nothing; the Library answers, and a refusal is shown as it came.
///
/// OPENED TWO WAYS, RENDERED ONE WAY. A corrections-queue row tap or the
/// `Open` control on an epic, work-item, queue or proposal row
/// (`CockpitView.onSelectCorrection`) and a `deck-open:?origin=item&ref=…`
/// link (`ContentView.openViewer`'s `.item` branch) both land here, because
/// both name a Library item and the pane does not care which route found
/// it. The header shows the item's own title and product — read from
/// `LibraryClient.CorrectionDetail`, the one fetch this pane makes, rather
/// than from the caller's corrections queue — because a `deck-open:` link can
/// (and per its whole reason for existing, will) name an item filed against
/// a DIFFERENT product than whichever crew's queue happens to be on screen,
/// where a queue lookup would find nothing and show the bare id.
///
/// DOCUMENT-SHAPED, SO IT IS A WEB PANE (CLAUDE.md's boundary rule). A
/// correction's body and its comment thread are prose a person reads, the
/// same shape as `FileViewerPane`'s file content — not the scannable-list
/// shape `CockpitView` argues makes IT native.
///
/// RENDERED, NOT SHOWN AS SOURCE. A correction's body is Markdown — headings,
/// bold, fenced code, tables — so it is composed into one Markdown document
/// (`markdown(for:)`) and rendered through `session-view --render-file -`,
/// the same remote renderer `FileViewerPane` uses for a `.md` path
/// (`SessionAgent.renderFile(target:content:name:appearance:)`). A failed
/// render (the mini unreachable, Node missing) falls back to `page(for:
/// appearance:)`, the local generator that shows the body escaped in a
/// `<pre>` block — legible, not styled, but never a blank pane.
///
/// `FileViewerWebView` is reused verbatim for all three of its security
/// mechanisms — no JavaScript, `NetworkBlock`, and a navigation delegate that
/// cancels link activation, with `loadHTMLString(baseURL: nil)` for the
/// opaque origin — on both the rendered page and the fallback page.
///
/// COMPOSING ONE DOCUMENT OUT OF SEVERAL LIBRARY-CONTROLLED FIELDS IS ITS OWN
/// SEAM. `markdown(for:)` strips newlines from single-line fields (title,
/// meta, a comment's actor/kind/at) so none of them can inject a heading or
/// break the line they belong on, and closes any fenced code block a body or
/// comment leaves open (`closeUnbalancedFences`) so it cannot swallow the
/// sections composed after it. Embedded raw HTML is not a concern the way it
/// would be for an HTML template: `session-view`'s Markdown renderer
/// (`md-serial`) has no raw-HTML passthrough node and escapes all text and
/// attribute values in `toHTML`, confirmed by reading `render.js`'s `toHTML`/
/// `renderInline` — so a body or comment containing `<script>` renders as
/// inert escaped text, the same as the fallback page's `htmlEscape`.
///
/// The header is chrome, so it stays native SwiftUI above the web view.
///
/// THE SHELL IS STILL THE APPEARANCE AUTHORITY. `appearance` is resolved by
/// the caller and stamped into `data-theme` here, never read from
/// `prefers-color-scheme`.
struct ItemDetailPane: View {
    let id: String
    let target: SSHTarget
    let appearance: Appearance
    /// Closes the column and returns to the cockpit.
    let onClose: () -> Void
    /// Opens another Library item in this same pane — the found-during
    /// epic's title on an item, and a found-during item's own row on an
    /// epic. Reuses `target`: `found_during` names an epic in the same
    /// product as the item carrying it, so no second host lookup is needed.
    let onOpenItem: (String) -> Void

    @StateObject private var model = ItemDetailModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            foundDuringSection
            foundDuringItemsSection
            if LibraryClient.canSetModel(state: model.detail?.state) {
                Divider()
                modelControl
            }
            Divider()
            FileViewerWebView(html: model.html)
        }
        // CONTAINER-LEVEL, THE SAME IDIOM `EditorPane` ALREADY USES —
        // makes the header's title/product selectable
        // (issue_01M1HQXGN5QVYGQ6FAPX4KHS67). Unlike
        // `CockpitView`, nothing here needs an opt-out: this pane opens
        // FROM a cockpit row's tap, but has none of its own — the header
        // has no gesture, and `FileViewerWebView` is a wrapped
        // `NSViewRepresentable` that `.textSelection` has no effect on
        // either way (its own document text is already selectable web
        // content, a separate mechanism).
        .textSelection(.enabled)
        .task(id: CorrectionLoadIdentity(id: id, target: target)) {
            await model.load(id: id, target: target, appearance: appearance)
        }
        .onChange(of: appearance) { _, new in
            Task { await model.reRender(appearance: new) }
        }
    }

    /// The item's own identity, and the way back to the cockpit.
    ///
    /// **IT READS THE MODEL, NOT THE QUEUE.** The version this replaced looked
    /// the title up in `cockpitModel.queue` and fell back to the raw id — which
    /// works only for an item in the selected crew's own corrections queue, and
    /// shows a bare `issue_01M0…` for anything a `deck-open:` link brought in
    /// from another product. `GET /items/{id}` already returns the title and
    /// the product; the header now uses them, so there is ONE source of truth
    /// for what this item is.
    ///
    /// **The product is drawn beside the title** because an item can now
    /// arrive from any product the token can see, and "whose project is this
    /// filed against" is the question a cross-product link raises (the
    /// operator, 2026-08-26). It draws nothing when the Library did not carry one,
    /// rather than a placeholder.
    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(model.detail?.title ?? id)
                .frameFont(.emphasis)
                .lineLimit(2)
            if let product = model.detail?.product, !product.isEmpty {
                Text(product)
                    .frameFont(.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.isLoading { ProgressView().controlSize(.mini) }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close and return to the cockpit")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The epic whose work turned this item up, when `found_during` is set —
    /// native chrome, not part of the rendered document, because clicking it
    /// has to open that epic IN THIS PANE (`onOpenItem`), and the web view
    /// below has no route back to native navigation (`FileViewerWebView`'s
    /// navigation delegate sends every link-activated click to the user's
    /// browser instead).
    ///
    /// Shows the epic's title once `ItemDetailModel.load` resolves it, and
    /// the raw id until it does or if it never resolves — "an id that
    /// doesn't resolve shows the id rather than nothing."
    @ViewBuilder
    private var foundDuringSection: some View {
        if let epicId = model.detail?.foundDuring, !epicId.isEmpty {
            Divider()
            HStack(spacing: 4) {
                Text("Found during:")
                    .frameFont(.label)
                    .foregroundStyle(.secondary)
                Button(model.foundDuringTitle ?? epicId) {
                    onOpenItem(epicId)
                }
                .buttonStyle(.link)
                .frameFont(.label)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    /// The open items whose `found_during` names this epic, drawn only when
    /// the loaded item is itself an epic. Same native-chrome reasoning as
    /// `foundDuringSection` above — each row opens in this pane via
    /// `onOpenItem`.
    ///
    /// Always draws once the item is known to be an epic: a count when the
    /// fetch has resolved and found open items, a plain line when it
    /// resolved to none (which also covers a Library that does not serve
    /// `found_during` at all — the defensive check in
    /// `LibraryClient.decodeFoundDuringItems` drops everything it cannot
    /// confirm, so an unsupporting Library reads the same as "none found"
    /// rather than drawing something wrong).
    @ViewBuilder
    private var foundDuringItemsSection: some View {
        if model.detail?.type == "epic" {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                switch model.foundDuringItemsState {
                case .none:
                    EmptyView()
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Loading items found during this epic…")
                            .frameFont(.label)
                            .foregroundStyle(.secondary)
                    }
                case .loaded(let items):
                    let openItems = LibraryClient.openFoundDuringItems(items)
                    Text(openItems.isEmpty
                         ? "No items found during this epic."
                         : "\(openItems.count) item\(openItems.count == 1 ? "" : "s") found during this epic:")
                        .frameFont(.label)
                        .foregroundStyle(.secondary)
                    ForEach(openItems) { item in
                        Button(item.title) { onOpenItem(item.id) }
                            .buttonStyle(.link)
                            .frameFont(.label)
                    }
                case .failed(let message):
                    Text("Could not reach items found during this epic: \(message)")
                        .frameFont(.label)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

/// The model control, native chrome above the document. It is offered only
/// while `LibraryClient.canSetModel` says the item is not terminal.
///
/// THE PICKER OFFERS ONLY WHAT THE HOST SERVES — no free-text fallback. A
/// free-text field let the operator type `claude-opus` on 2026-09-28 and have the
/// Bosun refuse it at dispatch with a name the Library had already stored;
/// `platform/contracts/agentctl-models` exists to close exactly that
/// entry line, and a fallback here would reopen it the moment the host is
/// slow or unreachable — precisely when a picker would otherwise be tempted
/// to fall back.
extension ItemDetailPane {
    @ViewBuilder
    var modelControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(ItemDetailPane.modelHeaderText(choice: model.detail?.modelChoice, modelList: model.modelList))
                    .frameFont(.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if model.isWritingModel { ProgressView().controlSize(.mini) }
                Button(model.isEditingModel ? "Cancel" : "Set model…") {
                    model.toggleEditing()
                }
                .buttonStyle(.link)
                .frameFont(.label)
                .disabled(model.isWritingModel)
            }
            if model.isEditingModel {
                modelPicker
                TextField("Reason (optional)", text: $model.draftReason)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button("Set") {
                        Task { await model.setModel(model.draftModel, reason: model.draftReason) }
                    }
                    .disabled(!model.canSubmitModel)
                    Button("Clear") {
                        Task { await model.clearModel(reason: model.draftReason) }
                    }
                    .disabled(model.isWritingModel || model.detail?.modelChoice == nil)
                }
                .frameFont(.label)
                Text("Affects the next dispatch of this item. A run already dispatched keeps its model.")
                    .frameFont(.label)
                    .foregroundStyle(.secondary)
            }
            if let refusal = model.modelWriteRefusal {
                Text(refusal)
                    .frameFont(.label)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The editor's model row: a loading spinner while the fetch is in
    /// flight, the picker once the host answers with a usable list, or a
    /// refusal message with no control to fall back to. Entries are drawn
    /// in the order `AgentctlModels.decode` returned — never sorted, per
    /// the contract.
    @ViewBuilder
    private var modelPicker: some View {
        switch model.modelList {
        case .models(let entries) where !entries.isEmpty:
            Picker("Model", selection: $model.draftModel) {
                ForEach(entries, id: \.model) { entry in
                    Text(entry.label).tag(entry.model)
                }
            }
            .labelsHidden()
        case .models:
            Text("The host serves no models.")
                .frameFont(.label)
                .foregroundStyle(.red)
        case .unavailable:
            Text("Model list unavailable — the host could not be reached or returned an answer Deck cannot read.")
                .frameFont(.label)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading models…")
                    .frameFont(.label)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The header's line for the model control: "No model set", the stored
    /// choice, "Model choice unreadable" for a malformed record, or the
    /// choice suffixed " (not served)" when the host's own list
    /// (`platform/contracts/agentctl-models`) does not carry it. `nil`
    /// list — before the editor has ever been opened, or while the host is
    /// unreachable — shows the bare choice rather than a guess at whether
    /// it is still servable.
    static func modelHeaderText(choice: LibraryClient.ModelChoice?, modelList: AgentctlModels.Outcome?) -> String {
        guard let choice else { return "No model set" }
        if choice.isMalformed { return "Model choice unreadable" }
        let value = choice.model ?? ""
        if case .models(let entries) = modelList, !entries.contains(where: { $0.model == value }) {
            return "\(value) (not served)"
        }
        return value
    }
}

private struct CorrectionLoadIdentity: Equatable {
    let id: String
    let target: SSHTarget
}

// MARK: - HTML generation

extension ItemDetailPane {
    /// Composes a correction's detail — title, meta line, then its
    /// content and comment thread — into ONE Markdown document, the input
    /// `SessionAgent.renderFile(target:content:name:appearance:)` renders.
    ///
    /// AN EPIC OPENS ON ITS SPECIFICATION AND DEFINITION OF DONE, NOT ITS
    /// BODY. The operator, 2026-09-22: "can we somehow move the spec and
    /// definition of done to the top of every epic? All the narration that
    /// accompanies each epic is not useful and it takes up a ton of space."
    /// So when either field is non-empty, the order is title, meta, "##
    /// Specification", "## Done when", then the body folded under a closed
    /// "Background" disclosure — the narration the operator is describing. An item
    /// with neither field (every correction, most work items) keeps the
    /// order it always read — title, meta, body, outcome, comments — with
    /// no Background heading, because for those the body IS the content. An
    /// epic with an empty body gets no Background disclosure either; there
    /// is nothing to fold.
    ///
    /// THE FOLD IS A POST-RENDER SUBSTITUTION, NOT RAW HTML IN THE MARKDOWN.
    /// `session-view`'s renderer escapes raw HTML by design (confirmed
    /// 2026-09-22: piping `<details><summary>Background</summary>…` through
    /// `session-view --render-file -` came back as `&lt;details&gt;…`
    /// inside a `<p>`), so a literal `<details>` tag here would render as
    /// inert text rather than fold anything. `nonce` — a per-render UUID
    /// `ItemDetailModel.render` generates — lets `backgroundOpenMarker(_:)`
    /// and `backgroundCloseMarker(_:)` bracket the body with two plain-text
    /// paragraphs that nothing in a Library-controlled body or comment can
    /// forge, since it would need this exact render's nonce. Once
    /// `session-view` has rendered the Markdown, `foldBackground(html:
    /// nonce:)` turns those two paragraphs into the real `<details>` and
    /// `</details>`.
    ///
    /// Every section is Library-controlled text, so two guards apply before
    /// a piece is embedded:
    /// - `singleLine` on anything meant to occupy one line (title, each meta
    ///   part, a comment's actor/kind/at) — a stray newline in a "claimed by"
    ///   value could otherwise open a new paragraph or heading mid-line.
    /// - `closeUnbalancedFences` on free-form prose (the body, the
    ///   specification, the definition of done, the outcome note, a
    ///   comment's body) — an odd number of code-fence delimiters would
    ///   otherwise leave a fence open that swallows every section composed
    ///   after it, including the "## Comments" heading and the comments
    ///   themselves, into one inert code block.
    ///
    /// Sections join on a blank line, which also keeps a body ending in
    /// plain text from being read as a Setext heading by whatever markup
    /// (a "## Comments" heading, an "---" thematic break) follows it —
    /// Setext heading detection requires no blank line between the text and
    /// its underline.
    nonisolated static func markdown(
        for detail: LibraryClient.CorrectionDetail, nonce: String,
        now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        var sections: [String] = ["# \(singleLine(detail.title ?? detail.id))"]

        var metaParts: [String] = []
        if let type = detail.type { metaParts.append(singleLine(type)) }
        if let state = detail.state { metaParts.append(singleLine(state)) }
        if let severity = detail.severity { metaParts.append("severity: \(singleLine(severity))") }
        if let needs = detail.needs { metaParts.append("needs: \(singleLine(needs))") }
        if let claimedBy = detail.claimedBy {
            metaParts.append(singleLine(
                LibraryClient.claimMetaFragment(claimedBy: claimedBy, expired: detail.claimExpired)))
        }
        if !metaParts.isEmpty {
            sections.append(metaParts.joined(separator: " · "))
        }

        if let choice = detail.modelChoice {
            sections.append("## Model")
            sections.append(LibraryClient.modelChoiceLines(choice).map(singleLine).joined(separator: "\n\n"))
        }

        let specification = detail.specification.flatMap { $0.isEmpty ? nil : $0 }
        let definitionOfDone = detail.definitionOfDone.flatMap { $0.isEmpty ? nil : $0 }
        let body = detail.body.flatMap { $0.isEmpty ? nil : $0 }

        // An epic opens on its specification and definition of done, ahead of
        // the body — the operator, 2026-09-22: "move the spec and definition of done
        // to the top of every epic; the narration is not useful and takes up
        // a ton of space." Same fence guard as the body, since either can
        // open a fence it never closes. An item with neither (every
        // correction, most work items) gets no heading, and its body stays
        // right after the meta line, where it always read.
        if specification != nil || definitionOfDone != nil {
            if let specification {
                sections.append("## Specification")
                sections.append(closeUnbalancedFences(specification))
            }
            if let definitionOfDone {
                sections.append("## \(doneHeading)")
                sections.append(closeUnbalancedFences(definitionOfDone))
            }
            // The body follows, bracketed by the sentinel paragraphs
            // `foldBackground(html:nonce:)` turns into a closed "Background"
            // disclosure after the render — see the doc comment above. An
            // empty body has nothing to fold, so it gets no markers either.
            if let body {
                sections.append(backgroundOpenMarker(nonce))
                sections.append(closeUnbalancedFences(body))
                sections.append(backgroundCloseMarker(nonce))
            }
        } else if let body {
            sections.append(closeUnbalancedFences(body))
        }

        if let note = detail.outcomeNote, !note.isEmpty {
            sections.append("**Outcome:** \(closeUnbalancedFences(note))")
        }

        sections.append("## Comments")
        if detail.comments.isEmpty {
            sections.append("_No comments yet._")
        } else {
            sections.append(contentsOf: detail.comments.map {
                "---\n\n" + commentMarkdown($0, now: now, timeZone: timeZone, locale: locale)
            })
        }

        return sections.joined(separator: "\n\n")
    }

    /// The Course entry calls this field `Done when:`; the pane uses the same
    /// words so a reader meets one name for it.
    private nonisolated static let doneHeading = "Done when"

    /// The paragraph `markdown(for:nonce:)` opens an epic's folded body
    /// with, and the one `foldBackground(html:nonce:)` looks for in the
    /// rendered HTML.
    nonisolated static func backgroundOpenMarker(_ nonce: String) -> String {
        "ITEMDETAIL-BACKGROUND-OPEN-\(nonce)"
    }

    /// The close counterpart to `backgroundOpenMarker(_:)`.
    nonisolated static func backgroundCloseMarker(_ nonce: String) -> String {
        "ITEMDETAIL-BACKGROUND-CLOSE-\(nonce)"
    }

    /// Turns the two sentinel paragraphs `markdown(for:nonce:)` places
    /// around an epic's body into a real `<details>`, once `session-view`
    /// has rendered the Markdown to HTML.
    ///
    /// A plain-text paragraph renders as `<p>…</p>` with no surrounding
    /// whitespace — confirmed 2026-09-22 by piping a marker paragraph
    /// through `session-view --render-file - --name probe.md` and reading
    /// the output — so that is the exact string this looks for.
    ///
    /// SUBSTITUTES ONLY WHEN BOTH MARKERS APPEAR EXACTLY ONCE. Anything else
    /// — a marker missing because the render came back some other way than
    /// expected, or a body that happens to contain the marker text under a
    /// DIFFERENT nonce, which cannot match this render's exact string —
    /// strips whatever marker text is present and returns the rest of the
    /// HTML untouched, so the body stays legible unfolded rather than
    /// emitting an unbalanced `<details>` or a stray `</details>` with no
    /// opener.
    nonisolated static func foldBackground(html: String, nonce: String) -> String {
        let open = "<p>\(backgroundOpenMarker(nonce))</p>"
        let close = "<p>\(backgroundCloseMarker(nonce))</p>"
        let openCount = html.components(separatedBy: open).count - 1
        let closeCount = html.components(separatedBy: close).count - 1
        guard openCount == 1, closeCount == 1 else {
            return html
                .replacingOccurrences(of: open, with: "")
                .replacingOccurrences(of: close, with: "")
        }
        return html
            .replacingOccurrences(
                of: open, with: "<details class=\"background\"><summary>Background</summary>")
            .replacingOccurrences(of: close, with: "</details>")
    }

    private nonisolated static func commentMarkdown(
        _ comment: LibraryClient.CorrectionComment, now: Date, timeZone: TimeZone, locale: Locale
    ) -> String {
        let at = ServedTimestamp.localLabel(comment.at ?? "", now: now, timeZone: timeZone, locale: locale)
        let meta = "**\(singleLine(comment.actor ?? "unknown"))"
            + " · \(singleLine(comment.kind ?? "note"))"
            + " · \(singleLine(at))**"
        guard let body = comment.body, !body.isEmpty else { return meta }
        return meta + "\n\n" + closeUnbalancedFences(body)
    }

    /// Collapses every line break to a space, for a field meant to occupy
    /// exactly one line of the composed document (a heading, a meta value).
    /// A field this touches is never meant to carry Markdown structure of its
    /// own, so collapsing rather than escaping is the right degradation.
    ///
    /// NOT `private` — `ReviewRecordsPane` reuses this verbatim rather than
    /// hand-copying the same single-line guard a second time, the same
    /// reasoning `FileViewerWebView`'s own doc gives for staying shared.
    nonisolated static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// A line's leading fence run — 3+ backticks or tildes, after up to 3
    /// leading spaces of indent per CommonMark (4+ leading spaces makes it an
    /// indented code block, never a fence). Returns the fence character, the
    /// run's length, and whatever follows it on the line, or `nil` if the
    /// line opens no fence at all.
    private nonisolated static func fenceRun(_ line: some StringProtocol) -> (char: Character, length: Int, rest: Substring)? {
        var rest = Substring(line)
        var indent = 0
        while indent < 3, rest.first == " " {
            rest = rest.dropFirst()
            indent += 1
        }
        guard let char = rest.first, char == "`" || char == "~" else { return nil }
        var length = 0
        while rest.first == char {
            rest = rest.dropFirst()
            length += 1
        }
        guard length >= 3 else { return nil }
        return (char, length, rest)
    }

    /// Appends a closing fence when `text` leaves a fenced code block open at
    /// its end, so a section that opens one and never closes it cannot run
    /// past its own boundary and swallow the sections composed after it.
    ///
    /// Tracks fence PAIRS, not fence-looking LINE COUNT — CommonMark closes a
    /// fence only with the SAME character and a run AT LEAST AS LONG as its
    /// opener; anything shorter, or a different character, is content inside
    /// the still-open fence. A line-parity count gets both directions wrong:
    /// an unclosed 4-backtick fence followed by a 3-backtick line reads as
    /// "2, even" and is left untouched (the swallow this function exists to
    /// prevent), and a genuinely closed 4-backtick fence wrapping a literal
    /// 3-backtick line reads as "3, odd" and gets a spurious closer appended,
    /// which itself opens a new, unpaired fence.
    /// NOT `private` — `ReviewRecordsPane` reuses this verbatim, same
    /// reasoning as `singleLine`'s doc above.
    nonisolated static func closeUnbalancedFences(_ text: String) -> String {
        var open: (char: Character, length: Int)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (char, length, rest) = fenceRun(line) else { continue }
            if let current = open {
                guard char == current.char, length >= current.length,
                      rest.allSatisfy({ $0 == " " || $0 == "\t" }) else { continue }
                open = nil
            } else {
                open = (char, length)
            }
        }
        guard let open else { return text }
        return text + "\n" + String(repeating: open.char, count: open.length) + "\n"
    }

    /// Renders a correction's detail as a self-contained page, the same
    /// shape `FileViewerPane.page(for:data:appearance:)` produces for a file.
    /// Every piece of Library-sourced text is HTML-escaped before embedding.
    ///
    /// SAME ORDER AS `markdown(for:nonce:)`, FOR THE SAME REASON (the operator,
    /// 2026-09-22, quoted there): title, meta, Specification, Done when,
    /// then the body — behind a real `<details>`/`<summary>` when an epic
    /// has a specification or a definition of done, since this path builds
    /// HTML directly and needs no marker workaround to fold it; plain
    /// `<pre>` otherwise, exactly as before. An empty body gets no
    /// `<details>` either.
    ///
    /// THE FALLBACK PATH. `ItemDetailModel` renders through
    /// `markdown(for:nonce:)` and `SessionAgent.renderFile` first; this is
    /// what a failed remote render (the mini unreachable, Node missing)
    /// falls back to, so it stays legible even unstyled rather than showing
    /// nothing.
    nonisolated static func page(
        for detail: LibraryClient.CorrectionDetail, appearance: Appearance,
        now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        let theme = appearance == .dark ? "dark" : "light"
        let title = detail.title ?? detail.id
        var metaParts: [String] = []
        if let type = detail.type { metaParts.append(type) }
        if let state = detail.state { metaParts.append(state) }
        if let severity = detail.severity { metaParts.append("severity: \(severity)") }
        if let needs = detail.needs { metaParts.append("needs: \(needs)") }
        if let claimedBy = detail.claimedBy {
            metaParts.append(LibraryClient.claimMetaFragment(claimedBy: claimedBy, expired: detail.claimExpired))
        }
        let meta = metaParts.joined(separator: " · ")
        let outcomeSection = detail.outcomeNote.map {
            "<div class=\"outcome\"><strong>Outcome:</strong> \(FileViewerPane.htmlEscape($0))</div>"
        } ?? ""
        let commentsHTML = detail.comments
            .map { commentHTML($0, now: now, timeZone: timeZone, locale: locale) }
            .joined()
        func extraSection(_ heading: String, _ text: String?) -> String {
            guard let text, !text.isEmpty else { return "" }
            return "<h3>\(FileViewerPane.htmlEscape(heading))</h3>\n<pre>\(FileViewerPane.htmlEscape(text))</pre>"
        }
        let specificationSection = extraSection("Specification", detail.specification)
        let doneSection = extraSection(doneHeading, detail.definitionOfDone)
        let modelSection = detail.modelChoice.map { choice in
            "<h3>Model</h3>\n" + LibraryClient.modelChoiceLines(choice)
                .map { "<div>\(FileViewerPane.htmlEscape($0))</div>" }.joined(separator: "\n")
        } ?? ""
        let hasSpecOrDone = !(detail.specification ?? "").isEmpty || !(detail.definitionOfDone ?? "").isEmpty
        let body = detail.body ?? ""
        let bodySection: String
        if hasSpecOrDone {
            bodySection = body.isEmpty ? "" : """
                <details class="background"><summary>Background</summary>
                <pre>\(FileViewerPane.htmlEscape(body))</pre>
                </details>
                """
        } else {
            bodySection = "<pre>\(FileViewerPane.htmlEscape(body))</pre>"
        }
        return """
        <!DOCTYPE html>
        <html data-theme="\(theme)">
        <head><meta charset="UTF-8">\(viewerSharedStyle)\(correctionStyle)</head>
        <body>
        <div class="filename">\(FileViewerPane.htmlEscape(detail.id))</div>
        <h2>\(FileViewerPane.htmlEscape(title))</h2>
        <div class="muted">\(FileViewerPane.htmlEscape(meta))</div>
        \(modelSection)
        \(specificationSection)
        \(doneSection)
        \(bodySection)
        \(outcomeSection)
        <h3>Comments</h3>
        \(commentsHTML.isEmpty ? "<p class=\"muted\">No comments yet.</p>" : commentsHTML)
        </body>
        </html>
        """
    }

    private nonisolated static func commentHTML(
        _ comment: LibraryClient.CorrectionComment, now: Date, timeZone: TimeZone, locale: Locale
    ) -> String {
        let actor = FileViewerPane.htmlEscape(comment.actor ?? "unknown")
        let kind = FileViewerPane.htmlEscape(comment.kind ?? "note")
        let at = FileViewerPane.htmlEscape(
            ServedTimestamp.localLabel(comment.at ?? "", now: now, timeZone: timeZone, locale: locale))
        let body = FileViewerPane.htmlEscape(comment.body ?? "")
        return """
        <div class="comment">
          <div class="comment-meta">\(actor) · \(kind) · \(at)</div>
          <div class="comment-body">\(body)</div>
        </div>
        """
    }

    /// Small additions to `viewerSharedStyle`'s existing tokens — no new
    /// colors, only layout for the pieces the file viewer never needed
    /// (a heading, a comment thread, the epic's folded body).
    private nonisolated static let correctionStyle = """
        <style>
        h2{font-size:15px;margin:4px 0}
        h3,summary{font-size:11px;margin:16px 0 6px;color:var(--fg2);text-transform:uppercase;letter-spacing:0.04em}
        summary{cursor:pointer}
        .outcome{margin-top:10px;font-size:12px;color:var(--fg2)}
        .comment{margin-bottom:10px;padding-bottom:8px;border-bottom:1px solid var(--border)}
        .comment-meta{font-size:11px;color:var(--fg2);margin-bottom:2px}
        .comment-body{font-size:13px;white-space:pre-wrap}
        </style>
        """
}

// MARK: - Model

/// Drives one `ItemDetailPane`: the read of one item and its render.
@MainActor
final class ItemDetailModel: ObservableObject {
    @Published var html = FileViewerPane.loadingPage(appearance: .light)
    @Published private(set) var detail: LibraryClient.CorrectionDetail?
    @Published private(set) var isLoading = false
    /// The model write in flight, and the Library's words for the last one it
    /// refused. Cleared when the next write starts.
    @Published private(set) var isWritingModel = false
    @Published private(set) var modelWriteRefusal: String?

    /// The found-during epic's own title, resolved by a second fetch once
    /// `detail.foundDuring` is known. `nil` until that fetch resolves (or
    /// fails, or there is nothing to resolve) — `foundDuringSection` falls
    /// back to the raw id while this is `nil`, so the row never shows
    /// nothing.
    @Published private(set) var foundDuringTitle: String?

    /// The items found during this epic, drawn only when the loaded item is
    /// itself an epic.
    enum FoundDuringItemsState: Equatable {
        case none
        case loading
        case loaded([LibraryClient.FoundDuringItem])
        case failed(String)
    }
    @Published private(set) var foundDuringItemsState: FoundDuringItemsState = .none
    /// The two secondary fetches `load` kicks off, held so a test can await
    /// them — same reasoning as `modelListFetchTask`: each runs unstructured
    /// off of `load`'s own `Task`, so nothing else marks when it has settled.
    private(set) var foundDuringTitleFetchTask: Task<Void, Never>?
    private(set) var foundDuringItemsFetchTask: Task<Void, Never>?

    /// The model control's draft. It lives here rather than in the view's
    /// `@State` because the pane is reused when another item opens, and
    /// `@State` survived that switch: a draft typed for item A was posted to
    /// item B by the next Set (deck-reviewer, round 1 on #280). `load`
    /// resets all three, so a draft only ever belongs to the item it was
    /// typed for.
    @Published private(set) var isEditingModel = false
    @Published var draftModel = ""
    @Published var draftReason = ""

    /// The host's own list of models a dispatch will accept
    /// (`platform/contracts/agentctl-models`) — what the picker offers and
    /// what the header checks a stored choice against. `nil` until the
    /// editor has been opened at least once for the current item; reset on
    /// every `load`, since the pane's `target` can change between items
    /// (a `deck-open:` link can bring one in from a different host).
    @Published private(set) var modelList: AgentctlModels.Outcome?
    /// Guards against firing a second fetch while the first is still in
    /// flight — a cancel-and-reopen of the editor before it resolves would
    /// otherwise start a duplicate.
    private var isLoadingModels = false

    /// Whether Set may be pressed. No free-text fallback exists: an
    /// unavailable or empty list means there is nothing to Set, per the
    /// contract, whatever `draftModel` happens to hold.
    var canSubmitModel: Bool {
        guard !isWritingModel, case .models(let entries) = modelList else { return false }
        return entries.contains { $0.model == draftModel }
    }

    var fetchModels: @Sendable (SSHTarget) -> AgentctlModels.Outcome = { target in
        AgentctlModels.fetch(target: target)
    }

    /// The fetch `refreshModelListIfNeeded` kicks off, held so a test can
    /// await it — `toggleEditing` itself is synchronous, so this is the only
    /// handle onto when the fetch has actually settled.
    private(set) var modelListFetchTask: Task<Void, Never>?

    func toggleEditing() {
        isEditingModel.toggle()
        if isEditingModel {
            draftModel = detail?.modelChoice?.model ?? ""
            draftReason = ""
            refreshModelListIfNeeded()
        }
    }

    /// Fetches the host's model list the first time the editor opens for
    /// this item. Once it resolves, `draftModel` is moved onto a model Set
    /// can actually dispatch when the stored choice (or an empty draft) is
    /// not one of them — the picker must never open pointed at a value Set
    /// cannot submit.
    private func refreshModelListIfNeeded() {
        guard modelList == nil, !isLoadingModels, let target = cachedTarget else { return }
        let id = cachedId
        isLoadingModels = true
        let fetch = fetchModels
        modelListFetchTask = Task {
            let outcome = await Task.detached { fetch(target) }.value
            guard cachedId == id else { return }
            isLoadingModels = false
            modelList = outcome
            if case .models(let entries) = outcome, !entries.isEmpty,
               !entries.contains(where: { $0.model == draftModel }) {
                draftModel = entries[0].model
            }
        }
    }

    /// The reads and the write, stored so a test substitutes fakes and
    /// never reaches ssh (the seam `CockpitModel.approveEpic` uses).
    var fetchDetail: @Sendable (SSHTarget, String) throws -> LibraryClient.CorrectionDetail = { target, id in
        try LibraryClient.fetchCorrection(target: target, id: id)
    }
    var writeModel: @Sendable (SSHTarget, String, String?, String?, String) throws -> Void = {
        target, id, model, reason, actingHuman in
        try LibraryClient.setItemModel(target: target, itemId: id, model: model, reason: reason,
                                       actingHuman: actingHuman)
    }
    var renderDetail: @Sendable (LibraryClient.CorrectionDetail, SSHTarget, Appearance) async -> String = {
        detail, target, appearance in
        await ItemDetailModel.render(detail, target: target, appearance: appearance)
    }
    var fetchFoundDuringItems: @Sendable (SSHTarget, String) throws -> [LibraryClient.FoundDuringItem] = {
        target, epicId in
        try LibraryClient.fetchFoundDuringItems(target: target, epicId: epicId)
    }

    private var cachedId: String?
    private var cachedTarget: SSHTarget?
    private var cachedAppearance: Appearance = .light

    func load(id: String, target: SSHTarget, appearance: Appearance) async {
        cachedId = id
        cachedTarget = target
        cachedAppearance = appearance
        modelWriteRefusal = nil
        isEditingModel = false
        draftModel = ""
        draftReason = ""
        // The pane's `target` can differ between items (a `deck-open:` link
        // can bring one in from a different host), so a list fetched for
        // the old item is not necessarily valid for the new one.
        modelList = nil
        isLoadingModels = false
        // Dropped before the fetch, so nothing judges the new item by the
        // old one's state or model choice while it loads.
        detail = nil
        isLoading = true
        html = FileViewerPane.loadingPage(appearance: appearance)
        // Belongs to the old item, same reasoning as `modelList` above — a
        // stale title or item list must not be shown under the new one even
        // for the instant before its own fetch resolves.
        foundDuringTitle = nil
        foundDuringItemsState = .none
        // `.task(id:)` cancels this load when another item opens, but a
        // detached fetch does not stop on cancellation, so it can return
        // after the newer load has finished. Once `cachedId` names another
        // item, this load draws nothing: an old item under a live model
        // control would send Set and Clear to one item while showing another
        // (deck-reviewer, round 2 on #280).
        let read = fetchDetail
        do {
            let fetched = try await Task.detached { try read(target, id) }.value
            guard cachedId == id else { return }
            let page = await renderDetail(fetched, target, appearance)
            guard cachedId == id else { return }
            detail = fetched
            html = page
            loadFoundDuringTitleIfNeeded(fetched, id: id, target: target)
            loadFoundDuringItemsIfNeeded(fetched, id: id, target: target)
        } catch {
            guard cachedId == id else { return }
            detail = nil
            html = FileViewerPane.errorPage(
                "Could not reach this item: \(ItemDetailModel.describe(error))", appearance: appearance)
        }
        isLoading = false
    }

    /// Resolves the found-during epic's title for `foundDuringSection`, when
    /// `detail.foundDuring` is set. Runs after the item's own render rather
    /// than blocking it — the title is only for the clickable row, not the
    /// rendered document, so the pane shows everything else at once and
    /// swaps the row's label in once this resolves. Leaves `foundDuringTitle`
    /// `nil` on any failure (a 404, a refusal, an unreachable host): the row
    /// still shows the raw id, never nothing.
    private func loadFoundDuringTitleIfNeeded(
        _ detail: LibraryClient.CorrectionDetail, id: String, target: SSHTarget
    ) {
        guard let epicId = detail.foundDuring, !epicId.isEmpty else { return }
        let read = fetchDetail
        foundDuringTitleFetchTask = Task {
            let epic = try? await Task.detached { try read(target, epicId) }.value
            guard cachedId == id else { return }
            let title = epic?.title
            foundDuringTitle = (title?.isEmpty == false) ? title : nil
        }
    }

    /// Fetches the items found during this epic, when the loaded item is
    /// itself an epic — `foundDuringItemsSection`'s data. Runs after the
    /// item's own render, same reasoning as `loadFoundDuringTitleIfNeeded`.
    private func loadFoundDuringItemsIfNeeded(
        _ detail: LibraryClient.CorrectionDetail, id: String, target: SSHTarget
    ) {
        guard detail.type == "epic" else { return }
        foundDuringItemsState = .loading
        let fetch = fetchFoundDuringItems
        foundDuringItemsFetchTask = Task {
            do {
                let items = try await Task.detached { try fetch(target, id) }.value
                guard cachedId == id else { return }
                foundDuringItemsState = .loaded(items)
            } catch {
                guard cachedId == id else { return }
                foundDuringItemsState = .failed(ItemDetailModel.describe(error))
            }
        }
    }

    /// When the initial fetch failed, `detail` is nil and `html` is showing
    /// `FileViewerPane.errorPage` — an appearance switch retries the fetch
    /// rather than replacing that error with the loading page forever, which
    /// is what a bare `guard let detail` here used to do: it never runs
    /// again because nothing else re-triggers `load`, so the pane is stuck
    /// on "loading" until the operator closes and reopens it.
    func reRender(appearance: Appearance) async {
        guard let detail else {
            if let id = cachedId, let target = cachedTarget {
                await load(id: id, target: target, appearance: appearance)
            } else {
                html = FileViewerPane.loadingPage(appearance: appearance)
            }
            return
        }
        guard let target = cachedTarget else {
            html = FileViewerPane.loadingPage(appearance: appearance)
            return
        }
        cachedAppearance = appearance
        let renderedId = cachedId
        let page = await renderDetail(detail, target, appearance)
        guard cachedId == renderedId else { return }
        html = page
    }

    /// Sets the loaded item's model. `acting_human` is `DeckOperator.label()`
    /// run through `LibraryClient.validateActingHuman` inside the write, the
    /// same source Approve sends; it says a person pressed a button at this
    /// machine and is not a verified identity.
    func setModel(_ model: String, reason: String?) async {
        await writeModelChoice(model, reason: reason)
    }

    /// Clears the loaded item's model choice: `model` goes as JSON null.
    func clearModel(reason: String?) async {
        await writeModelChoice(nil, reason: reason)
    }

    private func writeModelChoice(_ chosen: String?, reason: String?) async {
        guard let id = cachedId, let target = cachedTarget, !isWritingModel else { return }
        modelWriteRefusal = nil
        // The pane hides the control on a terminal item; this is the same
        // rule for a caller that reaches the model another way. The Library
        // would answer 409, and saying so first spares the round trip.
        guard LibraryClient.canSetModel(state: detail?.state) else {
            modelWriteRefusal = "This item is closed, so its model cannot be changed."
            return
        }
        isWritingModel = true
        defer { isWritingModel = false }
        let write = writeModel
        let actingHuman = DeckOperator.label()
        // Each await below can return after another item has opened in this
        // pane. From then on the pane belongs to that item, so nothing about
        // this write is drawn over it.
        do {
            try await Task.detached { try write(target, id, chosen, reason, actingHuman) }.value
        } catch {
            if cachedId == id { modelWriteRefusal = LibraryClient.modelChoiceRefusalMessage(error) }
            return
        }
        guard cachedId == id else { return }
        isEditingModel = false
        // Show what the Library now holds, not what was sent.
        let read = fetchDetail
        do {
            let fetched = try await Task.detached { try read(target, id) }.value
            guard cachedId == id else { return }
            let page = await renderDetail(fetched, target, cachedAppearance)
            guard cachedId == id else { return }
            detail = fetched
            html = page
        } catch {
            guard cachedId == id else { return }
            modelWriteRefusal = "The change was sent, but reading the item back failed: "
                + LibraryClient.modelChoiceRefusalMessage(error)
        }
    }

    /// Renders `detail` as one composed Markdown document through
    /// `session-view --render-file -`, falling back to the local
    /// `<pre>`-escaped page on any failure — an unreachable mini, Node
    /// missing, or a bridge error — so the pane always shows something
    /// legible rather than going blank on a render failure.
    ///
    /// Generates the nonce `markdown(for:nonce:)` brackets an epic's body
    /// with, fresh per render, and folds it into a real `<details>` once
    /// the mini's HTML comes back — see `markdown(for:nonce:)`'s doc
    /// comment for why the fold can't happen inside the Markdown itself.
    fileprivate static func render(_ detail: LibraryClient.CorrectionDetail,
                              target: SSHTarget, appearance: Appearance) async -> String {
        let nonce = UUID().uuidString
        let markdown = ItemDetailPane.markdown(for: detail, nonce: nonce)
        do {
            let rendered = try await Task.detached {
                try SessionAgent.renderFile(
                    target: target, content: markdown, name: detail.id, appearance: appearance)
            }.value
            return ItemDetailPane.foldBackground(html: rendered, nonce: nonce)
        } catch {
            return ItemDetailPane.page(for: detail, appearance: appearance)
        }
    }

    /// The text shown when the item fetch fails: the Library's own refusal
    /// message where its body carries one, rather than a generic "could not
    /// load". The pane makes no writes, so this only ever describes a failed
    /// read.
    private static func describe(_ error: Error) -> String {
        if case LibraryClient.FetchError.libraryRefused(let status, let body) = error {
            if let data = body.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["error"] as? String {
                return message
            }
            return "the Library refused (\(status)): \(body)"
        }
        if case LibraryClient.FetchError.invalidInput(let value) = error {
            return "that id is not usable: \(value)"
        }
        return "\(error)"
    }
}
