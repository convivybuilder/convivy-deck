import Foundation

/// The Hosts tab's Test button's result — see
/// `deck/specs/multiple-sessions-per-project` §"Crews on different hosts".
/// Three outcomes, plainly: reachable (with the name it answered), refused,
/// or unreachable/timed out.
enum HostTestOutcome: Equatable {
    case reachable(machineName: String)
    case refused(String)
    case unreachable(String)

    /// PURE classification of ssh's own stderr text, so the mapping is
    /// pinned by a test without an ssh round trip — the same discipline
    /// `HostDisplay`'s fallback chain follows. Ssh's own wording is the only
    /// signal available, and the unreachable phrases are checked FIRST
    /// because "Connection refused" and "Operation timed out" describe
    /// markedly different failures a user should be able to tell apart: a
    /// dead address hangs until the bound `ConnectTimeout` fires, a live box
    /// with no sshd on it refuses immediately.
    static func classify(errorText: String) -> HostTestOutcome {
        let lower = errorText.lowercased()
        let unreachablePhrases = [
            "timed out", "no route to host", "could not resolve hostname",
            "network is unreachable", "host is down",
        ]
        if unreachablePhrases.contains(where: lower.contains) {
            return .unreachable(errorText)
        }
        return .refused(errorText)
    }
}
