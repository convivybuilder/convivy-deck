import XCTest
@testable import Deck

/// A stand-in credential for every test that doesn't care which one was
/// used, only that a credential was read — a file-level constant, never a
/// property on the test case, so the `@Sendable` closures below can capture
/// it without capturing the (non-`Sendable`) test case itself.
private let testCredential = MergeCredentialChoice(token: "token", identity: .account(login: "test"))

/// `MergePressModel`'s own orchestration — every external effect is an
/// injected seam, so no test here shells out to `gh`, touches the real
/// Keychain, calls `api.github.com`, or opens a real ssh forward.
@MainActor
final class MergePressModelTests: XCTestCase {
    private func row(
        repo: String = "acme/widgets", number: Int = 42, headSha: String? = "deadbeef",
        position: PRLadder.Position = .readyToMerge
    ) -> PRLadder.LadderResult {
        PRLadder.LadderResult(
            repo: repo, number: number, title: "A pull request", author: "someone",
            position: position, staleReviewCount: 0, updatedAt: nil, headSha: headSha)
    }

    private func host(_ address: String) -> HostEntry {
        HostEntry(name: "h", user: "operator", address: address)
    }

    // MARK: - Served-sessions precedes the credential read

    func testAConfiguredHostRefusalNeverReadsACredential() async {
        let model = MergePressModel()
        model.tokenStore = FakeMergeTokenStore()
        model.evaluateServedSessions = { _ in .configuredHostResolvesHere }
        let credentialRead = Box(false)
        model.readCredential = { _ in credentialRead.value = true; return testCredential }
        await model.confirmMerge(for: row())
        XCTAssertEqual(model.state(for: row()), .refused(.servesSessions(.configuredHostResolvesHere)))
        XCTAssertFalse(credentialRead.value)
    }

    func testABuilderInstallRefusalNeverReadsACredential() async {
        let model = MergePressModel()
        model.tokenStore = FakeMergeTokenStore()
        model.evaluateServedSessions = { _ in .builderInstalledHere }
        let credentialRead = Box(false)
        model.readCredential = { _ in credentialRead.value = true; return testCredential }
        await model.confirmMerge(for: row())
        XCTAssertEqual(model.state(for: row()), .refused(.servesSessions(.builderInstalledHere)))
        XCTAssertFalse(credentialRead.value)
    }

