import Foundation

/// User overrides, read from `~/.config/convivy/deck/theme.json`.
///
/// This file is the whole customization story, and it is why the catalog ships
/// colors rather than a table of Convivy's sessions: a user maps their own
/// session names onto shipped themes here, and gets a sensible hashed default
/// for anything they have not mapped. The operator's Convivy mapping is one instance of
/// the mechanism, not the mechanism.
///
/// ```json
/// {
///   "rail": [
///     { "session": "vivy", "host": "macstudio", "name": "Vivy", "workdir": "~/work/vivy" },
///     { "session": "deck", "host": "macstudio" }
///   ],
///   "sessions": { "macstudio|vivy": "azure", "macstudio|deck": "gold" },
///   "defaultHost": "macstudio",
///   "appearance": "system"
/// }
/// ```
///
/// EVERY CREW RECORDS ITS HOST, AND EVERY THEME KEY NAMES ONE. A crew is
/// identified by its host together with its name, because a tmux session
/// name is unique per machine rather than globally: every Builder install
/// has a crew named `steward`, and one operator runs several machines, so
/// `steward` on two hosts is two crews. A file written before this change
/// reads intact — a crew naming no host takes `defaultHost`, a bare theme
/// key takes the host of whichever row carries its name — and the next save
/// writes both in the new form.
struct ThemeConfiguration: Equatable {
    /// Session to shipped theme name, keyed by host and name.
    ///
    /// A `SessionRef` rather than a bare name, and written as that ref's
    /// `stringForm` (`"macstudio|deck"`): with one key per name, macstudio's
    /// `steward` and macmini's `steward` shared a colour and neither could be
    /// themed without the other. Children are in here on the same footing as
    /// crews, each under its own crew's host (`SessionRef.owned(by:name:)`),
    /// since a child's theme is picked from its own row.
    var sessions: [SessionRef: String]

    /// The rail's rows, in the order they are drawn. `nil` means the user has
    /// not configured a rail and gets the shipped catalog.
    ///
    /// An ordered array rather than a keyed object, because the rail's order is
    /// load-bearing — "the rail sorts stably so muscle memory survives" — and
    /// JSON objects carry no order. Kept separate from `sessions` above, which
    /// stays a theme lookup: one key decides what is on the rail, the other
    /// decides what color it is, and a session can be themed without being
    /// pinned to the rail.
    var railSessions: [Crew]? = nil

    /// Sessions Deck can start but does not pin to the rail.
    ///
    /// The rail is what you keep in front of you; this is what you can summon.
    /// Kept as a separate key rather than a `pinned` flag on the rail, because
    /// the two lists answer different questions and a reader scanning the file
    /// should not have to filter one to see the other.
    var catalog: [LaunchableSession] = []
    var appearancePreference: AppearancePreference

    /// Every typographic surface, each sized on its own.
    ///
    /// `typography` remains as the terminal's, because that is what every
    /// existing caller means by it and renaming thirty call sites to prove a
    /// point would be churn. The other three surfaces arrive beside it.
    var typography: TerminalTypography
    var sessionTypography: SessionTypography = .default
    var composerTypography: ComposerTypography = .default
    var frameTypography: FrameTypography = .default

    /// Which key sends a message in the session composer.
    ///
    /// Defaulted on the property so every existing caller and test keeps
    /// compiling and gets the shipped behaviour, rather than a compile error
    /// that teaches nobody anything.
    var sendKey: SendKeyPreference = .default

    /// The right-hand column's width, dragged from the divider between it
    /// and the conversation. Persisted the way every other view preference
    /// here is — a plain field on this struct, written by `ThemeStore.commit`
    /// — rather than a second mechanism, so the column comes back where a
    /// user left it the way font size and theme picks already do.
    var columnWidth: Double = ThemeConfiguration.defaultColumnWidth

    /// The root the steward's directory falls back to when its host has no
    /// root of its own: `<crewsRoot>/<slug>` (`StewardCrew.directory`). Empty
    /// until an operator has one — either written into `theme.json`, or read
    /// from the host itself (`SessionAgent.crewsRoot`, the `crews-root`
    /// verb, which is what fills a host's own root when it is added) — because
    /// there is no compiled-in root that is correct on a machine Deck has never
    /// seen. Nothing in Deck's UI edits this one; a host's own root, in
    /// Settings › Hosts, is the editable one and takes precedence
    /// (`HostResolution.crewsRoot`).
    /// `session-agent --create-dir` refuses anything outside its own
    /// configured floor (`_validated_directory` in agent-platform's
    /// `session_lifecycle.py`, `CREWS_ROOT` in the host's own
    /// `session-agent.env`), a deliberate floor documented in the
    /// `session-agent-api` contract — Deck proposing a root that floor will
    /// refuse is what `deck-deck#103`/`#105` were. An empty root here is
    /// honest rather than a placeholder: `StewardCrew.directory` derives
    /// nothing from it rather than a garbage `/<slug>`, and
    /// `validateWorkingDirectory` refuses the empty directory that leaves
    /// behind. See `deck/specs/running-deck-as-someone-else`.
    var crewsRoot: String = ""

