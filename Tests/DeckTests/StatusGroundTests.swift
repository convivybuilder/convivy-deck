import XCTest
@testable import Deck

/// The Builder Default ground and the inks solved against it.
///
/// Every check reads `StatusGround`, never a literal colour, so changing the
/// one `ground` value (to Builder green `#1d3026`, for one) re-runs the whole
/// set. A test that pinned the hex would fail on that change for the wrong
/// reason, and one that passed on a broken derivation would hide the break.
final class StatusGroundTests: XCTestCase {
    private let ground = StatusGround.ground

    // MARK: - The derived tokens

    /// The raised surface and the divider sit above the ground, and the divider
    /// sits above the raised surface. A derivation that flipped a sign would
    /// put the rail's raised controls below its own ground.
    func testRaisedAndDividerAreLighterThanTheGroundInOrder() {
        let groundL = ground.toOKLCH().l
        let raisedL = StatusGround.raised.toOKLCH().l
        let dividerL = StatusGround.divider.toOKLCH().l
        XCTAssertGreaterThan(raisedL, groundL, "the raised surface must sit above the ground")
        XCTAssertGreaterThan(dividerL, raisedL, "the divider must sit above the raised surface")
    }

    /// The primary ink is readable on both surfaces the text sits on: the
    /// ground, and the raised surface a control draws over it.
    func testPrimaryInkClearsTextContrastOnBothSurfaces() {
        for surface in [ground, StatusGround.raised] {
            XCTAssertGreaterThanOrEqual(
                StatusGround.primaryInk.contrastRatio(against: surface),
                ThemeRecipe.minimumTextContrast,
                "primary ink under-contrasts a status surface")
        }
    }

    // MARK: - The marks and text the status panes draw on the ground

    /// The summons amber, the error red, the warning and the place line are the
    /// inks the rail and the cockpit are scanned by. Each one is solved against
    /// the ground and must still clear its floor there.
    func testStatusInksClearTheirFloorsOnTheGround() {
        XCTAssertGreaterThanOrEqual(
            ThemeRecipe.attentionInk(on: ground).contrastRatio(against: ground),
            ThemeRecipe.markContrast, "summons amber mark")
        XCTAssertGreaterThanOrEqual(
            ThemeRecipe.attentionTextInk(on: ground).contrastRatio(against: ground),
            ThemeRecipe.minimumTextContrast, "summons amber text")
        XCTAssertGreaterThanOrEqual(
            ThemeRecipe.errorInk(on: ground).contrastRatio(against: ground),
            ThemeRecipe.minimumTextContrast, "error red")
        XCTAssertGreaterThanOrEqual(
            ThemeRecipe.warningInk(on: ground).contrastRatio(against: ground),
            ThemeRecipe.minimumTextContrast, "warning")
        XCTAssertGreaterThanOrEqual(
            ThemeRecipe.placeLineInk(on: ground).contrastRatio(against: ground),
            ThemeRecipe.minimumTextContrast, "place line")
        XCTAssertGreaterThanOrEqual(
            ThemeRecipe.workItemChipInk(on: ground).contrastRatio(against: ground),
            ThemeRecipe.minimumTextContrast, "work-item chip")
    }

    /// Every crew hue, drawn the way the rail draws its mark: the session's
    /// theme cursor (`ContentView`'s rail accent, dark palette), solved by
    /// `dotInk` against the row's backing (`RailRow.markBacking`), once on the
    /// ground and once on a selected row, which washes the ground with the hue.
    /// The rail's crew marks sit on this ground, so a later change to `ground`
    /// re-runs every crew here.
    func testEveryCrewMarkClearsMarkContrastOnTheGroundAndOnASelectedRow() {
        for theme in ThemeCatalog.all {
            let accent = theme.palette(for: .dark).cursor
            for isSelected in [false, true] {
                let backing = RailRow.markBacking(appearance: .dark, isSelected: isSelected,
                                                  accent: accent, ground: ground)
                let mark = ThemeRecipe.dotInk(accent: accent, on: backing)
                XCTAssertGreaterThanOrEqual(
                    mark.contrastRatio(against: backing), ThemeRecipe.markContrast,
                    "\(theme.name) crew mark under-contrasts "
                    + (isSelected ? "a selected row" : "the ground"))
            }
        }
    }

    // MARK: - The top bar and the Course strip

