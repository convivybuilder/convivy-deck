import Foundation

/// Merges the steward's served crew specs (`ServedCrew`, from
/// `session-agent crews`) into Deck's own configured rail rows (`Crew`, from
/// `theme.json`). A crew is made by the steward's `new-crew` skill rather
/// than configured in Deck, so most crews reach the rail as a spec with no
/// local config at all; this is what lets one draw as a first-class row with
/// no Settings edit first. PURE, so the merge rule is exercised as plain
/// logic without a poll — see `platform/contracts/session-agent-api`'s
/// `crews` section and the epic it serves,
/// `issue_01M1S58ZXTV4FX0V77JVP4FWNR`.
///
/// SAYS "RATHER THAN CONFIGURED", NOT "ONE PATH". This line claimed crew
/// creation had a single path until the claim was swept out of the tree;
/// promoting a discovered session is a second one, and it lands on the
/// configured side of this very merge, as a configured row with no spec.
/// What the sentence is actually for is why the spec-only case is the
/// common one, and that survives without the exclusivity.
enum CrewMerge {
    /// A served crew's own tmux session id, scoped to the config host NAME
    /// it was reported from. `sessionId` alone is tmux's per-server counter
    /// (`$<digits>`), so two different real machines can report the exact
    /// same raw id for two entirely unrelated sessions — keying on the pair
    /// is what stops that coincidence from merging them into one row.
    private struct SessionIdKey: Hashable {
        var host: String?
        var sessionId: String
    }

    /// The host key `merge` compares a configured crew and a served crew
    /// by: a config host NAME, or `nil` for "the implied default" — never a
    /// resolved `SSHTarget`. `served.host` is always a real target (the
    /// actual box the poll ran against), so it is reverse-resolved to a
    /// NAME via `HostResolution.hostName(for:hosts:)` first — the identical
    /// lookup `asCrew`/`applying` use to fill `Crew.host`. `crew.host ??
    /// defaultHost` mirrors what `ThemeConfiguration.parseRail` would fill
    /// in for a row naming no host of its own, so a fresh, not-yet-persisted
    /// crew (built this same render, before any save) compares the same way
    /// a saved one does.
    ///
    /// COMPARING NAMES RATHER THAN RESOLVED TARGETS is what keeps this
    /// working with `hosts: []` — the state `Settings > Hosts` starts in and
    /// every `SessionRoster` test fixture uses. Forward-resolving a crew's
    /// host through `HostResolution.target(forHostName:hosts:defaultHost:)`
    /// answers `nil` for EVERY crew the moment `hosts` is empty, and a served
    /// crew's own `host` is never `nil` — so target comparison could never
    /// match anything at all in that state, not even two rows that plainly
    /// belong together. Two names, both `nil`, compare equal exactly as they
    /// should.
    private static func hostKey(for served: ServedCrew, hosts: [HostEntry]) -> String? {
        HostResolution.hostName(for: served.host, hosts: hosts)
    }

    /// The configured side's host name, normalized the way every action on
    /// the row resolves it. A crew naming a host that is no longer in
    /// `hosts` (what `ThemeStore.removeHost` leaves behind) attaches, starts
    /// and polls on the default host, so it matches the default host's spec
    /// too; comparing the stale name as written would stop it matching
    /// anything, and `SessionRoster.applied(to:)` would then freeze the
    /// spec's fill into local config. When nothing resolves (including
    /// `hosts: []`) the name is compared as written, as above.
    static func crewHostKey(for crew: Crew, hosts: [HostEntry], defaultHost: String?) -> String? {
        let name = crew.host ?? defaultHost
        guard let target = HostResolution.target(forHostName: crew.host, hosts: hosts,
                                                 defaultHost: defaultHost) else { return name }
        return HostResolution.hostName(for: target, hosts: hosts)
    }

