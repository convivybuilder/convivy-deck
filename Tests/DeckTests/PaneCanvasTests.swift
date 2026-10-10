import XCTest
@testable import Deck

/// The pane's canvas is the session's terminal background, lifted — so the
/// conversation reads as a surface on the same theme rather than a window from
/// somewhere else.
final class PaneCanvasTests: XCTestCase {

    // MARK: - The lift

    func testLighteningMovesTowardWhiteWithoutLeavingTheGamut() {
        let dark = RGB(red: 0.09, green: 0.09, blue: 0.10)
        let lifted = dark.lightened(by: 0.06)

        XCTAssertGreaterThan(lifted.relativeLuminance, dark.relativeLuminance)
        XCTAssertTrue(lifted.isInGamut)
    }

    func testLighteningByNothingChangesNothing() {
        let colour = RGB(red: 0.2, green: 0.15, blue: 0.1)
        let same = colour.lightened(by: 0)

        XCTAssertEqual(same.red, colour.red, accuracy: 0.0001)
        XCTAssertEqual(same.green, colour.green, accuracy: 0.0001)
        XCTAssertEqual(same.blue, colour.blue, accuracy: 0.0001)
    }

    func testLighteningFullyIsWhite() {
        let white = RGB(red: 0.1, green: 0.2, blue: 0.3).lightened(by: 1)
        XCTAssertEqual(white.red, 1, accuracy: 0.001)
        XCTAssertEqual(white.green, 1, accuracy: 0.001)
        XCTAssertEqual(white.blue, 1, accuracy: 0.001)
    }

    func testAnOutOfRangeAmountIsClampedRatherThanExploding() {
        XCTAssertTrue(RGB(red: 0.2, green: 0.2, blue: 0.2).lightened(by: -5).isInGamut)
        XCTAssertTrue(RGB(red: 0.2, green: 0.2, blue: 0.2).lightened(by: 99).isInGamut)
    }

    func testTheLiftKeepsTheHueOfAWarmBackground() {
        // an operator's terminal is gold and brown. A lift that greyed it would lose the
        // theme, which is the thing being carried across to the pane.
        let brown = RGB(red: 0.16, green: 0.11, blue: 0.07)
        let lifted = brown.lightened(by: 0.06)

        XCTAssertGreaterThan(lifted.red, lifted.green)
        XCTAssertGreaterThan(lifted.green, lifted.blue)
    }

    // MARK: - What reaches the renderer

    func testTheBackgroundIsPassedToTheRenderer() throws {
        let argv = try SessionAgent.renderArguments(
            target: TestHost.target, session: "deck", appearance: .dark, background: "#2b1d12")

        XCTAssertTrue(argv.contains("--background"))
        // Quoted: ssh hands its joined argv to the remote shell, where a bare
        // `#` starts a comment and would eat the value. This test asserted the
        // unquoted form and so encoded the bug rather than catching it.
        XCTAssertTrue(argv.contains("'#2b1d12'"))
    }

    func testNoBackgroundSendsNoArgument() throws {
        let argv = try SessionAgent.renderArguments(target: TestHost.target, session: "deck", appearance: .dark)
        XCTAssertFalse(argv.contains("--background"))
    }

    @MainActor
    func testAValueThatIsNotAColourIsDroppedRatherThanSent() throws {
        // It lands in ssh argv, which the remote shell splits again, and then in
        // a `<style>` block on the far side. A page with the shipped background
        // is a smaller failure than an argument read as something else.
        for hostile in ["red; } body { background: url(https://evil/x)",
                        "#fff --theme dark",
                        "$(whoami)",
                        "; rm -rf /",
                        "var(--ink)"] {
            let argv = try SessionAgent.renderArguments(
                target: TestHost.target, session: "deck", appearance: .dark, background: hostile)
            XCTAssertFalse(argv.contains("--background"), hostile)
            XCTAssertFalse(argv.contains(hostile), hostile)
        }
    }

    func testBothHexFormsAreAccepted() {
        XCTAssertNotNil(SessionAgent.validateHexColour("#abc"))
        XCTAssertNotNil(SessionAgent.validateHexColour("#AABBCC"))
        XCTAssertNil(SessionAgent.validateHexColour("abc"))
        XCTAssertNil(SessionAgent.validateHexColour("#abcd"))
        XCTAssertNil(SessionAgent.validateHexColour(""))
    }

