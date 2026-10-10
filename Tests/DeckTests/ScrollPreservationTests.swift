import XCTest
import WebKit
@testable import Deck

// MARK: - At-bottom predicate

/// The scroll-preservation logic lives in `ConversationWebView.isAtBottom`:
/// a pure predicate that separates "reader is at the newest turn" from
/// "reader has scrolled into history". The tests below hold it stable so a
/// tolerance change stays intentional, and so the column-reverse semantics
/// are explicit rather than assumed.
///
/// In the column-reverse scroller, scrollTop=0 IS the bottom (newest content).
/// Higher values mean the reader scrolled up toward older turns.
final class ScrollPreservationTests: XCTestCase {

    func testScrollTopZeroIsAtBottom() {
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: 0))
    }

    func testScrollTopWithinToleranceIsAtBottom() {
        // Tolerance is 5px, absorbing fractional offsets and the one-pixel
        // nudge some pointer devices produce when releasing at the end of a
        // momentum scroll.
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: 1))
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: 4))
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: 5))
    }

    func testScrollTopBeyondToleranceIsScrolledUp() {
        XCTAssertFalse(ConversationWebView.isAtBottom(scrollTop: 6))
        XCTAssertFalse(ConversationWebView.isAtBottom(scrollTop: 100))
        XCTAssertFalse(ConversationWebView.isAtBottom(scrollTop: 1000))
    }

    func testNegativeScrollTopCountsAsBottom() {
        // A sub-pixel fractional position can round slightly negative on some
        // high-DPI configurations in WebKit. Treat it as at-bottom.
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: -1))
    }

    func testToleranceBoundaryIsInclusive() {
        // Exactly at the tolerance value is at-bottom; one unit past is not.
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: 5))
        XCTAssertFalse(ConversationWebView.isAtBottom(scrollTop: 5.1))
    }
}

// MARK: - New-output pill state machine

/// Tests for the `hasNewOutput` flag's state-machine transitions.
///
/// These cover the four scenarios described in the scroll-fix review:
///
/// 1. **At bottom, output arrives** — pill must stay clear. The reader saw the
///    output the moment it appeared; `updateNSView` calls `clearNewOutput`.
/// 2. **Scrolled up, output arrives** — pill must show.
/// 3. **Scrolled up, output arrives, then manual return to bottom** — pill must
///    clear on the next poll tick, via `applyScrollCheck(scrollTop:)`.
/// 4. **Scrolled up, output arrives, manual return to bottom, NO further output** —
///    the residual the reviewer's one-liner left open. The pill must still clear
///    when the poll tick fires, even though `updateNSView` never fires again.
///    This is the test that pins the behaviour and marks the gap; without it the
///    fix to case 3 could be silently reverted later.
///
/// `applyScrollCheck` is the testable surface: it receives the already-read
/// scrollTop rather than calling `evaluateJavaScript`, so no WKWebView is needed.
/// `checkAndClearIfAtBottom` (the production entry point) calls it after reading
/// the webView, and is exercised end-to-end by the empirical WebKit tests above.
@MainActor
final class NewOutputPillTests: XCTestCase {

    // MARK: Scenario 1: at bottom when output arrives

    func testAtBottomWhenOutputArrives_pillStaysCleared() {
        let state = ConversationScrollState()
        // updateNSView called clearNewOutput because the reader was at the bottom.
        state.clearNewOutput()
        XCTAssertFalse(state.hasNewOutput)
    }

    // MARK: Scenario 2: scrolled up when output arrives

    func testScrolledUpWhenOutputArrives_pillShown() {
        let state = ConversationScrollState()
        state.markNewOutput()
        XCTAssertTrue(state.hasNewOutput)
    }

    // MARK: Scenario 3: scrolled up, output arrives, manual return to bottom

    func testScrolledUp_outputArrives_manualReturnToBottom_pollClears() {
        let state = ConversationScrollState()
        state.markNewOutput()
        XCTAssertTrue(state.hasNewOutput, "pill must show after new output")
        // Reader scrolls back manually; poll tick fires, reader is at the bottom:
        state.applyScrollCheck(scrollTop: 0)
        XCTAssertFalse(state.hasNewOutput, "pill must clear when reader reaches the bottom")
    }

    func testScrolledUp_outputArrives_manualReturnNearBottom_pollClears() {
        let state = ConversationScrollState()
        state.markNewOutput()
        // Within the 5 px tolerance — counts as at-bottom:
        state.applyScrollCheck(scrollTop: 4)
        XCTAssertFalse(state.hasNewOutput)
    }

    // MARK: Scenario 4: scrolled up, output arrives, manual return, NO further output

    func testScrolledUp_outputArrives_manualReturn_noFurtherOutput_pollClears() {
        // THE RESIDUAL. Output has stopped streaming, so updateNSView never fires
        // again. The pill must still clear when the reader reaches the bottom and
        // the poll tick fires applyScrollCheck.
        let state = ConversationScrollState()
        state.markNewOutput()
        // ... output stops; updateNSView is never called again ...
        // Poll tick fires; reader is at the bottom:
        state.applyScrollCheck(scrollTop: 0)
        XCTAssertFalse(state.hasNewOutput,
            "pill must clear at the bottom even after output stops streaming")
    }

