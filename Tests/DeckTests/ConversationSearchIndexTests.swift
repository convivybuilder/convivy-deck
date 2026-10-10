import XCTest
@testable import Deck

/// The wrap-around arithmetic behind `findNext`/`findPrevious`, and
/// `parseSearchCount`'s decoding — both pure, so both are pinned without a
/// live `WKWebView`. The same split `ScrollPreservationTests` and
/// `SessionPaneModel`'s own `shouldRender`/`backgroundActive` tests use: the
/// part that decides is testable directly, the part that reaches WebKit is
/// covered separately in `ConversationSearchCapabilityTests`.
@MainActor
final class ConversationSearchIndexTests: XCTestCase {

    // MARK: - nextSearchIndex / previousSearchIndex

    func testNextAdvancesByOne() {
        XCTAssertEqual(ConversationScrollState.nextSearchIndex(current: 2, total: 5), 3)
    }

    func testNextWrapsPastTheLastMatchToTheFirst() {
        XCTAssertEqual(ConversationScrollState.nextSearchIndex(current: 5, total: 5), 1)
    }

    func testPreviousStepsBackByOne() {
        XCTAssertEqual(ConversationScrollState.previousSearchIndex(current: 3, total: 5), 2)
    }

    func testPreviousWrapsPastTheFirstMatchToTheLast() {
        XCTAssertEqual(ConversationScrollState.previousSearchIndex(current: 1, total: 5), 5)
    }

    /// Zero matches has no position to move to or from, in either direction —
    /// the caller (`findNext`/`findPrevious`) already guards on `total > 0`
    /// before calling either, but the pure function holds the invariant on
    /// its own too rather than trusting every call site to.
    func testZeroTotalHasNoPositionInEitherDirection() {
        XCTAssertEqual(ConversationScrollState.nextSearchIndex(current: 0, total: 0), 0)
        XCTAssertEqual(ConversationScrollState.previousSearchIndex(current: 0, total: 0), 0)
    }

    func testSingleMatchStaysOnItselfInEitherDirection() {
        XCTAssertEqual(ConversationScrollState.nextSearchIndex(current: 1, total: 1), 1)
        XCTAssertEqual(ConversationScrollState.previousSearchIndex(current: 1, total: 1), 1)
    }

    // MARK: - parseSearchCount

    func testParsesAnOrdinaryResult() {
        let result = ConversationWebView.parseSearchCount(["total": 4, "capped": false])
        XCTAssertEqual(result.total, 4)
        XCTAssertFalse(result.capped)
    }

    func testParsesADoubleTotalTheJSBridgeMayHandBack() {
        // JavaScriptCore numbers cross the bridge as NSNumber, which Swift
        // can decode as either Int or Double depending on the exact value —
        // both must be accepted, the same tolerance `parseReadResult` and
        // `parsePinCandidate` already give every numeric field on this
        // bridge.
        let result = ConversationWebView.parseSearchCount(["total": 4.0, "capped": true])
        XCTAssertEqual(result.total, 4)
        XCTAssertTrue(result.capped)
    }

    /// Degrades to "no matches" rather than crashing or reporting a bogus
    /// count — this runs against a page built from a transcript, so a shape
    /// it does not expect is a case to survive, matching the posture every
    /// other parser on this bridge takes.
    func testNonDictionaryResultIsNoMatches() {
        let result = ConversationWebView.parseSearchCount("not a dictionary")
        XCTAssertEqual(result.total, 0)
        XCTAssertFalse(result.capped)
    }

    func testNilResultIsNoMatches() {
        let result = ConversationWebView.parseSearchCount(nil)
        XCTAssertEqual(result.total, 0)
        XCTAssertFalse(result.capped)
    }

    func testMissingCappedDefaultsToFalse() {
        let result = ConversationWebView.parseSearchCount(["total": 2])
        XCTAssertEqual(result.total, 2)
        XCTAssertFalse(result.capped)
    }

    func testMissingTotalDefaultsToZero() {
        let result = ConversationWebView.parseSearchCount(["capped": true])
        XCTAssertEqual(result.total, 0)
        XCTAssertTrue(result.capped)
    }

    // MARK: - label / resultsLabel

    func testLabelWithNoMatchesReadsAsNoResults() {
        XCTAssertEqual(ConversationScrollState.label(index: 0, total: 0, capped: false), "No results")
    }

    func testLabelWithAnOrdinaryMatchReadsAsIndexOfTotal() {
        XCTAssertEqual(ConversationScrollState.label(index: 3, total: 17, capped: false), "3 of 17")
    }

    /// The find bar must not print the cap's bare number as if it were an
    /// exact count — `searchCapped` is what tells it the true total was
    /// never counted, only that at least `ConversationWebView.searchMatchCap`
    /// matches exist.
    func testLabelAtTheCapReadsAsPlusRatherThanAFlatNumber() {
        XCTAssertEqual(ConversationScrollState.label(index: 250, total: 1000, capped: true), "250 of 1000+")
    }

    func testResultsLabelReflectsTheStatesOwnFields() {
        let state = ConversationScrollState()
        XCTAssertEqual(state.resultsLabel, "No results")
    }

    // MARK: - Instance state, no live webView

    /// `search(_:)` sets the term immediately even with nothing to count
    /// against — `recount` guards on `webView` being present and simply
    /// never publishes a total, leaving it at its initial 0 rather than
    /// crashing on a nil web view.
    func testSearchWithNoWebViewSetsTheTermButPublishesNoCount() {
        let state = ConversationScrollState()
        state.search("widget")
        XCTAssertEqual(state.searchTerm, "widget")
        XCTAssertEqual(state.searchTotal, 0)
        XCTAssertEqual(state.searchIndex, 0)
    }

    func testSearchWithAnEmptyTermClearsInstead() {
        let state = ConversationScrollState()
        state.search("widget")
        state.search("")
        XCTAssertNil(state.searchTerm)
    }

    func testFindNextIsANoOpWithNoActiveSearch() {
        let state = ConversationScrollState()
        state.findNext()
        XCTAssertEqual(state.searchIndex, 0)
    }

    func testClearSearchResetsEveryPublishedField() {
        let state = ConversationScrollState()
        state.search("widget")
        state.clearSearch()
        XCTAssertNil(state.searchTerm)
        XCTAssertEqual(state.searchIndex, 0)
        XCTAssertEqual(state.searchTotal, 0)
        XCTAssertFalse(state.searchCapped)
    }

    /// `documentDidChange()` with nothing being searched must not start
    /// counting against a term that does not exist — there is nothing for a
    /// poll tick or a delta apply to disturb when the reader has not typed
    /// into the find bar.
    func testDocumentDidChangeIsANoOpWithNoActiveSearch() {
        let state = ConversationScrollState()
        state.documentDidChange()
        XCTAssertNil(state.searchTerm)
        XCTAssertEqual(state.searchTotal, 0)
    }
}
