import SwiftUI

/// What the run pane draws for one Dispatched run, derived from the live run
/// list so the derivation is testable without a view.
struct RunDetail: Equatable {
    /// The instruction's state. Only `.text` carries text, and only ever the
    /// register's full copy: session-agent's `task` is cut near 500 characters
    /// and is never an input here.
    enum Instruction: Equatable {
        case text(String)
        /// The register has no `task` for this run: a private crew withholds
        /// it, or the `/runs` read failed. Deck cannot tell which.
        case withheld
    }

    static let withheldNotice = "Instruction withheld or unavailable"
    /// Deck can't tell a run that ended from one that belongs to a crew other
    /// than the selected one, so the notice names both.
    static let endedNotice = "This run isn't in the selected crew's list now. It has ended, or another crew is selected."

    let runId: String
    let agent: String?
    let modelLine: String?
    let instruction: Instruction
    /// True when the run is absent from the live list: it ended, or the rail
    /// has moved to another crew. The pane can't tell which.
    let hasEnded: Bool
    /// Epoch seconds, straight from `SessionState.AgentRun.startedAt`. Carried
    /// through `last` the same way `modelLine` is, so a run that leaves the
    /// list keeps its start time in the pane.
    let startedAt: Double?

    /// The `Started` fact's value: the full local date and time, with the
    /// elapsed runtime appended while the run is still listed. An ended run
    /// shows only the start time — Deck doesn't know when the run ended, so
    /// it can't compute a runtime for it. `nil` when the run carries no
    /// `startedAt` at all.
    func startedFactValue(now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let startedAt else { return nil }
        let label = CockpitView.agentRunStartFullLabel(startedAt, timeZone: timeZone, locale: locale)
        guard !hasEnded else { return label }
        let runtime = WorkingStrip.durationLabel(now.timeIntervalSince1970 - startedAt)
        return "\(label) · \(runtime)"
    }

    /// `runs` is the joined list (`RunModelMark.withModelSources`), so
    /// `fullTask` and the model qualifier are already on each run. Every
    /// field is sanitised here, never at the call site.
    ///
    /// **A RUN THAT LEAVES THE LIST KEEPS WHAT THE PANE LAST SAW.** `last` is
    /// the detail built while the run was still listed (ContentView keeps one
    /// per run id). When the run is absent, that detail draws with the ended
    /// notice, so the instruction stays readable at the moment someone looks
    /// back at it. Without `last`, the pane has never seen the run, and only
    /// then does it fall back to the withheld notice. deck-reviewer's round-1
    /// finding on #276: the pane blanked, and said "no longer in flight"
    /// when the rail had merely moved to another crew.
    static func make(runId: String, runs: [SessionState.AgentRun]?, last: RunDetail? = nil) -> RunDetail {
        let cleanId = CockpitView.sanitizedAgentField(runId)
        guard let run = runs?.first(where: { $0.runId == runId }) else {
            if let last {
                return RunDetail(runId: last.runId, agent: last.agent, modelLine: last.modelLine,
                                 instruction: last.instruction, hasEnded: true, startedAt: last.startedAt)
            }
            return RunDetail(runId: cleanId, agent: nil, modelLine: nil, instruction: .withheld,
                             hasEnded: true, startedAt: nil)
        }
        return present(run, cleanId: cleanId)
    }

    /// The cache `ContentView` keeps for `make(runId:runs:last:)`. Each listed
    /// run gets its current detail, `keeping`'s entry survives while its run is
    /// absent, and every other entry is dropped.
    static func remembering(_ runs: [SessionState.AgentRun]?, previous: [String: RunDetail],
                            keeping openRunId: String) -> [String: RunDetail] {
        var next: [String: RunDetail] = [:]
        if let kept = previous[openRunId] { next[openRunId] = kept }
        for run in runs ?? [] {
            guard let id = run.runId else { continue }
            next[id] = present(run, cleanId: CockpitView.sanitizedAgentField(id))
        }
        return next
    }

    private static func present(_ run: SessionState.AgentRun, cleanId: String) -> RunDetail {
        let instruction: Instruction
        if let full = run.fullTask, !full.isEmpty {
            instruction = .text(CockpitView.sanitizedInstruction(full))
        } else {
            instruction = .withheld
        }
        return RunDetail(
            runId: cleanId,
            agent: run.agent.map { CockpitView.sanitizedAgentField($0) },
            modelLine: CockpitView.agentRunModelLine(run),
            instruction: instruction,
            hasEnded: false,
            startedAt: run.startedAt)
    }
}

