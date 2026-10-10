import Foundation

/// Pure helpers for `RailStateModel.refresh`'s per-host fan-out — grouping
/// tracked refs by their resolved host, and merging each host's outcome
/// into the last good reading. Split out so the shape can be pinned by a
/// test without an ssh round trip, the same discipline `SessionGrouping`
/// and `HostResolution` follow.
enum RailPoll {
    /// Buckets tracked `SessionRef`s by the `SSHTarget` they resolve to.
    /// With one host defined every ref lands in the same bucket, which is
    /// how `RailStateModel.refresh` collapses to "one states call, one
    /// sessions call" — exactly today's behaviour — the moment only one
    /// host exists.
    static func grouped(
        _ sessions: [SessionRef], resolveHost: (SessionRef) -> SSHTarget?
    ) -> [SSHTarget: [SessionRef]] {
        var out: [SSHTarget: [SessionRef]] = [:]
        for ref in sessions {
            // A ref whose host does not resolve to anything is left out of
            // every bucket — there is no host to ask about it, so it is
            // simply never polled. It reads as "unpolled," never as
            // "stopped": the same state-unknown idiom the rail already uses
            // for a ref removed mid-launch.
            guard let target = resolveHost(ref) else { continue }
            out[target, default: []].append(ref)
        }
        return out
    }

    /// Merges each host's `states` outcome into the previous reading. A host
    /// whose outcome is `nil` here contributes nothing, so every session it
    /// was asked about KEEPS its last good reading rather than losing it —
    /// this is the generic overlay merge, agnostic to WHY an outcome is
    /// missing. `RailStateModel.refresh` never actually calls this with a
    /// `nil` outcome for a host whose fetch failed: it passes
    /// `demotedStates(for:)`'s placeholders instead, so a transport failure
    /// demotes those sessions to `.unreadable` rather than leaving a filled
    /// mark standing on state Deck no longer has (`issue_01M23WC488NVYT6T5MDZN37ZBR`).
    /// `nil` remains meaningful to this function for a host skipped
    /// entirely — untracked this tick — which is what these tests below
    /// pin. A host that answered, even with an empty object, overlays its
    /// own entries.
    static func mergedStates(
        previous: [SessionRef: SessionState],
        outcomes: [SSHTarget: [SessionRef: SessionState]?]
    ) -> [SessionRef: SessionState] {
        var merged = previous
        for outcome in outcomes.values {
            guard let outcome else { continue }
            merged.merge(outcome) { _, new in new }
        }
        return merged
    }

    /// Every ref in `refs`, set to the same placeholder `SessionState.decode`
    /// already produces for a payload it could not parse: `phase: .unknown`,
    /// which resolves to `Mark.unreadable` — a hollow ring, never a filled
    /// one. Built for the case one layer further out than a bad payload: no
    /// payload at all, because the host that would have sent one could not
    /// be reached. See `Mark.unreadable`'s doc — "a filled shape would
    /// assert something" — and `issue_01M23WC488NVYT6T5MDZN37ZBR`, where
    /// every session on an offline host kept drawing its last filled mark
    /// through a transport failure that answered nothing at all.
    static func demotedStates(for refs: [SessionRef]) -> [SessionRef: SessionState] {
        var out: [SessionRef: SessionState] = [:]
        for ref in refs {
            out[ref] = SessionState(
                session: ref.name, phase: .unknown, gate: nil, alive: false,
                reason: "host unreachable", lastEvent: nil,
                transcriptMTime: nil, cwd: nil, progressing: nil, lastEventAge: nil)
        }
        return out
    }

    /// NOT the same merge as `mergedStates` — the shapes only look alike.
    /// `states` is an OVERLAY: a map of answers about sessions Deck asked
    /// about, where a missing answer means "no news" and every entry not
    /// mentioned keeps standing. `discovered` is an INVENTORY: a host that
    /// answers is reporting its complete session list, so an entry of that
    /// host's the answer does not repeat is gone, not merely unmentioned.
    ///
    /// A host whose outcome is `nil` — unreachable, or a transport failure —
    /// contributes nothing, and every entry keyed to it keeps its last good
    /// reading, same as `mergedStates`. A host that DOES answer, even with an
    /// empty list, is authoritative for its own entries: every previous
    /// entry keyed to that host is dropped first, then replaced with exactly
    /// what the answer reported. Keyed by `DiscoveredSession.ID`, which
    /// carries the host, so one host's answer can never touch another's
    /// entries.
    static func mergedDiscovered(
        previous: [DiscoveredSession.ID: DiscoveredSession],
        outcomes: [SSHTarget: [DiscoveredSession]?]
    ) -> [DiscoveredSession.ID: DiscoveredSession] {
        var merged = previous
        for (target, outcome) in outcomes {
            guard let outcome else { continue }
            merged = merged.filter { $0.key.host != target }
            for session in outcome { merged[session.id] = session }
        }
        return merged
    }

