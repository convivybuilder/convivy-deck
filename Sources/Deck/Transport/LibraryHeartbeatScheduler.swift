import Foundation

/// A token for one scheduled repeating heartbeat. `cancel()` stops future
/// ticks and is safe to call more than once.
protocol LibraryHeartbeatToken {
    func cancel()
}

/// Schedules the mutual-TLS heartbeat's repeating tick, behind a seam so a
/// test can fire ticks on demand instead of sleeping 45 real seconds —
/// `LibraryMutualTLSSessionHolder`'s own done condition.
protocol LibraryHeartbeatScheduling {
    /// Calls `tick` every `interval` seconds until the returned token is
    /// cancelled. The first call lands after one full `interval`, never
    /// immediately.
    func scheduleRepeating(interval: TimeInterval, tick: @escaping () -> Void) -> LibraryHeartbeatToken
}

/// Production scheduler: one `DispatchSourceTimer` per call, on its own
/// serial queue so a slow heartbeat request never blocks another host's
/// timer. `@unchecked Sendable`: holds no mutable state of its own —
/// `scheduleRepeating` builds a fresh queue and timer per call — the same
/// "stateless, so there is nothing for the checker to need proof about"
/// shape as the rest of this file's singletons.
final class LibraryDispatchHeartbeatScheduler: LibraryHeartbeatScheduling, @unchecked Sendable {
    static let shared = LibraryDispatchHeartbeatScheduler()

    func scheduleRepeating(interval: TimeInterval, tick: @escaping () -> Void) -> LibraryHeartbeatToken {
        let queue = DispatchQueue(label: "convivy.deck.library-heartbeat")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: tick)
        timer.resume()
        return DispatchHeartbeatToken(timer: timer)
    }
}

private final class DispatchHeartbeatToken: LibraryHeartbeatToken {
    private let timer: DispatchSourceTimer
    init(timer: DispatchSourceTimer) { self.timer = timer }
    func cancel() { timer.cancel() }
}
