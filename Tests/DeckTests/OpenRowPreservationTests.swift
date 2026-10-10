import XCTest
import WebKit
@testable import Deck

// MARK: - Which keys survive the reload

/// A `<details>` the reader opened re-collapses on every reload, because Deck
/// replaces the whole document and nothing in the old one survives. The fix
/// reads the open rows' keys before the load and re-opens the same keys after.
///
/// **The failure worth guarding is not "the row closed".** It is a key that
/// identifies the wrong row, which silently expands a call the reader never
/// touched. So these tests are mostly about what is REFUSED: a key off the
/// contracted shape, a duplicate, an unbounded list, and anything that would
/// leave the array literal and become script.
///
/// The key's shape is agent-platform's, recorded in
/// `platform/contracts/session-page-markup`.
final class OpenRowKeySanitizingTests: XCTestCase {

    func testAUuidKeyIsKept() {
        // The common case: a record uuid and a block index.
        XCTAssertEqual(
            ConversationWebView.sanitize(openKeys: ["a8896700-58ca-4c84-be20-13b40bc5e7aa.0"]),
            ["a8896700-58ca-4c84-be20-13b40bc5e7aa.0"])
    }

    func testAHashKeyAndADisambiguatedKeyAreKept() {
        // The two other shapes the producer emits: a content hash, and either
        // form carrying a `~n` suffix when a key would otherwise repeat.
        let keys = ["h6dc66093f97f561c", "h6dc66093f97f561c~1", "a-1.0~2"]
        XCTAssertEqual(ConversationWebView.sanitize(openKeys: keys), keys)
    }

    func testAKeyCarryingAQuoteIsDropped() {
        // The key is interpolated into an array literal inside a script Deck
        // evaluates. A quote would end the string and start whatever followed.
        XCTAssertEqual(ConversationWebView.sanitize(openKeys: ["a\",alert(1),\"b"]), [])
    }

    func testKeysCarryingScriptPunctuationAreDropped() {
        let hostile = [
            "a'b", "a\\b", "a<b", "a>b", "a b", "a;b", "a)b", "a}b",
            "a\nb", "a\u{2028}b", "a\u{2029}b", "</script>",
        ]
        XCTAssertEqual(ConversationWebView.sanitize(openKeys: hostile), [])
    }

    func testANewlineCannotSmuggleAValidLineThrough() {
        // THE ANCHORING TEST. A regex anchored with ^/$ rather than \A/\z
        // matches line-by-line in some engines, so a key whose SECOND line is
        // well-formed would pass while carrying a first line that is not.
        XCTAssertEqual(ConversationWebView.sanitize(openKeys: ["alert(1)\nvalidkey"]), [])
    }

    func testAnEmptyKeyIsDropped() {
        XCTAssertEqual(ConversationWebView.sanitize(openKeys: [""]), [])
    }

    func testAnOverlongKeyIsDropped() {
        XCTAssertEqual(ConversationWebView.sanitize(openKeys: [String(repeating: "a", count: 121)]), [])
    }

    func testALegalKeyAtTheLengthBoundIsKept() {
        let key = String(repeating: "a", count: 120)
        XCTAssertEqual(ConversationWebView.sanitize(openKeys: [key]), [key])
    }

    func testDuplicatesCollapse() {
        XCTAssertEqual(ConversationWebView.sanitize(openKeys: ["a.0", "a.0", "b.1"]), ["a.0", "b.1"])
    }

    func testTheListIsBounded() {
        let many = (0..<(ConversationWebView.maxRestoredRows + 50)).map { "k\($0)" }
        XCTAssertEqual(ConversationWebView.sanitize(openKeys: many).count,
                       ConversationWebView.maxRestoredRows)
    }

    func testOneBadKeyDoesNotDiscardTheGoodOnes() {
        // Degrade per key. One unreadable row must not close every other row
        // the reader had open.
        XCTAssertEqual(ConversationWebView.sanitize(openKeys: ["a.0", "bad\"key", "b.1"]),
                       ["a.0", "b.1"])
    }
}

