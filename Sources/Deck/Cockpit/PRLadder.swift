import Foundation

/// Derives a pull request's ladder position — draft, in review, changes
/// requested, in second review, in CI, failed CI, ready to merge, state
/// unknown, or closed/merged — from the Library's latest-state-per-PR route
/// and its review records. `issue_01M1372GMQ5SENJ1P80H646MQM`, under the cockpit
/// PR-ladder epic (`issue_01M0NWVW4YS8E04A657JD04QQD`).
///
/// **Library reads only, and this file is the derivation alone.** The
/// cockpit panel (`issue_01M1372GNR81ZV7K1DXHAD10R0`) and the session-pane
/// chip (`issue_01M1372GPQVK1Q042VZR2K1FAB`) are later PRs that call into
/// `derivePosition` and `fetchLadder`; neither is wired to a view here.
///
/// **No `gh` invocation anywhere.** Every read goes through the Library over
/// the transport `LibraryClient.swift` already uses — `SessionAgent.run`
/// forwarding a curl command over the existing ssh ControlMaster to the
/// mini, `Library-Protocol: 1`, bearer token off argv. See that file's own
/// header for why the transport is shaped this way.
enum PRLadder {

    // MARK: - Ladder position

    /// One rung of the ladder a pull request stands on. Only `draft` through
    /// `readyToMerge` are the seven named rungs the epic's specification
    /// lists; `.closed` and `.stateUnknown` are the two the specification
    /// adds alongside them ("plus state unknown, and closed/merged for
    /// recently closed rows").
    enum Position: Equatable {
        case draft
        case inReview
        case changesRequested
        case inSecondReview
        case inCI
        case failedCI
        case readyToMerge
        /// `state == CLOSED` or `state == MERGED` — no ladder distinction
        /// beyond that; `ClosedState` carries which. "Recently" is a row-set
        /// question for whatever panel selects which closed PRs to show,
        /// not a fact this derivation computes.
        case closed(ClosedState)
        case stateUnknown(UnknownReason)
    }

    enum ClosedState: Equatable {
        case closed
        case merged
    }

    /// Why a position could not be derived. Each case names the gap so a
    /// panel can say something more useful than a blank row — the per-field
    /// degrade discipline the whole Deck codebase already follows for
    /// Library reads.
    enum UnknownReason: Equatable {
        /// No `StateRow` at all for this pull request.
        case noPRRecord
        /// The `StateRow` exists but its `state` field did not decode.
        case missingState
        /// The `StateRow`'s `state` was `OPEN`, not draft, but `headSha` did
        /// not decode — reviews cannot be told fresh from stale without it.
        case missingHeadSha
        /// The `StateRow`'s `state` decoded but, after uppercasing, held
        /// something other than `OPEN`/`CLOSED`/`MERGED` — including an
        /// empty string, which `bin/pr-state-capture`'s `_state()` produces
        /// when the upstream GitHub payload carries no `state` key at all
        /// (`(pr.get("state") or "").upper()`). Carries the raw value for a
        /// panel that wants to say what it actually saw. Treated the same as
        /// `missingState`: the producer had nothing usable to report either
        /// way, so proceeding as if the PR were open would read a review row
        /// as informative when it is not.
        case unrecognizedState(String)
        /// Every review at head approved, so the remaining question is CI,
        /// and `ciStatus(row:)` could not resolve it (`CIStatus.unavailable`'s
        /// reason travels here) — the repository is not captured, or the
        /// conclusion is one this client does not recognise.
        case noCISource(detail: String)
    }

    /// What's known about the reviewed commit's CI, read off the same
    /// `GET /signals/pr-state` row as everything else `derivePosition` takes
    /// (`StateRow.ciConclusion`, `StateRow.ciCaptured`) — the Library
    /// (library#226) joins this onto the row by head sha, so no second read
    /// or client-side join against `test-result` is needed. `ciStatus(row:)`
    /// is the one producer; see its doc for the mapping.
    enum CIStatus: Equatable {
        case running
        case passed
        case failed
        case unavailable(reason: String)
    }

    /// Maps a `StateRow`'s `ciConclusion`/`ciCaptured` onto `CIStatus`,
    /// degrading per field like every other read in this file.
    ///
    /// - `ciCaptured != true` (false, or missing/non-boolean and so `nil`
    ///   after decode): `.unavailable` naming which; the repository either
    ///   is not captured or this client could not tell.
    /// - `ciCaptured == true`, `ciConclusion == nil`: `.running` — checks
    ///   have not finished, or finished inside the fetcher's own lag and
    ///   are not captured yet; the Library's two cases Deck cannot tell
    ///   apart, both rendering as "in CI" either way.
    /// - `success`: `.passed`.
    /// - `failure`, `timed_out`, `cancelled`, `action_required`,
    ///   `startup_failure`: `.failed` — every GitHub check-run conclusion
    ///   that means the run did not succeed.
    /// - Anything else (`neutral`, `skipped`, `stale`, or a value this
    ///   client has never seen): `.unavailable` naming the conclusion, never
    ///   guessed as passed or failed.
    static func ciStatus(row: StateRow) -> CIStatus {
        guard row.ciCaptured == true else {
            return .unavailable(reason: "CI is not captured for this repository")
        }
        guard let conclusion = row.ciConclusion else {
            return .running
        }
        switch conclusion {
        case "success": return .passed
        case "failure", "timed_out", "cancelled", "action_required", "startup_failure": return .failed
        default: return .unavailable(reason: "CI reported \"\(conclusion)\", which this view does not map")
        }
    }

