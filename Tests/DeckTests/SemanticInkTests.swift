import XCTest
import AppKit
@testable import Deck

/// The semantic inks and the session-dot vocabulary, solved against the surfaces
/// they are actually drawn on, across every theme and both appearances.
///
/// WHY THIS IS A SWEEP AND NOT A SPOT CHECK. The requirement is not "the colour
/// looks right"; it is that the one mark a reader scans for survives being drawn
/// over ten different session accents in two appearances. A single-theme
/// assertion would have passed happily while the rose and ember themes failed,
/// and those are exactly the ones nearest the attention hue.
///
/// THE SWEEP NOW COVERS THE ACCENTS THEMSELVES, which it did not need to while
/// the dot was only identity. A circle is a circle at any contrast; a square
/// told apart from a notched disc is not. Moving state onto the identity dot
/// made every session's own colour load-bearing, and the sweep found sage at
/// 2.85:1 on a selected light row the first time it looked.
final class SemanticInkTests: XCTestCase {

    /// The WCAG floor for body text. Still what the inks that carry TEXT are
    /// held to — the error and warning inks letter a status line.
    private let target = 4.5

    /// Every surface an ink is drawn on, per theme and appearance.
    private func surfaces(for theme: TerminalTheme, _ appearance: Appearance) -> [(String, RGB)] {
        let canvas = theme.palette(for: appearance).background
        let hex = String(format: "#%02x%02x%02x",
                         Int((canvas.red * 255).rounded()),
                         Int((canvas.green * 255).rounded()),
                         Int((canvas.blue * 255).rounded()))
        var found: [(String, RGB)] = []
        if let tint = SessionPaneView.frameTintRGB(canvas: hex, appearance: appearance) {
            found.append(("frame tint", tint))
        }
        // The rail's own backing, and that backing under the selection wash —
        // the wash is the session's accent, so it is the worse of the two and
        // the one an accent-coloured mark could disappear into.
        let accent = theme.palette(for: appearance).cursor
        found.append(("rail", RailRow.markBacking(
            appearance: appearance, isSelected: false, accent: accent)))
        found.append(("rail selected", RailRow.markBacking(
            appearance: appearance, isSelected: true, accent: accent)))
        return found
    }

    /// The rail's real backing, from AppKit, resolved per appearance.
    ///
    /// THE INDEPENDENT GROUND TRUTH, and the whole reason this test bites. The
    /// ink is SOLVED against what the view believes the surface is
    /// (`RailRow.markBacking`) and MEASURED against what the surface actually
    /// is. Solving and measuring against the same function is self-consistent
    /// whatever that function returns — which is why the first attempt at this
    /// test passed happily with the dark-mode bug reintroduced.
    private func realRailBacking(_ appearance: Appearance) -> RGB {
        let name: NSAppearance.Name = appearance == .dark ? .darkAqua : .aqua
        let previous = NSAppearance.current
        NSAppearance.current = NSAppearance(named: name)
        defer { NSAppearance.current = previous }
        let resolved = NSColor.controlBackgroundColor
            .usingColorSpace(.sRGB) ?? NSColor.white
        return RGB(red: Double(resolved.redComponent),
                   green: Double(resolved.greenComponent),
                   blue: Double(resolved.blueComponent))
    }

