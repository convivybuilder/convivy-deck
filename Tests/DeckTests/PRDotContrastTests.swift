import XCTest
@testable import Deck

/// `ThemeRecipe.prDotInk` against the surface it actually draws on
/// (`CockpitView.resolvedIndexSurface`) — the PR ladder's stoplight dot has no
/// crew hue to fall back on, so every value in it is a fixed colour that must
/// individually clear the mark-legibility floor, in both appearances.
///
/// The operator's 2026-09-16 revision split the old single "in flight" amber into a
/// brown (`inCI`) and an amber (`inReview`), and moved `closed` off red onto
/// the shell's own text ink — both changes this file exists to hold, since a
/// pure-mapping test (`PRLadderRowTests`) cannot see whether two colours are
/// actually told apart.
///
/// `StatusGround.ground` appears below as a fixed value to solve against, not
/// as a claim about where the PR ladder draws: that ground belongs to the
/// rail, the strip and the chrome. The cockpit's own ground under Builder
/// Default is `realCockpitGrounds`, the frame tint `ContentView.columnPin`
/// actually pins it to.
final class PRDotContrastTests: XCTestCase {

    private let allColors: [PRLadderRow.DotColor] = [
        .merged, .ready, .closed, .failedCI, .inCI, .inReview, .draftOrUnknown,
    ]

    private func surface(_ appearance: Appearance) -> RGB {
        CockpitView.resolvedIndexSurface(appearance: appearance)
    }

    func testEveryDotColorClearsMarkContrastInBothAppearances() {
        for appearance in [Appearance.light, .dark] {
            for color in allColors {
                let ink = ThemeRecipe.prDotInk(color, appearance: appearance, on: surface(appearance))
                let ratio = ink.contrastRatio(against: surface(appearance))
                XCTAssertGreaterThanOrEqual(
                    ratio, ThemeRecipe.markContrast,
                    "\(color) under-contrasts the cockpit surface in \(appearance): \(ratio)")
            }
        }
    }

    /// The Builder Default ground is the one the status panes draw on, and
    /// every dot must clear the mark floor on it, including the four GitHub
    /// values that do not on their own.
    func testEveryDotColorClearsMarkContrastOnTheBuilderDefaultGround() {
        let ground = StatusGround.ground
        for color in allColors {
            let ink = ThemeRecipe.prDotInk(color, appearance: .dark, on: ground)
            XCTAssertGreaterThanOrEqual(
                ink.contrastRatio(against: ground), ThemeRecipe.markContrast,
                "\(color) under-contrasts the Builder Default ground: \(ink.contrastRatio(against: ground))")
        }
    }

    /// The lift only moves a dot that fails, with one named exception: `.ready`
    /// always moves, because its GitHub green clears `markContrast` on every
    /// ground this file or `CockpitFrameTintInkTests` measures while still
    /// reading too close to the grey draft dot (`ΔE` 0.16, see
    /// `testReadyClearsAMinimumSeparationFromDraftOnTheRealCockpitGround`), so
    /// gating its lift on contrast alone never fires where it is needed.
    /// A dot that already clears keeps its GitHub value exactly, so the
    /// system dark ground draws as it did. Both directions: on the system
    /// ground nothing but ready moves, and on the Builder ground the four
    /// failing values move, lighter, with hue kept.
    func testOnlyDotsBelowTheFloorAreLiftedAndTheirHueIsKept() {
        let systemDark = surface(.dark)
        for color in allColors where color != .ready {
            let base = ThemeRecipe.primerInk(color, appearance: .dark)
            XCTAssertEqual(ThemeRecipe.prDotInk(color, appearance: .dark, on: systemDark), base,
                           "\(color) moved on the system dark ground, where it already clears")
        }

        let ground = StatusGround.ground
        for color in allColors {
            let base = ThemeRecipe.primerInk(color, appearance: .dark)
            let lifted = ThemeRecipe.prDotInk(color, appearance: .dark, on: ground)
            if base.contrastRatio(against: ground) >= ThemeRecipe.markContrast {
                XCTAssertEqual(lifted, base, "\(color) already clears and must not move")
                continue
            }
            XCTAssertGreaterThan(lifted.toOKLCH().l, base.toOKLCH().l,
                                 "\(color) must lift lighter on the Builder Default ground")
            let hueDrift = abs(lifted.toOKLCH().h - base.toOKLCH().h)
            XCTAssertLessThan(min(hueDrift, 360 - hueDrift), 2,
                              "\(color) must keep its hue when it lifts")
        }
    }

