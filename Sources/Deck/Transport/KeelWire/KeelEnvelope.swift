import Foundation

/// The response envelope every Keel endpoint uses —
/// `platform/contracts/deck-keel-wire`'s wire form, verbatim from
/// `deck/decisions/0002-the-deck-to-bosun-adjacency-becomes-a-typed-wire-interface`:
///
/// ```
/// {"ok": true,  "result": { … }}
/// {"ok": false, "error": {"kind": "<taxonomy>", "message": "<human text>", "detail": { … }}}
/// ```
///
/// **NOTHING IN THIS FILE CALLS A KEEL ENDPOINT.** This is work item 1 of the
/// Deck-to-Keel typed wire epic (`issue_01M0K1SAGMJTZMNZ95TKXHE3YS`): the
/// shared decode/error stack, written once against fixture JSON so both
/// future Keel client stacks (a Bosun client for process control, a Library
/// client for documents) decode through the same types rather than growing
/// their own. No socket, no HTTP call, no retrofit of `SessionAgent` or
/// `LibraryClient` lands here — see the PR body for what that means for
/// review.
///
/// Generic over the result payload so each verb decodes its OWN result shape
/// through this one envelope, without this file needing to know what any
/// verb returns. `Result: Decodable` is the only requirement; a verb's result
/// type is free to be anything JSON-decodable, from an empty struct to a full
/// document body.
enum KeelEnvelope<Result: Decodable> {
    /// `ok: true`. Carries the decoded `result`.
    case ok(Result)
    /// `ok: false`. Carries the server's own error — see `KeelErrorKind` for
    /// what `kind` means and `KeelError` for why this case, unlike
    /// `KeelError.transport`, is exactly what a decoded envelope CAN produce.
    case error(kind: KeelErrorKind, message: String, detail: KeelJSONValue?)
}

extension KeelEnvelope: Decodable {
    private enum CodingKeys: String, CodingKey {
        case ok, result, error
    }

    private struct ErrorBody: Decodable {
        let kind: KeelErrorKind
        let message: String
        let detail: KeelJSONValue?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Bool.self, forKey: .ok) else {
            let body = try container.decode(ErrorBody.self, forKey: .error)
            self = .error(kind: body.kind, message: body.message, detail: body.detail)
            return
        }
        self = .ok(try container.decode(Result.self, forKey: .result))
    }
}

extension KeelEnvelope {
    /// The decoded `result`, or the server's own decline thrown as
    /// `KeelError.server`.
    ///
    /// NEVER THROWS `KeelError.transport`. This method only ever runs once an
    /// envelope has already been decoded from bytes that arrived — a
    /// transport failure is what prevents those bytes from arriving at all,
    /// so by the time this method is reachable, transport has already
    /// succeeded. A caller that wants to raise `.transport` does so directly,
    /// at the point where the read or the write actually failed, before an
    /// envelope exists to call this on. See `KeelError`'s own doc comment.
    func get() throws -> Result {
        switch self {
        case .ok(let result):
            return result
        case .error(let kind, let message, let detail):
            throw KeelError.server(kind: kind, message: message, detail: detail)
        }
    }
}