    func testATrailingNewlineIsRejected() {
        // NSRegularExpression is ICU, where `$` matches at the end of input OR
        // just before a final newline — so a `$`-anchored pattern accepted
        // "#aabbcc\n". Nothing in the current path produces a trailing newline,
        // which is exactly what would have kept the hole quiet.
        XCTAssertNil(SessionAgent.validateHexColour("#aabbcc\n"))
        XCTAssertNil(SessionAgent.validateHexColour("#abc\n"))
        XCTAssertNil(SessionAgent.validateHexColour("#aabbcc\n--theme dark"))
    }

    // MARK: - The NaN case, folded in from PR #21's security review

    func testANaNMTimeDoesNotForceARenderOnEveryPoll() {
        // `NaN != NaN` is true, so without the isFinite guard the gate would
        // report a change forever and reload the document every two seconds.
        func state(_ mtime: Double?) -> SessionState {
            SessionState(session: "deck", phase: .working, gate: nil, alive: true,
                         reason: nil, lastEvent: "PreToolUse", transcriptMTime: mtime)
        }
        XCTAssertFalse(SessionPaneModel.shouldRender(from: state(.nan), to: state(.nan)))
        XCTAssertFalse(SessionPaneModel.shouldRender(from: state(1_000), to: state(.nan)))
    }
}

extension PaneCanvasTests {
    /// The round trip the lift depends on. A new colour conversion is exactly
    /// the kind of code that looks right and is subtly transposed.
    func testOKLCHRoundTripsThroughRGB() {
        for colour in [RGB(red: 0.086, green: 0.063, blue: 0.043),
                       RGB(red: 0.99, green: 0.99, blue: 0.98),
                       RGB(red: 0.8, green: 0.1, blue: 0.1),
                       RGB(red: 0.1, green: 0.4, blue: 0.9),
                       RGB(red: 0, green: 0, blue: 0),
                       RGB(red: 1, green: 1, blue: 1)] {
            let back = colour.toOKLCH().toRGB()
            XCTAssertEqual(back.red, colour.red, accuracy: 0.002, colour.hexString)
            XCTAssertEqual(back.green, colour.green, accuracy: 0.002, colour.hexString)
            XCTAssertEqual(back.blue, colour.blue, accuracy: 0.002, colour.hexString)
        }
    }

    func testTheLiftIsSubtleRatherThanAJumpToGrey() {
        // The first implementation mixed toward white in linear light and took
        // this background to #494847 — a quarter of the way up the scale, and
        // neutral. The lift has to stay in the theme.
        let warmNearBlack = RGB(red: 0.086, green: 0.063, blue: 0.043)
        let lifted = warmNearBlack.lightened(by: 0.06)

        XCTAssertLessThan(lifted.relativeLuminance, 0.05,
                          "the canvas is no longer a dark surface: \(lifted.hexString)")
        XCTAssertGreaterThan(lifted.relativeLuminance, warmNearBlack.relativeLuminance)
    }

    func testTheLiftKeepsChromaRatherThanWashingItOut() {
        // Mixing toward white pulls chroma out; raising L does not. This is the
        // difference between carrying the theme across and greying it.
        let warm = RGB(red: 0.16, green: 0.11, blue: 0.07)
        let lifted = warm.lightened(by: 0.06)

        XCTAssertGreaterThan(lifted.toOKLCH().c, warm.toOKLCH().c * 0.9,
                             "the lift desaturated the theme")
    }
}


/// The `#` in a hex colour is a shell comment character, and ssh hands its
/// joined argv to the REMOTE shell. Unquoted, `--background #2b1d12` arrived as
/// `--background` with the value eaten — session-view exited 2 and Deck's pane
/// sat on "Loading the conversation…" forever with the failure swallowed.
final class RemoteShellQuotingTests: XCTestCase {
    func testTheColourSurvivesTheRemoteShell() throws {
        let argv = try SessionAgent.renderArguments(
            target: TestHost.target, session: "deck", appearance: .dark, background: "#2b1d12")
        let value = try XCTUnwrap(argv.last)

        XCTAssertEqual(value, "'#2b1d12'",
                       "an unquoted # is a comment to the remote shell")
    }

    func testTheQuotingCannotItselfBeEscaped() {
        // Quoting is only safe because the allowlist admits no quote character —
        // a hex colour cannot contain one, so there is nothing to break out.
        for hostile in ["#fff' ; rm -rf /", "#fff'", "'", "#ff'f"] {
            XCTAssertNil(SessionAgent.validateHexColour(hostile), hostile)
        }
    }

