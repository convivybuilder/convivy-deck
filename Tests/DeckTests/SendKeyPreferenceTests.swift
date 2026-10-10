import XCTest
@testable import Deck

/// The send key is a preference because the two populations genuinely disagree:
/// a chat user sends on Return, an editor user needs Return to be a newline.
/// These pin the parts a wrong answer would cost a user their message.
final class SendKeyPreferenceTests: XCTestCase {
    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-sendkey-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    func testTheDefaultIsTheChatIdiom() {
        // The pane is a conversation, and its neighbours in that role send on
        // Return. A user who has never opened settings gets that.
        XCTAssertEqual(SendKeyPreference.default, .returnKey)
        XCTAssertTrue(SendKeyPreference.default.sendsOnBareReturn)
    }

    func testCommandReturnDoesNotSendOnABareReturn() {
        XCTAssertFalse(SendKeyPreference.commandReturn.sendsOnBareReturn)
    }

    func testEveryPreferenceNamesBothKeys() {
        // A label naming only the send key leaves the reader to guess what
        // happened to the newline, which is the question they are asking.
        for preference in SendKeyPreference.allCases {
            XCTAssertTrue(preference.label.contains("sends"), preference.label)
            XCTAssertTrue(preference.label.contains("new line"), preference.label)
        }
    }

    func testAnAbsentKeyGetsTheDefault() throws {
        let file = url()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"sessions": {}}"#.write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(ThemeConfiguration.load(from: file).sendKey, .default)
    }

    func testAnUnknownValueGetsTheDefaultRatherThanFailingTheWholeFile() throws {
        // The per-key degradation every other setting gets: a bad sendKey must
        // not cost the user their session colours.
        let file = url()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"sendKey": "banana", "sessions": {"vivy": "azure"}}"#
            .write(to: file, atomically: true, encoding: .utf8)

        let loaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(loaded.sendKey, .default)
        XCTAssertEqual(loaded.sessions[SessionRef(host: nil, name: "vivy")], "azure")
    }

    func testThePreferenceSurvivesSaveAndLoad() throws {
        let file = url()
        var configuration = ThemeConfiguration.empty
        configuration.sendKey = .commandReturn
        try configuration.save(to: file)

        XCTAssertEqual(ThemeConfiguration.load(from: file).sendKey, .commandReturn)
    }

    @MainActor
    func testTheStoreWritesTheChangeThrough() throws {
        let file = url()
        let store = ThemeStore(fileURL: file)
        XCTAssertEqual(store.configuration.sendKey, .default)

        store.setSendKey(.commandReturn)

        XCTAssertEqual(store.configuration.sendKey, .commandReturn)
        XCTAssertEqual(ThemeConfiguration.load(from: file).sendKey, .commandReturn,
                       "the preference applied in memory but was not persisted")
    }

    @MainActor
    func testTheOtherSettingsWriteThroughToo() throws {
        // The settings window is the first surface to mutate these, so each
        // needs the same round trip the theme picker already had.
        let file = url()
        let store = ThemeStore(fileURL: file)

        store.setAppearancePreference(.dark)
        store.setFontSize(18)
        store.setLineSpacing(1.4)

        let reloaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(reloaded.appearancePreference, .dark)
        XCTAssertEqual(reloaded.typography.clampedFontSize, 18)
        XCTAssertEqual(reloaded.typography.clampedLineSpacing, 1.4, accuracy: 0.001)
    }
}

/// The settings sliders fire continuously while dragged, and `commit` writes the
/// config synchronously on the main actor — so a drag was one file write per
/// tick. These pin the split that fixed it: preview applies on screen, and only
/// the end of the gesture reaches the disk.
final class TypographyPreviewTests: XCTestCase {
    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-preview-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    @MainActor
    func testAPreviewAppliesOnScreenWithoutTouchingTheFile() throws {
        let file = url()
        let store = ThemeStore(fileURL: file)
        store.setFontSize(12)          // one real write, so the file exists

        store.previewTypography { $0.fontSize = 20 }

        XCTAssertEqual(store.configuration.typography.clampedFontSize, 20,
                       "the preview did not apply on screen")
        XCTAssertEqual(ThemeConfiguration.load(from: file).typography.clampedFontSize, 12,
                       "the preview reached the file; a drag would write once per tick")
    }

    @MainActor
    func testTheEndOfTheGesturePersistsWhateverWasPreviewed() throws {
        let file = url()
        let store = ThemeStore(fileURL: file)

        // A drag: several previews, then one commit.
        for size in stride(from: 12.0, through: 20.0, by: 2.0) {
            store.previewTypography { $0.fontSize = CGFloat(size) }
        }
        store.commitPreviewedTypography()

        XCTAssertEqual(ThemeConfiguration.load(from: file).typography.clampedFontSize, 20)
    }

    @MainActor
    func testAPreviewOfOneValueLeavesTheOtherAlone() throws {
        let store = ThemeStore(fileURL: url())
        store.previewTypography { $0.fontSize = 20 }
        store.previewTypography { $0.lineSpacing = 1.5 }

        XCTAssertEqual(store.configuration.typography.clampedFontSize, 20)
        XCTAssertEqual(store.configuration.typography.clampedLineSpacing, 1.5, accuracy: 0.001)
    }
}