    /// The light appearance draws GitHub's values as written, on the cockpit
    /// surface — except `.ready`, which always lifts past its GitHub value
    /// (see `testOnlyDotsBelowTheFloorAreLiftedAndTheirHueIsKept`). Pinned to
    /// the hex values, so a change to the light lift (or to the surface it is
    /// solved on) fails here rather than moving light dots.
    func testLightDotsKeepTheirPrimerValues() {
        let expected: [PRLadderRow.DotColor: String] = [
            .merged: "8250df", .closed: "1F2328", .failedCI: "cf222e",
            .inCI: "7d481f", .inReview: "b78a23", .draftOrUnknown: "59636e",
        ]
        for (color, hex) in expected {
            XCTAssertEqual(ThemeRecipe.prDotInk(color, appearance: .light, on: surface(.light)),
                           parseHexColor(hex)!, "\(color) light dot moved from \(hex)")
        }
    }

    /// Brown (`inCI`, a build still running) and amber (`inReview`, a human
    /// still reading) must be told apart at a glance in both appearances —
    /// the whole reason they were split out of one shared amber.
    func testInCIAndInReviewAreDistinctInBothAppearances() {
        for appearance in [Appearance.light, .dark] {
            let brown = ThemeRecipe.prDotInk(.inCI, appearance: appearance, on: surface(appearance))
            let amber = ThemeRecipe.prDotInk(.inReview, appearance: appearance, on: surface(appearance))
            XCTAssertGreaterThanOrEqual(
                brown.contrastRatio(against: amber), 1.4,
                "brown and amber read as the same colour in \(appearance)")
        }
    }

    /// `closed` (the shell's text ink) must stay clearly distinct from
    /// `draftOrUnknown` (grey) in both appearances — closed took over the
    /// ink slot right next to grey once red moved to `failedCI`.
    func testClosedIsDistinctFromDraftInBothAppearances() {
        for appearance in [Appearance.light, .dark] {
            let closed = ThemeRecipe.prDotInk(.closed, appearance: appearance, on: surface(appearance))
            let draft = ThemeRecipe.prDotInk(.draftOrUnknown, appearance: appearance, on: surface(appearance))
            XCTAssertGreaterThanOrEqual(
                closed.contrastRatio(against: draft), 1.4,
                "closed and draft read as the same colour in \(appearance)")
        }
    }

    /// `merged` is untouched by this revision — pinned so a future change to
    /// the shared enum cannot silently move it. Read on the system ground,
    /// where it already clears and needs no lift.
    func testMergedIsUnchanged() {
        XCTAssertEqual(ThemeRecipe.prDotInk(.merged, appearance: .light, on: surface(.light)), parseHexColor("8250df")!)
        XCTAssertEqual(ThemeRecipe.prDotInk(.merged, appearance: .dark, on: surface(.dark)), parseHexColor("8957e5")!)
    }

    /// `ready` always lifts past its GitHub value, on every ground, because
    /// the value already clears `markContrast` everywhere this file measures
    /// while still reading too close to the grey draft dot (see
    /// `testReadyClearsAMinimumSeparationFromDraftOnTheRealCockpitGround` and
    /// `testReadyClearsAMinimumSeparationFromDraftOnTheSystemFallbackGrounds`,
    /// which measure that the lift was needed on each ground rather than only
    /// pinning its result). Pinned to the lifted hex on both system-fallback
    /// grounds, so a regression back to the old "only lift when contrast
    /// fails" gate moves these values and fails here.
    func testReadyAlwaysLiftsPastItsPrimerValue() {
        XCTAssertEqual(ThemeRecipe.prDotInk(.ready, appearance: .light, on: surface(.light)).hexString, "#01a543")
        XCTAssertEqual(ThemeRecipe.prDotInk(.ready, appearance: .dark, on: surface(.dark)).hexString, "#4ad862")
    }

    /// OKLab Euclidean distance (`ΔE`), the plain measure of "do two colours
    /// look different" — the ladder's inks already round-trip through OKLCH,
    /// so converting to OKLab's Cartesian `a`/`b` costs nothing more than
    /// `cos`/`sin` of the hue already on hand.
    private func deltaE(_ a: RGB, _ b: RGB) -> Double {
        func lab(_ c: RGB) -> (l: Double, a: Double, b: Double) {
            let oklch = c.toOKLCH()
            let radians = oklch.h * .pi / 180
            return (oklch.l, oklch.c * cos(radians), oklch.c * sin(radians))
        }
        let x = lab(a), y = lab(b)
        return ((x.l - y.l) * (x.l - y.l) + (x.a - y.a) * (x.a - y.a) + (x.b - y.b) * (x.b - y.b)).squareRoot()
    }

