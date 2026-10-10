import Foundation

/// Resolves the `user@machine` label an operator reads for a host — see
/// `deck/specs/multiple-sessions-per-project` §"Crews on different hosts":
/// "the account alone does not tell an operator which box they are looking
/// at, and the machine alone cannot distinguish the two." PURE — no ssh, no
/// view code, the same discipline `HostResolution` follows — so every
/// fallback and the rejection case are exercised as plain logic.
enum HostDisplay {
    /// A DNS label's own length ceiling, which is also generous for a
    /// config-typed host name or a hostname `hostname -s` would ever
    /// actually report.
    static let maximumMachineLength = 63

    /// A conservative charset, the same discipline
    /// `platform/contracts/session-agent-api` applies to `paneVersion`: a
    /// machine name is a string from the far side that Deck renders, so
    /// anything outside this is REPLACED with a placeholder rather than
    /// truncated — a truncated string is a claim about what the box
    /// reported, and a placeholder is not.
    private static let allowedMachineCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Drawn when nothing in the fallback chain — probed, config name,
    /// address — survives the charset gate. Distinct from any real machine
    /// name or address by construction (no real hostname or IPv4/IPv6
    /// address is bracketed like this).
    static let placeholder = "[unknown]"

    /// The machine half of the label: the probed `hostname -s` answer when
    /// it landed and passes the charset gate, else the config host NAME,
    /// else the address, else `placeholder`. Each candidate is checked on
    /// its own — a probed name that fails the gate does not disqualify a
    /// good config name behind it.
    static func machineLabel(probed: String?, configName: String?, address: String?) -> String {
        for candidate in [probed, configName, address] {
            if let candidate, let sanitized = sanitizedMachineName(candidate) {
                return sanitized
            }
        }
        return placeholder
    }

