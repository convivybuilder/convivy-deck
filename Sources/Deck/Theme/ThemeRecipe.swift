// Generates a full terminal theme from a single hue.
//
// WHERE THE RECIPE COMES FROM. The thirteen iTerm profiles in agent-platform
// (`iterm/co-*.json`) all follow one pattern: a background tinted a few percent
// toward the session's accent hue, a foreground pulled to a dark desaturated
// version of that same hue, and the accent itself kept saturated for the
// cursor. That is a function of one hue, which is what this file makes
// explicit. Deck therefore ships the *pattern* rather than Convivy's specific
// thirteen colors — a user with different crews gets the same design
// language applied to their own names, instead of a table of ours they cannot
// read.
import Foundation

enum ThemeRecipe {
    /// Standard ANSI hues in OKLCH degrees. Slots 0/7/8/15 are the achromatic
    /// black/white pairs and take the theme's own hue at near-zero chroma, so a
    /// theme's grays sit in its own color family rather than reading as a
    /// foreign neutral dropped in.
    static let ansiHues: [Double] = [
        29,   // red
        145,  // green
        95,   // yellow
        262,  // blue
        328,  // magenta
        195,  // cyan
    ]

    /// WCAG AA for body text. Every ANSI slot that carries text is solved to at
    /// least this against its own background — see `solveLightness`.
    static let minimumTextContrast = 4.5

    /// A theme built from `hue`, with every chroma scaled by `chroma`. `chroma`
    /// 0 is the neutral form: the same lightness walk over a grey ramp, which
    /// is how the laptop's graphite theme is drawn (`ThemeCatalog.graphite`).
    static func theme(named name: String, hue: Double, chroma: Double = 1) -> TerminalTheme {
        TerminalTheme(name: name,
                      light: lightPalette(hue: hue, chroma: chroma),
                      dark: darkPalette(hue: hue, chroma: chroma))
    }

    /// Ink for a failure, solved against the surface it will actually sit on.
    ///
    /// WHY THIS EXISTS. Errors were `.orange`, a fixed system colour, drawn on
    /// the FRAME TINT — the session's canvas mixed halfway to white in light
    /// mode. That canvas starts at OKLCH lightness 0.975, so the tint lands
    /// around 0.99, and system orange over it measures roughly 2:1: below the
    /// 4.5:1 WCAG asks for body text, at any size. The one colour on the surface
    /// that must be read the instant it appears was the least readable.
    ///
    /// SOLVED AGAINST THE TINT, NOT THE CANVAS, because the tint is where this
    /// text is drawn — the status bar and the live bar both carry it. Solving
    /// against the canvas would answer a question nobody asked and miss by the
    /// width of the mix.
    ///
    /// The hue is fixed at a warm red rather than taken from the session, and
    /// that is the point: a failure must read as a failure in every theme, and a
    /// per-session error colour would make "something is wrong" a shade the user
    /// has to learn ten times.
    static func errorInk(on surface: RGB) -> RGB {
        solved(OKLCH(l: 0.55, c: 0.19, h: 25), on: surface, target: 4.5)
    }

    /// Ink for a standing state that is not a failure — `rc off`, a degraded
    /// reading. Solved to the same 4.5:1, at a hue far enough from the error's
    /// that the two are not read as the same signal.
    /// QUIETER AND FURTHER AWAY THAN THE FIRST DRAFT, which put this at hue 75
    /// against the summons at 65. Ten degrees is a nominal separation and no
    /// perceptual one: the vitals' standing `rc off` badge and the rail's "your
    /// turn" mark would have read as the same signal. They are not the same —
    /// one is a passive caution you may ignore all day, the other is an active
    /// summons — so they separate on two channels: thirty degrees of hue, and a
    /// lower chroma, because the thing you can ignore should not be as loud as
    /// the thing you cannot.
    static func warningInk(on surface: RGB) -> RGB {
        solved(OKLCH(l: 0.58, c: 0.10, h: 95), on: surface, target: 4.5)
    }

