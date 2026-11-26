import CryptoKit
import Foundation

/// The envelope Deck signs for a Library signed item act — approve, decline,
/// or a model choice — per the Library protocol contract's "Signed item
/// acts" section (knowledge PR #1293, commit dfc79579; not yet merged, so
/// this mirrors that still-unmerged text rather than citing a file in this
/// repo). The Library rebuilds this exact byte sequence from its own state —
/// the item it holds, the body it just received, and the `signed-at` that
/// travelled with the act — and refuses the act when the signature does not
/// verify against it, or when a hashed or named field no longer matches what
/// it holds (409 `stale`). Deck must reproduce the same bytes for the same
/// reason a checksum must: one byte off and the signature never verifies.
enum LibraryItemActSignature {
    enum Action: String {
        case approve, decline, model
    }

    /// A field that cannot be signed because it carries a line break — the
    /// envelope's own format refuses one line's text bleeding into the next.
    enum FieldError: Error, Equatable, LocalizedError {
        case containsNewline(field: String)

        var errorDescription: String? {
            switch self {
            case .containsNewline(let field):
                return "The \(field) cannot be signed: it contains a line break."
            }
        }
    }

    /// The literal `convivy-item-act/1` envelope: UTF-8, every line ending
    /// in a single `\n` including the last, these fields in this exact
    /// order, no spaces around the colon. `specification` and
    /// `definitionOfDone` are hashed exactly as stored, with no trimming —
    /// an absent or empty value's line carries an empty value after the
    /// colon, never the word `none` (knowledge PR #1293, review round:
    /// `specification-sha256:`, `definition-of-done-sha256:`, `maturity:`
    /// and `model:` all read this way when their field is null or empty).
    /// `maturity` and `model` are the item's own current values, the ones
    /// the person saw before this act, never the write's target state.
    /// `bodyBytes` must be the exact bytes the HTTP request body will
    /// carry; an empty body hashes as `{}`.
    ///
    /// Throws `FieldError.containsNewline` for `itemId`, `maturity`, or
    /// `model` carrying `\n` or `\r` — the three raw fields that are not
    /// hashed, so a line break in any of them would otherwise bleed into
    /// the next line of the envelope.
    static func bytes(
        action: Action, itemId: String, specification: String?, definitionOfDone: String?,
        maturity: String?, model: String?, bodyBytes: Data, signedAt: Date
    ) throws -> Data {
        let maturityValue = maturity ?? ""
        let modelValue = model ?? ""
        try refuseNewline(itemId, field: "item id")
        try refuseNewline(maturityValue, field: "maturity")
        try refuseNewline(modelValue, field: "model")

        let text = "convivy-item-act/1\n"
            + "action:\(action.rawValue)\n"
            + "item:\(itemId)\n"
            + "specification-sha256:\(hexSHA256OrEmpty(specification))\n"
            + "definition-of-done-sha256:\(hexSHA256OrEmpty(definitionOfDone))\n"
            + "maturity:\(maturityValue)\n"
            + "model:\(modelValue)\n"
            + "body-sha256:\(hexSHA256(bodyBytes))\n"
            + "signed-at:\(SignedSaveEnvelope.signedAtString(signedAt))\n"
        return Data(text.utf8)
    }

    /// 64 lowercase hex characters of `data`'s SHA-256.
    private static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `hexSHA256` of `text`'s UTF-8 bytes, or an empty string when `text`
    /// is null or empty — the contract's reading of a stored
    /// `specification` or `definition_of_done` that was never filled in.
    private static func hexSHA256OrEmpty(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        return hexSHA256(Data(text.utf8))
    }

    private static func refuseNewline(_ value: String, field: String) throws {
        guard !value.contains("\n"), !value.contains("\r") else {
            throw FieldError.containsNewline(field: field)
        }
    }
}
