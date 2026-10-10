import XCTest
@testable import Deck

/// `PRLadderRow.present`: the pure position → presentation map the cockpit's
/// Pull Requests panel draws from. Pinned here rather than only exercised
/// through the view, since a view has no return value XCTest can assert on
/// (`CockpitViewTests`' own header gives the same reason for `childProgress`).
///
/// The specification's own distinctions are what these tests are organized
/// around: "in CI" vs "failed CI", "in second review" vs "ready to merge",
/// and "waiting on a person" vs "waiting on a machine" must each draw differently.
final class PRLadderRowTests: XCTestCase {

    // MARK: - The three required distinctions

    /// "In CI" and "failed CI" must draw differently — the specification's
    /// own first example of two positions implying opposite next actions.
    func testInCIAndFailedCIDrawDifferentSeverities() {
        XCTAssertEqual(PRLadderRow.present(.inCI).severity, .neutral)
        XCTAssertEqual(PRLadderRow.present(.failedCI).severity, .failure)
        XCTAssertNotEqual(PRLadderRow.present(.inCI).severity, PRLadderRow.present(.failedCI).severity)
    }

    /// "In second review" and "ready to merge" must draw differently — the
    /// specification's second example.
    func testInSecondReviewAndReadyToMergeDrawDifferently() {
        let inSecondReview = PRLadderRow.present(.inSecondReview)
        let readyToMerge = PRLadderRow.present(.readyToMerge)
        XCTAssertNotEqual(inSecondReview.severity, readyToMerge.severity)
    }

    /// "Ready to merge" is the one position that draws as `.invitation` —
    /// the ink that means "waiting on a person" and is never reused for anything
    /// a machine is still doing (in review, in second review, in CI).
    func testReadyToMergeIsTheOnlyInvitationSeverityPosition() {
        let machinePositions: [PRLadder.Position] = [.inReview, .inSecondReview, .inCI]
        for position in machinePositions {
            XCTAssertNotEqual(PRLadderRow.present(position).severity, .invitation)
        }
        XCTAssertEqual(PRLadderRow.present(.readyToMerge).severity, .invitation)
    }

    // MARK: - Every position presents distinctly enough to tell apart