// MARK: - Reading what the page returned

/// `readScript` returns one object carrying both halves of the reader's state.
/// These pin the parse, including every shape the page could return that the
/// code does not expect — it is built from a transcript, so an unexpected shape
/// is a case to survive rather than a case to assume away.
final class OpenRowReadResultTests: XCTestCase {

    func testAWellFormedResultIsSplitInTwo() {
        let result: [String: Any] = ["scrollTop": 412.5, "open": ["a.0", "b.1"]]
        let parsed = ConversationWebView.parseReadResult(result)
        XCTAssertEqual(parsed.scrollTop, 412.5)
        XCTAssertEqual(parsed.openKeys, ["a.0", "b.1"])
    }

    func testAnIntegerScrollTopIsAccepted() {
        // JavaScript numbers arrive as either NSNumber flavour depending on
        // whether the value was fractional.
        let parsed = ConversationWebView.parseReadResult(["scrollTop": 300, "open": []])
        XCTAssertEqual(parsed.scrollTop, 300)
    }

    func testNilReadsAsAFreshPage() {
        // The first load: no `.turns`, no rows, nothing to restore.
        let parsed = ConversationWebView.parseReadResult(nil)
        XCTAssertEqual(parsed.scrollTop, 0)
        XCTAssertTrue(parsed.openKeys.isEmpty)
        XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: parsed.scrollTop))
    }

    func testAResultOfTheWrongTypeReadsAsAFreshPage() {
        let parsed = ConversationWebView.parseReadResult("not a dictionary")
        XCTAssertEqual(parsed.scrollTop, 0)
        XCTAssertTrue(parsed.openKeys.isEmpty)
    }

    func testAMissingScrollTopReadsAsAtBottom() {
        let parsed = ConversationWebView.parseReadResult(["open": ["a.0"]])
        XCTAssertEqual(parsed.scrollTop, 0)
        XCTAssertEqual(parsed.openKeys, ["a.0"])
    }

    func testANonArrayOpenFieldLosesOnlyTheRows() {
        // Scroll position still restores; only the open rows are lost.
        let parsed = ConversationWebView.parseReadResult(["scrollTop": 200, "open": "nope"])
        XCTAssertEqual(parsed.scrollTop, 200)
        XCTAssertTrue(parsed.openKeys.isEmpty)
    }

    func testNonStringEntriesAreSkippedAndTheRestKept() {
        let parsed = ConversationWebView.parseReadResult(["scrollTop": 0, "open": ["a.0", 7, "b.1"]])
        XCTAssertEqual(parsed.openKeys, ["a.0", "b.1"])
    }

    func testAHostileKeyIsAlreadyGoneByTheTimeItIsParsed() {
        // parseReadResult sanitizes, so no caller can forget to.
        let parsed = ConversationWebView.parseReadResult(["scrollTop": 0, "open": ["a\";alert(1);\""]])
        XCTAssertTrue(parsed.openKeys.isEmpty)
    }
}

// MARK: - Building the restore script

final class OpenRowRestoreScriptTests: XCTestCase {

    func testRowsAreOpenedBeforeScrollIsSet() {
        // ORDER IS LOAD-BEARING. Opening a row changes the height above the
        // reader, so a scrollTop applied first would land somewhere else.
        let js = ConversationWebView.restoreScript(openKeys: ["a.0"], scrollTop: 400)
        let openIndex = js.range(of: "d[i].open=true")
        let scrollIndex = js.range(of: "scrollTop=400")
        XCTAssertNotNil(openIndex)
        XCTAssertNotNil(scrollIndex)
        XCTAssertTrue(openIndex!.lowerBound < scrollIndex!.lowerBound,
                      "rows must be opened before the scroll position is restored")
    }

