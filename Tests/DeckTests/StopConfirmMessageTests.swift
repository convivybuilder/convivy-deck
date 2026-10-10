import XCTest
@testable import Deck

/// The Stop confirm's message — carried over from PR #106's non-blocking
/// review finding. "Stop" is reachable from a session pane (which always
/// has an agent) and from an "OTHER SESSIONS" row (which may not), and the
/// wording must not claim an agent is being asked to exit when there is
/// none.
final class StopConfirmMessageTests: XCTestCase {
    func testWithAnAgentMentionsAskingItToExit() {
        let message = ContentView.stopConfirmMessage(hasAgent: true)
        XCTAssertEqual(message,
            "The agent is asked to exit, then the session and its scrollback are closed.")
    }

    /// The no-agent branch says what actually happens rather than
    /// asserting the false premise the shared wording used to carry.
    func testWithNoAgentDoesNotMentionOne() {
        let message = ContentView.stopConfirmMessage(hasAgent: false)
        XCTAssertEqual(message, "The session and its scrollback are closed.")
        XCTAssertFalse(message.contains("agent"))
    }
}