    /// A spec row and a configured row describing the same crew draw as ONE
    /// row, ON THE SAME HOST. Matched by `sessionId` first — the field that
    /// survives a crew whose configured `id` and the spec's own `id` have
    /// drifted apart — then by `id`/`crewId`, the common case, since both
    /// name spaces are the crew's tmux session name today.
    ///
    /// A spec with no configured counterpart still draws a row — this is
    /// how a crew made through `new-crew`, with no local config at all,
    /// reaches the rail (`placard`, created 2026-09-05). A configured row
    /// with no matching spec (a crew from before this feature, or a
    /// laptop-only entry the steward never wrote a spec for) draws
    /// unchanged.
    ///
    /// `hosts`/`defaultHost` scope every match to `hostKey`'s host-NAME
    /// comparison, above. Every Builder install has a crew named `steward`,
    /// and one operator's several machines each run one, so before this,
    /// two hosts serving a `steward` spec collapsed into whichever one
    /// happened to land first in `servedByCrewId` — an array-order-dependent
    /// pick that could just as easily fill MACSTUDIO's configured row from
    /// MACMINI's spec.
    ///
    /// THE SPEC FILLS A FIELD ONLY WHEN THE CONFIGURED ROW LEFT IT UNSET —
    /// it never overwrites a value Settings actually set. `displayName`
    /// counts as unset when it still equals the row's own `id`, the same
    /// fallback `ThemeConfiguration.parseRail` writes for a row with no
    /// `name` of its own. `workingDirectory`/`project`/`bead` count as
    /// unset when `nil`; `documents`/`repos` count as unset when empty, the
    /// same rule spelled for a list. `sessionId` is the one field a
    /// configured row can never set locally, so the spec's value always
    /// applies once matched.
    static func merge(
        configured: [Crew], served: [ServedCrew], hosts: [HostEntry], defaultHost: String?
    ) -> [Crew] {
        var result: [Crew] = []
        var matched = Set<ServedCrew.ID>()
        let servedBySessionId = Dictionary(
            served.compactMap { crew in
                crew.sessionId.map { (SessionIdKey(host: hostKey(for: crew, hosts: hosts), sessionId: $0), crew) }
            },
            uniquingKeysWith: { first, _ in first })
        let servedByCrewId = Dictionary(
            served.map { (SessionRef(host: hostKey(for: $0, hosts: hosts), name: $0.crewId), $0) },
            uniquingKeysWith: { first, _ in first })

        for crew in configured {
            let crewHostKey = crewHostKey(for: crew, hosts: hosts, defaultHost: defaultHost)
            let match = crew.sessionId.flatMap { servedBySessionId[SessionIdKey(host: crewHostKey, sessionId: $0)] }
                ?? servedByCrewId[SessionRef(host: crewHostKey, name: crew.id)]
            guard let match else {
                result.append(crew)
                continue
            }
            matched.insert(match.id)
            result.append(applying(match, to: crew, hosts: hosts))
        }
        for crew in served where !matched.contains(crew.id) {
            result.append(asCrew(crew, hosts: hosts))
        }
        return result
    }

    /// A served-only crew, drawn with no configured counterpart at all — ON
    /// THE HOST IT WAS ACTUALLY SERVED FROM, reverse-resolved via
    /// `HostResolution.hostName(for:hosts:)` against the real target the
    /// poll found it on (`served.host`), never `served.specHost` — the same
    /// "the actual target, not the spec's self-reported name" rule
    /// `ServedCrew.host`'s own doc states. Without this, a served-only crew
    /// drew with no `host` of its own, so two hosts serving the same id both
    /// resolved to the same (default) host and neither attached, started,
    /// stopped or polled against the machine it actually runs on.
    private static func asCrew(_ served: ServedCrew, hosts: [HostEntry]) -> Crew {
        Crew(id: served.crewId,
             displayName: served.displayName ?? served.crewId,
             workingDirectory: served.workingDirectory,
             sessions: served.sessions.map(asPinnedSession),
             host: HostResolution.hostName(for: served.host, hosts: hosts),
             project: served.project,
             bead: served.bead,
             repos: served.resolvedRepos,
             sessionId: served.sessionId,
             shape: served.shape,
             documents: served.documents)
    }

    /// A configured crew, with a matched spec's fields filling whatever it
    /// left unset. `host` follows the same fill rule — a configured row
    /// whose own host is already set (the ordinary case: `parseRail` fills
    /// it from `defaultHost` at load time) is never overwritten.
    private static func applying(_ served: ServedCrew, to crew: Crew, hosts: [HostEntry]) -> Crew {
        var merged = crew
        if merged.displayName == merged.id, let displayName = served.displayName {
            merged.displayName = displayName
        }
        merged.workingDirectory = merged.workingDirectory ?? served.workingDirectory
        merged.host = merged.host ?? HostResolution.hostName(for: served.host, hosts: hosts)
        merged.project = merged.project ?? served.project
        merged.bead = merged.bead ?? served.bead
        merged.sessionId = merged.sessionId ?? served.sessionId
        merged.shape = merged.shape ?? served.shape
        // `documents` and `repos` are `[String]`, not optional, so "unset"
        // is empty — the same `nil`-means-unset rule `project`/`bead`
        // follow, just spelled for an array rather than an optional. See
        // `Crew.repos`'s doc for why this is a deliberate choice for a
        // list-valued field rather than an oversight.
        merged.documents = merged.documents.isEmpty ? served.documents : merged.documents
        merged.repos = merged.repos.isEmpty ? served.resolvedRepos : merged.repos
        merged.sessions = mergedChildren(configured: merged.sessions, served: served.sessions)
        return merged
    }