    /// The same inventory merge as `mergedDiscovered`, for `session-agent
    /// crews` — a host that answers is authoritative for its own crew
    /// specs, dropping and replacing them; a host that fails leaves its
    /// specs standing at their last good reading. See `mergedDiscovered`'s
    /// doc for why this differs from `mergedStates`'s overlay.
    static func mergedServedCrews(
        previous: [ServedCrew.ID: ServedCrew],
        outcomes: [SSHTarget: [ServedCrew]?]
    ) -> [ServedCrew.ID: ServedCrew] {
        var merged = previous
        for (target, outcome) in outcomes {
            guard let outcome else { continue }
            merged = merged.filter { $0.key.host != target }
            for crew in outcome { merged[crew.id] = crew }
        }
        return merged
    }
}

/// Polls the mini for the liveness and phase of every session on the rail, so a
/// row can decorate itself with what its session is doing and grey out when the
/// session is not running.
///
/// ONE ROUND TRIP FOR THE WHOLE RAIL. The rail draws many sessions and would
/// otherwise poll one ssh call per row; `session-agent states` answers all of
/// them at once, and each answer is brief — liveness and phase, none of the
/// status-area reads a row does not show. The open pane keeps its own richer
/// poll; this is the cheaper, wider one the rail needs.
///
/// SEPARATE FROM THE PANE'S POLL ON PURPOSE. The pane follows one conversation
/// closely; the rail glances at all of them. Folding them together would either
/// make the rail pay the pane's cost per row or make the pane as shallow as the
/// rail. Two readers, each sized to its job.
@MainActor
final class RailStateModel: ObservableObject {
    /// Keyed by `SessionRef`, not a bare name — two crews with the same
    /// tmux name on different hosts are two distinct entries here, per
    /// `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// hosts": "identity becomes `(host, session name)`". Every tracked ref
    /// is one `track(_:)` already knows the config host of, so keying here
    /// costs no extra resolution.
    @Published private(set) var states: [SessionRef: SessionState] = [:]

    /// Hosts whose `states` call failed outright on the most recent tick —
    /// an ssh transport failure, not a batch that merely answered with
    /// nothing to report. Drives the rail's per-host "cannot reach" warning
    /// (`RailView.unreachableWarning`); cleared the moment that host answers
    /// again. Per-host rather than a single flag, since one configured host
    /// can be down while another answers — see
    /// `issue_01M23WC488NVYT6T5MDZN37ZBR`.
    @Published private(set) var unreachableHosts: Set<SSHTarget> = []

    /// Whether `target`'s most recent poll failed to land at all — the
    /// shell reads this to decide whether to show the rail's "cannot reach"
    /// warning for a crew resolved to it.
    func isHostUnreachable(_ target: SSHTarget) -> Bool {
        unreachableHosts.contains(target)
    }

    /// Every session `session-agent sessions` reported on the last
    /// successful poll, keyed by `DiscoveredSession.ID` — the actual
    /// `SSHTarget` it was found on, plus its name — see `DiscoveredSession`
    /// and `SessionGrouping`. Ephemeral: never written to config,
    /// recomputed fresh from this dictionary every render. A failed poll
    /// leaves the last good set standing, the same discipline `states`
    /// follows.
    @Published private(set) var discovered: [DiscoveredSession.ID: DiscoveredSession] = [:]

    /// Every crew spec `session-agent crews` reported on the last successful
    /// poll, keyed by `ServedCrew.ID` — the actual `SSHTarget` it was found
    /// on, plus the spec's own id. See `ServedCrew` and `CrewMerge`.
    /// Ephemeral, same as `discovered`: never written to config, recomputed
    /// fresh from this dictionary every render. A failed poll leaves the
    /// last good set standing, the same discipline `discovered` follows.
    @Published private(set) var servedCrews: [ServedCrew.ID: ServedCrew] = [:]

    /// `hostname -s`'s answer for each host that has landed, keyed by the
    /// resolved `SSHTarget` — see `HostProbe` and
    /// `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// hosts". Probed at most ONCE PER HOST PER APP RUN: a host that has
    /// already answered is skipped on every later tick, since a machine's
    /// own hostname changes about never. Never cleared — a host that goes
    /// briefly unreachable keeps the name it already gave, which is exactly
    /// the "last good reading" discipline `states`/`discovered` follow.
    @Published private(set) var probedMachineNames: [SSHTarget: String] = [:]

    /// The probed name for `target`, or nil when the probe has not landed
    /// yet — the shell reads this to resolve `HostDisplay`'s `probed`
    /// parameter without reaching into the dictionary directly.
    func probedMachineName(for target: SSHTarget) -> String? {
        probedMachineNames[target]
    }

