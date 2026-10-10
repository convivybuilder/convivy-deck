import XCTest
@testable import Deck

/// The frame strips — the status line above the conversation and the composer
/// below it — carry the session's canvas colour pushed halfway to the
/// appearance's extreme, so the chrome reads as the same surface as the page.
final class FrameTintTests: XCTestCase {

    private func tint(_ canvas: String?, _ appearance: Appearance) -> RGB? {
        SessionPaneView.frameTintRGB(canvas: canvas, appearance: appearance)
    }

    func testLightModeMovesHalfwayToWhite() {
        // deck's light canvas. Each channel lands halfway between it and 1.0.
        let canvas = parseHexColor("#f4efdc")!
        let t = tint("#f4efdc", .light)!
        XCTAssertEqual(t.red, (canvas.red + 1) / 2, accuracy: 0.0005)
        XCTAssertEqual(t.green, (canvas.green + 1) / 2, accuracy: 0.0005)
        XCTAssertEqual(t.blue, (canvas.blue + 1) / 2, accuracy: 0.0005)
        // And it is genuinely lighter than the canvas it borders.
        XCTAssertGreaterThan(t.red, canvas.red)
    }

    func testDarkModeMovesHalfwayToBlack() {
        let canvas = parseHexColor("#221a12")!
        let t = tint("#221a12", .dark)!
        XCTAssertEqual(t.red, canvas.red / 2, accuracy: 0.0005)
        XCTAssertEqual(t.green, canvas.green / 2, accuracy: 0.0005)
        XCTAssertEqual(t.blue, canvas.blue / 2, accuracy: 0.0005)
        XCTAssertLessThan(t.red, canvas.red, "a dark frame moves toward black")
    }

    func testTheTintKeepsTheCanvasHueRatherThanGreyingIt() {
        // deck is warm: red > green > blue. Halfway to white must preserve that
        // ordering, or the frame would read as grey chrome rather than as the
        // same theme a shade along.
        let t = tint("#f4efdc", .light)!
        XCTAssertGreaterThan(t.red, t.green)
        XCTAssertGreaterThan(t.green, t.blue)
    }

    func testNoCanvasOrBadHexIsNilNotAGuess() {
        XCTAssertNil(tint(nil, .light))
        XCTAssertNil(tint("", .light))
        XCTAssertNil(tint("not-a-colour", .dark))
        XCTAssertNil(tint("#12", .light))
    }

    func testTheSameCanvasTintsOppositeWaysByAppearance() {
        // The one canvas moves lighter in light mode and darker in dark, so the
        // direction is the appearance's, not the colour's.
        let light = tint("#808080", .light)!
        let dark = tint("#808080", .dark)!
        XCTAssertGreaterThan(light.red, dark.red)
    }
}
