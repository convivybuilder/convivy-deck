import CryptoKit
import Foundation
import Security
import XCTest
@testable import Deck

/// A software P-256 key standing in for the Secure Enclave, which cannot run
/// under XCTest. `failure` makes `sign` throw, the way a cancelled prompt does,
/// and every message it signs is logged so a test can see whether it signed at all.
private final class SoftwareAnswerKey: SigningKey, @unchecked Sendable {
    let key = P256.Signing.PrivateKey()
    var failure: Error?
    private let lock = NSLock()
    private var messages: [Data] = []

    var signedMessages: [Data] { lock.lock(); defer { lock.unlock() }; return messages }
    var publicKeyX963: Data { key.publicKey.x963Representation }
    var dataRepresentation: Data { key.rawRepresentation }

    func sign(_ message: Data) throws -> Data {
        lock.lock()
        messages.append(message)
        lock.unlock()
        if let failure { throw failure }
        return try key.signature(for: message).derRepresentation
    }
}

/// Verifies a DER ECDSA P-256 signature with Security.framework, a verifier that
/// shares no code with CryptoKit's signer.
private func verifies(_ derSignature: Data, over message: Data, publicKeyX963: Data) -> Bool {
    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        kSecAttrKeySizeInBits as String: 256,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(publicKeyX963 as CFData, attributes as CFDictionary, &error) else {
        return false
    }
    return SecKeyVerifySignature(key, .ecdsaSignatureMessageX962SHA256,
                                 message as CFData, derSignature as CFData, &error)
}

/// Undoes `SlateAnswerSignature.base64url`, adding back the padding.
private func fromBase64url(_ text: String) -> Data? {
    var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while standard.count % 4 != 0 { standard += "=" }
    return Data(base64Encoded: standard)
}

/// Splits a `--sig` value into the payload bytes and the signature bytes.
private func splitSig(_ sig: String) -> (payload: Data, signature: Data)? {
    let parts = sig.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, let payload = fromBase64url(parts[0]),
          let signature = fromBase64url(parts[1]) else { return nil }
    return (payload, signature)
}

private let fixedNonce = Data(repeating: 0, count: 16)
private let fixedTime = Date(timeIntervalSince1970: 1_780_000_000)

final class SlateAnswerSignatureTests: XCTestCase {

    // MARK: The payload bytes

