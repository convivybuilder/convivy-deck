import Foundation

/// The nine-kind error taxonomy `platform/contracts/deck-keel-wire` defines
/// (open as `knowledge#303`, lifted out of
/// `deck/decisions/0002-the-deck-to-bosun-adjacency-becomes-a-typed-wire-interface`
/// alongside this file — that record is the normative source until the
/// contract lands, and it is what this type implements).
///
/// EIGHT OF THE NINE ARRIVE ON THE WIRE AND ARE MODELED HERE. THE NINTH,
/// `transport`, NEVER DOES — see `KeelError.transport` for where it lives and
/// why it can't be a case of this type. `transport` means the socket or the
/// forward failed, and when that happens no envelope reaches this decoder at
/// all: there is no JSON body to carry a `kind` string, because the failure
/// is what kept the body from arriving in the first place. A case here named
/// `.transport` would invite a decode path that can never actually be taken,
/// which is worse than no case — it would read as "the server told us
/// `transport`" when the truth is the opposite, that the server was never
/// reached to tell us anything.
///
/// `refused` IS NOT THE SAME AS `unauthenticated` OR `forbidden`, AND
/// COLLAPSING THEM WOULD DESTROY THE ONE DISTINCTION A CALLER ACTUALLY NEEDS.
/// `refused` means the verb RAN and declined per its own contract — a
/// business decision, made after the call was accepted. `unauthenticated`
/// and `forbidden` mean the verb NEVER RAN: no resolvable identity, or an
/// identity that resolved but lacks the capability. Three different actions
/// follow: re-authenticate on a 401, never retry as this identity on a 403,
/// and surface the business decline as-is on a refusal. Do not add a shared
/// computed property or case grouping that treats these as one "rejected"
/// notion anywhere in this codebase — that grouping is the exact defect this
/// wire exists to remove, one layer up, from Deck's pre-wire stderr-grepping
/// classifier (`SSHStderrClassifier`), which had no way to tell them apart at
/// all.
enum KeelErrorKind: Equatable, Sendable {
    /// No resolvable identity. The wire's HTTP 401.
    case unauthenticated
    /// Identity resolved and lacks the capability. The wire's HTTP 403.
    case forbidden
    /// The endpoint does not serve this verb.
    case noSuchMethod
    /// The named session does not exist.
    case noSuchSession
    /// A named path does not exist.
    case noSuchPath
    /// The verb ran and declined, per its own contract. See the type's own
    /// doc comment above for why this is not `unauthenticated`/`forbidden`.
    case refused
    /// A path resolved outside the admitted roots.
    case contained
    /// The endpoint is up but cannot serve this now.
    case unavailable
    /// A `kind` string this build doesn't recognize.
    ///
    /// THE TAXONOMY CAN GROW WITHOUT A CLIENT REBUILD. Two crews implement
    /// this wire — the Bosun for process control, the Library for documents —
    /// and each may add a kind the other, or an older Deck build, has never
    /// heard of. Decoding an unrecognized string as a hard failure would mean
    /// a perfectly well-formed envelope stops decoding at all the moment
    /// either side ships a new kind first; carrying it as data instead means
    /// the raw string survives to a caller that wants to log it, even though
    /// no `switch` in this build has a case for it.
    case unrecognized(String)
}

extension KeelErrorKind: Decodable {
    /// The wire's `kind` field is a bare JSON string, not an object — this
    /// reads it as a single-value container rather than expecting a keyed one.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "unauthenticated": self = .unauthenticated
        case "forbidden": self = .forbidden
        case "no_such_method": self = .noSuchMethod
        case "no_such_session": self = .noSuchSession
        case "no_such_path": self = .noSuchPath
        case "refused": self = .refused
        case "contained": self = .contained
        case "unavailable": self = .unavailable
        default: self = .unrecognized(raw)
        }
    }
}
