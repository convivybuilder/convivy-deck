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

    /// E22/CQ·200: a reading that needs a setup step allows setup now, not
    /// only `.ready` — only the two readings with no evidence either way
    /// start nothing.
    func testEverySetupStepReadingAllowsSetupAndOnlyTheBlockingTwoDoNot() {
        let allowed: [PreInstallReading] = [.ready, .claudeSignedOut("x"), .claudeNotInstalled]
        let blocked: [PreInstallReading] = [.desktopLoggedOut, .couldNotCheck("x")]
        for reading in allowed {
            XCTAssertTrue(reading.allowsSetup, "\(reading)")
        }
        for reading in blocked {
            XCTAssertFalse(reading.allowsSetup, "\(reading)")
        }
    }

    /// The steps the setup pane runs, pinned per reading (E22's
    /// specification): `.ready` only needs Builder's installer,
    /// `.claudeSignedOut` adds the sign-in, and `.claudeNotInstalled` adds
    /// Claude Code's own install ahead of both. The two blocking readings
    /// start nothing.
    func testSetupStepsArePinnedPerReading() {
        XCTAssertEqual(PreInstallReading.ready.setupSteps, [.installBuilderServer])
        XCTAssertEqual(PreInstallReading.claudeSignedOut("x").setupSteps,
                       [.signIntoClaudeCode, .installBuilderServer])
        XCTAssertEqual(PreInstallReading.claudeNotInstalled.setupSteps,
                       [.installClaudeCode, .signIntoClaudeCode, .installBuilderServer])
        XCTAssertEqual(PreInstallReading.desktopLoggedOut.setupSteps, [])
        XCTAssertEqual(PreInstallReading.couldNotCheck("x").setupSteps, [])
    }

    /// A retry keeps no progress of its own, so it skips finished steps only
    /// because the next check reads the host as it now stands: from what the
    /// check sees after each stage of a partial setup through to the steps
    /// the retry runs.
    func testARetryAfterAPartialSetupStartsFromWhatTheCheckNowReads() {
        func stepsAfterCheck(exitStatus: Int32, errorText: String) -> [SetupStep] {
            PreInstallCheck.classifyClaude(exitStatus: exitStatus, errorText: errorText, timedOut: false).setupSteps
        }
        XCTAssertEqual(stepsAfterCheck(exitStatus: 127, errorText: "bash: claude: command not found"),
                       [.installClaudeCode, .signIntoClaudeCode, .installBuilderServer],
                       "the first step failed, so everything runs again")
        XCTAssertEqual(stepsAfterCheck(exitStatus: 1, errorText: "Not logged in · Please run /login"),
                       [.signIntoClaudeCode, .installBuilderServer],
                       "Claude Code installed, so the retry starts at the sign-in")
        XCTAssertEqual(stepsAfterCheck(exitStatus: 0, errorText: ""),
                       [.installBuilderServer],
                       "signed in, so the retry runs only Builder's installer")
    }

    /// Only the two readings that start nothing explain themselves to the
    /// person; a reading that starts a setup step is never told to install
    /// Claude Code or sign in by hand, because the pane does both.
    func testOnlyTheBlockingReadingsExplainThemselves() {
        let blocking: [PreInstallReading] = [.desktopLoggedOut, .couldNotCheck("ssh failed")]
        for reading in blocking {
            XCTAssertEqual(reading.explanation(hostName: "kestrel")?.contains("kestrel"), true, "\(reading)")
        }
        let setup: [PreInstallReading] = [.ready, .claudeSignedOut("Not logged in"), .claudeNotInstalled]
        for reading in setup {
            XCTAssertNil(reading.explanation(hostName: "kestrel"), "\(reading)")
        }
    }

    func testTheClaudeCommandRidesTheSharedConnectionAndIsFixed() throws {
        let argv = try PreInstallCheck.claudeArguments(
            target: SSHTarget(user: "builder", host: "kestrel"), controlPath: "/tmp/cm", home: "/nonexistent")
        XCTAssertTrue(argv.contains("ControlPath=/tmp/cm"))
        XCTAssertEqual(Array(argv.suffix(2)),
                       ["builder@kestrel",
                        #"exec "$SHELL" -lc 'export PATH="$HOME/.local/bin:$PATH"; "#
                            + #"claude -p ok --max-turns 1 --model haiku'"#])
    }

    /// A temporary home holding a fake signed-in `claude` in `folder`, and a
    /// way to run a command through a local `sh` as if over ssh from there.
    private func homeWithClaude(in folder: String, profile: String?) throws
        -> (home: URL, run: (String) throws -> (Int32, String)) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("preinstall-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("claude")
        try "#!/bin/sh\necho signed-in\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        if let profile {
            try profile.write(to: home.appendingPathComponent(".profile"), atomically: true, encoding: .utf8)
        }
        return (home, { command in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["HOME": home.path, "SHELL": "/bin/bash", "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (process.terminationStatus, text)
        })
    }

    /// `claude` in a folder only the login profile adds, so the login shell
    /// is what finds it. A bare `claude` fails there with 127, which the
    /// check read as "not installed" (live install check 2, 2026-10-20).
    func testTheCommandFindsAClaudeThatOnlyTheLoginProfilePutsOnPath() throws {
        let (home, run) = try homeWithClaude(in: "tools/bin", profile: "PATH=\"$HOME/tools/bin:$PATH\"\n")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(try run("claude -p ok").0, 127, "control: a bare claude is not on the non-login PATH")
        let (status, output) = try run(PreInstallCheck.claudeCommand)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output, "signed-in\n")
    }

    /// The shape measured on a fresh Mac account: `claude` in `~/.local/bin`
    /// and no profile adding that folder. The check must read it as present,
    /// or a retry installs Claude Code again.
    func testTheCommandFindsAClaudeInLocalBinThatNoProfileAdds() throws {
        let (home, run) = try homeWithClaude(in: ".local/bin", profile: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(try run(#"exec "$SHELL" -lc 'claude -p ok'"#).0, 127,
                       "control: the login shell alone does not find it")
        let (status, output) = try run(PreInstallCheck.claudeCommand)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output, "signed-in\n")
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
