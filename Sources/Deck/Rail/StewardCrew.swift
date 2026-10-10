import Foundation

/// The crew a fresh install creates once it has a host to put it on —
/// The operator's call, 2026-08-19: "A FRESH INSTALL SHIPS A STEWARD." An operator
/// can do anything by working with a steward, and the steward can explain
/// things — a helpbot on day one and a real team member later, while the
/// deterministic surfaces arrive behind it. See
/// `deck/specs/running-deck-as-someone-else` §"The defaults name Convivy".
///
/// A CREW IS A DIRECTORY WITH A ROLE FRAMING IN IT, so shipping one is a
/// first-run act rather than a default value: `CrewCatalog.known` cannot
/// carry this the way it used to carry Convivy's org chart, because there
/// is nothing to create ahead of time on a host the operator has not yet
/// added.
///
/// KEEP THE FRAMING GENERIC — the rule that decides the whole feature.
/// `roleFraming` must name no project, host, or person a stranger would
/// not recognise; `StewardCrewTests` pins that so a later edit cannot
/// quietly reintroduce Convivy's own specifics the way `CrewCatalog.known`
/// used to carry them.
enum StewardCrew {
    static let id = "steward"
    static let displayName = "Steward"
    static let roleFilename = "CLAUDE.md"

    /// Written into the crew's directory on creation — the one thing that
    /// makes the agent working there behave as a steward rather than an
    /// unconfigured shell. Says nothing a stranger would not recognise:
    /// no project name, no host, no person.
    static let roleFraming = """
    # Role

    You are the steward: the first thing this operator's setup created, \
    and the one crew whose job is helping them work with all the others.

    Help them understand what is running and why, explain how a piece of \
    the system works when they ask, and coordinate work across their \
    other crews — naming which one a task actually belongs to and \
    helping them get there rather than doing unrelated work here \
    yourself.

    Assume nothing about what the operator already knows going in. \
    Answer in plain terms, and treat every question as a chance to leave \
    them able to answer the next one themselves.
    """

    /// Whether now is the moment to CREATE the steward: a host is
    /// configured and there is no crew yet. See
    /// `deck/specs/running-deck-as-someone-else`: **"A FRESH INSTALL SHIPS
    /// A STEWARD"** (the operator, 2026-08-19) — every fresh install gets one; this
    /// is not an offer the operator can decline.
    ///
    /// The spec's OTHER line, "Creating that is a first-run act, not a
    /// default," is a different claim and does not license an offer. It
    /// says the steward needs a real directory on a real host, so it
    /// cannot ship as a compiled-in rail entry the way `CrewCatalog.known`
    /// once carried Convivy's org chart — which is why this waits for a
    /// host to exist rather than running before one does. An earlier
    /// version of this function read "first-run act" as "ask the
    /// operator" and grew a `declined` flag the spec never called for;
    /// that flag is gone, and this comment says plainly what the line does
    /// and does not mean so the same misreading does not recur.
    ///
    /// Checked against the CURRENT host count and crew list, not a
    /// before/after delta, is what makes a failed create self-heal: a
    /// `StewardCrew.create` that throws (host unreachable, an ssh hiccup)
    /// leaves the host configured and `crews` empty, so this returns true
    /// again the next time it is evaluated — no persisted "already asked"
    /// state to defeat the retry the way `stewardOfferDeclined` used to.
    static func shouldCreate(hostCount: Int, crews: [Crew]) -> Bool {
        hostCount > 0 && crews.isEmpty
    }

    /// The host a LAUNCH-TIME create runs against. `HostsSettingsView`'s own
    /// call to `shouldCreate` always has the host it just added in hand;
    /// evaluating at launch has no such entry, so it has to pick one from
    /// whatever is configured. The default host is the obvious candidate —
    /// it is already what a crew with no host of its own resolves to
    /// (`HostResolution`), and the steward is exactly such a crew: nobody
    /// picked a host for it. Falls back to the first configured host when
    /// none is marked default, which is the common case on a fresh install:
    /// adding the first host does not mark it default (`ThemeStore.addHost`
    /// deliberately never touches `defaultHost`), so a single-host install
    /// would otherwise never resolve to anything here.
    static func launchHostEntry(hosts: [HostEntry], defaultHost: String?) -> HostEntry? {
        hosts.first(where: { $0.name == defaultHost }) ?? hosts.first
    }

    /// The single decision `ContentView`'s one-shot launch evaluation asks:
    /// whether to create the steward now and, if so, on which host. Folds
    /// three things `shouldCreate` alone does not cover for this call site —
    /// picking a host (`launchHostEntry`), and refusing while a create from
    /// EITHER evaluation path is already in flight (`createInFlight`, backed
    /// by `ThemeStore.stewardCreateInFlight`) — into one pure, testable
    /// answer distinct from the host-add path's own inline guard in
    /// `HostsSettingsView.createStewardIfNeeded`.
    static func launchTarget(
        hosts: [HostEntry], defaultHost: String?, crews: [Crew], createInFlight: Bool
    ) -> HostEntry? {
        guard !createInFlight, shouldCreate(hostCount: hosts.count, crews: crews) else { return nil }
        return launchHostEntry(hosts: hosts, defaultHost: defaultHost)
    }

