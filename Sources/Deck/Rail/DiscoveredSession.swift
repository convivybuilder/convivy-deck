import Foundation

/// One row from `session-agent sessions` — a tmux session on the host that
/// Deck did not necessarily create, offered so `SessionGrouping` can draw it
/// under whichever crew's directory or naming convention claims it. See
/// `platform/contracts/session-agent-api`'s `sessions` section for the
/// producer side of this shape, and
/// `deck/specs/multiple-sessions-per-project` §"Discovering sessions
/// created outside Deck".
///
/// EPHEMERAL. A `DiscoveredSession` is never written to `theme.json` — it is
/// recomputed from the poll every tick, the same way `RailStateModel.states`
/// is. `RailChildRow`/`RailView` draw from it fresh each render.
struct DiscoveredSession: Identifiable, Equatable {
    /// A discovered row's identity: the actual resolved target it was
    /// found on, plus its tmux name — see `host` below.
    struct ID: Hashable {
        var host: SSHTarget
        var name: String
    }

    let name: String
    /// The actual `SSHTarget` this row was found on — set at decode time by
    /// `RailStateModel`'s per-host poll task, from the target that task
    /// dispatched `session-agent sessions` against. NEVER derived from
    /// config. See `deck/specs/multiple-sessions-per-project` §"Crews on
    /// different hosts": "A discovered session already knows its host and
    /// Deck throws it away." Carrying it here is what lets
    /// `SessionGrouping` compare a crew's OWN resolved host against this
    /// row's without resolving the crew's host through the discovered row
    /// first — the circularity phase 6a's `hostUser` parameter worked
    /// around rather than removed.
    /// Required rather than defaulted — there is no implied host left to
    /// fall back to.
    let host: SSHTarget
    /// `#{session_path}`, or nil when tmux could not report it, or this row
    /// could not be corroborated against the trusted name listing — see the
    /// contract's "round 2" reconciliation.
    let path: String?
    /// The session's window count, or nil under the same corroboration
    /// failure, or when the count tmux reported was not a plain ASCII
    /// integer.
    let windows: Int?
    /// Whether a client is attached now, or nil under the same condition.
    let attached: Bool?

    /// tmux's `#{session_id}` (`$<digits>`), or nil. Part of the contract's
    /// `sessions` shape as of agent-platform#524 — `session-agent sessions`
    /// carries it on every row, per `platform/contracts/session-agent-api`'s
    /// `sessions` section. Still decoded defensively, the same way every
    /// other field here degrades to `nil` on an absent or malformed key: a
    /// row a corroboration failure withheld everything but the name from
    /// (the contract's "round 2" reconciliation) carries this as `nil` too.
    /// See `SessionGrouping.discoveredChildren`, which prefers this over a
    /// name match whenever both sides carry one, and
    /// `PinnedSessionReconcile`, which is what follows a pinned child
    /// through a rename using it.
    let sessionId: String?

    init(name: String, host: SSHTarget, path: String? = nil,
         windows: Int? = nil, attached: Bool? = nil, sessionId: String? = nil) {
        self.name = name
        self.host = host
        self.path = path
        self.windows = windows
        self.attached = attached
        self.sessionId = sessionId
    }

    var id: ID { ID(host: host, name: name) }

    /// Decodes the `{"sessions": [...]}` envelope.
    ///
    /// EVERY FIELD BUT `name` DEGRADES INDEPENDENTLY, per the contract: a
    /// row can legitimately carry `path`, `windows`, and `attached` all
    /// `null` when reconciliation withheld everything but the name — that is
    /// a REAL session Deck must still draw, never a row to drop. `windows`
    /// and `attached` are read the way `SessionState.decode` reads every
    /// numeric field: `NSNumber`-cast first, so a null or a wrongly-typed
    /// value degrades to `nil` instead of crashing or silently reading as
    /// `0`/`false`.
    ///
    /// A TOTAL FUNCTION OF THE BYTES, never throwing. A payload that is not
    /// a JSON object, has no `sessions` array, or holds something other than
    /// an array of objects there decodes to `[]` — the same answer a
    /// genuinely empty host gives per the contract ("No tmux server / no
    /// sessions both read as `{"sessions": []}`, never an error"). This runs
    /// inside the rail's poll loop, where an uncaught error is not an
    /// option; `RailStateModel.refresh()` is what tells a transport failure
    /// (this call throwing) apart from a legitimately empty answer (this
    /// function returning `[]`).
    static func decode(_ data: Data, host: SSHTarget) -> [DiscoveredSession] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawSessions = root["sessions"] as? [Any] else {
            return []
        }
        var out: [DiscoveredSession] = []
        out.reserveCapacity(rawSessions.count)
        for item in rawSessions {
            // `name` is the one field every row must carry — it is what a
            // row is grouped and drawn by. A row with no usable name costs
            // only itself: skipped here rather than invalidating the batch,
            // since (unlike a delta row advancing a cursor) there is no
            // later poll this would rob of a chance to re-report it.
            guard let dict = item as? [String: Any],
                  let name = dict["name"] as? String, !name.isEmpty else { continue }
            out.append(DiscoveredSession(
                name: name,
                host: host,
                path: dict["path"] as? String,
                windows: (dict["windows"] as? NSNumber)?.intValue,
                attached: dict["attached"] as? Bool,
                sessionId: dict["sessionId"] as? String))
        }
        return out
    }
}
