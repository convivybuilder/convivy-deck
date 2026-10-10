import XCTest
@testable import Deck

final class HexColorTests: XCTestCase {
    func testParsesWithLeadingHash() {
        XCTAssertEqual(parseHexColor("#FF0000"), RGB(red: 1, green: 0, blue: 0))
    }

    func testParsesWithoutLeadingHash() {
        XCTAssertEqual(parseHexColor("00FF00"), RGB(red: 0, green: 1, blue: 0))
    }

    func testIsCaseInsensitive() {
        XCTAssertEqual(parseHexColor("#0000ff"), parseHexColor("#0000FF"))
    }

    func testRejectsWrongLength() {
        XCTAssertNil(parseHexColor("#FFF"))
        XCTAssertNil(parseHexColor("#FF00000"))
    }

    func testRejectsNonHexCharacters() {
        XCTAssertNil(parseHexColor("#GGGGGG"))
    }
}
