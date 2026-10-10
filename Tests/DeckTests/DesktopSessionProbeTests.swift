import XCTest
@testable import Deck

/// `DesktopSessionProbe.classify` — the pure mapping from a failed probe's
/// exit status and stderr text to a reading. The logged-out fixture below
/// (`shipwrightLoggedOutExitStatus`/`shipwrightLoggedOutStderr`) is the live
/// sample Shipwright recorded 2026-10-02 on macmini (uid 504, no console
/// session, over non-interactive ssh), returned identically four times by
/// `launchctl bootstrap gui/504` in that state — see CQ·124's PR body.
final class DesktopSessionProbeTests: XCTestCase {
    /// Shipwright, 2026-10-02, macmini macOS 26.4, builder-rehearsal uid 504,
    /// `who` showing no console line for that account:
    /// `launchctl print gui/$(id -u); echo "exit=$?"` over ssh.
    static let shipwrightLoggedOutExitStatus: Int32 = 125
    static let shipwrightLoggedOutStderr = "Could not print domain: 125: Domain does not support specified action"

    func testTheShipwrightLoggedOutSampleClassifiesAsLoggedOut() {
        XCTAssertEqual(
            DesktopSessionProbe.classify(
                exitStatus: Self.shipwrightLoggedOutExitStatus,
                errorText: Self.shipwrightLoggedOutStderr),
            .loggedOut)
    }

    /// Text alone, without the matching exit status, is not enough —
    /// `classify` requires both, because a cross-user probe used to answer
    /// this same text (see `testADifferentDomainErrorNowClassifiesAsLoggedOut`
    /// for why that ambiguity doesn't reach production).
    func testThePhraseWithoutTheMatchingExitStatusClassifiesAsUnknown() {
        XCTAssertEqual(
            DesktopSessionProbe.classify(exitStatus: 1, errorText: Self.shipwrightLoggedOutStderr),
            .unknown)
    }

    func testTheDocumentedLoggedOutPhraseClassifiesAsLoggedOut() {
        XCTAssertEqual(
            DesktopSessionProbe.classify(exitStatus: 1, errorText: "Could not find domain for pid 1"),
            .loggedOut)
    }

    func testThePhraseIsMatchedCaseInsensitively() {
        XCTAssertEqual(
            DesktopSessionProbe.classify(exitStatus: 1, errorText: "COULD NOT FIND DOMAIN FOR pid 1"),
            .loggedOut)
    }

    /// This exact text+status pair used to be read as a cross-user probe's
    /// distinct error, kept apart from logged-out. Shipwright's sample
    /// above shows the identical shape IS the logged-out answer, and Deck
    /// always probes as the target account itself — it never asks for a
    /// different account's domain — so there is no real cross-user call
    /// site left for this classification to get wrong.
    func testADifferentDomainErrorNowClassifiesAsLoggedOut() {
        XCTAssertEqual(
            DesktopSessionProbe.classify(
                exitStatus: 125,
                errorText: "Could not print domain: 125: Domain does not support specified action"),
            .loggedOut)
    }

    func testATimeoutClassifiesAsUnknown() {
        XCTAssertEqual(
            DesktopSessionProbe.classify(
                exitStatus: 1,
                errorText: "ssh did not respond within 20s — the connection may be wedged"),
            .unknown)
    }

    func testAConnectionRefusedClassifiesAsUnknown() {
        XCTAssertEqual(
            DesktopSessionProbe.classify(
                exitStatus: 255,
                errorText: "ssh: connect to host 10.0.0.5 port 22: Connection refused"),
            .unknown)
    }

    func testUnexpectedTextClassifiesAsUnknown() {
        XCTAssertEqual(
            DesktopSessionProbe.classify(exitStatus: 1, errorText: "something else entirely"), .unknown)
    }

    func testEmptyTextClassifiesAsUnknown() {
        XCTAssertEqual(DesktopSessionProbe.classify(exitStatus: 1, errorText: ""), .unknown)
    }

    // MARK: - argv

    func testArgumentsCarryTheLiteralSubshellExpressionUnexpanded() throws {
        let argv = try DesktopSessionProbe.arguments(
            target: SSHTarget(user: "operator", host: "macstudio"), controlPath: "/tmp/cm-%C")
        XCTAssertEqual(argv.suffix(4), ["operator@macstudio", "launchctl", "print", "gui/$(id -u)"])
    }

    func testArgumentsRejectAHostUserStartingWithADash() {
        XCTAssertThrowsError(
            try DesktopSessionProbe.arguments(target: SSHTarget(user: "-oProxyCommand=x", host: "macstudio")))
    }
}
