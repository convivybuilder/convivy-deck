import XCTest
@testable import Deck

/// `PRLadderModel.refresh`'s repo-switch invariant: `coveredReadings` (backed
/// by `currentKeys`) and `result` must never name different repos, since
/// `SessionReviewChip`'s reuse path trusts `coveredReadings` alone to decide
/// whether `result`'s rows are safe to match a PR number against
/// (`deck-reviewer`'s round-1 finding on #237).
///
/// Also covers the per-repo cache `issue_01M2P60KDY9KPXWMZ4C6G1CJ52` added:
/// a switch to a repo already cached must serve its rows instantly instead
/// of flashing empty, the cache is bounded and evicts least-recently-used,
/// and the timer sweep (`reloadEveryCachedRepo`) reaches every cached repo,
/// not only the selected one.
@MainActor
final class PRLadderModelTests: XCTestCase {

    private let target = TestHost.target

    /// `nonisolated static` so the `@Sendable` fetch closures below can call
    /// it synchronously without capturing `self` (the test case is
    /// `@MainActor` and not `Sendable`) or hopping actors.
    private nonisolated static func ladder(repo: String, number: Int) -> PRLadder.FetchResult {
        .ladder([
            PRLadder.LadderResult(
                repo: repo, number: number, title: nil, author: nil,
                position: .inReview, staleReviewCount: 0, updatedAt: nil),
        ], truncated: false)
    }

    /// Blocks `fetch` on `gate` until signaled, and signals `entered` the
    /// moment it starts running — the same shape
    /// `CheckoutDocumentsTests.testAReplyForASessionNoLongerSelectedIsDropped`
    /// uses to observe state mid-fetch rather than only before and after.
    private func gatedFetch(
        entered: DispatchSemaphore, gate: DispatchSemaphore, result: PRLadder.FetchResult
    ) -> @Sendable (SSHTarget, String, String) throws -> PRLadder.FetchResult {
        { _, _, _ in
            entered.signal()
            gate.wait()
            return result
        }
    }

    /// The exact case the review finding named: the selected repo changes
    /// while a fetch for the old repo is not what's running — the *new*
    /// repo's own fetch is in flight. `coveredReadings` reports the new repo as
    /// soon as `refresh` is called (synchronously), so `result` must already
    /// be `nil` at that same instant rather than trailing the old repo's rows
    /// until the new fetch returns.
    func testSwitchingRepoClearsResultBeforeTheNewFetchCompletes() async {
        let model = PRLadderModel()
        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/a", number: 5) }
        await model.refresh(target: target, owner: "acme", repoName: "a")
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/a", number: 5))

        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        model.fetchLadder = gatedFetch(entered: entered, gate: gate, result: Self.ladder(repo: "acme/b", number: 5))

        let switching = Task { await model.refresh(target: target, owner: "acme", repoName: "b") }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }

