import SwiftUI

/// What occupies the right-hand column beside the conversation.
///
/// Exactly one occupant at a time — the spec's requirement. The two-boolean
/// state that preceded this allowed both `showingShellPane` and
/// `showingLocalTerminal` to be true at once, producing a split nobody asked
/// for. This enum is the authority; setting it to a new case implicitly closes
/// whatever was there before.
///
/// NOT `private` — the toggle helpers below are pure and unit-tested from
/// `Tests/DeckTests`, which needs `@testable import Deck` to see the type at
/// all. `private` is file-scoped regardless of `@testable`, so the type
/// stayed internal rather than public: nothing outside this module needs it.
enum ColumnOccupant: Hashable, Sendable {
    /// The cockpit: the Course, the current epic's interior, and the
    /// corrections queue. The default — every other occupant is something a
    /// reader summoned, and closing it reveals this rather than a blank
    /// strip.
    case cockpit
    /// A scratch shell on the mini in the selected session's working directory.
    case remoteShell
    /// A local terminal on this machine.
    case localTerminal
    /// The read-only file viewer, showing the file at the given validated ref,
    /// on the host it was opened from.
    case viewer(ref: DeckOpenRef.Origin, target: SSHTarget)
    /// The WYSIWYG editor on the same file, entered from the viewer.
    case editor(ref: DeckOpenRef.Origin, target: SSHTarget)
    /// The item detail pane: a Library item's full body and comment thread,
    /// with the actions that write it back. Opened either by clicking a
    /// corrections-queue row, or by a `deck-open:?origin=item&ref=…` link —
    /// the two arrive at the same pane because both name a Library item, and
    /// nothing about the pane depends on which route found it. Named
    /// `.item` rather than `.correction` because it renders any item this
    /// way opens, not only one drawn from the corrections queue.
    case item(id: String, target: SSHTarget)
    /// The run pane for one Dispatched row: the run's agent, model and full
    /// dispatch instruction. It holds only the `run_id`; the pane looks the
    /// run up in the live list on every draw, so a run that has ended keeps
    /// its pane and says so. Needs no host: it reads what the rail already
    /// polls.
    case run(runId: String)
    /// The reviews pane for one pull request: every review record on file
    /// for it, prose and findings included, read from the Library
    /// (`issue_01M3830X3DXRZDJFB8657YRCMK`). `headSha` is the PR's head
    /// commit as last read by the Pull Requests panel, carried along so the
    /// pane can mark each record reviewed-at-head without a second fetch —
    /// see `ReviewRecordsPane.headSha`'s doc.
    case reviewRecords(repo: String, pr: Int, headSha: String?, target: SSHTarget)
    /// The Slate sheet for one crew: the asks its co has posted for the
    /// operator, open to answer and send
    /// (issue_01M3WPYD8M0P8PD20Y3ZBNGBWG). `session` is the crew's tmux
    /// session name, the same key `session-agent slate` takes — carried
    /// explicitly, like `.item`'s id, rather than read back from `selection`
    /// at render time, since the rail badge this item leaves a hook for
    /// (issue_01M3WPYSH0S1FZVZ6P3YMNJGXW) opens a crew's Slate independent of
    /// whichever session is currently selected. `crew` is the rail row the
    /// Slate was opened for, recorded from the toolbar segment or the badge.
    /// Two crews can share a session name on different hosts, so the name and
    /// target alone cannot say which crew a Slate belongs to.
    case slate(session: String, target: SSHTarget, crew: SessionRef)
}

extension ColumnOccupant {
    /// What the local-terminal toggle button produces: off when it was
    /// already showing, on otherwise — closing REVEALS THE COCKPIT rather
    /// than a blank strip, which is the whole reason `.cockpit` replaced
    /// `.none` as this enum's rest state. Pure, so the transition is
    /// testable without a view.
    static func togglingLocalTerminal(from current: ColumnOccupant) -> ColumnOccupant {
        current == .localTerminal ? .cockpit : .localTerminal
    }

    /// The remote-shell toggle's counterpart to `togglingLocalTerminal` —
    /// see that function's doc.
    static func togglingRemoteShell(from current: ColumnOccupant) -> ColumnOccupant {
        current == .remoteShell ? .cockpit : .remoteShell
    }

    /// What a click on a Dispatched row produces: that run's pane, or the
    /// cockpit again when that run's pane is already the one open. From any
    /// other occupant, including another run's pane, the click opens this
    /// run's, so selecting a second row follows the selection.
    static func togglingRun(_ runId: String, from current: ColumnOccupant) -> ColumnOccupant {
        current == .run(runId: runId) ? .cockpit : .run(runId: runId)
    }

    /// Where the right column goes when the rail selection moves from one
    /// crew to another. A Slate is the one occupant that follows the
    /// selection: when the column holds a Slate that was opened for the crew
    /// being left, it moves to the new crew's Slate, or to the cockpit when
    /// the new crew has no reachable Slate. Any other occupant stays where it
    /// is, including a Slate the rail badge opened for a crew that was not
    /// selected, even one that shares the crew being left's session name on
    /// another host.
    ///
    /// "Opened for" is the full `SessionRef` of the rail row, host included,
    /// so the match is by crew identity. The crew's target is not compared:
    /// its host may have changed, or stopped resolving, since the Slate
    /// opened, and the round-1 case still follows. `leaving` is `nil` when
    /// there was no crew to leave. `entering` is the crew now selected, `nil`
    /// for the Local shell or no selection; those keep the column's Slate
    /// unchanged. `newSelectionSlate` is built from the new crew's own
    /// reference and is `nil` when that crew has no resolved host, which is
    /// the only case that returns the column to the cockpit.
    static func followingSelection(
        from current: ColumnOccupant,
        leaving: SessionRef?,
        entering: SessionRef?,
        newSelectionSlate: ColumnOccupant?
    ) -> ColumnOccupant {
        guard let leaving,
              case .slate(_, _, let crew) = current,
              crew == leaving,
              entering != nil
        else { return current }
        return newSelectionSlate ?? .cockpit
    }

    /// The selection's own Slate segment, when it stands for the Slate the
    /// column holds: both are for the same crew. The crew's target is not
    /// compared, so a column Slate opened before the host was edited still
    /// matches. `nil` when the column holds no Slate, or holds one for a
    /// crew other than the selection's. `nil` also when the selection offers
    /// no Slate, since then the column's own Slate needs a segment of its own.
    static func selectionSlateCovering(
        _ column: ColumnOccupant,
        selectionSlate: ColumnOccupant?
    ) -> ColumnOccupant? {
        guard case .slate(_, _, let crew) = column,
              let selectionSlate,
              case .slate(_, _, let selectedCrew) = selectionSlate,
              selectedCrew == crew
        else { return nil }
        return selectionSlate
    }

    /// The column's occupant after its crew's host has changed. A Slate in
    /// the column follows the Slate its crew has now, built from the crew's
    /// own ref by `slateOccupant(for:)`, so the pane polls and writes the
    /// target the picker shows. When that crew's host no longer resolves,
    /// the column returns to the cockpit, the same as `followingSelection`
    /// does for a crew with no reachable host. Any other occupant is returned
    /// unchanged, and `currentSlate` is not consulted for it.
    ///
    /// `currentSlate` is asked only about the column's own crew, so a host
    /// edit to a different crew never moves this column.
    static func repointingToCrewSlate(
        _ column: ColumnOccupant,
        currentSlate: (SessionRef) -> ColumnOccupant?
    ) -> ColumnOccupant {
        guard case .slate(_, _, let crew) = column else { return column }
        return currentSlate(crew) ?? .cockpit
    }
}

struct ContentView: View {
    @State private var selection: SessionRef?
    /// The last detail the run pane built for each run while it was still
    /// listed. `RunDetail.make` draws it once the run leaves the list.
    @State private var lastListedRunDetails: [String: RunDetail] = [:]
    @State private var phase: ConnectionStateMachine.Phase = .connecting

    /// Shared with the menu bar, which lives at App scope and cannot reach a
    /// view's `@State`. One owner, so the font-size shortcuts and the canvas
    /// never disagree.
    @EnvironmentObject private var store: ThemeStore
    @EnvironmentObject private var server: WorkingCopyServer

    /// Polls the mini for every rail session's liveness and phase, so a row can
    /// decorate itself and grey out when its session is not running. One poll for
    /// the whole rail; the open pane keeps its own closer one.
    ///
    /// OWNED IN `DeckApp`, NOT HERE, since `servedCrews` also has to reach
    /// `SessionsSettingsView` in the separate `Settings` scene — the same
    /// reason `store` is hoisted there rather than kept as this view's own
    /// `@StateObject`.
    @EnvironmentObject private var railState: RailStateModel

    /// The logged-out alerts (CQ·124, CQ·130) — owned in `DeckApp`, for the
    /// same cross-scene reason `railState` is.
    @EnvironmentObject private var desktopAlerts: DesktopSessionAlertCenter

    /// Reached here only for `openRunbookLink`'s no-runbook-link fallback,
    /// which switches Settings to the Hosts tab and selects the host's row
    /// (`SettingsNavigation.openHostsSettings`) — every other use of
    /// navigation lives in the nested views that already carry this.
    @EnvironmentObject private var navigation: SettingsNavigation

    /// Guards `evaluateStewardAtLaunch` to exactly one run per launch — see
    /// that method's doc.
    @State private var stewardLaunchEvaluated = false

    /// A session's typed-but-unsent composer text, surviving the `.id()`
    /// teardown `mainPane` forces on every session switch. Owned here,
    /// above that boundary, and handed to `SessionPaneView` as a reference
    /// rather than a `Binding` into this view's own `@State` — see
    /// `SessionDraftStore`'s doc for why a `Binding` broke sending in #153.
    @StateObject private var draftStore = SessionDraftStore()

    /// The session waiting on the user's confirmation to be stopped, or nil.
    /// Stopping kills the tmux session, which is destructive, so it asks first.
    @State private var sessionToStop: SessionRef?
    /// A row's "Roll Over Now…" waiting on its confirm.
    @State private var rolloverToForce: SessionRef?

    /// The crew waiting on the user's confirmation to be removed from
    /// Deck, or nil. Removing is config-only — it never touches the mini's
    /// filesystem or a running session — but it still asks first, so a
    /// misclick does not lose a display name, a working directory override,
    /// or a set of pinned children. See
    /// `deck/specs/multiple-sessions-per-project` §"Remove".
    @State private var crewToRemove: Crew?

    /// The pinned child waiting on the user's confirmation to be removed
    /// from Deck, or nil — the same confirm machinery as `crewToRemove`,
    /// one level down. See
    /// `deck/specs/multiple-sessions-per-project` §"Remove" and the operator's
    /// call to mirror the crew's own semantics exactly.
    @State private var childToRemove: (crew: Crew, session: PinnedSession)?

    /// The "OTHER SESSIONS" row waiting on the user's confirmation to be
    /// promoted to its own crew, or nil. See
    /// `deck/specs/multiple-sessions-per-project` §"An OTHER SESSIONS row
    /// can be adopted into a crew but cannot BECOME one".
    @State private var sessionToPromote: DiscoveredSession?

    /// The catalog entry waiting on the user's confirmation to be removed
    /// from Deck, or nil — the same confirm machinery as `crewToRemove`, for
    /// a `START` row rather than a rail one. See
    /// `deck/specs/multiple-sessions-per-project` §"The rail": "A way out
    /// that only a right-click reveals is not a way out."
    @State private var catalogEntryToRemove: LaunchableSession?

    /// The shell reads the system appearance in exactly one place, here, and
    /// hands the resolved value down. This is the appearance-authority rule
    /// from CLAUDE.md: surfaces are told what to be in the same frame, so a
    /// light rail can never end up beside a dark pane.
    @Environment(\.colorScheme) private var systemColorScheme

    /// The window's own measured width, kept in sync from `body`'s outer
    /// `GeometryReader` — see `isRailCollapsed`/`usesColumnSheet`. Distinct
    /// from the pane row's `GeometryReader` deeper in `body`, which measures
    /// only `mainPane` + the column and feeds `columnWidth(totalWidth:)`;
    /// that arithmetic is unchanged by this phase, so it keeps its own,
    /// narrower measurement rather than sharing this one.
    @State private var windowWidth: CGFloat = LayoutBreakpoints.windowMinWidth

    /// The height of the toolbar row above the panes, measured where it is
    /// laid out. Under Builder Default the rail starts its first row this far
    /// down, on the session pane's top line (CQ·153); see `RailView.topInset`.
    @State private var paneChromeHeight: CGFloat = 0

    /// Below `LayoutBreakpoints.railCollapse` — see `RailView.isCollapsed`'s
    /// doc.
    private var isRailCollapsed: Bool {
        LayoutBreakpoints.isRailCollapsed(totalWidth: Double(windowWidth))
    }

    /// Below `LayoutBreakpoints.columnSheet` — the right column stops
    /// splitting the row and arrives as a sheet instead. See
    /// `isColumnSheetPresented`'s doc for how the sheet's own visibility is
    /// tracked separately from this threshold.
    private var usesColumnSheet: Bool {
        LayoutBreakpoints.usesColumnSheet(totalWidth: Double(windowWidth))
    }

    /// Whether the sheet (narrow layout only) is currently summoned.
    /// Ignored entirely in the wide layout, where the column always shows —
    /// see `ColumnOccupant`'s doc for why `.cockpit` is that layout's rest
    /// state rather than "closed." Defaults `false`: "the cockpit leaves"
    /// is `04-narrow.html`'s own default narrow state, not something the
    /// column falls back into showing.
    ///
    /// SET ONLY AT THE CALL SITES THAT CHANGE `columnOccupant` — see
    /// `presentColumnOccupant`/`closeColumnOccupant` — rather than from a
    /// generic `.onChange(of: columnOccupant)`, which cannot tell "the user
    /// asked to see something new" from "closing X reset this to
    /// `.cockpit`" and would reopen the sheet the moment a close callback
    /// ran.
    @State private var isColumnSheetPresented = false

    /// The Slate sends in flight, for the whole process. Not in `SlatePane`, so a
    /// send outlives the sheet that started it, and not in this view's `@State`,
    /// so it outlives the window too. A plain reference rather than an observed
    /// object, so ContentView does not redraw on each send; `SlateModel` forwards
    /// the changes to its own sheet.
    private var slateSends: SlateSendRegistry { .shared }

    /// Sets the right column's content and, in the narrow layout, summons
    /// the sheet that shows it. A harmless extra write in the wide layout,
    /// where `isColumnSheetPresented` is never consulted.
    private func presentColumnOccupant(_ occupant: ColumnOccupant) {
        columnOccupant = occupant
        isColumnSheetPresented = true
    }

    /// Returns the right column to its cockpit rest state and, in the
    /// narrow layout, dismisses the sheet entirely — see
    /// `isColumnSheetPresented`'s doc.
    private func closeColumnOccupant() {
        columnOccupant = .cockpit
        isColumnSheetPresented = false
    }

    /// The sheet's fixed width — `design/redesign/04-narrow.html`'s
    /// `.sheet` (340px). Unlike the docked column, the sheet does not share
    /// the divider-drag width `ThemeConfiguration.columnWidth` stores: it
    /// overlays the conversation rather than sharing the row with it, so
    /// there is no adjacent pane for a drag to steal width from.
    static let sheetWidth: CGFloat = 340

    /// The width of the green band down the cockpit's right edge under Builder
    /// Default. The band is laid out beside the cockpit and takes this width out
    /// of the column, so the cockpit's header, refresh button and rows keep their
    /// padding inside the narrower body.
    static let cockpitFrameBandWidth: CGFloat = 12

    private var configuration: ThemeConfiguration { store.configuration }

    /// The rail's rows: config's own rail (or `CrewCatalog.known` when the
    /// user has none — empty today, see that fallback's doc comment) merged
    /// with whatever the steward has served since the last poll landed. See
    /// `CrewMerge` for the match-and-fill rule — this is what lets a crew
    /// made through `new-crew`, with no local config at all, reach the rail.
    private var crews: [Crew] {
        CrewMerge.merge(
            configured: configuration.railSessions ?? CrewCatalog.known,
            served: Array(railState.servedCrews.values),
            hosts: configuration.hosts, defaultHost: configuration.defaultHost)
    }

    /// Maps a pinned sibling session to the crew row that owns it — a
    /// child's directory, launch command, resolved host and theme fallback.
    ///
    /// Keyed by `SessionRef`, so two crews sharing a child's name on
    /// different hosts are two entries. There used to be a second,
    /// bare-name-keyed copy of this map beside it, for theme fallback alone,
    /// on the grounds that resolving the wrong crew there cost a colour
    /// rather than a box; theme storage is host-scoped now, so the colour has
    /// the same answer as everything else and one map serves both.
    private var childParentByRef: [SessionRef: Crew] {
        var map: [SessionRef: Crew] = [:]
        for crew in crews {
            for child in crew.sessions { map[SessionRef.owned(by: crew, name: child.name)] = crew }
        }
        return map
    }

    /// `childParentByRef` for sessions `session-agent sessions` found rather
    /// than ones Deck pinned — computed fresh from the rail's last discovery
    /// poll by the same rules `RailView` groups its tree with
    /// (`SessionGrouping`), which already enforces the host boundary, so a
    /// discovered session grouped under a crew here is grouped under the
    /// RIGHT crew regardless of what its name also matches on another host.
    private var discoveredParentByRef: [SessionRef: Crew] {
        let groups = SessionGrouping.group(
            Array(railState.discovered.values), into: crews,
            hosts: configuration.hosts, defaultHost: configuration.defaultHost)
        var map: [SessionRef: Crew] = [:]
        for crew in crews {
            for discovered in groups[crew.id] ?? [] where discovered.name != crew.id {
                map[SessionRef.owned(by: crew, name: discovered.name)] = crew
            }
        }
        return map
    }

    /// The crew that owns `ref` — itself, a pinned child, or a discovered
    /// child — or nil for a catalog-only or orphaned session. The single
    /// host-aware replacement for the three-way name search every directory,
    /// command, and host lookup used before hosts existed: a name search
    /// could not tell two same-named crews on different hosts apart, exactly
    /// the ambiguity `SessionRef` exists to remove.
    private func owningCrew(for ref: SessionRef) -> Crew? {
        if let crew = crews.first(where: { $0.ref == ref }) {
            return crew
        }
        return childParentByRef[ref] ?? discoveredParentByRef[ref]
    }

    /// Every co session the rail draws — pinned rows, their pinned children,
    /// catalog entries, and discovered sessions once the rail has learned of
    /// them — so the rail poller watches each. Deduplicated, since a session
    /// can appear in more than one of those, and there is no point polling it
    /// twice.
    ///
    /// EACH REF CARRIES ITS OWN HOST, so `RailStateModel.states` can key on
    /// it directly rather than a bare name search — see
    /// `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// hosts": "identity becomes `(host, session name)`".
    ///
    /// DISCOVERED REFS COME FROM THE SAME POLL TICK THEY ARE DRAWN FROM, not
    /// from a separate lookup — `railState.discovered` is itself the rail's
    /// last discovery reading, so there is no chicken-and-egg dependency: a
    /// session discovered this tick is simply not yet in this list, and picks
    /// up its liveness mark on the next one, per
    /// `deck/specs/multiple-sessions-per-project`.
    private var railSessionRefs: [SessionRef] {
        var seen = Set<SessionRef>()
        let ownRefs = crews.map { SessionRef.owned(by: $0, name: $0.id) }
        let childRefs = crews.flatMap { crew in crew.sessions.map { SessionRef.owned(by: crew, name: $0.name) } }
        let catalogRefs = configuration.catalog.map { SessionRef(host: $0.host, name: $0.id) }
        let discoveredSessions = Array(railState.discovered.values)
        let ownedDiscoveredRefs = Array(discoveredParentByRef.keys)
        let orphanedRefs = SessionGrouping.ungrouped(
            discoveredSessions, crews: crews,
            hosts: configuration.hosts, defaultHost: configuration.defaultHost
        ).map { SessionRef.orphaned($0, hosts: configuration.hosts) }
        return (ownRefs + childRefs + catalogRefs + ownedDiscoveredRefs + orphanedRefs)
            .filter { seen.insert($0).inserted }
    }

    /// Every session name already in play: crew ids, their pinned children,
    /// the catalog, and discovered names. A derived name (a new sibling, or a
    /// window promoted to its own session) is checked against all of them at
    /// once rather than the caller re-deriving the set per keystroke. The rail
    /// carried a matching set of its own until it went with the "+ New" crew
    /// sheet that was its only reader; this is now the only one.
    ///
    /// STAYS BARE-NAME KEYED: a derived name must not shadow any tmux name in
    /// play on ANY host, since Deck cannot stat a name's availability per host
    /// and a conservative, global check is the safer default.
    private var allKnownSessionNames: Set<String> {
        var names = Set(crews.map(\.id))
        for crew in crews {
            for child in crew.sessions { names.insert(child.name) }
        }
        names.formUnion(configuration.catalog.map(\.id))
        names.formUnion(railState.discovered.values.map(\.name))
        return names
    }

    /// `runningSessionCount(for:)` and `isChildRunning(_:_:)` used to live
    /// here as private funcs, each independently calling
    /// `RailStateModel.runningSessionNames`. A reviewer found that wiring
    /// untested: `RunningSessionNamesTests` pinned the rule the funcs
    /// called, but stubbing that rule cannot catch a call site that stops
    /// calling it, and reverting either func to its pre-fix `isStopped`
    /// shape still passed the full suite. `RailRunningSessions` is a plain,
    /// `View`-free struct holding that logic instead, directly constructible
    /// and assertable in a test — see `RailRunningSessionsTests`.
    ///
    /// The two Remove alerts below read `RemoveAlertShape` — the button's
    /// presence and the message's wording, computed together by
    /// `removeCrewAlertShape(for:)`/`removeChildAlertShape(for:_:)` — rather
    /// than each deriving its own `> 0` or count/flag mapping, so there is
    /// no `ContentView`-owned arithmetic left to diverge between the
    /// button's condition and the message's text.
    private var railRunningSessions: RailRunningSessions {
        RailRunningSessions(
            crews: crews, discovered: railState.discovered,
            hosts: configuration.hosts, defaultHost: configuration.defaultHost)
    }

    /// Every session a crew owns — itself, its pinned children, and its
    /// discovered children — regardless of whether it is currently live.
    /// Read by `removeCrewAndStopSessions` (which stops every name in this
    /// set, live or not, since a name reported stopped a beat ago by a
    /// stale poll should not be skipped). Forwards to
    /// `RailRunningSessions.crewSessionNames(for:)`.
    private func crewSessionNames(for crew: Crew) -> Set<String> {
        railRunningSessions.crewSessionNames(for: crew)
    }

    /// Whether `catalogEntryToRemove` has a real tmux session behind it —
    /// pulled out to its own property, the same reason `railRunningSessions`
    /// is one, so the Remove-confirm's `message:` closure stays a single
    /// function call the type checker can solve quickly rather than an
    /// inline `SessionRef` construction and `hasTmuxSession` call.
    private var isCatalogEntryToRemoveRunning: Bool {
        guard let entry = catalogEntryToRemove else { return false }
        return railState.hasTmuxSession(
            SessionRef(host: entry.host, name: entry.id),
            hosts: configuration.hosts, defaultHost: configuration.defaultHost)
    }

    /// The human name for a session, from the rail, a pinned child, or the
    /// catalog, falling back to the name itself for a session typed into the
    /// new-session field. A DISCOVERED session is deliberately not checked
    /// here, matching `RailChildRow`'s own rule ("no display name of its
    /// own — its tmux name is drawn as-is"), so this stops at pinned
    /// children rather than reaching for `owningCrew(for:)`, which would
    /// also match a discovered child and wrongly return its CREW's name.
    private func displayName(for ref: SessionRef) -> String {
        if let crew = crews.first(where: { SessionRef.owned(by: $0, name: $0.id) == ref }) {
            return crew.displayName
        }
        if let crew = childParentByRef[ref], let child = crew.sessions.first(where: { $0.name == ref.name }) {
            return child.displayName
        }
        if let entry = configuration.catalog.first(where: { SessionRef(host: $0.host, name: $0.id) == ref }) {
            return entry.displayName
        }
        return ref.name
    }