    /// What WCAG 1.4.11 asks of a non-text mark, and what the phase marks are
    /// solved to.
    ///
    /// THE MARKS USED TO ASK 4.5:1 AND THE HUE PAID FOR IT. Text-grade contrast
    /// against a near-white rail can only be reached by walking lightness down,
    /// and hue 65 walked down far enough stops reading as amber: the operator,
    /// on the shipped build, "there's two brown things". Nothing was wrong with the
    /// hue; it was being dragged dark to clear a bar these marks do not have to
    /// clear. At 3:1 the amber stays amber, and there is chroma headroom left
    /// over for `staleness` to spend.
    static let markContrast = 3.0

    /// Ink for the one thing the rail is scanned for: a session stopped and
    /// waiting on you.
    ///
    /// ONE PHASE, NOT TWO. This ink used to carry `waiting` as well as
    /// `blocked`, on the reasoning that both answered "does this need me" with
    /// yes. `waiting` is not that: it is a co sitting at its prompt, which is
    /// either the ready state or a co listening while dispatched agents work,
    /// and neither is a summons. Now `blocked` is the only coloured mark in the
    /// vocabulary, which is what lets it win a fifteen-row rail — the other two
    /// marks are neutral by construction, so nothing competes for the eye.
    ///
    /// RED IS DELIBERATELY NOT HERE. `blocked` is a permission gate that fires
    /// dozens of times a session, not a failure; painting it red trains the eye
    /// to ignore red, and `errorInk` needs red to still mean something when a
    /// render or a send actually fails.
    ///
    /// `staleness` is 0…1 and rides on chroma, not lightness: the solver holds
    /// the contrast promise whatever chroma it is handed, so a gate that has
    /// been standing a while intensifies without ever getting harder to see.
    /// Going the other way — ramping lightness — would trade legibility for
    /// urgency, which is the wrong direction for the mark that matters most.
    static func attentionInk(on surface: RGB, staleness: Double = 0) -> RGB {
        let ramp = min(max(staleness, 0), 1)
        return solved(OKLCH(l: 0.60, c: 0.13 + 0.06 * ramp, h: attentionHue),
                      on: surface, target: markContrast)
    }

    /// The hue `attentionInk` is anchored at. Named rather than left as a
    /// literal inside that function, because `progressCollidesWithSummons`
    /// below has to test against the same number `attentionInk` actually
    /// draws — two 65s that happened to agree would be one accidental
    /// coincidence away from two that don't.
    static let attentionHue = 65.0

    /// The text-weight form of `attentionInk`, for the badges that letter a
    /// word rather than draw a shape — the held pause icon, the held count,
    /// the corrections queue's "needs attention" exclamation, the `HIGH`
    /// severity chip. Held to `minimumTextContrast` rather than
    /// `markContrast`, the same reason `errorInk` and `warningInk` are: a
    /// system `.orange` measured 2.11:1 in this exact slot before `errorInk`
    /// existed to replace it, and these badges are the same kind of text.
    static func attentionTextInk(on surface: RGB) -> RGB {
        solved(OKLCH(l: 0.60, c: 0.13, h: attentionHue), on: surface, target: minimumTextContrast)
    }

    /// Ink for the stable-key chip a PR row draws before `#N`
    /// (`CockpitView.pullRequestRow`) — plain information, not a severity or
    /// a summons, so it is fully desaturated rather than drawn at
    /// `attentionHue` or any crew's own accent. Solved to
    /// `minimumTextContrast` like `attentionTextInk`, the same "this is text
    /// a reader must be able to read" floor, against whichever surface the
    /// panel is drawn on.
    static func workItemChipInk(on surface: RGB) -> RGB {
        solved(OKLCH(l: 0.50, c: 0, h: 0), on: surface, target: minimumTextContrast)
    }

