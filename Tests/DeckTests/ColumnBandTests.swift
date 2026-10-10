import XCTest
@testable import Deck

/// What each right-column band draws, decided before a view is involved:
/// which theme each tab resolves, and the inks each band solves to.
///
/// Issue `issue_01M447Y6GWYGJW2Z0QKFCFTVBQ`: every tab draws its own identity.
/// Shell wears the selected session's colour, Local wears graphite, Slate wears
/// the colour of the session it was opened for, and Cockpit stays neutral.
final class ColumnBandTests: XCTestCase {
    private let deck = SessionRef(host: "macstudio", name: "deck")
    private let steward = SessionRef(host: "macmini", name: "steward")

    // MARK: - Theme resolution

    /// A session that nothing has mapped gets its hashed theme, never graphite.
    /// Graphite is the laptop's colour, and a crew wearing it would read as
    /// the laptop.
    func testAnUnmappedCrewNeverResolvesToGraphite() {
        for name in ["deck", "steward", "bosun", "ask", "orient", "deck-coder"] {
            let ref = SessionRef(host: "macstudio", name: name)
            XCTAssertNotEqual(ThemeConfiguration.empty.theme(forSession: ref).name, "graphite",
                              "\(name) resolved to graphite")
        }
    }

    /// The Shell and the Local terminal draw different palettes whenever a
    /// crew is selected: Shell takes the crew's, Local takes graphite's.
    func testShellAndLocalDrawDifferentThemes() {
        let config = ThemeConfiguration.empty
        XCTAssertNotEqual(config.theme(forSession: deck).name,
                          config.theme(forSession: .localShell).name)
    }

    /// The user's own mapping for a crew is still what the Shell draws.
    func testAUserMappingForACrewWinsOverItsHashedDefault() {
        let config = ThemeConfiguration.empty.settingTheme("rose", forSession: deck)
        XCTAssertEqual(config.theme(forSession: deck).name, "rose")
    }

    /// Slate follows the row it was opened for, matched on name and host. A
    /// same-named crew on another host is not that row.
    func testSlateFindsTheRowOnTheSameHostNotTheSameName() {
        let macstudioSteward = SessionRef(host: "macstudio", name: "steward")
        let rows: [(ref: SessionRef, target: SSHTarget?)] = [
            (macstudioSteward, SSHTarget(user: "operator", host: "macstudio")),
            (steward, SSHTarget(user: "operator", host: "macmini")),
        ]
        XCTAssertEqual(
            ContentView.slateRef(session: "steward", target: SSHTarget(user: "operator", host: "macmini"), rows: rows),
            steward)
    }

    /// A sheet can outlive its row. With no row matching, the lookup says so
    /// and the caller falls back to the name's hashed default.
    func testSlateWithNoMatchingRowResolvesNothing() {
        let rows: [(ref: SessionRef, target: SSHTarget?)] = [
            (deck, SSHTarget(user: "operator", host: "macstudio")),
        ]
        XCTAssertNil(ContentView.slateRef(session: "deck", target: SSHTarget(user: "operator", host: "macmini"), rows: rows))
        XCTAssertNil(ContentView.slateRef(session: "gone", target: SSHTarget(user: "operator", host: "macstudio"), rows: rows))
    }

    // MARK: - Graphite

    /// Graphite is the shipped recipe at zero chroma: every palette colour is
    /// grey, so the laptop's pane reads as neutral next to the crews.
    func testGraphiteIsNeutralInBothAppearances() {
        for palette in [ThemeCatalog.graphite.light, ThemeCatalog.graphite.dark] {
            let coloured = [palette.background, palette.foreground, palette.cursor, palette.selection] + palette.ansi
            for rgb in coloured {
                XCTAssertLessThan(rgb.toOKLCH().c, 0.01, "\(rgb.hexString) is not grey")
            }
        }
    }

