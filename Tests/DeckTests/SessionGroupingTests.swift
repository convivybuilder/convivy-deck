import XCTest
@testable import Deck

/// `SessionGrouping` decides which crew a session `session-agent sessions`
/// found belongs to — the two rules (name, then path) `deck/specs/multiple-
/// sessions-per-project` §"The model" specifies, checked in order, plus the
/// ordering rule for what draws under a crew once grouped, and (phase 6b) the
/// host boundary: a crew is a candidate only when its own resolved host
/// equals the discovered session's. PURE, so every case here runs with no
/// tmux session, no ssh round trip, and no poll.
final class SessionGroupingTests: XCTestCase {
    private let mini = TestHost.target
    private let laptop = SSHTarget(user: TestHost.secondaryUser, host: "10.0.0.5")
    private let hosts = [
        HostEntry(name: "mini", user: TestHost.user, address: TestHost.address),
        HostEntry(name: "laptop", user: TestHost.secondaryUser, address: "10.0.0.5"),
    ]

    private func session(_ name: String, host: SSHTarget = TestHost.target, path: String? = nil,
                         windows: Int? = nil, attached: Bool? = nil) -> DiscoveredSession {
        DiscoveredSession(name: name, host: host, path: path, windows: windows, attached: attached)
    }

    private func crew(_ id: String, dir: String? = nil, host: String? = nil) -> Crew {
        Crew(id: id, displayName: id, workingDirectory: dir, host: host)
    }

    // MARK: - Rule A: name

    func testExactNameMatch() {
        XCTAssertTrue(SessionGrouping.matchesByName("ask", crewId: "ask"))
    }

    func testDoubleDashPrefixMatches() {
        XCTAssertTrue(SessionGrouping.matchesByName("ask--tax", crewId: "ask"))
    }

    /// The double-dash separator exists precisely because a single dash
    /// already occurs inside a real fleet name — `sous-chef` must not
    /// register as a child of a crew called `sous`, and a lookalike
    /// crew `sous-chef-other` must not be swallowed by `sous-chef`.
    func testSingleDashLookalikeDoesNotMatch() {
        XCTAssertFalse(SessionGrouping.matchesByName("sous-chef-other", crewId: "sous-chef"))
        XCTAssertFalse(SessionGrouping.matchesByName("sous-chef", crewId: "sous"))
    }

    func testBareContainsIsNotEnough() {
        // "askreconsider" contains "ask" but is neither equal nor
        // `--`-qualified, so it must not match.
        XCTAssertFalse(SessionGrouping.matchesByName("askreconsider", crewId: "ask"))
    }

    func testScratchShellPrefixNeverMatchesByName() {
        XCTAssertFalse(SessionGrouping.matchesByName("deck-shell-ask", crewId: "ask"))
        XCTAssertFalse(SessionGrouping.matchesByName("\(scratchShellPrefix)ask--tax", crewId: "ask"))
    }

    // MARK: - Rule B: path

    func testPathInsideDirectoryMatchesExactlyOrWithBoundary() {
        XCTAssertTrue(SessionGrouping.isPath("\(TestHost.homeRoot)/Convivy/ask",
                                             inside: "\(TestHost.homeRoot)/Convivy/ask"))
        XCTAssertTrue(SessionGrouping.isPath("\(TestHost.homeRoot)/Convivy/ask/sub",
                                             inside: "\(TestHost.homeRoot)/Convivy/ask"))
    }

    /// A bare string prefix would wrongly match `.../ask` against a
    /// directory of `.../as` — the boundary must be a real path separator.
    func testPathIsNotABarePrefixMatch() {
        XCTAssertFalse(SessionGrouping.isPath("\(TestHost.homeRoot)/Convivy/ask",
                                              inside: "\(TestHost.homeRoot)/Convivy/as"))
    }

    func testExpandedWorkingDirectoryExpandsTildeAgainstTheMiniUser() {
        XCTAssertEqual(
            SessionGrouping.expandedWorkingDirectory("~/Convivy/ask", hostUser: TestHost.user),
            "\(TestHost.homeRoot)/Convivy/ask")
    }

