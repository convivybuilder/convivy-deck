import Foundation

/// Every live `SessionStateFollower`, across every pane and every window, so
/// app termination can stop all of them at once.
///
/// `SessionPaneModel` already tears its own follower down the moment it stops
/// needing it — on deselect and on pane close, both of which destroy the
/// pane's `StateObject` and run `deinit`, which calls `stop()`. That path
/// works today and this type does not change it.
///
/// WHAT THIS EXISTS FOR IS THE PATH `deinit` CANNOT COVER. Quitting the app
/// does not run ordinary Swift deallocation — AppKit's terminate sequence
/// exits the process directly — so a follower still registered at that
/// moment would never see `stop()` called, and the `ssh` child it owns would
/// outlive Deck. `DeckAppDelegate.applicationWillTerminate` is the one place
/// that still gets to run code before the process exits, and `stopAll()` is
/// what it calls.
///
/// `@unchecked Sendable`, the same discipline `SessionStateFollower` itself
/// uses: every mutation happens under `lock`, so the data race `Sendable`
/// exists to catch cannot occur here even though the compiler has no way to
/// see that through `NSLock`. Not `@MainActor` deliberately — `deinit` on a
/// `@MainActor` class runs nonisolated, and `SessionPaneModel` needs to reach
/// this type from there the same way it already reaches `follower.stop()`.
final class FollowerRegistry: @unchecked Sendable {
    static let shared = FollowerRegistry()

    /// Not `private` — tests construct their own instance so they can assert
    /// against a registry nothing else is touching, rather than fighting for
    /// state in `shared`.
    init() {}

    private let lock = NSLock()
    private var followers: [ObjectIdentifier: SessionStateFollower] = [:]

    func register(_ follower: SessionStateFollower) {
        lock.lock()
        defer { lock.unlock() }
        followers[ObjectIdentifier(follower)] = follower
    }

    /// Called once a follower has been (or is being) stopped through its
    /// owner's own path, so `stopAll()` does not hold a reference to — or
    /// redundantly re-stop — a follower that is already done.
    func unregister(_ follower: SessionStateFollower) {
        lock.lock()
        defer { lock.unlock() }
        followers.removeValue(forKey: ObjectIdentifier(follower))
    }

    /// Stops every currently-registered follower and forgets them.
    ///
    /// SAFE TO CALL WITH NOTHING REGISTERED, AND SAFE TO CALL TWICE — the
    /// list is drained under the lock before anything is stopped, so a
    /// second call simply finds nothing left to do. Each follower's own
    /// `stop()` is separately idempotent, so even a follower reached here
    /// AND torn down through its owner's normal path at the same moment is
    /// stopped safely either way.
    func stopAll() {
        let live: [SessionStateFollower] = {
            lock.lock()
            defer { lock.unlock() }
            let values = Array(followers.values)
            followers.removeAll()
            return values
        }()
        for follower in live { follower.stop() }
    }
}
