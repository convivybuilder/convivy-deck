import XCTest
@testable import Deck

/// `SessionState.decode`'s `asks_open`/`slate_error` reading, and
/// `SlateBadge`'s pure rules drawn from it — issue_01M3WPYSH0S1FZVZ6P3YMNJGXW.
final class SlateBadgeTests: XCTestCase {

    private func decode(_ json: String) -> SessionState {
        SessionState.decode(Data(json.utf8), fallbackSession: "deck")
    }

    // MARK: - Decode

    /// A mini that predates the Slate sends neither key. `nil`, never
    /// `.count(0)` — collapsing the two would draw an old mini's silence as
    /// an honest zero.
    func testAbsentFieldsDecodeToNil() {
        let state = decode(#"{"state":"idle"}"#)
        XCTAssertNil(state.asksOpen)
    }

    /// The ordinary positive reading.
    func testPresentCountDecodes() {
        let state = decode(#"{"state":"idle","asks_open":1}"#)
        XCTAssertEqual(state.asksOpen, .count(1))
    }

    /// Checked after an answer is sent, the DoD's own second half: the rail
    /// reads a real zero, not a hidden field.
    func testZeroCountDecodes() {
        let state = decode(#"{"state":"idle","asks_open":0}"#)
        XCTAssertEqual(state.asksOpen, .count(0))
    }

    /// `asks_open` sent as something that is not a number decodes like any
    /// other unparseable field: absent, not a crash and not a guessed count.
    func testUnparseableCountDecodesToNil() {
        let state = decode(#"{"state":"idle","asks_open":"two"}"#)
        XCTAssertNil(state.asksOpen)
    }

    /// `slate_error`'s mere presence forces `.unknown`, regardless of
    /// whatever `asks_open` carries alongside it — the producer sets both
    /// together (steward epic comment 4615), and a zero the mini could not
    /// vouch for must not read as "nothing waiting."
    func testSlateErrorPresentForcesUnknownEvenBesideAZeroCount() {
        let state = decode(#"{"state":"idle","asks_open":0,"slate_error":"could not read the board"}"#)
        XCTAssertEqual(state.asksOpen, .unknown)
    }

    /// `slate_error: null` still counts as present — the same
    /// presence-not-cast idiom `decodeHeld` uses for `held`.
    func testSlateErrorPresentAsJSONNullStillForcesUnknown() {
        let state = decode(#"{"state":"idle","asks_open":3,"slate_error":null}"#)
        XCTAssertEqual(state.asksOpen, .unknown)
    }

    // MARK: - `SlateBadge.isVisible`

    func testNilDrawsNoBadge() {
        XCTAssertFalse(SlateBadge.isVisible(nil))
    }

    func testZeroCountDrawsNoBadge() {
        XCTAssertFalse(SlateBadge.isVisible(.count(0)))
    }

    func testPositiveCountDrawsABadge() {
        XCTAssertTrue(SlateBadge.isVisible(.count(1)))
    }

    /// The one case that draws regardless of what the count says: an
    /// unreadable board is never silent, even if it happened to carry a zero.
    func testUnknownAlwaysDrawsABadge() {
        XCTAssertTrue(SlateBadge.isVisible(.unknown))
    }

    // MARK: - Labels

    func testCountLabelIsTheBareDigit() {
        XCTAssertEqual(SlateBadge.label(for: .count(3)), "3")
    }

    func testUnknownLabelIsAQuestionMark() {
        XCTAssertEqual(SlateBadge.label(for: .unknown), "?")
    }

    func testAccessibilityLabelNamesTheCount() {
        XCTAssertEqual(SlateBadge.accessibilityLabel(for: .count(1)), "1 ask waiting on you")
        XCTAssertEqual(SlateBadge.accessibilityLabel(for: .count(4)), "4 asks waiting on you")
    }

    func testAccessibilityLabelForUnknownNamesTheState() {
        XCTAssertEqual(SlateBadge.accessibilityLabel(for: .unknown), "Slate state unknown")
    }

    // MARK: - Ink

    /// Two different inks for the two different meanings — a summons draws
    /// differently from a caution, the same split `RunModelMarkGlyph` makes
    /// between an override and a fail-over.
    func testCountAndUnknownResolveDifferentInks() {
        let surface = RGB(red: 0.92, green: 0.92, blue: 0.93)
        let countInk = SlateBadgeGlyph.ink(for: .count(2), on: surface)
        let unknownInk = SlateBadgeGlyph.ink(for: .unknown, on: surface)
        XCTAssertNotEqual(countInk, unknownInk)
    }
}
