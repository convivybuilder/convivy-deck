import XCTest
@testable import Deck

/// `RailPoll`'s pure grouping and merge helpers back `RailStateModel.refresh`'s
/// per-host fan-out (phase 6a/6b of
/// `deck/specs/multiple-sessions-per-project` §"Crews on different hosts").
/// Split out precisely so the shape can be pinned here, without a real ssh
/// round trip — `refresh` itself talks to a live mini and is not unit-tested.
final class RailPollTests: XCTestCase {
    private let mini = TestHost.target
    private let laptop = SSHTarget(user: TestHost.secondaryUser, host: "10.0.0.5")

    private func ref(_ name: String, host: String? = nil) -> SessionRef {
        SessionRef(host: host, name: name)
    }

    private func state(alive: Bool) -> SessionState {
        SessionState(session: "x", phase: alive ? .working : .ended, gate: nil,
                    alive: alive, reason: nil, lastEvent: nil)
    }

    // MARK: - grouped

    /// With one host defined, every tracked ref lands in the same bucket —
    /// this is how the refactor collapses to "exactly today's two calls".
    func testRefsAcrossOneHostGroupIntoOneBucket() {
        let refs = [ref("ask"), ref("vivy"), ref("deck")]
        let groups = RailPoll.grouped(refs, resolveHost: { _ in self.mini })
        XCTAssertEqual(groups, [mini: refs])
    }

    func testRefsAcrossTwoHostsGroupSeparately() {
        let askRef = ref("ask")
        let vivyChildRef = ref("vivy--research", host: "laptop")
        let groups = RailPoll.grouped([askRef, vivyChildRef], resolveHost: {
            $0.host == "laptop" ? self.laptop : self.mini
        })
        XCTAssertEqual(groups[mini], [askRef])
        XCTAssertEqual(groups[laptop], [vivyChildRef])
    }

    /// The proof case: two hosts each running a session named `vivy` group
    /// into two entirely separate buckets, keyed by the resolved target
    /// rather than colliding on the shared name.
    func testTwoHostsWithTheSameSessionNameGroupSeparately() {
        let miniVivy = ref("vivy", host: "mini")
        let guestVivy = ref("vivy", host: "guest")
        let guest = TestHost.secondaryTarget
        let groups = RailPoll.grouped([miniVivy, guestVivy], resolveHost: {
            $0.host == "guest" ? guest : self.mini
        })
        XCTAssertEqual(groups[mini], [miniVivy])
        XCTAssertEqual(groups[guest], [guestVivy])
    }

    func testAnEmptyRefListGroupsToNothing() {
        XCTAssertTrue(RailPoll.grouped([], resolveHost: { _ in self.mini }).isEmpty)
    }

    // MARK: - mergedStates

    /// The property under test: an unreachable host's `nil` outcome must
    /// not blank the sessions it was asked about — they keep the last good
    /// reading — while a host that DID answer overlays its own entries.
    func testAnUnreachableHostLeavesTheOthersReadingsIntact() {
        let askRef = ref("ask")
        let vivyChildRef = ref("vivy--research", host: "laptop")
        let previous: [SessionRef: SessionState] = [
            askRef: state(alive: true),
            vivyChildRef: state(alive: true),
        ]
        let freshAskReading = state(alive: false)
        let merged = RailPoll.mergedStates(previous: previous, outcomes: [
            mini: [askRef: freshAskReading],
            laptop: nil,
        ])
        XCTAssertEqual(merged[askRef]?.alive, false, "the reachable host's fresh reading applies")
        XCTAssertEqual(merged[vivyChildRef]?.alive, true,
                       "the unreachable host's session keeps its last good reading, not blanked")
    }

    func testBothHostsSucceedingOverlaysBoth() {
        let askRef = ref("ask")
        let vivyChildRef = ref("vivy--research", host: "laptop")
        let previous: [SessionRef: SessionState] = [:]
        let merged = RailPoll.mergedStates(previous: previous, outcomes: [
            mini: [askRef: state(alive: true)],
            laptop: [vivyChildRef: state(alive: false)],
        ])
        XCTAssertEqual(merged[askRef]?.alive, true)
        XCTAssertEqual(merged[vivyChildRef]?.alive, false)
    }

