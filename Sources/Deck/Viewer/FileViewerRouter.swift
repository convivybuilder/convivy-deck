import AppKit

/// Routing decision for a file reference: render in the pane, open in the
/// browser via the loopback server, or hand off to the owning application.
enum FileViewerRoute {
    case pane
    case browser
    case handOff
}

/// Decides how to open a validated `DeckOpenRef.Origin`.
///
/// ## Routing table
///
/// | Ref type | Extensions | Route |
/// |---|---|---|
/// | KB doc (any) | — | Pane (remote renderer) |
/// | Markdown path | `.md` | Pane (remote renderer) |
/// | Image path | `.png .jpg .jpeg .gif .webp .svg .bmp .tiff .tif .ico` | Pane (base64 data URI) |
/// | Source / text path | `.swift .py .js .ts .jsx .tsx .rb .go .rs .java .c .h .cpp .m .sh .bash .zsh .txt .json .yaml .yml .xml .css .toml .ini .env .lock .log .conf .cfg` | Pane (escaped text) |
/// | PDF path | `.pdf` | Browser (loopback URL) |
/// | HTML path | `.html .htm` | Browser (loopback URL) |
/// | Everything else | — | Desktop hand-off (NSWorkspace) |
///
/// Unknown extensions go to desktop hand-off: the owning app or Finder handles
/// them. The pane's "(binary file — cannot display as text)" fallback is avoided
/// for unknown types by routing them to their natural handler.
enum FileViewerRouter {

    // MARK: - Extension sets

    private static let browserExtensions: Set<String> = [
        "pdf", "html", "htm",
    ]

    private static let paneImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "tif", "ico",
    ]

    private static let paneTextExtensions: Set<String> = [
        "md",
        "swift", "py", "js", "ts", "jsx", "tsx", "rb", "go", "rs", "java",
        "c", "h", "cpp", "m", "sh", "bash", "zsh",
        "txt", "json", "yaml", "yml", "xml", "css", "toml", "ini",
        "env", "lock", "log", "conf", "cfg",
    ]

    // MARK: - Routing

    /// Returns the route for `ref`.
    ///
    /// KB refs are always pane — KB documents are Markdown. Path refs are
    /// routed by extension; an unrecognised extension goes to hand-off.
    static func route(for ref: DeckOpenRef.Origin) -> FileViewerRoute {
        switch ref {
        case .kb:
            return .pane
        case .path(let absolutePath):
            let ext = (absolutePath as NSString).pathExtension.lowercased()
            if browserExtensions.contains(ext) { return .browser }
            if paneImageExtensions.contains(ext) { return .pane }
            if paneTextExtensions.contains(ext) { return .pane }
            return .handOff
        case .item:
            // NOT REACHABLE: `ContentView.openViewer` routes `.item` to the
            // item detail pane before this function ever sees it. `.pane` is
            // the harmless answer if that invariant is ever wrong, since it
            // names no file-fetching behaviour on its own.
            return .pane
        }
    }

    // MARK: - Desktop hand-off

    /// Opens `localURL` in the application that owns the file type.
    ///
    /// Uses `NSWorkspace.open` on the working-copy path on disk. The working
    /// copy lives in Application Support, so the owning application opens a
    /// local copy rather than the original on the mini.
    @MainActor
    static func handOff(localURL: URL) {
        NSWorkspace.shared.open(localURL)
    }
}
