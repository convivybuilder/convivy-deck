import SwiftUI
import WebKit

/// A read-only pane for files fetched from the mini: Markdown, source, and images.
///
/// THE SHELL IS THE APPEARANCE AUTHORITY. The caller resolves `appearance` and
/// passes it in; the viewer stamps `data-theme` from that value into every page
/// it generates. It never reads `colorScheme` or uses `prefers-color-scheme`.
///
/// THE WEB VIEW FOLLOWS THE SAME SECURITY PATTERN AS ConversationWebView,
/// all three mechanisms: `allowsContentJavaScript = false` stops script;
/// `NetworkBlock` blocks passive subresource fetches; the navigation delegate
/// cancels link-activated navigation so a future Markdown link cannot replace
/// the document. `loadHTMLString(_:baseURL: nil)` gives the page an opaque
/// origin. File content is HTML-escaped before embedding; images use data URIs
/// so the NetworkBlock rule is never relaxed.
///
/// Phase 1: read-only display. No editing, no loopback server, no write path.
/// The working copy lives in Application Support; that location is established
/// now so phases 3 and 4 build on it without moving things around.
struct FileViewerPane: View {
    let ref: DeckOpenRef.Origin
    let appearance: Appearance
    /// The host this file was opened from.
    let target: SSHTarget

    @StateObject private var model = FileViewerModel()

    var body: some View {
        FileViewerWebView(html: model.html)
            .task(id: PaneLoadIdentity(ref: ref, target: target)) {
                await model.load(ref: ref, appearance: appearance, target: target)
            }
            .onChange(of: appearance) { _, new in
                Task { await model.reRender(appearance: new) }
            }
    }
}

// MARK: - HTML generation

// File-level constants carry no actor isolation, so the nonisolated HTML
// generation functions below can reference them without warnings.

private let viewerImageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "tif", "ico",
]

/// CSS stamped into every viewer page. `data-theme` on `<html>` is the single
/// appearance decision — the shell stamps it in; the viewer never reads
/// `prefers-color-scheme`.
///
/// Exposed `internal` (not `private`) so the test suite can assert the dark
/// selector is present without instantiating a web view.
let viewerSharedStyle = """
    <style>
    :root{--bg:#ffffff;--fg:#1a1a1a;--fg2:#6b6b6b;--border:#e0e0e0;--pre-bg:#f7f7f7}
    [data-theme="dark"]{--bg:#1e1e1e;--fg:#d4d4d4;--fg2:#999;--border:#333;--pre-bg:#161616}
    *{box-sizing:border-box}
    body{margin:0;padding:16px;background:var(--bg);color:var(--fg);
         font-family:system-ui,-apple-system,sans-serif;font-size:13px;line-height:1.6}
    pre{margin:0;font-family:'SF Mono',Menlo,Consolas,monospace;font-size:12px;
        line-height:1.5;white-space:pre-wrap;word-wrap:break-word;
        background:var(--pre-bg);padding:12px;border-radius:6px;
        border:1px solid var(--border)}
    img{max-width:100%;height:auto;display:block}
    .filename{font-family:'SF Mono',Menlo,monospace;font-size:11px;color:var(--fg2);
              margin-bottom:8px;padding-bottom:6px;border-bottom:1px solid var(--border)}
    .muted{color:var(--fg2);font-size:13px}
    .error{color:#d95c5c;font-size:13px;white-space:pre-wrap;font-family:'SF Mono',Menlo,monospace}
    </style>
    """

extension FileViewerPane {

