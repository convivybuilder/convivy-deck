import Foundation
import XCTest
@testable import Deck

/// `RailStateModel.refresh()` itself — the real per-host publish path, not
/// just `RailPoll`'s pure merge helpers `RailPollTests` pins. Reached through
/// the `fetchStates`/`fetchDiscovered`/`fetchProbe` seams, so a host's
/// answer can be held or made to fail with no real ssh round trip.
///
/// `@MainActor` because `RailStateModel` is: `refresh()`, and every
/// `@Published` property it writes, only ever run there.
@MainActor
final class RailStateModelRefreshTests: XCTestCase {
    private let fast = TestHost.target
    private let slow = SSHTarget(user: "operator", host: "10.0.0.5")

    private func state(alive: Bool) -> SessionState {
        SessionState(session: "x", phase: alive ? .working : .ended, gate: nil,
                    alive: alive, reason: nil, lastEvent: nil)
    }

    /// The property deck-reviewer's finding traced from PR #110's third
    /// serial probe attempt: a slow or unreachable host must not hold back a
    /// reachable host's already-fetched readings. `RailPollTests`' two-host
    /// fixture only ever drove `RailPoll.mergedStates` with pre-computed
    /// outcomes, never `refresh()` itself, so it could not see this — the
    /// gap the finding named directly.
    ///
    /// The slow host's `fetchStates` blocks on a semaphore the test holds,
    /// so the ordering is pinned rather than raced: the fast host's reading
    /// is asserted to land — via an awaited poll, which yields the actor so
    /// `refresh()`'s own `for await` loop can actually run — WHILE the slow
    /// host is still provably blocked, not merely before some timeout.
    func testAFastHostsReadingLandsWithoutWaitingOnASlowHost() async {
        let model = RailStateModel()
        let fastRef = SessionRef(host: "fast", name: "ask")
        let slowRef = SessionRef(host: "slow", name: "vivy")
        model.sessions = [fastRef, slowRef]
        model.resolveHost = { [fast, slow] ref in ref.host == "slow" ? slow : fast }

        let slowGate = DispatchSemaphore(value: 0)
        model.fetchStates = { [slow, state = state(alive: true)] target, _ in
            if target == slow {
                slowGate.wait()
                throw SessionAgent.AgentError.failed("held for the test")
            }
            return ["ask": state]
        }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .unknown }

        let refreshTask = Task { await model.refresh() }

        let deadline = Date().addingTimeInterval(2)
        var landed = false
        while Date() < deadline {
            if model.states[fastRef] != nil { landed = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(landed, "the fast host's reading must land while the slow host is still blocked")
        XCTAssertNil(model.states[slowRef], "the slow host has not answered yet")

        slowGate.signal()
        await refreshTask.value
    }

    /// The third serial ssh attempt deck-reviewer flagged: a probe that
    /// keeps failing must not be retried on every four-second tick forever.
    /// Calls `refresh()` three times back to back — three ticks — and
    /// asserts the probe was actually attempted only once, the rest sitting
    /// out backoff.
    func testAFailedProbeBacksOffRatherThanRetryingEveryTick() async {
        let model = RailStateModel()
        let ref = SessionRef(host: "fast", name: "ask")
        model.sessions = [ref]
        model.resolveHost = { [fast] _ in fast }
        model.fetchStates = { _, _ in [:] }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchDesktopSession = { _ in .unknown }

        let attempts = AtomicCounter()
        model.fetchProbe = { _ in
            attempts.increment()
            throw SessionAgent.AgentError.failed("never answers")
        }

        for _ in 0..<3 {
            await model.refresh()
        }

        XCTAssertEqual(attempts.value, 1,
                       "a failed probe must back off rather than retrying every tick")
    }

    // MARK: - unreachable hosts (issue_01M23WC488NVYT6T5MDZN37ZBR)
    //
    // The operator's report: on a plane, laptop off the tailnet, every session drew a
    // filled mark beside blank panes — the mini's `states` call was never
    // answering at all, and `refresh()` was leaving every session's last
    // filled mark standing rather than demoting it. These pin the state
    // layer's half of the fix; the render itself is not observed here (this
    // machine has no Screen Recording/Accessibility grant to drive a real
    // window) — see the PR body.

    /// The exact scenario reported: a session was `.listening` (a filled
    /// circle) on the last good poll, the host then goes fully unreachable,
    /// and the very next tick must demote that mark to `.unreadable` rather
    /// than repeating the stale filled one.
    func testASessionsFilledMarkDemotesToUnreadableWhenItsHostGoesUnreachable() async {
        let model = RailStateModel()
        let ref = SessionRef(host: "fast", name: "ask")
        model.sessions = [ref]
        model.resolveHost = { [fast] _ in fast }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .unknown }

        // A first, healthy tick: the session lands with dispatched agents
        // alive behind it, drawing the filled `.listening` mark.
        model.fetchStates = { _, _ in
            ["ask": SessionState(session: "ask", phase: .idle, gate: nil, alive: true,
                                 reason: nil, lastEvent: nil, liveAgents: ["writer"])]
        }
        await model.refresh()
        XCTAssertEqual(model.states[ref]?.mark, .listening, "the healthy tick draws the filled mark")
        XCTAssertFalse(model.isHostUnreachable(fast))

        // The plane scenario: the host stops answering `states` at all —
        // not an empty batch, an outright transport failure.
        model.fetchStates = { _, _ in throw SessionAgent.AgentError.failed("ssh: connect timed out") }
        await model.refresh()

        XCTAssertEqual(model.states[ref]?.mark, .unreadable,
                       "an unreachable host must demote its sessions' marks rather than repeat the stale filled one")
        XCTAssertTrue(model.isHostUnreachable(fast))
    }

