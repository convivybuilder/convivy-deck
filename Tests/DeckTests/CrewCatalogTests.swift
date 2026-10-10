import XCTest
@testable import Deck

/// `deck/specs/running-deck-as-someone-else` §"The defaults name Convivy":
/// `CrewCatalog.known` no longer carries Convivy's own org chart, so an
/// unconfigured install's rail is empty rather than nine hardcoded rows.
final class CrewCatalogTests: XCTestCase {
    func testTheCatalogIsEmpty() {
        XCTAssertTrue(CrewCatalog.known.isEmpty,
            "the shipped org chart was removed; a fresh install's rail fallback has nothing in it")
    }

    /// The real assertion, at the layer the rail actually draws from —
    /// `SessionRoster.init(configuration:)` is what `ContentView.crews` and
    /// `HostsSettingsView.rail` both fall back to, so pinning it here (rather
    /// than only restating `CrewCatalog.known.isEmpty` above) is what would
    /// catch a call site that grew its own hardcoded fallback instead of
    /// using the catalog.
    func testAnUnconfiguredConfigurationYieldsAnEmptyRail() {
        let roster = SessionRoster(configuration: .empty)
        XCTAssertEqual(roster.pinnedCount, 0)
        XCTAssertTrue(roster.entries.filter(\.isPinned).isEmpty)
    }
}
