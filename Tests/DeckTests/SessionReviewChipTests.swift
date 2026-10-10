import XCTest
import SwiftUI
@testable import Deck

/// `SessionReviewChip`: the session pane's PR chip, put on `PRLadder`'s
/// derivation rather than Claude Code's own `review_state`
/// (`issue_01M1372GPQVK1Q042VZR2K1FAB`). Two things are pinned here: parsing
/// `pr.url` into a `(owner, repoName, number)` reference, and choosing a
/// presentation from a fetched ladder — including the two cases that must
/// draw the plain "PR #N" fallback rather than guessing.
final class SessionReviewChipTests: XCTestCase {

    // MARK: - URL parsing

    func testAValidGitHubPullRequestURLParses() {
        let reference = SessionReviewChip.parsePullRequestURL("https://github.com/convivy/convivy-deck/pull/92")
        XCTAssertEqual(reference, .init(owner: "convivy", repoName: "convivy-deck", number: 92))
    }

    func testAMissingURLDoesNotParse() {
        XCTAssertNil(SessionReviewChip.parsePullRequestURL(nil))
    }

    func testANonGitHubHostDoesNotParse() {
        XCTAssertNil(SessionReviewChip.parsePullRequestURL("https://gitlab.com/convivy/convivy-deck/pull/92"))
    }

    func testExtraPathSegmentsDoNotParse() {
        XCTAssertNil(SessionReviewChip.parsePullRequestURL(
            "https://github.com/convivy/convivy-deck/pull/92/files"))
        XCTAssertNil(SessionReviewChip.parsePullRequestURL(
            "https://github.com/convivy/convivy-deck/issues/92"))
    }

    func testMissingPathSegmentsDoNotParse() {
        XCTAssertNil(SessionReviewChip.parsePullRequestURL("https://github.com/convivy/convivy-deck"))
        XCTAssertNil(SessionReviewChip.parsePullRequestURL("https://github.com"))
    }

    func testANonNumericPullRequestSegmentDoesNotParse() {
        XCTAssertNil(SessionReviewChip.parsePullRequestURL(
            "https://github.com/convivy/convivy-deck/pull/not-a-number"))
    }

    func testInvalidRepoSegmentCharactersDoNotParse() {
        // `LibraryClient.validateRepoSegment`'s own charset guard rejects
        // anything outside `[A-Za-z0-9._-]` — `~` and `!` are both legal,
        // unescaped URL path characters, so these reach the charset check
        // rather than failing to parse as a URL at all.
        XCTAssertNil(SessionReviewChip.parsePullRequestURL(
            "https://github.com/convivy/con~vivy-deck/pull/92"))
        XCTAssertNil(SessionReviewChip.parsePullRequestURL(
            "https://github.com/con!vivy/convivy-deck/pull/92"))
    }

    func testWWWGitHubHostParsesTheSameAsBareGitHub() {
        XCTAssertEqual(
            SessionReviewChip.parsePullRequestURL("https://www.github.com/convivy/convivy-deck/pull/92"),
            SessionReviewChip.parsePullRequestURL("https://github.com/convivy/convivy-deck/pull/92"))
    }

    // MARK: - Presentation from a fetched ladder

    private func pr(number: Int = 92, url: String? = "https://github.com/convivy/convivy-deck/pull/92")
        -> SessionState.Vitals.PullRequest {
        .init(number: number, url: url)
    }

    private func ladderResult(number: Int, position: PRLadder.Position) -> PRLadder.LadderResult {
        .init(repo: "convivy/convivy-deck", number: number, title: "title", author: "author",
              position: position, staleReviewCount: 0, updatedAt: nil)
    }

    /// One shared reading, in `presentation`'s own `sharedReadings` shape —
    /// pulled out since every test below builds exactly this.
    private func reading(owner: String = "convivy", repoName: String = "convivy-deck", result: PRLadder.FetchResult?)
        -> (owner: String, repoName: String, result: PRLadder.FetchResult?) {
        (owner, repoName, result)
    }

    /// The reuse path: the cockpit's own ladder already covers this PR's
    /// repo, so its result is read directly and the fallback is never
    /// consulted.
    func testReusesTheSharedLadderWhenItCoversTheSameRepo() {
        let shared = PRLadder.FetchResult.ladder([ladderResult(number: 92, position: .readyToMerge)], truncated: false)
        let presentation = SessionReviewChip.presentation(
            for: pr(), sharedReadings: [reading(result: shared)],
            fallbackResult: .ladder([ladderResult(number: 92, position: .failedCI)], truncated: false))
        XCTAssertEqual(presentation, PRLadderRow.present(.readyToMerge))
    }