    /// Counts ticks of `refresh()`, purely to schedule a failed probe's next
    /// retry — no view reads it, so it is not `@Published`.
    private var tickCount: Int = 0

    /// The tick a target's probe may next be attempted, for a target whose
    /// most recent attempt failed. A target absent here is eligible
    /// immediately — either it has never been tried, or it last succeeded
    /// (and so has left `unprobedTargets` entirely; see `refresh()`).
    private var probeRetryAtTick: [SSHTarget: Int] = [:]

    /// How many ticks a failed probe sits out before trying again — about a
    /// minute at the poll's four-second cadence. An unreachable host's own
    /// name is not urgent, so retrying it every tick forever bought nothing
    /// but a third serial ssh attempt on a box that was never going to
    /// answer; caught by deck-reviewer on PR #110. A host that starts
    /// answering is still picked up within a bounded window rather than
    /// never.
    private static let probeBackoffTicks = 15

    /// Fetches one host's batched session states. A stored `@Sendable`
    /// closure, not a direct call to `SessionAgent.states`, so a test can
    /// substitute a fake that is slow or that fails without a real ssh round
    /// trip — the seam `refresh()`'s per-host publish timing needed to be
    /// verifiable at all (deck-reviewer, PR #110). Defaults to the real call.
    var fetchStates: @Sendable (SSHTarget, [String]) throws -> [String: SessionState] = { target, sessions in
        try SessionAgent.states(target: target, sessions: sessions)
    }

    /// The same seam as `fetchStates`, for `session-agent sessions`.
    var fetchDiscovered: @Sendable (SSHTarget) throws -> [DiscoveredSession] = { target in
        try SessionAgent.discoveredSessions(target: target)
    }

    /// The same seam as `fetchStates`, for `HostProbe.probe`.
    var fetchProbe: @Sendable (SSHTarget) throws -> String = { target in
        try HostProbe.probe(target: target)
    }

    /// The same seam as `fetchStates`, for `session-agent crews`.
    var fetchServedCrews: @Sendable (SSHTarget) throws -> [ServedCrew] = { target in
        try SessionAgent.servedCrews(target: target)
    }

    /// The same seam as `fetchStates`, for the run register's `GET /runs`.
    var fetchRunRegister: @Sendable (SSHTarget) throws -> [String: RunModelChoice] = { target in
        try RunRegister.fetch(target: target)
    }

    /// The same seam as `fetchStates`, for `DesktopSessionProbe.probe` —
    /// never throws, unlike its siblings, since every failure it can hit is
    /// already a `DesktopSessionReading` in its own right (CQ·124).
    var fetchDesktopSession: @Sendable (SSHTarget) -> DesktopSessionReading = { target in
        DesktopSessionProbe.probe(target: target)
    }

    /// The last DEFINITE desktop-session reading for each polled host —
    /// holds through a run of `.unknown` readings rather than clearing, the
    /// same "last good reading" discipline `states`/`discovered` already
    /// follow. Read by Settings › Hosts so the logged-out fact still shows
    /// there even after its alert has been dismissed (CQ·124).
    @Published private(set) var desktopSessionKnownState: [SSHTarget: DesktopSessionKnownState] = [:]

    /// Called the instant a host's desktop-session reading transitions to
    /// logged out — see `DesktopSessionTracker.apply` for exactly which
    /// transitions that is. Set by `track()`'s caller, the same way
    /// `resolveHost`/`configuredTargets` are; a test that never names one
    /// (every test untouched by CQ·124) sees no calls at all.
    var onDesktopSessionLoggedOut: (SSHTarget) -> Void = { _ in }

    /// Each host's last `/runs` answer, keyed by `run_id`. Kept per host so a
    /// host whose read fails loses only its own entries, and the join below
    /// never lets one host's table mark another host's run.
    private var runChoicesByHost: [SSHTarget: [String: RunModelChoice]] = [:]

    /// Every host's answer merged, for the join in `runModelMark(for:)`.
    ///
    /// A FAILED READ CLEARS ITS HOST'S ENTRIES rather than leaving them
    /// standing, unlike `states`' "keep the last good reading". A mark says a
    /// run is off its roster model; a register that cannot be read cannot
    /// vouch for that any longer, and the row's own state is unaffected.
    @Published private(set) var runChoices: [String: RunModelChoice] = [:]

    /// The mark a session's row draws for its live runs, or nil.
    ///
    /// A FLEET-WIDE RUN LIST DRAWS NO MARK. session-agent scopes `agent_runs`
    /// to the session's product, except for a `substrate` session or one
    /// outside the crews root, where it returns every crew's live runs and
    /// says so with `agents_fleet_wide`. Such a list cannot say which runs are
    /// the row's own, so marking from it would put other crews' overrides on
    /// the steward's row. The cockpit labels the same list " (fleet)"; the
    /// rail mark has no room for that, so it draws nothing instead.
    func runModelMark(for session: SessionRef) -> RunModelMark? {
        guard let state = states[session], !state.agentsAreFleetWide,
              let runs = state.agentRuns else { return nil }
        return RunModelMark.resolve(runs: runs, register: runChoices)
    }

