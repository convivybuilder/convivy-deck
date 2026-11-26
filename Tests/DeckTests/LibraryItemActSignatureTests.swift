import CryptoKit
import XCTest
@testable import Deck

/// `LibraryItemActSignature`, pinned to the worked example from the Library
/// protocol contract's "Signed item acts" section (knowledge PR #1293,
/// commit dfc79579): a test key (private scalar 32 bytes of `0x11`), one
/// item, and an Approve and a Model act over it. Both example signatures were
/// verified with `openssl dgst -verify` against these exact envelope bytes
/// before this file was written, so a failure here means the envelope this
/// code builds no longer matches the one that signature was made over.
final class LibraryItemActSignatureTests: XCTestCase {
    private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private let itemId = "issue_01KZ0000000000000000000000"
    private let specification = "Every invoice is reconciled by Friday."
    private let definitionOfDone = "- The reconcile job reads zero unmatched rows on Friday."
    private let signedAt = ISO8601DateFormatter().date(from: "2026-11-13T23:30:00Z")!

    private let specificationDigest = "9abdb6aeea0504824cbd3f8ebf02811274bc729839d42314483851c4e8f6b4c4"
    private let definitionOfDoneDigest = "942d47922b41b0ac13b711df0de75a6ccaeb18d0edad364abae61b063d0cc6a2"
    private let approveBodyDigest = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
    private let modelBodyDigest = "dd355026aee07c8520e1663e2635425bcd10f7be2ebc32ef6860ad5433012123"

    /// The test key's public point, as the 65-byte uncompressed x963 bytes —
    /// the suffix of the worked example's SubjectPublicKeyInfo DER.
    private let examplePublicKeyX963 = Data(base64Encoded:
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEAhfmF/C2RDkoJ4+WmZ5pojpPLBUr321s32bluAKC1O0ZSn3ry5dxLS3aPKhaqHZaVvRfx1hZllLyiXxlMG5XlA=="
    )!.suffix(65)

    private func publicKey() throws -> P256.Signing.PublicKey {
        try P256.Signing.PublicKey(x963Representation: examplePublicKeyX963)
    }

    // MARK: - The worked example, byte for byte

    private let expectedApproveEnvelope = """
        convivy-item-act/1
        action:approve
        item:issue_01KZ0000000000000000000000
        specification-sha256:9abdb6aeea0504824cbd3f8ebf02811274bc729839d42314483851c4e8f6b4c4
        definition-of-done-sha256:942d47922b41b0ac13b711df0de75a6ccaeb18d0edad364abae61b063d0cc6a2
        maturity:proposed
        model:
        body-sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a
        signed-at:2026-11-13T23:30:00Z\n
        """

    private let expectedModelEnvelope = """
        convivy-item-act/1
        action:model
        item:issue_01KZ0000000000000000000000
        specification-sha256:9abdb6aeea0504824cbd3f8ebf02811274bc729839d42314483851c4e8f6b4c4
        definition-of-done-sha256:942d47922b41b0ac13b711df0de75a6ccaeb18d0edad364abae61b063d0cc6a2
        maturity:approved
        model:
        body-sha256:dd355026aee07c8520e1663e2635425bcd10f7be2ebc32ef6860ad5433012123
        signed-at:2026-11-13T23:30:00Z\n
        """

    /// Approve: `maturity:proposed` (the item's own current maturity, the
    /// one the person saw — never the write's target of `approved`),
    /// `model:` empty (no model choice set), body `{}`.
    func testTheApproveEnvelopeMatchesTheWorkedExampleExactly() throws {
        let envelope = try LibraryItemActSignature.bytes(
            action: .approve, itemId: itemId, specification: specification,
            definitionOfDone: definitionOfDone, maturity: "proposed", model: nil,
            bodyBytes: Data("{}".utf8), signedAt: signedAt)
        XCTAssertEqual(String(decoding: envelope, as: UTF8.self), expectedApproveEnvelope)
    }

