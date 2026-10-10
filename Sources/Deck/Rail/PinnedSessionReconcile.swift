import Foundation

/// Keeps a crew's pinned sibling sessions (`Crew.sessions`) pointing at a
/// live tmux session that has been renamed outside Deck — the operator's
/// 2026-09-11 call on `issue_01M1KXVY8MNNNG53NFBT8SY58Z`'s rename half (the
/// resurrection half shipped in PR #222): "when a session added under a
/// crew is renamed in tmux, Deck updates its saved pin to the new name, so
/// the user keeps one live row that opens the renamed session."
///
/// PURE — no config, no host resolution, no file write — so the three rules
/// are exercised as plain logic against one crew's own pins and the
/// sessions discovered on THAT crew's host. `ThemeStore.reconcilePinnedSessions`
/// is the driver: it resolves each crew's host, filters `discovered` down to
/// that host, calls this once per crew, and commits whatever changed.
enum PinnedSessionReconcile {
    /// A pin whose tmux name changed this reconcile — enough for a caller
    /// keying other state by the pin's OLD name (the rail's selection, the
    /// per-session theme, terminal/launch state) to move it onto the new
    /// one. See `ThemeStore.reconcilePinnedSessions`'s doc for what moves
    /// where.
    struct Rename: Equatable {
        let from: String
        let to: String
    }

    struct Outcome: Equatable {
        var sessions: [PinnedSession]
        var renames: [Rename]
    }

    /// Applies three rules, in order, to each pin in turn:
    ///
    /// (a) the pin has an id and a discovered session carries that id: if
    ///     its name differs, the pin follows it to the live name, keeping
    ///     its own `displayName`.
    /// (b) otherwise, a discovered session carries the pin's exact name:
    ///     the pin records that session's id, replacing any id it had —
    ///     the session that used to answer to that id is gone, and this is
    ///     the one holding the name now.
    /// (c) otherwise the pin is left exactly as it was — stale, as today.
    ///
    /// A pin is never removed.
    ///
    /// NEVER LETS TWO PINS CLAIM ONE SESSION. Pins are considered in their
    /// own order; once a discovered session has matched a pin (by either
    /// rule), it is unavailable to every pin considered after it — the
    /// first pin in the list wins a session two pins could otherwise both
    /// claim.
    static func reconciling(
        _ pins: [PinnedSession], discovered: [DiscoveredSession]
    ) -> Outcome {
        var claimed = Set<Int>()
        let candidates = Array(discovered.enumerated())
        var sessions: [PinnedSession] = []
        var renames: [Rename] = []

        for pin in pins {
            var pin = pin
            if let id = pin.sessionId,
               let (index, match) = candidates.first(where: {
                   !claimed.contains($0.offset) && $0.element.sessionId == id
               }) {
                claimed.insert(index)
                // FOLLOWS ONLY TO A NAME THIS FILE CAN LOAD BACK. tmux accepts
                // names `validateTmuxSessionName` rejects (a space, for one),
                // and `ThemeConfiguration.parseSessions` drops a pin whose name
                // fails it. Following such a rename would save a pin the next
                // launch deletes, and attaching under it would fail before
                // then. The pin is left as it was instead, stale, and Remove
                // pin stays the way out.
                if match.name != pin.name, (try? validateTmuxSessionName(match.name)) != nil {
                    renames.append(Rename(from: pin.name, to: match.name))
                    pin.name = match.name
                }
                sessions.append(pin)
                continue
            }
            if let (index, match) = candidates.first(where: {
                !claimed.contains($0.offset) && $0.element.name == pin.name
            }) {
                claimed.insert(index)
                pin.sessionId = match.sessionId
                sessions.append(pin)
                continue
            }
            sessions.append(pin)
        }
        return Outcome(sessions: sessions, renames: renames)
    }
}