    /// The ticket of the poll whose data is in `states` now, or -1 before any
    /// poll has landed.
    ///
    /// WHY A READER NEEDS THIS. `states` alone cannot say whether a reading
    /// predates something the reader did. That is not a detail — a caller
    /// acting on "stopped" a moment after pressing Start is reading the poll
    /// that put the Start button on screen in the first place, and treating it
    /// as a verdict on the launch it precedes.
    ///
    /// TICKETED AT DISPATCH, NOT AT LANDING, and the difference is the whole
    /// correctness of this. A poll is an ssh round trip: one already in flight
    /// when the user presses Start asked the mini BEFORE the press, so its
    /// answer describes the session before the launch — but it lands after.
    /// Numbering by arrival would stamp that answer newer than the press and
    /// hand a reader pre-launch data labelled as fresh. Numbering by dispatch
    /// puts it where it belongs: below anything captured after it was issued.
    /// Caught by deck-reviewer, who noted the window is one round trip per
    /// four-second interval rather than every restart.
    @Published private(set) var generation: Int = -1

    /// The ticket the next poll DISPATCHED from here on will carry. A caller
    /// captures this at the instant it acts; `generation` reaching it means a
    /// poll issued after that instant has landed.
    ///
    /// Not `@Published`: it is read once at the moment of an action, and a view
    /// has no reason to redraw when it moves.
    private(set) var pendingTicket: Int = 0

    /// The refs polled each tick. Set by the shell when the rail changes, and
    /// read fresh at the top of every tick so adding a row does not wait for a
    /// restart of the loop.
    ///
    /// Not `private`, the same as `resolveHost` and `refresh()` below — see
    /// their doc comments for why.
    var sessions: [SessionRef] = []
    /// Resolves a tracked ref to the host its crew runs on, or `nil` when
    /// the ref's host does not resolve to anything — see `HostResolution`.
    /// `RailPoll.grouped` drops such a ref from every bucket it builds, so
    /// an unresolved crew is simply never asked about: it reads exactly as
    /// unpolled, the same "state unknown" the rail already draws for a ref
    /// removed mid-launch. Set alongside `sessions` by `track`, and read
    /// fresh at the top of every tick the same way `sessions` is. Defaults
    /// to every ref resolving unresolved, so a caller that never names a
    /// resolver (every test, and any call site untouched by phase 6a/6b)
    /// reads every session as unpolled rather than targeting a compiled-in
    /// box. Production passes an explicit closure
    /// (`ContentView.swift`), so only tests take this default.
    ///
    /// Not `private`: a test can set this directly, alongside `sessions` and
    /// `fetchStates`/`fetchDiscovered`/`fetchProbe`, and call `refresh()`
    /// once rather than going through `track()`'s real four-second loop.
    var resolveHost: (SessionRef) -> SSHTarget? = { _ in nil }

    /// Every host configured in Settings, resolved to its `SSHTarget`,
    /// polled each tick whether or not any ref resolves there —
    /// `issue_01M3RGBXYGMC4D9K1CEP63R9G1`: a host running only a crew-less
    /// tmux session (macmini's `steward`) got no bucket from
    /// `RailPoll.grouped` at all, since that groups by REF, and so was never
    /// asked for `sessions`/`crews`. Read fresh at the top of every tick, the
    /// same as `resolveHost` — see its doc for why a closure over the live
    /// config, rather than a value snapshotted at `track()` time, is what
    /// lets a host added in Settings get polled without a relaunch. Set
    /// alongside `sessions` and `resolveHost` by `track`. Defaults to no
    /// extra hosts, so a test that never names one (every test untouched by
    /// this fix) sees exactly today's "poll only what refs resolve to."
    var configuredTargets: () -> [SSHTarget] = { [] }
    private var pollTask: Task<Void, Never>?

    /// Slower than the pane's two seconds: a rail row's state is glanceable
    /// context, not the thing being read, and every rail session is polled each
    /// tick, so the cost is a round trip carrying all of them at this cadence.
    private static let pollInterval = Duration.seconds(4)

    deinit { pollTask?.cancel() }

