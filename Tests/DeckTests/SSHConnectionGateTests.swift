import XCTest
@testable import Deck

/// A thread-safe "how many are in at once, and what was the peak" counter —
/// the same `NSLock`-boxed-state idiom `HeldKBSavesTests.SigningLog` uses,
/// needed here because the burst tests below genuinely run on several
/// threads at once.
private final class ConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maxObserved = 0

    func enter() {
        lock.lock()
        current += 1
        maxObserved = max(maxObserved, current)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
}

/// A thread-safe, ordered record — the same idiom `ConcurrencyCounter`
/// above uses, for a log of values rather than a count.
private final class OrderedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int] = []

    var values: [Int] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func record(_ value: Int) {
        lock.lock()
        entries.append(value)
        lock.unlock()
    }
}

/// A thread-safe box for one value set from a background closure and read
/// back on the test's own thread afterward.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// `SSHConnectionGate`'s own bookkeeping — the cap, the FIFO queue, and the
/// per-host override — exercised with real threads but no real ssh, per
/// CQ·164's own test discipline (issue_01M4RZJ13RZG4Z5YR8C68BAEBP).
final class SSHConnectionGateTests: XCTestCase {
    private func uniqueKey(_ name: String = UUID().uuidString) -> SSHConnectionGate.Key {
        SSHConnectionGate.Key(destination: "user@\(name)", controlPath: "/tmp/deck-cm-\(name)")
    }

