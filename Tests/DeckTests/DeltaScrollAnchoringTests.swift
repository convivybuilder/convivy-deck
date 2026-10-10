import XCTest
import WebKit
@testable import Deck

/// Whether applying a delta leaves the reader looking at what they were
/// looking at.
///
/// FOUND IN THE LIVE APP, NOT BY A TEST, which is what the design spec had
/// predicted about this exact behaviour. The operator, on 2026-08-08, scrolled up in
/// history while a session worked: the pane "moves just a little bit, the
/// exact amount that is printed to the bottom of the feed."
///
/// THE MECHANISM. `.turns` is `flex-direction: column-reverse`, so `scrollTop`
/// is measured from the visual bottom, and rows are inserted at the DOM start
/// — which is that same bottom. The document grows underneath the reader while
/// `scrollTop` keeps its old value, so the viewport slides toward the newer
/// content by exactly the height that arrived.
///
/// THESE ASSERT ON WHERE A ROW IS ON SCREEN, not on `scrollTop`. The first
/// version of this file asserted a `scrollTop` arithmetic relationship and got
/// the sign backwards, because WebKit's column-reverse history is NEGATIVE
/// (see `isAtBottom`). An anchor's `getBoundingClientRect().top` is the
/// property actually wanted — the reader sees the same thing — and it cannot
/// be satisfied by a wrong-signed compensation that merely looks arithmetically
/// tidy.
@MainActor
final class DeltaScrollAnchoringTests: XCTestCase {

    /// A scroller tall enough to have somewhere to scroll to: 40 rows of 50 px
    /// against a 200 px viewport.
    private static func page(rows: Int) -> String {
        let turns = (0..<rows).map {
            "<div class='turn' data-k='r\($0).0'>row \($0)</div>"
        }.joined()
        return """
            <html><head><style>
            html,body{margin:0;padding:0}
            .turns{display:flex;flex-direction:column-reverse;overflow-y:auto;
                   height:200px}
            .turn{height:50px;flex:none}
            </style></head><body><div class="turns">\(turns)</div></body></html>
            """
    }

    /// The same conversation with one more turn at the newest end.
    ///
    /// The row goes FIRST in the DOM because `.turns` is column-reverse and its
    /// rows are emitted reversed: the first child renders at the visual bottom,
    /// which is where a new turn appears.
    private static func pageWithANewestTurn(rows: Int) -> String {
        let existing = (0..<rows).map {
            "<div class='turn' data-k='r\($0).0'>row \($0)</div>"
        }.joined()
        return """
            <html><head><style>
            html,body{margin:0;padding:0}
            .turns{display:flex;flex-direction:column-reverse;overflow-y:auto;
                   height:200px}
            .turn{height:50px;flex:none}
            </style></head><body><div class="turns">\
            <div class='turn' data-k='new.0'>a new turn</div>\(existing)</div></body></html>
            """
    }