/// The pane a Dispatched row opens in the right column. Native, not a web
/// pane: the instruction is plain selectable text in a scroll view, with no
/// rendering step, so it sits on the chrome side of the boundary rule.
struct RunDetailPane: View {
    /// The ground the column draws this pane on, or `nil` when it draws on the
    /// system's own ground. Secondary text is solved against it, as the
    /// cockpit's secondary text is.
    @Environment(\.statusGround) private var statusGround
    private var secondaryInk: AnyShapeStyle { CockpitView.secondaryInkStyle(on: statusGround) }

    let detail: RunDetail
    /// The run's record of the documents it was given, read by
    /// `RunGivenDocumentsModel`.
    let given: RunGivenDocumentsModel.State
    /// The documents the run has fetched so far, read by
    /// `RunFetchedDocumentsModel`.
    let fetched: RunFetchedDocumentsModel.State
    /// Takes an id that `DeckOpenRef.validateKBId` has accepted, and opens it
    /// in the side pane, as a checkout row does.
    let onOpenDocument: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if detail.hasEnded {
                        Text(RunDetail.endedNotice)
                            .frameFont(.body).foregroundStyle(secondaryInk)
                    }
                    facts
                    section("Instruction") {
                        switch detail.instruction {
                        case .text(let text):
                            Text(text)
                                .frameFont(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .withheld:
                            Text(RunDetail.withheldNotice)
                                .frameFont(.body).foregroundStyle(secondaryInk)
                        }
                    }
                    section("Documents it was given") {
                        givenBody
                    }
                    section("Documents it has fetched") {
                        fetchedBody
                    }
                    if let searches = fetchedListing?.searches {
                        section("Searches it has made") {
                            searchesBody(searches, unreadable: fetchedListing?.unreadableSearches ?? 0)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(detail.agent ?? "Run").frameFont(.emphasis).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Close and return to the cockpit")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    /// `Grid` sizes the label column to its widest label at whatever font size
    /// `frameTypography` resolves to, rather than the fixed 44pt column this
    /// replaced: that width was measured at one base size and "Started" wrapped
    /// to two lines once the frame-size setting pushed caption text past it.
    var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 3) {
            if let agent = detail.agent { fact("Agent", agent) }
            fact("Run", detail.runId)
            if let model = detail.modelLine { fact("Model", model) }
            if let started = detail.startedFactValue(now: Date()) { fact("Started", started) }
        }
    }

    func fact(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).frameFont(.caption).foregroundStyle(secondaryInk).lineLimit(1)
            Text(value).frameFont(.body)
        }
    }

    /// The given section's body. An empty list is never drawn for a missing
    /// or unreadable record: each of those names its part instead.
    @ViewBuilder
    private var givenBody: some View {
        switch given {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reading the documents it was given…").frameFont(.body).foregroundStyle(secondaryInk)
            }
        case .failed(let sentence):
            Text(sentence).frameFont(.body).foregroundStyle(secondaryInk)
        case .loaded(.unavailable(let reason)):
            Text(reason.explanation).frameFont(.body).foregroundStyle(secondaryInk)
        case .loaded(.listed(let listing)):
            if listing.documents.isEmpty {
                Text("This run's record lists no documents.").frameFont(.body).foregroundStyle(secondaryInk)
            } else {
                ForEach(RunGivenDocuments.groups(listing.documents)) { group in
                    Text(group.title).frameFont(.caption).foregroundStyle(secondaryInk)
                    ForEach(group.documents) { document in
                        givenRow(document)
                    }
                }
            }
            if !listing.unmatchedNames.isEmpty {
                Text("The record names \(listing.unmatchedNames.joined(separator: ", ")), which no listed document carries.")
                    .frameFont(.caption).foregroundStyle(secondaryInk)
            }
        }
    }

    /// The fetched section's body. A failed read names the failure; an
    /// unavailable list names its reason; an empty list is drawn only for a
    /// read that succeeded and found nothing fetched.
    @ViewBuilder
    private var fetchedBody: some View {
        switch fetched {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reading the documents it has fetched…").frameFont(.body).foregroundStyle(secondaryInk)
            }
        case .failed(let sentence):
            Text(sentence).frameFont(.body).foregroundStyle(secondaryInk)
        case .loaded(.unavailable(let reason)):
            Text(reason.explanation).frameFont(.body).foregroundStyle(secondaryInk)
        case .loaded(.listed(let listing)):
            if listing.documents.isEmpty && listing.unreadableDocuments == 0 {
                Text("No documents fetched so far.").frameFont(.body).foregroundStyle(secondaryInk)
            }
            ForEach(listing.documents) { document in
                fetchedRow(document)
            }
            if listing.unreadableDocuments > 0 {
                Text(listing.unreadableDocuments == 1
                     ? "1 document could not be read."
                     : "\(listing.unreadableDocuments) documents could not be read.")
                    .frameFont(.caption).foregroundStyle(secondaryInk)
            }
        }
    }

    /// The listing when the fetched read succeeded, else nil.
    private var fetchedListing: RunFetchedDocuments.Listing? {
        guard case .loaded(.listed(let listing)) = fetched else { return nil }
        return listing
    }

    /// The searches section's body, drawn only when the answer carried a
    /// `searches` key. An empty list says none were made. Rows that could not
    /// be read are counted, never drawn.
    @ViewBuilder
    private func searchesBody(_ searches: [RunFetchedDocuments.Search], unreadable: Int) -> some View {
        if searches.isEmpty && unreadable == 0 {
            Text("No searches made so far.").frameFont(.body).foregroundStyle(secondaryInk)
        }
        ForEach(searches) { search in
            searchRow(search)
        }
        if unreadable > 0 {
            Text(unreadable == 1
                 ? "1 search could not be read."
                 : "\(unreadable) searches could not be read.")
                .frameFont(.caption).foregroundStyle(secondaryInk)
        }
    }

    /// One search, in call order: its kind, its query and the time it ran. A
    /// search is not a document, so the row has no tap target.
    private func searchRow(_ search: RunFetchedDocuments.Search) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(secondaryInk)
                .frame(width: 14, alignment: .center)
            Text(search.kindLabel).frameFont(.caption).foregroundStyle(secondaryInk)
            Text("\u{201C}\(search.query)\u{201D}")
                .frameFont(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            if let time = search.searchedLabel(now: Date()) {
                Text(time).frameFont(.caption).foregroundStyle(secondaryInk)
            }
        }
        .padding(.leading, 14)
        .help(search.tool)
    }

    /// One fetched document, in fetch order, with the time it was read.
    private func fetchedRow(_ document: RunFetchedDocuments.Document) -> some View {
        documentRow(label: document.label,
                    detail: document.fetchedLabel(now: Date()),
                    openableId: document.openableId,
                    help: document.documentId)
    }

    /// One given document. A row whose id opens is a tap target, and the id is
    /// its tooltip; a row without one says it cannot be opened.
    private func givenRow(_ document: RunGivenDocuments.Document) -> some View {
        documentRow(label: document.slug ?? "No id recorded",
                    detail: document.scope,
                    openableId: document.openableId,
                    help: document.recordId ?? "The record gives no id for this document")
    }

    /// The row both document sections draw. `openableId` is the id a tap opens,
    /// nil for a row that cannot open.
    private func documentRow(label: String, detail: String?, openableId: String?,
                             help: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(secondaryInk)
                .frame(width: 14, alignment: .center)
            Text(label)
                .frameFont(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail).frameFont(.caption).foregroundStyle(secondaryInk)
            }
            if openableId == nil {
                Text("cannot be opened").frameFont(.caption).foregroundStyle(secondaryInk)
            }
        }
        .padding(.leading, 14)
        .contentShape(Rectangle())
        .onTapGesture {
            if let id = openableId { onOpenDocument(id) }
        }
        .help(help)
        .textSelection(.disabled)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).frameFont(.body).fontWeight(.semibold)
            content()
        }
    }
}

extension View {
    /// Makes a Dispatched row open its run pane. A run with no `run_id` has
    /// nothing to key a pane on and stays inert.
    ///
    /// Both panels that draw these rows set `.textSelection(.enabled)` on
    /// their container, and a plain `onTapGesture` row inherits it, so a
    /// click on the agent name or the instruction snippet started a text
    /// selection and never reached the tap. Only the glyph and the gap
    /// between the lines opened the pane (the operator, build 773). A selectable row
    /// opts back out here, as `courseEntryRow` does; the full instruction
    /// stays copyable in the pane itself.
    @ViewBuilder
    func runRowSelection(runId: String?, openRunId: String?,
                         onSelectRun: ((String) -> Void)?) -> some View {
        if let runId, let onSelectRun {
            self
                .padding(.vertical, 2)
                .background(openRunId == runId ? Color.accentColor.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { onSelectRun(runId) }
                .textSelection(.disabled)
                .accessibilityAddTraits(.isButton)
        } else {
            self
        }
    }
}