    private static let approveVerdict = "APPROVE"
    private static let requestChangesVerdict = "REQUEST_CHANGES"
    /// `library/app.py`'s `_review_record_auth` stamps every review record
    /// with this or `"unverified"` — see `ReviewRecordEntry.auth`'s doc.
    private static let runVerifiedAuth = "run-verified"

    /// How many of a pull request's review records were made at a commit
    /// other than its head. Zero once the PR is merged or closed: a stale
    /// review only matters while a fresh one could still gate the merge, and
    /// on a closed row the count read as unfinished work (the operator, 2026-10-01).
    static func staleReviewCount(
        headSha: String?, records: [ReviewRecordEntry], position: Position
    ) -> Int {
        if case .closed = position { return 0 }
        guard let headSha else { return 0 }
        return records.filter { record in
            guard let ref = record.reviewedRef else { return false }
            return ref != headSha
        }.count
    }

    /// The position of one pull request, given its latest state row (one per
    /// PR, as `GET /signals/pr-state` serves it) and every review record on
    /// file for it, at any ref.
    ///
    /// **A review whose `reviewedRef` != `stateRow.headSha` is stale and
    /// does not count toward the position** — the specification's own rule.
    /// **Nor does a review whose `auth` != `"run-verified"`** — an
    /// `unverified` record (no `agentctl` run-id behind it, e.g. a
    /// Task-dispatched reviewer) still decodes and is still visible to a
    /// caller that wants to show it, but its verdict counts toward neither
    /// `changesRequested` nor `rolesApprovedAtHead`. A record with no `auth`
    /// at all is treated the same as `"unverified"`.
    /// A stale record still informs the position indirectly: its presence is
    /// what distinguishes "in second review" (a revision was pushed; the
    /// prior round is now stale) from "in review" (nothing has happened
    /// yet). Which records were stale is not returned here — a caller that
    /// wants to draw them as stale filters `reviewRecords` itself with the
    /// same `reviewedRef != stateRow.headSha` test this function uses.
    ///
    /// **Roles are read from the data, never hardcoded.** Deck's own roles
    /// are `deck-reviewer` and `deck-security-reviewer`, but nothing here
    /// spells either out: "ready to merge" is reached when every role that
    /// has EVER reviewed this pull request (at any ref) has an `APPROVE`
    /// verdict at head. A pull request only one role has ever reviewed needs
    /// only that role's approval; one only reviewed by two roles needs both.
    /// A role's first-ever review, still in flight, is indistinguishable
    /// from "this repo only needs one reviewer" — there is no roster this
    /// function can consult to tell those apart, and the specification does
    /// not ask it to.
    static func derivePosition(
        stateRow: StateRow?, reviewRecords: [ReviewRecordEntry], ciStatus: CIStatus
    ) -> Position {
        guard let stateRow else { return .stateUnknown(.noPRRecord) }
        guard let state = stateRow.state else { return .stateUnknown(.missingState) }
        switch state.uppercased() {
        case "CLOSED": return .closed(.closed)
        case "MERGED": return .closed(.merged)
        case "OPEN": break
        default: return .stateUnknown(.unrecognizedState(state))
        }
        // Only OPEN reaches here. `_state` in `bin/pr-state-capture` folds
        // `merged_at` into `MERGED` itself, so a genuinely open PR is the
        // only case this client should proceed past — anything else
        // (including the empty string an absent upstream `state` key
        // produces) is handled above as `.unrecognizedState`, never as
        // "proceed as OPEN".
        if stateRow.draft == true {
            return .draft
        }
        guard let headSha = stateRow.headSha else { return .stateUnknown(.missingHeadSha) }

        let headReviews = reviewRecords.filter { $0.reviewedRef == headSha }
        let staleReviews = reviewRecords.filter { record in
            guard let ref = record.reviewedRef else { return false }
            return ref != headSha
        }

        if headReviews.contains(where: { $0.verdict == requestChangesVerdict && $0.auth == runVerifiedAuth }) {
            return .changesRequested
        }

        let rolesEverSeen = Set(reviewRecords.compactMap(\.role))
        let rolesApprovedAtHead = Set(
            headReviews.filter { $0.verdict == approveVerdict && $0.auth == runVerifiedAuth }.compactMap(\.role))

        if !rolesEverSeen.isEmpty, !rolesApprovedAtHead.isEmpty,
           rolesApprovedAtHead.isSuperset(of: rolesEverSeen) {
            switch ciStatus {
            case .running: return .inCI
            case .passed: return .readyToMerge
            case .failed: return .failedCI
            case .unavailable(let reason): return .stateUnknown(.noCISource(detail: reason))
            }
        }

        return staleReviews.isEmpty ? .inReview : .inSecondReview
    }

