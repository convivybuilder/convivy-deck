import SwiftUI

/// The frame of every rail row currently asking for an answer, keyed by
/// ref — see `RailView.attentionAnchor(for:isStopped:)`. Merges rather than
/// overwrites-only-last, since every needs-answer row anchors independently
/// and a later one reporting must not erase an earlier one still on screen.
private struct RailAttentionFrameKey: PreferenceKey {
    static var defaultValue: [SessionRef: CGRect] { [:] }
    static func reduce(value: inout [SessionRef: CGRect], nextValue: () -> [SessionRef: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The rail's `List` container's own visible height, in the same space —
/// see `RailView.attentionListHeight`.
private struct RailAttentionListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 216pt, or 44pt collapsed (`design/redesign/03-rail.html`,
/// `04-narrow.html`). `[+ new]` at the bottom lets a session outside the
/// fixed catalog be reached by name, same escape hatch the manual text
/// field gave before the rail existed.
struct RailView: View {
    let crews: [Crew]
    /// Resolves a session to its accent. Injected so the rail draws from the
    /// same theme resolution the terminal canvas does, rather than carrying a
    /// second colour source of its own. Keyed by `SessionRef`, like `mark`
    /// and every other per-session lookup here: theme storage is host-scoped
    /// now, so the same crew name on two hosts has two accents.
    let accent: (SessionRef) -> RGB
    /// What a session's live state draws. Injected like `accent`: the shell owns
    /// the poll, the rail only draws what it is told. An unpolled session
    /// resolves to `.unpolled`. Keyed by `SessionRef`, since the poll's own
    /// `RailStateModel.states` is.
    let mark: (SessionRef) -> SessionState.Mark
    /// Whether a session has no live agent, for greying the row.
    let isStopped: (SessionRef) -> Bool
    /// Whether a session is showing a gate right now — the same
    /// `SessionState.gate` field `SessionPaneView.composer` branches on to
    /// draw `GatePanel` in place of the ordinary composer. Injected like
    /// `mark`, and read only for `selection`: see
    /// `suppressesNumberShortcuts(selection:hasOpenGate:)`.
    let hasOpenGate: (SessionRef) -> Bool
    /// Whether a DISCOVERED session should draw the `⊞` terminal-only
    /// treatment instead of its ordinary dot — `SessionSurface.choose(...)
    /// == .terminalOnly`, resolved by the shell. Only asked for a discovered
    /// child row or an "OTHER SESSIONS" row; a crew or pinned child never
    /// asks.
    let isTerminalOnly: (SessionRef) -> Bool
    /// A session's context meter, or nil to draw none — see `ContextMeter`.
    /// Injected like `mark`: the shell owns the poll, the rail only draws it.
    var contextMeter: (SessionRef) -> ContextMeter? = { _ in nil }
    /// A session's run-model mark, or nil to draw none — see `RunModelMark`.
    var runModelMark: (SessionRef) -> RunModelMark? = { _ in nil }
    /// A crew's Slate badge reading — `RailStateModel.asksOpen(for:)`,
    /// resolved by the shell like `mark`. Read only for a crew's own row
    /// (`row(for:)`); a pinned/discovered child shares its crew's Slate, so
    /// `childRow`/`discoveredChildRow`/`otherSessionRow` never ask this —
    /// see `RailRow.asksOpen`'s doc.
    var asksOpen: (SessionRef) -> SessionState.AsksOpen? = { _ in nil }
    /// A crew's Slate badge was clicked. The shell owns resolving the crew's
    /// host and opening the cockpit on its Slate.
    var onOpenSlate: (SessionRef) -> Void = { _ in }
    /// The rollover overrides a session's row offers (`ContextMeter.actions`).
    var rolloverActions: (SessionRef) -> [SessionAgent.RolloverAction] = { _ in [] }
    /// A rollover override was chosen on a row. The shell owns the confirm
    /// for `force` and the `session-agent rollover` call.
    var onRollover: (SessionRef, SessionAgent.RolloverAction) -> Void = { _, _ in }
    /// The window a session's rollover successor is starting in, while it is
    /// rolling (`WindowLeafRow.successorWindow(of:)`), or nil.
    var rolloverSuccessorWindow: (SessionRef) -> Int? = { _ in nil }
    /// Built per row by the shell, which owns theme resolution and the config
    /// write. The rail renders the menu; it does not decide what is in it.
    /// Keyed by `SessionRef`, like `accent`.
    let themeMenu: (SessionRef) -> AnyView
    /// Whether to offer a local shell below the fleet sessions. On by default
    /// and hideable, per the rule that defaults are opinionated and everything
    /// is overridable.
    /// Sessions Deck can start but does not pin. Drawn in their own section
    /// below the rail; empty means the section is absent, not blank.
    let catalog: [LaunchableSession]
    /// Start a catalog session. The shell owns the ssh call and the selection
    /// change; the rail only reports the click, the same division RailRow's
    /// theme menu follows.
    let onLaunch: (LaunchableSession) -> Void
    /// Resolved by the shell, handed down rather than read from the
    /// environment: Deck's appearance can be pinned in config, and
    /// `@Environment(\.colorScheme)` would report the system's instead.
    let appearance: Appearance
    /// The Builder Default ground the rail is drawn on, set by the shell's pin.
    @Environment(\.statusGround) private var statusGround
    /// The rail's own ground: the Builder Default ground under the status pin,
    /// and the system's control colour otherwise.
    private var railFill: Color {
        statusGround.map { Color($0) } ?? Color(nsColor: .controlBackgroundColor)
    }
    /// Every session `session-agent sessions` reported on the last poll —
    /// grouped fresh every render by `SessionGrouping`, never persisted. See
    /// `deck/specs/multiple-sessions-per-project` §"Discovering sessions
    /// created outside Deck".
    let discoveredSessions: [DiscoveredSession]
    /// "Move to its own session" was chosen on a window leaf. The shell owns
    /// the derivation, the `move-window` call, the config write, and the
    /// selection change — the same division `onLaunch` already follows.
    /// Carries the owning crew, the tmux name of the session that currently
    /// holds the window, and the window number.
    let onMoveWindowToOwnSession: (Crew, String, Int) -> Void
    /// "Rename…" was chosen on a crew row's context menu, with the new
    /// display name already trimmed and non-empty. The shell owns the
    /// `ThemeStore.renameCrew` call, the same division every other
    /// structural action here already follows.
    var onRenameCrew: (Crew, String) -> Void = { _, _ in }
    /// "Remove from Deck…" was chosen on a crew row's context menu. The
    /// shell owns the confirm and the config write.
    let onRequestRemoveCrew: (Crew) -> Void
    /// "Remove from Deck…" was chosen on a pinned child row's context
    /// menu — mirrors `onRequestRemoveCrew` one level down. The shell owns
    /// the confirm and the `ThemeStore.removePinnedSession` call.
    let onRequestRemoveChild: (Crew, PinnedSession) -> Void
    /// "Nest under <parent>" or "Move to Top Level" was chosen on a crew
    /// row's context menu — see `deck/specs/multiple-sessions-per-project`
    /// §"Setting a parent is a UI act". The shell owns the config write,
    /// the same division `onRequestRemoveCrew` already follows. `parentId`
    /// is nil for "Move to Top Level".
    let onSetCrewParent: (Crew, String?) -> Void
    /// "Stop" was chosen on a discovered row's context menu or hover
    /// button — an "OTHER SESSIONS" row (`otherSessionRow`) or a discovered
    /// child under its crew (`discoveredChildRow`), the only two rows whose
    /// surface can resolve to `.terminalOnly` with no other Stop control.
    /// The shell owns the confirm (the existing `sessionToStop` alert) and
    /// the `SessionAgent.stop` call — the same division every other
    /// destructive action here already follows.
    let onStopDiscoveredSession: (SessionRef) -> Void
    /// "Adopt into <Crew>" was chosen on an "OTHER SESSIONS" row's context
    /// menu — the inverse of `onRequestRemoveChild`: pins a session Deck did
    /// not create as the chosen crew's child. The shell owns the
    /// `ThemeStore.addPinnedSession` call. A NAV act, not a move: it does
    /// not touch the mini, the session's working directory, or restart
    /// anything, and `childRow`'s `PinnedRowLiveness` check keeps the Stop
    /// control an agent-less adoptee already had — only where Deck draws
    /// the row changes. See `deck/specs/multiple-sessions-per-project`
    /// §"The model".
    let onAdoptSession: (DiscoveredSession, Crew) -> Void
    /// "Promote to Crew…" was chosen on an "OTHER SESSIONS" row's context
    /// menu — the inverse of `onAdoptSession`: the shell owns the
    /// derivation, the confirm, and the `ThemeStore.addCrew` call, the same
    /// division every other structural action here already follows. See
    /// `deck/specs/multiple-sessions-per-project` §"An OTHER SESSIONS row
    /// can be adopted into a crew but cannot BECOME one".
    let onRequestPromoteSession: (DiscoveredSession) -> Void
    /// Whether the mini has confirmed a tmux session exists for `ref` —
    /// `RailStateModel.hasTmuxSession`, resolved by the shell. Gates a
    /// catalog row's "Stop": a catalog entry that has never been launched
    /// has nothing to stop, distinct from `isStopped`, which only answers
    /// whether there is an agent (`deck/specs/multiple-sessions-per-project`
    /// §"The rail": "Deck already knows the difference").
    var hasTmuxSession: (SessionRef) -> Bool = { _ in false }
    /// "Remove from Deck" was chosen on a catalog row's context menu — a
    /// catalog entry's only way out; before this it had none
    /// (`deck/specs/multiple-sessions-per-project` §"The rail": "A way out
    /// that only a right-click reveals is not a way out"). The shell owns
    /// the confirm and the `SessionRoster` write, the same division every
    /// other structural action here already follows.
    var onRequestRemoveCatalogEntry: (LaunchableSession) -> Void = { _ in }
    /// Every named host a crew can resolve against, and the configured
    /// default — passed down so `SessionGrouping` can enforce the host
    /// boundary (`deck/specs/multiple-sessions-per-project` §"Crews on
    /// different hosts") and an "OTHER SESSIONS" row can recover a
    /// `SessionRef` from the actual target it was discovered on
    /// (`HostResolution.hostName`). Defaults to `[]`/`nil`, so a call site
    /// built before this field existed keeps resolving discovered sessions
    /// exactly as it did.
    var hosts: [HostEntry] = []
    var defaultHost: String? = nil
    /// Reads `RailStateModel.probedMachineName(for:)` — the shell owns the
    /// poll, the rail only reads its cache. Defaults to "never landed", so a
    /// call site untouched by this phase draws exactly what it did before a
    /// probe existed.
    var probedMachineName: (SSHTarget) -> String? = { _ in nil }
    /// Reads `RailStateModel.isHostUnreachable(_:)` — whether a target's
    /// most recent poll failed to land at all, not merely a batch that
    /// answered with nothing new. Feeds `unreachableWarning(for:)`.
    /// Defaults to "never unreachable", so a call site untouched by this
    /// phase draws exactly what it did before this warning existed.
    var isHostUnreachable: (SSHTarget) -> Bool = { _ in false }
    /// Opens the selected crew's bead in the viewer, or nil when there is
    /// none to open — no selection, no resolved host, or a crew whose
    /// `Crew.project` is unset. THE RAIL IS THE ONLY REGION ABOUT THE
    /// PROJECT RATHER THAN A SESSION (`deck/bead/deck` §"The work"), so its
    /// foot is where this link belongs rather than the cockpit column, which
    /// already carries the bead's own content once opened. The shell owns
    /// deriving the doc id and the `WorkingCopyStore` fetch, the same
    /// division every other action here follows. Defaults to `nil` so a
    /// call site built before this field existed draws no button rather
    /// than a crashing one.
    var onOpenBead: (() -> Void)? = nil
    /// The bead button's tooltip — the same value that decides `onOpenBead`,
    /// so the two cannot say different things. See
    /// `CockpitResolution.BeadAvailability`.
    var beadHelp: String = "Open this project's bead"

    /// The selected crew's bead — title and progress fraction, or nil to
    /// draw the pane's whole body as nothing, the same posture
    /// `WaypointRibbon`/`WorkingStrip` take for "no data for this crew".
    /// Populated by `BeadProgressModel`; the shell owns the poll, the rail
    /// only draws what it is told. `title`/`progress` inside a non-nil
    /// value are independently optional — a load in flight, a failed
    /// fetch, or (`progress` only) an unparseable revision each draw their
    /// own partial state rather than hiding the whole pane, per
    /// `BeadProgress.compute`'s "never invent a denominator" doc.
    struct BeadProgressDisplay: Equatable {
        let title: String?
        let progress: BeadProgress.Result?
    }
    var beadProgress: BeadProgressDisplay? = nil

    /// True below `LayoutBreakpoints.railCollapse` — the 44pt dot rail
    /// (`design/redesign/04-narrow.html`: "names go, marks stay"). Resolved
    /// by the shell from the window's measured width, the same division
    /// every other appearance/layout input here follows: the rail draws
    /// what it is told rather than measuring its own container. Every row
    /// builder below forwards this to `RailRow`/`RailChildRow`/
    /// `WindowLeafRow`/`LauncherRow`, which already carry the collapsed
    /// treatment — see their own `isCollapsed` docs.
    var isCollapsed: Bool = false

    /// Ground above the `List`, so the first crew starts on the session pane's
    /// top line (CQ·153). The shell hands down the toolbar row's measured
    /// height under Builder Default, where the rail and the toolbar row share
    /// one ground, and zero under every other preference.
    ///
    /// IT ALSO KEEPS SCROLLED ROWS OUT OF THE TITLE BAR (CQ·147). A `List`
    /// whose top meets the window's safe-area line has its scroll view
    /// extended up into the title bar by SwiftUI, so its rows scroll behind
    /// the title. With this ground between them the `List` no longer meets
    /// that line, and its rows stop at its own top edge. Two earlier fixes
    /// painted a band of the title bar's height from the rail's top instead;
    /// the rail's top is already the title bar's bottom, so that band covered
    /// the first row and hid none of the scrolled ones.
    var topInset: CGFloat = 0

    @Binding var selection: SessionRef?

    /// Every row currently asking for an answer, keyed by ref, with its
    /// on-screen frame in `RailView.attentionSpace` — reported by
    /// `attentionAnchor(for:isStopped:)`, which only a row with
    /// `case .needsYou = mark(ref)` attaches. Feeds the pinned "N needs
    /// you" chip: a summons the fold has scrolled past is still an alert,
    /// not something the rail may go quiet about
    /// (`design/redesign/03-rail.html`'s `.offscreen`).
    @State private var attentionFrames: [SessionRef: CGRect] = [:]
    /// The list's own visible height in the same space — reported once by a
    /// `GeometryReader` in the list's background, which (unlike a row's own
    /// reader) is anchored to the container rather than to scrolling
    /// content, so this stays the viewport's height regardless of scroll
    /// position.
    @State private var attentionListHeight: CGFloat = 0

    /// The coordinate space `attentionFrames` and `attentionListHeight` are
    /// both measured in — attached to the `List` itself, the same trick a
    /// `ScrollView` uses to expose "is this row still on screen" (a named
    /// space anchored to the SCROLLING CONTAINER reports a row's frame
    /// shifting as it scrolls, rather than a fixed offset from the row's own
    /// content).
    private static let attentionSpace = "RailView.attentionSpace"

    /// Every off-screen row needing an answer, nearest first — `nil`/empty
    /// list height means the list has not laid out yet, and a frame nobody
    /// reported yet cannot be off-screen, since it is not on screen either.
    private var offscreenAttentionRefs: [SessionRef] {
        guard attentionListHeight > 0 else { return [] }
        return attentionFrames
            .filter { $0.value.minY >= attentionListHeight }
            .sorted { $0.value.minY < $1.value.minY }
            .map(\.key)
    }

    /// Reports a needs-answer row's on-screen frame for the off-screen chip
    /// above — gated the same way `RailRow.summonsInk`/
    /// `RailChildRow`'s own summons bar are, so a stopped session (no
    /// longer asking anything) never counts toward it.
    @ViewBuilder
    private func attentionAnchor(for ref: SessionRef, isStopped: Bool) -> some View {
        if !isStopped, case .needsYou = mark(ref) {
            GeometryReader { geo in
                Color.clear.preference(
                    key: RailAttentionFrameKey.self,
                    value: [ref: geo.frame(in: .named(RailView.attentionSpace))])
            }
        }
    }

    /// The pinned chip itself — `design/redesign/03-rail.html`'s
    /// `.offscreen`: "a chip pinned to the list's bottom edge whenever a row
    /// needing an answer is scrolled out of view... absent when nothing
    /// qualifies, because here it is an alert and not furniture." The text
    /// drops in the dot rail the same way `.rail.dots .offscreen span`
    /// hides it there — the tick and chevron alone still say "something is
    /// below," and there is no width left to say more.
    @ViewBuilder
    private func offscreenAttentionChip(count: Int, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Rectangle().fill(Color.orange).frame(width: 3, height: 12)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                if !isCollapsed {
                    Text("\(count) needs you").frameFont(.label)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(railFill)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.orange)
        .help("\(count) session\(count == 1 ? "" : "s") below needs an answer; activate to scroll to it")
    }

    /// The crew a "Rename…" prompt is asking a new display name for, or nil
    /// when none is open. Holding the `Crew` rather than just its id keeps
    /// the alert's title from disagreeing with a rail that changed
    /// underneath it.
    @State private var renamingCrew: Crew?
    @State private var renameText = ""

    /// Whether `START`'s picker popover is open — option C
    /// (`design/start-section/index.html`). Lives here, not in
    /// `StartPickerView`, because `StartOpenerRow` needs to know it too, to
    /// draw its own open/closed state.
    @State private var isShowingStartPicker = false

    /// The catalog entries `START`'s opener and picker offer — every entry
    /// that is not already running, per `StartPicker.availableEntries`. A
    /// running entry is excluded here and appears under `OTHER SESSIONS`
    /// instead — see `otherSessions`'s doc.
    private var availableCatalogEntries: [LaunchableSession] {
        StartPicker.availableEntries(catalog) { entry in
            hasTmuxSession(SessionRef(host: entry.host, name: entry.id))
        }
    }

    /// Which crew rows are expanded, persisted across launches the same
    /// way the local shell's last directory is — `@AppStorage`, because this
    /// is the rail remembering what the user left open, not a setting anyone
    /// hand-edits. A comma-joined string rather than a second file: nothing
    /// here needs to survive a hand edit or sync with `theme.json`. The
    /// keying, including how an entry written before hosts existed is read,
    /// lives in `CrewExpansion`.
    @AppStorage(CrewExpansion.storageKey) private var expandedCrewIdsRaw = ""

    private func isExpanded(_ crew: SessionRef) -> Bool {
        CrewExpansion(raw: expandedCrewIdsRaw).isExpanded(crew)
    }

    private func toggleExpanded(_ crew: SessionRef) {
        var expansion = CrewExpansion(raw: expandedCrewIdsRaw)
        expansion.toggle(crew)
        expandedCrewIdsRaw = expansion.raw
    }

    /// Every discovered session, grouped by the crew that owns it —
    /// computed once per render rather than re-run per row.
    private var groupedDiscovered: [String: [DiscoveredSession]] {
        SessionGrouping.group(discoveredSessions, into: crews, hosts: hosts, defaultHost: defaultHost)
    }

    /// The rail's outer rows — `RailNesting.topLevelCrews(crews)`, cached
    /// per render the same way `groupedDiscovered` is. A nested crew is
    /// drawn from inside `rows(for:)`, never from this list directly.
    private var topLevelCrews: [Crew] {
        RailNesting.topLevelCrews(crews, hosts: hosts, defaultHost: defaultHost)
    }

    /// Every display name drawn by more than one crew on the rail right
    /// now — `HostDisplay.duplicateDisplayNames`, computed once per render
    /// the same way `groupedDiscovered` is. `hostLabel(for:)` is nil for
    /// every crew NOT in this set: see `HostDisplay.crewLabel`'s doc for why
    /// a name shown once needs no host beside it.
    private var duplicateCrewNames: Set<String> {
        HostDisplay.duplicateDisplayNames(among: crews)
    }

    /// A crew row's "user@machine" label, or nil to draw nothing — see
    /// `HostDisplay.crewLabel`.
    private func hostLabel(for crew: Crew) -> String? {
        HostDisplay.crewLabel(
            for: crew, duplicateNames: duplicateCrewNames, hosts: hosts, defaultHost: defaultHost,
            probed: probedMachineName)
    }

    /// A crew row's stale-host warning, or nil — see
    /// `HostDisplay.unresolvedHostWarning`.
    private func hostWarning(for crew: Crew) -> String? {
        HostDisplay.unresolvedHostWarning(
            for: crew, hosts: hosts, defaultHost: defaultHost, probed: probedMachineName)
    }

    /// A crew row's "cannot reach the host" warning, or nil — see
    /// `HostDisplay.unreachableWarning`. Checked only when `hostWarning`
    /// itself found nothing, via the `??` at this row's `hostWarning:`
    /// argument below.
    ///
    /// NOT MUTUALLY EXCLUSIVE WITH `hostWarning`. `HostResolution.target`
    /// falls back to the configured default host when a crew's `host` names
    /// something the table no longer has, rather than failing — so
    /// `hostWarning` fires for that stale-name case too, and the crew is
    /// still polled, against the fallback target, which can genuinely be
    /// unreachable. When both are true, the `??` means `hostWarning`'s
    /// stale-name message wins and this one never runs for that row.
    ///
    /// Accepted rather than given both a slot: a stale host name is the more
    /// actionable of the two, and fixing it is what makes the reachability
    /// question meaningful at all — there is nothing useful to say about
    /// whether the fallback host is reachable until the name is corrected to
    /// point at the host the operator actually meant. The row is not silent
    /// about the outage either way; it demotes to `Mark.unreadable` through
    /// `RailStateModel.refresh`, a path that does not go through this
    /// warning slot.
    private func unreachableWarning(for crew: Crew) -> String? {
        HostDisplay.unreachableWarning(
            for: crew, hosts: hosts, defaultHost: defaultHost,
            isUnreachable: isHostUnreachable, probed: probedMachineName)
    }

    /// Discovered sessions no crew owns, for the "OTHER SESSIONS" section —
    /// `SessionGrouping.ungrouped`, sorted alphabetically. Empty means the
    /// section itself is absent — see
    /// `deck/specs/multiple-sessions-per-project` §"The model".
    ///
    /// USED TO ALSO DROP ANY NAME THE CATALOG LISTED. That filter is why a
    /// launched-but-unpinned catalog entry used to stay invisible on both
    /// sides: excluded here, and still drawn as an ordinary hollow "not
    /// running" row under `START`, whose `onLaunch` had already selected a
    /// `SessionRef` no visible row carried
    /// (`issue_01M1SV8QKJ7ADH87PCNC0Q0YE8`). `START`'s own picker now
    /// excludes a running entry on its side instead (`StartPicker.availableEntries`),
    /// so a running catalog entry belongs here and only here — no filter
    /// left to delete a second time.
    ///
    /// A NAMED, TESTABLE FUNCTION rather than only a computed property, so
    /// this routing is pinned by a test without a view-level test target —
    /// see `RailStartSectionTests`.
    nonisolated static func otherSessions(
        discoveredSessions: [DiscoveredSession], crews: [Crew], hosts: [HostEntry], defaultHost: String?
    ) -> [DiscoveredSession] {
        SessionGrouping.ungrouped(discoveredSessions, crews: crews, hosts: hosts, defaultHost: defaultHost)
            .sorted { $0.name < $1.name }
    }

    private var otherSessions: [DiscoveredSession] {
        RailView.otherSessions(
            discoveredSessions: discoveredSessions, crews: crews, hosts: hosts, defaultHost: defaultHost)
    }

    /// A crew's discovered children: grouped rows minus its own id (a
    /// crew's own primary session matches rule A against itself) and
    /// minus any name already pinned, sorted alphabetically — "pinned
    /// children hold config order and discovered rows append after them
    /// alphabetically" (design §"The rail").
    private func discoveredChildren(for crew: Crew) -> [DiscoveredSession] {
        SessionGrouping.discoveredChildren(
            of: groupedDiscovered[crew.id] ?? [],
            crewId: crew.id,
            crewSessionId: crew.sessionId,
            pinnedNames: Set(crew.sessions.map(\.name)),
            pinnedSessionIds: Set(crew.sessions.compactMap(\.sessionId)))
    }

    /// The mark that should drive a COLLAPSED crew's summons bar: the
    /// first live child — pinned or discovered — that needs an answer, or
    /// nil when none does. Only consulted for a collapsed row —
    /// `RailRow.effectiveSummonsSource` ignores it entirely when the row's
    /// own mark already needs a reply, and the caller here only asks in the
    /// first place when `!isExpanded`.
    ///
    /// REACHES THROUGH A NESTED CREW TOO (design §"Collapse follows the
    /// parent"): "a summons anywhere in a collapsed subtree lights the
    /// top-level parent's bar." A collapsed parent hides a nested crew and
    /// everything under it regardless of the nested crew's OWN disclosure
    /// state, so its own mark and its own children are checked here
    /// unconditionally rather than only when it, too, happens to be
    /// expanded.
    private func collapsedChildAttentionMark(for crew: Crew) -> SessionState.Mark? {
        if let own = attentionMark(amongChildrenOf: crew) { return own }
        for nested in RailNesting.nestedCrews(of: crew, in: crews, hosts: hosts, defaultHost: defaultHost) {
            let nestedRef = SessionRef.owned(by: nested, name: nested.id)
            if !isStopped(nestedRef), case .needsYou = mark(nestedRef) { return mark(nestedRef) }
            if let nestedChild = attentionMark(amongChildrenOf: nested) { return nestedChild }
        }
        return nil
    }

    /// One crew's own pinned and discovered children only — no nesting —
    /// factored out so `collapsedChildAttentionMark` can run it once for
    /// `crew` itself and again for each of its nested crews.
    private func attentionMark(amongChildrenOf crew: Crew) -> SessionState.Mark? {
        for child in crew.sessions {
            let ref = SessionRef.owned(by: crew, name: child.name)
            guard !isStopped(ref) else { continue }
            let childMark = mark(ref)
            if case .needsYou = childMark { return childMark }
        }
        for discovered in discoveredChildren(for: crew) {
            let ref = SessionRef.owned(by: crew, name: discovered.name)
            guard !isStopped(ref) else { continue }
            let discoveredMark = mark(ref)
            if case .needsYou = discoveredMark { return discoveredMark }
        }
        return nil
    }

    /// A no-op for a blank name — the trim-and-check `ThemeStore.renameCrew`
    /// also does, mirrored here so a submit on an emptied field just closes
    /// the prompt rather than round-tripping a write that would be dropped.
    private func submitRename(_ crew: Crew) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onRenameCrew(crew, trimmed) }
        cancelRename()
    }

    private func cancelRename() {
        renamingCrew = nil
        renameText = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The band's height is untouched: the boat is an overlay, so the
            // CQ·153 alignment and the CQ·147 scroll fix stand. It centres on
            // the dot column, which holds still between the expanded and
            // collapsed rail (`RailRow.leadingPadding`), and on the toolbar
            // row. Gated on a real band, because an overlay on a 0pt band does
            // not clip and would draw over the first crew under every other
            // appearance.
            Color.clear.frame(height: topInset)
                .overlay(alignment: .leading) {
                    if topInset > 0 {
                        BuilderBoatMark()
                            .padding(.leading, RailRow.dotColumnCenterX - BuilderBoatMark.size.width / 2)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
            // A LIST WITH A SELECTION BINDING, not a ScrollView of tap
            // gestures. Moving between sessions is the highest-frequency
            // navigation in this app and the arrow keys did nothing: a tap
            // gesture is not a control, so it brought no keyboard handling, no
            // type-select, and no VoiceOver semantics with it. `List` gives all
            // three for the price of the binding, and the row's own appearance
            // survives via the row insets and background below.
            //
            // WRAPPED IN A `ScrollViewReader`, for the off-screen "needs you"
            // chip's `scrollTo` — see `offscreenAttentionRefs`.
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    List(selection: $selection) {
                        // Identified by `ref`, not by `crew.id`: two crews of
                        // one name on two hosts are two rows, and a duplicate
                        // SwiftUI id would let it reuse one row's view for the
                        // other.
                        ForEach(topLevelCrews, id: \.ref) { crew in
                            rows(for: crew)
                        }
                        // Above `START`, below the crews: every discovered session
                        // no crew owns is still RUNNING, so it belongs on the live
                        // side of that line rather than beside an invitation to
                        // start something that is not. Inside the same `List` as
                        // the crews, not beside it like `START`'s catalog rows,
                        // because these rows select — `START`'s do not.
                        if !otherSessions.isEmpty {
                            otherSessionsSection
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .coordinateSpace(name: RailView.attentionSpace)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: RailAttentionListHeightKey.self, value: geo.size.height)
                    })
                    .onPreferenceChange(RailAttentionFrameKey.self) { attentionFrames = $0 }
                    .onPreferenceChange(RailAttentionListHeightKey.self) { attentionListHeight = $0 }

                    if let nearest = offscreenAttentionRefs.first {
                        offscreenAttentionChip(count: offscreenAttentionRefs.count) {
                            proxy.scrollTo(nearest, anchor: .center)
                        }
                    }
                }
            }

            if statusGround == nil || !catalog.isEmpty || beadProgress != nil { Divider() }

            // Below the fleet sessions and below a divider, because it is a
            // different kind of thing: everything above is a persistent tmux
            // session on the mini, this is a throwaway shell on this machine.
            // Grouping it with them would imply it survives the way they do.
            //
            // A LABEL AND EXACTLY ONE ROW, option C
            // (`design/start-section/index.html`,
            // `issue_01M1SV8QKJ7ADH87PCNC0Q0YE8`) — fixed at 52pt regardless
            // of catalog size, where the old `ForEach(catalog)` cost 26pt per
            // entry and starved the crews' own `List` as the catalog grew
            // (measured: 468pt of a 640pt rail at 17 entries). The row is a
            // SIBLING of the `List` above, exactly as `START` always was —
            // opening a `.popover` here carries no nested-scroll hazard.
            if !catalog.isEmpty {
                sectionHeader("START")
                let available = availableCatalogEntries
                StartOpenerRow(count: available.count, isCollapsed: isCollapsed,
                              isOpen: isShowingStartPicker)
                    .onTapGesture { isShowingStartPicker = true }
                    .popover(isPresented: $isShowingStartPicker, arrowEdge: .leading) {
                        StartPickerView(
                            catalog: available,
                            onLaunch: { entry in
                                isShowingStartPicker = false
                                onLaunch(entry)
                            },
                            onRemove: { onRequestRemoveCatalogEntry($0) },
                            onDismiss: { isShowingStartPicker = false })
                    }
                // Under the status ground a divider only separates two sections,
                // so it is drawn only when a section follows it. The last one would
                // otherwise sit on the rail's foot, where the Course strip joins.
                if statusGround == nil || beadProgress != nil { Divider() }
            }

            // Below the crews — the operator's remembered layout, 2026-08-26: "a whole
            // pane just above 'new' and below the rail." The "+ New" row it
            // sat above is gone — a crew is made by the steward's `new-crew`
            // skill, or adopted by promoting a discovered session, and no
            // longer conjured from a sheet — so this is the rail's last
            // element.
            //
            // IT OWNS ONLY A TRAILING `Divider()`, never a leading one. A
            // divider always precedes this point already — the unconditional
            // one after the crews, or the catalog section's trailing one when
            // a catalog draws — so a leading divider here stacked two
            // hairlines together in every case a bead existed
            // (`deck-reviewer`, PR #142). See `beadProgressPane`.
            beadProgressPane
        }
        .frame(width: isCollapsed ? 44 : 216)
        .background(railFill)
        // Cmd-1…9 jumps to a row. Nine rather than the whole rail because the
        // shortcuts run out, and the first nine are the ones a hand learns.
        // TOP-LEVEL ROWS ONLY — `RailNesting.topLevelCrews`, not the raw
        // `crews` list — so a nested crew never claims a shortcut and never
        // shifts a later top-level row into an earlier slot (design
        // §"Nested rendering" item 4). A child, nested or otherwise, is
        // reached by arrow keys, which the `List` already handles (design §E).
        //
        // STANDS DOWN WHILE THE SELECTED SESSION IS SHOWING A GATE (the operator,
        // 2026-09-05). A gate is Deck's permission prompt, and both this
        // block and `OptionCard` bound ⌘1-9 unconditionally, so which one
        // AppKit resolved a keystroke to was undocumented — someone reaching
        // for ⌘3 to glance at another crew could land on the gate's third
        // option instead, authorising an action they never meant to answer.
        // The `Button`s are left out of the view tree entirely rather than
        // `.disabled`, because a disabled button can still swallow its key
        // equivalent under AppKit; leaving them out never registers the
        // shortcut at all. Nothing is latched: `suppressesNumberShortcuts`
        // reads live off `hasOpenGate`, so the rail recovers on the render
        // right after the gate clears.
        .background {
            if !RailView.suppressesNumberShortcuts(selection: selection, hasOpenGate: hasOpenGate) {
                ForEach(Array(topLevelCrews.prefix(9).enumerated()), id: \.element.ref) { index, crew in
                    Button("") { selection = SessionRef.owned(by: crew, name: crew.id) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .hidden()
                }
            }
        }
        .alert(
            "Rename \(renamingCrew?.displayName ?? "")",
            isPresented: Binding(
                get: { renamingCrew != nil },
                set: { if !$0 { cancelRename() } })
        ) {
            TextField("Name", text: $renameText)
                .onSubmit { if let crew = renamingCrew { submitRename(crew) } }
            Button("Rename") { if let crew = renamingCrew { submitRename(crew) } }
            Button("Cancel", role: .cancel, action: cancelRename)
        } message: {
            // This relabels the row only — never the session it attaches
            // to, which is `crew.id` and stays exactly what it was. Named
            // here so the one place this could be misread is where the
            // reader already is.
            Text("Changes what shows on the rail. The session itself is unaffected.")
        }
    }

    /// A section heading — "OTHER SESSIONS", "START" — or, collapsed, a
    /// plain rule in its place (`design/redesign/03-rail.html`'s
    /// `.rail.dots .sect`: "a rule, not a label"). The label carries no
    /// information the mark-only rows below it could not lose without
    /// consequence, but the section BOUNDARY still matters at 44pt — a
    /// bare run of dots with no break between crews and "OTHER SESSIONS"
    /// would read as one undifferentiated list.
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        if isCollapsed {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityLabel(title)
        } else {
            Text(title)
                .frameFont(.label)
                .tracking(0.9)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    /// The rail's own small cockpit surface — the selected crew's bead as a
    /// label, its title, a thin meter, and the fraction as text
    /// (`deck/bead/deck` §1: "Deck renders a project's bead as its cockpit
    /// content, which is what makes a bead load-bearing rather than a
    /// document nobody opens"). The operator's LEAN treatment, 2026-08-26 — those
    /// four things, nothing more.
    ///
    /// Draws nothing when `beadProgress` is nil — the selected crew names
    /// no bead — the same posture `WaypointRibbon`/`WorkingStrip` take: the
    /// rest of the rail gets that space back rather than an empty pane
    /// claiming it.
    ///
    /// **THE ONLY WAY THE BEAD OPENS.** This pane and the rail foot's
    /// `doc.text.magnifyingglass` icon both called `onOpenBead`; the icon was
    /// removed on 2026-09-03 because it did nothing this pane does not, and
    /// this pane also names the bead and shows its progress. One door, not
    /// two that could drift.
    @ViewBuilder
    private var beadProgressPane: some View {
        if let beadProgress {
            Button(action: { onOpenBead?() }) {
                // COLLAPSED, THE PANE IS JUST THE METER (`design/redesign/
                // 03-rail.html`'s `.rail.dots .bead .t, .f, .sectlabel {
                // display: none }`): the label, the title and the fraction
                // are all names, and 44pt has room for none of them. Nothing
                // draws at all when there is no `progress` to show even a
                // bar for — an empty button the width of the dot rail would
                // read as a stray control rather than a bead with no
                // progress yet.
                if isCollapsed {
                    if let progress = beadProgress.progress {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .padding(.horizontal, 10).padding(.vertical, 10)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BEAD")
                            .frameFont(.label)
                            .tracking(0.9)
                            .foregroundStyle(.tertiary)
                        Text(beadProgress.title ?? "\u{2026}")
                            .frameFont(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let progress = beadProgress.progress {
                            ProgressView(value: progress.fraction)
                                .progressViewStyle(.linear)
                            Text(progress.fractionLabel)
                                .frameFont(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .help(beadHelp)
            // The rail's foot. Under the status ground it would sit on the Course
            // strip's top edge, so it is left out there.
            if statusGround == nil { Divider() }
        }
    }

    /// A crew's row, plus its pinned children and nested crews when
    /// expanded. Two separate `@ViewBuilder`s below rather than one large
    /// one, for the same reason `row(for:)` was already pulled out of the
    /// `List` builder: the type checker times out on a row's modifier chain
    /// plus a tag plus a second row's, all inlined into one closure.
    ///
    /// `indent` is 0 for a top-level crew and `RailChildRow.indent` for a
    /// nested one — `rows(for:)` recurses into a nested crew's own subtree
    /// at one indent level deeper, the same way a pinned child's own window
    /// leaves already sit one level deeper than the child itself.
    ///
    /// ERASED TO `AnyView`, not `some View`. This function calls itself —
    /// once per nested crew — and Swift cannot infer an opaque return type
    /// from a call that is itself the thing being inferred. `rowsContent`
    /// below carries the actual `@ViewBuilder` body; erasing only at this
    /// one boundary keeps every other row builder in this file concrete.
    private func rows(for crew: Crew, indent: CGFloat = 0) -> AnyView {
        AnyView(rowsContent(for: crew, indent: indent))
    }

    /// How many extra tmux windows `ref` has, from the last poll's per-host
    /// grouping — pulled out of `windowLeaves` so `rowsContent` can also
    /// resolve a CREW's own window count directly: unlike a child's, a
    /// crew's own leaves can have pinned or discovered siblings after them,
    /// so `rowsContent` needs the count itself to decide whether one of
    /// those leaves is the crew's LAST child before it draws a spine.
    private func windowCount(for ref: SessionRef, crew: Crew) -> Int? {
        (groupedDiscovered[crew.id] ?? []).first { $0.name == ref.name }?.windows
    }

    @ViewBuilder
    private func rowsContent(for crew: Crew, indent: CGFloat) -> some View {
        row(for: crew, indent: indent)
        if isExpanded(crew.ref) {
            let ownRef = SessionRef.owned(by: crew, name: crew.id)
            let ownWindows = WindowLeaf.numbers(forWindowCount: windowCount(for: ownRef, crew: crew))
            let pinned = crew.sessions
            let discovered = discoveredChildren(for: crew)
            // The last row in this list is what `RailChildSpine` needs to
            // know to stop its line at that row's centre rather than run it
            // through a sibling that is not there (design §"The rail": "the
            // spine drawn under children so nesting survives a wrapped
            // name"). Nested crews are excluded from this count — a nested
            // crew's own header row carries no spine of its own (design
            // §"Nested rendering": "a nested crew is still a full crew
            // row"), so its presence after the last child does not change
            // where that child's line ends.
            let totalChildren = ownWindows.count + pinned.count + discovered.count

            // The crew's own extra windows sit at the same indent as its
            // children — immediately after its own row, before any of them
            // (design §"The rail").
            ForEach(Array(ownWindows.enumerated()), id: \.element) { i, window in
                let leafRef = WindowLeaf.ref(session: ownRef, window: window)
                WindowLeafRow(window: window,
                             isSelected: selection == leafRef,
                             accent: accent(ownRef),
                             appearance: appearance,
                             indent: indent + RailChildRow.indent,
                             isLast: i == totalChildren - 1,
                             onMoveToOwnSession: { onMoveWindowToOwnSession(crew, crew.id, window) },
                             isCollapsed: isCollapsed)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .tag(leafRef)
            }
            ForEach(Array(pinned.enumerated()), id: \.element.id) { i, child in
                childRow(for: child, crew: crew, indent: indent + RailChildRow.indent,
                        isLast: (ownWindows.count + i) == totalChildren - 1)
                windowLeaves(owningSessionRef: SessionRef.owned(by: crew, name: child.name), crew: crew,
                            indent: indent + RailChildRow.indent * 2)
            }
            ForEach(Array(discovered.enumerated()), id: \.element.id) { i, item in
                discoveredChildRow(for: item, crew: crew, indent: indent + RailChildRow.indent,
                                  isLast: (ownWindows.count + pinned.count + i) == totalChildren - 1)
                windowLeaves(owningSessionRef: SessionRef.owned(by: crew, name: item.name), crew: crew,
                            indent: indent + RailChildRow.indent * 2)
            }
            // Nested crews draw last, after the crew's own sessions and
            // before the next top-level crew (design §"Nested rendering"),
            // each carrying its own full subtree one indent level deeper.
            ForEach(RailNesting.nestedCrews(of: crew, in: crews, hosts: hosts, defaultHost: defaultHost), id: \.ref) { nested in
                rows(for: nested, indent: indent + RailChildRow.indent)
            }
        }
    }

    @ViewBuilder
    private func row(for crew: Crew, indent: CGFloat = 0) -> some View {
        let ref = SessionRef.owned(by: crew, name: crew.id)
        let expanded = isExpanded(crew.ref)
        let childCount = crew.sessions.count + discoveredChildren(for: crew).count
            + RailNesting.nestedCrews(of: crew, in: crews, hosts: hosts, defaultHost: defaultHost).count
        RailRow(crew: crew,
                isSelected: selection == ref,
                accent: accent(ref),
                appearance: appearance,
                mark: mark(ref),
                isStopped: isStopped(ref),
                themeMenu: { themeMenu(ref) },
                // Gated on the COMBINED count, not just pinned children —
                // otherwise a crew whose only children are ones a hand
                // discovered would show no chevron at all, and nothing
                // could ever reveal them.
                disclosure: childCount == 0 ? nil : RailRow.Disclosure(
                    childCount: childCount,
                    isExpanded: expanded,
                    onToggle: { toggleExpanded(crew.ref) }),
                // Only asked while collapsed — expanded, a needy child gets
                // its own bar on its own row instead (design §"Attention").
                childSummonsMark: expanded ? nil : collapsedChildAttentionMark(for: crew),
                onRename: { renamingCrew = crew; renameText = crew.displayName },
                onRemove: { onRequestRemoveCrew(crew) },
                indent: indent,
                eligibleParents: RailNesting.eligibleParents(for: crew, in: crews, hosts: hosts, defaultHost: defaultHost),
                onSetParent: { onSetCrewParent(crew, $0) },
                hostLabel: hostLabel(for: crew),
                hostWarning: hostWarning(for: crew) ?? unreachableWarning(for: crew),
                isCollapsed: isCollapsed,
                meter: rowMeter(ref),
                rolloverActions: rowRolloverActions(ref),
                onRollover: { onRollover(ref, $0) },
                runModelMark: runModelMark(ref),
                asksOpen: asksOpen(ref),
                onOpenSlate: { onOpenSlate(ref) })
            .background(attentionAnchor(for: ref, isStopped: isStopped(ref)))
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            // The row paints its own selection wash in the session's accent, so
            // the list must not paint the system one over the top of it.
            .listRowBackground(Color.clear)
            .tag(ref)
    }

    /// A row's context meter, or nil for a session with no agent. A stopped
    /// row greys out and a terminal-only one has no agent to fill a context,
    /// so neither draws a track that would read as a live reading.
    private func rowMeter(_ ref: SessionRef, isTerminalOnly: Bool = false) -> ContextMeter? {
        guard !isStopped(ref), !isTerminalOnly else { return nil }
        return contextMeter(ref)
    }

    /// A row's rollover overrides, under the same guard as `rowMeter`:
    /// rolling over a session with no agent means nothing.
    private func rowRolloverActions(_ ref: SessionRef, isTerminalOnly: Bool = false) -> [SessionAgent.RolloverAction] {
        guard !isStopped(ref), !isTerminalOnly else { return [] }
        return rolloverActions(ref)
    }

    @ViewBuilder
    private func childRow(for child: PinnedSession, crew: Crew,
                          indent: CGFloat = RailChildRow.indent, isLast: Bool = false) -> some View {
        let ref = SessionRef.owned(by: crew, name: child.name)
        // See `PinnedRowLiveness`: a pinned row's config says nothing about
        // whether its session still exists, so `hasTmuxSession` — the same
        // reading the catalog row already uses — is what tells a stale pin
        // apart from a live one, and what restores the Stop an adopted,
        // agent-less session had before `onAdoptSession` moved it here.
        let liveness = PinnedRowLiveness.choose(
            hasPolled: mark(ref) != .unpolled,
            isStopped: isStopped(ref),
            hasTmuxSession: hasTmuxSession(ref))
        RailChildRow(name: child.name, displayName: child.displayName,
                     isSelected: selection == ref,
                     accent: accent(ref),
                     appearance: appearance,
                     mark: mark(ref),
                     isStopped: isStopped(ref),
                     themeMenu: { themeMenu(ref) },
                     isTerminalOnly: liveness == .stale,
                     isLast: isLast,
                     onStop: liveness == .needsRowStop ? { onStopDiscoveredSession(ref) } : nil,
                     onRemove: { onRequestRemoveChild(crew, child) },
                     indent: indent,
                     isCollapsed: isCollapsed,
                     meter: rowMeter(ref, isTerminalOnly: liveness == .stale),
                     rolloverActions: rowRolloverActions(ref, isTerminalOnly: liveness == .stale),
                     onRollover: { onRollover(ref, $0) },
                     runModelMark: runModelMark(ref))
            .background(attentionAnchor(for: ref, isStopped: isStopped(ref)))
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .tag(ref)
    }

    /// A discovered child's row — same look as a pinned one, but built from
    /// a `DiscoveredSession` rather than config: no display name of its own,
    /// so its tmux name is drawn as-is, and no "New session…" item, matching
    /// a pinned child today. Carries `onStop` the same way `otherSessionRow`
    /// does: an agent-less discovered child resolves to `.terminalOnly`,
    /// which has no Stop control in the pane, so the row is its only way
    /// out — the same reason gap 1 wired a hover Stop into "OTHER SESSIONS"
    /// in the first place, one section over.
    @ViewBuilder
    private func discoveredChildRow(
        for discovered: DiscoveredSession, crew: Crew, indent: CGFloat = RailChildRow.indent,
        isLast: Bool = false
    ) -> some View {
        let ref = SessionRef.owned(by: crew, name: discovered.name)
        RailChildRow(name: discovered.name, displayName: discovered.name,
                     isSelected: selection == ref,
                     accent: accent(ref),
                     appearance: appearance,
                     mark: mark(ref),
                     isStopped: isStopped(ref),
                     themeMenu: { themeMenu(ref) },
                     isTerminalOnly: isTerminalOnly(ref),
                     isLast: isLast,
                     onStop: { onStopDiscoveredSession(ref) },
                     indent: indent,
                     isCollapsed: isCollapsed,
                     meter: rowMeter(ref, isTerminalOnly: isTerminalOnly(ref)),
                     rolloverActions: rowRolloverActions(ref, isTerminalOnly: isTerminalOnly(ref)),
                     onRollover: { onRollover(ref, $0) },
                     runModelMark: runModelMark(ref))
            .background(attentionAnchor(for: ref, isStopped: isStopped(ref)))
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .tag(ref)
    }

    /// The "OTHER SESSIONS" heading and its rows — every discovered session
    /// no crew owns, reachable and stoppable instead of running off the
    /// rail's edge. Styled exactly like `START`'s heading (same font, same
    /// insets), but drawn as `List` rows rather than beside the `List`: an
    /// `START` entry is not yet running and merely launches on tap, while
    /// these rows select like any other session and need the `List`'s own
    /// selection machinery for that.
    @ViewBuilder
    private var otherSessionsSection: some View {
        sectionHeader("OTHER SESSIONS")
        ForEach(otherSessions) { discovered in
            otherSessionRow(for: discovered)
        }
    }

    /// One "OTHER SESSIONS" row. Drawn at the rail's top level (`indent: 0`)
    /// rather than under a crew — there is no crew here to indent under.
    /// Carries a "Stop" the same way `discoveredChildRow` does, for the
    /// same reason: an agent-less discovered session resolves to
    /// `.terminalOnly`, which has no Stop control in the pane.
    ///
    /// NO CREW OWNS THIS ROW, so its `SessionRef` cannot inherit a host from
    /// one — `SessionRef.orphaned` recovers the config host NAME (if any)
    /// whose entry resolves to the actual target this row was discovered
    /// on, via `HostResolution.hostName`.
    @ViewBuilder
    private func otherSessionRow(for discovered: DiscoveredSession) -> some View {
        let ref = SessionRef.orphaned(discovered, hosts: hosts)
        RailChildRow(name: discovered.name, displayName: discovered.name,
                     isSelected: selection == ref,
                     accent: accent(ref),
                     appearance: appearance,
                     mark: mark(ref),
                     isStopped: isStopped(ref),
                     themeMenu: { themeMenu(ref) },
                     isTerminalOnly: isTerminalOnly(ref),
                     previewsAdoptionHue: true,
                     onStop: { onStopDiscoveredSession(ref) },
                     adoptionTargets: SessionGrouping.adoptionTargets(
                         for: discovered, crews: crews, hosts: hosts, defaultHost: defaultHost),
                     onAdopt: { onAdoptSession(discovered, $0) },
                     onPromote: { onRequestPromoteSession(discovered) },
                     indent: 0,
                     isCollapsed: isCollapsed,
                     meter: rowMeter(ref, isTerminalOnly: isTerminalOnly(ref)),
                     rolloverActions: rowRolloverActions(ref, isTerminalOnly: isTerminalOnly(ref)),
                     onRollover: { onRollover(ref, $0) },
                     runModelMark: runModelMark(ref))
            .background(attentionAnchor(for: ref, isStopped: isStopped(ref)))
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .tag(ref)
    }

    /// The window leaves belonging to one session — its own extra windows
    /// (`ctrl-A c`), if `session-agent sessions` reported more than one.
    /// `owningSessionRef` may be the crew's own ref, a pinned child's, or a
    /// discovered child's — `session-agent sessions` lists every real tmux
    /// session uniformly, so the window count for any of them comes from
    /// a discovered row matched by bare name. The lookup is scoped to
    /// `groupedDiscovered[crew.id]` rather than the raw, cross-host
    /// `discoveredSessions` array: `SessionGrouping.group` has already
    /// filtered that bucket to sessions on `crew`'s own host, which is what
    /// makes matching the rest of the way by bare name safe. Matching
    /// `discoveredSessions` directly would let a same-named session on a
    /// DIFFERENT host win `.first` and draw that host's window count here.
    @ViewBuilder
    private func windowLeaves(owningSessionRef: SessionRef, crew: Crew, indent: CGFloat) -> some View {
        let numbers = WindowLeaf.numbers(forWindowCount: windowCount(for: owningSessionRef, crew: crew))
        ForEach(numbers, id: \.self) { window in
            let leafRef = WindowLeaf.ref(session: owningSessionRef, window: window)
            WindowLeafRow(window: window,
                         isSelected: selection == leafRef,
                         accent: accent(owningSessionRef),
                         appearance: appearance,
                         indent: indent,
                         // Nothing else at this indent follows a session's
                         // OWN window leaves (design §"The rail": a child's
                         // own windows sit one level deeper than any
                         // sibling), so the last window number is always
                         // this group's own last row.
                         isLast: window == numbers.last,
                         onMoveToOwnSession: {
                             onMoveWindowToOwnSession(crew, owningSessionRef.name, window)
                         },
                         isCollapsed: isCollapsed,
                         successorWindow: rolloverSuccessorWindow(owningSessionRef))
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .tag(leafRef)
        }
    }

    /// Whether the rail's ⌘1-9 crew-jump bindings must stand down right now.
    /// The operator's ruling, 2026-09-05: the gate wins while it is on screen, since
    /// answering it is time-sensitive and crew-jumping can wait a moment.
    ///
    /// TRUE ONLY FOR A GATE ON THE SELECTED SESSION. A gate open in some
    /// other crew is not on screen and must not touch navigation here —
    /// that would make ⌘1-9 mysteriously dead while the user looks at an
    /// ordinary pane. `nil` selection (nothing chosen yet) can have no gate
    /// showing, so it never suppresses.
    ///
    /// A pure function of `selection` and whatever `hasOpenGate` answers for
    /// it — nothing is latched here, so a caller that re-evaluates this on
    /// every render (as `RailView.body` does) recovers the instant the gate
    /// clears, the same render the composer itself falls back to `nil`.
    nonisolated static func suppressesNumberShortcuts(
        selection: SessionRef?, hasOpenGate: (SessionRef) -> Bool
    ) -> Bool {
        guard let selection else { return false }
        return hasOpenGate(selection)
    }
}


/// One catalog row: a session that can be started. Dimmer than a rail row and
/// carrying a start glyph, because it is an invitation rather than a live
/// session — the visual difference is the whole point of the separate section.
private struct LauncherRow: View {
    let entry: LaunchableSession
    /// True in the 44pt dot rail — see `RailRow.isCollapsed`'s doc, which
    /// this mirrors. `CatalogStartMark`'s hollow square is unchanged either
    /// way — the mark, not the name, is what "not running; activate to
    /// start" is drawn as at any width.
    var isCollapsed: Bool = false
    /// "Stop", offered only when non-nil — `RailView` passes this whenever
    /// `hasTmuxSession` confirms a real tmux session behind this catalog
    /// entry. Mirrors `RailChildRow.onStop`'s own gate and hover idiom,
    /// rather than inventing a second one.
    var onStop: (() -> Void)? = nil
    /// "Remove from Deck…", always offered — see `RailView.onRequestRemoveCatalogEntry`.
    let onRemove: () -> Void

    /// Gates the hover Stop button, the same idiom `RailChildRow` uses.
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            CatalogStartMark()
            if !isCollapsed {
                Text(entry.displayName)
                    .frameFont(.primary)
                    .foregroundStyle(.secondary)
                Spacer()
                if let onStop, isHovering {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }
            }
        }
        .padding(.horizontal, isCollapsed ? 0 : 10)
        .frame(maxWidth: isCollapsed ? .infinity : nil)
        .frame(height: RailRow.rowHeight)
        .help(isCollapsed ? entry.displayName : "")
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if let onStop {
                Button("Stop", role: .destructive, action: onStop)
                Divider()
            }
            Button("Remove from Deck…", role: .destructive, action: onRemove)
        }
    }
}

/// `START`'s own row: a label and exactly one row, at any catalog size
/// (`design/start-section/index.html` §"C · One row that opens a picker").
/// Opening it is `RailView`'s job — this only draws what a click should
/// look like, the same division `LauncherRow` already follows for a plain
/// catalog row.
private struct StartOpenerRow: View {
    let count: Int
    var isCollapsed: Bool = false
    /// Whether `StartPickerView` is showing right now — draws the chevron
    /// pointing down, mirroring `RailRow.Disclosure`'s own expanded chevron,
    /// rather than a state this row tracks itself.
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 8) {
            CatalogStartMark()
            if !isCollapsed {
                Text("Start a session\u{2026}")
                    .frameFont(.primary)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(count)")
                    .frameFont(.label)
                    .foregroundStyle(.secondary)
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, isCollapsed ? 0 : 10)
        .frame(maxWidth: isCollapsed ? .infinity : nil)
        .frame(height: RailRow.rowHeight)
        .help(isCollapsed ? "Start a session\u{2026} (\(count) available)" : "")
        .contentShape(Rectangle())
        .accessibilityLabel(Text("Start a session; \(count) available"))
    }
}

/// The picker itself — `START`'s catalog, reached from `StartOpenerRow`'s
/// popover. A SECOND, LOCAL SELECTION (`focusedId`) that never touches the
/// rail's own `$selection`, per the design's own item to verify: `START`
/// rows launch, they do not select.
///
/// KEYBOARD FOCUS STAYS IN THE FILTER FIELD the whole time, so ↑↓/↩/Esc are
/// intercepted there with `.onKeyPress` rather than left to a `List`'s own
/// arrow-key handling, which only answers when the LIST holds focus. The
/// same interception idiom `ComposerView`'s Return/Up-arrow handling
/// already uses for the same reason: a focused text control is the one
/// thing on screen actually listening.
private struct StartPickerView: View {
    let catalog: [LaunchableSession]
    let onLaunch: (LaunchableSession) -> Void
    let onRemove: (LaunchableSession) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var focusedId: String?
    @FocusState private var isFieldFocused: Bool
    /// The Builder Default ground the start view is drawn on, set by the shell's pin.
    @Environment(\.statusGround) private var statusGround

    private var filtered: [LaunchableSession] {
        StartPicker.filter(catalog, query: query)
    }

    /// The filter field's raised fill: one step above the ground under a status
    /// pin, and the system's control colour otherwise.
    private var filterFill: Color {
        statusGround == nil ? Color(nsColor: .controlBackgroundColor) : Color(StatusGround.raised)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(filterFill))
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .onChange(of: query) { _, _ in
                    // A keystroke can narrow the list out from under
                    // whatever `focusedId` pointed at — `move` already
                    // treats a vanished id as "nothing focused yet", so
                    // resetting here just makes that explicit rather than
                    // leaving a focus ring on a row that scrolled away.
                    focusedId = filtered.first?.id
                }
                .onKeyPress(.downArrow, phases: .down) { _ in
                    focusedId = StartPicker.move(current: focusedId, in: filtered, delta: 1)
                    return .handled
                }
                .onKeyPress(.upArrow, phases: .down) { _ in
                    focusedId = StartPicker.move(current: focusedId, in: filtered, delta: -1)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { _ in
                    guard let focusedId, let entry = filtered.first(where: { $0.id == focusedId })
                    else { return .ignored }
                    onLaunch(entry)
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    onDismiss()
                    return .handled
                }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { entry in
                        LauncherRow(entry: entry, onRemove: { onRemove(entry) })
                            .background(focusedId == entry.id
                                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.12)
                                : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { onLaunch(entry) }
                    }
                }
            }
            // Ten rows before it scrolls — `design/start-section/index.html`'s
            // `.pop .rows { max-height: calc(10 * 26px) }`.
            .frame(maxHeight: CGFloat(min(filtered.count, 10)) * RailRow.rowHeight)

            HStack {
                Text(StartPicker.footLabel(matchCount: filtered.count, totalCount: catalog.count))
                Spacer()
                Text("\u{2191}\u{2193} move \u{00b7} \u{21a9} starts")
            }
            .frameFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(width: 232)
        .onAppear {
            focusedId = filtered.first?.id
            isFieldFocused = true
        }
    }
}
