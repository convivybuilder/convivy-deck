import XCTest
@testable import Deck

/// `ContentView.runbookOpenAction` — what the "Open Runbook" action on a
/// logged-out alert should do (CQ·124), pinned without a window or a live
/// alert.
final class RunbookOpenActionTests: XCTestCase {
    private let host = HostEntry(name: "macmini", user: "builder-rehearsal", address: "10.0.0.9")

    func testNoLinkSelectsTheHostInSettings() {
        XCTAssertEqual(
            ContentView.runbookOpenAction(hostName: "macmini", rawLink: nil, hosts: [host]),
            .selectHostInSettings("macmini"))
    }

    func testAnEmptyLinkSelectsTheHostInSettings() {
        XCTAssertEqual(
            ContentView.runbookOpenAction(hostName: "macmini", rawLink: "", hosts: [host]),
            .selectHostInSettings("macmini"))
    }

    func testAnHttpsLinkOpensTheURL() {
        XCTAssertEqual(
            ContentView.runbookOpenAction(
                hostName: "macmini", rawLink: "https://example.com/runbook", hosts: [host]),
            .openURL(URL(string: "https://example.com/runbook")!))
    }

    func testAKBIdOpensItInTheHostsOwnTarget() {
        XCTAssertEqual(
            ContentView.runbookOpenAction(
                hostName: "macmini", rawLink: "shipwright/runbooks/log-back-in", hosts: [host]),
            .openKB(id: "shipwright/runbooks/log-back-in",
                    target: SSHTarget(user: "builder-rehearsal", host: "10.0.0.9")))
    }

    /// The host named in the click no longer exists in the live table —
    /// removed from Settings since the alert was raised. A KB id
    /// has no target to open against, so this falls back to selecting
    /// whatever Settings can still show for the name.
    func testAKBIdWithNoMatchingHostFallsBackToSelectingInSettings() {
        XCTAssertEqual(
            ContentView.runbookOpenAction(
                hostName: "macmini", rawLink: "shipwright/runbooks/log-back-in", hosts: []),
            .selectHostInSettings("macmini"))
    }

    /// A link that was once valid but no longer parses — refuse rather
    /// than guess; this must never reach `NSWorkspace` with an untrusted
    /// scheme.
    func testAnUnrecognisedSchemeFallsBackToSelectingInSettings() {
        XCTAssertEqual(
            ContentView.runbookOpenAction(
                hostName: "macmini", rawLink: "javascript:alert(1)", hosts: [host]),
            .selectHostInSettings("macmini"))
    }
}
