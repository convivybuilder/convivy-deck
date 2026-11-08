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
        // So a `maxSessionsPerControlMaster` hand-edited into `theme.json`
        // takes effect from the first ssh call this launch makes, not only
        // after some later `commit` — see `SSHConnectionGate.applyHostCaps`.
        SSHConnectionGate.shared.applyHostCaps(configuration.hosts)
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
        var updated = roster.applied(to: configuration)
        // Mirrors `removeCrew`'s own prune, for every path that can take a
        // top-level crew off the rail through the roster editor (an unpin,
        // a bulk remove) rather than through `removeCrew` directly — see
        // that mutator's doc.
        //
        // MATCHED ON THE RESOLVED HOST (`CrewMerge.crewHostKey`), not a raw
        // `.ref` — `roster.applied` writes `rail` sparse (`CrewMerge.sparse`
        // drops a default-host row's `host` to nil), while a group's own
        // members are stored resolved. Comparing raw refs failed every
        // member of a default-host group and dropped it on any roster edit
        // at all, pinned crew or not (CQ·189).
        let rail = updated.railSessions ?? CrewCatalog.known
        let liveTopLevelRefs = Set(
            RailNesting.topLevelCrews(rail, hosts: updated.hosts, defaultHost: updated.defaultHost).map {
                SessionRef(host: CrewMerge.crewHostKey(for: $0, hosts: updated.hosts, defaultHost: updated.defaultHost),
                           name: $0.id)
            })
        updated.groups = pruningGroups(updated.groups, keeping: liveTopLevelRefs)
        commit(updated)
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
        guard let index = rail.firstIndex(where: {
            refMatches(crew, row: $0, hosts: updated.hosts, defaultHost: updated.defaultHost)
        }) else { return }
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
        guard let index = rail.firstIndex(where: {
            refMatches(crew, row: $0, hosts: updated.hosts, defaultHost: updated.defaultHost)
        }) else { return }
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
        rail.removeAll { refMatches(crew, row: $0, hosts: updated.hosts, defaultHost: updated.defaultHost) }
        // A genuine no-op — including "that crew was never on the rail" —
        // writes nothing at all, rather than materializing the shipped
        // catalog into an explicit `rail` key for a remove that changed
        // nothing.
        guard rail.count != countBefore else { return }
        updated.railSessions = rail
        // Unpinning a crew takes it out of its group too (CQ·184): a
        // member naming a crew no longer on the rail is otherwise only
        // "ignored" by the epic's own degrade-gracefully rule, which would
        // leave a stale reference sitting in `groups` until the crew is
        // re-pinned and silently rejoins a group nobody chose for it again.
        updated.groups = removingMember(crew, from: updated.groups)
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
        guard let index = rail.firstIndex(where: {
            refMatches(crew, row: $0, hosts: updated.hosts, defaultHost: updated.defaultHost)
        }) else { return }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, rail[index].displayName != trimmed else { return }
        rail[index].displayName = trimmed
        updated.railSessions = rail
        commit(updated)
    }

    /// Opens or folds a group — a click on its heading (toggling), or a
    /// selection landing on one of its members while it is folded (forcing
    /// it open, never closed). `group` is matched by full value, the same
    /// identity `RailView` rendered it from, since a group carries no id of
    /// its own; a mismatch (another edit beat this one to `configuration`)
    /// is a no-op rather than a wrong group's fold flipping.
    func setGroupFolded(_ group: CrewGroup, folded: Bool) {
        var updated = configuration
        guard let index = updated.groups.firstIndex(of: group), group.folded != folded else { return }
        updated.groups[index].folded = folded
        commit(updated)
    }

    // MARK: - Groups (CQ·184)

    /// Matches a caller-supplied ref against a rail row on the RESOLVED
    /// host, not the raw stored one. `row.host` can be sparse — nil for a
    /// default-host row, the way `CrewMerge.sparse` leaves it once any
    /// `setRoster` commit has run this session — while `ref` is typically
    /// built from the merged crews list `ContentView` draws (`Crew.ref`),
    /// which fills a served crew's host from its resolved target. Comparing
    /// `ref` as written against `row.ref` failed that case outright: not a
    /// mismatched group membership, but `removeCrew`/`setParent` finding no
    /// row at all to act on (CQ·189).
    private func refMatches(_ ref: SessionRef, row: Crew, hosts: [HostEntry], defaultHost: String?) -> Bool {
        ref.name == row.id
            && CrewMerge.resolvedHostKey(forHostName: ref.host, hosts: hosts, defaultHost: defaultHost)
                == CrewMerge.crewHostKey(for: row, hosts: hosts, defaultHost: defaultHost)
    }

    /// Takes `crew` out of whatever group it belongs to, leaving every other
    /// group untouched. Shared by every mutator below that moves a crew
    /// somewhere else — "Remove from Group", a move into a different group,
    /// `createGroup`'s own "take it out of its old group first" step, and
    /// `removeCrew`/`setRoster` unpinning it from the rail altogether. A
    /// group left with no members is dropped outright rather than kept as
    /// an empty heading nothing could ever draw (CQ·184 bullet 1: "A group
    /// that loses its last member through a move or a removal is deleted").
    private func removingMember(_ crew: SessionRef, from groups: [CrewGroup]) -> [CrewGroup] {
        groups.compactMap { group in
            guard group.members.contains(crew) else { return group }
            var updated = group
            updated.members.removeAll { $0 == crew }
            return updated.members.isEmpty ? nil : updated
        }
    }

    /// The same pruning as `removingMember`, run over every group at once
    /// against a set of still-live refs rather than one removed ref — what
    /// `setRoster` needs, since a roster edit can take several crews off the
    /// rail in one commit (a drag, a bulk unpin) and each one's membership
    /// has to go the same way `removeCrew`'s single-crew path already does.
    private func pruningGroups(_ groups: [CrewGroup], keeping liveRefs: Set<SessionRef>) -> [CrewGroup] {
        groups.compactMap { group in
            var updated = group
            updated.members = group.members.filter { liveRefs.contains($0) }
            return updated.members.isEmpty ? nil : updated
        }
    }

    /// "New Group…" from a crew's rail context menu — creates a group
    /// holding only `crew`, taking it out of whatever group it was already
    /// in first (a crew can move straight from one group into a brand-new
    /// one). A name that trims to empty, or already names another group, is
    /// refused outright and nothing commits: `RailNesting.DrawItem`
    /// identifies a group as `"group:<name>"`, so two groups sharing a name
    /// would collide on SwiftUI list identity (PR #397's security review).
    func createGroup(named name: String, firstMember crew: SessionRef) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !configuration.groups.contains(where: { $0.name == trimmed }) else { return }
        var updated = configuration
        updated.groups = removingMember(crew, from: updated.groups)
        updated.groups.append(CrewGroup(name: trimmed, members: [crew], folded: false))
        commit(updated)
    }

    /// "Move to Group ▸" — moves `crew` into the existing group named
    /// `groupName`, taking it out of any group it already belonged to
    /// first. A no-op when no group has that name — the menu only ever
    /// offers a real one, so this is defence in depth against a stale
    /// caller, the same posture every other mutator here takes.
    func moveCrew(_ crew: SessionRef, toGroup groupName: String) {
        guard configuration.groups.contains(where: { $0.name == groupName }) else { return }
        var updated = configuration
        updated.groups = removingMember(crew, from: updated.groups)
        guard let index = updated.groups.firstIndex(where: { $0.name == groupName }) else { return }
        if !updated.groups[index].members.contains(crew) {
            updated.groups[index].members.append(crew)
        }
        commit(updated)
    }

    /// "Remove from Group" — a no-op for a crew that is not in any group.
    func removeCrewFromGroup(_ crew: SessionRef) {
        let before = configuration.groups
        let after = removingMember(crew, from: before)
        guard after != before else { return }
        var updated = configuration
        updated.groups = after
        commit(updated)
    }

    /// Renames a group from Settings › Sessions. Refused the same way
    /// `createGroup` refuses a name — empty, or already another group's —
    /// and a no-op for a group not currently in `groups` (matched by value,
    /// like `setGroupFolded`) or a name that is already exactly its own.
    func renameGroup(_ group: CrewGroup, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != group.name else { return }
        var updated = configuration
        guard let index = updated.groups.firstIndex(of: group),
              !updated.groups.contains(where: { $0.name == trimmed })
        else { return }
        updated.groups[index].name = trimmed
        commit(updated)
    }

    /// Deletes a group from Settings › Sessions, leaving its members on the
    /// rail exactly where they already sit — ungrouped, per the epic
    /// specification: "Deleting a group leaves its members on the rail
    /// ungrouped." A no-op for a group not currently in `groups`, matched
    /// by value like `setGroupFolded`.
    func deleteGroup(_ group: CrewGroup) {
        var updated = configuration
        guard let index = updated.groups.firstIndex(of: group) else { return }
        updated.groups.remove(at: index)
        commit(updated)
    }

    /// Settings › Sessions' up/down reorder — swaps `group` with whichever
    /// top-level draw item sits immediately before (`up: true`) or after
    /// (`up: false`) it, over `roster`'s own merged crews — the same ones
    /// the rail itself draws, never `configuration.railSessions` directly,
    /// so a crew served but not yet written into `rail` still moves with
    /// its group. See `SessionRoster.movingGroup`'s doc for why that
    /// distinction matters and how a crew with no `rail` row yet survives
    /// the write. Persists through `setRoster`, the same materialize-sparse
    /// path every other structural roster edit already takes. A no-op when
    /// the group has no neighbor in that direction (already first/last) or
    /// draws nowhere at all right now.
    func moveGroup(_ group: CrewGroup, up: Bool, in roster: SessionRoster) {
        var updated = roster
        guard updated.movingGroup(
            group, up: up, groups: configuration.groups,
            hosts: configuration.hosts, defaultHost: configuration.defaultHost)
        else { return }
        setRoster(updated)
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
        let removed = updated.hosts.filter { $0.name == name }
        guard !removed.isEmpty else { return }
        updated.hosts.removeAll { $0.name == name }
        if updated.defaultHost == name { updated.defaultHost = nil }
        commit(updated)
        // A removed host's Library forward goes with it (CQ·162).
        for entry in removed {
            LibraryHostConnectionPool.shared.close(SSHTarget(user: entry.user, host: entry.address))
        }
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
        guard let index = rail.firstIndex(where: {
            refMatches(crew, row: $0, hosts: updated.hosts, defaultHost: updated.defaultHost)
        }) else { return }
        rail[index].parent = parentId
        updated.railSessions = rail
        // A grouped crew leaves its group the moment nesting actually takes
        // it off the top level (CQ·184 follow-up) — `CrewGroup`'s own doc
        // says membership is only ever a top-level ref, and once nested,
        // the rail's context menu hides every group item for it
        // (`isTopLevel` gates them off), leaving no UI path to clear a
        // stale membership otherwise. Checked AFTER the write, the same way
        // `isTopLevel` is always derived, rather than assumed from
        // `parentId` being non-nil: a parent id that fails
        // `nestingParent`'s own rule (no match, a cycle, another host)
        // leaves `crew` top-level still, and its group membership
        // untouched.
        if !RailNesting.isTopLevel(rail[index], in: rail, hosts: updated.hosts, defaultHost: updated.defaultHost) {
            updated.groups = removingMember(crew, from: updated.groups)
        }
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
        SSHConnectionGate.shared.applyHostCaps(updated.hosts)
        do {
            try updated.save(to: fileURL)
        } catch {
            saveError = "Could not save preferences: \(error.localizedDescription)"
        }
    }
}