    /// The Course strip's passed labels and dots, and its upcoming labels, are
    /// the neutral solved to the text floor on the ground.
    func testCourseStripNeutralInksClearTheTextFloorOnTheGround() {
        XCTAssertGreaterThanOrEqual(
            ThemeRecipe.workItemChipInk(on: ground).contrastRatio(against: ground),
            ThemeRecipe.minimumTextContrast, "course strip passed and upcoming labels")
    }

    /// An upcoming waypoint's hollow mark is non-text, so it clears the mark
    /// floor rather than the text floor. The same solve is what keeps it from
    /// going faint.
    func testUpcomingRouteMarkClearsTheMarkFloorOnTheGround() {
        XCTAssertGreaterThanOrEqual(
            ThemeRecipe.routeMarkInk(on: ground).contrastRatio(against: ground),
            ThemeRecipe.markContrast, "course strip upcoming mark")
    }

    /// The current waypoint's mark and label are solved against the ground
    /// when the crew's hue allows a mark of its own, and fall back to the
    /// primary ink otherwise. Both must clear their floors on the ground.
    func testCurrentWaypointInksClearTheirFloorsOnTheGround() {
        for theme in ThemeCatalog.all {
            let accent = theme.palette(for: .dark).cursor
            if let mark = ThemeRecipe.progressMarkInk(accent: accent, on: ground) {
                XCTAssertGreaterThanOrEqual(mark.contrastRatio(against: ground),
                                            ThemeRecipe.markContrast,
                                            "\(theme.name) current waypoint mark")
            }
            if let text = ThemeRecipe.progressTextInk(accent: accent, on: ground) {
                XCTAssertGreaterThanOrEqual(text.contrastRatio(against: ground),
                                            ThemeRecipe.minimumTextContrast,
                                            "\(theme.name) current waypoint label")
            }
        }
    }

    /// The top bar's host label is the place-line ink, solved against the ground.
    func testTopBarHostLabelClearsTheTextFloorOnTheGround() {
        XCTAssertGreaterThanOrEqual(
            ThemeRecipe.placeLineInk(on: ground).contrastRatio(against: ground),
            ThemeRecipe.minimumTextContrast, "top bar host label")
    }

    // MARK: - The cockpit on its frame tint

    /// The composer's frame tint for each catalog theme's session, in the light
    /// scheme the cockpit draws in under Builder Default. The canvas comes from
    /// `ContentView.paneCanvas`, the call `cockpitFrameGround` makes, so this is
    /// the colour the cockpit actually takes.
    private var frameTints: [(name: String, tint: RGB)] {
        ThemeCatalog.all.compactMap { theme in
            let canvas = ContentView.paneCanvas(for: theme.palette(for: .light), appearance: .light)
            guard let tint = SessionPaneView.frameTintRGB(canvas: canvas.hexString, appearance: .light) else {
                return nil
            }
            return (theme.name, tint)
        }
    }

    /// The cockpit's primary ink and its place line, solved on the frame tint,
    /// clear the text floor for every theme. The neutral band's ink is the
    /// cockpit's only solved primary ink, so this runs the real band constructor.
    func testCockpitInksClearTheirFloorsOnTheFrameTint() {
        XCTAssertFalse(frameTints.isEmpty)
        for (name, tint) in frameTints {
            let band = ColumnBandColours.neutral(.light, ground: tint)
            XCTAssertGreaterThanOrEqual(band.ink.contrastRatio(against: tint),
                                        ThemeRecipe.minimumTextContrast, "\(name) cockpit primary ink")
            XCTAssertGreaterThanOrEqual(band.placeInk.contrastRatio(against: tint),
                                        ThemeRecipe.minimumTextContrast, "\(name) cockpit place line")
            XCTAssertGreaterThanOrEqual(ThemeRecipe.attentionTextInk(on: tint).contrastRatio(against: tint),
                                        ThemeRecipe.minimumTextContrast, "\(name) cockpit summons text")
            XCTAssertGreaterThanOrEqual(ThemeRecipe.errorInk(on: tint).contrastRatio(against: tint),
                                        ThemeRecipe.minimumTextContrast, "\(name) cockpit error")
            XCTAssertGreaterThanOrEqual(ThemeRecipe.warningInk(on: tint).contrastRatio(against: tint),
                                        ThemeRecipe.minimumTextContrast, "\(name) cockpit warning")
            XCTAssertGreaterThanOrEqual(ThemeRecipe.workItemChipInk(on: tint).contrastRatio(against: tint),
                                        ThemeRecipe.minimumTextContrast, "\(name) cockpit chip")
            XCTAssertGreaterThanOrEqual(ThemeRecipe.secondaryTextInk(on: tint).contrastRatio(against: tint),
                                        ThemeRecipe.minimumTextContrast, "\(name) cockpit secondary text")
            XCTAssertGreaterThanOrEqual(ThemeRecipe.neutralMarkInk(on: tint).contrastRatio(against: tint),
                                        ThemeRecipe.markContrast, "\(name) cockpit disclosure mark")
        }
    }

