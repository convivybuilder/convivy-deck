import XCTest
@testable import Deck

/// `RailStateModel.hasTmuxSession` — the rule the Remove confirm's
/// running-sessions sentence and its "Remove and Stop" gate share, in place
/// of `isStopped`. `isStopped` answers "does this have a claude process";
/// this answers "does the mini report a tmux session for it at all", which
/// is the question those two call sites actually need to ask. See
/// `deck/specs/multiple-sessions-per-project` §"The model" and
/// `ContentView.runningSessionCount(for:)`.
final class HasTmuxSessionTests: XCTestCase {
    /// A single configured host so a bare, hostless `SessionRef` still
    /// resolves to something real — an unconfigured install (empty `hosts`,
    /// no `defaultHost`) resolves every such ref to nothing, per
    /// `deck/specs/running-deck-as-someone-else`, which is a different
    /// property from the one most of these tests pin.
    private let mini = HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)

    private func discovered(_ sessions: [DiscoveredSession]) -> [DiscoveredSession.ID: DiscoveredSession] {
        Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    }

    /// THE REGRESSION THIS LOCKS. A crew whose agent exited while its tmux
    /// session stayed alive — `isStopped` reads this as stopped (no claude
    /// process), but the session-agent `sessions` poll still reports the
    /// tmux session, and that is what must decide "is there anything here
    /// to stop".
    func testACrewWithNoAgentButALiveTmuxSessionCounts() {
        let ref = SessionRef(host: nil, name: "ask")
        let set = discovered([DiscoveredSession(name: "ask", host: TestHost.target, path: "/x")])
        XCTAssertTrue(RailStateModel.hasTmuxSession(ref, discovered: set, hosts: [mini], defaultHost: "mini"))
    }

    /// The ordinary case: a session with an agent is reported by `sessions`
    /// exactly the same as one without — `hasTmuxSession` cannot and does
    /// not distinguish them, which is the point.
    func testACrewWithAnAgentCounts() {
        let ref = SessionRef(host: nil, name: "ask")
        let set = discovered([DiscoveredSession(name: "ask", host: TestHost.target)])
        XCTAssertTrue(RailStateModel.hasTmuxSession(ref, discovered: set, hosts: [mini], defaultHost: "mini"))
    }

    /// A crew whose session is genuinely gone — never started, or already
    /// stopped and its tmux session killed — does not count. This is the
    /// case where the old `isStopped`-based rule happened to give the right
    /// answer; the new rule must still give it.
    func testACrewWithNoTmuxSessionAtAllDoesNotCount() {
        let ref = SessionRef(host: nil, name: "ask")
        XCTAssertFalse(RailStateModel.hasTmuxSession(ref, discovered: [:], hosts: [mini], defaultHost: "mini"))
    }

    /// A discovered set that has OTHER sessions, but not this one, must not
    /// count it either — this is what catches a rule that accidentally
    /// checks "is the set non-empty" instead of "does this name appear in
    /// it".
    func testAnUnrelatedDiscoveredSessionDoesNotMakeThisOneCount() {
        let ref = SessionRef(host: nil, name: "ask")
        let set = discovered([DiscoveredSession(name: "vivy", host: TestHost.target)])
        XCTAssertFalse(RailStateModel.hasTmuxSession(ref, discovered: set, hosts: [mini], defaultHost: "mini"))
    }

    /// An unconfigured install — no `hosts`, no `defaultHost` — resolves a
    /// bare, hostless ref to nothing at all, so it can never report a tmux
    /// session even when the discovered set carries one under a configured
    /// host: the fallback that used to imply one compiled-in host is gone.
    /// See `deck/specs/running-deck-as-someone-else`.
    func testAnUnconfiguredInstallNeverCountsAnything() {
        let ref = SessionRef(host: nil, name: "ask")
        let set = discovered([DiscoveredSession(name: "ask", host: TestHost.target)])
        XCTAssertFalse(RailStateModel.hasTmuxSession(ref, discovered: set, hosts: [], defaultHost: nil))
    }

    /// A session on a DIFFERENT host with the same bare name must not count
    /// — the host boundary `SessionGrouping.owningCrewId` enforces elsewhere
    /// has to hold here too, or a crew on host B would read as running
    /// because host A happens to have a same-named session.
    func testASameNameSessionOnADifferentHostDoesNotCount() {
        let guest = TestHost.secondaryTarget
        let hosts = [mini, HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress)]
        let ref = SessionRef(host: nil, name: "ask") // resolves to the default (mini)
        let set = discovered([DiscoveredSession(name: "ask", host: guest)])
        XCTAssertFalse(RailStateModel.hasTmuxSession(ref, discovered: set, hosts: hosts, defaultHost: "mini"))
    }

    /// The ref's own `host` name is what resolves, not the default — a ref
    /// explicitly naming a host must find a session discovered on THAT
    /// host, even when it differs from the configured default.
    func testARefNamingItsOwnHostResolvesAgainstThatHostRatherThanTheDefault() {
        let guest = TestHost.secondaryTarget
        let hosts = [HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress)]
        let ref = SessionRef(host: "guest", name: "ask")
        let set = discovered([DiscoveredSession(name: "ask", host: guest)])
        XCTAssertTrue(RailStateModel.hasTmuxSession(ref, discovered: set, hosts: hosts, defaultHost: nil))
    }

    /// The instance method reads `self.discovered`, populated by a real
    /// `refresh()` through the `fetchStates`/`fetchDiscovered` seams — so
    /// this pins the wiring end to end, not just the pure static form. The
    /// fake `fetchStates` reports no agent at all, and the row still counts,
    /// because `fetchDiscovered` reports the tmux session.
    @MainActor
    func testTheInstanceMethodReadsATmuxSessionFoundByARealRefresh() async {
        let model = RailStateModel()
        let target = TestHost.target
        let ref = SessionRef(host: nil, name: "ask")
        model.sessions = [ref]
        model.resolveHost = { _ in target }
        model.fetchStates = { _, _ in
            ["ask": SessionState(session: "ask", phase: .ended, gate: nil,
                                  alive: false, reason: "no claude process", lastEvent: nil)]
        }
        model.fetchDiscovered = { _ in [DiscoveredSession(name: "ask", host: target, path: "/x")] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .unknown }

        await model.refresh()

        XCTAssertTrue(model.isStopped(ref), "precondition: the agent reading alone reads as stopped")
        // `hasTmuxSession`'s own host resolution is independent of
        // `resolveHost` above — it re-resolves `ref.host` against `hosts`/
        // `defaultHost`, so this needs its own explicit config naming the
        // same target `fetchDiscovered` reported the session on.
        XCTAssertTrue(
            model.hasTmuxSession(ref, hosts: [mini], defaultHost: "mini"),
            "the tmux session is still there per the sessions poll")
    }

    /// The mirror case: `fetchDiscovered` reports nothing for this name, so
    /// the instance method reads false even though a poll has landed.
    @MainActor
    func testTheInstanceMethodReadsFalseWhenNoDiscoverySessionMatches() async {
        let model = RailStateModel()
        let target = TestHost.target
        let ref = SessionRef(host: nil, name: "ask")
        model.sessions = [ref]
        model.resolveHost = { _ in target }
        model.fetchStates = { _, _ in [:] }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .unknown }

        await model.refresh()

        XCTAssertFalse(model.hasTmuxSession(ref))
    }
}
