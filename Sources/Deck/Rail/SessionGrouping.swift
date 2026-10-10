import Foundation

/// Groups a discovered tmux session under the crew row that owns it, by
/// the two rules `deck/specs/multiple-sessions-per-project` §"The model"
/// specifies, checked in order. PURE — no ssh, no view code — so the rules
/// are exercised as plain logic without a mini.
enum SessionGrouping {
    /// Expands a working directory's leading `~/` against the crew's HOST's
    /// home, never the laptop's — a discovered session's `path` is always an
    /// absolute path on the box the session runs on, so comparing it against
    /// a home-relative `workingDirectory` needs that host's home, and
    /// `NSHomeDirectory()` on this machine has nothing to do with that.
    /// Anything already absolute, or nil, passes through unchanged.
    ///
    /// `hostUser` is required rather than defaulted — there is no implied
    /// host left to fall back to. Callers with a real discovered session
    /// pass `session.host.user` — the actual host the row was found on —
    /// never a per-crew resolution: see `owningCrewId` below for why that
    /// circularity (resolving a crew's host to compare it against a session
    /// that hasn't been matched to a crew yet) no longer exists — phase 6b's
    /// discovered rows carry their own host, so nothing here needs to derive
    /// one first.
    static func expandedWorkingDirectory(
        _ directory: String?, hostUser: String
    ) -> String? {
        guard let directory else { return nil }
        guard directory.hasPrefix("~/") else { return directory }
        return "/Users/\(hostUser)/" + directory.dropFirst(2)
    }

    /// Rule A — name. A discovered session's name matches a crew if it
    /// equals the crew's id, or starts with `<crew-id>--`. Deck-spawned
    /// siblings use this form; a plain `contains` would wrongly match
    /// `askreconsider` against crew `ask`, which is why this is equality
    /// or a `--`-qualified prefix and nothing looser.
    ///
    /// `deck-shell-*` insurance: the verb already excludes Deck's own scratch
    /// shells server-side, but re-admitting one that slipped through would
    /// draw a throwaway shell as a sibling session, so it costs nothing to
    /// check again here.
    static func matchesByName(_ discoveredName: String, crewId: String) -> Bool {
        guard !discoveredName.hasPrefix(scratchShellPrefix) else { return false }
        return discoveredName == crewId || discoveredName.hasPrefix("\(crewId)--")
    }

    /// Rule B — path. `path` is "inside" `expandedDirectory` when it equals
    /// it exactly or starts with it plus a `/` boundary — never a bare
    /// string prefix, which would wrongly match
    /// `$HOME/Convivy/ask` against a directory of
    /// `$HOME/Convivy/as`.
    static func isPath(_ path: String, inside expandedDirectory: String) -> Bool {
        path == expandedDirectory || path.hasPrefix(expandedDirectory + "/")
    }

