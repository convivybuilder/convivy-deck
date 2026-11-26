@testable import Deck
import XCTest

/// CQ·202: the setup pane's browser opener is called at most once per pane,
/// only for an Open line matching the forwarded port, and never for a
/// mismatch — tested directly against `InstallerTerminalView.Coordinator`,
/// which takes an injected opener and exposes the same `dataReceived` hook
/// `BuilderSetupTerminalView` calls with the pane's real output, with no
/// need to stand up a real `LocalProcessTerminalView`.
@MainActor
final class InstallerTerminalViewTests: XCTestCase {
    private func coordinator(
        githubAppPort: UInt16?, opened: @escaping (URL) -> Void
    ) -> InstallerTerminalView.Coordinator {
        InstallerTerminalView.Coordinator(onExit: { _ in }, githubAppPort: githubAppPort, openBrowser: opened)
    }

    func testTheRealLineOpensExactlyOnce() {
        var opened: [URL] = []
        let coordinator = coordinator(githubAppPort: 54213) { opened.append($0) }
        let line = Array("Open http://127.0.0.1:54213/ in a browser on this machine.\n".utf8)
        coordinator.dataReceived(line[...])
        coordinator.dataReceived(line[...])
        XCTAssertEqual(opened, [URL(string: "http://127.0.0.1:54213/")!])
    }

    /// The line arriving in two separate reads is still found, and still
    /// opened only once.
    func testALineSplitAcrossTwoReadsIsFoundOnce() {
        var opened: [URL] = []
        let coordinator = coordinator(githubAppPort: 54213) { opened.append($0) }
        let bytes = Array("Open http://127.0.0.1:54213/ in a browser on this machine.\n".utf8)
        let splitPoint = 20
        coordinator.dataReceived(bytes[0..<splitPoint])
        coordinator.dataReceived(bytes[splitPoint...])
        XCTAssertEqual(opened, [URL(string: "http://127.0.0.1:54213/")!])
    }

    func testAMismatchedPortNeverOpens() {
        var opened: [URL] = []
        let coordinator = coordinator(githubAppPort: 54213) { opened.append($0) }
        let line = Array("Open http://127.0.0.1:9999/ in a browser on this machine.\n".utf8)
        coordinator.dataReceived(line[...])
        XCTAssertTrue(opened.isEmpty)
    }

    /// Another local process on the server can bind the forwarded port
    /// first (the port shows in `ps` for the whole install). create-github-app
    /// then refuses and prints no Open line, and Deck must open nothing, or the
    /// person would create an App on that process's page and hand it the
    /// App's code and key. The text is the two refusals Builder 0.7.1 prints
    /// in that case, from create-github-app and then builder-install.
    func testARefusedStepOpensNoBrowser() {
        var opened: [URL] = []
        let coordinator = coordinator(githubAppPort: 54213) { opened.append($0) }
        let refusal = "create-github-app: cannot listen on 127.0.0.1:54213 (Address already in use). "
            + "Choose another --port, or finish with --code.\r\n"
            + "builder-install: refusing \u{2014} the backend is installed; only the GitHub App remains. "
            + "Finish it with: python3.11 /opt/builder/src/shipwright/bin/create-github-app --port 54213 "
            + "(over SSH, where the redirect cannot reach this machine, add --code <code> with the value "
            + "from the browser's address bar).\r\n"
        coordinator.dataReceived(Array(refusal.utf8)[...])
        XCTAssertTrue(opened.isEmpty)
    }

    /// No port forwarded for this pane at all (`.installBuilderServer` was
    /// not among its steps, or reservation failed) means nothing is ever
    /// opened, regardless of what the pane prints.
    func testNoExpectedPortNeverOpens() {
        var opened: [URL] = []
        let coordinator = coordinator(githubAppPort: nil) { opened.append($0) }
        let line = Array("Open http://127.0.0.1:54213/ in a browser on this machine.\n".utf8)
        coordinator.dataReceived(line[...])
        XCTAssertTrue(opened.isEmpty)
    }
}
