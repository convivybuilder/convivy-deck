import XCTest
@testable import Deck

/// The promote confirm's copy — `ContentView.promoteSessionMessage`/
/// `promotionErrorMessage`, the pure halves of "Promote to Crew…". See
/// `deck/specs/multiple-sessions-per-project` §"An OTHER SESSIONS row can be
/// adopted into a crew but cannot BECOME one".
final class PromoteSessionMessageTests: XCTestCase {
    func testSuccessMessageNamesTheSessionAndSaysNothingRestarts() {
        let message = ContentView.promoteSessionMessage(name: "comptroller")
        XCTAssertTrue(message.contains("comptroller"), message)
        XCTAssertTrue(message.contains("not restarted"), message)
        XCTAssertTrue(message.contains("keeps running"), message)
        XCTAssertTrue(message.contains("nothing changes"), message)
    }

    /// A resolved host names it, in place of Convivy's own machine — see
    /// `deck/specs/running-deck-as-someone-else`.
    func testSuccessMessageNamesTheResolvedHostWhenOneIsGiven() {
        let message = ContentView.promoteSessionMessage(name: "comptroller", hostLabel: "mini")
        XCTAssertTrue(message.contains("nothing on mini changes"), message)
    }

    /// No configured host resolves: the location clause drops rather than
    /// naming a host that is not really there.
    func testSuccessMessageDropsTheLocationClauseWithNoHostLabel() {
        let message = ContentView.promoteSessionMessage(name: "comptroller", hostLabel: nil)
        XCTAssertTrue(message.contains("nothing changes."), message)
        XCTAssertFalse(message.contains("nothing on"), message)
    }

    func testCollisionErrorNamesTheId() {
        let message = ContentView.promotionErrorMessage(.collision("ask"))
        XCTAssertTrue(message.contains("ask"), message)
        XCTAssertTrue(message.contains("already exists"), message)
    }
}