    /// The single crew a discovered session belongs to, or nil when it
    /// matches neither rule against a crew on the SAME host — same as an
    /// unconfigured session today.
    ///
    /// A CREW IS CONSIDERED ONLY WHEN ITS OWN RESOLVED HOST EQUALS THE
    /// SESSION'S. `session.host` is the actual `SSHTarget`
    /// `RailStateModel`'s poll found this row on — set once, at decode time,
    /// never re-derived — so filtering to `HostResolution.target(forHostName:
    /// crew.host, hosts:, defaultHost:) == session.host` is what makes "a
    /// discovered session from host A never groups under a crew on host B,
    /// even when the names or paths would otherwise match" hold (see
    /// `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// hosts"). This is also what removes the circularity phase 6a's
    /// `hostUser` parameter worked around rather than resolved: the session
    /// already knows which real machine it came from, so nothing here has
    /// to resolve a crew's host FIRST in order to ask whether it owns this
    /// row.
    ///
    /// Rule A is checked first and short-circuits: a name match never falls
    /// through to the path rule. Rule B only fires when `path` is non-nil —
    /// a discovered row whose `path` came back null cannot match it at all,
    /// there is nothing to guess from — and among every same-host crew
    /// whose (expanded) directory contains the path, the one with the
    /// LONGEST expanded directory string wins, so a nested crew's own
    /// directory claims a session before its parent does. The path rule
    /// expands `~/` against `session.host.user` — the discovered row's own
    /// host, which by construction is every candidate crew's host too.
    ///
    /// `hosts`/`defaultHost` default to `[]`/`nil`, the same defaults
    /// `HostResolution` itself uses — with no hosts configured, every crew
    /// resolves to nothing, so `sameHostCrews` is empty and no session
    /// groups under anything until an operator adds a host.
    static func owningCrewId(
        for session: DiscoveredSession, crews: [Crew],
        hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> String? {
        // A crew whose own host does not resolve to anything (see
        // `HostResolution`) cannot own a session found on a real target —
        // there is nothing for it to equal.
        let sameHostCrews = crews.filter {
            HostResolution.target(forHostName: $0.host, hosts: hosts, defaultHost: defaultHost)
                == session.host
        }
        if let byName = sameHostCrews.first(where: { matchesByName(session.name, crewId: $0.id) }) {
            return byName.id
        }
        guard let path = session.path else { return nil }
        var best: (id: String, length: Int)?
        for crew in sameHostCrews {
            guard let expanded = expandedWorkingDirectory(
                    crew.workingDirectory, hostUser: session.host.user),
                  isPath(path, inside: expanded) else { continue }
            if best == nil || expanded.count > best!.length {
                best = (crew.id, expanded.count)
            }
        }
        return best?.id
    }

    /// Every discovered session no crew's rules claim — matches neither the
    /// name rule nor the path rule against any crew, AND is not currently
    /// pinned as anyone's child, so `group` draws it nowhere. `RailView`
    /// draws this set in its own "OTHER SESSIONS" section instead, sorted
    /// alphabetically, so a session that outlived the crew row that used to
    /// own it (removed from Deck, or never matched to begin with) stays
    /// reachable and stoppable rather than running off the rail's edge. See
    /// `deck/specs/multiple-sessions-per-project` §"The model".
    ///
    /// THE PIN EXCLUSION IS WHAT MAKES ADOPTION A MOVE RATHER THAN A COPY.
    /// Pinning a session (`ThemeStore.addPinnedSession`) never changes its
    /// name or path, so the name/path rules alone would keep claiming it for
    /// nowhere and it would draw twice: once as the pinned child, once still
    /// here. `discoveredChildren(of:crewId:pinnedNames:)` already subtracts
    /// a crew's own pinned names before drawing that crew's discovered
    /// children; this does the same thing one level up, across every crew,
    /// so a name pinned to ANY crew ON THE SAME HOST AS THE DISCOVERED
    /// SESSION stops being "ungrouped" the moment it is pinned, regardless
    /// of what the name/path rules would otherwise say.
    ///
    /// THE EXCLUSION IS HOST-SCOPED, THE SAME WAY `owningCrewId` AND
    /// `adoptionTargets` ARE. A bare name collision across two boxes is
    /// ordinary (two independent checkouts both running a `worker` session),
    /// so a pin on host A must never hide a same-named, unrelated session on
    /// host B — that session belongs to no crew on ITS OWN host and would
    /// otherwise vanish from every section, reachable nowhere. Each crew's
    /// pinned names are keyed to that crew's own resolved host before being
    /// compared against a discovered session's host, exactly as
    /// `owningCrewId` resolves a crew's host before matching it against
    /// `session.host`.
    ///
    /// Re-excludes the scratch-shell prefix the same way `matchesByName`
    /// does, and for the same reason: the verb already excludes Deck's own
    /// throwaway shells server-side, but one that slipped through would
    /// otherwise surface as a phantom "other session" whenever its crew has
    /// no `workingDirectory` configured for the path rule to catch it.
    ///
    /// Also excludes `keeperSessionName`, Builder's own infrastructure session.
    static func ungrouped(
        _ sessions: [DiscoveredSession], crews: [Crew],
        hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> [DiscoveredSession] {
        var pinnedNamesByHost: [SSHTarget: Set<String>] = [:]
        for crew in crews {
            // A crew whose own host does not resolve has no bucket to pin
            // names into — it cannot be the reason a discovered session on a
            // real host reads as "already pinned."
            guard let target = HostResolution.target(
                forHostName: crew.host, hosts: hosts, defaultHost: defaultHost)
            else { continue }
            pinnedNamesByHost[target, default: []].formUnion(crew.sessions.map(\.name))
        }
        return sessions.filter {
            !$0.name.hasPrefix(scratchShellPrefix)
                && $0.name != keeperSessionName
                && !(pinnedNamesByHost[$0.host]?.contains($0.name) ?? false)
                && owningCrewId(for: $0, crews: crews, hosts: hosts, defaultHost: defaultHost) == nil
        }
    }

    /// Every discovered session, grouped by the owning crew's id. A
    /// session matching neither rule — or matching one only against a crew
    /// on a DIFFERENT host — is simply absent from the result, the same as
    /// an unconfigured session today.
    static func group(
        _ sessions: [DiscoveredSession], into crews: [Crew],
        hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> [String: [DiscoveredSession]] {
        var out: [String: [DiscoveredSession]] = [:]
        for session in sessions {
            guard let crewId = owningCrewId(
                for: session, crews: crews, hosts: hosts, defaultHost: defaultHost)
            else { continue }
            out[crewId, default: []].append(session)
        }
        return out
    }

    /// "Adopt into ▸"'s targets for an "OTHER SESSIONS" row — every crew on
    /// the session's OWN host, in `crews`' own order. A session cannot be
    /// adopted onto a different box: pinning it as a crew's child implies
    /// that crew's directory, and a directory lives on one host, the same
    /// reason `owningCrewId` filters to `sameHostCrews` before checking
    /// either rule. No further filtering — a crew already matching the
    /// session by name or path never reaches this function in practice
    /// (`owningCrewId` would have claimed the session and it would not be
    /// in "OTHER SESSIONS" to adopt from), and offering it anyway would be
    /// harmless: adoption only pins what the rules would have inferred.
    static func adoptionTargets(
        for session: DiscoveredSession, crews: [Crew],
        hosts: [HostEntry] = [], defaultHost: String? = nil
    ) -> [Crew] {
        crews.filter {
            HostResolution.target(forHostName: $0.host, hosts: hosts, defaultHost: defaultHost)
                == session.host
        }
    }

    /// A crew's discovered children, ready to draw: its own primary
    /// session and anything already pinned are excluded, and what remains
    /// is sorted alphabetically — "pinned children hold config order and
    /// discovered rows append after them alphabetically"
    /// (`deck/specs/multiple-sessions-per-project` §"The rail"). Pulled out
    /// of `RailView` so the ordering rule is exercised as plain logic:
    /// pinned rows are drawn from config in their own order beforehand, and
    /// this only decides what comes after them and in what order.
    ///
    /// PREFERS `sessionId` OVER NAME WHEREVER BOTH SIDES CARRY ONE, checked
    /// first and short-circuiting the name check. This is what a pinned
    /// name and a renamed live session no longer matching as strings used
    /// to cause: two rows for one session, because the name-only dedup
    /// could not see they were the same. `crewSessionId`/`pinnedSessionIds`
    /// default to inert values, so a caller with nothing to offer here
    /// (or a discovered row `session-agent sessions` did not tag with an
    /// id — true of every row as of this writing, since that verb does not
    /// report one) falls through to the name rule exactly as before.
    static func discoveredChildren(
        of grouped: [DiscoveredSession], crewId: String, crewSessionId: String? = nil,
        pinnedNames: Set<String>, pinnedSessionIds: Set<String> = []
    ) -> [DiscoveredSession] {
        grouped
            .filter { discovered in
                if let sessionId = discovered.sessionId {
                    // The crew's own primary session is excluded here only
                    // while it STILL answers to the crew's configured name
                    // too. That name comes from the steward's spec, so it
                    // never follows a tmux rename the way a pinned CHILD's
                    // name does (`PinnedSessionReconcile`) — a renamed
                    // primary session no longer looks like the crew's own
                    // row (`RailView`'s crew row still checks liveness by
                    // `crewId`), so excluding it here too would make the
                    // live session vanish from the rail entirely rather
                    // than draw as its own child row. See
                    // `deck/specs/multiple-sessions-per-project`'s rename
                    // half, issue_01M1KXVY8MNNNG53NFBT8SY58Z.
                    if sessionId == crewSessionId && discovered.name == crewId { return false }
                    if pinnedSessionIds.contains(sessionId) { return false }
                }
                return discovered.name != crewId && !pinnedNames.contains(discovered.name)
            }
            .sorted { $0.name < $1.name }
    }
}
