import XCTest
@testable import Deck

/// `ReviewRecordsPane`'s decode, pure presentation helpers, and HTML
/// generation — the pieces testable without a running WKWebView or a real
/// Library, matching the split `ItemDetailPaneTests` and `PRLadderTests`
/// already document for the rest of this seam.
final class ReviewRecordsPaneTests: XCTestCase {

    // MARK: - Fixtures

    private func curlResponse(status: Int, body: String) -> Data {
        Data("\(body)\n\(status)".utf8)
    }

    /// A real `GET /review-records` row's full shape
    /// (`library/store.py`'s `review_record_dict`), with one finding —
    /// `library/tests/test_review_record_routes.py`'s own round-trip
    /// fixture for `findings` (`severity`/`location`/`text`).
    private func reviewRecordJSON(
        id: String? = "rev_01M2M6Z8TW0GW228QZFMKF9BVZ",
        role: String? = "deck-reviewer", verdict: String? = "APPROVE",
        auth: String? = "run-verified",
        reviewedRef: String? = "78ee30229782093be95276aa7fa14c39485b442d",
        prose: String? = "VERDICT: APPROVE", findings: String = "[]",
        updatedAt: String? = "2026-09-15T00:00:00Z"
    ) -> String {
        func field(_ name: String, _ value: String?) -> String {
            value.map { "\"\(name)\":\"\($0)\"," } ?? ""
        }
        let idField = id.map { "\"id\":\"\($0)\"," } ?? ""
        let proseField = prose.map { "\"prose\":\"\($0)\"," } ?? "\"prose\":null,"
        let updatedAtField = updatedAt.map { "\"updated_at\":\"\($0)\"," } ?? ""
        return """
        {\(idField)"repo_identity":"github:convivy/convivy-deck","product":"convivy-deck",\
        "pr":233,\(field("reviewed_ref", reviewedRef))\(field("role", role))\
        "run_id":"run-c5a4c55b","identity_key":"run-c5a4c55b",\(field("verdict", verdict))\
        "findings":\(findings),\(proseField)"paths":[],"doc_ids":[],"item_ids":[],\
        \(field("auth", auth))"auth_reason":null,"content_sha":"abc123","version":1,\
        "source_comment_id":null,"signal_id":"sig_01ABC",\
        "created_at":"2026-09-15T00:00:00Z",\(updatedAtField)"x":0}
        """.replacingOccurrences(of: ",\"x\":0}", with: "}")
    }

    // MARK: - ReviewRecordRow.decode

