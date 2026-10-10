import XCTest
@testable import Deck

/// `KeelError` and `KeelErrorKind`: the taxonomy's two traps that live at the
/// type level rather than in any one decode — that `transport` can only be
/// raised by client code, never decoded off a server response, and that
/// `refused` cannot be collapsed with `unauthenticated`/`forbidden`.
final class KeelErrorTests: XCTestCase {

    private struct Widget: Decodable, Equatable {
        let name: String
    }

    // MARK: - Trap 3: `transport` is client-raised and cannot arrive in an envelope

    /// `KeelError.transport` is an ordinary enum case — a caller constructs
    /// it directly, with no decoder in the loop. This is the "constructor,
    /// not a decode path" the wire contract calls for: a transport failure
    /// means the socket or the forward failed, which is exactly the
    /// situation with NO JSON body to decode a `kind` from.
    func testTransportIsConstructedDirectlyRatherThanDecoded() {
        let error = KeelError.transport("ssh exited 255: Connection refused")
        guard case .transport(let message) = error else {
            return XCTFail("expected .transport")
        }
        XCTAssertEqual(message, "ssh exited 255: Connection refused")
    }

    /// The other half of the same trap: no matter what a decoded envelope's
    /// error looks like, `KeelEnvelope.get()` can only ever throw
    /// `KeelError.server` — never `.transport`. This is checked across every
    /// one of the eight decodable kinds plus an unrecognized one, so the
    /// claim isn't resting on a single case that happens to work.
    ///
    /// THIS WOULD FAIL IF `KeelEnvelope.get()`'S ERROR PATH EVER LEARNED TO
    /// PRODUCE `.transport` — e.g. if a future edit added a case there that
    /// mapped some `kind` string onto `.transport` instead of `.server`,
    /// which is precisely the "backwards" reading the contract warns against:
    /// Deck's most common real failure (an unreachable mini) would then
    /// silently stop being reported by the one code path built to raise it,
    /// because that path would have been quietly rerouted through a decoder
    /// that is never on the receiving end of that failure in the first place.
    func testDecodedEnvelopesNeverThrowTransportFromGet() throws {
        let kinds = [
            "unauthenticated", "forbidden", "no_such_method", "no_such_session",
            "no_such_path", "refused", "contained", "unavailable", "something_brand_new",
        ]
        for kind in kinds {
            let raw = Data("""
            {"ok": false, "error": {"kind": "\(kind)", "message": "irrelevant"}}
            """.utf8)
            let envelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw)
            XCTAssertThrowsError(try envelope.get()) { error in
                guard case KeelError.server = error else {
                    return XCTFail("kind \(kind) threw \(error), expected .server")
                }
            }
        }
    }

    // MARK: - Trap 4: refused, unauthenticated and forbidden are not the same thing

    /// A caller's real branching, mirroring the three distinct actions the
    /// wire contract names: re-authenticate on `unauthenticated`, never
    /// retry as this identity on `forbidden`, surface the business decline
    /// on `refused`. Three kinds, three actions — no `default:` catch-all
    /// that would let two of them collapse together unnoticed.
    private enum ClientAction: Equatable {
        case reauthenticate
        case neverRetryAsThisIdentity
        case surfaceBusinessDecline
        case other
    }

    private func action(for kind: KeelErrorKind) -> ClientAction {
        switch kind {
        case .unauthenticated: return .reauthenticate
        case .forbidden: return .neverRetryAsThisIdentity
        case .refused: return .surfaceBusinessDecline
        case .noSuchMethod, .noSuchSession, .noSuchPath, .contained, .unavailable, .unrecognized:
            return .other
        }
    }

    /// THIS WOULD FAIL IF `refused` WERE EVER FOLDED INTO THE SAME BRANCH AS
    /// `unauthenticated` OR `forbidden`. The wire's own reasoning is that
    /// they mean different things to a caller — the verb ran and declined,
    /// versus the verb never ran at all — and this test decodes all three
    /// off fixture envelopes (not bare enum literals) and checks that each
    /// routes to its own distinct action.
    func testUnauthenticatedForbiddenAndRefusedRouteToThreeDistinctActions() throws {
        func decodedKind(_ kind: String) throws -> KeelErrorKind {
            let raw = Data("""
            {"ok": false, "error": {"kind": "\(kind)", "message": "irrelevant"}}
            """.utf8)
            let envelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: raw)
            guard case .error(let decoded, _, _) = envelope else {
                XCTFail("expected .error")
                return .unrecognized("decode failed")
            }
            return decoded
        }

        let unauthenticated = try decodedKind("unauthenticated")
        let forbidden = try decodedKind("forbidden")
        let refused = try decodedKind("refused")

        let actions: Set<ClientAction> = [
            action(for: unauthenticated), action(for: forbidden), action(for: refused),
        ]
        XCTAssertEqual(actions.count, 3, "unauthenticated, forbidden and refused must route distinctly")
        XCTAssertEqual(action(for: unauthenticated), .reauthenticate)
        XCTAssertEqual(action(for: forbidden), .neverRetryAsThisIdentity)
        XCTAssertEqual(action(for: refused), .surfaceBusinessDecline)
    }

    // MARK: - Basic taxonomy sanity

    /// Every one of the nine named kinds decodes to a distinct, stable case
    /// — pinned so a typo in the string-matching `switch` inside
    /// `KeelErrorKind.init(from:)` (e.g. `"no_such_method"` vs.
    /// `"no_such_methd"`) fails loudly here rather than surfacing as a kind
    /// silently downgrading to `.unrecognized` in the field.
    func testAllEightWireKindsDecodeToTheirOwnCase() throws {
        let expectations: [(String, KeelErrorKind)] = [
            ("unauthenticated", .unauthenticated),
            ("forbidden", .forbidden),
            ("no_such_method", .noSuchMethod),
            ("no_such_session", .noSuchSession),
            ("no_such_path", .noSuchPath),
            ("refused", .refused),
            ("contained", .contained),
            ("unavailable", .unavailable),
        ]
        for (raw, expected) in expectations {
            let json = Data("""
            {"ok": false, "error": {"kind": "\(raw)", "message": "irrelevant"}}
            """.utf8)
            let envelope = try JSONDecoder().decode(KeelEnvelope<Widget>.self, from: json)
            guard case .error(let kind, _, _) = envelope else {
                return XCTFail("expected .error for \(raw)")
            }
            XCTAssertEqual(kind, expected, "wire string \(raw)")
        }
    }
}
