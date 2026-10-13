@testable import Deck
import XCTest

/// CQ·160: the installer's argv, and how a finished run reads.
final class BuilderServerInstallRunTests: XCTestCase {
    /// `-t` for sudo's password prompt, its own ssh connection (CQ·165), the
    /// clicked host's `user@host`, then the published installer as one
    /// fixed remote command, with no release pin and no step of Deck's own.
    func testTheArgvRunsThePublishedInstallerOnTheGivenHostOnly() throws {
        let argv = try BuilderServerInstall.arguments(
            target: SSHTarget(user: "builder", host: "kestrel"), home: "/nonexistent")
        XCTAssertEqual(argv.first, "-t")
        XCTAssertTrue(argv.contains("ControlPath=none"))
        XCTAssertEqual(Array(argv.suffix(2)),
                       ["builder@kestrel", "curl -fsSL https://convivybuilder.org/install.sh | sh"])
        XCTAssertFalse(argv.contains { $0.contains("--release") })
        XCTAssertEqual(argv.filter { $0.contains("@") }, ["builder@kestrel"])
    }

    /// CQ·165: the installer is a `-t` pane too, so a stalled installer
    /// terminal must not be able to freeze every other ssh call on the host.
    func testTheArgvNeverJoinsTheSharedMaster() throws {
        let argv = try BuilderServerInstall.arguments(
            target: SSHTarget(user: "builder", host: "kestrel"), home: "/nonexistent")
        XCTAssertFalse(argv.contains { $0.hasPrefix("ControlMaster=") })
        XCTAssertFalse(argv.contains { $0.hasPrefix("ControlPersist=") })
    }

    func testAHostileTargetGetsNoArgv() {
        XCTAssertThrowsError(try BuilderServerInstall.arguments(
            target: SSHTarget(user: "builder", host: "-oProxyCommand=touch /tmp/x")))
        XCTAssertThrowsError(try BuilderServerInstall.arguments(
            target: SSHTarget(user: "-l root", host: "kestrel")))
    }

    /// Success is the re-probe's call: `curl … | sh` exits 0 when the
    /// download fails, because `sh` was handed nothing to run.
    func testOnlyACleanExitWithTheServerAnsweringIsInstalled() {
        XCTAssertEqual(BuilderServerInstall.outcome(exitCode: 0, serverFound: true), .installed)
        XCTAssertEqual(BuilderServerInstall.outcome(exitCode: 0, serverFound: false), .exitedWithoutServer)
        XCTAssertEqual(BuilderServerInstall.outcome(exitCode: 1, serverFound: true), .failed(exitCode: 1))
        XCTAssertEqual(BuilderServerInstall.outcome(exitCode: 255, serverFound: false), .failed(exitCode: 255))
        XCTAssertEqual(BuilderServerInstall.outcome(exitCode: nil, serverFound: false), .failed(exitCode: nil))
    }

    func testAFailureNamesItsExitStatusAndTheWayBack() {
        let line = BuilderServerInstallSheet.statusLine(for: .failed(exitCode: 3), hostName: "kestrel")
        XCTAssertTrue(line.contains("exit status 3"))
        XCTAssertTrue(line.contains("did not retry"))
        XCTAssertTrue(line.contains("kestrel"))
    }

    func testEveryOutcomeNamesTheHost() {
        let outcomes: [BuilderServerInstall.Outcome] = [
            .installed, .exitedWithoutServer, .failed(exitCode: 1), .failed(exitCode: nil),
        ]
        for outcome in outcomes {
            XCTAssertTrue(
                BuilderServerInstallSheet.statusLine(for: outcome, hostName: "kestrel").contains("kestrel"),
                "\(outcome)")
        }
    }
}