    /// Model: `maturity:approved` (the item's own current maturity at the
    /// time of this act), `model:` empty (no model was set before this act —
    /// the envelope signs what was there before, not the "opus" being set),
    /// body `{"model":"opus","reason":"needs judgment"}`.
    func testTheModelEnvelopeMatchesTheWorkedExampleExactly() throws {
        let envelope = try LibraryItemActSignature.bytes(
            action: .model, itemId: itemId, specification: specification,
            definitionOfDone: definitionOfDone, maturity: "approved", model: nil,
            bodyBytes: Data(#"{"model":"opus","reason":"needs judgment"}"#.utf8), signedAt: signedAt)
        XCTAssertEqual(String(decoding: envelope, as: UTF8.self), expectedModelEnvelope)
    }

    /// The four digests the worked example names, each pinned on its own so
    /// a failure here points straight at which hash drifted.
    func testTheWorkedExamplesFourDigestsAppearInTheEnvelopes() throws {
        let approve = try LibraryItemActSignature.bytes(
            action: .approve, itemId: itemId, specification: specification,
            definitionOfDone: definitionOfDone, maturity: "proposed", model: nil,
            bodyBytes: Data("{}".utf8), signedAt: signedAt)
        let text = String(decoding: approve, as: UTF8.self)
        XCTAssertTrue(text.contains("specification-sha256:\(specificationDigest)"))
        XCTAssertTrue(text.contains("definition-of-done-sha256:\(definitionOfDoneDigest)"))
        XCTAssertTrue(text.contains("body-sha256:\(approveBodyDigest)"))

        let model = try LibraryItemActSignature.bytes(
            action: .model, itemId: itemId, specification: specification,
            definitionOfDone: definitionOfDone, maturity: "approved", model: nil,
            bodyBytes: Data(#"{"model":"opus","reason":"needs judgment"}"#.utf8), signedAt: signedAt)
        XCTAssertTrue(String(decoding: model, as: UTF8.self).contains("body-sha256:\(modelBodyDigest)"))
    }

    // MARK: - The worked example's own signatures verify

    /// Verified with CryptoKit against the example public key — never
    /// against a signature this code itself produced, since that would only
    /// prove the signer and verifier agree with each other, not with the
    /// contract's own worked example.
    func testTheApproveExampleSignatureVerifiesAgainstTheApproveEnvelope() throws {
        let envelope = try LibraryItemActSignature.bytes(
            action: .approve, itemId: itemId, specification: specification,
            definitionOfDone: definitionOfDone, maturity: "proposed", model: nil,
            bodyBytes: Data("{}".utf8), signedAt: signedAt)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded:
            "MEUCIDopJypszcBdI1XVY/VG/DJzta+8Pas8hFXaSiz95JygAiEAy6S/MhFz+DbgfeyhmL5ntci0oMBhe4eaADk8mP85eZI="
        )!)
        XCTAssertTrue(try publicKey().isValidSignature(signature, for: envelope))
    }

    func testTheModelExampleSignatureVerifiesAgainstTheModelEnvelope() throws {
        let envelope = try LibraryItemActSignature.bytes(
            action: .model, itemId: itemId, specification: specification,
            definitionOfDone: definitionOfDone, maturity: "approved", model: nil,
            bodyBytes: Data(#"{"model":"opus","reason":"needs judgment"}"#.utf8), signedAt: signedAt)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded:
            "MEUCIHv+lQOvDF3cJaKIiHsziS25rAOzSWed7krLfegjpxBSAiEA/tubLaMUUazje1Y6yZLi89DhanlzAZBoi8ShTEGz5Io="
        )!)
        XCTAssertTrue(try publicKey().isValidSignature(signature, for: envelope))
    }

    /// A signature over a tampered envelope must not verify — the baseline
    /// that confirms the two tests above are not vacuously true.
    func testATamperedEnvelopeDoesNotVerify() throws {
        var envelope = try LibraryItemActSignature.bytes(
            action: .approve, itemId: itemId, specification: specification,
            definitionOfDone: definitionOfDone, maturity: "proposed", model: nil,
            bodyBytes: Data("{}".utf8), signedAt: signedAt)
        envelope.append(contentsOf: [0x00])
        let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded:
            "MEUCIDopJypszcBdI1XVY/VG/DJzta+8Pas8hFXaSiz95JygAiEAy6S/MhFz+DbgfeyhmL5ntci0oMBhe4eaADk8mP85eZI="
        )!)
        XCTAssertFalse(try publicKey().isValidSignature(signature, for: envelope))
    }

