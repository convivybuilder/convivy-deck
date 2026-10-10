import Foundation

/// A credential presented on a Keel call, opaque outside this stack.
///
/// Wrapped rather than passed as a bare `String` so a call site can hold one
/// without every place that formats it for a log or a crash report having to
/// remember to redact it — `description` does that once, here, rather than
/// leaving it to be remembered at each call site.
struct KeelToken: Equatable, Sendable {
    let value: String

    init(_ value: String) {
        self.value = value
    }
}

extension KeelToken: CustomStringConvertible {
    var description: String { "<redacted>" }
}

extension KeelToken: CustomDebugStringConvertible {
    /// `String(reflecting:)` and `debugPrint` take this path rather than
    /// `description`, so redacting only `description` would leave both
    /// printing the raw value.
    var debugDescription: String { "<redacted>" }
}

extension KeelToken: CustomReflectable {
    /// `dump(_:)` AND LLDB's `po` READ STORED PROPERTIES THROUGH `Mirror`,
    /// WHICH BYPASSES BOTH CONVERSIONS ABOVE. Without this, `dump` on a
    /// `KeelCallerKind` prints the token's raw value under an `agent:`
    /// child — measured, not assumed:
    ///
    ///     ▿ KeelCallerKind.agent
    ///       ▿ agent: <redacted>
    ///         - value: "SUPER-SECRET-VALUE"
    ///
    /// The `<redacted>` on that middle line is `description` working exactly
    /// as intended and being stepped straight past. Presenting an EMPTY
    /// child collection is what closes it, because there is then no stored
    /// property for reflection to walk to.
    ///
    /// Any stored property added to this type is exposed again the moment it
    /// exists unless it is also kept out of this mirror. There is no
    /// compile-time check for that, which is why the mirror is written as
    /// "expose nothing" rather than as a list of fields to hide.
    var customMirror: Mirror { Mirror(self, children: []) }
}

/// Which kind of caller a Keel request is made as.
///
/// `deck/decisions/0002-the-deck-to-bosun-adjacency-becomes-a-typed-wire-interface`
/// ("Two kinds of caller"): an operator's own client and a dispatched agent
/// both reach the Keel, and they do not hold the same authority. **They are
/// told apart by WHICH TOKEN IS PRESENTED** — an operator's session token, or
/// an agent token the Bosun issued and recorded a permission set against.
///
/// NOT MODELED BY PEER IDENTITY OR ACCOUNT, AND THAT OMISSION IS DELIBERATE.
/// Which account connected is a question the peer's user id can answer; which
/// AUTHORITY the caller holds is a different question, and peer identity
/// cannot supply it, because an operator's client and a dispatched agent can
/// run in the same account. This type carries only the token distinction —
/// no field for a uid, a process owner, or any other peer-identity signal —
/// so a caller can't reach for the wrong axis by habit because this type
/// happened to expose it.
///
/// **IN STAGE ONE THIS IS POLICY, NOT CONTAINMENT.** Stage one has no account
/// boundary, so an agent holding general command execution already has
/// whatever its operator has — presenting an agent token doesn't grant less
/// than the operator could already reach by other means. What the distinction
/// buys today is that the wire RECORDS which kind of caller asked and refuses
/// on the grant that kind carries; it is not a security boundary, and no code
/// in this stack should be read as though it were one. Do not build a
/// call site that trusts this type to keep an agent out of something an
/// operator could do — nothing here enforces that yet.
enum KeelCallerKind: Equatable, Sendable {
    /// An operator working the app directly.
    case operatorSession(KeelToken)
    /// A dispatched agent, presenting a token the Bosun issued and recorded a
    /// permission set against.
    case agent(KeelToken)
}

extension KeelCallerKind {
    /// The token this caller presents, whichever kind it is.
    ///
    /// Added for `KeelClient`, which needs exactly this and nothing else to
    /// attach the right credential to a request: this type's own doc says
    /// the two kinds are told apart by WHICH token is presented, not by a
    /// header naming the kind, so the transport never needs to know which
    /// case it was given — only what to put in the `Authorization` header.
    var token: KeelToken {
        switch self {
        case .operatorSession(let token), .agent(let token):
            return token
        }
    }
}