    // MARK: - Wire model: pull-request state

    /// One entry of `GET /signals/pr-state`'s `prs` array, decoded: a pull
    /// request's latest state, already one per PR. The Library picks the
    /// latest (`produced_at DESC NULLS LAST`, then `ingested_at DESC`, then
    /// `id DESC`) over every row a PR has before it applies scope or paging,
    /// so nothing here needs to choose among a PR's several transitions.
    struct StateRow: Equatable {
        let repo: String?
        let number: Int?
        let title: String?
        let author: String?
        let draft: Bool?
        let headSha: String?
        /// `OPEN` | `CLOSED` | `MERGED`.
        let state: String?
        /// `null` on every row captured before agent-platform#598; the
        /// Library falls back to `ingestedAt` for those, and so does
        /// `LadderResult.updatedAt`.
        let producedAt: String?
        let ingestedAt: String?
        /// The GitHub conclusion of the test-result captured for this row's
        /// head sha (`library#226`): `success`, `failure`, `timed_out`,
        /// `cancelled`, `action_required`, `startup_failure`, or another
        /// conclusion string GitHub defines. `nil` when checks have not run,
        /// or have finished but the fetcher (every 900s) has not captured
        /// them yet — `ciCaptured` is what tells those apart from a
        /// repository nobody captures at all. Defaulted so the existing
        /// fixtures that build a `StateRow` without caring about CI keep
        /// compiling unchanged.
        let ciConclusion: String?
        /// Whether the Library captures CI for this row's repository at
        /// all. `false` or a missing/non-boolean value (both decode to
        /// `nil`) mean `ciConclusion` cannot be trusted even when present.
        let ciCaptured: Bool?

        init(
            repo: String?, number: Int?, title: String?, author: String?, draft: Bool?,
            headSha: String?, state: String?, producedAt: String?, ingestedAt: String?,
            ciConclusion: String? = nil, ciCaptured: Bool? = nil
        ) {
            self.repo = repo
            self.number = number
            self.title = title
            self.author = author
            self.draft = draft
            self.headSha = headSha
            self.state = state
            self.producedAt = producedAt
            self.ingestedAt = ingestedAt
            self.ciConclusion = ciConclusion
            self.ciCaptured = ciCaptured
        }
    }

    /// Unlike the raw signal rows this route replaces, an entry is flat: the
    /// PR's fields sit at the top level, not under `meta`.
    private static func decodeStateRow(_ raw: [String: Any]) -> StateRow {
        StateRow(
            repo: raw["repo"] as? String,
            number: (raw["number"] as? NSNumber)?.intValue,
            title: raw["title"] as? String,
            author: raw["author"] as? String,
            draft: raw["draft"] as? Bool,
            headSha: raw["head_sha"] as? String,
            state: raw["state"] as? String,
            producedAt: raw["produced_at"] as? String,
            ingestedAt: raw["ingested_at"] as? String,
            ciConclusion: raw["ci_conclusion"] as? String,
            ciCaptured: raw["ci_captured"] as? Bool)
    }

    /// One page of `GET /signals/pr-state`, decoded. Every field degrades
    /// independently inside `decodeStateRow`; an entry with no `repo` or
    /// `number` still decodes here and is dropped by `fetchLadder`, which is
    /// the first place either is needed. A body that is not a JSON object at
    /// all still throws — a transport-level surprise, not a content one,
    /// matching `LibraryClient.decodeChildItems`'s split.
    static func decodeLatestPRStatesPage(_ raw: Data) throws -> (rows: [StateRow], truncated: Bool) {
        let body = try LibraryClient.refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LibraryClient.FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        let rawEntries = (root["prs"] as? [[String: Any]]) ?? []
        let rows = rawEntries.map(decodeStateRow)
        let truncated = (root["truncated"] as? Bool) ?? false
        return (rows, truncated)
    }