    /// Ink for the place line a right-column band names its host with
    /// (`user@host`, a project, "this Mac"). It is `workItemChipInk`'s neutral
    /// at the same 4.5:1 floor, named separately because the band's place line
    /// is read beside a crew's accent and should not share a name with a chip.
    static func placeLineInk(on surface: RGB) -> RGB {
        workItemChipInk(on: surface)
    }

    /// Secondary text on a light surface the cockpit draws on under Builder
    /// Default: its labels, counts and timestamps. Solved to `minimumTextContrast`,
    /// the same floor and the same solve as `workItemChipInk`, which it matches.
    static func secondaryTextInk(on surface: RGB) -> RGB {
        solved(OKLCH(l: 0.50, c: 0, h: 0), on: surface, target: minimumTextContrast)
    }

    /// A neutral non-text mark on a light surface, such as a disclosure chevron.
    /// Solved to `markContrast`, the non-text floor, so it stays visible without
    /// competing with the text it sits beside.
    static func neutralMarkInk(on surface: RGB) -> RGB {
        solved(OKLCH(l: 0.50, c: 0, h: 0), on: surface, target: markContrast)
    }

    /// The full-strength text ink on a light surface the status panes draw on,
    /// such as the cockpit's frame-tint ground under Builder Default. The dark
    /// counterpart is `StatusGround.primaryInk`, which stays fixed because the
    /// status ground is always dark. Solved to `minimumTextContrast`.
    static func primaryTextInk(on surface: RGB) -> RGB {
        solved(OKLCH(l: 0.22, c: 0, h: 0), on: surface, target: minimumTextContrast)
    }

    /// Ink for an upcoming waypoint's hollow mark on the Course strip. It is a
    /// non-text mark, so it is solved to `markContrast` rather than the text
    /// floor, which keeps it visibly hollow without going faint.
    static func routeMarkInk(on surface: RGB) -> RGB {
        solved(OKLCH(l: 0.50, c: 0, h: 0), on: surface, target: markContrast)
    }

    /// How close a crew's own hue may sit to `attentionHue` before an
    /// in-progress mark backs off to the primary ink instead of risking a
    /// read as a second summons. Ember (29), amber (68) and gold (95) all
    /// fall inside it — the same or within thirty degrees of the summons.
    static let progressNeutralBand = 40.0

