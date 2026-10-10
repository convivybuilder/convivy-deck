import XCTest
@testable import Deck

/// `KeelEnvelope`'s decode, against fixture JSON only — no socket, no ssh, no
/// live endpoint. See `KeelEnvelope.swift`'s file header for why: this is
/// work item 1 of the Deck-to-Keel typed wire epic, the shared decode/error
/// stack, written before either future endpoint exists to call.
final class KeelEnvelopeTests: XCTestCase {

    /// A stand-in result payload. `KeelEnvelope` is generic over whatever a
    /// verb returns; this fixture exercises the envelope without committing
    /// to any real verb's shape.
    private struct Widget: Decodable, Equatable {
        let name: String
    }

    // MARK: - The happy path

    func testDecodesAnOkEnvelopeIntoItsResultType() throws {
        let raw = Data("""
        {"ok": true, "result": {"name": "crew-row"}}
        """.utf8)
        let envelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw)
        guard case .ok(let widget) = envelope else {
            return XCTFail("expected .ok, got \(envelope)")
        }
        XCTAssertEqual(widget, Widget(name: "crew-row"))
    }

    func testGetReturnsTheResultOnAnOkEnvelope() throws {
        let raw = Data("""
        {"ok": true, "result": {"name": "crew-row"}}
        """.utf8)
        let envelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw)
        XCTAssertEqual(try envelope.get(), Widget(name: "crew-row"))
    }

    func testDecodesAnErrorEnvelopeWithDetail() throws {
        let raw = Data("""
        {"ok": false, "error": {"kind": "no_such_session", "message": "no such session: crew-3",
         "detail": {"session": "crew-3"}}}
        """.utf8)
        let envelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw)
        guard case .error(let kind, let message, let detail) = envelope else {
            return XCTFail("expected .error, got \(envelope)")
        }
        XCTAssertEqual(kind, .noSuchSession)
        XCTAssertEqual(message, "no such session: crew-3")
        XCTAssertEqual(detail, .object(["session": .string("crew-3")]))
    }

    func testDecodesAnErrorEnvelopeWithNoDetail() throws {
        let raw = Data("""
        {"ok": false, "error": {"kind": "unavailable", "message": "not yet"}}
        """.utf8)
        let envelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw)
        guard case .error(_, _, let detail) = envelope else {
            return XCTFail("expected .error, got \(envelope)")
        }
        XCTAssertNil(detail)
    }

    func testGetThrowsKeelErrorServerOnAnErrorEnvelope() throws {
        let raw = Data("""
        {"ok": false, "error": {"kind": "refused", "message": "the merge is already in flight"}}
        """.utf8)
        let envelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw)
        XCTAssertThrowsError(try envelope.get()) { error in
            guard case KeelError.server(let kind, let message, _) = error else {
                return XCTFail("expected .server, got \(error)")
            }
            XCTAssertEqual(kind, .refused)
            XCTAssertEqual(message, "the merge is already in flight")
        }
    }

    // MARK: - Trap 1: an unrecognized kind must not break the client

    /// The taxonomy can grow — two crews implement it, the Bosun and the
    /// Library, and either may ship a kind this build predates. Decoding
    /// must not fail just because the `kind` string isn't one of the nine
    /// this build knows; it has to carry the raw string forward instead. A
    /// client built against an OLDER taxonomy meeting a NEWER server is
    /// exactly the shape a Deck rebuild lag produces, so this is not a
    /// hypothetical: it is the ordinary case of two independently-deployed
    /// programs whose releases don't line up.
    func testAnUnrecognizedKindStillDecodesRatherThanFailingTheWholeEnvelope() throws {
        let raw = Data("""
        {"ok": false, "error": {"kind": "quarantined", "message": "a kind this build has never seen"}}
        """.utf8)
        let envelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw)
        guard case .error(let kind, _, _) = envelope else {
            return XCTFail("expected .error, got \(envelope)")
        }
        XCTAssertEqual(kind, .unrecognized("quarantined"))
    }

    /// A `kind` string that HAPPENS to spell `"transport"` is still just an
    /// unrecognized string to the decoder — it is not promoted to
    /// `KeelError.transport`. See `KeelErrorKind`'s own doc comment: no
    /// decode path produces `.transport` under any input, including this one.
    /// A server sending the literal string `"transport"` would violate the
    /// contract (it means no envelope should have arrived at all), and this
    /// pins that even a contract-violating server can't make this client
    /// silently misclassify a decoded response as a client-side transport
    /// failure it never actually had.
    func testAKindStringSpelledTransportIsUnrecognizedNotPromoted() throws {
        let raw = Data("""
        {"ok": false, "error": {"kind": "transport", "message": "should never really arrive this way"}}
        """.utf8)
        let envelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw)
        guard case .error(let kind, _, _) = envelope else {
            return XCTFail("expected .error, got \(envelope)")
        }
        XCTAssertEqual(kind, .unrecognized("transport"))
    }

    // MARK: - Trap 2: `message` must never be branched on

    /// THE MECHANISM, NOT THE OUTCOME. `route` below switches on `kind`
    /// alone — its signature doesn't even accept a `message` argument, so it
    /// is structurally incapable of branching on one. Decoding two envelopes
    /// that share a `kind` but carry different `message` text and reaching
    /// the identical routed action for both proves a caller can rely on
    /// `kind` as the only switchable field, which is what the wire contract
    /// requires ("`message` is for a person to read and MUST NOT be branched
    /// on. `kind` is the only field a client may switch on."). A test that
    /// only asserted one message string decoded would say nothing about this.
    private enum RoutedAction: Equatable {
        case declinedByBusinessLogic
        case somethingElse
    }

    private func route(_ kind: KeelErrorKind) -> RoutedAction {
        switch kind {
        case .refused: return .declinedByBusinessLogic
        default: return .somethingElse
        }
    }

    func testSameKindDifferentMessageRoutesIdentically() throws {
        let first = Data("""
        {"ok": false, "error": {"kind": "refused", "message": "the merge is already in flight"}}
        """.utf8)
        let second = Data("""
        {"ok": false, "error": {"kind": "refused", "message": "a completely different sentence, in French: refusé"}}
        """.utf8)
        let firstEnvelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: first)
        let secondEnvelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: second)
        guard case .error(let firstKind, _, _) = firstEnvelope,
              case .error(let secondKind, _, _) = secondEnvelope else {
            return XCTFail("expected both to decode as .error")
        }
        XCTAssertEqual(route(firstKind), route(secondKind))
        XCTAssertEqual(route(firstKind), .declinedByBusinessLogic)
    }
    /// A MALFORMED ENVELOPE MUST FAIL LOUDLY, NEVER DEGRADE. `ok: true` with
    /// no `result` and `ok: false` with no `error` are the two shapes a
    /// half-built or half-broken server is most likely to emit, and both are
    /// plausible enough to slip past a decoder that treats missing keys as
    /// empty. Throwing is the right answer: there is no honest value to
    /// return, and inventing one would put a fabricated result in front of a
    /// caller that cannot tell.
    func testAnOkEnvelopeWithNoResultThrowsRatherThanDecodingEmpty() {
        let raw = Data(#"{"ok": true}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw)) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
        }
    }

    func testAnErrorEnvelopeWithNoErrorThrowsRatherThanDecodingEmpty() {
        let raw = Data(#"{"ok": false}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw)) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
        }
    }

    func testAnEnvelopeWithNoOkThrows() {
        let raw = Data(#"{"result": {"name": "w"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw))
    }

}
