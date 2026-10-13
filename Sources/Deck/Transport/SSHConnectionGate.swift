import Foundation

/// A per-control-path cap on how many ssh sessions Deck opens through one
/// ControlMaster at once, so Deck's own concurrency never asks sshd for more
/// channels than it will give.
///
/// THE INCIDENT THIS CLOSES (CQ·164). On a slow link (~164ms round trip) the
/// mux client's own concurrency through one master — Library `curl` calls,
/// `session-agent` polls, a followed pane, a render — passed the host's
/// sshd running at its default `MaxSessions` of 10: an 11th request got
/// "Session open refused by peer," and `ControlMaster=auto` silently fell
/// back to a full direct connection that ran 26.4s, well past
/// `SessionAgent.defaultTimeout`. Deck went nearly unresponsive on a link
/// where every request simply lives longer, which is what pushed the count
/// over 10 in the first place — on the LAN the same calls finish fast enough
/// to never collide.
///
/// KEYED BY (DESTINATION, CONTROLPATH) RATHER THAN THE RESOLVED SOCKET FILE.
/// ssh's own `%C` token hashes `(host, port, user)` to the literal socket
/// filename `defaultControlPath()` leaves as a template, and resolving it
/// costs a local `ssh -G` round trip (`SSHControlSocket.clear`'s own path) —
/// too expensive to pay on every gated call. The literal `"user@host"`
/// destination token every argv in this codebase already carries, paired
/// with the UNRESOLVED controlpath template, distinguishes every master
/// Deck actually opens just as well: two different hosts never share a
/// destination token, and the session master and the `-render` master for
/// one host carry different templates (`SessionAgent.renderArguments`'s own
/// `-render` suffix) — which is correct, since they are two sockets with two
/// separate `MaxSessions` budgets of their own.
/// `@unchecked Sendable`: every mutable property below is guarded by
/// `condition` (an `NSCondition`), the same "a legacy locking primitive
/// gives the discipline Swift's checker cannot see through" reasoning
/// `SessionStateFollower` already documents for its own `@unchecked
/// Sendable`.
final class SSHConnectionGate: @unchecked Sendable {
    static let shared = SSHConnectionGate()

    /// sshd's own `MaxSessions` default, less two channels of headroom:
    /// CQ·164's own diagnosis measured the overflow at an 11th concurrent
    /// request against a default-configured server, so Deck's own ceiling
    /// has to sit below 10, not at it — `ControlMaster` keepalive
    /// bookkeeping and anything outside Deck sharing the same master (a
    /// second ssh client, say) can occupy a channel Deck itself never
    /// requested.
    static let defaultCap = 8

    /// How long a one-shot call may sit queued for a free slot before
    /// giving up. Bounded SEPARATELY from, and never counted toward,
    /// `SessionAgent.defaultTimeout`'s own per-attempt watchdog — a call
    /// that times out here never started an ssh process at all, so nothing
    /// about it is a transport failure.
    static let defaultQueueTimeout: TimeInterval = 45

    /// One master this codebase might open: the literal `"user@host"`
    /// destination token the ssh call carries, together with the
    /// unresolved `ControlPath` template it was given. See this type's own
    /// doc for why this identifies a real, distinct socket without ever
    /// resolving ssh's own `%C`.
    struct Key: Hashable {
        let destination: String
        let controlPath: String
    }

    private let condition = NSCondition()
    private var held: [Key: Int] = [:]
    private var waitOrder: [Key: [UInt64]] = [:]
    private var nextTicket: UInt64 = 0
    private var capOverrides: [String: Int] = [:]

    /// Blocks the calling thread until a slot under `cap` is free for
    /// `key`, honouring FIFO order among waiters for the same key — a later
    /// caller never jumps ahead of one already waiting. Throws
    /// `SSHConnectionGateError.queueTimedOut` if `queueTimeout` elapses
    /// first, having started no process and touched no watchdog at all.
    func acquire(_ key: Key, cap: Int, queueTimeout: TimeInterval) throws {
        condition.lock()
        defer { condition.unlock() }
        let ticket = nextTicket
        nextTicket += 1
        waitOrder[key, default: []].append(ticket)
        let deadline = Date().addingTimeInterval(queueTimeout)
        while true {
            if waitOrder[key]?.first == ticket, (held[key] ?? 0) < cap {
                held[key, default: 0] += 1
                waitOrder[key]?.removeFirst()
                condition.broadcast()
                return
            }
            guard condition.wait(until: deadline) else {
                waitOrder[key]?.removeAll { $0 == ticket }
                condition.broadcast()
                throw SSHConnectionGateError.queueTimedOut
            }
        }
    }

