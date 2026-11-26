import XCTest
@testable import Deck

/// `MergeReportClient.send`/`.outcome` — the report to the Bosun's
/// `/merge-reports`, over an injected `transport` seam so no test here opens
/// a real ssh forward or socket. Covers the three-way draw
/// (`closed`/`waitingOnLeaseHolder`/`reportFailed`) and the report body's
/// own shape.
final class MergeReportClientTests: XCTestCase {
    private func jsonBody(_ json: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - reportBody

    func testReportBodyCarriesExactlyTheThreeRequiredKeysWithPRAsAString() throws {
        let data = try MergeReportClient.reportBody(repo: "acme/widgets", number: 42, mergeCommitSha: "feedface")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["repo"] as? String, "acme/widgets")
        XCTAssertEqual(json["pr"] as? String, "42", "pr must be a NUMBER STRING, per validate_report")
        XCTAssertEqual(json["merge_commit_sha"] as? String, "feedface")
        XCTAssertEqual(Set(json.keys), Set(["repo", "pr", "merge_commit_sha"]))
    }

    // MARK: - send: the report carries no credential

    func testSendNeverAttachesACredentialToTheTransportCall() {
        var capturedBody: Data?
        _ = MergeReportClient.send(repo: "acme/widgets", number: 42, mergeCommitSha: "feedface", transport: { body in
            capturedBody = body
            return (200, self.jsonBody(["ok": true, "reason": "reconciled"]))
        })
        let body = try! XCTUnwrap(capturedBody)
        let json = try! XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["repo", "pr", "merge_commit_sha"]),
                       "the report body must carry no credential field of any kind")
    }

    // MARK: - outcome: the three-way draw

    func testOkReconciledIsClosed() {
        XCTAssertEqual(
            MergeReportClient.outcome(from: jsonBody(["ok": true, "reason": "reconciled"])), .closed)
    }

    func testOkAlreadyFixedIsClosed() {
        XCTAssertEqual(
            MergeReportClient.outcome(from: jsonBody(["ok": true, "reason": "already_fixed"])), .closed)
    }

    func testHeldIsWaitingOnLeaseHolder() {
        XCTAssertEqual(
            MergeReportClient.outcome(from: jsonBody(["ok": false, "reason": "held", "lease": ["holder": "someone"]])),
            .waitingOnLeaseHolder)
    }

    func testAnyOtherRefusalReasonIsReportFailed() {
        XCTAssertEqual(
            MergeReportClient.outcome(from: jsonBody(["ok": false, "reason": "library_unreachable"])),
            .reportFailed(reason: "library_unreachable"))
    }

    func testAMalformedBodyIsReportFailedRatherThanThrowing() {
        let outcome = MergeReportClient.outcome(from: Data("not json".utf8))
        guard case .reportFailed = outcome else {
            return XCTFail("expected .reportFailed, got \(outcome)")
        }
    }

    func testSendTurnsATransportThrowIntoReportFailed() {
        struct BoomError: Error {}
        let outcome = MergeReportClient.send(
            repo: "acme/widgets", number: 42, mergeCommitSha: "feedface",
            transport: { _ in throw BoomError() })
        guard case .reportFailed = outcome else {
            return XCTFail("expected .reportFailed, got \(outcome)")
        }
    }

    func testSendNeverSendsMoreThanOneRequest() {
        var callCount = 0
        _ = MergeReportClient.send(repo: "acme/widgets", number: 42, mergeCommitSha: "feedface", transport: { _ in
            callCount += 1
            return (200, self.jsonBody(["ok": true, "reason": "reconciled"]))
        })
        XCTAssertEqual(callCount, 1)
    }
}