    /// True when `accent`'s hue sits within `progressNeutralBand` of the
    /// summons' — the case `design/redesign/02-cockpit.html` draws for Vivy
    /// Commercial (amber, hue 68, three degrees from the summons' 65).
    static func progressCollidesWithSummons(accent: RGB) -> Bool {
        let hue = accent.toOKLCH().h
        let raw = abs(hue - attentionHue).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw) <= progressNeutralBand
    }

    /// Ink for the one mark that says "this is what's in flight" — the
    /// half-filled glyph, the pull-request glyph on a `pr-open` queue row,
    /// the current waypoint's dot and halo. THE CREW'S OWN HUE CARRIES THIS
    /// NOW, not `Color.accentColor`: the same system blue behind ten
    /// different crews taught the eye nothing about which crew it was
    /// looking at.
    ///
    /// `nil` exactly when `progressCollidesWithSummons` — the caller's cue
    /// to fall back to the primary ink instead, since a mark that gives up
    /// matching its crew's identity beats one that reads as a second
    /// summons. Select Vivy Commercial and the half-filled glyph would
    /// otherwise sit beside the held pause in what reads as one colour.
    static func progressMarkInk(accent: RGB, on surface: RGB) -> RGB? {
        guard !progressCollidesWithSummons(accent: accent) else { return nil }
        return dotInk(accent: accent, on: surface)
    }

    /// The text-weight form of `progressMarkInk`, at `minimumTextContrast`
    /// — the current waypoint's label. Same fallback rule: `nil` when the
    /// crew's hue collides with the summons.
    static func progressTextInk(accent: RGB, on surface: RGB) -> RGB? {
        guard !progressCollidesWithSummons(accent: accent) else { return nil }
        return solveLightness(accent.toOKLCH(), on: surface, target: minimumTextContrast)
    }

    /// The crew's own hue, made legible as a filled slab's background under
    /// white text — Send, Replace. Solved against white rather than
    /// whatever surface the button sits on, and always from the crew's hue
    /// alone: the button's own shape already says "primary action", so
    /// unlike `progressMarkInk` this never backs off to a neutral ink even
    /// when the hue collides with the summons — there is nothing here for
    /// it to be confused with.
    static func accentFillInk(accent: RGB) -> RGB {
        solved(OKLCH(l: 0.58, c: 0.16, h: accent.toOKLCH().h),
               on: RGB(red: 1, green: 1, blue: 1), target: minimumTextContrast)
    }

    // THERE IS NO `machineryInk` ANY MORE, and its absence is the design. It
    // existed for a neutral working mark drawn BESIDE the session's accent
    // rather than in it. That arrangement is gone: state rides on the identity
    // dot now, so working and listening draw in the session's own colour and
    // are told apart from ready by shape.

    /// A session's accent, made legible against the surface its dot sits on.
    ///
    /// WHY THE ACCENT CANNOT JUST BE USED RAW. Each theme's `cursor` is solved
    /// to 3:1 against THAT THEME'S CANVAS, which is not the surface the rail
    /// draws on. The rail's backing is the system control background, lighter
    /// than most canvases, and a selected row washes it with the session's own
    /// hue — so the dot can end up sitting on a tint of itself. Measured across
    /// every theme, sage on a selected light row bottoms out at 2.85:1.
    ///
    /// That was survivable while the dot was only an identity blob: a circle is
    /// a circle at any contrast. It stopped being survivable when the dot
    /// started carrying STATE in its shape, because telling a square from a
    /// circle from a notched disc is a shape judgement, and 1.4.11 asks 3:1 of
    /// exactly that.
    ///
    /// HUE AND CHROMA ARE UNTOUCHED; ONLY LIGHTNESS MOVES. Identity here means
    /// "recognisable as this session's colour", which is carried by hue, and a
    /// lightness walk keeps it. And the walk is a no-op for any accent that
    /// already clears — `solveLightness` returns its input unchanged — so this
    /// changes nothing at all for most themes rather than shifting the whole
    /// palette to fix two of them.
    static func dotInk(accent: RGB, on surface: RGB) -> RGB {
        solveLightness(accent.toOKLCH(), on: surface, target: markContrast)
    }

    /// How far apart, in OKLCH lightness, the two ends of the `.listening`
    /// pulse must land. Chosen rather than derived: it is roughly two-thirds of
    /// the lightness step between adjacent ANSI slots' normal/bright pair
    /// (`normalL`/`brightL` below run about 0.1–0.2 apart per appearance), which
    /// is already the app's own standard for "a different emphasis of the same
    /// hue, plainly told apart." Below that the two phases of a slow pulse blur
    /// into one perceived colour; there is no floor this size protects, only
    /// legibility of the motion itself.
    static let pulseLightnessStep = 0.12

    /// The other end of the `.listening` pulse — solved, not a fixed alpha.
    ///
    /// WHY AN OPACITY COULD NOT DO THIS. The pulse used to fade `dotInk` to 35%,
    /// which blends toward `surface` and is not a contrast-bearing operation at
    /// all: measured across the catalog, the second phase bottomed out around
    /// 1.4–1.95:1, under half of `markContrast`, because nothing in an alpha
    /// blend enforces a floor.
    ///
    /// THIS PHASE BRIGHTENS, ON EVERY THEME, RATHER THAN DIMMING. A first
    /// version tried to dim toward `surface` first and fell back to brightening
    /// only where dimming could not clear `markContrast` — light, selected
    /// leaves no room at all, since `dotInk` already sits at 3.00–3.25 there
    /// before the pulse touches it. That fallback fired on 29 of the 40
    /// theme/appearance/selection combinations, so the pulse dimmed on some
    /// themes and brightened on others, and which one depended on which theme
    /// happened to be showing — a pulse that changes direction with the theme
    /// reads as broken motion, not as a state.
    ///
    /// So this always walks away from `surface`, the same direction `dotInk`
    /// itself walks when it has to. Both ends still clear the floor (worst
    /// measured: 1.43 → 3.03), and the same `pulseLightnessStep` still
    /// separates them on every theme.
    static func pulseDotInk(accent: RGB, on surface: RGB) -> RGB {
        let bright = dotInk(accent: accent, on: surface).toOKLCH()
        // `dotInk` walked darker exactly when it started on the dark side of
        // the surface — recomputing that same comparison on its result places
        // this step on the same side, whether or not `dotInk` needed to walk.
        let brightIsOnDarkSide = bright.l < backgroundLightnessProxy(surface)

        var awayFromSurface = bright
        awayFromSurface.l += brightIsOnDarkSide ? -pulseLightnessStep : pulseLightnessStep
        awayFromSurface.l = min(max(awayFromSurface.l, 0), 1)
        return solveLightness(awayFromSurface, on: surface, target: markContrast)
    }

    /// How stale a standing gate is, 0…1, from the seconds since it opened.
    ///
    /// THESE TWO NUMBERS ARE A GUESS AND ARE MARKED AS ONE. Nothing has measured
    /// how long a gate typically stands before the operator answers it, so the ramp is
    /// set where a fresh gate reads plainly and a forgotten one has visibly
    /// aged: flat for the first two minutes, full by fifteen. Live with them
    /// before trusting them — the same footing as the reaper's 24h idle
    /// threshold, and worth replacing with a measurement rather than a
    /// re-guess.
    ///
    /// `nil` — a mini that could not date the last event — is fresh rather than
    /// stale. An unknown age must not manufacture urgency.
    static func staleness(gateAge: Double?) -> Double {
        guard let gateAge else { return 0 }
        let fresh = 120.0, aged = 900.0
        return min(max((gateAge - fresh) / (aged - fresh), 0), 1)
    }

    // MARK: - PR ladder stoplight

    /// The dot's ink on `surface`, the ground the dot is drawn over. Under
    /// Builder Default that ground is the cockpit's own frame tint
    /// (`ContentView.columnPin` -> `cockpitFrameGround`), light appearance,
    /// never `StatusGround.ground` — that ground belongs to the rail, the
    /// strip and the chrome, which the cockpit does not pin to.
    ///
    /// WHY THE LIFT. On the Builder Default ground, four of GitHub's values
    /// fall below `markContrast`: merged, ready, failed CI and draft each
    /// measure 2.7:1 there. Such a value is walked lighter, in OKLCH, until it
    /// clears, keeping its hue and chroma, the same walk `dotInk` uses. A
    /// value that already clears is returned as written, so the system dark
    /// ground and the light appearance are unchanged.
    ///
    /// READY IS THE ONE EXCEPTION, AND `readyDotInk` IS WHY. Ready's problem
    /// is not contrast — `primerReadyLight` (`#1f883d`) already clears
    /// `markContrast` on the real cockpit ground, on every catalog theme's
    /// frame tint, and on the system fallback grounds. The generic walk never
    /// runs there, so the green it leaves behind sits only 13 degrees of hue
    /// from the ground's own light-green tint, close enough in lightness to
    /// the grey draft dot (`ΔE` 0.16, `PRDotContrastTests`) that the two read
    /// as the same dot. Ready is the one colour checked unconditionally,
    /// before the contrast guard, because the guard is exactly what let this
    /// ship. The operator, 2026-10-07: "gray and green look the same."
    static func prDotInk(_ color: PRLadderRow.DotColor, appearance: Appearance,
                         on surface: RGB) -> RGB {
        let base = primerInk(color, appearance: appearance)
        if color == .ready {
            return readyDotInk(baseHue: base.toOKLCH().h, on: surface)
        }
        guard base.contrastRatio(against: surface) < markContrast else { return base }
        return solveLightness(base.toOKLCH(), on: surface, target: markContrast)
    }

    /// Ready's lift past the mark-contrast floor, not to it, and run on every
    /// ground rather than only where the base value under-contrasts: fixed
    /// lightness and chroma rather than a walk from GitHub's own value, so the
    /// result reads as a plainly bright green rather than "the dimmest green
    /// that still legally clears" — or, on most real grounds, GitHub's own
    /// value verbatim, which is the bug this replaces.
    ///
    /// THE NUMBERS. L 0.78 and C 0.20 sit near the other lifted PR inks in
    /// magnitude (`inReview` lands at L 0.77 C 0.14, `failedCI` at L 0.62 C
    /// 0.20) rather than inventing a new register, and the hue is kept from
    /// whichever appearance's Primer value called this — green stays green,
    /// only the lightness and chroma move. `PRDotContrastTests` pins the
    /// separation this buys on every ground the cockpit actually draws on,
    /// not only Builder Default's: ΔE(ready, draft) goes from 0.16 to roughly
    /// 0.23 on every catalog theme's frame tint, past the 0.22 floor that
    /// test holds the line at. The two grounds `CockpitView.resolvedIndexSurface`
    /// falls back to with no session selected (System and the plain
    /// Light/Dark presets) show the same pre-fix confusion measured directly
    /// against the gated code: light fallback (`#fafafa`) ΔE 0.1615 pre,
    /// 0.2305 post; dark fallback (`#1f1f21`) ΔE 0.1561 pre, 0.3004 post — so
    /// the lift belongs on both, not only on Builder Default's frame tint,
    /// and `testReadyClearsAMinimumSeparationFromDraftOnTheSystemFallbackGrounds`
    /// holds that line too. `solveLightness` still runs underneath so a
    /// future ground this anchor does not clear 3:1 on fails loudly instead
    /// of silently under-contrasting.
    private static func readyDotInk(baseHue: Double, on surface: RGB) -> RGB {
        solveLightness(OKLCH(l: 0.78, c: 0.20, h: baseHue), on: surface, target: markContrast)
    }

    /// GitHub's own Primer palette for a pull request's overall state — the
    /// one ink family in this file that is copied rather than solved from a
    /// hue. Every other ink here is a formula because Deck ships to users
    /// with their own crew hues (CLAUDE.md, "Deck ships to others"); a PR's
    /// state is not a crew's identity, it is GitHub's own vocabulary (merged
    /// purple, open green, closed red), so matching GitHub's fixed values is
    /// the legible choice, not a derived look-alike. Still keyed on
    /// `Appearance`, like every other ink in this file, so it stamps
    /// correctly with `data-theme` and never reads `colorScheme` on its own.
    ///
    /// The operator revised this mapping after seeing the first cut (2026-09-16, in
    /// session): CI and review no longer share one amber, and closed-not-merged
    /// takes the shell's own text ink rather than red, since red now means "CI
    /// failed" specifically. `.closed`'s two values are `foreground`, not a
    /// Primer state colour — there is nothing in Primer's own scale for "no
    /// verdict, just shut", and the shell's text ink already reads as
    /// "finished, no further state" everywhere else in Deck.
    static func primerInk(_ color: PRLadderRow.DotColor, appearance: Appearance) -> RGB {
        switch (color, appearance) {
        case (.merged, .light): return primerMergedLight
        case (.merged, .dark): return primerMergedDark
        case (.ready, .light): return primerReadyLight
        case (.ready, .dark): return primerReadyDark
        case (.closed, .light): return primerClosedTextLight
        case (.closed, .dark): return primerClosedTextDark
        case (.failedCI, .light): return primerFailedLight
        case (.failedCI, .dark): return primerFailedDark
        case (.inCI, .light): return primerInCILight
        case (.inCI, .dark): return primerInCIDark
        case (.inReview, .light): return primerInReviewLight
        case (.inReview, .dark): return primerInReviewDark
        case (.draftOrUnknown, .light): return primerDraftLight
        case (.draftOrUnknown, .dark): return primerDraftDark
        }
    }

    // Primer's own hex values (github.com/primer/primitives) where GitHub has
    // a matching state colour: merged/ready/draft, and failed CI (Primer's
    // "closed" red — GitHub itself has no separate "CI failed" state, so this
    // is the closest borrowed meaning). `closed` (not-merged, no CI verdict)
    // is `foreground.default` instead, GitHub's own body-text ink, since
    // Primer's scale has nothing for "shut with no verdict." `inCI` and
    // `inReview` are tuned rather than copied: Primer has one "attention"
    // amber for everything still moving, and this mapping needs two colours
    // told apart at a glance (brown for a machine still running CI, amber for
    // a human still reading), each solved against the cockpit surface
    // (`markContrast`) with enough headroom that a review request never
    // blends into a CI run — see `SemanticInkTests` for the measured floor.
    private static let primerMergedLight = parseHexColor("8250df")!
    private static let primerMergedDark = parseHexColor("8957e5")!
    private static let primerReadyLight = parseHexColor("1f883d")!
    private static let primerReadyDark = parseHexColor("238636")!
    private static let primerClosedTextLight = parseHexColor("1F2328")!
    private static let primerClosedTextDark = parseHexColor("F0F6FC")!
    private static let primerFailedLight = parseHexColor("cf222e")!
    private static let primerFailedDark = parseHexColor("da3633")!
    private static let primerDraftLight = parseHexColor("59636e")!
    private static let primerDraftDark = parseHexColor("6e7681")!
    private static let primerInCILight = parseHexColor("7d481f")!
    private static let primerInCIDark = parseHexColor("ad774e")!
    // Light in-review amber: the lightest at its hue (OKLCH h 83) that still clears
    // `markContrast` on the light cockpit surface (3.01 on #fafafa). The earlier
    // #a67a00 read as brown beside `inCI` (operator, 2026-10-08).
    private static let primerInReviewLight = parseHexColor("b78a23")!
    private static let primerInReviewDark = parseHexColor("d9ad36")!

    // MARK: - Variants

    private static func lightPalette(hue: Double, chroma: Double) -> TerminalPalette {
        let background = OKLCH(l: 0.975, c: 0.018 * chroma, h: hue).toRGB()
        return TerminalPalette(
            background: background,
            foreground: solved(OKLCH(l: 0.30, c: 0.035 * chroma, h: hue), on: background, target: 7.0),
            cursor: solved(OKLCH(l: 0.58, c: 0.16 * chroma, h: hue), on: background, target: 3.0),
            selection: OKLCH(l: 0.90, c: 0.055 * chroma, h: hue).toRGB(),
            ansi: ansiRamp(hue: hue, chroma: chroma, background: background, isLight: true)
        )
    }

    private static func darkPalette(hue: Double, chroma: Double) -> TerminalPalette {
        let background = OKLCH(l: 0.20, c: 0.022 * chroma, h: hue).toRGB()
        return TerminalPalette(
            background: background,
            foreground: solved(OKLCH(l: 0.90, c: 0.02 * chroma, h: hue), on: background, target: 7.0),
            cursor: solved(OKLCH(l: 0.72, c: 0.15 * chroma, h: hue), on: background, target: 3.0),
            selection: OKLCH(l: 0.34, c: 0.06 * chroma, h: hue).toRGB(),
            ansi: ansiRamp(hue: hue, chroma: chroma, background: background, isLight: false)
        )
    }

    // MARK: - The 16 slots

    /// Slots 7 and 15 in a light theme (and 0 and 8 in a dark one) are the
    /// low-contrast end of the ramp. That is deliberate and conventional: those
    /// slots are what programs select for *backgrounds* in reverse video, so
    /// forcing them to 4.5:1 against the page would make every highlighted
    /// region unreadable instead. `ThemeContrastTests` asserts the text-bearing
    /// slots and asserts these stay in their background role.
    private static func ansiRamp(hue: Double, chroma: Double, background: RGB, isLight: Bool) -> [RGB] {
        // "Bright" means emphasized, which is a different move per appearance.
        // On a dark page, brighter reads as emphasis. On a light page it reads
        // as *faded*, so emphasis there is more chroma with slightly lower
        // lightness — the opposite direction, same intent.
        let normalL = isLight ? 0.50 : 0.70
        let brightL = isLight ? 0.44 : 0.80
        let normalC = 0.13 * chroma
        let brightC = 0.17 * chroma

        var slots = [RGB](repeating: RGB(red: 0, green: 0, blue: 0), count: 16)

        slots[0] = achromatic(l: isLight ? 0.26 : 0.30, hue: hue, chroma: chroma)
        slots[8] = achromatic(l: isLight ? 0.46 : 0.45, hue: hue, chroma: chroma)
        slots[7] = achromatic(l: isLight ? 0.84 : 0.85, hue: hue, chroma: chroma)
        slots[15] = achromatic(l: isLight ? 0.94 : 0.96, hue: hue, chroma: chroma)

        for (offset, ansiHue) in ansiHues.enumerated() {
            let normalSlot = normalIndex(for: offset)
            slots[normalSlot] = solved(
                OKLCH(l: normalL, c: normalC, h: ansiHue), on: background, target: minimumTextContrast)
            slots[normalSlot + 8] = solved(
                OKLCH(l: brightL, c: brightC, h: ansiHue), on: background, target: minimumTextContrast)
        }
        return slots
    }

    /// `ansiHues` is ordered red, green, yellow, blue, magenta, cyan — which is
    /// ANSI slots 1, 2, 3, 4, 5, 6. The mapping is the identity plus one.
    private static func normalIndex(for offset: Int) -> Int { offset + 1 }

    private static func achromatic(l: Double, hue: Double, chroma: Double) -> RGB {
        OKLCH(l: l, c: 0.008 * chroma, h: hue).toRGB()
    }

    // MARK: - Contrast solving

    private static func solved(_ color: OKLCH, on background: RGB, target: Double) -> RGB {
        solveLightness(color, on: background, target: target)
    }

    /// Walks lightness away from the background until the color clears `target`.
    ///
    /// This exists because WCAG luminance and perceptual lightness disagree,
    /// and they disagree *by hue*. A yellow and a blue at the same OKLCH L look
    /// equally light but differ by several multiples in WCAG luminance, so a
    /// palette built on fixed lightness values has readable blues and yellows
    /// that disappear into a light background. Solving per-slot is what lets
    /// every hue make the same promise.
    ///
    /// Direction is chosen by which side of the background the color starts on,
    /// so this works unchanged for both appearances. If the ramp runs to the end
    /// without clearing the target — possible only for a hue whose maximum
    /// contrast against this background is genuinely below it — the best
    /// available lightness is returned rather than looping forever, and
    /// `ThemeContrastTests` is what catches that case if a future palette
    /// introduces one.
    static func solveLightness(_ color: OKLCH, on background: RGB, target: Double) -> RGB {
        let goDarker = color.l < backgroundLightnessProxy(background)
        var candidate = color
        var best = candidate.toRGB()
        var bestRatio = best.contrastRatio(against: background)

        while bestRatio < target {
            candidate.l += goDarker ? -0.01 : 0.01
            if candidate.l < 0 || candidate.l > 1 { break }
            let rgb = candidate.toRGB()
            let ratio = rgb.contrastRatio(against: background)
            // Monotone in practice, but guard anyway: keep the best seen rather
            // than trusting the last step to be the strongest.
            if ratio > bestRatio {
                bestRatio = ratio
                best = rgb
            }
        }
        return best
    }

    /// Perceptual lightness of the background, used only to pick a direction.
    /// Derived from WCAG luminance rather than round-tripping through OKLab,
    /// because the only question here is "is the page light or dark".
    private static func backgroundLightnessProxy(_ background: RGB) -> Double {
        background.relativeLuminance > 0.18 ? 1.0 : 0.0
    }
}
