import Foundation

/// Drives the cockpit's Pull Requests panel: every pull request for the
/// selected crew's project repo, with its ladder position, read through
/// `PRLadder.fetchLadder`.
///
/// KEPT SEPARATE FROM `CockpitModel`, on the same footing
/// `CheckoutDocumentsModel`'s own doc gives for staying separate from it —
/// this follows a (host, owner, repo) key, not `CockpitModel`'s (host,
/// product) key, and the two happen to derive from the same crew today only
/// because `CockpitResolution.prLadderRepo` says so, not because they are
/// the same fetch.
///
/// **CACHES PER REPO, KEYED ACROSS EVERY CREW A SESSION HAS VISITED** —
/// `issue_01M2P60KDY9KPXWMZ4C6G1CJ52`. A crew switch used to clear the one
/// slot this model held and refetch from empty every time, which cost a full
/// ssh round trip even for a crew looked at ten seconds earlier. Now each
/// repo keyed by `refresh` gets its own `Entry`, switching serves whatever
/// that repo's entry already holds (nil only the first time this session
/// ever asks about it), and a background fetch runs behind the served rows
/// to bring them current. That's safe because the data is already stale by
/// construction: `agent-platform/bin/pr-state-capture` writes the `pr_state`
/// signals this reads on a 900-second launchd interval, and its own doc says
/// the dashboard "is fine lagging one capture interval." Serving a
/// two-minute-old cached ladder costs nothing real in accuracy.
///
/// FETCHES ON SELECTION CHANGE, ON THE COCKPIT'S REFRESH, AND ON A SLOW
/// TIMER. The timer now walks every cached entry, not only the selected
/// repo's — see `refreshInterval`. Each entry's fetch is awaited fully
/// before the next one starts, so the fleet's ssh round trips are already
/// serialized one at a time; nothing further staggers them.
@MainActor
final class PRLadderModel: ObservableObject {
    private struct Key: Hashable {
        let target: SSHTarget
        let owner: String
        let repoName: String
    }

    /// One repo's cached reading — the same three facts the single
    /// `result`/`fetchError`/`isLoading` trio held before, plus `fetchedAt`
    /// so a future panel can show how old what it's looking at is
    /// (`issue_01M2P60KDY9KPXWMZ4C6G1CJ52` point 5 — the staleness label
    /// itself lives in `CockpitView`, a later PR, not here).
    private struct Entry: Equatable {
        /// The last rows this repo produced, whether from the fetch that set
        /// `fetchError` to `nil` or from an earlier one a subsequent failed
        /// refresh left untouched — see `fetch`'s catch path. `nil` only
        /// when this repo has never once fetched successfully.
        var result: PRLadder.FetchResult?
        /// The most recent fetch's transport or decode failure, or `nil`
        /// once a fetch has succeeded. Set alongside a surviving `result`
        /// when a refresh fails after an earlier success — the two are not
        /// mutually exclusive, so the panel can show stale-but-real rows and
        /// the fact that the latest attempt to refresh them failed.
        var fetchError: String?
        var isLoading = false
        /// When `result` was last set by a successful fetch — `nil` before
        /// this repo has ever been fetched successfully. A failed refresh
        /// leaves this dating the surviving rows rather than clearing it;
        /// only a failure with no prior success leaves it `nil`.
        var fetchedAt: Date?
    }

    @Published private var entries: [Key: Entry] = [:]
    /// The repo(s) the model is presently pointed at, in configured order —
    /// zero or one for the single-repo `refresh(target:owner:repoName:)`
    /// path (`sessionReviewChipLadder`'s own use), several for
    /// `refresh(target:repos:)` (the cockpit's own use, one crew mapping to
    /// several cache keys — `issue_01M2P5JHM1G8XCMKM4HEHVJB2P`). The
    /// singular `result`/`fetchError`/`isLoading`/`fetchedAt` accessors
    /// below all read `currentKeys.first`, so a single-repo caller sees
    /// exactly the same behavior `current: Key?` gave before this was
    /// widened to an array.
    @Published private var currentKeys: [Key] = []

    /// Least-recently-selected first — `refresh` moves a key to the end
    /// every time it becomes `current`. What `evictLeastRecentlyUsed`
    /// consults once `entries.count` reaches `cacheLimit`.
    private var lruKeys: [Key] = []
    /// Guards a same-key race between two in-flight fetches for the same
    /// repo (a manual reload landing while the background timer is
    /// mid-fetch for it, or the reverse) — incremented every time a fetch
    /// starts for a key, so a fetch that finishes after a newer one has
    /// already started for the same key drops its own result rather than
    /// clobbering the fresher one. The cross-repo version of this problem
    /// (switching away mid-fetch) needs no such guard any more: each repo
    /// writes its own `Entry`, so a slow fetch for a repo no longer selected
    /// simply updates that repo's own entry instead of colliding with
    /// whatever is current.
    private var fetchGeneration: [Key: Int] = [:]
    private var timerTask: Task<Void, Never>?

