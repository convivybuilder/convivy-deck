import Foundation

/// One row of Settings › Sessions: a session Deck can start, plus whether it is
/// pinned to the rail.
///
/// WHY THIS TYPE EXISTS. `Crew` and `LaunchableSession` carry nearly the same
/// fields and differ in one thing a person would recognise — a rail row is a
/// session you keep in front of you, a catalog row is one you can summon. The
/// settings window shows them as one list with a pin, because that is the shape
/// of the question ("is this on my rail?") rather than the shape of the file,
/// which stores them under two keys and will keep doing so.
///
/// The rules that make the two representations agree live here rather than in
/// the view, because they are the part that can be wrong: a session that changes
/// what it does when you merely pin it is a bug a screenshot cannot show.
struct RosterEntry: Identifiable, Equatable {
    let id: String
    var displayName: String
    var workingDirectory: String?

    /// The command AS STORED. `nil` means "whatever this list's default is",
    /// which is not the same string for a pinned row as for an unpinned one.
    /// Read `resolvedCommand` for what actually runs.
    var command: String?

    var isPinned: Bool

    /// A pinned row's sibling sessions, carried through so an ORDINARY edit
    /// here — a rename, a reorder, a pin toggle, a command change — cannot
    /// silently drop them. `asCrew`/`asLaunchableSession` are the only two
    /// places this travels through; nothing in this file reads or writes
    /// individual children. `LaunchableSession` carries the same field, so
    /// unpinning a crew with children survives the round trip too.
    var sessions: [PinnedSession]
    /// Round-tripped the same way and for the same reason — see
    /// `Crew.parent`. Not rendered or edited from Settings in this phase.
    var parent: String?
    /// Round-tripped the same way and for the same reason — see
    /// `Crew.host`. Not rendered or edited from Settings in this phase.
    var host: String?

    /// Round-tripped the same way, and — unlike `host` — edited from
    /// Settings › Sessions today. See `Crew.project`.
    var project: String?

    /// Round-tripped the same way, and edited from Settings › Sessions via
    /// the bead picker. See `Crew.bead`.
    var bead: String?

    /// Round-tripped the same way, and edited from Settings › Sessions
    /// beside `project` and `bead`, via the list editor. See `Crew.repos`.
    var repos: [String]

    /// Mirrors `Crew.repo` — a read/write convenience over `repos` kept so
    /// existing single-repo call sites and tests need no change.
    var repo: String? {
        get { repos.first }
        set { repos = newValue.map { [$0] } ?? [] }
    }

    /// Round-tripped the same way, and NOT edited from Settings in this
    /// phase — see `Crew.shape`. Carried through regardless: a pin/unpin
    /// that dropped this silently would reproduce the exact bug class
    /// `project`/`bead` exist here to avoid.
    var shape: String?
    /// Round-tripped the same way, and NOT edited from Settings in this
    /// phase — see `Crew.documents`.
    var documents: [String]

    /// `repo`/`repos` combine the same way `Crew`'s init does — see that
    /// initializer's doc.
    init(id: String, displayName: String, workingDirectory: String? = nil,
         command: String? = nil, isPinned: Bool,
         sessions: [PinnedSession] = [], parent: String? = nil, host: String? = nil,
         project: String? = nil, bead: String? = nil, repo: String? = nil,
         repos: [String] = [], shape: String? = nil, documents: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.workingDirectory = workingDirectory
        self.command = command
        self.isPinned = isPinned
        self.sessions = sessions
        self.parent = parent
        self.host = host
        self.project = project
        self.bead = bead
        self.repos = !repos.isEmpty ? repos : (repo.map { [$0] } ?? [])
        self.shape = shape
        self.documents = documents
    }

    /// This row's identity, matching `Crew.ref`/`LaunchableSession.ref` — what
    /// a per-crew setting is stored under, such as the theme swatch this list
    /// draws, and what `SessionRoster.subscript`/`update`/`remove` and this
    /// row's SwiftUI selection key on. `id` alone is still the bare session
    /// name (it doubles as the tmux session name/argv, the same reason
    /// `Crew.id` does), so two crews of one name on different hosts share
    /// `id` but never `ref`.
    var ref: SessionRef { SessionRef(host: host, name: id) }

    /// What a `nil` command means for this row, which depends on which list it
    /// is in: the rail refreshes by default, the catalog does not.
    var defaultCommand: String {
        isPinned ? Crew.defaultLaunchCommand : LaunchableSession.defaultLaunchCommand
    }

    var resolvedCommand: String { command ?? defaultCommand }

