import XCTest
import WebKit
@testable import Deck

// MARK: - The append bridge's one empirical premise

/// Whether `callAsyncJavaScript` can hand the page a value as a BOUND ARGUMENT
/// while page-origin JavaScript is switched off.
///
/// THE WHOLE SECURITY ARGUMENT FOR THE APPEND BRIDGE RESTS ON THIS. A delta
/// arrives as HTML the renderer produced from transcript text — tool output,
/// file contents, pages a session fetched. Interpolating that into a script
/// string would create a SECOND place where escaping has to be right, in
/// host-evaluated JavaScript, against exactly the text most likely to be
/// hostile. `callAsyncJavaScript(_:arguments:)` binds the value as a parameter
/// instead, so there is no string boundary to escape across and nothing to get
/// wrong.
///
/// That is a claim about WebKit, not a documented guarantee, and
/// `EvaluateJSCapabilityTests` exists because the same question about
/// `evaluateJavaScript` had to be answered empirically before the scroll
/// restoration could rely on it. This is that test for the bridge.
///
/// IF THIS FAILS, THE DESIGN CHANGES rather than the code being patched. See
/// `deck/specs/session-pane-incremental-rendering`. It stays in CI so a WebKit
/// update that withdraws the capability is caught here rather than in a pane
/// that has quietly stopped updating.
///
/// Tests touching WKWebView run on the main actor: WKWebView's methods are
/// `@MainActor` in the Swift 6 SDK.
@MainActor
final class AppendBridgeCapabilityTests: XCTestCase {

    /// A page shaped like the rendered conversation: one `column-reverse`
    /// `.turns` scroller holding a turn. The bridge inserts at the DOM start,
    /// which is the visual bottom.
    private static let page = """
        <html><body><div class="turns"><div class="turn" data-k="a.0">first</div></div></body></html>
        """

    /// The fragment a delta would carry, built to break a naive interpolation.
    ///
    /// Every character here is one that would end a JavaScript string literal,
    /// escape the next one, or close a script element the fragment might be
    /// spliced into. If the bound argument arrives intact, none of them had to
    /// be escaped — which is the property being tested, rather than the
    /// insertion itself.
    private static let hostileFragment = """
        <div class="turn" data-k="b.0">quote " apos ' backslash \\ close </script> newline
        and a trailing backtick `</div>
        """

    private func loadedWebView(_ html: String) async -> (WKWebView, LoadHelper) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            configuration: config)
        let helper = LoadHelper()
        webView.navigationDelegate = helper
        webView.loadHTMLString(html, baseURL: nil)
        await helper.waitForLoad()
        return (webView, helper)
    }

    func testCallAsyncJavaScriptBindsAnArgumentWithContentJavaScriptDisabled() async throws {
        let (webView, helper) = await loadedWebView(AppendBridgeCapabilityTests.page)

        // `afterbegin` rather than `beforeend`: the turns are emitted reversed
        // inside a column-reverse container, so the DOM start is the visual
        // bottom and a new turn belongs there. The same reasoning is on
        // `ConversationWebView.isAtBottom`.
        // `raw` is the argument AS RECEIVED, read before anything parses it.
        // That is the property under test — what the HTML parser then does with
        // the markup is a separate question, asserted separately below.
        //
        // `afterbegin` rather than `beforeend`: the turns are emitted reversed
        // inside a column-reverse container, so the DOM start is the visual
        // bottom and a new turn belongs there. The same reasoning is on
        // `ConversationWebView.isAtBottom`.
        let body = """
            var raw = html;
            document.querySelector('.turns').insertAdjacentHTML('afterbegin', html);
            var rows = document.querySelectorAll('.turns .turn');
            return {raw: raw, count: rows.length, first: rows[0].getAttribute('data-k'),
                    text: rows[0].textContent};
            """

        let value = try await webView.callAsyncJavaScript(
            body,
            arguments: ["html": AppendBridgeCapabilityTests.hostileFragment],
            in: nil,
            contentWorld: .page)

        let dict = try XCTUnwrap(value as? [String: Any],
            "expected a dictionary back, got \(String(describing: value))")
        // THE CLAIM: the argument arrived byte-identical, so nothing about it
        // had to be escaped on the way across. Compared whole rather than
        // character by character — a partial match would pass while a mangled
        // middle went unnoticed.
        XCTAssertEqual(dict["raw"] as? String, AppendBridgeCapabilityTests.hostileFragment,
            "every character that would end a JS string literal crossed as a bound argument")

        // A SEPARATE QUESTION, and it has a different answer for one input.
        // The insertion itself works: the fragment parsed and joined the page.
        XCTAssertEqual(dict["count"] as? Int, 2,
            "the fragment parsed as markup and joined the existing turn")
        XCTAssertEqual(dict["first"] as? String, "b.0",
            "the inserted row landed at the DOM start, which is the visual bottom")

        let text = dict["text"] as? String ?? ""
        XCTAssertTrue(text.contains("quote \""), "a double quote survives parsing")
        XCTAssertTrue(text.contains("apos '"), "a single quote survives parsing")
        XCTAssertTrue(text.contains("backslash \\"), "a backslash survives parsing")
        XCTAssertTrue(text.contains("`"), "a backtick survives parsing")
        // A STRAY `</script>` IS DROPPED BY THE HTML PARSER, not by the bridge:
        // an end tag with no matching start is discarded as a parse error, so it
        // never becomes text. Asserted as the observed behaviour rather than
        // left as a surprise for whoever next reads a delta and cannot find a
        // string they know was in the transcript.
        XCTAssertFalse(text.contains("</script>"),
            "the parser discards a stray end tag; the argument still carried it, see `raw`")
        _ = helper
    }

    /// Replacing a row in place, which a delta does whenever a tool result
    /// arrives for a call already on the page.
    ///
    /// The row is found by `data-k` rather than by position, for the reason
    /// `platform/contracts/session-page-markup` gives: an index-based lookup
    /// looks correct until a turn is inserted above one, and then it silently
    /// addresses a different row.
    func testReplacingAKeyedRowInPlace() async throws {
        let (webView, helper) = await loadedWebView(AppendBridgeCapabilityTests.page)

        let body = """
            var existing = document.querySelector('.turns [data-k="' + key + '"]');
            if (!existing) { return {found: false}; }
            existing.outerHTML = html;
            var rows = document.querySelectorAll('.turns .turn');
            return {found: true, count: rows.length, text: rows[0].textContent};
            """

        let value = try await webView.callAsyncJavaScript(
            body,
            arguments: [
                "key": "a.0",
                "html": "<div class=\"turn\" data-k=\"a.0\">first, now with its result</div>",
            ],
            in: nil,
            contentWorld: .page)

        let dict = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(dict["found"] as? Bool, true, "the row was addressable by its key")
        XCTAssertEqual(dict["count"] as? Int, 1,
            "replacing left the row count unchanged rather than adding one")
        XCTAssertEqual(dict["text"] as? String, "first, now with its result")
        _ = helper
    }
}

/// Resumes once the in-memory page has loaded, so a script runs against a
/// document that exists.
@MainActor
private final class LoadHelper: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var loaded = false

    func waitForLoad() async {
        if loaded { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        continuation?.resume()
        continuation = nil
    }
}