    func testNoServedSessionsRefusalReadsTheCredential() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        let credentialRead = Box(false)
        model.readCredential = { _ in credentialRead.value = true; return testCredential }
        model.performMerge = { _, _, _, _ in .merged(mergeCommitSha: "feedface") }
        model.reportMerge = { _, _, _ in .closed }
        await model.confirmMerge(for: row())
        XCTAssertTrue(credentialRead.value)
    }

    func testCloseAlsoRunsTheServedSessionsCheckBeforeAnyCredentialRead() async {
        let model = MergePressModel()
        model.tokenStore = FakeMergeTokenStore()
        model.evaluateServedSessions = { _ in .configuredHostResolvesHere }
        let credentialRead = Box(false)
        model.readCredential = { _ in credentialRead.value = true; return testCredential }
        await model.confirmClose(for: row())
        XCTAssertEqual(model.state(for: row()), .refused(.servesSessions(.configuredHostResolvesHere)))
        XCTAssertFalse(credentialRead.value)
    }

    // MARK: - No credential available

    func testNoCredentialRefusesBeforeAnyGitHubCall() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in nil }
        let mergeCalled = Box(false)
        model.performMerge = { _, _, _, _ in mergeCalled.value = true; return .merged(mergeCommitSha: "x") }
        await model.confirmMerge(for: row())
        XCTAssertEqual(model.state(for: row()), .noCredential)
        XCTAssertFalse(mergeCalled.value)
    }

    // MARK: - Expected sha is the row head

    func testTheExpectedHeadSentIsTheRowsOwnHeadSha() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        let capturedExpectedHead = Box<String?>(nil)
        model.performMerge = { _, _, expectedHeadSha, _ in
            capturedExpectedHead.value = expectedHeadSha
            return .merged(mergeCommitSha: "feedface")
        }
        model.reportMerge = { _, _, _ in .closed }
        await model.confirmMerge(for: row(headSha: "abc1234"))
        XCTAssertEqual(capturedExpectedHead.value, "abc1234")
    }

    func testARowWithNoHeadShaOffersNothingToConfirm() async {
        let model = MergePressModel()
        let mergeCalled = Box(false)
        model.performMerge = { _, _, _, _ in mergeCalled.value = true; return .merged(mergeCommitSha: "x") }
        await model.confirmMerge(for: row(headSha: nil))
        XCTAssertFalse(mergeCalled.value)
        XCTAssertEqual(model.state(for: row(headSha: nil)), .idle)
    }

    // MARK: - Each refusal draws its own cause

    func testAGitHubRefusalDrawsItsOwnCause() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        model.performMerge = { _, _, _, _ in .refused(.conflict) }
        await model.confirmMerge(for: row())
        XCTAssertEqual(model.state(for: row()), .refused(.conflict))
    }

    func testADifferentGitHubRefusalDrawsADifferentCause() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        model.performMerge = { _, _, _, _ in .refused(.protectedBranch) }
        await model.confirmMerge(for: row())
        XCTAssertEqual(model.state(for: row()), .refused(.protectedBranch))
    }

    // MARK: - Moved head redraws

    func testAMovedHeadRefusalTriggersOnLadderChanged() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        model.performMerge = { _, _, _, _ in .refused(.movedHead) }
        var headMovedCalled = false
        model.onLadderChanged = { headMovedCalled = true }
        await model.confirmMerge(for: row())
        XCTAssertTrue(headMovedCalled)
        XCTAssertEqual(model.state(for: row()), .refused(.movedHead))
    }

    func testANonMovedHeadRefusalNeverTriggersOnLadderChanged() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        model.performMerge = { _, _, _, _ in .refused(.conflict) }
        var headMovedCalled = false
        model.onLadderChanged = { headMovedCalled = true }
        await model.confirmMerge(for: row())
        XCTAssertFalse(headMovedCalled)
    }

    // MARK: - The report is sent only after a merge, and carries no credential

    func testTheReportIsSentOnlyAfterAMergeSucceeds() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        model.performMerge = { _, _, _, _ in .refused(.conflict) }
        let reportCalled = Box(false)
        model.reportMerge = { _, _, _ in reportCalled.value = true; return .closed }
        await model.confirmMerge(for: row())
        XCTAssertFalse(reportCalled.value, "a refused merge must never report to the Keel")
    }

    func testTheReportCarriesTheMergeCommitShaGitHubReportedNotTheExpectedHead() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        model.performMerge = { _, _, _, _ in .merged(mergeCommitSha: "feedface") }
        let capturedMergeCommitSha = Box<String?>(nil)
        model.reportMerge = { _, _, mergeCommitSha in
            capturedMergeCommitSha.value = mergeCommitSha
            return .closed
        }
        await model.confirmMerge(for: row(headSha: "deadbeef"))
        XCTAssertEqual(capturedMergeCommitSha.value, "feedface")
    }

    func testEachOfTheThreeReportOutcomesDrawsItsOwnState() async {
        for (outcome, expectedState) in [
            (MergeReportOutcome.closed, MergePressState.reported(.closed)),
            (MergeReportOutcome.waitingOnLeaseHolder, MergePressState.reported(.waitingOnLeaseHolder)),
            (MergeReportOutcome.reportFailed(reason: "boom"), MergePressState.reported(.reportFailed(reason: "boom"))),
        ] {
            let model = MergePressModel()
            model.evaluateServedSessions = { _ in nil }
            model.readCredential = { _ in testCredential }
            model.performMerge = { _, _, _, _ in .merged(mergeCommitSha: "feedface") }
            model.reportMerge = { _, _, _ in outcome }
            await model.confirmMerge(for: row())
            XCTAssertEqual(model.state(for: row()), expectedState)
        }
    }

    // MARK: - No retry, at most one PUT per press

    func testAPressWhileAnEarlierOneIsStillWorkingIsDropped() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let callCount = Counter()
        model.performMerge = { _, _, _, _ in
            callCount.increment()
            entered.signal()
            gate.wait()
            return .merged(mergeCommitSha: "feedface")
        }
        model.reportMerge = { _, _, _ in .closed }
        let pr = row()

        async let first: Void = model.confirmMerge(for: pr)
        // Waits for `entered` on a plain (non-async) dispatched block, bridged
        // back to this test's async body with a continuation — never a bare
        // blocking wait called directly from async code (unavailable), and
        // never a wait that would otherwise tie up this (main) actor's own
        // executor, which would starve `first`'s own MainActor work of a
        // chance to run at all.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }
        // A second press lands while the first is still inside `performMerge`.
        await model.confirmMerge(for: pr)
        gate.signal()
        await first

        XCTAssertEqual(callCount.value, 1, "a press on a key already working must never call performMerge again")
    }

    func testNoAutomaticRetryAfterARefusal() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        let callCount = Counter()
        model.performMerge = { _, _, _, _ in callCount.increment(); return .refused(.conflict) }
        await model.confirmMerge(for: row())
        // Nothing here presses again — the model itself must not loop.
        XCTAssertEqual(callCount.value, 1)
    }

    // MARK: - Close path

    func testCloseCallsPerformCloseAndDrawsClosedOnSuccess() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        let capturedRepo = Box<String?>(nil)
        let capturedNumber = Box<Int?>(nil)
        model.performClose = { repo, number, _ in
            capturedRepo.value = repo
            capturedNumber.value = number
            return nil
        }
        await model.confirmClose(for: row())
        XCTAssertEqual(model.state(for: row()), .closed)
        XCTAssertEqual(capturedRepo.value, "acme/widgets")
        XCTAssertEqual(capturedNumber.value, 42)
    }

    // MARK: - A cockpit close gives way to the capture

    private func captured(_ position: PRLadder.Position, at updatedAt: String?) -> PRLadder.LadderResult {
        PRLadder.LadderResult(
            repo: "acme/widgets", number: 42, title: "A pull request", author: "someone",
            position: position, staleReviewCount: 0, updatedAt: updatedAt, headSha: "deadbeef")
    }

    private func closedModel(over row: PRLadder.LadderResult) async -> MergePressModel {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        model.performClose = { _, _, _ in nil }
        await model.confirmClose(for: row)
        return model
    }

    func testAConfirmedCloseDrawsClosedBeforeTheCaptureCatchesUp() async {
        let before = captured(.readyToMerge, at: "2026-11-10T01:00:00Z")
        let model = await closedModel(over: before)
        XCTAssertEqual(model.drawnPosition(for: before), .closed(.closed))
        XCTAssertEqual(model.displayState(for: before), .closed)
    }

    /// The reviewer's case on #424: close from the cockpit, the capture
    /// reads CLOSED, then the pull request is reopened on GitHub. The next
    /// capture reads it open, and the row must draw open with its buttons.
    func testAReopenAfterTheCaptureSawTheCloseDrawsOpen() async {
        let before = captured(.readyToMerge, at: "2026-11-10T01:00:00Z")
        let model = await closedModel(over: before)
        XCTAssertEqual(model.drawnPosition(for: captured(.closed(.closed), at: nil)), .closed(.closed))
        let reopened = captured(.readyToMerge, at: nil)
        XCTAssertEqual(model.drawnPosition(for: reopened), .readyToMerge)
        XCTAssertEqual(model.displayState(for: reopened), .idle)
    }

    /// Reopened before any capture read CLOSED: a newer capture than the one
    /// the close was pressed over is the authority. Real rows carry
    /// `updatedAt` (`producedAt ?? ingestedAt`; live pr-state rows carry
    /// both, and `produced_at` is GitHub's `updated_at`, which a reopen
    /// moves), so the populated fixture is the common case.
    func testAReopenBeforeTheCaptureSawTheCloseDrawsOpenOnTheNextCapture() async {
        let before = captured(.readyToMerge, at: "2026-11-10T01:00:00Z")
        let model = await closedModel(over: before)
        let newer = captured(.inReview, at: "2026-11-10T01:03:00Z")
        XCTAssertEqual(model.drawnPosition(for: newer), .inReview)
        XCTAssertEqual(model.displayState(for: newer), .idle)
    }

    func testAConfirmedMergeKeepsDrawingMergedWhateverTheCaptureSays() {
        XCTAssertEqual(
            PRLadderRow.effectivePosition(.readyToMerge, pressState: .reported(.reportFailed(reason: "x"))),
            .closed(.merged))
    }

    func testCloseRefusalDrawsItsOwnCause() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        model.performClose = { _, _, _ in
            .unauthorizedCredential(.account(login: "test"), status: 403, githubMessage: "Forbidden")
        }
        await model.confirmClose(for: row())
        XCTAssertEqual(
            model.state(for: row()),
            .refused(.unauthorizedCredential(.account(login: "test"), status: 403, githubMessage: "Forbidden")))
    }

    func testCloseNeverReportsToTheKeel() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        model.performClose = { _, _, _ in nil }
        let reportCalled = Box(false)
        model.reportMerge = { _, _, _ in reportCalled.value = true; return .closed }
        await model.confirmClose(for: row())
        XCTAssertFalse(reportCalled.value)
    }

    // MARK: - Confirmation states

    func testBeginMergeConfirmationSetsConfirmingMerge() {
        let model = MergePressModel()
        model.beginMergeConfirmation(for: row())
        XCTAssertEqual(model.state(for: row()), .confirmingMerge)
    }

    func testCancelReturnsToIdle() {
        let model = MergePressModel()
        model.beginMergeConfirmation(for: row())
        model.cancel(for: row())
        XCTAssertEqual(model.state(for: row()), .idle)
    }

    // MARK: - servedSessionsReason for display

    func testServedSessionsReasonIsNilBeforeHostsIsEverSet() {
        let model = MergePressModel()
        XCTAssertNil(model.servedSessionsReason)
    }

    func testSettingHostsRefreshesServedSessionsReason() async {
        let model = MergePressModel()
        model.tokenStore = FakeMergeTokenStore()
        model.evaluateServedSessions = { _ in .configuredHostResolvesHere }
        model.hosts = [host("this-mac.example")]
        await model.servedSessionsRefresh?.value
        XCTAssertEqual(model.servedSessionsReason, .configuredHostResolvesHere)
    }

    func testARefreshReportsWhetherAPastedTokenIsStored() async {
        let model = MergePressModel()
        let store = FakeMergeTokenStore()
        store.stored = "a-token"
        model.tokenStore = store
        model.evaluateServedSessions = { _ in .builderInstalledHere }
        model.hosts = [host("this-mac.example")]
        await model.servedSessionsRefresh?.value
        XCTAssertTrue(model.pastedTokenStored)
    }

    func testAServedSessionsRefusalOnAPressRefreshesTheDisplayReason() async {
        let model = MergePressModel()
        model.tokenStore = FakeMergeTokenStore()
        model.evaluateServedSessions = { _ in .builderInstalledHere }
        await model.confirmMerge(for: row())
        await model.servedSessionsRefresh?.value
        XCTAssertEqual(model.servedSessionsReason, .builderInstalledHere)
    }

    // MARK: - A settled press reloads the ladder

    func testASuccessfulMergeTriggersOnLadderChanged() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        model.performMerge = { _, _, _, _ in .merged(mergeCommitSha: "abc123") }
        model.reportMerge = { _, _, _ in .closed }
        var called = false
        model.onLadderChanged = { called = true }
        await model.confirmMerge(for: row())
        XCTAssertTrue(called)
    }

    func testASuccessfulCloseTriggersOnLadderChanged() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in testCredential }
        model.performClose = { _, _, _ in nil }
        var called = false
        model.onLadderChanged = { called = true }
        await model.confirmClose(for: row())
        XCTAssertTrue(called)
    }

    // MARK: - Saving a pasted token

    func testSavingAPastedTokenReturnsTheRowToIdle() async {
        let model = MergePressModel()
        model.evaluateServedSessions = { _ in nil }
        model.readCredential = { _ in nil }
        await model.confirmMerge(for: row())
        XCTAssertEqual(model.state(for: row()), .noCredential)

        let store = FakeMergeTokenStore()
        model.tokenStore = store
        await model.savePastedToken("a-token", for: row())
        XCTAssertEqual(store.stored, "a-token")
        XCTAssertTrue(model.pastedTokenStored)
        XCTAssertEqual(model.state(for: row()), .idle)
    }

    func testAPastedTokenIsNotStoredOnAMachineThatServesSessions() async {
        let model = MergePressModel()
        let store = FakeMergeTokenStore()
        model.tokenStore = store
        model.evaluateServedSessions = { _ in .builderInstalledHere }
        await model.savePastedToken("a-token", for: row())
        XCTAssertNil(store.stored)
        XCTAssertEqual(store.saveCallCount, 0)
        XCTAssertFalse(model.pastedTokenStored)
        XCTAssertEqual(model.state(for: row()), .refused(.servesSessions(.builderInstalledHere)))
    }

    func testRemovingAPastedTokenClearsTheStoreAndTheOffer() async {
        let model = MergePressModel()
        let store = FakeMergeTokenStore()
        store.stored = "a-token"
        model.tokenStore = store
        model.evaluateServedSessions = { _ in .builderInstalledHere }
        model.hosts = [host("this-mac.example")]
        await model.servedSessionsRefresh?.value
        XCTAssertTrue(model.pastedTokenStored)

        await model.removePastedToken()
        XCTAssertNil(store.stored)
        XCTAssertFalse(model.pastedTokenStored)
    }
}

/// A plain, non-isolated lock-protected box, for a value a `@Sendable`
/// closure needs to write and the (MainActor) test body reads back
/// afterward — a local `var` cannot be mutated inside a `@Sendable`
/// closure, which every seam on `MergePressModel` is declared as.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// A plain, non-isolated counter for the "at most one call" tests above,
/// which read it from the main actor after a detached call has finished.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}