    /// Whether a page of `StateRow`s stayed within the repositories asked
    /// for.
    ///
    /// **What this guards under `GET /signals/pr-state`: the `repo`
    /// parameter not being applied at all.** The route applies `repo` inside
    /// the ranking's own `FROM` clause, before it picks each PR's latest
    /// row, so no ranking effect can hand back a foreign winner: a PR whose
    /// rows sit in the requested repo can only win with one of those rows.
    /// (That is the property the older `/signals?kind=pr_state&repo=` read
    /// leaned on this guard for; the new route makes it structural.) What
    /// the route cannot promise is that the request reached the filter. A
    /// misspelled or dropped `repo=`, or a deploy predating `repo` support,
    /// answers 200 with every repository's PRs, and the panel would draw
    /// another repo's rows as this one's. `library-protocol` §3.2 documents
    /// that shape — an unrecognised parameter NAME is ignored silently, and
    /// clients are told to check the rows they got back. Measured against
    /// the running Library on 2026-09-18: `repoo=` returned 200 with
    /// `total: 5086` and `convivy/agent-platform` rows on page 1, where the
    /// correct spelling returned `total: 252` and this repo alone.
    ///
    /// **A route renamed out from under this path is a different failure
    /// and does NOT need this guard** — it answers 404 (measured the same
    /// day), which `refusedOr200Body` already turns into a loud refusal.
    /// Nor does a 200 in some other envelope, which decodes to zero rows
    /// (`testDecodeLatestPRStatesPageIgnoresTheOldSignalsEnvelope`) and
    /// passes this check vacuously.
    ///
    /// Every entry carries its own `repo`, and Deck asks for one repository
    /// per call, so checking each page against the requested repo catches
    /// the unfiltered answer wherever it lands: the route orders by repo
    /// ascending, and `pagedRows` checks every page. `fetchLadder` runs it
    /// on every page and stops on `.foreignRowsPresent` rather than
    /// trusting the query string alone.
    ///
    /// **Takes a SET, not one repo** — `issue_01M2P5JHM1G8XCMKM4HEHVJB2P`'s
    /// own instruction: "the row's repo is in the expected set," widened
    /// from "equals expected" so a crew's second repo does not trip a guard
    /// meant to mean the filter did not apply. `fetchLadder` still pages
    /// exactly one repo per call (several repos are separate calls, merged
    /// afterward at the `LadderResult` level, so each repo keeps its own
    /// cache entry and failure), so today's one caller always passes a
    /// one-element set holding that call's own repo. A row from this same
    /// crew's OTHER followed repo is therefore as foreign to a single-repo
    /// call as any other.
    enum RepoConsistency: Equatable {
        case consistent
        case foreignRowsPresent(repos: [String])
    }

    static func repoConsistency(of rows: [StateRow], expectedRepos: Set<String>) -> RepoConsistency {
        let foreign = Set(rows.compactMap(\.repo).filter { !expectedRepos.contains($0) })
        return foreign.isEmpty ? .consistent : .foreignRowsPresent(repos: foreign.sorted())
    }