    /// The fallback path: the shared ladder covers a different repo, so the
    /// pane's own fetch is read instead.
    func testFallsBackToItsOwnFetchWhenTheSharedLadderCoversADifferentRepo() {
        let presentation = SessionReviewChip.presentation(
            for: pr(),
            sharedReadings: [reading(repoName: "vivy",
                result: .ladder([ladderResult(number: 92, position: .failedCI)], truncated: false))],
            fallbackResult: .ladder([ladderResult(number: 92, position: .inCI)], truncated: false))
        XCTAssertEqual(presentation, PRLadderRow.present(.inCI))
    }

    /// No url, or one that does not parse — the plain "PR #N" fallback,
    /// never a guess at a position.
    func testNoPresentationWhenTheURLDoesNotParse() {
        XCTAssertNil(SessionReviewChip.presentation(
            for: pr(url: nil),
            sharedReadings: [reading(result: .ladder([ladderResult(number: 92, position: .readyToMerge)], truncated: false))],
            fallbackResult: nil))
    }

    /// Still loading (no result yet) — nil, not a guess.
    func testNoPresentationWhileLoading() {
        XCTAssertNil(SessionReviewChip.presentation(
            for: pr(), sharedReadings: [reading(result: nil)], fallbackResult: nil))
    }

    /// A whole-fetch degrade — nil, never drawn as if it were a real row.
    func testNoPresentationWhenTheFetchIsDegraded() {
        XCTAssertNil(SessionReviewChip.presentation(
            for: pr(),
            sharedReadings: [reading(result: .degraded(reason: "the Library's /signals repo filter is not enforced yet"))],
            fallbackResult: nil))
    }

    /// The fetch succeeded, and covers the right repo, but simply has no row
    /// for this PR's number — still nil, distinct from every case above only
    /// by which branch of `PRLadder.FetchResult` produced it.
    func testNoPresentationWhenTheLadderHasNoRowForThisNumber() {
        XCTAssertNil(SessionReviewChip.presentation(
            for: pr(number: 92),
            sharedReadings: [reading(result: .ladder([ladderResult(number: 41, position: .readyToMerge)], truncated: false))],
            fallbackResult: nil))
    }

    /// A ladder row IS found, but its own derived position is itself
    /// `.stateUnknown` — a legitimate presentation, not the "no row" case
    /// above, and it draws its own label rather than "PR #N".
    func testAStateUnknownRowStillDrawsItsOwnPresentation() {
        let presentation = SessionReviewChip.presentation(
            for: pr(),
            sharedReadings: [reading(
                result: .ladder([ladderResult(number: 92, position: .stateUnknown(.noPRRecord))], truncated: false))],
            fallbackResult: nil)
        XCTAssertEqual(presentation, PRLadderRow.present(.stateUnknown(.noPRRecord)))
    }

    /// The multi-repo case `issue_01M2P5JHM1G8XCMKM4HEHVJB2P` adds: several
    /// readings are covered at once, and the one matching this PR's repo is
    /// the one consulted — not merely the first.
    func testReusesTheMatchingReadingAmongSeveralCoveredRepos() {
        let presentation = SessionReviewChip.presentation(
            for: pr(),
            sharedReadings: [
                reading(repoName: "vivy", result: .ladder([ladderResult(number: 92, position: .failedCI)], truncated: false)),
                reading(repoName: "convivy-deck", result: .ladder([ladderResult(number: 92, position: .readyToMerge)], truncated: false)),
            ],
            fallbackResult: nil)
        XCTAssertEqual(presentation, PRLadderRow.present(.readyToMerge))
    }

    // MARK: - Label and tint

    func testLabelIsPlainWithNoPresentation() {
        XCTAssertEqual(SessionReviewChip.label(pr: pr(number: 7), presentation: nil), "PR #7")
    }

    func testLabelAppendsThePresentationWordingWhenPresent() {
        XCTAssertEqual(
            SessionReviewChip.label(pr: pr(number: 92), presentation: PRLadderRow.present(.readyToMerge)),
            "PR #92 · Ready to merge")
    }

    func testTintIsSecondaryWithNoPresentation() {
        XCTAssertEqual(
            SessionReviewChip.tint(presentation: nil, warningInk: .orange, errorInk: .red, attentionInk: .blue),
            .secondary)
    }

    func testTintFollowsSeverity() {
        XCTAssertEqual(
            SessionReviewChip.tint(presentation: PRLadderRow.present(.changesRequested),
                                    warningInk: .orange, errorInk: .red, attentionInk: .blue),
            .orange)
        XCTAssertEqual(
            SessionReviewChip.tint(presentation: PRLadderRow.present(.failedCI),
                                    warningInk: .orange, errorInk: .red, attentionInk: .blue),
            .red)
        XCTAssertEqual(
            SessionReviewChip.tint(presentation: PRLadderRow.present(.readyToMerge),
                                    warningInk: .orange, errorInk: .red, attentionInk: .blue),
            .blue)
        XCTAssertEqual(
            SessionReviewChip.tint(presentation: PRLadderRow.present(.inReview),
                                    warningInk: .orange, errorInk: .red, attentionInk: .blue),
            .secondary)
    }
}
