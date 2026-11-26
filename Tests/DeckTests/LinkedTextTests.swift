import SwiftUI
import XCTest
@testable import Deck

final class LinkedTextTests: XCTestCase {
    /// The substring a run's `.link` attribute covers, or `nil` for a run
    /// carrying none.
    private func linkedSubstring(_ result: AttributedString, url: URL) -> String? {
        for run in result.runs where run.link == url {
            return String(result[run.range].characters)
        }
        return nil
    }

    // MARK: - Characters are the input's own, byte for byte

    func testCharactersArePreservedExactlyWithNoURL() {
        let input = "No link here — quotes \", dollars $, `backticks`\nand a newline."
        let result = LinkedText.attributedString(input)
        XCTAssertEqual(String(result.characters), input)
    }

    func testCharactersArePreservedExactlyAroundALink() {
        let input = "See https://example.com/path for the doc."
        let result = LinkedText.attributedString(input)
        XCTAssertEqual(String(result.characters), input)
    }

    func testNoURLInputCarriesNoLinkAttribute() {
        let input = "Plain text with no scheme at all."
        let result = LinkedText.attributedString(input)
        XCTAssertTrue(result.runs.allSatisfy { $0.link == nil })
    }

    // MARK: - Allowlisted schemes are linked

    func testHTTPIsLinked() {
        let url = URL(string: "http://example.com")!
        let result = LinkedText.attributedString("Visit http://example.com today")
        XCTAssertEqual(linkedSubstring(result, url: url), "http://example.com")
    }

    func testHTTPSIsLinked() {
        let url = URL(string: "https://example.com/docs")!
        let result = LinkedText.attributedString("Visit https://example.com/docs today")
        XCTAssertEqual(linkedSubstring(result, url: url), "https://example.com/docs")
    }

    func testMailtoIsLinked() {
        let url = URL(string: "mailto:someone@example.com")!
        let result = LinkedText.attributedString("Reach mailto:someone@example.com for help")
        XCTAssertEqual(linkedSubstring(result, url: url), "mailto:someone@example.com")
    }

    // MARK: - Everything else is left as plain text

    func testFileSchemeIsNotLinked() {
        let result = LinkedText.attributedString("Open file://" + "/Users/" + "someone" + "/notes.txt now")
        XCTAssertTrue(result.runs.allSatisfy { $0.link == nil })
    }

    func testSSHSchemeIsNotLinked() {
        let result = LinkedText.attributedString("Connect with ssh://example.com now")
        XCTAssertTrue(result.runs.allSatisfy { $0.link == nil })
    }

    func testAnAppSchemeIsNotLinked() {
        let result = LinkedText.attributedString("Open obsidian://vault/note now")
        XCTAssertTrue(result.runs.allSatisfy { $0.link == nil })
    }

    // MARK: - Deck's own references, as the session window links them

    private let hosts = [HostEntry(name: "test-host", user: TestHost.user, address: "203.0.113.10")]

    /// The single linked run's URL and covered text.
    private func onlyLink(_ result: AttributedString) -> (URL, String)? {
        let linked = result.runs.filter { $0.link != nil }
        guard linked.count == 1, let run = linked.first, let url = run.link else { return nil }
        return (url, String(result[run.range].characters))
    }

    func testAnAbsolutePathUnderAHostHomeLinksToTheViewerWithoutItsSentenceTail() throws {
        let path = "/Users/\(TestHost.user)/Convivy/notes/plan.md"
        let input = "Read \(path)."
        let result = LinkedText.attributedString(input)
        XCTAssertEqual(String(result.characters), input)
        let (url, covered) = try XCTUnwrap(onlyLink(result))
        XCTAssertEqual(covered, path)
        XCTAssertEqual(DeckLinkRouting.decide(url, hosts: hosts), .open(.path(absolutePath: path)))
    }

    func testAScratchpadPathLinks() throws {
        let path = "/private/tmp/claude-\(getuid())/scratch/report.md"
        let (url, covered) = try XCTUnwrap(onlyLink(LinkedText.attributedString("See \(path)")))
        XCTAssertEqual(covered, path)
        XCTAssertEqual(DeckLinkRouting.decide(url, hosts: hosts), .open(.path(absolutePath: path)))
    }

