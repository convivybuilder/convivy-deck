import XCTest
@testable import Deck

/// `issue_01M5MME44FPVHRQB4KDBXZA5YR`: a running, unpinned catalog entry —
/// a crew Deck already knows about — drew under "OTHER SESSIONS" with
/// "Promote to Crew…", meant for a tmux session Deck knows nothing about.
/// The fix reinstates the catalog exclusion `otherSessions` once dropped
/// (`issue_01M1SV8QKJ7ADH87PCNC0Q0YE8`), now host-scoped, paired with
/// `START` no longer excluding a running entry — see `StartPickerTests`
/// and `RailStateModelRefreshTests`'s own coverage of the discovery side.
/// `SessionGroupingTests` already pins `SessionGrouping.ungrouped` itself,
/// which never filters by catalog; this file pins the filter `RailView`
/// layers on top of it.
final class RailStartSectionTests: XCTestCase {
    private func crew(_ id: String, dir: String? = nil) -> Crew {
        Crew(id: id, displayName: id, workingDirectory: dir)
    }

    private let hosts = [HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)]

    /// The issue's own shape: a catalog entry naming a running session on
    /// the same host is excluded, so "Promote to Crew…" never appears for
    /// a crew Deck already has.
    func testOtherSessionsExcludesARunningCatalogEntryOnTheSameHost() {
        let quarry = LaunchableSession(id: "quarry", displayName: "Quarry", host: "mini")
        let discovered = DiscoveredSession(name: "quarry", host: TestHost.target, path: "/x")
        let result = RailView.otherSessions(
            discoveredSessions: [discovered], crews: [], catalog: [quarry],
            hosts: hosts, defaultHost: "mini")
        XCTAssertTrue(result.isEmpty)
    }

    /// Host-scoped, the same way the pin exclusion `SessionGrouping.ungrouped`
    /// already applies is: a catalog entry on one host must never hide an
    /// unrelated, same-named session discovered on a DIFFERENT host.
    func testOtherSessionsIncludesASessionACatalogEntryNamesOnADifferentHost() {
        let secondaryHosts = hosts + [
            HostEntry(name: "annex", user: TestHost.secondaryUser, address: TestHost.secondaryAddress),
        ]
        let quarry = LaunchableSession(id: "quarry", displayName: "Quarry", host: "mini")
        let discovered = DiscoveredSession(name: "quarry", host: TestHost.secondaryTarget, path: "/x")
        let result = RailView.otherSessions(
            discoveredSessions: [discovered], crews: [], catalog: [quarry],
            hosts: secondaryHosts, defaultHost: "mini")
        XCTAssertEqual(result.map(\.name), ["quarry"])
    }

    /// A tmux session no catalog entry and no crew names is the case the
    /// section still exists for — unaffected by either exclusion.
    func testOtherSessionsStillIncludesAnUnknownTmuxSession() {
        let discovered = DiscoveredSession(name: "steward", host: TestHost.target, path: "/x")
        let result = RailView.otherSessions(
            discoveredSessions: [discovered], crews: [], hosts: [], defaultHost: nil)
        XCTAssertEqual(result.map(\.name), ["steward"])
    }

    /// A crew still wins the grouping rules it always did — this fix only
    /// adds a CATALOG exclusion, not a replacement for the crew one
    /// `SessionGrouping` already applies.
    func testOtherSessionsStillExcludesASessionACrewOwns() {
        let ask = crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")
        let discovered = DiscoveredSession(name: "ask--research", host: TestHost.target, path: "/x")
        let result = RailView.otherSessions(
            discoveredSessions: [discovered], crews: [ask], hosts: hosts, defaultHost: "mini")
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