    func testKeysAreComparedNotConcatenatedIntoASelector() {
        // A selector built from a key is the one place a malformed key could
        // reach past the row it names. The script queries every keyed row and
        // compares instead.
        let js = ConversationWebView.restoreScript(openKeys: ["a.0"], scrollTop: nil)
        XCTAssertTrue(js.contains("querySelectorAll('details[data-k]')"))
        XCTAssertFalse(js.contains("data-k=\"a.0\"]"),
                       "the key must not be built into a selector")
    }

    func testRowsRestoreEvenWhenTheReaderWasAtTheBottom() {
        // scrollTop is nil when the reader was already at the bottom, which is
        // the case this defect hurt most: watching a tool call unfold live.
        let js = ConversationWebView.restoreScript(openKeys: ["a.0"], scrollTop: nil)
        XCTAssertTrue(js.contains("a.0"))
        XCTAssertFalse(js.contains("scrollTop="))
    }

    func testScrollRestoresWithNoOpenRows() {
        let js = ConversationWebView.restoreScript(openKeys: [], scrollTop: 250)
        XCTAssertTrue(js.contains("scrollTop=250"))
        XCTAssertFalse(js.contains("querySelectorAll"))
    }

    func testNothingToRestoreProducesNoScript() {
        // The caller skips evaluation entirely on an empty string.
        XCTAssertEqual(ConversationWebView.restoreScript(openKeys: [], scrollTop: nil), "")
    }

    func testANonFiniteScrollTopIsOmittedRatherThanEmitted() {
        // `inf` and `nan` interpolate as bare identifiers and would make the
        // whole script a syntax error, taking the row restoration down with it.
        let js = ConversationWebView.restoreScript(openKeys: ["a.0"], scrollTop: .infinity)
        XCTAssertFalse(js.contains("inf"))
        XCTAssertTrue(js.contains("a.0"), "the rows must still restore")

        let nanJS = ConversationWebView.restoreScript(openKeys: ["a.0"], scrollTop: .nan)
        XCTAssertFalse(nanJS.contains("nan"))
        XCTAssertTrue(nanJS.contains("a.0"))
    }

    func testANonFiniteHeightBeforeIsOmittedRatherThanEmitted() {
        // The same guard covers `heightBefore`, interpolated the same way as
        // `scrollTop` above. A non-finite value must be omitted rather than
        // emitted into the script; the scroll restoration still happens, just
        // without the growth correction that value would have supplied.
        let js = ConversationWebView.restoreScript(openKeys: ["a.0"], scrollTop: 400,
                                                    heightBefore: .infinity)
        XCTAssertFalse(js.contains("inf"))
        XCTAssertTrue(js.contains("a.0"), "the rows must still restore")
        XCTAssertTrue(js.contains("scrollTop=400"), "scroll still restores")

        let nanJS = ConversationWebView.restoreScript(openKeys: ["a.0"], scrollTop: 400,
                                                       heightBefore: .nan)
        XCTAssertFalse(nanJS.contains("nan"))
        XCTAssertTrue(nanJS.contains("a.0"))
        XCTAssertTrue(nanJS.contains("scrollTop=400"))
    }

    func testSeveralKeysBecomeOneArrayLiteral() {
        let js = ConversationWebView.restoreScript(openKeys: ["a.0", "b.1", "h0123456789abcdef"],
                                                   scrollTop: nil)
        XCTAssertTrue(js.contains("var k=[\"a.0\",\"b.1\",\"h0123456789abcdef\"];"))
    }
}

// MARK: - Empirical: the round trip against a real WKWebView

/// The pure functions above cannot answer whether the two scripts agree with
/// each other and with the page. These run them against a real WKWebView, with
/// `allowsContentJavaScript = false` exactly as the pane configures it, on
/// markup shaped like what `session-view` renders.
@MainActor
final class OpenRowRoundTripTests: XCTestCase {

    private static let page = """
        <html><body><div class=turns>
        <details data-k="a-1.0"><summary>Bash(ls)</summary><pre>out</pre></details>
        <details data-k="a-2.0" open><summary>Read(x.py)</summary><pre>out</pre></details>
        <details data-k="a-3.0"><summary>Grep(foo)</summary><pre>out</pre></details>
        </div></body></html>
        """

