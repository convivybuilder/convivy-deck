import XCTest
@testable import Deck

/// `RailRunningSessions` — the type `ContentView.railRunningSessions`
/// constructs and both Remove confirms call straight into. `RunningSessionNamesTests`
/// and `HasTmuxSessionTests` pin the rule underneath; this file pins
/// `runningSessionCount(for:)`, `isChildRunning(_:_:)`, and the
/// `removeCrewAlertShape(for:)`/`removeChildAlertShape(for:_:)` decisions
/// built on them — all reachable and assertable here because this is a
/// plain struct, not a `View`.
///
/// It does NOT reach the four `ContentView` call sites that read these
/// values: those are still `private` on a SwiftUI `View`, so no test can
/// construct a `ContentView` and observe what it renders. Disconnecting one
/// of those call sites (e.g. hardcoding the button condition to `false`)
/// would still pass this file and the full suite — see the PR body for the
/// mutation that confirms it.
final class RailRunningSessionsTests: XCTestCase {
    /// A single configured host so a hostless crew still resolves to
    /// something real — an unconfigured install (empty `hosts`) resolves a
    /// `nil`-host crew to nothing, per
    /// `deck/specs/running-deck-as-someone-else`, which is a different
    /// property from the ones most of these tests pin.
    private let mini = HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)

    private func discovered(_ sessions: [DiscoveredSession]) -> [DiscoveredSession.ID: DiscoveredSession] {
        Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    }

    /// THE OPERATOR'S EXACT CASE, at this layer: a crew's own session has no agent
    /// but a live tmux session, so it must still count as one running
    /// session and mark the child as running.
    func testACrewsOwnAgentlessButLiveSessionCounts() {
        let crew = Crew(id: "ask", displayName: "Ask")
        let rail = RailRunningSessions(
            crews: [crew],
            discovered: discovered([DiscoveredSession(name: "ask", host: TestHost.target, path: "/x")]),
            hosts: [mini], defaultHost: "mini")

        XCTAssertEqual(rail.runningSessionCount(for: crew), 1)
    }

    /// The pinned-child mirror: a child with no agent but a live tmux
    /// session reads as running through `isChildRunning`, not just through
    /// the crew-level count.
    func testAPinnedChildsAgentlessButLiveSessionCountsAsRunning() {
        let session = PinnedSession(name: "ask--research", displayName: "research")
        let crew = Crew(id: "ask", displayName: "Ask", sessions: [session])
        let rail = RailRunningSessions(
            crews: [crew],
            discovered: discovered([DiscoveredSession(name: "ask--research", host: TestHost.target, path: "/x")]),
            hosts: [mini], defaultHost: "mini")

        XCTAssertTrue(rail.isChildRunning(crew, session))
    }

    /// A crew with nothing live at all — neither its own name nor any
    /// child's — counts zero and reads every child as not running. This is
    /// the case the pre-fix `isStopped` shape also got right, so it alone
    /// would not have caught the regression; it rules out a rewrite that
    /// always reports something running.
    func testACrewWithNothingLiveCountsZero() {
        let session = PinnedSession(name: "ask--research", displayName: "research")
        let crew = Crew(id: "ask", displayName: "Ask", sessions: [session])
        let rail = RailRunningSessions(crews: [crew], discovered: [:], hosts: [], defaultHost: nil)

        XCTAssertEqual(rail.runningSessionCount(for: crew), 0)
        XCTAssertFalse(rail.isChildRunning(crew, session))
    }

    /// A crew's own name, a pinned child, and a discovered child together —
    /// `runningSessionCount` must total every name `crewSessionNames(for:)`
    /// gathers, not just the crew's own row.
    func testCountsTheCrewsOwnPinnedAndDiscoveredSessionsTogether() {
        let session = PinnedSession(name: "ask--research", displayName: "research")
        let crew = Crew(id: "ask", displayName: "Ask", sessions: [session])
        let rail = RailRunningSessions(
            crews: [crew],
            discovered: discovered([
                DiscoveredSession(name: "ask", host: TestHost.target, path: "/x"),
                DiscoveredSession(name: "ask--research", host: TestHost.target, path: "/x"),
                DiscoveredSession(name: "ask--adopted", host: TestHost.target, path: "/x"),
            ]),
            hosts: [mini], defaultHost: "mini")

        XCTAssertEqual(rail.runningSessionCount(for: crew), 3)
    }

    // MARK: - removeCrewAlertShape / removeChildAlertShape

    /// Nothing running: no button, and the message carries no running
    /// sentence — the same case `testACrewWithNothingLiveCountsZero` pins
    /// at the count layer, now pinned at the shape `ContentView` renders.
    func testRemoveCrewAlertShapeWithNothingRunningHidesButton() {
        let crew = Crew(id: "ask", displayName: "Ask")
        let rail = RailRunningSessions(crews: [crew], discovered: [:], hosts: [], defaultHost: nil)

        let shape = rail.removeCrewAlertShape(for: crew)

        XCTAssertFalse(shape.showRemoveAndStopButton)
        XCTAssertFalse(shape.message.contains("running"))
    }

    /// Something running: the button appears, and the message is the same
    /// text `ContentView.removeCrewMessage(runningSessionCount:)` would
    /// produce for that count — both halves of one call.
    func testRemoveCrewAlertShapeWithARunningSessionShowsButtonAndMatchingMessage() {
        let crew = Crew(id: "ask", displayName: "Ask")
        let rail = RailRunningSessions(
            crews: [crew],
            discovered: discovered([DiscoveredSession(name: "ask", host: TestHost.target, path: "/x")]),
            hosts: [mini], defaultHost: "mini")

        let shape = rail.removeCrewAlertShape(for: crew)

        XCTAssertTrue(shape.showRemoveAndStopButton)
        XCTAssertEqual(shape.message,
                      ContentView.removeCrewMessage(runningSessionCount: 1, hostLabel: "mini"))
    }

    func testRemoveChildAlertShapeNotRunningHidesButton() {
        let session = PinnedSession(name: "ask--research", displayName: "research")
        let crew = Crew(id: "ask", displayName: "Ask", sessions: [session])
        let rail = RailRunningSessions(crews: [crew], discovered: [:], hosts: [], defaultHost: nil)

        let shape = rail.removeChildAlertShape(for: crew, session)

        XCTAssertFalse(shape.showRemoveAndStopButton)
        XCTAssertEqual(shape.message, ContentView.removeChildMessage(isRunning: false))
    }

    func testRemoveChildAlertShapeRunningShowsButtonAndMatchingMessage() {
        let session = PinnedSession(name: "ask--research", displayName: "research")
        let crew = Crew(id: "ask", displayName: "Ask", sessions: [session])
        let rail = RailRunningSessions(
            crews: [crew],
            discovered: discovered([DiscoveredSession(name: "ask--research", host: TestHost.target, path: "/x")]),
            hosts: [mini], defaultHost: "mini")

        let shape = rail.removeChildAlertShape(for: crew, session)

        XCTAssertTrue(shape.showRemoveAndStopButton)
        XCTAssertEqual(shape.message,
                      ContentView.removeChildMessage(isRunning: true, hostLabel: "mini"))
    }
}
