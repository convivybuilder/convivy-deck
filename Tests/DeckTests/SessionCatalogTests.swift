import XCTest
@testable import Deck

/// The catalog is the list of sessions Deck can start but does not pin to the
/// rail. The operator, 2026-07-23: "we have co's set up for NYH studio, write-better,
/// ask, etc. And no way to launch them from Deck. But we don't always need
/// every co in the rail."
final class SessionCatalogTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - Reading it

    func testACatalogIsParsedBesideTheRail() throws {
        let file = try write("""
        {"rail": [{"session": "deck"}],
         "catalog": [{"session": "nyh", "name": "NYH Studio", "workdir": "~/NYH"},
                     {"session": "write-better"}]}
        """)
        let loaded = ThemeConfiguration.load(from: file)

        XCTAssertEqual(loaded.railSessions?.map(\.id), ["deck"])
        XCTAssertEqual(loaded.catalog.map(\.id), ["nyh", "write-better"])
        XCTAssertEqual(loaded.catalog[0].displayName, "NYH Studio")
        XCTAssertEqual(loaded.catalog[0].workingDirectory, "~/NYH")
    }

    func testARailRowCarriesItsLaunchCommand() throws {
        // A rail row that wants something other than `Crew.defaultLaunchCommand`
        // says so, and the override survives the parse. The stored value is what
        // the row wrote; `launchCommand` is what a row without one resolves to.
        let file = try write("""
        {"rail": [{"session": "deck", "name": "Deck", "command": "co -r"},
                  {"session": "vivy"}]}
        """)
        let rail = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions)
        XCTAssertEqual(rail.first { $0.id == "deck" }?.command, "co -r")
        XCTAssertNil(rail.first { $0.id == "vivy" }?.command, "an unspecified command stays unspecified")
        XCTAssertEqual(rail.first { $0.id == "vivy" }?.launchCommand, "co -r",
                       "and resolves to the rail default rather than the mini's plain `co`")
    }

    func testABadRailCommandCostsTheRowItsCommandNotItsPlace() throws {
        // Same degradation the catalog and the workdir get: a typo falls back to
        // `Crew.defaultLaunchCommand` rather than unpinning the session.
        let file = try write("""
        {"rail": [{"session": "deck", "command": "co\\nrm -rf /"}]}
        """)
        let deck = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(deck.id, "deck")
        XCTAssertNil(deck.command)
    }

    /// A rail row that names no command must still name none after a save, so
    /// the default stays in the code. Baking `co -r` into the file would freeze
    /// today's default in every user's config and stop them following the next
    /// change to it — the same reason `railArray` is omitted when unconfigured.
    func testTheDefaultCommandIsNotWrittenIntoConfig() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        let rail = [Crew(id: "vivy", displayName: "Vivy"), Crew(id: "deck", displayName: "Deck")]
        config.railSessions = rail
        try config.save(to: file)

        let reloaded = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions)
        XCTAssertEqual(reloaded.count, rail.count)
        for row in reloaded {
            XCTAssertNil(row.command, "\(row.id) baked the default into the config file")
            XCTAssertEqual(row.launchCommand, "co -r", "\(row.id) lost the default across a round trip")
        }
    }

    func testARailCommandSurvivesSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "deck", displayName: "Deck",
                                       workingDirectory: nil, command: "co -r")]
        try config.save(to: file)
        XCTAssertEqual(ThemeConfiguration.load(from: file).railSessions?.first?.command, "co -r")
    }

    func testARowWithoutANameFallsBackToItsSessionName() throws {
        let file = try write(#"{"catalog": [{"session": "ask"}]}"#)
        XCTAssertEqual(ThemeConfiguration.load(from: file).catalog.first?.displayName, "ask")
    }

    func testAnAbsentCatalogIsEmptyRatherThanFatal() throws {
        let file = try write(#"{"sessions": {}}"#)
        XCTAssertTrue(ThemeConfiguration.load(from: file).catalog.isEmpty)
    }

    func testAnUnattachableSessionNameIsDropped() throws {
        // A launcher entry that fails the moment it is clicked is worse than an
        // absent one: it reads as the session being broken, not the config.
        let file = try write("""
        {"catalog": [{"session": "nyh; rm -rf /"}, {"session": "ok"}]}
        """)
        XCTAssertEqual(ThemeConfiguration.load(from: file).catalog.map(\.id), ["ok"])
    }

    func testABadDirectoryCostsTheRowItsDirectoryNotItsPlace() throws {
        let file = try write("""
        {"catalog": [{"session": "nyh", "workdir": "../escape"}]}
        """)
        let entry = try XCTUnwrap(ThemeConfiguration.load(from: file).catalog.first)
        XCTAssertEqual(entry.id, "nyh")
        XCTAssertNil(entry.workingDirectory)
    }

    func testABadCommandCostsTheRowItsOverrideNotItsPlace() throws {
        let file = try write("""
        {"catalog": [{"session": "nyh", "command": "co\\nrm -rf /"}]}
        """)
        let entry = try XCTUnwrap(ThemeConfiguration.load(from: file).catalog.first)
        XCTAssertEqual(entry.id, "nyh")
        XCTAssertNil(entry.command, "a bad override must fall back to the mini's default")
    }

    func testTheCatalogSurvivesSaveAndLoad() throws {
        let file = try write("{}")
        var configuration = ThemeConfiguration.empty
        configuration.catalog = [
            LaunchableSession(id: "nyh", displayName: "NYH Studio",
                              workingDirectory: "~/NYH", command: "co -r")
        ]
        try configuration.save(to: file)

        let reloaded = ThemeConfiguration.load(from: file).catalog
        XCTAssertEqual(reloaded, configuration.catalog)
    }

    // MARK: - What a command may be

    func testACommandIsBoundedByShapeNotAnAllowlist() {
        // Not an allowlist: the catalog exists so a row can say `co -r`.
        for allowed in ["co", "co -r", "co plan", "co --model kimi"] {
            XCTAssertEqual(ThemeConfiguration.validatedCommand(allowed), allowed, allowed)
        }
        for refused in ["", "   ", "co\nrm -rf /", "co\rx", "co\u{1b}[2J",
                        "co\u{2028}rm -rf /", "co\u{2029}x",
                        String(repeating: "x", count: 201)] {
            XCTAssertNil(ThemeConfiguration.validatedCommand(refused),
                         refused.debugDescription)
        }
    }

    // MARK: - What reaches the mini

    func testStartCarriesTheDirectoryOnArgvButNotTheCommand() throws {
        // The directory is metacharacter-free by validateWorkingDirectory, so
        // it is safe on argv. The command is not, so it goes on stdin — argv
        // carries only `--command -`.
        let argv = try SessionAgent.startArguments(
            target: TestHost.target, session: "nyh", directory: "~/NYH", hasCommand: true)

        XCTAssertTrue(argv.contains("start"))
        XCTAssertTrue(argv.contains("nyh"))
        XCTAssertEqual(argv[argv.firstIndex(of: "--dir")! + 1], "~/NYH")
        XCTAssertEqual(argv[argv.firstIndex(of: "--command")! + 1], "-",
                       "the command is read from stdin, never placed on argv")
    }

    func testAMultiWordCommandNeverAppearsInArgv() throws {
        // THE BUG BOTH REVIEWS FOUND. ssh joins trailing argv with spaces and the
        // remote shell resplits, so `co -r` on argv arrives as two tokens and
        // `co; curl evil` escapes into the ssh control shell. It goes on stdin.
        for command in ["co -r", "co --model kimi", "co; curl evil", "co && rm -rf /"] {
            let argv = try SessionAgent.startArguments(
                target: TestHost.target, session: "nyh", hasCommand: true)
            XCTAssertFalse(argv.contains(command), command)
            XCTAssertFalse(argv.contains { $0.contains(" ") },
                           "no argv element carries a space for \(command)")
        }
    }

    func testStartOmitsWhatTheRowDidNotSay() throws {
        let argv = try SessionAgent.startArguments(target: TestHost.target, session: "nyh")
        XCTAssertFalse(argv.contains("--dir"))
        XCTAssertFalse(argv.contains("--command"))
    }

    func testStartRejectsABadCommandBeforeSending() throws {
        // start() validates the command before it becomes stdin, so a bad row
        // fails at the call rather than being piped to the mini.
        XCTAssertThrowsError(try SessionAgent.start(target: TestHost.target, session: "nyh", command: "co\nrm -rf /"))
    }

    func testStartRefusesADirectoryThatEscapes() throws {
        XCTAssertThrowsError(try SessionAgent.startArguments(
            target: TestHost.target, session: "nyh", directory: "../../etc"))
    }

    func testACatalogEntryLaunchesWithItsDirectoryAndCommandChannel() throws {
        // The launcher hands a LaunchableSession to start(); its directory rides
        // argv and its command rides stdin. This is the argv half.
        let entry = LaunchableSession(id: "nyh", displayName: "NYH Studio",
                                      workingDirectory: "~/NYH", command: "co -r")
        let argv = try SessionAgent.startArguments(
            target: TestHost.target, session: entry.id, directory: entry.workingDirectory,
            hasCommand: entry.command != nil)

        XCTAssertEqual(argv[argv.firstIndex(of: "--dir")! + 1], "~/NYH")
        XCTAssertEqual(argv[argv.firstIndex(of: "--command")! + 1], "-")
        XCTAssertFalse(argv.contains("co -r"))
    }

    func testACatalogEntryWithNoCommandLaunchesArgvOnly() throws {
        let entry = LaunchableSession(id: "ask", displayName: "Ask")
        let argv = try SessionAgent.startArguments(
            target: TestHost.target, session: entry.id, directory: entry.workingDirectory,
            hasCommand: entry.command != nil)

        XCTAssertFalse(argv.contains("--command"))
        XCTAssertFalse(argv.contains("--dir"))
    }

    func testKillIsNeverTheDefault() throws {
        let gentle = try SessionAgent.stopArguments(target: TestHost.target, session: "nyh", kill: false)
        XCTAssertFalse(gentle.contains("--kill"))

        let destructive = try SessionAgent.stopArguments(target: TestHost.target, session: "nyh", kill: true)
        XCTAssertTrue(destructive.contains("--kill"))
    }
}

/// The scratch shell pane: its own tmux session on the mini, one per fleet
/// session, so the pane is disposable and the shell is not.
final class ShellPaneTests: XCTestCase {
    private func argv(session: String, directory: String? = nil) throws -> [String] {
        let (_, argv) = try TerminalLaunch.executableAndArguments(
            for: .remoteShell(session: session, workingDirectory: directory, target: TestHost.target))
        return argv
    }

    func testTheShellIsItsOwnTmuxSessionNamedForTheFleetSession() throws {
        // THE FIX THIS PINS. The shell used to be a bare `exec "$SHELL"`, so the
        // only thing holding its process was the pane — and tearing the pane
        // down on a session switch killed it, taking whatever was running.
        let a = try argv(session: "vivy")
        XCTAssertTrue(a.contains("new-session"), "\(a)")
        XCTAssertTrue(a.contains("deck-shell-vivy"), "\(a)")
        XCTAssertFalse(a.contains { $0.contains("exec \"$SHELL\"") }, "\(a)")
    }

    func testItAttachesRatherThanAlwaysCreating() throws {
        // `-A` is what makes switching back a REATTACH: same scrollback, same
        // running command. Without it every switch would start a fresh shell,
        // which is the old behaviour wearing tmux.
        XCTAssertTrue(try argv(session: "vivy").contains("-A"))
    }

    func testItNeverAttachesToTheAgentsOwnSession() throws {
        // The prefix is the whole guard: a scratch shell that attached to `vivy`
        // itself would put the user's typing into the agent's pane.
        let a = try argv(session: "vivy")
        XCTAssertFalse(a.contains("vivy"), "attached to the agent's session: \(a)")
    }

    func testTheDirectoryIsHonouredOnCreation() throws {
        let a = try argv(session: "vivy", directory: "~/Convivy/vivy")
        XCTAssertTrue(a.contains("-c"), "\(a)")
        XCTAssertTrue(a.contains("~/Convivy/vivy"), "\(a)")
    }

    func testADirectoryWithMetacharactersIsRefused() {
        for hostile in ["~/x; rm -rf /", "/tmp/$(whoami)", "/a b", "../escape"] {
            XCTAssertThrowsError(try argv(session: "vivy", directory: hostile), hostile)
        }
    }

    func testTheScratchSessionNameFollowsTheFleetSessionNotTheDirectory() throws {
        // THE BUG, AS AN ASSERTION. The pane's SwiftUI identity used to be
        // the cwd, so changing session changed the id and SwiftUI tore the
        // pane down. That identity now lives entirely at the call site —
        // `ContentView` tags the pane with `"shell:\(selection.stringForm)"`,
        // which never mentions a directory at all — so what is left to pin
        // here is the scratch tmux SESSION NAME `TerminalTarget.remoteShell`
        // produces: derived from the fleet session alone, present in argv
        // regardless of which directory the shell was opened with.
        XCTAssertTrue(try argv(session: "vivy", directory: "~/a").contains("deck-shell-vivy"))
        XCTAssertTrue(try argv(session: "vivy", directory: "~/b").contains("deck-shell-vivy"))
        XCTAssertFalse(try argv(session: "deck", directory: "~/a").contains("deck-shell-vivy"))
    }

    func testAnOverlongSessionNameIsTruncatedRatherThanRefused() throws {
        // Refusing would cost a long rail row its shell entirely. Truncation
        // keeps it, and stays inside the 64-character tmux cap.
        let long = String(repeating: "s", count: 80)
        let name = scratchShellSessionName(for: long)
        XCTAssertEqual(try validateTmuxSessionName(name), name)
        XCTAssertTrue(name.hasPrefix(scratchShellPrefix))
    }

    func testTheCwdIsDecodedFromState() {
        let json = #"{"session":"vivy","state":"working","alive":true,"cwd":"\#(TestHost.homeRoot)/vivy"}"#
        let decoded = SessionState.decode(Data(json.utf8), fallbackSession: "vivy")
        XCTAssertEqual(decoded.cwd, "\(TestHost.homeRoot)/vivy")
    }
}
