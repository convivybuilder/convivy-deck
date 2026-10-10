import SwiftUI

/// Settings › Sessions — rail membership, the summon catalog, and what each
/// session does when it starts.
///
/// ONE LIST, NOT TWO. The config file keeps `rail` and `catalog` as separate
/// keys and will go on doing so; this shows them as one list with a pin,
/// because the difference a person recognises is whether a session is kept in
/// front of them. `SessionRoster` owns the translation and the rules that make
/// pinning safe.
///
/// THE PIN IS NOT A CHECKBOX, and that is the point of the layout. Two columns
/// of identical checkboxes read as one repeated control with nothing to say
/// which is which. A pin already means "kept in front of me", so the column
/// reads without its header and the single checkbox left in the table is
/// unambiguous.
struct SessionsSettingsView: View {
    @EnvironmentObject private var store: ThemeStore
    @EnvironmentObject private var railState: RailStateModel
    @Environment(\.colorScheme) private var systemColorScheme

    /// Keyed by `ref`, not the bare session name — see `RosterEntry.ref`'s
    /// doc. A bare-name selection would jump to whichever of two same-named
    /// crews on different hosts came first in `roster.entries`.
    @State private var selection: SessionRef?
    @State private var showsAdvanced = false

    /// The bead picker's own listing — `nil` while `LibraryClient.fetchBeadsList`
    /// hasn't resolved yet (or has nothing to fetch against), `[]` once it has
    /// run and found nothing usable. Kept separate from `beadListFailed` so the
    /// picker can tell "still looking" from "looked, found nothing" from "could
    /// not look at all" — the manual field is the fallback for the latter two,
    /// per the round-fix: this read must not block the sheet.
    @State private var beadDocuments: [LibraryClient.BeadDocument]?
    @State private var beadListFailed = false

    private var configuration: ThemeConfiguration { store.configuration }
    /// Merges in whatever the steward has served, the same rail
    /// `ContentView.crews` draws — this is what lets a crew made through
    /// `new-crew`, with no local config at all, reach Settings too.
    private var roster: SessionRoster {
        SessionRoster(configuration: configuration, servedCrews: Array(railState.servedCrews.values))
    }
    private var appearance: Appearance {
        configuration.windowAppearance(systemIsDark: systemColorScheme == .dark)
    }
    /// Every display name this roster draws more than once — the same rule
    /// `RailView.duplicateCrewNames`/`HostDisplay.crewLabel` use for the
    /// rail, so a name typed once anywhere in Settings reads the same way it
    /// does there: "where a name appears more than once, each row shows its
    /// host beside it; a name that appears once shows none."
    private var duplicateEntryNames: Set<String> {
        HostDisplay.duplicateDisplayNames(among: roster.entries.map(\.displayName))
    }

    /// THE LIST IS THE ONLY SCROLLER, and that is load-bearing rather than a
    /// style choice. The first version put this `List` inside a `.grouped`
    /// `Form`, which is itself a scroll view: the outer one took the gesture,
    /// the inner one never scrolled, and the rows past the fixed height simply
    /// could not be reached. A fixed height on both also left the window no
    /// flexible axis, so it could not be resized out of the problem either.
    ///
    /// So the tab is a plain stack: the list taking whatever height the window
    /// gives it (its column captions live inside it as a sticky section header),
    /// then the controls and the selected session beneath.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            list

            controls
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

            if let entry = selection.flatMap({ roster[$0] }) {
                Divider()
                detail(for: entry)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        // A floor rather than a fixed size: eleven rows fit without scrolling,
        // and a longer roster grows the list instead of hiding its tail.
        .frame(minWidth: 460, minHeight: 470, alignment: .topLeading)
        // Advanced is a per-session question, so it closes when the selection
        // moves. Left open it would claim the next session also runs a command
        // worth reading, which is the opposite of what "advanced" is for.
        .onChange(of: selection) { _, _ in showsAdvanced = false }
    }

    // MARK: - The list

    /// The pin button's slot in `row`, which the `Rail` caption centres over.
    private static let railColumnWidth: CGFloat = 30

    /// The checkbox's slot in `row`, which the `Refresh` caption centres over.
    private static let refreshColumnWidth: CGFloat = 18

