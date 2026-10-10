import XCTest
@testable import Deck

/// The rail's lifecycle surface: the batched state read that feeds it, and the
/// classification that decides which rows grey and offer a Start.
final class SessionLifecycleTests: XCTestCase {

    // MARK: - The batched states read

    func testStatesBatchesEveryNameIntoOneCommand() throws {
        let argv = try SessionAgent.statesArguments(target: TestHost.target, sessions: ["vivy", "deck", "selector"])
        // One `states` verb, then every validated name — one ssh call for the
        // whole rail rather than one per row.
        guard let verb = argv.firstIndex(of: "states") else {
            return XCTFail("no states verb in \(argv)")
        }
        XCTAssertEqual(Array(argv[(verb + 1)...]), ["vivy", "deck", "selector"])
        XCTAssertTrue(argv.contains("session-agent"))
    }

    func testAnInvalidNameNeverReachesTheBatchedArgv() {
        for hostile in ["deck; rm -rf /", "a b", "", String(repeating: "d", count: 65)] {
            XCTAssertThrowsError(
                try SessionAgent.statesArguments(target: TestHost.target, sessions: ["vivy", hostile]), hostile)
        }
    }

    func testStatesDecodesTheKeyedObjectPerSession() throws {
        // The shape `session-agent states` emits: a brief state keyed by name.
        let json = """
            {"vivy": {"session":"vivy","state":"working","alive":true},
             "deck": {"session":"deck","state":"unknown","alive":false,
                      "reason":"no claude process found in any pane of 'deck'"}}
            """
        let decoded = try SessionAgent.decodeStates(Data(json.utf8))
        XCTAssertEqual(decoded["vivy"]?.phase, .working)
        XCTAssertEqual(decoded["vivy"]?.alive, true)
        XCTAssertEqual(decoded["deck"]?.alive, false)
    }

    // MARK: - What counts as stopped

    private func state(alive: Bool, phase: SessionState.Phase, reason: String? = nil) -> SessionState {
        SessionState(session: "x", phase: phase, gate: nil, alive: alive,
                     reason: reason, lastEvent: nil)
    }

    func testANeverPolledSessionIsNotStopped() {
        // nil is "no reading yet", which the rail draws live-looking rather than
        // greying — otherwise every row flashes grey on launch before the first
        // poll lands.
        XCTAssertFalse(RailStateModel.isStopped(nil))
    }

    func testAnAbsentAgentIsStopped() {
        // The join's own words when a session has no claude in it.
        XCTAssertTrue(RailStateModel.isStopped(
            state(alive: false, phase: .unknown,
                  reason: "no claude process found in any pane of 'deck'")))
        // And an ended session, whatever its reason.
        XCTAssertTrue(RailStateModel.isStopped(state(alive: false, phase: .ended)))
    }

    func testATransportFailureIsNotStopped() {
        // "cannot reach the session" is the mini being unreachable, not the
        // session being down. Greying it — and offering a Start that would fail
        // "already has an agent" — would be a confident wrong answer.
        XCTAssertFalse(RailStateModel.isStopped(
            state(alive: false, phase: .unknown, reason: "cannot reach the session")))
    }

    func testALiveSessionIsNeverStopped() {
        for phase in [SessionState.Phase.idle, .working, .waiting, .blocked] {
            XCTAssertFalse(RailStateModel.isStopped(state(alive: true, phase: phase)), "\(phase)")
        }
    }

    // MARK: - Which start failure the user is allowed to hear

    func testAnAlreadyRunningAgentIsTheOneFailureNotWorthShowing() {
        // The rail's poll was a beat stale and selecting the row did the right
        // thing, so an alert would be noise.
        XCTAssertTrue(SessionAgent.isBenignStartFailure(
            "session 'deck' already has an agent"))
    }

    func testAnExistingSessionWithNoAgentIsSurfaced() {
        // THE REGRESSION THIS LOCKS. This message was swallowed too, and it is
        // not benign: a session whose agent had exited greyed on the rail,
        // offered a Start, and had every attempt discarded in silence. The pane
        // flipped to "Starting…" and back with no explanation, on a row that
        // could never recover. Observed on `ask`, 2026-07-24.
        XCTAssertFalse(SessionAgent.isBenignStartFailure(
            "session 'ask' already exists"))
        // The mini adopts an agentless session now, so what it returns instead
        // is a pane that cannot take keystrokes — actionable, and shown.
        XCTAssertFalse(SessionAgent.isBenignStartFailure(
            "session 'ask' exists and no pane of it is at a shell prompt"))
    }

    func testAnOrdinaryFailureIsSurfaced() {
        for message in ["tmux could not create session 'deck'",
                        "no such directory: /nope",
                        "session-agent: command not found",
                        ""] {
            XCTAssertFalse(SessionAgent.isBenignStartFailure(message), message)
        }
    }
}
