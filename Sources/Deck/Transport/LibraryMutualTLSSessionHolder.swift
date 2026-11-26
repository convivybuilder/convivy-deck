import Foundation

/// A `URLSession` that refuses a new task once closed, because creating a task
/// on an invalidated `URLSession` raises an uncaught `NSGenericException` and
/// takes the whole app down. Requests and heartbeats run on their own threads
/// and a failure on any of them closes the session, so a thread holding this
/// can lose the race to another's close. `lock` makes "not closed yet, so
/// create the task" and "close" atomic against each other.
final class LibraryMutualTLSSession: @unchecked Sendable {
    private let urlSession: URLSession
    private let lock = NSLock()
    private var closed = false

    init(urlSession: URLSession) { self.urlSession = urlSession }

    func dataTask(
        with request: URLRequest,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) throws -> URLSessionDataTask {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else {
            throw LibraryMutualTLSError.transportFailed("the Library connection closed before this request started")
        }
        return urlSession.dataTask(with: request, completionHandler: completionHandler)
    }

    /// Lets tasks already running finish, and refuses new ones.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        urlSession.finishTasksAndInvalidate()
    }
}

/// The one `URLSession` a `LibraryHostConnection` keeps alive for its host,
/// plus the heartbeat that keeps the Library's listener from treating it as
/// idle. Split out of `LibraryHostConnection` itself so the session cache and
/// the heartbeat schedule are testable with no real ssh forward at all — the
/// session is built from a caller-supplied `make()`, and each tick calls a
/// caller-supplied `heartbeat(URLSession)`; this type interprets neither.
/// `@unchecked Sendable`: `lock` is the actual synchronization for `session`
/// and `heartbeatToken`, the same discipline `LibraryHostConnection` and
/// `TransportLog` already use for the identical shape.
final class LibraryMutualTLSSessionHolder: @unchecked Sendable {
    /// The Library's 8443 listener drops an idle mutual-TLS connection after
    /// 120 s (library#348, deployed at fae6e7ca on 2026-11-03). One missed
    /// beat lands the next at 90 s, 30 s inside that timeout.
    static let heartbeatInterval: TimeInterval = 45

    private let heartbeatScheduler: LibraryHeartbeatScheduling
    private let lock = NSLock()
    private var session: LibraryMutualTLSSession?
    private var heartbeatToken: LibraryHeartbeatToken?

    init(heartbeatScheduler: LibraryHeartbeatScheduling = LibraryDispatchHeartbeatScheduler.shared) {
        self.heartbeatScheduler = heartbeatScheduler
    }

    /// Returns the cached session, or builds one with `make()`, caches it,
    /// and starts the heartbeat — `heartbeat(session)` on every tick until
    /// `close()`. Two calls before a `close()` always return the same
    /// instance, and never call `make()` a second time.
    func session(
        make: () -> URLSession, heartbeat: @escaping (LibraryMutualTLSSession) -> Void
    ) -> LibraryMutualTLSSession {
        lock.lock()
        defer { lock.unlock() }
        if let session { return session }
        let made = LibraryMutualTLSSession(urlSession: make())
        session = made
        heartbeatToken = heartbeatScheduler.scheduleRepeating(interval: Self.heartbeatInterval) {
            heartbeat(made)
        }
        return made
    }

    /// Invalidates the cached session and stops its heartbeat. The next
    /// `session(make:heartbeat:)` call builds a fresh one.
    func close() {
        lock.lock()
        let closing = session
        session = nil
        heartbeatToken?.cancel()
        heartbeatToken = nil
        lock.unlock()
        closing?.invalidate()
    }
}
