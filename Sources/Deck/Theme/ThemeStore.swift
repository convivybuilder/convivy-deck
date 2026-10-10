import SwiftUI

/// Owns the theme configuration for the app's lifetime.
///
/// This exists because the menu bar needs to reach the same configuration the
/// views draw from. `.commands` is built at App scope, outside any view's
/// `@State`, so font-size shortcuts could not otherwise mutate what
/// `ContentView` renders. One observable object owned by `DeckApp` and shared
/// down keeps a single source of truth, rather than the menu and the view each
/// holding a copy that drifts.
@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var configuration: ThemeConfiguration

    /// Surfaced rather than swallowed: a change that appears to apply and then
    /// reverts on next launch, unexplained, is worse than one that says it
    /// could not be saved.
    @Published var saveError: String?

    /// Set while a `StewardCrew.create` attempt is in flight, cleared when
    /// it resolves either way. Shared here rather than held per-view because
    /// `StewardCrew.shouldCreate` is now evaluated from two independent
    /// places — `HostsSettingsView` on a host add, `ContentView` once at
    /// launch — and both hold this same store. Without a shared guard, a
    /// launch racing a host add (Settings opened at the same moment the app
    /// starts) could send two `session-agent create-crew` calls at the
    /// steward's directory before either had a row on the rail to make
    /// `shouldCreate` false for the other.
    @Published var stewardCreateInFlight = false

    private let fileURL: URL

    /// Where the rail's expand state lives (`CrewExpansion.storageKey`), so a
    /// host rename can move it. Injected for tests.
    private let railDefaults: UserDefaults

    init(fileURL: URL = ThemeConfiguration.defaultURL,
         railDefaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.railDefaults = railDefaults
        self.configuration = ThemeConfiguration.load(from: fileURL)
    }

    func setTheme(_ themeName: String?, forSession session: SessionRef) {
        var updated = configuration
        if let themeName {
            updated = configuration.settingTheme(themeName, forSession: session)
        } else {
            updated.sessions.removeValue(forKey: session)
        }
        commit(updated)
    }

    /// Writes the whole session roster: rail membership, rail order, and every
    /// row's name, folder and command. One commit per edit, because each of
    /// these is a discrete click rather than a drag, and there is no continuous
    /// gesture to coalesce.
    func setRoster(_ roster: SessionRoster) {
        commit(roster.applied(to: configuration))
    }

    /// Pins a newly spawned sibling session under its crew — see
    /// `Crew.sessions` and `design-multiple-sessions.md` §A/B. Materializes
    /// `railSessions` from the shipped catalog first when the rail is still
    /// unconfigured, the same way `SessionRoster.init(configuration:)` does,
    /// so a crew row with no explicit config entry yet still has a row to
    /// append the child to.
    ///
    /// `crew` IS A `SessionRef`, NOT A BARE ID — as it is on every mutator
    /// here that finds a row. A pin belongs to one crew on one host, and the
    /// same crew name on two hosts is the normal case (see `Crew.ref`), so an
    /// id lookup would append macmini's new child to macstudio's row.
    func addPinnedSession(_ session: PinnedSession, toCrew crew: SessionRef) {
        var updated = configuration
        var rail = updated.railSessions ?? CrewCatalog.known
        guard let index = rail.firstIndex(where: { $0.ref == crew }) else { return }
        rail[index].sessions.append(session)
        updated.railSessions = rail
        commit(updated)
    }

    /// One rename `reconcilePinnedSessions` applied to a pinned child —
    /// enough for a caller (`ContentView`) to move whatever ELSE it keys by
    /// the child's old name (the rail's selection, and the terminal/launch
    /// state in `ContentView`'s own `@State`, all keyed by `SessionRef`).
    /// `crewHost` is the owning crew's config `host` field, which is what
    /// `SessionRef.owned(by:name:)` keys a child's ref on — carried here
    /// rather than the crew id so the caller needs no further lookup.
    struct PinnedSessionRename: Equatable {
        let crewHost: String?
        let from: String
        let to: String
    }

    /// Follows every crew's pinned sibling sessions through a tmux rename —
    /// see `PinnedSessionReconcile`'s doc for the three rules. Run once per
    /// poll tick from `ContentView` (`.onChange(of: railState.generation)`),
    /// against everything `session-agent sessions` has reported so far;
    /// each crew is reconciled only against the sessions discovered on that
    /// CREW'S OWN resolved host, the same host boundary `SessionGrouping`
    /// and `hasTmuxSession` already enforce.
    ///
    /// WRITES `theme.json` ONLY WHEN SOMETHING ACTUALLY CHANGED — a crew
    /// with no pins, or pins that still answer to their configured name,
    /// cost the poll nothing. `PinnedSessionReconcile.reconciling` returning
    /// its input unchanged is what makes that comparison exact rather than
    /// a heuristic.
    ///
    /// MOVES THE PER-SESSION THEME IN THE SAME COMMIT A RENAME APPLIES. A
    /// rename that left the mapping under the old key would read the child's
    /// colour as freshly hashed rather than as the one the user picked for
    /// it. Both keys carry the CREW'S host, since that is the host a child's
    /// ref inherits (`SessionRef.owned(by:name:)`).
    @discardableResult
    func reconcilePinnedSessions(
        discovered: [DiscoveredSession], hosts: [HostEntry], defaultHost: String?
    ) -> [PinnedSessionRename] {
        var updated = configuration
        var rail = updated.railSessions ?? CrewCatalog.known
        var renames: [PinnedSessionRename] = []
        var changed = false

        for i in rail.indices {
            guard let target = HostResolution.target(
                forHostName: rail[i].host, hosts: hosts, defaultHost: defaultHost)
            else { continue }
            let sameHost = discovered.filter { $0.host == target }
            let outcome = PinnedSessionReconcile.reconciling(rail[i].sessions, discovered: sameHost)
            guard outcome.sessions != rail[i].sessions else { continue }
            rail[i].sessions = outcome.sessions
            changed = true
            for rename in outcome.renames {
                renames.append(PinnedSessionRename(crewHost: rail[i].host, from: rename.from, to: rename.to))
                let oldRef = SessionRef.owned(by: rail[i], name: rename.from)
                if let themeName = updated.sessions.removeValue(forKey: oldRef) {
                    updated.sessions[SessionRef.owned(by: rail[i], name: rename.to)] = themeName
                }
            }
        }
        guard changed else { return [] }
        updated.railSessions = rail
        commit(updated)
        return renames
    }

    /// "Remove from Deck" for a pinned sibling — mirrors `removeCrew`'s
    /// shape and semantics exactly, one level down: config only, never the
    /// mini's filesystem or a running tmux session. See
    /// `deck/specs/multiple-sessions-per-project` §"Remove". A genuine
    /// no-op — an unknown crew id, or a name not pinned there — writes
    /// nothing at all, the same defence in depth `removeCrew` takes against
    /// materializing the shipped catalog for a removal that changed
    /// nothing. The session, if still running, is not lost: it is simply no
    /// longer pinned, and the next poll draws it wherever
    /// `SessionGrouping`'s own rules place it.
    func removePinnedSession(_ name: String, fromCrew crew: SessionRef) {
        var updated = configuration
        var rail = updated.railSessions ?? CrewCatalog.known
        guard let index = rail.firstIndex(where: { $0.ref == crew }) else { return }
        let countBefore = rail[index].sessions.count
        rail[index].sessions.removeAll { $0.name == name }
        guard rail[index].sessions.count != countBefore else { return }
        updated.railSessions = rail
        commit(updated)
    }

    /// Writes a brand-new crew row — `StewardCrew.create`'s fresh-install
    /// bootstrap, or `promoteSession` turning a discovered "OTHER SESSIONS"
    /// row into a crew. Materializes the shipped catalog first when the
    /// rail is still unconfigured, the same reason `addPinnedSession` does.
    ///
    /// A no-op if the same crew is already on the rail — defence in depth
    /// against a stale caller, since both current callers check for a
    /// collision before reaching this. Matched on `ref`, so a crew of this
    /// name on a DIFFERENT host is not a collision and is added; that is the
    /// whole point of the epic this is part of.
    func addCrew(_ crew: Crew) {
        var updated = configuration
        var rail = updated.railSessions ?? CrewCatalog.known
        guard !rail.contains(where: { $0.ref == crew.ref }) else { return }
        rail.append(crew)
        updated.railSessions = rail
        commit(updated)
    }

    /// "Remove from Deck" — config only. Never touches the mini's
    /// filesystem or a running tmux session; see
    /// `deck/specs/multiple-sessions-per-project` §"Remove". A crew's
    /// pinned children live nested inside its own row (`Crew.sessions`),
    /// so removing the row drops them with it — a child with no parent row
    /// left to draw under has nowhere on the rail to be, the same as an
    /// unconfigured session today. A discovered child needs no handling at
    /// all: it is never persisted, and `SessionGrouping` simply stops
    /// finding a crew to group it under.
    func removeCrew(_ crew: SessionRef) {
        var updated = configuration
        var rail = updated.railSessions ?? CrewCatalog.known
        let countBefore = rail.count
        rail.removeAll { $0.ref == crew }
        // A genuine no-op — including "that crew was never on the rail" —
        // writes nothing at all, rather than materializing the shipped
        // catalog into an explicit `rail` key for a remove that changed
        // nothing.
        guard rail.count != countBefore else { return }
        updated.railSessions = rail
        commit(updated)
    }

    /// Renames a crew row from a rail context menu — see the cross-session
    /// brief for this PR: promotion (`SessionPromotion.derive`) sets a
    /// crew's display name equal to the discovered session's raw name, so a
    /// promoted crew has no other way to read as anything but lowercase.
    ///
    /// DISPLAY NAME ONLY. This never touches `id`, which is the tmux
    /// session name every `SessionRef`, every argv builder
    /// (`sshArguments`/`SessionAgent`) and every grouping rule
    /// (`SessionGrouping`) keys on — renaming that would mean detaching from
    /// the running session and re-deriving every reference to it, which is
    /// a different operation this button does not perform. "Rename" reads
    /// as renaming the crew; what it actually does is relabel the row.
    ///
    /// A no-op for an id not on the rail, or a name that is already exactly
    /// what is stored — the same defence in depth `setParent` takes, so an
    /// unrelated edit's commit cannot pick up a stray write from a stale
    /// caller.
    func renameCrew(_ crew: SessionRef, to displayName: String) {
        var updated = configuration
        var rail = updated.railSessions ?? CrewCatalog.known
        guard let index = rail.firstIndex(where: { $0.ref == crew }) else { return }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, rail[index].displayName != trimmed else { return }
        rail[index].displayName = trimmed
        updated.railSessions = rail
        commit(updated)
    }

    /// Adds a host from the Hosts tab's Add sheet — see
    /// `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// hosts". A no-op on a name collision: the sheet has already refused
    /// the duplicate (`HostFormValidation.makeEntry`) before this is
    /// called, so this guard is defence in depth, the same posture
    /// `addCrew` takes against a colliding id.
    ///
    /// DELIBERATELY NEVER TOUCHES `defaultHost`. That is the fix for the
    /// hazard the spec calls out by name: with `hosts` empty, EVERY crew
    /// with no `host` of its own resolves to nothing
    /// (`HostResolution.resolvedEntry` returns nil regardless of what is in
    /// the table, so `target` returns nil too). That unresolved state is
    /// keyed on `defaultHost` being nil or unmatched, not on `hosts` being
    /// empty — so adding the FIRST host while leaving `defaultHost` exactly
    /// as it was (nil, on every install that has not explicitly set one)
    /// leaves every such crew resolving the identical way, before and after.
    /// Auto-selecting the new host as the default would be the
    /// natural-looking move and the wrong one: it is exactly what would make
    /// `resolvedEntry`'s second branch start matching and repoint every crew
    /// with no explicit `host` onto a possibly different box. See
    /// `HostConfigTests` for the pinned before/after resolution.
    func addHost(_ host: HostEntry) {
        var updated = configuration
        guard !updated.hosts.contains(where: { $0.name == host.name }) else { return }
        updated.hosts.append(host)
        commit(updated)
    }

    /// Edits an existing host in place — name, user, address, or its own
    /// `crewsRoot`. `oldName` is the entry's name before this edit; when
    /// `updated.name` differs, every crew and catalog row naming the old
    /// name is repointed to the new one IN THE SAME COMMIT, and so is
    /// `defaultHost` — a rename that left those referring to a name that no
    /// longer exists in `hosts` would silently fall them all back to the
    /// default via `HostResolution`'s own "unmatched resolves to default"
    /// rule, which is a real behaviour change dressed up as a typo fix.
    ///
    /// EVERY THEME KEY NAMING THE OLD HOST MOVES WITH THEM, in the same
    /// commit and for the same reason. A theme key carries its session's host
    /// now, so a rename that repointed the rows and left the keys behind
    /// would reset every crew on that host to its hashed default colour —
    /// the same silent loss the row repoint prevents, one key down. The
    /// rail's expand state (`CrewExpansion`) is keyed the same way and moves
    /// too, or every row left open on that host would draw collapsed.
    ///
    /// A no-op when `oldName` names no host, or when the new name collides
    /// with a DIFFERENT existing host — the editor has already refused that
    /// (`HostFormValidation.makeEntry(excludingName:)`) before calling
    /// this, so the guard here is defence in depth, the same posture
    /// `addHost` takes.
    func updateHost(named oldName: String, to updated: HostEntry) {
        var config = configuration
        guard let index = config.hosts.firstIndex(where: { $0.name == oldName }) else { return }
        guard updated.name == oldName
            || !config.hosts.contains(where: { $0.name == updated.name }) else { return }
        config.hosts[index] = updated

        if updated.name != oldName {
            if config.defaultHost == oldName { config.defaultHost = updated.name }

            var rail = config.railSessions ?? CrewCatalog.known
            var railChanged = false
            for i in rail.indices where rail[i].host == oldName {
                rail[i].host = updated.name
                railChanged = true
            }
            if railChanged { config.railSessions = rail }

            for i in config.catalog.indices where config.catalog[i].host == oldName {
                config.catalog[i].host = updated.name
            }

            var themes: [SessionRef: String] = [:]
            for (ref, themeName) in config.sessions {
                var moved = ref
                if ref.host == oldName { moved.host = updated.name }
                themes[moved] = themeName
            }
            config.sessions = themes

            // The rail's expand state is host-qualified the same way, and
            // lives in defaults rather than theme.json, so it moves here too.
            var expansion = CrewExpansion(
                raw: railDefaults.string(forKey: CrewExpansion.storageKey) ?? "")
            expansion.renameHost(oldName, to: updated.name)
            railDefaults.set(expansion.raw, forKey: CrewExpansion.storageKey)
        }
        commit(config)
    }

    /// "Remove" from the Hosts tab. Unlike `removeCrew`, this never touches
    /// a crew or catalog row's own `host` field — see
    /// `deck/specs/multiple-sessions-per-project` §"Removing a host some
    /// crew still names": "Keep `HostResolution`'s fallback behaviour
    /// EXACTLY as it is; this adds visibility, not a refusal." A crew still
    /// naming the removed host simply starts resolving through the
    /// "unmatched host name falls back to the default" rule it already
    /// had; the Hosts tab's remove confirm is what makes that visible
    /// beforehand (`HostUsage.crewsNaming`), not this mutator.
    ///
    /// Resets `defaultHost` to nil when the removed host WAS the default,
    /// rather than guessing a replacement from whatever is left: picking
    /// another host automatically would repoint every host-less crew onto a
    /// box nobody chose for them, the same hazard `addHost` avoids by
    /// leaving `defaultHost` alone. Reverting to nil returns those crews to
    /// unresolved, the same state as an install that has never configured a
    /// default.
    func removeHost(_ name: String) {
        var updated = configuration
        let countBefore = updated.hosts.count
        updated.hosts.removeAll { $0.name == name }
        guard updated.hosts.count != countBefore else { return }
        if updated.defaultHost == name { updated.defaultHost = nil }
        commit(updated)
    }

    /// Sets or clears which host a crew with no `host` of its own resolves
    /// to — the Hosts tab's default marker. `nil` means "no explicit
    /// default", which `HostResolution` already reads as unresolved.
    /// A no-op both when nothing changes and when `name` names no
    /// configured host — the picker only offers real names, so the latter
    /// guard is defence in depth, the same posture every mutator above
    /// takes against a stale caller.
    func setDefaultHost(_ name: String?) {
        var updated = configuration
        guard updated.defaultHost != name else { return }
        guard name == nil || updated.hosts.contains(where: { $0.name == name }) else { return }
        updated.defaultHost = name
        commit(updated)
    }

    /// "Nest under <parent>" or "Move to Top Level" — see
    /// `deck/specs/multiple-sessions-per-project` §"Setting a parent is a
    /// UI act": config is storage, never the interface, so this is the one
    /// place a crew's `parent` field is written. `parentId` nil means "Move
    /// to Top Level". A no-op for a crew not on the rail, the same defence
    /// in depth `addPinnedSession` takes.
    ///
    /// `parentId` STAYS A BARE CREW ID, read on the child's own host — see
    /// `Crew.parent` for why the link needs no host of its own.
    func setParent(_ parentId: String?, forCrew crew: SessionRef) {
        var updated = configuration
        var rail = updated.railSessions ?? CrewCatalog.known
        guard let index = rail.firstIndex(where: { $0.ref == crew }) else { return }
        rail[index].parent = parentId
        updated.railSessions = rail
        commit(updated)
    }

    func setSendKey(_ preference: SendKeyPreference) {
        var updated = configuration
        updated.sendKey = preference
        commit(updated)
    }

    func setAppearancePreference(_ preference: ThemeConfiguration.AppearancePreference) {
        var updated = configuration
        updated.appearancePreference = preference
        commit(updated)
    }

    /// The corrections queue's sort control — `CockpitView`'s own sort menu
    /// calls this directly (it reaches `ThemeStore` via `@EnvironmentObject`,
    /// the same object `DeckApp` injects for every other view preference).
    /// A no-op when the choice has not changed, the same defence in depth
    /// every other mutator here takes against a stray write from a picker
    /// re-selecting its own current value.
    func setQueueSortOrder(_ order: LibraryClient.QueueSortOrder) {
        var updated = configuration
        guard updated.queueSortOrder != order else { return }
        updated.queueSortOrder = order
        commit(updated)
    }

    /// Applies a typography change on screen WITHOUT writing the file.
    ///
    /// A slider fires continuously while it is dragged, and `commit` writes the
    /// config synchronously on the main actor — so a drag was one file write per
    /// tick, on the thread drawing the drag. Small and fast on an SSD, and still
    /// the wrong shape.
    ///
    /// Splitting it keeps the live preview that makes a slider the right control
    /// for a value you judge by looking at it, and costs nothing if the app dies
    /// mid-drag: the unsaved state is a font size the user was still choosing.
    /// The paired `commit` on release is what persists.
    func previewTypography(_ change: (inout TerminalTypography) -> Void) {
        var updated = configuration
        change(&updated.typography)
        configuration = updated
    }

    /// The same preview for the other three surfaces. Each takes the whole
    /// configuration rather than one struct, so a single `commitPreviewed…`
    /// serves them all and a caller cannot forget which surface it was editing.
    func previewConfiguration(_ change: (inout ThemeConfiguration) -> Void) {
        var updated = configuration
        change(&updated)
        configuration = updated
    }

    /// Persists whatever a preview has been showing. Called when a drag ends,
    /// so the file sees one write per gesture rather than per tick.
    func commitPreviewedTypography() {
        commit(configuration)
    }

    func setFontSize(_ size: CGFloat) {
        var updated = configuration
        updated.typography.fontSize = size
        commit(updated)
    }

    func setLineSpacing(_ spacing: CGFloat) {
        var updated = configuration
        updated.typography.lineSpacing = spacing
        commit(updated)
    }

    func adjustFontSize(by delta: CGFloat) {
        var updated = configuration
        updated.typography = configuration.typography.adjustingFontSize(by: delta)
        commit(updated)
    }

    func resetFontSize() {
        var updated = configuration
        updated.typography.fontSize = TerminalTypography.default.fontSize
        commit(updated)
    }

    var canIncreaseFontSize: Bool {
        configuration.typography.clampedFontSize < TerminalTypography.maximumFontSize
    }

    var canDecreaseFontSize: Bool {
        configuration.typography.clampedFontSize > TerminalTypography.minimumFontSize
    }

    /// The in-memory change always applies; only persistence can fail. Applying
    /// first means a read-only config directory costs the user the *saving* of
    /// a preference, never the use of it in this session.
    private func commit(_ updated: ThemeConfiguration) {
        configuration = updated
        do {
            try updated.save(to: fileURL)
        } catch {
            saveError = "Could not save preferences: \(error.localizedDescription)"
        }
    }
}