    /// Graphite clears the same text floors a crew's theme does, so a pane
    /// drawn in it is as readable as any other.
    func testGraphiteClearsTheTextFloors() {
        for (label, palette) in [("light", ThemeCatalog.graphite.light), ("dark", ThemeCatalog.graphite.dark)] {
            XCTAssertGreaterThanOrEqual(
                palette.foreground.contrastRatio(against: palette.background), 7.0, label)
            XCTAssertGreaterThanOrEqual(
                palette.cursor.contrastRatio(against: palette.background), 3.0, label)
            for slot in Array(1...6) + Array(9...14) {
                XCTAssertGreaterThanOrEqual(
                    palette.ansi[slot].contrastRatio(against: palette.background),
                    ThemeRecipe.minimumTextContrast, "\(label) ANSI \(slot)")
            }
        }
    }

    // MARK: - Band inks

    private let allThemes = ThemeCatalog.all + [ThemeCatalog.graphite]

    /// The place line is read on every band, so it clears 4.5:1 on every
    /// surface the bands can draw, in both appearances.
    func testThePlaceLineReachesFourPointFiveOnEveryBand() {
        for appearance in [Appearance.light, .dark] {
            for theme in allThemes {
                let palette = theme.palette(for: appearance)
                let colours = ColumnBandColours.identity(canvas: canvas(palette, appearance), accent: palette.cursor, appearance)
                XCTAssertGreaterThanOrEqual(
                    colours.placeInk.contrastRatio(against: colours.surface), 4.5,
                    "\(theme.name) \(appearance) place line on its band")
            }
            let neutral = ColumnBandColours.neutral(appearance)
            XCTAssertGreaterThanOrEqual(neutral.placeInk.contrastRatio(against: neutral.surface), 4.5,
                                        "neutral place line, \(appearance)")
        }
    }

    /// The icon and the rule are non-text marks, so they need 3:1 against the
    /// band, the same floor the session's own dot is held to.
    func testTheIdentityInkReachesThreeToOneOnEveryBand() {
        for appearance in [Appearance.light, .dark] {
            for theme in allThemes {
                let palette = theme.palette(for: appearance)
                let colours = ColumnBandColours.identity(canvas: canvas(palette, appearance), accent: palette.cursor, appearance)
                XCTAssertGreaterThanOrEqual(
                    colours.ink.contrastRatio(against: colours.surface), ThemeRecipe.markContrast,
                    "\(theme.name) \(appearance) rule on its band")
            }
        }
    }

    /// The neutral band is the only one without a rule, so the two forms
    /// never look alike: an identity band is drawn with its 2pt rule and the
    /// Cockpit keeps the plain separator.
    func testOnlyTheIdentityBandCarriesARule() {
        for appearance in [Appearance.light, .dark] {
            XCTAssertFalse(ColumnBandColours.neutral(appearance).hasRule)
            let palette = ThemeCatalog.graphite.palette(for: appearance)
            XCTAssertTrue(ColumnBandColours.identity(canvas: canvas(palette, appearance),
                                                    accent: palette.cursor, appearance).hasRule)
        }
    }

    /// Shell and Local, drawn in their own colours, have different surfaces,
    /// so the two tabs can be told apart at a glance.
    func testShellAndLocalBandsDiffer() {
        let config = ThemeConfiguration.empty
        for appearance in [Appearance.light, .dark] {
            let shell = config.theme(forSession: deck).palette(for: appearance)
            let local = config.theme(forSession: .localShell).palette(for: appearance)
            let shellBand = ColumnBandColours.identity(canvas: canvas(shell, appearance), accent: shell.cursor, appearance)
            let localBand = ColumnBandColours.identity(canvas: canvas(local, appearance), accent: local.cursor, appearance)
            XCTAssertNotEqual(shellBand.surface, localBand.surface, "\(appearance)")
        }
    }

    /// The canvas the bands are built from, the same maths `ContentView` uses.
    private func canvas(_ palette: TerminalPalette, _ appearance: Appearance) -> RGB {
        palette.background.canvasTint(for: appearance,
                                      lift: ContentView.canvasLift,
                                      chroma: ContentView.canvasChroma)
    }
}