    func testAPathOutsideAHomeOrScratchpadIsNotLinked() {
        let result = LinkedText.attributedString("Logs go to /var/log/system.log and /etc/hosts")
        XCTAssertTrue(result.runs.allSatisfy { $0.link == nil })
    }

    func testThePathPartOfAWebAddressIsNotAPathLink() throws {
        let (url, covered) = try XCTUnwrap(onlyLink(LinkedText.attributedString(
            "See https://example.com" + "/Users/" + "someone" + "/file.md now")))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(covered, "https://example.com" + "/Users/" + "someone" + "/file.md")
    }

    func testAPathUnderAnUnconfiguredAccountDrawsAsALinkButIsRefusedAtTheClick() throws {
        let (url, _) = try XCTUnwrap(onlyLink(LinkedText.attributedString("/Users/" + "nobody-here" + "/x.md")))
        XCTAssertEqual(DeckLinkRouting.decide(url, hosts: hosts), .refuse)
    }

    func testAWikilinkToAKnowledgeDocumentLinksToTheViewer() throws {
        let input = "Follow [[deck/runbooks/post-merge]] after a merge."
        let (url, covered) = try XCTUnwrap(onlyLink(LinkedText.attributedString(input)))
        XCTAssertEqual(covered, "[[deck/runbooks/post-merge]]")
        XCTAssertEqual(DeckLinkRouting.decide(url, hosts: hosts), .open(.kb(id: "deck/runbooks/post-merge")))
    }

    func testAWikilinkThatIsNotAKnowledgeDocumentIdIsNotLinked() {
        let result = LinkedText.attributedString("Not a doc: [[Some Title]] or [[a/b]]")
        XCTAssertTrue(result.runs.allSatisfy { $0.link == nil })
    }

    func testAWorkItemIdLinksToTheItemPane() throws {
        let id = "issue_01M6P77WXGCMHQ2VJ47C1KBE3G"
        let (url, covered) = try XCTUnwrap(onlyLink(LinkedText.attributedString("Tracked in \(id), see thread.")))
        XCTAssertEqual(covered, id)
        XCTAssertEqual(DeckLinkRouting.decide(url, hosts: hosts), .open(.item(id: id)))
    }

    func testAWorkItemIdInsideALongerTokenIsNotLinked() {
        let result = LinkedText.attributedString("xissue_01M6P77WXGCMHQ2VJ47C1KBE3G and issue_01M6P77WXGCMHQ2VJ47C1KBE3Gx")
        XCTAssertTrue(result.runs.allSatisfy { $0.link == nil })
    }

    // MARK: - The route a tapped link takes

    func testTheRouterSendsWebAddressesToTheBrowser() {
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(DeckLinkRouting.decide(url, hosts: hosts), .external(url))
    }

    func testTheRouterRefusesASchemeOutsideTheAllowlist() {
        for raw in ["ssh://example.com", "file:///etc/hosts", "obsidian://vault/note"] {
            XCTAssertEqual(DeckLinkRouting.decide(URL(string: raw)!, hosts: hosts), .refuse, raw)
        }
    }

    func testTheRouterRefusesAMalformedDeckOpenReference() {
        let bad = URL(string: "deck-open:?origin=kb&ref=not-an-id")!
        XCTAssertEqual(DeckLinkRouting.decide(bad, hosts: hosts), .refuse)
    }

    @MainActor
    func testTheInstalledActionOpensADeckReferenceInDeckAndDiscardsARefusal() {
        var opened: [DeckOpenRef.Origin] = []
        let action = DeckLinkRouting.action(hosts: hosts) { opened.append($0) }
        let handled = expectation(description: "deck-open handled")
        action(LinkedText.deckOpenURL(origin: "item", ref: "issue_01M6P77WXGCMHQ2VJ47C1KBE3G")!) { accepted in
            XCTAssertTrue(accepted)
            handled.fulfill()
        }
        let refused = expectation(description: "ssh discarded")
        action(URL(string: "ssh://example.com")!) { accepted in
            XCTAssertFalse(accepted)
            refused.fulfill()
        }
        wait(for: [handled, refused], timeout: 1)
        XCTAssertEqual(opened, [.item(id: "issue_01M6P77WXGCMHQ2VJ47C1KBE3G")])
    }
}
