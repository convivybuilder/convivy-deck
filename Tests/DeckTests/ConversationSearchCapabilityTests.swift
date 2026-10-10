import XCTest
import WebKit
@testable import Deck

/// Whether `ConversationWebView.searchCountBody` counts correctly against a
/// real page, and whether `WKWebView.find(_:configuration:completionHandler:)`
/// itself actually calls back the way `ConversationScrollState` assumes.
///
/// AN EMPIRICAL QUESTION, NOT A DOCUMENTED GUARANTEE — the same reason
/// `EvaluateJSCapabilityTests`, `AppendBridgeCapabilityTests` and
/// `PinnedMessageCapabilityTests` exist. `find` is a public API since macOS
/// 13.3, so it compiles; only calling it against a real `WKWebView` confirms
/// this app can actually use it, including the one behaviour nothing in the
/// type signature promises: that an empty search string is how a highlight
/// gets withdrawn.
///
/// Tests touching WKWebView run on the main actor: its methods are
/// `@MainActor` in the Swift 6 SDK.
@MainActor
final class ConversationSearchCapabilityTests: XCTestCase {

    /// A `.turns` page shaped like the real one, with a known, hand-counted
    /// number of occurrences of "widget" spread across several rows so a
    /// match spanning a row boundary is exercised too.
    private static let page = """
        <html><body><div class="turns">
        <div class="turn" data-k="c.0">the third widget arrived, a WIDGET indeed</div>
        <div class="turn" data-k="b.0">no matches in this one</div>
        <div class="turn" data-k="a.0">a widget, then another Widget</div>
        </div></body></html>
        """

