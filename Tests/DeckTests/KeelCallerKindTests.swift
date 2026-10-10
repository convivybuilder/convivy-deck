import XCTest
@testable import Deck

/// `KeelCallerKind`: which token a request carries — an operator's own
/// session, or a dispatched agent's — told apart by the token presented, and
/// nothing else. No test here constructs one from a peer identity or an
/// account, because this type has no initializer that accepts either; the
/// only inputs it takes are the two token cases themselves.
final class KeelCallerKindTests: XCTestCase {

    func testOperatorAndAgentAreDistinctCasesEvenWithTheSameTokenText() {
        // Deliberately the SAME raw string in both cases: what makes them
        // different is which case wraps the token, per
        // `deck/decisions/0002` — "told apart by WHICH TOKEN IS PRESENTED",
        // not by any property of the string itself. If this type ever grew
        // an initializer that inferred the kind from the token's shape (a
        // prefix, a length) rather than requiring the caller to state it,
        // this test would still pass by construction — which is exactly the
        // point: the caller must say which kind it is presenting.
        let token = KeelToken("shared-looking-value")
        let operatorCaller = KeelCallerKind.operatorSession(token)
        let agentCaller = KeelCallerKind.agent(token)
        XCTAssertNotEqual(operatorCaller, agentCaller)
    }

    func testTwoOperatorTokensWithDifferentValuesAreNotEqual() {
        XCTAssertNotEqual(
            KeelCallerKind.operatorSession(KeelToken("token-a")),
            KeelCallerKind.operatorSession(KeelToken("token-b")))
    }

    /// A token's `description` never prints the raw value — so a call site
    /// that interpolates a `KeelCallerKind` into a log line (an error
    /// message, a crash report) can't leak the credential by forgetting to
    /// redact it, because redaction isn't something a call site does at all.
    /// `dump(_:)` READS STORED PROPERTIES THROUGH `Mirror` AND STEPS PAST
    /// BOTH STRING CONVERSIONS, so the test above passing says nothing about
    /// this path. Before `KeelToken` conformed to `CustomReflectable`, this
    /// printed the raw secret under an `agent:` child while the line above it
    /// read `<redacted>` — the redaction working and being walked around.
    /// `dump` is reachable from LLDB's `po` and from anything Mirror-based,
    /// which is a real place for a token to land.
    func testDumpDoesNotPrintATokensRawValue() {
        let secret = "SUPER-SECRET-VALUE"
        var out = ""
        dump(KeelCallerKind.agent(KeelToken(secret)), to: &out)
        XCTAssertFalse(out.contains(secret), "dump leaked the token: \(out)")
        // Not vacuous: the dump must actually have produced something.
        XCTAssertTrue(out.contains("agent"), "dump produced nothing to check: \(out)")
    }

    func testDumpOfABareTokenDoesNotPrintItsRawValue() {
        let secret = "OPERATOR-SESSION-TOKEN"
        var out = ""
        dump(KeelToken(secret), to: &out)
        XCTAssertFalse(out.contains(secret), "dump leaked the token: \(out)")
    }

    func testStringReflectingNeverPrintsATokensRawValue() {
        let secret = "REFLECTED-TOKEN"
        XCTAssertFalse(String(reflecting: KeelToken(secret)).contains(secret))
        XCTAssertFalse(String(reflecting: KeelCallerKind.operatorSession(KeelToken(secret))).contains(secret))
    }

    func testATokensDescriptionNeverPrintsItsRawValue() {
        let token = KeelToken("super-secret-agent-token-do-not-log-me")
        XCTAssertFalse("\(token)".contains("super-secret-agent-token-do-not-log-me"))
    }
}
