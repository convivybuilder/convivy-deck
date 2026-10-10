import XCTest
@testable import Deck

/// `SSHStderrClassifier` recognises exactly one condition — OpenSSH's
/// multiplexing-client refusal — and must leave every other ssh failure
/// alone. A real failure (host down, key rejected, session gone) absorbed by
/// mistake would be a far worse bug than the transient refusal this exists
/// to hide; these tests are the guardrail against that.
final class SSHStderrClassifierTests: XCTestCase {
    func testRecognisesTheMuxRefusal() {
        let line = "mux_client_request_session: session request failed: Session open refused by peer"
        XCTAssertEqual(SSHStderrClassifier.classify(line), .transientMuxRefusal)
    }

    func testRecognisesTheMuxRefusalEmbeddedInSurroundingText() {
        let line = "ControlSocket /tmp/deck-ssh-mux\r\nmux_client_request_session: session request failed: Session open refused by peer\r\n"
        XCTAssertEqual(SSHStderrClassifier.classify(line), .transientMuxRefusal)
    }

    func testHostUnreachableIsNotAbsorbed() {
        let line = "ssh: connect to host mini.local port 22: Operation timed out"
        XCTAssertEqual(SSHStderrClassifier.classify(line), .other)
    }

    func testPermissionDeniedIsNotAbsorbed() {
        let line = "operator@example.com: Permission denied (publickey)."
        XCTAssertEqual(SSHStderrClassifier.classify(line), .other)
    }

    func testSessionNotFoundIsNotAbsorbed() {
        let line = "can't find session: deck"
        XCTAssertEqual(SSHStderrClassifier.classify(line), .other)
    }

    func testEmptyTextIsNotAbsorbed() {
        XCTAssertEqual(SSHStderrClassifier.classify(""), .other)
    }
}

/// `MuxRefusalAbsorptionPolicy` bounds how many consecutive refusals a
/// caller may hide. Absorption must be bounded, not unconditional — a
/// genuinely wedged ControlMaster must eventually reach the user rather than
/// retry forever behind a silent veil.
final class MuxRefusalAbsorptionPolicyTests: XCTestCase {
    func testAbsorbsUpToTheBound() {
        var policy = MuxRefusalAbsorptionPolicy(maxConsecutive: 3)
        for _ in 0..<3 {
            XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
        }
    }

    func testSurfacesOnceTheBoundIsExceeded() {
        var policy = MuxRefusalAbsorptionPolicy(maxConsecutive: 3)
        for _ in 0..<3 {
            XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
        }
        // The 4th consecutive refusal in a row is not absorbed — a genuinely
        // wedged connection must eventually reach the user.
        XCTAssertFalse(policy.shouldAbsorb(classification: .transientMuxRefusal))
    }

    func testTheCountResetsAfterSurfacingSoALaterRunGetsTheFullBudget() {
        var policy = MuxRefusalAbsorptionPolicy(maxConsecutive: 2)
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
        XCTAssertFalse(policy.shouldAbsorb(classification: .transientMuxRefusal))
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
    }

    func testANonMuxFailureIsNeverAbsorbedAndResetsTheCount() {
        var policy = MuxRefusalAbsorptionPolicy(maxConsecutive: 3)
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
        // A real failure in the middle of a run is never absorbed...
        XCTAssertFalse(policy.shouldAbsorb(classification: .other))
        // ...and resets the count, so the next mux refusal gets the full
        // budget rather than inheriting the interrupted run's tally.
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
    }

    func testSucceededResetsTheCount() {
        var policy = MuxRefusalAbsorptionPolicy(maxConsecutive: 3)
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
        policy.succeeded()
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
        XCTAssertTrue(policy.shouldAbsorb(classification: .transientMuxRefusal))
    }
}