    /// How many repos' entries this model keeps at once. Bounds memory and
    /// the timer's background fetch fan-out against a session that visits
    /// many crews in one sitting; sized generously above any fleet size
    /// this model has been asked to cover, so it is a backstop rather than a
    /// cache an ordinary session ever fills. Eviction is LRU
    /// (`evictLeastRecentlyUsed`), not roster-membership: this model is
    /// never told which crews still exist (that list lives in
    /// `ContentView`), so a crew that leaves the roster simply stops being
    /// switched to and ages out on its own rather than being evicted the
    /// instant it disappears.
    static let cacheLimit = 24

    static let refreshInterval = Duration.seconds(900)

    /// Every repo `currentKeys` presently names, each paired with its own
    /// latest `result` — what `SessionReviewChip.presentation` consults to
    /// decide, per PR, whether it can reuse one of this model's own fetches
    /// instead of running a fallback fetch for the same repo. One call
    /// answers both "is this repo covered" and "what does it currently
    /// show," since a caller needs both together.
    var coveredReadings: [(owner: String, repoName: String, result: PRLadder.FetchResult?)] {
        currentKeys.map { key in (key.owner, key.repoName, entries[key]?.result) }
    }

    /// The selected repo's cached rows — served the instant a switch lands
    /// on a repo this model has fetched before, even while the background
    /// refresh below is still in flight.
    var result: PRLadder.FetchResult? { currentEntry?.result }
    /// The selected repo's most recent transport or decode failure — see
    /// `Entry`'s own doc for why this and `.degraded` are kept apart, and
    /// for why it can be set at the same time as `result`.
    var fetchError: String? { currentEntry?.fetchError }
    var isLoading: Bool { currentEntry?.isLoading ?? false }
    /// When the selected repo's `result` was last set by a successful
    /// fetch — nil before this repo has ever been fetched successfully.
    var fetchedAt: Date? { currentEntry?.fetchedAt }

    private var currentEntry: Entry? {
        currentKeys.first.flatMap { entries[$0] }
    }

    /// One repo's cached reading, independent of `current` — what a caller
    /// asks for a repo without switching the selection to it. Exposed so a
    /// future per-crew indicator (or a test verifying the timer sweep
    /// reaches every cached repo, not only the selected one) can read a
    /// specific entry directly rather than through `result`/`fetchError`/
    /// `isLoading`/`fetchedAt`, which only ever answer for `current`.
    struct CachedReading: Equatable {
        let result: PRLadder.FetchResult?
        let fetchError: String?
        let isLoading: Bool
        let fetchedAt: Date?
    }

    func cachedReading(target: SSHTarget, owner: String, repoName: String) -> CachedReading? {
        entries[Key(target: target, owner: owner, repoName: repoName)].map {
            CachedReading(result: $0.result, fetchError: $0.fetchError, isLoading: $0.isLoading, fetchedAt: $0.fetchedAt)
        }
    }

    /// The ssh round trip, as a seam so a test can answer without one — the
    /// same shape as `CockpitModel.fetchChildItems` and
    /// `CheckoutDocumentsModel.fetchDocuments`.
    var fetchLadder: @Sendable (SSHTarget, String, String) throws -> PRLadder.FetchResult = { target, owner, repoName in
        try PRLadder.fetchLadder(target: target, owner: owner, repoName: repoName)
    }

    /// The clock, as a seam so a test can assert `fetchedAt` against a fixed
    /// instant instead of racing the wall clock.
    var now: () -> Date = Date.init