    /// Every machine a crew can be told to run on, named so a crew's `host`
    /// field can reference one without repeating its address. Empty until
    /// an operator adds an entry in Settings › Hosts, which is what has
    /// written this table since `e86e7d3` (2026-08-17) —
    /// `ThemeStore.addHost`/`updateHost`/`removeHost`/`setDefaultHost`. An
    /// empty table and a `nil`/unmatched host name resolve the same way:
    /// `HostResolution` treats both as "nothing to resolve to," and a crew
    /// naming either draws unresolved rather than falling back to a
    /// compiled-in box — see `deck/specs/running-deck-as-someone-else` and
    /// `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// boxes".
    var hosts: [HostEntry] = []

    /// The host name a crew with no `host` of its own resolves to. `nil` (or
    /// a name matching nothing in `hosts`) resolves to nothing at all —
    /// see `HostResolution.target(forHostName:hosts:defaultHost:)`.
    var defaultHost: String? = nil

    /// The corrections queue's chosen ordering — `CockpitView`'s sort
    /// control, persisted the same channel `columnWidth` and every other
    /// view preference here uses, rather than a second mechanism (see that
    /// field's own doc). Defaults to `.severity`, worst first
    /// (issue_01M2P9ZPBA5114PE875BHHT8NR: the operator, 2026-09-16, "yeah let's just
    /// do severity sort for now").
    var queueSortOrder: LibraryClient.QueueSortOrder = .severity

    /// The floor on the right-hand column's width. Was four separate
    /// `.frame(minWidth: 280)` calls, one per occupant (`remoteShell`,
    /// `localTerminal`, `viewer`, `editor`); now the divider enforces it
    /// once, on the way in from a drag, and this is the one number.
    static let minimumColumnWidth: Double = 280
    static let defaultColumnWidth: Double = 320

    /// Bounded independently of any particular window's width — that bound
    /// is `ContentView.clampedColumnWidth`'s job, at render time, since it
    /// alone knows how wide the window is. This only keeps a corrupt or
    /// hand-edited value (negative, NaN, absurdly large) from reaching disk.
    var clampedColumnWidth: Double {
        DeckTypography.clamp(columnWidth, Self.minimumColumnWidth, 4_000,
                             fallback: Self.defaultColumnWidth)
    }

    static let empty = ThemeConfiguration(
        sessions: [:], catalog: [], appearancePreference: .builderDefault,
        typography: .default, sessionTypography: .default,
        composerTypography: .default, frameTypography: .default, sendKey: .default)

    /// `builderDefault` is the answer for a preference that was never set. It
    /// draws the interactive, reading and writing panes light and the status
    /// panes dark on `StatusGround.ground`, per surface (`AppearanceSurface`).
    /// It is the only case whose answer depends on which surface is asking.
    ///
    /// `system` follows the system appearance. The explicit pins exist because
    /// "follows the system" is not sufficient for a user who cannot read one of
    /// the two appearances; without an override, such a user is stuck the moment
    /// anything else moves the system setting.
    enum AppearancePreference: String, Equatable {
        case system
        case light
        case dark
        case builderDefault