    /// The steward's directory: `<crewsRoot>/steward`. A trailing slash on
    /// `crewsRoot` is tolerated rather than doubled, since the root is free
    /// text in `theme.json` and in a host's own Settings › Hosts field, and a
    /// user who typed `~/Convivy/` should not get `~/Convivy//steward`.
    ///
    /// AN EMPTY ROOT YIELDS NO DIRECTORY, rather than the bare `/steward` a
    /// naive join would produce. `crewsRoot` is empty exactly when nobody has
    /// configured one and the host could not be asked — see
    /// `ThemeConfiguration.crewsRoot` — and `/steward` is not a fallback, it
    /// is a path off the disk's own root that `validateWorkingDirectory`
    /// happens to accept and the mini will refuse. An empty result is what
    /// lets `validateWorkingDirectory`'s existing "must be absolute or start
    /// with `~/`" gate catch it downstream instead.
    static func directory(crewsRoot: String) -> String {
        guard !crewsRoot.isEmpty else { return "" }
        guard crewsRoot != "/" else { return "/\(id)" }
        let root = crewsRoot.hasSuffix("/") ? String(crewsRoot.dropLast()) : crewsRoot
        return "\(root)/\(id)"
    }

    // MARK: - Writing the role file

    /// argv for `session-agent write-file <directory>/CLAUDE.md`, content on
    /// stdin — the same contained verb `WorkingCopyStore.writeFileArguments`
    /// builds for the editor's write-back, reused rather than recomposed.
    /// `#122` moved Deck's document writes off raw ssh (`cat > <path>`)
    /// because a symlinked parent directory could redirect that composition
    /// out of the allowed root with no check catching it; `write-file`
    /// opens each path component with `O_NOFOLLOW` so a symlink in the way
    /// is refused rather than followed. This is the same write, to the same
    /// class of path, so it goes through the same verb rather than a second
    /// raw-ssh composition invented for one call site.
    ///
    /// Validates `target` and `directory` itself before delegating to
    /// `WorkingCopyStore.writeFileArguments`, which builds argv from
    /// `target` as given — the early throw here is what keeps an
    /// injection-shaped user or a directory that escapes from ever reaching
    /// that builder.
    static func writeRoleFileArguments(
        target: SSHTarget,
        directory: String,
        controlPath: String = defaultControlPath()
    ) throws -> [String] {
        _ = try validateHostUser(target.user)
        _ = try validateHostAddress(target.host)
        let dir = try validateWorkingDirectory(directory)
        return WorkingCopyStore.writeFileArguments(
            target: target, path: "\(dir)/\(roleFilename)", controlPath: controlPath)
    }

    /// Writes `roleFraming` to `<directory>/CLAUDE.md` on `target` through
    /// `session-agent write-file`. The directory must already exist —
    /// `write-file` does not create one — so `create` below calls this
    /// only after `SessionAgent.createCrew` has made it. Content goes on
    /// stdin for the reason `WorkingCopyStore.writeBack` sends its document
    /// the same way: argv is visible in the remote process table, and ssh
    /// joins trailing argv with spaces, so multi-line text cannot survive
    /// that trip as an argument. `classifyMissingCommand: false` because
    /// this command touches a path rather than naming a remote binary — a
    /// failure here should carry the remote shell's own words, not a "run
    /// the installer" misdiagnosis.
    @discardableResult
    static func writeRoleFile(target: SSHTarget, directory: String) throws -> Data {
        try SessionAgent.run(
            writeRoleFileArguments(target: target, directory: directory),
            stdin: roleFraming,
            classifyMissingCommand: false)
    }

    /// Creates the steward crew end to end: the tmux session via
    /// `SessionAgent.createCrew` — the only call allowed to pass
    /// `--create-dir` — then the role file. Directory before file: `write-file`
    /// refuses to create the directory it targets, so the crew's directory
    /// has to exist before the role file can land in it. Returns `false`
    /// without touching the network when a steward already exists in
    /// `existingCrews`, so a caller invoked twice — a retry, a race between
    /// two windows — never overwrites a role file the operator or the agent
    /// itself may have since edited. A genuine failure THROWS rather than
    /// returning `false`, so a caller cannot mistake "the mini refused" for
    /// "there was already one here."
    @discardableResult
    static func create(target: SSHTarget, directory: String, existingCrews: [Crew]) throws -> Bool {
        guard !existingCrews.contains(where: { $0.id == id }) else { return false }
        try SessionAgent.createCrew(target: target, session: id, directory: directory)
        try writeRoleFile(target: target, directory: directory)
        return true
    }

    /// Runs `create` off the main actor and hands back a `Result` rather
    /// than throwing — the one shape both call sites (`HostsSettingsView`'s
    /// host-add path and `ContentView`'s launch-time evaluation) switch on
    /// the same way: `.success(true)` adds the rail row, `.success(false)`
    /// means a steward already existed and there is nothing to do, and
    /// `.failure` surfaces through `store.saveError` — the failure branch
    /// must set no other state, so it never blocks the next evaluation from
    /// retrying.
    static func attemptCreate(target: SSHTarget, directory: String, existingCrews: [Crew]) async -> Result<Bool, Error> {
        await Task.detached {
            Result { try create(target: target, directory: directory, existingCrews: existingCrews) }
        }.value
    }
}
