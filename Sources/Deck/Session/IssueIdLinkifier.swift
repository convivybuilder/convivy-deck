import Foundation

/// Turns a Library issue id in the conversation's markup into a
/// `deck-open:?origin=item&ref=<id>` link, so a click lands on the route that
/// already opens an item (`DeckOpenRef.validate`, then `ContentView.openViewer`).
/// There is no second route; this only produces the link the first one takes.
///
/// **DONE TO THE MARKUP, AT LOAD, BECAUSE THE PAGE IS NOT OURS.** The
/// conversation is rendered by `session-view` on the mini and the page runs no
/// script, so a detector cannot live in the page. `ConversationWebView` passes
/// every full page and every delta row through `linkify` on its way to the web
/// view. The stored `html` the model compares is left raw, so a re-render that
/// changes nothing still compares equal.
///
/// **NO LOOKUP HERE.** Whether an id belongs to the current project cannot be
/// read off the id, and a lookup per id would be a request per id in a long
/// conversation. Every id becomes a link and the question is answered by the
/// one that is clicked (`CockpitModel.reveal`).
enum IssueIdLinkifier {
    /// `issue_` and a 26-character ULID. Bounded on both sides by anything
    /// outside `[A-Za-z0-9_]`, so a longer token that merely contains one is
    /// left alone rather than linked to a truncated, wrong id.
    private static let idPattern = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_])issue_[0-9A-Z]{26}(?![A-Za-z0-9_])")

    /// Elements whose text is not linked: inside an anchor a second anchor is
    /// invalid markup and swallows the first click, and script or style text
    /// is not prose.
    private static let skippedElements: Set<String> = ["a", "script", "style"]

    /// The same markup with every id in a text node wrapped in a link. Tags,
    /// attribute values and comments are copied verbatim.
    nonisolated static func linkify(_ html: String) -> String {
        // A page with no id costs one substring search and comes back as is.
        guard html.contains("issue_") else { return html }
        let bytes = Array(html.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 16)
        var skipDepth = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "<") {
                let end = endOfMarkup(in: bytes, from: i)
                updateSkipDepth(&skipDepth, tag: bytes[i..<end])
                out.append(contentsOf: bytes[i..<end])
                i = end
            } else {
                var end = i
                while end < bytes.count, bytes[end] != UInt8(ascii: "<") { end += 1 }
                let text = String(decoding: bytes[i..<end], as: UTF8.self)
                out.append(contentsOf: Array((skipDepth == 0 ? linkifyText(text) : text).utf8))
                i = end
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func linkifyText(_ text: String) -> String {
        guard text.contains("issue_") else { return text }
        let nsText = text as NSString
        let matches = idPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            let id = nsText.substring(with: match.range)
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "<a href=\"deck-open:?origin=item&amp;ref=\(id)\">\(id)</a>"
            cursor = match.range.location + match.range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }

    /// The index one past the markup construct starting at `start`, which is a
    /// `<`. A comment runs to `-->`; a tag runs to the first `>` outside a
    /// quoted attribute value. An unterminated construct runs to the end of
    /// the input, so nothing after it is linked.
    private static func endOfMarkup(in bytes: [UInt8], from start: Int) -> Int {
        let dashes = Array("!--".utf8)
        if bytes.count >= start + 4, Array(bytes[(start + 1)..<(start + 4)]) == dashes {
            var j = start + 4
            while j + 2 < bytes.count {
                if bytes[j] == UInt8(ascii: "-"), bytes[j + 1] == UInt8(ascii: "-"),
                   bytes[j + 2] == UInt8(ascii: ">") { return j + 3 }
                j += 1
            }
            return bytes.count
        }
        var quote: UInt8?
        var j = start + 1
        while j < bytes.count {
            let b = bytes[j]
            if let q = quote {
                if b == q { quote = nil }
            } else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                quote = b
            } else if b == UInt8(ascii: ">") {
                return j + 1
            }
            j += 1
        }
        return bytes.count
    }

    private static func updateSkipDepth(_ depth: inout Int, tag: ArraySlice<UInt8>) {
        var bytes = tag.dropFirst()
        let isClosing = bytes.first == UInt8(ascii: "/")
        if isClosing { bytes = bytes.dropFirst() }
        let name = String(decoding: bytes.prefix { b in
            b != UInt8(ascii: " ") && b != UInt8(ascii: "\t") && b != UInt8(ascii: "\n")
                && b != UInt8(ascii: "\r") && b != UInt8(ascii: "/") && b != UInt8(ascii: ">")
        }, as: UTF8.self).lowercased()
        guard skippedElements.contains(name) else { return }
        if isClosing {
            depth = max(0, depth - 1)
        } else if tag.dropLast().last != UInt8(ascii: "/") {
            depth += 1
        }
    }
}