    func testDecodeTheRealShapeIncludingAFinding() throws {
        let findings = #"[{"severity":"high","location":"app.py:10","text":"a finding"}]"#
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(reviewRecordJSON(findings: findings).utf8)) as? [String: Any])
        guard case .record(let record) = ReviewRecordRow.decode(raw) else {
            return XCTFail("expected .record")
        }
        XCTAssertEqual(record.id, "rev_01M2M6Z8TW0GW228QZFMKF9BVZ")
        XCTAssertEqual(record.role, "deck-reviewer")
        XCTAssertEqual(record.verdict, "APPROVE")
        XCTAssertEqual(record.auth, "run-verified")
        XCTAssertEqual(record.reviewedRef, "78ee30229782093be95276aa7fa14c39485b442d")
        XCTAssertEqual(record.pr, 233)
        XCTAssertEqual(record.findings.count, 1)
        XCTAssertEqual(record.findings.first?.severity, "high")
        XCTAssertEqual(record.findings.first?.location, "app.py:10")
        XCTAssertEqual(record.findings.first?.text, "a finding")
    }

    /// A missing optional field (`auth`, here) still decodes the rest of
    /// the record rather than dropping it — the per-field degrade
    /// discipline this codebase already follows for a Library read.
    func testDecodeDegradesAMissingOptionalFieldWithoutDroppingTheRecord() throws {
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(reviewRecordJSON(auth: nil).utf8)) as? [String: Any])
        guard case .record(let record) = ReviewRecordRow.decode(raw) else {
            return XCTFail("expected .record")
        }
        XCTAssertNil(record.auth)
        XCTAssertEqual(record.verdict, "APPROVE")
    }

    /// A finding missing `location` still decodes, with that field blank.
    func testDecodeDegradesAFindingMissingLocation() throws {
        let findings = #"[{"severity":"low","text":"no location given"}]"#
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(reviewRecordJSON(findings: findings).utf8)) as? [String: Any])
        guard case .record(let record) = ReviewRecordRow.decode(raw) else {
            return XCTFail("expected .record")
        }
        XCTAssertNil(record.findings.first?.location)
        XCTAssertEqual(record.findings.first?.severity, "low")
    }

    /// A row with no usable `id` cannot be told apart from any other such
    /// row, so it decodes as `.undecodable` rather than silently taking on
    /// a guessed identity.
    func testARecordWithNoIdIsUndecodable() throws {
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(reviewRecordJSON(id: nil).utf8)) as? [String: Any])
        XCTAssertEqual(ReviewRecordRow.decode(raw), .undecodable)
    }

    func testAnEmptyIdIsAlsoUndecodable() throws {
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(reviewRecordJSON(id: "").utf8)) as? [String: Any])
        XCTAssertEqual(ReviewRecordRow.decode(raw), .undecodable)
    }

    // MARK: - decodeReviewRecordsFullPage

    func testDecodeReviewRecordsFullPageDecodesTheRealShape() throws {
        let raw = curlResponse(status: 200, body: """
        {"review_records":[\(reviewRecordJSON())],"count":1,"total":1,"offset":0,"truncated":false}
        """)
        let page = try LibraryClient.decodeReviewRecordsFullPage(raw)
        XCTAssertEqual(page.rows.count, 1)
        XCTAssertFalse(page.truncated)
        guard case .record(let record) = page.rows.first else { return XCTFail("expected .record") }
        XCTAssertEqual(record.prose, "VERDICT: APPROVE")
    }

    func testDecodeReviewRecordsFullPageThrowsOnANonOKStatus() {
        let raw = curlResponse(status: 500, body: #"{"error":"internal"}"#)
        XCTAssertThrowsError(try LibraryClient.decodeReviewRecordsFullPage(raw)) { error in
            guard case LibraryClient.FetchError.libraryRefused(let status, _) = error else {
                return XCTFail("expected .libraryRefused, got \(error)")
            }
            XCTAssertEqual(status, 500)
        }
    }

    // MARK: - authLabel

    func testAuthLabelReadsRunVerifiedAsItself() {
        XCTAssertEqual(ReviewRecordsPane.authLabel("run-verified"), "run-verified")
    }

    func testAuthLabelMarksAnUnverifiedRecordAsNotCountingTowardAMerge() {
        XCTAssertTrue(ReviewRecordsPane.authLabel("unverified").contains("does not count toward a merge"))
    }

    /// A missing `auth` reads the same as `"unverified"` —
    /// `PRLadder.ReviewRecordEntry.auth`'s own rule, mirrored here.
    func testAuthLabelTreatsAMissingAuthAsUnverified() {
        XCTAssertTrue(ReviewRecordsPane.authLabel(nil).contains("does not count toward a merge"))
    }

    // MARK: - headComparison

    func testHeadComparisonMatchesTheCurrentHead() {
        XCTAssertEqual(
            ReviewRecordsPane.headComparison(reviewedRef: "abc123", headSha: "abc123"), .head)
    }

    func testHeadComparisonMarksAnEarlierRefAsStale() {
        XCTAssertEqual(
            ReviewRecordsPane.headComparison(reviewedRef: "abc123", headSha: "def456"), .stale)
    }

    func testHeadComparisonIsUnknownWithNoHeadToCompareAgainst() {
        XCTAssertEqual(
            ReviewRecordsPane.headComparison(reviewedRef: "abc123", headSha: nil), .unknown)
    }

    func testHeadComparisonIsUnknownWithNoReviewedRef() {
        XCTAssertEqual(
            ReviewRecordsPane.headComparison(reviewedRef: nil, headSha: "abc123"), .unknown)
    }

    // MARK: - page(for:) — empty state

    func testEmptyStatePageSaysSoAndNamesThePR() {
        let html = ReviewRecordsPane.emptyStatePage(repo: "convivy/convivy-deck", pr: 233, appearance: .light)
        XCTAssertTrue(html.contains("No review records on file"))
        XCTAssertTrue(html.contains("convivy/convivy-deck"))
        XCTAssertTrue(html.contains("#233"))
    }

    // MARK: - page(for:) — head/stale/unverified marking

    private func record(
        role: String = "deck-reviewer", verdict: String = "APPROVE", auth: String? = "run-verified",
        reviewedRef: String? = "abc123", prose: String? = "looks fine",
        findings: [ReviewFinding] = []
    ) -> ReviewRecord {
        ReviewRecord(
            id: "rev_1", role: role, verdict: verdict, auth: auth, authReason: nil,
            reviewedRef: reviewedRef, pr: 233, prose: prose, findings: findings,
            createdAt: nil, updatedAt: nil)
    }

    func testPageMarksARecordReviewedAtHead() {
        let html = ReviewRecordsPane.page(
            for: [.record(record(reviewedRef: "abc123"))], truncated: false,
            repo: "convivy/convivy-deck", pr: 233, headSha: "abc123", appearance: .light)
        XCTAssertTrue(html.contains("current head"))
    }

    func testPageMarksAStaleRecord() {
        let html = ReviewRecordsPane.page(
            for: [.record(record(reviewedRef: "abc123"))], truncated: false,
            repo: "convivy/convivy-deck", pr: 233, headSha: "def456", appearance: .light)
        XCTAssertTrue(html.contains("stale"))
        XCTAssertFalse(html.contains("current head"))
    }

    func testPageMarksAnUnverifiedRecord() {
        let html = ReviewRecordsPane.page(
            for: [.record(record(auth: "unverified"))], truncated: false,
            repo: "convivy/convivy-deck", pr: 233, headSha: nil, appearance: .light)
        XCTAssertTrue(html.contains("does not count toward a merge"))
    }

    func testPageShowsAnUndecodableRowRatherThanDroppingIt() {
        let html = ReviewRecordsPane.page(
            for: [.undecodable], truncated: false,
            repo: "convivy/convivy-deck", pr: 233, headSha: nil, appearance: .light)
        XCTAssertTrue(html.contains("could not be read"))
    }

    func testMarkdownKeepsAHostileReviewedRefOnItsOwnLineInsideItsCodeSpan() {
        let markdown = ReviewRecordsPane.markdown(
            for: [.record(record(reviewedRef: "ab\n# APPROVE`x"))], truncated: false,
            repo: "convivy/convivy-deck", pr: 233, headSha: nil)
        XCTAssertFalse(markdown.contains("\n# APPROVE"))
        XCTAssertTrue(markdown.contains("reviewed `ab # APPR`"))
    }

    // MARK: - page(for:) — escaping hostile prose

    /// A review's prose is reviewer-written text, and a reviewer identity
    /// is exactly as untrusted as the Library item body `ItemDetailPane`'s
    /// own escaping test covers — a script tag must render as inert text,
    /// never as markup the page executes.
    func testProseContainingAScriptTagIsHTMLEscaped() {
        let html = ReviewRecordsPane.page(
            for: [.record(record(prose: "<script>alert(1)</script>"))], truncated: false,
            repo: "convivy/convivy-deck", pr: 233, headSha: nil, appearance: .light)
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    /// A finding's own `text` gets the same treatment as prose.
    func testAFindingsTextIsHTMLEscaped() {
        let html = ReviewRecordsPane.page(
            for: [.record(record(findings: [
                ReviewFinding(severity: "high", location: "app.py:1", text: "<img src=x onerror=alert(1)>"),
            ]))],
            truncated: false, repo: "convivy/convivy-deck", pr: 233, headSha: nil, appearance: .light)
        XCTAssertFalse(html.contains("<img src=x onerror"))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
    }

    /// A Markdown-shaped link whose href is a `javascript:` URL stays
    /// literal escaped text in the fallback page — this path never parses
    /// Markdown into real anchors, so there is no `<a href="javascript:…">`
    /// for the three independent protections `FileViewerWebView` already
    /// applies (no JavaScript, a navigation delegate that cancels
    /// link-activated navigation, and `ExternalLink`'s scheme allowlist) to
    /// even need to catch.
    func testAMarkdownJavascriptLinkStaysLiteralText() {
        let hostile = "[click me](javascript:alert(document.cookie))"
        let html = ReviewRecordsPane.page(
            for: [.record(record(prose: hostile))], truncated: false,
            repo: "convivy/convivy-deck", pr: 233, headSha: nil, appearance: .light)
        XCTAssertFalse(html.contains("<a href=\"javascript:"))
        XCTAssertTrue(html.contains(FileViewerPane.htmlEscape(hostile)))
    }

    func testRepoAndPRInThePageChromeAreEscapedToo() {
        let html = ReviewRecordsPane.page(
            for: [], truncated: false, repo: "<b>x</b>/convivy-deck", pr: 233, headSha: nil, appearance: .light)
        XCTAssertFalse(html.contains("<b>x</b>"))
    }

    // MARK: - markdown(for:) — truncation notice

    func testMarkdownNotesATruncatedRead() {
        let markdown = ReviewRecordsPane.markdown(
            for: [.record(record())], truncated: true, repo: "convivy/convivy-deck", pr: 233, headSha: nil)
        XCTAssertTrue(markdown.contains("some reviews may be missing"))
    }

    func testMarkdownOmitsTheTruncationNoticeWhenComplete() {
        let markdown = ReviewRecordsPane.markdown(
            for: [.record(record())], truncated: false, repo: "convivy/convivy-deck", pr: 233, headSha: nil)
        XCTAssertFalse(markdown.contains("may be missing"))
    }

    // MARK: - LibraryClient.reviewRecordsRemoteCommand(pr:)

    func testReviewRecordsRemoteCommandCarriesPRWhenGiven() {
        let command = LibraryClient.reviewRecordsRemoteCommand(
            owner: "convivy", repoName: "convivy-deck", pr: 233, limit: 200, offset: 0)
        XCTAssertTrue(command.contains(
            "/review-records?repo_identity=github:convivy/convivy-deck&pr=233&limit=200&offset=0"))
    }

    func testReviewRecordsRemoteCommandOmitsPRWhenNotGiven() {
        let command = LibraryClient.reviewRecordsRemoteCommand(
            owner: "convivy", repoName: "convivy-deck", limit: 200, offset: 0)
        XCTAssertFalse(command.contains("pr="))
        XCTAssertTrue(command.contains(
            "/review-records?repo_identity=github:convivy/convivy-deck&limit=200&offset=0"))
    }
}