    func testEveryHostFailingLeavesThePreviousReadingWhollyUnchanged() {
        let askRef = ref("ask")
        let previous: [SessionRef: SessionState] = [askRef: state(alive: true)]
        let merged = RailPoll.mergedStates(previous: previous, outcomes: [mini: nil, laptop: nil])
        XCTAssertEqual(merged, previous)
    }

    /// The same-name-two-hosts collision the tuple exists to resolve: each
    /// host's own reading for `vivy` lands under its own `SessionRef`
    /// rather than one overwriting the other.
    func testTwoHostsBothReportingTheSameSessionNameStayDistinct() {
        let miniVivy = ref("vivy", host: "mini")
        let guestVivy = ref("vivy", host: "guest")
        let guest = TestHost.secondaryTarget
        let merged = RailPoll.mergedStates(previous: [:], outcomes: [
            mini: [miniVivy: state(alive: true)],
            guest: [guestVivy: state(alive: false)],
        ])
        XCTAssertEqual(merged[miniVivy]?.alive, true)
        XCTAssertEqual(merged[guestVivy]?.alive, false)
    }

    // MARK: - the two-host fixture: a declared-but-unreachable second host
    //
    // The state the operator can verify today without a second real machine: a
    // `hosts` entry pointing at an address that never answers. Both the
    // display fallback (`HostDisplay`) and the poll's own degradation
    // (`RailPoll`) have to hold for it — this section pins both halves
    // together against one fixture, per this phase's brief.

    private let declaredButUnreachable = HostEntry(name: "ghost", user: "operator", address: "10.255.255.1")

    /// The reachable host's crews keep advancing every tick regardless of
    /// the unreachable one's standing outcome — the same guarantee
    /// `testAnUnreachableHostLeavesTheOthersReadingsIntact` pins, restated
    /// against this fixture's own two hosts.
    func testTheReachableHostsCrewsAdvanceWhileTheDeclaredHostNeverAnswers() {
        let miniAsk = ref("ask", host: "mini")
        let ghostVivy = ref("vivy", host: "ghost")
        let ghostTarget = SSHTarget(user: declaredButUnreachable.user, host: declaredButUnreachable.address)
        let previous: [SessionRef: SessionState] = [:]

        let firstTick = RailPoll.mergedStates(previous: previous, outcomes: [
            mini: [miniAsk: state(alive: true)],
            ghostTarget: nil,
        ])
        XCTAssertEqual(firstTick[miniAsk]?.alive, true)
        // Never having landed at all is a different fact from having landed
        // and reported stopped — this ref is simply absent, which is what
        // the rail reads as "unpolled" rather than "state unknown but
        // definitely tried."
        XCTAssertNil(firstTick[ghostVivy])

        // A later tick where mini has moved on and ghost still hasn't
        // answered: mini's crews keep advancing, ghost's entry (there isn't
        // one) still costs nothing.
        let secondTick = RailPoll.mergedStates(previous: firstTick, outcomes: [
            mini: [miniAsk: state(alive: false)],
            ghostTarget: nil,
        ])
        XCTAssertEqual(secondTick[miniAsk]?.alive, false, "the reachable host's poll must not stall")
        XCTAssertNil(secondTick[ghostVivy])
    }

    /// The display half of the same fixture: with the probe never landing,
    /// the label falls back to the configured host NAME (recovered from
    /// `hosts` via the target the crew resolved to) — never a placeholder,
    /// since the config name is known the moment the entry exists, whether
    /// or not the box behind it ever answers.
    func testTheDeclaredButUnreachableHostsLabelFallsBackToItsConfiguredName() {
        let ghostTarget = SSHTarget(user: declaredButUnreachable.user, host: declaredButUnreachable.address)
        let label = HostDisplay.label(
            for: ghostTarget, hosts: [declaredButUnreachable], probed: { _ in nil })
        XCTAssertEqual(label, "operator@ghost", "the config host NAME is used once the probe hasn't landed")
    }

    // MARK: - demotedStates

    /// `issue_01M23WC488NVYT6T5MDZN37ZBR`: every session asked about on a
    /// host whose poll failed outright demotes to `.unreadable`, never a
    /// filled mark surviving on stale data.
    func testDemotedStatesResolveToTheUnreadableMark() {
        let askRef = ref("ask")
        let vivyRef = ref("vivy")
        let demoted = RailPoll.demotedStates(for: [askRef, vivyRef])
        XCTAssertEqual(demoted[askRef]?.mark, .unreadable)
        XCTAssertEqual(demoted[vivyRef]?.mark, .unreadable)
    }