    /// Expected bytes match Python's `json.dumps(..., sort_keys=True,
    /// separators=(',', ':'), ensure_ascii=False)` over the same fields, for ASCII
    /// text. Python's default `ensure_ascii=True` would escape non-ASCII text and
    /// this encoder writes it raw, so the two differ only on non-ASCII text, which
    /// this test does not cover. The verifier checks the signature over the bytes
    /// delivered and never re-serialises them, so the bytes this encoder writes are
    /// the ones it must read.
    func testThePayloadIsSortedJSONWithNoWhitespace() {
        let payload = SlateAnswerSignature.payload(
            card: "a-7f3k2q", crew: "deck", host: "macstudio", text: "hi / there",
            nonce: fixedNonce, ts: fixedTime)
        XCTAssertEqual(String(decoding: payload, as: UTF8.self),
                       #"{"card":"a-7f3k2q","crew":"deck","host":"macstudio","nonce":"AAAAAAAAAAAAAAAAAAAAAA","text":"hi / there","ts":"2026-05-28T20:26:40Z","v":1}"#)
    }

    func testTheTextIsWrittenAsItIsSoOnlyTheStrippedStringReachesThePayload() {
        let payload = SlateAnswerSignature.payload(
            card: "a-1", crew: "deck", host: "macstudio",
            text: SlateAnswerSignature.pythonStrip("  line one\n\tline two\n"),
            nonce: fixedNonce, ts: fixedTime)
        let fields = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        XCTAssertEqual(fields?["text"] as? String, "line one\n\tline two")
    }

    /// The nonce and timestamp are fixed by the arguments, so the same inputs
    /// give the same bytes, and a different nonce gives different bytes.
    func testANewNonceChangesThePayload() {
        let a = SlateAnswerSignature.payload(card: "a-1", crew: "deck", host: "macstudio", text: "x",
                                             nonce: fixedNonce, ts: fixedTime)
        let b = SlateAnswerSignature.payload(card: "a-1", crew: "deck", host: "macstudio", text: "x",
                                             nonce: Data(repeating: 1, count: 16), ts: fixedTime)
        XCTAssertNotEqual(a, b)
    }

    func testTheNonceIsSixteenRandomBytesInBase64URLWithNoPadding() {
        let nonce = SlateAnswerSignature.randomNonce()
        XCTAssertEqual(nonce.count, 16)
        let encoded = SlateAnswerSignature.base64url(nonce)
        XCTAssertEqual(encoded.count, 22, "16 bytes encode to 22 characters without padding")
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertNotEqual(SlateAnswerSignature.randomNonce(), nonce)
    }

    func testTheTimestampIsRFC3339UTCToTheSecond() {
        XCTAssertEqual(SlateAnswerSignature.timestamp(fixedTime), "2026-05-28T20:26:40Z")
    }

    // MARK: The signature

    /// The signature verifies over the decoded payload bytes with an independent
    /// verifier, and the `--sig` value is the two base64url parts joined by a dot.
    func testTheSignatureVerifiesOverTheDecodedPayload() throws {
        let signer = SoftwareAnswerKey()
        let payload = SlateAnswerSignature.payload(card: "a-7f3k2q", crew: "deck", host: "macstudio",
                                                   text: "the answer", nonce: fixedNonce, ts: fixedTime)
        let sig = try SlateAnswerSignature.sign(payload, with: signer)
        let parts = try XCTUnwrap(splitSig(sig))
        XCTAssertEqual(parts.payload, payload, "the decoded payload is the bytes that were signed")
        XCTAssertTrue(verifies(parts.signature, over: parts.payload, publicKeyX963: signer.publicKeyX963))
    }

    /// The negative direction: a payload altered by one byte, or a signature from
    /// another key, must not verify.
    func testAlteredPayloadOrAForeignKeyDoesNotVerify() throws {
        let signer = SoftwareAnswerKey()
        let payload = SlateAnswerSignature.payload(card: "a-7f3k2q", crew: "deck", host: "macstudio",
                                                   text: "the answer", nonce: fixedNonce, ts: fixedTime)
        let parts = try XCTUnwrap(splitSig(try SlateAnswerSignature.sign(payload, with: signer)))
        var tampered = payload
        tampered[tampered.count - 3] ^= 0x01
        XCTAssertFalse(verifies(parts.signature, over: tampered, publicKeyX963: signer.publicKeyX963))

        let stranger = SoftwareAnswerKey()
        XCTAssertFalse(verifies(parts.signature, over: parts.payload, publicKeyX963: stranger.publicKeyX963))
    }

    // MARK: The strip

    /// Each expected value is what Python's `str.strip()` returns for the same
    /// input, checked with `python3` on the same code points.
    func testTheStripMatchesPythonOnLeadingAndTrailingWhitespace() {
        XCTAssertEqual(SlateAnswerSignature.pythonStrip("  \t\nhello world\r\n\t "), "hello world")
        XCTAssertEqual(SlateAnswerSignature.pythonStrip("\n\n"), "")
        XCTAssertEqual(SlateAnswerSignature.pythonStrip("   "), "")
        XCTAssertEqual(SlateAnswerSignature.pythonStrip(""), "")
        XCTAssertEqual(SlateAnswerSignature.pythonStrip("a\n\tb"), "a\n\tb", "interior whitespace is kept")
        XCTAssertEqual(SlateAnswerSignature.pythonStrip("\u{1C}\u{1F}x\u{0B}"), "x",
                       "Python strips U+001C to U+001F and vertical tab; Foundation does not strip U+001C")
        XCTAssertEqual(SlateAnswerSignature.pythonStrip("\u{A0}\u{3000}a b\u{2028}"), "a b")
        XCTAssertEqual(SlateAnswerSignature.pythonStrip("\u{200B}kept\u{200B}"), "\u{200B}kept\u{200B}",
                       "Python does not strip the zero-width space")
    }

    // MARK: The argv value

    func testOnlyAWellFormedSignatureIsAccepted() {
        XCTAssertTrue(SlateAnswerSignature.isWellFormed("AAAA-_0.Zz9_-"))
        XCTAssertFalse(SlateAnswerSignature.isWellFormed("AAAA"), "no dot")
        XCTAssertFalse(SlateAnswerSignature.isWellFormed("AA.BB.CC"), "two dots")
        XCTAssertFalse(SlateAnswerSignature.isWellFormed(".BB"), "empty payload part")
        XCTAssertFalse(SlateAnswerSignature.isWellFormed("AA+/.BB"), "standard base64 is not base64url")
        XCTAssertFalse(SlateAnswerSignature.isWellFormed("AA BB.CC"), "a space would split the argv word")
    }
}
