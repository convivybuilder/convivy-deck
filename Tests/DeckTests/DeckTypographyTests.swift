import XCTest
@testable import Deck

/// Four independently sized surfaces, and the migration that keeps a user's
/// current page size when the session stops inheriting the terminal's.
final class DeckTypographyTests: XCTestCase {

    // MARK: - The migration

    func testAnAbsentSessionKeyInheritsTheOldDerivedScale() {
        // THE SILENT REGRESSION THIS PREVENTS. The pane's scale used to be
        // `terminalSize / 11.5`, so a user at 13pt has been reading a ~113%
        // page. Decoupling with a flat 1.0 default would shrink it on the next
        // launch with nothing to say what changed.
        let config = ThemeConfiguration.parse(Data(#"{"terminal":{"fontSize":13}}"#.utf8))
        let expected = 13.0 / Double(TerminalTypography.scaleInheritanceBase)
        XCTAssertEqual(config?.sessionTypography.scale ?? 0, expected, accuracy: 0.0001)
    }

    func testTheMigrationSurvivesTheTerminalDefaultMoving() {
        // THE LATENT BUG THIS CLOSES. The migration divided by the LIVE default,
        // which is the same number as the historical one today and stops being
        // so the moment the default moves — and it is about to. SwiftTerm's
        // cell-width rounding was fixed upstream (87a7888), `.rounded()`
        // replaces `ceil`, and Monaco 12 then lands on the same 7.0pt cell that
        // forced 11.5 in the first place.
        //
        // Asserted against the frozen constant rather than the default, so this
        // test keeps passing when the default becomes 12 — and would have failed
        // the day someone moved it while the divisor still tracked it.
        let config = ThemeConfiguration.parse(Data(#"{"terminal":{"fontSize":13}}"#.utf8))
        XCTAssertEqual(config?.sessionTypography.scale ?? 0,
                       13.0 / Double(TerminalTypography.scaleInheritanceBase),
                       accuracy: 0.0001)
        // The record of what a past version computed. If this ever needs
        // changing, the migration it describes has changed meaning.
        XCTAssertEqual(TerminalTypography.scaleInheritanceBase, 11.5)
    }

    func testAConfigWithNeitherKeyGetsTheShippedDefault() {
        // No terminal override means the ratio is 1, which is also the default —
        // the migration and the default agree for anyone who never touched it.
        let config = ThemeConfiguration.parse(Data("{}".utf8))
        XCTAssertEqual(config?.sessionTypography.clampedScale ?? 0, 1.0, accuracy: 0.0001)
    }

    func testAPresentSessionKeyIsTakenAtItsWord() {
        // Once written, the value is a choice rather than an inheritance — even
        // when it equals the default and even when the terminal disagrees.
        let json = #"{"terminal":{"fontSize":20},"session":{"scale":1.0,"lineHeight":1.9}}"#
        let config = ThemeConfiguration.parse(Data(json.utf8))
        XCTAssertEqual(config?.sessionTypography.scale, 1.0)
        XCTAssertEqual(config?.sessionTypography.lineHeight, 1.9)
    }

    func testTheInheritedScaleIsWrittenDownOnTheFirstSave() throws {
        // If the save omitted it, every later launch would re-derive it from the
        // terminal and the decoupling would never actually take.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-typo-\(UUID().uuidString)")
            .appendingPathComponent("theme.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var config = try XCTUnwrap(ThemeConfiguration.parse(Data(#"{"terminal":{"fontSize":13}}"#.utf8)))
        let inherited = config.sessionTypography.scale
        try config.save(to: url)

        // Reloaded, the terminal could be anything: the session keeps its value.
        let reloaded = ThemeConfiguration.load(from: url)
        XCTAssertEqual(reloaded.sessionTypography.scale, inherited, accuracy: 0.0001)
    }

    // MARK: - Independence

    func testEachSurfaceSurvivesSaveAndLoadOnItsOwn() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-typo-\(UUID().uuidString)")
            .appendingPathComponent("theme.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var config = ThemeConfiguration.empty
        config.typography.fontSize = 14
        config.sessionTypography = SessionTypography(scale: 1.3, lineHeight: 1.8)
        config.composerTypography = ComposerTypography(fontSize: 15)
        config.frameTypography = FrameTypography(baseSize: 12)
        try config.save(to: url)

        let reloaded = ThemeConfiguration.load(from: url)
        XCTAssertEqual(reloaded.typography.clampedFontSize, 14)
        XCTAssertEqual(reloaded.sessionTypography.clampedScale, 1.3, accuracy: 0.0001)
        XCTAssertEqual(reloaded.sessionTypography.clampedLineHeight, 1.8, accuracy: 0.0001)
        XCTAssertEqual(reloaded.composerTypography.clampedFontSize, 15)
        XCTAssertEqual(reloaded.frameTypography.clampedBaseSize, 12)
    }

    func testMovingTheTerminalNoLongerMovesTheSession() {
        // The coupling the operator reported, as an assertion: "a terminal font size
        // which also changes the session font size".
        var config = ThemeConfiguration.empty
        let before = config.sessionTypography.clampedScale
        config.typography.fontSize = 20
        XCTAssertEqual(config.sessionTypography.clampedScale, before)
    }

    // MARK: - Bounds

    func testEverySurfaceClampsAndSurvivesNaN() {
        // A NaN passes a naive clamp — every comparison against it is false —
        // and a NaN size reaching layout arithmetic traps on the Int conversion.
        XCTAssertEqual(SessionTypography(scale: .nan, lineHeight: .nan).clampedScale,
                       SessionTypography.default.scale)
        XCTAssertEqual(SessionTypography(scale: .nan, lineHeight: .nan).clampedLineHeight,
                       SessionTypography.default.lineHeight)
        XCTAssertEqual(ComposerTypography(fontSize: .nan).clampedFontSize,
                       ComposerTypography.default.fontSize)
        XCTAssertEqual(FrameTypography(baseSize: .nan).clampedBaseSize,
                       FrameTypography.default.baseSize)

        XCTAssertEqual(SessionTypography(scale: 99, lineHeight: 99).clampedScale,
                       SessionTypography.maximumScale)
        XCTAssertEqual(FrameTypography(baseSize: 0).clampedBaseSize,
                       FrameTypography.minimumBaseSize)
    }

    // MARK: - Frame roles

    func testTheRolesHoldTheirHierarchyAtEverySize() {
        // The point of deriving them: a user moving the frame's base must not be
        // able to make a caption larger than a rail row's name.
        for base in stride(from: FrameTypography.minimumBaseSize,
                           through: FrameTypography.maximumBaseSize, by: 0.5) {
            let frame = FrameTypography(baseSize: base)
            XCTAssertGreaterThan(frame.size(.primary), frame.size(.emphasis), "base \(base)")
            XCTAssertGreaterThan(frame.size(.emphasis), frame.size(.body), "base \(base)")
            XCTAssertGreaterThan(frame.size(.body), frame.size(.caption), "base \(base)")
            XCTAssertGreaterThan(frame.size(.caption), frame.size(.icon), "base \(base)")
            XCTAssertEqual(frame.size(.body), frame.size(.live), "base \(base)")
        }
    }

    func testCaptionsClearTheLegibilityFloorAtTheDefault() {
        // The send hint was 9pt, under the 10 macOS treats as the minimum for
        // text — the line telling a new user which key sends was the least
        // legible thing on screen. Only the icon role may go below it, and it is
        // an optical correction beside text rather than text itself.
        let frame = FrameTypography.default
        XCTAssertGreaterThanOrEqual(frame.size(.caption), 10)
        XCTAssertGreaterThanOrEqual(frame.size(.label), 10)
        XCTAssertLessThan(frame.size(.icon), frame.size(.body))
    }

    // MARK: - What reaches the renderer

    func testTheDefaultLineHeightIsNotSentToTheRenderer() throws {
        // An older mini rejects the unknown flag and the render fails outright,
        // so a user who never touched the slider must never meet it.
        let argv = try SessionAgent.renderArguments(
            target: TestHost.target, session: "deck", appearance: .dark,
            lineHeight: SessionTypography.default.lineHeight)
        XCTAssertFalse(argv.contains("--line-height"), "\(argv)")
    }

    func testAChosenLineHeightIsSent() throws {
        let argv = try SessionAgent.renderArguments(
            target: TestHost.target, session: "deck", appearance: .dark, lineHeight: 1.9)
        guard let flag = argv.firstIndex(of: "--line-height") else {
            return XCTFail("no --line-height in \(argv)")
        }
        XCTAssertEqual(argv[flag + 1], "1.90")
    }

    func testAnOutOfRangeLineHeightIsNeverSent() throws {
        for bad in [0.5, 9.0, Double.nan, .infinity] {
            let argv = try SessionAgent.renderArguments(
                target: TestHost.target, session: "deck", appearance: .dark, lineHeight: bad)
            XCTAssertFalse(argv.contains("--line-height"), "\(bad) reached the renderer")
        }
    }
}
