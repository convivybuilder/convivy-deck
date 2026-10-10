import XCTest
import WebKit
@testable import Deck

/// Whether `ConversationWebView.pinCheckScript` and `.scrollToElementBody`
/// actually work against a real, laid-out `.turns` page under
/// `allowsContentJavaScript = false`.
///
/// AN EMPIRICAL QUESTION, NOT A DOCUMENTED GUARANTEE — the same reason
/// `EvaluateJSCapabilityTests` and `AppendBridgeCapabilityTests` exist. Two
/// things here are specifically the kind of belief that has been wrong before
/// in this file: that `getComputedStyle(...).lineHeight` resolves to a pixel
/// value rather than the bare ratio a CSS `line-height: 1.65` was written
/// with (the resolved-value behaviour is a real WebKit quirk, not spec text),
/// and that `getBoundingClientRect()` on a `column-reverse` container's child
/// moves the way this feature's geometry assumes. `isAtBottom`'s own history
/// — reasoned about instead of measured, and wrong — is why these are
/// measured here instead of assumed.
///
/// Tests touching WKWebView run on the main actor: its methods are
/// `@MainActor` in the Swift 6 SDK.
@MainActor
final class PinnedMessageCapabilityTests: XCTestCase {

    /// A scroller shaped like the real page: `column-reverse`, one `you` row
    /// at the DOM start (the visual bottom, i.e. newest), a `you held` row
    /// that must be skipped, and enough older rows to scroll past.
    private static func page(rows: Int) -> String {
        let older = (0..<rows).map {
            "<div class='turn' data-k='r\($0).0'>row \($0)</div>"
        }.joined()
        return """
            <html><head><style>
            html,body{margin:0;padding:0}
            .turns{display:flex;flex-direction:column-reverse;overflow-y:auto;height:200px}
            .turn{flex:none}
            .you .body{line-height:1.5;font-size:16px;margin:0}
            </style></head><body><div class="turns">\
            <div class='turn you' data-k='mine.0'><div class=who>you</div>\
            <div class=body>my own last message</div></div>\
            <div class='turn you held' data-k='~held.0.abc'><div class=who>you (queued)</div>\
            <div class=body>a queued message, must be skipped</div></div>\
            \(older)</div></body></html>
            """
    }

    /// The scenario the feature exists for, per the plan: at REST — the
    /// reader has not scrolled at all — a reply newer than `mine.0` is
    /// already taller than the viewport, so `mine.0` sits above it.
    ///
    /// THIS IS NOT "scrolled up into history", and getting that distinction
    /// backwards is the trap: `mine.0` is the DOM's first non-held `you` row,
    /// so it is only "newest" when nothing newer exists. Here the reply rows
    /// are newer still — later in the conversation, so earlier in DOM order,
    /// so visually BELOW `mine.0` — and it is their height, not a manual
    /// scroll, that pushes `mine.0` above the container's top edge. Scrolling
    /// further negative from here would move `mine.0` away from the top edge
    /// altogether, back toward and past the bottom, exactly like every other
    /// item in a `column-reverse` container: confirmed by
    /// `testScrollingFurtherIntoHistoryMovesTheRowAwayFromTheTopEdge` below.
    private static func pageWithATallReplyBelowMine(replyRows: Int, olderRows: Int) -> String {
        let reply = (0..<replyRows).map {
            "<div class='turn' data-k='reply\($0).0' style='height:50px'>reply row \($0)</div>"
        }.joined()
        let older = (0..<olderRows).map {
            "<div class='turn' data-k='r\($0).0' style='height:50px'>row \($0)</div>"
        }.joined()
        return """
            <html><head><style>
            html,body{margin:0;padding:0}
            .turns{display:flex;flex-direction:column-reverse;overflow-y:auto;height:200px}
            .turn{flex:none}
            .you .body{line-height:1.5;font-size:16px;margin:0}
            </style></head><body><div class="turns">\
            \(reply)\
            <div class='turn you' data-k='mine.0' style='height:50px'>\
            <div class=who>you</div><div class=body>my own last message</div></div>\
            \(older)</div></body></html>
            """
    }