    /// THE CAP ITSELF. A burst of far more callers than the cap allows —
    /// some released quickly (one-shot calls), some held for the whole run
    /// (long-lived holders: a follow stream, an interactive pane, a Keel
    /// forward) — must never push concurrent holders past `cap`, however
    /// they interleave.
    func testCapIsNeverExceededUnderABurstOfOneShotAndLongLivedHolders() throws {
        let gate = SSHConnectionGate()
        let key = uniqueKey()
        let cap = 4
        let counter = ConcurrencyCounter()

        let group = DispatchGroup()
        // Long-lived holders: acquire once, hold for the whole burst.
        for _ in 0..<3 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                try? gate.acquire(key, cap: cap, queueTimeout: 10)
                counter.enter()
                Thread.sleep(forTimeInterval: 0.2)
                counter.leave()
                gate.release(key)
            }
        }
        // One-shot calls: acquire and release quickly, many more than the cap.
        for _ in 0..<40 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                guard (try? gate.acquire(key, cap: cap, queueTimeout: 10)) != nil else { return }
                counter.enter()
                Thread.sleep(forTimeInterval: 0.01)
                counter.leave()
                gate.release(key)
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success, "the burst must finish, not deadlock")
        XCTAssertLessThanOrEqual(counter.maxObserved, cap, "the cap must never be exceeded, holders or one-shots alike")
    }

    /// FIFO ORDER. A caller that started waiting first is granted its slot
    /// before one that arrived later, for the SAME key.
    func testWaitersAreGrantedInFIFOOrder() throws {
        let gate = SSHConnectionGate()
        let key = uniqueKey()
        // Fill the only slot so every acquire below has to queue.
        try gate.acquire(key, cap: 1, queueTimeout: 10)

        let log = OrderedLog()
        let group = DispatchGroup()
        for i in 0..<5 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                guard (try? gate.acquire(key, cap: 1, queueTimeout: 10)) != nil else { return }
                log.record(i)
                gate.release(key)
            }
            // Start the next waiter only once this one holds its ticket. A
            // sleep-based stagger let a late-scheduled thread take an earlier
            // ticket on a loaded CI runner ([0, 1, 3, 2, 4]), which is the
            // gate being FIFO by arrival, not a defect in it.
            let queued = Date().addingTimeInterval(5)
            while gate.waitingCount(key) < i + 1, Date() < queued { Thread.sleep(forTimeInterval: 0.005) }
            XCTAssertEqual(gate.waitingCount(key), i + 1, "waiter \(i) must be queued before the next starts")
        }
        gate.release(key)

        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
        XCTAssertEqual(log.values, [0, 1, 2, 3, 4], "waiters must be granted in the order they queued")
    }

    /// QUEUE TIME IS A SEPARATE, NAMED FAILURE — never a transport failure.
    /// A caller that cannot get a slot within `queueTimeout` throws
    /// `.queueTimedOut`, having started no ssh process and touched no
    /// watchdog at all.
    func testQueueTimeoutNeverStartsAnythingAndThrowsItsOwnError() throws {
        let gate = SSHConnectionGate()
        let key = uniqueKey()
        try gate.acquire(key, cap: 1, queueTimeout: 10) // hold the only slot

        XCTAssertThrowsError(try gate.acquire(key, cap: 1, queueTimeout: 0.3)) { error in
            XCTAssertEqual(error as? SSHConnectionGateError, .queueTimedOut)
        }
        gate.release(key)
    }

    /// A GIVEN-UP WAITER DOES NOT BLOCK THE NEXT ONE. Removing itself from
    /// the queue on timeout must not corrupt the line for whoever is still
    /// waiting behind it.
    func testATimedOutWaiterDoesNotBlockTheNextOne() throws {
        let gate = SSHConnectionGate()
        let key = uniqueKey()
        try gate.acquire(key, cap: 1, queueTimeout: 10)

        let timedOut = Box(false)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do {
                try gate.acquire(key, cap: 1, queueTimeout: 0.2)
            } catch {
                timedOut.value = true
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(timedOut.value)

        // A fresh waiter, after the one above gave up, must still be able
        // to acquire once the held slot is released.
        gate.release(key)
        XCTAssertNoThrow(try gate.acquire(key, cap: 1, queueTimeout: 2))
        gate.release(key)
    }

    // MARK: - Per-host overrides

    func testUnconfiguredDestinationUsesTheDefaultCap() {
        let gate = SSHConnectionGate()
        XCTAssertEqual(gate.cap(forDestination: "someone@example.com"), SSHConnectionGate.defaultCap)
    }

    func testApplyHostCapsSetsAndClearsTheOverride() {
        let gate = SSHConnectionGate()
        let host = HostEntry(
            name: "raised", user: "someuser", address: "raised.example.com",
            maxSessionsPerControlMaster: 20)
        gate.applyHostCaps([host])
        XCTAssertEqual(gate.cap(forDestination: "someuser@raised.example.com"), 20)

        // Re-applying with the override removed falls back to the default
        // — an edit that clears the field must actually take effect, not
        // leave a stale override behind.
        gate.applyHostCaps([HostEntry(name: "raised", user: "someuser", address: "raised.example.com")])
        XCTAssertEqual(gate.cap(forDestination: "someuser@raised.example.com"), SSHConnectionGate.defaultCap)
    }

    // MARK: - Key extraction

    func testKeyExtractionReadsTheDestinationAndControlPath() {
        let argv = ["-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/deck-cm-abc",
                    "someuser@host.example.com", "session-agent", "state", "deck"]
        XCTAssertEqual(
            SSHConnectionGate.Key.from(argv: argv),
            SSHConnectionGate.Key(destination: "someuser@host.example.com", controlPath: "/tmp/deck-cm-abc"))
    }

    func testKeyExtractionSkipsTheIdentityFlag() {
        let argv = ["-i", "/Users/example/.ssh/id_ed25519_deck",
                    "-o", "ControlPath=/tmp/deck-cm-abc", "someuser@host.example.com", "session-agent"]
        XCTAssertEqual(
            SSHConnectionGate.Key.from(argv: argv)?.destination, "someuser@host.example.com")
    }

    /// `-O check`/`-O cancel` ride the mux control channel, never a new
    /// session — `SSHControlSocketCheck`'s own cap-exempt behaviour must
    /// hold regardless of what else is on the argv.
    func testKeyExtractionExcludesControlCommands() {
        let check = ["-O", "check", "-o", "ControlPath=/tmp/deck-cm-abc", "someuser@host.example.com"]
        XCTAssertNil(SSHConnectionGate.Key.from(argv: check))

        let cancel = ["-O", "cancel", "-L", "127.0.0.1:1234:/tmp/sock",
                      "-o", "ControlPath=/tmp/deck-cm-abc", "someuser@host.example.com"]
        XCTAssertNil(SSHConnectionGate.Key.from(argv: cancel))
    }

    func testKeyExtractionExcludesTheLocalConfigDump() {
        let argv = ["-G", "-o", "ControlPath=/tmp/deck-cm-abc", "someuser@host.example.com"]
        XCTAssertNil(SSHConnectionGate.Key.from(argv: argv))
    }

    /// `HostPairing`'s first-contact probe deliberately shares no master
    /// (`ControlMaster=no`, `ControlPath=none`) — it must never be gated.
    func testKeyExtractionExcludesControlPathNone() {
        let argv = ["-o", "ControlMaster=no", "-o", "ControlPath=none", "someuser@host.example.com"]
        XCTAssertNil(SSHConnectionGate.Key.from(argv: argv))
    }

    /// The render ControlMaster and the session ControlMaster for the SAME
    /// host are two different sockets with two separate `MaxSessions`
    /// budgets, and must produce two different keys.
    func testKeyExtractionDistinguishesTheRenderControlPath() {
        let session = ["-o", "ControlPath=/tmp/deck-cm-abc", "someuser@host.example.com", "session-agent"]
        let render = ["-C", "-o", "ControlPath=/tmp/deck-cm-abc-render", "someuser@host.example.com", "session-view"]
        XCTAssertNotEqual(SSHConnectionGate.Key.from(argv: session), SSHConnectionGate.Key.from(argv: render))
    }

    /// A LIBRARY-SUPPLIED TITLE CAN ITSELF CONTAIN AN `@`, and the quoting
    /// that keeps it safe from the remote shell does nothing to stop it
    /// from looking like a destination token to a naive scan — this is the
    /// exact case the stricter destination match exists for.
    func testKeyExtractionIsNotFooledByAFreeTextNameContainingAnAtSign() {
        let argv = ["-C", "-o", "ControlPath=/tmp/deck-cm-abc-render", "someuser@host.example.com",
                    "session-view", "--render-file", "-", "--name", "'Reach me @ work'"]
        XCTAssertEqual(SSHConnectionGate.Key.from(argv: argv)?.destination, "someuser@host.example.com")
    }
}