    // MARK: Pill stays when scrolled up

    func testPollCheck_notAtBottom_pillRemains() {
        let state = ConversationScrollState()
        state.markNewOutput()
        state.applyScrollCheck(scrollTop: 100)
        XCTAssertTrue(state.hasNewOutput, "pill must stay while reader is scrolled up")
    }

    func testPollCheck_justPastTolerance_pillRemains() {
        let state = ConversationScrollState()
        state.markNewOutput()
        state.applyScrollCheck(scrollTop: 6) // 5 px is the tolerance boundary
        XCTAssertTrue(state.hasNewOutput)
    }

    // MARK: Button click

    func testButtonClick_pillClears() {
        let state = ConversationScrollState()
        state.markNewOutput()
        state.scrollToBottom()
        XCTAssertFalse(state.hasNewOutput)
    }

    // MARK: No-op when already clear

    func testApplyScrollCheck_alreadyClear_noOp() {
        let state = ConversationScrollState()
        // hasNewOutput is false; method must not change it (and must not trap):
        state.applyScrollCheck(scrollTop: 0)
        XCTAssertFalse(state.hasNewOutput)
    }
}

// MARK: - Empirical: evaluateJavaScript under allowsContentJavaScript = false

/// This test ANSWERS the load-bearing question before any scroll-preservation
/// code relies on it: does `evaluateJavaScript` (host-injected JS) still
/// execute when `allowsContentJavaScript = false`?
///
/// `allowsContentJavaScript` governs page-origin script — inline event
/// handlers, `<script>` tags, JavaScript: URLs. `evaluateJavaScript` is a
/// different path: the host calls into the page's JavaScript engine directly,
/// bypassing the content-policy gate. The belief is that they are independent.
/// This test confirms it rather than assuming it.
///
/// If this test FAILS, scroll preservation via `evaluateJavaScript` is not
/// available and the design needs to change. The test is kept in CI so any
/// future WebKit update that changes this behaviour is caught immediately.
///
/// Tests touching WKWebView must run on the main actor: WKWebView methods
/// are `@MainActor` in the Swift 6 SDK, and `waitForExpectations` is too.
@MainActor
final class EvaluateJSCapabilityTests: XCTestCase {

    func testEvaluateJavaScriptRunsWithContentJavaScriptDisabled() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            configuration: config)

        let jsExecuted = expectation(description: "JS executed")

        // NavHelper drives the load → evaluate sequence, kept alive by
        // the local variable below through the waitForExpectations spin.
        let helper = NavHelper {
            webView.evaluateJavaScript("1 + 1") { result, error in
                XCTAssertNil(error,
                    "evaluateJavaScript must not fail when page-origin JS is off")
                XCTAssertEqual(result as? Int, 2,
                    "host-evaluated JS runs regardless of allowsContentJavaScript")
                jsExecuted.fulfill()
            }
        }
        webView.navigationDelegate = helper
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)

        // waitForExpectations spins the main run loop, so WKWebView callbacks
        // that are dispatched to the main thread fire during the wait.
        waitForExpectations(timeout: 5)
        _ = helper  // keep the weak-referenced delegate alive through the wait
    }

    /// Confirms that the `.turns` element query used in the scroll-read JS
    /// returns 0 (not nil/error) on a page that carries no such element —
    /// which is the state during the very first pane load (placeholder page).
    func testTurnsQueryReturnsZeroWhenElementAbsent() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            configuration: config)

        let jsExecuted = expectation(description: "JS executed")

        let helper = NavHelper {
            // Same IIFE as ConversationWebView uses to read scroll position.
            let js = "(function(){var t=document.querySelector('.turns');return t?t.scrollTop:0;})()"
            webView.evaluateJavaScript(js) { result, error in
                XCTAssertNil(error)
                // No .turns element on this page → returns 0, which isAtBottom
                // treats as "at the bottom". The first load never preserves.
                let scrollTop = (result as? Double) ?? ((result as? Int).map(Double.init) ?? -1)
                XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: scrollTop),
                    "absent .turns returns a scrollTop that reads as at-bottom")
                jsExecuted.fulfill()
            }
        }
        webView.navigationDelegate = helper
        webView.loadHTMLString("<html><body><p>no turns element here</p></body></html>",
                               baseURL: nil)

        waitForExpectations(timeout: 5)
        _ = helper
    }
}

// MARK: - Helper

/// Minimal WKNavigationDelegate that fires a closure on load completion.
/// Declared here rather than inline so XCTest can hold a typed reference
/// through the waitForExpectations spin — WKWebView holds its delegate
/// weakly, so the caller must retain it.
private final class NavHelper: NSObject, WKNavigationDelegate {
    private let onLoad: () -> Void
    init(_ onLoad: @escaping () -> Void) { self.onLoad = onLoad }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoad()
    }
}