    /// The dark-ground primary ink is the one the cockpit used before the frame
    /// tint. On the light tint it cannot read, so a band that kept it would fail
    /// the floor above. Checking that here keeps the floor test from passing on
    /// an ink that was never tested against the light surface.
    func testTheStatusGroundPrimaryInkCannotReadOnTheFrameTint() {
        for (name, tint) in frameTints {
            XCTAssertLessThan(StatusGround.primaryInk.contrastRatio(against: tint),
                              ThemeRecipe.minimumTextContrast, "\(name) would keep the old ink")
        }
    }

    /// The frame tint is a light surface, not the status ground. A cockpit that
    /// drew the ground again would fail here.
    func testTheFrameTintIsNotTheStatusGround() {
        for (name, tint) in frameTints {
            XCTAssertNotEqual(tint, ground, "\(name) frame tint must not be the status ground")
            XCTAssertGreaterThan(tint.toOKLCH().l, 0.5, "\(name) frame tint should be light")
        }
    }

    // MARK: - Helpers that take the ground

    /// The rail's mark backing is the ground under Builder Default, so an
    /// unselected row's backing is the ground itself. A selected row washes the
    /// ground with the session's accent at 15%, the same wash the old
    /// approximation used.
    func testMarkBackingIsTheGroundWhenTheRailDrawsOnIt() {
        let accent = parseHexColor("e1901f")!
        XCTAssertEqual(RailRow.markBacking(appearance: .dark, isSelected: false,
                                           accent: accent, ground: ground), ground)
        let selected = RailRow.markBacking(appearance: .dark, isSelected: true,
                                           accent: accent, ground: ground)
        XCTAssertEqual(selected.red, ground.red + (accent.red - ground.red) * 0.15, accuracy: 1e-9)
        XCTAssertEqual(selected.green, ground.green + (accent.green - ground.green) * 0.15, accuracy: 1e-9)
        XCTAssertEqual(selected.blue, ground.blue + (accent.blue - ground.blue) * 0.15, accuracy: 1e-9)
    }

    /// With no ground passed, the mark backing keeps the hand-written
    /// approximation it has always had. System, Light and Dark rely on it.
    func testMarkBackingWithoutAGroundKeepsTheSystemApproximation() {
        let accent = parseHexColor("e1901f")!
        XCTAssertEqual(RailRow.markBacking(appearance: .dark, isSelected: false, accent: accent),
                       RGB(red: 0.16, green: 0.16, blue: 0.17))
        XCTAssertNotEqual(RailRow.markBacking(appearance: .dark, isSelected: false,
                                              accent: accent), ground)
    }

    func testResolvedIndexSurfaceIsTheGroundWhenGiven() {
        XCTAssertEqual(CockpitView.resolvedIndexSurface(appearance: .dark, ground: ground), ground)
        XCTAssertEqual(CockpitView.resolvedIndexSurface(appearance: .dark),
                       RGB(red: 0.12, green: 0.12, blue: 0.13))
    }

    /// The neutral band takes the ground as its fill and the primary ink as its
    /// icon ink. Without a ground it keeps the system colours it always drew.
    func testNeutralBandDrawsOnTheGroundWithThePrimaryInk() {
        let onGround = ColumnBandColours.neutral(.dark, ground: ground)
        XCTAssertEqual(onGround.surface, ground)
        XCTAssertEqual(onGround.ink, StatusGround.primaryInk)
        XCTAssertEqual(onGround.placeInk, ThemeRecipe.placeLineInk(on: ground))

        let system = ColumnBandColours.neutral(.dark)
        XCTAssertNotEqual(system.surface, ground)
        XCTAssertNotEqual(system.ink, StatusGround.primaryInk)
    }
}
