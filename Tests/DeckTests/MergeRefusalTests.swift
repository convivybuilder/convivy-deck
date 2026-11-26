import XCTest
@testable import Deck

/// `MergeRefusal.classify(status:body:)` — one test per known GitHub shape,
/// plus the degrade cases: a merged 200, a non-JSON body, an unmatched
/// status, and the one case the classifier must not confuse with another
/// (a status-check 405 misread as a protected-branch 405).
final class MergeRefusalTests: XCTestCase {
    private func body(_ json: [String: String]) -> Data {
        try! JSONSerialization.data(withJSONObject: json)
    }

    /// Every test below that isn't exercising the unauthorized-credential
    /// cases classifies a status those cases never match, so which
    /// credential is passed makes no difference to the result — a fixed
    /// placeholder keeps every call site shaped the same.
    private let unused = CredentialIdentity.account(login: "unused")

    // MARK: - 200, merged

    func testA200WithMergedTrueClassifiesAsNil() {
        let data = try! JSONSerialization.data(withJSONObject: ["merged": true, "sha": "abc123"])
        XCTAssertNil(MergeRefusal.classify(status: 200, body: data, credential: unused))
    }

    // MARK: - Moved head

    func testA409HeadBranchModifiedClassifiesAsMovedHead() {
        let data = body(["message": "Head branch was modified. Review and try the merge again."])
        XCTAssertEqual(MergeRefusal.classify(status: 409, body: data, credential: unused), .movedHead)
    }

    // MARK: - Conflict

    func testA405NotMergeableClassifiesAsConflict() {
        let data = body(["message": "Pull Request is not mergeable"])
        XCTAssertEqual(MergeRefusal.classify(status: 405, body: data, credential: unused), .conflict)
    }

    /// The live result on convivy/builder-merge-rehearsal#5, 2026-11-10:
    /// GitHub's exact observed text for a conflicting pull request.
    func testA405MergeConflictsClassifiesAsConflict() {
        let data = body(["message": "Pull Request has merge conflicts"])
        XCTAssertEqual(MergeRefusal.classify(status: 405, body: data, credential: unused), .conflict)
    }

    // MARK: - Protected branch — the real rehearsal body

    /// The real body from the 2026-11-08 rehearsal on
    /// convivy/builder-merge-rehearsal.
    func testTheRehearsalProtectedBranchBodyClassifiesAsProtectedBranch() {
        let data = """
        {"documentation_url":"https://docs.github.com/rest/pulls/pulls#merge-a-pull-request",\
        "message":"Repository rule violations found\\n\\nCannot update this protected ref.\\n\\n",\
        "status":"405"}
        """.data(using: .utf8)!
        XCTAssertEqual(MergeRefusal.classify(status: 405, body: data, credential: unused), .protectedBranch)
    }

    // MARK: - Red required check

    func testA405RequiredStatusCheckExpectedClassifiesAsRedRequiredCheck() {
        let data = body(["message": "Required status check \"build-test\" is expected"])
        XCTAssertEqual(MergeRefusal.classify(status: 405, body: data, credential: unused), .redRequiredCheck)
    }

    func testA405RequiredStatusCheckFailingClassifiesAsRedRequiredCheck() {
        let data = body(["message": "Required status check \"build-test\" is failing"])
        XCTAssertEqual(MergeRefusal.classify(status: 405, body: data, credential: unused), .redRequiredCheck)
    }

    /// A status-check 405 must never be misread as a protected-branch
    /// 405 — the two share the same HTTP status, and only the message
    /// text tells them apart.
    func testAStatusCheck405IsNotReadAsProtectedBranch() {
        let data = body(["message": "Required status check \"build-test\" is expected"])
        XCTAssertNotEqual(MergeRefusal.classify(status: 405, body: data, credential: unused), .protectedBranch)
    }

    // MARK: - Unauthorized credential

    private let account = CredentialIdentity.account(login: "work-account")

    func testA401ClassifiesAsUnauthorizedCredential() {
        let data = body(["message": "Bad credentials"])
        XCTAssertEqual(
            MergeRefusal.classify(status: 401, body: data, credential: account),
            .unauthorizedCredential(account, status: 401, githubMessage: "Bad credentials"))
    }

    func testA403ClassifiesAsUnauthorizedCredential() {
        let data = body(["message": "Forbidden"])
        XCTAssertEqual(
            MergeRefusal.classify(status: 403, body: data, credential: account),
            .unauthorizedCredential(account, status: 403, githubMessage: "Forbidden"))
    }

