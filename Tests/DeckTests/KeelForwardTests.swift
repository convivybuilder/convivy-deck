import XCTest
@testable import Deck

/// `KeelForward`: the ssh-held local-TCP-to-remote-unix-socket forward
/// `KeelConnection.forwardedPort` dials in production.
///
/// FIXTURE/ARGV TESTED ONLY — the ssh-forward hop stays untested live in
/// this environment for the same reason `KeelHTTPExchangeTests`'s own header
/// names for the socket-and-HTTP layer: the live-reachable path in this
/// sandbox is the direct `run-register-api` unix socket, not a working ssh
/// hop to a remote host. There is no live forward target this sandbox can
/// reach, so this file exercises only the PURE, no-process, no-socket argv
/// builders (`keelForwardArguments`, `sshCancelForwardArguments`) against
/// literal expected argv — proving the shape ssh actually receives without
/// needing a real `ssh -N` process or a real ControlMaster.
final class KeelForwardTests: XCTestCase {
    private let fixtureTarget = SSHTarget(user: "vivy", host: "fleet-mini")
    /// A home with no Deck key, so no `-i` is added and the argv asserted here is
    /// the same on any machine. Passed to every builder, so none reads the real `~/.ssh`.
    private let noDeckKeyHome = "/nonexistent/deck-test-home"

    /// Deliberately NOT `defaultControlPath()` — a test that happened to
    /// pass the production default could not tell "the argv builder uses
    /// whatever `controlPath` it's given" apart from "the argv builder
    /// silently always uses the production default", since both would
    /// produce the same string. This fixture path makes the two
    /// distinguishable.
    private let fixtureControlPath = "/tmp/keel-forward-test-control-path-fixture"

    private func lArgument(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let index = argv.firstIndex(of: "-L"), argv.indices.contains(index + 1) else {
            XCTFail("argv carries no -L flag: \(argv)", file: file, line: line)
            return ""
        }
        return argv[index + 1]
    }

    // MARK: - keelForwardArguments

    func testKeelForwardArgumentsCarryExitOnForwardFailure() throws {
        let argv = try keelForwardArguments(
            target: fixtureTarget, remoteSocketPath: "~/.local/run/run-register-api.sock",
            localPort: 54321, controlPath: fixtureControlPath, home: noDeckKeyHome)
        XCTAssertTrue(argv.contains("ExitOnForwardFailure=yes"))
    }

    func testKeelForwardArgumentsLBindsLoopbackToTheExactRemoteSocketPath() throws {
        let argv = try keelForwardArguments(
            target: fixtureTarget, remoteSocketPath: "~/.local/run/run-register-api.sock",
            localPort: 54321, controlPath: fixtureControlPath, home: noDeckKeyHome)
        XCTAssertEqual(lArgument(argv), "127.0.0.1:54321:~/.local/run/run-register-api.sock")
    }

    func testKeelForwardArgumentsCarryTheControlPathTheyWereGiven() throws {
        let argv = try keelForwardArguments(
            target: fixtureTarget, remoteSocketPath: "~/.local/run/run-register-api.sock",
            localPort: 54321, controlPath: fixtureControlPath, home: noDeckKeyHome)
        XCTAssertNotEqual(fixtureControlPath, defaultControlPath(),
                           "the fixture must diverge from production or this test cannot tell "
                           + "\"uses the controlPath it was given\" apart from \"always uses the default\"")
        XCTAssertTrue(argv.contains("ControlPath=\(fixtureControlPath)"))
    }

    func testKeelForwardArgumentsRejectARemoteSocketPathContainingAColon() {
        XCTAssertThrowsError(try keelForwardArguments(
            target: fixtureTarget, remoteSocketPath: "~/.local/run/evil:socket.sock",
            localPort: 54321, controlPath: fixtureControlPath, home: noDeckKeyHome))
    }

    func testKeelForwardArgumentsRejectARemoteSocketPathContainingAPercent() {
        XCTAssertThrowsError(try keelForwardArguments(
            target: fixtureTarget, remoteSocketPath: "~/.local/run/%h.sock",
            localPort: 54321, controlPath: fixtureControlPath, home: noDeckKeyHome))
    }

    // MARK: - sshCancelForwardArguments

    /// `KeelForward.stop()`'s mechanism (see its own doc for why): cancels
    /// this forward's `-L` mapping on the shared control socket without
    /// touching whichever process actually holds it.
    func testSSHCancelForwardArgumentsCarryTheCancelVerb() throws {
        let argv = try sshCancelForwardArguments(
            target: fixtureTarget, remoteSocketPath: "~/.local/run/run-register-api.sock",
            localPort: 54321, controlPath: fixtureControlPath,
            home: noDeckKeyHome)
        XCTAssertEqual(argv.first, "-O")
        XCTAssertTrue(argv.contains("cancel"))
    }

    func testSSHCancelForwardArgumentsCarryTheSameLSpecAsTheForwardTheyCancel() throws {
        let forwardArgv = try keelForwardArguments(
            target: fixtureTarget, remoteSocketPath: "~/.local/run/run-register-api.sock",
            localPort: 54321, controlPath: fixtureControlPath, home: noDeckKeyHome)
        let cancelArgv = try sshCancelForwardArguments(
            target: fixtureTarget, remoteSocketPath: "~/.local/run/run-register-api.sock",
            localPort: 54321, controlPath: fixtureControlPath, home: noDeckKeyHome)
        XCTAssertEqual(lArgument(forwardArgv), lArgument(cancelArgv))
    }

    func testSSHCancelForwardArgumentsCarryTheControlPathTheyWereGiven() throws {
        let argv = try sshCancelForwardArguments(
            target: fixtureTarget, remoteSocketPath: "~/.local/run/run-register-api.sock",
            localPort: 54321, controlPath: fixtureControlPath, home: noDeckKeyHome)
        XCTAssertTrue(argv.contains("ControlPath=\(fixtureControlPath)"))
    }

    func testSSHCancelForwardArgumentsRejectARemoteSocketPathContainingAColon() {
        XCTAssertThrowsError(try sshCancelForwardArguments(
            target: fixtureTarget, remoteSocketPath: "~/.local/run/evil:socket.sock",
            localPort: 54321, controlPath: fixtureControlPath, home: noDeckKeyHome))
    }

    func testSSHCancelForwardArgumentsRejectARemoteSocketPathContainingAPercent() {
        XCTAssertThrowsError(try sshCancelForwardArguments(
            target: fixtureTarget, remoteSocketPath: "~/.local/run/%h.sock",
            localPort: 54321, controlPath: fixtureControlPath, home: noDeckKeyHome))
    }
}
