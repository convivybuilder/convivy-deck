import SwiftUI

/// The reviews pane: one pull request's review records in full, read from
/// the Library — role, verdict, `auth`, the reviewed commit and whether it
/// is the current head, findings with severity and location, and the
/// reviewer's prose. `issue_01M3830X3DXRZDJFB8657YRCMK`, under the
/// reviews-as-memory epic (`issue_01M2F52BXECXGHC1P3PRJ28AV8`).
///
/// OPENED FROM ONE PLACE: a Pull Requests panel row's tap
/// (`CockpitView.onSelectPullRequest`). `ContentView.openReviewRecords`
/// resolves the host and presents this pane the same way
/// `ItemDetailPane`'s own opener does.
///
/// DOCUMENT-SHAPED, SO IT IS A WEB PANE (CLAUDE.md's boundary rule). A
/// review's prose and findings are reviewer-written text, the same shape
/// `ItemDetailPane` already draws a Library item's body and comments as.
///
/// RENDERED, NOT SHOWN AS SOURCE, through the same `session-view
/// --render-file -` path and the same `FileViewerWebView` (no JavaScript,
/// `NetworkBlock`, link-activated navigation cancelled and handed to
/// `ExternalLink`'s own scheme allowlist) `ItemDetailPane` uses — see that
/// file's header for why each of those three mechanisms is load-bearing.
/// `markdown(for:)`/`page(for:)` reuse `ItemDetailPane.singleLine`/
/// `closeUnbalancedFences` rather than a second copy of the same fence
/// guard, for the identical reason `FileViewerWebView` itself is shared.
///
/// A PR WITH NO RECORDS SHOWS AN EMPTY STATE, NEVER A GITHUB FALLBACK
/// (the item's own "done when"). A record that fails to decode
/// (`ReviewRecordRow.undecodable`) demotes to a row saying so rather than
/// being dropped from the list — the per-field degrade discipline this
/// codebase already follows for a Library read whose shape is only
/// partially trustworthy.
///
/// THE SHELL IS STILL THE APPEARANCE AUTHORITY. `appearance` is resolved by
/// the caller and stamped into `data-theme` here, never read from
/// `prefers-color-scheme`.
struct ReviewRecordsPane: View {
    let repo: String
    let pr: Int
    /// The PR's head commit as last read by the Pull Requests panel
    /// (`PRLadder.LadderResult.headSha`), carried in rather than re-fetched
    /// — see `ContentView.openReviewRecords`'s doc for why a second read of
    /// the same state row would buy nothing a reader could tell apart from
    /// this one. `nil` when the panel never resolved a head (a draft PR, or
    /// a mini old enough that `pr_state` carries no `head_sha`), in which
    /// case no record is marked either way.
    let headSha: String?
    let target: SSHTarget
    let appearance: Appearance
    /// Closes the column and returns to the cockpit.
    let onClose: () -> Void

