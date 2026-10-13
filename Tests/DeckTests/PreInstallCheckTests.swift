@testable import Deck
import XCTest

/// CQ·159: the pre-install check's classification, from the outputs
/// Shipwright recorded on Claude Code 2.1.283 (E22's thread, 2026-10-11).
final class PreInstallCheckTests: XCTestCase {
    func testExitZeroIsReady() {
        XCTAssertEqual(PreInstallCheck.classifyClaude(exitStatus: 0, errorText: "", timedOut: false), .ready)
    }

    func testSignedOutIsNotSignedInWithWhatClaudeSaid() {
        XCTAssertEqual(
            PreInstallCheck.classifyClaude(
                exitStatus: 1, errorText: "Not logged in · Please run /login\n", timedOut: false),
            .claudeSignedOut("Not logged in · Please run /login"))
    }

    /// The case `claude auth status` misses: a credential is present but
    /// dead. `claude -p` refuses it, and so does the check.
    func testAnExpiredSessionIsNotSignedIn() {
        let text = "Failed to authenticate: OAuth session expired and could not be refreshed"
        XCTAssertEqual(
            PreInstallCheck.classifyClaude(exitStatus: 1, errorText: text, timedOut: false),
            .claudeSignedOut(text))
    }

    func testAMissingClaudeIsNotInstalled() {
        XCTAssertEqual(
            PreInstallCheck.classifyClaude(exitStatus: 127, errorText: "bash: claude: command not found",
                                           timedOut: false),
            .claudeNotInstalled)
        XCTAssertEqual(
            PreInstallCheck.classifyClaude(exitStatus: 1, errorText: "zsh: command not found: claude",
                                           timedOut: false),
            .claudeNotInstalled)
    }

    /// Neither an ssh failure nor a timeout says anything about the sign-in.
    func testTransportFailureAndTimeoutCouldNotCheck() {
        XCTAssertEqual(
            PreInstallCheck.classifyClaude(
                exitStatus: 255, errorText: "ssh: connect to host x port 22: Connection refused", timedOut: false),
            .couldNotCheck("ssh: connect to host x port 22: Connection refused"))
        guard case .couldNotCheck = PreInstallCheck.classifyClaude(exitStatus: 15, errorText: "", timedOut: true)
        else { return XCTFail("a timeout must not read as signed out") }
    }

    /// Only a positive logged-out desktop reading blocks. A Linux host has
    /// no `launchctl`, which `DesktopSessionProbe` reads as `.unknown`, so
    /// the claude reading decides there.
    func testOnlyALoggedOutDesktopOverridesTheClaudeReading() {
        XCTAssertEqual(PreInstallCheck.combine(desktop: .loggedOut, claude: .ready), .desktopLoggedOut)
        XCTAssertEqual(PreInstallCheck.combine(desktop: .unknown, claude: .ready), .ready)
        XCTAssertEqual(PreInstallCheck.combine(desktop: .loggedIn, claude: .claudeNotInstalled),
                       .claudeNotInstalled)
    }

    func testOnlyReadyAllowsTheInstall() {
        let notReady: [PreInstallReading] = [
            .claudeNotInstalled, .claudeSignedOut("x"), .desktopLoggedOut, .couldNotCheck("x"),
        ]
        XCTAssertTrue(PreInstallReading.ready.allowsInstall)
        for reading in notReady {
            XCTAssertFalse(reading.allowsInstall, "\(reading)")
        }
    }

    func testEveryNotReadyReadingNamesTheHost() {
        let readings: [PreInstallReading] = [
            .claudeNotInstalled, .claudeSignedOut("Not logged in"), .desktopLoggedOut, .couldNotCheck("ssh failed"),
        ]
        for reading in readings {
            XCTAssertTrue(reading.explanation(hostName: "kestrel").contains("kestrel"), "\(reading)")
        }
    }

    func testTheClaudeCommandRidesTheSharedConnectionAndIsFixed() throws {
        let argv = try PreInstallCheck.claudeArguments(
            target: SSHTarget(user: "builder", host: "kestrel"), controlPath: "/tmp/cm", home: "/nonexistent")
        XCTAssertTrue(argv.contains("ControlPath=/tmp/cm"))
        XCTAssertEqual(Array(argv.suffix(8)),
                       ["builder@kestrel", "claude", "-p", "ok", "--max-turns", "1", "--model", "haiku"])
    }

    func testAHostileTargetIsRefusedBeforeAnyArgv() {
        XCTAssertThrowsError(try PreInstallCheck.claudeArguments(
            target: SSHTarget(user: "builder", host: "-oProxyCommand=x"), controlPath: "/tmp/cm"))
    }

    /// The sign-in check rides the shared ControlMaster too, so it counts
    /// against `SSHConnectionGate`'s cap like every other session.
    func testClaudeCheckArgvIsGatedOnTheSharedConnection() throws {
        let argv = try PreInstallCheck.claudeArguments(
            target: SSHTarget(user: "builder", host: "kestrel"), controlPath: "/tmp/cm", home: "/nonexistent")
        let key = try XCTUnwrap(SSHConnectionGate.Key.from(argv: argv))
        XCTAssertEqual(key.destination, "builder@kestrel")
    }
}