        /// The preference a stored `appearance` value names. `split` was this
        /// case's name before it became `builderDefault`, and a file that still
        /// says `split` keeps its meaning.
        init?(stored: String) {
            if stored == "split" {
                self = .builderDefault
            } else {
                self.init(rawValue: stored)
            }
        }
    }

    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/convivy/deck/theme.json")
    }

    /// A missing file is the normal case, not an error — it means "no overrides".
    ///
    /// A malformed file is also non-fatal: it degrades to defaults rather than
    /// refusing to draw a terminal. A user whose JSON has a stray comma should
    /// get their sessions with default colors, not a dead app.
    static func load(from url: URL = defaultURL) -> ThemeConfiguration {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return parse(data) ?? .empty
    }

    static func parse(_ data: Data) -> ThemeConfiguration? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Each field degrades independently: a bad `appearance` should not cost
        // the user their session mapping.
        //
        // `defaultHost` is read before the rail and the catalog because both
        // now fill a row's absent `host` from it, and the theme map is read
        // after them because a bare theme key resolves against the rows.
        let defaultHost = (root["defaultHost"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // An absent key is a preference that was never set, and it takes the
        // default. A key that names no preference keeps the `system` fallback
        // it has always had.
        let appearance = root["appearance"] == nil
            ? AppearancePreference.builderDefault
            : (root["appearance"] as? String)
                .flatMap(AppearancePreference.init(stored:)) ?? .system

        // Each typography key degrades on its own: a bad fontSize must not
        // cost the user their lineSpacing, for the same reason a bad
        // appearance must not cost them their session mapping.
        let terminal = (root["terminal"] as? [String: Any]) ?? [:]
        let typography = TerminalTypography(
            // Falls back to the default's font like every other key, rather
            // than to nil. Defaulting this one to nil would mean an absent
            // `terminal` section silently selected SwiftTerm's wider fallback
            // font while fontSize and lineSpacing took Deck's values — a
            // config that is half default and half not.
            fontName: (terminal["fontName"] as? String) ?? TerminalTypography.default.fontName,
            fontSize: (terminal["fontSize"] as? NSNumber).map { CGFloat($0.doubleValue) }
                ?? TerminalTypography.default.fontSize,
            lineSpacing: (terminal["lineSpacing"] as? NSNumber).map { CGFloat($0.doubleValue) }
                ?? TerminalTypography.default.lineSpacing
        )
        let composer = (root["composer"] as? [String: Any]) ?? [:]
        let frame = (root["frame"] as? [String: Any]) ?? [:]
        let (railSessions, catalog) = droppingScratchShellCollisions(
            rail: parseRail(root["rail"], defaultHost: defaultHost),
            catalog: parseCatalog(root["catalog"], defaultHost: defaultHost))
        let sessions = parseThemeMap(root["sessions"], rail: railSessions,
                                     catalog: catalog, defaultHost: defaultHost)
        return ThemeConfiguration(
            sessions: sessions, railSessions: railSessions,
            catalog: catalog,
            appearancePreference: appearance, typography: typography,
            sessionTypography: parseSession(root["session"], terminal: typography),
            composerTypography: ComposerTypography(
                fontSize: (composer["fontSize"] as? NSNumber).map { CGFloat($0.doubleValue) }
                    ?? ComposerTypography.default.fontSize),
            frameTypography: FrameTypography(
                baseSize: (frame["baseSize"] as? NSNumber).map { CGFloat($0.doubleValue) }
                    ?? FrameTypography.default.baseSize),
            sendKey: (root["sendKey"] as? String)
                .flatMap(SendKeyPreference.init(rawValue:)) ?? .default,
            columnWidth: (root["columnWidth"] as? NSNumber)?.doubleValue
                ?? ThemeConfiguration.defaultColumnWidth,
            crewsRoot: (root["crewsRoot"] as? String).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "",
            hosts: parseHosts(root["hosts"]),
            defaultHost: defaultHost,
            queueSortOrder: (root["queueSortOrder"] as? String)
                .flatMap(LibraryClient.QueueSortOrder.init(rawValue:)) ?? .severity)
    }

    /// The `sessions` theme map, keyed by `SessionRef` — see that field.
    ///
    /// A KEY CARRYING A `|` IS ALREADY HOST-QUALIFIED and is taken as
    /// written (`SessionRef.parse`). A key with no `|` was written before the
    /// host half existed, when the map was global by name, so the row
    /// carrying that name is what decides which host the user meant: the
    /// rail first, then the catalog, then either list's pinned children,
    /// each inheriting its own row's host. A name no row carries — a session
    /// typed into the new-session field, a row deleted since the theme was
    /// picked — takes `defaultHost`, which is where a row naming no host
    /// lands too.
    ///
    /// FIRST MATCH WINS for a name two rows share, which is deterministic
    /// for a given file and is the best available answer: the old map had one
    /// entry for both rows, so there is no second colour to recover. This is
    /// the one place the old format genuinely loses information, and it
    /// loses it in the direction of keeping a colour rather than dropping
    /// one.
    private static func parseThemeMap(
        _ raw: Any?, rail: [Crew]?, catalog: [LaunchableSession], defaultHost: String?
    ) -> [SessionRef: String] {
        guard let rows = raw as? [String: String] else { return [:] }

        // A row with no host at all is only possible on an install with no
        // `defaultHost` either, since `parseRail`/`parseCatalog` fill from it —
        // so such a row has nothing to contribute here and the fallback below
        // reaches the same answer.
        var hostByName: [String: String] = [:]
        func note(_ name: String, _ host: String?) {
            guard let host, hostByName[name] == nil else { return }
            hostByName[name] = host
        }
        for crew in rail ?? [] {
            note(crew.id, crew.host)
            for child in crew.sessions { note(child.name, crew.host) }
        }
        for entry in catalog {
            note(entry.id, entry.host)
            for child in entry.sessions { note(child.name, entry.host) }
        }

        var map: [SessionRef: String] = [:]
        for (key, themeName) in rows {
            if let ref = SessionRef.parse(stringForm: key) {
                map[ref] = themeName
            } else {
                map[SessionRef(host: hostByName[key] ?? defaultHost, name: key)] = themeName
            }
        }
        return map
    }

    /// A malformed row is dropped, not fatal — the same per-field
    /// degradation every other key gets. A row missing `name`, `user`, or
    /// `address` cannot be resolved to an `SSHTarget` at all, so admitting
    /// it half-built would only defer the failure to whichever crew
    /// referenced it.
    ///
    /// `name`/`user`/`address` are all run through their own validators
    /// here, not just at argv construction — the same two-ends discipline
    /// `validateTmuxSessionName` and `validateWorkingDirectory` already get
    /// elsewhere in this file. `user`/`address` keep a `-oProxyCommand=...`-
    /// shaped entry out of the table at parse time, with the argv gate in
    /// `SessionAgent.arguments`/`sshArguments` making that guarantee hold
    /// regardless of who builds the `SSHTarget` later. `name` keeps a
    /// `|`-shaped entry out for a narrower reason: `SessionRef.stringForm`
    /// joins a host name and a session name with `|`, and that join is
    /// collision-free only because a validated host name can never contain
    /// one.
    ///
    /// A row whose `name` collides with an earlier row's, once validated, is
    /// also dropped — `HostResolution` resolves both directions by first
    /// match, so a duplicate name would make the reverse lookup an "OTHER
    /// SESSIONS" row uses to answer a different address than the forward
    /// lookup a Stop button uses to act on it. See `HostResolution.hostName`.
    private static func parseHosts(_ raw: Any?) -> [HostEntry] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        var seenNames: Set<String> = []
        return rows.compactMap { row in
            guard let rawName = row["name"] as? String,
                  let name = try? validateHostName(rawName),
                  !seenNames.contains(name),
                  let rawUser = row["user"] as? String,
                  let user = try? validateHostUser(rawUser),
                  let rawAddress = row["address"] as? String,
                  let address = try? validateHostAddress(rawAddress)
            else { return nil }
            seenNames.insert(name)
            // A bad `crewsRoot` costs the host entry its own root and falls
            // back to the global one, the same "field costs itself" pattern
            // a rail row's bad `workdir`/`command`/`host` already gets —
            // never the whole entry.
            let crewsRoot = (row["crewsRoot"] as? String).flatMap { try? validateWorkingDirectory($0) }
            // A bad `runbookLink` costs the host entry only its own
            // runbook, the same "field costs itself" rule `crewsRoot`
            // follows above — see `RunbookLink.parse`.
            let runbookLink = (row["runbookLink"] as? String).flatMap { RunbookLink.parse($0)?.stored }
            return HostEntry(
                name: name, user: user, address: address, crewsRoot: crewsRoot, runbookLink: runbookLink)
        }
    }

    /// The session pane's typography, seeded from the terminal's when absent.
    ///
    /// THE MIGRATION, AND WHY IT IS NOT JUST A DEFAULT. Until now the pane's
    /// scale was DERIVED — `terminalSize / 11.5` — so a user running the
    /// terminal at 13pt has been reading a 113% page for as long as they have
    /// had one. Decoupling the two with a flat 1.0 default would silently shrink
    /// that page on the next launch, and the user would have no idea what they
    /// changed. An absent `session` key therefore means "carry forward what the
    /// ratio was giving you", and the first save writes it down explicitly.
    ///
    /// A PRESENT key is taken at its word, including a scale of exactly 1.0:
    /// once written, the value is a choice rather than an inheritance.
    private static func parseSession(_ raw: Any?,
                                     terminal: TerminalTypography) -> SessionTypography {
        guard let section = raw as? [String: Any] else {
            let base = Double(TerminalTypography.scaleInheritanceBase)
            let inherited = base > 0 ? Double(terminal.clampedFontSize) / base : 1
            return SessionTypography(scale: inherited,
                                     lineHeight: SessionTypography.default.lineHeight)
        }
        return SessionTypography(
            scale: (section["scale"] as? NSNumber)?.doubleValue
                ?? SessionTypography.default.scale,
            lineHeight: (section["lineHeight"] as? NSNumber)?.doubleValue
                ?? SessionTypography.default.lineHeight)
    }

    /// A malformed row is dropped, not fatal — the same per-field degradation
    /// every other key gets. A row whose session name could never become valid
    /// ssh argv is dropped here rather than drawn and left to fail on click:
    /// a rail row that cannot connect is worse than an absent one, because it
    /// looks like the session is down.
    ///
    /// An absent `rail` key and a `rail: []` are different answers, and both are
    /// kept: absent means "not configured, show the shipped catalog", empty
    /// means "I want no fleet rows" and is honoured.
    private static func parseRail(_ raw: Any?, defaultHost: String?) -> [Crew]? {
        guard let rows = raw as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let session = row["session"] as? String,
                  (try? validateTmuxSessionName(session)) != nil
            else { return nil }
            // A workdir that fails validation costs the row its directory, not
            // its place on the rail: the session still attaches, and creating it
            // falls back to the remote default. Losing the row would be a larger
            // punishment than the typo deserves.
            let workdir = (row["workdir"] as? String)
                .flatMap { try? validateWorkingDirectory($0) }
            return Crew(
                id: session,
                displayName: (row["name"] as? String) ?? session,
                workingDirectory: workdir,
                // A bad command costs the row its override and falls back to
                // `Crew.defaultLaunchCommand`, the same way a bad workdir
                // costs it its directory rather than its place — a typo should
                // not unpin a session.
                command: (row["command"] as? String).flatMap(validatedCommand),
                sessions: parseSessions(row["sessions"]),
                parent: row["parent"] as? String,
                // A row naming no host, or naming one that fails validation,
                // takes the configured default AND RECORDS IT — a crew's host
                // is half its identity now, so leaving it absent would mean
                // the same crew changed identity whenever `defaultHost` moved
                // under it. A bad host still costs the row its host
                // designation and nothing else, the same "field costs itself"
                // pattern the workdir and command overrides above get;
                // `validateHostName` is what makes `SessionRef.stringForm`'s
                // `|`-join collision-free.
                host: (row["host"] as? String).flatMap { try? validateHostName($0) } ?? defaultHost,
                // Same "field costs itself" pattern as `host` — a project
                // name that fails validation costs the row its cockpit, not
                // its place on the rail. See `Crew.project`.
                project: (row["project"] as? String).flatMap { LibraryClient.validateLibraryProduct($0) },
                // Same "field costs itself" pattern — a bead id that fails
                // validation costs the row its "Open bead" action, not its
                // place on the rail. See `Crew.bead`. `validateKBId` is the
                // same gate a `deck-open:` URL's `kb` ref clears, since a
                // bead id is a Library doc id like any other.
                bead: (row["bead"] as? String).flatMap { DeckOpenRef.validateKBId($0) },
                // Same "field costs itself" pattern, applied per entry — see
                // `parseRepos`. See `Crew.repos`.
                repos: parseRepos(row),
                // No validation gate — `RestStateResolution.shape(for:)`
                // already degrades an unrecognized string to the same
                // "unset" default a missing field gets, so there is nothing
                // for this decode to reject that the resolver doesn't
                // already handle. See `Crew.shape`.
                shape: row["shape"] as? String,
                documents: (row["documents"] as? [Any])?.compactMap { $0 as? String } ?? [])
        }
    }

    /// `repo` (singular, since #238) and `repos` (plural, since
    /// issue_01M2P5JHM1G8XCMKM4HEHVJB2P) are two keys a hand-edited file may
    /// carry. `repos` wins when it decodes to a non-empty list; otherwise
    /// the singular key is wrapped as a one-element list, so a file that
    /// only ever wrote `repo` needs no rewrite. Each entry is validated
    /// independently, the same "field costs itself" pattern every other
    /// key in this file follows, just applied per list entry rather than to
    /// a whole row.
    private static func parseRepos(_ row: [String: Any]) -> [String] {
        func valid(_ raw: String) -> String? {
            LibraryClient.validateRepoIdentity(raw).map { "\($0.owner)/\($0.repoName)" }
        }
        if let list = (row["repos"] as? [Any])?.compactMap({ $0 as? String }).compactMap(valid),
           !list.isEmpty {
            return list
        }
        return (row["repo"] as? String).flatMap(valid).map { [$0] } ?? []
    }

    /// A pinned child's own name still has to be usable ssh argv, for the same
    /// reason a rail row's does — a malformed one is dropped rather than drawn,
    /// so a typo costs that one child rather than the whole row.
    ///
    /// `sessionId` round-trips as a bare string with no validation of its
    /// own — it is tmux's own `#{session_id}`, never argv, so nothing here
    /// depends on its shape. An older file with no `sessionId` key decodes
    /// to `nil`, the same "migration costs nothing" every other field in
    /// this file follows; `PinnedSessionReconcile` is what fills it in on
    /// the first poll that finds a matching live session.
    private static func parseSessions(_ raw: Any?) -> [PinnedSession] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let name = row["name"] as? String,
                  (try? validateTmuxSessionName(name)) != nil
            else { return nil }
            return PinnedSession(name: name, displayName: (row["displayName"] as? String) ?? name,
                                 sessionId: row["sessionId"] as? String)
        }
    }

    /// A catalog row is dropped when its session name could never attach, for
    /// the same reason a rail row is: a launcher entry that fails the moment it
    /// is clicked is worse than one that is absent, because it reads as the
    /// session being broken rather than the config being wrong.
    ///
    /// A bad `workdir` costs the row its directory rather than its place, and a
    /// bad `command` costs it the override — both fall back to the mini's
    /// defaults, which are the values a row that omitted them would have got.
    private static func parseCatalog(_ raw: Any?, defaultHost: String?) -> [LaunchableSession] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let session = row["session"] as? String,
                  (try? validateTmuxSessionName(session)) != nil
            else { return nil }
            let workdir = (row["workdir"] as? String)
                .flatMap { try? validateWorkingDirectory($0) }
            return LaunchableSession(
                id: session,
                displayName: (row["name"] as? String) ?? session,
                workingDirectory: workdir,
                command: (row["command"] as? String).flatMap(validatedCommand),
                sessions: parseSessions(row["sessions"]),
                parent: row["parent"] as? String,
                // Same as `parseRail`'s `host`, including the fill from
                // `defaultHost` — see that comment.
                host: (row["host"] as? String).flatMap { try? validateHostName($0) } ?? defaultHost,
                project: (row["project"] as? String).flatMap { LibraryClient.validateLibraryProduct($0) },
                bead: (row["bead"] as? String).flatMap { DeckOpenRef.validateKBId($0) },
                repos: parseRepos(row),
                shape: row["shape"] as? String,
                documents: (row["documents"] as? [Any])?.compactMap { $0 as? String } ?? [])
        }
    }

    /// The config-parse counterpart to the collision check
    /// `SiblingSessionName.derive` runs on the spawn path.
    ///
    /// `derive` only ever sees one candidate at a time, checked against every
    /// session already in play, so it catches a truncation collision the
    /// moment a user types a new sibling's label. A name arriving straight
    /// from `theme.json` never runs through `derive` at all — `parseRail`,
    /// `parseSessions`, and `parseCatalog` validate with
    /// `validateTmuxSessionName` alone, which has no notion of any other name
    /// in the file. So this runs once, after all three, across every name they
    /// admitted — rail row ids, catalog row ids, and every row's children —
    /// because every one of them resolves to a scratch shell through the same
    /// `scratchShellSessionName`, and two of them agreeing on its truncated
    /// prefix is the same hazard regardless of which two.
    ///
    /// A colliding CHILD is dropped and its row kept, the same per-row
    /// degradation `parseSessions` already gives a child that fails
    /// `validateTmuxSessionName`. A colliding ROW is dropped outright, taking
    /// its own children with it, since a dropped row leaves nothing for them
    /// to hang under. The first occurrence in each case wins — rail before
    /// catalog, each in file order, a row's own id before its children — so
    /// the result is deterministic for a given file.
    ///
    /// SCOPED PER HOST, because the collision it guards against is. A scratch
    /// shell is a tmux session on one machine, and a tmux session name is
    /// unique per machine, so two rows agreeing on a truncated prefix are a
    /// hazard only when they are on the same host. Checking globally is what
    /// would drop macmini's `steward` because macstudio already had one — the
    /// collision this epic exists to stop being a collision.
    private static func droppingScratchShellCollisions(
        rail: [Crew]?, catalog: [LaunchableSession]
    ) -> (rail: [Crew]?, catalog: [LaunchableSession]) {
        var seenScratchNames: Set<SessionRef> = []
        func accept(_ name: String, on host: String?) -> Bool {
            let scratchRef = SessionRef(host: host, name: scratchShellSessionName(for: name))
            guard !seenScratchNames.contains(scratchRef) else { return false }
            seenScratchNames.insert(scratchRef)
            return true
        }
        func filteredChildren(_ children: [PinnedSession], on host: String?) -> [PinnedSession] {
            children.filter { accept($0.name, on: host) }
        }

        let filteredRail = rail?.compactMap { row -> Crew? in
            guard accept(row.id, on: row.host) else { return nil }
            var row = row
            row.sessions = filteredChildren(row.sessions, on: row.host)
            return row
        }
        let filteredCatalog = catalog.compactMap { row -> LaunchableSession? in
            guard accept(row.id, on: row.host) else { return nil }
            var row = row
            row.sessions = filteredChildren(row.sessions, on: row.host)
            return row
        }
        return (filteredRail, filteredCatalog)
    }

    /// A SHAPE gate, not an injection gate. The command travels to the mini on
    /// stdin (`SessionAgent.start`), so it never reaches ssh argv and the remote
    /// shell never parses it — `;`, `|`, `&&` are therefore NOT blocked, because
    /// `cd foo && co` is a launch command a user may legitimately write and it
    /// runs in the session they are starting, not in the ssh control shell.
    ///
    /// What is blocked is what would stop it being one typed line: it is trimmed,
    /// length-capped, and refused if it carries a control character or either
    /// Unicode line separator. The line separators matter because Deck is a
    /// JavaScript-adjacent caller and both are line breaks in a JS or Swift
    /// string literal — a later re-serialisation could turn one into a real
    /// newline, which the mini types as two commands.
    ///
    /// Deliberately not an allowlist of commands: the catalog exists so a row
    /// can say `co -r`.
    static func validatedCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return nil }
        // `.controlCharacters` is the Unicode category, so it also catches the
        // C1 range (U+0080–U+009F) the mini's ASCII check does not — stricter is
        // safe here, since none of those belong in a launch command.
        let forbidden = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "\u{2028}\u{2029}"))
        guard trimmed.rangeOfCharacter(from: forbidden) == nil else { return nil }
        return trimmed
    }

    /// Resolution order: an explicit mapping the user wrote, then — for a
    /// sibling session with a crew — that crew's own resolved theme,
    /// then the hashed default. A mapping naming a theme that does not exist
    /// falls through the same way, rather than failing — a typo costs the
    /// intended color, not the terminal.
    ///
    /// `fallbackParent` is the caller's job to supply: this type has no notion
    /// of the rail's crew/child structure, only of session-to-theme
    /// mappings, so the caller (which does know that structure) passes its
    /// crew's ref for a child session and nil for everything else. A child
    /// with no theme of its own is meant to read as its crew's accent, not
    /// as a color hashed from its own, unrelated-looking name.
    ///
    /// THE HASHED DEFAULT IS STILL HASHED FROM THE BARE NAME, so the same crew
    /// name on two hosts falls back to the same colour. That is the right
    /// answer for a default: the colour a name hashes to is a property of the
    /// name, and two crews called `steward` looking alike until one is themed
    /// reads as what it is.
    ///
    /// THE LAPTOP'S SHELL DEFAULTS TO GRAPHITE, NOT A HASH. `local:shell` names
    /// no crew, so a hashed colour would make it look like one. A user mapping
    /// for it still wins, because the mapping is read first.
    func theme(forSession session: SessionRef, fallbackParent: SessionRef? = nil) -> TerminalTheme {
        if let name = sessions[session], let theme = ThemeCatalog.named(name) {
            return theme
        }
        if session == .localShell {
            return ThemeCatalog.graphite
        }
        if let fallbackParent {
            return theme(forSession: fallbackParent)
        }
        return ThemeCatalog.defaultTheme(forSession: session.name)
    }

    /// Assigns a theme to a session and returns the updated configuration.
    /// Value semantics deliberately: the caller decides when to persist, so a
    /// failed write cannot leave the in-memory state disagreeing with what the
    /// user just picked.
    func settingTheme(_ themeName: String, forSession session: SessionRef) -> ThemeConfiguration {
        var updated = self
        updated.sessions[session] = themeName
        return updated
    }

    /// Writes the config, creating `~/.config/convivy/deck/` if needed.
    ///
    /// Throws rather than swallowing. A theme the user picked that silently
    /// fails to persist is worse than one that reports it: the color would
    /// change now and revert on the next launch with no explanation.
    /// `fontName` is omitted when unset rather than written as null:
    /// JSONSerialization rejects a nil Optional bridged through `Any`, and an
    /// explicit null would round-trip as a font named "null" on a less careful
    /// reader.
    private var terminalDictionary: [String: Any] {
        var dict: [String: Any] = [
            "fontSize": Double(typography.clampedFontSize),
            "lineSpacing": Double(typography.clampedLineSpacing),
        ]
        if let fontName = typography.fontName { dict["fontName"] = fontName }
        return dict
    }

    /// The theme map as JSON writes it: one key per `SessionRef`, in that
    /// ref's `stringForm` (`"macstudio|deck"`). This is the format change the
    /// `sessions` key carries. A file read in the old bare-name form arrives
    /// here already migrated (`parseThemeMap`), so the first save after an
    /// upgrade rewrites the whole map.
    private var themeMapDictionary: [String: String] {
        var written: [String: String] = [:]
        for (ref, themeName) in sessions { written[ref.stringForm] = themeName }
        return written
    }

    /// Omitted from the written file when unconfigured, so a save triggered by
    /// something unrelated (picking a theme, changing font size) cannot silently
    /// freeze the shipped catalog into the user's config as if they had chosen
    /// it. Once that happened, later changes to the catalog would never reach
    /// them and the cause would be invisible.
    private var railArray: [[String: Any]]? {
        railSessions?.map { crew in
            var row: [String: Any] = ["session": crew.id]
            if crew.displayName != crew.id { row["name"] = crew.displayName }
            if let workdir = crew.workingDirectory { row["workdir"] = workdir }
            if let command = crew.command { row["command"] = command }
            // Omitted when empty/nil, the same reason `railArray` itself is
            // omitted when unconfigured: a row nobody touched should not grow
            // keys nobody wrote.
            if !crew.sessions.isEmpty {
                row["sessions"] = crew.sessions.map { child -> [String: Any] in
                    var childRow: [String: Any] = ["name": child.name]
                    if child.displayName != child.name { childRow["displayName"] = child.displayName }
                    if let sessionId = child.sessionId { childRow["sessionId"] = sessionId }
                    return childRow
                }
            }
            if let parent = crew.parent { row["parent"] = parent }
            if let host = crew.host { row["host"] = host }
            if let project = crew.project { row["project"] = project }
            if let bead = crew.bead { row["bead"] = bead }
            if !crew.repos.isEmpty { row["repos"] = crew.repos }
            if let shape = crew.shape { row["shape"] = shape }
            if !crew.documents.isEmpty { row["documents"] = crew.documents }
            return row
        }
    }

    /// Omitted when empty, the same reason `railArray` is omitted when
    /// unconfigured: nothing writes this table yet, and a save triggered by
    /// something unrelated must not freeze an empty array into a file that
    /// had no `hosts` key at all.
    private var hostsArray: [[String: Any]]? {
        hosts.isEmpty ? nil : hosts.map { host in
            var row: [String: Any] = ["name": host.name, "user": host.user, "address": host.address]
            // Omitted when unset, the same reason every other optional field
            // in this file is: an entry nobody gave its own root should not
            // grow a key nobody wrote.
            if let crewsRoot = host.crewsRoot { row["crewsRoot"] = crewsRoot }
            if let runbookLink = host.runbookLink { row["runbookLink"] = runbookLink }
            return row
        }
    }

    func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [
            "sessions": themeMapDictionary,
            // Written clamped, so a hand-edited out-of-range value is
            // corrected in the file the next time the app saves rather
            // than silently ignored on every launch.
            "terminal": terminalDictionary,
            // Written clamped for the same reason the terminal's are, and
            // written ALWAYS rather than when non-default: the session section's
            // absence is what triggers the migration above, so once a config has
            // been saved the inherited value must be on disk as a choice. Left
            // out, every later launch would re-derive it from the terminal and
            // the decoupling would never take.
            "session": [
                "scale": sessionTypography.clampedScale,
                "lineHeight": sessionTypography.clampedLineHeight,
            ],
            "composer": ["fontSize": Double(composerTypography.clampedFontSize)],
            "frame": ["baseSize": Double(frameTypography.clampedBaseSize)],
            "catalog": catalog.map { entry -> [String: Any] in
                var row: [String: Any] = ["session": entry.id, "name": entry.displayName]
                if let dir = entry.workingDirectory { row["workdir"] = dir }
                if let command = entry.command { row["command"] = command }
                // Same reason `railArray` writes `sessions`/`parent`: a crew
                // unpinned from the rail keeps its children on the far side of
                // the same edit, so the catalog row it becomes has to be able
                // to carry them back if it is ever re-pinned.
                if !entry.sessions.isEmpty {
                    row["sessions"] = entry.sessions.map { child -> [String: Any] in
                        var childRow: [String: Any] = ["name": child.name]
                        if child.displayName != child.name { childRow["displayName"] = child.displayName }
                        if let sessionId = child.sessionId { childRow["sessionId"] = sessionId }
                        return childRow
                    }
                }
                if let parent = entry.parent { row["parent"] = parent }
                if let host = entry.host { row["host"] = host }
                if let project = entry.project { row["project"] = project }
                if let bead = entry.bead { row["bead"] = bead }
                if !entry.repos.isEmpty { row["repos"] = entry.repos }
                if let shape = entry.shape { row["shape"] = shape }
                if !entry.documents.isEmpty { row["documents"] = entry.documents }
                return row
            },
            "sendKey": sendKey.rawValue,
            "columnWidth": clampedColumnWidth,
            "crewsRoot": crewsRoot,
            "queueSortOrder": queueSortOrder.rawValue,
        ]
        // Builder Default is not written. An absent key is what "never set"
        // reads as, so a file saved without a choice keeps following the default
        // as it changes. Every other preference is written, as it always was.
        if appearancePreference != .builderDefault {
            root["appearance"] = appearancePreference.rawValue
        }
        if let railArray { root["rail"] = railArray }
        if let hostsArray { root["hosts"] = hostsArray }
        if let defaultHost { root["defaultHost"] = defaultHost }
        // Sorted keys so a hand-edited file and a picker-written one stay
        // diffable, and repeated saves do not reshuffle the file.
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