    private func webView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                         configuration: config)
    }

    func testReadScriptReturnsOnlyTheOpenRowsKey() {
        let view = webView()
        let done = expectation(description: "read")
        let helper = OpenRowNavHelper {
            view.evaluateJavaScript(ConversationWebView.readScript) { result, error in
                XCTAssertNil(error)
                let parsed = ConversationWebView.parseReadResult(result)
                XCTAssertEqual(parsed.openKeys, ["a-2.0"],
                               "only the row carrying `open` is reported")
                done.fulfill()
            }
        }
        view.navigationDelegate = helper
        view.loadHTMLString(Self.page, baseURL: nil)
        waitForExpectations(timeout: 5)
        _ = helper
    }

    func testRestoreScriptOpensExactlyTheNamedRows() {
        // THE DEFECT, END TO END. A fresh document arrives with every row
        // closed; the keys read from the old one must reopen the same rows and
        // no others.
        let view = webView()
        let done = expectation(description: "restore")
        let helper = OpenRowNavHelper {
            let js = ConversationWebView.restoreScript(openKeys: ["a-1.0", "a-3.0"],
                                                       scrollTop: nil)
            view.evaluateJavaScript(js) { _, error in
                XCTAssertNil(error, "the restore script must be valid JavaScript")
                let probe = """
                    (function(){var d=document.querySelectorAll('details[open]');var o=[];\
                    for(var i=0;i<d.length;i++){o.push(d[i].getAttribute('data-k'));}\
                    return o.join(',');})()
                    """
                view.evaluateJavaScript(probe) { result, _ in
                    // a-2.0 was open in the markup and is expected to stay so;
                    // the script opens rows and never closes one.
                    XCTAssertEqual(result as? String, "a-1.0,a-2.0,a-3.0")
                    done.fulfill()
                }
            }
        }
        view.navigationDelegate = helper
        view.loadHTMLString(Self.page, baseURL: nil)
        waitForExpectations(timeout: 5)
        _ = helper
    }

    func testAKeyForNoRowOnThePageOpensNothing() {
        // A row can leave the window as a session grows. Its key must be inert.
        let view = webView()
        let done = expectation(description: "absent")
        let helper = OpenRowNavHelper {
            let js = ConversationWebView.restoreScript(openKeys: ["gone-9.0"], scrollTop: nil)
            view.evaluateJavaScript(js) { _, error in
                XCTAssertNil(error)
                view.evaluateJavaScript("document.querySelectorAll('details[open]').length") { result, _ in
                    XCTAssertEqual((result as? Int) ?? -1, 1, "only the already-open row")
                    done.fulfill()
                }
            }
        }
        view.navigationDelegate = helper
        view.loadHTMLString(Self.page, baseURL: nil)
        waitForExpectations(timeout: 5)
        _ = helper
    }

    func testReadScriptOnAPageWithNoRowsIsEmptyRatherThanAnError() {
        let view = webView()
        let done = expectation(description: "empty")
        let helper = OpenRowNavHelper {
            view.evaluateJavaScript(ConversationWebView.readScript) { result, error in
                XCTAssertNil(error)
                let parsed = ConversationWebView.parseReadResult(result)
                XCTAssertTrue(parsed.openKeys.isEmpty)
                XCTAssertTrue(ConversationWebView.isAtBottom(scrollTop: parsed.scrollTop))
                done.fulfill()
            }
        }
        view.navigationDelegate = helper
        view.loadHTMLString("<html><body><p>nothing here</p></body></html>", baseURL: nil)
        waitForExpectations(timeout: 5)
        _ = helper
    }
}

// MARK: - Helper

/// WKWebView holds its delegate weakly, so the caller retains this through the
/// `waitForExpectations` spin.
private final class OpenRowNavHelper: NSObject, WKNavigationDelegate {
    private let onLoad: () -> Void
    init(_ onLoad: @escaping () -> Void) { self.onLoad = onLoad }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoad() }
}
