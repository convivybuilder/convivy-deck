import XCTest
@testable import Deck

/// An in-memory `MergeTokenStore` so no test here touches the real login
/// Keychain.
final class FakeMergeTokenStore: MergeTokenStore, @unchecked Sendable {
    var stored: String?
    private(set) var saveCallCount = 0
    private(set) var removeCallCount = 0

    func read() -> String? { stored }
    func save(_ token: String) { stored = token; saveCallCount += 1 }
    func remove() { stored = nil; removeCallCount += 1 }
    func exists() -> Bool { stored != nil }
}

/// `MergeCredentialSource.resolve`: the first logged-in `gh` account that
/// can push, falling back to the pasted token — none of the four reads
/// here shells out to `gh`, touches the real Keychain, or reaches GitHub.
final class MergeCredentialTests: XCTestCase {
    private func account(_ login: String, active: Bool = false) -> GHAccount {
        GHAccount(login: login, active: active)
    }

    func testTheActiveAccountIsUsedWhenItCanPush() {
        let credential = MergeCredentialSource.resolve(
            repo: "acme/widgets",
            listAccounts: { [self.account("work-account", active: true), self.account("home-account")] },
            readAccountToken: { login in login == "work-account" ? "token-a" : "token-b" },
            canPush: { token, _ in token == "token-a" },
            readPastedToken: { XCTFail("must not fall back to the pasted token"); return nil })
        XCTAssertEqual(credential, MergeCredentialChoice(token: "token-a", identity: .account(login: "work-account")))
    }

    func testTheSecondAccountIsUsedWhenOnlyItCanPush() {
        let credential = MergeCredentialSource.resolve(
            repo: "acme/widgets",
            listAccounts: { [self.account("work-account", active: true), self.account("home-account")] },
            readAccountToken: { login in login == "work-account" ? "token-a" : "token-b" },
            canPush: { token, _ in token == "token-b" },
            readPastedToken: { XCTFail("must not fall back to the pasted token"); return nil })
        XCTAssertEqual(credential, MergeCredentialChoice(token: "token-b", identity: .account(login: "home-account")))
    }

    func testNoAccountsFallsBackToThePastedToken() {
        let credential = MergeCredentialSource.resolve(
            repo: "acme/widgets",
            listAccounts: { [] },
            readAccountToken: { _ in XCTFail("must not read a token for an account gh never listed"); return nil },
            canPush: { _, _ in XCTFail("must not check push for an account gh never listed"); return false },
            readPastedToken: { "pasted-token" })
        XCTAssertEqual(
            credential,
            MergeCredentialChoice(token: "pasted-token", identity: .pastedToken(couldNotPush: [], unreadable: [])))
    }

    func testNoAccountCanPushFallsBackToThePastedTokenNamingTheAccountsThatCouldNotPush() {
        let credential = MergeCredentialSource.resolve(
            repo: "acme/widgets",
            listAccounts: { [self.account("work-account", active: true), self.account("home-account")] },
            readAccountToken: { login in login == "work-account" ? "token-a" : "token-b" },
            canPush: { _, _ in false },
            readPastedToken: { "pasted-token" })
        XCTAssertEqual(
            credential,
            MergeCredentialChoice(
                token: "pasted-token",
                identity: .pastedToken(couldNotPush: ["work-account", "home-account"], unreadable: [])))
    }

    /// An account whose token `gh` would not hand over was never asked about
    /// push, so the fallback must record it as unreadable, apart from the
    /// account GitHub said can't push.
    func testAnUnreadableAccountAndAnAccountThatCannotPushFallBackToThePastedTokenRecordedApart() {
        let credential = MergeCredentialSource.resolve(
            repo: "acme/widgets",
            listAccounts: { [self.account("work-account", active: true), self.account("home-account")] },
            readAccountToken: { login in login == "work-account" ? nil : "token-b" },
            canPush: { token, _ in
                XCTAssertEqual(token, "token-b", "must not check push without a token")
                return false
            },
            readPastedToken: { "pasted-token" })
        XCTAssertEqual(
            credential,
            MergeCredentialChoice(
                token: "pasted-token",
                identity: .pastedToken(couldNotPush: ["home-account"], unreadable: ["work-account"])))
    }

    func testEveryAccountUnreadableFallsBackToThePastedTokenWithNoPushClaim() {
        let credential = MergeCredentialSource.resolve(
            repo: "acme/widgets",
            listAccounts: { [self.account("work-account", active: true)] },
            readAccountToken: { _ in nil },
            canPush: { _, _ in XCTFail("must not check push without a token"); return false },
            readPastedToken: { "pasted-token" })
        XCTAssertEqual(
            credential,
            MergeCredentialChoice(
                token: "pasted-token", identity: .pastedToken(couldNotPush: [], unreadable: ["work-account"])))
    }

    func testNoAccountCanPushAndNoPastedTokenSendsTheFirstReadableAccountSoGitHubsRefusalNamesIt() {
        let credential = MergeCredentialSource.resolve(
            repo: "acme/widgets",
            listAccounts: { [self.account("work-account", active: true), self.account("home-account")] },
            readAccountToken: { login in login == "work-account" ? nil : "token-b" },
            canPush: { _, _ in false },
            readPastedToken: { nil })
        XCTAssertEqual(credential, MergeCredentialChoice(token: "token-b", identity: .account(login: "home-account")))
    }

