import XCTest
@testable import Deck

final class TerminalTargetTests: XCTestCase {
    // MARK: - Identity

    /// The local shell's reserved key must be something no tmux session can
    /// be, because the rail carries both in one `SessionRef` selection.
    /// `validateTmuxSessionName` rejects the colon, so the reserved key is
    /// unreachable as a session name. `TerminalTarget` used to carry its own
    /// mirrored `id`/`themeKey` computed properties, keyed on the bare
    /// session name for a `.remoteSession`/`.remoteShell` — removed as dead
    /// code once more than one host could exist, since a bare name is not a
    /// safe SwiftUI identity or theme key on its own once two crews can
    /// share a name on different hosts. `SessionRef.localShell.name` is now
    /// the sole source of this reserved key; see that property's doc.
    func testLocalShellKeyCannotCollideWithATmuxSession() {
        let key = SessionRef.localShell.name
        XCTAssertThrowsError(try validateTmuxSessionName(key),
                             "\(key) must not be a valid session name, or a session could shadow it")
    }

    // MARK: - Launch

    func testRemoteTargetLaunchesSSHWithTheSessionArguments() throws {
        let (executable, args) = try TerminalLaunch.executableAndArguments(
            for: .remoteSession(name: "deck", workingDirectory: nil, target: TestHost.target))
        XCTAssertEqual(executable, "/usr/bin/ssh")
        XCTAssertTrue(args.contains("-t"), "the remote PTY flag must survive this refactor")
        XCTAssertEqual(args.suffix(6), ["tmux", "new-session", "-A", "-D", "-s", "deck"])
    }

    /// A resolved host reaches the ssh argv for both a fleet session's
    /// terminal attach and its scratch shell — the two sites phase 6a
    /// threads `target` through beside `SessionAgent`'s verbs.
    func testARemoteSessionsResolvedTargetReachesArgv() throws {
        let target = SSHTarget(user: "operator", host: "10.0.0.5")
        let (_, args) = try TerminalLaunch.executableAndArguments(
            for: .remoteSession(name: "vivy", workingDirectory: nil, target: target))
        XCTAssertTrue(args.contains("operator@10.0.0.5"))
    }

    func testARemoteShellsResolvedTargetReachesArgv() throws {
        let target = SSHTarget(user: "operator", host: "10.0.0.5")
        let (_, args) = try TerminalLaunch.executableAndArguments(
            for: .remoteShell(session: "vivy", workingDirectory: nil, target: target))
        XCTAssertTrue(args.contains("operator@10.0.0.5"))
    }

    func testRemoteTargetRejectsAnInvalidSessionName() {
        XCTAssertThrowsError(
            try TerminalLaunch.executableAndArguments(
                for: .remoteSession(name: "steward; rm -rf ~", workingDirectory: nil, target: TestHost.target)))
    }

    /// `-l` so the shell sources the user's profile. Without it a pane launched
    /// from Finder inherits launchd's environment and has none of the PATH,
    /// aliases or functions the same shell has in Terminal.app — which looks
    /// broken rather than merely different.
    func testLocalShellLaunchesALoginShell() throws {
        let (executable, args) = try TerminalLaunch.executableAndArguments(for: .localShell)
        XCTAssertEqual(args, ["-l"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable))
    }

    func testLocalShellPrefersTheUsersShell() {
        XCTAssertEqual(
            TerminalLaunch.resolvedShell(environment: ["SHELL": "/bin/bash"]), "/bin/bash")
    }

    /// A GUI app launched from Finder inherits launchd's environment, where
    /// SHELL can be absent; and a stale value can name something that no longer
    /// exists. Both must fall back rather than fail at spawn time.
    func testLocalShellFallsBackWhenShellIsMissingOrBogus() {
        XCTAssertEqual(TerminalLaunch.resolvedShell(environment: [:]),
                       TerminalLaunch.fallbackShell)
        XCTAssertEqual(
            TerminalLaunch.resolvedShell(environment: ["SHELL": "/nonexistent/shell"]),
            TerminalLaunch.fallbackShell)
    }

    func testLocalShellIgnoresANonExecutableShellValue() {
        // A directory exists but is not executable as a program.
        XCTAssertEqual(
            TerminalLaunch.resolvedShell(environment: ["SHELL": "/tmp"]),
            TerminalLaunch.fallbackShell)
    }

    // MARK: - Where the local shell reopens
    //
    // Closing the Local split captures the shell's cwd from the kernel
    // (`ProcessCwd`, tested separately against a real spawned process) and the
    // next one opens there. This layer decides whether the remembered path is
    // still worth using, so `directoryExists` is injected rather than the tests
    // creating and deleting real directories.

    /// The case the feature exists for: a directory was remembered, it is
    /// still there, and that is where the next shell opens.
    func testReopensInTheRememberedDirectory() {
        let directory = TerminalLaunch.localStartingDirectory(
            remembered: "\(TestHost.homeRoot)/Convivy",
            directoryExists: { $0 == "\(TestHost.homeRoot)/Convivy" })
        XCTAssertEqual(directory, "\(TestHost.homeRoot)/Convivy")
    }