    /// A session's resolved theme — its own mapping if it has one, else, for a
    /// pinned or discovered child with none of its own, its crew's (design
    /// §A: "a child session with no theme of its own resolves to its
    /// crew's"), else the hashed default `ThemeConfiguration.theme(forSession:)`
    /// gives any unmapped session.
    ///
    /// A NESTED CREW RESOLVES THROUGH `RailNesting.nestingParent`, the same
    /// rule that decides whether it draws nested at all (design §"Accent
    /// inheritance"): only checked once `key` matches neither a pinned nor
    /// a discovered child, since those two already found their crew.
    ///
    /// A WINDOW LEAF RESOLVES THROUGH ITS OWNING SESSION. `WindowLeaf.parse`
    /// strips a leaf's `"<session>:<n>"` selection down to the session that
    /// owns it before any of the lookups above run, so a leaf reads exactly
    /// the theme its owning row already draws rather than falling through to
    /// the hashed default for an id nothing maps.
    ///
    /// HOST-QUALIFIED THROUGHOUT, which is what let two bare-name maps
    /// (`childParent`, `discoveredParent`) go: they existed only to answer
    /// this one question, and each resolved a name shared across two hosts to
    /// whichever crew it happened to find first. Theme storage is keyed by
    /// `SessionRef` now, so the `ByRef` maps the rest of `ContentView`
    /// already used answer it exactly.
    private func themeForSession(_ ref: SessionRef) -> TerminalTheme {
        let key = SessionRef(host: ref.host, name: WindowLeaf.parse(ref.name)?.session ?? ref.name)
        let parent = childParentByRef[key] ?? discoveredParentByRef[key]
            ?? crews.first { $0.ref == key }.flatMap {
                RailNesting.nestingParent(of: $0, in: crews, hosts: configuration.hosts,
                                          defaultHost: configuration.defaultHost)
            }
        return configuration.theme(forSession: key, fallbackParent: parent?.ref)
    }

    /// The rail carries a `SessionRef`; the local shell uses a reserved ref
    /// (`SessionRef.localShell`) whose name contains a colon, which
    /// `validateTmuxSessionName` rejects, so a tmux session can never
    /// collide with it.
    ///
    /// A selection with no matching row gets no working directory rather than no
    /// session: the "new session" field accepts any valid name, and a session
    /// typed there should still connect.
    ///
    /// A WINDOW LEAF ATTACHES TO ITS OWNING SESSION, not to a tmux session
    /// literally named `"<session>:<n>"` — that name would fail
    /// `validateTmuxSessionName` outright. `WindowLeaf.parse` recovers the
    /// owning session (host included) before the lookup below runs.
    /// Nil exactly when `hostTarget(for:)` is — a ref whose host does not
    /// resolve to anything has nothing to attach a terminal to, and callers
    /// must treat that as "unavailable" rather than reach for a default that
    /// no longer exists. `.localShell` is the one exception: it names no
    /// host at all, so it resolves regardless of `configuration.hosts`.
    private func target(for ref: SessionRef) -> TerminalTarget? {
        guard ref != .localShell else { return .localShell }
        let key = WindowLeaf.parse(ref)?.session ?? ref
        guard let sshTarget = hostTarget(for: key) else { return nil }
        return .remoteSession(
            name: key.name,
            workingDirectory: owningCrew(for: key)?.workingDirectory,
            target: sshTarget)
    }

    /// The `SSHTarget` a ref's config host name resolves to, or nil when it
    /// resolves to nothing — see `HostResolution`. Every ssh-driving call
    /// site resolves through here rather than each re-deriving it, so the
    /// terminal, the conversation pane, and the rail poll can never
    /// disagree about which box a session is on, and can never disagree
    /// about whether one is even configured.
    ///
    /// A NIL RESULT MEANS THE ACTION IS UNAVAILABLE, NOT THAT ONE SHOULD BE
    /// INVENTED. Every caller either declines to act (an unresolved crew's
    /// Start, Stop, or terminal attach) or renders the "no host configured"
    /// state instead of guessing — see
    /// `deck/specs/running-deck-as-someone-else`.
    ///
    /// TRIVIAL NOW, DELIBERATELY: `ref.host` IS the config key already —
    /// the crew, catalog, or child row this ref was built from carries it
    /// directly — so this needs no search across `crews`/`catalog` the way
    /// the phase-6a bare-name `HostResolution.target(forSession:...)` did.
    /// That is the whole point of `SessionRef`: a ref built once, from the
    /// row that owns it, never needs its host re-derived by name.
    private func hostTarget(for ref: SessionRef) -> SSHTarget? {
        HostResolution.target(
            forHostName: ref.host, hosts: configuration.hosts, defaultHost: configuration.defaultHost)
    }

    /// The rail's Slate badge was clicked (issue_01M3WPYSH0S1FZVZ6P3YMNJGXW).
    /// Opens the cockpit on `ref`'s own Slate — `ref` is always a crew's own
    /// row here, never a child's, so its name is the tmux session name
    /// `session-agent slate` takes. A crew whose host does not resolve has
    /// nothing to reach the Slate through, the same "unavailable, not
    /// invented" rule `target(for:)` follows, so the click is silently
    /// declined rather than opening a pane with no host to poll.
    private func openSlate(for ref: SessionRef) {
        guard let target = hostTarget(for: ref) else { return }
        presentColumnOccupant(.slate(session: ref.name, target: target, crew: ref))
    }

    /// The other half of `StewardCrew.shouldCreate`'s self-healing besides
    /// `HostsSettingsView.createStewardIfNeeded`. That one only runs when
    /// the operator adds a host from Settings, which only happens while
    /// Settings is open — a host that comes up unreachable on the ONE host
    /// a fresh install has leaves an empty rail with no further Settings
    /// action to retrigger it. This is what makes that retry happen on the
    /// very next launch instead, with no operator action needed at all.
    ///
    /// Called from the one-shot `.task` in `body` — no `id:`, so it runs
    /// once for this view's lifetime rather than on every rail poll.
    /// `stewardLaunchEvaluated` backs that up explicitly rather than relying
    /// on the `.task` alone, the same one-shot discipline
    /// `addHostRequestToken` consuming uses in `HostsSettingsView`.
    ///
    /// Fires no alert on success, unlike `HostsSettingsView`'s
    /// `stewardJustCreated` note. That note fits a Settings pane the
    /// operator is already looking at and just took an action in; a modal
    /// over the MAIN window on every fresh launch, for something the
    /// operator never asked for, is not the same kind of interruption — the
    /// new "Steward" row appearing on the rail is announcement enough, the
    /// same way any other discovered session arrives on the rail
    /// unannounced.
    ///
    /// RE-RUNS `HostsSettingsView.addHost`'s fetch-and-land step before
    /// creating, not just its pure `HostResolution.crewsRoot` lookup — see
    /// the comment inside for why: this is precisely the retry for a host
    /// whose real root never landed, so skipping the fetch here would leave
    /// it retrying forever against the fallback.
    private func evaluateStewardAtLaunch() {
        guard !stewardLaunchEvaluated else { return }
        stewardLaunchEvaluated = true
        guard let entry = StewardCrew.launchTarget(
            hosts: configuration.hosts, defaultHost: configuration.defaultHost,
            crews: crews, createInFlight: store.stewardCreateInFlight)
        else { return }
        store.stewardCreateInFlight = true
        let target = SSHTarget(user: entry.user, host: entry.address)
        let existingCrews = crews
        Task {
            // Re-run `HostsSettingsView.addHost`'s own fetch-and-land step
            // before creating, not just its pure `crewsRoot` lookup. A host
            // added while unreachable never got a real root landed into its
            // entry — `addHost` is the only place that ever writes one — so
            // without this, every launch retry keeps resolving through the
            // `~/Convivy` global fallback and never self-heals. That
            // fallback is itself correct and unchanged, per
            // platform/contracts/session-agent-api: "a consumer's job is to
            // stop proposing paths the floor will refuse, not to
            // re-implement the check: Deck defaults its crewsRoot to
            // ~/Convivy for exactly this reason, and adds no containment
            // check of its own, since it cannot stat a path on the mini
            // anyway." A failed fetch here is tolerated the same way
            // `addHost` tolerates it: the create still proceeds against
            // whatever root is currently on file.
            let fetchedRoot = await Task.detached {
                try? SessionAgent.crewsRoot(target: target)
            }.value
            let landed = HostsSettingsView.applyingFetchedRoot(
                fetchedRoot, toHostNamed: entry.name, in: store) ?? entry
            let crewsRoot = HostResolution.crewsRoot(
                forHostName: landed.name, hosts: store.configuration.hosts,
                defaultHost: store.configuration.defaultHost,
                globalCrewsRoot: store.configuration.crewsRoot)
            let directory = StewardCrew.directory(crewsRoot: crewsRoot)
            let outcome = await StewardCrew.attemptCreate(
                target: target, directory: directory, existingCrews: existingCrews)
            store.stewardCreateInFlight = false
            switch outcome {
            case .success(let created):
                guard created else { return }
                store.addCrew(Crew(id: StewardCrew.id, displayName: StewardCrew.displayName,
                                    workingDirectory: directory, host: entry.name))
            case .failure(let error):
                store.saveError = "Could not create the steward crew: \(error)"
            }
        }
    }

    /// The appearance `surface` draws in. Resolved here, once per surface, from
    /// the shell's own configuration; a surface never decides it for itself.
    private func appearance(for surface: AppearanceSurface) -> Appearance {
        configuration.appearance(for: surface, systemIsDark: systemColorScheme == .dark)
    }

    /// Pulled out of `body`, which is one large `ViewBuilder` expression the
    /// type checker solves as a whole — adding fields to this initializer's
    /// already-long argument list pushed it over the checker's time limit
    /// inline. Splitting the call into its own typed property gives the
    /// checker a much smaller expression to solve here, with no change to
    /// what gets drawn.
    private var rail: some View {
        RailView(
            crews: crews,
            accent: { themeForSession($0).palette(for: appearance(for: .rail)).cursor },
            mark: { railState.mark(for: $0) },
            isStopped: { railState.isStopped($0) },
            hasOpenGate: { railState.hasOpenGate($0) },
            isTerminalOnly: { isTerminalOnly($0) },
            contextMeter: { ref in
                ContextMeter.resolve(contextPercent: railState.states[ref]?.contextPercent,
                                     rollover: railState.states[ref]?.rollover)
            },
            runModelMark: { railState.runModelMark(for: $0) },
            asksOpen: { railState.asksOpen(for: $0) },
            onOpenSlate: { openSlate(for: $0) },
            rolloverActions: { ContextMeter.actions(for: railState.states[$0]?.rollover) },
            onRollover: { ref, action in
                if action == .force { rolloverToForce = ref } else { changeRollover(ref, action) }
            },
            rolloverSuccessorWindow: { WindowLeafRow.successorWindow(of: railState.states[$0]?.rollover) },
            themeMenu: { session in
                AnyView(
                    ThemePicker(
                        currentThemeName: themeForSession(session).name,
                        appearance: appearance(for: .rail),
                        onPick: { store.setTheme($0, forSession: session) },
                        onResetToDefault: { store.setTheme(nil, forSession: session) }
                    )
                )
            },
            catalog: configuration.catalog,
            onLaunch: launch,
            appearance: appearance(for: .rail),
            discoveredSessions: Array(railState.discovered.values),
            onMoveWindowToOwnSession: moveWindowToOwnSession,
            onRenameCrew: { crew, name in store.renameCrew(crew.ref, to: name) },
            onRequestRemoveCrew: { crewToRemove = $0 },
            onRequestRemoveChild: { crew, session in childToRemove = (crew, session) },
            onSetCrewParent: { crew, parentId in store.setParent(parentId, forCrew: crew.ref) },
            onStopDiscoveredSession: { sessionToStop = $0 },
            onAdoptSession: adoptSession,
            onRequestPromoteSession: { sessionToPromote = $0 },
            hasTmuxSession: { railState.hasTmuxSession($0, hosts: configuration.hosts, defaultHost: configuration.defaultHost) },
            onRequestRemoveCatalogEntry: { catalogEntryToRemove = $0 },
            hosts: configuration.hosts,
            defaultHost: configuration.defaultHost,
            probedMachineName: { railState.probedMachineName(for: $0) },
            isHostUnreachable: { railState.isHostUnreachable($0) },
            onOpenBead: openSelectedCrewBead(),
            beadHelp: beadAvailability.help,
            beadProgress: railBeadProgress,
            isCollapsed: isRailCollapsed,
            topInset: isBuilderDefault ? paneChromeHeight : 0,
            selection: $selection
        )
        .surfaceAppearance(configuration.pinnedSurface(for: .rail))
    }

    /// The selected crew's bead doc id, or nil, matching
    /// `RailView.onOpenBead`'s contract.
    ///
    /// PICKED, NOT DERIVED — see `Crew.bead`. `id`, `displayName`, and
    /// `project` are three naming spaces a bead's own doc id does not
    /// reliably agree with (`convivy-deck` → `deck/bead/deck`, `bosun` →
    /// `agent-platform/bead/agent-platform`), so nothing here guesses one
    /// from another; `Crew.bead` is set explicitly in Settings › Sessions
    /// from `LibraryClient.fetchBeadsList`'s own listing.
    private func selectedCrewBeadId() -> String? {
        CockpitResolution.beadId(for: selection.flatMap { owningCrew(for: $0) })
    }

    /// THE HOST COMES FROM THE SELECTION, NOT FROM THE COCKPIT'S RESOLUTION.
    /// This used to read `cockpitProjectAndTarget?.target`, which requires
    /// `crew.project` — so a crew carrying a bead and no project had a
    /// permanently disabled button, for a reason that has nothing to do with
    /// opening a document. `Crew.bead` and `Crew.project` are orthogonal by
    /// design. Found by `deck-reviewer` on #133.
    /// Whether the bead link can open, and if not why — ONE value, so the
    /// button's enabled state and its tooltip cannot disagree. They drifted
    /// twice when they were computed separately; see `BeadAvailability`.
    private var beadAvailability: CockpitResolution.BeadAvailability {
        CockpitResolution.beadAvailability(
            hasSelection: selection != nil,
            crew: selection.flatMap { owningCrew(for: $0) },
            target: selection.flatMap { hostTarget(for: $0) })
    }

    private func openSelectedCrewBead() -> (() -> Void)? {
        guard let open = beadAvailability.openable else { return nil }
        return { openViewer(.kb(id: open.beadId), target: open.target) }
    }

