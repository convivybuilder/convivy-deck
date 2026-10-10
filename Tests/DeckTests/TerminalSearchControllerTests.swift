import XCTest
@testable import Deck

/// `TerminalSearchController` reaches a live `SSHStderrWatchingTerminalView`
/// through `@MainActor`-isolated, weakly-held state — the same "exercised in
/// live verify" shape `TerminalTargetTests`' exit-behaviour section names for
/// `TerminalPaneView.Coordinator`. What's testable here without a live view
/// is the pure summary-to-label mapping `searchMatchSummary`'s (index, total)
/// feeds into.
final class TerminalSearchControllerTests: XCTestCase {
    func testNoMatchesReadsAsNoResults() {
        XCTAssertEqual(TerminalSearchController.label(index: 0, total: 0, limit: 1000), "No results")
    }

    func testOrdinaryMatchReadsAsIndexOfTotal() {
        XCTAssertEqual(TerminalSearchController.label(index: 3, total: 17, limit: 1000), "3 of 17")
    }

    func testFirstOfOneReadsAsOneOfOne() {
        XCTAssertEqual(TerminalSearchController.label(index: 1, total: 1, limit: 1000), "1 of 1")
    }

    /// `searchMatchSummary`'s `limit` truncates the scan, so a scrollback
    /// with exactly `limit` matches and one with far more are indistinguishable
    /// from the raw total alone — both come back as `limit`. The label must
    /// say "1000+", not the flat, silently-wrong "1000".
    func testTotalAtTheCapReadsAsPlusRatherThanAFlatNumber() {
        XCTAssertEqual(TerminalSearchController.label(index: 250, total: 1000, limit: 1000), "250 of 1000+")
    }

    /// Belt-and-suspenders against a total that somehow exceeds the limit
    /// (SwiftTerm never returns one, but the mapping should not silently
    /// print a number bigger than what was actually promised to be shown).
    func testTotalPastTheCapStillReadsAsPlusNotTheRawNumber() {
        XCTAssertEqual(TerminalSearchController.label(index: 1, total: 1234, limit: 1000), "1 of 1000+")
    }

    func testASmallerLimitCapsAtItsOwnValue() {
        XCTAssertEqual(TerminalSearchController.label(index: 5, total: 5, limit: 5), "5 of 5+")
    }

    @MainActor
    func testResultsLabelReflectsTheControllersOwnState() {
        let controller = TerminalSearchController()
        XCTAssertEqual(controller.resultsLabel, "No results")
    }
}
