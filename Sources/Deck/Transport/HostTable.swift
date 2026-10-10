import Foundation

/// One named machine a crew can run on. See
/// `deck/specs/multiple-sessions-per-project` §"Crews on different boxes".
///
/// Named and referenced by a crew's `host` field rather than written inline
/// on each row, because several crews move between boxes together — the
/// operator's call, recorded in the phase-6a brief.
struct HostEntry: Equatable, Hashable {
    var name: String
    var user: String
    var address: String

    /// This host's own crews root, overriding the global
    /// `ThemeConfiguration.crewsRoot` fallback for a crew landing here — see
    /// `deck/specs/multiple-sessions-per-project` §"The crews root is per
    /// machine": "two boxes with different layouts is the ordinary case."
    /// `nil` means "use the global default."
    ///
    /// Editable in Settings › Hosts, alongside name, user and address — see
    /// `HostsSettingsView`. `ThemeStore.updateHost` is the one place a
    /// running app writes this field; `theme.json` remains the storage, not
    /// the interface, the same discipline `Crew.parent` follows since the
    /// "Nest under" menu replaced hand-editing it.
    ///
    /// SEEDED FROM THE HOST ITSELF when a host is first added
    /// (`HostsSettingsView.addHost`, `SessionAgent.crewsRoot`), then left
    /// alone — nothing re-polls it. A value read once and then STALE is
    /// accepted rather than solved: if the host's own `CREWS_ROOT` moves
    /// afterward, a create under the old value is simply refused, and the
    /// refusal names the real root (`--create-dir path must be under
    /// <root>`), so a stale value here fails loud rather than quiet. See
    /// `deck/specs/running-deck-as-someone-else`.
    var crewsRoot: String? = nil

    /// The recovery runbook for this host (CQ·124) — a KB id or an
    /// `https://` URL, validated by `RunbookLink.parse` on every write and
    /// every open. `nil` means no runbook has been set yet, in which case
    /// the logged-out alert for this host opens Deck's own Settings › Hosts
    /// row for it instead.
    ///
    /// Editable in Settings › Hosts, the same place `crewsRoot` is —
    /// `theme.json` is the storage, never the interface, per the operator's call on
    /// `crewsRoot` above.
    var runbookLink: String? = nil
}

/// Resolves a crew's `host` field, and a bare session name, to the
/// `SSHTarget` its session-agent calls should use.
///
/// PURE — no ssh, no view code, the same discipline `SessionGrouping`
/// follows — so a hand-edited `theme.json` naming a host that no longer
/// exists is a state a test can pin rather than a hypothetical.
enum HostResolution {
    /// Resolves one host name against the table, falling through to the
    /// configured default when the name is absent or matches nothing, and
    /// to `nil` when the default itself resolves to nothing either.
    ///
    /// AN UNKNOWN HOST NAME RESOLVES TO THE DEFAULT RATHER THAN FAILING —
    /// a hand-edited config naming a host that no longer exists should
    /// degrade to whatever the operator has actually configured as default,
    /// not take the row out of service. This is a deliberate choice, not an
    /// oversight: see `deck/specs/multiple-sessions-per-project` §"Crews on
    /// different boxes".
    ///
    /// THERE IS NO FURTHER FALLBACK ONE LEVEL UP. An absent or unmatched
    /// `defaultHost` used to resolve to `SSHTarget.mini`, the one host that
    /// was always implied; that fallback cannot outlive the constant it
    /// falls back to, so it is gone — see
    /// `deck/specs/running-deck-as-someone-else`. With `hosts` empty, which
    /// is Settings › Hosts' own empty state until an operator adds an entry
    /// there, every name resolves to `nil` regardless of `hostName` or
    /// `defaultHost`: an unresolved host resolves to NOTHING rather than to
    /// a default, and every caller here treats that as "this action is
    /// unavailable," not as a reason to invent a host.
    static func target(
        forHostName hostName: String?,
        hosts: [HostEntry],
        defaultHost: String?
    ) -> SSHTarget? {
        guard let entry = resolvedEntry(forHostName: hostName, hosts: hosts, defaultHost: defaultHost) else {
            return nil
        }
        return SSHTarget(user: entry.user, host: entry.address)
    }

    /// The `HostEntry` a host name resolves to, or nil when neither the name
    /// nor the configured default match anything — the same fallback chain
    /// `target(forHostName:hosts:defaultHost:)` follows, factored out so
    /// `crewsRoot(forHostName:...)` below can share it: the two must never
    /// resolve a given crew to different HOSTS, only (potentially) different
    /// roots on the same one.
    private static func resolvedEntry(
        forHostName hostName: String?, hosts: [HostEntry], defaultHost: String?
    ) -> HostEntry? {
        if let hostName, let match = hosts.first(where: { $0.name == hostName }) {
            return match
        }
        return defaultHost.flatMap { name in hosts.first { $0.name == name } }
    }

