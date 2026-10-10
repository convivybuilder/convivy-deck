import Foundation

/// The crossing of a crew's — or one pinned child's — session name(s) with
/// `RailStateModel.runningSessionNames`, for the Remove confirms' "is there
/// anything here to stop" question. Pulled out of `ContentView` as a plain
/// struct with no `View` conformance and no `@EnvironmentObject`, so it can
/// be constructed and asserted on directly in a test — seeded with a `Crew`
/// and a discovered session, the same way `RunningSessionNamesTests` and
/// `HasTmuxSessionTests` already exercise the two layers underneath it —
/// rather than only through `ContentView`'s environment-dependent `crews`
/// and `configuration`, which only resolve inside a live SwiftUI render
/// pass.
///
/// Each Remove confirm needs two things from this crossing — whether
/// "Remove and Stop" appears, and what the message says — and both come
/// from the same running-count-or-flag. `removeCrewAlertShape(for:)` and
/// `removeChildAlertShape(for:_:)` compute both together as one
/// `RemoveAlertShape`, so `ContentView` has nothing left to derive: it
/// reads `.showRemoveAndStopButton` for the button and `.message` for the
/// text, rather than recomputing a `> 0` or mapping a count itself. See
/// `deck/specs/multiple-sessions-per-project` §"The model".
struct RailRunningSessions {
    let crews: [Crew]
    let discovered: [DiscoveredSession.ID: DiscoveredSession]
    let hosts: [HostEntry]
    let defaultHost: String?

    /// Every session name `crew` owns — itself, its pinned children, and its
    /// discovered children — regardless of whether it is currently live.
    /// `ContentView.removeCrewAndStopSessions` reads this too, through
    /// `ContentView.crewSessionNames(for:)`, which forwards here.
    func crewSessionNames(for crew: Crew) -> Set<String> {
        var names = Set([crew.id])
        names.formUnion(crew.sessions.map(\.name))
        let groups = SessionGrouping.group(
            Array(discovered.values), into: crews, hosts: hosts, defaultHost: defaultHost)
        names.formUnion((groups[crew.id] ?? []).filter { $0.name != crew.id }.map(\.name))
        return names
    }

    /// Every RUNNING session a crew owns, for the Remove confirm's
    /// running-sessions sentence. "Running" means the mini reported a tmux
    /// session for it, agent or no agent — `RailStateModel.runningSessionNames`,
    /// not `isStopped`. `isStopped` only tells us the mini found no claude
    /// process, so a crew whose agent exited while its tmux session stayed
    /// alive would otherwise count as zero running, tell the user nothing is
    /// running when a session is, and never offer "Remove and Stop".
    func runningSessionCount(for crew: Crew) -> Int {
        RailStateModel.runningSessionNames(
            among: crewSessionNames(for: crew), host: crew.host,
            discovered: discovered, hosts: hosts, defaultHost: defaultHost
        ).count
    }

    /// Whether a pinned child currently has a tmux session, for the child
    /// Remove confirm's "Remove and Stop" gate — the single-session
    /// counterpart to `runningSessionCount(for:)`, reading the identical
    /// rule.
    func isChildRunning(_ crew: Crew, _ session: PinnedSession) -> Bool {
        !RailStateModel.runningSessionNames(
            among: [session.name], host: crew.host,
            discovered: discovered, hosts: hosts, defaultHost: defaultHost
        ).isEmpty
    }

    /// Everything a Remove confirm renders, from one running-count-or-flag:
    /// whether "Remove and Stop" appears, and the message's wording. A crew
    /// or child with nothing running gets no button and the plain message;
    /// anything running gets both.
    func removeCrewAlertShape(for crew: Crew) -> RemoveAlertShape {
        let count = runningSessionCount(for: crew)
        return RemoveAlertShape(
            showRemoveAndStopButton: count > 0,
            message: ContentView.removeCrewMessage(runningSessionCount: count,
                                                    hostLabel: hostLabel(for: crew)))
    }

    /// The pinned-child mirror of `removeCrewAlertShape(for:)`.
    func removeChildAlertShape(for crew: Crew, _ session: PinnedSession) -> RemoveAlertShape {
        let isRunning = isChildRunning(crew, session)
        return RemoveAlertShape(
            showRemoveAndStopButton: isRunning,
            message: ContentView.removeChildMessage(isRunning: isRunning,
                                                     hostLabel: hostLabel(for: crew)))
    }

    /// The name of the host `crew`'s folder actually lives on — what the
    /// Remove confirm names in place of Convivy's own machine
    /// (`deck/specs/running-deck-as-someone-else`). `nil` when the crew's
    /// `host` (or the configured default) resolves to nothing, the same
    /// "unresolved resolves to nothing" case `HostResolution` gives
    /// everywhere else — the confirm drops the location clause rather than
    /// naming a host that is not really there.
    private func hostLabel(for crew: Crew) -> String? {
        guard let target = HostResolution.target(
            forHostName: crew.host, hosts: hosts, defaultHost: defaultHost) else { return nil }
        return HostResolution.hostName(for: target, hosts: hosts)
    }
}

/// A Remove confirm's full shape — everything `ContentView` needs to render
/// one of the two alerts — so the view has a single value to read rather
/// than a boolean and a count/flag it would otherwise derive independently.
struct RemoveAlertShape {
    let showRemoveAndStopButton: Bool
    let message: String
}
