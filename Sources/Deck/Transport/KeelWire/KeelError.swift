import Foundation

/// A Keel call's outcome, from the perspective of code that has to decide
/// what happened and what to do next.
///
/// This is the type the not-yet-built transport layer will throw once it
/// exists (see the file header on `KeelEnvelope.swift` — nothing in Deck
/// calls a Keel endpoint yet). It's `Error`-conforming so that shape is ready
/// when that layer lands.
///
/// TWO CASES, AND THE SPLIT BETWEEN THEM IS THE WHOLE POINT.
/// `platform/contracts/deck-keel-wire` (open as `knowledge#303`, lifted out of
/// `deck/decisions/0002-the-deck-to-bosun-adjacency-becomes-a-typed-wire-interface`
/// alongside this work — read the decision record until that lands)
/// lists `transport` as one of nine `kind` values, but it cannot arrive the
/// way the other eight do. The other eight are things the SERVER said, and
/// this build reads them off a decoded envelope's `error.kind` field. If the
/// socket or the SSH forward failed, no envelope reached this build to decode
/// — the failure is precisely what kept the JSON body from arriving. So
/// `.transport` isn't decoded here at all; it's `.transport`, a case a
/// caller constructs directly, the moment the future transport layer learns
/// its write or its read failed. `KeelErrorKind` (the eight-case, wire-decoded
/// enum) deliberately has no `.transport` case for the same reason — see its
/// own doc comment.
///
/// Getting this backwards — modeling `transport` as something this build
/// waits to decode — would mean Deck's most common failure today (an
/// unreachable mini, a stale ControlMaster, a wedged ssh child; see
/// `SSHProcessRunner` and `SSHControlSocket`) silently never gets reported
/// once this wire replaces the ssh calls those exist to guard, because the
/// one path that actually produces that failure is a path this type would
/// have no case built to receive it on.
enum KeelError: Error, Equatable, Sendable {
    /// The endpoint answered: a full envelope arrived with `ok: false`. The
    /// verb was reached and it declined, per whatever `kind` names — see
    /// `KeelErrorKind`'s own doc comment for what each kind means and why
    /// `refused` is not the same thing as `unauthenticated`/`forbidden`.
    ///
    /// `message` is included for a person to read in a log or an alert.
    /// SWITCH ON `kind`, NEVER ON `message` — the wire contract says
    /// `message` "MUST NOT be branched on", and this codebase does not do it
    /// anywhere in this stack. `detail` is the free-form object the verb's
    /// own contract may attach; see `KeelJSONValue`.
    case server(kind: KeelErrorKind, message: String, detail: KeelJSONValue?)

    /// The socket or the forward failed. RAISED BY THE CLIENT, NEVER
    /// DECODED — see this type's own doc comment above for why no decode
    /// path produces this case. `message` is whatever the transport layer
    /// observed (an ssh exit code, a timeout, a connection refusal); it's
    /// Deck's own words, not a server's, since no server was reached.
    case transport(String)
}