    /// The case that must still work: merging a host's demoted placeholders
    /// through `mergedStates` overwrites whatever filled mark that host's
    /// refs last drew — this is what `RailStateModel.refresh` actually does
    /// on a failed `states` call, in place of leaving the previous reading
    /// standing.
    func testMergingDemotedStatesOverwritesAPreviouslyFilledMark() {
        let askRef = ref("ask")
        let previous: [SessionRef: SessionState] = [askRef: state(alive: true)]
        XCTAssertEqual(previous[askRef]?.mark, .busy)

        let merged = RailPoll.mergedStates(
            previous: previous, outcomes: [mini: RailPoll.demotedStates(for: [askRef])])
        XCTAssertEqual(merged[askRef]?.mark, .unreadable,
                       "a host's own failed poll must demote its refs' filled marks, not leave them standing")
    }

    // MARK: - mergedDiscovered

    func testAnUnreachableHostLeavesTheOthersDiscoveredSessionsIntact() {
        let previous: [DiscoveredSession.ID: DiscoveredSession] = [
            DiscoveredSession.ID(host: mini, name: "ask"):
                DiscoveredSession(name: "ask", host: mini, path: "\(TestHost.homeRoot)/Convivy/ask",
                                 windows: 1, attached: true),
            DiscoveredSession.ID(host: laptop, name: "vivy--research"):
                DiscoveredSession(name: "vivy--research", host: laptop, path: "\(TestHost.secondaryHomeRoot)/vivy",
                                  windows: 1, attached: false),
        ]
        let freshAsk = DiscoveredSession(name: "ask", host: mini, path: "\(TestHost.homeRoot)/Convivy/ask",
                                         windows: 2, attached: false)
        let merged = RailPoll.mergedDiscovered(previous: previous, outcomes: [
            mini: [freshAsk],
            laptop: nil,
        ])
        XCTAssertEqual(merged[freshAsk.id]?.windows, 2, "the reachable host's fresh reading applies")
        XCTAssertEqual(merged[DiscoveredSession.ID(host: laptop, name: "vivy--research")]?.attached, false,
                       "the unreachable host's row keeps its last good reading, not dropped")
    }