    /// The sessions to watch. Idempotent, so the shell can call it on every rail
    /// change without restarting the loop; a changed set is picked up on the next
    /// tick. Starts the loop the first time it is given something to watch.
    func track(
        _ sessions: [SessionRef], resolveHost: @escaping (SessionRef) -> SSHTarget? = { _ in nil },
        configuredTargets: @escaping () -> [SSHTarget] = { [] },
        onDesktopSessionLoggedOut: @escaping (SSHTarget) -> Void = { _ in }
    ) {
        self.sessions = sessions
        self.resolveHost = resolveHost
        self.configuredTargets = configuredTargets
        self.onDesktopSessionLoggedOut = onDesktopSessionLoggedOut
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: RailStateModel.pollInterval)
            }
        }
    }

    /// Off the main actor — a rail-wide ssh round trip must not freeze the
    /// window any more than the pane's does. Fans out ONE `states` CALL, ONE
    /// `sessions` CALL, ONE `crews` CALL, AND (AT MOST) ONE PROBE CALL PER
    /// HOST, all four running concurrently with each other, so a box that is
    /// unreachable cannot stall the others' readings — see
    /// `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// boxes". With one host defined `RailPoll.grouped` puts every name in
    /// one bucket, so this is exactly the pair of calls it always was; the
    /// concurrency and the per-host merge only start doing anything the
    /// moment a second host exists.
    ///
    /// PUBLISHED PER HOST, AS EACH HOST'S TASK COMPLETES, not once after
    /// every host in the tick has finished. A reachable host's rows must
    /// reach `states`/`discovered` on its own round-trip time — a slow or
    /// unreachable host beside it must not hold that data back. Merging once
    /// at the end used to do exactly that; caught by deck-reviewer on PR
    /// #110, whose finding traced it to the app's whole effective poll
    /// cadence stalling on the slowest host in the group.
    ///
    /// NOT `private`. `track()`'s own loop calls this on a real four-second
    /// cadence, which is unusable from a test wanting to pin `refresh()`'s
    /// publish TIMING rather than merely its eventual result. A test sets
    /// `sessions`/`resolveHost`/`fetchStates`/`fetchDiscovered`/`fetchProbe`
    /// directly and calls this once — the same seam
    /// `SessionPaneModel.applyDeltaOutcome` already gives its own tests for
    /// the identical reason.
    func refresh() async {
        let refs = sessions
        let resolve = resolveHost
        var groups = RailPoll.grouped(refs, resolveHost: resolve)
        // A configured host no ref resolved to gets an empty bucket rather
        // than no bucket at all — see `configuredTargets`'s doc
        // (`issue_01M3RGBXYGMC4D9K1CEP63R9G1`). A target already present
        // (the ordinary case: every host has at least one ref) is left
        // exactly as `RailPoll.grouped` built it.
        for target in configuredTargets() where groups[target] == nil {
            groups[target] = []
        }
        guard !groups.isEmpty else { return }
        // Taken before the await, so it dates the QUESTION rather than the
        // answer. See `generation`.
        let ticket = pendingTicket
        pendingTicket += 1
        tickCount += 1
        let currentTick = tickCount

        // Read on the main actor, before any task is dispatched, so the
        // decision "does this host still need probing this tick" is made
        // once per tick rather than raced against this same tick's own
        // outcome. A target is skipped either because it already has a
        // cached name, or because a recent failed attempt put it in
        // backoff — see `probeBackoffTicks`.
        let unprobedTargets = Set(groups.keys).subtracting(probedMachineNames.keys)
        let targetsToProbe = unprobedTargets.filter { (probeRetryAtTick[$0] ?? 0) <= currentTick }

        // Captured as locals so the concurrent tasks below close over plain
        // `@Sendable` values rather than reaching back into `self` — the same
        // reason `resolve` is captured above.
        let statesFetch = fetchStates
        let discoveredFetch = fetchDiscovered
        let probeFetch = fetchProbe
        let servedCrewsFetch = fetchServedCrews
        let runRegisterFetch = fetchRunRegister
        let desktopSessionFetch = fetchDesktopSession

        await withTaskGroup(
            of: (SSHTarget, [SessionRef], [SessionRef: SessionState]?,
                 [DiscoveredSession]?, [ServedCrew]?, [String: RunModelChoice]?, Bool, String?,
                 DesktopSessionReading).self
        ) { group in
            for (target, groupRefs) in groups {
                let shouldProbe = targetsToProbe.contains(target)
                group.addTask {
                    // `session-agent states` speaks bare names — the wire
                    // format has no notion of a config host key — so the
                    // reading is translated back to `SessionRef` here, using
                    // THIS bucket's own refs: every ref in one bucket already
                    // resolved to the same target, so a name it reports can
                    // only mean the ref that shares it.
                    let refsByName = Dictionary(
                        groupRefs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                    let names = groupRefs.map(\.name)
                    // A configured host with no ref resolved to it has no
                    // names to ask `states` about — see `configuredTargets`'s
                    // doc. Skipped rather than called with an empty list, so
                    // it can never be read as "asked and got nothing back,"
                    // which is what marks a host unreachable below.
                    let hasRefs = !groupRefs.isEmpty

                    // `states`, `discovered`, `servedCrews` and the probe all
                    // ride the same ControlMaster, so they run CONCURRENTLY
                    // here rather than one after another — a host does not
                    // pay for four serial round trips when it could pay for
                    // the cost of the slowest of them. `session-agent
                    // sessions`/`crews` take no argument (they list the
                    // whole host, not this rail's watched names), so a
                    // crew-less host still runs them.
                    async let statesResult: [String: SessionState]? = {
                        guard hasRefs else { return nil }
                        return await Task.detached {
                            try? statesFetch(target, names)
                        }.value
                    }()
                    async let discoveredResult: [DiscoveredSession]? = Task.detached {
                        try? discoveredFetch(target)
                    }.value
                    async let servedCrewsResult: [ServedCrew]? = Task.detached {
                        try? servedCrewsFetch(target)
                    }.value
                    async let runRegisterResult: [String: RunModelChoice]? = Task.detached {
                        try? runRegisterFetch(target)
                    }.value
                    // No gating, unlike the hostname probe below: this must
                    // catch a transition on every tick, not merely once per
                    // host, so it rides the cadence unconditionally — the
                    // same way `discoveredResult`/`servedCrewsResult` do.
                    async let desktopSessionResult: DesktopSessionReading = Task.detached {
                        desktopSessionFetch(target)
                    }.value
                    // `attempted` is distinct from `name` being nil: a target
                    // skipped this tick (already probed, or sitting out a
                    // backoff) must not be read as a fresh failure and reset
                    // its own backoff clock.
                    async let probedResult: (attempted: Bool, name: String?) = {
                        guard shouldProbe else { return (attempted: false, name: nil) }
                        let name = await Task.detached {
                            (try? probeFetch(target)).flatMap { $0.isEmpty ? nil : $0 }
                        }.value
                        return (attempted: true, name: name)
                    }()

                    let hostStates = await statesResult
                    let hostDiscovered = await discoveredResult
                    let hostServedCrews = await servedCrewsResult
                    let hostRunRegister = await runRegisterResult
                    let (attempted, probed) = await probedResult
                    let desktopReading = await desktopSessionResult

                    let translated = hostStates.map { raw -> [SessionRef: SessionState] in
                        var out: [SessionRef: SessionState] = [:]
                        for (name, state) in raw {
                            if let ref = refsByName[name] { out[ref] = state }
                        }
                        return out
                    }
                    return (target, groupRefs, translated, hostDiscovered, hostServedCrews, hostRunRegister,
                            attempted, probed, desktopReading)
                }
            }
            for await (target, groupRefs, hostStates, hostDiscovered, hostServedCrews, hostRunRegister,
                       attempted, probed, desktopReading) in group {
                // A host that answered advances the reading; a host whose
                // `states` call failed outright demotes every ref it was
                // asked about to `.unreadable` instead — see
                // `RailPoll.demotedStates` and `Mark.unreadable`'s doc. This
                // is a REPLACEMENT for the corresponding "keep it standing"
                // behaviour `RailPoll.mergedStates` documents for a merely
                // skipped host: `states/sessions` overall still degrade
                // gracefully (a discovered row's own last-good reading
                // still stands, below), but a mark that once asserted
                // `.listening` or `.busy` must not keep asserting that
                // through a total transport failure
                // (`issue_01M23WC488NVYT6T5MDZN37ZBR`). Published the
                // moment THIS host's task returns, not after every host in
                // the tick has, which is the whole point of publishing
                // inside this loop rather than after it.
                //
                // A target with no refs (`issue_01M3RGBXYGMC4D9K1CEP63R9G1`)
                // never had a `states` call made about it at all — see
                // `hasRefs` above — so it touches neither `states` nor
                // `unreachableHosts` here: there is nothing to demote, and a
                // crew-less host being unreachable is not a fact about any
                // session's mark.
                if !groupRefs.isEmpty {
                    if let hostStates {
                        states = RailPoll.mergedStates(previous: states, outcomes: [target: hostStates])
                        // `max`, so an out-of-order landing can never walk the
                        // reading backwards.
                        generation = max(generation, ticket)
                        unreachableHosts.remove(target)
                    } else {
                        states = RailPoll.mergedStates(
                            previous: states, outcomes: [target: RailPoll.demotedStates(for: groupRefs)])
                        unreachableHosts.insert(target)
                    }
                }
                // A row-level empty list (no tmux server, or genuinely no
                // sessions) is a real answer per the contract and DOES
                // update `discovered`; only a `nil` outcome — an unreachable
                // host, or a malformed top-level payload
                // `SessionAgent.discoveredSessions` could not even parse
                // into an envelope — leaves that host's rows standing.
                if let hostDiscovered {
                    discovered = RailPoll.mergedDiscovered(
                        previous: discovered, outcomes: [target: hostDiscovered])
                }
                // Same "a row-level empty list is a real answer, only `nil`
                // leaves the host's entries standing" rule as `discovered`.
                if let hostServedCrews {
                    servedCrews = RailPoll.mergedServedCrews(
                        previous: servedCrews, outcomes: [target: hostServedCrews])
                }
                runChoicesByHost[target] = hostRunRegister
                runChoices = runChoicesByHost.values.reduce(into: [:]) { $0.merge($1) { first, _ in first } }

                // Runs for EVERY target in `groups`, including a crew-less
                // configured host — "For each configured host" per
                // CQ·124's own wording — unlike the hostname probe below,
                // which only ever runs once per host.
                let (nextDesktopState, notify) = DesktopSessionTracker.apply(
                    reading: desktopReading, lastKnown: desktopSessionKnownState[target])
                desktopSessionKnownState[target] = nextDesktopState
                if notify { onDesktopSessionLoggedOut(target) }

                guard attempted else { continue }
                if let probed {
                    probedMachineNames[target] = probed
                    probeRetryAtTick[target] = nil
                } else {
                    probeRetryAtTick[target] = currentTick + Self.probeBackoffTicks
                }
            }
        }
    }

    /// The phase of a session, or nil when it has not been polled yet — which the
    /// rail reads as "no decoration yet" rather than as any particular state.
    func phase(for session: SessionRef) -> SessionState.Phase? {
        states[session]?.phase
    }

    /// The Slate badge's reading for a crew's rail row — `nil` before the
    /// first poll, same as every other unpolled reading here.
    func asksOpen(for session: SessionRef) -> SessionState.AsksOpen? {
        states[session]?.asksOpen
    }

    /// What a session's dot draws on its row.
    ///
    /// AN UNPOLLED SESSION IS `.unpolled`, NOT `.ready`, and the difference
    /// shows now that ready draws a shape of its own. A row that came up as a
    /// settled square would say "done" about a session that might be mid-turn,
    /// for the length of a poll interval, on every launch. A plain circle claims
    /// nothing and is what the rail looked like before it drew state at all.
    func mark(for session: SessionRef) -> SessionState.Mark {
        states[session]?.mark ?? .unpolled
    }

    /// Whether a session has a live agent. False for an absent or stopped one,
    /// and false before the first poll — a row starts undecorated and lights up
    /// when the first reading says it is alive.
    func isAlive(_ session: SessionRef) -> Bool {
        states[session]?.alive ?? false
    }

    /// Whether the mini has told us this session has no agent — stopped, killed,
    /// or never started — as opposed to not having been polled yet, or a
    /// transport failure. This is what a row greys on and what offers a Start.
    func isStopped(_ session: SessionRef) -> Bool {
        RailStateModel.isStopped(states[session])
    }

    /// The classification, as a pure function of a reading so it can be tested
    /// without a poll.
    ///
    /// A transport failure (`cannot reach the session`) is deliberately NOT
    /// stopped: a row must not offer to start a session that may well be running
    /// behind an ssh hiccup, and a Start on it would fail with "already has an
    /// agent".
    /// Only the mini saying, in a reading we received, that there is no agent —
    /// an `ended` phase, or the join reporting no claude process — counts. A nil
    /// reading (not polled yet) is not stopped either: the rail starts a row
    /// live-looking rather than flashing grey before the first poll lands.
    nonisolated static func isStopped(_ state: SessionState?) -> Bool {
        guard let state, !state.alive else { return false }
        if state.phase == .ended { return true }
        return (state.reason ?? "").contains("no claude process")
    }

    /// A gate reading pushed straight off the SELECTED session's own pane
    /// model — see `SessionPaneView`'s `onGateChange` and
    /// `SessionPaneModel.handleFollowedState`. `states[session]?.gate` is
    /// fed only by this model's own 4-second poll (`refresh()`), which is a
    /// SEPARATE `SessionState` reading from the one the pane's composer
    /// draws `GatePanel` off — the two can genuinely disagree with what is
    /// on screen for up to a poll interval. This is the event-driven path
    /// that closes that window for the one session actually visible: the
    /// shell calls `applyPushedGate` on every transition the pane's own
    /// follower observes, live, and `hasOpenGate` prefers this reading over
    /// the poll's whenever one has been pushed for the session being asked
    /// about. The poll loop is unchanged and keeps `states` current
    /// regardless — this is the backstop for a push that never arrives (the
    /// pane's follower has fallen back to its own polling, or the session
    /// was never selected at all), not a replacement for it.
    private var pushedGate: (session: SessionRef, open: Bool)?

    /// Records a gate transition the shell observed live for `session` —
    /// called on every change `SessionPaneView.onGateChange` reports for
    /// the currently selected session. NOT restricted to the open direction:
    /// a push of `false` is how the rail recovers immediately when a gate
    /// closes, rather than waiting out the next poll tick — see
    /// `hasOpenGate`. Takes `session` explicitly rather than assuming "the
    /// selection", so a push landing after the selection has already moved
    /// on cannot be misattributed to whatever is selected now; `hasOpenGate`
    /// only ever reads this back for the exact session it was recorded
    /// against.
    func applyPushedGate(_ open: Bool, for session: SessionRef) {
        pushedGate = (session, open)
    }

    /// Drops a stale push once the pane that was reporting it goes away — the
    /// shell calls this from the pane's teardown (a selection change, or the
    /// pane leaving screen). Harmless to skip today, since `hasOpenGate` is
    /// only ever asked about the CURRENT selection and a push for a session
    /// nobody is asking about is simply never read — but leaving a stale
    /// entry sitting in `pushedGate` is the shape a future caller could
    /// misread as live, so it is cleared rather than left to rot.
    func clearPushedGate(for session: SessionRef) {
        if pushedGate?.session == session { pushedGate = nil }
    }

    /// Whether a session is showing a gate right now — the same
    /// `SessionState.gate` field `SessionPaneView.composer` branches on to
    /// draw `GatePanel` for its own session. Feeds
    /// `RailView.suppressesNumberShortcuts`. A pushed reading for `session`
    /// (see `pushedGate`) wins over the polled one whenever there is one;
    /// otherwise this falls back to the poll-fed `states[session]?.gate`, a
    /// `nil` reading (not polled yet) reading as no gate, the same "claim
    /// nothing" default every other unpolled reading here follows.
    func hasOpenGate(_ session: SessionRef) -> Bool {
        if let pushedGate, pushedGate.session == session {
            return pushedGate.open
        }
        return RailStateModel.hasOpenGate(states[session])
    }

    /// The pure form, so the rule can be pinned by a test without a poll —
    /// the same split `isStopped`/`isStopped(_:)` already follows.
    nonisolated static func hasOpenGate(_ state: SessionState?) -> Bool {
        state?.gate != nil
    }

    /// Whether the mini reported a TMUX SESSION for `ref` on the last
    /// `session-agent sessions` poll — agent or no agent. This is a
    /// different question from `isStopped`, which only answers whether the
    /// mini found no CLAUDE PROCESS: a crew whose agent exited while its
    /// tmux session stayed alive reads `isStopped == true` even though there
    /// is still a session for "Remove and Stop" to end. Use this wherever
    /// the question is "is there anything here to stop", not "does this
    /// have an agent" — see `deck/specs/multiple-sessions-per-project`
    /// §"The model": "Deck already knows the difference."
    func hasTmuxSession(_ ref: SessionRef, hosts: [HostEntry] = [], defaultHost: String? = nil) -> Bool {
        RailStateModel.hasTmuxSession(ref, discovered: discovered, hosts: hosts, defaultHost: defaultHost)
    }

    /// The pure form of `hasTmuxSession(_:hosts:defaultHost:)`, taking the
    /// discovered set as a plain argument instead of reading `self.discovered`,
    /// so the rule can be pinned by a test without a poll — the same split
    /// `isStopped`/`isStopped(_:)` already follows. `ref.host` is a config
    /// host NAME; it is resolved to the actual `SSHTarget` the discovered set
    /// is keyed by, the same resolution every other host-aware lookup here
    /// goes through.
    nonisolated static func hasTmuxSession(
        _ ref: SessionRef, discovered: [DiscoveredSession.ID: DiscoveredSession],
        hosts: [HostEntry], defaultHost: String?
    ) -> Bool {
        // A ref whose host does not resolve to anything cannot be reported by
        // any host's poll — there is nothing to have found it on.
        guard let target = HostResolution.target(forHostName: ref.host, hosts: hosts, defaultHost: defaultHost)
        else { return false }
        return discovered[DiscoveredSession.ID(host: target, name: ref.name)] != nil
    }

    /// `names` narrowed to the ones `hasTmuxSession` reports live — the
    /// crossing of a crew's own session names with that rule, extracted so
    /// `ContentView.runningSessionCount(for:)`/`isChildRunning` can be
    /// pinned by a test rather than staying private wiring nothing exercises.
    /// `host` is the config host name every name in `names` shares by
    /// construction (a crew's own name, its pinned children, and its
    /// discovered children all inherit the crew's `host` — see
    /// `ContentView.crewSessionNames`).
    nonisolated static func runningSessionNames(
        among names: Set<String>, host: String?,
        discovered: [DiscoveredSession.ID: DiscoveredSession],
        hosts: [HostEntry], defaultHost: String?
    ) -> Set<String> {
        names.filter {
            hasTmuxSession(
                SessionRef(host: host, name: $0), discovered: discovered,
                hosts: hosts, defaultHost: defaultHost)
        }
    }
}