    private func loaded(_ html: String) async -> (WKWebView, PinLoadHelper) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200),
            configuration: config)
        let helper = PinLoadHelper()
        webView.navigationDelegate = helper
        webView.loadHTMLString(html, baseURL: nil)
        await helper.waitForLoad()
        return (webView, helper)
    }

    // MARK: - pinCheckScript

    /// At rest (scrollTop 0, the newest turn on screen), `mine.0` is fully
    /// visible: `edgeOffset` must be positive — its bottom edge is below the
    /// container's top — and `lineHeight` must resolve to a real pixel
    /// number, not the bare CSS ratio, `NaN`, or zero.
    func testPinCheckFindsTheNewestYouRowAtRest() async throws {
        let (webView, helper) = await loaded(PinnedMessageCapabilityTests.page(rows: 40))

        let result = try await webView.callAsyncJavaScript(
            "return \(ConversationWebView.pinCheckScript);",
            arguments: [:], in: nil, contentWorld: .page)

        let candidate = try XCTUnwrap(ConversationWebView.parsePinCandidate(result))
        XCTAssertEqual(candidate.key, "mine.0", "the held row must be skipped")
        XCTAssertEqual(candidate.text, "my own last message")
        XCTAssertGreaterThan(candidate.edgeOffset, 0,
            "at rest the reader's own row is visible, not past the top edge")
        XCTAssertGreaterThan(candidate.lineHeight, 0,
            "getComputedStyle resolves line-height to a real pixel number, not the bare CSS ratio")
        _ = helper
    }

    /// AT REST — no scrolling at all — a reply taller than the viewport
    /// already pushes `mine.0` above the top edge. `edgeOffset` must go
    /// negative, which is the show condition `applyPinCheck` tests against
    /// `pinShowThreshold`.
    func testPinCheckReportsANegativeEdgeOffsetWhenATallReplyPushesTheRowAboveTheTop() async throws {
        // 10 rows * 50px = 500px of reply against a 200px viewport.
        let (webView, helper) = await loaded(
            PinnedMessageCapabilityTests.pageWithATallReplyBelowMine(replyRows: 10, olderRows: 5))

        let before = try await webView.callAsyncJavaScript(
            "return document.querySelector('.turns').scrollTop;",
            arguments: [:], in: nil, contentWorld: .page) as? Double ?? -1
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: before),
            "precondition: the reader has not scrolled — this is the AT-REST case the feature exists for")

        let result = try await webView.callAsyncJavaScript(
            "return \(ConversationWebView.pinCheckScript);",
            arguments: [:], in: nil, contentWorld: .page)

        let candidate = try XCTUnwrap(ConversationWebView.parsePinCandidate(result))
        XCTAssertEqual(candidate.key, "mine.0")
        XCTAssertLessThan(candidate.edgeOffset, 0,
            "the reply's own height pushed the row's bottom edge above the container's top, unscrolled")
        _ = helper
    }

    /// THE DIRECTION THAT LOOKS BACKWARDS UNTIL MEASURED. Scrolling further
    /// negative from the pushed-above-top state does NOT keep `mine.0` above
    /// the edge — it moves every item down on screen, same as any other
    /// `column-reverse` child, carrying `mine.0` back toward and then past
    /// the bottom. Manual scrolling is not how this feature's target state is
    /// reached; only more content below the row is.
    func testScrollingFurtherIntoHistoryMovesTheRowAwayFromTheTopEdge() async throws {
        let (webView, helper) = await loaded(
            PinnedMessageCapabilityTests.pageWithATallReplyBelowMine(replyRows: 10, olderRows: 20))

        let atRest = try await webView.callAsyncJavaScript(
            "return \(ConversationWebView.pinCheckScript);",
            arguments: [:], in: nil, contentWorld: .page)
        let before = try XCTUnwrap(ConversationWebView.parsePinCandidate(atRest))
        XCTAssertLessThan(before.edgeOffset, 0, "precondition: pushed above the top at rest")

        _ = try await webView.callAsyncJavaScript(
            "document.querySelector('.turns').scrollTop = -800; return 1;",
            arguments: [:], in: nil, contentWorld: .page)

        let scrolled = try await webView.callAsyncJavaScript(
            "return \(ConversationWebView.pinCheckScript);",
            arguments: [:], in: nil, contentWorld: .page)
        let after = try XCTUnwrap(ConversationWebView.parsePinCandidate(scrolled))
        XCTAssertGreaterThan(after.edgeOffset, before.edgeOffset,
            "scrolling into history moved the row's bottom edge DOWN on screen, away from the top edge")
        _ = helper
    }

    /// No `.turn.you` row at all (a session with nothing sent yet) must
    /// return `null`, not throw or return a half-populated dictionary.
    func testPinCheckReturnsNullWhenNoYouRowExists() async throws {
        let noYouRows = """
            <html><body><div class="turns">\
            <div class='turn' data-k='r0.0'>not from you</div>\
            </div></body></html>
            """
        let (webView, helper) = await loaded(noYouRows)

        let result = try await webView.callAsyncJavaScript(
            "return \(ConversationWebView.pinCheckScript);",
            arguments: [:], in: nil, contentWorld: .page)

        XCTAssertNil(ConversationWebView.parsePinCandidate(result))
        _ = helper
    }

    func testPinCheckReturnsNullWhenTheOnlyYouRowIsHeld() async throws {
        // Distinct from "no you rows at all": here the selector has a `.turn.you`
        // to find and must reject it for carrying `held`. A held row is a queued
        // message the agent has not read, so it sits at the very bottom and is
        // never the thing a reader has lost track of — pinning it would point at
        // something already on screen. Gap named by `deck-reviewer` on #88.
        let onlyHeld = """
            <html><body><div class="turns">\
            <div class='turn you held' data-k='~held.0.abc123'>still queued</div>\
            <div class='turn said' data-k='r0.0'>from the agent</div>\
            </div></body></html>
            """
        let (webView, helper) = await loaded(onlyHeld)

        let result = try await webView.callAsyncJavaScript(
            "return \(ConversationWebView.pinCheckScript);",
            arguments: [:], in: nil, contentWorld: .page)

        XCTAssertNil(ConversationWebView.parsePinCandidate(result),
                     "a held row is not a candidate, so there is nothing to pin")
        _ = helper
    }

    // MARK: - scrollToElementBody

    /// The key arrives as a BOUND ARGUMENT, and the row is still found by
    /// COMPARING `data-k` rather than a selector built from it — this proves
    /// the bound-argument path (`AppendBridgeCapabilityTests` proved the same
    /// mechanism for the delta bridge) actually reaches and scrolls the
    /// target on a real column-reverse layout, starting from the same
    /// pushed-above-the-top-at-rest state the pin-check tests establish
    /// above — clicking the bar is the click this feature exists to make.
    func testScrollToElementMovesTheRowPushedAboveTheTopBackIntoView() async throws {
        let (webView, helper) = await loaded(
            PinnedMessageCapabilityTests.pageWithATallReplyBelowMine(replyRows: 10, olderRows: 5))

        let before = try await webView.callAsyncJavaScript(
            "return \(ConversationWebView.pinCheckScript);",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertLessThan(try XCTUnwrap(ConversationWebView.parsePinCandidate(before)).edgeOffset, 0,
            "precondition: the row starts pushed above the top edge, unscrolled")

        let value = try await webView.callAsyncJavaScript(
            ConversationWebView.scrollToElementBody,
            arguments: ["key": "mine.0"],
            in: nil, contentWorld: .page)
        let dict = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(dict["ok"] as? Bool, true)

        // Destructured into a plain object rather than returning the DOMRect
        // itself: DOMRect's fields are prototype accessors, not own
        // enumerable properties, so the bridge's JSON round trip does not
        // carry them — the same reason `DeltaScrollAnchoringTests` always
        // pulls a single scalar (`.top`) off a rect rather than the rect.
        let after = try await webView.callAsyncJavaScript(
            "var r = document.querySelector('[data-k=\"mine.0\"]').getBoundingClientRect(); "
            + "return {top: r.top, bottom: r.bottom};",
            arguments: [:], in: nil, contentWorld: .page)
        let rect = try XCTUnwrap(after as? [String: Any])
        let top = try XCTUnwrap(rect["top"] as? Double)
        let bottom = try XCTUnwrap(rect["bottom"] as? Double)
        XCTAssertTrue(bottom > 0 && top < 200,
            "the target row is back inside the 200pt viewport after scrolling to it")
        _ = helper
    }

    /// A key with no matching row is not an error — the client and the page
    /// need not agree perfectly, matching the removal path's own contract.
    func testScrollToElementReportsNotOkForAnUnknownKey() async throws {
        let (webView, helper) = await loaded(PinnedMessageCapabilityTests.page(rows: 40))

        let value = try await webView.callAsyncJavaScript(
            ConversationWebView.scrollToElementBody,
            arguments: ["key": "does-not-exist"],
            in: nil, contentWorld: .page)
        let dict = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(dict["ok"] as? Bool, false)
        _ = helper
    }
}

/// Resumes once the in-memory page has loaded.
@MainActor
private final class PinLoadHelper: NSObject, WKNavigationDelegate {
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