    /// Two hosts each discovering a session named `scratch` must not
    /// collide — `DiscoveredSession.ID` carries the actual host, so the
    /// two rows key separately even though their names agree.
    func testTwoHostsDiscoveringTheSameSessionNameStayDistinct() {
        let guest = TestHost.secondaryTarget
        let miniRow = DiscoveredSession(name: "scratch", host: mini, path: nil, windows: 1, attached: nil)
        let guestRow = DiscoveredSession(name: "scratch", host: guest, path: nil, windows: 1, attached: nil)
        let merged = RailPoll.mergedDiscovered(previous: [:], outcomes: [
            mini: [miniRow],
            guest: [guestRow],
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[miniRow.id], miniRow)
        XCTAssertEqual(merged[guestRow.id], guestRow)
    }

    /// The bug this PR fixes: `comptroller` stopped on 2026-08-14, the mini
    /// has answered cleanly ever since, and the stale row must not survive
    /// a single answering poll — `discovered` is an inventory, so a name the
    /// host no longer reports is gone, not merely unmentioned.
    func testAHostsAnswerDropsASessionItNoLongerReports() {
        let comptroller = DiscoveredSession(name: "comptroller", host: mini,
                                            path: "\(TestHost.homeRoot)/Convivy/comptroller",
                                            windows: 1, attached: false)
        let ask = DiscoveredSession(name: "ask", host: mini,
                                    path: "\(TestHost.homeRoot)/Convivy/ask", windows: 1, attached: true)
        let previous: [DiscoveredSession.ID: DiscoveredSession] = [
            comptroller.id: comptroller,
            ask.id: ask,
        ]
        let merged = RailPoll.mergedDiscovered(previous: previous, outcomes: [mini: [ask]])
        XCTAssertNil(merged[comptroller.id], "comptroller is gone from the host's own answer, so it must not linger")
        XCTAssertEqual(merged[ask.id], ask)
    }

    /// An answering host reporting an EMPTY list is a real answer — "this
    /// host has no sessions" — and must clear every one of that host's
    /// previous entries, not be read as no news.
    func testAHostsEmptyAnswerDropsAllOfThatHostsEntries() {
        let ask = DiscoveredSession(name: "ask", host: mini,
                                    path: "\(TestHost.homeRoot)/Convivy/ask", windows: 1, attached: true)
        let previous: [DiscoveredSession.ID: DiscoveredSession] = [ask.id: ask]
        let merged = RailPoll.mergedDiscovered(previous: previous, outcomes: [mini: []])
        XCTAssertTrue(merged.isEmpty)
    }

    /// The `nil`-outcome half of the same rule, restated directly against
    /// `mergedDiscovered`: an unreachable host's entries survive untouched.
    func testAnUnreachableHostsOutcomeOfNilLeavesEveryEntrySurviving() {
        let ask = DiscoveredSession(name: "ask", host: mini,
                                    path: "\(TestHost.homeRoot)/Convivy/ask", windows: 1, attached: true)
        let previous: [DiscoveredSession.ID: DiscoveredSession] = [ask.id: ask]
        let merged = RailPoll.mergedDiscovered(previous: previous, outcomes: [mini: nil])
        XCTAssertEqual(merged, previous)
    }

    /// Two hosts, one answering and one unreachable: the answering host's
    /// removal of its own stale entry must not touch the unreachable host's
    /// entries, and vice versa — each host's answer is scoped to its own
    /// `DiscoveredSession.ID`s only.
    func testOneHostsRemovalDoesNotTouchAnUnreachableHostsEntries() {
        let staleAsk = DiscoveredSession(name: "ask", host: mini,
                                         path: "\(TestHost.homeRoot)/Convivy/ask", windows: 1, attached: true)
        let vivyChild = DiscoveredSession(name: "vivy--research", host: laptop,
                                          path: "\(TestHost.secondaryHomeRoot)/vivy", windows: 1, attached: false)
        let previous: [DiscoveredSession.ID: DiscoveredSession] = [
            staleAsk.id: staleAsk,
            vivyChild.id: vivyChild,
        ]
        // mini answers with no sessions at all — its stale `ask` row is
        // dropped — while laptop never answers this tick.
        let merged = RailPoll.mergedDiscovered(previous: previous, outcomes: [
            mini: [],
            laptop: nil,
        ])
        XCTAssertNil(merged[staleAsk.id], "mini's own answer drops its stale entry")
        XCTAssertEqual(merged[vivyChild.id], vivyChild, "laptop's entry is untouched by mini's answer")
    }

    // MARK: - mergedServedCrews

    private func served(_ id: String, host: SSHTarget) -> ServedCrew {
        ServedCrew(crewId: id, host: host)
    }

    func testAnUnreachableHostLeavesTheOthersServedCrewsIntact() {
        let previous: [ServedCrew.ID: ServedCrew] = [
            served("placard", host: mini).id: served("placard", host: mini),
        ]
        let merged = RailPoll.mergedServedCrews(previous: previous, outcomes: [
            mini: nil,
        ])
        XCTAssertEqual(merged, previous)
    }

    /// The same inventory rule `mergedDiscovered` follows: a host that
    /// answers is authoritative for its own crew specs, so a spec it no
    /// longer reports is gone, not merely unmentioned.
    func testAHostsAnswerDropsAServedCrewItNoLongerReports() {
        let removed = served("old-crew", host: mini)
        let kept = served("placard", host: mini)
        let previous: [ServedCrew.ID: ServedCrew] = [removed.id: removed, kept.id: kept]
        let merged = RailPoll.mergedServedCrews(previous: previous, outcomes: [mini: [kept]])
        XCTAssertNil(merged[removed.id])
        XCTAssertEqual(merged[kept.id], kept)
    }

    func testTwoHostsServingTheSameCrewIdStayDistinct() {
        let guest = TestHost.secondaryTarget
        let miniRow = served("placard", host: mini)
        let guestRow = served("placard", host: guest)
        let merged = RailPoll.mergedServedCrews(previous: [:], outcomes: [
            mini: [miniRow],
            guest: [guestRow],
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[miniRow.id], miniRow)
        XCTAssertEqual(merged[guestRow.id], guestRow)
    }
}