    private func loaded(_ html: String) async -> (WKWebView, ScrollLoadHelper) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 200),
            configuration: config)
        let helper = ScrollLoadHelper()
        webView.navigationDelegate = helper
        webView.loadHTMLString(html, baseURL: nil)
        await helper.waitForLoad()
        return (webView, helper)
    }

    private static let newRow = [["key": "new.0",
                                  "html": "<div class='turn' data-k='new.0'>a new turn</div>"]]

    /// Scroll the reader up into history and return the on-screen position of
    /// the row they are looking at.
    private func scrollUpAndAnchor(_ webView: WKWebView) async throws -> Double {
        let js = """
            var t = document.querySelector('.turns');
            t.scrollTop = -600;
            var a = t.querySelector('[data-k="r20.0"]');
            return {scrollTop: t.scrollTop, anchorTop: a.getBoundingClientRect().top};
            """
        let v = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil,
                                                      contentWorld: .page)
        let dict = try XCTUnwrap(v as? [String: Any])
        let scrollTop = try XCTUnwrap(dict["scrollTop"] as? Double)
        XCTAssertFalse(ConversationWebView.isAtBottom(scrollTop: scrollTop),
            "precondition: the reader is up in history, not at the newest turn")
        return try XCTUnwrap(dict["anchorTop"] as? Double)
    }

    private func anchorTop(_ webView: WKWebView) async throws -> Double {
        let js = """
            var a = document.querySelector('[data-k="r20.0"]');
            return a.getBoundingClientRect().top;
            """
        let v = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil,
                                                      contentWorld: .page)
        return try XCTUnwrap(v as? Double)
    }

    /// A reader scrolled up into history keeps looking at the same row when a
    /// new turn arrives at the bottom.
    func testAScrolledUpReaderKeepsLookingAtTheSameRow() async throws {
        let (webView, helper) = await loaded(DeltaScrollAnchoringTests.page(rows: 40))
        let before = try await scrollUpAndAnchor(webView)

        let result = try await webView.callAsyncJavaScript(
            ConversationWebView.applyDeltaBody,
            arguments: ["rows": DeltaScrollAnchoringTests.newRow,
                        "removed": [String](),
                        "tolerance": ConversationWebView.atBottomTolerance],
            in: nil, contentWorld: .page)

        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["inserted"] as? Bool, true)
        XCTAssertEqual(dict["grew"] as? Double ?? 0, 50, accuracy: 1,
            "the inserted row is 50 px tall, so that is what the document gained")

        // WITHOUT THE COMPENSATION this differs by the 50 px that arrived,
        // which is the defect the operator reported.
        let after = try await anchorTop(webView)
        XCTAssertEqual(after, before, accuracy: 1,
            "the row the reader was looking at is still in the same place")
        _ = helper
    }

    /// A reader already at the newest turn stays pinned there.
    ///
    /// The opposite requirement, and why the compensation is gated: applying it
    /// here would scroll them off the turn that just arrived.
    func testAReaderAtTheBottomStaysPinnedToTheNewest() async throws {
        let (webView, helper) = await loaded(DeltaScrollAnchoringTests.page(rows: 40))

        let before = try await webView.callAsyncJavaScript(
            "var t=document.querySelector('.turns'); t.scrollTop = 0; return t.scrollTop;",
            arguments: [:], in: nil, contentWorld: .page) as? Double ?? -1
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: before),
            "precondition: the reader is at the newest turn")

        let result = try await webView.callAsyncJavaScript(
            ConversationWebView.applyDeltaBody,
            arguments: ["rows": DeltaScrollAnchoringTests.newRow,
                        "removed": [String](),
                        "tolerance": ConversationWebView.atBottomTolerance],
            in: nil, contentWorld: .page)

        let dict = try XCTUnwrap(result as? [String: Any])
        let after = try XCTUnwrap(dict["scrollTop"] as? Double)
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: after),
            "still at the bottom, now showing the turn that just arrived")
        _ = helper
    }

    /// A row growing because its result folded in also must not move the
    /// reader. This is the replace case rather than the insert case, and it is
    /// the one a fold produces.
    func testAReplaceThatGrowsARowKeepsTheReaderPut() async throws {
        let (webView, helper) = await loaded(DeltaScrollAnchoringTests.page(rows: 40))
        let before = try await scrollUpAndAnchor(webView)

        let result = try await webView.callAsyncJavaScript(
            ConversationWebView.applyDeltaBody,
            arguments: [
                // Same key as a row already on the page, and twice the height:
                // a replace, never an insert.
                "rows": [["key": "r0.0",
                          "html": "<div class='turn' data-k='r0.0' style='height:100px'>with its result</div>"]],
                "removed": [String](),
                "tolerance": ConversationWebView.atBottomTolerance,
            ],
            in: nil, contentWorld: .page)

        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["inserted"] as? Bool, false,
            "a keyed row already on the page is replaced, never inserted")

        let after = try await anchorTop(webView)
        XCTAssertEqual(after, before, accuracy: 1,
            "growth below the reader is absorbed the same way an insert's is")
        _ = helper
    }

    /// THE SAME BLIND SPOT `testARemovalBeyondTheReaderDoesNotMoveThem` closes,
    /// but for replace: `testAReplaceThatGrowsARowKeepsTheReaderPut` only ever
    /// grows the row nearest the DOM start, which — like the old removal
    /// code — happens to be the one case a signed height delta gets right by
    /// accident. A fold can grow any tool-call row on the page, not only the
    /// newest, so this grows a row OLDER than the reader instead. The anchor
    /// fix is general across all three operations, so this passes for the
    /// same reason the removal case does: nothing between the reader and the
    /// DOM start changed, and the anchor measures that directly rather than
    /// assuming it.
    func testAReplaceBeyondTheReaderDoesNotMoveThem() async throws {
        let (webView, helper) = await loaded(DeltaScrollAnchoringTests.page(rows: 40))
        let before = try await scrollUpAndAnchor(webView)

        let result = try await webView.callAsyncJavaScript(
            ConversationWebView.applyDeltaBody,
            arguments: [
                // Older than the reader's row 20, same as the removal
                // reproduction — on the far side of them from the DOM start.
                "rows": [["key": "r35.0",
                          "html": "<div class='turn' data-k='r35.0' style='height:100px'>with its result</div>"]],
                "removed": [String](),
                "tolerance": ConversationWebView.atBottomTolerance,
            ],
            in: nil, contentWorld: .page)

        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["inserted"] as? Bool, false,
            "a keyed row already on the page is replaced, never inserted")

        let scrollTopAfter = try XCTUnwrap(dict["scrollTop"] as? Double)
        XCTAssertEqual(scrollTopAfter, -600, accuracy: 1,
            "nothing between the reader and the DOM start changed, so scrollTop itself must not move")

        let after = try await anchorTop(webView)
        XCTAssertEqual(after, before, accuracy: 1,
            "the row the reader was looking at is still in the same place")
        _ = helper
    }

    /// THE MIRROR CASE FOR A SHRINK. Removal deletes at the same DOM start /
    /// visual bottom an insert grows from, so the document can get SHORTER
    /// here — `grew` goes negative — and the reader scrolled up in history
    /// must not move: the same compensation applies, just in the other
    /// direction.
    func testARemovalThatShrinksTheDocumentKeepsTheScrolledUpReaderPut() async throws {
        let (webView, helper) = await loaded(DeltaScrollAnchoringTests.page(rows: 40))
        let before = try await scrollUpAndAnchor(webView)

        let result = try await webView.callAsyncJavaScript(
            ConversationWebView.applyDeltaBody,
            arguments: [
                "rows": [[String: String]](),
                // A row at the DOM start (the visual bottom) — the same
                // place an insert lands, and the same reasoning `page(rows:)`
                // gives for `r0.0` being there.
                "removed": ["r0.0"],
                "tolerance": ConversationWebView.atBottomTolerance,
            ],
            in: nil, contentWorld: .page)

        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["inserted"] as? Bool, false, "a removal is not new output")
        XCTAssertEqual(dict["grew"] as? Double ?? 0, -50, accuracy: 1,
            "the removed row was 50 px tall, so that is what the document lost")

        // WITHOUT THE COMPENSATION this differs by the 50 px that left.
        let after = try await anchorTop(webView)
        XCTAssertEqual(after, before, accuracy: 1,
            "the row the reader was looking at is still in the same place")
        _ = helper
    }

    /// `deck-reviewer`'s reproduction against #86, at 468fcf4: the row taken
    /// off the page is older than anything the reader can see, so nothing
    /// between them and the DOM start actually changed — the correct
    /// compensation is ZERO. A signed height delta cannot tell this apart
    /// from `testARemovalThatShrinksTheDocumentKeepsTheScrolledUpReaderPut`,
    /// since `scrollHeight` shrinks by the same 50 px either way; only
    /// where the removed row sat relative to the reader tells them apart,
    /// which is exactly what an anchor measures instead of assuming.
    func testARemovalBeyondTheReaderDoesNotMoveThem() async throws {
        let (webView, helper) = await loaded(DeltaScrollAnchoringTests.page(rows: 40))
        let before = try await scrollUpAndAnchor(webView)

        let result = try await webView.callAsyncJavaScript(
            ConversationWebView.applyDeltaBody,
            arguments: [
                "rows": [[String: String]](),
                // Older than the reader's row 20 — on the far side of them
                // from the DOM start / visual bottom the old reasoning
                // assumed every change fell between.
                "removed": ["r35.0"],
                "tolerance": ConversationWebView.atBottomTolerance,
            ],
            in: nil, contentWorld: .page)

        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["inserted"] as? Bool, false, "a removal is not new output")

        let scrollTopAfter = try XCTUnwrap(dict["scrollTop"] as? Double)
        XCTAssertEqual(scrollTopAfter, -600, accuracy: 1,
            "nothing between the reader and the DOM start changed, so scrollTop itself must not move")

        let after = try await anchorTop(webView)
        XCTAssertEqual(after, before, accuracy: 1,
            "the row the reader was looking at is still in the same place")
        _ = helper
    }

    /// The counterpart to the above: a removal that DOES fall between the
    /// DOM start and the reader still needs — and gets — compensation. Pairs
    /// with the beyond-the-reader case so the fix is not simply "never
    /// compensate a removal".
    func testARemovalBetweenTheEdgeAndTheReaderStillCompensates() async throws {
        let (webView, helper) = await loaded(DeltaScrollAnchoringTests.page(rows: 40))
        let before = try await scrollUpAndAnchor(webView)

        let result = try await webView.callAsyncJavaScript(
            ConversationWebView.applyDeltaBody,
            arguments: [
                "rows": [[String: String]](),
                // Newer than the reader's row 20 — between them and the DOM
                // start, where a change actually does need compensating.
                "removed": ["r5.0"],
                "tolerance": ConversationWebView.atBottomTolerance,
            ],
            in: nil, contentWorld: .page)

        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["inserted"] as? Bool, false, "a removal is not new output")

        let scrollTopAfter = try XCTUnwrap(dict["scrollTop"] as? Double)
        XCTAssertEqual(scrollTopAfter, -550, accuracy: 1,
            "a row between the reader and the DOM start left, so scrollTop moves by its height")

        let after = try await anchorTop(webView)
        XCTAssertEqual(after, before, accuracy: 1,
            "the row the reader was looking at is still in the same place")
        _ = helper
    }

    /// The reader already at the newest turn stays pinned there through a
    /// removal too — the same requirement `testAReaderAtTheBottomStaysPinnedToTheNewest`
    /// checks for growth.
    func testARemovalKeepsAReaderAtTheBottomPinnedToTheNewest() async throws {
        let (webView, helper) = await loaded(DeltaScrollAnchoringTests.page(rows: 40))

        let before = try await webView.callAsyncJavaScript(
            "var t=document.querySelector('.turns'); t.scrollTop = 0; return t.scrollTop;",
            arguments: [:], in: nil, contentWorld: .page) as? Double ?? -1
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: before),
            "precondition: the reader is at the newest turn")

        let result = try await webView.callAsyncJavaScript(
            ConversationWebView.applyDeltaBody,
            arguments: ["rows": [[String: String]](),
                        "removed": ["r0.0"],
                        "tolerance": ConversationWebView.atBottomTolerance],
            in: nil, contentWorld: .page)

        let dict = try XCTUnwrap(result as? [String: Any])
        let after = try XCTUnwrap(dict["scrollTop"] as? Double)
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: after),
            "still at the bottom after the row beneath it was withdrawn")
        _ = helper
    }

    /// THE RELOAD PATH HAS THE SAME BUG, and fixing `isAtBottom` is what
    /// exposed it. `savedScrollTop` was always nil while the predicate returned
    /// true unconditionally, so restoration never ran; once it does, it reapplies
    /// the offset measured against the OLD document. The replacement is normally
    /// taller, because the one path that reliably reloads is
    /// `deltaFailed()` → `reRender()`, which fires precisely because new content
    /// arrived and could not be applied incrementally.
    ///
    /// `deck-reviewer` reproduced this while reviewing #83 and measured the same
    /// 50 px signature as the delta-apply bug. This is that scenario: read the
    /// state off one document, load a taller one, restore, and check the reader
    /// did not move.
    func testRestoringAfterAReloadCorrectsForTheDocumentHavingGrown() async throws {
        let (webView, helper) = await loaded(DeltaScrollAnchoringTests.page(rows: 40))

        // Scroll up, then read the state the way `updateNSView` does before it
        // replaces the document.
        _ = try await scrollUpAndAnchor(webView)
        let read = try await webView.callAsyncJavaScript(
            "return \(ConversationWebView.readScript);",
            arguments: [:], in: nil, contentWorld: .page)
        let (savedTop, savedHeight, _) = ConversationWebView.parseReadResult(read)
        XCTAssertFalse(ConversationWebView.isAtBottom(scrollTop: savedTop),
            "precondition: the reader is up in history, so a restore is wanted")
        XCTAssertGreaterThan(savedHeight, 0, "the pre-reload height was captured")

        // The anchor's position in the OLD document, which is what restoring
        // has to reproduce.
        let before = try await anchorTop(webView)

        // The replacement document, one row taller — what a re-render after a
        // failed delta looks like.
        //
        // THE NEW ROW GOES AT THE DOM START, and getting that wrong is a real
        // trap: `render_html` emits the turns REVERSED, so the DOM's first
        // child is the NEWEST turn and its last child is the oldest. A test
        // that appends the extra row instead grows the document at the visually
        // OLDEST end, which needs no compensation at all — and then asserts the
        // correction is wrong. The first draft of this test did exactly that.
        let helper2 = ScrollLoadHelper()
        webView.navigationDelegate = helper2
        webView.loadHTMLString(DeltaScrollAnchoringTests.pageWithANewestTurn(rows: 40),
                               baseURL: nil)
        await helper2.waitForLoad()

        let js = ConversationWebView.restoreScript(openKeys: [], scrollTop: savedTop,
                                                   heightBefore: savedHeight)
        XCTAssertFalse(js.isEmpty, "a scrolled-up reader gets a restore script")
        _ = try await webView.callAsyncJavaScript("\(js); return 1;",
            arguments: [:], in: nil, contentWorld: .page)

        // WITHOUT the growth correction this is off by the 50 px that arrived.
        let after = try await anchorTop(webView)
        XCTAssertEqual(after, before, accuracy: 1,
            "the reader is back on the same row despite the document growing")
        _ = helper
        _ = helper2
    }

    /// The predicate the compensation and the pill both depend on, pinned
    /// against the sign convention that was wrong before.
    func testIsAtBottomTreatsHistoryAsAwayFromTheBottom() {
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: 0))
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: -3),
            "within tolerance of the newest turn still counts as at it")
        // The case that used to return true and made the pill unreachable.
        XCTAssertFalse(ConversationWebView.isAtBottom(scrollTop: -600),
            "history is NEGATIVE in a column-reverse scroller, and it is not the bottom")
        XCTAssertFalse(ConversationWebView.isAtBottom(scrollTop: 600),
            "unreachable in practice, but a positive excursion is not the bottom either")
    }
}

/// Resumes once the page has loaded, so a script runs against a real layout.
@MainActor
private final class ScrollLoadHelper: NSObject, WKNavigationDelegate {
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
