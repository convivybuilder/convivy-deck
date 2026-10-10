import XCTest
@testable import Deck

/// The readability guarantee, made executable.
///
/// This suite exists because of a real failure: the terminal canvas ran
/// SwiftTerm's stock palette — black background, ANSI colors tuned for it —
/// inside a light app frame, and was unreadable. Setting a light background
/// alone would have swapped one unreadable state for another, because ANSI
/// colors chosen against black have no contrast against cream. These tests
/// assert the property that actually matters rather than pinning hex values,
/// so the palette can be retuned freely and can never regress to unreadable.
final class ThemeContrastTests: XCTestCase {
    /// Slots that carry text. 0/8 and 7/15 are the ends of the ramp and are
    /// asserted separately below — one end is text, the other is the
    /// reverse-video background role.
    private let chromaticSlots = Array(1...6) + Array(9...14)

    func testEveryChromaticANSIColorIsReadableInBothAppearances() {
        for theme in ThemeCatalog.all {
            for (label, palette) in [("light", theme.light), ("dark", theme.dark)] {
                for slot in chromaticSlots {
                    let ratio = palette.ansi[slot].contrastRatio(against: palette.background)
                    XCTAssertGreaterThanOrEqual(
                        ratio, ThemeRecipe.minimumTextContrast,
                        """
                        \(theme.name) \(label) ANSI \(slot) \
                        (\(palette.ansi[slot].hexString) on \(palette.background.hexString)) \
                        is \(String(format: "%.2f", ratio)):1 — below WCAG AA.
                        """
                    )
                }
            }
        }
    }

    func testForegroundClearsEnhancedContrastInBothAppearances() {
        for theme in ThemeCatalog.all {
            for (label, palette) in [("light", theme.light), ("dark", theme.dark)] {
                let ratio = palette.foreground.contrastRatio(against: palette.background)
                XCTAssertGreaterThanOrEqual(
                    ratio, 7.0,
                    "\(theme.name) \(label) foreground is only \(String(format: "%.2f", ratio)):1"
                )
            }
        }
    }

    /// The strongest text slot must be genuinely strong, and the
    /// reverse-video background slot must stay close to the page. Asserting
    /// both directions is what stops a future retune from "fixing" the low
    /// end by making highlighted regions unreadable.
    func testRampEndsKeepTheirRoles() {
        for theme in ThemeCatalog.all {
            // Light: slot 0 is text, slot 15 is a background.
            XCTAssertGreaterThanOrEqual(
                theme.light.ansi[0].contrastRatio(against: theme.light.background), 7.0,
                "\(theme.name) light ANSI 0 should be the strongest text color")
            XCTAssertLessThan(
                theme.light.ansi[15].contrastRatio(against: theme.light.background), 2.0,
                "\(theme.name) light ANSI 15 should sit near the page, for reverse video")

            // Dark: the roles swap ends.
            XCTAssertGreaterThanOrEqual(
                theme.dark.ansi[15].contrastRatio(against: theme.dark.background), 7.0,
                "\(theme.name) dark ANSI 15 should be the strongest text color")
            XCTAssertLessThan(
                theme.dark.ansi[0].contrastRatio(against: theme.dark.background), 2.0,
                "\(theme.name) dark ANSI 0 should sit near the page, for reverse video")
        }
    }

    /// Selected text is a separate contrast pair from ordinary text, and it is
    /// easy to miss: SwiftTerm overrides each character's own color with
    /// `selectedTextForegroundColor` while selected, so a palette can have
    /// every ANSI slot readable and still render selections illegibly. Its Mac
    /// default is black, which is why this needs asserting rather than
    /// assuming.
    ///
    /// SCOPE, stated so this is not read as more than it is: this asserts the
    /// palette's own foreground-on-selection pair. It does not assert that
    /// `apply` assigns `selectedTextForegroundColor`, which would need a live
    /// TerminalView and a window server. Deleting that line would still pass
    /// here — the comment at the assignment is what carries that.
    func testSelectedTextIsReadable() {
        for theme in ThemeCatalog.all {
            for (label, palette) in [("light", theme.light), ("dark", theme.dark)] {
                let ratio = palette.foreground.contrastRatio(against: palette.selection)
                XCTAssertGreaterThanOrEqual(
                    ratio, ThemeRecipe.minimumTextContrast,
                    """
                    \(theme.name) \(label): selected text \
                    (\(palette.foreground.hexString) on \(palette.selection.hexString)) \
                    is \(String(format: "%.2f", ratio)):1
                    """
                )
            }
        }
    }

    func testCursorIsVisibleAgainstItsBackground() {
        for theme in ThemeCatalog.all {
            for (label, palette) in [("light", theme.light), ("dark", theme.dark)] {
                XCTAssertGreaterThanOrEqual(
                    palette.cursor.contrastRatio(against: palette.background), 3.0,
                    "\(theme.name) \(label) cursor is hard to spot")
            }
        }
    }

    /// `installColors` silently ignores an array that is not exactly 16 long,
    /// which would leave SwiftTerm's dark-tuned defaults in place on a light
    /// background — the original bug, restored invisibly.
    func testEveryPaletteHasExactlySixteenANSISlots() {
        for theme in ThemeCatalog.all {
            XCTAssertEqual(theme.light.ansi.count, 16, "\(theme.name) light")
            XCTAssertEqual(theme.dark.ansi.count, 16, "\(theme.name) dark")
        }
    }

    func testLightAndDarkAppearancesAreActuallyDifferent() {
        for theme in ThemeCatalog.all {
            XCTAssertNotEqual(theme.light.background, theme.dark.background, theme.name)
            XCTAssertLessThan(
                theme.light.background.relativeLuminance, 1.0, theme.name)
            XCTAssertGreaterThan(
                theme.light.background.relativeLuminance,
                theme.dark.background.relativeLuminance,
                "\(theme.name): the light appearance should be the lighter one")
        }
    }
}
