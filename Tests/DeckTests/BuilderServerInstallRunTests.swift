@testable import Deck
import XCTest

/// CQ·160/CQ·200: the setup pane's composed argv, and how a finished run
/// reads.
final class BuilderServerInstallRunTests: XCTestCase {
    /// `-t` for sudo's password prompt, its own ssh connection (CQ·165), the
    /// clicked host's `user@host`, then `.ready`'s one step — Builder's
    /// published installer — as one fixed remote command, with PATH set
    /// first and no step of Deck's own.
    func testTheArgvRunsThePublishedInstallerOnTheGivenHostOnly() throws {
        let argv = try BuilderServerInstall.setupArguments(
            target: SSHTarget(user: "builder", host: "kestrel"), steps: [.installBuilderServer],
            home: "/nonexistent")
        XCTAssertEqual(argv.first, "-t")
        XCTAssertTrue(argv.contains("ControlPath=none"))
        XCTAssertEqual(Array(argv.suffix(2)),
                       ["builder@kestrel",
                        #"exec "$SHELL" -lc 'set -o pipefail; export PATH="$HOME/.local/bin:$PATH"; "#
                            + #"curl -fsSL https://convivybuilder.org/install.sh | sh'"#])
        XCTAssertEqual(argv.filter { $0.contains("@") }, ["builder@kestrel"])
    }

    /// The three readings that start a setup step each compose their own
    /// fixed chain — Shipwright's installer, `claude auth login`, and
    /// Anthropic's installer — only the steps they need, in order.
    func testTheComposedArgvMatchesEachReadingsSteps() throws {
        func remoteCommand(_ steps: [SetupStep]) throws -> String {
            let argv = try BuilderServerInstall.setupArguments(
                target: SSHTarget(user: "builder", host: "kestrel"), steps: steps, home: "/nonexistent")
            return argv.last!
        }
        XCTAssertEqual(try remoteCommand(PreInstallReading.ready.setupSteps),
                        #"exec "$SHELL" -lc 'set -o pipefail; export PATH="$HOME/.local/bin:$PATH"; "#
                            + #"curl -fsSL https://convivybuilder.org/install.sh | sh'"#)
        XCTAssertEqual(try remoteCommand(PreInstallReading.claudeSignedOut("x").setupSteps),
                        #"exec "$SHELL" -lc 'set -o pipefail; export PATH="$HOME/.local/bin:$PATH"; "#
                            + #"claude auth login && curl -fsSL https://convivybuilder.org/install.sh | sh'"#)
        XCTAssertEqual(try remoteCommand(PreInstallReading.claudeNotInstalled.setupSteps),
                        #"exec "$SHELL" -lc 'set -o pipefail; export PATH="$HOME/.local/bin:$PATH"; "#
                            + #"curl -fsSL https://claude.ai/install.sh | bash && claude auth login "#
                            + #"&& curl -fsSL https://convivybuilder.org/install.sh | sh'"#)
    }

    /// A failed download must stop the chain with its own status, under both
    /// shells a host's login shell is likely to be. `false | cat` stands in
    /// for `curl | shell`: without `pipefail` its status is `cat`'s 0, so the
    /// next step runs and the pane exits 0. The passing chain is the control
    /// that the marker can appear at all.
    func testAFailedPipeStopsTheChainWithItsOwnStatus() throws {
        func run(_ shell: String, _ commands: [String]) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", BuilderServerInstall.chain(commands: commands)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        for shell in ["/bin/bash", "/bin/zsh"] {
            let failed = try run(shell, ["(exit 7) | cat", "echo NEXT-STEP-RAN"])
            XCTAssertEqual(failed.status, 7, shell)
            XCTAssertFalse(failed.output.contains("NEXT-STEP-RAN"), shell)
            let passed = try run(shell, ["true | cat", "echo NEXT-STEP-RAN"])
            XCTAssertEqual(passed.status, 0, shell)
            XCTAssertTrue(passed.output.contains("NEXT-STEP-RAN"), shell)
        }
    }

    /// Only the validated `user@host` varies across hosts; the rest of the
    /// argv, and the composed remote command, stays fixed.
    func testOnlyTheHostVariesAcrossReadings() throws {
        let steps = PreInstallReading.claudeNotInstalled.setupSteps
        let first = try BuilderServerInstall.setupArguments(
            target: SSHTarget(user: "builder", host: "kestrel"), steps: steps, home: "/nonexistent")
        let second = try BuilderServerInstall.setupArguments(
            target: SSHTarget(user: "builder", host: "falcon"), steps: steps, home: "/nonexistent")
        XCTAssertEqual(first.count, second.count)
        let destinationIndex = first.count - 2
        XCTAssertEqual(first.last, second.last, "the remote command is fixed text")
        XCTAssertEqual(first[destinationIndex], "builder@kestrel")
        XCTAssertEqual(second[destinationIndex], "builder@falcon")
        XCTAssertEqual(first.enumerated().filter { $0.offset != destinationIndex }.map(\.element),
                        second.enumerated().filter { $0.offset != destinationIndex }.map(\.element))
    }

    /// CQ·165: the setup pane is a `-t` pane too, so a stalled terminal must
    /// not be able to freeze every other ssh call on the host.
    func testTheArgvNeverJoinsTheSharedMaster() throws {
        let argv = try BuilderServerInstall.setupArguments(
            target: SSHTarget(user: "builder", host: "kestrel"), steps: [.installBuilderServer],
            home: "/nonexistent")
        XCTAssertFalse(argv.contains { $0.hasPrefix("ControlMaster=") })
        XCTAssertFalse(argv.contains { $0.hasPrefix("ControlPersist=") })
    }

    // MARK: - CQ·202: forwarding Builder's GitHub App page port

    /// Each reading that starts a setup step ends with `.installBuilderServer`,
    /// so a requested port is forwarded for every one of them: the argv
    /// carries `-L <port>:127.0.0.1:<port>` and `ExitOnForwardFailure=yes`,
    /// and the installer step's own text gets Shipwright's flag appended.
    func testThePortIsForwardedForEveryReadingThatInstalls() throws {
        let readings: [PreInstallReading] = [.ready, .claudeSignedOut("x"), .claudeNotInstalled]
        for reading in readings {
            let argv = try BuilderServerInstall.setupArguments(
                target: SSHTarget(user: "builder", host: "kestrel"), steps: reading.setupSteps,
                githubAppPort: 54213, home: "/nonexistent")
            XCTAssertTrue(argv.contains("-L"), "\(reading)")
            XCTAssertTrue(argv.contains("54213:127.0.0.1:54213"), "\(reading)")
            XCTAssertTrue(argv.contains("ExitOnForwardFailure=yes"), "\(reading)")
            XCTAssertTrue(argv.last!.contains("-s -- --github-app-port 54213"), "\(reading)")
            XCTAssertTrue(argv.last!.hasSuffix("--github-app-port 54213'"), "\(reading)")
        }
    }

    /// Steps that never reach `.installBuilderServer` get no forward and no
    /// flag at all — the guard this item's spec calls out by name, even
    /// though no real `PreInstallReading` produces this combination today.
    func testNoPortIsForwardedWhenInstallBuilderServerIsNotAStep() throws {
        let argv = try BuilderServerInstall.setupArguments(
            target: SSHTarget(user: "builder", host: "kestrel"), steps: [.installClaudeCode],
            githubAppPort: 54213, home: "/nonexistent")
        XCTAssertFalse(argv.contains("-L"))
        XCTAssertFalse(argv.contains { $0.contains("ExitOnForwardFailure") })
        XCTAssertFalse(argv.last!.contains("--github-app-port"))
    }

    /// No `githubAppPort` at all (the default, and what every existing test
    /// above passes) leaves the argv exactly as it was before this
    /// parameter existed.
    func testNoPortRequestedAddsNothing() throws {
        let argv = try BuilderServerInstall.setupArguments(
            target: SSHTarget(user: "builder", host: "kestrel"), steps: [.installBuilderServer],
            home: "/nonexistent")
        XCTAssertFalse(argv.contains("-L"))
        XCTAssertFalse(argv.contains { $0.contains("ExitOnForwardFailure") })
        XCTAssertFalse(argv.last!.contains("--github-app-port"))
    }

    /// The port is the only varying part two otherwise-identical setups can
    /// differ by: the `-L` field and the appended flag change, nothing else.
    func testThePortIsTheOnlyVaryingPartOfTheArgv() throws {
        let steps = PreInstallReading.ready.setupSteps
        let first = try BuilderServerInstall.setupArguments(
            target: SSHTarget(user: "builder", host: "kestrel"), steps: steps,
            githubAppPort: 11111, home: "/nonexistent")
        let second = try BuilderServerInstall.setupArguments(
            target: SSHTarget(user: "builder", host: "kestrel"), steps: steps,
            githubAppPort: 22222, home: "/nonexistent")
        XCTAssertEqual(first.count, second.count)
        XCTAssertFalse(first.elementsEqual(second), "two different ports must produce different argv")
        for (left, right) in zip(first, second) {
            XCTAssertEqual(left.replacingOccurrences(of: "11111", with: "N"),
                            right.replacingOccurrences(of: "22222", with: "N"), "\(left) vs \(right)")
        }
    }

    func testAHostileTargetGetsNoArgv() {
        XCTAssertThrowsError(try BuilderServerInstall.setupArguments(
            target: SSHTarget(user: "builder", host: "-oProxyCommand=touch /tmp/x"), steps: [.installBuilderServer]))
        XCTAssertThrowsError(try BuilderServerInstall.setupArguments(
            target: SSHTarget(user: "-l root", host: "kestrel"), steps: [.installBuilderServer]))
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

    /// A port forwarded for Builder's GitHub App step means the install
    /// finished line also says the App exists and where to install it.
    func testAnInstalledOutcomeWithAForwardedPortNamesTheGithubApp() {
        let withPort = BuilderServerInstallSheet.statusLine(
            for: .installed, hostName: "kestrel", githubAppPort: 54213)
        XCTAssertTrue(withPort.contains("GitHub App"))
        XCTAssertTrue(withPort.contains("kestrel"))
        let withoutPort = BuilderServerInstallSheet.statusLine(for: .installed, hostName: "kestrel")
        XCTAssertFalse(withoutPort.contains("GitHub App"))
    }

    /// E22: before the GitHub App step runs, the running line already says
    /// what the App is for and that the person clicks Create on GitHub's
    /// page; a setup without Builder's installer never mentions the App.
    func testTheRunningLineExplainsTheGithubAppBeforeItsStep() {
        let before = BuilderServerInstallSheet.runningStatusLine(
            hostName: "kestrel", createsGithubApp: true, sawGithubAppOpenLine: false)
        XCTAssertTrue(before.contains("sign-in link"))
        XCTAssertTrue(before.contains("GitHub App"))
        XCTAssertTrue(before.contains("open pull requests"))
        XCTAssertTrue(before.contains("click Create"))
        let noApp = BuilderServerInstallSheet.runningStatusLine(
            hostName: "kestrel", createsGithubApp: false, sawGithubAppOpenLine: false)
        XCTAssertTrue(noApp.contains("sign-in link"))
        XCTAssertFalse(noApp.contains("GitHub App"))
    }

    /// Once the pane prints the App page's Open line, the running line says
    /// the page is in the browser and nothing needs pasting, despite the
    /// pane's own "the redirect will fail" message.
    func testTheRunningLineAfterTheOpenLineSaysNothingNeedsPasting() {
        let during = BuilderServerInstallSheet.runningStatusLine(
            hostName: "kestrel", createsGithubApp: true, sawGithubAppOpenLine: true)
        XCTAssertTrue(during.contains("GitHub App"))
        XCTAssertTrue(during.contains("click Create"))
        XCTAssertTrue(during.contains("nothing needs pasting"))
        XCTAssertTrue(during.contains("kestrel"))
        XCTAssertFalse(during.contains("sign-in link"))
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