    /// The case that must still work: a host recovering clears both the
    /// demoted mark and the unreachable flag on its very next answering
    /// poll, and does so from real fetched data rather than merely
    /// resetting to some default.
    func testAHostRecoveringClearsBothTheDemotedMarkAndTheUnreachableFlag() async {
        let model = RailStateModel()
        let ref = SessionRef(host: "fast", name: "ask")
        model.sessions = [ref]
        model.resolveHost = { [fast] _ in fast }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .unknown }

        model.fetchStates = { _, _ in throw SessionAgent.AgentError.failed("ssh: connect timed out") }
        await model.refresh()
        XCTAssertEqual(model.states[ref]?.mark, .unreadable)
        XCTAssertTrue(model.isHostUnreachable(fast))

        model.fetchStates = { _, _ in
            ["ask": SessionState(session: "ask", phase: .working, gate: nil, alive: true,
                                 reason: nil, lastEvent: nil)]
        }
        await model.refresh()

        XCTAssertEqual(model.states[ref]?.mark, .busy, "a landed poll must overwrite the demoted placeholder")
        XCTAssertFalse(model.isHostUnreachable(fast), "a host that just answered is no longer unreachable")
    }

    /// Per-host, not global: one configured host answering while a second
    /// is unreachable must demote only the unreachable one's sessions and
    /// flag only that host, never the reachable one's.
    func testOneHostsFailureDoesNotMarkAReachableHostUnreachable() async {
        let model = RailStateModel()
        let fastRef = SessionRef(host: "fast", name: "ask")
        let slowRef = SessionRef(host: "slow", name: "vivy")
        model.sessions = [fastRef, slowRef]
        model.resolveHost = { [fast, slow] ref in ref.host == "slow" ? slow : fast }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .unknown }
        model.fetchStates = { [slow] target, _ in
            if target == slow { throw SessionAgent.AgentError.failed("ssh: connect timed out") }
            return ["ask": SessionState(session: "ask", phase: .working, gate: nil,
                                        alive: true, reason: nil, lastEvent: nil)]
        }

        await model.refresh()

        XCTAssertEqual(model.states[fastRef]?.mark, .busy, "the reachable host's session draws its real mark")
        XCTAssertFalse(model.isHostUnreachable(fast))
        XCTAssertEqual(model.states[slowRef]?.mark, .unreadable, "the unreachable host's session demotes")
        XCTAssertTrue(model.isHostUnreachable(slow))
    }

    // MARK: - a configured host with no crew (issue_01M3RGBXYGMC4D9K1CEP63R9G1)
    //
    // macmini runs a tmux session no crew owns, so `RailPoll.grouped` never
    // gave it a bucket at all: `session-agent sessions`/`crews` were simply
    // never run against it, and its sessions could never reach OTHER
    // SESSIONS or Promote to Crew. `configuredTargets` is what gives such a
    // host a bucket regardless of refs.

    /// The core fix: a host with no ref resolved to it, named only via
    /// `configuredTargets`, is still asked for `sessions` and `crews`.
    func testACrewLessHostIsPolledForDiscoveredSessionsAndServedCrews() async {
        let model = RailStateModel()
        let crewRef = SessionRef(host: "fast", name: "ask")
        model.sessions = [crewRef]
        model.resolveHost = { [fast] _ in fast }
        model.configuredTargets = { [fast, slow] in [fast, slow] }
        model.fetchStates = { _, _ in [:] }
        model.fetchDiscovered = { [slow] target in
            target == slow ? [DiscoveredSession(name: "steward", host: slow, path: "/x")] : []
        }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .unknown }

        await model.refresh()

        let steward = DiscoveredSession.ID(host: slow, name: "steward")
        XCTAssertNotNil(model.discovered[steward], "the crew-less host's discovered session must land")
    }

    /// `RailView.otherSessions` is what actually draws OTHER SESSIONS; this
    /// pins that a session discovered on a crew-less host reaches it, the
    /// same way any other discovered session does.
    func testACrewLessHostsDiscoveredSessionReachesOtherSessions() async {
        let model = RailStateModel()
        model.sessions = []
        model.configuredTargets = { [slow] in [slow] }
        model.fetchStates = { _, _ in [:] }
        model.fetchDiscovered = { [slow] _ in [DiscoveredSession(name: "steward", host: slow, path: "/x")] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .unknown }

        await model.refresh()

        let result = RailView.otherSessions(
            discoveredSessions: Array(model.discovered.values), crews: [], hosts: [], defaultHost: nil)
        XCTAssertEqual(result.map(\.name), ["steward"])
    }

    /// The states fetch takes names to ask about; a crew-less host has none,
    /// so it must never be called at all — not with an empty list, which
    /// would be indistinguishable from "asked and got nothing back."
    func testStatesFetchIsNotCalledForACrewLessHost() async {
        let model = RailStateModel()
        let crewRef = SessionRef(host: "fast", name: "ask")
        model.sessions = [crewRef]
        model.resolveHost = { [fast] _ in fast }
        model.configuredTargets = { [fast, slow] in [fast, slow] }

        let calledTargets = CalledTargets()
        model.fetchStates = { [state = state(alive: true)] target, _ in
            calledTargets.record(target)
            return ["ask": state]
        }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .unknown }

        await model.refresh()

        XCTAssertEqual(calledTargets.values, [fast], "only the host with a ref may have states fetched")
    }

    /// A crew-less host going unreachable is not a fact about any session's
    /// mark, and must not stall or demote a reachable host's own reading —
    /// the same per-host isolation `testOneHostsFailureDoesNotMarkAReachableHostUnreachable`
    /// pins for two hosts that both carry refs.
    func testAnUnreachableCrewLessHostLeavesOtherHostsStatesAndGenerationAlone() async {
        let model = RailStateModel()
        let crewRef = SessionRef(host: "fast", name: "ask")
        model.sessions = [crewRef]
        model.resolveHost = { [fast] _ in fast }
        model.configuredTargets = { [fast, slow] in [fast, slow] }
        model.fetchStates = { _, _ in
            ["ask": SessionState(session: "ask", phase: .working, gate: nil,
                                 alive: true, reason: nil, lastEvent: nil)]
        }
        model.fetchDiscovered = { [slow] target in
            if target == slow { throw SessionAgent.AgentError.failed("ssh: connect timed out") }
            return []
        }
        model.fetchServedCrews = { [slow] target in
            if target == slow { throw SessionAgent.AgentError.failed("ssh: connect timed out") }
            return []
        }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .unknown }

        await model.refresh()

        XCTAssertEqual(model.states[crewRef]?.mark, .busy, "the reachable host's session still draws its real mark")
        XCTAssertEqual(model.generation, 0, "the reachable host's poll still advances the generation")
        XCTAssertFalse(model.isHostUnreachable(fast))
        XCTAssertFalse(model.isHostUnreachable(slow), "a crew-less host has no refs to demote or mark unreachable")
    }

    // MARK: - desktop-session transitions (CQ·124)

    /// The first logged-out reading for a host raises its alert, and
    /// `desktopSessionKnownState` carries the fact even with no view ever
    /// reading it — the "shows in Deck itself, whether or not the operator
    /// has dismissed the alert" half of the item.
    func testADesktopSessionGoingLoggedOutRaisesOneAlertAndRecordsTheKnownState() async {
        let model = RailStateModel()
        let ref = SessionRef(host: "fast", name: "ask")
        model.sessions = [ref]
        model.resolveHost = { [fast] _ in fast }
        model.fetchStates = { _, _ in [:] }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { [fast] target in target == fast ? .loggedOut : .unknown }

        let notified = CalledTargets()
        model.onDesktopSessionLoggedOut = { notified.record($0) }
        await model.refresh()

        XCTAssertEqual(model.desktopSessionKnownState[fast], .loggedOut)
        XCTAssertEqual(notified.values, [fast])
    }

    /// The state holds — a second logged-out tick in a row must not
    /// raise another alert.
    func testADesktopSessionStayingLoggedOutDoesNotRaiseTwice() async {
        let model = RailStateModel()
        let ref = SessionRef(host: "fast", name: "ask")
        model.sessions = [ref]
        model.resolveHost = { [fast] _ in fast }
        model.fetchStates = { _, _ in [:] }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .loggedOut }

        let notified = CalledTargets()
        model.onDesktopSessionLoggedOut = { notified.record($0) }
        await model.refresh()
        await model.refresh()

        XCTAssertEqual(notified.values, [fast], "only the first tick's transition should raise an alert")
    }

    /// "For each configured host" — a crew-less host reaches the probe and
    /// the alert callback too, the same `configuredTargets` coverage
    /// `testACrewLessHostIsPolledForDiscoveredSessionsAndServedCrews` pins
    /// for `states`/`discovered`.
    func testACrewLessConfiguredHostStillRaisesAnAlertOnLoggedOut() async {
        let model = RailStateModel()
        model.sessions = []
        model.configuredTargets = { [slow] in [slow] }
        model.fetchStates = { _, _ in [:] }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .loggedOut }

        let notified = CalledTargets()
        model.onDesktopSessionLoggedOut = { notified.record($0) }
        await model.refresh()

        XCTAssertEqual(notified.values, [slow])
        XCTAssertEqual(model.desktopSessionKnownState[slow], .loggedOut)
    }

    /// An unknown reading never raises an alert and never clears a known
    /// logged-out state — `DesktopSessionTrackerTests` pins the pure rule;
    /// this is the same rule reached through a real `refresh()` tick.
    func testAnUnknownReadingNeitherRaisesAnAlertNorClearsTheKnownState() async {
        let model = RailStateModel()
        let ref = SessionRef(host: "fast", name: "ask")
        model.sessions = [ref]
        model.resolveHost = { [fast] _ in fast }
        model.fetchStates = { _, _ in [:] }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .loggedOut }

        let notified = CalledTargets()
        model.onDesktopSessionLoggedOut = { notified.record($0) }
        await model.refresh()

        model.fetchDesktopSession = { _ in .unknown }
        await model.refresh()

        XCTAssertEqual(notified.values, [fast], "the unknown tick must not have raised a second alert")
        XCTAssertEqual(model.desktopSessionKnownState[fast], .loggedOut, "the known state must survive the unknown reading")
    }
}

/// Records every target `fetchStates` was actually called with, so a test
/// can assert a crew-less host was skipped entirely rather than merely
/// asked with an empty name list.
private final class CalledTargets: @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [SSHTarget] = []

    func record(_ target: SSHTarget) {
        lock.lock()
        targets.append(target)
        lock.unlock()
    }

    var values: [SSHTarget] {
        lock.lock()
        defer { lock.unlock() }
        return targets
    }
}

/// A plain thread-safe counter — `fetchProbe`'s closure type is synchronous,
/// so an `actor` cannot be awaited from inside it; this is the minimal
/// substitute.
private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