    /// Whether starting this session pulls the knowledge base first.
    ///
    /// Read off the resolved command rather than stored separately, so there is
    /// one truth. `-r` and `--refresh` are the same flag to `co`; both are
    /// recognised, because a person who typed the long form into the config file
    /// should not see the checkbox disagree with what they wrote.
    var refreshes: Bool {
        resolvedCommand.split(separator: " ").contains { $0 == "-r" || $0 == "--refresh" }
    }

    /// The commands the checkbox can express. Anything else — a model override,
    /// a `cd … && co` — is a command only its author can edit, and the checkbox
    /// stands aside rather than rewriting it into something it guesses at.
    ///
    /// `co --refresh` is here because it is the same flag written the long way.
    /// Leaving it out made the checkbox draw itself checked and then refuse to
    /// be clicked, which tells a reader their config is somehow wrong when it
    /// is the form `co` documents.
    static let expressibleCommands = ["co", "co -r", "co --refresh"]

    var isCustomCommand: Bool {
        !RosterEntry.expressibleCommands.contains(resolvedCommand)
    }

    /// Stores the default as `nil` rather than as its string.
    ///
    /// This is the property that keeps a config file following the default when
    /// the default next changes. Writing `co -r` into every row would freeze
    /// today's value in every user's file, invisibly.
    private mutating func normalise() {
        if command == defaultCommand { command = nil }
    }

    mutating func setRefreshes(_ on: Bool) {
        guard !isCustomCommand else { return }
        command = on ? "co -r" : "co"
        normalise()
    }

    /// Pin or unpin WITHOUT changing what the session does.
    ///
    /// The subtle case, and the reason this is not a one-line toggle: `nil`
    /// means `co -r` on the rail and `co` in the catalog, so flipping the flag
    /// alone would silently turn the refresh off for a row that had it on. The
    /// resolved command is captured first and written back explicitly, then
    /// normalised away again if it happens to match the new list's default.
    mutating func setPinned(_ pinned: Bool) {
        let running = resolvedCommand
        isPinned = pinned
        command = running
        normalise()
    }

    /// Free-text edit from the Advanced field. An empty or unusable string
    /// clears the override rather than storing something the mini would refuse.
    mutating func setCommand(_ raw: String) {
        command = ThemeConfiguration.validatedCommand(raw)
        normalise()
    }

    var asCrew: Crew {
        Crew(id: id, displayName: displayName,
                workingDirectory: workingDirectory, command: command,
                sessions: sessions, parent: parent, host: host, project: project, bead: bead,
                repos: repos, shape: shape, documents: documents)
    }

    var asLaunchableSession: LaunchableSession {
        LaunchableSession(id: id, displayName: displayName,
                          workingDirectory: workingDirectory, command: command,
                          sessions: sessions, parent: parent, host: host, project: project, bead: bead,
                          repos: repos, shape: shape, documents: documents)
    }
}

/// The unified list behind Settings › Sessions, and the translation back into
/// the two config keys.
struct SessionRoster: Equatable {
    /// Pinned rows first, in rail order, then the catalog. The tab relies on
    /// that split being contiguous: reordering is a rail-only gesture, and a
    /// drag that would carry a row across the boundary is refused rather than
    /// silently pinning it.
    private(set) var entries: [RosterEntry]

    /// Every served crew known when this roster was built — kept so
    /// `applied(to:)` can undo a spec's fill before persisting (see
    /// `CrewMerge.sparse`) without threading the served list through every
    /// call site that mutates `entries`. Not `Equatable`-relevant beyond what
    /// `ServedCrew`'s own conformance already gives it.
    private var servedCrews: [ServedCrew]

    init(entries: [RosterEntry], servedCrews: [ServedCrew] = []) {
        self.entries = entries.sorted { $0.isPinned && !$1.isPinned }
        self.servedCrews = servedCrews
    }