    /// How many callers are queued for `key` right now. Lets a test start
    /// each waiter only after the previous one has taken its ticket, since
    /// thread start order alone does not fix queue order.
    func waitingCount(_ key: Key) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return waitOrder[key]?.count ?? 0
    }

    /// Frees one slot `key` held, and wakes every waiter so the new front
    /// of the queue — if the slot it is waiting on is now free — can
    /// proceed. Safe to call exactly once per successful `acquire`; callers
    /// own that discipline the same way a lock's unlock does.
    func release(_ key: Key) {
        condition.lock()
        if let current = held[key] {
            if current <= 1 { held.removeValue(forKey: key) } else { held[key] = current - 1 }
        }
        condition.unlock()
        condition.broadcast()
    }

    // MARK: - Per-host overrides

    /// Overrides `defaultCap` for every call keyed by `destination` — a
    /// server whose sshd raised `MaxSessions` above the default can let
    /// Deck use more of it. See `applyHostCaps`, which is how a configured
    /// `HostEntry` reaches here.
    func setCap(_ cap: Int, forDestination destination: String) {
        condition.lock()
        capOverrides[destination] = cap
        condition.unlock()
    }

    func clearCap(forDestination destination: String) {
        condition.lock()
        capOverrides.removeValue(forKey: destination)
        condition.unlock()
    }

    func cap(forDestination destination: String) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return capOverrides[destination] ?? SSHConnectionGate.defaultCap
    }

    /// Syncs every configured host's own `maxSessionsPerControlMaster`
    /// override onto this gate. Called whenever `ThemeConfiguration`'s
    /// hosts load or change (`ThemeStore.init`/`commit`), so an edited
    /// `theme.json` takes effect on the very next gated call rather than
    /// needing a relaunch — the same "hand-edited config, read fresh"
    /// discipline the rest of `HostEntry` already follows.
    func applyHostCaps(_ hosts: [HostEntry]) {
        for host in hosts {
            let destination = "\(host.user)@\(host.address)"
            if let cap = host.maxSessionsPerControlMaster, cap > 0 {
                setCap(cap, forDestination: destination)
            } else {
                clearCap(forDestination: destination)
            }
        }
    }
}

enum SSHConnectionGateError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// A one-shot call waited `SSHConnectionGate.defaultQueueTimeout` (or a
    /// caller-supplied bound) for a free slot and none opened. Shown as
    /// waiting for a connection slot, never as a transport failure — this
    /// is Deck's own concurrency limit, not ssh's or the host's.
    case queueTimedOut
    /// A one-shot call kept hitting sshd's own `MaxSessions` refusal past
    /// `MuxRefusalAbsorptionPolicy`'s retry budget. Surfaced rather than
    /// returned, so a caller can never read the slow direct-connection
    /// fallback this guards against as a success — see
    /// `SSHProcessRunner.runQueued`.
    case masterFull

    var description: String {
        switch self {
        case .queueTimedOut: return "waiting for a connection slot"
        case .masterFull: return "the ssh connection kept refusing a new session"
        }
    }

    var errorDescription: String? { description }
}

extension SSHConnectionGate.Key {
    /// Derives the gate key an argv array would ride, or nil when `argv`
    /// carries no shared control socket to protect: a control command
    /// (`-O check`/`-O cancel`), a local config dump (`-G`), or an explicit
    /// `ControlPath=none` (`HostPairing`'s own first-contact probe, which
    /// deliberately never shares a master — see its own doc). None of
    /// those opens a new session on a ControlMaster, so none of them is
    /// what sshd's `MaxSessions` bounds.
    ///
    /// PURE, and deliberately so: parses the exact argv every builder in
    /// this codebase already assembles, rather than asking each of the
    /// ~40 call sites behind `SessionAgent.run`/`SSHProcessRunner.run` to
    /// also hand back a key on the side.
    ///
    /// The destination token is matched against the SAME charset
    /// `validateHostUser`/`validateHostAddress` already enforce before it
    /// ever reaches argv — not merely "contains an `@`". A quoted,
    /// free-text `--name` value (`renderFileFromStdinArguments`'s
    /// Library-supplied title) can itself contain an `@`, and the quoting
    /// that keeps it safe from the remote shell (`shellQuotePath`) does
    /// nothing to stop it from LOOKING like a destination token to a naive
    /// scan; the stricter match is what tells the two apart.
    static func from(argv: [String]) -> SSHConnectionGate.Key? {
        guard !argv.contains("-O"), !argv.contains("-G") else { return nil }
        var controlPath: String?
        var destination: String?
        var index = 0
        while index < argv.count {
            let token = argv[index]
            if token == "-o", index + 1 < argv.count {
                let option = argv[index + 1]
                if option.hasPrefix("ControlPath=") {
                    controlPath = String(option.dropFirst("ControlPath=".count))
                }
                index += 2
                continue
            }
            if token == "-i" || token == "-L" {
                index += 2
                continue
            }
            if destination == nil, isDestinationToken(token) {
                destination = token
            }
            index += 1
        }
        guard let controlPath, controlPath != "none", let destination else { return nil }
        return SSHConnectionGate.Key(destination: destination, controlPath: controlPath)
    }

    private static let destinationPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9._-]+@[A-Za-z0-9.:_-]+\\z")

    private static func isDestinationToken(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..., in: token)
        return destinationPattern.firstMatch(in: token, range: range) != nil
    }
}