    func testExpandedWorkingDirectoryPassesThroughAbsolutePaths() {
        XCTAssertEqual(
            SessionGrouping.expandedWorkingDirectory("\(TestHost.homeRoot)/Convivy/ask", hostUser: TestHost.user),
            "\(TestHost.homeRoot)/Convivy/ask")
    }

    func testExpandedWorkingDirectoryOfNilIsNil() {
        XCTAssertNil(SessionGrouping.expandedWorkingDirectory(nil, hostUser: TestHost.user))
    }

    /// Phase 6a's whole point: the parameter used to default to
    /// `SSHTarget.mini.user` and nothing else. A host whose user is not
    /// the mini's own account must expand against ITS OWN home, not the mini's.
    func testExpandedWorkingDirectoryExpandsAgainstANonMiniHostsUser() {
        XCTAssertEqual(
            SessionGrouping.expandedWorkingDirectory("~/Convivy/ask", hostUser: "otheruser"),
            "/Users/" + "otheruser" + "/Convivy/ask")
    }

    // MARK: - owningCrewId: rule ordering and precedence

    /// Rule A is checked first and short-circuits — a name match must never
    /// fall through to a path comparison that might disagree with it.
    func testNameRuleWinsEvenWhenPathWouldMatchAnotherCrew() {
        let crews = [
            crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask"),
            crew("other", dir: "\(TestHost.homeRoot)/Convivy/other"),
        ]
        let discovered = session("ask--research", path: "\(TestHost.homeRoot)/Convivy/other")
        XCTAssertEqual(
            SessionGrouping.owningCrewId(for: discovered, crews: crews, hosts: hosts, defaultHost: "mini"),
            "ask")
    }

    /// Among every crew whose directory contains the path, the LONGEST
    /// expanded directory wins — a nested child crew's own directory
    /// claims a session before its parent does.
    func testLongestPathMatchWins() {
        let crews = [
            crew("parent", dir: "\(TestHost.homeRoot)/Convivy/parent"),
            crew("child", dir: "\(TestHost.homeRoot)/Convivy/parent/child"),
        ]
        let discovered = session("hand-made", path: "\(TestHost.homeRoot)/Convivy/parent/child/work")
        XCTAssertEqual(
            SessionGrouping.owningCrewId(for: discovered, crews: crews, hosts: hosts, defaultHost: "mini"),
            "child")
    }

    /// The reverse of the above: a session actually inside the parent, but
    /// not inside the child, must not be claimed by the child.
    func testParentDoesNotClaimASessionOutsideTheChildDirectory() {
        let crews = [
            crew("parent", dir: "\(TestHost.homeRoot)/Convivy/parent"),
            crew("child", dir: "\(TestHost.homeRoot)/Convivy/parent/child"),
        ]
        let discovered = session("hand-made", path: "\(TestHost.homeRoot)/Convivy/parent/other-file")
        XCTAssertEqual(
            SessionGrouping.owningCrewId(for: discovered, crews: crews, hosts: hosts, defaultHost: "mini"),
            "parent")
    }