    private static func sanitizedMachineName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumMachineLength,
              trimmed.unicodeScalars.allSatisfy(allowedMachineCharacters.contains)
        else { return nil }
        return trimmed
    }

    /// The full label an operator reads: `user@machine`. `user` is always a
    /// validated `SSHTarget.user`/`HostEntry.user`, never itself subject to
    /// the machine-name fallback chain — it comes from config or the probe
    /// target, not from a remote answer.
    static func label(user: String, probed: String?, configName: String?, address: String?) -> String {
        "\(user)@\(machineLabel(probed: probed, configName: configName, address: address))"
    }

    /// The same label, resolved for a real `SSHTarget` against the config's
    /// `hosts` table — `configName` recovered via
    /// `HostResolution.hostName(for:hosts:)`, so a caller holding only the
    /// resolved target (not the original host NAME) still gets the right
    /// fallback chain.
    static func label(for target: SSHTarget, hosts: [HostEntry], probed: (SSHTarget) -> String?) -> String {
        label(user: target.user, probed: probed(target),
              configName: HostResolution.hostName(for: target, hosts: hosts), address: target.host)
    }

    /// Every display name drawn by more than one crew in `crews` — what
    /// `crewLabel`'s `duplicateNames` argument is built from. Pulled out as
    /// its own pure function so the "which names collide" question is
    /// exercised as plain logic, the same discipline every other rule here
    /// follows, rather than only inside a view's private computed property.
    static func duplicateDisplayNames(among crews: [Crew]) -> Set<String> {
        duplicateDisplayNames(among: crews.map(\.displayName))
    }

    /// The same rule, for a caller that already has display names rather than
    /// `Crew`s — Settings › Sessions' roster mixes pinned crews and catalog
    /// rows, neither of which is a `Crew`.
    ///
    /// Returns NORMALIZED keys (`normalizedDisplayNameKey`), not the raw
    /// names passed in — macstudio's "Steward" and a promoted macmini "steward"
    /// read as the same name to an operator, so a caller checking membership
    /// against this set must normalize the name it is testing the same way
    /// (`crewLabel` and `SessionsSettingsView.duplicateEntryNames` both do).
    static func duplicateDisplayNames(among displayNames: [String]) -> Set<String> {
        Set(Dictionary(grouping: displayNames, by: normalizedDisplayNameKey).filter { $0.value.count > 1 }.keys)
    }

    /// Folds a display name to the key two differently-cased or
    /// differently-accented spellings of the same name share: case and
    /// diacritics folded, surrounding whitespace trimmed. "Steward" and
    /// "steward" fold to the same key; "Steward" and "Stewart" do not.
    static func normalizedDisplayNameKey(_ displayName: String) -> String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The host name Settings › Sessions draws beside a duplicated name: the
    /// host the crew actually runs on (`CrewMerge.crewHostKey`), so a crew
    /// still naming a host removed from Settings shows the default host it
    /// falls back to, as the rail does, rather than a name no longer in
    /// `hosts`. "default" when nothing names a host.
    static func settingsHostName(for crew: Crew, hosts: [HostEntry], defaultHost: String?) -> String {
        CrewMerge.crewHostKey(for: crew, hosts: hosts, defaultHost: defaultHost) ?? "default"
    }

    /// A crew row's label, or nil to draw nothing — shown only when this
    /// crew's DISPLAYED NAME collides with another entry's on the rail. Every
    /// Builder install has a crew named `steward`, and one operator's
    /// several machines each run one, so two rail entries sharing a name is
    /// the normal case rather than a rarity to hunt for — "where a name
    /// appears more than once on the rail, each entry shows its host's name
    /// beside it; a name that appears once shows none."
    ///
    /// `duplicateNames` IS THE SET OF DISPLAY NAMES DRAWN MORE THAN ONCE ON
    /// THE RAIL RIGHT NOW — `RailView.duplicateCrewNames`, computed once per
    /// render. Checking `displayName` rather than `id` is deliberate: `id`
    /// is the tmux session name every rail row's IDENTITY keys on, but the
    /// label exists to disambiguate what a person actually READS, and a
    /// crew already renamed to tell two "steward"s apart needs no further
    /// help. This replaced an earlier `hosts.count > 1` gate, which drew the
    /// label on every row once a second host existed even when nothing on
    /// the rail actually collided.
    ///
    /// ALSO NIL WHEN THE CREW'S HOST DOES NOT RESOLVE. There is no
    /// `user@machine` to show for a crew with no host — `unresolvedHostWarning`
    /// carries that message instead, so the two never draw conflicting
    /// things about the same row.
    static func crewLabel(
        for crew: Crew, duplicateNames: Set<String>, hosts: [HostEntry], defaultHost: String?,
        probed: (SSHTarget) -> String?
    ) -> String? {
        guard duplicateNames.contains(normalizedDisplayNameKey(crew.displayName)),
              let target = HostResolution.target(forHostName: crew.host, hosts: hosts, defaultHost: defaultHost)
        else { return nil }
        return label(for: target, hosts: hosts, probed: probed)
    }

    /// Non-nil whenever a crew's `host` resolves to nothing at all, or
    /// names something the table no longer has and `HostResolution` has
    /// fallen back to the configured default, silently — see
    /// `deck/specs/multiple-sessions-per-project` §"Warn when a crew's
    /// host names nothing". INDEPENDENT OF HOST COUNT, unlike `crewLabel`:
    /// a stale reference, or an outright unresolved host, is worth flagging
    /// even when only one host is left in the table (or none at all).
    ///
    /// THE UNRESOLVED CASE IS CHECKED FIRST, deliberately, rather than only
    /// when `crew.host` itself names something — a crew with NO `host` field
    /// at all used to resolve silently to `SSHTarget.mini`; now, with an
    /// empty `hosts` table, it resolves to nothing, and that is exactly the
    /// state this warning exists to name. See
    /// `deck/specs/running-deck-as-someone-else`.
    static func unresolvedHostWarning(
        for crew: Crew, hosts: [HostEntry], defaultHost: String?, probed: (SSHTarget) -> String?
    ) -> String? {
        guard let target = HostResolution.target(forHostName: crew.host, hosts: hosts, defaultHost: defaultHost)
        else { return "No host is configured for this crew \u{2014} add one in Settings \u{203a} Hosts." }
        guard let hostName = crew.host, !hosts.contains(where: { $0.name == hostName }) else { return nil }
        return "\u{201c}\(hostName)\u{201d} isn\u{2019}t a configured host \u{2014} using "
            + "\(label(for: target, hosts: hosts, probed: probed)) instead."
    }

    /// Non-nil when a crew's host resolves to a real target but that
    /// target's most recent poll could not be reached at all.
    ///
    /// CAN BE TRUE AT THE SAME TIME AS `unresolvedHostWarning`, not just
    /// when the host name resolves cleanly. `HostResolution.target` falls
    /// back to the configured default host, rather than failing, when a
    /// crew names a host the table no longer has — so `unresolvedHostWarning`
    /// fires for that stale-name case too, and the crew is polled against
    /// the fallback target, which can genuinely be unreachable (a crew
    /// naming a host removed from Settings falls back to `mini`, and `mini`
    /// then goes unreachable). Callers that give the two warnings a single
    /// display slot, like `RailView.unreachableWarning(for:)`, pick
    /// `unresolvedHostWarning` for that case: see its doc for why.
    ///
    /// KEEPS THE OPERATOR'S HEDGE. Deck knows the ssh attempt failed; it does not
    /// know why — a downed tailnet, a sleeping host, an uncompleted
    /// captive portal, and a stopped sshd all look identical from here. So
    /// this names the tailnet as the likeliest cause without asserting it
    /// is THE cause, the same restraint `Mark.unreadable` observes about
    /// the session mark one layer in
    /// (`issue_01M23WC488NVYT6T5MDZN37ZBR`).
    static func unreachableWarning(
        for crew: Crew, hosts: [HostEntry], defaultHost: String?,
        isUnreachable: (SSHTarget) -> Bool, probed: (SSHTarget) -> String?
    ) -> String? {
        guard let target = HostResolution.target(forHostName: crew.host, hosts: hosts, defaultHost: defaultHost),
              isUnreachable(target)
        else { return nil }
        return "Cannot reach \(label(for: target, hosts: hosts, probed: probed)). "
            + "The tailnet may be down."
    }
}
