import XCTest
@testable import Deck

final class IssueIdLinkifierTests: XCTestCase {
    private let id = "issue_01M2VHDM6QTEXMBTNKF4CP9M6P"
    private var link: String {
        "<a href=\"deck-open:?origin=item&amp;ref=\(id)\">\(id)</a>"
    }

    func testAnIdInATextNodeBecomesAnItemLink() {
        XCTAssertEqual(IssueIdLinkifier.linkify("<p>working on \(id) now</p>"),
                       "<p>working on \(link) now</p>")
    }

    /// The link it emits must be one `DeckOpenRef` accepts as an item ref,
    /// because that validation is the only thing standing between a click and
    /// the route. Read back through the real validator rather than compared to
    /// a string.
    func testTheEmittedLinkValidatesAsAnItemRef() throws {
        let html = IssueIdLinkifier.linkify("<p>\(id)</p>")
        let href = try XCTUnwrap(html.components(separatedBy: "href=\"").dropFirst().first?
            .components(separatedBy: "\"").first)
        let url = try XCTUnwrap(URL(string: href.replacingOccurrences(of: "&amp;", with: "&")))
        XCTAssertEqual(DeckOpenRef.validate(url, hosts: []), .item(id: id))
    }

    func testAnIdInsideACodeSpanIsLinked() {
        XCTAssertEqual(IssueIdLinkifier.linkify("<code>\(id)</code>"), "<code>\(link)</code>")
    }

    func testEveryIdInOneNodeIsLinked() {
        let other = "issue_01M2P5JHM1G8XCMKM4HEHVJB2P"
        let out = IssueIdLinkifier.linkify("<p>\(id), \(other)</p>")
        XCTAssertTrue(out.contains("ref=\(id)\">"))
        XCTAssertTrue(out.contains("ref=\(other)\">"))
    }

    // MARK: - What must not change

    func testAnIdInsideAnAnchorIsNotNested() {
        let html = "<a href=\"https://example.com\">\(id)</a> after \(id)"
        XCTAssertEqual(IssueIdLinkifier.linkify(html),
                       "<a href=\"https://example.com\">\(id)</a> after \(link)")
    }

    func testAnIdInsideAnAttributeIsLeftAlone() {
        let html = "<div data-k=\"\(id)\" title='\(id)'>x</div>"
        XCTAssertEqual(IssueIdLinkifier.linkify(html), html)
    }

    /// A `>` inside a quoted attribute value must not end the tag early and
    /// expose the rest of the value as text.
    func testAGreaterThanInsideAQuotedAttributeDoesNotEndTheTag() {
        let html = "<div title=\"a > \(id)\">x</div>"
        XCTAssertEqual(IssueIdLinkifier.linkify(html), html)
    }

    func testACommentIsLeftAlone() {
        let html = "<!-- \(id) --><p>y</p>"
        XCTAssertEqual(IssueIdLinkifier.linkify(html), html)
    }

    func testScriptAndStyleTextIsLeftAlone() {
        let html = "<style>/* \(id) */</style><script>var a = '\(id)'</script>"
        XCTAssertEqual(IssueIdLinkifier.linkify(html), html)
    }

    func testTextAfterAClosedAnchorIsLinkedAgain() {
        XCTAssertEqual(IssueIdLinkifier.linkify("<a href=\"x\">go</a><p>\(id)</p>"),
                       "<a href=\"x\">go</a><p>\(link)</p>")
    }

    // MARK: - What counts as an id

    func testALongerTokenContainingAnIdIsNotLinked() {
        for html in ["<p>x\(id)</p>", "<p>\(id)Z</p>", "<p>\(id)_2</p>", "<p>my_\(id)</p>"] {
            XCTAssertEqual(IssueIdLinkifier.linkify(html), html, html)
        }
    }

    func testAShortOrLowercaseTailIsNotAnId() {
        for html in ["<p>issue_01M2VHDM6QTEXMBTNKF4CP9M6</p>",
                     "<p>issue_01m2vhdm6qtexmbtnkf4cp9m6p</p>",
                     "<p>issue_</p>", "<p>the issue_tracker</p>"] {
            XCTAssertEqual(IssueIdLinkifier.linkify(html), html, html)
        }
    }

    func testPunctuationAroundAnIdStaysOutsideTheLink() {
        XCTAssertEqual(IssueIdLinkifier.linkify("<p>(\(id)), and \(id).</p>"),
                       "<p>(\(link)), and \(link).</p>")
    }

    func testMultibyteTextAroundAnIdSurvives() {
        XCTAssertEqual(IssueIdLinkifier.linkify("<p>café — \(id) — 日本語</p>"),
                       "<p>café — \(link) — 日本語</p>")
    }

    func testAPageWithNoIdIsReturnedUnchanged() {
        let html = "<div class=\"turn\" data-k=\"a.0\">nothing here</div>"
        XCTAssertEqual(IssueIdLinkifier.linkify(html), html)
    }

    func testAnUnterminatedTagDoesNotCrashOrLinkInsideIt() {
        let html = "<p>\(id)</p><div title=\"\(id)"
        XCTAssertEqual(IssueIdLinkifier.linkify(html), "<p>\(link)</p><div title=\"\(id)")
    }
}
