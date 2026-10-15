import Foundation

/// Reads the method, path and token-file back out of one of `LibraryClient`'s
/// or `WorkingCopyStore`'s composed curl command strings — `remoteGETCommand`,
/// `remoteWriteCommand` and `libraryDocumentRemoteCommand` are all built from
/// the same two shapes, and this is the one place that reads either shape
/// back, so the mutual-TLS branch of `LibraryTransportDispatch` needs no
/// second copy of what the ssh/curl branch already composed.
///
/// **THIS IS NOT A GENERAL SHELL PARSER.** It reads exactly the two fixed
/// templates those three functions produce, matched by their own fixed
/// substrings (`${LIBRARY_BASE_URL:-…}`, `$(cat … 2>/dev/null)`, `-X …`) —
/// safe only because every value that can vary inside them (`path`, a
/// `tokenFile` constant) is already charset-validated or a compiled-in
/// literal before it reaches the template, per those functions' own docs. A
/// template whose shape changes needs this parser updated alongside it,
/// which is the same coupling `splitCurlStatusResponse` already has to
/// curl's own `-w` output.
enum LibraryCurlCommand {
    struct Parsed: Equatable {
        let method: String
        let path: String
        let tokenFile: String
    }

    /// `nil` when `command` does not carry the base-URL marker or the
    /// token-file marker every composed request carries — the caller's cue
    /// that this was not one of the shapes this parser knows, and the whole
    /// request should fail loudly rather than reach a guessed path.
    static func parse(_ command: String) -> Parsed? {
        guard let path = extractPath(command), let tokenFile = extractTokenFile(command) else {
            return nil
        }
        return Parsed(method: extractMethod(command) ?? "GET", path: path, tokenFile: tokenFile)
    }

    private static func extractPath(_ command: String) -> String? {
        let marker = WorkingCopyStore.libraryBaseURLExpression
        guard let markerRange = command.range(of: marker) else { return nil }
        let afterMarker = command[markerRange.upperBound...]
        guard let endQuote = afterMarker.firstIndex(of: "\"") else { return nil }
        return String(afterMarker[..<endQuote])
    }

    private static func extractTokenFile(_ command: String) -> String? {
        let openMarker = "$(cat "
        let closeMarker = " 2>/dev/null)"
        guard let openRange = command.range(of: openMarker),
              let closeRange = command.range(of: closeMarker, range: openRange.upperBound..<command.endIndex)
        else { return nil }
        return String(command[openRange.upperBound..<closeRange.lowerBound])
    }

    /// `remoteWriteCommand`'s `-X \(method)`; absent on every GET template,
    /// which is what makes `GET` the right default rather than a guess.
    private static func extractMethod(_ command: String) -> String? {
        guard let marker = command.range(of: "-X ") else { return nil }
        let afterMarker = command[marker.upperBound...]
        guard let endSpace = afterMarker.firstIndex(of: " ") else { return nil }
        return String(afterMarker[..<endSpace])
    }
}
