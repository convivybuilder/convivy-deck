import XCTest
@testable import Deck

/// `issue_01M1SV8QKJ7ADH87PCNC0Q0YE8`'s one non-optional correctness fix,
/// pinned at the layer that used to hide it: `RailView.otherSessions` used
/// to also drop any discovered session whose name matched a catalog id, so
/// a launched-but-unpinned catalog entry drew nowhere selectable — filtered
/// out here, and still drawn as an ordinary "not running" row under
/// `START`. `SessionGroupingTests` already pins `SessionGrouping.ungrouped`
/// itself, which never filtered by catalog; this file pins that `RailView`
/// no longer adds a filter of its own on top of it.
final class RailStartSectionTests: XCTestCase {
    private func crew(_ id: String, dir: String? = nil) -> Crew {
        Crew(id: id, displayName: id, workingDirectory: dir)
    }

    /// The regression shape directly: a discovered session sharing a name
    /// with what used to be a catalog id, matching no crew, is included —
    /// where the deleted filter used to drop it.
    func testOtherSessionsIncludesADiscoveredSessionSharingANameWithACatalogEntry() {
        let discovered = DiscoveredSession(name: "hollis", host: TestHost.target, path: "/x")
        let result = RailView.otherSessions(
            discoveredSessions: [discovered], crews: [], hosts: [], defaultHost: nil)
        XCTAssertEqual(result.map(\.name), ["hollis"])
    }

    /// A crew still wins the grouping rules it always did — this fix only
    /// removed the CATALOG exclusion, not the crew one `SessionGrouping`
    /// already applies.
    func testOtherSessionsStillExcludesASessionACrewOwns() {
        let ask = crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")
        let discovered = DiscoveredSession(name: "ask--research", host: TestHost.target, path: "/x")
        let result = RailView.otherSessions(
            discoveredSessions: [discovered], crews: [ask],
            hosts: [HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)],
            defaultHost: "mini")
        XCTAssertTrue(result.isEmpty)
    }

    func testOtherSessionsSortsAlphabetically() {
        let sessions = [
            DiscoveredSession(name: "zeta", host: TestHost.target, path: "/x"),
            DiscoveredSession(name: "alpha", host: TestHost.target, path: "/x"),
        ]
        let result = RailView.otherSessions(
            discoveredSessions: sessions, crews: [], hosts: [], defaultHost: nil)
        XCTAssertEqual(result.map(\.name), ["alpha", "zeta"])
    }
}
