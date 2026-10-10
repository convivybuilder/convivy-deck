import XCTest
@testable import Deck

/// `RailStateModel.runningSessionNames` — the crossing of a crew's session
/// names with `hasTmuxSession`, extracted from `ContentView`'s
/// `runningSessionCount(for:)`/`isChildRunning` so that wiring is no longer
/// private glue nothing exercises. Before this, both call sites reverted to
/// `isStopped` still passed the full suite — see `HasTmuxSessionTests` for
/// the predicate itself, `deck/specs/multiple-sessions-per-project` §"The
/// model" for why the two questions differ.
final class RunningSessionNamesTests: XCTestCase {
    /// A single configured host so a bare, hostless crew name still
    /// resolves to something real — see `HasTmuxSessionTests.mini`'s doc.
    private let mini = HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)

    private func discovered(_ sessions: [DiscoveredSession]) -> [DiscoveredSession.ID: DiscoveredSession] {
        Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    }

    /// THE OPERATOR'S EXACT CASE: a name whose agent is gone but whose tmux session
    /// is still alive must still come back as running. This is the scenario
    /// the reviewer's revert-to-`isStopped` mutation exposed as uncovered —
    /// `isStopped` would read this session as stopped and drop it from the
    /// result.
    func testANameWithNoAgentButALiveTmuxSessionCounts() {
        let names: Set<String> = ["ask"]
        let set = discovered([DiscoveredSession(name: "ask", host: TestHost.target, path: "/x")])
        let running = RailStateModel.runningSessionNames(
            among: names, host: nil, discovered: set, hosts: [mini], defaultHost: "mini")
        XCTAssertEqual(running, ["ask"])
    }

    /// A crew's session set can name more than one session; only the ones
    /// the mini actually reported a tmux session for come back.
    func testOnlyNamesWithATmuxSessionAreReturned() {
        let names: Set<String> = ["ask", "vivy", "gone"]
        let set = discovered([
            DiscoveredSession(name: "ask", host: TestHost.target),
            DiscoveredSession(name: "vivy", host: TestHost.target),
        ])
        let running = RailStateModel.runningSessionNames(
            among: names, host: nil, discovered: set, hosts: [mini], defaultHost: "mini")
        XCTAssertEqual(running, ["ask", "vivy"])
    }

    /// A crew with no tmux sessions at all among its names comes back empty
    /// — the ordinary "Remove" case with nothing running to warn about.
    func testNoMatchingSessionsReturnsEmpty() {
        let names: Set<String> = ["ask"]
        let running = RailStateModel.runningSessionNames(
            among: names, host: nil, discovered: [:], hosts: [], defaultHost: nil)
        XCTAssertTrue(running.isEmpty)
    }

    /// `host` scopes the lookup exactly the way `hasTmuxSession` itself
    /// does: a same-named session on a different host does not count.
    func testHostScopesTheLookupTheSameWayHasTmuxSessionDoes() {
        let guest = TestHost.secondaryTarget
        let hosts = [HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress)]
        let names: Set<String> = ["ask"]
        let set = discovered([DiscoveredSession(name: "ask", host: guest)])
        let running = RailStateModel.runningSessionNames(
            among: names, host: nil, discovered: set, hosts: hosts, defaultHost: nil)
        XCTAssertTrue(running.isEmpty, "a session on host \"guest\" must not count for the default host")
    }
}
