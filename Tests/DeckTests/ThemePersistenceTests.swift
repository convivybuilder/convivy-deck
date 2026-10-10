import XCTest
@testable import Deck

/// The picker writes the same file a user can hand-edit, so the two have to
/// agree. These cover the round trip and the reset path.
final class ThemePersistenceTests: XCTestCase {
    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-theme-\(UUID().uuidString)")
            .appendingPathComponent("theme.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        return url
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = tempURL()
        let config = ThemeConfiguration(
            sessions: [SessionRef(host: nil, name: "vivy"): "azure", SessionRef(host: nil, name: "deck"): "gold"], appearancePreference: .light, typography: .default)
        try config.save(to: url)
        XCTAssertEqual(ThemeConfiguration.load(from: url), config)
    }

    /// The picker's target directory does not exist on a fresh machine.
    func testSaveCreatesTheContainingDirectory() throws {
        let url = tempURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        try ThemeConfiguration.empty.save(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// A file the picker wrote must be one a user can read and edit — that is
    /// the whole reason the file remains the escape hatch.
    func testSavedFileIsHumanEditable() throws {
        let url = tempURL()
        try ThemeConfiguration(sessions: [SessionRef(host: nil, name: "vivy"): "azure"], appearancePreference: .system, typography: .default)
            .save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\n"), "should be pretty-printed, not one line")
        XCTAssertTrue(text.contains("vivy"))
        XCTAssertTrue(text.contains("azure"))
    }

    func testSettingThemeDoesNotMutateTheOriginal() {
        let original = ThemeConfiguration.empty
        let updated = original.settingTheme("gold", forSession: SessionRef(host: nil, name: "deck"))
        XCTAssertTrue(original.sessions.isEmpty, "value semantics: the pick must not mutate in place")
        XCTAssertEqual(updated.sessions[SessionRef(host: nil, name: "deck")], "gold")
    }

    func testSettingThemeOverwritesAnExistingMapping() {
        let config = ThemeConfiguration(sessions: [SessionRef(host: nil, name: "deck"): "rose"], appearancePreference: .system, typography: .default)
        XCTAssertEqual(config.settingTheme("gold", forSession: SessionRef(host: nil, name: "deck")).sessions[SessionRef(host: nil, name: "deck")], "gold")
    }

    /// Reset removes the mapping so the session falls back to its hashed
    /// default, rather than pinning the default as an explicit choice — those
    /// differ the moment the catalog changes.
    func testResetRemovesTheMappingEntirely() throws {
        let url = tempURL()
        var config = ThemeConfiguration(sessions: [SessionRef(host: nil, name: "deck"): "rose"], appearancePreference: .system, typography: .default)
        config.sessions.removeValue(forKey: SessionRef(host: nil, name: "deck"))
        try config.save(to: url)

        let reloaded = ThemeConfiguration.load(from: url)
        XCTAssertNil(reloaded.sessions[SessionRef(host: nil, name: "deck")])
        XCTAssertEqual(reloaded.theme(forSession: SessionRef(host: nil, name: "deck")).name,
                       ThemeCatalog.defaultTheme(forSession: "deck").name)
    }

    func testAppearancePreferenceSurvivesTheRoundTrip() throws {
        for preference in [ThemeConfiguration.AppearancePreference.system, .light, .dark, .builderDefault] {
            let url = tempURL()
            try ThemeConfiguration(
                sessions: [:], appearancePreference: preference, typography: .default
            ).save(to: url)
            XCTAssertEqual(ThemeConfiguration.load(from: url).appearancePreference, preference)
        }
    }

    // MARK: - The divider's persisted width

    /// The same view-preference channel font size and theme picks use — see
    /// `ContentView.columnDivider`, which never invents a second mechanism.
    func testColumnWidthSurvivesTheRoundTrip() throws {
        let url = tempURL()
        var config = ThemeConfiguration.empty
        config.columnWidth = 512
        try config.save(to: url)
        XCTAssertEqual(ThemeConfiguration.load(from: url).columnWidth, 512)
    }

    /// A config that predates this field reads as the shipped default rather
    /// than zero — the same per-field degradation every other key gets.
    func testAnAbsentColumnWidthLoadsAsTheDefault() throws {
        let url = tempURL()
        // `tempURL` names a file inside a directory that does not exist yet.
        // Every other test here reaches disk through `save(to:)`, which creates
        // it; this one writes the bytes directly and has to do the same.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
        XCTAssertEqual(ThemeConfiguration.load(from: url).columnWidth,
                       ThemeConfiguration.defaultColumnWidth)
    }

    /// `clampedColumnWidth` is what reaches disk, so a hand-edited negative or
    /// NaN value cannot corrupt the row it is written into.
    func testClampedColumnWidthFallsBackOnACorruptValue() {
        var config = ThemeConfiguration.empty
        config.columnWidth = -40
        XCTAssertEqual(config.clampedColumnWidth, ThemeConfiguration.minimumColumnWidth)
        config.columnWidth = .nan
        XCTAssertEqual(config.clampedColumnWidth, ThemeConfiguration.defaultColumnWidth)
    }
}
