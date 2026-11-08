import XCTest
@testable import Deck

/// CQ·194: a group heading's VoiceOver label never spoke its own summed
/// Slate badge (CQ·192 drew it, but only visually), so a reader heard a
/// group's fold state but never that it had asks waiting. Covers
/// `RailGroupHeadingRow.accessibilityLabel(name:state:badge:)` directly,
/// the pure function all three of the row's labels now compose through.
///
/// FAILED ON THE CODE BEFORE THIS ITEM: `RailGroupHeadingRow` had no
/// `accessibilityLabel(name:state:badge:)` function at all, so this file
/// could not compile — `swift build --build-tests` failed with "type
/// 'RailGroupHeadingRow' has no member 'accessibilityLabel'". See the PR
/// body for the exact command and output.
final class RailGroupHeadingAccessibilityTests: XCTestCase {
    func testOpenWithNoBadgeIsUnchangedFromToday() {
        XCTAssertEqual(
            RailGroupHeadingRow.accessibilityLabel(name: "Alpha", state: "open", badge: nil),
            "Alpha, open")
    }

    func testFoldedWithNoBadgeIsUnchangedFromToday() {
        XCTAssertEqual(
            RailGroupHeadingRow.accessibilityLabel(name: "Alpha", state: "folded", badge: nil),
            "Alpha, folded")
    }

    func testNoStateWithNoBadgeIsUnchangedFromToday() {
        XCTAssertEqual(
            RailGroupHeadingRow.accessibilityLabel(name: "Alpha", state: nil, badge: nil),
            "Alpha")
    }

    func testCountZeroDrawsNoBadgeSameAsNil() {
        XCTAssertEqual(
            RailGroupHeadingRow.accessibilityLabel(name: "Alpha", state: "open", badge: .count(0)),
            "Alpha, open")
    }

    func testOpenWithSingularCountAppendsTheBadge() {
        XCTAssertEqual(
            RailGroupHeadingRow.accessibilityLabel(name: "Alpha", state: "open", badge: .count(1)),
            "Alpha, open, 1 ask waiting on you")
    }

    func testOpenWithPluralCountAppendsTheBadge() {
        XCTAssertEqual(
            RailGroupHeadingRow.accessibilityLabel(name: "Alpha", state: "open", badge: .count(3)),
            "Alpha, open, 3 asks waiting on you")
    }

    func testFoldedWithPluralCountAppendsTheBadge() {
        XCTAssertEqual(
            RailGroupHeadingRow.accessibilityLabel(name: "Alpha", state: "folded", badge: .count(3)),
            "Alpha, folded, 3 asks waiting on you")
    }

    func testUnknownAppendsStateUnknownEvenFolded() {
        XCTAssertEqual(
            RailGroupHeadingRow.accessibilityLabel(name: "Alpha", state: "folded", badge: .unknown),
            "Alpha, folded, Slate state unknown")
    }

    func testUnknownAppendsStateUnknownOpen() {
        XCTAssertEqual(
            RailGroupHeadingRow.accessibilityLabel(name: "Alpha", state: "open", badge: .unknown),
            "Alpha, open, Slate state unknown")
    }
}