    /// The same match-then-fill rule as `merge`, one level down: a spec's
    /// child and a configured pinned child for the same crew are one row,
    /// matched by `sessionId` first, `name` second.
    private static func mergedChildren(
        configured: [PinnedSession], served: [ServedCrew.Child]
    ) -> [PinnedSession] {
        var result: [PinnedSession] = []
        var matchedNames = Set<String>()
        let servedBySessionId = Dictionary(
            served.compactMap { child in child.sessionId.map { ($0, child) } },
            uniquingKeysWith: { first, _ in first })
        let servedByName = Dictionary(
            served.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        for child in configured {
            let match = child.sessionId.flatMap { servedBySessionId[$0] } ?? servedByName[child.name]
            guard let match else {
                result.append(child)
                continue
            }
            matchedNames.insert(match.name)
            var merged = child
            if merged.displayName == merged.name, let displayName = match.displayName {
                merged.displayName = displayName
            }
            merged.sessionId = merged.sessionId ?? match.sessionId
            result.append(merged)
        }
        for child in served where !matchedNames.contains(child.name) {
            result.append(asPinnedSession(child))
        }
        return result
    }

    private static func asPinnedSession(_ served: ServedCrew.Child) -> PinnedSession {
        PinnedSession(name: served.name, displayName: served.displayName ?? served.name,
                     sessionId: served.sessionId)
    }

    /// The served spec `merge` would match `crew` against, by the identical
    /// sessionId-then-crewId rule — exposed so a caller that persists a crew
    /// AFTER merging (`SessionRoster.applied(to:)`) can undo the fill
    /// relative to the same match, via `sparse` below.
    ///
    /// HOST-SCOPED THE SAME WAY `merge` IS: `served` is filtered to
    /// the crew's own resolved host (`crewHostKey`) before either lookup runs, so a
    /// crew on one host can never match the other host's spec of the same
    /// sessionId or crewId. This is unrelated to `RosterEntry` still being
    /// bare-id keyed (see its `ref` doc comment) — that governs which ROW a
    /// Settings edit lands on and stays this epic's own part 3
    /// (issue_01M3NQRR53ZT351DWT7KYNZXKE); this governs which SPEC a given
    /// row diffs against once found, and nothing about that needs
    /// `RosterEntry` to change.
    static func match(_ crew: Crew, in served: [ServedCrew], hosts: [HostEntry], defaultHost: String?) -> ServedCrew? {
        let crewHostKey = crewHostKey(for: crew, hosts: hosts, defaultHost: defaultHost)
        let served = served.filter { hostKey(for: $0, hosts: hosts) == crewHostKey }
        if let sessionId = crew.sessionId, let hit = served.first(where: { $0.sessionId == sessionId }) {
            return hit
        }
        return served.first(where: { $0.crewId == crew.id })
    }

    /// The inverse of `applying`: strips every field of `crew` back to unset
    /// wherever it agrees with what `served` would fill in, so persisting the
    /// result cannot freeze a spec's own value into local config — see
    /// `SessionRoster.applied(to:)`'s doc for why a frozen field stops
    /// receiving every later change the spec makes (a rename, a new
    /// `sessionId`, a moved directory).
    ///
    /// A FIELD SURVIVES ONLY WHEN IT DIFFERS FROM WHAT `served` OWNS. That
    /// covers a value `applying` filled in (identical to the spec by
    /// construction, so it strips cleanly) and a coincidental local value
    /// that happens to equal the spec's own (stripping it is harmless: the
    /// next merge fills back in the identical value). Anything genuinely
    /// overridden — including a field the operator just edited — differs
    /// from the spec and survives untouched.
    ///
    /// `hosts` resolves `served.host` back to the config NAME `asCrew`/
    /// `applying` would have filled `out.host` with — the same reverse
    /// lookup, so a served-only crew's `host` strips back to unset exactly
    /// like every other field `merge` fills, rather than permanently
    /// reading as "edited" the moment any real host is configured. Unlike
    /// `match`, this is safe with `hosts: []`: the lookup simply answers
    /// `nil`, which is `out.host`'s own value whenever no real host was
    /// filled in the first place.
    static func sparse(_ crew: Crew, relativeTo served: ServedCrew, hosts: [HostEntry]) -> Crew {
        var out = crew
        if let displayName = served.displayName, out.displayName == displayName {
            out.displayName = out.id
        }
        if out.workingDirectory == served.workingDirectory { out.workingDirectory = nil }
        if out.host == HostResolution.hostName(for: served.host, hosts: hosts) { out.host = nil }
        if out.project == served.project { out.project = nil }
        if out.bead == served.bead { out.bead = nil }
        if out.sessionId == served.sessionId { out.sessionId = nil }
        if out.shape == served.shape { out.shape = nil }
        if out.documents == served.documents { out.documents = [] }
        if out.repos == served.resolvedRepos { out.repos = [] }
        if out.sessions == served.sessions.map(asPinnedSession) { out.sessions = [] }
        return out
    }

    /// A crew with every field at its "unset" value — what a served-only
    /// row's own edit reduces to via `sparse` when nothing about it was
    /// actually changed. `SessionRoster.applied(to:)` compares against this
    /// to decide whether to omit the row from `railSessions` entirely,
    /// rather than writing out a row that says nothing.
    static func isUnedited(_ crew: Crew) -> Bool {
        crew == Crew(id: crew.id, displayName: crew.id)
    }
}
