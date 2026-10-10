import XCTest
import WebKit
@testable import Deck

// MARK: - Parsing the meta's content: pure, no WebKit needed

/// `ConversationWebView.parseCursor(fromMetaContent:)` is the one place that
/// decides whether a value read off the page is trustworthy enough to become
/// a cursor. A WRONG cursor is the dangerous failure here, not a missing
/// one: too high and the next `--delta-since` silently skips rows, leaving a
/// pane that quietly lacks a turn with no error anywhere. So every shape
/// that is not cleanly "a non-negative integer, as a string" has to come
/// back nil, never a best-effort guess.
final class ParseCursorFromMetaTests: XCTestCase {

    func testAPositiveIntegerStringParses() {
        XCTAssertEqual(ConversationWebView.parseCursor(fromMetaContent: "874"), 874)
    }

    func testZeroParses() {
        // An empty conversation still carries the meta, per agent-platform
        // #379 — and its count is legitimately 0. This must not be confused
        // with "no cursor".
        XCTAssertEqual(ConversationWebView.parseCursor(fromMetaContent: "0"), 0)
    }

    func testNilResultParsesToNoCursor() {
        // What `evaluateJavaScript` hands back when the script itself
        // returned nothing usable.
        XCTAssertNil(ConversationWebView.parseCursor(fromMetaContent: nil))
    }

    func testJavaScriptNullParsesToNoCursor() {
        // `readCursorScript` returns JS `null` when the meta is absent —
        // the case a mini that has not pulled #379 hits on every page.
        // WKWebView bridges that as `NSNull`, not Swift `nil`.
        XCTAssertNil(ConversationWebView.parseCursor(fromMetaContent: NSNull()))
    }

    func testANonIntegerStringParsesToNoCursor() {
        XCTAssertNil(ConversationWebView.parseCursor(fromMetaContent: "abc"))
    }

    func testAFractionalStringParsesToNoCursor() {
        XCTAssertNil(ConversationWebView.parseCursor(fromMetaContent: "3.5"))
    }

    func testANegativeStringParsesToNoCursor() {
        // Refused rather than clamped to 0: a negative value means something
        // is already wrong with the reading, and guessing 0 would still be a
        // guess presented as a fact.
        XCTAssertNil(ConversationWebView.parseCursor(fromMetaContent: "-1"))
    }

    func testAnEmptyStringParsesToNoCursor() {
        XCTAssertNil(ConversationWebView.parseCursor(fromMetaContent: ""))
    }

    func testAWrongTypeParsesToNoCursor() {
        // `readCursorScript` always returns a string or null, but this
        // guards the day something upstream changes the shape.
        XCTAssertNil(ConversationWebView.parseCursor(fromMetaContent: 874))
    }
}

// MARK: - Reading the meta off a loaded page: empirical, against a real WKWebView

/// `readCursorScript` is host-evaluated JavaScript, the same path
/// `readScript` and `restoreScript` already rely on — see
/// `ConversationWebView`'s type doc for why that is independent of
/// `allowsContentJavaScript = false`. These drive the actual production
/// script against pages shaped like what `session-view` renders, the same
/// pattern `AppendBridgeCapabilityTests` and `EvaluateJSCapabilityTests` use.
///
/// Tests touching WKWebView run on the main actor: WKWebView's methods are
/// `@MainActor` in the Swift 6 SDK.
@MainActor
final class ReadCursorScriptTests: XCTestCase {

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