    /// Nothing remembered yet — the first Local split ever opened, and on a
    /// fresh install the stored value is the empty string rather than a path.
    func testFallsBackToHomeWhenNothingIsRemembered() {
        XCTAssertEqual(
            TerminalLaunch.localStartingDirectory(
                remembered: nil,
                directoryExists: { _ in XCTFail("must not stat when nothing was remembered"); return false }),
            TerminalLaunch.localWorkingDirectory)
    }

    /// The remembered path is re-checked, not trusted. A worktree deleted
    /// between one Deck launch and the next would otherwise be handed to
    /// `startProcess`, which fails at spawn time with nothing on screen to
    /// explain why the terminal did not appear.
    func testFallsBackToHomeWhenTheRememberedDirectoryIsGone() {
        XCTAssertEqual(
            TerminalLaunch.localStartingDirectory(
                remembered: "\(TestHost.homeRoot)/Convivy/worktrees/deleted-since-last-launch",
                directoryExists: { _ in false }),
            TerminalLaunch.localWorkingDirectory)
    }

    /// A path that exists but is a FILE is not somewhere a shell can start.
    /// `directoryIsReachable` is the real predicate here rather than an
    /// injected one, because this is precisely the distinction it makes.
    func testFallsBackToHomeWhenTheRememberedPathIsAFile() {
        XCTAssertEqual(
            TerminalLaunch.localStartingDirectory(remembered: "/etc/hosts"),
            TerminalLaunch.localWorkingDirectory)
    }

    /// End-to-end against the real filesystem: a directory that genuinely
    /// exists survives the check and comes back unchanged.
    func testARealDirectorySurvivesTheCheck() {
        XCTAssertEqual(
            TerminalLaunch.localStartingDirectory(remembered: "/private/tmp"),
            "/private/tmp")
    }

    // MARK: - Configuration

    func testAnOldConfigsLocalTerminalKeyIsHarmless(){
        // The rail's Local Terminal row is gone — the split toggle above the
        // pane is the one way in, and two doors to the same shell was the
        // clutter. A theme.json written before that still carries the key; it
        // is simply not read, and must not cost the user the rest of the file.
        let config = ThemeConfiguration.parse(
            Data(#"{"showLocalTerminal":false,"appearance":"dark"}"#.utf8))
        XCTAssertEqual(config?.appearancePreference, .dark)
    }

    /// With nothing mapped, the laptop's shell is graphite. It is not one of the
    /// hashed crew themes, so no crew reads as the laptop and the laptop does
    /// not read as a crew.
    func testLocalShellDefaultsToGraphite() {
        let theme = ThemeConfiguration.empty.theme(forSession: .localShell)
        XCTAssertEqual(theme, ThemeCatalog.graphite)
        XCTAssertEqual(theme.name, "graphite")
    }

    /// Graphite is kept out of the catalog on purpose. `all` is what the hash
    /// indexes, so a graphite entry there would move every unthemed session's
    /// colour, and `named` is what a mapping resolves through.
    func testGraphiteStaysOutOfTheCatalog() {
        XCTAssertNil(ThemeCatalog.named("graphite"))
        XCTAssertEqual(ThemeCatalog.all.count, 10)
        XCTAssertFalse(ThemeCatalog.all.contains(ThemeCatalog.graphite))
    }

    /// A user's own mapping for `local:shell` beats the graphite default, the
    /// same as it does for any session.
    func testAnExplicitLocalShellMappingWinsOverGraphite() {
        let config = ThemeConfiguration.empty.settingTheme("teal", forSession: .localShell)
        XCTAssertEqual(config.theme(forSession: .localShell).name, "teal")
    }

    // MARK: - Exit behaviour
    //
    // The Coordinator is @MainActor and needs a live NSView, so the branch
    // itself is exercised in live verify. What is testable here is the
    // property the branch depends on: that the two targets are distinguishable
    // at the point the decision is made, and that a clean exit is
    // distinguishable from a crash.

    func testTargetsAreDistinguishableForExitHandling() {
        let local = TerminalTarget.localShell
        let remote = TerminalTarget.remoteSession(name: "deck", workingDirectory: nil, target: TestHost.target)

        // The `if case .localShell` branch in processTerminated relies on this.
        if case .localShell = local {} else { XCTFail("localShell must match its own case") }
        if case .localShell = remote { XCTFail("a remote session must not match localShell") }
    }

    // MARK: - Catalog

    /// `orient` had a rail row but no tmux session on the mini and never has,
    /// so the row could only ever fail to connect.
    func testCatalogDoesNotOfferOrient() {
        XCTAssertFalse(CrewCatalog.known.contains { $0.id == "orient" })
    }
}
