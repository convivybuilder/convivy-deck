import XCTest
@testable import Deck

final class TypographyTests: XCTestCase {
    // MARK: - Defaults

    /// The default names a font rather than leaving SwiftTerm to fall back.
    ///
    /// The fallback is `monospacedSystemFont` (SF Mono), whose advance is
    /// 2.9% wider than Monaco's at the same size — 26pt across a 120-column
    /// line, which reads as loose letter spacing. Asserting the name is set
    /// is what stops a future "simplify" from dropping back to the fallback
    /// and reintroducing that.
    func testDefaultNamesAFontExplicitly() {
        XCTAssertNotNil(TerminalTypography.default.fontName)
        XCTAssertFalse(TerminalTypography.default.fontNameIsUnresolvable,
                       "the default must resolve on a stock macOS install")
    }

    /// The property that actually matters is the rendered cell, not the
    /// numbers that produce it: rows need separation, and columns should not
    /// be looser than the font requires.
    ///
    /// SwiftTerm's own fallback (SF Mono at 13pt, lineSpacing 1.0) is the
    /// baseline this is measured against, because that combination is what
    /// made the canvas uncomfortable to read.
    func testDefaultCellIsTighterHorizontallyAndTallerVertically() {
        let fallback = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let fallbackWidth = fallback.advancement(forGlyph: fallback.glyph(withName: "W")).width
        let fallbackHeight = ceil(fallback.ascender - fallback.descender + fallback.leading)

        let font = TerminalTypography.default.resolvedFont
        let width = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let height = ceil((font.ascender - font.descender + font.leading)
                          * TerminalTypography.default.clampedLineSpacing)

        XCTAssertLessThan(width, fallbackWidth, "columns should be tighter than the fallback's")
        XCTAssertGreaterThanOrEqual(height, fallbackHeight,
                                    "rows should have at least the fallback's separation")
    }

    /// The default must land on a cell width that does NOT get inflated by
    /// SwiftTerm's pixel snapping.
    ///
    /// SwiftTerm computes `ceil(advance * scale) / scale`. Monaco 12's advance
    /// is 14.402 device pixels at 2x, so ceil pushes it to 15 — a 7.5pt cell
    /// where iTerm draws 7.0. That half-point per column is what made Deck read
    /// ~7% wider than iTerm at an identical font and size.
    ///
    /// Replicating the formula here rather than asserting `fontSize == 11.5`
    /// pins the property instead of the number: any size whose advance clears
    /// the pixel boundary cleanly passes, and any size that gets rounded up
    /// fails, which is the thing worth defending.
    func testDefaultSizeDoesNotGetInflatedByPixelSnapping() {
        let font = TerminalTypography.default.resolvedFont
        let advance = font.advancement(forGlyph: font.glyph(withName: "W")).width

        for scale: CGFloat in [1, 2] {
            let snapped = ceil(advance * scale) / scale
            let waste = snapped - advance
            XCTAssertLessThan(
                waste, 0.5 / scale,
                """
                at \(Int(scale))x, the default rounds \(advance)pt up to \(snapped)pt, \
                wasting \(waste)pt per column — SwiftTerm's ceil is inflating the cell.
                """
            )
        }
    }

    // MARK: - Bounds

    /// SwiftTerm divides the view by cell dimensions to get rows and columns,
    /// so a near-zero font size would ask for an enormous grid.
    func testFontSizeIsClampedBothWays() {
        XCTAssertEqual(
            TerminalTypography(fontName: nil, fontSize: 0.1, lineSpacing: 1.2).clampedFontSize,
            TerminalTypography.minimumFontSize)
        XCTAssertEqual(
            TerminalTypography(fontName: nil, fontSize: 999, lineSpacing: 1.2).clampedFontSize,
            TerminalTypography.maximumFontSize)
    }