    // MARK: - An absent or empty value's line carries an empty value, never `none`

    func testNilSpecificationDefinitionOfDoneMaturityAndModelLeaveTheirLinesEmpty() throws {
        let envelope = try LibraryItemActSignature.bytes(
            action: .approve, itemId: itemId, specification: nil, definitionOfDone: nil,
            maturity: nil, model: nil, bodyBytes: Data("{}".utf8), signedAt: signedAt)
        let text = String(decoding: envelope, as: UTF8.self)
        XCTAssertTrue(text.contains("specification-sha256:\n"))
        XCTAssertTrue(text.contains("definition-of-done-sha256:\n"))
        XCTAssertTrue(text.contains("maturity:\n"))
        XCTAssertTrue(text.contains("model:\n"))
    }

    func testEmptySpecificationAndDefinitionOfDoneLeaveTheirLinesEmptyTheSameAsNil() throws {
        let envelope = try LibraryItemActSignature.bytes(
            action: .approve, itemId: itemId, specification: "", definitionOfDone: "",
            maturity: "proposed", model: nil, bodyBytes: Data("{}".utf8), signedAt: signedAt)
        let text = String(decoding: envelope, as: UTF8.self)
        XCTAssertTrue(text.contains("specification-sha256:\n"))
        XCTAssertTrue(text.contains("definition-of-done-sha256:\n"))
    }

    // MARK: - A line break cannot be signed

    func testAnItemIdContainingANewlineIsRefused() {
        XCTAssertThrowsError(try LibraryItemActSignature.bytes(
            action: .approve, itemId: "issue_1\nrogue:field", specification: nil, definitionOfDone: nil,
            maturity: nil, model: nil, bodyBytes: Data("{}".utf8), signedAt: signedAt)) { error in
            guard case LibraryItemActSignature.FieldError.containsNewline(let field) = error else {
                return XCTFail("expected containsNewline, got \(error)")
            }
            XCTAssertEqual(field, "item id")
        }
    }

    func testAMaturityContainingACarriageReturnIsRefused() {
        XCTAssertThrowsError(try LibraryItemActSignature.bytes(
            action: .approve, itemId: itemId, specification: nil, definitionOfDone: nil,
            maturity: "proposed\rrogue:field", model: nil, bodyBytes: Data("{}".utf8), signedAt: signedAt)) { error in
            guard case LibraryItemActSignature.FieldError.containsNewline(let field) = error else {
                return XCTFail("expected containsNewline, got \(error)")
            }
            XCTAssertEqual(field, "maturity")
        }
    }

    func testAModelContainingANewlineIsRefused() {
        XCTAssertThrowsError(try LibraryItemActSignature.bytes(
            action: .model, itemId: itemId, specification: nil, definitionOfDone: nil,
            maturity: nil, model: "opus\nrogue:field", bodyBytes: Data("{}".utf8), signedAt: signedAt)) { error in
            guard case LibraryItemActSignature.FieldError.containsNewline(let field) = error else {
                return XCTFail("expected containsNewline, got \(error)")
            }
            XCTAssertEqual(field, "model")
        }
    }

    /// A specification or definition of done is hashed, never placed raw in
    /// the envelope, so a line break inside either one is not a signing
    /// hazard at all — only the three raw fields above are.
    func testASpecificationContainingANewlineSignsFine() throws {
        XCTAssertNoThrow(try LibraryItemActSignature.bytes(
            action: .approve, itemId: itemId, specification: "Line one.\nLine two.", definitionOfDone: nil,
            maturity: nil, model: nil, bodyBytes: Data("{}".utf8), signedAt: signedAt))
    }
}
