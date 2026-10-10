import XCTest
@testable import Deck

/// `PRLadder`'s pure pieces: the position derivation, the repo-consistency
/// guard, and the decoders — against well-formed and malformed bodies, the same split `LibraryClientTests`
/// documents for the rest of the Library seam. `fetchLadder` itself reaches
/// `SessionAgent.run` and is not covered here, matching `LibraryClientTests`'
/// own posture toward `fetchCourse`/`fetchCorrectionsQueue`.
final class PRLadderTests: XCTestCase {

    // MARK: - Fixtures shaped like the running Library

    /// One entry of `GET /signals/pr-state`'s `prs` array, in the shape
    /// `library/app.py`'s `pr_state_latest` builds it (flat, not nested under
    /// `meta`). **Built from the route's own docstring and handler, not
    /// captured from the running Library** — the session that wrote this
    /// had no bearer token to call it with. Field values are edited per test
    /// via the helper's parameters.
    private func latestPRStateJSON(
        id: String = "sig_01M2N76AQ1XQX8MHKF9TVEPM0F",
        repo: String? = "convivy/convivy-deck",
        number: Int? = 233,
        title: String? = "fix(rail): the first seeking call reads \\\"1 call so far\\\"",
        author: String? = "operator-at-convivy",
        draft: Bool? = false,
        headSha: String? = "78ee30229782093be95276aa7fa14c39485b442d",
        state: String? = "OPEN",
        producedAt: String? = nil,
        ingestedAt: String? = "2026-09-16T13:41:09Z"
    ) -> String {
        func field(_ name: String, _ value: String?) -> String {
            guard let value else { return "" }
            return "\"\(name)\":\"\(value)\","
        }
        func numberField(_ name: String, _ value: Int?) -> String {
            guard let value else { return "" }
            return "\"\(name)\":\(value),"
        }
        func boolField(_ name: String, _ value: Bool?) -> String {
            guard let value else { return "" }
            return "\"\(name)\":\(value),"
        }
        let producedAtValue = producedAt.map { "\"\($0)\"" } ?? "null"
        let fields = field("repo", repo) + numberField("number", number)
            + field("title", title) + field("author", author) + boolField("draft", draft)
            + field("head_sha", headSha) + field("state", state) + field("id", id)
            + "\"produced_at\":\(producedAtValue),\"ingested_at\":\"\(ingestedAt ?? "")\","
        return "{\(fields.trimmingTrailingComma)}"
    }

