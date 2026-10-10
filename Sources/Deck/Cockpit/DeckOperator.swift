import Foundation

/// The `owner` label Deck presents on a Library write.
///
/// **A COORDINATION LABEL, NOT A CREDENTIAL.** `library-protocol`'s
/// `_claim_owner` doc is explicit that `owner` says who to attribute a claim
/// to and authorizes nothing — the bearer token does that. So this needs to
/// be stable and honest, not secret: stable, so everything this laptop writes
/// is recognizably from the same holder; honest, because
/// `deck/decisions/0001` settles that Deck is where a person presses a
/// button, not an agent acting on its own — the label should read as a human
/// at a specific machine, not invent an agent identity Deck has none of.
enum DeckOperator {
    /// `userName`/`hostName` are parameters rather than read directly so the
    /// derivation is testable without depending on the running machine's own
    /// identity.
    static func label(userName: String = NSUserName(),
                      hostName: String = ProcessInfo.processInfo.hostName) -> String {
        "deck:\(userName)@\(hostName)"
    }
}
