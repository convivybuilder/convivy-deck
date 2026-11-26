import Foundation
import SwiftUI

/// Turns a plain string into an `AttributedString` whose characters are the
/// input's own, byte for byte, with a `.link` attribute added on the same
/// kinds of reference the session window makes clickable:
///
/// - a web address `NSDataDetector` finds, whose scheme is in
///   `ExternalLink.allowedSchemes` (http, https, mailto);
/// - an absolute path under a host home or a session scratchpad, which
///   becomes `deck-open:?origin=path&ref=…`;
/// - a `[[project/kind/slug]]` knowledge-document link, which becomes
///   `deck-open:?origin=kb&ref=…`;
/// - a work-item id (`issue_` and a 26-character ULID, `IssueIdLinkifier`'s
///   pattern), which becomes `deck-open:?origin=item&ref=…`.
///
/// The `deck-open:` links are the ones the session window's renderer emits
/// (agent-platform's session_view.py `_PATH_RE` and `_WIKILINK_RE`, and
/// `IssueIdLinkifier`), so a click opens the same viewer or item pane.
/// Building a link here authorises nothing: `DeckLinkRouting` validates every
/// `deck-open:` URL against the configured hosts at the click, through the
/// same `DeckOpenRef.validate` the conversation pane uses.
///
/// **NO MARKDOWN.** A Slate card question draws as plain text on purpose
/// (`SlatePane.askBody`'s own doc), so quotes, `$`, backticks and a newline
/// still draw literally; this adds link ranges to that same text rather than
/// parsing it.
enum LinkedText {
    /// A path anchor's own shape, from session_view.py's `_PATH_RE` absolute
    /// branch: not preceded by `/`, a word character or `~`, so the path part
    /// of a web address never matches.
    private static let pathPattern = try! NSRegularExpression(
        pattern: "(?<![/\\w~])/[A-Za-z0-9_.~][^\\s&<>'\"]*")

    /// Sentence punctuation that cannot end a path, session_view.py's
    /// `_PATH_SENTENCE_TAIL`. Trimmed so a path ending a sentence links without its full stop.
    private static let pathSentenceTail = Set(").,;:!?]}")

    /// Lexical prefixes a path must start with to draw as a link: a host
    /// account's home or a session scratchpad, the shapes
    /// `DeckOpenRef.allowedPathRoots(hosts:)` admits. Which account is
    /// configured is checked at the click, not here.
    private static let pathPrefixes = ["/Users/", "/private/tmp/claude-", "/tmp/claude-"]

    private static let wikilinkPattern = try! NSRegularExpression(
        pattern: "\\[\\[([^\\[\\]\\n]+)\\]\\]")

    /// `IssueIdLinkifier`'s own pattern.
    private static let itemPattern = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_])issue_[0-9A-Z]{26}(?![A-Za-z0-9_])")

    nonisolated static func attributedString(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let full = NSRange(location: 0, length: (text as NSString).length)
        var taken: [NSRange] = []

        func attach(_ url: URL, _ range: NSRange) {
            guard !taken.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                  let swiftRange = Range(range, in: text),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: result),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: result)
            else { return }
            result[lower..<upper].link = url
            taken.append(range)
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: full) {
                guard let url = match.url, let scheme = url.scheme?.lowercased(),
                      ExternalLink.allowedSchemes.contains(scheme) else { continue }
                attach(url, match.range)
            }
        }
        for match in wikilinkPattern.matches(in: text, range: full) {
            let target = (text as NSString).substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            guard let id = DeckOpenRef.validateKBId(target),
                  let url = deckOpenURL(origin: "kb", ref: id) else { continue }
            attach(url, match.range)
        }
        for match in itemPattern.matches(in: text, range: full) {
            let id = (text as NSString).substring(with: match.range)
            guard let url = deckOpenURL(origin: "item", ref: id) else { continue }
            attach(url, match.range)
        }
        for match in pathPattern.matches(in: text, range: full) {
            var path = (text as NSString).substring(with: match.range)
            while let last = path.last, pathSentenceTail.contains(last) { path.removeLast() }
            guard pathPrefixes.contains(where: { path.hasPrefix($0) && path.count > $0.count }),
                  let url = deckOpenURL(origin: "path", ref: path) else { continue }
            attach(url, NSRange(location: match.range.location, length: (path as NSString).length))
        }
        return result
    }

    /// `deck-open:?origin=<origin>&ref=<percent-encoded ref>`, the format
    /// `DeckOpenRef.validate` parses.
    nonisolated static func deckOpenURL(origin: String, ref: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/")
        guard let encoded = ref.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "deck-open:?origin=\(origin)&ref=\(encoded)")
    }
}

/// Where a link tapped in a native pane goes: the same two routes a link in
/// the session window's conversation pane takes
/// (`ConversationWebView.Coordinator.webView(_:decidePolicyFor:…)`).
enum DeckLinkRouting {
    enum Decision: Equatable {
        /// A validated `deck-open:` reference, for `ContentView.openViewer`.
        case open(DeckOpenRef.Origin)
        /// A web or mail address, for `ExternalLink.open`.
        case external(URL)
        /// Anything else: a `deck-open:` reference that fails validation, or
        /// a scheme outside `ExternalLink.allowedSchemes`. Nothing opens.
        case refuse
    }

    nonisolated static func decide(_ url: URL, hosts: [HostEntry]) -> Decision {
        let scheme = url.scheme?.lowercased()
        if scheme == "deck-open" {
            return DeckOpenRef.validate(url, hosts: hosts).map { .open($0) } ?? .refuse
        }
        if let scheme, ExternalLink.allowedSchemes.contains(scheme) { return .external(url) }
        return .refuse
    }

    /// The `OpenURLAction` the shell installs over the Slate and the cockpit's
    /// native panes. `deck-open:` is never handed to the system opener.
    @MainActor
    static func action(
        hosts: [HostEntry], open: @escaping @MainActor @Sendable (DeckOpenRef.Origin) -> Void
    ) -> OpenURLAction {
        OpenURLAction { @MainActor url in
            switch decide(url, hosts: hosts) {
            case .open(let origin):
                open(origin)
                return .handled
            case .external(let url):
                return ExternalLink.open(url) ? .handled : .discarded
            case .refuse:
                print("[Deck] link refused: \(url)")
                return .discarded
            }
        }
    }
}
