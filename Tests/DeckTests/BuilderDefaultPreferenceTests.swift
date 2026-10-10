import XCTest
@testable import Deck

/// What "never set" means for the appearance preference, and what the file
/// holds once a choice is made.
///
/// An absent `appearance` key is "never set" and reads as Builder Default. A
/// stored `system`, `light` or `dark` is a choice and reads as itself. Builder
/// Default is not written, so a file saved without a choice stays without the
/// key and keeps following the default.
final class BuilderDefaultPreferenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("builder-default-pref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String = "theme.json") -> URL {
        directory.appendingPathComponent(name)
    }

    private func parse(_ json: String) throws -> ThemeConfiguration {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(ThemeConfiguration.parse(data))
    }

    private func storedAppearance(at url: URL) throws -> Any? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])["appearance"]
    }

    // MARK: - Never set

    /// A file that says nothing about appearance has never had a choice made,
    /// so it draws Builder Default. Both directions: the key is absent, and a
    /// file that has other keys does not change that.
    func testAFileWithoutTheKeyIsBuilderDefault() throws {
        XCTAssertEqual(try parse(#"{}"#).appearancePreference, .builderDefault)
        XCTAssertEqual(try parse(#"{"defaultHost":"macstudio","columnWidth":320}"#).appearancePreference,
                       .builderDefault)
    }

    /// With no file at all, the in-memory configuration is the default too.
    func testNoFileIsBuilderDefault() {
        XCTAssertEqual(ThemeConfiguration.load(from: url("absent.json")).appearancePreference,
                       .builderDefault)
    }

    /// A malformed file names no preference, so it is the same as no file.
    func testAMalformedFileIsBuilderDefault() throws {
        try "{ not json".write(to: url("broken.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ThemeConfiguration.load(from: url("broken.json")).appearancePreference,
                       .builderDefault)
    }

    // MARK: - Explicit choices stay as they are

    /// An explicit stored System, Light or Dark is kept, whatever the default
    /// is. A file written by a build before this change holds `system` even
    /// where the user never chose it, and this is what keeps that file's value.
    func testStoredSystemLightAndDarkAreKept() throws {
        XCTAssertEqual(try parse(#"{"appearance":"system"}"#).appearancePreference, .system)
        XCTAssertEqual(try parse(#"{"appearance":"light"}"#).appearancePreference, .light)
        XCTAssertEqual(try parse(#"{"appearance":"dark"}"#).appearancePreference, .dark)
    }

    /// `split` is the name Builder Default had before the rename, and a file
    /// that still says it keeps the choice it made.
    func testStoredSplitIsBuilderDefault() throws {
        XCTAssertEqual(try parse(#"{"appearance":"split"}"#).appearancePreference, .builderDefault)
    }

    /// Each explicit choice is written and read back as itself, so saving
    /// never turns a choice into the default.
    func testExplicitChoicesRoundTripThroughTheFile() throws {
        for preference in [ThemeConfiguration.AppearancePreference.system, .light, .dark] {
            var config = ThemeConfiguration.empty
            config.appearancePreference = preference
            try config.save(to: url())
            XCTAssertEqual(ThemeConfiguration.load(from: url()).appearancePreference, preference)
            XCTAssertEqual(try storedAppearance(at: url()) as? String, preference.rawValue)
        }
    }

    // MARK: - Builder Default is not written

    /// A save of Builder Default leaves the key out, so the next load still
    /// finds the preference never set.
    func testSavingBuilderDefaultOmitsTheKey() throws {
        var config = ThemeConfiguration.empty
        config.appearancePreference = .builderDefault
        try config.save(to: url())
        XCTAssertNil(try storedAppearance(at: url()))
        XCTAssertEqual(ThemeConfiguration.load(from: url()).appearancePreference, .builderDefault)
    }

    /// Choosing Builder Default after Dark removes the stored Dark. The file
    /// does not keep the old choice behind the default.
    func testChoosingBuilderDefaultAfterDarkRemovesTheStoredChoice() throws {
        var config = ThemeConfiguration.empty
        config.appearancePreference = .dark
        try config.save(to: url())
        XCTAssertEqual(try storedAppearance(at: url()) as? String, "dark")

        config.appearancePreference = .builderDefault
        try config.save(to: url())
        XCTAssertNil(try storedAppearance(at: url()))
        XCTAssertEqual(ThemeConfiguration.load(from: url()).appearancePreference, .builderDefault)
    }
}