    /// The window's layout and its lifecycle handlers, without the alerts.
    ///
    /// SPLIT FROM `body` BECAUSE ONE CHAIN EXCEEDED THE TYPE CHECKER'S BUDGET.
    /// On Swift 6.3.3, which the laptop's self-updating launcher builds with,
    /// `swift build -c release` failed at the `.alert("Preferences not
    /// saved", …)` alert's `set:` line with "unable to type-check this
    /// expression in reasonable time" once #308 added an
    /// `onDesktopSessionLoggedOut:` closure argument to the `railState.track`
    /// task and an `.onChange(of: desktopAlerts.pendingRunbookOpen)`.
    /// Swift 6.4 on macstudio and the debug build CI runs both passed, so nothing
    /// caught it, and the laptop sat at build 848 while the launcher fell back
    /// to the previous binary. Each half now type-checks as its own expression.
    /// Add a lifecycle modifier here and an alert in `body`, rather than
    /// lengthening either chain past what it holds today.
    private var windowContent: some View {
        // MEASURES THE WHOLE WINDOW, not just the pane row. The narrower
        // `GeometryReader` below (unchanged) still feeds `columnWidth(totalWidth:)`
        // its own row-relative width; this one exists only to decide the two
        // breakpoints — see `windowWidth`'s doc.
        GeometryReader { windowGeo in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    rail
                    // Under Builder Default the rail and the top bar are both the
                    // ground, so the hairline between them is dropped. It would
                    // be the only break in the frame.
                    if !isBuilderDefault {
                        Divider()
                            .surfaceAppearance(configuration.pinnedDividerSurface)
                    }
                    // HOISTED ABOVE THE VSTACK so `paneChrome` can be handed the
                    // row's width as a plain value — see `paneChrome(rowWidth:)`'s
                    // doc for why a preference-to-`@State` round trip could not be
                    // trusted to deliver it at all.
                    GeometryReader { rowGeo in
                        VStack(spacing: 0) {
                            paneChrome(rowWidth: rowGeo.size.width)
                                .background(GeometryReader { chromeGeo in
                                    Color.clear
                                        .onAppear { paneChromeHeight = chromeGeo.size.height }
                                        .onChange(of: chromeGeo.size.height) { _, new in paneChromeHeight = new }
                                })
                                .surfaceAppearance(configuration.pinnedSurface(for: .chrome))
                            // Dropped under Builder Default for the same reason as the
                            // rail's: this hairline ran over the cockpit's band and
                            // cut the frame between the top bar and the band.
                            if !isBuilderDefault {
                                Divider()
                                    .surfaceAppearance(configuration.pinnedDividerSurface)
                            }
                            // Wrapped in a `GeometryReader` so the divider's drag can
                            // clamp against the row's actual width — `columnWidth(totalWidth:)`
                            // is what keeps `mainPaneMinWidth` on the left honoured, not
                            // merely the right column's own floor. Kept as its own
                            // reader rather than reusing `rowGeo` above so this
                            // measurement and its arithmetic stay exactly as tested.
                            GeometryReader { geo in
                                ZStack(alignment: .trailing) {
                                    HStack(spacing: 0) {
                                        mainPane
                                            .frame(minWidth: ContentView.mainPaneMinWidth,
                                                   maxWidth: .infinity, maxHeight: .infinity)
                                            // The pane's two corners that meet the frame: the
                                            // top bar and the rail, and the Course strip and the rail.
                                            .builderFrameCorner(.topLeading, enabled: isBuilderDefault)
                                            .builderFrameCorner(.bottomLeading, enabled: isBuilderDefault)
                                            // ⌘F opens the find bar. Scoped to a
                                            // searchable surface being on screen
                                            // — left out of the tree entirely
                                            // rather than `.disabled`, the same
                                            // discipline `RailView`'s ⌘1-9 and
                                            // `OptionCard` use, so it never
                                            // shadows a shortcut some OTHER
                                            // surface (`StartSessionView`'s
                                            // Return, a future `F`-using pane)
                                            // might claim when neither the
                                            // conversation nor Terminal View is
                                            // showing. `⌘G`/`⇧⌘G`/Esc live on
                                            // `FindBarRow` itself instead, scoped
                                            // to the bar's OWN presence rather
                                            // than to the surface's — see that
                                            // type's doc.
                                            .background {
                                                if isSearchableSurfaceShowing {
                                                    Button("") { findBarState.open() }
                                                        .keyboardShortcut("f", modifiers: .command)
                                                        .hidden()
                                                }
                                            }
                                        // BELOW `LayoutBreakpoints.columnSheet` THE COLUMN
                                        // LEAVES THE ROW ENTIRELY rather than narrowing
                                        // further — it returns below as a sheet instead.
                                        // `design/redesign/04-narrow.html`'s "What gives
                                        // way, in order".
                                        if !usesColumnSheet {
                                            columnDivider(totalWidth: geo.size.width)
                                            HStack(spacing: 0) {
                                                columnBody(for: columnOccupant)
                                                    .frame(width: columnWidth(totalWidth: geo.size.width)
                                                                - frameBandInset)
                                                    .surfaceAppearance(columnPinnedSurface)
                                                    // The column's top-right and bottom-right corners meet the band.
                                                    .builderFrameCorner(.topTrailing, enabled: isBuilderDefault)
                                                    .builderFrameCorner(.bottomTrailing, enabled: isBuilderDefault)
                                                cockpitFrameBand
                                            }
                                            .frame(width: columnWidth(totalWidth: geo.size.width))
                                        }
                                    }
    
                                    // THE SHEET. Summoned by the toolbar's segmented
                                    // control (`presentColumnOccupant`, called from
                                    // every occupant-opening site) and dismissed by
                                    // the scrim tap below or a pane's own close
                                    // button (`closeColumnOccupant`) — see
                                    // `isColumnSheetPresented`'s doc. Hosts the SAME
                                    // `columnBody(for:)` the docked column does, so
                                    // every occupant — cockpit, shell, local
                                    // terminal, viewer, editor, item — reaches the
                                    // sheet rather than only the cockpit.
                                    if usesColumnSheet, isColumnSheetPresented {
                                        Color.black.opacity(0.18)
                                            .onTapGesture { isColumnSheetPresented = false }
                                        HStack(spacing: 0) {
                                            Divider()
                                            columnBody(for: columnOccupant)
                                                .frame(width: ContentView.sheetWidth)
                                                .surfaceAppearance(columnPinnedSurface)
                                                .background(Color(nsColor: .textBackgroundColor))
                                        }
                                        .shadow(radius: 16, x: -4)
                                    }
                                }
                            }
                        }
                    }
                }
                // Under Builder Default the strip sits below the whole row, so it
                // runs under the right column like a chyron and the frame has no
                // break at its foot. See `liftedCourseRibbon`.
                liftedCourseRibbon
            }
            .onAppear { windowWidth = windowGeo.size.width }
            .onChange(of: windowGeo.size.width) { _, new in windowWidth = new }
            .background(WindowChromeSetter(builderDefault: isBuilderDefault))
            // SwiftUI rewrites the title bar's transparency and title visibility
            // from these two preferences on every environment update, so the values
            // `DeckWindowChrome.apply` sets would last only until the next update.
            // Stating them here keeps the bar transparent and the native title
            // hidden under Builder Default. `DeckWindowChrome` still sets the
            // full-size content view, the window's green and the title accessory,
            // and restores the system values on the other preferences.
            //
            // The preference reaches both as a value rather than through an `if`,
            // so a preference switch never changes the identity of the window's
            // content.
            //
            // When SwiftUI's reset won, the title bar was opaque: grey system
            // material on macOS 26, the window's own green on macstudio's macOS 27.
            .toolbarBackground(isBuilderDefault ? .hidden : .automatic, for: .windowToolbar)
            .modifier(NativeTitleRemoval(removed: isBuilderDefault))
        }
        .frame(minWidth: LayoutBreakpoints.windowMinWidth, minHeight: 500)
        // Injected once, here, for the reason the appearance is: one owner
        // stamps it and every surface below resolves the same base, rather than
        // each reading the store and possibly disagreeing mid-frame.
        .environment(\.frameTypography, configuration.frameTypography)
        // The rail polls every session it draws — the pinned rows and the
        // catalog entries, since a catalog row also greys when its session is
        // not running. Re-tracked whenever that set changes, so a newly
        // configured row is watched without waiting for a relaunch. Also
        // polls every host in Settings that no ref resolves to
        // (`configuredTargets`), so a crew-less host's sessions still reach
        // OTHER SESSIONS (`issue_01M3RGBXYGMC4D9K1CEP63R9G1`) — read fresh
        // each tick off the live `configuration.hosts`, the same "no
        // relaunch needed" discipline `resolveHost` already follows.
        .task(id: railSessionRefs) {
            railState.track(
                railSessionRefs, resolveHost: { hostTarget(for: $0) },
                configuredTargets: { configuration.hosts.map { SSHTarget(user: $0.user, host: $0.address) } },
                onDesktopSessionLoggedOut: { target in
                    desktopAlerts.raiseLoggedOut(target: target, hosts: configuration.hosts)
                })
        }
        // A pressed "Open Runbook" on a logged-out alert (CQ·124) — a fresh
        // request per press, consumed the moment it is acted on.
        .onChange(of: desktopAlerts.pendingRunbookOpen) { _, request in
            guard let request else { return }
            openRunbookLink(hostName: request.hostName, rawLink: request.rawLink)
            desktopAlerts.consumePendingRunbookOpen()
        }
        // Deliberately no `id:` — this must run once for the launch, not
        // re-run every time `railSessionRefs` (or anything else) changes.
        // See `evaluateStewardAtLaunch`'s doc.
        .task {
            evaluateStewardAtLaunch()
        }
        // Keyed on the RESOLVED pair rather than on `selection` alone, so an
        // edit to `Crew.project` in Settings while that session stays
        // selected re-fetches too — not merely a selection change, per
        // `cockpitProjectAndTarget`'s doc.
        .task(id: cockpitRefreshKey) {
            let resolved = cockpitProjectAndTarget
            await cockpitModel.refresh(target: resolved?.target, product: resolved?.project)
        }
        .task(id: checkoutDocumentsRefreshKey) {
            let resolved = checkoutDocumentsSessionAndTarget
            await checkoutDocumentsModel.refresh(target: resolved?.target, session: resolved?.session)
        }
        // Keyed on `cockpitRefreshKey`, the same identity `cockpitModel`
        // refreshes on — `CockpitResolution.prLadderRepos` derives entirely
        // from the crew's project, which is exactly what that key already
        // identifies, so a second key would only ever agree with the first.
        .task(id: cockpitRefreshKey) {
            let target = cockpitProjectAndTarget?.target
            let repos = CockpitResolution.prLadderRepos(for: selection.flatMap { owningCrew(for: $0) })
                .repos.map { (owner: $0.owner, repoName: $0.repoName) }
            await prLadderModel.refresh(target: target, repos: repos)
        }
        // The session pane's PR chip's own fallback fetch — see
        // `sessionReviewChipLadder`'s doc. Keyed on
        // `sessionReviewChipRefreshKey` rather than `cockpitRefreshKey`: the
        // two can name different repos whenever the selected session's PR
        // is not in the crew's own repo.
        .task(id: sessionReviewChipRefreshKey) {
            let resolved = sessionReviewChipFetchTarget
            await sessionReviewChipLadder.refresh(target: resolved?.target, owner: resolved?.owner, repoName: resolved?.repoName)
        }
        // Keyed on `beadProgressRefreshKey` rather than `cockpitRefreshKey`
        // — the two can disagree, since a crew's bead and its project are
        // set independently (`BeadProgressModel`'s doc).
        .task(id: beadProgressRefreshKey) {
            let crew = selection.flatMap { owningCrew(for: $0) }
            await beadProgressModel.refresh(
                target: selection.flatMap { hostTarget(for: $0) },
                beadId: CockpitResolution.beadId(for: crew),
                product: crew?.project)
        }
        // A ROW REMOVED MID-LAUNCH WOULD STRAND THE PLACEHOLDER FOREVER.
        // Nothing polls an untracked ref, so its state stays nil, which reads
        // as neither alive nor stopped — undecided — and the prune below keeps
        // an undecided entry on purpose. Other sessions' polls go on advancing
        // `generation`, so the reading looks fresh while never being about
        // this session, and an opaque placeholder covers the pane until Deck
        // restarts. The launch cannot be resolved once nobody is watching for
        // it, so it is dropped rather than waited on. Found by
        // deck-security-reviewer.
        .onChange(of: railSessionRefs) { _, refs in
            let watched = Set(refs)
            launchPending = launchPending.filter { watched.contains($0.key) }
            // Same point, same reason: `railSessionRefs` is every ref
            // currently configured, so a ref missing from it left Deck's
            // config entirely rather than merely missed a poll — see
            // `SessionDraftStore.prune`'s doc.
            draftStore.prune(keeping: watched)
        }
        // The shell follows the selection. Without this the pane respawned in
        // the remote HOME for any session whose cwd was not already cached —
        // so the feature's promise ("opens where that session is working") held
        // only for a session you had opened the pane on before. Caught in
        // review; the PR description claimed the behaviour this adds.
        .onChange(of: selection) { _, newValue in
            // A different session's content is not what a find-bar term
            // typed against the old one was ever about — see
            // `FindBarState.closeAndClear`'s doc.
            findBarState.closeAndClear()
            if columnOccupant == .remoteShell { resolveShellCwd() }
            // Deck's selection and tmux's current window stay decoupled
            // (design §"Sessions within a crew") — Deck never drives
            // `select-window` on behalf of an ordinary session switch. A
            // window LEAF is the one exception: selecting it is the whole
            // point of the row, so tmux is told to follow. Safe blind
            // because every Deck attach carries `-D`, guaranteeing at most
            // one client per session.
            if let newValue, let leaf = WindowLeaf.parse(newValue) {
                selectWindow(leaf.session, window: leaf.window)
            }
        }
        // Prunes `launchPending` the moment the rail confirms a session
        // alive OR stopped. Not load-bearing for `showsLaunchPlaceholder`
        // itself — that predicate re-checks both readings independently —
        // but without this the set only ever grows, and a session that is
        // restarted later would otherwise reuse a stale membership that
        // happens to read correctly by luck rather than by clearing.
        //
        // Also prunes `staleTerminalRequests`, and reconciles every pinned
        // child against this tick's discovery answer — both folded into
        // this same modifier rather than a separate
        // `.onChange(of: railState.generation)` or
        // `.onChange(of: railState.discovered)`, which pushed this already-
        // long chain past the type checker's budget. A ref stays in
        // `staleTerminalRequests` only while its row is still `.stale`
        // (`pruneStaleTerminalRequests`'s doc), so the entry is gone by the
        // time the row could plausibly go stale again — leaving it would
        // silently lower `showsStaleGate` on that next occurrence, with
        // nothing said. See `reconcilePinnedSessionsAndMoveState`'s doc for
        // the rename follow.
        .onChange(of: railState.generation) { _, current in
            launchPending = launchPending.filter { id, launch in
                guard let launchedAt = launch.decidableFrom else { return true }
                // Same freshness rule the placeholder uses, for the same
                // reason: a poll issued before the launch cannot resolve it,
                // and pruning on one would drop the entry that is holding the
                // placeholder up — permanently, since no later poll could
                // bring it back.
                guard ContentView.hasReadingSinceLaunch(
                    reading: current, launchedAt: launchedAt) else { return true }
                return !railState.isAlive(id) && !railState.isStopped(id)
            }
            pruneStaleTerminalRequests()
            reconcilePinnedSessionsAndMoveState()
        }
    }

    /// `cockpitModel` is injectable so a render test can seed the Course strip,
    /// and `columnOccupant` so it can open a pane other than the cockpit. The app
    /// passes nothing and gets the window's own model and the cockpit rest state.
    init(cockpitModel: CockpitModel = CockpitModel(), columnOccupant: ColumnOccupant = .cockpit) {
        _cockpitModel = StateObject(wrappedValue: cockpitModel)
        _columnOccupant = State(initialValue: columnOccupant)
    }

    var body: some View {
        windowContent
        // Stopping kills the tmux session, which is destructive, so it confirms.
        .alert("Stop this session?", isPresented: Binding(
            get: { sessionToStop != nil },
            set: { if !$0 { sessionToStop = nil } }
        )) {
            Button("Cancel", role: .cancel) { sessionToStop = nil }
            Button("Stop", role: .destructive) {
                if let session = sessionToStop { stop(session) }
                sessionToStop = nil
            }
        } message: {
            Text(ContentView.stopConfirmMessage(
                hasAgent: sessionToStop.map { surface(for: $0) != .terminalOnly } ?? true))
        }
        // Rolling over ends the session's current context, so it confirms. The
        // other overrides (veto, start looking, lift the veto) only record
        // state the next hook firing reads, and go through without asking.
        // A `ViewModifier` rather than an inline `.alert`, for the reason
        // `CatalogEntryRemoveAlert`'s call site gives: one more alert in this
        // chain puts the whole body past the type checker's time limit.
        .modifier(RolloverForceAlert(
            session: $rolloverToForce,
            onConfirm: { changeRollover($0, .force) }))
        // Removing is config-only, but it is still a click a user did not
        // mean to make, so it confirms — the same reason Stop does. The
        // title and message are built from `crewToRemove` while it is
        // still set; the `Binding`'s `set` clears it on any dismissal,
        // including the buttons below, which also clear it explicitly so
        // the alert's own text does not flash to the "no crew" case during
        // the dismiss animation. "Remove and Stop" only appears when the
        // crew has something running to stop — see
        // `removeCrewAndStopSessions`.
        .alert(
            crewToRemove.map { "Remove \($0.displayName) from Deck?" } ?? "Remove from Deck?",
            isPresented: Binding(
                get: { crewToRemove != nil },
                set: { if !$0 { crewToRemove = nil } })
        ) {
            Button("Cancel", role: .cancel) { crewToRemove = nil }
            if let crew = crewToRemove, railRunningSessions.removeCrewAlertShape(for: crew).showRemoveAndStopButton {
                Button("Remove and Stop", role: .destructive) {
                    removeCrewAndStopSessions(crew)
                    crewToRemove = nil
                }
            }
            Button("Remove", role: .destructive) {
                if let crew = crewToRemove { store.removeCrew(crew.ref) }
                crewToRemove = nil
            }
        } message: {
            Text(crewToRemove.map { railRunningSessions.removeCrewAlertShape(for: $0).message }
                ?? ContentView.removeCrewMessage(runningSessionCount: 0))
        }
        // The pinned-child mirror of the alert above — same title shape,
        // same button roles and ordering, one level down. See
        // `deck/specs/multiple-sessions-per-project` §"Remove".
        .alert(
            childToRemove.map { "Remove \($0.session.displayName) from Deck?" } ?? "Remove from Deck?",
            isPresented: Binding(
                get: { childToRemove != nil },
                set: { if !$0 { childToRemove = nil } })
        ) {
            Button("Cancel", role: .cancel) { childToRemove = nil }
            if let child = childToRemove,
               railRunningSessions.removeChildAlertShape(for: child.crew, child.session).showRemoveAndStopButton {
                Button("Remove and Stop", role: .destructive) {
                    removeChildAndStopSession(child.crew, child.session)
                    childToRemove = nil
                }
            }
            Button("Remove", role: .destructive) {
                if let child = childToRemove {
                    store.removePinnedSession(child.session.name, fromCrew: child.crew.ref)
                }
                childToRemove = nil
            }
        } message: {
            Text(childToRemove.map { railRunningSessions.removeChildAlertShape(for: $0.crew, $0.session).message }
                ?? ContentView.removeChildMessage(isRunning: false))
        }
        // "Remove from Deck" on a `START` row — a catalog entry's only way
        // out. Config-only, the same as the two alerts above, but with no
        // "Remove and Stop": a catalog row names no owned children the way
        // a crew or pinned child does, so there is nothing to fuse a Stop
        // into. If the entry is currently running, its session is untouched
        // and simply becomes reachable under "OTHER SESSIONS" on the next
        // poll, the same as any other session no catalog or crew claims.
        //
        // A `.modifier`, not another inline `.alert` on this chain: `body`
        // already carries eight of them, and a ninth pushed the type
        // checker past its time limit (it reported the failure on the
        // UNRELATED "File viewer unavailable" alert below, not on the new
        // one — the whole chain is one expression to solve). Extracting
        // just this alert into its own `ViewModifier` is the minimal fix;
        // the other eight are untouched.
        .modifier(CatalogEntryRemoveAlert(
            entryToRemove: $catalogEntryToRemove,
            isRunning: isCatalogEntryToRemoveRunning,
            onRemove: removeCatalogEntry))
        // "Promote to Crew…" on an "OTHER SESSIONS" row. Every field
        // derives from the session itself (design §"An OTHER SESSIONS row
        // can be adopted into a crew but cannot BECOME one": "Use a sheet
        // only if you need one for the display name; if every field
        // derives, a confirm is enough"), so this is a confirm rather than a
        // sheet. A derivation failure (an id collision with an existing
        // crew) shows the same alert with no Promote button — the message
        // explains why instead.
        .alert(
            sessionToPromote.map { "Promote \($0.name) to Crew?" } ?? "Promote to Crew?",
            isPresented: Binding(
                get: { sessionToPromote != nil },
                set: { if !$0 { sessionToPromote = nil } })
        ) {
            Button("Cancel", role: .cancel) { sessionToPromote = nil }
            if let session = sessionToPromote, case .success(let crew) = promotionResult(for: session) {
                Button("Promote") {
                    promoteSession(session, as: crew)
                    sessionToPromote = nil
                }
            }
        } message: {
            Text(sessionToPromote.map(promotionMessage) ?? "")
        }
        // A two-way binding, not `.constant`. SwiftUI writes `false` back on a
        // dismissal it initiates itself (window lifecycle, another alert taking
        // precedence, a hierarchy change); a read-only binding drops that write,
        // leaving the error set so the alert re-presents on the next render.
        .alert("Preferences not saved", isPresented: Binding(
            get: { store.saveError != nil },
            set: { if !$0 { store.saveError = nil } }
        )) {
            Button("OK") { store.saveError = nil }
        } message: {
            Text(store.saveError ?? "")
        }
        .alert("File viewer unavailable", isPresented: Binding(
            get: { server.bindError != nil },
            set: { if !$0 { server.bindError = nil } }
        )) {
            Button("OK") { server.bindError = nil }
        } message: {
            Text("The local file server could not start: \(server.bindError?.localizedDescription ?? "unknown error"). PDF and HTML files will not open in the browser.")
        }
    }

    /// Sessions currently showing the raw terminal instead of the session pane.
    ///
    /// The terminal is hidden machinery: summoned when the pane cannot drive
    /// something, or when a user wants the bytes, and otherwise off screen. Kept
    /// per session rather than globally, so falling back on one does not drag
    /// every other row into a surface they did not ask for.
    @State private var showingTerminal: Set<SessionRef> = []

    /// Sessions where "Open terminal" was clicked on a `.stale` row's
    /// refusal — the one explicit action allowed to bypass
    /// `ContentView.showsStaleGate` and attach through `target(for:)`
    /// despite `SessionSurface.stale`. Pruned by the `railState.generation`
    /// handler below the moment the poll confirms the tmux session is back,
    /// so a row that goes stale again later needs a fresh click rather than
    /// reusing this one — see `showsStaleGate`'s doc for why `showingTerminal`
    /// alone cannot stand in for this.
    @State private var staleTerminalRequests: Set<SessionRef> = []

    /// The find bar's shared presentation state and, for the terminal
    /// backend, the controller `TerminalPaneView`'s coordinator attaches to
    /// once the main pane's terminal connects. One of each rather than one
    /// per session: `mainPane` shows at most one searchable surface at a
    /// time, and a session switch already closes the bar
    /// (`onChange(of: selection)` below), so nothing here needs to survive
    /// past that.
    @StateObject private var findBarState = FindBarState()
    @StateObject private var terminalSearchController = TerminalSearchController()

    /// Sessions with a start in flight. A launch selects the session before the
    /// tmux session exists, so the pane polls and finds nothing for a beat —
    /// which reads as "cannot reach the session", the same message an offline
    /// mini gives. While a ref is in here the pane says "Starting…" instead, so
    /// a first click does not look broken. Cleared when the start returns.
    @State private var launching: Set<SessionRef> = []

    /// Sessions whose pane region is covered by the launch placeholder.
    ///
    /// SEPARATE FROM `launching`, and that is the fix. `launching` clears as
    /// soon as `SessionAgent.start` returns — often faster than the rail's own
    /// ~4s poll — and clearing it was itself the artifact the operator reported: the
    /// beat between that return and the rail's next tick left `mainPane`
    /// reading the rail's still-stale "stopped" reading as current, so it
    /// flashed `StartSessionView` between the pane's first paint and the rail
    /// catching up — "a flicker of the construction of the session window,
    /// then back to splash, then eventually a session window that starts
    /// populating." This set outlives that gap: entered synchronously on the
    /// button press, alongside `launching`, and left only once the rail has
    /// independently confirmed the session is alive, or the start genuinely
    /// failed. See `showsLaunchPlaceholder`.
    /// The launches this pane is waiting on, keyed by session ref.
    @State private var launchPending: [SessionRef: LaunchInFlight] = [:]

    /// A launch that has begun and has not yet been resolved by the rail.
    ///
    /// THE POINT OF THE OPTIONAL IS WHEN A POLL BECOMES ADMISSIBLE. `nil` says
    /// `SessionAgent.start` has not returned, which means the tmux session may
    /// not exist on the mini yet — and a poll that runs in that window answers
    /// "stopped" perfectly correctly about a session that has not been created.
    /// That answer is freshly taken and still says nothing about this launch,
    /// so no ticket can make it admissible; only the start call returning can.
    ///
    /// The distinction is not theoretical. `SessionAgent.start` and
    /// `SessionAgent.states` are separate ssh invocations multiplexed over one
    /// ControlMaster with no ordering between them, so a routine 4-second tick
    /// landing inside a launch's own round trip is ordinary rather than
    /// adversarial — deck-security-reviewer put it at low single digits to
    /// ~10% of restarts, which is exactly often enough that the operator would still see
    /// the flicker sometimes and be unable to tell whether it was fixed.
    struct LaunchInFlight: Equatable {
        /// The ticket of the earliest poll entitled to resolve this launch, or
        /// nil while the start call is still in flight.
        var decidableFrom: Int?
        /// When the button was pressed — the origin `showsLaunchPlaceholder`
        /// measures `elapsedSinceLaunch` from, so a launch whose reading never
        /// arrives (a host that was never going to answer, not merely slow to)
        /// still has a moment it gives up rather than covering the pane forever.
        var startedAt = Date()
    }

    /// What is showing in the right-hand column beside the conversation.
    ///
    /// One occupant at a time — switching to a new case closes whatever was
    /// there before. `.cockpit` is the default and what closing any other
    /// occupant reveals — see `ColumnOccupant`'s doc. The viewer case is
    /// opened by clicking a `deck-open:` link in the conversation; the shell
    /// and local-terminal cases are toggled by their buttons in the pane
    /// chrome.
    @State private var columnOccupant: ColumnOccupant

    /// Drives the cockpit column's Library reads. One instance for the
    /// window's life — `refresh` is a no-op when the (target, product) pair
    /// has not changed, so re-selecting the same session costs nothing.
    @StateObject private var cockpitModel: CockpitModel
    /// The cockpit's Checkout panel — keyed on the selected session rather
    /// than the crew's project, so it has its own model and refresh key.
    @StateObject private var checkoutDocumentsModel = CheckoutDocumentsModel()
    @StateObject private var runGivenDocumentsModel = RunGivenDocumentsModel()
    @StateObject private var runFetchedDocumentsModel = RunFetchedDocumentsModel()
    /// The cockpit's Pull Requests panel — keyed on the crew's project repo
    /// (`CockpitResolution.prLadderRepo`), its own model for the reason
    /// `PRLadderModel`'s doc gives.
    @StateObject private var prLadderModel = PRLadderModel()
    /// The session pane's PR chip's fallback fetch — used only when the
    /// selected session's own PR belongs to a different repo than
    /// `prLadderModel` currently covers, so the chip still reuses one fetch
    /// per repo rather than one per pane. One instance for the window's
    /// life, shared by `SessionPaneView` and `terminalStatusBar` alike:
    /// those two are never both on screen for the same selection at once,
    /// so nothing is lost by giving them one fallback rather than two. See
    /// `sessionReviewChipFetchTarget`'s doc for the reuse-vs-fallback
    /// decision itself.
    @StateObject private var sessionReviewChipLadder = PRLadderModel()

    /// Drives the rail's bead-progress pane. Kept separate from
    /// `cockpitModel` rather than folded in — see `BeadProgressModel`'s doc
    /// for why the two need different gating.
    @StateObject private var beadProgressModel = BeadProgressModel()

    /// The selected session's working directory, as the shell pane should open
    /// in. Resolved from `session-agent state`, keyed by session ref so
    /// switching selection re-opens the shell where that session is working —
    /// two sessions sharing a bare name on different hosts must not share a
    /// cached cwd. Nil while unresolved or for a session with no reported
    /// cwd, which opens the shell in the remote home.
    @State private var sessionCwd: [SessionRef: String] = [:]

    /// Runs `ThemeStore.reconcilePinnedSessions` on every rail poll tick
    /// (`.onChange(of: railState.generation)`, folded in there rather than
    /// its own modifier for the type-checker-budget reason that block's
    /// comment gives) and moves whatever THIS VIEW keys by a pinned
    /// child's old name onto the new one — the per-session theme moves
    /// inside that call, since it lives in config; this is everything else
    /// that lives in `@State` here, keyed by `SessionRef`: the current
    /// selection, the cached working directory, whether its terminal is
    /// showing or was requested stale, any launch still in flight for it,
    /// and a Stop confirm waiting on it (`sessionToStop`). A ref with
    /// nothing recorded under any of these is simply skipped — most renames
    /// rename a session nobody has selected or launched this run.
    private func reconcilePinnedSessionsAndMoveState() {
        let renames = store.reconcilePinnedSessions(
            discovered: Array(railState.discovered.values),
            hosts: configuration.hosts, defaultHost: configuration.defaultHost)
        for rename in renames {
            let oldRef = SessionRef(host: rename.crewHost, name: rename.from)
            let newRef = SessionRef(host: rename.crewHost, name: rename.to)
            if selection == oldRef { selection = newRef }
            if let cwd = sessionCwd.removeValue(forKey: oldRef) { sessionCwd[newRef] = cwd }
            if showingTerminal.remove(oldRef) != nil { showingTerminal.insert(newRef) }
            if staleTerminalRequests.remove(oldRef) != nil { staleTerminalRequests.insert(newRef) }
            if let launch = launchPending.removeValue(forKey: oldRef) { launchPending[newRef] = launch }
            // A Stop confirm left open across the rename would otherwise kill
            // by the old name: `stop(_:)` targets `ref.name`, which no longer
            // exists, so the kill fails and the renamed session keeps running.
            if sessionToStop == oldRef { sessionToStop = newRef }
            // The same for a Roll Over Now confirm: `changeRollover` targets
            // `ref.name`, so confirming by the old name would be refused.
            if rolloverToForce == oldRef { rolloverToForce = newRef }
        }
    }

    /// Where the local shell was last sitting when its pane closed, so the
    /// next one opens there rather than back in home.
    ///
    /// `@AppStorage` because the point is continuity, and half of the
    /// continuity a user notices spans a relaunch: toggling the split off and
    /// on is the common case, quitting Deck at the end of the day is the
    /// memorable one. Deck has no other way to learn a local shell's cwd —
    /// unlike a tmux session on the mini, a bare local shell has no
    /// `session-agent state` to ask — so this is written from the kernel read
    /// `TerminalPaneView` performs in the moment before it kills the child.
    ///
    /// A plain path in UserDefaults, not the theme config: this is Deck
    /// remembering what you were doing, not a setting anybody hand-edits.
    @AppStorage("localShellDirectory") private var localShellDirectory: String = ""

    /// Whether a selection is a fleet co session, and therefore has a pane.
    ///
    /// The local shell is not a co session — it has no transcript, no hook
    /// stream, and nothing to render — so it stays a terminal always.
    private func hasSessionPane(_ ref: SessionRef) -> Bool {
        ref != .localShell && (try? validateTmuxSessionName(ref.name)) != nil
    }

    /// Whether a terminal is what is actually on screen for a selection —
    /// because the selection has no pane, because the user summoned it, or
    /// because `surface(for:)` says this session gets no pane at all.
    private func showsTerminal(for ref: SessionRef) -> Bool {
        ContentView.pickerShowsTerminal(
            hasSessionPane: hasSessionPane(ref),
            isInShowingTerminalSet: showingTerminal.contains(ref),
            isTerminalOnlySurface: surface(for: ref) == .terminalOnly)
    }

    /// The pure truth behind `showsTerminal(for:)`, pulled out so it is
    /// directly pinnable the way `mainPaneChromeWidth` and
    /// `showsLaunchPlaceholder` are — no view, no instance state.
    ///
    /// `isShowingTerminalForSelection` (the toolbar's Main pane picker
    /// binding) used to read `showingTerminal.contains(_:)` alone, which
    /// lies for a `.terminalOnly` session: such a session is never inserted
    /// into `showingTerminal` — `showsTerminal(for:)` forces its terminal on
    /// screen through `isTerminalOnlySurface` instead — so the picker showed
    /// "Session" selected while a terminal was already drawn, and clicking a
    /// segment moved the highlight with nothing on screen changing
    /// (`issue_01M2715540KEV1P6Z831R6TAWA`). Binding the picker to this same
    /// function fixes it: for a `.terminalOnly` session it now reports
    /// Terminal truthfully, and clicking "Session" toggles `showingTerminal`
    /// harmlessly (`SessionSurface.showsConversationPane` already excludes
    /// `.terminalOnly` regardless of that set) while the binding itself
    /// keeps reporting Terminal, so the segment has nothing to move to and
    /// snaps back — the "no alternative that sticks" the bar this replaces
    /// used to provide by absenting itself instead.
    nonisolated static func pickerShowsTerminal(
        hasSessionPane: Bool, isInShowingTerminalSet: Bool, isTerminalOnlySurface: Bool
    ) -> Bool {
        !hasSessionPane || isInShowingTerminalSet || isTerminalOnlySurface
    }

    /// Whether `mainPane` draws the `.stale` refusal (`StartSessionView`,
    /// gating both Start and the raw terminal) rather than falling through
    /// to the terminal branch beneath it. Takes no `showingTerminal` reading
    /// at all, DELIBERATELY: that set can already hold a ref from before the
    /// row went stale — the picker was left on Terminal for the session
    /// while it was still alive — and honouring it here would resurrect the
    /// session through `tmux new-session -A -D` with nothing said, the exact
    /// bug `SessionSurface.stale` exists to stop. `terminalRequested` is the
    /// one thing that lowers the gate: `staleTerminalRequests`, set only by
    /// an explicit "Open terminal" click on the refusal itself, never by a
    /// lingering picker selection. See `issue_01M1KXVY8MNNNG53NFBT8SY58Z`.
    nonisolated static func showsStaleGate(surface: SessionSurface, terminalRequested: Bool) -> Bool {
        surface == .stale && !terminalRequested
    }

    /// Whether a session is one Deck did not configure — not a crew id, a
    /// pinned child, or a catalog entry — so its only source is
    /// `session-agent sessions`: a discovered child row, or an "OTHER
    /// SESSIONS" row. Feeds `SessionSurface.choose`, which is what tells a
    /// plain shell someone is using apart from a row Deck itself knows how
    /// to start. Uses `childParentByRef` rather than `owningCrew(for:)`,
    /// which would also match a DISCOVERED child — the very thing this
    /// predicate exists to detect.
    private func isDiscoveredSession(_ ref: SessionRef) -> Bool {
        crews.first { SessionRef.owned(by: $0, name: $0.id) == ref } == nil
            && childParentByRef[ref] == nil
            && configuration.catalog.first { SessionRef(host: $0.host, name: $0.id) == ref } == nil
    }

    /// A session's main surface — see `SessionSurface`. `hasReading` folds
    /// `isAlive` and `isStopped` together because either one, on its own, is
    /// evidence a poll has actually landed for this session; `isStopped`
    /// alone reads false both before the first poll and for a live session,
    /// and the two must not be conflated here.
    ///
    /// `hasDirectory` reads the identical source `startSelectedRow` starts
    /// from (`owningCrew(for: ref)?.workingDirectory`) and asks the question
    /// the start itself will ask (`SessionSurface.isUsableDirectory`), so a
    /// row this marks `.missingDirectory` is exactly the row whose Start
    /// would either create its tmux session at `$HOME` or throw — see
    /// `SessionSurface.missingDirectory`.
    ///
    /// `hasPolled`/`hasTmuxSession` are only passed for real — rather than
    /// left at `SessionSurface.choose`'s defaults, which never resolve
    /// `.stale` — when `owningCrew(for: ref)` finds an owner: a crew's own
    /// row or one of its pinned children, the two rows `SessionSurface.stale`
    /// exists for. A catalog entry has no owning crew and stays on the
    /// defaults deliberately: it is polled continuously too (see
    /// `railSessionRefs`), and before its first launch that poll can read
    /// exactly like a stale pin's — no tmux session, but a reading on
    /// record. Gating this is scoped, not incidental: the gate this reading
    /// drives offers "Remove pin," which has nothing to call for a catalog
    /// row (`store.removePinnedSession` has no pin to find).
    private func surface(for ref: SessionRef) -> SessionSurface {
        let owner = owningCrew(for: ref)
        return SessionSurface.choose(
            isDiscovered: isDiscoveredSession(ref),
            isStopped: railState.isStopped(ref),
            hasReading: railState.isAlive(ref) || railState.isStopped(ref),
            hasDirectory: SessionSurface.isUsableDirectory(owner?.workingDirectory),
            hasPolled: owner == nil ? true : railState.mark(for: ref) != .unpolled,
            hasTmuxSession: owner == nil ? true : railState.hasTmuxSession(
                ref, hosts: configuration.hosts, defaultHost: configuration.defaultHost))
    }

    /// `ContentView.showsStaleGate`, applied to a selection — pulled out so
    /// `mainPane` and `isSearchableSurfaceShowing` each read one short
    /// boolean call rather than repeating the two-argument static call
    /// inline, the same reason `showsTerminal(for:)` wraps `pickerShowsTerminal`.
    private func showsStaleGate(for ref: SessionRef) -> Bool {
        ContentView.showsStaleGate(
            surface: surface(for: ref), terminalRequested: staleTerminalRequests.contains(ref))
    }

    /// Called on every `railState.generation` tick — see that `.onChange`
    /// in `body` for why: a ref stays here only while its row is still
    /// `.stale`, so the entry is gone by the time the row could plausibly
    /// go stale again.
    private func pruneStaleTerminalRequests() {
        staleTerminalRequests = staleTerminalRequests.filter { surface(for: $0) == .stale }
    }

    /// Whether `ref` is a pinned CHILD specifically — not a crew's own row,
    /// which `owningCrew(for:)` also resolves. `StartSessionView`'s "Remove
    /// pin" (drawn for a `.stale` row) only makes sense for a child; a
    /// crew's own row is the crew, and removing it is a different, more
    /// destructive action this gate does
    /// not offer.
    private func isPinnedChild(_ ref: SessionRef) -> Bool {
        childParentByRef[ref] != nil
    }

    /// Opens the same confirm-and-remove flow `RailView`'s own "Remove"
    /// context-menu item does (`childToRemove`, and the alert below that
    /// reads it) — the "existing removePinnedSession path" a stale row's
    /// "Remove pin" button reuses rather than removing outright with no
    /// confirmation.
    private func requestRemovePinnedSession(_ ref: SessionRef) {
        guard let crew = childParentByRef[ref],
              let child = crew.sessions.first(where: { $0.name == ref.name }) else { return }
        childToRemove = (crew, child)
    }

    /// Whether a discovered session should draw the rail's `⊞`
    /// terminal-only mark instead of its ordinary dot. Passed to `RailView`,
    /// which only asks this for a discovered child row or an "OTHER
    /// SESSIONS" row — a crew or pinned child is never discovered, so this
    /// never resolves `.start` there.
    private func isTerminalOnly(_ ref: SessionRef) -> Bool {
        surface(for: ref) == .terminalOnly
    }

    /// The right column's pin. Under Builder Default the cockpit draws light on
    /// `cockpitFrameGround`. Every other preset, and every other occupant, takes
    /// the pin `pinnedSurface(for:)` gives it.
    private var columnPinnedSurface: PinnedSurface? {
        ContentView.columnPin(for: columnOccupant, configuration: configuration,
                              cockpitGround: cockpitFrameGround)
    }

    /// The pin a right-column occupant draws with. Under Builder Default the
    /// cockpit draws light on `cockpitGround`, and so does the run pane the
    /// cockpit opens, so the column reads as one surface. Every other occupant
    /// keeps the pin it has always had. Pure, so a test can read each pin.
    static func columnPin(for occupant: ColumnOccupant, configuration: ThemeConfiguration,
                          cockpitGround: RGB?) -> PinnedSurface? {
        let drawsOnCockpitGround: Bool
        switch occupant {
        case .cockpit, .run: drawsOnCockpitGround = true
        default: drawsOnCockpitGround = false
        }
        // Pinned Light and Dark keep their own pins (#330), so the frame tint
        // applies only under Builder Default.
        guard drawsOnCockpitGround,
              configuration.appearancePreference == .builderDefault,
              let appearance = configuration.pinnedAppearance(for: .cockpit) else {
            return configuration.pinnedSurface(for: occupant.appearanceSurface)
        }
        return PinnedSurface(appearance: appearance, ground: cockpitGround)
    }

    /// The frame tint of the selected session's composer, which the cockpit
    /// draws on under Builder Default. The composer and the cockpit take their
    /// colour from the same canvas and the same conversation appearance, so the
    /// two read as one surface. With no selection it is the system's light
    /// window colour, passed as RGB so the cockpit's inks solve against the
    /// ground they draw on, as they do with a selection.
    private var cockpitFrameGround: RGB? {
        guard let selection else {
            return ColumnBandColours.systemRGB(.windowBackgroundColor, .light)
        }
        return SessionPaneView.frameTintRGB(canvas: paneCanvas(for: selection, on: .conversation),
                                            appearance: appearance(for: .conversation))
    }

    /// Whether the window draws the Builder Default frame: the green title bar,
    /// the Course strip along the foot of the whole window, and no seams between
    /// the status panes.
    private var isBuilderDefault: Bool {
        configuration.appearancePreference == .builderDefault
    }

    /// The Course strip under Builder Default, drawn once along the foot of the
    /// whole window, under the right column too. It reads like a chyron: the
    /// waypoints lay out across the full width. The strip is pinned to the status
    /// ground like the rail, so it joins the frame with no break.
    ///
    /// The bar is always there under Builder Default, one strip tall, as the
    /// frame's bottom edge. The Course fills it when the selected crew has one;
    /// with no Course, or no session selected at startup, it is the bare ground
    /// (the operator, 2026-10-06). `WaypointRibbon` draws nothing without a Course, so the
    /// bar's height comes from here rather than from the ribbon.
    ///
    /// Under the other preferences the strip stays in the session pane, where it
    /// has always been, and this draws nothing.
    @ViewBuilder
    private var liftedCourseRibbon: some View {
        if isBuilderDefault {
            ZStack {
                Color.clear
                WaypointRibbon(course: cockpitModel.course,
                               workingOn: selection.flatMap { railState.states[$0]?.workingOn },
                               appearance: appearance(for: .strip),
                               accent: selectedAccent(for: .strip))
            }
            .frame(height: WaypointRibbon.height)
            .surfaceAppearance(configuration.pinnedSurface(for: .strip))
        }
    }

    /// Whether the green band closes the docked column's right edge. Under
    /// Builder Default it does for every occupant, not only the cockpit: the
    /// docked column shows whichever pane the segmented control picked, and a
    /// Slate or Shell column left the frame open on the right.
    private var showsFrameBand: Bool {
        configuration.appearancePreference == .builderDefault
    }

    /// The width the band takes from the column, which the column's pane gives up.
    /// Zero when no band is drawn, so the other preferences keep the full column.
    private var frameBandInset: CGFloat {
        showsFrameBand ? ContentView.cockpitFrameBandWidth : 0
    }

    /// The green band down the docked column's right edge under Builder Default.
    /// It sits beside the column's pane. The rail, the top bar and the Course
    /// strip already draw the status ground, so this closes the window's frame on
    /// the right.
    @ViewBuilder
    private var cockpitFrameBand: some View {
        if showsFrameBand {
            Rectangle()
                .fill(Color(StatusGround.ground))
                .frame(width: ContentView.cockpitFrameBandWidth)
        }
    }

    /// The session pane's canvas: this session's terminal background, lifted.
    ///
    /// Resolved here because this is where the theme already is, and because
    /// the shell is the appearance authority — the pane is told its colour in
    /// the same frame it is told its appearance, rather than asking.
    ///
    /// LIFTED RATHER THAN IDENTICAL. Reading a conversation is not reading a
    /// terminal, and a document on exactly the terminal's black reads as a hole
    /// in the window. A few percent toward white keeps the theme and gives the
    /// prose a surface to sit on.
    private func paneCanvas(for ref: SessionRef, on surface: AppearanceSurface) -> String {
        paneCanvasRGB(for: ref, on: surface).hexString
    }

    /// The same canvas as `paneCanvas(for:on:)`, typed, for a view that solves
    /// its inks against it rather than handing the hex to a pane.
    private func paneCanvasRGB(for ref: SessionRef, on surface: AppearanceSurface) -> RGB {
        ContentView.paneCanvas(for: themeForSession(ref).palette(for: appearance(for: surface)),
                               appearance: appearance(for: surface))
    }

    /// How far the canvas moves from the terminal background, AWAY from the
    /// appearance's extreme — lighter on a dark theme, darker on a light one.
    ///
    /// The direction was the bug. A one-way "lighter" is away from black in dark
    /// mode and straight toward the background in light mode, so every light
    /// canvas came out `#ffffff` and the theme vanished. The operator runs light
    /// mode and saw a white pane on white.
    /// Tuned by looking at it, three times. 0.08 with 2.5x chroma was what "move
    /// further from white" produced and it overshot into a deep khaki; 0.03 with
    /// 1.5x was the soft cream that replaced it; this is that cream a notch
    /// lighter again, which is where the operator stopped.
    static let canvasLift = 0.025

    /// How much the theme's own hue is strengthened. On a near-white or
    /// near-black background a lightness step alone reads as "slightly grey";
    /// the chroma is what makes deck read warm and vivy read green.
    /// Internal rather than private so the tests guard the SHIPPED value. They
    /// hardcoded a strength before, so they would have passed just as happily
    /// with a canvas set to white — which is the bug they exist to catch.
    ///
    /// Lowered with the lift rather than held, because "lighter" here means a
    /// weaker tint and not merely a paler one: dropping only the lightness step
    /// leaves the same amount of colour on a brighter surface, which reads as
    /// more saturated, not less. Deck lands on `#f4efdc`.
    static let canvasChroma = 1.4

    /// The pane's text scale — the session's own preference, not the terminal's.
    ///
    /// IT USED TO BE DERIVED, `terminalSize / 11.5`, so one shortcut moved both
    /// surfaces coherently and neither could be set alone. That was the right
    /// answer while there was one preference; it is the wrong one now that the
    /// session has its own. A user who had the terminal at 13pt keeps the ~113%
    /// page they have been reading, because `parseSession` seeds the new value
    /// from that same ratio the first time it loads a config without one.
    private var paneTextScale: Double {
        configuration.sessionTypography.clampedScale
    }

    /// Start a catalog session, then select it so its pane attaches.
    private func launch(_ entry: LaunchableSession) {
        let ref = SessionRef(host: entry.host, name: entry.id)
        selection = ref
        start(ref, directory: entry.workingDirectory, command: entry.command)
    }

    /// Start a stopped rail row: `co -r` in the row's own working directory,
    /// unless the row overrides the command. A stopped pinned CHILD resolves
    /// the same way through its crew's directory and command, since a
    /// sibling session has no launch settings of its own to override with —
    /// see `Crew.sessions`.
    ///
    /// This is what a Start button on a dead session presses. It sends a command
    /// at all because attaching does not: `new-session -A` would leave a bare
    /// shell with no agent in it.
    ///
    /// A ref matching neither a row nor a pinned child still gets the default
    /// rather than a bare `co`. That case should not arise, since the
    /// selection comes from `crews` or a crew's `sessions`, and if it
    /// ever does the refresh is the safer of the two.
    private func startSelectedRow(_ ref: SessionRef) {
        let row = owningCrew(for: ref)
        start(ref, directory: row?.workingDirectory,
              command: row?.launchCommand ?? Crew.defaultLaunchCommand)
    }

    /// Tells tmux to follow a window leaf's selection — see the `onChange`
    /// site's comment for why this is the one case Deck drives
    /// `select-window` at all. Off the main actor, and its failure is not
    /// surfaced: the terminal pane still attaches to the right SESSION
    /// either way, this only decides which of that session's windows is on
    /// screen, and the next poll's own drawing is unaffected by whether it
    /// landed.
    private func selectWindow(_ ref: SessionRef, window: Int) {
        // Unreachable in practice — a window leaf is only ever drawn under a
        // session the rail already resolved a host for — but an unresolved
        // host has nothing to send `select-window` to either way, and this
        // call's own failure is already not surfaced.
        guard let target = hostTarget(for: ref) else { return }
        Task {
            await Task.detached {
                try? TmuxWindowControl.selectWindow(target: target, session: ref.name, window: window)
            }.value
        }
    }

    /// The Stop confirm's message. PR #106 made "Stop" reachable from an
    /// "OTHER SESSIONS" row — a discovered session `surface(for:)` may have
    /// already confirmed has no agent — where the old, unconditional wording
    /// claimed an agent would be "asked to exit" even when there was none to
    /// ask. A PURE FUNCTION, mirroring `removeCrewMessage`, so both branches
    /// are pinned by a test rather than only read off the alert.
    nonisolated static func stopConfirmMessage(hasAgent: Bool) -> String {
        hasAgent
            ? "The agent is asked to exit, then the session and its scrollback are closed."
            : "The session and its scrollback are closed."
    }

    /// The Remove confirm's message — see
    /// `deck/specs/multiple-sessions-per-project` §"Remove". A PURE FUNCTION
    /// so the running-sessions sentence's wording, and its 0/1/2+ branches,
    /// are pinned by a test rather than only read off the alert.
    ///
    /// `hostLabel` is the crew's resolved host — see
    /// `RailRunningSessions.hostLabel(for:)`, the caller that resolves it —
    /// named because this sentence is about WHERE the folder lives, not
    /// about scope, and Convivy's own machine no longer belongs in text a
    /// stranger reads (`deck/specs/running-deck-as-someone-else`). `nil`
    /// when the crew's host does not resolve to anything configured; the
    /// location clause is dropped rather than naming a host that is not
    /// really there.
    nonisolated static func removeCrewMessage(runningSessionCount: Int,
                                              hostLabel: String? = nil) -> String {
        let base = hostLabel.map {
            "This removes the rail entry only. The folder on \($0) and its files are untouched."
        } ?? "This removes the rail entry only. The folder and its files are untouched."
        switch runningSessionCount {
        case 0:
            return base
        case 1:
            return base + " 1 session is still running and will keep running; "
                + "choose Remove and Stop if you want it ended."
        default:
            return base + " \(runningSessionCount) sessions are still running and will "
                + "keep running; choose Remove and Stop if you want them ended."
        }
    }

    /// The pinned-child Remove confirm's message — mirrors
    /// `removeCrewMessage`'s wording, but for exactly one session rather
    /// than 0/1/2+, since a child IS one session and the 0/1/2+ shape does
    /// not fit it. A PURE FUNCTION for the same reason `removeCrewMessage`
    /// is one. Names that the session stays reachable rather than lost —
    /// "worth a line in the confirm," per the spec — without naming the
    /// specific section it lands in: a Deck-spawned child's name still
    /// matches its own crew by `SessionGrouping`'s own rule even once
    /// unpinned, so it resurfaces as a discovered child of the SAME crew
    /// rather than in "OTHER SESSIONS"; only a hand-pinned or adopted
    /// session with no such name/path match lands there. Either way it is
    /// still on the rail, which is the claim this sentence actually makes.
    ///
    /// `hostLabel` follows `removeCrewMessage`'s own — the child's folder is
    /// the parent crew's, so it resolves the same way.
    nonisolated static func removeChildMessage(isRunning: Bool,
                                               hostLabel: String? = nil) -> String {
        let base = hostLabel.map {
            "This removes the rail entry only. The folder on \($0) and its files are untouched."
        } ?? "This removes the rail entry only. The folder and its files are untouched."
        guard isRunning else { return base }
        return base + " The session is still running and will keep running, still "
            + "reachable on the rail; choose Remove and Stop if you want it ended."
    }

    /// The catalog-row Remove confirm's message — a PURE FUNCTION for the
    /// same reason `removeChildMessage` is one. No "Remove and Stop" branch:
    /// a catalog entry owns no children to fuse a Stop with, so a running
    /// session just becomes reachable elsewhere rather than needing to be
    /// ended in the same click.
    nonisolated static func removeCatalogEntryMessage(isRunning: Bool) -> String {
        let base = "This removes it from Settings › Sessions."
        guard isRunning else { return base }
        return base + " The session is still running and will keep running, reachable "
            + "under Other Sessions."
    }

    /// The name a window promoted "to its own session" gets by default —
    /// pulled out as a pure static function so the label convention (and
    /// that this call site feeds `SiblingSessionName.derive` correctly) is
    /// pinned by a test rather than only exercised through the view. Phase 1
    /// already tests `derive` itself; this only needs to prove the label and
    /// arguments here are right.
    nonisolated static func deriveWindowSessionName(
        crewId: String, window: Int, existingNames: Set<String>
    ) throws -> String {
        try SiblingSessionName.derive(
            crewId: crewId, label: "window-\(window)", existingNames: existingNames)
    }

    /// "Move to its own session" on a window leaf. `window-<n>` is the
    /// default label — a judgment call in place of prompting for one, since
    /// a window's number is already a perfectly good name and a modal for
    /// every promotion would be friction the gesture does not need; both the
    /// label and the derivation still run through `SiblingSessionName.derive`,
    /// so they inherit the same collision and scratch-shell-truncation
    /// checks a typed label would.
    private func moveWindowToOwnSession(crew: Crew, owningSession: String, window: Int) {
        guard let name = try? ContentView.deriveWindowSessionName(
            crewId: crew.id, window: window, existingNames: allKnownSessionNames) else {
            store.saveError = "Could not name a new session for window \(window)."
            return
        }
        guard let target = hostTarget(for: SessionRef.owned(by: crew, name: owningSession)) else {
            store.saveError = "Could not move window \(window) to its own session: "
                + "\(crew.displayName) has no host configured."
            return
        }
        Task {
            let message: String? = await Task.detached {
                do {
                    try TmuxWindowControl.moveWindow(
                        target: target, session: owningSession, window: window, newSessionName: name)
                    return nil
                } catch { return "\(error)" }
            }.value
            if let message {
                store.saveError = "Could not move window \(window) to its own session: \(message)"
                return
            }
            // The promoted window survives as a normal pinned sibling from
            // here on — the same `ThemeStore.addPinnedSession` call
            // `adoptSession` makes, and the same reason: config is what
            // makes a child's name and order outlive a restart.
            store.addPinnedSession(
                PinnedSession(name: name, displayName: "window-\(window)"), toCrew: crew.ref)
            selection = SessionRef.owned(by: crew, name: name)
        }
    }

    /// Create a session on the mini and mark it launching so the pane says
    /// "Starting…" rather than "cannot reach" during the beat before it exists.
    ///
    /// The start runs off the main actor — an ssh round trip must not freeze the
    /// window. A start that genuinely fails surfaces through the same saveError
    /// channel the config write uses.
    ///
    /// ONE failure is swallowed, and which one moved after it hid a dead end —
    /// see `SessionAgent.isBenignStartFailure`, which now owns and tests that
    /// judgement.
    private func start(_ ref: SessionRef, directory: String?, command: String?) {
        guard let target = hostTarget(for: ref) else {
            store.saveError = "Could not start \(ref.name): no host is configured for it. "
                + "Add one in Settings \u{203a} Hosts."
            return
        }
        beginLaunch(ref, failureVerb: "start") {
            try SessionAgent.start(target: target, session: ref.name, directory: directory, command: command)
        }
    }

    /// The launch bookkeeping `start` uses, and its only caller since the
    /// private `createCrew` went with the "+ New" sheet: mark the id
    /// launching, run the ssh call off the main actor, then clear it and
    /// hand the launch a ticket the rail's next poll can resolve against.
    /// Factored out so the placeholder machinery (`launching`,
    /// `launchPending`, `LaunchInFlight`) has exactly one implementation
    /// regardless of which `SessionAgent` call started the session.
    ///
    /// `onFailure` fires only on the genuine-failure branch below, never on
    /// the benign "already has an agent" race `isBenignStartFailure` catches
    /// — that race means the row is real and merely arrived a beat before
    /// the rail's next poll, so nothing should be rolled back.
    private func beginLaunch(
        _ ref: SessionRef, failureVerb: String, onFailure: (() -> Void)? = nil,
        run: @escaping @Sendable () throws -> Data
    ) {
        launching.insert(ref)
        // No ticket yet, deliberately. The tmux session does not exist on the
        // mini until the call below returns, so until then NO poll can speak
        // to this launch, however freshly it was issued. See `LaunchInFlight`.
        launchPending[ref] = LaunchInFlight()
        Task {
            let message: String? = await Task.detached {
                do {
                    try run()
                    return nil
                } catch {
                    let text = "\(error)"
                    return SessionAgent.isBenignStartFailure(text) ? nil : text
                }
            }.value
            launching.remove(ref)
            // The session now exists on the mini, so a poll ISSUED from here
            // on will see it — and a "stopped" from one of those is a real
            // verdict rather than a statement about a session that had not
            // been created yet. Only set when the entry is still there: a
            // selection change or a rail removal may have retired it.
            if launchPending[ref] != nil {
                launchPending[ref]?.decidableFrom = railState.pendingTicket
            }
            if let message {
                store.saveError = "Could not \(failureVerb) \(ref.name): \(message)"
                // A genuine failure, not the benign "already has an agent"
                // race — nothing further will confirm this session alive, so
                // waiting on that would hold the placeholder up forever. Let
                // it come down and show the real error instead.
                launchPending[ref] = nil
                onFailure?()
            }
        }
    }

    /// Whether the launch placeholder should cover the pane region.
    ///
    /// A pure function of three independent signals, deliberately not just
    /// `launching`: `launchPending` says a start is unresolved, `isAlive` and
    /// `isStopped` are the rail's own readings, from ITS OWN poll — and the
    /// artifact this covers is precisely the gap between those readings and
    /// `launchPending` settling. See `launchPending`'s doc for the sequence
    /// that gap produces.
    ///
    /// `isStopped` clears the placeholder too, not only `isAlive`, because a
    /// start can resolve either way: `SessionAgent.start` returns
    /// successfully but the agent inside the new session dies immediately —
    /// wrong working directory, missing command, an ordinary launch crash —
    /// and the next rail poll reports the session stopped, never alive.
    /// Without this the placeholder covers `StartSessionView`'s own Start and
    /// Terminal buttons forever, and the only way out is quitting Deck.
    ///
    /// ONLY A READING TAKEN AFTER THE LAUNCH DECIDES ANYTHING, which is what
    /// `hasReadingSinceLaunch` carries. Without it this predicate was inert on
    /// the path that matters most: restarting a stopped session. `isStopped`
    /// is already true at the button press — it is the reason `StartSessionView`
    /// is on screen at all — so an earlier version read its own precondition as
    /// a verdict on the launch and never raised the placeholder. Every artifact
    /// it was built to cover survived, for every restart. Caught by
    /// deck-reviewer.
    ///
    /// Both readings are gated on freshness rather than just `isStopped`,
    /// because the reasoning is about the reading's age and not about which
    /// answer it carries: a poll that predates the launch is evidence of what
    /// was true before it, whatever it says.
    ///
    /// It APPEARS the instant `launchPending` gains the id — the button press,
    /// before `SessionAgent.start` is even dispatched — and clears the instant
    /// the rail has real evidence, however long that takes. It also clears once
    /// `elapsedSinceLaunch` passes `launchPlaceholderTimeout`, however the other
    /// three arguments read, which is the one exception to "never on a timer"
    /// this predicate makes.
    ///
    /// THAT EXCEPTION EXISTS BECAUSE "NO EVIDENCE YET" AND "NO EVIDENCE EVER
    /// COMING" READ IDENTICALLY through `isAlive`/`isStopped` alone — both are
    /// false before a poll lands AND false for every poll a genuinely
    /// unreachable host produces, since a transport failure is neither an
    /// alive reading nor a stopped one (`RailStateModel.isStopped`'s own doc:
    /// "A transport failure ... is deliberately NOT stopped"). Without a
    /// second, independent signal this predicate cannot tell a slow launch
    /// from a host that was never going to answer, and stayed up covering the
    /// pane in exactly that shape until this was added — see the PR this
    /// shipped in for the incident that found it. `elapsedSinceLaunch` is that
    /// second signal precisely because it does not depend on a poll landing at
    /// all: it advances whether or not the host ever answers.
    ///
    /// Past the bound this returns `false` — the placeholder comes down and
    /// whatever the pane draws underneath (`SessionPaneView`,
    /// `StartSessionView`) is on its own to say what it actually knows, the
    /// same as it already does once `hasReadingSinceLaunch` is true. This does
    /// NOT claim the session is reachable, alive, or stopped; it only stops
    /// asserting "still loading" once that stops being an honest thing to say.
    nonisolated static func showsLaunchPlaceholder(launchPending: Bool, isAlive: Bool,
                                                   isStopped: Bool,
                                                   hasReadingSinceLaunch: Bool,
                                                   elapsedSinceLaunch: TimeInterval) -> Bool {
        guard launchPending else { return false }
        guard elapsedSinceLaunch < launchPlaceholderTimeout else { return false }
        guard hasReadingSinceLaunch else { return true }
        return !isAlive && !isStopped
    }

    /// How long the launch placeholder is allowed to cover the pane with no
    /// resolving evidence — generous next to an ordinary launch, which
    /// resolves within one poll interval, but bounded, which is the whole
    /// point: see `showsLaunchPlaceholder`. Sized with real margin above the
    /// worst case a single bounded ssh call can take: `SessionAgent.run`'s
    /// stale-socket recovery is `SessionAgent.defaultTimeout` (20s) for the
    /// first attempt, `SSHControlSocket.checkTimeout` (5s) for `check`, the
    /// same bound again for `clear`'s config-resolve step (5s), and a second
    /// full `defaultTimeout` (20s) for the retry — 50s total. This sits 15s
    /// above that rather than under it, so the placeholder outlasts an
    /// in-flight bounded call instead of dropping a beat before it resolves.
    nonisolated static let launchPlaceholderTimeout: TimeInterval = 65

    /// Whether the rail's current reading was ISSUED after a launch that
    /// captured `launchedAt` from `RailStateModel.pendingTicket`.
    ///
    /// `>=`, not `>`, and that is the whole comparison. `launchedAt` is the
    /// ticket the next poll issued after the press WILL carry, so a reading
    /// stamped with exactly that number is the first one that asked the mini
    /// after the launch — the earliest reading entitled to an opinion about it.
    /// Anything below is a poll issued earlier, however late it landed.
    ///
    /// Pulled out of the call site because it is where the subtlety lives: a
    /// version of this that dated readings by arrival cleared the placeholder
    /// mid-launch whenever a poll happened to be in flight at the press.
    nonisolated static func hasReadingSinceLaunch(reading: Int, launchedAt: Int) -> Bool {
        reading >= launchedAt
    }

    /// Stop a session: ask its agent to exit, then close the tmux session. The
    /// confirmation lives at the call site (the `.alert`); by here the user has
    /// said yes. Off the main actor for the same reason start is.
    private func stop(_ ref: SessionRef) {
        guard let target = hostTarget(for: ref) else {
            store.saveError = "Could not stop \(ref.name): no host is configured for it."
            return
        }
        Task {
            let message: String? = await Task.detached {
                do { try SessionAgent.stop(target: target, session: ref.name, kill: true); return nil }
                catch { return "\(error)" }
            }.value
            if let message { store.saveError = "Could not stop \(ref.name): \(message)" }
        }
    }

    /// Apply a rollover override from a row. Off the main actor, like `stop`.
    /// A successful change needs no message: the next poll redraws the row's
    /// meter in its new state.
    private func changeRollover(_ ref: SessionRef, _ action: SessionAgent.RolloverAction) {
        guard let target = hostTarget(for: ref) else {
            store.saveError = "Could not change \(ref.name)\u{2019}s rollover: no host is configured for it."
            return
        }
        Task {
            let message: String? = await Task.detached {
                do {
                    return ContentView.rolloverFailure(
                        try SessionAgent.rollover(target: target, session: ref.name, action: action))
                } catch {
                    return "\(error)"
                }
            }.value
            if let message { store.saveError = "Could not change \(ref.name)\u{2019}s rollover: \(message)" }
        }
    }

    /// What to tell the operator about a rollover override's outcome, or nil
    /// when it took effect. A PURE FUNCTION so a refusal and an unreadable
    /// answer are pinned by a test: on a write, an answer Deck cannot read
    /// must never pass silently as success.
    nonisolated static func rolloverFailure(_ outcome: SessionAgent.RolloverOutcome) -> String? {
        switch outcome {
        case .sent, .armed: return nil
        case .refused(let reason): return reason
        // NAMES NO MACHINE. This said "the mini", which is Convivy's own
        // hardware and meaningless on anyone else's install
        // (`deck/specs/running-deck-as-someone-else`, Check 1).
        //
        // Generic because the CALLER ALREADY PREFIXES THE SESSION — "Could
        // not change deck's rollover: …" — and the failing row is the one the
        // operator just clicked, so the machine name adds nothing they need.
        //
        // **The friendly host name IS reachable, and an earlier version of
        // this comment wrongly said it was not.** `changeRollover` holds
        // `ref.host` and `configuration.hosts`, and
        // `HostDisplay.label(for:hosts:probed:)` is already called in this
        // file; its chain prefers the probed machine name, then the config
        // name, and reaches a raw address only when both fail the charset
        // gate. So interpolating it would not normally leak a Tailnet
        // address. Interpolation is left for later on the reason above, not
        // because it cannot be done. `testRolloverFailureNamesNoMachine`
        // pins the generic wording.
        case .malformed: return "the host\u{2019}s answer could not be read, so the change may not have taken effect"
        }
    }

    /// "Remove" on the catalog-row confirm — config only, never the mini's
    /// filesystem or a running tmux session, the same discipline
    /// `store.removeCrew`/`removePinnedSession` follow. Goes through
    /// `SessionRoster`, the write path Settings › Sessions already drives
    /// for every remove (`SessionsSettingsView`), rather than a new
    /// `ThemeStore` method: `SessionRoster.remove(_:)` already enforces
    /// unique refs across the rail and the catalog, so `entry.ref` can only
    /// ever match this one row.
    private func removeCatalogEntry(_ entry: LaunchableSession) {
        var roster = SessionRoster(configuration: configuration,
                                   servedCrews: Array(railState.servedCrews.values))
        roster.remove(entry.ref)
        store.setRoster(roster)
    }

    /// "Remove and Stop" on the Remove confirm — see
    /// `deck/specs/multiple-sessions-per-project` §"Remove". Stops every
    /// session `crewSessionNames(for:)` names for this crew (itself, its
    /// pinned children, its discovered children), then removes the row
    /// regardless of whether every stop succeeded: the user asked for the
    /// row to go, and a session that refused to stop is not a reason to
    /// leave a phantom row behind for it. Failures report stop-by-stop
    /// through the same `store.saveError` channel `stop(_:)` uses, one at a
    /// time — the last failure is what the user sees, the same single-slot
    /// behaviour every other `saveError` write already has.
    private func removeCrewAndStopSessions(_ crew: Crew) {
        let names = crewSessionNames(for: crew).sorted()
        // An unresolved host has nothing to send a stop to for ANY of this
        // crew's sessions — every one of them inherits the crew's own
        // `host` — but the row still goes: the user asked for it to be
        // removed, the same "not a reason to leave a phantom row" reasoning
        // that already governs a stop that fails for any other reason.
        guard let target = hostTarget(for: SessionRef.owned(by: crew, name: crew.id)) else {
            if !names.isEmpty {
                store.saveError = "Could not stop \(crew.displayName)\u{2019}s sessions: "
                    + "no host is configured for it."
            }
            store.removeCrew(crew.ref)
            return
        }
        Task {
            for name in names {
                let message: String? = await Task.detached {
                    do { try SessionAgent.stop(target: target, session: name, kill: true); return nil }
                    catch { return "\(error)" }
                }.value
                if let message { store.saveError = "Could not stop \(name): \(message)" }
            }
            store.removeCrew(crew.ref)
        }
    }

    /// "Remove and Stop" on the pinned-child Remove confirm — the
    /// single-session counterpart to `removeCrewAndStopSessions`. Removes
    /// the pin regardless of whether the stop succeeded, the same reason
    /// the crew-level version does: the user asked for the row to go, and a
    /// session that refused to stop is not a reason to leave it pinned.
    private func removeChildAndStopSession(_ crew: Crew, _ session: PinnedSession) {
        let ref = SessionRef.owned(by: crew, name: session.name)
        guard let target = hostTarget(for: ref) else {
            store.saveError = "Could not stop \(ref.name): no host is configured for it."
            store.removePinnedSession(session.name, fromCrew: crew.ref)
            return
        }
        Task {
            let message: String? = await Task.detached {
                do { try SessionAgent.stop(target: target, session: ref.name, kill: true); return nil }
                catch { return "\(error)" }
            }.value
            if let message { store.saveError = "Could not stop \(ref.name): \(message)" }
            store.removePinnedSession(session.name, fromCrew: crew.ref)
        }
    }

    /// "Adopt into <Crew>" on an "OTHER SESSIONS" row's context menu —
    /// the inverse of Remove: pins a session Deck did not create as the
    /// chosen crew's child, using its own tmux name as its display name
    /// (matching how a discovered child is drawn today — "no display name
    /// of its own"). A NAV act, not a move: no directory change, no
    /// restart, no touch of the mini beyond the config write — only where
    /// Deck draws the row changes. See
    /// `deck/specs/multiple-sessions-per-project` §"The model".
    private func adoptSession(_ discovered: DiscoveredSession, into crew: Crew) {
        store.addPinnedSession(
            PinnedSession(name: discovered.name, displayName: discovered.name), toCrew: crew.ref)
    }

    /// `SessionPromotion.derive`'s outcome for `session`, against the crew
    /// ids on the rail right now — read by both the confirm's Promote button
    /// (present only on `.success`) and its message. `derive` throws only
    /// `SessionPromotion.PromotionError`, so the cast in `catch` always
    /// succeeds.
    private func promotionResult(for session: DiscoveredSession) -> Result<Crew, SessionPromotion.PromotionError> {
        do {
            return .success(try SessionPromotion.derive(
                session,
                existingRefs: SessionPromotion.existingRefs(
                    for: crews, hosts: configuration.hosts, defaultHost: configuration.defaultHost),
                hosts: configuration.hosts))
        } catch let error as SessionPromotion.PromotionError {
            return .failure(error)
        } catch {
            return .failure(.collision(session.name))
        }
    }

    /// The promote confirm's message: what promotion will do, on success, or
    /// why it was refused, on a collision.
    private func promotionMessage(for session: DiscoveredSession) -> String {
        switch promotionResult(for: session) {
        case .success:
            let hostLabel = HostResolution.hostName(for: session.id.host, hosts: configuration.hosts)
            return ContentView.promoteSessionMessage(name: session.name, hostLabel: hostLabel)
        case .failure(let error):
            return ContentView.promotionErrorMessage(error)
        }
    }

    /// "Promote" on the confirm. A NAV act, not a move, exactly like
    /// `adoptSession`: it does not restart the session, does not create or
    /// move a directory, and does not touch the mini — only where Deck
    /// draws the row changes. Selects the new crew's row.
    private func promoteSession(_ discovered: DiscoveredSession, as crew: Crew) {
        store.addCrew(crew)
        selection = SessionRef.owned(by: crew, name: crew.id)
    }

    /// The promote confirm's message on success — pinned separately so its
    /// wording can be tested without building a `Result`.
    ///
    /// `hostLabel` is the session's own actually-resolved `SSHTarget` (a
    /// promotable session is always an "OTHER SESSIONS" row, so it carries
    /// its host directly rather than through a crew — see
    /// `HostResolution.hostName(for:hosts:)`), named for the same reason
    /// `removeCrewMessage`'s `hostLabel` is: naming Convivy's own machine in
    /// text a stranger reads is what `deck/specs/running-deck-as-someone-else`
    /// rules out. `nil` drops the location clause rather than naming a host
    /// that is not really there.
    nonisolated static func promoteSessionMessage(name: String, hostLabel: String? = nil) -> String {
        let unchanged = hostLabel.map { "nothing on \($0) changes." } ?? "nothing changes."
        return "This adds \(name) as its own crew on the rail. The session keeps running "
            + "and is not restarted; \(unchanged)"
    }

    /// The promote confirm's message on a derivation failure — pinned
    /// separately so the wording is testable without a confirm dialog.
    nonisolated static func promotionErrorMessage(_ error: SessionPromotion.PromotionError) -> String {
        switch error {
        case .collision(let id):
            return "\(id) already exists as a crew on the rail."
        }
    }

    /// "user@machine" for the selected session's resolved host, or nil when
    /// nothing is selected, the local shell is, or only one host is
    /// configured — see
    /// `deck/specs/multiple-sessions-per-project` §"Where it is drawn":
    /// "on the pane chrome for the selected session, where there is
    /// horizontal room, and only when more than one host is configured."
    /// `WindowLeaf.parse` recovers the owning session first, the same way
    /// `target(for:)` does, so a window leaf's chrome reads its owning
    /// session's host rather than failing to resolve one at all.
    private var selectedHostLabel: String? {
        guard configuration.hosts.count > 1, let selection, selection != .localShell else { return nil }
        let key = WindowLeaf.parse(selection)?.session ?? selection
        guard let target = hostTarget(for: key) else { return nil }
        return HostDisplay.label(
            for: target, hosts: configuration.hosts,
            probed: { railState.probedMachineName(for: $0) })
    }

    /// The occupant the toolbar's always-on Slate segment offers for the
    /// current selection, or `nil` when there is no crew to show one for —
    /// no selection, the local shell, or a selection whose host has not
    /// resolved. `WindowLeaf.parse` recovers the owning session first, the
    /// same way `selectedHostLabel` does, so a terminal tab's Slate is its
    /// crew's own Slate rather than one keyed on the tab's own synthetic name.
    private var selectedSlateOccupant: ColumnOccupant? {
        slateOccupant(for: selection)
    }

    /// The Slate occupant for the crew `ref` belongs to, or `nil` when there
    /// is no crew or its host has not resolved. Takes the selection as an
    /// argument so `rightColumnPicker` can ask about the selection it is
    /// moving away from, which `selection` no longer holds in `onChange`.
    private func slateOccupant(for ref: SessionRef?) -> ColumnOccupant? {
        guard let key = slateKey(for: ref), let target = hostTarget(for: key) else { return nil }
        return .slate(session: key.name, target: target, crew: key)
    }

    /// The crew reference a Slate for `ref` is keyed on, or `nil` when there
    /// is no crew. Unlike `slateOccupant(for:)`, it does not need the host to
    /// resolve, so the crew being left can still be named after its host changes.
    private func slateKey(for ref: SessionRef?) -> SessionRef? {
        guard let ref, ref != .localShell else { return nil }
        return WindowLeaf.parse(ref)?.session ?? ref
    }

    /// Whether the toolbar's mode selector should show Terminal selected —
    /// the same truth `mainPane` draws from (`showsTerminal(for:)`), not
    /// `showingTerminal` alone. See `pickerShowsTerminal`'s doc for why the
    /// membership set alone lied for a `.terminalOnly` session.
    private var isShowingTerminalForSelection: Bool {
        selection.map { showsTerminal(for: $0) } ?? false
    }

    private func toggleTerminalView() {
        guard let selection else { return }
        if showingTerminal.contains(selection) {
            showingTerminal.remove(selection)
        } else {
            showingTerminal.insert(selection)
        }
    }

    /// The strip above the panes — Deck's toolbar. It draws exactly two
    /// mechanisms, because there are exactly two: which occupant sits in the
    /// right-hand column, and whether the main pane shows the conversation or
    /// Terminal View underneath it. Two Buttons here used to stand in for the
    /// first mechanism (Local, Shell) with no segment for Cockpit itself or
    /// for the viewer/editor/item occupants the toolbar could not show at
    /// all — four look-alike toggles across two mechanisms, misstating both.
    ///
    /// TAKES `rowWidth` AS A PLAIN VALUE, passed down from a `GeometryReader`
    /// hoisted above this view's parent `VStack` (`body`, `:649`), rather than
    /// reading it back via a `PreferenceKey` into `@State`. The round trip
    /// this replaced never delivered: the preference was set on a `Group`
    /// whose content branches on `usesColumnSheet`, and `_ConditionalContent`
    /// — the type an `if`/`else` inside a `ViewBuilder` produces — does not
    /// reliably carry a preference to `.onPreferenceChange` when hosted
    /// without a real `App`/`Scene`, confirmed by a minimal repro in
    /// `issue_01M249YXQESGX3D74AJMN1H5XN`. `chromeRowWidth` stayed at its
    /// initial `0` every pass, which floors `mainPaneChromeWidth` at `0` too
    /// — a zero-wide leading box, trailing-aligned, puts the Main pane picker
    /// at the row's far left. `paneChrome` and the pane row's own
    /// `GeometryReader` (`:659`) are siblings in the same `VStack`, so the
    /// hoisted reader reports the identical width `columnWidth(totalWidth:)`
    /// resolves the divider against, with no preference and no delivery to
    /// fail.
    private func paneChrome(rowWidth: CGFloat) -> some View {
        Group {
            if usesColumnSheet {
                // BELOW `LayoutBreakpoints.columnSheet` THE RIGHT COLUMN
                // LEAVES THE ROW AND ARRIVES AS A SHEET instead (`body`,
                // `usesColumnSheet`'s doc), so there is no divider for the
                // Main pane picker's trailing edge to align to. The Right
                // column picker is still drawn here too, as the control that
                // SUMMONS that sheet, so flushing the Main pane picker to
                // where a divider would be risks landing it on top of that
                // control instead. Keep the one right-aligned group this
                // toolbar always drew, below the breakpoint only.
                HStack {
                    hostLabel
                    Spacer()
                    mainPanePicker
                        .padding(.trailing, 10)
                    rightColumnPicker(fittingWidth: ContentView.sheetWidth)
                }
            } else {
                // Two boxes rather than one right-aligned group, so the Main
                // pane picker's trailing edge lands on the divider BY
                // CONSTRUCTION instead of by a tuned constant: the leading
                // box is exactly the main pane's own width, so its content,
                // trailing-aligned within it, cannot end anywhere else.
                // `columnWidth(totalWidth:)` is the same call the column
                // itself uses to size against this divider (`:696`).
                // `rowWidth` is this row's own width, handed down from
                // `body`'s hoisted `GeometryReader` — see this function's doc.
                HStack(spacing: 0) {
                    HStack {
                        hostLabel
                        Spacer()
                        mainPanePicker
                    }
                    .frame(width: CGFloat(ContentView.mainPaneChromeWidth(
                        chromeRowWidth: Double(rowWidth), dragging: draggingColumnWidth,
                        stored: configuration.columnWidth)),
                           alignment: .trailing)
                    // `spacing: 0`: the default 8pt between the Spacer and the
                    // picker would push a column-width picker past the row's edge.
                    // Under Builder Default the cockpit's band takes the column's last
                    // 12pt, so the picker stops at the band's edge rather than
                    // drawing its track over the band.
                    HStack(spacing: 0) {
                        Spacer()
                        rightColumnPicker(fittingWidth: columnWidth(totalWidth: rowWidth))
                    }
                    .padding(.trailing, frameBandInset)
                }
            }
        }
        // `maxWidth: .infinity` PROPOSES THIS ROW THE FULL WIDTH `rowWidth`
        // NAMES, rather than letting it hug its own content. Without this,
        // the outer `HStack`'s trailing box (the right column's picker and
        // stop-session menu, both flexible around a `Spacer`) has nothing to
        // expand into and hugs its content instead of reaching the divider —
        // the leading box's fixed width alone does not fill the row.
        .frame(maxWidth: .infinity)
    }

    /// The host label's ink under Builder Default: the place-line ink solved
    /// against the ground. `paneChrome` is the pin's child, so this reads the
    /// preference from the configuration rather than the environment. Every
    /// other preset gets `.secondary`, the system's own.
    private var chromeHostInk: AnyShapeStyle {
        guard let ground = configuration.pinnedSurface(for: .chrome)?.ground else {
            return AnyShapeStyle(.secondary)
        }
        return AnyShapeStyle(Color(ThemeRecipe.placeLineInk(on: ground)))
    }

    /// "user@machine" beside the pickers, or nothing — pulled out of
    /// `paneChrome` so both its branches (the pre-breakpoint single group and
    /// the post-breakpoint two-box split) draw the identical leading content.
    @ViewBuilder
    private var hostLabel: some View {
        if let selectedHostLabel {
            Text(selectedHostLabel)
                .frameFont(.label)
                .foregroundStyle(chromeHostInk)
                .padding(.leading, 10)
        }
    }

    /// A two-segment selector, not a toggle button: modelled on the "Right
    /// column" picker below, and replacing a bordered/borderedProminent pair
    /// that cost ~130pt with its border and the row's own spacing — width the
    /// status bar needed back for the billing token
    /// (`SessionPaneView.swift`'s `PaneStatusBar`).
    ///
    /// Always enabled whenever a selection exists: the terminal is the
    /// drift-proof fallback, and a user must never be stuck inside a surface
    /// that is confused about what is happening, so this segment stays
    /// reachable in every state the status bar's deleted "See Terminal View"
    /// button covered.
    private var mainPanePicker: some View {
        Picker("Main pane", selection: Binding(
            get: { isShowingTerminalForSelection },
            set: { pickedTerminal in
                if pickedTerminal != isShowingTerminalForSelection { toggleTerminalView() }
            }
        )) {
            Label("Session", systemImage: "message").tag(false)
            Label("Terminal", systemImage: "apple.terminal").tag(true)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.large)
        .fixedSize()
        .segmentedField()
        .disabled(selection == nil)
        .help("Terminal View (a main-pane swap, independent of the column)")
    }

    /// `ColumnOccupant` has exactly one live case, so it is one segmented
    /// control rather than a button per case. The fourth segment appears only
    /// while the column holds a viewer, editor or item, so the control can
    /// always say what the column holds — the two Buttons this replaces could
    /// not show those three occupants at all.
    /// A CUSTOM BINDING, not `$columnOccupant` directly — selecting a segment
    /// is a SUMMONS below `LayoutBreakpoints.columnSheet`
    /// (`presentColumnOccupant`), which a plain binding to the `@State`
    /// cannot express: it would only set the content, never the sheet's own
    /// visibility. Harmless above the breakpoint, where
    /// `isColumnSheetPresented` is never read.
    private func rightColumnPicker(fittingWidth: CGFloat) -> some View {
        // Both forms carry the same occupants, so only the drawing changes; the
        // width fallback itself lives in `RightColumnPicker`.
        RightColumnPicker(selection: Binding<ColumnOccupant>(
            get: {
                ColumnOccupant.selectionSlateCovering(columnOccupant, selectionSlate: selectedSlateOccupant)
                    ?? columnOccupant
            },
            set: { presentColumnOccupant($0) }
        ), fittingWidth: fittingWidth) { iconOnly in
            columnSegment(restStateLabel, "square.grid.2x2.fill", iconOnly: iconOnly, tag: .cockpit)
            columnSegment("Shell", "terminal.fill", iconOnly: iconOnly, tag: .remoteShell)
            columnSegment("Local", "laptopcomputer", iconOnly: iconOnly, tag: .localTerminal)
            // ALWAYS OFFERED FOR A REACHABLE SELECTION, the same footing as
            // Shell and Local above, rather than appearing only once already
            // open the way the viewer/editor/item/run segments below do —
            // this is the "clear way to open the Slate sheet for a crew"
            // issue_01M3WPYD8M0P8PD20Y3ZBNGBWG asks for, ahead of the rail
            // badge CQ-121 adds later. Hidden only when there is no crew
            // selected or its host has not resolved, the same condition
            // every per-session verb in this toolbar already needs.
            if let slateOccupant = selectedSlateOccupant {
                columnSegment("Slate", "list.bullet.clipboard.fill", iconOnly: iconOnly, tag: slateOccupant)
            }
            if case .viewer(let ref, let target) = columnOccupant {
                columnSegment("Viewer", "doc.text", iconOnly: iconOnly,
                              tag: .viewer(ref: ref, target: target))
            }
            if case .editor(let ref, let target) = columnOccupant {
                columnSegment("Editor", "square.and.pencil", iconOnly: iconOnly,
                              tag: .editor(ref: ref, target: target))
            }
            if case .item(let id, let target) = columnOccupant {
                columnSegment("Item", "checklist", iconOnly: iconOnly,
                              tag: .item(id: id, target: target))
            }
            if case .run(let runId) = columnOccupant {
                columnSegment("Run", "text.alignleft", iconOnly: iconOnly,
                              tag: .run(runId: runId))
            }
            // A Slate already open for a session OTHER than the current
            // selection — the future rail badge's case
            // (issue_01M3WPYSH0S1FZVZ6P3YMNJGXW) — needs its own segment too,
            // the same way `.item`/`.run` above cover an occupant the
            // always-on branch could not have offered. Guarded by crew, not
            // by the whole value: a Slate opened before its host was edited
            // carries the old target, and the always-on segment already
            // stands for that crew. The segment keeps the glyph and icon-only
            // fallback of the other segments.
            if case .slate(let session, let target, let crew) = columnOccupant,
               ColumnOccupant.selectionSlateCovering(columnOccupant, selectionSlate: selectedSlateOccupant) == nil {
                columnSegment("Slate", "list.bullet.clipboard.fill", iconOnly: iconOnly,
                              tag: ColumnOccupant.slate(session: session, target: target, crew: crew))
            }
        }
        .onChange(of: columnOccupant) { old, new in
            if new == .remoteShell, old != .remoteShell { resolveShellCwd() }
        }
        // A Slate that was showing the crew being left follows the selection
        // to the new crew, so the picker never holds two Slate segments for
        // one selection. Lives here, not in `body`, because this picker is
        // drawn in both the docked and the sheet layouts.
        .onChange(of: selection) { old, new in
            let next = ColumnOccupant.followingSelection(
                from: columnOccupant,
                leaving: slateKey(for: old),
                entering: slateKey(for: new),
                newSelectionSlate: slateOccupant(for: new))
            guard next != columnOccupant else { return }
            if next == .cockpit { closeColumnOccupant() } else { columnOccupant = next }
        }
        // A host edit changes the Slate the column's crew has now, even while
        // another crew is selected. Observing that value, not `configuration`,
        // keeps the trigger to this crew. Re-pointing the column changes
        // `columnOccupant`, so `SlatePane` restarts on the new target, and
        // `SlateModel.start` flushes the old crew first.
        .onChange(of: columnCrewSlate) { _, _ in
            let next = ColumnOccupant.repointingToCrewSlate(
                columnOccupant, currentSlate: slateOccupant(for:))
            guard next != columnOccupant else { return }
            if next == .cockpit { closeColumnOccupant() } else { columnOccupant = next }
        }
    }

    /// The Slate the column's own crew has now, or `nil` when the column
    /// holds no Slate or that crew's host has stopped resolving. Its change
    /// is the trigger for re-pointing the column after a host edit.
    private var columnCrewSlate: ColumnOccupant? {
        guard case .slate(_, _, let crew) = columnOccupant else { return nil }
        return slateOccupant(for: crew)
    }

    /// Whether `mainPane` draws the given session's live `SessionPaneView` —
    /// read by both the find bar's searchable-surface check and `mainPane`'s
    /// own branch via `SessionSurface.showsConversationPane`, so the two can
    /// never drift the way a hand-copied second copy of this condition once
    /// did.
    private func sessionPaneIsShowing(for ref: SessionRef) -> Bool {
        surface(for: ref).showsConversationPane(
            hasSessionPane: hasSessionPane(ref),
            isShowingTerminal: showingTerminal.contains(ref),
            hasHostTarget: hostTarget(for: ref) != nil,
            isLaunching: launching.contains(ref))
    }

    /// Whether `mainPane` is drawing one of the two surfaces the find bar
    /// can search — the conversation or the main pane's OWN Terminal View,
    /// never `shellPane`/`localTerminalPane` in the right column, which the
    /// bar does not reach. Mirrors `mainPane`'s own if/else-if ladder,
    /// branch for branch and in the same order, so ⌘F cannot claim the key
    /// in a state
    /// (`UnresolvedHostView`, `StartSessionView`, `MissingDirectoryView`)
    /// where there is nothing underneath it to search.
    private var isSearchableSurfaceShowing: Bool {
        guard let selection else { return false }
        if hasSessionPane(selection), hostTarget(for: selection) == nil { return false }
        if hasSessionPane(selection), !showingTerminal.contains(selection),
           surface(for: selection) == .start, !launching.contains(selection) { return false }
        if hasSessionPane(selection), !showingTerminal.contains(selection),
           surface(for: selection) == .missingDirectory { return false }
        if hasSessionPane(selection), showsStaleGate(for: selection) { return false }
        if sessionPaneIsShowing(for: selection), hostTarget(for: selection) != nil { return true }
        return target(for: selection) != nil
    }

    /// The close control every right-column band carries. Closing returns to
    /// the cockpit, which is what the viewer and editor headers already promise.
    private var columnCloseButton: some View {
        Button(action: closeColumnOccupant) {
            Image(systemName: "xmark")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Close and return to the cockpit")
    }

    /// The canvas a session pane paints for `palette` in `appearance`, as RGB.
    /// `paneCanvas(for:on:)` returns it as hex for `SessionPaneView`.
    static func paneCanvas(for palette: TerminalPalette, appearance: Appearance) -> RGB {
        palette.background.canvasTint(for: appearance,
                                      lift: ContentView.canvasLift,
                                      chroma: ContentView.canvasChroma)
    }

    /// Why the cockpit column has nothing to follow, or nil when it does.
    /// Read by `CockpitView` and by the `.onChange`/`.task` below that keeps
    /// `cockpitModel` pointed at the right project.
    ///
    /// **THE WHOLE-VIEW REASON ONLY FOR `.course`** (`RestStateResolution.Shape`)
    /// — see `restStateUnresolvedReason` for the `.board`/`.service` answer,
    /// which asks nothing about a Library project. On `.board` this feeds only
    /// the Course panel (`CockpitView.courseUnresolvedReason`), so a steward
    /// with no project still sees its fleet; it never reaches `ServiceCrewPanel`.
    private var cockpitUnresolvedReason: String? {
        CockpitResolution.unresolvedReason(
            hasSelection: selection != nil,
            crew: selection.flatMap { owningCrew(for: $0) },
            target: selection.flatMap { hostTarget(for: $0) })
    }

    /// Why the Pull Requests panel has nothing to follow, or nil when it
    /// does — read by `CockpitView` alongside `pullRequestsPanel`. Gated on
    /// `crew.repo` rather than `crew.project`, the two fields being set
    /// independently (`CockpitResolution.prLadderUnresolvedReason`'s doc).
    private var pullRequestsUnresolvedReason: String? {
        CockpitResolution.prLadderUnresolvedReason(
            hasSelection: selection != nil,
            crew: selection.flatMap { owningCrew(for: $0) },
            target: selection.flatMap { hostTarget(for: $0) })
    }

    /// The `.cockpit` occupant's rest-state shape for the selected crew —
    /// what `columnBody(for: .cockpit)` draws and what `rightColumnPicker`'s
    /// first segment labels itself after. See `RestStateResolution` for the
    /// full reasoning; this is the one place the running view asks it.
    private var restStateShape: RestStateResolution.Shape {
        RestStateResolution.shape(for: selection.flatMap { owningCrew(for: $0) })
    }

    /// The place line the rest-state band names the selected crew's project
    /// with, or nil when the crew has none. A steward or service crew with no
    /// project draws no place line rather than an empty one.
    private var restStatePlaceLine: String? {
        guard let project = selection.flatMap({ owningCrew(for: $0) })?.project,
              !project.isEmpty else { return nil }
        return project
    }

    /// The palette of the crew a Slate sheet was opened for, found by its
    /// session name and host. A sheet can outlive its row, so when no row
    /// matches, the hashed default for the name stands in.
    private func slatePalette(session: String, target: SSHTarget) -> TerminalPalette {
        let rows = crews.map { ($0.ref, hostTarget(for: $0.ref)) }
        let theme = ContentView.slateRef(session: session, target: target, rows: rows)
            .map(themeForSession) ?? ThemeCatalog.defaultTheme(forSession: session)
        return theme.palette(for: appearance(for: .slate))
    }

    /// The row a Slate occupant names: the one whose session name matches and
    /// whose resolved host is the occupant's target. Matching on the host as
    /// well as the name keeps two crews called `steward` on two hosts apart.
    nonisolated static func slateRef(session: String, target: SSHTarget,
                                     rows: [(ref: SessionRef, target: SSHTarget?)]) -> SessionRef? {
        rows.first { $0.ref.name == session && $0.target == target }?.ref
    }

    /// `rightColumnPicker`'s first-segment label — "Cockpit" for a
    /// project-shaped crew, "Board" for the steward, "Crew" for a service
    /// crew. One function reused by both the docked and sheet-breakpoint
    /// pickers, since both draw through `rightColumnPicker` itself.
    private var restStateLabel: String {
        switch restStateShape {
        case .course: return "Cockpit"
        case .board: return "Board"
        case .service: return "Crew"
        }
    }

    /// Why the steward's board or a `ServiceCrewPanel` has nothing to draw — the
    /// session-level answer (`CockpitResolution.restStateUnresolvedReason`)
    /// that never asks for a Library project, unlike `cockpitUnresolvedReason`
    /// above. This is the fix for the bug the steward-board proposal names:
    /// a `.board`/`.service` crew must never be told to set a project that
    /// would not help.
    private var restStateSessionUnresolvedReason: String? {
        CockpitResolution.restStateUnresolvedReason(
            hasSelection: selection != nil,
            crew: selection.flatMap { owningCrew(for: $0) },
            target: selection.flatMap { hostTarget(for: $0) })
    }

    /// The Working documents panel's rows for the selected crew — see
    /// `RestStateResolution.documentPaths(for:)`.
    private var restStateDocumentPaths: [String] {
        RestStateResolution.documentPaths(for: selection.flatMap { owningCrew(for: $0) })
    }

    /// The steward's board's `CockpitView.DocumentsPanel.onOpen` — routes a Working-documents row
    /// through the SAME containment boundary a `deck-open:` URL is held to
    /// (`DeckOpenRef.validatePath`/`allowedPathRoots`) before it ever reaches
    /// `openViewer`.
    ///
    /// `RestStateResolution.documentPaths(for:)` builds this list from
    /// `crew.documents`, and a served crew's spec is a JSON file any crew
    /// running `new-crew`/`new-subcrew` can write
    /// (`~/.config/convivy/deck/crews.d/<id>.json`) — spec-controlled,
    /// attacker-reachable content, unlike `workingDirectory`
    /// (`validateWorkingDirectory`) or `bead`
    /// (`DeckOpenRef.validateKBId`), which are already gated where they're
    /// decoded. This was the one caller in the app that constructed a
    /// `.path` ref from served data without passing it through
    /// `DeckOpenRef.validatePath` first.
    ///
    /// A path that fails validation does not open — the row stays visible
    /// rather than being silently dropped from the list (a crew author who
    /// misconfigured a document, or an escaped one, gets a reason rather than
    /// a document that inexplicably never appears), and `store.saveError`
    /// surfaces why, the same channel every other open/save failure in this
    /// view already uses.
    private func openRestStateDocument(_ path: String) {
        guard let target = selection.flatMap({ hostTarget(for: $0) }) else { return }
        guard let validated = DeckOpenRef.validatePath(
            path, allowedRoots: DeckOpenRef.allowedPathRoots(hosts: configuration.hosts)
        ) else {
            store.saveError = "Could not open \((path as NSString).lastPathComponent): "
                + "this document's path falls outside the directories Deck is allowed to open."
            return
        }
        openViewer(.path(absolutePath: validated), target: target)
    }

    /// The session the Checkout panel reads, or nil when the cockpit draws no
    /// Checkout panel — only a project crew's cockpit carries one, so the
    /// board and a service crew cost no ssh round trip for it.
    private var checkoutDocumentsSessionAndTarget: (session: String, target: SSHTarget)? {
        guard let selection, restStateShape == .course, cockpitUnresolvedReason == nil,
              let target = hostTarget(for: selection) else { return nil }
        return (selection.name, target)
    }

    /// `checkoutDocumentsSessionAndTarget` as a `.task(id:)` key, on the same
    /// footing as `cockpitRefreshKey`.
    private var checkoutDocumentsRefreshKey: String {
        guard let pair = checkoutDocumentsSessionAndTarget else { return "" }
        return "\(pair.target.user)@\(pair.target.host)|\(pair.session)"
    }

    /// The Checkout panel's value, built here rather than inline at the
    /// `CockpitView` call site for the type-checker reason `selectedAgentRuns`
    /// gives.
    private var checkoutDocumentsPanel: CockpitView.CheckoutDocumentsPanel {
        .init(state: checkoutDocumentsModel.state, onOpen: openCheckoutDocument)
    }

    /// Opens one Checkout row. The id came from a record the session itself
    /// can write, so it passes `DeckOpenRef.validateKBId` — the gate a
    /// `deck-open:` link passes — before it reaches `openViewer`. A row that
    /// fails stays listed and says why through `store.saveError`, as
    /// `openRestStateDocument` does for a path.
    private func openCheckoutDocument(_ id: String) {
        guard let target = selection.flatMap({ hostTarget(for: $0) }) else { return }
        guard let validated = DeckOpenRef.validateKBId(id) else {
            store.saveError = "Could not open \(id): it is not a valid knowledge document id."
            return
        }
        openViewer(.kb(id: validated), target: target)
    }

    private func reloadCheckoutDocuments() {
        Task { await checkoutDocumentsModel.reload() }
    }

    /// The run pane's `.task(id:)` key: the run, the crew's host, and whether
    /// the register still lists the run. A run that leaves the list changes
    /// the key, so its documents are read once more as it ends.
    private func runGivenDocumentsKey(_ runId: String) -> String {
        guard let target = selection.flatMap({ hostTarget(for: $0) }) else { return "" }
        let listed = selectedAgentRuns?.contains { $0.runId == runId } == true
        return "\(target.user)@\(target.host)|\(runId)|\(listed)"
    }

    private func refreshRunGivenDocuments(_ runId: String) async {
        guard let target = selection.flatMap({ hostTarget(for: $0) }) else { return }
        await runGivenDocumentsModel.refresh(target: target, runId: runId)
    }

    /// The run pane's fetched-list `.task(id:)` key. While the run is listed,
    /// the rail poll's generation is part of it, so the list is read on every
    /// poll and grows as the run reads. Once the run leaves the list the key
    /// stops changing, so the list is read once more and then stays put.
    private func runFetchedDocumentsKey(_ runId: String) -> String {
        guard let target = selection.flatMap({ hostTarget(for: $0) }) else { return "" }
        let listed = selectedAgentRuns?.contains { $0.runId == runId } == true
        let poll = listed ? railState.generation : -1
        return "\(target.user)@\(target.host)|\(runId)|\(listed)|\(poll)"
    }

    private func refreshRunFetchedDocuments(_ runId: String) async {
        guard let target = selection.flatMap({ hostTarget(for: $0) }) else { return }
        await runFetchedDocumentsModel.refresh(target: target, runId: runId)
    }

    /// The Pull Requests panel's value, on `checkoutDocumentsPanel`'s own
    /// footing — built here rather than inline at the `CockpitView` call
    /// site for the same type-checker reason. One `RepoReading` per repo
    /// the crew resolves to (`CockpitResolution.prLadderRepos`, capped and
    /// deduplicated), each read straight off `prLadderModel`'s own per-repo
    /// cache (`cachedReading`) — the same cache `prLadderModel.refresh`
    /// above is keeping current, so this never issues a fetch of its own.
    private var pullRequestsPanel: CockpitView.PullRequestsPanel {
        let target = cockpitProjectAndTarget?.target
        let resolved = CockpitResolution.prLadderRepos(for: selection.flatMap { owningCrew(for: $0) })
        let readings = resolved.repos.map { repo -> CockpitView.PullRequestsPanel.RepoReading in
            let cached = target.flatMap {
                prLadderModel.cachedReading(target: $0, owner: repo.owner, repoName: repo.repoName)
            }
            return .init(owner: repo.owner, repoName: repo.repoName, result: cached?.result,
                         fetchError: cached?.fetchError, isLoading: cached?.isLoading ?? false,
                         fetchedAt: cached?.fetchedAt)
        }
        return .init(readings: readings, droppedByCap: resolved.droppedByCap)
    }

    private func reloadPullRequests() {
        Task { await prLadderModel.reload() }
    }

    /// The repo `sessionReviewChipLadder` should fetch for the selected
    /// session's PR chip — nil when there is no selection, no PR, a url that
    /// does not parse as a GitHub pull-request link, or (the reuse case)
    /// `prLadderModel` already covers this PR's repo, in which case the chip
    /// reads `prLadderModel.result` directly (see
    /// `SessionPaneView.prChipPresentation` and `terminalStatusBar`) rather
    /// than this model fetching the same repo a second time.
    private var sessionReviewChipFetchTarget: (target: SSHTarget, owner: String, repoName: String)? {
        guard let selection, let target = hostTarget(for: selection),
              let pr = railState.states[selection]?.vitals?.pr,
              let reference = SessionReviewChip.parsePullRequestURL(pr.url) else { return nil }
        if prLadderModel.coveredReadings.contains(where: {
            $0.owner == reference.owner && $0.repoName == reference.repoName
        }) {
            return nil
        }
        return (target, reference.owner, reference.repoName)
    }

    /// `sessionReviewChipFetchTarget` as a `.task(id:)` key, on
    /// `cockpitRefreshKey`'s own footing.
    private var sessionReviewChipRefreshKey: String {
        guard let resolved = sessionReviewChipFetchTarget else { return "" }
        return "\(resolved.target.user)@\(resolved.target.host)|\(resolved.owner)/\(resolved.repoName)"
    }

    /// Records the current detail of every listed run, and drops every other
    /// entry except the open pane's run, so the cache holds only what can
    /// still be shown rather than every run of the app's lifetime.
    private func rememberListedRunDetails(_ runs: [SessionState.AgentRun]?, keeping openRunId: String) {
        lastListedRunDetails = RunDetail.remembering(runs, previous: lastListedRunDetails, keeping: openRunId)
    }

    /// The selected crew's dispatched runs for the crew-stats panel — straight
    /// off `railState.states`, the same read `PaneStatusBar`/`WaypointRibbon`
    /// already take `workingOn` from, so this panel costs no poller of its
    /// own. Pulled out to its own computed property, alongside
    /// `cockpitUnresolvedReason`, rather than inlined at the `CockpitView`
    /// call site: folded into `body`'s already enormous expression tree, the
    /// same closure made the type checker time out on an unrelated `.alert`
    /// elsewhere in this view — a single-identifier reference at the call
    /// site avoids adding to that tree at all.
    ///
    /// The selected session's runs, each with its `modelSource` joined in
    /// from the run register by `run_id`. Unlike the rail mark, this join is
    /// safe on a fleet-wide list, because every run here draws as its own
    /// row and names its own agent.
    private var selectedAgentRuns: [SessionState.AgentRun]? {
        selection.flatMap { railState.states[$0]?.agentRuns }
            .map { RunModelMark.withModelSources($0, register: railState.runChoices) }
    }

    /// Whether `selectedAgentRuns` lists every repo's runs rather than just
    /// the selected crew's own — the same `railState.states` entry
    /// `selectedAgentRuns` reads, and on the same footing: both are
    /// top-level `SessionState` fields, so this is never stale relative to
    /// the list it describes the scope of.
    private var selectedAgentsAreFleetWide: Bool {
        selection.flatMap { railState.states[$0]?.agentsAreFleetWide } ?? false
    }

    /// The selected crew's own hue — the same expression `SessionPaneView`'s
    /// own `accent` argument below uses, so `CockpitView` and
    /// `WaypointRibbon` draw an in-progress mark in provably the same colour
    /// as the pane and the rail do. `nil` when there is no selection.
    private func selectedAccent(for surface: AppearanceSurface) -> RGB? {
        selection.map { themeForSession($0).palette(for: appearance(for: surface)).cursor }
    }

    /// The selected session's crew, if it names a Library project — the pair
    /// `cockpitModel.refresh` needs. `nil` whenever `cockpitUnresolvedReason`
    /// is non-nil; kept as a separate computed property rather than derived
    /// from that one so neither has to parse the other's prose.
    private var cockpitProjectAndTarget: (project: String, target: SSHTarget)? {
        guard let selection else { return nil }
        return CockpitResolution.projectAndTarget(
            for: owningCrew(for: selection), target: hostTarget(for: selection))
    }

    /// A stable string identity for `cockpitProjectAndTarget`, so
    /// `.task(id:)` can key on it directly — the tuple itself is not
    /// `Equatable` for free, and this is cheaper than making it so.
    private var cockpitRefreshKey: String {
        guard let pair = cockpitProjectAndTarget else { return "" }
        return "\(pair.target.user)@\(pair.target.host)|\(pair.project)"
    }

    /// A stable string identity for `BeadProgressModel.refresh`'s three
    /// inputs, mirroring `cockpitRefreshKey` for the same `.task(id:)`
    /// reason. Empty whenever the selected crew names no bead — a project
    /// with no bead needs no key at all, since `beadProgressModel.refresh`
    /// clears its state on a nil `beadId` regardless of what this string is.
    private var beadProgressRefreshKey: String {
        guard let target = selection.flatMap({ hostTarget(for: $0) }),
              let crew = selection.flatMap({ owningCrew(for: $0) }),
              let beadId = CockpitResolution.beadId(for: crew) else { return "" }
        return "\(target.user)@\(target.host)|\(beadId)|\(crew.project ?? "")"
    }

    /// The bead-progress pane's display value for `RailView`, or nil to draw
    /// nothing — gated on the selected crew NAMING a bead, independent of
    /// whether `beadProgressModel` has finished loading it yet. A crew with
    /// no bead never shows the pane; a crew with one shows it as soon as
    /// its title/progress arrive, following `RailView.BeadProgressDisplay`'s
    /// own "each field costs itself" doc for the load-in-flight case.
    private var railBeadProgress: RailView.BeadProgressDisplay? {
        guard CockpitResolution.beadId(for: selection.flatMap { owningCrew(for: $0) }) != nil else { return nil }
        return RailView.BeadProgressDisplay(title: beadProgressModel.title, progress: beadProgressModel.progress)
    }

    /// A short label for the viewer's column header derived from the ref origin.
    private func viewerTitle(_ ref: DeckOpenRef.Origin) -> String {
        switch ref {
        case .kb(let id):   return String(id.split(separator: "/").last ?? "doc")
        case .path(let p):  return (p as NSString).lastPathComponent
        case .item(let id): return id  // not reachable — see `openViewer`'s `.item` branch
        }
    }

    /// The header bar over the right-hand viewer column: filename on the left,
    /// edit, download and close buttons on the right. Using `.buttonStyle(.bordered)` so
    /// they read as controls rather than plain text labels.
    ///
    /// EDITING IS ENTERED, NOT THE DEFAULT. A Markdown file could open straight
    /// into the editor, and the spec's pipeline reads that way. It opens
    /// read-only instead, because the two surfaces have different security
    /// postures: the viewer keeps `allowsContentJavaScript = false` and an
    /// opaque origin, where the editor runs script over a loopback HTTP origin
    /// holding the capability token. Making that the default for every Markdown
    /// link would widen the JavaScript surface on a click meant for reading.
    @ViewBuilder
    private func viewerColumnHeader(for ref: DeckOpenRef.Origin, target: SSHTarget) -> some View {
        HStack(spacing: 6) {
            Text(viewerTitle(ref))
                .frameFont(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if EditorPane.canEdit(ref) {
                Button {
                    presentColumnOccupant(.editor(ref: ref, target: target))
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Edit this file")
            }
            Button {
                saveViewerFile(ref: ref, target: target)
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Save a copy to your Mac")
            Button {
                closeColumnOccupant()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Close and return to the cockpit")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    /// Opens the item detail pane for one corrections-queue row —
    /// `CockpitView`'s row tap. `nil` when the cockpit itself cannot resolve
    /// a project/host pair (`cockpitProjectAndTarget`'s doc), which should
    /// not be reachable from a queue row that only draws once that pair
    /// resolved, but this stays a no-op rather than opening a pane with no
    /// host to reach.
    private func openItem(id: String) {
        guard let target = cockpitProjectAndTarget?.target else { return }
        presentColumnOccupant(.item(id: id, target: target))
    }

    /// A Dispatched row's click: open that run's pane, close it when it is
    /// already open, follow the selection otherwise (`togglingRun`).
    private func toggleRunPane(runId: String) {
        let next = ColumnOccupant.togglingRun(runId, from: columnOccupant)
        if next == .cockpit { closeColumnOccupant() } else { presentColumnOccupant(next) }
    }

    /// The run id whose pane is open, for the Dispatched rows' highlight.
    private var openRunId: String? {
        if case .run(let id) = columnOccupant { return id }
        return nil
    }

    /// Opens the reviews pane for one Pull Requests panel row —
    /// `CockpitView.onSelectPullRequest`. `nil` when the cockpit itself
    /// cannot resolve a project/host pair, the same no-op `openItem` takes
    /// for the identical reason: not reachable from a row that only draws
    /// once that pair resolved.
    private func openReviewRecords(_ row: PRLadder.LadderResult) {
        guard let target = cockpitProjectAndTarget?.target else { return }
        presentColumnOccupant(.reviewRecords(repo: row.repo, pr: row.number, headSha: row.headSha, target: target))
    }

    /// Fetches the working copy (or re-fetches if missing) then presents a save
    /// panel so the file can be written to a chosen location on this machine.
    /// Errors surface through `store.saveError`.
    private func saveViewerFile(ref: DeckOpenRef.Origin, target: SSHTarget) {
        Task {
            let localURL: URL
            do {
                localURL = try await Task.detached {
                    try ContentView.fetchNonItemRef(ref, target: target)
                }.value
            } catch {
                store.saveError = "Could not fetch file for saving: \(error)"
                return
            }

            let panel = NSSavePanel()
            panel.nameFieldStringValue = DeckOpenRef.suggestedFilename(for: ref)
            panel.directoryURL = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let destination = panel.url else { return }

            // `saveCopy` stages and swaps rather than overwriting in place; its
            // docstring says why that matters.
            do {
                try DeckOpenRef.saveCopy(of: localURL, to: destination)
            } catch {
                store.saveError = "Could not save file: \(error)"
            }
        }
    }

    /// What a click on an item id does: point the cockpit at it when the
    /// cockpit can, and open the item pane when it cannot, so a click always
    /// lands somewhere visible. `CockpitModel.reveal` decides which and says
    /// why it may decline (another project, no parent, an epic that is not a
    /// Course entry); none of those is an error.
    ///
    /// Presenting `.cockpit` rather than doing nothing on success is what
    /// brings the cockpit back when the column is showing another occupant, or
    /// summons the sheet in the narrow layout where the cockpit is not docked.
    private func revealOrOpenItem(id: String, target: SSHTarget) async {
        switch await cockpitModel.reveal(itemID: id) {
        case .revealed:
            presentColumnOccupant(.cockpit)
        case .notInCockpit:
            presentColumnOccupant(.item(id: id, target: target))
        }
    }

    /// Opens a validated `deck-open:` origin via the correct route.
    ///
    /// - Item: reveals the item in the cockpit when it sits under one of the
    ///   current project's epics, and otherwise opens the item detail pane, the
    ///   same one a corrections-queue row tap opens (`openItem`) — see
    ///   `revealOrOpenItem`. Checked FIRST, and returning, because an item is
    ///   not a file and none of `FileViewerRouter`'s routing applies to it.
    /// - Pane: Markdown, source, and images render in the right-hand column.
    /// - Browser: PDFs and HTML are fetched to the working copy, then opened
    ///   in the default browser at the loopback URL carrying the capability token.
    /// - Hand-off: everything else is fetched to the working copy and opened in
    ///   the owning desktop application via NSWorkspace.
    ///
    /// This is the one place an arbitrary validated `Origin` is routed — a
    /// link inside a viewed or edited document (`onOpenRef`) and a link
    /// inside the conversation pane (`onDeckOpen`) both funnel through here,
    /// so an item link clicked from either place opens the item pane rather
    /// than being mistaken for a file.
    private func openViewer(_ ref: DeckOpenRef.Origin, target: SSHTarget) {
        if case .item(let id) = ref {
            Task { await revealOrOpenItem(id: id, target: target) }
            return
        }
        switch FileViewerRouter.route(for: ref) {
        case .pane:
            presentColumnOccupant(.viewer(ref: ref, target: target))
        case .browser:
            Task { await openInBrowser(ref, target: target) }
        case .handOff:
            Task { await openOnDesktop(ref, target: target) }
        }
    }

    /// What the "Open Runbook" action on a logged-out alert should do
    /// (CQ·124), as a pure function of the host name, the stored (untrusted)
    /// link text, and the live host table — `nonisolated static`, with no
    /// `private`, the same testability convention `fetchNonItemRef` below
    /// follows, so this decision is pinned without a window or a live alert.
    ///
    /// `rawLink` is RE-VALIDATED here with `RunbookLink.parse` rather than
    /// trusted because the alert parsed it when it was raised. The operator
    /// can edit the runbook in Settings after the alert appears, so the
    /// stored text may differ at click time. This is the same "the gate
    /// that makes it true regardless of who built it" discipline
    /// `DeckOpenRef` applies to a `HostEntry`'s own fields.
    enum RunbookOpenAction: Equatable {
        case openKB(id: String, target: SSHTarget)
        case openURL(URL)
        case selectHostInSettings(String)
    }

    nonisolated static func runbookOpenAction(
        hostName: String, rawLink: String?, hosts: [HostEntry]
    ) -> RunbookOpenAction {
        guard let rawLink, let link = RunbookLink.parse(rawLink) else {
            return .selectHostInSettings(hostName)
        }
        switch link {
        case .kb(let id):
            guard let entry = hosts.first(where: { $0.name == hostName }) else {
                return .selectHostInSettings(hostName)
            }
            return .openKB(id: id, target: SSHTarget(user: entry.user, host: entry.address))
        case .url(let url):
            return .openURL(url)
        }
    }

    /// Runs `runbookOpenAction`'s decision — opens via `NSWorkspace` only
    /// for an `https` URL, the cockpit's own side pane for a KB id, and
    /// Settings' own row for neither — never anything else.
    private func openRunbookLink(hostName: String, rawLink: String?) {
        NSApp.activate(ignoringOtherApps: true)
        switch ContentView.runbookOpenAction(hostName: hostName, rawLink: rawLink, hosts: configuration.hosts) {
        case .openKB(let id, let target):
            openViewer(.kb(id: id), target: target)
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .selectHostInSettings(let name):
            navigation.openHostsSettings(selecting: name)
        }
    }

    /// The `.kb`/`.path` fetch shared by `saveViewerFile`, `openInBrowser` and
    /// `openOnDesktop` — every caller of `openViewer` that reaches a real
    /// working-copy fetch, once `.item` has already been routed away by
    /// `openViewer` itself.
    ///
    /// `.item` cannot reach here through the app (`openViewer` returns before
    /// any of these three run), so it throws rather than fetching anything —
    /// there is no file to fetch a Library item as, and doing that silently
    /// would hand the reader a working copy for a ref that never named one.
    nonisolated static func fetchNonItemRef(_ ref: DeckOpenRef.Origin, target: SSHTarget) throws -> URL {
        switch ref {
        case .kb(let id):   return try WorkingCopyStore.fetch(target: target, kbId: id)
        case .path(let p):  return try WorkingCopyStore.fetch(target: target, absolutePath: p)
        case .item(let id):
            throw WorkingCopyStore.FetchError.unexpectedResponse(
                "item ref reached a file fetch (id: \(id)) — this should open the item pane instead")
        }
    }

    /// Fetches `ref` to the working copy, then opens the loopback URL in the
    /// default browser. Errors are surfaced through the existing `saveError` channel.
    private func openInBrowser(_ ref: DeckOpenRef.Origin, target: SSHTarget) async {
        do {
            let localURL: URL = try await Task.detached {
                try ContentView.fetchNonItemRef(ref, target: target)
            }.value
            guard let url = server.url(for: localURL) else {
                store.saveError = "Loopback server is not running — cannot open in browser."
                return
            }
            NSWorkspace.shared.open(url)
        } catch {
            store.saveError = "Could not open file in browser: \(error)"
        }
    }

    /// Fetches `ref` to the working copy, then opens it in the owning desktop
    /// application. Errors are surfaced through the existing `saveError` channel.
    private func openOnDesktop(_ ref: DeckOpenRef.Origin, target: SSHTarget) async {
        do {
            let localURL: URL = try await Task.detached {
                try ContentView.fetchNonItemRef(ref, target: target)
            }.value
            FileViewerRouter.handOff(localURL: localURL)
        } catch {
            store.saveError = "Could not open file: \(error)"
        }
    }

    /// The scratch shell for the selected session, in that session's cwd.
    ///
    /// Its own tmux session on the mini, so the pane is disposable and the shell
    /// is not. `.id` follows the SELECTION rather than the directory: keying it
    /// on the cwd meant that switching sessions changed the id, SwiftUI tore the
    /// pane down, and teardown killed the ssh process along with whatever was
    /// running in it — the operator's "change co sessions, it kills the shell session".
    /// Now the pane swaps and the shell underneath keeps going.
    ///
    /// Nothing renders when no session is selected, or the selected
    /// session's host does not resolve to anything: a scratch shell belongs
    /// to a session on a real machine, and there is no sensible one to
    /// attach to without either.
    @ViewBuilder
    private var shellPane: some View {
        if let selection, let target = hostTarget(for: selection) {
            TerminalPaneView(
                target: .remoteShell(session: selection.name,
                                     workingDirectory: sessionCwd[selection],
                                     target: target),
                theme: themeForSession(selection),
                appearance: appearance(for: .terminal),
                typography: configuration.typography
            ) { _ in }
                .id("shell:\(selection.stringForm)")
        } else {
            Spacer(minLength: 0)
        }
    }

    /// The Shell tab's band. The shell runs on the selected session's host, so
    /// the band takes that session's identity, the same colour its pane wears.
    /// With no selection the band is neutral and says so.
    private var shellBand: some View {
        Group {
            // The shell pane beneath this band draws in the terminal surface's
            // appearance, so the band resolves the same one.
            let bandAppearance = appearance(for: .terminal)
            if let selection {
                let palette = themeForSession(selection).palette(for: bandAppearance)
                ColumnBand(
                    title: "Shell", icon: "terminal.fill",
                    place: hostTarget(for: selection).map { "\($0.user)@\($0.host)" },
                    colours: .identity(canvas: ContentView.paneCanvas(for: palette, appearance: bandAppearance),
                                       accent: palette.cursor, bandAppearance)
                ) { columnCloseButton }
            } else {
                ColumnBand(
                    title: "Shell", icon: "terminal.fill", place: "no session selected",
                    colours: .neutral(bandAppearance)
                ) { columnCloseButton }
            }
        }
    }

    /// The Local tab's band: the laptop's own identity, graphite, so it reads
    /// as this machine rather than as one of the crews. It sits over the Local
    /// terminal, so it draws in the terminal surface's appearance.
    private var localBand: some View {
        let bandAppearance = appearance(for: .terminal)
        let palette = configuration.theme(forSession: .localShell).palette(for: bandAppearance)
        return ColumnBand(
            title: "Local", icon: "laptopcomputer", place: "this Mac",
            colours: .identity(canvas: ContentView.paneCanvas(for: palette, appearance: bandAppearance),
                               accent: palette.cursor, bandAppearance)
        ) { columnCloseButton }
    }

    /// A terminal on this machine, beside the conversation. `.localShell`, the
    /// same target the rail's Local Terminal row uses, so the split and the
    /// full-pane form are one shell configured one way. Its `.id` is fixed —
    /// unlike the scratch shell, it does not follow the selected session's cwd,
    /// because a laptop terminal is not about where the agent is working — so it
    /// survives a selection change rather than respawning on one.
    private var localTerminalPane: some View {
        TerminalPaneView(
            target: .localShell,
            theme: configuration.theme(forSession: .localShell),
            appearance: appearance(for: .terminal),
            typography: configuration.typography,
            // Resolved fresh at connect time, not here — this closure runs on
            // whatever render happened to build the view, but its BODY only
            // executes inside the Coordinator at the moment it is about to
            // spawn, which is the "on demand" this was built to.
            localStartingDirectory: {
                TerminalLaunch.localStartingDirectory(
                    remembered: localShellDirectory.isEmpty ? nil : localShellDirectory)
            },
            onLocalShellDirectory: { localShellDirectory = $0 }
        ) { _ in }
            .id(SessionRef.localShell.name)
    }

    /// Reads the selected session's cwd from the mini and stores it, so the
    /// shell pane opens where the agent is working. Off the main actor — one
    /// ssh round trip must not stall the toggle.
    private func resolveShellCwd() {
        guard let session = selection,
              (try? validateTmuxSessionName(session.name)) != nil,
              let target = hostTarget(for: session) else { return }
        Task {
            let cwd: String? = await Task.detached {
                (try? SessionAgent.state(target: target, session: session.name))?.cwd
            }.value
            if let cwd { sessionCwd[session] = cwd }
        }
    }

    /// The conversation's own floor, so dragging the divider cannot squeeze
    /// it away either. The right column's matching floor lives on
    /// `ThemeConfiguration.minimumColumnWidth`, since that is also what gets
    /// written to disk and needs a NaN-safe fallback; this one has no such
    /// need; it exists only for `clampedColumnWidth`'s arithmetic.
    static let mainPaneMinWidth: Double = 400

    /// The right column's width for a `totalWidth`-wide row, clamped so
    /// neither side of the divider can be dragged to nothing. Pure
    /// arithmetic, tested directly at both minimums and past them.
    nonisolated static func clampedColumnWidth(_ proposed: Double, totalWidth: Double) -> Double {
        let maxWidth = max(ThemeConfiguration.minimumColumnWidth,
                           totalWidth - ContentView.mainPaneMinWidth)
        return min(max(proposed, ThemeConfiguration.minimumColumnWidth), maxWidth)
    }

    /// The right column's current width, resolved against the row's actual
    /// size. Reads `configuration.columnWidth` when no drag is in flight — the
    /// same choice every other view preference here makes, so a menu-bar
    /// shortcut or a Settings change is never a stale pane away — and the
    /// drag's own local width while one is.
    private func columnWidth(totalWidth: CGFloat) -> CGFloat {
        CGFloat(ContentView.effectiveColumnWidth(dragging: draggingColumnWidth,
                                                 stored: configuration.columnWidth,
                                                 totalWidth: Double(totalWidth)))
    }

    /// Which width the column is drawn at: the drag's, while one is in flight,
    /// and the stored one otherwise. Clamped either way, so a drag cannot show
    /// a width the stored value would not be allowed to hold.
    ///
    /// A free function so the choice is testable without a view. The bug this
    /// state exists to fix was invisible to a suite that could only reach
    /// `clampedColumnWidth`'s arithmetic.
    nonisolated static func effectiveColumnWidth(dragging: Double?, stored: Double,
                                                 totalWidth: Double) -> Double {
        clampedColumnWidth(dragging ?? stored, totalWidth: totalWidth)
    }

    /// The Main pane picker's box width in `paneChrome`'s two-box split above
    /// `LayoutBreakpoints.columnSheet` — the row's own width minus whatever
    /// the column currently claims, so the picker's trailing edge lands on
    /// the divider by construction. Reuses `effectiveColumnWidth` rather than
    /// re-deriving the column's width a second way, so the two can never
    /// disagree about where the divider sits. Pure arithmetic, tested
    /// directly the way `clampedColumnWidth` is — see `PaneChromeWidthTests`.
    nonisolated static func mainPaneChromeWidth(chromeRowWidth: Double, dragging: Double?,
                                                stored: Double) -> Double {
        max(0, chromeRowWidth - effectiveColumnWidth(dragging: dragging, stored: stored,
                                                      totalWidth: chromeRowWidth))
    }

    /// The width a divider drag is currently showing, or nil when none is in
    /// flight.
    ///
    /// A DRAG MUST NOT TOUCH THE STORE ON EVERY TICK. `ThemeStore.configuration`
    /// is `@Published`, so writing it re-evaluates all of `ContentView` — the
    /// rail, the chrome, and every terminal and web pane it builds — and a
    /// drag does that once per mouse-move. The operator reported the result as
    /// "herky-jerky" redrawing, which is the app re-rendering per pixel of
    /// travel.
    ///
    /// Local state keeps the drag's cost to this view's own body. The store
    /// still sees exactly one write, at the end of the gesture, which is what
    /// `commitPreviewedTypography` was always for.
    @State private var draggingColumnWidth: Double?

    /// `CockpitView`, sized to the right-hand column. Pulled out of `body`'s
    /// own `HStack` — which was already a large `@ViewBuilder` expression
    /// spanning several hundred lines and multiple column occupants — because
    /// adding `CockpitView`'s fourth initializer argument (`agentRuns`)
    /// directly inside that tree pushed an UNRELATED expression elsewhere in
    /// `body` (an `.onChange(of: selection)` closure) over the type
    /// checker's "reasonable time" ceiling. Moving the call out to its own
    /// function, with its own much smaller expression to solve, is what
    /// closed that — the checker was never confused about this call's own
    /// types, only overloaded by the size of the tree it sat inside.
    private func cockpitColumn(totalWidth: CGFloat) -> some View {
        columnBody(for: .cockpit)
            .frame(width: columnWidth(totalWidth: totalWidth))
    }

    /// The right column's content for a given occupant, with no width frame
    /// of its own — the caller applies one, since the DOCKED column's width
    /// (`columnWidth(totalWidth:)`) and the SHEET's fixed width
    /// (`ContentView.sheetWidth`) are different numbers for the same
    /// content. One switch rather than two: `04-narrow.html`'s sheet "must
    /// host every `ColumnOccupant`," and building the docked and sheet
    /// cases from two separate copies of this switch is exactly how they
    /// would drift.
    @ViewBuilder
    private func columnBody(for occupant: ColumnOccupant) -> some View {
        switch occupant {
        case .cockpit:
            // ONE OCCUPANT, THREE SHAPES — see `RestStateResolution` and the
            // steward-board proposal it implements: the resolution happens
            // HERE, inside the single `.cockpit` case, rather than as a new
            // `ColumnOccupant` case, so closing/reopening the column and the
            // narrow-layout sheet keep treating the rest state as one thing
            // whatever it currently draws.
            switch restStateShape {
            case .course:
                CockpitView(model: cockpitModel, unresolvedReason: cockpitUnresolvedReason,
                           agentRuns: selectedAgentRuns, agentsAreFleetWide: selectedAgentsAreFleetWide,
                           appearance: appearance(for: .cockpit), accent: selectedAccent(for: .cockpit),
                           onSelectCorrection: openItem,
                           onSelectRun: toggleRunPane, openRunId: openRunId,
                           placeLine: restStatePlaceLine,
                           checkoutDocuments: checkoutDocumentsPanel, pullRequests: pullRequestsPanel,
                           pullRequestsUnresolvedReason: pullRequestsUnresolvedReason,
                           onSelectPullRequest: openReviewRecords,
                           onRefresh: {
                               reloadCheckoutDocuments()
                               reloadPullRequests()
                           })
            case .board:
                // The board IS the cockpit, drawing `boardPanelIDs`, so its
                // Course and Proposals are fetched and drawn exactly as a
                // project crew's are. The session-level reason blanks the
                // whole board; the project reason blanks only its Course and
                // Proposals panels, so a steward with no project set still
                // sees its fleet and documents.
                CockpitView(model: cockpitModel, unresolvedReason: restStateSessionUnresolvedReason,
                           agentRuns: selectedAgentRuns, agentsAreFleetWide: selectedAgentsAreFleetWide,
                           appearance: appearance(for: .cockpit), accent: selectedAccent(for: .cockpit),
                           onSelectCorrection: openItem,
                           onSelectRun: toggleRunPane, openRunId: openRunId,
                           title: "Board", placeLine: restStatePlaceLine,
                           panelIDs: CockpitView.boardPanelIDs,
                           courseUnresolvedReason: cockpitUnresolvedReason,
                           proposalsUnresolvedReason: cockpitUnresolvedReason,
                           documents: .init(paths: restStateDocumentPaths, onOpen: openRestStateDocument),
                           onSelectPullRequest: openReviewRecords)
            case .service:
                ServiceCrewPanel(
                    unresolvedReason: restStateSessionUnresolvedReason,
                    agentRuns: selectedAgentRuns, appearance: appearance(for: .cockpit),
                    accent: selectedAccent(for: .cockpit),
                    onSelectRun: toggleRunPane, openRunId: openRunId)
            }
        case .remoteShell:
            VStack(spacing: 0) {
                shellBand
                shellPane
            }
        case .localTerminal:
            VStack(spacing: 0) {
                localBand
                localTerminalPane
            }
        case .viewer(let ref, let target):
            VStack(spacing: 0) {
                viewerColumnHeader(for: ref, target: target)
                Divider()
                FileViewerPane(ref: ref, appearance: appearance(for: .document), target: target)
            }
        case .editor(let ref, let target):
            EditorPane(
                ref: ref,
                appearance: appearance(for: .document),
                server: server,
                target: target,
                hosts: configuration.hosts,
                onDone: { presentColumnOccupant(.viewer(ref: ref, target: target)) },
                onClose: closeColumnOccupant,
                onOpenRef: { r in openViewer(r, target: target) })
        case .item(let id, let target):
            ItemDetailPane(
                id: id, target: target, appearance: appearance(for: .document),
                onClose: closeColumnOccupant,
                onOpenItem: { newId in presentColumnOccupant(.item(id: newId, target: target)) })
        case .run(let runId):
            RunDetailPane(
                detail: RunDetail.make(runId: runId, runs: selectedAgentRuns,
                                       last: lastListedRunDetails[runId]),
                given: runGivenDocumentsModel.state,
                fetched: runFetchedDocumentsModel.state,
                onOpenDocument: openCheckoutDocument,
                onClose: closeColumnOccupant)
                // Remember each listed run's detail, so the pane still has
                // it after the run leaves the list (see `RunDetail.make`).
                .onChange(of: selectedAgentRuns, initial: true) { _, runs in
                    rememberListedRunDetails(runs, keeping: runId)
                }
                .task(id: runGivenDocumentsKey(runId)) {
                    await refreshRunGivenDocuments(runId)
                }
                .task(id: runFetchedDocumentsKey(runId)) {
                    await refreshRunFetchedDocuments(runId)
                }
        case .reviewRecords(let repo, let pr, let headSha, let target):
            ReviewRecordsPane(
                repo: repo, pr: pr, headSha: headSha, target: target,
                appearance: appearance(for: .document), onClose: closeColumnOccupant)
        case .slate(let session, let target, _):
            // The sheet's identity is the session it was opened for, not the
            // selection, so a Slate open for another crew keeps that crew's colour.
            let palette = slatePalette(session: session, target: target)
            let slateAppearance = appearance(for: .slate)
            let canvas = ContentView.paneCanvas(for: palette, appearance: slateAppearance)
            SlatePane(session: session, target: target, onClose: closeColumnOccupant,
                      canvas: canvas,
                      bandColours: .identity(canvas: canvas, accent: palette.cursor, slateAppearance),
                      place: "\(session) on \(target.host)",
                      sends: slateSends,
                      probedName: { railState.probedMachineName(for: $0) })
        }
    }

    /// The draggable handle between `mainPane` and whichever pane occupies
    /// the right-hand column. One shared instance rather than one per
    /// occupant, since `ColumnOccupant` guarantees only one is ever mounted.
    private func columnDivider(totalWidth: CGFloat) -> some View {
        ResizableDivider(
            width: Binding(
                // Clamped, not the raw stored width — a config saved at a
                // wider window, or hand-edited out of range, must hand the
                // drag gesture the same baseline the divider is actually
                // drawn at, or the first pixel of a drag computes its delta
                // from a value the screen never showed.
                get: { Double(columnWidth(totalWidth: totalWidth)) },
                set: { newValue in
                    // Into local state, not the store. See `draggingColumnWidth`.
                    draggingColumnWidth =
                        ContentView.clampedColumnWidth(newValue, totalWidth: Double(totalWidth))
                }),
            onCommit: {
                // One store write per gesture. Cleared after, so the column
                // goes back to reading the stored value and a later change
                // from Settings or a shortcut is not masked by a finished
                // drag's leftover.
                if let dragged = draggingColumnWidth {
                    store.previewConfiguration { $0.columnWidth = dragged }
                    store.commitPreviewedTypography()
                }
                draggingColumnWidth = nil
            })
        // The strip is outside both panes, so it takes the pinned ground itself.
        // Under Builder Default this is `nil` and the divider draws as before.
        .surfaceAppearance(configuration.pinnedDividerSurface)
        // The window's background is the Builder green now, for the title bar.
        // Left unpainted, the gap between the session pane and the column would
        // take that green. Before #331 it showed the system window colour, so
        // this paints that colour back.
        .background {
            if isBuilderDefault { Color(nsColor: .windowBackgroundColor) }
        }
    }

    /// The bar Terminal View draws instead of a conversation — the same
    /// `PaneStatusBar` `SessionPaneView.statusBar` builds, but from
    /// `railState.states` (the rail's own brief poll) rather than a
    /// `SessionPaneModel`, since this branch of `mainPane` has no model
    /// instance to read. `WaypointRibbon` in the session-pane branch already
    /// reads the identical `railState.states[selection]?.workingOn` for its
    /// pulse, so this is a second consumer of a poll already happening, not
    /// a new one.
    ///
    /// `renderError` is always nil: rendering the conversation document is a
    /// `SessionPaneModel` concern, and there is no document here that can
    /// fail to render. `onRefresh` asks the rail to poll again — the nearest
    /// analogue to `SessionPaneModel.refresh()`'s re-render available here,
    /// since there is no rendered document to redraw. `onStop` matches the
    /// session-pane branch's own wiring (`:2650`) exactly, so Stop reaches
    /// the same confirmation dialog from either surface.
    private func terminalStatusBar(for selection: SessionRef) -> some View {
        let state = railState.states[selection]
        // The same fallback-to-window-background `SessionPaneView.inkSurface`
        // uses when there is no canvas to derive from, reused here via the
        // shared static rather than re-picked, so an error or warning ink
        // solved over a terminal reads as the identical colour it would over
        // the conversation.
        let terminalAppearance = appearance(for: .terminal)
        let ink = SessionPaneView.frameTintRGB(canvas: paneCanvas(for: selection, on: .terminal),
                                               appearance: terminalAppearance)
            ?? (terminalAppearance == .dark ? RGB(red: 0.12, green: 0.12, blue: 0.13)
                                    : RGB(red: 0.98, green: 0.98, blue: 0.98))
        // The same `SessionReviewChip.presentation` reuse-vs-fallback choice
        // `SessionPaneView.prChipPresentation` makes, driven by the rail's
        // own vitals rather than a `SessionPaneModel` — this branch has none.
        let prChip: PRLadderRow.Presentation? = state?.vitals?.pr.flatMap {
            SessionReviewChip.presentation(
                for: $0, sharedReadings: prLadderModel.coveredReadings,
                fallbackResult: sessionReviewChipLadder.result)
        }
        return PaneStatusBar(
            mark: state?.mark ?? .unpolled,
            displayName: displayName(for: selection),
            dotAccent: themeForSession(selection).palette(for: appearance(for: .terminal)).cursor,
            dotSurface: ink,
            workingOn: state?.workingOn,
            vitals: state?.vitals,
            agentsAreFleetWide: state?.agentsAreFleetWide ?? false,
            isLaunching: launching.contains(selection),
            phase: state?.phase ?? .unknown,
            renderError: nil,
            reason: state?.reason,
            alive: state?.alive ?? false,
            warningInk: Color(ThemeRecipe.warningInk(on: ink)),
            errorInk: Color(ThemeRecipe.errorInk(on: ink)),
            attentionInk: Color(ThemeRecipe.attentionTextInk(on: ink)),
            prChip: prChip,
            onRefresh: { Task { await railState.refresh() } },
            onStop: { sessionToStop = selection })
        .background(SessionPaneView.frameTintRGB(canvas: paneCanvas(for: selection, on: .terminal),
                                                 appearance: terminalAppearance)
            .map(Color.init) ?? Color.clear)
    }

    @ViewBuilder
    private var mainPane: some View {
        ZStack {
            if let selection, hasSessionPane(selection), hostTarget(for: selection) == nil {
                // No host, no action: Start, the conversation pane, and the
                // raw terminal all need a real `SSHTarget` to reach the mini
                // over, and there is none to invent — see
                // `deck/specs/running-deck-as-someone-else`. The row itself
                // already carries the same message via `hostWarning`'s
                // tooltip and context-menu line; this is the pane-side echo
                // of it, since selecting the row is the other place an
                // operator learns why nothing is happening.
                UnresolvedHostView(name: displayName(for: selection))
                    .surfaceAppearance(configuration.pinnedSurface(for: .start))
            } else if let selection, hasSessionPane(selection), !showingTerminal.contains(selection),
               surface(for: selection) == .start, !launching.contains(selection) {
                // A stopped session has no conversation to render. Rather than the
                // pane's "cannot reach", offer to start it — which runs `co`, not
                // the bare shell attaching would leave. The rail's poll is what
                // says stopped, so this appears within a poll of a session ending
                // and clears within one of it starting. Only reachable when
                // `surface(for:)` says `.start` — a discovered session gets no
                // Start offer, since Deck has no directory or command for one.
                // Drawn on the session pane's canvas and the conversation
                // surface's pin, so a stopped session shares its ground with the
                // live pane it becomes. See `StartSessionView.canvas`.
                StartSessionView(name: displayName(for: selection),
                                 canvas: paneCanvasRGB(for: selection, on: .conversation),
                                 onStart: { startSelectedRow(selection) },
                                 onTerminal: { showingTerminal.insert(selection) })
                    .surfaceAppearance(configuration.pinnedSurface(for: .conversation))
            } else if let selection, hasSessionPane(selection), !showingTerminal.contains(selection),
                      surface(for: selection) == .missingDirectory {
                // A stopped row with nowhere usable configured to start in.
                // Refused rather than started at `$HOME` or left to throw —
                // see `SessionSurface.missingDirectory`.
                MissingDirectoryView(name: displayName(for: selection),
                                     folder: owningCrew(for: selection)?.workingDirectory,
                                     canvas: paneCanvasRGB(for: selection, on: .conversation),
                                     onTerminal: { showingTerminal.insert(selection) })
                    .surfaceAppearance(configuration.pinnedSurface(for: .conversation))
            } else if let selection, hasSessionPane(selection), showsStaleGate(for: selection) {
                // A crew's own row or a pinned child confirmed to have no
                // tmux session left — see `SessionSurface.stale` and
                // `showsStaleGate`. NO `!showingTerminal.contains(selection)`
                // guard, unlike the two branches above: the Terminal side of
                // the Session/Terminal picker reaches the exact same `tmux
                // new-session -A -D` through `target(for:)` below, so this
                // must preempt BOTH regardless of which the picker is on, or
                // picking "Terminal" would resurrect the session with
                // nothing said. The one way through is `staleTerminalRequests`
                // — an explicit "Open terminal" click on this same refusal,
                // never a `showingTerminal` membership left over from before
                // the row went stale.
                StartSessionView(
                    name: displayName(for: selection),
                    canvas: paneCanvasRGB(for: selection, on: .conversation),
                    onStart: { startSelectedRow(selection) },
                    onTerminal: {
                        staleTerminalRequests.insert(selection)
                        showingTerminal.insert(selection)
                    },
                    onRemovePin: isPinnedChild(selection)
                        ? { requestRemovePinnedSession(selection) } : nil)
                .surfaceAppearance(configuration.pinnedSurface(for: .conversation))
            } else if let selection, sessionPaneIsShowing(for: selection), let target = hostTarget(for: selection) {
                VStack(spacing: 0) {
                    SessionPaneView(
                        session: selection.name,
                        displayName: displayName(for: selection),
                        appearance: appearance(for: .conversation),
                        sendKey: configuration.sendKey,
                        canvas: paneCanvas(for: selection, on: .conversation),
                        // The same expression the rail passes for its dot, so the
                        // two are provably one colour rather than two resolutions
                        // that happen to agree.
                        accent: themeForSession(selection)
                            .palette(for: appearance(for: .conversation)).cursor,
                        isLaunching: launching.contains(selection),
                        textScale: paneTextScale,
                        sessionLineHeight: configuration.sessionTypography.clampedLineHeight,
                        composerTypography: configuration.composerTypography,
                        target: target,
                        draftStore: draftStore,
                        draftKey: selection,
                        onFallBackToTerminal: { showingTerminal.insert(selection) },
                        onDeckOpen: { ref in openViewer(ref, target: target) },
                        onStop: { sessionToStop = selection },
                        // The event-driven half of gate suppression — see
                        // `RailStateModel.pushedGate`'s doc for why the
                        // rail's own poll-fed reading can lag what this pane
                        // is already showing by up to four seconds.
                        onGateChange: { open in
                            railState.applyPushedGate(open, for: selection)
                        },
                        hosts: configuration.hosts,
                        // ABOVE the conversation, not below it (the operator,
                        // 2026-08-25). The window splits by WHO DRIVES a
                        // surface rather than by how wide its scope is: what
                        // is above the conversation is the co's, what is
                        // below is the operator's. This line is written by
                        // the co, so `PaneStatusBar` draws it at the top of
                        // the pane — merged into that one row rather than a
                        // strip of its own, see `PaneStatusBar`'s doc.
                        //
                        // `railState.states` is the rail's own brief poll,
                        // which already carries `working_on` — no second poll
                        // for one line of text.
                        workingOn: railState.states[selection]?.workingOn,
                        findBarState: findBarState,
                        sharedPRLadder: prLadderModel,
                        fallbackPRLadder: sessionReviewChipLadder
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The Course as a route rather than a list, same data at
                    // a different zoom (`deck/bead/deck` §1) — draws nothing
                    // when there is no Course, so a project with none loses
                    // no space to it. **It stays at the very bottom**: a route
                    // drawn along the frame's edge is what keeps the Bead in
                    // view while the reader works (the operator, 2026-08-25), so this is
                    // the last row rather than merely a low one.
                    // `workingOn` is the SAME value `PaneStatusBar` draws above
                    // the conversation, taken here only for its liveness — the
                    // ribbon never shows the text. One poll feeds both.
                    // Pinned on its own surface, not the conversation's: under
                    // Builder Default the conversation is light and the strip is
                    // a status pane, so it takes the status ground the rail and
                    // cockpit draw on.
                    // Under Builder Default `liftedCourseRibbon` draws it instead, at
                    // the foot of the whole window.
                    if !isBuilderDefault {
                        WaypointRibbon(course: cockpitModel.course,
                                       workingOn: railState.states[selection]?.workingOn,
                                       appearance: appearance(for: .strip),
                                       accent: selectedAccent(for: .strip))
                            .surfaceAppearance(configuration.pinnedSurface(for: .strip))
                    }
                }
                .surfaceAppearance(configuration.pinnedSurface(for: .conversation))
                .id("pane-\(selection.stringForm)")
                // The pane behind `onGateChange` is going away — a selection
                // change, or the surface switching to the terminal — so any
                // push it recorded must go with it rather than sit in
                // `railState` describing a pane that no longer exists. See
                // `RailStateModel.clearPushedGate`.
                .onDisappear { railState.clearPushedGate(for: selection) }
            } else if let selection, let terminalTarget = target(for: selection) {
                VStack(spacing: 0) {
                    // The status bar the conversation gets, carried over the
                    // terminal too — the crew's mark and name, the working-on
                    // sentence, context, model, billing, remote control and
                    // the stop control are all just as true here, and the
                    // terminal is where a reader most needs them. Replaces a
                    // "Terminal View" label and a "Back to Session View"
                    // button that only restated the Main pane picker two
                    // inches away (`issue_01M2715540KEV1P6Z831R6TAWA`).
                    terminalStatusBar(for: selection)
                    Divider()
                    // The same bar `SessionPaneView` draws over the
                    // conversation, driven here by `terminalSearchController`
                    // instead of a `ConversationScrollState` — see
                    // `TerminalFindBar`'s doc for why the controller is
                    // owned here rather than by `TerminalPaneView` itself.
                    if findBarState.isPresented {
                        TerminalFindBar(state: findBarState, controller: terminalSearchController)
                        Divider()
                    }
                    // `.id` forces SwiftUI to tear down and recreate the pane
                    // (and its Coordinator) on every session switch, rather than
                    // reusing one Coordinator across sessions — TerminalPaneView's
                    // updateNSView only repaints palette and typography and cannot
                    // re-target an existing pane at a different ssh process, and
                    // this is what invokes dismantleNSView to kill the outgoing
                    // session's ssh process instead of orphaning it.
                    TerminalPaneView(
                        target: terminalTarget,
                        theme: themeForSession(selection),
                        appearance: appearance(for: .terminal),
                        typography: configuration.typography,
                        onPhaseChange: { phase = $0 },
                        searchController: terminalSearchController
                    )
                        .id(selection)
                }
                .surfaceAppearance(configuration.pinnedSurface(for: .terminal))
            } else if let selection {
                // Reached only when `target(for:)` itself is nil — the same
                // "no host, nothing to invent" state as the top branch,
                // for a selection `hasSessionPane` already ruled out above.
                UnresolvedHostView(name: displayName(for: selection))
                    .surfaceAppearance(configuration.pinnedSurface(for: .start))
            } else {
                VStack {
                    Text("Select a session from the rail")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .surfaceAppearance(configuration.pinnedSurface(for: .conversation))
            }

            // Only over a terminal. `phase` is the ssh connection's, reported by
            // TerminalPaneView, and it says nothing about a session pane — which
            // has no ssh process of its own to be disconnected from. Veiling the
            // pane with it would cover a working surface with a stale verdict
            // from whichever terminal was last on screen.
            if let selection, showsTerminal(for: selection), phase != .connected {
                ReconnectingVeil(phase: phase,
                                 appearance: configuration.pinnedAppearance(for: .terminal))
            }

            // TOPMOST, so it covers whichever of the branches above got
            // picked — the whole point, since the branch itself is what was
            // flickering. See `launchPending` and `showsLaunchPlaceholder`.
            if let selection, ContentView.showsLaunchPlaceholder(
                launchPending: launchPending[selection] != nil,
                isAlive: railState.isAlive(selection),
                isStopped: railState.isStopped(selection),
                hasReadingSinceLaunch: launchPending[selection]?.decidableFrom.map {
                    ContentView.hasReadingSinceLaunch(
                        reading: railState.generation, launchedAt: $0)
                } ?? false,
                elapsedSinceLaunch: launchPending[selection].map {
                    Date().timeIntervalSince($0.startedAt)
                } ?? 0) {
                LaunchPlaceholderView(canvas: paneCanvasRGB(for: selection, on: .conversation))
                    .surfaceAppearance(configuration.pinnedSurface(for: .conversation))
            }
        }
    }
}

/// The catalog-row "Remove from Deck" confirm, pulled out of
/// `ContentView.body`'s own modifier chain — see the comment at its call
/// site for why. Otherwise identical in shape to the crew/child Remove
/// alerts it sits beside: same title format, same Cancel/destructive-Remove
/// button pair, message built from a pure function.
private struct CatalogEntryRemoveAlert: ViewModifier {
    @Binding var entryToRemove: LaunchableSession?
    let isRunning: Bool
    let onRemove: (LaunchableSession) -> Void

    func body(content: Content) -> some View {
        content.alert(
            entryToRemove.map { "Remove \($0.displayName) from Deck?" } ?? "Remove from Deck?",
            isPresented: Binding(
                get: { entryToRemove != nil },
                set: { if !$0 { entryToRemove = nil } })
        ) {
            Button("Cancel", role: .cancel) { entryToRemove = nil }
            Button("Remove", role: .destructive) {
                if let entry = entryToRemove { onRemove(entry) }
                entryToRemove = nil
            }
        } message: {
            Text(ContentView.removeCatalogEntryMessage(isRunning: isRunning))
        }
    }
}

/// A row's "Roll Over Now…" confirm, pulled out of `ContentView.body`'s
/// modifier chain for the same reason as `CatalogEntryRemoveAlert`.
private struct RolloverForceAlert: ViewModifier {
    @Binding var session: SessionRef?
    let onConfirm: (SessionRef) -> Void

    func body(content: Content) -> some View {
        content.alert(
            session.map { "Roll \($0.name) over now?" } ?? "Roll this session over now?",
            isPresented: Binding(
                get: { session != nil },
                set: { if !$0 { session = nil } })
        ) {
            Button("Cancel", role: .cancel) { session = nil }
            Button("Roll Over Now") {
                if let ref = session { onConfirm(ref) }
                session = nil
            }
        } message: {
            Text("It writes a handoff and carries on in a fresh session. If the session is mid-turn, it rolls over at its next chance; if a draft or a queued message is waiting, nothing is sent.")
        }
    }
}

/// Covers the pane region from the button press until the rail confirms the
/// session is alive. Opaque, deliberately, rather than a spinner laid over
/// the branch underneath: the branch itself is what was visibly assembling —
/// `StartSessionView`, then the pane, then `StartSessionView` again on the
/// rail's stale reading — and a translucent overlay would still let that
/// show through.
///
/// Drawn on the session pane's canvas, the same ground `StartSessionView` and
/// `MissingDirectoryView` take, so the pane does not change colour between Start
/// and the live session. It used to fill with the system text background, which
/// is black under Builder Default's dark status pin: the black frame in between.
/// The text is solved against `canvas`, not taken from `.secondary`, for the
/// reason `StartSessionView.textInk` gives.
struct LaunchPlaceholderView: View {
    /// The session pane's canvas, from `ContentView.paneCanvasRGB`.
    let canvas: RGB

    private var textInk: Color { Color(ThemeRecipe.secondaryTextInk(on: canvas)) }

    var body: some View {
        VStack {
            Text("Loading…").frameFont(.primary).foregroundStyle(textInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(canvas))
    }
}

/// The draggable handle between `mainPane` and the right-hand column.
///
/// WIDER THAN THE HAIRLINE IT DRAWS. A bare `Divider()` is a one-point-wide
/// target; the hit area here is `hitWidth`, generous enough to grab without
/// pixel-perfect aim, and the cursor swaps to the resize glyph on hover so
/// the affordance is visible before the drag even starts.
struct ResizableDivider: View {
    /// The live width, previewed on every tick of the drag; only `onCommit`
    /// touches disk. See `ContentView.columnDivider`.
    @Binding var width: Double
    var onCommit: () -> Void

    /// The width the drag started from, captured once per gesture so
    /// `DragGesture`'s CUMULATIVE `translation` is applied against a fixed
    /// baseline rather than compounding on every tick.
    @State private var dragStartWidth: Double?

    /// Tracks whether THIS view is the one showing the resize cursor, so it is
    /// only restored by the view that set it. Without it, the divider
    /// vanishing mid-hover — closing the column while the pointer is still
    /// over the handle — leaves the resize glyph on over whatever takes its
    /// place.
    @State private var isHovering = false

    /// WIDE ENOUGH TO HIT WITHOUT AIMING. At 8 this was reported as "hard to
    /// grab": the pointer has to land inside four points either side of a
    /// hairline while crossing between two panes that both want the mouse.
    /// AppKit's own split-view dividers take a comparable slop, and the cost
    /// of the extra points is nothing — the strip is transparent, and the line
    /// it draws is still one point.
    static let hitWidth: CGFloat = 14

    /// `Divider()` only draws its thin, DRAGGABLE-length axis vertically when
    /// it is the direct child of an `HStack` — SwiftUI picks its orientation
    /// from the stack it sits in, not from the frame around it. Hosted in a
    /// `ZStack` (the previous body) it drew HORIZONTALLY: one point tall,
    /// full width, centred in whatever the ZStack collapsed to. Widening
    /// `hitWidth` in 05e4395 grew the wrong axis, since `.frame(width:)`
    /// only ever constrained the horizontal one — measured with an
    /// `NSHostingView` probe: `(14.0, 1.0)` for exactly this body, both
    /// standalone and hosted in a fixed-size row. `maxHeight: .infinity`
    /// below is what makes the strip claim the row's actual height rather
    /// than the divider's own 1pt intrinsic one.
    var body: some View {
        HStack(spacing: 0) { Divider() }
            .frame(width: ResizableDivider.hitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            // `.set()` ON EVERY TICK, NOT `.push()` ONCE. A pushed cursor is
            // only the top of a stack that any AppKit view can overwrite, and
            // both neighbours here do: SwiftTerm's terminal view and WKWebView
            // set their own cursor from their tracking areas as the mouse
            // moves. The push won the moment it happened and was gone by the
            // next mouse-moved event, so the resize glyph never appeared —
            // reported by the operator on build 279, with the drag itself working.
            // Reasserting each tick beats the reset because it happens after.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    NSCursor.resizeLeftRight.set()
                case .ended:
                    guard isHovering else { return }
                    isHovering = false
                    NSCursor.arrow.set()
                }
            }
            // The pointer can leave without an `.ended` — the column closing
            // under it, or the window losing key — and the glyph would stay on
            // over whatever replaced the handle.
            .onDisappear {
                if isHovering { NSCursor.arrow.set(); isHovering = false }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStartWidth ?? width
                        dragStartWidth = start
                        // The column is on the right, so dragging the handle
                        // LEFT (a negative translation) widens it.
                        width = start - value.translation.width
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        onCommit()
                    }
            )
    }
}

/// Shown in place of the conversation when a rail session has no agent to
/// render: a stopped crew/pinned row (`SessionSurface.start`), or one a poll
/// has confirmed has no tmux session behind it at all (`SessionSurface.stale`,
/// gated by `ContentView.showsStaleGate`). Starting runs `co`, so the row
/// comes back as a live agent rather than the bare shell that attaching to a
/// fresh tmux session would leave. The terminal is still reachable — a user
/// may want a bare shell in the session rather than a co, and the
/// drift-proof fallback is never more than a click away — and for a `.stale`
/// row this button is the ONE action allowed to attach at all, precisely
/// because it is explicit rather than a side effect of the picker landing on
/// Terminal (see `showsStaleGate`).
///
/// `onRemovePin`, present only for a pinned child stuck in `.stale`, ends
/// the row instead through the existing confirm-and-remove flow — a crew's
/// own row has no pin to remove, so it stays nil there and this view offers
/// Start and Open terminal alone. Was two near-identical views
/// (`StaleSessionView` carried its own "no longer exists" copy and icon)
/// until `issue_01M1KXVY8MNNNG53NFBT8SY58Z`'s revision: that copy was false
/// for every idle crew or pinned row now routed through the same gate, and
/// `StartSessionView`'s own "is not running" was already true for both.
struct StartSessionView: View {
    let name: String
    /// The session pane's canvas, from `ContentView.paneCanvasRGB`: the same
    /// colour the live pane's conversation draws on, so a stopped session and a
    /// running one share one ground. Its inks are solved against it.
    let canvas: RGB
    var onStart: () -> Void
    var onTerminal: () -> Void
    var onRemovePin: (() -> Void)? = nil

    /// Text and the moon mark are solved against `canvas`, not taken from the
    /// system's `.secondary`/`.tertiary`, because those resolve against the pinned
    /// scheme and would stop holding a contrast floor if the canvas moved.
    private var textInk: Color { Color(ThemeRecipe.secondaryTextInk(on: canvas)) }
    private var markInk: Color { Color(ThemeRecipe.neutralMarkInk(on: canvas)) }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 28)).foregroundStyle(markInk)
            Text("\(name) is not running.")
                .frameFont(.primary).foregroundStyle(textInk)
            Button("Start session") { onStart() }
                .keyboardShortcut(.return, modifiers: [])
            // The terminal is still reachable — a user may want a bare shell in
            // the session rather than a co, and the drift-proof fallback is never
            // more than a click away.
            Button("Open terminal", action: onTerminal)
                .frameFont(.body).buttonStyle(.plain)
                .foregroundStyle(textInk)
            if let onRemovePin {
                Button("Remove pin", role: .destructive, action: onRemovePin)
                    .frameFont(.body).buttonStyle(.plain)
                    .foregroundStyle(textInk)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(canvas))
    }
}

/// Drawn in place of Start when a stopped crew or pinned child has no usable
/// `workingDirectory` — none configured, or one `validateWorkingDirectory`
/// rejects, which `folder` tells apart. See `SessionSurface.missingDirectory`.
/// Refusing is the deliberate choice over inventing one: this codebase's
/// standing rule for an unresolvable value is "the action is unavailable,
/// not that one should be invented" (`ContentView.hostTarget(for:)`), and a
/// guessed directory here would be exactly the `$HOME` fallback this view
/// exists to head off. The terminal fallback stays offered, same as
/// `StartSessionView` — a bare shell in whatever directory ssh lands in is
/// still useful even though `co` is not.
struct MissingDirectoryView: View {
    let name: String
    /// The configured folder when there is one Deck cannot use, `nil` when
    /// none is configured.
    let folder: String?
    /// The session pane's canvas — see `StartSessionView.canvas`.
    let canvas: RGB
    var onTerminal: () -> Void

    @EnvironmentObject private var navigation: SettingsNavigation
    @Environment(\.openSettings) private var openSettings

    /// Solved against `canvas`, for the reason `StartSessionView.textInk` gives.
    private var textInk: Color { Color(ThemeRecipe.secondaryTextInk(on: canvas)) }
    private var markInk: Color { Color(ThemeRecipe.neutralMarkInk(on: canvas)) }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 28)).foregroundStyle(markInk)
            if let folder {
                Text("Deck cannot start \(name) in \(folder).")
                    .frameFont(.primary).foregroundStyle(textInk)
                Text("Use an absolute or ~/ path with no spaces or shell characters.")
                    .frameFont(.body).foregroundStyle(textInk)
            } else {
                Text("\(name) has no working directory configured.")
                    .frameFont(.primary).foregroundStyle(textInk)
            }
            Button("Set a Working Directory\u{2026}") {
                navigation.openSessionsSettings()
                openSettings()
            }
            .frameFont(.body)
            Button("Open terminal", action: onTerminal)
                .frameFont(.body).buttonStyle(.plain)
                .foregroundStyle(textInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(canvas))
    }
}

/// Drawn in place of Start, the conversation pane, or the raw terminal when
/// a selected row's host does not resolve to anything — see
/// `deck/specs/running-deck-as-someone-else`. Unlike `StartSessionView`,
/// which offers a fallback that still works, nothing here can act without a
/// real machine to reach, so the one honest action is a way to configure
/// one. The row itself carries the same message in its
/// `hostWarning` tooltip and context menu (`RailRow`); this is the pane-side
/// echo of it, reached by actually selecting the row.
///
/// THE BUTTON IS THE POINT — see `issue_01M0ECVNHX6XRT47EJJ8B5Z54T`, filed
/// after this pane shipped correct but unreachable: a hover tooltip on a
/// warning triangle is not a way in
/// (`deck/specs/multiple-sessions-per-project`, the lesson from #111), and
/// a caption reading "Add one in Settings \u{203a} Hosts" is the same
/// mistake in prose. `SettingsNavigation` carries the request across scenes
/// since Settings is a separate window from this one.
private struct UnresolvedHostView: View {
    let name: String

    @EnvironmentObject private var navigation: SettingsNavigation
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("\(name) has no host configured.")
                .frameFont(.primary).foregroundStyle(.secondary)
            Button("Add a Host\u{2026}") {
                navigation.openHostsWithAddSheet()
                openSettings()
            }
            .frameFont(.body)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Removes the native window title while `removed` is true, where
/// `DeckTitleAccessory` draws it instead. `ToolbarDefaultItemKind.title` needs
/// macOS 15 and the package targets 14, so the branch is on the OS version,
/// which cannot change while the app runs; `removed` reaches it as a value.
/// On macOS 14 the native title stays visible.
private struct NativeTitleRemoval: ViewModifier {
    let removed: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: removed ? .title : nil)
        } else {
            content
        }
    }
}
