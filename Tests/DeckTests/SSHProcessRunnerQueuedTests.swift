import XCTest
@testable import Deck

/// A thread-safe box for one value set from a background closure and read
/// back on the test's own thread afterward — the same `NSLock`-boxed-state
/// idiom `HeldKBSavesTests.SigningLog` uses.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// A thread-safe counter, for "how many at once" and "how many calls total"
/// alike.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private(set) var maxObserved = 0

    @discardableResult
    func increment() -> Int {
        lock.lock(); count += 1; maxObserved = max(maxObserved, count); defer { lock.unlock() }; return count
    }

    func decrement() {
        lock.lock(); count -= 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }; return count
    }
}

private func fakeOutcome(stderr: String = "", status: Int32 = 0, timedOut: Bool = false) -> SSHProcessOutcome {
    SSHProcessOutcome(stdout: Data(), stderr: stderr, terminationStatus: status, timedOut: timedOut)
}

/// `SSHProcessRunner.runQueued` — the gate/requeue wrapper CQ·164 adds
/// (issue_01M4RZJ13RZG4Z5YR8C68BAEBP). Every test here injects a fake `run`
/// closure and its own `SSHConnectionGate` instance: no real ssh, per the
/// item's own test discipline.
final class SSHProcessRunnerQueuedTests: XCTestCase {
    private let argv = ["-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/deck-cm-abc",
                        "someuser@host.example.com", "session-agent", "state", "deck"]

    /// ARGV WITH NO SHARED CONTROL SOCKET (a control command, a local
    /// config dump, `ControlPath=none`) skips the gate and runs exactly
    /// once, unconditionally — `SSHControlSocket.check`/`.clear` must never
    /// be slowed down or rate-limited by this wrapper.
    func testUngatedArgvRunsOnceWithNoGateInvolved() throws {
        let checkArgv = ["-O", "check", "-o", "ControlPath=/tmp/deck-cm-abc", "someuser@host.example.com"]
        let calls = Counter()
        let result = try SSHProcessRunner.runQueued(checkArgv, timeout: 5) { _, _, _ in
            calls.increment()
            return fakeOutcome(stderr: "Master running (pid=1)\n")
        }
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(result.stderr, "Master running (pid=1)\n")
    }

