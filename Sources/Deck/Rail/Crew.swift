import Foundation

/// A pinned sibling session: another tmux session in the same crew
/// directory, drawn as a child row under it. See
/// `design-multiple-sessions.md` §A — Phase 1 pins only, no discovery of
/// sessions created outside Deck.
struct PinnedSession: Identifiable, Equatable {
    /// The full tmux session name, `<crew-id>--<slug>`.
    var name: String
    var displayName: String

    /// tmux's `#{session_id}`, or nil. A served crew spec's `sessions` entry
    /// supplies it (`ServedCrew.Child`, `CrewMerge`), and for a hand-pinned
    /// child `PinnedSessionReconcile` records it from the first live session
    /// that answers to the pin's name. Either way it round-trips through
    /// `theme.json`. It is what lets a pin follow a tmux rename, which the
    /// name alone cannot; see `SessionGrouping.discoveredChildren` and
    /// `PinnedSessionReconcile`.
    var sessionId: String?

    var id: String { name }

    init(name: String, displayName: String, sessionId: String? = nil) {
        self.name = name
        self.displayName = displayName
        self.sessionId = sessionId
    }
}

/// One rail row's static identity. `id` doubles as the tmux session name
/// it connects to, so it must satisfy `validateTmuxSessionName` (checked in
/// tests) — a rail row that can't become valid ssh argv is a bug, not an
/// edge case.
///
/// A CREW IS IDENTIFIED BY `ref`, NOT BY `id` ALONE. A tmux session name is
/// unique per machine rather than globally, and every Builder install has a
/// crew named `steward` while one operator runs several machines, so the
/// same crew name on two hosts is the normal case rather than a collision.
/// `ref` is what every stored key uses — the theme map, the rail's expand
/// state, a pinned child's owner, a nested crew's parent.
struct Crew: Identifiable, Equatable {
    let id: String
    /// Editable — `ThemeStore.renameCrew` is the one place a running app
    /// writes this. `id` stays `let`: it is the tmux session name every
    /// `SessionRef` and argv builder keys on, and renaming THAT is a
    /// different operation (detaching from a running session and re-
    /// deriving every reference to it) that no UI in Deck performs.
    var displayName: String

    /// Where the session starts when Deck has to create it. Only consulted on
    /// creation — attaching to a session that already exists uses whatever
    /// directory it was created in, which is tmux's behaviour and the right one:
    /// a running session's directory belongs to the session, not to Deck's
    /// config.
    ///
    /// Optional because a session that already exists on the mini needs no
    /// directory at all, and requiring one would make the common case wordier
    /// for no gain.
    var workingDirectory: String?

    /// An override for what runs when the Start button creates this session.
    /// `nil` takes `Crew.defaultLaunchCommand`; read `launchCommand` rather
    /// than this field to get the value that is actually typed.
    ///
    /// A row opts out of the refresh by saying `"command": "co"` explicitly.
    /// Storing `nil` as the common case keeps the default in one place: a row
    /// that says nothing follows the default when the default changes, and
    /// nothing writes `co -r` back into a user's config file.
    var command: String?

    /// What the Start button types when this row has no override.
    ///
    /// `-r` is `--refresh`: it pulls `~/Convivy/knowledge` and re-individuates
    /// agent config before launching. Every rail row is a crew co that reads
    /// the KB, so every rail row wants it; on a session with no KB to pull it is
    /// a documented no-op. It is NOT about remote control, which `co` passes
    /// unconditionally on every branch — an earlier comment here claimed
    /// otherwise, and that misreading is why the default was opt-in.
    ///
    /// It was opt-in and three rows named it, so the five that did not —
    /// `steward`, `vivy`, `constance`, `hollis`, `sous-chef` — started against
    /// whatever the KB looked like the last time something else pulled it. A
    /// default the rail inherits is the version of this that a sixth row cannot
    /// forget.
    static let defaultLaunchCommand = "co -r"

    /// The command to send, override first.
    var launchCommand: String { command ?? Crew.defaultLaunchCommand }

    /// This crew's identity, and the ref for its own primary session — the
    /// key every per-crew setting is stored under. Identical to
    /// `SessionRef.owned(by: self, name: id)`, named here because a crew's
    /// own ref is asked for far more often than a child's.
    var ref: SessionRef { SessionRef(host: host, name: id) }

    /// Pinned sibling sessions in this crew's directory (the multiple-sessions
    /// design, phase 1). Config order is the order they draw in, once expanded.
    /// Empty for a row nobody has added a sibling to, which is every row before
    /// this field existed — an old `theme.json` decodes with an empty array here,
    /// costing the migration nothing.
    var sessions: [PinnedSession]

