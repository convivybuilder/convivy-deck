import XCTest
@testable import Deck

/// `HostsSettingsView.hostUserPlaceholder` — the User field's ghost text
/// derives from the machine's own account rather than shipping a real name
/// compiled into the binary, so it must fall back for the case
/// `NSUserName()` can actually return: an empty string.
final class HostPlaceholderTests: XCTestCase {
    func testFallsBackToDemouserWhenTheSystemUserIsEmpty() {
        XCTAssertEqual(HostsSettingsView.hostUserPlaceholder(systemUser: ""), "demouser")
    }

    func testUsesTheSystemUserWhenPresent() {
        XCTAssertEqual(HostsSettingsView.hostUserPlaceholder(systemUser: TestHost.user), TestHost.user)
    }

    func testTheAddressPlaceholderIsTheDocumentationReservedRange() {
        // RFC 5737 TEST-NET-1 — reserved so it can never resolve to a real,
        // reachable machine, unlike the Tailscale address this replaced.
        XCTAssertEqual(HostsSettingsView.hostAddressPlaceholder, "192.0.2.1")
    }

    func testTheNamePlaceholderIsNotARealPersonsName() {
        XCTAssertEqual(HostsSettingsView.hostNamePlaceholder, "studio")
    }
}
