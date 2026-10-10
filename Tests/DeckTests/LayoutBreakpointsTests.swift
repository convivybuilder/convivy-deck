import XCTest
@testable import Deck

/// `LayoutBreakpoints`: the two width thresholds the narrow layout collapses
/// on, tested at both sides of each edge — see the type's own doc for why
/// 1280/1000 were chosen over the work item's 1100/820.
final class LayoutBreakpointsTests: XCTestCase {

    // MARK: - The rail's own breakpoint

    func testAboveTheRailBreakpointTheRailStaysFull() {
        XCTAssertFalse(LayoutBreakpoints.isRailCollapsed(totalWidth: 1_281))
    }

    func testAtTheRailBreakpointTheRailStaysFull() {
        // `<`, not `<=` — the threshold itself is still the wide rail, so a
        // window sized to exactly 1280 does not flicker between the two on
        // the boundary pixel.
        XCTAssertFalse(LayoutBreakpoints.isRailCollapsed(totalWidth: LayoutBreakpoints.railCollapse))
    }

    func testBelowTheRailBreakpointTheRailCollapses() {
        XCTAssertTrue(LayoutBreakpoints.isRailCollapsed(totalWidth: 1_279))
    }

    // MARK: - The column's own breakpoint

    func testAboveTheColumnBreakpointTheColumnStaysDocked() {
        XCTAssertFalse(LayoutBreakpoints.usesColumnSheet(totalWidth: 1_001))
    }

    func testAtTheColumnBreakpointTheColumnStaysDocked() {
        XCTAssertFalse(LayoutBreakpoints.usesColumnSheet(totalWidth: LayoutBreakpoints.columnSheet))
    }

    func testBelowTheColumnBreakpointTheColumnBecomesASheet() {
        XCTAssertTrue(LayoutBreakpoints.usesColumnSheet(totalWidth: 999))
    }

    // MARK: - Both give way together, below the rail's own breakpoint

    func testAtTheWindowFloorBothHaveCollapsed() {
        XCTAssertTrue(LayoutBreakpoints.isRailCollapsed(totalWidth: LayoutBreakpoints.windowMinWidth))
        XCTAssertTrue(LayoutBreakpoints.usesColumnSheet(totalWidth: LayoutBreakpoints.windowMinWidth))
    }

    // MARK: - Today's fixed floor no longer applies

    /// The window used to refuse anything below 900 — see
    /// `ContentView.body`'s old `.frame(minWidth: 900, ...)`. This phase
    /// replaces it; a regression that quietly restored the old constant
    /// would pass every other assertion here while reopening exactly the
    /// bug this work item exists to fix.
    func testTheNewFloorIsNotTheOldFixedNine00() {
        XCTAssertNotEqual(LayoutBreakpoints.windowMinWidth, 900)
        XCTAssertEqual(LayoutBreakpoints.windowMinWidth, 720)
    }
}
