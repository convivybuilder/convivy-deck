import Foundation

/// Pure derivation for "Promote to Crew…" — an "OTHER SESSIONS" row becoming
/// its own crew row, rather than only being adoptable into someone else's.
/// See `deck/specs/multiple-sessions-per-project` §"An OTHER SESSIONS row
/// can be adopted into a crew but cannot BECOME one".
///
/// PROMOTION IS A CONFIG ACT ONLY, exactly like adoption
/// (`ContentView.adoptSession`): it does not restart the session, does not
/// create or move a directory, and does not touch the mini. The session
/// keeps running; a crew row now draws it.
enum SessionPromotion {
    enum PromotionError: Error, Equatable {
        /// The session's tmux name matches a crew already on the rail, ON
        /// THE SAME HOST — see `derive`'s doc. A name shared with a crew on
        /// a different host is not a collision at all.
        case collision(String)
    }

    /// The crew a promoted "OTHER SESSIONS" row becomes.
    ///
    /// `id` IS THE SESSION'S OWN TMUX NAME, UNCHANGED — there is no free-typed
    /// text here to derive an id from. `DiscoveredSession.decode` does NOT run
    /// this name through `validateTmuxSessionName` (it only checks
    /// non-empty), so promotion does not itself guarantee the name is
    /// well-formed. Safety comes from a layer down instead: every argv
    /// builder that turns a session name into a command
    /// (`SessionAgent.arguments`, used by `start`/`state`/`send`/etc.)
    /// independently re-validates via `validateTmuxSessionName` regardless
    /// of where the name came from, so a malformed name would fail closed
    /// on the next action against the promoted crew rather than reach ssh
    /// argv unvalidated.
    ///
    /// `workingDirectory` carries `session.path` through UNCHANGED, nil
    /// included. Per the `session-agent-api` contract, a row whose record
    /// could not be corroborated reports `name` only — `path` is
    /// legitimately absent — and a crew with no `workingDirectory` is legal
    /// (`deck/specs/multiple-sessions-per-project` §"The model": the name
    /// rule still groups its children). Refusing to promote a nil-path
    /// session would leave exactly the recovery gap this feature exists to
    /// close.
    ///
    /// `displayName` is the session's own name, drawn as-is — the same
    /// convention `ContentView.adoptSession` and every discovered-child row
    /// already follow ("no display name of its own"), with no humanizing or
    /// capitalizing step.
    ///
    /// `command` is left `nil` — the configured default
    /// (`Crew.defaultLaunchCommand`), resolved through `Crew.launchCommand`
    /// the same way every other crew's is, rather than baking today's
    /// default string into this row.
    ///
    /// `existingRefs` IS `Set<SessionRef>` — `existingRefs(for:)` above — NOT A BARE
    /// SET OF IDS. Every Builder install has a crew named `steward`, and one
    /// operator's several machines each run one, so a name match against a
    /// crew on a DIFFERENT host is not a collision at all: refuses only when
    /// the session's own resolved host (below) and name together already
    /// match a rail entry. Uses the identical reverse lookup `host` resolves
    /// through, so a promoted crew's `.host` and the ref this collision check
    /// tests can never disagree about which host the session is actually on.
    /// The rail's crews as refs on the host each one actually resolves to
    /// (`CrewMerge.crewHostKey`), for `derive`'s `existingRefs`. A crew
    /// still naming a host removed from Settings runs on the default host,
    /// so its stored `ref` would miss a same-named session there and let
    /// Promote create a second row for it.
    static func existingRefs(
        for crews: [Crew], hosts: [HostEntry], defaultHost: String?
    ) -> Set<SessionRef> {
        Set(crews.map {
            SessionRef(host: CrewMerge.crewHostKey(for: $0, hosts: hosts, defaultHost: defaultHost),
                       name: $0.id)
        })
    }

    static func derive(
        _ session: DiscoveredSession, existingRefs: Set<SessionRef>, hosts: [HostEntry]
    ) throws -> Crew {
        let host = HostResolution.hostName(for: session.host, hosts: hosts)
        guard !existingRefs.contains(SessionRef(host: host, name: session.name)) else {
            throw PromotionError.collision(session.name)
        }
        return Crew(id: session.name, displayName: session.name, workingDirectory: session.path, host: host)
    }
}
