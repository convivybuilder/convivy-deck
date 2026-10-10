import SwiftUI

/// The session pane's PR chip, put on the same derivation the cockpit's Pull
/// Requests panel draws from — `issue_01M1372GPQVK1Q042VZR2K1FAB`, under the
/// cockpit PR-ladder epic (`issue_01M0NWVW4YS8E04A657JD04QQD`).
///
/// **Claude Code's own `review_state` is no longer read for this.** It was
/// the verdict of the last review alone; the ladder carries CI and staleness
/// too, and the epic's own rule is that one pull request has one position
/// everywhere in Deck. Drawing both would let the two surfaces disagree
/// about the same PR — the exact thing this replacement removes.
enum SessionReviewChip {

    /// One pull request identified from Claude Code's own `pr.url` —
    /// `https://github.com/<owner>/<repo>/pull/<number>`.
    struct Reference: Equatable {
        let owner: String
        let repoName: String
        let number: Int
    }

    /// `nil` for a missing url, a url that is not a GitHub pull-request
    /// link, one with extra or missing path segments, or one whose
    /// owner/repo segment fails `LibraryClient.validateRepoSegment` — the
    /// same guard `PRLadder.fetchLadder` applies before composing a remote
    /// command, so a malformed or hostile owner/repo never reaches an ssh
    /// command line from this path either. Every failure draws the chip's
    /// plain "PR #N" fallback rather than guessing.
    static func parsePullRequestURL(_ urlString: String?) -> Reference? {
        guard let urlString, let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(), host == "github.com" || host == "www.github.com"
        else { return nil }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == 4, segments[2] == "pull", let number = Int(segments[3]) else { return nil }
        guard let owner = LibraryClient.validateRepoSegment(segments[0]),
              let repoName = LibraryClient.validateRepoSegment(segments[1]) else { return nil }
        return Reference(owner: owner, repoName: repoName, number: number)
    }

    /// The row matching `reference.number` out of a fetched ladder, or nil
    /// when the fetch has not produced rows for this PR — no result yet, a
    /// whole-fetch `.degraded`, or a repo whose rows simply do not include
    /// this number.
    static func matchingResult(_ reference: Reference, in fetchResult: PRLadder.FetchResult?) -> PRLadder.LadderResult? {
        guard case .ladder(let results, _) = fetchResult else { return nil }
        return results.first { $0.number == reference.number }
    }

    /// The chip's presentation for one PR vital, choosing between the
    /// cockpit's own ladder fetch(es) and a pane-owned fallback: when
    /// `sharedReadings` already names this PR's repo (a crew can now follow
    /// several — `issue_01M2P5JHM1G8XCMKM4HEHVJB2P`), that entry's own
    /// `result` is read directly rather than fetching the same repo a
    /// second time; otherwise `fallbackResult` (a fetch scoped to this PR's
    /// own repo) is read instead. `nil` whenever the url does not parse, or
    /// when neither result yet holds a row for this PR's number — every one
    /// of those draws the chip's plain "PR #N" fallback
    /// (`SessionReviewChip.label`), never `review_state`.
    static func presentation(
        for pr: SessionState.Vitals.PullRequest,
        sharedReadings: [(owner: String, repoName: String, result: PRLadder.FetchResult?)],
        fallbackResult: PRLadder.FetchResult?
    ) -> PRLadderRow.Presentation? {
        guard let reference = parsePullRequestURL(pr.url) else { return nil }
        let fetchResult: PRLadder.FetchResult?
        if let covered = sharedReadings.first(where: { $0.owner == reference.owner && $0.repoName == reference.repoName }) {
            fetchResult = covered.result
        } else {
            fetchResult = fallbackResult
        }
        return matchingResult(reference, in: fetchResult).map { PRLadderRow.present($0.position) }
    }

    /// "PR #33" or "PR #33 · Ready to merge" — the same wording
    /// `PRLadderRow.present` gives the cockpit panel, so the two surfaces
    /// read as one rather than two spellings of the same state.
    static func label(pr: SessionState.Vitals.PullRequest, presentation: PRLadderRow.Presentation?) -> String {
        guard let presentation else { return "PR #\(pr.number)" }
        return "PR #\(pr.number) · \(presentation.label)"
    }

    /// `.secondary` with no presentation (loading, degraded, or no matching
    /// row) — the chip's existing neutral default — otherwise the ink
    /// `CockpitView.pullRequestSeverityInk` solves for the panel row, using
    /// the pane's own pre-solved inks rather than re-deriving them from a
    /// surface this row cannot see (`VitalsRow.warningInk`'s own doc gives
    /// the same reason for the two inks it already takes this way).
    static func tint(presentation: PRLadderRow.Presentation?, warningInk: Color, errorInk: Color, attentionInk: Color) -> Color {
        guard let presentation else { return .secondary }
        switch presentation.severity {
        case .neutral: return .secondary
        case .caution: return warningInk
        case .failure: return errorInk
        case .invitation: return attentionInk
        }
    }
}
