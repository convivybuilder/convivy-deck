@testable import Deck
import XCTest

/// CQ·202: parsing `create-github-app`'s one printed line out of a byte
/// stream that may split it across reads and carries ANSI escapes.
final class BuilderGitHubAppOpenLineTests: XCTestCase {
    private let realLine =
        "Open http://127.0.0.1:54213/ in a browser on this machine, then create the App on GitHub.\n"

    func testTheRealLineParsesToTheExpectedPortsAddress() {
        XCTAssertEqual(
            BuilderGitHubAppOpenLine.find(in: realLine, expectedPort: 54213),
            URL(string: "http://127.0.0.1:54213/"))
    }

    func testADifferentHostIsRefused() {
        let line = "Open http://localhost:54213/ in a browser on this machine, then create the App on GitHub.\n"
        XCTAssertNil(BuilderGitHubAppOpenLine.find(in: line, expectedPort: 54213))
    }

    func testADifferentPortIsRefused() {
        XCTAssertNil(BuilderGitHubAppOpenLine.find(in: realLine, expectedPort: 9999))
    }

    func testHttpsIsRefused() {
        let line = "Open https://127.0.0.1:54213/ in a browser on this machine, then create the App on GitHub.\n"
        XCTAssertNil(BuilderGitHubAppOpenLine.find(in: line, expectedPort: 54213))
    }

    func testAPathOtherThanRootIsRefused() {
        let line = "Open http://127.0.0.1:54213/setup in a browser on this machine, then create the App on GitHub.\n"
        XCTAssertNil(BuilderGitHubAppOpenLine.find(in: line, expectedPort: 54213))
    }

    func testAQueryOrFragmentIsRefused() {
        XCTAssertNil(BuilderGitHubAppOpenLine.find(
            in: "Open http://127.0.0.1:54213/?x=1 in a browser...\n", expectedPort: 54213))
        XCTAssertNil(BuilderGitHubAppOpenLine.find(
            in: "Open http://127.0.0.1:54213/#frag in a browser...\n", expectedPort: 54213))
    }

    /// A line not yet fully received — as it would arrive mid-byte-stream —
    /// is not found; it is found only once the rest arrives and the
    /// accumulated buffer is parsed again.
    func testASplitLineIsFoundOnlyOnceReassembled() {
        let splitPoint = realLine.index(realLine.startIndex, offsetBy: 20)
        let firstChunk = String(realLine[..<splitPoint])
        let secondChunk = String(realLine[splitPoint...])
        XCTAssertNil(BuilderGitHubAppOpenLine.find(in: firstChunk, expectedPort: 54213))
        XCTAssertNotNil(BuilderGitHubAppOpenLine.find(in: firstChunk + secondChunk, expectedPort: 54213))
    }

    /// Builder's installer runs `apt-get update` on Debian before this
    /// step, so an earlier `http://` address can still be in the buffer.
    func testAnEarlierAptAddressDoesNotHideTheOpenLine() {
        let aptOutput = "Get:1 http://deb.debian.org/debian bookworm InRelease [151 kB]\n"
            + "Hit:2 http://deb.debian.org/debian-security bookworm-security InRelease\n"
        XCTAssertEqual(
            BuilderGitHubAppOpenLine.find(in: aptOutput + realLine, expectedPort: 54213),
            URL(string: "http://127.0.0.1:54213/"))
        XCTAssertNil(BuilderGitHubAppOpenLine.find(in: aptOutput, expectedPort: 54213))
    }

    /// ANSI SGR escapes (color, bold) wrapping the line must not break the
    /// parse — a real terminal interleaves these with the plain text.
    func testANSIEscapesAroundTheLineAreTolerated() {
        let styled = "\u{1B}[1mOpen \u{1B}[32mhttp://127.0.0.1:54213/\u{1B}[0m in a browser on this machine.\n"
        XCTAssertEqual(
            BuilderGitHubAppOpenLine.find(in: styled, expectedPort: 54213),
            URL(string: "http://127.0.0.1:54213/"))
    }
}