    func testLineSpacingIsClampedBothWays() {
        XCTAssertEqual(
            TerminalTypography(fontName: nil, fontSize: 12, lineSpacing: 0).clampedLineSpacing,
            TerminalTypography.minimumLineSpacing)
        XCTAssertEqual(
            TerminalTypography(fontName: nil, fontSize: 12, lineSpacing: 99).clampedLineSpacing,
            TerminalTypography.maximumLineSpacing)
    }

    /// `min(max(nan, lo), hi)` returns nan — every comparison against NaN is
    /// false, so a naive clamp passes it straight through. SwiftTerm divides
    /// the view by cell dimensions to get rows and columns, and converting a
    /// NaN Double to Int traps, so this must be total.
    func testNaNFallsBackRatherThanPropagating() {
        let nanSize = TerminalTypography(fontName: nil, fontSize: .nan, lineSpacing: .nan)
        XCTAssertFalse(nanSize.clampedFontSize.isNaN)
        XCTAssertFalse(nanSize.clampedLineSpacing.isNaN)
        XCTAssertEqual(nanSize.clampedFontSize, TerminalTypography.default.fontSize)
        XCTAssertEqual(nanSize.clampedLineSpacing, TerminalTypography.default.lineSpacing)
        XCTAssertFalse(nanSize.resolvedFont.pointSize.isNaN)
    }

    /// `-1e999` survives JSONSerialization as -infinity, unlike `1e999` and a
    /// literal NaN, which it rejects. So infinity is the one non-finite value
    /// that genuinely reaches this from a config file.
    func testInfinityIsClampedToTheBounds() {
        let positive = TerminalTypography(
            fontName: nil, fontSize: .infinity, lineSpacing: .infinity)
        XCTAssertEqual(positive.clampedFontSize, TerminalTypography.maximumFontSize)
        XCTAssertEqual(positive.clampedLineSpacing, TerminalTypography.maximumLineSpacing)

        let negative = TerminalTypography(
            fontName: nil, fontSize: -.infinity, lineSpacing: -.infinity)
        XCTAssertEqual(negative.clampedFontSize, TerminalTypography.minimumFontSize)
        XCTAssertEqual(negative.clampedLineSpacing, TerminalTypography.minimumLineSpacing)
    }