    /// The crews root a crew's `host` resolves to: the host's own
    /// `crewsRoot` when it has one, else the global fallback the caller
    /// passes in (`ThemeConfiguration.crewsRoot`) — see
    /// `deck/specs/multiple-sessions-per-project` §"The crews root is per
    /// machine". Follows `target(forHostName:hosts:defaultHost:)`'s own
    /// "an unknown host name resolves to the default" fallback via the same
    /// `resolvedEntry`, so a crew's directory prefill and its ssh target
    /// always agree about which host they are describing.
    static func crewsRoot(
        forHostName hostName: String?,
        hosts: [HostEntry],
        defaultHost: String?,
        globalCrewsRoot: String
    ) -> String {
        resolvedEntry(forHostName: hostName, hosts: hosts, defaultHost: defaultHost)?.crewsRoot
            ?? globalCrewsRoot
    }

    /// The target a session resolves to: the crew or catalog row that owns
    /// it, by `SessionGrouping`'s NAME rule only — a session's owner is
    /// knowable from its name alone, the same way a Deck-spawned pinned
    /// sibling's is (`<crew-id>--child`) — then that row's `host`, then the
    /// default.
    ///
    /// CREWS ARE CHECKED BEFORE THE CATALOG, deliberately: a rail row and a
    /// catalog row are not expected to share an id, but if config ever hand-
    /// edits its way into that, the pinned row is the one actually drawn on
    /// the rail and is the more specific answer.
    ///
    /// THE PATH RULE IS DELIBERATELY NOT CHECKED HERE — still, but no longer
    /// for the circularity phase 6a flagged. That gap is closed:
    /// `SessionGrouping.owningCrewId` resolves a DISCOVERED session's owning
    /// crew (and therefore its host) using the row's OWN `host` — the actual
    /// target `RailStateModel`'s poll found it on, carried on
    /// `DiscoveredSession` rather than derived — so the path rule never
    /// needs this function's output as an input any more. What remains is
    /// narrower: this function takes a bare session NAME with no
    /// `DiscoveredSession` behind it at all, so there is no `path` here to
    /// compare in the first place. A caller holding only a name resolves to
    /// the default host, which is the same answer a name-rule-only lookup
    /// always gave.
    static func target(
        forSession session: String,
        crews: [Crew],
        catalog: [LaunchableSession] = [],
        hosts: [HostEntry],
        defaultHost: String?
    ) -> SSHTarget? {
        let hostName = crews.first { SessionGrouping.matchesByName(session, crewId: $0.id) }?.host
            ?? catalog.first { SessionGrouping.matchesByName(session, crewId: $0.id) }?.host
        return target(forHostName: hostName, hosts: hosts, defaultHost: defaultHost)
    }

    /// The reverse of `target(forHostName:hosts:defaultHost:)`: the config
    /// host NAME whose entry resolves to `target`, or nil when none does.
    ///
    /// FOR A DISCOVERED SESSION NO CREW OWNS. `SessionGrouping` attributes
    /// an owned discovered child to its crew's own `host` field directly —
    /// no resolution needed, since the crew already names it. An
    /// "OTHER SESSIONS" row has no crew to inherit a name from, only the
    /// actual `SSHTarget` `RailStateModel`'s poll found it on
    /// (`DiscoveredSession.host`), so this is what lets it get a
    /// `SessionRef` at all. With `hosts` empty this always answers nil,
    /// which is the correct "the implied default" token
    /// `SessionRef.host == nil` already carries everywhere else.
    ///
    /// Ambiguous only when two entries share both a user and an address,
    /// which is outside this phase's scope (see
    /// `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// hosts": the proof case always names two hosts with different
    /// accounts); the first match wins.
    ///
    /// TWO ENTRIES SHARING A NAME CANNOT REACH THIS FUNCTION —
    /// `ThemeConfiguration.parseHosts` enforces `HostEntry.name` uniqueness
    /// at parse time, dropping the later colliding row. That guarantee is
    /// what keeps this reverse lookup and `target(forHostName:)`'s forward
    /// one in agreement: an "OTHER SESSIONS" row's `SessionRef` is built by
    /// this function, and a Stop button resolves the target to act on by
    /// running `target(forHostName:)` on the name this function returned.
    /// Before the uniqueness check existed, two entries sharing a name but
    /// differing in `(user, address)` could round-trip a discovered session
    /// through the OTHER entry's target — a session found on `bob@host-b`
    /// resolving `hostName(for:)` to `"h"`, then `target(forHostName: "h")`
    /// answering `alice@host-a` — sending a `kill: true` Stop to the wrong
    /// box. A `[HostEntry]` built by hand with duplicate names (as a test
    /// might) can still exercise the old first-match behaviour here; it is
    /// only unreachable through parsed config.
    static func hostName(for target: SSHTarget, hosts: [HostEntry]) -> String? {
        hosts.first { SSHTarget(user: $0.user, host: $0.address) == target }?.name
    }
}
