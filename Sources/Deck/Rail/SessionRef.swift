import Foundation

/// Identifies one tmux session unambiguously once more than one host can
/// exist: the config host NAME a crew, catalog row, or child names via its
/// `host` field, plus the tmux session name on that host. See
/// `deck/specs/multiple-sessions-per-project` §"Crews on different hosts":
/// "A tmux session name is unique per machine, not globally."
///
/// `host` IS THE CONFIG KEY, NOT A RESOLVED ADDRESS — the same string
/// `Crew.host`/`LaunchableSession.host` already carry, `nil` meaning the
/// configured default the same way it does there. A `SessionRef` is built
/// straight from a row's own `host` field wherever one is available (a crew,
/// a pinned or discovered child inheriting its crew's, a catalog entry), so
/// two refs for the same real row always agree — nothing here re-resolves a
/// host name against `hosts`/`defaultHost`, which stays `HostResolution`'s
/// job for the moment a network call actually needs an address.
struct SessionRef: Hashable {
    var host: String?
    var name: String

    /// A stable string form for the places that need one: SwiftUI `.id()`
    /// values on `TerminalPaneView`/`SessionPaneView` in `ContentView`, and
    /// every stored settings key that identifies a session —
    /// `theme.json`'s `sessions` theme map (`ThemeConfiguration.sessions`)
    /// and the rail's expand-state list (`CrewExpansion`). Those two were
    /// bare-name keyed until crews became host-scoped, which is what made
    /// macstudio's `steward` and macmini's `steward` one key rather than two.
    ///
    /// `host` is validated to `validateHostName`'s charset (letters,
    /// digits, `._-`, no `|`) at every place a host name enters config —
    /// `ThemeConfiguration.parseHosts` for `HostEntry.name`, `parseRail`/
    /// `parseCatalog` for `Crew.host`/`LaunchableSession.host` — so the two
    /// halves can never bleed into each other: a host containing `|` never
    /// makes it into a `SessionRef` in the first place. Without that gate,
    /// `host: "a|b", name: "c"` and `host: "a", name: "b|c"` would both
    /// produce `"a|b|c"` and collide on whatever reads `stringForm` — which
    /// today means SwiftUI treating two different sessions as one view
    /// identity, reusing a coordinator instead of tearing it down.
    var stringForm: String { "\(host ?? "")|\(name)" }

    /// The inverse of `stringForm`, for the two readers of a stored key: the
    /// `sessions` theme map in `theme.json` and the rail's expand-state
    /// list. Splits on the FIRST `|`, so it agrees with `stringForm` for
    /// every ref `stringForm` can produce; an empty host half is `nil`, the
    /// same "no host of its own" `stringForm` writes it from.
    ///
    /// `nil` FOR A STRING CARRYING NO `|` AT ALL — a key written before the
    /// host half existed. The caller decides which host such a key meant,
    /// because only the caller knows: `ThemeConfiguration.parse` resolves it
    /// against the crew or child that carries the name, and
    /// `CrewExpansion` treats it as matching that name on any host.
    ///
    /// NO VALIDATION OF EITHER HALF, and nothing here needs one. A host name
    /// reaches `stringForm` only from config, where `validateHostName` has
    /// already refused a `|` (see this type's own doc), so the split can
    /// never mis-divide a ref Deck wrote. A hand-edited key whose host half
    /// is nonsense names no configured host, which means it matches no
    /// session and the mapping is simply inert — the same outcome as the key
    /// never having been written.
    static func parse(stringForm: String) -> SessionRef? {
        guard let separator = stringForm.firstIndex(of: "|") else { return nil }
        let host = String(stringForm[stringForm.startIndex..<separator])
        let name = String(stringForm[stringForm.index(after: separator)...])
        return SessionRef(host: host.isEmpty ? nil : host, name: name)
    }
}

extension SessionRef: ExpressibleByStringLiteral {
    /// A bare literal means "no host of its own" — the same reading
    /// `stringForm`'s empty host half and `parse`'s missing-`|` case already
    /// give it. For fixture code written before hosts existed (most of
    /// `SessionRosterTests` and its neighbours), this keeps `list.update("ask")`
    /// meaning exactly what it always meant rather than forcing every
    /// single-host call site to spell out `SessionRef(host: nil, name: "ask")`.
    init(stringLiteral value: String) {
        self.init(host: nil, name: value)
    }
}

extension SessionRef {
    /// The reserved local-shell selection — the sole source of truth for
    /// that reserved key; `ContentView` reads `SessionRef.localShell.name`
    /// directly wherever it needs it (theme lookup, SwiftUI `.id()`) rather
    /// than through a second, mirrored constant on `TerminalTarget`. The
    /// colon in `"local:shell"` is a character `validateTmuxSessionName`
    /// forbids, so no real tmux session can ever collide with it, the same
    /// trick `WindowLeaf`'s `"<session>:<n>"` ids rely on.
    static let localShell = SessionRef(host: nil, name: "local:shell")

    /// The ref for a session belonging to a crew — its own primary session,
    /// or a pinned or discovered child's name — always inheriting the
    /// CREW's `host`. A child carries no host field of its own: it lives in
    /// its crew's directory, and a directory lives on one host, per
    /// `deck/specs/multiple-sessions-per-project` §"Sessions within a
    /// crew".
    static func owned(by crew: Crew, name: String) -> SessionRef {
        SessionRef(host: crew.host, name: name)
    }

    /// The ref for a discovered session no crew owns (an "OTHER SESSIONS"
    /// row) — the config host NAME whose entry resolves to the actual
    /// `SSHTarget` the row was found on
    /// (`DiscoveredSession.host`), via `HostResolution.hostName`, or nil
    /// (the implied default) when no entry names it. With `hosts` empty —
    /// today's only real config — this is always nil, matching how every
    /// other ref in an unconfigured install resolves.
    static func orphaned(_ discovered: DiscoveredSession, hosts: [HostEntry]) -> SessionRef {
        SessionRef(host: HostResolution.hostName(for: discovered.host, hosts: hosts), name: discovered.name)
    }
}
