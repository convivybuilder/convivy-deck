import XCTest
@testable import Deck

final class ReconnectPolicyTests: XCTestCase {
    func testFirstAttemptCentersOnBaseDelay() {
        let policy = ReconnectPolicy(baseDelay: 1, maxDelay: 30, jitterFraction: 0.5)
        XCTAssertEqual(policy.delay(forAttempt: 1, jitterSource: 0.5), 1, accuracy: 0.0001)
    }

    func testJitterStaysWithinBounds() {
        let policy = ReconnectPolicy(baseDelay: 1, maxDelay: 30, jitterFraction: 0.5)
        // attempt 3 -> exponential = 4, spread = 2, so range is [2, 6]
        XCTAssertEqual(policy.delay(forAttempt: 3, jitterSource: 0), 2, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 3, jitterSource: 1), 6, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 3, jitterSource: 0.5), 4, accuracy: 0.0001)
    }

    func testDelayCapsAtMaxDelay() {
        let policy = ReconnectPolicy(baseDelay: 1, maxDelay: 30, jitterFraction: 0.5)
        // attempt 10 -> exponential would be 512 without the cap
        XCTAssertLessThanOrEqual(policy.delay(forAttempt: 10, jitterSource: 1), 30 * 1.5)
    }

    func testStateMachineTransitionsThroughLossAndRecovery() {
        let machine = ConnectionStateMachine(
            policy: ReconnectPolicy(baseDelay: 1, maxDelay: 30, jitterFraction: 0),
            jitterSource: { 0 }
        )
        XCTAssertEqual(machine.phase, .connecting)

        XCTAssertEqual(machine.connectSucceeded(), .connected)

        XCTAssertEqual(machine.connectionLost(), .reconnecting(attempt: 1, delay: 1))
        XCTAssertEqual(machine.connectionLost(), .reconnecting(attempt: 2, delay: 2))
        XCTAssertEqual(machine.connectionLost(), .reconnecting(attempt: 3, delay: 4))

        // Recovery resets the attempt counter, so a later loss starts the
        // backoff over rather than continuing to climb.
        XCTAssertEqual(machine.connectSucceeded(), .connected)
        XCTAssertEqual(machine.connectionLost(), .reconnecting(attempt: 1, delay: 1))
    }
}
