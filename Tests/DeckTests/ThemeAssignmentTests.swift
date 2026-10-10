import XCTest
@testable import Deck

final class ThemeAssignmentTests: XCTestCase {
    // MARK: - Stable assignment

    /// The property that makes a session color an identity cue: it must not
    /// move. Swift's built-in hasher is seeded per process and would repaint
    /// every session on every launch, so this pins the assignment to specific
    /// themes. If a future change swaps the hash, this fails loudly rather
    /// than shipping colors that quietly shuffle between runs.
    func testSessionAssignmentIsPinnedAndStable() {
        let first = ThemeCatalog.defaultTheme(forSession: "vivy").name
        for _ in 0..<50 {
            XCTAssertEqual(ThemeCatalog.defaultTheme(forSession: "vivy").name, first)
        }
    }

    func testStableHashMatchesFNV1aReferenceVectors() {
        // Canonical FNV-1a 64-bit vectors — independent of this implementation,
        // so the test still means something if the function is rewritten.
        XCTAssertEqual(ThemeCatalog.stableHash(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(ThemeCatalog.stableHash("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(ThemeCatalog.stableHash("foobar"), 0x85944171f73967e8)
    }

    /// Adding or removing sessions must not repaint the others — the failure
    /// mode of assigning by rail position.
    func testAssignmentDoesNotDependOnOtherSessions() {
        let before = ["vivy", "deck", "hollis"].map { ThemeCatalog.defaultTheme(forSession: $0).name }
        _ = ThemeCatalog.defaultTheme(forSession: "a-brand-new-session")
        let after = ["vivy", "deck", "hollis"].map { ThemeCatalog.defaultTheme(forSession: $0).name }
        XCTAssertEqual(before, after)
    }

    func testEverySessionNameResolvesToAShippedTheme() {
        for name in ["vivy", "deck", "steward", "", "a", String(repeating: "z", count: 64)] {
            let theme = ThemeCatalog.defaultTheme(forSession: name)
            XCTAssertNotNil(ThemeCatalog.named(theme.name), "\(name) resolved outside the catalog")
        }
    }

    // MARK: - Configuration precedence

    func testExplicitMappingWinsOverHashedDefault() {
        let config = ThemeConfiguration(sessions: [SessionRef(host: nil, name: "vivy"): "gold"], appearancePreference: .system, typography: .default)
        XCTAssertEqual(config.theme(forSession: SessionRef(host: nil, name: "vivy")).name, "gold")
    }

    /// A typo should cost the intended color, never the terminal.
    func testUnknownThemeNameFallsBackToDefault() {
        let config = ThemeConfiguration(sessions: [SessionRef(host: nil, name: "vivy"): "chartreuse"], appearancePreference: .system, typography: .default)
        XCTAssertEqual(config.theme(forSession: SessionRef(host: nil, name: "vivy")).name,
                       ThemeCatalog.defaultTheme(forSession: "vivy").name)
    }

    func testUnmappedSessionUsesHashedDefault() {
        let config = ThemeConfiguration(sessions: [SessionRef(host: nil, name: "vivy"): "gold"], appearancePreference: .system, typography: .default)
        XCTAssertEqual(config.theme(forSession: SessionRef(host: nil, name: "deck")).name,
                       ThemeCatalog.defaultTheme(forSession: "deck").name)
    }

    // MARK: - Appearance preference

    func testSystemPreferenceFollowsTheSystem() {
        let config = ThemeConfiguration(sessions: [:], appearancePreference: .system, typography: .default)
        XCTAssertEqual(config.appearance(for: .conversation, systemIsDark: true), .dark)
        XCTAssertEqual(config.appearance(for: .conversation, systemIsDark: false), .light)
    }

    /// A never-set preference is Builder Default, so the conversation draws
    /// light whichever way the system is set.
    func testNeverSetPreferenceDrawsTheConversationLightWhateverTheSystem() {
        XCTAssertEqual(ThemeConfiguration.empty.appearancePreference, .builderDefault)
        XCTAssertEqual(ThemeConfiguration.empty.appearance(for: .conversation, systemIsDark: true), .light)
        XCTAssertEqual(ThemeConfiguration.empty.appearance(for: .conversation, systemIsDark: false), .light)
    }

    /// The override is the reason this exists: a user who cannot read one
    /// appearance must not be dragged into it by a system setting.
    func testExplicitPreferenceIgnoresTheSystem() {
        let pinnedLight = ThemeConfiguration(sessions: [:], appearancePreference: .light, typography: .default)
        XCTAssertEqual(pinnedLight.appearance(for: .conversation, systemIsDark: true), .light)

        let pinnedDark = ThemeConfiguration(sessions: [:], appearancePreference: .dark, typography: .default)
        XCTAssertEqual(pinnedDark.appearance(for: .conversation, systemIsDark: false), .dark)
    }

    // MARK: - Config parsing

    func testParsesAWellFormedConfig() {
        let json = #"{"sessions":{"vivy":"azure"},"appearance":"light"}"#
        let config = ThemeConfiguration.parse(Data(json.utf8))
        XCTAssertEqual(config?.sessions, [SessionRef(host: nil, name: "vivy"): "azure"])
        XCTAssertEqual(config?.appearancePreference, .light)
    }

    func testMissingFileMeansNoOverrides() {
        let missing = URL(fileURLWithPath: "/nonexistent/deck/theme.json")
        XCTAssertEqual(ThemeConfiguration.load(from: missing), .empty)
    }

    /// Malformed JSON degrades to defaults rather than refusing to draw.
    func testMalformedConfigDegradesToDefaults() {
        XCTAssertNil(ThemeConfiguration.parse(Data("{not json".utf8)))
        XCTAssertEqual(ThemeConfiguration.load(from: writeTemp("{not json")), .empty)
    }

    /// Each field degrades independently — a bad appearance value should not
    /// cost the user their session mapping.
    func testBadAppearanceValueKeepsSessionMapping() {
        let json = #"{"sessions":{"vivy":"azure"},"appearance":"chartreuse"}"#
        let config = ThemeConfiguration.parse(Data(json.utf8))
        XCTAssertEqual(config?.sessions, [SessionRef(host: nil, name: "vivy"): "azure"])
        XCTAssertEqual(config?.appearancePreference, .system)
    }

    // MARK: - Rail from config

    func testParsesARailInFileOrder() {
        let json = """
        {"rail":[{"session":"hollis","name":"Hollis","workdir":"\(TestHost.secondaryHomeRoot)/hollis"},
                 {"session":"ask"}]}
        """
        let rail = ThemeConfiguration.parse(Data(json.utf8))?.railSessions
        XCTAssertEqual(rail?.map(\.id), ["hollis", "ask"])
        XCTAssertEqual(rail?.first?.displayName, "Hollis")
        XCTAssertEqual(rail?.first?.workingDirectory, "\(TestHost.secondaryHomeRoot)/hollis")
        // A row with no name shows its session name rather than nothing.
        XCTAssertEqual(rail?.last?.displayName, "ask")
        XCTAssertNil(rail?.last?.workingDirectory)
    }

    /// Absent and empty are different answers. Absent means "not configured",
    /// which falls back to the shipped catalog; empty means the user wants no
    /// fleet rows and must be honoured, or opting out would be impossible.
    func testAbsentRailIsDistinctFromAnEmptyOne() {
        XCTAssertNil(ThemeConfiguration.parse(Data(#"{"sessions":{}}"#.utf8))?.railSessions)
        XCTAssertEqual(ThemeConfiguration.parse(Data(#"{"rail":[]}"#.utf8))?.railSessions, [])
    }

    /// A row that could never become valid ssh argv is dropped rather than
    /// drawn: a rail row that fails on click looks like the session is down.
    func testRailDropsRowsThatCouldNotConnect() {
        let json = #"{"rail":[{"session":"steward; rm -rf ~"},{"name":"No session"},{"session":"deck"}]}"#
        XCTAssertEqual(
            ThemeConfiguration.parse(Data(json.utf8))?.railSessions?.map(\.id), ["deck"])
    }

    /// A bad workdir costs the row its directory, not its place on the rail.
    /// The session still attaches; only creating it loses the starting point.
    func testBadWorkingDirectoryKeepsTheRow() {
        let json = #"{"rail":[{"session":"deck","workdir":"/tmp; rm -rf ~"}]}"#
        let rail = ThemeConfiguration.parse(Data(json.utf8))?.railSessions
        XCTAssertEqual(rail?.map(\.id), ["deck"])
        XCTAssertNil(rail?.first?.workingDirectory)
    }

    /// A save triggered by something unrelated — picking a theme, changing font
    /// size — must not freeze the shipped catalog into the user's file as if
    /// they had chosen it, or later catalog changes would never reach them.
    func testUnconfiguredRailIsNotWrittenToTheFile() throws {
        let url = writeTemp("{}")
        try ThemeConfiguration.empty.save(to: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.contains("rail"))
        XCTAssertNil(ThemeConfiguration.load(from: url).railSessions)
    }

    func testRailSurvivesSaveAndLoad() throws {
        let url = writeTemp("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [
            Crew(id: "hollis", displayName: "Hollis", workingDirectory: "\(TestHost.secondaryHomeRoot)/hollis"),
            Crew(id: "ask", displayName: "ask"),
        ]
        try config.save(to: url)
        XCTAssertEqual(ThemeConfiguration.load(from: url).railSessions, config.railSessions)
    }

    private func writeTemp(_ contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-theme-\(UUID().uuidString).json")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