    func testTheOtherRemoteArgumentsNeedNoQuoting() throws {
        // The session name and the theme are allowlisted to characters the shell
        // leaves alone, so they travel bare — quoting them would be noise.
        let argv = try SessionAgent.renderArguments(target: TestHost.target, session: "deck", appearance: .dark)
        XCTAssertTrue(argv.contains("deck"))
        XCTAssertTrue(argv.contains("dark"))
        XCTAssertFalse(argv.contains { $0.contains("'") })
    }
}

extension PaneCanvasTests {
    /// THE BUG: the canvas always moved toward white, so in light mode it
    /// converged on the background and every session came out `#ffffff` — the
    /// theme erased. an operator running light mode saw a white pane on white.
    func testTheCanvasMovesAwayFromTheBackgroundInBothAppearances() {
        let nearWhite = RGB(red: 0.98, green: 0.97, blue: 0.92)
        let nearBlack = RGB(red: 0.10, green: 0.09, blue: 0.04)

        let light = nearWhite.canvasTint(for: .light, lift: ContentView.canvasLift,
                                         chroma: ContentView.canvasChroma)
        let dark = nearBlack.canvasTint(for: .dark, lift: ContentView.canvasLift,
                                        chroma: ContentView.canvasChroma)

        XCTAssertLessThan(light.relativeLuminance, nearWhite.relativeLuminance,
                          "a light canvas must move DARKER, away from white: \(light.hexString)")
        XCTAssertGreaterThan(dark.relativeLuminance, nearBlack.relativeLuminance,
                             "a dark canvas must move lighter, away from black: \(dark.hexString)")
    }

    func testALightCanvasIsNeverJustWhite() {
        for session in ["deck", "steward", "vivy", "selector"] {
            let bg = ThemeConfiguration.empty.theme(forSession: SessionRef(host: nil, name: session))
                .palette(for: .light).background
            let tint = bg.canvasTint(for: .light, lift: ContentView.canvasLift,
                                     chroma: ContentView.canvasChroma)
            XCTAssertNotEqual(tint.hexString, "#ffffff", session)
            XCTAssertLessThan(tint.relativeLuminance, 0.93,
                              "\(session) canvas is indistinguishable from white: \(tint.hexString)")
        }
    }

    func testTheHueSurvivesTheTint() {
        // Chroma is raised so the theme reads as a colour rather than as grey.
        let warm = RGB(red: 0.98, green: 0.96, blue: 0.91)
        let tint = warm.canvasTint(for: .light, lift: ContentView.canvasLift,
                                   chroma: ContentView.canvasChroma)
        XCTAssertGreaterThan(tint.toOKLCH().c, warm.toOKLCH().c,
                             "the tint lost the theme's hue")
    }
}

/// ssh negotiates compression ONCE, when the ControlMaster is established, and
/// every channel over that master inherits it. So `-C` on a connection sharing
/// the terminal's master either does nothing (terminal opened first) or
/// compresses interactive keystrokes (render opened first) — neither is what
/// was wanted. The render gets its own master instead.
final class RenderTransportTests: XCTestCase {
    func testTheRenderDoesNotShareTheTerminalsControlMaster() throws {
        let render = try SessionAgent.renderArguments(
            target: TestHost.target, session: "deck", appearance: .dark, controlPath: "/tmp/deck-%r@%h")
        let state = try SessionAgent.arguments(
            target: TestHost.target, session: "deck", verb: ["state"], controlPath: "/tmp/deck-%r@%h")

        let renderPath = try XCTUnwrap(render.first { $0.hasPrefix("ControlPath=") })
        let statePath = try XCTUnwrap(state.first { $0.hasPrefix("ControlPath=") })

        XCTAssertNotEqual(renderPath, statePath,
                          "a shared master would swallow the render's compression")
        XCTAssertTrue(renderPath.hasSuffix("-render"))
    }

    func testOnlyTheRenderCompresses() throws {
        // The terminal carries keystrokes, where latency matters more than
        // volume, and state is a few hundred bytes where compression is pure
        // overhead.
        XCTAssertTrue(try SessionAgent.renderArguments(
            target: TestHost.target, session: "deck", appearance: .dark).contains("-C"))
        XCTAssertFalse(try SessionAgent.arguments(
            target: TestHost.target, session: "deck", verb: ["state"]).contains("-C"))
        XCTAssertFalse(try sshArguments(target: TestHost.target, tmuxSession: "deck").contains("-C"))
    }
}