    @StateObject private var model = ReviewRecordsModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            FileViewerWebView(html: model.html)
        }
        .textSelection(.enabled)
        .task(id: ReviewRecordsLoadIdentity(repo: repo, pr: pr, target: target)) {
            await model.load(repo: repo, pr: pr, headSha: headSha, target: target, appearance: appearance)
        }
        .onChange(of: appearance) { _, new in
            Task { await model.reRender(appearance: new) }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("#\(pr) reviews")
                .frameFont(.emphasis)
                .lineLimit(1)
            Text(repo)
                .frameFont(.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if model.isLoading { ProgressView().controlSize(.mini) }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close and return to the cockpit")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct ReviewRecordsLoadIdentity: Equatable {
    let repo: String
    let pr: Int
    let target: SSHTarget
}

// MARK: - Wire model

/// One row of `GET /review-records`'s full shape (`library/store.py`'s
/// `review_record_dict`) — `id`, `role`, `verdict`, `auth`, the reviewed
/// ref, the prose and the findings. Distinct from `PRLadder.ReviewRecordEntry`,
/// which decodes only the four fields the ladder derivation reads; this is
/// the fuller read a pane showing the review itself needs.
enum ReviewRecordRow: Equatable {
    case record(ReviewRecord)
    /// A row whose `id` did not decode as a non-empty string — the one
    /// field every reader needs to tell two records apart, so a row
    /// missing it is shown as "could not be read" rather than silently
    /// dropped from the list.
    case undecodable
}

struct ReviewRecord: Equatable {
    let id: String
    let role: String?
    let verdict: String?
    /// `"run-verified"` or `"unverified"`, stamped by `library/app.py`'s
    /// `_review_record_auth`. `nil` (a row missing the field) reads the
    /// same as `"unverified"` — see `PRLadder.ReviewRecordEntry.auth`'s doc,
    /// which this mirrors: an unverified record still shows, but does not
    /// count toward a merge.
    let auth: String?
    let authReason: String?
    let reviewedRef: String?
    let pr: Int?
    let prose: String?
    let findings: [ReviewFinding]
    let createdAt: String?
    let updatedAt: String?
}

/// One entry of a record's `findings` array. The Library validates only
/// that each entry is a JSON object (`library/app.py`'s
/// `_validate_review_record_payload`); it imposes no fixed schema. `severity`
/// and `location` are the two fields the item names as what the pane shows
/// alongside each finding, and `text` is the finding's own prose — the shape
/// `library/tests/test_review_record_routes.py`'s round-trip test posts and
/// reads back. A finding carrying none of the three still draws, with every
/// field blank, rather than being dropped.
struct ReviewFinding: Equatable {
    let severity: String?
    let location: String?
    let text: String?
}

extension ReviewRecordRow {
    static func decode(_ raw: [String: Any]) -> ReviewRecordRow {
        guard let id = raw["id"] as? String, !id.isEmpty else { return .undecodable }
        let findings = ((raw["findings"] as? [[String: Any]]) ?? []).map(ReviewFinding.decode)
        return .record(ReviewRecord(
            id: id,
            role: raw["role"] as? String,
            verdict: raw["verdict"] as? String,
            auth: raw["auth"] as? String,
            authReason: raw["auth_reason"] as? String,
            reviewedRef: raw["reviewed_ref"] as? String,
            pr: (raw["pr"] as? NSNumber)?.intValue,
            prose: raw["prose"] as? String,
            findings: findings,
            createdAt: raw["created_at"] as? String,
            updatedAt: raw["updated_at"] as? String))
    }
}

extension ReviewFinding {
    static func decode(_ raw: [String: Any]) -> ReviewFinding {
        ReviewFinding(
            severity: raw["severity"] as? String,
            location: raw["location"] as? String,
            text: raw["text"] as? String)
    }
}

extension LibraryClient {
    /// One page of `GET /review-records`, decoded to the full
    /// `ReviewRecordRow` shape — `PRLadder.decodeReviewRecordsPage`'s
    /// counterpart for a reader that needs the prose and findings rather
    /// than only the four fields the ladder derivation reads. A body that
    /// is not a JSON object at all still throws — a transport-level
    /// surprise, matching every other decoder in this file.
    static func decodeReviewRecordsFullPage(_ raw: Data) throws -> (rows: [ReviewRecordRow], truncated: Bool) {
        let body = try refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        let rawRows = (root["review_records"] as? [[String: Any]]) ?? []
        let rows = rawRows.map(ReviewRecordRow.decode)
        let truncated = (root["truncated"] as? Bool) ?? false
        return (rows, truncated)
    }
}

/// The paged fetch of one pull request's full review records, server-side
/// filtered by `repo_identity` and `pr` (`LibraryClient.reviewRecordsRemoteCommand`'s
/// own doc on why both are safe to leave unverified client-side). Reuses
/// `PRLadder.pagedRows`/`pageLimit`/`maxPages` rather than a second paging
/// loop — one PR's record count is bounded by the same budget the ladder's
/// whole-repository read already budgets for.
enum ReviewRecordsFetch {
    static func fetch(
        target: SSHTarget, owner: String, repoName: String, pr: Int
    ) throws -> (rows: [ReviewRecordRow], truncated: Bool) {
        guard let safeOwner = LibraryClient.validateRepoSegment(owner),
              let safeRepoName = LibraryClient.validateRepoSegment(repoName) else {
            throw LibraryClient.FetchError.invalidInput("\(owner)/\(repoName)")
        }
        return try PRLadder.pagedRows(
            fetchPage: { offset in
                try SessionAgent.run(
                    LibraryClient.reviewRecordsArguments(
                        target: target, owner: safeOwner, repoName: safeRepoName, pr: pr,
                        limit: PRLadder.pageLimit, offset: offset),
                    classifyMissingCommand: false)
            },
            decodePage: LibraryClient.decodeReviewRecordsFullPage)
    }
}

// MARK: - Pure presentation helpers

extension ReviewRecordsPane {
    /// `"run-verified"` reads as itself; anything else — `"unverified"` or a
    /// missing `auth` — reads as "unverified", with the merge consequence
    /// spelled out, matching the item's own words ("mark `unverified` as
    /// not counting toward a merge").
    nonisolated static func authLabel(_ auth: String?) -> String {
        auth == "run-verified" ? "run-verified" : "unverified (does not count toward a merge)"
    }

    /// Whether `reviewedRef` is this PR's current head, stale (reviewed an
    /// earlier commit), or unknown (either side of the comparison is
    /// missing — a record with no `reviewedRef`, or a PR whose head was
    /// never resolved).
    enum HeadComparison: Equatable {
        case head
        case stale
        case unknown
    }

    nonisolated static func headComparison(reviewedRef: String?, headSha: String?) -> HeadComparison {
        guard let reviewedRef, let headSha else { return .unknown }
        return reviewedRef == headSha ? .head : .stale
    }
}

// MARK: - HTML generation

extension ReviewRecordsPane {
    /// Composes every record into one Markdown document, `ItemDetailModel.render`'s
    /// exact shape for `ItemDetailPane`: rendered through `session-view
    /// --render-file -` first, with `page(for:)` as the local, escaped
    /// fallback on a failed render.
    nonisolated static func markdown(for rows: [ReviewRecordRow], truncated: Bool, repo: String, pr: Int, headSha: String?) -> String {
        var sections: [String] = ["# \(singleLine(repo)) #\(pr) — reviews"]
        if truncated {
            sections.append(
                "_The Library holds more records than this pane could page in; some reviews may be missing._")
        }
        for row in rows {
            sections.append("---")
            switch row {
            case .undecodable:
                sections.append("_A review record could not be read._")
            case .record(let record):
                sections.append(recordMarkdown(record, headSha: headSha))
            }
        }
        return sections.joined(separator: "\n\n")
    }

    private nonisolated static func recordMarkdown(_ record: ReviewRecord, headSha: String?) -> String {
        var lines: [String] = []
        let role = record.role ?? "(unknown role)"
        let verdict = record.verdict ?? "(no verdict)"
        lines.append("## \(singleLine(role)) — \(singleLine(verdict))")

        var metaParts = ["auth: \(authLabel(record.auth))"]
        if let ref = record.reviewedRef {
            // `reviewed_ref` is reviewer-written text like its siblings, so it
            // is flattened to one line and loses any backtick before it sits in
            // a code span: a newline would start new Markdown structure and a
            // backtick would close the span early.
            let short = String(singleLine(ref).filter { $0 != "`" }.prefix(9))
            switch headComparison(reviewedRef: ref, headSha: headSha) {
            case .head: metaParts.append("reviewed `\(short)` (current head)")
            case .stale: metaParts.append("reviewed `\(short)` (stale)")
            case .unknown: metaParts.append("reviewed `\(short)`")
            }
        }
        if let updatedAt = record.updatedAt { metaParts.append(singleLine(updatedAt)) }
        lines.append(metaParts.joined(separator: " · "))

        if !record.findings.isEmpty {
            lines.append("### Findings")
            for (index, finding) in record.findings.enumerated() {
                var headingParts = ["Finding \(index + 1)"]
                headingParts.append(finding.severity ?? "severity unknown")
                if let location = finding.location { headingParts.append(location) }
                lines.append("**\(singleLine(headingParts.joined(separator: " · ")))**")
                if let text = finding.text, !text.isEmpty {
                    lines.append(closeUnbalancedFences(text))
                }
            }
        }

        if let prose = record.prose, !prose.isEmpty {
            lines.append(closeUnbalancedFences(prose))
        } else {
            lines.append("_No prose._")
        }
        return lines.joined(separator: "\n\n")
    }

    /// `ItemDetailPane.singleLine`, reused rather than copied.
    private nonisolated static func singleLine(_ value: String) -> String {
        ItemDetailPane.singleLine(value)
    }

    /// `ItemDetailPane.closeUnbalancedFences`, reused rather than copied.
    private nonisolated static func closeUnbalancedFences(_ value: String) -> String {
        ItemDetailPane.closeUnbalancedFences(value)
    }

    /// The pane's one legitimate non-review state: the item's own "done
    /// when" — "A PR with no records shows an empty state and never falls
    /// back to GitHub."
    nonisolated static func emptyStatePage(repo: String, pr: Int, appearance: Appearance) -> String {
        let theme = appearance == .dark ? "dark" : "light"
        return """
        <!DOCTYPE html>
        <html data-theme="\(theme)">
        <head><meta charset="UTF-8">\(viewerSharedStyle)</head>
        <body>
        <div class="filename">\(FileViewerPane.htmlEscape(repo)) #\(pr)</div>
        <p class="muted">No review records on file for this pull request.</p>
        </body>
        </html>
        """
    }

    /// The fallback path: every piece of Library-sourced text is
    /// HTML-escaped before embedding, the same discipline
    /// `ItemDetailPane.page(for:appearance:)` applies to a correction's body
    /// and comments.
    nonisolated static func page(
        for rows: [ReviewRecordRow], truncated: Bool, repo: String, pr: Int, headSha: String?,
        appearance: Appearance
    ) -> String {
        let theme = appearance == .dark ? "dark" : "light"
        let truncatedNotice = truncated
            ? "<p class=\"muted\">The Library holds more records than this pane could page in; "
              + "some reviews may be missing.</p>"
            : ""
        let rowsHTML = rows.map { recordHTML($0, headSha: headSha) }.joined()
        return """
        <!DOCTYPE html>
        <html data-theme="\(theme)">
        <head><meta charset="UTF-8">\(viewerSharedStyle)\(reviewRecordsStyle)</head>
        <body>
        <div class="filename">\(FileViewerPane.htmlEscape(repo)) #\(pr)</div>
        \(truncatedNotice)
        \(rowsHTML)
        </body>
        </html>
        """
    }

    private nonisolated static func recordHTML(_ row: ReviewRecordRow, headSha: String?) -> String {
        switch row {
        case .undecodable:
            return "<div class=\"record\"><p class=\"error\">A review record could not be read.</p></div>"
        case .record(let record):
            let role = FileViewerPane.htmlEscape(record.role ?? "(unknown role)")
            let verdict = FileViewerPane.htmlEscape(record.verdict ?? "(no verdict)")
            var metaParts = [FileViewerPane.htmlEscape("auth: \(authLabel(record.auth))")]
            if let ref = record.reviewedRef {
                let short = String(ref.prefix(9))
                let suffix: String
                switch headComparison(reviewedRef: ref, headSha: headSha) {
                case .head: suffix = " (current head)"
                case .stale: suffix = " (stale)"
                case .unknown: suffix = ""
                }
                metaParts.append(FileViewerPane.htmlEscape("reviewed \(short)\(suffix)"))
            }
            if let updatedAt = record.updatedAt { metaParts.append(FileViewerPane.htmlEscape(updatedAt)) }
            let findingsHTML = record.findings.enumerated().map { index, finding -> String in
                let heading = FileViewerPane.htmlEscape(
                    "Finding \(index + 1) · \(finding.severity ?? "severity unknown")"
                        + (finding.location.map { " · \($0)" } ?? ""))
                let text = FileViewerPane.htmlEscape(finding.text ?? "")
                return "<div class=\"finding\"><strong>\(heading)</strong><pre>\(text)</pre></div>"
            }.joined()
            let prose = record.prose.flatMap { $0.isEmpty ? nil : $0 } ?? "(no prose)"
            return """
            <div class="record">
              <h3>\(role) — \(verdict)</h3>
              <div class="muted">\(metaParts.joined(separator: " · "))</div>
              \(findingsHTML)
              <pre>\(FileViewerPane.htmlEscape(prose))</pre>
            </div>
            """
        }
    }

    private nonisolated static let reviewRecordsStyle = """
        <style>
        h3{font-size:13px;margin:0 0 4px}
        .record{margin-bottom:16px;padding-bottom:12px;border-bottom:1px solid var(--border)}
        .finding{margin:8px 0}
        </style>
        """
}

// MARK: - Model

/// Drives one `ReviewRecordsPane`: the read of one pull request's review
/// records and their render. Mirrors `ItemDetailModel`'s shape — see that
/// class's doc for why the fetch/render seams are injectable and why every
/// `guard cached... == ...` check exists (a slower, earlier load must never
/// draw over a newer one that has already started).
@MainActor
final class ReviewRecordsModel: ObservableObject {
    @Published var html = FileViewerPane.loadingPage(appearance: .light)
    @Published private(set) var isLoading = false

    var fetchRows: @Sendable (SSHTarget, String, String, Int) throws -> (rows: [ReviewRecordRow], truncated: Bool) = {
        target, owner, repoName, pr in
        try ReviewRecordsFetch.fetch(target: target, owner: owner, repoName: repoName, pr: pr)
    }
    var renderRows: @Sendable (
        [ReviewRecordRow], Bool, String, Int, String?, SSHTarget, Appearance
    ) async -> String = { rows, truncated, repo, pr, headSha, target, appearance in
        await ReviewRecordsModel.render(
            rows, truncated: truncated, repo: repo, pr: pr, headSha: headSha,
            target: target, appearance: appearance)
    }

    private var cachedRepo: String?
    private var cachedPR: Int?
    private var cachedHeadSha: String?
    private var cachedTarget: SSHTarget?
    private var cachedRows: [ReviewRecordRow] = []
    private var cachedTruncated = false

    func load(repo: String, pr: Int, headSha: String?, target: SSHTarget, appearance: Appearance) async {
        cachedRepo = repo
        cachedPR = pr
        cachedHeadSha = headSha
        cachedTarget = target
        cachedRows = []
        cachedTruncated = false
        isLoading = true
        html = FileViewerPane.loadingPage(appearance: appearance)
        let parts = repo.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            html = FileViewerPane.errorPage("not a usable owner/repo: \(repo)", appearance: appearance)
            isLoading = false
            return
        }
        let owner = String(parts[0]), repoName = String(parts[1])
        let read = fetchRows
        do {
            let (rows, truncated) = try await Task.detached { try read(target, owner, repoName, pr) }.value
            guard cachedRepo == repo, cachedPR == pr else { return }
            cachedRows = rows
            cachedTruncated = truncated
            let page = await renderRows(rows, truncated, repo, pr, headSha, target, appearance)
            guard cachedRepo == repo, cachedPR == pr else { return }
            html = page
        } catch {
            guard cachedRepo == repo, cachedPR == pr else { return }
            html = FileViewerPane.errorPage(
                "Could not reach the Library's reviews: \(ReviewRecordsModel.describe(error))",
                appearance: appearance)
        }
        isLoading = false
    }

    /// Same posture as `ItemDetailModel.reRender`: an appearance switch
    /// re-renders what is already held rather than re-fetching, and retries
    /// the fetch itself only when the prior one never produced a page the
    /// render seam saw.
    func reRender(appearance: Appearance) async {
        guard let repo = cachedRepo, let pr = cachedPR, let target = cachedTarget else {
            html = FileViewerPane.loadingPage(appearance: appearance)
            return
        }
        let page = await renderRows(cachedRows, cachedTruncated, repo, pr, cachedHeadSha, target, appearance)
        guard cachedRepo == repo, cachedPR == pr else { return }
        html = page
    }

    fileprivate static func render(
        _ rows: [ReviewRecordRow], truncated: Bool, repo: String, pr: Int, headSha: String?,
        target: SSHTarget, appearance: Appearance
    ) async -> String {
        guard !rows.isEmpty else {
            return ReviewRecordsPane.emptyStatePage(repo: repo, pr: pr, appearance: appearance)
        }
        let markdown = ReviewRecordsPane.markdown(for: rows, truncated: truncated, repo: repo, pr: pr, headSha: headSha)
        do {
            return try await Task.detached {
                try SessionAgent.renderFile(
                    target: target, content: markdown, name: "pr-\(pr)-reviews", appearance: appearance)
            }.value
        } catch {
            return ReviewRecordsPane.page(
                for: rows, truncated: truncated, repo: repo, pr: pr, headSha: headSha, appearance: appearance)
        }
    }

    /// Same wording strategy as `ItemDetailModel.describe`: the Library's
    /// own refusal message where its body carries one.
    private static func describe(_ error: Error) -> String {
        if case LibraryClient.FetchError.libraryRefused(let status, let body) = error {
            if let data = body.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["error"] as? String {
                return message
            }
            return "the Library refused (\(status)): \(body)"
        }
        if case LibraryClient.FetchError.invalidInput(let value) = error {
            return "that repository is not usable: \(value)"
        }
        return "\(error)"
    }
}