    /// Builds the list a user sees. An unconfigured rail falls back to
    /// `CrewCatalog.known`, which is what the rail itself draws — empty today,
    /// so an unconfigured install shows no pinned rows until first run or a
    /// config of its own gives it some.
    ///
    /// `servedCrews` is folded into the rail through `CrewMerge.merge`, the
    /// same call `ContentView.crews` makes, so Settings shows exactly the
    /// rows the rail draws — a crew made through `new-crew` with no local
    /// config at all now reaches Settings, not only the rail. The catalog is
    /// never merged with served specs: a served crew always reaches Deck
    /// pinned to the rail (see `CrewMerge.asCrew`'s doc), never as a summon
    /// entry.
    init(configuration: ThemeConfiguration, servedCrews: [ServedCrew] = []) {
        let rail = CrewMerge.merge(
            configured: configuration.railSessions ?? CrewCatalog.known, served: servedCrews,
            hosts: configuration.hosts, defaultHost: configuration.defaultHost
        ).map {
            RosterEntry(id: $0.id, displayName: $0.displayName,
                        workingDirectory: $0.workingDirectory,
                        command: $0.command, isPinned: true,
                        sessions: $0.sessions, parent: $0.parent, host: $0.host,
                        project: $0.project, bead: $0.bead, repos: $0.repos,
                        shape: $0.shape, documents: $0.documents)
        }
        let catalog = configuration.catalog.map {
            RosterEntry(id: $0.id, displayName: $0.displayName,
                        workingDirectory: $0.workingDirectory,
                        command: $0.command, isPinned: false,
                        sessions: $0.sessions, parent: $0.parent, host: $0.host,
                        project: $0.project, bead: $0.bead, repos: $0.repos,
                        shape: $0.shape, documents: $0.documents)
        }
        self.entries = rail + catalog
        self.servedCrews = servedCrews
    }

    var pinnedCount: Int { entries.filter(\.isPinned).count }

    /// Keyed by `ref`, NOT `id`: two crews of one name on different hosts
    /// share `id`, and a bare-id lookup would always resolve to whichever
    /// came first — see `RosterEntry.ref`'s doc.
    subscript(ref: SessionRef) -> RosterEntry? {
        entries.first { $0.ref == ref }
    }

    /// Keyed by `ref` for the same reason the subscript above is — this is
    /// the write path every pin, rename, and command edit in Settings ›
    /// Sessions goes through, so a bare-id lookup here would route an edit
    /// to whichever of two same-named crews came first in `entries`.
    mutating func update(_ ref: SessionRef, _ change: (inout RosterEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.ref == ref }) else { return }
        change(&entries[index])
        // A pin flip moves the row across the boundary, so the split has to be
        // restored or the next drag would compute the wrong range.
        entries = entries.enumerated()
            .sorted { a, b in
                a.element.isPinned == b.element.isPinned
                    ? a.offset < b.offset
                    : a.element.isPinned
            }
            .map(\.element)
    }

    /// Reorders the rail. A move that starts or lands outside the pinned block
    /// is dropped: the rail's order is the only order stored, and the catalog
    /// has none to change.
    mutating func moveRail(from source: IndexSet, to destination: Int) {
        let pinned = pinnedCount
        guard source.allSatisfy({ $0 < pinned }), destination <= pinned else { return }
        entries.move(fromOffsets: source, toOffset: destination)
    }

    /// Keyed by `ref` for the same reason `update` is.
    mutating func remove(_ ref: SessionRef) {
        entries.removeAll { $0.ref == ref }
    }

    /// Writes the roster back into a configuration.
    ///
    /// `railSessions` stays `nil` when the pinned rows are exactly the shipped
    /// catalog, for the reason `railArray` is omitted when unconfigured: a user
    /// who edits a catalog folder should not thereby freeze the rail and stop
    /// receiving later changes to it.
    ///
    /// THE SAME RULE EXTENDS TO A SERVED CREW. `entries` was built by merging
    /// each served spec into the rail (see `init(configuration:servedCrews:)`),
    /// so a pinned row drawn from a served-only crew arrives here with every
    /// field the spec filled in already sitting on it. Writing that straight
    /// out would freeze the fill into local config and stop the crew from
    /// receiving any later spec change — a rename, a new `sessionId`, a moved
    /// directory. `CrewMerge.sparse` undoes exactly the fill `merge` applied,
    /// so what actually persists is only whatever the operator changed;
    /// `CrewMerge.isUnedited` then drops a row that changed nothing at all,
    /// leaving an untouched served crew out of `railSessions` entirely,
    /// exactly as it was before this roster ever merged it in.
    func applied(to configuration: ThemeConfiguration) -> ThemeConfiguration {
        var updated = configuration
        let rail = entries.filter(\.isPinned).compactMap { entry -> Crew? in
            let crew = entry.asCrew
            guard let served = CrewMerge.match(
                crew, in: servedCrews, hosts: configuration.hosts, defaultHost: configuration.defaultHost
            ) else { return crew }
            let sparse = CrewMerge.sparse(crew, relativeTo: served, hosts: configuration.hosts)
            return CrewMerge.isUnedited(sparse) ? nil : sparse
        }
        updated.railSessions = (rail == CrewCatalog.known) ? nil : rail
        updated.catalog = entries.filter { !$0.isPinned }.map(\.asLaunchableSession)
        return updated
    }
}
