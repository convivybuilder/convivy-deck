import XCTest
@testable import Deck

/// the operator's ruling, 2026-09-05, on the ⌘1-9 collision between the rail's
/// crew-jump and the gate's own option shortcuts: the gate wins while it is
/// showing, and the rail's bindings stand down for exactly that long.
///
/// `RailView`'s own `.keyboardShortcut` binding is not reachable without a
/// view-level test target, so this pins the predicate that decides
/// suppression — `RailView.suppressesNumberShortcuts` — rather than the
/// binding itself. The actual key-equivalent behaviour is a hand-check (see
/// the PR body).
@MainActor
final class RailGateShortcutSuppressionTests: XCTestCase {
    private let a = SessionRef(host: nil, name: "a")
    private let b = SessionRef(host: nil, name: "b")

    func testNoSelectionNeverSuppresses() {
        XCTAssertFalse(
            RailView.suppressesNumberShortcuts(selection: nil, hasOpenGate: { _ in true }))
    }

    func testSuppressesWhenTheSelectedSessionHasAnOpenGate() {
        XCTAssertTrue(
            RailView.suppressesNumberShortcuts(selection: a, hasOpenGate: { $0 == a }))
    }

    /// The case the ruling calls out by name: a gate open in some OTHER
    /// crew is not on screen and must not disable navigation while looking
    /// at an ordinary pane. `b` has the open gate; `a` is selected and does
    /// not.
    func testAGateInAnUnselectedSessionDoesNotSuppress() {
        XCTAssertFalse(
            RailView.suppressesNumberShortcuts(selection: a, hasOpenGate: { $0 == b }))
    }

    /// Nothing is latched: the same selection reads false the instant
    /// `hasOpenGate` stops reporting a gate, exactly as the pane's own
    /// composer falls back the moment `state.gate` goes nil.
    func testRecoversTheInstantTheGateClears() {
        let selected = a
        var gateOpen = true
        let predicate: (SessionRef) -> Bool = { $0 == selected && gateOpen }

        XCTAssertTrue(RailView.suppressesNumberShortcuts(selection: selected, hasOpenGate: predicate))
        gateOpen = false
        XCTAssertFalse(RailView.suppressesNumberShortcuts(selection: selected, hasOpenGate: predicate))
    }

    // MARK: - RailStateModel.hasOpenGate, the pure form

    private func state(gate: SessionState.Gate?) -> SessionState {
        SessionState(session: "a", phase: .blocked, gate: gate, alive: true,
                     reason: nil, lastEvent: nil, transcriptMTime: nil)
    }

    func testHasOpenGateIsFalseForANilReading() {
        XCTAssertFalse(RailStateModel.hasOpenGate(nil))
    }

    func testHasOpenGateIsFalseWhenTheReadingCarriesNoGate() {
        XCTAssertFalse(RailStateModel.hasOpenGate(state(gate: nil)))
    }

    func testHasOpenGateIsTrueWhenTheReadingCarriesAGate() {
        let gate = SessionState.Gate(
            kind: .permission, tool: "Bash",
            questions: [.init(question: "Run this?", header: nil, options: [])],
            hasSuggestions: false)
        XCTAssertTrue(RailStateModel.hasOpenGate(state(gate: gate)))
    }

    // MARK: - The pushed path (event-driven, ahead of the 4s poll)

    /// The seam `SessionPaneView.onGateChange` calls into: `applyPushedGate`
    /// must flip `hasOpenGate`'s instance-level answer immediately, with no
    /// poll and no `Task.sleep` — this is the whole point of the push path
    /// existing beside `RailStateModel.refresh()`'s 4-second loop.
    func testAPushedGateOpenFlipsHasOpenGateWithoutAPoll() {
        let model = RailStateModel()
        XCTAssertFalse(model.hasOpenGate(a))
        model.applyPushedGate(true, for: a)
        XCTAssertTrue(model.hasOpenGate(a))
    }

    /// No latching: a pushed close reading recovers `hasOpenGate` just as
    /// immediately as a pushed open one suppressed it — both directions go
    /// through the same call, never a one-way latch.
    func testAPushedGateCloseRecoversHasOpenGateWithoutAPoll() {
        let model = RailStateModel()
        model.applyPushedGate(true, for: a)
        XCTAssertTrue(model.hasOpenGate(a))
        model.applyPushedGate(false, for: a)
        XCTAssertFalse(model.hasOpenGate(a))
    }

    /// A push for a session that is not the one being asked about must not
    /// leak into another session's answer — the same "only the selected
    /// session's gate suppresses" rule `testAGateInAnUnselectedSessionDoesNotSuppress`
    /// pins for the pure predicate, exercised here against the pushed path.
    func testAPushForOneSessionDoesNotAffectAnothers() {
        let model = RailStateModel()
        model.applyPushedGate(true, for: b)
        XCTAssertFalse(model.hasOpenGate(a))
        XCTAssertTrue(model.hasOpenGate(b))
    }

    /// While no push has landed for a session, `hasOpenGate` falls back to
    /// the poll-fed `states` reading — the 4-second loop stays the backstop
    /// a push that never arrives (a follower fallen back to its own polling,
    /// or a session that was never selected) still needs. Goes through a
    /// real `refresh()` rather than writing `states` directly, the same
    /// seam `RailStateModelRefreshTests` uses to pin `refresh()`'s own
    /// behaviour without an ssh round trip.
    func testWithNoPushHasOpenGateFallsBackToThePolledReading() async {
        let model = RailStateModel()
        let target = SSHTarget(user: "operator", host: "10.0.0.1")
        model.sessions = [a]
        model.resolveHost = { _ in target }
        let gate = SessionState.Gate(
            kind: .permission, tool: "Bash",
            questions: [.init(question: "Run this?", header: nil, options: [])],
            hasSuggestions: false)
        model.fetchStates = { [gateState = state(gate: gate)] _, _ in ["a": gateState] }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .unknown }

        XCTAssertFalse(model.hasOpenGate(a), "unpolled reads as no gate")
        await model.refresh()
        XCTAssertTrue(model.hasOpenGate(a))
    }

    /// `clearPushedGate` drops a push once its pane goes away — after
    /// clearing, `hasOpenGate` reads straight off the poll again rather than
    /// continuing to answer off a reading nobody is pushing anymore.
    func testClearingAPushedGateFallsBackToThePolledReading() {
        let model = RailStateModel()
        model.applyPushedGate(true, for: a)
        XCTAssertTrue(model.hasOpenGate(a))
        model.clearPushedGate(for: a)
        XCTAssertFalse(model.hasOpenGate(a))
    }
}