    /// Bridges the completion-handler form of `evaluateJavaScript` — the one
    /// `EvaluateJSCapabilityTests` confirms runs under
    /// `allowsContentJavaScript = false` — to `async`, rather than reaching
    /// for the separate `async throws` overload this codebase has not
    /// exercised elsewhere.
    ///
    /// Parses to `Int?` INSIDE the completion handler rather than resuming
    /// with the raw `Any?` result: that value is not `Sendable`, and under
    /// Swift 6 strict concurrency sending it across the continuation is a
    /// compile error. `parseCursor` is a pure function either side of that
    /// boundary, so parsing here rather than at the call site changes
    /// nothing about what is under test.
    private func readCursor(from webView: WKWebView) async -> Int? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(ConversationWebView.readCursorScript) { result, _ in
                continuation.resume(returning: ConversationWebView.parseCursor(fromMetaContent: result))
            }
        }
    }

    /// The shape agent-platform #379 promises: the meta sits right after the
    /// charset meta, ahead of the `.turns` content.
    func testReadsTheCursorOffAPageCarryingTheMeta() async {
        let page = """
            <!doctype html><meta charset=utf-8><meta name="transcript-lines" content="874">
            <body><div class="turns"><div class="turn" data-k="a.0">hi</div></div></body>
            """
        let (webView, helper) = await loadedWebView(page)
        let cursor = await readCursor(from: webView)
        XCTAssertEqual(cursor, 874)
        _ = helper
    }

    /// A mini that has not yet pulled agent-platform #379 renders a page
    /// with no such meta at all — this is the fallback trigger, and it must
    /// read as "no cursor" rather than fail outright.
    func testReturnsNilWhenTheMetaIsAbsent() async {
        let page = """
            <!doctype html><meta charset=utf-8>
            <body><div class="turns"><div class="turn" data-k="a.0">hi</div></div></body>
            """
        let (webView, helper) = await loadedWebView(page)
        let cursor = await readCursor(from: webView)
        XCTAssertNil(cursor)
        _ = helper
    }

    /// The meta is present even on an empty conversation, where there is no
    /// `.turns` element at all — the spec's explicit guarantee. The read must
    /// not depend on `.turns` existing.
    func testReadsTheCursorOnAPageWithNoTurnsElement() async {
        let page = """
            <!doctype html><meta charset=utf-8><meta name="transcript-lines" content="0">
            <body><p>Nothing here yet.</p></body>
            """
        let (webView, helper) = await loadedWebView(page)
        let cursor = await readCursor(from: webView)
        XCTAssertEqual(cursor, 0)
        _ = helper
    }

    /// The `full:true` fallback page carries the meta too, per the spec —
    /// this is the same read regardless of which of the two pages produced
    /// it, so a page shaped like that fallback is covered by the same script.
    func testReadsTheCursorOnTheFullTrueFallbackShapedPage() async {
        let page = """
            <!doctype html><meta charset=utf-8><meta name="transcript-lines" content="1203">
            <body><div class="turns"><div class="turn" data-k="z.9">whole page</div></div></body>
            """
        let (webView, helper) = await loadedWebView(page)
        let cursor = await readCursor(from: webView)
        XCTAssertEqual(cursor, 1203)
        _ = helper
    }

    func testANegativeMetaContentIsRefusedRatherThanBecomingACursor() async {
        let page = """
            <!doctype html><meta charset=utf-8><meta name="transcript-lines" content="-3">
            <body><div class="turns"></div></body>
            """
        let (webView, helper) = await loadedWebView(page)
        let cursor = await readCursor(from: webView)
        XCTAssertNil(cursor)
        _ = helper
    }

    func testANonIntegerMetaContentIsRefusedRatherThanBecomingACursor() async {
        let page = """
            <!doctype html><meta charset=utf-8><meta name="transcript-lines" content="soon">
            <body><div class="turns"></div></body>
            """
        let (webView, helper) = await loadedWebView(page)
        let cursor = await readCursor(from: webView)
        XCTAssertNil(cursor)
        _ = helper
    }
}

// MARK: - SessionPaneModel.cursorRead(fromMeta:): routing the parsed value

/// `@MainActor` because `SessionPaneModel` is — the same pattern
/// `DeltaCursorTests` in `AppendBridgeConsumerTests.swift` uses.
@MainActor
final class CursorReadFromMetaRoutingTests: XCTestCase {

    func testAPresentValueIsAdoptedDirectly() {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        XCTAssertNil(model.cursor)
        model.cursorRead(fromMeta: 874)
        XCTAssertEqual(model.cursor, 874)
    }

    func testZeroIsAdoptedRatherThanTreatedAsAbsent() {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        model.cursorRead(fromMeta: 0)
        XCTAssertEqual(model.cursor, 0)
    }

    /// Once a cursor is known, a later read — from a cosmetic re-render, say
    /// — must not overwrite it. This is the same "no-op whenever the cursor
    /// is already known" guard `establishCursorIfNeeded` has always had.
    func testANoOpOnceTheCursorIsAlreadyKnown() {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        model.deltaApplied(cursor: 10)
        model.cursorRead(fromMeta: 999)
        XCTAssertEqual(model.cursor, 10, "a later meta read must not override an established cursor")
    }

    /// A missing meta must not become a guessed cursor — it has to fall
    /// through to the probe instead. The probe itself is an ssh round trip
    /// this test cannot observe directly, so it uses a session name that
    /// cannot exist (the same pattern `DeltaCursorTests` uses for
    /// `deltaFailed`'s fallback `Task`) and asserts the one thing available
    /// synchronously: `cursorRead` never sets a cursor itself on a nil read.
    func testANilReadDoesNotItselfSetACursor() {
        let model = SessionPaneModel(session: "test-append-bridge-no-such-session", target: TestHost.target)
        model.cursorRead(fromMeta: nil)
        XCTAssertNil(model.cursor, "a nil meta read must route to the probe, never invent a cursor")
    }
}

// MARK: - The cursor set from the meta is what the next delta asks for

/// Closes the loop: whatever `cursorRead(fromMeta:)` adopts is the exact
/// value `SessionAgent.deltaArguments` sends as `--delta-since` on the next
/// poll — the same assertion style `SessionAgentTests` uses for the cursor
/// argument in general.
@MainActor
final class CursorFromMetaReachesTheNextDeltaSinceTests: XCTestCase {

    func testTheAdoptedCursorIsSentAsDeltaSince() throws {
        let model = SessionPaneModel(session: "deck", target: TestHost.target)
        model.cursorRead(fromMeta: 412)
        let cursor = try XCTUnwrap(model.cursor)
        let args = try SessionAgent.deltaArguments(target: TestHost.target, session: "deck", cursor: cursor, appearance: .dark)
        XCTAssertEqual(args.suffix(2), ["--delta-since", "412"])
    }
}

// MARK: - Helper

/// Resumes once the in-memory page has loaded, so a script runs against a
/// document that exists. WKWebView holds its delegate weakly, so the caller
/// retains this through the async wait — the same pattern
/// `AppendBridgeCapabilityTests` and `AppendBridgeConsumerTests` use.
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
