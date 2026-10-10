import Foundation

/// A host's optional recovery-runbook link (CQ·124) — entered in Settings ›
/// Hosts, never hand-edited in `theme.json` and never hard-coded to one
/// operator's runbook. Exactly two shapes are accepted: a KB id Deck already
/// knows how to open in its own side pane (`DeckOpenRef.validateKBId`'s
/// charset), or an `https` URL opened in the browser.
///
/// NARROWER THAN `ExternalLink.allowedSchemes` ON PURPOSE. This link is
/// clicked from a logged-out alert, which sits outside any pane and has no
/// error text to show if it goes somewhere unintended, unlike a link clicked
/// inside a pane. `ExternalLink` accepts `http` and `mailto`; this accepts
/// neither.
enum RunbookLink: Equatable {
    case kb(id: String)
    case url(URL)

    /// Validates raw text typed into the Settings › Hosts field. Trims
    /// whitespace, then accepts a KB id or an `https://` URL; anything
    /// else — empty text, `http://`, a bare hostname, a `javascript:` or
    /// `file:` URL — is refused. An invalid runbook link costs only this
    /// field, the same "a field costs itself" rule `ThemeConfiguration`
    /// already applies to `crewsRoot`: never the rest of the host entry.
    static func parse(_ raw: String) -> RunbookLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let kbId = DeckOpenRef.validateKBId(trimmed) {
            return .kb(id: kbId)
        }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              url.host != nil
        else { return nil }
        return .url(url)
    }

    /// The form persisted to `theme.json` and reparsed with `parse` on
    /// every use — the same "never trust a stored value further than the
    /// gate that produced it" discipline `DeckOpenRef` already applies to
    /// `HostEntry.user` wherever it reaches a security boundary.
    var stored: String {
        switch self {
        case .kb(let id): return id
        case .url(let url): return url.absoluteString
        }
    }
}