    /// Generates a page for the working-copy file at `url`.
    ///
    /// Image extensions embed the data as a base64 data URI so the NetworkBlock
    /// rule list is never loosened. Everything else is displayed as escaped text
    /// in a `<pre>` block.
    nonisolated static func page(for url: URL, data: Data, appearance: Appearance) -> String {
        let ext = url.pathExtension.lowercased()
        if viewerImageExtensions.contains(ext) {
            return imagePage(data: data, ext: ext, appearance: appearance)
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? "(binary file — cannot display as text)"
        return textPage(text: text, filename: url.lastPathComponent, appearance: appearance)
    }

    nonisolated static func loadingPage(appearance: Appearance) -> String {
        let theme = appearance == .dark ? "dark" : "light"
        return """
        <!DOCTYPE html>
        <html data-theme="\(theme)">
        <head><meta charset="UTF-8">\(viewerSharedStyle)</head>
        <body><p class="muted">Loading…</p></body>
        </html>
        """
    }

    nonisolated static func errorPage(_ message: String, appearance: Appearance) -> String {
        let theme = appearance == .dark ? "dark" : "light"
        return """
        <!DOCTYPE html>
        <html data-theme="\(theme)">
        <head><meta charset="UTF-8">\(viewerSharedStyle)</head>
        <body><p class="error">\(htmlEscape(message))</p></body>
        </html>
        """
    }

    private nonisolated static func textPage(text: String, filename: String,
                                              appearance: Appearance) -> String {
        let theme = appearance == .dark ? "dark" : "light"
        return """
        <!DOCTYPE html>
        <html data-theme="\(theme)">
        <head><meta charset="UTF-8">\(viewerSharedStyle)</head>
        <body>
        <div class="filename">\(htmlEscape(filename))</div>
        <pre>\(htmlEscape(text))</pre>
        </body>
        </html>
        """
    }

    private nonisolated static func imagePage(data: Data, ext: String,
                                               appearance: Appearance) -> String {
        let theme = appearance == .dark ? "dark" : "light"
        let mime = imageMIME(ext: ext)
        let b64 = data.base64EncodedString()
        return """
        <!DOCTYPE html>
        <html data-theme="\(theme)">
        <head><meta charset="UTF-8">\(viewerSharedStyle)</head>
        <body><img src="data:\(mime);base64,\(b64)" alt=""></body>
        </html>
        """
    }

    private nonisolated static func imageMIME(ext: String) -> String {
        switch ext {
        case "svg":         return "image/svg+xml"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "bmp":         return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        case "ico":         return "image/x-icon"
        default:            return "image/png"
        }
    }

    /// Whether the file should be rendered by `session-view` rather than the
    /// local page generator.
    ///
    /// KB refs always use `session-view --render-kb`: the document has no local
    /// path, and the remote renderer produces the same self-contained HTML that
    /// `--render-file` does, styled to match the session pane.
    ///
    /// Markdown path refs use `session-view --render-file` so they look like
    /// session messages — same inline formatting, same GFM tables.
    ///
    /// All other file types (source, images, non-Markdown paths) use the local
    /// page generator. Exposed as `nonisolated static` so the dispatch logic is
    /// testable without instantiating a model or a web view.
    nonisolated static func usesRemoteRenderer(url: URL, ref: DeckOpenRef.Origin?) -> Bool {
        switch ref {
        case .kb:   return true
        case .path: return url.pathExtension.lowercased() == "md"
        case .item: return false  // not reachable — see `FileViewerModel.load`'s `.item` case
        case nil:   return false
        }
    }

    /// HTML-escapes a string for safe embedding in page content.
    ///
    /// Applied to all file content and filenames before they are placed in the
    /// page: the file's text is untrusted and must never reach the DOM unescaped.
    nonisolated static func htmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Model

@MainActor
private final class FileViewerModel: ObservableObject {
    @Published var html = FileViewerPane.loadingPage(appearance: .light)

    private var cachedData: Data?
    private var cachedURL: URL?
    private var cachedRef: DeckOpenRef.Origin?
    private var cachedTarget: SSHTarget?

    func load(ref: DeckOpenRef.Origin, appearance: Appearance, target: SSHTarget) async {
        html = FileViewerPane.loadingPage(appearance: appearance)
        cachedData = nil
        cachedURL = nil
        cachedRef = ref
        cachedTarget = target
        do {
            let (url, data): (URL, Data) = try await Task.detached {
                let u: URL
                switch ref {
                case .kb(let id):  u = try WorkingCopyStore.fetch(target: target, kbId: id)
                case .path(let p): u = try WorkingCopyStore.fetch(target: target, absolutePath: p)
                case .item(let id):
                    // NOT REACHABLE: `ContentView.openViewer` sends `.item`
                    // to the item detail pane and never constructs a
                    // `FileViewerPane` with one. Thrown rather than
                    // force-unwrapped so a future caller that violates the
                    // invariant gets this pane's own error page instead of a
                    // crash.
                    throw WorkingCopyStore.FetchError.unexpectedResponse(
                        "item ref reached the file viewer (id: \(id)) — this should open the item pane instead")
                }
                return (u, try Data(contentsOf: u))
            }.value
            cachedData = data
            cachedURL = url
            html = try await renderHTML(url: url, data: data, ref: ref, target: target, appearance: appearance)
        } catch {
            html = FileViewerPane.errorPage("\(error)", appearance: appearance)
        }
    }

    func reRender(appearance: Appearance) async {
        guard let data = cachedData, let url = cachedURL, let target = cachedTarget else {
            html = FileViewerPane.loadingPage(appearance: appearance)
            return
        }
        do {
            html = try await renderHTML(url: url, data: data, ref: cachedRef, target: target, appearance: appearance)
        } catch {
            html = FileViewerPane.errorPage("\(error)", appearance: appearance)
        }
    }

    /// Produces the HTML for `url`. KB refs use `session-view --render-kb`;
    /// Markdown path refs use `session-view --render-file`; everything else
    /// uses the local page generator. A non-zero exit from either remote
    /// path propagates as a thrown error and the caller converts it to the
    /// viewer's error state.
    private func renderHTML(url: URL, data: Data, ref: DeckOpenRef.Origin?, target: SSHTarget,
                            appearance: Appearance) async throws -> String {
        if FileViewerPane.usesRemoteRenderer(url: url, ref: ref) {
            switch ref {
            case .path(let remotePath):
                return try await Task.detached {
                    try SessionAgent.renderFile(target: target, path: remotePath, appearance: appearance)
                }.value
            case .kb(let id):
                return try await Task.detached {
                    try SessionAgent.renderKB(target: target, docId: id, appearance: appearance)
                }.value
            case .item, nil:
                break
            }
        }
        return FileViewerPane.page(for: url, data: data, appearance: appearance)
    }
}

// MARK: - Web view

/// The inner WKWebView, following the ConversationWebView security pattern
/// exactly: no JavaScript, NetworkBlock to stop passive subresource fetches,
/// opaque origin, and a navigation delegate that cancels link-activated
/// navigation. All three mechanisms are required; see `ConversationWebView`
/// for why each one is necessary and why none substitutes for another.
///
/// NOT `private` — `ItemDetailPane` reuses this verbatim rather than
/// standing up a second WKWebView with the same three mechanisms hand-copied,
/// per CLAUDE.md's boundary rule ("both draw from one design-token source");
/// a security-critical configuration duplicated in a second file is a
/// configuration that can drift out from under the first without either
/// looking wrong on its own.
struct FileViewerWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        // Same fail-open policy as ConversationWebView: if the rule list cannot
        // compile, load the page anyway. The primary protection (no JS) holds.
        NetworkBlock.attach(to: view) { [html] in
            view.loadHTMLString(html, baseURL: nil)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastLoaded != html else { return }
        view.loadHTMLString(html, baseURL: nil)
        context.coordinator.lastLoaded = html
    }

    func makeCoordinator() -> Coordinator { Coordinator(html: html) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoaded: String
        init(html: String) { self.lastLoaded = html }

        /// Only the initial in-memory load is allowed. A link in file content
        /// opens in the user's browser; `ExternalLink.open` enforces its scheme
        /// allowlist, so `file://`, `ssh://`, and app deep-links are silently
        /// dropped. The `@MainActor` annotation is load-bearing — without it
        /// the compiler warning is silent and WebKit never calls this method.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                ExternalLink.open(url)
                decisionHandler(.cancel)
                return
            }
            let isInMemory = navigationAction.request.url.map {
                $0.scheme == "about" || $0.absoluteString.isEmpty
            } ?? true
            decisionHandler(isInMemory ? .allow : .cancel)
        }
    }
}