    /// The grounds the cockpit's PR list actually draws its dots on under
    /// Builder Default: the selected session's frame tint, light appearance
    /// (`ContentView.columnPin` -> `cockpitFrameGround`, the same two calls
    /// `CockpitFrameTintInkTests.frameTints` measures), one per catalog theme,
    /// plus the system window colour the cockpit falls back to with no
    /// session selected. Round 1 review found the first version of this test
    /// read `StatusGround.ground` instead — that ground belongs to the rail,
    /// the strip and the chrome; the cockpit, and the run pane it opens, never
    /// pin to it (`ContentView.columnPin`'s `drawsOnCockpitGround` branch
    /// passes `cockpitFrameGround`, not `StatusGround.ground`).
    private var realCockpitGrounds: [(name: String, ground: RGB)] {
        let frameTints = ThemeCatalog.all.map { theme -> (name: String, ground: RGB) in
            let canvas = ContentView.paneCanvas(for: theme.palette(for: .light), appearance: .light)
            let ground = SessionPaneView.frameTintRGB(canvas: canvas.hexString, appearance: .light)!
            return (theme.name, ground)
        }
        let noSelection = ("no selection", ColumnBandColours.systemRGB(.windowBackgroundColor, .light))
        return frameTints + [noSelection]
    }

    /// The operator, 2026-10-07: "gray and green look the same" — on every real
    /// cockpit ground (`realCockpitGrounds`), the ready dot and the draft dot
    /// measured 0.16 ΔE apart, because `primerReadyLight` (`#1f883d`) already
    /// clears `markContrast` on all of them, so the old `.ready` branch — only
    /// reached when the base value under-contrasts — never ran where the
    /// confusion actually is. This pins a floor above that failure and below
    /// where the fix lands (~0.23), and fails on the pre-fix code: reverting
    /// `prDotInk` to gate `.ready`'s lift behind the `base.contrastRatio(...)
    /// < markContrast` guard reproduces the 0.16 ΔE and fails every iteration
    /// of this loop.
    func testReadyClearsAMinimumSeparationFromDraftOnTheRealCockpitGround() {
        let minimumSeparation = 0.22
        for (name, ground) in realCockpitGrounds {
            let ready = ThemeRecipe.prDotInk(.ready, appearance: .light, on: ground)
            let draft = ThemeRecipe.prDotInk(.draftOrUnknown, appearance: .light, on: ground)
            XCTAssertGreaterThanOrEqual(
                ready.contrastRatio(against: ground), ThemeRecipe.markContrast,
                "\(name): ready under-contrasts its ground")
            XCTAssertGreaterThanOrEqual(
                deltaE(ready, draft), minimumSeparation,
                "\(name): ready and draft read as the same colour: ΔE \(deltaE(ready, draft))")
        }
    }

    /// Round 2 review: the same confusion `realCockpitGrounds` measures also
    /// shows up on the two grounds `CockpitView.resolvedIndexSurface` falls
    /// back to with no session selected — reached under System (light/dark
    /// sub-mode) and under the plain Light/Dark presets, none of which pin to
    /// `cockpitFrameGround`. Confirmed by reverting `prDotInk` to gate
    /// `.ready`'s lift behind `base.contrastRatio(...) < markContrast` and
    /// rerunning: both fallback grounds clear that guard, so the base Primer
    /// value drew unmodified before this fix, at light fallback (`#fafafa`)
    /// ΔE 0.1615, dark fallback (`#1f1f21`) ΔE 0.1561 — the same ~0.16
    /// confusion the Builder Default ground showed. With the fix restored,
    /// ΔE lands at 0.2305 (light) and 0.3004 (dark). So the unconditional
    /// lift belongs on both grounds, not only under Builder Default.
    func testReadyClearsAMinimumSeparationFromDraftOnTheSystemFallbackGrounds() {
        let minimumSeparation = 0.22
        for appearance in [Appearance.light, .dark] {
            let ground = surface(appearance)
            let ready = ThemeRecipe.prDotInk(.ready, appearance: appearance, on: ground)
            let draft = ThemeRecipe.prDotInk(.draftOrUnknown, appearance: appearance, on: ground)
            XCTAssertGreaterThanOrEqual(
                ready.contrastRatio(against: ground), ThemeRecipe.markContrast,
                "\(appearance): ready under-contrasts its ground")
            XCTAssertGreaterThanOrEqual(
                deltaE(ready, draft), minimumSeparation,
                "\(appearance): ready and draft read as the same colour: ΔE \(deltaE(ready, draft))")
        }
    }
}
