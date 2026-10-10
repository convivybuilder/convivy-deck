import Foundation

/// The signed form of a Slate answer: the payload Deck signs, and the `--sig`
/// value `session-agent slate-send` carries to the crew.
///
/// The format was agreed with the Bosun and is recorded on
/// issue_01M442JF8P939AMJQZPKAF1D0S (comments 4771, 4772 and 4775). The verifier
/// checks the signature over the decoded payload bytes as delivered, so the bytes
/// `payload` returns are the bytes that get signed, and nothing re-serialises them.
enum SlateAnswerSignature {
    /// The `capabilities` entry `session-agent slate <name>` lists once the host's
    /// session-agent accepts `--sig`. A host without it gets unsigned answers.
    static let capability = "slate-sig-v1"

    /// The payload's fields. Encoded with sorted keys and no whitespace.
    private struct Payload: Encodable {
        let card: String
        let crew: String
        let host: String
        let nonce: String
        let text: String
        let ts: String
        let v: Int
    }

    /// The exact bytes Deck signs: UTF-8 JSON, keys sorted, no whitespace.
    /// `/` stays unescaped, so the bytes match what a reader of the spec expects.
    static func payload(card: String, crew: String, host: String, text: String,
                        nonce: Data, ts: Date) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Every field is a String or the Int 1, so encoding cannot fail.
        return try! encoder.encode(Payload(
            card: card, crew: crew, host: host, nonce: base64url(nonce), text: text,
            ts: timestamp(ts), v: 1))
    }

    /// The `--sig` value: `base64url(payload).base64url(signature)`. The signature
    /// is the DER-encoded ECDSA P-256 signature over SHA-256 of the payload, which
    /// `SigningKey.sign` produces.
    static func sign(_ payload: Data, with key: SigningKey) throws -> String {
        "\(base64url(payload)).\(base64url(try key.sign(payload)))"
    }

    /// Python's `str.strip()` with no argument. It removes every character that
    /// `str.isspace()` accepts, which is wider than Foundation's whitespace set:
    /// it includes U+001C through U+001F. `slate-send` strips the draft this way,
    /// so the signed text must strip the same way.
    static func pythonStrip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isPythonSpace($0) }),
              let last = scalars.lastIndex(where: { !isPythonSpace($0) }) else { return "" }
        return String(Substring(scalars[first...last]))
    }

    /// Whether `value` has the shape `sign` produces: two non-empty base64url
    /// parts split by one dot. The value crosses to the remote shell as an ssh
    /// argument, so it gets the same argv check card ids get.
    static func isWellFormed(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { base64urlAlphabet.contains($0) }
        }
    }

    /// 16 random bytes from the system generator, a CSPRNG on Apple platforms.
    static func randomNonce() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// RFC 3339 UTC with whole seconds, such as `2026-10-05T04:40:00Z`.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Base64 with the URL alphabet and no padding.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let base64urlAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// The code points Python's `str.isspace()` accepts.
    private static func isPythonSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }
}