    /// GitHub answers 404, not 403, when a credential cannot see a private
    /// repository at all — still unauthorized credential, not unrecognised.
    func testA404ClassifiesAsUnauthorizedCredential() {
        let data = body(["message": "Not Found"])
        XCTAssertEqual(
            MergeRefusal.classify(status: 404, body: data, credential: account),
            .unauthorizedCredential(account, status: 404, githubMessage: "Not Found"))
    }

    /// A non-JSON body still classifies as unauthorized and still names the
    /// credential Deck used — only the GitHub message is missing.
    func testA401WithANonJSONBodyStillClassifiesAsUnauthorizedAndNamesTheLogin() {
        let data = "<html>401 Unauthorized</html>".data(using: .utf8)!
        guard case .unauthorizedCredential(let credential, let status, let githubMessage) =
            MergeRefusal.classify(status: 401, body: data, credential: account)
        else {
            return XCTFail("expected .unauthorizedCredential")
        }
        XCTAssertEqual(credential, account)
        XCTAssertEqual(status, 401)
        XCTAssertNil(githubMessage)
    }

    /// When no listed account was usable, the refusal's credential is the
    /// pasted token carrying why, so the line names the saved token, GitHub's
    /// answer, and the reason Deck fell back, in that order and without
    /// nested parentheses.
    func testAnUnauthorizedPastedTokenRefusalSaysWhyDeckFellBack() {
        let pastedToken = CredentialIdentity.pastedToken(couldNotPush: ["home-account"], unreadable: ["work-account"])
        let data = body(["message": "Resource not accessible by integration"])
        let refusal = MergeRefusal.classify(status: 403, body: data, credential: pastedToken)
        guard case .unauthorizedCredential(let credential, _, _) = refusal else {
            return XCTFail("expected .unauthorizedCredential")
        }
        XCTAssertEqual(credential, pastedToken)
        XCTAssertEqual(
            refusal?.message,
            "GitHub refused the merge for the saved token (403: Resource not accessible by integration). " +
                "Deck used it because home-account can't push here and gh couldn't read a token for " +
                "work-account. Sign in to gh with an account that can merge here, then try again.")
    }

    func testAnUnauthorizedAccountRefusalCarriesNoFallbackSentence() {
        let data = body(["message": "Bad credentials"])
        XCTAssertEqual(
            MergeRefusal.classify(status: 401, body: data, credential: .account(login: "work-account"))?.message,
            "GitHub refused the merge for work-account (401: Bad credentials). Sign in to gh with an " +
                "account that can merge here, then try again.")
    }

    // MARK: - Degrade: non-JSON body

    func testANonJSONBodyClassifiesAsUnrecognisedCarryingTheRawText() {
        let data = "<html>502 Bad Gateway</html>".data(using: .utf8)!
        guard case .unrecognised(let status, let message) = MergeRefusal.classify(
            status: 502, body: data, credential: account)
        else {
            return XCTFail("expected .unrecognised")
        }
        XCTAssertEqual(status, 502)
        XCTAssertEqual(message, "<html>502 Bad Gateway</html>")
    }

    // MARK: - Degrade: an unknown status

    func testAnUnknown422ClassifiesAsUnrecognisedCarryingTheMessageVerbatim() {
        let data = body(["message": "Validation Failed"])
        guard case .unrecognised(let status, let message) = MergeRefusal.classify(
            status: 422, body: data, credential: unused)
        else {
            return XCTFail("expected .unrecognised")
        }
        XCTAssertEqual(status, 422)
        XCTAssertEqual(message, "Validation Failed")
    }

    /// A 405 whose message matches none of the three known 405 shapes
    /// degrades to unrecognised rather than guessing protected branch.
    func testA405WithAnUnmatchedMessageClassifiesAsUnrecognised() {
        let data = body(["message": "Something GitHub has never told this client before"])
        guard case .unrecognised(let status, let message) = MergeRefusal.classify(
            status: 405, body: data, credential: unused)
        else {
            return XCTFail("expected .unrecognised")
        }
        XCTAssertEqual(status, 405)
        XCTAssertEqual(message, "Something GitHub has never told this client before")
    }

    /// A 409 whose message isn't the moved-head shape degrades rather than
    /// being read as a moved head it never actually reported.
    func testA409WithAnUnmatchedMessageClassifiesAsUnrecognised() {
        let data = body(["message": "Merge conflict for some other reason"])
        guard case .unrecognised(let status, _) = MergeRefusal.classify(
            status: 409, body: data, credential: unused)
        else {
            return XCTFail("expected .unrecognised")
        }
        XCTAssertEqual(status, 409)
    }
}
