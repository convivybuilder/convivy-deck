import XCTest
@testable import Deck

/// `GitHubMergeClient.merge`/`.close` — every exchange goes through the
/// injected `perform` seam, so no test here reaches `api.github.com`.
final class GitHubMergeClientTests: XCTestCase {
    private func jsonBody(_ json: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: json)
    }

    private let credential = MergeCredentialChoice(token: "tok", identity: .account(login: "work-account"))

    // MARK: - merge: request shape

    func testMergeSendsAPUTToTheMergeEndpointWithTheExpectedHeadAsSha() throws {
        var capturedRequest: URLRequest?
        _ = try GitHubMergeClient.merge(
            repo: "acme/widgets", number: 42, expectedHeadSha: "deadbeef", credential: credential,
            perform: { request in
                capturedRequest = request
                return (200, self.jsonBody(["merged": true, "sha": "feedface"]))
            })
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/acme/widgets/pulls/42/merge")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["sha"], "deadbeef")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testMergeNeverSendsMoreThanOneRequest() throws {
        var callCount = 0
        _ = try GitHubMergeClient.merge(
            repo: "acme/widgets", number: 42, expectedHeadSha: "deadbeef", credential: credential,
            perform: { _ in
                callCount += 1
                return (200, self.jsonBody(["merged": true, "sha": "feedface"]))
            })
        XCTAssertEqual(callCount, 1)
    }

    // MARK: - merge: outcomes

    func testAMergedResponseReturnsTheMergeCommitSha() throws {
        let outcome = try GitHubMergeClient.merge(
            repo: "acme/widgets", number: 42, expectedHeadSha: "deadbeef", credential: credential,
            perform: { _ in (200, self.jsonBody(["merged": true, "sha": "feedface"])) })
        XCTAssertEqual(outcome, .merged(mergeCommitSha: "feedface"))
    }

    func testAMovedHeadResponseClassifiesAsMovedHeadAndCarriesNoMergeCommit() throws {
        let outcome = try GitHubMergeClient.merge(
            repo: "acme/widgets", number: 42, expectedHeadSha: "deadbeef", credential: credential,
            perform: { _ in
                (409, self.jsonBody(["message": "Head branch was modified. Review and try the merge again."]))
            })
        XCTAssertEqual(outcome, .refused(.movedHead))
    }

    func testA403ResponseClassifiesAsUnauthorizedCredentialAndNamesTheLogin() throws {
        let outcome = try GitHubMergeClient.merge(
            repo: "acme/widgets", number: 42, expectedHeadSha: "deadbeef", credential: credential,
            perform: { _ in (403, self.jsonBody(["message": "Forbidden"])) })
        XCTAssertEqual(
            outcome,
            .refused(.unauthorizedCredential(
                .account(login: "work-account"), status: 403, githubMessage: "Forbidden")))
    }

    func testA200WithNoShaFieldRefusesRatherThanClaimingAMerge() throws {
        let outcome = try GitHubMergeClient.merge(
            repo: "acme/widgets", number: 42, expectedHeadSha: "deadbeef", credential: credential,
            perform: { _ in (200, self.jsonBody(["merged": true])) })
        guard case .refused(.unrecognised) = outcome else {
            return XCTFail("expected .refused(.unrecognised), got \(outcome)")
        }
    }

    func testAnInvalidRepoThrowsBeforeAnyRequestIsBuilt() {
        var called = false
        XCTAssertThrowsError(try GitHubMergeClient.merge(
            repo: "not-a-repo", number: 1, expectedHeadSha: "x", credential: credential,
            perform: { _ in called = true; return (200, Data()) }))
        XCTAssertFalse(called)
    }

    // MARK: - close

    func testCloseSendsAPATCHWithStateClosed() throws {
        var capturedRequest: URLRequest?
        let outcome = try GitHubMergeClient.close(
            repo: "acme/widgets", number: 42, credential: credential,
            perform: { request in
                capturedRequest = request
                return (200, Data())
            })
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/acme/widgets/pulls/42")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["state"], "closed")
        XCTAssertNil(outcome)
    }

    func testCloseRefusalClassifiesTheSameWayMergeDoes() throws {
        let outcome = try GitHubMergeClient.close(
            repo: "acme/widgets", number: 42, credential: credential,
            perform: { _ in (401, self.jsonBody(["message": "Bad credentials"])) })
        XCTAssertEqual(
            outcome,
            .unauthorizedCredential(.account(login: "work-account"), status: 401, githubMessage: "Bad credentials"))
    }

    func testCloseNeverSendsMoreThanOneRequest() throws {
        var callCount = 0
        _ = try GitHubMergeClient.close(
            repo: "acme/widgets", number: 42, credential: credential,
            perform: { _ in callCount += 1; return (200, Data()) })
        XCTAssertEqual(callCount, 1)
    }

    // MARK: - canPush

    func testCanPushIsTrueWhenPermissionsPushReadsTrue() {
        let canPush = GitHubMergeClient.canPush(
            repo: "acme/widgets", token: "tok",
            perform: { _ in (200, self.jsonBody(["permissions": ["push": true]])) })
        XCTAssertTrue(canPush)
    }

    func testCanPushIsFalseWhenPermissionsPushReadsFalse() {
        let canPush = GitHubMergeClient.canPush(
            repo: "acme/widgets", token: "tok",
            perform: { _ in (200, self.jsonBody(["permissions": ["push": false]])) })
        XCTAssertFalse(canPush)
    }

    func testCanPushIsFalseOnANon200Status() {
        let canPush = GitHubMergeClient.canPush(
            repo: "acme/widgets", token: "tok",
            perform: { _ in (403, self.jsonBody(["message": "Forbidden"])) })
        XCTAssertFalse(canPush)
    }

    func testCanPushIsFalseOnANonJSONBody() {
        let canPush = GitHubMergeClient.canPush(
            repo: "acme/widgets", token: "tok",
            perform: { _ in (200, "not json".data(using: .utf8)!) })
        XCTAssertFalse(canPush)
    }

    func testCanPushSendsAGETToTheRepoEndpointWithTheToken() {
        var capturedRequest: URLRequest?
        _ = GitHubMergeClient.canPush(
            repo: "acme/widgets", token: "tok",
            perform: { request in
                capturedRequest = request
                return (200, self.jsonBody(["permissions": ["push": true]]))
            })
        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://api.github.com/repos/acme/widgets")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }
}