    func testNilPathNeverMatchesRuleBAndFallsOffTheRail() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")]
        let discovered = session("mystery", path: nil)
        XCTAssertNil(SessionGrouping.owningCrewId(for: discovered, crews: crews))
    }

    func testSessionMatchingNeitherRuleStaysOffTheRail() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")]
        let discovered = session("totally-unrelated", path: "\(TestHost.homeRoot)/Convivy/elsewhere")
        XCTAssertNil(SessionGrouping.owningCrewId(for: discovered, crews: crews))
    }

    // MARK: - owningCrewId: the host boundary (phase 6b)

    /// The pinned case from `deck/specs/multiple-sessions-per-project`
    /// §"Crews on different hosts": "A discovered session from host A never
    /// groups under a crew on host B, even when the names or paths would
    /// otherwise match." Both the name rule and the path rule would claim
    /// this session for `ask` if host were ignored; neither may, because
    /// the session was found on the laptop and `ask` is a mini crew.
    func testANameMatchOnADifferentHostDoesNotGroup() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask", host: "mini")]
        let discovered = session("ask", host: laptop, path: "\(TestHost.homeRoot)/Convivy/ask")
        XCTAssertNil(SessionGrouping.owningCrewId(
            for: discovered, crews: crews, hosts: hosts, defaultHost: "mini"))
    }

    func testAPathMatchOnADifferentHostDoesNotGroup() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask", host: "mini")]
        let discovered = session("hand-made", host: laptop, path: "\(TestHost.homeRoot)/Convivy/ask/sub")
        XCTAssertNil(SessionGrouping.owningCrewId(
            for: discovered, crews: crews, hosts: hosts, defaultHost: "mini"))
    }

    /// The same session name, discovered on the crew's OWN host, still
    /// matches — the boundary excludes a different host, not every host.
    func testANameMatchOnTheSameHostStillGroups() {
        let crews = [
            crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask", host: "mini"),
            crew("vivy", dir: "\(TestHost.secondaryHomeRoot)/vivy", host: "laptop"),
        ]
        let discovered = session("vivy", host: laptop, path: "\(TestHost.secondaryHomeRoot)/vivy")
        XCTAssertEqual(SessionGrouping.owningCrewId(
            for: discovered, crews: crews, hosts: hosts, defaultHost: "mini"), "vivy")
    }

    /// A crew with no `host` field resolves to the configured default, and a
    /// session discovered on that same default target still matches it.
    func testACrewWithNoHostFieldMatchesASessionOnTheConfiguredDefault() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")]
        let discovered = session("ask", host: mini, path: "\(TestHost.homeRoot)/Convivy/ask")
        XCTAssertEqual(SessionGrouping.owningCrewId(
            for: discovered, crews: crews, hosts: hosts, defaultHost: "mini"), "ask")
    }

    /// With no `hosts` table configured at all — an unconfigured install —
    /// a crew naming no `host` of its own resolves to nothing, so it cannot
    /// own ANY discovered session, even one its name would otherwise match:
    /// there is no compiled-in box left for both sides to agree on. See
    /// `deck/specs/running-deck-as-someone-else`.
    func testWithNoHostsConfiguredNothingCanBeOwned() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")]
        let discovered = session("ask--research", path: "\(TestHost.homeRoot)/Convivy/other")
        XCTAssertNil(SessionGrouping.owningCrewId(for: discovered, crews: crews))
    }

    // MARK: - group()

    func testGroupOmitsSessionsMatchingNeitherRule() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")]
        let sessions = [
            session("ask--research", path: "\(TestHost.homeRoot)/Convivy/ask/research"),
            session("totally-unrelated", path: "\(TestHost.homeRoot)/Convivy/elsewhere"),
        ]
        let grouped = SessionGrouping.group(sessions, into: crews, hosts: hosts, defaultHost: "mini")
        XCTAssertEqual(grouped["ask"]?.map(\.name), ["ask--research"])
        XCTAssertEqual(grouped.values.flatMap { $0 }.count, 1)
    }

    /// The two-hosts-same-name proof case, one level up: each host's own
    /// `vivy` groups under its own crew, never the other's.
    func testGroupKeepsTwoHostsWithTheSameSessionNameSeparate() {
        let crews = [
            crew("vivy", dir: "\(TestHost.homeRoot)/Convivy/vivy", host: "mini"),
            crew("vivy-laptop", dir: "\(TestHost.secondaryHomeRoot)/vivy", host: "laptop"),
        ]
        let sessions = [
            session("vivy", host: mini, path: "\(TestHost.homeRoot)/Convivy/vivy"),
            session("vivy", host: laptop, path: "\(TestHost.secondaryHomeRoot)/vivy"),
        ]
        let grouped = SessionGrouping.group(sessions, into: crews, hosts: hosts, defaultHost: "mini")
        XCTAssertEqual(grouped["vivy"]?.map(\.host), [mini])
        XCTAssertEqual(grouped["vivy-laptop"]?.map(\.host), [laptop])
    }

    // MARK: - ungrouped(): the "OTHER SESSIONS" set

    /// A session matching neither rule is exactly what belongs in the
    /// section — this is `group`'s "simply absent" case turned into a
    /// first-class result instead of a silent drop.
    func testUngroupedIncludesASessionMatchingNeitherRule() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")]
        let sessions = [session("orphan", path: "\(TestHost.homeRoot)/Convivy/elsewhere")]
        XCTAssertEqual(
            SessionGrouping.ungrouped(sessions, crews: crews).map(\.name),
            ["orphan"])
    }

    func testUngroupedExcludesANameRuleMatch() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")]
        let sessions = [session("ask--research")]
        XCTAssertTrue(
            SessionGrouping.ungrouped(sessions, crews: crews, hosts: hosts, defaultHost: "mini").isEmpty)
    }

    func testUngroupedExcludesAPathRuleMatch() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")]
        let sessions = [session("hand-made", path: "\(TestHost.homeRoot)/Convivy/ask/sub")]
        XCTAssertTrue(
            SessionGrouping.ungrouped(sessions, crews: crews, hosts: hosts, defaultHost: "mini").isEmpty)
    }

    /// Insurance, the same reason `matchesByName` re-checks the prefix: the
    /// verb already excludes Deck's own scratch shells server-side, but one
    /// that slipped through — say, because its crew has no
    /// `workingDirectory` for the path rule to catch it — must not surface
    /// as a phantom "other session" a user could try to adopt or stop.
    func testUngroupedExcludesScratchShellsEvenWhenNoCrewWouldClaimThem() {
        let crews = [crew("ask")]
        let sessions = [session("\(scratchShellPrefix)orphan", path: "\(TestHost.homeRoot)/Convivy/elsewhere")]
        XCTAssertTrue(SessionGrouping.ungrouped(sessions, crews: crews).isEmpty)
    }

    /// Builder's `keeper` session is infrastructure with an empty shell, so it
    /// stays out of OTHER SESSIONS; a session whose name only contains the word
    /// is an ordinary session and still shows.
    func testUngroupedExcludesTheKeeperSessionButNotLookalikes() {
        let crews = [crew("ask")]
        let sessions = [
            session(keeperSessionName, path: TestHost.homeRoot),
            session("keeper-notes", path: "\(TestHost.homeRoot)/elsewhere"),
        ]
        XCTAssertEqual(SessionGrouping.ungrouped(sessions, crews: crews).map(\.name), ["keeper-notes"])
    }

    func testUngroupedOfEmptyIsEmpty() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")]
        XCTAssertTrue(SessionGrouping.ungrouped([], crews: crews).isEmpty)
    }

    /// The property adoption rests on: a session `ungrouped` returns must
    /// stop being returned once it is pinned to a crew — otherwise "Adopt
    /// into ▸" pins a second copy of the row rather than moving it, since
    /// pinning never changes the name or path the grouping rules look at.
    /// The `comptroller` shape from
    /// `testAnUnpinnedSessionMatchingNeitherRuleReturnsToUngrouped` below,
    /// run in the opposite direction: matches neither rule, so it starts in
    /// `ungrouped`, then a pin (not a name or path change) is enough to
    /// remove it.
    func testAPinnedSessionMatchingNeitherRuleIsExcludedFromUngrouped() {
        var ask = crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")
        let discovered = session("comptroller", path: "\(TestHost.homeRoot)/elsewhere")
        XCTAssertEqual(
            SessionGrouping.ungrouped([discovered], crews: [ask], hosts: hosts, defaultHost: "mini")
                .map(\.name),
            ["comptroller"])

        ask.sessions.append(PinnedSession(name: "comptroller", displayName: "Comptroller"))
        XCTAssertTrue(
            SessionGrouping.ungrouped([discovered], crews: [ask], hosts: hosts, defaultHost: "mini").isEmpty)
    }

    /// A session pinned to one crew must not leak into ANOTHER crew's
    /// "OTHER SESSIONS" exclusion check either, as long as both crews share
    /// a host: the exclusion pools pinned names across every crew on that
    /// host, not just the one that pinned this name. `ask` and `deck` both
    /// resolve to the default host here, so this is the same-host case;
    /// `testUngroupedIncludesAPinnedSessionOnADifferentHost` below is what
    /// proves the pooling stops at the host boundary.
    func testAPinnedSessionIsExcludedFromUngroupedRegardlessOfWhichCrewPinnedIt() {
        var ask = crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")
        let deck = crew("deck", dir: "\(TestHost.homeRoot)/Convivy/deck")
        ask.sessions.append(PinnedSession(name: "comptroller", displayName: "Comptroller"))
        let discovered = session("comptroller", path: "\(TestHost.homeRoot)/elsewhere")
        XCTAssertTrue(
            SessionGrouping.ungrouped([discovered], crews: [ask, deck], hosts: hosts, defaultHost: "mini")
                .isEmpty)
    }

    /// The collision the pooled-by-name version of this exclusion missed: a
    /// pinned child named `worker` on `mini` must not hide an unrelated
    /// session ALSO named `worker` running on `laptop`. That second session
    /// belongs to no crew on ITS OWN host (`owningCrewId` correctly returns
    /// nil for it), so before this exclusion existed it drew in "OTHER
    /// SESSIONS"; a bare `Set<String>` pooled across every crew regardless
    /// of host would filter it out too, and it would draw nowhere — running,
    /// unreachable, unstoppable from Deck. Reusing a name like `worker`
    /// across two independent boxes is ordinary, not contrived.
    func testUngroupedIncludesAPinnedSessionOnADifferentHost() {
        var ask = crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask", host: "mini")
        ask.sessions.append(PinnedSession(name: "worker", displayName: "Worker"))
        let discovered = session("worker", host: laptop, path: "\(TestHost.homeRoot)/elsewhere")
        XCTAssertEqual(
            SessionGrouping.ungrouped(
                [discovered], crews: [ask], hosts: hosts, defaultHost: "mini"
            ).map(\.name),
            ["worker"])
    }

    /// A session that would match by name or path, but on a different host,
    /// falls to "OTHER SESSIONS" rather than being silently swallowed by a
    /// same-named crew that is not actually where it is running.
    func testUngroupedIncludesANameMatchOnADifferentHost() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask", host: "mini")]
        let discovered = session("ask", host: laptop, path: "\(TestHost.homeRoot)/Convivy/ask")
        XCTAssertEqual(
            SessionGrouping.ungrouped([discovered], crews: crews, hosts: hosts, defaultHost: "mini")
                .map(\.name),
            ["ask"])
    }

    // MARK: - discoveredChildren: the merge/ordering rule

    /// Discovered rows merge AFTER pinned children (drawn separately from
    /// config) and sort alphabetically among themselves.
    func testDiscoveredChildrenSortAlphabetically() {
        let grouped = [session("ask--zeta"), session("ask--alpha"), session("ask--mu")]
        let children = SessionGrouping.discoveredChildren(
            of: grouped, crewId: "ask", pinnedNames: [])
        XCTAssertEqual(children.map(\.name), ["ask--alpha", "ask--mu", "ask--zeta"])
    }

    /// A crew's own primary session matches rule A against itself and
    /// must not be drawn as its own child.
    func testDiscoveredChildrenExcludesTheCrewsOwnId() {
        let grouped = [session("ask"), session("ask--research")]
        let children = SessionGrouping.discoveredChildren(
            of: grouped, crewId: "ask", pinnedNames: [])
        XCTAssertEqual(children.map(\.name), ["ask--research"])
    }

    /// A name already pinned in config is drawn once, from the pinned list —
    /// it must not also appear in the discovered block.
    func testDiscoveredChildrenExcludesAlreadyPinnedNames() {
        let grouped = [session("ask--research"), session("ask--tax")]
        let children = SessionGrouping.discoveredChildren(
            of: grouped, crewId: "ask", pinnedNames: ["ask--research"])
        XCTAssertEqual(children.map(\.name), ["ask--tax"])
    }

    /// An arrival must not move an existing discovered row — inserting a new
    /// name into the same set and re-sorting must leave every previously
    /// present name in the same relative order to each other.
    func testAnArrivalDoesNotReorderExistingDiscoveredRows() {
        let before = SessionGrouping.discoveredChildren(
            of: [session("ask--alpha"), session("ask--mu")],
            crewId: "ask", pinnedNames: [])
        XCTAssertEqual(before.map(\.name), ["ask--alpha", "ask--mu"])

        let after = SessionGrouping.discoveredChildren(
            of: [session("ask--alpha"), session("ask--mu"), session("ask--beta")],
            crewId: "ask", pinnedNames: [])
        // The arrival ("beta") grows the block downward without disturbing
        // "alpha" and "mu"'s order relative to each other.
        XCTAssertEqual(after.map(\.name), ["ask--alpha", "ask--beta", "ask--mu"])
        XCTAssertEqual(after.filter { $0.name != "ask--beta" }.map(\.name),
                       before.map(\.name))
    }

    /// The property `sessionId`-preferred matching exists for: a pinned
    /// name and a renamed live session no longer match as strings, but a
    /// shared `sessionId` still identifies them as one session, so the
    /// renamed row is excluded rather than drawn as a second, unrelated
    /// child.
    func testASessionIdMatchExcludesARenamedChildEvenWhenNamesDiffer() {
        let renamed = DiscoveredSession(name: "audio-v2", host: mini, sessionId: "$19")
        let children = SessionGrouping.discoveredChildren(
            of: [renamed], crewId: "ask", pinnedNames: ["audio"], pinnedSessionIds: ["$19"])
        XCTAssertEqual(children, [], "the renamed live session is the pinned child, not a new one")
    }

    /// The crew's own primary session is excluded by `sessionId` too, the
    /// same way it already is by name — as long as it still ANSWERS to the
    /// crew's own name.
    func testASessionIdMatchExcludesTheCrewsOwnPrimarySessionWhenTheNameStillAgrees() {
        let stillNamedAsk = DiscoveredSession(name: "ask", host: mini, sessionId: "$58")
        let children = SessionGrouping.discoveredChildren(
            of: [stillNamedAsk], crewId: "ask", crewSessionId: "$58", pinnedNames: [])
        XCTAssertEqual(children, [])
    }

    /// A RENAMED primary session must NOT be excluded by the id match once
    /// its name no longer agrees with the crew's configured id — the crew's
    /// own row still checks liveness by that id-derived name (a served
    /// spec's `id` never follows a tmux rename), so hiding the live session
    /// here as well would make it vanish from the rail entirely. It draws
    /// as its own child row instead, until something re-pins or promotes it.
    func testARenamedPrimarySessionIsNoLongerExcludedByTheOldSessionIdMatch() {
        let renamed = DiscoveredSession(name: "ask-v2", host: mini, sessionId: "$58")
        let children = SessionGrouping.discoveredChildren(
            of: [renamed], crewId: "ask", crewSessionId: "$58", pinnedNames: [])
        XCTAssertEqual(children.map(\.name), ["ask-v2"])
    }

    /// With no `sessionId` on either side — true of every live
    /// `session-agent sessions` row as of this writing — the rule falls
    /// through to the name check exactly as before.
    func testWithNoSessionIdAnywhereTheNameRuleAloneApplies() {
        let grouped = [session("ask--research"), session("ask--tax")]
        let children = SessionGrouping.discoveredChildren(
            of: grouped, crewId: "ask", pinnedNames: ["ask--research"])
        XCTAssertEqual(children.map(\.name), ["ask--tax"])
    }

    // MARK: - adoptionTargets(): "Adopt into ▸"

    /// With one host configured, every crew resolving to it is a candidate.
    func testAdoptionTargetsOffersEveryCrewOnASingleHostInstall() {
        let crews = [crew("ask"), crew("deck")]
        let discovered = session("comptroller")
        XCTAssertEqual(
            SessionGrouping.adoptionTargets(
                for: discovered, crews: crews, hosts: hosts, defaultHost: "mini"
            ).map(\.id),
            ["ask", "deck"])
    }

    /// The whole point of the field: a crew on a DIFFERENT host must never
    /// be offered, since adopting there would mean pinning a session as a
    /// child of a directory on a machine it does not live on.
    func testAdoptionTargetsExcludesCrewsOnAnotherHost() {
        let crews = [
            crew("ask", host: "mini"),
            crew("vivy", host: "laptop"),
        ]
        let discovered = session("comptroller", host: mini)
        XCTAssertEqual(
            SessionGrouping.adoptionTargets(
                for: discovered, crews: crews, hosts: hosts, defaultHost: "mini"
            ).map(\.id),
            ["ask"])
    }

    /// A crew with no `host` field resolves to the configured default, so a
    /// session discovered on that default target is still offered it.
    func testAdoptionTargetsIncludesACrewWithNoHostFieldOnTheDefaultHost() {
        let crews = [crew("ask")]
        let discovered = session("comptroller", host: mini)
        XCTAssertEqual(
            SessionGrouping.adoptionTargets(
                for: discovered, crews: crews, hosts: hosts, defaultHost: "mini"
            ).map(\.id),
            ["ask"])
    }

    func testAdoptionTargetsIsEmptyWhenNoCrewSharesTheHost() {
        let crews = [crew("vivy", host: "laptop")]
        let discovered = session("comptroller", host: mini)
        XCTAssertTrue(SessionGrouping.adoptionTargets(
            for: discovered, crews: crews, hosts: hosts, defaultHost: "mini").isEmpty)
    }

    /// Proves `adoptionTargets` compares RESOLVED targets, not host names.
    /// Two differently-named `HostEntry`s that resolve to the SAME address
    /// stand in for one real machine reachable under two config names —
    /// both crews must be offered, because both really do live on the
    /// session's own host. `testAdoptionTargetsExcludesCrewsOnAnotherHost`
    /// above cannot tell a name-comparison from an address-comparison,
    /// since that fixture's names and addresses are in 1:1 correspondence;
    /// this fixture breaks that correspondence on purpose.
    ///
    /// Verified by mutation: reverting `adoptionTargets` to compare
    /// `$0.host` (the config name) against `session.host.hostName(...)` —
    /// i.e. names rather than resolved `SSHTarget`s — turns this test red
    /// while leaving `testAdoptionTargetsExcludesCrewsOnAnotherHost` green,
    /// confirming this case is the one that actually exercises "a name is
    /// not identity."
    func testAdoptionTargetsComparesResolvedHostsNotHostNames() {
        let aliasedHosts = [
            HostEntry(name: "mini", user: TestHost.user, address: TestHost.address),
            HostEntry(name: "mini-alias", user: TestHost.user, address: TestHost.address),
        ]
        let crews = [
            crew("ask", host: "mini"),
            crew("deck", host: "mini-alias"),
        ]
        let discovered = session("comptroller", host: mini)
        XCTAssertEqual(
            SessionGrouping.adoptionTargets(
                for: discovered, crews: crews, hosts: aliasedHosts, defaultHost: "mini"
            ).map(\.id),
            ["ask", "deck"])
    }

    // MARK: - A removed-but-running pinned child stays reachable (the Remove confirm's claim)

    /// Verifies, rather than asserts, half of the Remove confirm's "still
    /// reachable on the rail" line — `RemovePinnedSessionTests` proves the
    /// other half, that `removePinnedSession` drops the name from
    /// `crew.sessions`. `SessionGrouping` never looks at pin state at all,
    /// only name and path, so a session whose name and path match neither
    /// rule was never going to be grouped under the crew regardless of
    /// whether it was pinned — it was drawn as a pinned row only because
    /// `RailView` draws `crew.sessions` directly, bypassing grouping
    /// entirely. This is exactly the situation adoption exists for ("the
    /// grouping rules already failed to claim it"), so once such a session
    /// is unpinned, this is what proves it resurfaces in `ungrouped` —
    /// "OTHER SESSIONS" — rather than disappearing.
    func testAnUnpinnedSessionMatchingNeitherRuleReturnsToUngrouped() {
        let crews = [crew("ask", dir: "\(TestHost.homeRoot)/Convivy/ask")]
        // No crew id or directory this session's name or path could match —
        // the `comptroller` shape: adopted (or hand-pinned) precisely
        // because the rules never would have claimed it.
        let discovered = session("comptroller", path: "\(TestHost.homeRoot)/elsewhere")
        XCTAssertEqual(
            SessionGrouping.ungrouped([discovered], crews: crews).map(\.name),
            ["comptroller"])
    }
}
