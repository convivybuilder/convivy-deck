import XCTest
@testable import Deck

final class HostUsageTests: XCTestCase {
    func testCountsZeroWhenNoRowNamesTheHost() {
        let rail = [Crew(id: "ask", displayName: "Ask")]
        XCTAssertEqual(HostUsage.crewsNaming("guest", rail: rail, catalog: []), 0)
    }

    func testCountsRailRowsNamingTheHost() {
        let rail = [
            Crew(id: "ask", displayName: "Ask", host: "guest"),
            Crew(id: "orchard", displayName: "Orchard", host: "guest"),
            Crew(id: "deck", displayName: "Deck"),
        ]
        XCTAssertEqual(HostUsage.crewsNaming("guest", rail: rail, catalog: []), 2)
    }

    func testCountsCatalogRowsNamingTheHostToo() {
        let rail = [Crew(id: "ask", displayName: "Ask", host: "guest")]
        let catalog = [LaunchableSession(id: "lakeside", displayName: "Lakeside Studio", host: "guest")]
        XCTAssertEqual(HostUsage.crewsNaming("guest", rail: rail, catalog: catalog), 2)
    }
}