    func testTheRailMarkClearsAgainstTheSurfaceItIsActuallyDrawnOn() {
        // Solved against the view's belief, measured against AppKit's reality.
        // They agree only if `markBacking` branches on appearance — it did not,
        // and dark mode drew about 2.7:1. Caught by deck-reviewer.
        //
        // ASSERTED AT `markContrast`, WHICH IS LOWER THAN THIS MEASURES. The
        // bar used to read 4.0 against an ink solved to 4.5, and the marks now
        // solve to 3:1 — the measurement did not move much (it bottoms out
        // around 4.1, because the real control background is lighter than the
        // 0.92 the view assumes, which flatters a dark-solved ink) but the
        // PROMISE did. Pinning the incidental headroom instead of the promise
        // would fail a future change that legitimately lands at 3.5. The bug
        // this test exists for drew 2.7:1 and still fails this bar.
        //
        // BOTH ENDS OF THE STALENESS RAMP, since chroma moves and the solver
        // has to hold the line at either end.
        var worst = Double.infinity
        var worstWhere = ""
        for theme in ThemeCatalog.all {
            for appearance in [Appearance.light, .dark] {
                let accent = theme.palette(for: appearance).cursor
                for selected in [false, true] {
                    for staleness in [0.0, 0.5, 1.0] {
                        let believed = RailRow.markBacking(
                            appearance: appearance, isSelected: selected, accent: accent)
                        let ink = ThemeRecipe.attentionInk(on: believed, staleness: staleness)
                        let ratio = ink.contrastRatio(against: realRailBacking(appearance))
                        if ratio < worst {
                            worst = ratio
                            worstWhere = """
                                \(theme.name)/\(appearance)/selected=\(selected)/\
                                staleness=\(staleness)
                                """
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(
            worst, ThemeRecipe.markContrast,
            "the rail mark bottoms out at \(String(format: "%.2f", worst)):1 on \(worstWhere)")
    }

    private func assertClears(_ ink: (RGB) -> RGB, _ name: String,
                              floor: Double? = nil) {
        let target = floor ?? self.target
        var worst = Double.infinity
        var worstWhere = ""
        for theme in ThemeCatalog.all {
            for appearance in [Appearance.light, .dark] {
                for (surface, rgb) in surfaces(for: theme, appearance) {
                    let ratio = ink(rgb).contrastRatio(against: rgb)
                    if ratio < worst {
                        worst = ratio
                        worstWhere = "\(theme.name)/\(appearance)/\(surface)"
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(
            worst, target,
            "\(name) bottoms out at \(String(format: "%.2f", worst)):1 on \(worstWhere)")
    }

    func testTheAttentionInkClearsOnEverySurfaceItIsDrawnOn() {
        // The mark that says "go here". It is drawn on the rail, on the rail
        // under a selection wash of the session's own accent, and in the live
        // bar on the frame tint.
        //
        // AT BOTH ENDS OF THE STALENESS RAMP. The ramp spends chroma, and the
        // whole reason it spends chroma rather than lightness is that the
        // solver's promise has to survive it — a gate that has been standing
        // fifteen minutes must not be harder to see than a fresh one.
        assertClears({ ThemeRecipe.attentionInk(on: $0) },
                     "attentionInk", floor: ThemeRecipe.markContrast)
        assertClears({ ThemeRecipe.attentionInk(on: $0, staleness: 1) },
                     "attentionInk (fully stale)", floor: ThemeRecipe.markContrast)
    }

    func testEverySessionAccentIsLegibleAsAShapeOnTheRail() {
        // THE CHECK THAT REPLACED `machineryInk`. State used to be a separate
        // neutral mark with its own solved ink; now it rides on the identity
        // dot, so what has to survive the rail is the SESSION'S OWN colour,
        // which is not solved against anything — it must equal that session's
        // canvas and terminal, a property tested elsewhere.
        //
        // MEASURED ON THE RAW ACCENT FIRST, TO SHOW WHY `dotInk` EXISTS. Each
        // theme's cursor is solved to 3:1 against THAT THEME'S canvas, which is
        // not the rail. Sage on a selected light row measures 2.85:1 raw — the
        // selected case being hardest because the wash under the dot is the
        // dot's own hue.
        var worstRaw = Double.infinity
        var worst = Double.infinity
        var worstWhere = ""
        for theme in ThemeCatalog.all {
            for appearance in [Appearance.light, .dark] {
                let accent = theme.palette(for: appearance).cursor
                for selected in [false, true] {
                    let backing = RailRow.markBacking(
                        appearance: appearance, isSelected: selected, accent: accent)
                    worstRaw = min(worstRaw, accent.contrastRatio(against: backing))
                    let ratio = ThemeRecipe.dotInk(accent: accent, on: backing)
                        .contrastRatio(against: backing)
                    if ratio < worst {
                        worst = ratio
                        worstWhere = "\(theme.name)/\(appearance)/selected=\(selected)"
                    }
                }
            }
        }
        XCTAssertLessThan(worstRaw, ThemeRecipe.markContrast,
                          "no accent falls short any more, so `dotInk` is dead weight")
        XCTAssertGreaterThanOrEqual(
            worst, ThemeRecipe.markContrast,
            "a session dot bottoms out at \(String(format: "%.2f", worst)):1 on \(worstWhere)")
    }

    func testTheDotKeepsItsSessionsHueAndOnlyMovesWhenItMust() {
        // What identity means here is "recognisable as this session's colour",
        // which hue carries. A solve that shifted hue would trade the thing the
        // dot is FOR to fix how it reads, and the accents that already clear
        // must come back untouched rather than nudged in sympathy.
        for theme in ThemeCatalog.all {
            for appearance in [Appearance.light, .dark] {
                let accent = theme.palette(for: appearance).cursor
                for selected in [false, true] {
                    let backing = RailRow.markBacking(
                        appearance: appearance, isSelected: selected, accent: accent)
                    let ink = ThemeRecipe.dotInk(accent: accent, on: backing)
                    let where_ = "\(theme.name)/\(appearance)/selected=\(selected)"

                    XCTAssertLessThan(hueGap(ink.toOKLCH().h, accent.toOKLCH().h), 3,
                                      "the dot changed hue on \(where_)")
                    if accent.contrastRatio(against: backing) >= ThemeRecipe.markContrast {
                        XCTAssertEqual(ink.red, accent.red, accuracy: 0.001, where_)
                        XCTAssertEqual(ink.green, accent.green, accuracy: 0.001, where_)
                        XCTAssertEqual(ink.blue, accent.blue, accuracy: 0.001, where_)
                    }
                }
            }
        }
    }

    func testTheListeningPulseClearsTheFloorAtBothEnds() {
        // Sometimes a selected crew's bar is so close to its icon's
        // colour that you can't tell if the dot is pulsing. The second phase
        // used to be `dotInk` at a fixed 35% opacity — a blend toward
        // `surface` that carries no contrast promise at all. Measured before
        // this fix, it bottomed out around 1.43:1 on a selected light row,
        // under half `markContrast`. Both ends are solved now, so both must
        // clear it.
        var worst = Double.infinity
        var worstWhere = ""
        for theme in ThemeCatalog.all {
            for appearance in [Appearance.light, .dark] {
                let accent = theme.palette(for: appearance).cursor
                for selected in [false, true] {
                    let backing = RailRow.markBacking(
                        appearance: appearance, isSelected: selected, accent: accent)
                    for (phase, ink) in [
                        ("full", ThemeRecipe.dotInk(accent: accent, on: backing)),
                        ("second", ThemeRecipe.pulseDotInk(accent: accent, on: backing)),
                    ] {
                        let ratio = ink.contrastRatio(against: backing)
                        if ratio < worst {
                            worst = ratio
                            worstWhere = "\(theme.name)/\(appearance)/selected=\(selected)/\(phase)"
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(
            worst, ThemeRecipe.markContrast,
            "the listening pulse bottoms out at \(String(format: "%.2f", worst)):1 on \(worstWhere)")
    }

    func testTheListeningPulseAlwaysMovesTheSameDirection() {
        // The bug this fixes: `dimDotInk` dimmed on 11 of the 40 theme/
        // appearance/selection combinations and brightened on the other 29,
        // because it tried to dim toward `surface` first and only fell back
        // to brightening where dimming could not clear `markContrast`. So
        // which way the pulse moved depended on which theme happened to be
        // showing — a real bug that both floor checks above are structurally
        // unable to see, since they only ever look at one end's contrast in
        // isolation. `pulseDotInk` now always walks away from `surface`, so
        // the pulse's contrast must never fall below the resting phase's, on
        // every combination.
        for theme in ThemeCatalog.all {
            for appearance in [Appearance.light, .dark] {
                let accent = theme.palette(for: appearance).cursor
                for selected in [false, true] {
                    let backing = RailRow.markBacking(
                        appearance: appearance, isSelected: selected, accent: accent)
                    let fullRatio = ThemeRecipe.dotInk(accent: accent, on: backing)
                        .contrastRatio(against: backing)
                    let pulseRatio = ThemeRecipe.pulseDotInk(accent: accent, on: backing)
                        .contrastRatio(against: backing)
                    XCTAssertGreaterThanOrEqual(
                        pulseRatio, fullRatio,
                        """
                        \(theme.name)/\(appearance)/selected=\(selected) dimmed \
                        (\(String(format: "%.2f", pulseRatio)):1 < \
                        \(String(format: "%.2f", fullRatio)):1) instead of brightening
                        """)
                }
            }
        }
    }

    func testTheListeningPulseIsPerceptibleOnEveryTheme() {
        // A pulse that clears the floor at both ends but barely moves has
        // traded one invisible state for another — the failure mode this test
        // exists to catch in a later change that satisfies contrast by
        // collapsing the two ends toward each other. Every theme, appearance
        // and selection state must swing by the full `pulseLightnessStep`.
        var worst = Double.infinity
        var worstWhere = ""
        for theme in ThemeCatalog.all {
            for appearance in [Appearance.light, .dark] {
                let accent = theme.palette(for: appearance).cursor
                for selected in [false, true] {
                    let backing = RailRow.markBacking(
                        appearance: appearance, isSelected: selected, accent: accent)
                    let full = ThemeRecipe.dotInk(accent: accent, on: backing).toOKLCH()
                    let pulse = ThemeRecipe.pulseDotInk(accent: accent, on: backing).toOKLCH()
                    let gap = abs(full.l - pulse.l)
                    if gap < worst {
                        worst = gap
                        worstWhere = "\(theme.name)/\(appearance)/selected=\(selected)"
                    }
                }
            }
        }
        // A hair under the nominal step: the sRGB gamut round-trip in `toRGB`
        // can shave a thousandth or two off the raw lightness delta.
        XCTAssertGreaterThanOrEqual(
            worst, ThemeRecipe.pulseLightnessStep - 0.005,
            "the listening pulse barely moves (\(String(format: "%.3f", worst)) L) on \(worstWhere)")
    }

    func testTheSecondPulseInkKeepsItsSessionsHue() {
        // Same requirement as `dotInk`: identity is the session's hue, and the
        // second phase must carry it too rather than drifting toward a
        // generic muted grey.
        for theme in ThemeCatalog.all {
            for appearance in [Appearance.light, .dark] {
                let accent = theme.palette(for: appearance).cursor
                for selected in [false, true] {
                    let backing = RailRow.markBacking(
                        appearance: appearance, isSelected: selected, accent: accent)
                    let pulse = ThemeRecipe.pulseDotInk(accent: accent, on: backing)
                    let where_ = "\(theme.name)/\(appearance)/selected=\(selected)"

                    XCTAssertLessThan(hueGap(pulse.toOKLCH().h, accent.toOKLCH().h), 3,
                                      "the second pulse ink changed hue on \(where_)")
                }
            }
        }
    }

    func testAStandingGateIntensifiesWithoutGettingHarderToSee() {
        // "3 is amber, getting amberer over time" — and the constraint that
        // makes it safe is that the ramp cannot spend the thing the mark is
        // solved for.
        let surface = RGB(red: 0.92, green: 0.92, blue: 0.93)
        let fresh = ThemeRecipe.attentionInk(on: surface).toOKLCH()
        let stale = ThemeRecipe.attentionInk(on: surface, staleness: 1).toOKLCH()

        XCTAssertGreaterThan(stale.c, fresh.c, "an aged gate must read louder")
        XCTAssertLessThan(abs(stale.h - fresh.h), 3, "it must stay the same colour")
    }

    func testTheStalenessRampIsFlatThenClimbsAndStops() {
        // nil is fresh, not stale: an age the mini could not establish must not
        // manufacture urgency.
        XCTAssertEqual(ThemeRecipe.staleness(gateAge: nil), 0)
        XCTAssertEqual(ThemeRecipe.staleness(gateAge: 0), 0)
        XCTAssertEqual(ThemeRecipe.staleness(gateAge: 60), 0, "a fresh gate is not aging yet")
        XCTAssertEqual(ThemeRecipe.staleness(gateAge: 100_000), 1, "and it tops out")

        // Monotone in between, so the mark never brightens and then dims.
        var previous = 0.0
        for age in stride(from: 0.0, through: 1200.0, by: 30.0) {
            let now = ThemeRecipe.staleness(gateAge: age)
            XCTAssertGreaterThanOrEqual(now, previous, "the ramp went backwards at \(age)s")
            previous = now
        }
    }

    func testTheErrorInkClears() {
        // System `.orange` over the light frame tint measured 2.11:1 — the one
        // colour that must be read the instant it appears was the least readable
        // thing on the surface.
        assertClears(ThemeRecipe.errorInk(on:), "errorInk")
    }

    func testTheWarningInkClears() {
        assertClears(ThemeRecipe.warningInk(on:), "warningInk")
    }

    func testTheThreeInksStayTellableApart() {
        // MEASURED BY HUE, NOT BY CONTRAST, and the first draft of this test got
        // that wrong. All three are solved to the same ratio against the same
        // surface, so by construction they have near-identical luminance — a
        // contrast comparison between them reads ~1.03:1 and says nothing about
        // whether a reader can tell them apart. Hue is the channel that
        // separates them, so hue is what to assert.
        let surface = RGB(red: 0.92, green: 0.92, blue: 0.93)
        let attention = ThemeRecipe.attentionInk(on: surface).toOKLCH()
        let error = ThemeRecipe.errorInk(on: surface).toOKLCH()
        let warning = ThemeRecipe.warningInk(on: surface).toOKLCH()

        // A failure must never be mistaken for either standing state.
        XCTAssertGreaterThan(hueGap(error.h, attention.h), 25,
                             "a failure reads as a summons")
        XCTAssertGreaterThan(hueGap(error.h, warning.h), 25,
                             "a failure reads as a caution")
        // "rc off" is a passive caution; "your turn" is an active summons.
        // Collapsing them would make the vitals badge and the rail's summons
        // read as the same kind of thing, and they are not — so they separate on
        // chroma as well, the caution being the quieter of the two.
        XCTAssertGreaterThan(hueGap(attention.h, warning.h), 15,
                             "the summons and the caution share a hue")
        XCTAssertLessThan(warning.c, attention.c,
                          "the passive caution is louder than the active summons")
    }

    /// Degrees between two hues, the short way round the wheel.
    private func hueGap(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }

    func testTheAttentionTextInkClears() {
        // The missing Swift binding for `--attn-text`: the held pause icon,
        // the held badge, the queue's "needs attention" exclamation and the
        // `HIGH` chip all used to read `.orange` here.
        assertClears(ThemeRecipe.attentionTextInk(on:), "attentionTextInk")
    }

    /// The PR row's stable-key chip (issue_01M2P5D0D4EQEQX7BSRNFT5QGJ) —
    /// legible on every theme's own surface in both appearances, the same
    /// floor `attentionTextInk` clears, confirmed here rather than assumed
    /// from `solved`'s own contract.
    func testTheWorkItemChipInkClears() {
        assertClears(ThemeRecipe.workItemChipInk(on:), "workItemChipInk")
    }

    // MARK: - The in-progress ink and its collision with the summons

    /// The three themes the issue names by hue: ember (29), amber (68) and
    /// gold (95) all sit within `progressNeutralBand` of the summons' 65.
    /// Named rather than derived, so a change to either constant that quietly
    /// moved this set would fail a test that says so in words.
    private static let collidingThemeNames: Set<String> = ["ember", "amber", "gold"]

    func testProgressCollidesWithSummonsForEmberAmberAndGoldOnly() {
        for theme in ThemeCatalog.all {
            for appearance in [Appearance.light, .dark] {
                let accent = theme.palette(for: appearance).cursor
                let collides = ThemeRecipe.progressCollidesWithSummons(accent: accent)
                XCTAssertEqual(collides, SemanticInkTests.collidingThemeNames.contains(theme.name),
                               "\(theme.name)/\(appearance) collided=\(collides)")
            }
        }
    }

    func testProgressMarkInkClearsWhenItDoesNotCollideAndIsNilWhenItDoes() {
        // The half-filled glyph, the pr-open glyph, the current waypoint's
        // dot and halo all read this. `nil` is the caller's cue to draw the
        // primary ink instead — asserted here as "no ink returned" rather
        // than compared against `.primary`, which has no RGB value to test.
        var worst = Double.infinity
        var worstWhere = ""
        for theme in ThemeCatalog.all {
            for appearance in [Appearance.light, .dark] {
                let accent = theme.palette(for: appearance).cursor
                for (surfaceName, surface) in surfaces(for: theme, appearance) {
                    let mark = ThemeRecipe.progressMarkInk(accent: accent, on: surface)
                    if SemanticInkTests.collidingThemeNames.contains(theme.name) {
                        XCTAssertNil(mark, "\(theme.name)/\(appearance)/\(surfaceName) should fall back")
                        continue
                    }
                    guard let mark else {
                        return XCTFail("\(theme.name)/\(appearance)/\(surfaceName) returned no ink")
                    }
                    let ratio = mark.contrastRatio(against: surface)
                    if ratio < worst {
                        worst = ratio
                        worstWhere = "\(theme.name)/\(appearance)/\(surfaceName)"
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(
            worst, ThemeRecipe.markContrast,
            "progressMarkInk bottoms out at \(String(format: "%.2f", worst)):1 on \(worstWhere)")
    }

    func testProgressTextInkClearsWhenItDoesNotCollideAndIsNilWhenItDoes() {
        var worst = Double.infinity
        var worstWhere = ""
        for theme in ThemeCatalog.all {
            for appearance in [Appearance.light, .dark] {
                let accent = theme.palette(for: appearance).cursor
                for (surfaceName, surface) in surfaces(for: theme, appearance) {
                    let text = ThemeRecipe.progressTextInk(accent: accent, on: surface)
                    if SemanticInkTests.collidingThemeNames.contains(theme.name) {
                        XCTAssertNil(text, "\(theme.name)/\(appearance)/\(surfaceName) should fall back")
                        continue
                    }
                    guard let text else {
                        return XCTFail("\(theme.name)/\(appearance)/\(surfaceName) returned no ink")
                    }
                    let ratio = text.contrastRatio(against: surface)
                    if ratio < worst {
                        worst = ratio
                        worstWhere = "\(theme.name)/\(appearance)/\(surfaceName)"
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(
            worst, ThemeRecipe.minimumTextContrast,
            "progressTextInk bottoms out at \(String(format: "%.2f", worst)):1 on \(worstWhere)")
    }

    func testProgressMarkInkKeepsTheCrewsHueWhenItDoesNotCollide() {
        // Identity is the point of moving off `Color.accentColor` at all — a
        // solve that shifted hue would trade away the thing this ink exists
        // to carry, the same property `testTheDotKeepsItsSessionsHue` pins
        // for `dotInk`.
        for theme in ThemeCatalog.all where !SemanticInkTests.collidingThemeNames.contains(theme.name) {
            for appearance in [Appearance.light, .dark] {
                let accent = theme.palette(for: appearance).cursor
                let surface = RailRow.markBacking(appearance: appearance, isSelected: false, accent: accent)
                guard let mark = ThemeRecipe.progressMarkInk(accent: accent, on: surface) else {
                    return XCTFail("\(theme.name)/\(appearance) unexpectedly collided")
                }
                XCTAssertLessThan(hueGap(mark.toOKLCH().h, accent.toOKLCH().h), 3,
                                  "\(theme.name)/\(appearance) changed hue")
            }
        }
    }

    func testAccentFillInkClearsForWhiteTextOnEveryHue() {
        // Send's background under white text. Unconditional on the collision
        // band — unlike `progressMarkInk`, a filled slab never falls back to
        // the primary ink, so every hue in the catalog is asserted here.
        let white = RGB(red: 1, green: 1, blue: 1)
        var worst = Double.infinity
        var worstWhere = ""
        for theme in ThemeCatalog.all {
            for appearance in [Appearance.light, .dark] {
                let accent = theme.palette(for: appearance).cursor
                let fill = ThemeRecipe.accentFillInk(accent: accent)
                let ratio = white.contrastRatio(against: fill)
                if ratio < worst {
                    worst = ratio
                    worstWhere = "\(theme.name)/\(appearance)"
                }
            }
        }
        XCTAssertGreaterThanOrEqual(
            worst, ThemeRecipe.minimumTextContrast,
            "accentFillInk bottoms out at \(String(format: "%.2f", worst)):1 on \(worstWhere)")
    }

    // MARK: - The mark vocabulary

    /// A state carrying just what the mark reads.
    private func state(_ phase: SessionState.Phase,
                       agents: [String] = [],
                       lastEventAge: Double? = nil) -> SessionState {
        SessionState(session: "deck", phase: phase, gate: nil, alive: true,
                     reason: nil, lastEvent: nil, transcriptMTime: nil, cwd: nil,
                     progressing: nil, lastEventAge: lastEventAge, liveAgents: agents)
    }

    func testOnlyABlockedSessionIsASummons() {
        // The vocabulary spends colour on exactly one state, which is what lets
        // it win a fifteen-row rail. `waiting` used to share this ink and does
        // not any more: a co sitting at its prompt is not asking for anything.
        guard case .needsYou = state(.blocked).mark else {
            return XCTFail("blocked must be the summons")
        }
        for phase in [SessionState.Phase.idle, .waiting, .working, .ended, .unknown] {
            if case .needsYou = state(phase, agents: ["coder"]).mark {
                XCTFail("\(phase) must not read as a summons")
            }
        }
    }

    func testTheSummonsCarriesTheAgeOfTheGateItStandsFor() {
        // A blocked session fires no further hooks, so the newest event IS the
        // gate — which is what makes the staleness ramp free of a new field.
        guard case .needsYou(let age) = state(.blocked, lastEventAge: 940).mark else {
            return XCTFail("blocked must be the summons")
        }
        XCTAssertEqual(age, 940)
    }

    func testACoAtItsPromptDependsEntirelyOnWhatIsRunningBehindIt() {
        // THE DISTINCTION THE PHASE ALONE CANNOT MAKE, and the reason the mark
        // moved off `Phase`. Same phase, same everything else on the wire; the
        // dispatched runs are the only thing that separates a session still
        // working from one that is done.
        for phase in [SessionState.Phase.idle, .waiting] {
            XCTAssertEqual(state(phase).mark, .ready,
                           "\(phase) with nothing dispatched is ready")
            XCTAssertEqual(state(phase, agents: ["deck-reviewer"]).mark, .listening,
                           "\(phase) with a run alive is listening")
        }
    }

    func testIdleAndWaitingAreOneHumanState() {
        // On the wire they are a `Stop` hook and Claude Code's sixty-second idle
        // notification: the same co, at the same prompt, differing only in
        // whether a minute has passed. Drawing them differently put a mark on a
        // row where nothing had changed.
        XCTAssertEqual(state(.idle).mark, state(.waiting).mark)
        XCTAssertEqual(state(.idle, agents: ["coder"]).mark,
                       state(.waiting, agents: ["coder"]).mark)
    }

    func testAMidTurnSessionIsBusyRegardlessOfWhatIsDispatched() {
        // Nothing typed at a co mid-turn lands until the turn ends, so this must
        // not read as an invitation even when agents are also running.
        XCTAssertEqual(state(.working).mark, .busy)
        XCTAssertEqual(state(.working, agents: ["coder"]).mark, .busy)
    }

    func testADeadSessionIsNeverListeningEvenWithRunsStillAlive() {
        // A record can outlive the session that dispatched it. Marking a dead
        // row as listening would invite a redirect at a co that is not there.
        XCTAssertEqual(state(.ended, agents: ["coder"]).mark, .ready)
        XCTAssertEqual(state(.unknown, agents: ["coder"]).mark, .unreadable)
    }

    func testAnUnreadableSessionDoesNotDrawItselfAsSettled() {
        // `.ready` draws a square, which asserts the session is done. When the
        // mini cannot establish what a session is doing, the honest answer is
        // that nobody knows — and the pane's response to it is to offer the raw
        // terminal, which is not what a settled row invites. These collapsed
        // into one mark while ready drew nothing, and separating them is what
        // giving ready a shape of its own costs.
        XCTAssertNotEqual(state(.unknown).mark, state(.ended).mark)
        XCTAssertEqual(state(.unknown).mark, .unreadable)
    }

    func testTheWordsAgreeWithTheMarkBesideThem() {
        // "Ready" beside a pulsing ring is the bar contradicting the mark next
        // to it. Whatever the words say, they must not describe a session as
        // done while the mark says something is still running.
        XCTAssertEqual(state(.idle).liveLabel, "Ready")
        XCTAssertEqual(state(.idle, agents: ["coder"]).liveLabel, "Agents working")
        XCTAssertEqual(state(.waiting, agents: ["coder"]).liveLabel, "Agents working")
        XCTAssertEqual(state(.working).liveLabel, "Working")
        XCTAssertEqual(state(.blocked).liveLabel, "Needs an answer")
    }

    func testTheWordsKeepADistinctionTheMarkDeliberatelyDrops() {
        // `idle` and `waiting` draw ONE mark and keep TWO labels, and that is
        // not an oversight. The mark is scanned across fifteen rows, where the
        // difference is noise — same co, same prompt, a minute apart. The live
        // bar describes one session in words, where "it asked for you" is worth
        // saying and costs nothing: neither label claims anything is running, so
        // neither can contradict the blank space beside it.
        XCTAssertEqual(state(.waiting).liveLabel, "Waiting for you")
        XCTAssertEqual(state(.idle).mark, state(.waiting).mark)
        XCTAssertNotEqual(state(.idle).liveLabel, state(.waiting).liveLabel)
    }

    // MARK: - The summons bar

    private func railBacking() -> RGB {
        RailRow.markBacking(appearance: .light, isSelected: false,
                            accent: RGB(red: 0.2, green: 0.5, blue: 0.4))
    }

    func testOnlyASummoningRowGetsABar() {
        // The bar is the loudest thing in the rail by construction — nothing
        // else is drawn at that x — so every other state has to leave it alone
        // or it stops meaning anything.
        for mark: SessionState.Mark in [.busy, .listening, .ready, .unreadable, .unpolled] {
            XCTAssertNil(RailRow.summonsInk(mark: mark, isStopped: false, on: railBacking()),
                         "\(mark) drew a summons bar")
        }
        XCTAssertNotNil(RailRow.summonsInk(mark: .needsYou(gateAge: 10),
                                           isStopped: false, on: railBacking()))
    }

    func testAStoppedRowDoesNotSummonAnyone() {
        // A row whose agent is gone can still be holding its last blocked
        // reading. Shouting on it sends the reader somewhere with nothing to
        // answer — the same reason its dot dims.
        XCTAssertNil(RailRow.summonsInk(mark: .needsYou(gateAge: 10),
                                        isStopped: true, on: railBacking()))
    }

    func testTheBarAgesOnTheSameScheduleAsTheDot() {
        // One escalation, drawn twice — not two ramps that drift apart. A fresh
        // gate and a fifteen-minute one must differ, and both must still clear
        // the contrast floor against the row they sit on.
        let surface = railBacking()
        guard let fresh = RailRow.summonsInk(mark: .needsYou(gateAge: 0),
                                             isStopped: false, on: surface),
              let stale = RailRow.summonsInk(mark: .needsYou(gateAge: 3600),
                                             isStopped: false, on: surface) else {
            return XCTFail("a summoning row must have a bar")
        }
        XCTAssertGreaterThan(stale.toOKLCH().c, fresh.toOKLCH().c)
        XCTAssertEqual(fresh, ThemeRecipe.attentionInk(on: surface, staleness: 0),
                       "the bar and the dot must be the same ink at the same age")
        for ink in [fresh, stale] {
            XCTAssertGreaterThanOrEqual(ink.contrastRatio(against: surface),
                                        ThemeRecipe.markContrast)
        }
    }

    // MARK: - A folded crew's summons (design §"Attention")

    /// A row's own summons always wins — a crew row whose OWN conversation
    /// needs a reply must show that, never a child's, regardless of which one
    /// the caller happens to pass in.
    func testARowsOwnSummonsWinsOverAChildsEvenWhenBothPresent() {
        let source = RailRow.effectiveSummonsSource(
            own: .needsYou(gateAge: 5), ownStopped: false,
            collapsedChildNeedingAttention: .needsYou(gateAge: 9000))
        XCTAssertEqual(source.mark, .needsYou(gateAge: 5))
        XCTAssertFalse(source.isStopped)
    }

    /// The whole point: a collapsed crew whose own row is quiet still
    /// shows a bar when a pinned child needs an answer — "a folded crew
    /// cannot hide a summons."
    func testACollapsedChildsSummonsSurfacesOnTheParentWhenTheParentIsQuiet() {
        let source = RailRow.effectiveSummonsSource(
            own: .ready, ownStopped: false,
            collapsedChildNeedingAttention: .needsYou(gateAge: 30))
        XCTAssertEqual(source.mark, .needsYou(gateAge: 30))
        XCTAssertFalse(source.isStopped)
    }

    /// Expanded, the caller passes nil — the child gets its own row and its
    /// own bar instead — and a quiet parent draws no bar of its own.
    func testNoChildSourceMeansNoSummonsWhenTheRowItselfIsQuiet() {
        let source = RailRow.effectiveSummonsSource(
            own: .ready, ownStopped: false, collapsedChildNeedingAttention: nil)
        XCTAssertNil(RailRow.summonsInk(mark: source.mark, isStopped: source.isStopped,
                                        on: railBacking()))
    }

    /// A stopped parent still surfaces a live child's summons — the row being
    /// stopped describes the PARENT's own conversation, not whether some
    /// sibling elsewhere in the same directory is alive and asking something.
    func testAStoppedParentStillSurfacesALiveChildsSummons() {
        let source = RailRow.effectiveSummonsSource(
            own: .ready, ownStopped: true,
            collapsedChildNeedingAttention: .needsYou(gateAge: 12))
        XCTAssertNotNil(RailRow.summonsInk(mark: source.mark, isStopped: source.isStopped,
                                           on: railBacking()))
    }

    // MARK: - The terminal-only preview hue

    /// A terminal-only CHILD of a known crew keeps the achromatic glyph —
    /// it already draws that crew's hue everywhere else, so there is
    /// nothing left to preview. Only an "OTHER SESSIONS" row, which has no
    /// crew yet, previews the hue adoption would give it.
    func testATerminalOnlyChildOfAKnownCrewDrawsNoPreviewHue() {
        let accent = RGB(red: 0.2, green: 0.5, blue: 0.4)
        XCTAssertNil(RailChildRow.terminalGlyphInk(previewsAdoptionHue: false, accent: accent),
                     "a discovered child under a crew must not preview a hue it already has")
    }

    func testAnOtherSessionsRowPreviewsItsAdoptionTargetsHue() {
        // `ContentView.themeForSession` hashes a bare name to a theme before
        // anyone adopts it, so the row previews exactly that hue — not a
        // fixed or a muted one — at 30% (the view applies the opacity; this
        // only pins which ink it applies it to).
        let accent = RGB(red: 0.2, green: 0.5, blue: 0.4)
        XCTAssertEqual(RailChildRow.terminalGlyphInk(previewsAdoptionHue: true, accent: accent), accent,
                       "an OTHER SESSIONS row must preview its own resolved accent")
    }

    func testEveryMarkIsTellableApartFromEveryOther() {
        // All six draw a different shape in `SessionDotView`, and five of them
        // share the session's own ink — so the enum collapsing two cases would
        // silently make two states draw the same dot. This is the guard for
        // that, and it has to cover `.unreadable` and `.unpolled`: those are the
        // two that used to BE `.none` alongside ready.
        let marks: [SessionState.Mark] = [
            state(.blocked).mark, state(.working).mark,
            state(.idle, agents: ["coder"]).mark, state(.idle).mark,
            state(.unknown).mark, .unpolled,
        ]
        for (i, a) in marks.enumerated() {
            for b in marks[(i + 1)...] {
                XCTAssertNotEqual(a, b)
            }
        }
    }
}
