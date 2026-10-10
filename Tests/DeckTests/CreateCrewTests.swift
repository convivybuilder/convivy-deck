import XCTest
@testable import Deck

/// `SessionAgent.createCrew` is `StewardCrew.create`'s only entry point —
/// the fresh-install bootstrap is the sole remaining caller in this app that
/// can put `--create-dir` on argv. A rail-row Start must never create a
/// directory, so a typo in config cannot manufacture one.
final class CreateCrewTests: XCTestCase {
    // MARK: - --create-dir reaches argv only through createCrew

    func testCreateCrewArgvCarriesCreateDir() throws {
        let argv = try SessionAgent.startArguments(
            target: TestHost.target, session: "ask", directory: "~/Convivy/ask", createDirectory: true)
        XCTAssertTrue(argv.contains("--create-dir"))
    }

    /// `createDirectory` DEFAULTS to false — a caller that says nothing
    /// about creation gets none. Verified by mutation: flipping the default
    /// to `true` in `startArguments`'s signature fails this test (and
    /// `testCreateCrewArgvCarriesCreateDir` below still passes, since it
    /// asks explicitly), then restoring the default makes it pass again.
    ///
    /// THE REST OF THE ENFORCEMENT IS STRUCTURAL, not runtime-testable here:
    /// `SessionAgent.start` — what every rail-row Start button calls — has
    /// no `createDirectory` parameter at all, so it has no way to request
    /// the flag regardless of what the default is. `start` cannot be driven
    /// through its success path in this suite without a real ssh call (see
    /// `SessionAgent.run`, which shells out to `/usr/bin/ssh` with no
    /// injection seam), so that guarantee rests on the signature itself —
    /// the same reason every other `start`-vs-`startArguments` test here
    /// pins the argv builder rather than `start`.
    func testOrdinaryStartNeverCarriesCreateDir() throws {
        let argv = try SessionAgent.startArguments(target: TestHost.target, session: "ask", directory: "~/Convivy/ask")
        XCTAssertFalse(argv.contains("--create-dir"))
    }

    // MARK: - createCrew's own argv shape

    func testCreateCrewCarriesTheDirectoryOnArgv() throws {
        let argv = try SessionAgent.startArguments(
            target: TestHost.target, session: "ask", directory: "~/Convivy/ask", hasCommand: true, createDirectory: true)
        XCTAssertEqual(argv[argv.firstIndex(of: "--dir")! + 1], "~/Convivy/ask")
        XCTAssertEqual(argv[argv.firstIndex(of: "--command")! + 1], "-",
                       "the command still goes on stdin, never argv")
    }

    func testCreateCrewRejectsABadCommandBeforeSending() {
        XCTAssertThrowsError(
            try SessionAgent.createCrew(target: TestHost.target, session: "ask", directory: "~/Convivy/ask",
                                           command: "co\nrm -rf /"))
    }

    func testCreateCrewRejectsADirectoryThatEscapes() {
        XCTAssertThrowsError(
            try SessionAgent.createCrew(target: TestHost.target, session: "ask", directory: "../../etc"))
    }

    // MARK: - Creating and adopting are the same call

    /// Deck cannot see the mini's filesystem, so it never learns whether a
    /// directory already exists, and never branches on it. `Crew` and
    /// `createCrew` carry no "adopt" flag for such a mode to set, so
    /// recreating a crew after removing it from Deck goes through the
    /// identical `addCrew` call a brand-new crew does, and lands on the
    /// identical row.
    ///
    /// The spec argued this from the sheet — "restarting a crew in an existing
    /// folder is therefore the same sheet with an existing path and needs no
    /// separate 'add existing' mode" — wording superseded along with the sheet.
    /// What these tests assert is unchanged, because the property lives in
    /// `createCrew` and `addCrew` and never lived in the sheet.
    @MainActor
    func testRestartingACrewInAnExistingFolderIsTheSameCallAsCreatingOne() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-createcrew-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ThemeStore(fileURL: dir.appendingPathComponent("theme.json"))
        let crew = Crew(id: "ask", displayName: "Ask",
                         workingDirectory: "~/Convivy/ask", command: "co -r")

        store.addCrew(crew)
        XCTAssertEqual(store.configuration.railSessions?.first { $0.id == "ask" }, crew)

        // "Remove from Deck" — config only, the folder on the mini is
        // untouched (per the spec's own framing of why no adopt mode is
        // needed).
        store.removeCrew(SessionRef(host: nil, name: "ask"))
        XCTAssertNil(store.configuration.railSessions?.first { $0.id == "ask" })

        // The same `addCrew` call — restarting "Ask" in its still-existing
        // folder is not a distinct code path from creating it the first
        // time.
        store.addCrew(crew)
        XCTAssertEqual(store.configuration.railSessions?.first { $0.id == "ask" }, crew)
    }
}