    /// THE CAP IS HONOURED. A burst of calls through `runQueued` against
    /// one gate/key never runs more than `cap` concurrently, whether they
    /// are quick one-shots or (simulated by a longer fake `run`) calls that
    /// take a while to answer.
    func testConcurrentCallsNeverExceedTheCap() throws {
        let gate = SSHConnectionGate()
        let counter = Counter()
        let group = DispatchGroup()
        let argv = self.argv
        for _ in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                _ = try? SSHProcessRunner.runQueued(
                    argv, timeout: 5, queueTimeout: 10, gate: gate
                ) { _, _, _ in
                    counter.increment()
                    Thread.sleep(forTimeInterval: 0.02)
                    counter.decrement()
                    return fakeOutcome()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
        XCTAssertLessThanOrEqual(counter.maxObserved, SSHConnectionGate.defaultCap)
    }

    /// QUEUE TIME NEVER COUNTS AGAINST THE WATCHDOG. A call that has to
    /// wait well past `timeout` for a free slot must still run with the
    /// FULL `timeout` once granted — the wait is bounded by `queueTimeout`
    /// alone, a separate clock from the one `SSHProcessRunner.run`'s own
    /// watchdog starts only once the process actually begins.
    func testQueueWaitDoesNotShortenOrAffectTheRunTimeout() throws {
        let gate = SSHConnectionGate()
        let key = try XCTUnwrap(SSHConnectionGate.Key.from(argv: argv))
        // `runQueued` looks up its own cap for this destination, so the
        // gate's own cap must be narrowed to 1 — not merely the `cap`
        // argument this test's own `acquire` call below happens to pass.
        gate.setCap(1, forDestination: key.destination)
        try gate.acquire(key, cap: 1, queueTimeout: 10) // occupy the only slot

        let observedTimeout = Box<TimeInterval?>(nil)
        let startedAt = Box<Date?>(nil)
        let group = DispatchGroup()
        group.enter()
        let argv = self.argv
        DispatchQueue.global().async {
            defer { group.leave() }
            _ = try? SSHProcessRunner.runQueued(
                argv, timeout: 7, queueTimeout: 10, gate: gate
            ) { _, _, timeout in
                observedTimeout.value = timeout
                startedAt.value = Date()
                return fakeOutcome()
            }
        }
        // Hold the slot well past the 7s `timeout` the queued call asks
        // for, so if queue time were (wrongly) deducted from it, the
        // eventual run would see a reduced or already-expired budget.
        Thread.sleep(forTimeInterval: 1.0)
        let releasedAt = Date()
        gate.release(key)

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(observedTimeout.value, 7, "the run timeout must arrive unchanged by how long the call queued")
        let startDelay = try XCTUnwrap(startedAt.value).timeIntervalSince(releasedAt)
        XCTAssertLessThan(abs(startDelay), 1.0, "the process must start promptly once a slot frees, not on its own delayed clock")
    }

    /// A MUX REFUSAL REQUEUES — IT NEVER FALLS BACK AND NEVER SURFACES AS
    /// THE RAW REFUSAL. `runQueued` must retry through the gate until it
    /// gets a clean answer, returning THAT, not the refusal.
    func testAMuxRefusalRequeuesRatherThanReturningTheRefusal() throws {
        let attempts = Counter()
        let result = try SSHProcessRunner.runQueued(argv, timeout: 5) { _, _, _ in
            let n = attempts.increment()
            if n == 1 {
                return fakeOutcome(
                    stderr: "mux_client_request_session: session request failed: Session open refused by peer\n",
                    status: 255)
            }
            return fakeOutcome(stderr: "", status: 0)
        }
        XCTAssertEqual(attempts.value, 2, "a refusal must be retried, not returned")
        XCTAssertEqual(result.terminationStatus, 0)
    }

    /// THE FALLBACK ITSELF IS NEVER ACCEPTED AS A SUCCESS, even though the
    /// fallback connection it describes would otherwise look exactly like
    /// one: `ControlMaster=auto` can report "disabling multiplexing" and
    /// still exit 0 with real stdout once the slow direct connection
    /// completes — `runQueued` must not hand that answer back as-is.
    func testTheDisablingMultiplexingFallbackIsRequeuedNotAccepted() throws {
        let attempts = Counter()
        let result = try SSHProcessRunner.runQueued(argv, timeout: 5) { _, _, _ in
            let n = attempts.increment()
            if n == 1 {
                return SSHProcessOutcome(
                    stdout: "stale-answer-from-the-fallback".data(using: .utf8)!,
                    stderr: "ControlSocket /tmp/deck-cm-abc already exists, disabling multiplexing\n",
                    terminationStatus: 0, timedOut: false)
            }
            return fakeOutcome(stderr: "", status: 0)
        }
        XCTAssertEqual(attempts.value, 2)
        XCTAssertNotEqual(result.stdout, "stale-answer-from-the-fallback".data(using: .utf8))
    }

    /// EXHAUSTED RETRIES THROW `masterFull`, NEVER RETURN THE REFUSAL AS A
    /// SUCCESS. Bounded by `MuxRefusalAbsorptionPolicy`'s own default
    /// budget, the same policy every interactive pane already uses.
    func testRefusalsPastTheAbsorptionBudgetThrowMasterFullRatherThanSucceeding() throws {
        let attempts = Counter()
        XCTAssertThrowsError(
            try SSHProcessRunner.runQueued(argv, timeout: 5) { _, _, _ in
                attempts.increment()
                return fakeOutcome(stderr: "mux_client_request_session: refused\n", status: 255)
            }
        ) { error in
            XCTAssertEqual(error as? SSHConnectionGateError, .masterFull)
        }
        XCTAssertEqual(attempts.value, MuxRefusalAbsorptionPolicy().maxConsecutive + 1,
                       "must retry exactly the absorption budget before giving up")
    }

    /// A GENUINE (NON-MUX) FAILURE IS NEVER RETRIED — it returns at once,
    /// exactly as an ungated call would, so a real transport problem is not
    /// hidden behind pointless requeues.
    func testANonMuxFailureIsReturnedAtOnceWithNoRetry() throws {
        let attempts = Counter()
        let result = try SSHProcessRunner.runQueued(argv, timeout: 5) { _, _, _ in
            attempts.increment()
            return fakeOutcome(stderr: "Permission denied (publickey).", status: 255)
        }
        XCTAssertEqual(attempts.value, 1)
        XCTAssertEqual(result.terminationStatus, 255)
    }

    /// A GATE QUEUE TIMEOUT PROPAGATES AS ITS OWN ERROR, never as a call to
    /// the injected `run` closure at all.
    func testGateQueueTimeoutNeverInvokesRun() throws {
        let gate = SSHConnectionGate()
        let key = try XCTUnwrap(SSHConnectionGate.Key.from(argv: argv))
        gate.setCap(1, forDestination: key.destination)
        try gate.acquire(key, cap: 1, queueTimeout: 10)
        defer { gate.release(key) }

        let invoked = Box(false)
        XCTAssertThrowsError(
            try SSHProcessRunner.runQueued(argv, timeout: 5, queueTimeout: 0.2, gate: gate) { _, _, _ in
                invoked.value = true
                return fakeOutcome()
            }
        ) { error in
            XCTAssertEqual(error as? SSHConnectionGateError, .queueTimedOut)
        }
        XCTAssertFalse(invoked.value)
    }
}