    func testNilWhenGHListsNoAccountAndNoPastedTokenExists() {
        let credential = MergeCredentialSource.resolve(
            repo: "acme/widgets",
            listAccounts: { [] },
            readAccountToken: { _ in XCTFail("no account to read"); return nil },
            canPush: { _, _ in false },
            readPastedToken: { nil })
        XCTAssertNil(credential)
    }

    func testAnAccountGHListsButCannotReadATokenForIsSkippedRatherThanStoppingTheSearch() {
        let credential = MergeCredentialSource.resolve(
            repo: "acme/widgets",
            listAccounts: { [self.account("work-account", active: true), self.account("home-account")] },
            readAccountToken: { login in login == "work-account" ? nil : "token-b" },
            canPush: { token, _ in token == "token-b" },
            readPastedToken: { XCTFail("must not fall back to the pasted token"); return nil })
        XCTAssertEqual(credential, MergeCredentialChoice(token: "token-b", identity: .account(login: "home-account")))
    }

    // MARK: - GHAuthStatus.parse

    func testParseReadsLoginsFromTheObservedGHJSONShapeActiveFirst() {
        let json = """
        {"hosts":{"github.com":[
            {"login":"home-account","active":false,"state":"login_with_browser"},
            {"login":"work-account","active":true,"state":"login_with_browser"}
        ]}}
        """.data(using: .utf8)!
        XCTAssertEqual(
            GHAuthStatus.parse(json),
            [GHAccount(login: "work-account", active: true), GHAccount(login: "home-account", active: false)])
    }

    func testParseAnswersNoAccountsOnAnUnparseableBody() {
        XCTAssertEqual(GHAuthStatus.parse("not json".data(using: .utf8)!), [])
    }

    // MARK: - GHAuthToken.resolvedExecutablePath

    func testResolvedExecutablePathPicksTheFirstCandidateThatExists() {
        let path = GHAuthToken.resolvedExecutablePath(
            candidates: ["/nonexistent/gh", "/opt/homebrew/bin/gh", "/usr/bin/gh"],
            isExecutable: { $0 == "/opt/homebrew/bin/gh" })
        XCTAssertEqual(path, "/opt/homebrew/bin/gh")
    }

    func testResolvedExecutablePathIsNilWhenNoCandidateExists() {
        let path = GHAuthToken.resolvedExecutablePath(
            candidates: ["/nonexistent/gh"], isExecutable: { _ in false })
        XCTAssertNil(path)
    }

    // MARK: - CredentialIdentity.label

    func testAnAccountsLabelIsItsLogin() {
        XCTAssertEqual(CredentialIdentity.account(login: "home-account").label, "home-account")
    }

    func testAPastedTokenLabelsItselfTheSavedTokenWithNoParentheses() {
        let identity = CredentialIdentity.pastedToken(couldNotPush: ["work-account"], unreadable: ["home-account"])
        XCTAssertEqual(identity.label, "the saved token")
    }

    // MARK: - CredentialIdentity.fallbackReason

    func testAnAccountHasNoFallbackReason() {
        XCTAssertNil(CredentialIdentity.account(login: "home-account").fallbackReason)
    }

    func testAPastedTokenWithNoAccountsListedHasNoFallbackReason() {
        XCTAssertNil(CredentialIdentity.pastedToken(couldNotPush: [], unreadable: []).fallbackReason)
    }

    func testAccountsThatCouldNotPushAreNamedAsSuch() {
        XCTAssertEqual(
            CredentialIdentity.pastedToken(couldNotPush: ["work-account", "home-account"], unreadable: [])
                .fallbackReason,
            "Deck used it because work-account and home-account can't push here.")
    }

    func testAnUnreadableAccountIsNeverSaidToBeUnableToPush() {
        let reason = CredentialIdentity.pastedToken(couldNotPush: [], unreadable: ["work-account"]).fallbackReason
        XCTAssertEqual(reason, "Deck used it because gh couldn't read a token for work-account.")
        XCTAssertFalse(reason?.contains("push") ?? true)
    }

    func testBothKindsOfUnusableAccountAreNamedApart() {
        XCTAssertEqual(
            CredentialIdentity.pastedToken(couldNotPush: ["home-account"], unreadable: ["work-account"])
                .fallbackReason,
            "Deck used it because home-account can't push here and gh couldn't read a token for work-account.")
    }

    func testThreeLoginsAreListedWithASerialComma() {
        XCTAssertEqual(
            CredentialIdentity.pastedToken(couldNotPush: ["a-account", "b-account", "c-account"], unreadable: [])
                .fallbackReason,
            "Deck used it because a-account, b-account, and c-account can't push here.")
    }

    // MARK: - MergeTokenKeychain's protocol surface, against the fake store

    func testSavingAndReadingARoundTrips() {
        let store = FakeMergeTokenStore()
        store.save("a-pasted-token")
        XCTAssertEqual(store.read(), "a-pasted-token")
    }

    func testRemoveClearsTheStore() {
        let store = FakeMergeTokenStore()
        store.save("a-pasted-token")
        store.remove()
        XCTAssertNil(store.read())
        XCTAssertFalse(store.exists())
    }
}