    init() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: PRLadderModel.refreshInterval)
                guard !Task.isCancelled, let self else { continue }
                await self.reloadEveryCachedRepo()
            }
        }
    }

    deinit {
        timerTask?.cancel()
    }

    /// Points the model at a single repo, or clears the selection when any
    /// part is nil — sugar over `refresh(target:repos:)` below for a caller
    /// that only ever follows one repo at a time (`sessionReviewChipLadder`).
    /// A key already cached from an earlier visit is served synchronously
    /// from that cache — no flash to empty — while a background fetch
    /// brings it current; a key seen for the first time this session starts
    /// from nil exactly as before.
    func refresh(target: SSHTarget?, owner: String?, repoName: String?) async {
        if let owner, !owner.isEmpty, let repoName, !repoName.isEmpty {
            await refresh(target: target, repos: [(owner, repoName)])
        } else {
            await refresh(target: target, repos: [])
        }
    }

    /// Points the model at an ordered set of repos — the crew's own,
    /// resolved `repos` list (`CockpitResolution.prLadderRepos`), or clears
    /// the selection when `target` is nil or `repos` is empty. Generalizes
    /// the single-repo path above over `currentKeys` rather than one
    /// `current` key: the model's cache is already per-repo
    /// (`issue_01M2P60KDY9KPXWMZ4C6G1CJ52`), so a crew with several repos
    /// simply maps to several cache keys instead of reshaping the cache
    /// itself. Each repo already cached from an earlier visit is served
    /// synchronously from that cache — no flash to empty — while a
    /// background fetch brings it current, exactly like the single-repo
    /// path; a repo seen for the first time this session starts from nil.
    ///
    /// `currentKeys` (and so `coveredReadings`) moves to the
    /// new keys here, synchronously, before any ssh round trip below — and
    /// each key's entry is created in the same step whenever it has none
    /// yet, so a view reading a repo's cached reading mid-fetch never sees
    /// `coveredReadings` naming a repo beside another repo's rows
    /// (`SessionReviewChip`'s reuse path trusts exactly that pairing).
    func refresh(target: SSHTarget?, repos: [(owner: String, repoName: String)]) async {
        guard let target, !repos.isEmpty else {
            currentKeys = []
            return
        }
        let keys = repos.map { Key(target: target, owner: $0.owner, repoName: $0.repoName) }
        guard keys != currentKeys else { return }
        currentKeys = keys
        for key in keys {
            touch(key)
            if entries[key] == nil {
                evictLeastRecentlyUsedIfNeeded(makingRoomFor: key)
                entries[key] = Entry()
            }
        }
        for key in keys {
            await fetch(key)
        }
    }

    /// Re-reads every currently selected repo, keeping what is showing
    /// until each answer arrives — the same "don't flash empty" posture
    /// `CheckoutDocumentsModel.reload` takes, and true of a failed answer
    /// too now: a repo with rows already cached keeps them, with
    /// `fetchError` set alongside, rather than losing them to whatever this
    /// fetch does (`issue_01M2PMHZVF1WN0VSJRHZHD2PD6`). Used for the
    /// header's manual refresh, which is about the repo(s) on screen, not
    /// every cached one. Each fetch is awaited fully before the next
    /// starts, the same serialization `reloadEveryCachedRepo` already gives
    /// the timer's sweep.
    func reload() async {
        for key in currentKeys {
            await fetch(key)
        }
    }

    /// The timer's sweep: every cached repo gets a background refresh, not
    /// only the selected one, so a later switch usually lands on warm rows
    /// instead of a repo this model hasn't touched in `refreshInterval`.
    /// Each fetch is awaited fully before the next one starts, so the
    /// fleet's ssh round trips already land one at a time with no extra
    /// pacing needed. This snapshots `entries.keys` once up front, so an
    /// eviction landing mid-sweep (a crew switch to a repo never seen
    /// before, racing this loop) leaves a stale key in the snapshot; `fetch`
    /// itself is what refuses to resurrect it — see its own doc. Not
    /// `private`, so a test can drive one sweep directly instead of waiting
    /// out `refreshInterval` for real.
    func reloadEveryCachedRepo() async {
        for key in Array(entries.keys) {
            guard !Task.isCancelled else { return }
            await fetch(key)
        }
    }

    private func touch(_ key: Key) {
        lruKeys.removeAll { $0 == key }
        lruKeys.append(key)
    }

    private func evictLeastRecentlyUsedIfNeeded(makingRoomFor newKey: Key) {
        while entries.count >= Self.cacheLimit, let oldest = lruKeys.first, oldest != newKey {
            entries.removeValue(forKey: oldest)
            fetchGeneration.removeValue(forKey: oldest)
            lruKeys.removeFirst()
        }
    }

    /// Never originates an entry — only `refresh` does that. A key can go
    /// missing from `entries` between this being called and it returning
    /// (evicted by a switch to a repo never seen before, landing mid-flight
    /// here or while this key sits unreached in `reloadEveryCachedRepo`'s
    /// stale snapshot); the guards below make eviction win that race rather
    /// than being undone by this fetch writing the key straight back in,
    /// which is what made an evicted key permanently unevictable before —
    /// `entries.count` climbed past `cacheLimit` and stayed there for the
    /// rest of the process.
    private func fetch(_ key: Key) async {
        guard entries[key] != nil else { return }
        let generation = (fetchGeneration[key] ?? 0) + 1
        fetchGeneration[key] = generation
        entries[key]?.isLoading = true
        let fetchLadder = self.fetchLadder
        do {
            let fetched = try await Task.detached {
                try fetchLadder(key.target, key.owner, key.repoName)
            }.value
            guard entries[key] != nil, fetchGeneration[key] == generation else { return }
            entries[key] = Entry(result: fetched, fetchError: nil, isLoading: false, fetchedAt: now())
        } catch {
            // Keep whatever rows and fetchedAt this repo already had rather
            // than replacing the entry outright — a refresh failure on rows
            // already held is pure loss with nothing gained, and this is the
            // only path that runs unprompted, on every cached repo, every
            // `refreshInterval` (`reloadEveryCachedRepo`). A repo with no
            // prior success has no rows or fetchedAt to keep, so this
            // reduces to the old behavior there.
            // (`issue_01M2PMHZVF1WN0VSJRHZHD2PD6`)
            guard let existing = entries[key], fetchGeneration[key] == generation else { return }
            entries[key] = Entry(
                result: existing.result, fetchError: "\(error)", isLoading: false, fetchedAt: existing.fetchedAt)
        }
    }
}