        // Mid-fetch: coveredReadings already names the new repo, so result must
        // already have moved with it rather than still holding repo a's rows.
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.coveredReadings.first?.owner, "acme")
        XCTAssertEqual(model.coveredReadings.first?.repoName, "b")
        XCTAssertNil(model.result)
        XCTAssertNil(model.fetchError)

        gate.signal()
        await switching.value
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/b", number: 5))
        XCTAssertFalse(model.isLoading)
    }

    /// A fetch for a repo the model has since moved away from must not land
    /// after the fact — the guard `fetch` already had (`guard key ==
    /// current`), re-asserted here so a future edit to the clear-on-switch
    /// fix above can't silently widen the window this closes back up.
    func testALateResultFromASupersededKeyIsDropped() async {
        let model = PRLadderModel()
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        model.fetchLadder = gatedFetch(entered: entered, gate: gate, result: Self.ladder(repo: "acme/a", number: 1))

        let slow = Task { await model.refresh(target: target, owner: "acme", repoName: "a") }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }

        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/b", number: 1) }
        await model.refresh(target: target, owner: "acme", repoName: "b")
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/b", number: 1))
        XCTAssertEqual(model.coveredReadings.first?.repoName, "b")

        gate.signal()
        await slow.value

        // The superseded repo a fetch must not overwrite repo b's result,
        // and coveredReadings must still agree with whatever result now holds.
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/b", number: 1))
        XCTAssertEqual(model.coveredReadings.first?.repoName, "b")
    }

    /// `reload()` re-reads the *same* repo `current` already names — not a
    /// switch — so it may keep the old result on screen while it refreshes,
    /// the same "don't flash empty" posture `CheckoutDocumentsModel.reload`
    /// takes. Distinguishing this from a real switch is what makes the fix
    /// above correct rather than merely clearing on every fetch.
    func testReloadOfTheSameRepoKeepsTheOldResultWhileItRefetches() async {
        let model = PRLadderModel()
        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/a", number: 1) }
        await model.refresh(target: target, owner: "acme", repoName: "a")
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/a", number: 1))

        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        model.fetchLadder = gatedFetch(entered: entered, gate: gate, result: Self.ladder(repo: "acme/a", number: 2))

        let reloading = Task { await model.reload() }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/a", number: 1))
        XCTAssertEqual(model.coveredReadings.first?.repoName, "a")

        gate.signal()
        await reloading.value
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/a", number: 2))
    }

    /// The behavior this PR exists for: switching to a repo already cached
    /// from an earlier visit this session must show its rows immediately —
    /// no flash to empty — while a background fetch re-reads it. Paired
    /// with `testSwitchingRepoClearsResultBeforeTheNewFetchCompletes` above,
    /// which is the still-must-fail-empty case: a repo never seen before.
    func testSwitchingBackToAPreviouslyFetchedRepoServesCachedRowsImmediately() async {
        let model = PRLadderModel()
        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/a", number: 1) }
        await model.refresh(target: target, owner: "acme", repoName: "a")
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/a", number: 1))

        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/b", number: 2) }
        await model.refresh(target: target, owner: "acme", repoName: "b")
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/b", number: 2))

        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        model.fetchLadder = gatedFetch(entered: entered, gate: gate, result: Self.ladder(repo: "acme/a", number: 3))

        let switching = Task { await model.refresh(target: target, owner: "acme", repoName: "a") }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }

        // Mid-fetch: "a"'s rows from its first visit must already be
        // showing, not nil.
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.coveredReadings.first?.repoName, "a")
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/a", number: 1))

        gate.signal()
        await switching.value
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/a", number: 3))
        XCTAssertFalse(model.isLoading)
    }

    /// `fetchedAt` records when the selected repo's rows were last fetched
    /// successfully, and a fetch with no prior success has nothing to keep:
    /// a failure on the first fetch for a repo leaves both `result` and
    /// `fetchedAt` nil, with `fetchError` as the only honest answer.
    func testAFirstFetchFailureHasNoRowsOrFetchedAtToKeep() async {
        let model = PRLadderModel()
        struct Boom: Error {}
        model.fetchLadder = { _, _, _ in throw Boom() }
        await model.refresh(target: target, owner: "acme", repoName: "a")
        XCTAssertNil(model.result)
        XCTAssertNotNil(model.fetchError)
        XCTAssertNil(model.fetchedAt)
    }

    /// `issue_01M2PMHZVF1WN0VSJRHZHD2PD6`: a refresh failure on a repo that
    /// already has cached rows must keep those rows and their `fetchedAt`
    /// on screen, with `fetchError` set alongside — not replace them with
    /// an error, which is what let one transient failure blank a repo the
    /// operator never asked to refresh. This is the assertion that fails
    /// against the pre-fix code: `entries[key] = Entry(result: nil, ...)`
    /// discarded `result` and `fetchedAt` unconditionally on the catch path.
    func testARefreshFailureOnARepoWithCachedRowsKeepsTheRowsAndFetchedAt() async {
        let model = PRLadderModel()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        model.now = { fixedNow }
        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/a", number: 1) }
        await model.refresh(target: target, owner: "acme", repoName: "a")
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/a", number: 1))
        XCTAssertEqual(model.fetchedAt, fixedNow)
        XCTAssertNil(model.fetchError)

        struct Boom: Error {}
        model.fetchLadder = { _, _, _ in throw Boom() }
        await model.reload()

        XCTAssertEqual(model.result, Self.ladder(repo: "acme/a", number: 1))
        XCTAssertEqual(model.fetchedAt, fixedNow)
        XCTAssertNotNil(model.fetchError)
    }

    /// The severity #issue_01M2PMHZVF1WN0VSJRHZHD2PD6 names directly: the
    /// unprompted sweep (`reloadEveryCachedRepo`) must not blank a cached
    /// repo the operator isn't even looking at when that repo's refresh
    /// fails — the rows and `fetchedAt` for every other repo the sweep
    /// touches must survive, each with its own `fetchError` set.
    func testASweepFailureOnOneRepoKeepsThatRepoAndEveryOtherReposRows() async {
        let model = PRLadderModel()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        model.now = { fixedNow }
        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/a", number: 1) }
        await model.refresh(target: target, owner: "acme", repoName: "a")

        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/b", number: 1) }
        await model.refresh(target: target, owner: "acme", repoName: "b")

        struct Boom: Error {}
        model.fetchLadder = { _, _, repoName in
            if repoName == "a" { throw Boom() }
            return Self.ladder(repo: "acme/b", number: 2)
        }
        await model.reloadEveryCachedRepo()

        let cachedA = model.cachedReading(target: target, owner: "acme", repoName: "a")
        XCTAssertEqual(cachedA?.result, Self.ladder(repo: "acme/a", number: 1), "repo a's rows must survive its own failed refresh")
        XCTAssertEqual(cachedA?.fetchedAt, fixedNow)
        XCTAssertNotNil(cachedA?.fetchError)

        let cachedB = model.cachedReading(target: target, owner: "acme", repoName: "b")
        XCTAssertEqual(cachedB?.result, Self.ladder(repo: "acme/b", number: 2), "repo b's refresh succeeded and must be unaffected by a's failure")
        XCTAssertNil(cachedB?.fetchError)
    }

    /// The cache is bounded by `cacheLimit` and evicts least-recently-used,
    /// not on a timer: a repo still within the limit keeps its cached rows
    /// no matter how long ago it was last selected, and only a genuinely
    /// new repo past the limit costs the oldest entry its place.
    func testTheLeastRecentlyUsedRepoIsEvictedOnceTheCacheLimitIsReached() async {
        let model = PRLadderModel()
        let limit = PRLadderModel.cacheLimit
        for i in 0..<limit {
            model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/r\(i)", number: i) }
            await model.refresh(target: target, owner: "acme", repoName: "r\(i)")
        }
        // The cache now holds r0...r(limit-1); r0 is the least recently used.

        // Touching r1 again (already cached, well within the limit) must
        // not evict anything: its cached rows show immediately, mid a slow
        // re-fetch.
        let entered1 = DispatchSemaphore(value: 0)
        let gate1 = DispatchSemaphore(value: 0)
        model.fetchLadder = gatedFetch(entered: entered1, gate: gate1, result: Self.ladder(repo: "acme/r1", number: 111))
        let switchingToR1 = Task { await model.refresh(target: target, owner: "acme", repoName: "r1") }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered1.wait()
                continuation.resume()
            }
        }
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/r1", number: 1))
        gate1.signal()
        await switchingToR1.value
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/r1", number: 111))

        // A brand-new repo past the limit evicts the true least-recently-used
        // entry — r0, since r1 was just touched again above.
        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/rNew", number: 999) }
        await model.refresh(target: target, owner: "acme", repoName: "rNew")

        // r0 was evicted: switching back to it shows nil mid-fetch, exactly
        // like a repo this model has never seen.
        let entered0 = DispatchSemaphore(value: 0)
        let gate0 = DispatchSemaphore(value: 0)
        model.fetchLadder = gatedFetch(entered: entered0, gate: gate0, result: Self.ladder(repo: "acme/r0", number: 0))
        let switchingToR0 = Task { await model.refresh(target: target, owner: "acme", repoName: "r0") }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered0.wait()
                continuation.resume()
            }
        }
        XCTAssertNil(model.result)
        gate0.signal()
        await switchingToR0.value
    }

    /// The timer's sweep (`reloadEveryCachedRepo`) refreshes every cached
    /// repo, not only the selected one, so a later switch usually lands on
    /// warm rows instead of a repo this model hasn't touched recently.
    func testReloadEveryCachedRepoRefreshesEntriesOtherThanTheSelectedOne() async {
        let model = PRLadderModel()
        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/a", number: 1) }
        await model.refresh(target: target, owner: "acme", repoName: "a")

        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/b", number: 1) }
        await model.refresh(target: target, owner: "acme", repoName: "b")
        // "b" is selected now; "a" sits cached but unselected.

        model.fetchLadder = { _, _, repoName in
            repoName == "a" ? Self.ladder(repo: "acme/a", number: 2) : Self.ladder(repo: "acme/b", number: 2)
        }
        await model.reloadEveryCachedRepo()

        let cachedA = model.cachedReading(target: target, owner: "acme", repoName: "a")
        XCTAssertEqual(cachedA?.result, Self.ladder(repo: "acme/a", number: 2))
        XCTAssertEqual(model.result, Self.ladder(repo: "acme/b", number: 2))
    }

    /// `deck-reviewer`'s round-2 finding on #243: `reloadEveryCachedRepo`
    /// snapshots `entries.keys` once, so an eviction landing after that
    /// snapshot but before the sweep reaches the evicted key must not be
    /// undone by the sweep's own fetch writing the key straight back in —
    /// that made the key permanently unevictable, since `touch` (and so
    /// `lruKeys`) is only ever called from `refresh`, never from a fetch the
    /// sweep starts on its own.
    func testAnEntryEvictedMidSweepIsNotResurrectedByTheSweep() async {
        let model = PRLadderModel()
        let limit = PRLadderModel.cacheLimit
        for i in 0..<limit {
            model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/r\(i)", number: i) }
            await model.refresh(target: target, owner: "acme", repoName: "r\(i)")
        }
        // Cache now holds r0...r(limit-1), exactly at cacheLimit; r0 is the
        // least recently used and is what the eviction below takes.

        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        model.fetchLadder = { _, _, repoName in
            entered.signal()
            gate.wait()
            return Self.ladder(repo: "acme/\(repoName)", number: 999)
        }

        let sweeping = Task { await model.reloadEveryCachedRepo() }
        // Wait for the sweep's first fetch to start, so its snapshot of
        // every cached key (r0 included) is already taken and stale by the
        // time the eviction below runs.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }

        // A switch to a repo never seen before evicts the true
        // least-recently-used entry, r0, while the sweep still holds r0 in
        // its stale snapshot and hasn't reached it yet.
        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/rNew", number: 1) }
        await model.refresh(target: target, owner: "acme", repoName: "rNew")
        XCTAssertNil(model.cachedReading(target: target, owner: "acme", repoName: "r0"))

        // Release every fetch the sweep is still working through, including
        // whichever one is r0's — it must come back absent rather than
        // resurrected.
        for _ in 0..<limit {
            gate.signal()
        }
        await sweeping.value

        XCTAssertNil(
            model.cachedReading(target: target, owner: "acme", repoName: "r0"),
            "the sweep's stale snapshot must not resurrect an entry evicted mid-sweep")
        // The cache still holds exactly cacheLimit entries — r1...r(limit-1)
        // plus rNew — never more.
        for i in 1..<limit {
            XCTAssertNotNil(model.cachedReading(target: target, owner: "acme", repoName: "r\(i)"))
        }
        XCTAssertNotNil(model.cachedReading(target: target, owner: "acme", repoName: "rNew"))
    }

    /// Deselecting (a nil target/owner/repoName, e.g. no crew resolved) must
    /// not evict the cache — only a crew switch past `cacheLimit` does.
    /// Re-selecting a repo visited before deselecting still shows its rows
    /// immediately.
    func testClearingTheSelectionDoesNotEvictTheCache() async {
        let model = PRLadderModel()
        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/a", number: 1) }
        await model.refresh(target: target, owner: "acme", repoName: "a")

        await model.refresh(target: nil, owner: nil, repoName: nil)
        XCTAssertNil(model.result)
        XCTAssertTrue(model.coveredReadings.isEmpty)

        let cached = model.cachedReading(target: target, owner: "acme", repoName: "a")
        XCTAssertEqual(cached?.result, Self.ladder(repo: "acme/a", number: 1))
    }

    // MARK: - refresh(target:repos:) — several repos, one crew
    // (issue_01M2P5JHM1G8XCMKM4HEHVJB2P: a crew maps to several cache keys)

    /// Every repo in the list gets its own fetch, and each repo's own rows
    /// are readable afterward through `cachedReading` — the plain "fetch
    /// per repo" case with no failures anywhere.
    func testRefreshWithSeveralReposFetchesEachOne() async {
        let model = PRLadderModel()
        model.fetchLadder = { _, _, repoName in Self.ladder(repo: "acme/\(repoName)", number: 1) }
        await model.refresh(target: target, repos: [(owner: "acme", repoName: "a"), (owner: "acme", repoName: "b")])

        XCTAssertEqual(model.cachedReading(target: target, owner: "acme", repoName: "a")?.result,
                       Self.ladder(repo: "acme/a", number: 1))
        XCTAssertEqual(model.cachedReading(target: target, owner: "acme", repoName: "b")?.result,
                       Self.ladder(repo: "acme/b", number: 1))
    }

    /// `coveredReadings` names every repo the last `refresh(target:repos:)`
    /// call pointed at, each paired with its own result — what
    /// `SessionReviewChip`'s reuse path consults.
    func testCoveredReadingsNamesEveryRepoWithItsOwnResult() async {
        let model = PRLadderModel()
        model.fetchLadder = { _, _, repoName in Self.ladder(repo: "acme/\(repoName)", number: 1) }
        await model.refresh(target: target, repos: [(owner: "acme", repoName: "a"), (owner: "acme", repoName: "b")])

        let readings = model.coveredReadings
        XCTAssertEqual(readings.map { "\($0.owner)/\($0.repoName)" }, ["acme/a", "acme/b"])
        XCTAssertEqual(readings.map(\.result), [Self.ladder(repo: "acme/a", number: 1), Self.ladder(repo: "acme/b", number: 1)])
    }

    /// One repo's fetch failing does not stop the others from fetching or
    /// being read — `PRLadder.mergeReadings`'s own "degrade that repo, not
    /// the whole panel" is only possible if the model itself keeps fetching
    /// every repo regardless of an earlier one's failure.
    func testRefreshWithSeveralReposKeepsFetchingAfterOneFails() async {
        let model = PRLadderModel()
        struct Boom: Error {}
        model.fetchLadder = { _, _, repoName in
            if repoName == "a" { throw Boom() }
            return Self.ladder(repo: "acme/\(repoName)", number: 1)
        }
        await model.refresh(target: target, repos: [(owner: "acme", repoName: "a"), (owner: "acme", repoName: "b")])

        let a = model.cachedReading(target: target, owner: "acme", repoName: "a")
        XCTAssertNil(a?.result)
        XCTAssertNotNil(a?.fetchError)
        let b = model.cachedReading(target: target, owner: "acme", repoName: "b")
        XCTAssertEqual(b?.result, Self.ladder(repo: "acme/b", number: 1))
        XCTAssertNil(b?.fetchError)
    }

    /// A repo already cached from an earlier `refresh(target:owner:repoName:)`
    /// call is served immediately by a later `refresh(target:repos:)` call
    /// naming it — the per-repo cache is shared across both entry points,
    /// exactly the "several keys, one cache" design this overload exists
    /// for. Mid-refresh, the repo's OLD rows are still what `cachedReading`
    /// returns, while its own background fetch (blocked on `gate`) has not
    /// yet landed — the same "no flash to empty" cache behavior the
    /// single-repo tests above pin, reached through the multi-repo entry
    /// point instead.
    func testRefreshWithSeveralReposServesAnAlreadyCachedRepoImmediately() async {
        let model = PRLadderModel()
        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/a", number: 1) }
        await model.refresh(target: target, owner: "acme", repoName: "a")

        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        model.fetchLadder = gatedFetch(entered: entered, gate: gate, result: Self.ladder(repo: "acme/a", number: 2))

        let refreshing = Task {
            await model.refresh(target: target, repos: [(owner: "acme", repoName: "a"), (owner: "acme", repoName: "b")])
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }
        // Mid-fetch on "a" (the first key, fetched first): its OLD rows are
        // still what's cached, and "b" has not been reached yet at all.
        XCTAssertEqual(model.cachedReading(target: target, owner: "acme", repoName: "a")?.result,
                       Self.ladder(repo: "acme/a", number: 1))
        XCTAssertNil(model.cachedReading(target: target, owner: "acme", repoName: "b")?.result,
                     "\"b\"'s entry exists (created up front) but has not fetched yet")

        // Release "a"'s fetch, then wait for "b"'s to start (same gated
        // closure blocks every call, so this releases them one at a time,
        // matching `refresh`'s own one-at-a-time fetch loop).
        gate.signal()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }
        gate.signal()
        await refreshing.value

        XCTAssertEqual(model.cachedReading(target: target, owner: "acme", repoName: "a")?.result,
                       Self.ladder(repo: "acme/a", number: 2))
        XCTAssertNotNil(model.cachedReading(target: target, owner: "acme", repoName: "b")?.result)
    }

    /// `reload()` re-reads every currently selected repo, not just the
    /// first — the multi-repo generalization of the single-repo reload
    /// test above.
    func testReloadRefetchesEverySelectedRepo() async {
        let model = PRLadderModel()
        model.fetchLadder = { _, _, repoName in Self.ladder(repo: "acme/\(repoName)", number: 1) }
        await model.refresh(target: target, repos: [(owner: "acme", repoName: "a"), (owner: "acme", repoName: "b")])

        model.fetchLadder = { _, _, repoName in Self.ladder(repo: "acme/\(repoName)", number: 2) }
        await model.reload()

        XCTAssertEqual(model.cachedReading(target: target, owner: "acme", repoName: "a")?.result,
                       Self.ladder(repo: "acme/a", number: 2))
        XCTAssertEqual(model.cachedReading(target: target, owner: "acme", repoName: "b")?.result,
                       Self.ladder(repo: "acme/b", number: 2))
    }

    /// An empty repo list clears the selection, on `refresh(target:owner:repoName:)`'s
    /// own "any part nil clears" footing.
    func testRefreshWithAnEmptyRepoListClearsTheSelection() async {
        let model = PRLadderModel()
        model.fetchLadder = { _, _, _ in Self.ladder(repo: "acme/a", number: 1) }
        await model.refresh(target: target, repos: [(owner: "acme", repoName: "a")])
        XCTAssertFalse(model.coveredReadings.isEmpty)

        await model.refresh(target: target, repos: [])
        XCTAssertTrue(model.coveredReadings.isEmpty)
        XCTAssertNil(model.result)
    }
}