    /// Another crew id this row nests under, for the nav only (design §D,
    /// phase 4). Decoded and written back so a file naming it round-trips, but
    /// NOT rendered as nesting in this phase — see the design doc's build order.
    /// A missing or dangling parent draws the row top-level, which is also what
    /// `nil` does today since nothing reads this field yet.
    ///
    /// A BARE CREW ID, READ ON THIS CREW'S OWN HOST. A nested crew and its
    /// parent are on the same host — a crew is a directory, and a directory
    /// is on one machine — so the host half of the link is this crew's own
    /// and does not need storing twice. `RailNesting.nestingParent` is what
    /// enforces that: a crew naming a parent that exists only on another
    /// host draws top-level, exactly as a dangling parent does.
    var parent: String?

    /// The named host this crew runs on, resolved against config's `hosts`
    /// table via `HostResolution`. Drawn on the row
    /// (`RailRow.hostLabel`/`hostWarning`).
    ///
    /// RECORDED EXPLICITLY IN `theme.json`. `ThemeConfiguration.parseRail`
    /// fills this from `defaultHost` for a row that names no host of its
    /// own, and the next save writes it down — so a crew that used to
    /// resolve to the default by omission now says which machine it is on.
    /// That is what makes `ref` a stable identity: two crews sharing a name
    /// stay two crews when the default host changes under them.
    ///
    /// `nil` STILL MEANS "NO HOST", which is what an install with no `hosts`
    /// table and no `defaultHost` leaves every crew with, and what
    /// `HostResolution` already reads as unresolved.
    var host: String?

    /// The Library product this crew's cockpit reads — `convivy-deck`,
    /// `bosun`, `library`, `convivy-orient`, `selector`. Not derivable from
    /// `id` or `displayName`: a crew id and a Library product are two
    /// different naming spaces (`keel` names the crew whose product is
    /// `bosun`), so guessing one from the other is exactly as unsafe as
    /// guessing a host would be. `nil` means the cockpit has nothing to
    /// follow for this crew, the same "unresolved resolves to nothing rather
    /// than guessing" posture `host` already takes. Set in Settings ›
    /// Sessions; the same shape as `host` otherwise — round-tripped through
    /// `RosterEntry`/`ThemeConfiguration` the identical way.
    var project: String?

    /// The Reference Room bead doc this crew's "Open bead" action follows —
    /// a Library doc id (`deck/bead/deck`), picked from
    /// `LibraryClient.fetchBeadsList` in Settings › Sessions rather than
    /// derived from `id`, `displayName`, or `project`. Those are three more
    /// naming spaces a bead's own doc id does not reliably agree with (see
    /// `ContentView.selectedCrewBeadId`, which used to guess this from
    /// `project` and was wrong for Deck's own crew). `nil` means the crew
    /// has no bead set, which draws no "Open bead" action — absent rather
    /// than guessed, the same posture `host` and `project` already take.
    /// Round-tripped through `RosterEntry`/`ThemeConfiguration` identically.
    var bead: String?

    /// The GitHub repositories the cockpit's Pull Requests panel reads, in
    /// the order they were configured — `owner/name` strings
    /// (`convivy/convivy-deck`), the two segments Deck's own config carries
    /// elsewhere as separate validated strings
    /// (`LibraryClient.validateRepoSegment`). Not derivable from `project`:
    /// a crew's Library product and its GitHub repo(s) are two more naming
    /// spaces that do not reliably agree (the Keel crew's project is
    /// `bosun`; its repo is `convivy/agent-platform`), so a guessed repo
    /// name is exactly as unsafe as a guessed host or bead would be. Several
    /// real crews genuinely span more than one repo — Selector
    /// (`selector`, `selector-backend`), Constance (four repos), Vivy
    /// (three) and the Library crew (`library`, `knowledge`) — which is
    /// what issue_01M2P5JHM1G8XCMKM4HEHVJB2P is about.
    ///
    /// EMPTY MEANS UNSET, the same "no distinct explicit-override-to-none"
    /// limit every optional field on this type already has: clearing
    /// `project`/`bead`/`repo` back to `nil` cannot durably override a spec
    /// that names one, because a cleared field is indistinguishable from a
    /// field nobody ever set once persisted, so the next merge fills it
    /// back in from the spec (see `CrewMerge.sparse`'s doc). `documents`
    /// below already carries this exact limitation for a list-valued field;
    /// `repos` follows the identical pattern rather than inventing a new
    /// one. Round-tripped through `RosterEntry`/`ServedCrew`/`CrewMerge`/
    /// `ThemeConfiguration`, matching `documents`'s isEmpty-then-fill /
    /// equals-then-clear pair.
    var repos: [String]