    func testNegativeInfinityFromJSONIsHandled() {
        let config = ThemeConfiguration.parse(Data(#"{"terminal":{"fontSize":-1e999}}"#.utf8))
        let size = try? XCTUnwrap(config).typography.clampedFontSize
        XCTAssertEqual(size, TerminalTypography.minimumFontSize)
    }

    /// Holding Cmd-+ must settle at the ceiling rather than running away.
    func testAdjustingStopsAtTheBounds() {
        var typography = TerminalTypography.default
        for _ in 0..<200 { typography = typography.adjustingFontSize(by: 1) }
        XCTAssertEqual(typography.fontSize, TerminalTypography.maximumFontSize)

        for _ in 0..<200 { typography = typography.adjustingFontSize(by: -1) }
        XCTAssertEqual(typography.fontSize, TerminalTypography.minimumFontSize)
    }

    func testAdjustingDoesNotMutateTheOriginal() {
        let original = TerminalTypography.default
        _ = original.adjustingFontSize(by: 4)
        XCTAssertEqual(original.fontSize, TerminalTypography.default.fontSize)
    }

    // MARK: - Font resolution

    /// A config copied from another machine can name a font that isn't
    /// installed. Falling back keeps the terminal usable; refusing to draw
    /// would be a worse answer to a typo.
    func testUnresolvableFontNameFallsBackToMonospacedSystem() {
        let typography = TerminalTypography(
            fontName: "NoSuchFontExistsAnywhere", fontSize: 12, lineSpacing: 1.2)
        XCTAssertTrue(typography.fontNameIsUnresolvable)
        XCTAssertEqual(typography.resolvedFont.pointSize, 12)
        XCTAssertNotNil(typography.resolvedFont)
    }

    func testNoFontNameIsNotTreatedAsUnresolvable() {
        XCTAssertFalse(TerminalTypography.default.fontNameIsUnresolvable,
                       "unset should mean 'no preference', not 'broken'")
    }

    func testResolvedFontUsesTheClampedSize() {
        let typography = TerminalTypography(fontName: nil, fontSize: 999, lineSpacing: 1.2)
        XCTAssertEqual(typography.resolvedFont.pointSize, TerminalTypography.maximumFontSize)
    }

    func testAnInstalledFontIsHonoured() {
        // Menlo ships with macOS, so this is safe to assert on any runner.
        // Asserting on familyName, not fontName: NSFont(name:) accepts a family
        // and resolves it to a PostScript name, so "Menlo" comes back as
        // "Menlo-Regular". Both are the font the user asked for.
        let typography = TerminalTypography(fontName: "Menlo", fontSize: 12, lineSpacing: 1.2)
        XCTAssertFalse(typography.fontNameIsUnresolvable)
        XCTAssertEqual(typography.resolvedFont.familyName, "Menlo")
    }

    // MARK: - Round trip

    func testTypographySurvivesSaveAndLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-typo-\(UUID().uuidString)")
            .appendingPathComponent("theme.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let config = ThemeConfiguration(
            sessions: [:], appearancePreference: .system,
            typography: TerminalTypography(fontName: "Menlo", fontSize: 14, lineSpacing: 1.35))
        try config.save(to: url)

        let loaded = ThemeConfiguration.load(from: url)
        XCTAssertEqual(loaded.typography.fontName, "Menlo")
        XCTAssertEqual(loaded.typography.fontSize, 14)
        XCTAssertEqual(loaded.typography.lineSpacing, 1.35)
    }

    /// An unset fontName is omitted rather than written as null —
    /// JSONSerialization rejects a nil Optional bridged through Any, so this
    /// also guards against `save` throwing on the default configuration.
    func testUnsetFontNameOmittedFromFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-typo-\(UUID().uuidString)")
            .appendingPathComponent("theme.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Explicitly nil, since the shipped default names Monaco — this is
        // testing the nil-serialisation path, not the default.
        try ThemeConfiguration(
            sessions: [:], appearancePreference: .system,
            typography: TerminalTypography(fontName: nil, fontSize: 12, lineSpacing: 1.0)
        ).save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("fontName"))
        XCTAssertFalse(text.contains("null"))
    }

    /// Each typography key degrades on its own, for the same reason a bad
    /// appearance must not cost the user their session mapping.
    func testPartialTerminalSectionKeepsTheOtherDefaults() {
        let json = #"{"terminal":{"fontSize":16}}"#
        let config = ThemeConfiguration.parse(Data(json.utf8))
        XCTAssertEqual(config?.typography.fontSize, 16)
        XCTAssertEqual(config?.typography.lineSpacing, TerminalTypography.default.lineSpacing)
        XCTAssertEqual(config?.typography.fontName, TerminalTypography.default.fontName,
                       "an absent fontName should take the default, not nil")
    }

    func testMissingTerminalSectionYieldsDefaults() {
        let config = ThemeConfiguration.parse(Data(#"{"sessions":{}}"#.utf8))
        XCTAssertEqual(config?.typography, .default)
    }

    /// Written clamped, so a hand-edited out-of-range value is corrected in the
    /// file rather than silently ignored on every launch.
    func testOutOfRangeValuesAreWrittenClamped() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-typo-\(UUID().uuidString)")
            .appendingPathComponent("theme.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try ThemeConfiguration(
            sessions: [:], appearancePreference: .system,
            typography: TerminalTypography(fontName: nil, fontSize: 999, lineSpacing: 99)
        ).save(to: url)

        let loaded = ThemeConfiguration.load(from: url)
        XCTAssertEqual(loaded.typography.fontSize, TerminalTypography.maximumFontSize)
        XCTAssertEqual(loaded.typography.lineSpacing, TerminalTypography.maximumLineSpacing)
    }
}
