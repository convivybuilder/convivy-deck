import XCTest
@testable import Deck

/// `RailGroupHeadingRow.totalText(for:)` — CQ·195's wording for the group
/// heading's own Slate total at 216pt, pure so it is testable without a
/// view the same way `SlateBadge.label`/`SlateBadgeGlyph.ink` already are.
final class RailGroupHeadingTotalTextTests: XCTestCase {
    func testSingularCountReadsAsOneOpenAsk() {
        XCTAssertEqual(RailGroupHeadingRow.totalText(for: .count(1)), "1 open ask")
    }

    func testPluralCountReadsAsNOpenAsks() {
        XCTAssertEqual(RailGroupHeadingRow.totalText(for: .count(3)), "3 open asks")
    }

    /// `.unknown` keeps `SlateBadge.label`'s own bare `?` — a reading the
    /// mini could not establish is not a count to put a word on.
    func testUnknownKeepsTheBareQuestionMark() {
        XCTAssertEqual(RailGroupHeadingRow.totalText(for: .unknown), "?")
    }
}
