import XCTest
@testable import Deck

/// The steward's board is `CockpitView` drawing `boardPanelIDs`
/// (issue_01M2GAFYACF3MZCF89F0HVZ5CP), so its Course draws and fetches
/// exactly as a project crew's cockpit does.
final class StewardBoardPanelsTests: XCTestCase {

    /// Fleet first, then Proposals directly above the Course it feeds, the
    /// corrections queue directly below it (the operator, 2026-09-24), then the crew's
    /// working documents.
    func testTheBoardDrawsDispatchedProposalsCourseQueueAndDocumentsInThatOrder() {
        XCTAssertEqual(CockpitView.boardPanelIDs,
                       [CockpitView.dispatchedPanelID, "proposals", CockpitView.coursePanelID,
                        CockpitView.correctionsQueuePanelID, CockpitView.documentsPanelID])
    }

    /// The queue sits immediately after the Course, as in `panelOrder`.
    func testTheBoardPutsTheQueueImmediatelyAfterTheCourse() throws {
        let ids = CockpitView.boardPanelIDs
        let course = try XCTUnwrap(ids.firstIndex(of: CockpitView.coursePanelID))
        XCTAssertEqual(ids[course + 1], CockpitView.correctionsQueuePanelID)
    }

    /// A project crew's cockpit draws its own six panels, ending with the
    /// checkout's documents, and never the board's working documents.
    func testTheCockpitDrawsItsOwnSixPanels() {
        XCTAssertEqual(CockpitView.panelOrder, [
            CockpitView.dispatchedPanelID, "proposals", CockpitView.coursePanelID, "correctionsQueue",
            CockpitView.pullRequestsPanelID, CockpitView.checkoutPanelID,
        ])
        XCTAssertFalse(CockpitView.panelOrder.contains(CockpitView.documentsPanelID))
    }

    func testTheDocumentsIndexEntryCountsTheDocuments() {
        XCTAssertEqual(
            CockpitView.panelIndexCount(id: CockpitView.documentsPanelID, agentRuns: nil, proposalCount: 0,
                                        courseEntries: nil, queueTotal: nil, documentCount: 3),
            "3")
        XCTAssertNil(
            CockpitView.panelIndexCount(id: CockpitView.documentsPanelID, agentRuns: nil, proposalCount: 0,
                                        courseEntries: nil, queueTotal: nil))
    }
}
