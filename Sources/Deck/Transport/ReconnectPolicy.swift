import Foundation

/// Exponential backoff with jitter, capped, so a flapping network cannot turn
/// into a reconnect storm against the mini's single ControlMaster (fork 1's
/// risk list: "Reconnect storms").
struct ReconnectPolicy: Equatable {
    var baseDelay: TimeInterval = 1
    var maxDelay: TimeInterval = 30
    /// Fraction of the exponential delay randomized away from center, both
    /// directions — e.g. 0.5 means the actual delay lands within ±50% of the
    /// unjittered value.
    var jitterFraction: Double = 0.5

    /// `jitterSource` is a caller-supplied value in `0...1`, not sampled
    /// internally, so the schedule is deterministic and testable; production
    /// callers pass `Double.random(in: 0...1)`.
    func delay(forAttempt attempt: Int, jitterSource: Double) -> TimeInterval {
        precondition(attempt >= 1, "attempt is 1-based")
        let exponential = min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
        let spread = exponential * jitterFraction
        let jittered = (exponential - spread) + spread * 2 * jitterSource
        return max(0, jittered)
    }
}

/// Drives the veil: `.connected` hides it, `.connecting`/`.reconnecting` show
/// it dimmed with a retry countdown (fork 1: "dim the panes with a
/// 'reconnecting' veil ... typically 1-2 seconds after wake").
final class ConnectionStateMachine {
    enum Phase: Equatable {
        case connecting
        case connected
        case reconnecting(attempt: Int, delay: TimeInterval)
    }

    private(set) var phase: Phase = .connecting
    private var attempt = 0
    private let policy: ReconnectPolicy
    private let jitterSource: () -> Double

    init(policy: ReconnectPolicy = ReconnectPolicy(), jitterSource: @escaping () -> Double = { Double.random(in: 0...1) }) {
        self.policy = policy
        self.jitterSource = jitterSource
    }

    @discardableResult
    func connectSucceeded() -> Phase {
        attempt = 0
        phase = .connected
        return phase
    }

    /// Called when the ssh/tmux process exits unexpectedly (socket loss,
    /// sleep/wake, network flip). Returns the phase to render and the delay
    /// to wait before the next attempt.
    @discardableResult
    func connectionLost() -> Phase {
        attempt += 1
        let delay = policy.delay(forAttempt: attempt, jitterSource: jitterSource())
        phase = .reconnecting(attempt: attempt, delay: delay)
        return phase
    }
}
