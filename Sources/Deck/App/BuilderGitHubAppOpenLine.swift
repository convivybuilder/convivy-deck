import Foundation

/// `create-github-app`'s one printed line once Deck forwards its page's
/// port (CQ·202): "Open http://127.0.0.1:<port>/ in a browser on this
/// machine, then create the App on GitHub." Finds that line's address in a
/// byte stream that may split it across reads and carries a real
/// terminal's ANSI escapes.
enum BuilderGitHubAppOpenLine {
    /// The address to open, found in `text`, only when it parses to EXACTLY
    /// scheme `http`, host `127.0.0.1`, port `expectedPort`, and path `/` —
    /// `nil` for anything else, including a line not yet fully received.
    /// Deck never opens any other URL from remote output.
    static func find(in text: String, expectedPort: UInt16) -> URL? {
        let stripped = stripANSIEscapes(text)
        // Every occurrence, not only the first: Builder's installer runs
        // `apt-get update` on Debian before this step, and its
        // `Get:1 http://deb.debian.org/...` lines can still sit in the
        // watcher's buffer when the Open line arrives.
        var searchStart = stripped.startIndex
        while let httpRange = stripped.range(of: "http://", range: searchStart..<stripped.endIndex) {
            searchStart = httpRange.upperBound
            let token = stripped[httpRange.lowerBound...].prefix { !$0.isWhitespace }
            if let url = exactAddress(String(token), expectedPort: expectedPort) { return url }
        }
        return nil
    }

    private static func exactAddress(_ token: String, expectedPort: UInt16) -> URL? {
        guard let components = URLComponents(string: token),
              components.scheme == "http",
              components.host == "127.0.0.1",
              components.port == Int(expectedPort),
              components.path == "/",
              components.query == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil,
              let url = components.url
        else { return nil }
        return url
    }

    /// Drops ANSI CSI sequences (`ESC [ ... final byte`) and any other bare
    /// ESC byte, so a styled line still matches. Not a full terminal
    /// parser — the one thing this must survive is the plain text either
    /// side of an escape staying intact, which this preserves.
    private static func stripANSIEscapes(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x1B {
                if index + 1 < scalars.count, scalars[index + 1] == "[" {
                    var end = index + 2
                    while end < scalars.count, !(0x40...0x7E).contains(scalars[end].value) {
                        end += 1
                    }
                    index = min(end + 1, scalars.count)
                    continue
                }
                index += 1
                continue
            }
            result.append(scalar)
            index += 1
        }
        return String(result)
    }
}