    /// THE CAPTIONS SIT OVER THE CONTROLS THEY NAME as a sticky section header,
    /// so they stay visible when the roster scrolls. The inset list applies the
    /// same row inset to section headers automatically — no measured constant
    /// needed, and a future SDK that changes the inset aligns both.
    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text("Rail")
                .frame(width: Self.railColumnWidth, alignment: .center)
            Spacer(minLength: 8)
            Text("Refresh")
                .fixedSize()
                .frame(width: Self.refreshColumnWidth, alignment: .center)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var list: some View {
        List(selection: $selection) {
            Section {
                // Keyed by `ref`, not `Identifiable`'s default `id`: two
                // same-named crews on different hosts share `id`, and
                // `ForEach`'s own diffing needs a key that does not.
                ForEach(roster.entries, id: \.ref) { entry in
                    row(entry).tag(entry.ref)
                }
                .onMove { source, destination in
                    var updated = roster
                    updated.moveRail(from: source, to: destination)
                    store.setRoster(updated)
                }
            } header: {
                columnHeaders
                    .padding(.top, 14)
                    .padding(.bottom, 5)
            }
        }
        // Takes the window's remaining height rather than naming its own, which
        // is what lets a roster longer than the window scroll to its end.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private func row(_ entry: RosterEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                edit(entry.ref) { $0.setPinned(!$0.isPinned) }
            } label: {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(entry.isPinned ? Color.accentColor
                                                    : Color.secondary.opacity(0.45))
                    .frame(width: Self.railColumnWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.isPinned ? "Take \(entry.displayName) off the rail"
                                 : "Put \(entry.displayName) on the rail")
            .accessibilityLabel("On the rail")
            .accessibilityValue(entry.isPinned ? "yes" : "no")

            Circle()
                .fill(Color(configuration.theme(forSession: entry.ref)
                    .palette(for: appearance).cursor))
                .frame(width: 8, height: 8)

            Text(entry.displayName)

            // Only drawn when this name collides with another row's, the
            // same restraint `HostDisplay.crewLabel` applies on the rail —
            // an ordinary install with no duplicate name shows nothing extra.
            if duplicateEntryNames.contains(HostDisplay.normalizedDisplayNameKey(entry.displayName)) {
                Text(HostDisplay.settingsHostName(for: entry.asCrew, hosts: configuration.hosts,
                                                  defaultHost: configuration.defaultHost))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { entry.refreshes },
                set: { on in edit(entry.ref) { $0.setRefreshes(on) } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(entry.isCustomCommand)
                .help(entry.isCustomCommand
                      ? "\(entry.displayName) runs a command of its own: \(entry.resolvedCommand)"
                      : "Refresh the knowledge base before \(entry.displayName) starts")
                .accessibilityLabel("Refresh on start")
                // Explicit slot width keeps the checkbox centred over its caption.
                // The pin button above uses Self.railColumnWidth for the same reason.
                .frame(width: Self.refreshColumnWidth, alignment: .center)
        }
    }

    /// The − button and the caption share a band, so the sentence explaining
    /// Refresh sits one line under the column it describes rather than at the
    /// bottom of the tab.
    ///
    /// THERE IS NO + HERE. A crew comes into being through the steward, so this
    /// tab configures the crews that exist and never mints one; the − takes a
    /// row off the list without touching its session.
    private var controls: some View {
        HStack(alignment: .top) {
            Button {
                guard let selection else { return }
                var updated = roster
                updated.remove(selection)
                store.setRoster(updated)
                self.selection = nil
            } label: {
                Image(systemName: "minus").frame(width: 20)
            }
            .buttonStyle(.borderless)
            .disabled(selection == nil)
            .help("Remove the selected session")

            Spacer(minLength: 12)

            Text("Refresh pulls the knowledge base and re-individuates agent "
                 + "config before the session starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 250, alignment: .trailing)
        }
    }

    // MARK: - The selected session

    /// Laid out by hand rather than in a `Form`, because a `Form` brings its own
    /// scroll view and the list above is the one that must scroll.
    @ViewBuilder
    private func detail(for entry: RosterEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.displayName)
                .font(.headline)

            LabeledContent("Folder:") {
                CommittingField(
                    text: entry.workingDirectory ?? "",
                    prompt: "The session's own directory",
                    onCommit: { raw in
                        edit(entry.ref) {
                            let trimmed = raw.trimmingCharacters(in: .whitespaces)
                            $0.workingDirectory = trimmed.isEmpty ? nil : trimmed
                        }
                    })
                    .id("folder-\(entry.ref.stringForm)")
            }
            // The folder is checked where it is used, not where it is stored,
            // which is right for a hand-edited file and wrong for a window: a
            // value that will be refused later should say so while the person
            // who typed it is still looking at it. Refused, not dropped: the
            // start validates it and throws, and the session pane shows
            // `MissingDirectoryView` in place of Start.
            if let folder = entry.workingDirectory,
               !SessionSurface.isUsableDirectory(folder) {
                Label("Deck cannot use this folder, so \(entry.displayName) will "
                      + "not start until it changes. Use an absolute or ~/ path "
                      + "with no spaces or shell characters.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            LabeledContent("Project:") {
                CommittingField(
                    text: entry.project ?? "",
                    prompt: "The Library product this cockpit reads",
                    onCommit: { raw in
                        edit(entry.ref) {
                            let trimmed = raw.trimmingCharacters(in: .whitespaces)
                            $0.project = trimmed.isEmpty ? nil : trimmed
                        }
                    })
                    .id("project-\(entry.ref.stringForm)")
            }
            // Checked where it is used, the same reason the folder's own
            // out-of-band check is: an unresolvable project draws no
            // cockpit rather than one guessing at a wrong reading.
            if let project = entry.project,
               LibraryClient.validateLibraryProduct(project) == nil {
                Label("Deck cannot use this project name, so \(entry.displayName)'s "
                      + "cockpit will show nothing to follow. Letters, digits, "
                      + "\".\", \"_\" and \"-\" only.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // A crew can follow several repos (Selector spans `selector` and
            // `selector-backend`; the Library crew works in both `library`
            // and `knowledge`) — see `Crew.repos`. The Pull Requests panel
            // itself still reads only the first entry as of this PR; the
            // fan-out is issue_01M2P5JHM1G8XCMKM4HEHVJB2P's follow-up.
            repoListEditor(for: entry)

            LabeledContent("Bead:") {
                if let beadDocuments, !beadDocuments.isEmpty {
                    Picker("", selection: Binding(
                        get: { entry.bead ?? "" },
                        set: { newValue in
                            edit(entry.ref) { $0.bead = newValue.isEmpty ? nil : newValue }
                        })) {
                        Text("None").tag("")
                        ForEach(beadDocuments) { doc in
                            Text(doc.product.map { "\($0) — \(doc.id)" } ?? doc.id).tag(doc.id)
                        }
                    }
                    .labelsHidden()
                } else {
                    // The listing not being available yet, or not being
                    // available at all, must not block setting a bead —
                    // an operator who knows the doc id can still type it.
                    CommittingField(
                        text: entry.bead ?? "",
                        prompt: manualBeadPrompt(for: entry),
                        onCommit: { raw in
                            edit(entry.ref) {
                                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                                $0.bead = trimmed.isEmpty ? nil : trimmed
                            }
                        })
                        .id("bead-\(entry.ref.stringForm)")
                }
            }
            // Checked where it is used, the same reason the project's own
            // out-of-band check is: an unresolvable bead draws no "Open
            // bead" action rather than one guessing at a wrong reading.
            if let bead = entry.bead, DeckOpenRef.validateKBId(bead) == nil {
                Label("Deck cannot use this bead id, so \(entry.displayName) will draw "
                      + "no \"Open bead\" action. Three slash-separated segments of "
                      + "lowercase letters, digits and \"-\" only.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                LabeledContent("Command:") {
                    CommittingField(
                        text: entry.resolvedCommand,
                        prompt: Crew.defaultLaunchCommand,
                        onCommit: { raw in edit(entry.ref) { $0.setCommand(raw) } })
                        .id("command-\(entry.ref.stringForm)")
                }
                // The checkbox writes `co` or `co -r` and nothing else, so a
                // command it cannot express is worth saying out loud rather than
                // leaving the reader to wonder why the checkbox went grey.
                if entry.isCustomCommand {
                    Text("The Refresh checkbox is off while a session runs its own "
                         + "command. Clear this field to get it back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Re-fetches when the selected row's resolved host changes (a
        // different entry, or the same entry after an edit to `host`) —
        // `nil` when there is nothing to resolve, which `loadBeads` reads as
        // "clear the listing" rather than "keep the last row's".
        .task(id: target(for: entry)) {
            await loadBeads(target: target(for: entry))
        }
    }

    /// The host `entry` resolves to, the same chain `ContentView.hostTarget`
    /// uses for a rail row — `HostResolution` falls through to the
    /// configured default the identical way for both.
    private func target(for entry: RosterEntry) -> SSHTarget? {
        HostResolution.target(forHostName: entry.host, hosts: configuration.hosts,
                              defaultHost: configuration.defaultHost)
    }

    /// Populates the bead picker, off the main actor like every other
    /// `LibraryClient` read (`CockpitModel.fetch`). A failed or empty read
    /// leaves `beadDocuments` `nil` so `detail(for:)` falls back to the
    /// manual field — this must never block the sheet on a slow or
    /// unreachable mini.
    private func loadBeads(target: SSHTarget?) async {
        guard let target else {
            beadDocuments = nil
            beadListFailed = false
            return
        }
        beadListFailed = false
        let result: [LibraryClient.BeadDocument]? = await Task.detached {
            try? LibraryClient.fetchBeadsList(target: target)
        }.value
        beadDocuments = result
        beadListFailed = result == nil
    }

    /// What the manual bead field prompts while no picker is showing —
    /// distinguishing "nothing to fetch against" from "still looking" from
    /// "looked and failed" so an operator isn't left staring at a spinner
    /// that will never resolve.
    private func manualBeadPrompt(for entry: RosterEntry) -> String {
        guard target(for: entry) != nil else { return "No host configured — type a doc id" }
        if beadListFailed { return "Could not list beads — type a doc id" }
        // A completed fetch that found nothing is not the same state as one
        // still in flight — `beadDocuments` is non-nil either way once the
        // read has actually returned.
        if beadDocuments != nil { return "No beads found — type a doc id" }
        return "Looking for beads\u{2026}"
    }

    private func edit(_ ref: SessionRef, _ change: (inout RosterEntry) -> Void) {
        var updated = roster
        updated.update(ref, change)
        store.setRoster(updated)
    }

    /// One row per configured repo, each with its own remove button and its
    /// own `validateRepoIdentity` warning — `entry.repo`'s old single-field
    /// form collapsed every crew to one repo, which is wrong for Selector
    /// (`selector`, `selector-backend`), Constance (four repos), Vivy
    /// (three) and the Library crew (`library`, `knowledge`).
    ///
    /// A row committed empty is REMOVED rather than left as an empty
    /// string, the same "field costs itself, and an empty field is no
    /// field" idiom every other `CommittingField` in this view already
    /// follows — it just removes an array element instead of writing `nil`.
    ///
    /// REMOVING EVERY ROW DOES NOT STICK FOR A SERVED CREW. `CrewMerge`
    /// treats an empty `repos` the same as unset (`Crew.repos`'s doc), so a
    /// spec that names a repo refills this list on the next poll — the
    /// empty-state copy below says so rather than reading as a permanent
    /// "no repos" the way deleting every row otherwise implies.
    @ViewBuilder
    private func repoListEditor(for entry: RosterEntry) -> some View {
        LabeledContent("Repos:") {
            VStack(alignment: .leading, spacing: 6) {
                if entry.repos.isEmpty {
                    Text("No repos — its Pull Requests panel shows nothing to follow. "
                         + "If a served spec names any, they reappear on the next poll.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(entry.repos.enumerated()), id: \.offset) { index, value in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            CommittingField(
                                text: value,
                                prompt: "owner/repo",
                                onCommit: { raw in commitRepo(raw, at: index, for: entry.ref) })
                                .id("repo-\(entry.ref.stringForm)-\(index)")
                            Button {
                                edit(entry.ref) { crew in
                                    guard index < crew.repos.count else { return }
                                    crew.repos.remove(at: index)
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this repo")
                        }
                        // Checked where it is used, the same reason every
                        // other identifier in this view is: an unresolvable
                        // repo costs this one entry, not the row's place on
                        // the rail, and the warning stays with the specific
                        // entry that is wrong rather than the whole list.
                        if !value.isEmpty, LibraryClient.validateRepoIdentity(value) == nil {
                            Label("Deck cannot use this repo. \"owner/repo\", letters, "
                                  + "digits, \".\", \"_\" and \"-\" only in each segment.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    edit(entry.ref) { $0.repos.append("") }
                } label: {
                    Label("Add a repo", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Add another GitHub repo for its Pull Requests panel to read")
            }
        }
    }

    private func commitRepo(_ raw: String, at index: Int, for ref: SessionRef) {
        edit(ref) { crew in
            guard index < crew.repos.count else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                crew.repos.remove(at: index)
            } else {
                crew.repos[index] = trimmed
            }
        }
    }
}

/// A text field that writes when the user is finished rather than on every
/// keystroke, because each commit here is a file write.
///
/// THREE WAYS AN EDIT COULD HAVE BEEN LOST, all closed here. The field commits
/// on Return, on losing focus, and on going away — the last one because
/// clicking a different session while still typing removes this field, and a
/// settings window that swallows what you typed is the failure the whole tab
/// exists to remove.
///
/// The caller must give this a `.id` that changes with the row, so switching
/// selection tears the field down rather than reusing it. Reuse is the subtle
/// case: `text` would change under the draft and the re-seed below would
/// overwrite an unsaved edit with the next row's value.
struct CommittingField: View {
    let text: String
    let prompt: String
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(prompt, text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11.5, design: .monospaced))
            .focused($isFocused)
            .onAppear { draft = text }
            // Only when the user is not mid-edit: a config write from anywhere
            // else should refresh the field, and must not overwrite typing.
            .onChange(of: text) { _, latest in
                if !isFocused { draft = latest }
            }
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onDisappear { commit() }
    }

    private func commit() {
        guard draft != text else { return }
        onCommit(draft)
    }
}