    /// String comparison, since every timestamp here is an ISO-8601 UTC
    /// string of one fixed shape (`store._iso`) — lexicographic order is
    /// chronological order for that shape, so no `DateFormatter` is needed.
    /// `nil` sorts last (older than any present value), matching the
    /// Library's own `NULLS LAST` on `produced_at`.
    private static func compareNullsLast(_ a: String?, _ b: String?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _?): return .orderedAscending
        case (_?, nil): return .orderedDescending
        case let (a?, b?):
            if a == b { return .orderedSame }
            return a > b ? .orderedDescending : .orderedAscending
        }
    }

    // MARK: - Wire model: review records

    /// One row of `GET /review-records`, decoded — the fields the ladder
    /// derivation reads (`pr`, `reviewedRef`, `role`, `verdict`) plus `auth`
    /// and `authReason`, which `derivePosition` gates counting on (see its
    /// doc); the route's fuller shape (`prose`, `findings`, …) is for a
    /// reader showing the review itself, not this derivation.
    struct ReviewRecordEntry: Equatable {
        let pr: Int?
        let reviewedRef: String?
        let role: String?
        let verdict: String?
        /// `"run-verified"` or `"unverified"`, stamped by `library/app.py`'s
        /// `_review_record_auth`. `nil` (a row missing the field) is treated
        /// the same as `"unverified"` everywhere this is checked.
        let auth: String?
        let authReason: String?
    }

    private static func decodeReviewRecordEntry(_ raw: [String: Any]) -> ReviewRecordEntry {
        ReviewRecordEntry(
            pr: (raw["pr"] as? NSNumber)?.intValue,
            reviewedRef: raw["reviewed_ref"] as? String,
            role: raw["role"] as? String,
            verdict: raw["verdict"] as? String,
            auth: raw["auth"] as? String,
            authReason: raw["auth_reason"] as? String)
    }

    /// One page of `GET /review-records`. Every row decodes, so nothing is
    /// dropped here; `derivePosition` degrades per missing field instead (a
    /// record with no `reviewedRef` counts toward neither "at head" nor
    /// "stale").
    static func decodeReviewRecordsPage(_ raw: Data) throws -> (records: [ReviewRecordEntry], truncated: Bool) {
        let body = try LibraryClient.refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw LibraryClient.FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        let rawRecords = (root["review_records"] as? [[String: Any]]) ?? []
        let records = rawRecords.map(decodeReviewRecordEntry)
        let truncated = (root["truncated"] as? Bool) ?? false
        return (records, truncated)
    }

    // MARK: - Paging

    /// The page size both routes are asked for — the Library's own
    /// `MAX_PAGE` (`library/app.py`), so one request is as large as the
    /// server will ever honour.
    static let pageLimit = 200

    /// How many pages `fetchLadder` asks for, per route, before giving up.
    /// `pageLimit * maxPages` is 5,000 rows, which bounds the loop against a
    /// server that never stops saying `truncated: true`.
    ///
    /// For `GET /signals/pr-state` that is 5,000 pull requests in ONE
    /// repository (every open PR plus those closed inside
    /// `closedWithinDays`), a count no repo approaches. For `GET
    /// /review-records` it is 5,000 records for one repository, which is
    /// the read that can still reach it: `agent-platform` held 2,326 on
    /// 2026-09-16 (see `fetchLadder`'s measurement note).
    static let maxPages = 25

    /// The window `GET /signals/pr-state` applies to CLOSED and MERGED PRs;
    /// every PR whose latest state is `OPEN` comes back at any age. Sent
    /// explicitly, so the window is Deck's own choice and does not move if
    /// the Library changes its default (14 days today, capped at 90).
    ///
    /// Left at 14 because the panel draws at most `recentClosedLimit`
    /// closed rows, so a window that already yields more than that changes
    /// nothing in the cockpit's closed tier. **Three differences from the
    /// raw-signal read this replaced, all of them at the closed end:**
    ///
    /// 1. A repo with fewer than `recentClosedLimit` closures in the last
    ///    14 days used to fill the closed tier from older closures, and
    ///    now shows only the recent ones.
    /// 2. **The session pane's PR chip reads the same fetch, uncapped.**
    ///    `orderedForDisplay` runs in `CockpitView`, so
    ///    `SessionReviewChip.matchingResult` searches every row
    ///    `FetchResult.ladder` carries for the session's own PR number. A
    ///    session whose `vitals.pr` points at a PR closed or merged more
    ///    than 14 days ago used to draw "PR #33 · Merged" and now draws
    ///    the plain "PR #33" the chip shows when it holds no row for that
    ///    number. Widening the window moves that boundary; it does not
    ///    remove it.
    /// 3. The route filters `state` with SQL `=` against `OPEN`, `CLOSED`
    ///    and `MERGED`, so a row whose state is missing or spelled
    ///    anything else never arrives. `derivePosition`'s `.missingState`
    ///    and `.unrecognizedState`, and `orderedForDisplay`'s rule about
    ///    keeping state-unknown rows, therefore describe rows this wire
    ///    cannot deliver. No writer emits one — `bin/pr-state-capture`
    ///    folds `merged_at` into `MERGED` — so that handling stays as the
    ///    client's own guard rather than something the route promises.
    static let closedWithinDays = 14

    /// Pages one route to completion, or until `maxPages` gives up —
    /// `LibraryClient.pagedQueueItems`'s exact shape, generalised over the
    /// row type so `fetchLadder` can reuse it for both the latest-state
    /// entries and review records. `fetchPage(offset)` is injected so this is
    /// testable against canned bytes; `decodePage` turns one response into
    /// its rows plus the envelope's own `truncated`. `stopEarly` lets the
    /// pr-state caller cut the loop short the moment a page fails the repo
    /// check, rather than paging further into a response already known bad.
    static func pagedRows<Row>(
        fetchPage: (_ offset: Int) throws -> Data,
        decodePage: (Data) throws -> (rows: [Row], truncated: Bool),
        stopEarly: (_ rows: [Row]) -> Bool = { _ in false }
    ) throws -> (rows: [Row], truncated: Bool) {
        var merged: [Row] = []
        var offset = 0
        for _ in 0..<maxPages {
            let raw = try fetchPage(offset)
            let page = try decodePage(raw)
            merged += page.rows
            if stopEarly(page.rows) {
                return (merged, false)
            }
            guard page.truncated, !page.rows.isEmpty else {
                return (merged, false)
            }
            offset += page.rows.count
        }
        return (merged, true)
    }

    // MARK: - Review records, per qualifying PR

    /// Whether anything `fetchLadder` computes for `row` reads its review
    /// records: the union of `derivePosition`'s gate and
    /// `staleReviewCount`'s. Both need `headSha`, and neither reads records
    /// for a CLOSED or MERGED row. A draft row is admitted although
    /// `derivePosition` returns `.draft` before consulting records, because
    /// `staleReviewCount` still counts a draft's stale reviews; the same
    /// holds for a row whose state is missing or unrecognized.
    static func needsReviewRecords(_ row: StateRow) -> Bool {
        guard row.headSha != nil else { return false }
        switch row.state?.uppercased() {
        case "CLOSED", "MERGED": return false
        default: return true
        }
    }

    /// Review records for exactly the rows `needsReviewRecords` admits, one
    /// paged read per PR via `fetchPage`'s own `pr` argument — `fetchLadder`
    /// used to read every review record in the repository once and group
    /// them by `pr` client-side; this reads only the PRs whose position
    /// depends on them, keyed by the PR number asked for rather than the
    /// record's own `pr` field, so a record that fails to decode its `pr`
    /// still lands under the right key. A PR absent from the returned
    /// dictionary needs no records; `fetchLadder` reads that as `[]`.
    static func fetchReviewRecordsByPR(
        stateRows: [StateRow],
        fetchPage: (_ pr: Int, _ offset: Int) throws -> Data
    ) throws -> (recordsByPR: [Int: [ReviewRecordEntry]], truncated: Bool) {
        var recordsByPR: [Int: [ReviewRecordEntry]] = [:]
        var truncated = false
        for row in stateRows {
            guard needsReviewRecords(row), let number = row.number else { continue }
            let (records, isTruncated) = try pagedRows(
                fetchPage: { offset in try fetchPage(number, offset) },
                decodePage: decodeReviewRecordsPage)
            recordsByPR[number] = records
            truncated = truncated || isTruncated
        }
        return (recordsByPR, truncated)
    }

    // MARK: - Fetch

    /// One pull request's row set, resolved — the shape `fetchLadder`
    /// returns per PR once the fetch itself succeeded.
    struct LadderResult: Equatable {
        let repo: String
        let number: Int
        let title: String?
        let author: String?
        let position: Position
        /// How many review records exist for this PR at a ref other than
        /// its head — visible-as-stale count, for a panel that wants to
        /// show "N stale reviews" without recomputing the split itself.
        let staleReviewCount: Int
        /// `StateRow.producedAt ?? StateRow.ingestedAt` — the same fallback
        /// the Library's own closed-window test uses, kept here so a panel
        /// can order recently-closed rows by recency
        /// without re-reading the state row itself. `nil` when neither
        /// timestamp decoded, which `orderedForDisplay` treats as older
        /// than any known time.
        let updatedAt: String?
        /// `StateRow.headSha` as last fetched — carried here so a reader
        /// that opens this PR's reviews (`issue_01M3830X3DXRZDJFB8657YRCMK`)
        /// can mark each record reviewed-at-head without a second fetch of
        /// the same state row. `nil` for the same reasons `StateRow.headSha`
        /// itself is: a draft PR, or a row that predates this field.
        /// Defaulted so the several call sites that build a `LadderResult`
        /// without caring about this field (every test fixture today) keep
        /// compiling unchanged.
        var headSha: String? = nil

        /// `"\(repo)#\(number)"` — the same `(repo, number)` key the Library
        /// ranks a PR's rows on, exposed so a view drawing several
        /// repos' rows in one list (`CockpitView.pullRequestsContent`) can
        /// key a `ForEach` on something unique once `number` alone no
        /// longer is.
        var identityKey: String { "\(repo)#\(number)" }
    }

    enum FetchResult: Equatable {
        /// `truncated` is `true` when EITHER paged read (latest PR states or
        /// review records) gave up at `maxPages` with the Library still
        /// answering `truncated: true` — `fetchLadder`'s own doc says what
        /// that means for `results`' correctness. In practice that is the
        /// review-records read; the latest-state read would need 5,000 open
        /// or recently closed PRs in one repository. A caller must show this
        /// rather than let a partial ladder look like a complete one, the
        /// same posture `LibraryClient.CorrectionsQueue.truncated` already
        /// takes for the corrections queue.
        case ladder([LadderResult], truncated: Bool)
        /// The fetch could not be trusted — named reason, never a silent
        /// empty panel. `PRLadder.repoFilterDegradeReason` is today's one
        /// producer of this case's message.
        case degraded(reason: String)
    }

    static func repoFilterDegradeReason(observedForeignRepos: [String]) -> String {
        let noun = observedForeignRepos.count == 1 ? "another repository's" : "other repositories'"
        return "the Library returned \(noun) rows for a request scoped to one repository: " +
            "\(observedForeignRepos.joined(separator: ", "))"
    }

    /// Every open, anticipated, or recently-closed pull request's ladder
    /// position for `owner/repoName` — the one entry point a later panel PR
    /// calls. Synchronous and blocking, like every `LibraryClient` fetch
    /// verb; callers run this off the main actor.
    ///
    /// Two paged reads, the second scoped by the first. `GET
    /// /signals/pr-state` reads every row for the repository (one row per
    /// PR already, so nothing to collapse here; repo-consistency checked
    /// per page — see `repoConsistency`'s doc — and stopped early on the
    /// first bad page). Review records are then read once per PR that
    /// `needsReviewRecords` admits — neither `derivePosition` nor
    /// `staleReviewCount` reads records for a CLOSED, MERGED or
    /// headSha-less row, so those rows are never asked for — via
    /// `fetchReviewRecordsByPR`, server-filtered by both `repo_identity`
    /// and `pr`. A row `needsReviewRecords` excludes gets `[]`.
    /// `derivePosition` runs once per PR with `ciStatus(row:)`'s read of
    /// that same row's `ciConclusion`/`ciCaptured` — see that function's
    /// doc for the mapping.
    ///
    /// **Measured 2026-10-10 against the running Library, over the ssh
    /// ControlMaster `fetchLadder` already uses:** the whole-repository
    /// review-records read this replaced paged `agent-platform`'s 3,133
    /// records 200 at a time, 16 pages and roughly 17MB (about 1.1MB per
    /// page) for about 86 seconds; one run of that same fetch failed
    /// outright with `AgentError.failed("")` after 140 seconds. Reading
    /// review records per qualifying PR instead removes both the size and
    /// the per-refresh cost of that read for the common case: most PRs this
    /// panel draws are either closed or hold far fewer records than
    /// the repository total.
    ///
    /// **The latest-state read's own truncation is clean.** The Library
    /// ranks a PR's rows over every row it has before it pages, so a PR
    /// that is present at all is present as its true latest state; a
    /// truncated read can only drop a PR entirely, never make a shown PR
    /// draw a wrong position.
    ///
    /// **A per-PR review-records truncation is not.** `GET /review-records`
    /// is "newest first" by its own handler doc, so a PR whose own read hits
    /// `maxPages` sheds its oldest records, which can drop a role's blocking
    /// `REQUEST_CHANGES` out of what `derivePosition` sees. `rolesEverSeen`
    /// is built only from the records that survived that PR's own read, so
    /// losing one role's only record there makes `rolesApprovedAtHead
    /// .isSuperset(of: rolesEverSeen)` true vacuously — the PR then draws
    /// `.readyToMerge` or `.stateUnknown(.noCISource)` while still carrying
    /// an unresolved blocking verdict `fetchLadder` never saw. Each PR's
    /// read is bounded by the same `pageLimit * maxPages` budget the
    /// whole-repository read used to share across every PR at once, so this
    /// risk is strictly smaller than before: it now takes one PR holding
    /// 5,000 of its own records, not the repository as a whole.
    ///
    /// `truncated` on `FetchResult.ladder` is `true` when the latest-state
    /// read truncated, or when ANY per-PR review-records read did — it says
    /// the read may be short, not which rows it is short for.
    static func fetchLadder(target: SSHTarget, owner: String, repoName: String) throws -> FetchResult {
        guard let safeOwner = LibraryClient.validateRepoSegment(owner),
              let safeRepoName = LibraryClient.validateRepoSegment(repoName) else {
            throw LibraryClient.FetchError.invalidInput("\(owner)/\(repoName)")
        }
        let expectedRepo = "\(safeOwner)/\(safeRepoName)"

        var degradeReason: String?
        let (stateRows, stateRowsTruncated) = try pagedRows(
            fetchPage: { offset in
                try SessionAgent.run(
                    LibraryClient.latestPRStatesArguments(
                        target: target, owner: safeOwner, repoName: safeRepoName,
                        closedWithinDays: closedWithinDays, limit: pageLimit, offset: offset),
                    classifyMissingCommand: false)
            },
            decodePage: decodeLatestPRStatesPage,
            stopEarly: { rows in
                if case .foreignRowsPresent(let repos) = repoConsistency(of: rows, expectedRepos: [expectedRepo]) {
                    degradeReason = repoFilterDegradeReason(observedForeignRepos: repos)
                    return true
                }
                return false
            })
        if let degradeReason {
            return .degraded(reason: degradeReason)
        }

        let (recordsByPR, reviewRecordsTruncated) = try fetchReviewRecordsByPR(stateRows: stateRows) { pr, offset in
            try SessionAgent.run(
                LibraryClient.reviewRecordsArguments(
                    target: target, owner: safeOwner, repoName: safeRepoName,
                    pr: pr, limit: pageLimit, offset: offset),
                classifyMissingCommand: false)
        }

        // An entry with no repo or number cannot be keyed, so it costs itself
        // rather than joining the wrong group or drawing under a guessed repo.
        let results = stateRows.compactMap { row -> LadderResult? in
            guard let repo = row.repo, let number = row.number else { return nil }
            let records = recordsByPR[number] ?? []
            let position = derivePosition(
                stateRow: row, reviewRecords: records, ciStatus: ciStatus(row: row))
            let staleCount = staleReviewCount(headSha: row.headSha, records: records, position: position)
            return LadderResult(
                repo: repo, number: number, title: row.title, author: row.author,
                position: position, staleReviewCount: staleCount,
                updatedAt: row.producedAt ?? row.ingestedAt, headSha: row.headSha)
        }
        return .ladder(results, truncated: stateRowsTruncated || reviewRecordsTruncated)
    }

    // MARK: - Row ordering

    /// How many recently-closed or -merged rows `orderedForDisplay` keeps.
    /// A long-lived repo can carry hundreds of closed PRs, and the
    /// `closedWithinDays` window still admits every closure in that span —
    /// this is what keeps the panel to "recently closed", not "every PR
    /// closed this fortnight".
    static let recentClosedLimit = 5

    /// The row order and cut the panel draws: every open (or state-unknown)
    /// row first, then the closed/merged rows, newest first, capped at
    /// `recentClosedLimit` unless `expanded` is true. **Never drops an open
    /// or state-unknown row** — the cut applies to the closed tier alone,
    /// matching the specification's "in flight, anticipated, and recently
    /// closed". `expanded` shows every closed row already in hand, which is
    /// every closed row inside `closedWithinDays` — the fetch's own window,
    /// not a second cut this function adds.
    ///
    /// Both tiers sort by `number` descending as their own tie-break (higher
    /// PR numbers are newer PRs), so the order is stable and testable
    /// without depending on `updatedAt`, which is `nil` for most rows today
    /// (`StateRow.producedAt`'s own doc).
    static func orderedForDisplay(_ results: [LadderResult], expanded: Bool = false) -> [LadderResult] {
        var open: [LadderResult] = []
        var closed: [LadderResult] = []
        for result in results {
            if case .closed = result.position {
                closed.append(result)
            } else {
                open.append(result)
            }
        }
        open.sort { $0.number > $1.number }
        closed.sort { lhs, rhs in
            let byRecency = compareNullsLast(lhs.updatedAt, rhs.updatedAt)
            if byRecency != .orderedSame { return byRecency == .orderedDescending }
            return lhs.number > rhs.number
        }
        let visibleClosed = expanded ? closed : Array(closed.prefix(recentClosedLimit))
        return open + visibleClosed
    }

    /// How many closed/merged rows `orderedForDisplay`'s collapsed default
    /// is hiding — `0` whenever the closed tier already fits within
    /// `recentClosedLimit`, which is also when the panel's toggle draws
    /// nothing (`CockpitView.pullRequestsExpander`'s own "button only when
    /// there's something to reveal" rule, matching `queueExpander`'s).
    static func hiddenClosedCount(_ results: [LadderResult]) -> Int {
        let closedCount = results.filter {
            if case .closed = $0.position { return true }
            return false
        }.count
        return max(0, closedCount - recentClosedLimit)
    }

    // MARK: - Merging several repos

    /// One followed repo's own current reading — the fields
    /// `PRLadderModel.CachedReading` already carries, restated here rather
    /// than imported, since this file is pure derivation with no
    /// `PRLadderModel` dependency (this file's own header: "the derivation
    /// alone"). What `mergeReadings` folds together.
    struct RepoReading: Equatable {
        let owner: String
        let repoName: String
        let result: FetchResult?
        let fetchError: String?
    }

    /// One followed repo's own problem, named — `mergeReadings` reports one
    /// of these per repo that could not be trusted, rather than folding
    /// every repo's trouble into a single string, so a panel can say which
    /// repo and why. `Hashable` so a view can key a `ForEach` on it
    /// directly.
    struct RepoFailure: Hashable {
        let owner: String
        let repoName: String
        let reason: String
    }

    /// Every followed repo's rows folded into one —
    /// `issue_01M2P5JHM1G8XCMKM4HEHVJB2P`'s "one repo failing should degrade
    /// that repo's rows rather than blanking the panel." Safe to concatenate
    /// blindly: `LadderResult` is already keyed by `(repo, number)`, the
    /// same key the Library ranks a PR's rows on, so two different repos can
    /// never collide on the same merged row.
    struct MergedLadder: Equatable {
        let results: [LadderResult]
        /// `true` when ANY contributing repo's own fetch was truncated —
        /// the merged read is only as complete as its least-complete repo.
        let truncated: Bool
        /// A repo whose latest fetch could not be trusted, in `readings`
        /// order — either structurally (`.degraded`) or because the fetch
        /// itself threw (`fetchError`, `PRLadderModel`'s catch path). A repo
        /// with `fetchError` alongside surviving cached rows
        /// (`issue_01M2PMHZVF1WN0VSJRHZHD2PD6`'s "keep it, note it" shape)
        /// still contributes its rows to `results` above AND appears here,
        /// so a panel can show both the stale-but-real rows and the fact
        /// this repo's latest refresh failed.
        let failures: [RepoFailure]
    }

    /// One repo with no result yet and no error is simply not in — its rows
    /// are not ready, which a panel reads off that repo's own `isLoading`
    /// rather than anything reported here.
    static func mergeReadings(_ readings: [RepoReading]) -> MergedLadder {
        var results: [LadderResult] = []
        var truncated = false
        var failures: [RepoFailure] = []
        for reading in readings {
            switch reading.result {
            case .ladder(let rows, let isTruncated):
                results += rows
                truncated = truncated || isTruncated
            case .degraded(let reason):
                failures.append(RepoFailure(owner: reading.owner, repoName: reading.repoName, reason: reason))
            case nil:
                break
            }
            if let fetchError = reading.fetchError {
                failures.append(RepoFailure(owner: reading.owner, repoName: reading.repoName, reason: fetchError))
            }
        }
        return MergedLadder(results: results, truncated: truncated, failures: failures)
    }
}
