import XCTest
@testable import Deck

/// `HostTestOutcome.classify` — the Hosts tab's Test button's pure mapping
/// from ssh's own stderr text to one of the three outcomes it reports
/// plainly. See `deck/specs/multiple-sessions-per-project` §"Crews on
/// different hosts": "reachable... refused, or unreachable/timed out."
final class HostTestOutcomeTests: XCTestCase {
    func testConnectionRefusedClassifiesAsRefused() {
        XCTAssertEqual(HostTestOutcome.classify(errorText: "ssh: connect to host 1.2.3.4 port 22: Connection refused"),
                       .refused("ssh: connect to host 1.2.3.4 port 22: Connection refused"))
    }

    func testOperationTimedOutClassifiesAsUnreachable() {
        if case .unreachable = HostTestOutcome.classify(errorText: "ssh: connect to host 1.2.3.4 port 22: Operation timed out") {
            // expected
        } else {
            XCTFail("expected .unreachable")
        }
    }

    func testConnectionTimedOutIsCaseInsensitive() {
        if case .unreachable = HostTestOutcome.classify(errorText: "CONNECTION TIMED OUT") {
        } else {
            XCTFail("expected .unreachable")
        }
    }

    func testNoRouteToHostClassifiesAsUnreachable() {
        if case .unreachable = HostTestOutcome.classify(errorText: "ssh: connect to host 1.2.3.4 port 22: No route to host") {
        } else {
            XCTFail("expected .unreachable")
        }
    }

    func testCouldNotResolveHostnameClassifiesAsUnreachable() {
        if case .unreachable = HostTestOutcome.classify(errorText: "ssh: Could not resolve hostname bogus: nodename nor servname provided") {
        } else {
            XCTFail("expected .unreachable")
        }
    }

    func testPermissionDeniedClassifiesAsRefused() {
        if case .refused = HostTestOutcome.classify(errorText: "guest@1.2.3.4: Permission denied (publickey).") {
        } else {
            XCTFail("expected .refused")
        }
    }

    func testHostKeyVerificationFailedClassifiesAsRefused() {
        if case .refused = HostTestOutcome.classify(errorText: "Host key verification failed.") {
        } else {
            XCTFail("expected .refused")
        }
    }
}