    /// The Pull Requests panel's single followed repo — `repos.first`, or
    /// `nil` when the crew names none. This is the field the cockpit
    /// (`PRLadderModel`/`PRLadder`/`CockpitResolution`) still reads as of
    /// this PR: fetching and merging every repo in `repos` is the follow-up
    /// issue_01M2P5JHM1G8XCMKM4HEHVJB2P describes, once PR #243's
    /// `PRLadderModel` rewrite has landed. `repos` itself is the "this
    /// crew's repos" accessor that follow-up consumes — this computed
    /// property is a read/write convenience over it, kept so every existing
    /// single-repo call site and test needs no change.
    var repo: String? {
        get { repos.first }
        set { repos = newValue.map { [$0] } ?? [] }
    }

    /// tmux's `#{session_id}` for this crew's own primary session, when a
    /// served spec provided one — see `ServedCrew.sessionId` and
    /// `CrewMerge`. `nil` for a purely local crew: `theme.json` never stores
    /// this itself, only a merge with a spec populates it. `CrewMerge`
    /// prefers this over `id` when matching a spec row to a configured one,
    /// since it survives a crew whose configured `id` and the spec's own
    /// `id` have drifted, where a bare string comparison would not.
    var sessionId: String?

    /// The right column's rest-state shape for this crew — the raw wire
    /// value (`"course"`, `"board"`, `"service"`), decoded and stored as-is
    /// rather than as an enum: the enum mapping, including the steward's
    /// by-id default when this is `nil` and the degrade for an
    /// unrecognized string, lives in `RestStateResolution.shape(for:)`, the
    /// one place that decision is made. Kept here on the same footing as
    /// `project`/`bead` — an optional the crew may or may not name, round-
    /// tripped through `ServedCrew`/`CrewMerge`/`ThemeConfiguration`
    /// identically. See `platform/contracts/session-agent-api`'s `crews`
    /// section for the wire shape once it documents this field (phase D of
    /// the steward-board proposal, 2026-09-09 — undocumented there today,
    /// named explicitly rather than left a surprise).
    var shape: String?

    /// The crew's own meta files for the steward board's Working documents
    /// panel — a charter, an intake backlog, a handoff, whatever this
    /// crew's directory holds that is worth a click. Each entry is a
    /// filename or relative path under `workingDirectory`, or an already-
    /// absolute path; `RestStateResolution.documentPaths(for:)` is what
    /// resolves either into something `DeckOpenRef.Origin.path` can open.
    /// Empty is the common case — Deck ships no filename knowledge beyond
    /// the role file (`StewardCrew.roleFilename`) it falls back to there,
    /// never a guessed list of "the" documents a crew probably has.
    var documents: [String]

    /// `repo` and `repos` are two ways to set the same storage — `repos`
    /// wins when non-empty, otherwise `repo` is wrapped as a one-element
    /// list, otherwise the crew names no repos. Keeping both lets every
    /// existing single-repo call site pass `repo:` unchanged while a new
    /// caller (`CrewMerge`, the Settings list editor) passes `repos:`.
    init(id: String, displayName: String, workingDirectory: String? = nil,
         command: String? = nil, sessions: [PinnedSession] = [], parent: String? = nil,
         host: String? = nil, project: String? = nil, bead: String? = nil, repo: String? = nil,
         repos: [String] = [], sessionId: String? = nil, shape: String? = nil,
         documents: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.workingDirectory = workingDirectory
        self.command = command
        self.sessions = sessions
        self.parent = parent
        self.host = host
        self.project = project
        self.bead = bead
        self.repos = !repos.isEmpty ? repos : (repo.map { [$0] } ?? [])
        self.sessionId = sessionId
        self.shape = shape
        self.documents = documents
    }
}

enum CrewCatalog {
    /// The rail's fallback when a config carries no `rail` array of its own.
    ///
    /// USED TO BE CONVIVY'S OWN ORG CHART — steward, vivy, constance, selector,
    /// hollis, sous-chef, svc, deck, vivy-commercial — nine rows nobody
    /// running Deck outside Convivy would recognise, let alone want pinned on
    /// first launch. `deck/specs/running-deck-as-someone-else` §"The defaults
    /// name Convivy" removed it: rule 1 is that Deck ships mechanisms and
    /// Convivy's own specifics are data, and a hardcoded org chart is exactly
    /// the specifics rule 1 rules out.
    ///
    /// EMPTY IS DELIBERATE AND TEMPORARY, not the finished answer. The operator
    /// has decided a fresh install should ship a `steward` crew instead — an
    /// operator can do anything by working with a steward, and it explains
    /// itself — but shipping one means creating a directory on a host the
    /// operator has just connected, which is first-run work the same spec
    /// tracks separately. Until that lands, an unconfigured rail is simply
    /// empty; a config with its own `rail` array is unaffected either way,
    /// since `railSessions` overrides this fallback entirely once a user has
    /// one.
    static let known: [Crew] = []
}
