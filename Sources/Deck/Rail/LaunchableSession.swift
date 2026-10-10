import Foundation

/// A session Deck can start, whether or not it is pinned to the rail.
///
/// WHY THIS IS SEPARATE FROM `Crew`. A rail row is a session you keep in
/// front of you; a catalog entry is one you can summon. They carry nearly the
/// same fields and mean different things — the operator, 2026-07-23: "we have co's set up
/// for NYH studio, write-better, ask, etc. And no way to launch them from Deck.
/// But we don't always need every co in the rail."
///
/// The extra field is `command`. A catalog row usually omits it and gets `co`;
/// a row that needs `co -r` or a specialist says so. It is not an allowlist on
/// this side either — the mini bounds it by shape, because enumerating the
/// legitimate forms here would mean editing Deck every time one is added.
struct LaunchableSession: Identifiable, Equatable {
    /// The tmux session name, and the id. Validated before it can be stored, so
    /// a catalog row that could never attach is dropped rather than drawn.
    let id: String
    let displayName: String
    /// Where the session starts. Optional: a row without one inherits whatever
    /// directory the remote shell begins in.
    var workingDirectory: String?
    /// What runs once the session exists. `nil` means the mini's default, `co`.
    ///
    /// This is where the two structs stop agreeing, and deliberately. A rail row
    /// with no command takes `Crew.defaultLaunchCommand` (`co -r`) because
    /// every rail row is a crew co that reads the KB. A catalog row is any
    /// session at all — `nyh`, `write-better`, `ask` — so there is nothing to
    /// refresh by default, and a row that wants the refresh says `co -r`.
    var command: String?

    /// Carried through unpinning for the same reason `Crew.sessions` exists
    /// and by the same route: `RosterEntry.asLaunchableSession` is the one place
    /// a pinned row's children cross into this shape, and until this field
    /// existed that crossing dropped them — unpinning a crew in Settings ›
    /// Sessions (reachable today: the pin toggle is the only UI this phase
    /// ships) silently orphaned every child it had. A catalog row a user typed
    /// directly still has none, the same way it has no `workingDirectory` until
    /// pinning gives it one.
    var sessions: [PinnedSession]
    /// Round-tripped the same way and for the same reason. Not rendered from
    /// the catalog side in this phase — see `Crew.parent`.
    var parent: String?

    /// Round-tripped the same way and for the same reason as `Crew.host`,
    /// including being filled from `defaultHost` at parse and written down
    /// explicitly — see that field's doc comment.
    var host: String?

    /// Round-tripped the same way and for the same reason as `Crew.project`
    /// — see that field's doc comment. A catalog row is not pinned to the
    /// rail, so it has no cockpit column showing it today, but pinning it
    /// (`RosterEntry.setPinned`) must not silently drop a project a user
    /// already set.
    var project: String?

    /// Round-tripped the same way and for the same reason as `Crew.bead` —
    /// see that field's doc comment. A catalog row is not pinned to the
    /// rail, so it draws no "Open bead" action today, but pinning it
    /// (`RosterEntry.setPinned`) must not silently drop a bead a user
    /// already set.
    var bead: String?

    /// Round-tripped the same way and for the same reason as `Crew.repos` —
    /// see that field's doc comment. A catalog row draws no Pull Requests
    /// panel today, but pinning it (`RosterEntry.setPinned`) must not
    /// silently drop a repo list a user already set.
    var repos: [String]

    /// Mirrors `Crew.repo` — a read/write convenience over `repos` kept so
    /// existing single-repo call sites need no change.
    var repo: String? {
        get { repos.first }
        set { repos = newValue.map { [$0] } ?? [] }
    }

    /// Round-tripped the same way and for the same reason as `Crew.shape` —
    /// a catalog row is not pinned to the rail, so it draws no board or
    /// service panel today, but pinning it (`RosterEntry.setPinned`) must
    /// not silently drop a shape a user already set.
    var shape: String?

    /// Round-tripped the same way and for the same reason as `Crew.documents`.
    var documents: [String]

    /// What a catalog row runs when it names nothing: the mini's own default.
    /// Named rather than left implicit so `RosterEntry` can ask either list what
    /// its `nil` means without knowing which one it is holding.
    static let defaultLaunchCommand = "co"

    /// The command to send, override first. Mirrors `Crew.launchCommand`.
    var launchCommand: String { command ?? LaunchableSession.defaultLaunchCommand }

    /// This entry's identity, on the same footing as `Crew.ref` and for the
    /// same reason: a catalog row is a crew a user has unpinned, so the two
    /// lists have to agree on what identifies one.
    var ref: SessionRef { SessionRef(host: host, name: id) }

    /// `repo`/`repos` combine the same way `Crew`'s init does — see that
    /// initializer's doc.
    init(id: String, displayName: String, workingDirectory: String? = nil,
         command: String? = nil, sessions: [PinnedSession] = [], parent: String? = nil,
         host: String? = nil, project: String? = nil, bead: String? = nil, repo: String? = nil,
         repos: [String] = [], shape: String? = nil, documents: [String] = []) {
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
        self.shape = shape
        self.documents = documents
    }
}
