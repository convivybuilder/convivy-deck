import XCTest
@testable import Deck

/// `RunbookLink.parse` — the gate every host's recovery-runbook link passes
/// through on write (`HostFormValidation`) and again on open
/// (`ContentView.openRunbookLink`). CQ·124: "opens via NSWorkspace only if
/// its scheme is https ... or a kb id Deck already knows how to open;
/// refuse others."
final class RunbookLinkTests: XCTestCase {
    func testEmptyTextParsesToNil() {
        XCTAssertNil(RunbookLink.parse(""))
        XCTAssertNil(RunbookLink.parse("   "))
    }

    func testAnHttpsURLParsesToURL() {
        XCTAssertEqual(
            RunbookLink.parse("https://example.com/runbook"),
            .url(URL(string: "https://example.com/runbook")!))
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(
            RunbookLink.parse("  https://example.com/runbook  "),
            .url(URL(string: "https://example.com/runbook")!))
    }

    func testAThreeSegmentKBIdParsesToKB() {
        XCTAssertEqual(
            RunbookLink.parse("shipwright/runbooks/log-your-builder-account-back-in-after-a-restart"),
            .kb(id: "shipwright/runbooks/log-your-builder-account-back-in-after-a-restart"))
    }

    func testHttpIsRefused() {
        XCTAssertNil(RunbookLink.parse("http://example.com/runbook"))
    }

    func testMailtoIsRefused() {
        XCTAssertNil(RunbookLink.parse("mailto:[email protected]"))
    }

    func testJavascriptSchemeIsRefused() {
        XCTAssertNil(RunbookLink.parse("javascript:alert(1)"))
    }

    func testFileSchemeIsRefused() {
        XCTAssertNil(RunbookLink.parse("file:///etc/passwd"))
    }

    func testAHostlessHttpsURLIsRefused() {
        XCTAssertNil(RunbookLink.parse("https:///runbook"))
    }

    func testABareTwoSegmentStringIsRefused() {
        // Neither a valid KB id (needs three segments) nor an https URL.
        XCTAssertNil(RunbookLink.parse("shipwright/runbooks"))
    }

    func testAPlainHostnameWithNoSchemeIsRefused() {
        XCTAssertNil(RunbookLink.parse("example.com/runbook"))
    }

    func testStoredRoundTripsForEachCase() {
        XCTAssertEqual(RunbookLink.kb(id: "a/b/c").stored, "a/b/c")
        let url = URL(string: "https://example.com/runbook")!
        XCTAssertEqual(RunbookLink.url(url).stored, url.absoluteString)
    }
}
