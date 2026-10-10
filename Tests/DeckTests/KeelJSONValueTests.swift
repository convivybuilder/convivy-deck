import XCTest
@testable import Deck

/// `KeelJSONValue`: the free-form box `KeelEnvelope`'s `detail` field
/// decodes into, so a caller can read an error's extra payload without this
/// shared stack declaring its shape up front.
final class KeelJSONValueTests: XCTestCase {

    private func decode(_ json: String) throws -> KeelJSONValue {
        try JSONDecoder().decode(KeelJSONValue.self, from: Data(json.utf8))
    }

    func testDecodesAString() throws {
        XCTAssertEqual(try decode("\"crew-3\""), .string("crew-3"))
    }

    func testAPlainIntegerDecodesExactlyRatherThanAsADouble() throws {
        XCTAssertEqual(try decode("42"), .integer(42))
    }

    /// THE MECHANISM, NOT THE OUTCOME. `9007199254740993` is the smallest
    /// integer `Double` cannot represent: rounded to `Double` it becomes
    /// `...992`, so a decoder that reached `Double` first would return a
    /// wrong number with no error. Asserting `.integer(9007199254740993)`
    /// fails if the `Int64` branch is ever moved below `Double`, which is
    /// the specific regression this guards.
    func testAnIntegerBeyondDoublesPrecisionSurvivesExactly() throws {
        XCTAssertEqual(try decode("9007199254740993"), .integer(9_007_199_254_740_993))
        // The proof the guard is not vacuous: the value this would have been.
        XCTAssertNotEqual(Double(9_007_199_254_740_993), 9_007_199_254_740_993.0.nextUp)
        XCTAssertEqual(Double(9_007_199_254_740_993), 9_007_199_254_740_992.0)
    }

    func testAFractionalNumberStillDecodesAsANumber() throws {
        XCTAssertEqual(try decode("1.5"), .number(1.5))
    }

    func testANumberBeyondInt64FallsThroughToDouble() throws {
        guard case .number(let d) = try decode("1e300") else {
            return XCTFail("expected .number for a value Int64 cannot hold")
        }
        XCTAssertEqual(d, 1e300)
    }

    func testDecodesABool() throws {
        XCTAssertEqual(try decode("true"), .bool(true))
        XCTAssertEqual(try decode("false"), .bool(false))
    }

    func testDecodesNull() throws {
        XCTAssertEqual(try decode("null"), .null)
    }

    func testDecodesAnArray() throws {
        XCTAssertEqual(try decode("[1, \"two\", true]"),
                       .array([.integer(1), .string("two"), .bool(true)]))
    }

    func testDecodesANestedObject() throws {
        let value = try decode("""
        {"session": "crew-3", "attempts": 2, "reasons": ["timeout", "refused"], "fatal": false, "note": null}
        """)
        XCTAssertEqual(value, .object([
            "session": .string("crew-3"),
            "attempts": .integer(2),
            "reasons": .array([.string("timeout"), .string("refused")]),
            "fatal": .bool(false),
            "note": .null,
        ]))
    }

    /// `detail`'s whole reason for existing: an envelope carries an object
    /// this shared stack has never declared a struct for, and it still
    /// decodes intact — a verb-specific reader can dig into it, and a
    /// generic one can at least log it, without either forcing the other's
    /// shape onto this file.
    func testAnUndeclaredShapeSurvivesThroughTheEnvelopesDetailField() throws {
        struct Widget: Decodable, Equatable { let name: String }
        let raw = Data("""
        {"ok": false, "error": {"kind": "contained", "message": "outside admitted roots",
         "detail": {"requested": "/etc/passwd", "roots": ["\(TestHost.homeRoot)/Convivy"], "depth": 3}}}
        """.utf8)
        let envelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw)
        guard case .error(_, _, let detail) = envelope else {
            return XCTFail("expected .error")
        }
        XCTAssertEqual(detail, .object([
            "requested": .string("/etc/passwd"),
            "roots": .array([.string("\(TestHost.homeRoot)/Convivy")]),
            "depth": .integer(3),
        ]))
    }
}
