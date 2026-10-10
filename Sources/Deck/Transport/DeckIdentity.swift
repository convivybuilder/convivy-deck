import Foundation

/// The key Deck's own ssh calls offer: `~/.ssh/id_ed25519_deck`. Pairing
/// creates it with no passphrase, because Deck's ssh calls never prompt and a
/// passphrase-protected default identity cannot answer them.
enum DeckIdentity {
    static let fileName = "id_ed25519_deck"

    static func path(home: String = NSHomeDirectory()) -> String {
        "\(home)/.ssh/\(fileName)"
    }
}

/// Every ssh argv Deck builds returns through here. When the Deck key exists,
/// this puts `-i <that key>` in front of the argv; otherwise it returns `argv`
/// unchanged. Adding `-i` does not set `IdentitiesOnly`, so ssh still offers
/// its other identities, and a host that works through the user's ssh config
/// keeps working. The path is absolute, so ssh does not depend on tilde
/// expansion. A leading option always precedes the destination, so ssh reads
/// the rest of the argv as before.
func withDeckIdentity(_ argv: [String], home: String = NSHomeDirectory()) -> [String] {
    let path = DeckIdentity.path(home: home)
    guard FileManager.default.fileExists(atPath: path) else { return argv }
    return ["-i", path] + argv
}