    /// No two of the seven named rungs plus closed/merged/unknown share a
    /// label — a coincidence here would be exactly the "two things read as
    /// one" bug the epic exists to close.
    func testEveryPositionHasADistinctLabel() {
        let positions: [PRLadder.Position] = [
            .draft, .inReview, .changesRequested, .inSecondReview, .inCI, .failedCI, .readyToMerge,
            .closed(.closed), .closed(.merged), .stateUnknown(.noPRRecord),
        ]
        let labels = positions.map { PRLadderRow.present($0).label }
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    // MARK: - Terminal states

    func testClosedAndMergedAreTerminal() {
        XCTAssertTrue(PRLadderRow.present(.closed(.closed)).isTerminal)
        XCTAssertTrue(PRLadderRow.present(.closed(.merged)).isTerminal)
    }

    func testOpenPositionsAreNotTerminal() {
        let openPositions: [PRLadder.Position] = [
            .draft, .inReview, .changesRequested, .inSecondReview, .inCI, .failedCI, .readyToMerge,
        ]
        for position in openPositions {
            XCTAssertFalse(PRLadderRow.present(position).isTerminal)
        }
    }

    // MARK: - stateUnknown carries its reason in the label

    func testStateUnknownLabelNamesNoPRRecord() {
        XCTAssertTrue(PRLadderRow.present(.stateUnknown(.noPRRecord)).label.contains("no record"))
    }

    func testStateUnknownLabelNamesTheCIDetailVerbatim() {
        let label = PRLadderRow.present(.stateUnknown(.noCISource(detail: "no check-run source for this repo"))).label
        XCTAssertTrue(label.contains("no check-run source for this repo"))
    }

    func testStateUnknownLabelNamesAnUnrecognizedStateVerbatim() {
        let label = PRLadderRow.present(.stateUnknown(.unrecognizedState("FOO"))).label
        XCTAssertTrue(label.contains("FOO"))
    }

    /// The empty-string case (`bin/pr-state-capture`'s no-`state`-key shape,
    /// per `PRLadder.UnknownReason.unrecognizedState`'s own doc) must not
    /// draw an empty or blank-looking reason.
    func testStateUnknownLabelForAnEmptyReportedStateSaysSomethingWasSeenAndBlank() {
        let label = PRLadderRow.present(.stateUnknown(.unrecognizedState(""))).label
        XCTAssertTrue(label.contains("no state"))
    }

    // MARK: - staleReviewsLabel

    func testStaleReviewsLabelIsNilForZero() {
        XCTAssertNil(PRLadderRow.staleReviewsLabel(0))
    }

    func testStaleReviewsLabelSingularForOne() {
        XCTAssertEqual(PRLadderRow.staleReviewsLabel(1), "1 stale review")
    }

    func testStaleReviewsLabelPluralForMoreThanOne() {
        XCTAssertEqual(PRLadderRow.staleReviewsLabel(3), "3 stale reviews")
    }

    // MARK: - dotColor: every Position case, per the stoplight's own spec

    func testDotColorMergedIsMerged() {
        XCTAssertEqual(PRLadderRow.dotColor(.closed(.merged)), .merged)
    }

    func testDotColorReadyToMergeIsReady() {
        XCTAssertEqual(PRLadderRow.dotColor(.readyToMerge), .ready)
    }

    func testDotColorClosedNotMergedIsClosed() {
        XCTAssertEqual(PRLadderRow.dotColor(.closed(.closed)), .closed)
    }

    /// A human still reading — in review, in second review, changes
    /// requested — is the amber dot, whether the next action falls to the
    /// author or a machine.
    func testDotColorReviewPositionsAreAllInReview() {
        let reviewPositions: [PRLadder.Position] = [.inReview, .changesRequested, .inSecondReview]
        for position in reviewPositions {
            XCTAssertEqual(PRLadderRow.dotColor(position), .inReview)
        }
    }

    /// A build still running is its own brown, not the review amber.
    func testDotColorInCIIsInCI() {
        XCTAssertEqual(PRLadderRow.dotColor(.inCI), .inCI)
    }

    /// A broken build is red, distinct from every other in-flight rung —
    /// the operator's revision (2026-09-16): CI failing and CI running must draw as
    /// different colours, not one shared "in flight" amber.
    func testDotColorFailedCIIsFailedCI() {
        XCTAssertEqual(PRLadderRow.dotColor(.failedCI), .failedCI)
    }

    /// Every in-flight rung still tells apart from every other: no two of
    /// review/CI/failed-CI/ready/draft collapse onto the same dot colour.
    func testInFlightDotColorsAreAllDistinct() {
        let colors: [PRLadderRow.DotColor] = [
            PRLadderRow.dotColor(.inReview),
            PRLadderRow.dotColor(.inCI),
            PRLadderRow.dotColor(.failedCI),
            PRLadderRow.dotColor(.readyToMerge),
            PRLadderRow.dotColor(.draft),
        ]
        XCTAssertEqual(Set(colors).count, colors.count)
    }

    func testDotColorDraftIsDraftOrUnknown() {
        XCTAssertEqual(PRLadderRow.dotColor(.draft), .draftOrUnknown)
    }

    func testDotColorStateUnknownIsDraftOrUnknown() {
        XCTAssertEqual(PRLadderRow.dotColor(.stateUnknown(.noPRRecord)), .draftOrUnknown)
        XCTAssertEqual(PRLadderRow.dotColor(.stateUnknown(.missingState)), .draftOrUnknown)
        XCTAssertEqual(PRLadderRow.dotColor(.stateUnknown(.missingHeadSha)), .draftOrUnknown)
        XCTAssertEqual(PRLadderRow.dotColor(.stateUnknown(.unrecognizedState("FOO"))), .draftOrUnknown)
        XCTAssertEqual(
            PRLadderRow.dotColor(.stateUnknown(.noCISource(detail: "no source"))), .draftOrUnknown)
    }

    // MARK: - githubURL — the merge affordance's placeholder

    func testGithubURLBuildsFromRepoAndNumber() {
        let url = PRLadderRow.githubURL(repo: "convivy/convivy-deck", number: 241)
        XCTAssertEqual(url?.absoluteString, "https://github.com/convivy/convivy-deck/pull/241")
    }

    /// A repo missing the owner or repo-name segment refuses to guess —
    /// the row draws no link rather than a link built from half a pair.
    func testGithubURLIsNilWhenRepoHasNoSlash() {
        XCTAssertNil(PRLadderRow.githubURL(repo: "convivy-deck", number: 241))
    }

    func testGithubURLIsNilWhenRepoHasATrailingSlash() {
        XCTAssertNil(PRLadderRow.githubURL(repo: "convivy/convivy-deck/", number: 241))
    }

    /// A third slash, e.g. a path smuggled onto the end of `repo`, refuses
    /// rather than taking the first two segments and dropping the rest.
    func testGithubURLIsNilWhenRepoHasAThirdSegment() {
        XCTAssertNil(PRLadderRow.githubURL(repo: "convivy/convivy-deck/extra", number: 241))
    }

    /// A segment outside `LibraryClient.validateRepoSegment`'s charset
    /// (the same check `PRLadder.fetchLadder` runs on this field) refuses
    /// rather than URL-encoding something that was never a valid owner or
    /// repo name.
    func testGithubURLIsNilWhenASegmentFailsValidation() {
        XCTAssertNil(PRLadderRow.githubURL(repo: "convivy/repo name", number: 241))
        XCTAssertNil(PRLadderRow.githubURL(repo: "convivy/repo!name", number: 241))
    }
}