    /// A real `GET /review-records` row, captured against the running
    /// Library 2026-09-16 (`convivy/convivy-deck#233`, `deck-reviewer`,
    /// `APPROVE`) — the shape `decodeReviewRecordEntry` decodes.
    private func reviewRecordJSON(
        pr: Int? = 233, reviewedRef: String? = "78ee30229782093be95276aa7fa14c39485b442d",
        role: String? = "deck-reviewer", verdict: String? = "APPROVE",
        auth: String? = "run-verified", authReason: String? = nil
    ) -> String {
        func field(_ name: String, _ value: String?) -> String {
            value.map { "\"\(name)\":\"\($0)\"," } ?? ""
        }
        let prField = pr.map { "\"pr\":\($0)," } ?? ""
        let authField = auth.map { "\"auth\":\"\($0)\"," } ?? ""
        let authReasonValue = authReason.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"rev_01M2M6Z8TW0GW228QZFMKF9BVZ",\
        "repo_identity":"github:convivy/convivy-deck","product":"convivy-deck",\
        \(prField)\(field("reviewed_ref", reviewedRef))\(field("role", role))\
        "run_id":"run-c5a4c55b","identity_key":"run-c5a4c55b",\(field("verdict", verdict))\
        "findings":[],"prose":"VERDICT: APPROVE","paths":[],"doc_ids":[],"item_ids":[],\
        \(authField)"auth_reason":\(authReasonValue),"content_sha":"abc123","version":1,\
        "source_comment_id":null,"signal_id":"sig_01ABC",\
        "created_at":"2026-09-15T00:00:00Z","updated_at":"2026-09-15T00:00:00Z"}
        """.trimmingTrailingCommaBeforeBrace
    }

    private func curlResponse(status: Int, body: String) -> Data {
        Data("\(body)\n\(status)".utf8)
    }

    // MARK: - derivePosition: closed/merged and missing data

    func testNoStateRowIsStateUnknownNoPRRecord() {
        let position = PRLadder.derivePosition(stateRow: nil, reviewRecords: [], ciStatus: .unavailable(reason: "x"))
        XCTAssertEqual(position, .stateUnknown(.noPRRecord))
    }

    func testMissingStateFieldIsStateUnknownMissingState() {
        let row = PRLadder.StateRow(
            repo: "convivy/convivy-deck", number: 1, title: nil, author: nil, draft: false,
            headSha: "abc", state: nil, producedAt: nil, ingestedAt: nil)
        let position = PRLadder.derivePosition(stateRow: row, reviewRecords: [], ciStatus: .unavailable(reason: "x"))
        XCTAssertEqual(position, .stateUnknown(.missingState))
    }

    /// An empty `state` — what `bin/pr-state-capture`'s `_state()` produces
    /// when the upstream GitHub payload carries no `state` key at all — must
    /// not fall through to the OPEN-handling path; nothing was actually
    /// reported.
    func testEmptyStateIsStateUnknownUnrecognizedState() {
        let row = makeRow(state: "", draft: false)
        let records = [makeReview(role: "deck-reviewer", verdict: "APPROVE", reviewedRef: row.headSha)]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "x")),
            .stateUnknown(.unrecognizedState("")))
    }

    /// A value this client has never seen must also resolve to state
    /// unknown, not proceed as if the PR were open.
    func testUnrecognisedStateValueIsStateUnknownUnrecognizedState() {
        let row = makeRow(state: "FOO", draft: false)
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: [], ciStatus: .unavailable(reason: "x")),
            .stateUnknown(.unrecognizedState("FOO")))
    }

    func testClosedStateDrawsAsClosed() {
        let row = makeRow(state: "CLOSED", draft: false)
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: [], ciStatus: .unavailable(reason: "x")),
            .closed(.closed))
    }

    func testMergedStateDrawsAsMerged() {
        let row = makeRow(state: "MERGED", draft: false)
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: [], ciStatus: .unavailable(reason: "x")),
            .closed(.merged))
    }

    /// A closed/merged PR draws by its state alone — reviews are irrelevant
    /// once the PR is no longer open, even a `REQUEST_CHANGES` at head.
    func testClosedStateIgnoresReviewRecords() {
        let row = makeRow(state: "MERGED", draft: false)
        let records = [makeReview(role: "deck-reviewer", verdict: "REQUEST_CHANGES", reviewedRef: row.headSha)]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "x")),
            .closed(.merged))
    }

    // MARK: - derivePosition: draft

    func testDraftDrawsAsDraftRegardlessOfReviews() {
        let row = makeRow(state: "OPEN", draft: true)
        let records = [makeReview(role: "deck-reviewer", verdict: "APPROVE", reviewedRef: row.headSha)]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "x")),
            .draft)
    }

    /// `draft` absent decodes to "not draft" (`nil` != `true`), the same
    /// absent-means-false posture `LibraryClient`'s other bool fields take.
    func testMissingDraftFieldIsTreatedAsNotDraft() {
        let row = makeRow(state: "OPEN", draft: nil)
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: [], ciStatus: .unavailable(reason: "x")),
            .inReview)
    }

    func testOpenNotDraftMissingHeadShaIsStateUnknown() {
        let row = PRLadder.StateRow(
            repo: "convivy/convivy-deck", number: 1, title: nil, author: nil, draft: false,
            headSha: nil, state: "OPEN", producedAt: nil, ingestedAt: nil)
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: [], ciStatus: .unavailable(reason: "x")),
            .stateUnknown(.missingHeadSha))
    }

    // MARK: - derivePosition: open, ready, no history

    func testOpenReadyNoReviewsAtAllIsInReview() {
        let row = makeRow(state: "OPEN", draft: false)
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: [], ciStatus: .unavailable(reason: "x")),
            .inReview)
    }

    // MARK: - derivePosition: changes requested wins over approve at head

    func testChangesRequestedAtHeadWinsOverAnApprovalAtHead() {
        let row = makeRow(state: "OPEN", draft: false)
        let records = [
            makeReview(role: "deck-reviewer", verdict: "APPROVE", reviewedRef: row.headSha),
            makeReview(role: "deck-security-reviewer", verdict: "REQUEST_CHANGES", reviewedRef: row.headSha),
        ]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "x")),
            .changesRequested)
    }

    /// A `REQUEST_CHANGES` at a STALE ref (an earlier head) must not block
    /// the current position — the specification's own rule: only reviews at
    /// head count. With nothing at the new head yet, this reads as waiting
    /// for reviewers again, not as still blocked on the old finding.
    func testStaleChangesRequestedDoesNotCountTowardThePosition() {
        let row = makeRow(state: "OPEN", draft: false, headSha: "newhead")
        let records = [makeReview(role: "deck-reviewer", verdict: "REQUEST_CHANGES", reviewedRef: "oldhead")]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "x")),
            .inSecondReview)
    }

    // MARK: - derivePosition: in review vs in second review

    /// No reviews at head and no stale reviews either — first round, nobody
    /// has weighed in on any ref yet.
    func testNoHeadReviewsAndNoStaleReviewsIsInReview() {
        let row = makeRow(state: "OPEN", draft: false, headSha: "head1")
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: [], ciStatus: .unavailable(reason: "x")),
            .inReview)
    }

    /// One role approved at head, a second role's ONLY record is stale (it
    /// reviewed an earlier push but has not re-reviewed the new head) — back
    /// in the review queue, not ready, since a known role has not weighed in
    /// on this head at all.
    func testOneRoleApprovedAtHeadWhileAnotherRolesOnlyRecordIsStaleIsInSecondReview() {
        let row = makeRow(state: "OPEN", draft: false, headSha: "head2")
        let records = [
            makeReview(role: "deck-reviewer", verdict: "APPROVE", reviewedRef: "head2"),
            makeReview(role: "deck-security-reviewer", verdict: "APPROVE", reviewedRef: "head1"),
        ]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "x")),
            .inSecondReview)
    }

    // MARK: - derivePosition: every known role approved at head → CI-dependent

    /// **Documents the derivation's real limit, rather than hiding it**: a
    /// role's very first review, in flight, is indistinguishable from "this
    /// repo only ever needed one reviewer" — there is no roster to consult.
    /// So a PR only one role has ever reviewed reaches the CI-dependent
    /// branch on that one role's approval alone.
    func testTheOnlyRoleEverToReviewApprovingAtHeadReachesTheCIBranch() {
        let row = makeRow(state: "OPEN", draft: false)
        let records = [makeReview(role: "deck-reviewer", verdict: "APPROVE", reviewedRef: row.headSha)]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "no CI source")),
            .stateUnknown(.noCISource(detail: "no CI source")))
    }

    func testEveryKnownRoleApprovedAtHeadWithNoCISourceIsStateUnknown() {
        let row = makeRow(state: "OPEN", draft: false)
        let records = [
            makeReview(role: "deck-reviewer", verdict: "APPROVE", reviewedRef: row.headSha),
            makeReview(role: "deck-security-reviewer", verdict: "APPROVE", reviewedRef: row.headSha),
        ]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "no CI check-run source")),
            .stateUnknown(.noCISource(detail: "no CI check-run source")))
    }

    /// The forward-compatibility contract: once a real CI source exists, the
    /// exact same all-approved review set resolves to the three CI-shaped
    /// rungs on `ciStatus` alone — `derivePosition` needs no change.
    func testEveryKnownRoleApprovedAtHeadWithCIRunningIsInCI() {
        let row = makeRow(state: "OPEN", draft: false)
        let records = [makeReview(role: "deck-reviewer", verdict: "APPROVE", reviewedRef: row.headSha)]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .running), .inCI)
    }

    func testEveryKnownRoleApprovedAtHeadWithCIFailedIsFailedCI() {
        let row = makeRow(state: "OPEN", draft: false)
        let records = [makeReview(role: "deck-reviewer", verdict: "APPROVE", reviewedRef: row.headSha)]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .failed), .failedCI)
    }

    func testEveryKnownRoleApprovedAtHeadWithCIPassedIsReadyToMerge() {
        let row = makeRow(state: "OPEN", draft: false)
        let records = [makeReview(role: "deck-reviewer", verdict: "APPROVE", reviewedRef: row.headSha)]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .passed), .readyToMerge)
    }

    // MARK: - derivePosition: degrade-per-field on review records

    /// A record with no `reviewedRef` cannot be classified fresh or stale,
    /// so it counts toward neither — the row degrades to as if that one
    /// record were absent, not to a crash or a wrong bucket.
    func testReviewRecordMissingReviewedRefCountsTowardNeitherHeadNorStale() {
        let row = makeRow(state: "OPEN", draft: false)
        let records = [makeReview(role: "deck-reviewer", verdict: "APPROVE", reviewedRef: nil)]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "x")),
            .inReview)
    }

    /// A verdict this client has never seen counts as neither an approval
    /// nor a block — conservative rather than guessed.
    func testUnrecognisedVerdictAtHeadIsNeitherApproveNorBlock() {
        let row = makeRow(state: "OPEN", draft: false)
        let records = [makeReview(role: "deck-reviewer", verdict: "COMMENT", reviewedRef: row.headSha)]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "x")),
            .inReview)
    }

    // MARK: - derivePosition: unverified review records don't count

    /// An `unverified` `APPROVE` at head must not reach any of the
    /// CI-dependent rungs — the review record `library/app.py` stamps
    /// `unverified` exists precisely so a gate can tell this apart from a
    /// run-verified one.
    func testUnverifiedApproveAloneAtHeadDoesNotReachCIRungs() {
        let row = makeRow(state: "OPEN", draft: false)
        let records = [makeReview(role: "deck-reviewer", verdict: "APPROVE", reviewedRef: row.headSha, auth: "unverified")]
        let position = PRLadder.derivePosition(
            stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "no CI source"))
        XCTAssertEqual(position, .inReview)
        XCTAssertNotEqual(position, .inCI)
        XCTAssertNotEqual(position, .readyToMerge)
        XCTAssertNotEqual(position, .stateUnknown(.noCISource(detail: "no CI source")))
    }

    /// An `unverified` `REQUEST_CHANGES` at head must not block the
    /// position — same reasoning as the approve case above, the other
    /// direction.
    func testUnverifiedRequestChangesAtHeadDoesNotProduceChangesRequested() {
        let row = makeRow(state: "OPEN", draft: false)
        let records = [makeReview(role: "deck-reviewer", verdict: "REQUEST_CHANGES", reviewedRef: row.headSha, auth: "unverified")]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "x")),
            .inReview)
    }

    /// A record with no `auth` field at all is treated the same as
    /// `"unverified"`, not as run-verified by default.
    func testReviewRecordMissingAuthIsTreatedAsNotRunVerified() {
        let row = makeRow(state: "OPEN", draft: false)
        let records = [makeReview(role: "deck-reviewer", verdict: "APPROVE", reviewedRef: row.headSha, auth: nil)]
        XCTAssertEqual(
            PRLadder.derivePosition(stateRow: row, reviewRecords: records, ciStatus: .unavailable(reason: "x")),
            .inReview)
    }

    // MARK: - repoConsistency

    func testRepoConsistencyIsConsistentWhenEveryRowMatches() {
        let rows = [makeRow(state: "OPEN", draft: false, number: 1), makeRow(state: "OPEN", draft: false, number: 2)]
        XCTAssertEqual(
            PRLadder.repoConsistency(of: rows, expectedRepos: ["convivy/convivy-deck"]), .consistent)
    }

    /// The shape this guard exists to catch: a page carrying a row from a
    /// repo other than the one `?repo=convivy/convivy-deck` asked for —
    /// caught independently of whether the Library's own `repo=` filter
    /// (library#123, merged and deployed) is behaving today.
    func testRepoConsistencyDetectsForeignRows() {
        let ownRow = makeRow(state: "OPEN", draft: false)
        let foreignRow = makeRow(state: "OPEN", draft: false, number: 5, repo: "convivy/library")
        let result = PRLadder.repoConsistency(of: [ownRow, foreignRow], expectedRepos: ["convivy/convivy-deck"])
        XCTAssertEqual(result, .foreignRowsPresent(repos: ["convivy/library"]))
    }

    /// Several distinct foreign repos in one page — every one is named, and
    /// sorted, not just the first found.
    func testRepoConsistencyNamesEveryDistinctForeignRepoSorted() {
        let rows = [
            makeRow(state: "OPEN", draft: false),
            makeRow(state: "OPEN", draft: false, number: 1, repo: "convivy/vivy"),
            makeRow(state: "OPEN", draft: false, number: 1, repo: "convivy/agent-platform"),
        ]
        XCTAssertEqual(
            PRLadder.repoConsistency(of: rows, expectedRepos: ["convivy/convivy-deck"]),
            .foreignRowsPresent(repos: ["convivy/agent-platform", "convivy/vivy"]))
    }

    /// The widening `issue_01M2P5JHM1G8XCMKM4HEHVJB2P` asks for: a row
    /// matching ANY member of the expected set is consistent, not just the
    /// first. `fetchLadder` itself still only ever passes a one-element
    /// set (see `repoConsistency`'s own doc), so this pins the general
    /// case the widened signature makes possible.
    func testRepoConsistencyAcceptsAnyRowMatchingAnyExpectedRepo() {
        let rows = [
            makeRow(state: "OPEN", draft: false),
            makeRow(state: "OPEN", draft: false, number: 1, repo: "convivy/library"),
        ]
        XCTAssertEqual(
            PRLadder.repoConsistency(of: rows, expectedRepos: ["convivy/convivy-deck", "convivy/library"]),
            .consistent)
    }

    // MARK: - repoFilterDegradeReason

    func testRepoFilterDegradeReasonNamesTheObservedRepos() {
        let reason = PRLadder.repoFilterDegradeReason(observedForeignRepos: ["convivy/library"])
        XCTAssertTrue(reason.contains("convivy/library"))
        XCTAssertFalse(reason.contains("not enforced"),
                       "library#123 is merged and deployed — the guard stays, the claim it's unenforced must not")
    }

    // MARK: - decodeLatestPRStatesPage

    func testDecodeLatestPRStatesPageDecodesTheRouteShape() throws {
        let raw = curlResponse(status: 200, body: """
        {"prs":[\(latestPRStateJSON())],"count":1,"total":1,"offset":0,"truncated":false}
        """)
        let page = try PRLadder.decodeLatestPRStatesPage(raw)
        XCTAssertEqual(page.rows.count, 1)
        XCTAssertFalse(page.truncated)
        let row = try XCTUnwrap(page.rows.first)
        XCTAssertEqual(row.repo, "convivy/convivy-deck")
        XCTAssertEqual(row.number, 233)
        XCTAssertEqual(row.title, #"fix(rail): the first seeking call reads "1 call so far""#)
        XCTAssertEqual(row.author, "operator-at-convivy")
        XCTAssertEqual(row.draft, false)
        XCTAssertEqual(row.headSha, "78ee30229782093be95276aa7fa14c39485b442d")
        XCTAssertEqual(row.state, "OPEN")
        XCTAssertNil(row.producedAt)
        XCTAssertEqual(row.ingestedAt, "2026-09-16T13:41:09Z")
    }

    /// The old raw-signal read nested every field under `meta`. A body still
    /// shaped that way (the route swapped for `GET /signals`, say) carries no
    /// `prs`, so it must decode to nothing rather than to rows with every
    /// field nil.
    func testDecodeLatestPRStatesPageIgnoresTheOldSignalsEnvelope() throws {
        let raw = curlResponse(status: 200, body: """
        {"signals":[{"id":"sig_1","meta":{"repo":"convivy/convivy-deck","number":1,"state":"OPEN"}}],\
        "count":1,"total":1,"offset":0,"truncated":false}
        """)
        let page = try PRLadder.decodeLatestPRStatesPage(raw)
        XCTAssertTrue(page.rows.isEmpty)
    }

    /// An entry missing one field (or all of them) still decodes; only
    /// `fetchLadder` drops a row it cannot key.
    func testDecodeLatestPRStatesPageDegradesOneMissingFieldWithoutDroppingTheRow() throws {
        let raw = curlResponse(status: 200, body: """
        {"prs":[\(latestPRStateJSON(headSha: nil))],"truncated":false}
        """)
        let page = try PRLadder.decodeLatestPRStatesPage(raw)
        let row = try XCTUnwrap(page.rows.first)
        XCTAssertNil(row.headSha)
        XCTAssertEqual(row.number, 233)
    }

    /// The two CI fields library#226 added, in the shape the live route
    /// served on 2026-10-08: a captured PR with a conclusion, a captured PR
    /// whose checks have not been captured yet (`ci_conclusion: null`), and
    /// a row from before the fields existed, which still decodes.
    func testDecodeLatestPRStatesPageDecodesTheCIFields() throws {
        let raw = curlResponse(status: 200, body: """
        {"prs":[\
        {"repo":"convivy/convivy-deck","number":349,"state":"MERGED","head_sha":"1e65979","ci_conclusion":"success","ci_captured":true},\
        {"repo":"convivy/convivy-deck","number":350,"state":"OPEN","head_sha":"108c32a","ci_conclusion":null,"ci_captured":true},\
        {"repo":"convivy/convivy-deck","number":233,"state":"OPEN","head_sha":"78ee302"}\
        ],"truncated":false}
        """)
        let rows = try PRLadder.decodeLatestPRStatesPage(raw).rows
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].ciConclusion, "success")
        XCTAssertEqual(rows[0].ciCaptured, true)
        XCTAssertNil(rows[1].ciConclusion)
        XCTAssertEqual(rows[1].ciCaptured, true)
        XCTAssertNil(rows[2].ciConclusion)
        XCTAssertNil(rows[2].ciCaptured)
    }

    /// A wrongly typed CI field degrades to nil and keeps the row.
    func testDecodeLatestPRStatesPageDegradesWronglyTypedCIFields() throws {
        let raw = curlResponse(status: 200, body: """
        {"prs":[{"repo":"convivy/convivy-deck","number":7,"state":"OPEN","ci_conclusion":1,"ci_captured":"yes"}],\
        "truncated":false}
        """)
        let row = try XCTUnwrap(PRLadder.decodeLatestPRStatesPage(raw).rows.first)
        XCTAssertEqual(row.number, 7)
        XCTAssertNil(row.ciConclusion)
        XCTAssertNil(row.ciCaptured)
    }

    // MARK: - ciStatus(row:)

    private func ciRow(conclusion: String?, captured: Bool?) -> PRLadder.StateRow {
        PRLadder.StateRow(
            repo: "convivy/convivy-deck", number: 1, title: nil, author: nil, draft: false,
            headSha: "abc1234", state: "OPEN", producedAt: nil, ingestedAt: nil,
            ciConclusion: conclusion, ciCaptured: captured)
    }

    func testCIStatusSuccessIsPassed() {
        XCTAssertEqual(PRLadder.ciStatus(row: ciRow(conclusion: "success", captured: true)), .passed)
    }

    func testCIStatusEveryFailingConclusionIsFailed() {
        for conclusion in ["failure", "timed_out", "cancelled", "action_required", "startup_failure"] {
            XCTAssertEqual(PRLadder.ciStatus(row: ciRow(conclusion: conclusion, captured: true)), .failed,
                           conclusion)
        }
    }

    func testCIStatusNoConclusionOnACapturedRepoIsRunning() {
        XCTAssertEqual(PRLadder.ciStatus(row: ciRow(conclusion: nil, captured: true)), .running)
    }

    /// An uncaptured repository is unknown even when a conclusion is present,
    /// and so is a row that does not say.
    func testCIStatusAnUncapturedOrUnsaidRepoIsUnavailable() {
        for captured in [false, nil] as [Bool?] {
            for conclusion in ["success", nil] as [String?] {
                guard case .unavailable = PRLadder.ciStatus(row: ciRow(conclusion: conclusion, captured: captured)) else {
                    return XCTFail("captured \(String(describing: captured)), conclusion \(String(describing: conclusion))")
                }
            }
        }
    }

    /// A conclusion this client does not know is never guessed as passed or
    /// failed, and the reason names it.
    func testCIStatusAnUnrecognisedConclusionIsUnavailableAndNamed() {
        for conclusion in ["neutral", "skipped", "stale", "something_new"] {
            guard case .unavailable(let reason) = PRLadder.ciStatus(row: ciRow(conclusion: conclusion, captured: true)) else {
                return XCTFail(conclusion)
            }
            XCTAssertTrue(reason.contains(conclusion), reason)
        }
    }

    func testDecodeLatestPRStatesPageKeepsRowsInTheOrderTheRouteServedThem() throws {
        let raw = curlResponse(status: 200, body: """
        {"prs":[\(latestPRStateJSON(repo: "convivy/convivy-deck", number: 9)),\
        \(latestPRStateJSON(repo: "convivy/convivy-deck", number: 4))],"truncated":false}
        """)
        let page = try PRLadder.decodeLatestPRStatesPage(raw)
        XCTAssertEqual(page.rows.map(\.number), [9, 4])
    }

    func testDecodeLatestPRStatesPageCarriesTheTruncatedFlag() throws {
        let raw = curlResponse(status: 200, body: """
        {"prs":[\(latestPRStateJSON())],"truncated":true}
        """)
        let page = try PRLadder.decodeLatestPRStatesPage(raw)
        XCTAssertTrue(page.truncated)
    }

    func testDecodeLatestPRStatesPageThrowsOnANonOKStatus() {
        let raw = curlResponse(status: 403, body: #"{"error":"forbidden"}"#)
        XCTAssertThrowsError(try PRLadder.decodeLatestPRStatesPage(raw)) { error in
            guard case LibraryClient.FetchError.libraryRefused(let status, _) = error else {
                return XCTFail("expected .libraryRefused, got \(error)")
            }
            XCTAssertEqual(status, 403)
        }
    }

    /// The Library refuses a client that omits `Library-Protocol` with a 400;
    /// that must surface as a refusal, not an empty panel.
    func testDecodeLatestPRStatesPageThrowsOnAProtocolRefusal() {
        let raw = curlResponse(status: 400, body: #"{"error":"bad request"}"#)
        XCTAssertThrowsError(try PRLadder.decodeLatestPRStatesPage(raw)) { error in
            guard case LibraryClient.FetchError.libraryRefused(let status, _) = error else {
                return XCTFail("expected .libraryRefused, got \(error)")
            }
            XCTAssertEqual(status, 400)
        }
    }

    func testDecodeLatestPRStatesPageWithNoPRsKeyDecodesEmpty() throws {
        let raw = curlResponse(status: 200, body: "{}")
        let page = try PRLadder.decodeLatestPRStatesPage(raw)
        XCTAssertTrue(page.rows.isEmpty)
        XCTAssertFalse(page.truncated)
    }

    // MARK: - The route's ordering against the panel's

    /// The Library serves repo ascending, then PR number descending;
    /// `orderedForDisplay` is what decides the panel's order, so the served
    /// order must not leak into it. The same results in the route's order and
    /// in its reverse draw identically.
    func testOrderedForDisplayIgnoresTheOrderTheRouteServedRowsIn() {
        let served = [
            makeResult(number: 12, position: .inReview),
            makeResult(number: 9, position: .closed(.merged), updatedAt: "2026-09-15T10:00:00Z"),
            makeResult(number: 7, position: .draft),
            makeResult(number: 4, position: .closed(.closed), updatedAt: "2026-09-17T10:00:00Z"),
        ]
        XCTAssertEqual(
            PRLadder.orderedForDisplay(served).map(\.number),
            PRLadder.orderedForDisplay(served.reversed()).map(\.number))
        XCTAssertEqual(PRLadder.orderedForDisplay(served).map(\.number), [12, 7, 4, 9])
    }

    // MARK: - decodeReviewRecordsPage

    func testDecodeReviewRecordsPageDecodesTheRealShape() throws {
        let raw = curlResponse(status: 200, body: """
        {"review_records":[\(reviewRecordJSON())],"count":1,"total":1,"offset":0,"truncated":false}
        """)
        let page = try PRLadder.decodeReviewRecordsPage(raw)
        XCTAssertEqual(page.records.count, 1)
        XCTAssertFalse(page.truncated)
        let record = try XCTUnwrap(page.records.first)
        XCTAssertEqual(record.pr, 233)
        XCTAssertEqual(record.reviewedRef, "78ee30229782093be95276aa7fa14c39485b442d")
        XCTAssertEqual(record.role, "deck-reviewer")
        XCTAssertEqual(record.verdict, "APPROVE")
        XCTAssertEqual(record.auth, "run-verified")
    }

    /// A row missing `auth` still decodes and stays visible — only its
    /// contribution to `derivePosition`'s counting changes.
    func testDecodeReviewRecordsPageDegradesAMissingAuthWithoutDroppingTheRecord() throws {
        let raw = curlResponse(status: 200, body: """
        {"review_records":[\(reviewRecordJSON(auth: nil))],"truncated":false}
        """)
        let page = try PRLadder.decodeReviewRecordsPage(raw)
        let record = try XCTUnwrap(page.records.first)
        XCTAssertNil(record.auth)
        XCTAssertEqual(record.verdict, "APPROVE")
    }

    func testDecodeReviewRecordsPageDegradesAMissingRoleWithoutDroppingTheRecord() throws {
        let raw = curlResponse(status: 200, body: """
        {"review_records":[\(reviewRecordJSON(role: nil))],"truncated":false}
        """)
        let page = try PRLadder.decodeReviewRecordsPage(raw)
        let record = try XCTUnwrap(page.records.first)
        XCTAssertNil(record.role)
        XCTAssertEqual(record.verdict, "APPROVE")
    }

    func testDecodeReviewRecordsPageCarriesTheTruncatedFlag() throws {
        let raw = curlResponse(status: 200, body: """
        {"review_records":[\(reviewRecordJSON())],"truncated":true}
        """)
        let page = try PRLadder.decodeReviewRecordsPage(raw)
        XCTAssertTrue(page.truncated)
    }

    func testDecodeReviewRecordsPageThrowsOnANonOKStatus() {
        let raw = curlResponse(status: 500, body: #"{"error":"internal"}"#)
        XCTAssertThrowsError(try PRLadder.decodeReviewRecordsPage(raw)) { error in
            guard case LibraryClient.FetchError.libraryRefused(let status, _) = error else {
                return XCTFail("expected .libraryRefused, got \(error)")
            }
            XCTAssertEqual(status, 500)
        }
    }

    // MARK: - pagedRows

    func testPagedRowsMergesEveryPageUntilNotTruncated() throws {
        var offsets: [Int] = []
        let (rows, truncated) = try PRLadder.pagedRows(
            fetchPage: { offset in
                offsets.append(offset)
                return Data()
            },
            decodePage: { _ in
                let page = offsets.count
                if page < 3 {
                    return (rows: [page], truncated: true)
                }
                return (rows: [page], truncated: false)
            })
        XCTAssertEqual(rows, [1, 2, 3])
        XCTAssertFalse(truncated)
        XCTAssertEqual(offsets, [0, 1, 2])
    }

    func testPagedRowsGivesUpAtMaxPagesAndReportsTruncated() throws {
        var calls = 0
        let (rows, truncated) = try PRLadder.pagedRows(
            fetchPage: { _ in calls += 1; return Data() },
            decodePage: { _ in (rows: [1], truncated: true) })
        XCTAssertEqual(calls, PRLadder.maxPages)
        XCTAssertEqual(rows.count, PRLadder.maxPages)
        XCTAssertTrue(truncated)
    }

    func testPagedRowsStopsOnAnEmptyPageEvenIfMarkedTruncated() throws {
        var calls = 0
        let (rows, truncated) = try PRLadder.pagedRows(
            fetchPage: { _ in calls += 1; return Data() },
            decodePage: { _ in (rows: [Int](), truncated: true) })
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(truncated)
    }

    /// `stopEarly` cuts the loop the moment it fires, and does not page
    /// further into a response already known bad — the guard `fetchLadder`
    /// relies on to avoid fetching 25 pages of a repo-contaminated result.
    func testPagedRowsStopEarlyHaltsWithoutFetchingFurtherPages() throws {
        var calls = 0
        let (rows, truncated) = try PRLadder.pagedRows(
            fetchPage: { _ in calls += 1; return Data() },
            decodePage: { _ in (rows: [1], truncated: true) },
            stopEarly: { _ in true })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(rows, [1])
        XCTAssertFalse(truncated)
    }

    /// The route's own paging, through the decoder `fetchLadder` hands
    /// `pagedRows`: a truncated first page, then a complete second one, merge
    /// in served order with the offset advanced by the rows received.
    func testPagedLatestPRStatesMergesPagesInServedOrder() throws {
        var offsets: [Int] = []
        let pages = [
            curlResponse(status: 200, body: """
            {"prs":[\(latestPRStateJSON(number: 9)),\(latestPRStateJSON(number: 8))],"truncated":true}
            """),
            curlResponse(status: 200, body: """
            {"prs":[\(latestPRStateJSON(number: 7))],"truncated":false}
            """),
        ]
        let (rows, truncated) = try PRLadder.pagedRows(
            fetchPage: { offset in
                offsets.append(offset)
                return pages[offsets.count - 1]
            },
            decodePage: PRLadder.decodeLatestPRStatesPage)
        XCTAssertEqual(rows.map(\.number), [9, 8, 7])
        XCTAssertEqual(offsets, [0, 2])
        XCTAssertFalse(truncated)
    }

    /// The guard `fetchLadder` wires into `pagedRows`: a 200 that carries
    /// another repository's PRs (the `repo` parameter not applied) halts
    /// paging on that page.
    func testPagedLatestPRStatesStopsWhenARowBelongsToAnotherRepo() throws {
        var calls = 0
        let page = curlResponse(status: 200, body: """
        {"prs":[\(latestPRStateJSON(repo: "convivy/convivy-deck", number: 3)),\
        \(latestPRStateJSON(repo: "convivy/library", number: 2))],"truncated":true}
        """)
        var foreign: [String] = []
        _ = try PRLadder.pagedRows(
            fetchPage: { _ in calls += 1; return page },
            decodePage: PRLadder.decodeLatestPRStatesPage,
            stopEarly: { rows in
                if case .foreignRowsPresent(let repos) = PRLadder.repoConsistency(
                    of: rows, expectedRepos: ["convivy/convivy-deck"]) {
                    foreign = repos
                    return true
                }
                return false
            })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(foreign, ["convivy/library"])
    }

    // MARK: - Remote commands (LibraryClient)

    func testLatestPRStatesRemoteCommandCarriesRepoWindowAndPaging() {
        let command = LibraryClient.latestPRStatesRemoteCommand(
            owner: "convivy", repoName: "convivy-deck", closedWithinDays: 14, limit: 200, offset: 0)
        XCTAssertTrue(command.contains(
            "/signals/pr-state?repo=convivy/convivy-deck&closed_within_days=14&limit=200&offset=0"))
        XCTAssertTrue(command.contains("Library-Protocol: 1"),
                      "the route refuses a request that omits the protocol header")
    }

    /// The old route's path must not survive: `/signals?kind=pr_state`
    /// answers raw transitions, one row per (head sha, state, draft, title)
    /// change, which this client no longer collapses.
    func testLatestPRStatesRemoteCommandDoesNotAskForRawPRStateSignals() {
        let command = LibraryClient.latestPRStatesRemoteCommand(
            owner: "convivy", repoName: "convivy-deck", closedWithinDays: 14, limit: 200, offset: 0)
        XCTAssertFalse(command.contains("kind=pr_state"))
        XCTAssertFalse(command.contains("/signals?"))
    }

    /// Deck's own window, sent explicitly so a Library default change does
    /// not move the panel.
    func testClosedWithinDaysIsTheWindowDeckAsksFor() {
        XCTAssertEqual(PRLadder.closedWithinDays, 14)
    }

    func testReviewRecordsRemoteCommandCarriesGithubPrefixedRepoIdentity() {
        let command = LibraryClient.reviewRecordsRemoteCommand(
            owner: "convivy", repoName: "convivy-deck", limit: 200, offset: 0)
        XCTAssertTrue(command.contains("/review-records?repo_identity=github:convivy/convivy-deck&limit=200&offset=0"))
        XCTAssertTrue(command.contains("Library-Protocol: 1"))
    }

    func testLatestPRStatesArgumentsCarryTheControlMasterAndAddressTheTarget() {
        let args = LibraryClient.latestPRStatesArguments(
            target: TestHost.target, owner: "convivy", repoName: "convivy-deck",
            closedWithinDays: 14, limit: 200, offset: 0)
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("\(TestHost.user)@\(TestHost.address)"))
        XCTAssertFalse(args.contains { $0.hasPrefix("Authorization") || $0.contains("-H \"Authorization") })
    }

    func testReviewRecordsArgumentsCarryTheControlMasterAndAddressTheTarget() {
        let args = LibraryClient.reviewRecordsArguments(
            target: TestHost.target, owner: "convivy", repoName: "convivy-deck", limit: 200, offset: 0)
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("\(TestHost.user)@\(TestHost.address)"))
    }

    // MARK: - validateRepoSegment

    func testValidateRepoSegmentAcceptsAnOrdinaryRepoName() {
        XCTAssertEqual(LibraryClient.validateRepoSegment("convivy-deck"), "convivy-deck")
    }

    func testValidateRepoSegmentRejectsASlash() {
        XCTAssertNil(LibraryClient.validateRepoSegment("convivy/convivy-deck"))
    }

    func testValidateRepoSegmentRejectsAShellMetacharacter() {
        XCTAssertNil(LibraryClient.validateRepoSegment("convivy-deck; rm -rf /"))
    }

    // MARK: - orderedForDisplay

    private func makeResult(
        number: Int, position: PRLadder.Position, updatedAt: String? = nil
    ) -> PRLadder.LadderResult {
        PRLadder.LadderResult(
            repo: "convivy/convivy-deck", number: number, title: "PR \(number)", author: "operator-at-convivy",
            position: position, staleReviewCount: 0, updatedAt: updatedAt)
    }

    /// Every open (or state-unknown) row is kept, whatever their number —
    /// the cut in `orderedForDisplay` applies to the closed tier alone.
    func testOrderedForDisplayKeepsEveryOpenRow() {
        let results = (1...10).map { makeResult(number: $0, position: .inReview) }
        XCTAssertEqual(PRLadder.orderedForDisplay(results).count, 10)
    }

    /// Open rows sort newest-first by number.
    func testOrderedForDisplaySortsOpenRowsByNumberDescending() {
        let results = [makeResult(number: 1, position: .inReview), makeResult(number: 5, position: .draft)]
        let ordered = PRLadder.orderedForDisplay(results)
        XCTAssertEqual(ordered.map(\.number), [5, 1])
    }

    /// Closed/merged rows beyond `recentClosedLimit` are cut — never an open
    /// row, only the closed tier, and only once it exceeds the limit.
    func testOrderedForDisplayCutsClosedRowsPastTheRecentLimit() {
        let closed = (1...(PRLadder.recentClosedLimit + 3)).map {
            makeResult(number: $0, position: .closed(.merged), updatedAt: "2026-09-\(String(format: "%02d", $0))T00:00:00Z")
        }
        let ordered = PRLadder.orderedForDisplay(closed)
        XCTAssertEqual(ordered.count, PRLadder.recentClosedLimit)
    }

    /// `expanded: true` keeps every closed row that was fetched — the whole
    /// `closedWithinDays` window, not a second, larger cut.
    func testOrderedForDisplayExpandedKeepsEveryClosedRowInTheWindow() {
        let closed = (1...(PRLadder.recentClosedLimit + 3)).map {
            makeResult(number: $0, position: .closed(.merged), updatedAt: "2026-09-\(String(format: "%02d", $0))T00:00:00Z")
        }
        let ordered = PRLadder.orderedForDisplay(closed, expanded: true)
        XCTAssertEqual(ordered.count, closed.count)
    }

    /// Collapsed is the default — an explicit `expanded: false` call and the
    /// bare-arguments call agree.
    func testOrderedForDisplayDefaultsToCollapsed() {
        let closed = (1...(PRLadder.recentClosedLimit + 3)).map {
            makeResult(number: $0, position: .closed(.merged), updatedAt: "2026-09-\(String(format: "%02d", $0))T00:00:00Z")
        }
        XCTAssertEqual(PRLadder.orderedForDisplay(closed), PRLadder.orderedForDisplay(closed, expanded: false))
    }

    /// `hiddenClosedCount` is the toggle's "N more" — zero once the closed
    /// tier already fits within the collapsed limit, the number past it
    /// once it doesn't.
    func testHiddenClosedCountIsZeroAtOrBelowTheLimit() {
        let closed = (1...PRLadder.recentClosedLimit).map { makeResult(number: $0, position: .closed(.merged)) }
        XCTAssertEqual(PRLadder.hiddenClosedCount(closed), 0)
    }

    func testHiddenClosedCountIsTheOverageAboveTheLimit() {
        let closed = (1...(PRLadder.recentClosedLimit + 3)).map { makeResult(number: $0, position: .closed(.merged)) }
        XCTAssertEqual(PRLadder.hiddenClosedCount(closed), 3)
    }

    /// Open and state-unknown rows never count toward the hidden total —
    /// only the closed tier is ever cut.
    func testHiddenClosedCountIgnoresOpenRows() {
        let results = (1...(PRLadder.recentClosedLimit + 3)).map { makeResult(number: $0, position: .inReview) }
        XCTAssertEqual(PRLadder.hiddenClosedCount(results), 0)
    }

    /// The kept closed rows are the most recently updated ones, not the
    /// first `recentClosedLimit` encountered.
    func testOrderedForDisplayKeepsTheMostRecentlyUpdatedClosedRows() {
        let closed = [
            makeResult(number: 1, position: .closed(.merged), updatedAt: "2026-09-01T00:00:00Z"),
            makeResult(number: 2, position: .closed(.merged), updatedAt: "2026-09-16T00:00:00Z"),
            makeResult(number: 3, position: .closed(.merged), updatedAt: "2026-09-10T00:00:00Z"),
        ]
        let ordered = PRLadder.orderedForDisplay(closed).prefix(2)
        XCTAssertEqual(Set(ordered.map(\.number)), Set([2, 3]))
    }

    /// Open rows always precede closed ones, whatever their numbers.
    func testOrderedForDisplayPutsEveryOpenRowBeforeAnyClosedRow() {
        let results = [
            makeResult(number: 99, position: .closed(.merged), updatedAt: "2026-09-16T00:00:00Z"),
            makeResult(number: 1, position: .inReview),
        ]
        let ordered = PRLadder.orderedForDisplay(results)
        XCTAssertEqual(ordered.map(\.number), [1, 99])
    }

    /// A row with no `updatedAt` at all still appears, sorted after every
    /// closed row that does carry a timestamp — nulls-last, matching the
    /// Library's `produced_at DESC NULLS LAST`.
    func testOrderedForDisplaySortsClosedRowsWithNoUpdatedAtLast() {
        let results = [
            makeResult(number: 1, position: .closed(.merged), updatedAt: nil),
            makeResult(number: 2, position: .closed(.merged), updatedAt: "2026-09-01T00:00:00Z"),
        ]
        let ordered = PRLadder.orderedForDisplay(results)
        XCTAssertEqual(ordered.map(\.number), [2, 1])
    }

    // MARK: - mergeReadings — several repos folded into one

    private func mergeLadderRow(_ repo: String, number: Int) -> PRLadder.LadderResult {
        PRLadder.LadderResult(
            repo: repo, number: number, title: nil, author: nil,
            position: .inReview, staleReviewCount: 0, updatedAt: nil)
    }

    /// Two repos, both succeeding: their rows concatenate, and neither
    /// `truncated` nor `failures` picks up anything.
    func testMergeReadingsConcatenatesRowsFromEverySucceedingRepo() {
        let readings = [
            PRLadder.RepoReading(
                owner: "convivy", repoName: "selector",
                result: .ladder([mergeLadderRow("convivy/selector", number: 1)], truncated: false), fetchError: nil),
            PRLadder.RepoReading(
                owner: "convivy", repoName: "selector-backend",
                result: .ladder([mergeLadderRow("convivy/selector-backend", number: 1)], truncated: false), fetchError: nil),
        ]
        let merged = PRLadder.mergeReadings(readings)
        XCTAssertEqual(Set(merged.results.map(\.repo)), ["convivy/selector", "convivy/selector-backend"])
        XCTAssertFalse(merged.truncated)
        XCTAssertTrue(merged.failures.isEmpty)
    }

    /// The issue's own rule: one repo failing degrades only that repo's
    /// rows, the other repo's rows still draw.
    func testMergeReadingsKeepsASucceedingReposRowsWhenAnotherRepoFails() {
        let readings = [
            PRLadder.RepoReading(
                owner: "convivy", repoName: "selector",
                result: .ladder([mergeLadderRow("convivy/selector", number: 1)], truncated: false), fetchError: nil),
            PRLadder.RepoReading(
                owner: "convivy", repoName: "selector-backend", result: nil, fetchError: "connection reset"),
        ]
        let merged = PRLadder.mergeReadings(readings)
        XCTAssertEqual(merged.results.map(\.repo), ["convivy/selector"])
        XCTAssertEqual(merged.failures, [
            PRLadder.RepoFailure(owner: "convivy", repoName: "selector-backend", reason: "connection reset"),
        ])
    }

    /// `.degraded` contributes no rows but does name a failure.
    func testMergeReadingsReportsAStructuralDegradeAsAFailure() {
        let readings = [
            PRLadder.RepoReading(
                owner: "convivy", repoName: "selector",
                result: .degraded(reason: "the Library returned another repository's rows"), fetchError: nil),
        ]
        let merged = PRLadder.mergeReadings(readings)
        XCTAssertTrue(merged.results.isEmpty)
        XCTAssertEqual(merged.failures, [
            PRLadder.RepoFailure(
                owner: "convivy", repoName: "selector",
                reason: "the Library returned another repository's rows"),
        ])
    }

    /// A repo with stale-but-real cached rows AND a failed latest refresh
    /// (`issue_01M2PMHZVF1WN0VSJRHZHD2PD6`'s own shape) contributes BOTH:
    /// its rows still draw, and it still appears as a failure so the panel
    /// can say the latest refresh failed.
    func testMergeReadingsReportsBothRowsAndAFailureForAStaleRefresh() {
        let readings = [
            PRLadder.RepoReading(
                owner: "convivy", repoName: "selector",
                result: .ladder([mergeLadderRow("convivy/selector", number: 1)], truncated: false),
                fetchError: "timed out"),
        ]
        let merged = PRLadder.mergeReadings(readings)
        XCTAssertEqual(merged.results.map(\.repo), ["convivy/selector"])
        XCTAssertEqual(merged.failures, [
            PRLadder.RepoFailure(owner: "convivy", repoName: "selector", reason: "timed out"),
        ])
    }

    /// `truncated` ORs across every succeeding repo — one truncated repo is
    /// enough to flag the merged read as possibly short.
    func testMergeReadingsTruncatedIsTrueIfAnyRepoTruncated() {
        let readings = [
            PRLadder.RepoReading(
                owner: "convivy", repoName: "selector",
                result: .ladder([mergeLadderRow("convivy/selector", number: 1)], truncated: false), fetchError: nil),
            PRLadder.RepoReading(
                owner: "convivy", repoName: "selector-backend",
                result: .ladder([mergeLadderRow("convivy/selector-backend", number: 1)], truncated: true), fetchError: nil),
        ]
        XCTAssertTrue(PRLadder.mergeReadings(readings).truncated)
    }

    /// A repo with no result and no error yet (still loading, or never
    /// touched) contributes nothing to either `results` or `failures` — its
    /// own `isLoading` is what a panel reads instead.
    func testMergeReadingsIgnoresARepoWithNoResultAndNoError() {
        let readings = [
            PRLadder.RepoReading(owner: "convivy", repoName: "selector", result: nil, fetchError: nil),
        ]
        let merged = PRLadder.mergeReadings(readings)
        XCTAssertTrue(merged.results.isEmpty)
        XCTAssertTrue(merged.failures.isEmpty)
    }

    // MARK: - Helpers

    private func makeRow(
        state: String?, draft: Bool?, number: Int = 233, headSha: String = "head-sha-1",
        repo: String = "convivy/convivy-deck"
    ) -> PRLadder.StateRow {
        PRLadder.StateRow(
            repo: repo, number: number,
            title: "a title", author: "operator-at-convivy", draft: draft,
            headSha: headSha, state: state, producedAt: nil, ingestedAt: "2026-09-16T13:41:09Z")
    }

    func testStaleReviewCountCountsReviewsAtAnOlderCommitOnAnOpenPR() {
        let records = [
            makeReview(role: "reviewer", verdict: "APPROVE", reviewedRef: "old"),
            makeReview(role: "security-reviewer", verdict: "APPROVE", reviewedRef: "head"),
            makeReview(role: "reviewer", verdict: "APPROVE", reviewedRef: nil),
        ]
        XCTAssertEqual(
            PRLadder.staleReviewCount(headSha: "head", records: records, position: .inReview), 1)
    }

    func testStaleReviewCountIsZeroOnceThePRIsMergedOrClosed() {
        let records = [makeReview(role: "reviewer", verdict: "APPROVE", reviewedRef: "old")]
        XCTAssertEqual(
            PRLadder.staleReviewCount(headSha: "head", records: records, position: .closed(.merged)), 0)
        XCTAssertEqual(
            PRLadder.staleReviewCount(headSha: "head", records: records, position: .closed(.closed)), 0)
    }

    private func makeReview(
        role: String?, verdict: String?, reviewedRef: String?, auth: String? = "run-verified"
    ) -> PRLadder.ReviewRecordEntry {
        PRLadder.ReviewRecordEntry(
            pr: 233, reviewedRef: reviewedRef, role: role, verdict: verdict, auth: auth, authReason: nil)
    }
}

private extension String {
    /// Trims a trailing `,` before the fixture builders' closing `}` — the
    /// field-composers above always append a trailing comma so an absent
    /// field can simply contribute nothing, and this cleans up the one spot
    /// that would otherwise leave a dangling comma before `}`.
    var trimmingTrailingComma: String {
        hasSuffix(",") ? String(dropLast()) : self
    }

    var trimmingTrailingCommaBeforeBrace: String {
        replacingOccurrences(of: ",}", with: "}")
    }
}