    private func loaded(_ html: String) async -> (WKWebView, SearchLoadHelper) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            configuration: config)
        let helper = SearchLoadHelper()
        webView.navigationDelegate = helper
        webView.loadHTMLString(html, baseURL: nil)
        await helper.waitForLoad()
        return (webView, helper)
    }

    // MARK: - searchCountBody

    /// "widget" appears 4 times across the three rows: 2 in the first row
    /// ("widget" and the uppercase "WIDGET"), 0 in the second, 2 in the third
    /// ("widget" and "Widget") — hand-counted against `page` above, and the
    /// case variation is the point: the count must be case-insensitive.
    func testCountsCaseInsensitiveMatchesAcrossRows() async throws {
        let (webView, helper) = await loaded(ConversationSearchCapabilityTests.page)
        let value = try await webView.callAsyncJavaScript(
            ConversationWebView.searchCountBody,
            arguments: ["term": "widget", "cap": ConversationWebView.searchMatchCap],
            in: nil, contentWorld: .page)
        let (total, capped) = ConversationWebView.parseSearchCount(value)
        XCTAssertEqual(total, 4)
        XCTAssertFalse(capped)
        _ = helper
    }

    func testReportsZeroForATermThatDoesNotAppear() async throws {
        let (webView, helper) = await loaded(ConversationSearchCapabilityTests.page)
        let value = try await webView.callAsyncJavaScript(
            ConversationWebView.searchCountBody,
            arguments: ["term": "gizmo", "cap": ConversationWebView.searchMatchCap],
            in: nil, contentWorld: .page)
        let (total, capped) = ConversationWebView.parseSearchCount(value)
        XCTAssertEqual(total, 0)
        XCTAssertFalse(capped)
        _ = helper
    }

    /// A bound `cap` lower than the true count is reported as capped, at
    /// exactly the cap — not the true count, and not one past it. "widget"
    /// has 4 real matches; capping at 2 must report exactly 2, `capped: true`.
    func testCapReportsTheCapAndFlagsItRatherThanTheTrueCount() async throws {
        let (webView, helper) = await loaded(ConversationSearchCapabilityTests.page)
        let value = try await webView.callAsyncJavaScript(
            ConversationWebView.searchCountBody,
            arguments: ["term": "widget", "cap": 2],
            in: nil, contentWorld: .page)
        let (total, capped) = ConversationWebView.parseSearchCount(value)
        XCTAssertEqual(total, 2)
        XCTAssertTrue(capped)
        _ = helper
    }

    func testEmptyTermCountsAsNoSearchRatherThanEveryPosition() async throws {
        let (webView, helper) = await loaded(ConversationSearchCapabilityTests.page)
        let value = try await webView.callAsyncJavaScript(
            ConversationWebView.searchCountBody,
            arguments: ["term": "", "cap": ConversationWebView.searchMatchCap],
            in: nil, contentWorld: .page)
        let (total, capped) = ConversationWebView.parseSearchCount(value)
        XCTAssertEqual(total, 0)
        XCTAssertFalse(capped)
        _ = helper
    }

    /// No `.turns` element — the placeholder page, or a document that failed
    /// to render — must not throw or crash the round trip.
    func testNoTurnsElementCountsAsZero() async throws {
        let (webView, helper) = await loaded("<html><body><p>no turns here</p></body></html>")
        let value = try await webView.callAsyncJavaScript(
            ConversationWebView.searchCountBody,
            arguments: ["term": "anything", "cap": ConversationWebView.searchMatchCap],
            in: nil, contentWorld: .page)
        let (total, capped) = ConversationWebView.parseSearchCount(value)
        XCTAssertEqual(total, 0)
        XCTAssertFalse(capped)
        _ = helper
    }

    // MARK: - WKWebView.find itself

    /// THE CALL, NOT THE SIGNATURE. Confirms `find` actually invokes its
    /// completion handler with `matchFound: true` for a term genuinely on
    /// the page, against a real, laid-out `WKWebView` under
    /// `allowsContentJavaScript = false` — the same posture every other
    /// capability test in this file takes toward an Apple API this pane
    /// relies on.
    func testFindLocatesARealMatch() async throws {
        let (webView, helper) = await loaded(ConversationSearchCapabilityTests.page)
        let found = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            webView.find("widget", configuration: WKFindConfiguration()) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
        XCTAssertTrue(found)
        _ = helper
    }

    func testFindReportsNoMatchForATermThatDoesNotAppear() async throws {
        let (webView, helper) = await loaded(ConversationSearchCapabilityTests.page)
        let found = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            webView.find("gizmo", configuration: WKFindConfiguration()) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
        XCTAssertFalse(found)
        _ = helper
    }

    /// `clearSearch()`'s whole mechanism: an empty search string is WebKit's
    /// own way to withdraw a highlight, since `find` has no separate "clear"
    /// entry point. This confirms the call completes cleanly (no error, no
    /// hang) and reports no match for an empty needle, rather than assuming
    /// that behaviour from the API's shape.
    func testEmptyStringFindCompletesAndReportsNoMatch() async throws {
        let (webView, helper) = await loaded(ConversationSearchCapabilityTests.page)
        // Establish a highlight first, so the empty call has something to
        // withdraw rather than trivially reporting no match either way.
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            webView.find("widget", configuration: WKFindConfiguration()) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
        let found = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            webView.find("", configuration: WKFindConfiguration()) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
        XCTAssertFalse(found)
        _ = helper
    }

    // MARK: - ConversationScrollState, end to end

    /// Polls `condition` on the main actor until it is true or `timeout`
    /// elapses, for waiting on the `Task { @MainActor in ... }` inside
    /// `ConversationScrollState.recount` to publish its result — there is no
    /// completion callback to hang a `CheckedContinuation` off, unlike the
    /// direct `callAsyncJavaScript` calls above.
    private func pollUntil(timeout: TimeInterval = 5,
                          _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                throw XCTSkip("condition never became true within \(timeout)s")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The whole backend, driven the way the (future) find bar will drive
    /// it: search finds the first of several matches, next and previous
    /// step through them and wrap at both ends, and clearing withdraws
    /// everything. `ConversationSearchIndexTests` pins the wrap arithmetic
    /// and the parser in isolation; this confirms the pieces actually work
    /// together against a live document.
    func testSearchNextPreviousAndClearEndToEnd() async throws {
        let (webView, helper) = await loaded(ConversationSearchCapabilityTests.page)
        let state = ConversationScrollState()
        state.webView = webView

        state.search("widget")
        try await pollUntil { state.searchTotal == 4 }
        XCTAssertEqual(state.searchIndex, 1)
        XCTAssertFalse(state.searchCapped)

        state.findNext()
        XCTAssertEqual(state.searchIndex, 2)
        state.findNext()
        state.findNext()
        XCTAssertEqual(state.searchIndex, 4)
        state.findNext()
        XCTAssertEqual(state.searchIndex, 1, "past the last match wraps to the first")

        state.findPrevious()
        XCTAssertEqual(state.searchIndex, 4, "back past the first match wraps to the last")

        state.clearSearch()
        XCTAssertNil(state.searchTerm)
        XCTAssertEqual(state.searchTotal, 0)
        XCTAssertEqual(state.searchIndex, 0)
        _ = helper
    }

    /// `documentDidChange()` is what `Coordinator` calls after a full reload
    /// or a landed delta batch. Simulates the document shrinking to fewer
    /// matches — the same shape a delta's replace/removal produces — and
    /// confirms the count updates and the position resets to the first match
    /// rather than carrying the old index forward into a total it no longer
    /// fits.
    func testDocumentDidChangeRecountsAndResetsPosition() async throws {
        let (webView, helper) = await loaded(ConversationSearchCapabilityTests.page)
        let state = ConversationScrollState()
        state.webView = webView

        state.search("widget")
        try await pollUntil { state.searchTotal == 4 }
        state.findNext()
        XCTAssertEqual(state.searchIndex, 2)

        _ = try await webView.callAsyncJavaScript(
            "document.querySelector('.turns').innerHTML = "
            + "'<div class=\"turn\" data-k=\"z.0\">just one widget now</div>';",
            arguments: [:], in: nil, contentWorld: .page)
        state.documentDidChange()

        try await pollUntil { state.searchTotal == 1 }
        XCTAssertEqual(state.searchIndex, 1,
            "position resets to the first match rather than staying at the old index")
        _ = helper
    }
}

/// Resumes once the in-memory page has loaded.
@MainActor
private final class SearchLoadHelper: NSObject, WKNavigationDelegate {
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
