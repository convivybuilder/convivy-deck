import Foundation

/// A JSON value whose shape isn't known until it's read.
///
/// `platform/contracts/deck-keel-wire`'s envelope carries `detail` on a
/// server error as "a free-form JSON object" — the wire contract deliberately
/// does not say what's in it, because each verb's own contract (the
/// session-agent API, the Library's document routes, and whatever else lands
/// on this wire later) decides that for itself. A `Decodable` struct with
/// named fields would force every caller of the shared envelope to agree on
/// one `detail` shape up front, which is exactly the coupling the envelope is
/// designed not to have. This type decodes whatever arrives — object, array,
/// string, number, bool, or null — and lets a verb-specific reader dig into
/// it only if it chooses to.
///
/// Boxes rather than bridges to `Any`: `Any` isn't `Equatable`, which is what
/// a fixture-based decode test needs to assert on, and isn't `Sendable`,
/// which a value crossing from a background transport call to the main actor
/// eventually will need to be.
indirect enum KeelJSONValue: Equatable, Sendable {
    case string(String)
    /// A JSON number too large for `Double` to hold exactly.
    ///
    /// `Double` carries 53 bits of integer precision, so `9007199254740993`
    /// decodes back as `9007199254740992` — silently, with no error and no
    /// signal that a digit was dropped. `detail` is free-form and nothing on
    /// the wire constrains it to small numbers, so a verb attaching a large
    /// id, an inode, or a nanosecond timestamp would be corrupted on the way
    /// through rather than refused. `Int64` is tried first for that reason;
    /// `.number` keeps the values `Int64` genuinely cannot hold, which are
    /// the fractional and out-of-range ones where `Double` is the right
    /// answer anyway.
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case object([String: KeelJSONValue])
    case array([KeelJSONValue])
    case null
}

extension KeelJSONValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            // Tried first among the scalars because a JSON bool and a JSON
            // number are genuinely distinct here — MEASURED on Swift 6.3.3 /
            // macOS 26: `decode(Bool.self)` on `0`/`1` throws, and
            // `decode(Double.self)` on `true`/`false` throws, so neither
            // order coerces one into the other today. An earlier version of
            // this comment claimed the ordering DEFENDED against such a
            // coercion; it does not, because there is none to defend against
            // on this platform. The order is kept because `Bool` first is
            // the cheapest correct arrangement and does not depend on that
            // behaviour staying true.
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            // BEFORE `Double`, and the order is the whole fix: `Double`
            // accepts every JSON integer, so trying it first would swallow
            // `9007199254740993` and hand back `9007199254740992` with no
            // error. Asking for `Int64` first means an integer that fits
            // stays exact, and only what `Int64` cannot represent falls
            // through to the lossy case.
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([KeelJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: KeelJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a JSON value Deck's client understands")
        }
    }
}
