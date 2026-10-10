import XCTest
@testable import Deck

/// `HostsSettingsView.removeHostMessage` — the Hosts tab's remove confirm,
/// pinned the same way `RemoveCrewTests` pins `ContentView.removeCrewMessage`.
final class RemoveHostMessageTests: XCTestCase {
    func testZeroCrewsHasNoFallbackSentence() {
        let message = HostsSettingsView.removeHostMessage(crewCount: 0, fallbackLabel: "")
        XCTAssertEqual(message, "This removes the host from the list.")
        XCTAssertFalse(message.contains("fall back"))
    }

    func testOneCrewUsesSingularGrammarAndNamesTheFallback() {
        let message = HostsSettingsView.removeHostMessage(crewCount: 1, fallbackLabel: "\(TestHost.user)@mini")
        XCTAssertEqual(message,
            "This removes the host from the list. 1 crew names it and will fall back to \(TestHost.user)@mini.")
    }

    func testTwoCrewsUsesPluralGrammar() {
        let message = HostsSettingsView.removeHostMessage(crewCount: 2, fallbackLabel: "\(TestHost.user)@mini")
        XCTAssertEqual(message,
            "This removes the host from the list. 2 crews name it and will fall back to \(TestHost.user)@mini.")
    }
}
