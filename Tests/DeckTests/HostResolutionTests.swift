import XCTest
@testable import Deck

/// `HostResolution` resolves a crew's `host` field, and a bare session name,
/// to the `SSHTarget` its session-agent calls should use — phase 6a of
/// `deck/specs/multiple-sessions-per-project` §"Crews on different boxes".
/// PURE, so every case here runs with no ssh round trip and no mini.
final class HostResolutionTests: XCTestCase {
    private let mini = HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)
    private let laptop = HostEntry(name: "laptop", user: "operator", address: "10.0.0.5")

    private func crew(_ id: String, host: String? = nil) -> Crew {
        Crew(id: id, displayName: id, host: host)
    }

    private func launchable(_ id: String, host: String? = nil) -> LaunchableSession {
        LaunchableSession(id: id, displayName: id, host: host)
    }

    // MARK: - target(forHostName:hosts:defaultHost:)

    /// An empty hosts table is Settings › Hosts' own empty state — an
    /// unconfigured install — and every name, whether nil or naming
    /// something that cannot possibly be configured, resolves to NOTHING:
    /// the fallback chain has no compiled-in box to bottom out in any more.
    /// See `deck/specs/running-deck-as-someone-else`.
    func testAnEmptyHostsTableAlwaysResolvesToNothing() {
        XCTAssertNil(HostResolution.target(forHostName: nil, hosts: [], defaultHost: nil))
        XCTAssertNil(HostResolution.target(forHostName: "anything", hosts: [], defaultHost: nil))
        XCTAssertNil(HostResolution.target(forHostName: nil, hosts: [], defaultHost: "also-anything"))
    }

    func testANamedHostResolvesToItsOwnAddressAndUser() {
        XCTAssertEqual(
            HostResolution.target(forHostName: "laptop", hosts: [mini, laptop], defaultHost: "mini"),
            SSHTarget(user: "operator", host: "10.0.0.5"))
    }

    /// No host name at all falls through to the configured default, not to
    /// the first entry in the table — the table carries no ordering promise.
    func testANilHostNameResolvesToTheConfiguredDefault() {
        XCTAssertEqual(
            HostResolution.target(forHostName: nil, hosts: [mini, laptop], defaultHost: "laptop"),
            SSHTarget(user: "operator", host: "10.0.0.5"))
    }

    /// The deliberate degrade: a host name that matches nothing in the table
    /// resolves to the DEFAULT rather than failing — a hand-edited config
    /// naming a host that no longer exists should not take the row out of
    /// service.
    func testAnUnknownHostNameFallsBackToTheConfiguredDefaultNotTheMini() {
        XCTAssertEqual(
            HostResolution.target(forHostName: "no-such-host", hosts: [mini, laptop],
                                  defaultHost: "laptop"),
            SSHTarget(user: "operator", host: "10.0.0.5"),
            "an unknown name must fall back to the CONFIGURED default, not silently to a compiled-in host")
    }

    /// One level up: an unmatched `defaultHost` itself resolves to nothing —
    /// there is no further fallback beneath it any more.
    func testAnUnmatchedDefaultHostResolvesToNothing() {
        XCTAssertNil(
            HostResolution.target(forHostName: nil, hosts: [laptop], defaultHost: "no-such-default"))
    }

    /// An unknown host name against a non-empty table with NO configured
    /// default at all — as distinct from an empty table, and from an
    /// unmatched-but-present default — still resolves to nothing: the chain
    /// runs out with nowhere left to land.
    func testAnUnknownHostNameWithNoDefaultConfiguredResolvesToNothing() {
        XCTAssertNil(
            HostResolution.target(forHostName: "no-such-host", hosts: [mini, laptop], defaultHost: nil))
    }

    // MARK: - target(forSession:crews:hosts:defaultHost:)

    func testACrewWithAHostResolvesThroughItsOwnField() {
        let crews = [crew("vivy", host: "laptop"), crew("ask")]
        XCTAssertEqual(
            HostResolution.target(forSession: "vivy", crews: crews,
                                  hosts: [mini, laptop], defaultHost: "mini"),
            SSHTarget(user: "operator", host: "10.0.0.5"))
    }

    func testACrewWithNoHostResolvesToTheDefault() {
        let crews = [crew("vivy", host: "laptop"), crew("ask")]
        XCTAssertEqual(
            HostResolution.target(forSession: "ask", crews: crews,
                                  hosts: [mini, laptop], defaultHost: "mini"),
            TestHost.target)
    }

    /// A pinned sibling resolves through the same crew its primary session
    /// does, via `SessionGrouping`'s name rule — `<crew-id>--child`.
    func testAPinnedChildResolvesThroughItsCrewsHost() {
        let crews = [crew("vivy", host: "laptop")]
        XCTAssertEqual(
            HostResolution.target(forSession: "vivy--research", crews: crews,
                                  hosts: [mini, laptop], defaultHost: "mini"),
            SSHTarget(user: "operator", host: "10.0.0.5"))
    }

    /// A session matching no crew by name — a catalog row typed straight
    /// in, or a hand-made session the path rule alone would claim — resolves
    /// to the default; this function deliberately checks only the name rule.
    func testASessionMatchingNoCrewResolvesToTheDefault() {
        let crews = [crew("vivy", host: "laptop")]
        XCTAssertEqual(
            HostResolution.target(forSession: "nyh-studio", crews: crews,
                                  hosts: [mini, laptop], defaultHost: "mini"),
            TestHost.target)
    }

    func testWithNoCrewsAtAllAndNoHostsEverySessionResolvesToNothing() {
        XCTAssertNil(
            HostResolution.target(forSession: "anything", crews: [], hosts: [], defaultHost: nil))
    }

    // MARK: - catalog

    /// A catalog-only session — one launched from the catalog rather than
    /// pinned to the rail — resolves through its own `host` the same way a
    /// crew's does. This is the field `deck-reviewer` found decoded and
    /// round-tripped but never consulted: `ContentView.hostTarget(for:)` used
    /// to resolve only against `crews`, so a catalog row's `host` was
    /// silently ignored.
    func testACatalogRowWithAHostResolvesThroughItsOwnField() {
        let catalog = [launchable("nyh-studio", host: "laptop")]
        XCTAssertEqual(
            HostResolution.target(forSession: "nyh-studio", crews: [], catalog: catalog,
                                  hosts: [mini, laptop], defaultHost: "mini"),
            SSHTarget(user: "operator", host: "10.0.0.5"))
    }

    func testACatalogRowWithNoHostResolvesToTheDefault() {
        let catalog = [launchable("nyh-studio")]
        XCTAssertEqual(
            HostResolution.target(forSession: "nyh-studio", crews: [], catalog: catalog,
                                  hosts: [mini, laptop], defaultHost: "laptop"),
            SSHTarget(user: "operator", host: "10.0.0.5"))
    }

    /// A pinned child of a catalog row resolves through the same row's host,
    /// via `SessionGrouping`'s name rule, exactly as a crew's pinned child
    /// does.
    func testACatalogRowsPinnedChildResolvesThroughItsHost() {
        let catalog = [launchable("nyh-studio", host: "laptop")]
        XCTAssertEqual(
            HostResolution.target(forSession: "nyh-studio--research", crews: [], catalog: catalog,
                                  hosts: [mini, laptop], defaultHost: "mini"),
            SSHTarget(user: "operator", host: "10.0.0.5"))
    }

    /// Crews are checked first — a name is not expected to appear in both
    /// lists, but if it does, the row actually pinned to the rail wins.
    func testACrewsHostWinsOverASameNamedCatalogRow() {
        let crews = [crew("vivy", host: "mini")]
        let catalog = [launchable("vivy", host: "laptop")]
        XCTAssertEqual(
            HostResolution.target(forSession: "vivy", crews: crews, catalog: catalog,
                                  hosts: [mini, laptop], defaultHost: "laptop"),
            TestHost.target)
    }

    /// The default parameter is `[]`, so every existing call site that never
    /// mentions a catalog keeps resolving exactly as it did before this
    /// field was wired.
    func testAnOmittedCatalogParameterBehavesAsEmpty() {
        let crews = [crew("vivy", host: "laptop")]
        XCTAssertEqual(
            HostResolution.target(forSession: "vivy", crews: crews,
                                  hosts: [mini, laptop], defaultHost: "mini"),
            SSHTarget(user: "operator", host: "10.0.0.5"))
    }

    // MARK: - hostName(for:hosts:) — phase 6b's reverse lookup

    /// The reverse of `target(forHostName:...)`: recovers the config host
    /// NAME an "OTHER SESSIONS" row's `SessionRef` needs, from the actual
    /// target `RailStateModel`'s poll found it on.
    func testHostNameRecoversTheEntryMatchingATarget() {
        XCTAssertEqual(
            HostResolution.hostName(for: SSHTarget(user: "operator", host: "10.0.0.5"), hosts: [mini, laptop]),
            "laptop")
    }

    /// No entry names this target — with `hosts` empty, today's only real
    /// config — so this always answers nil, the same "implied default"
    /// token `SessionRef.host == nil` carries everywhere else.
    func testHostNameOfAnUnnamedTargetIsNil() {
        XCTAssertNil(HostResolution.hostName(for: TestHost.target, hosts: []))
    }

    func testHostNameOfATargetMatchingNoEntryIsNil() {
        XCTAssertNil(HostResolution.hostName(
            for: SSHTarget(user: "nobody", host: "0.0.0.0"), hosts: [mini, laptop]))
    }

    // MARK: - crewsRoot(forHostName:hosts:defaultHost:globalCrewsRoot:)

    /// The ordinary case today: no host carries its own root, so every
    /// crew's directory prefill is the global fallback regardless of which
    /// host it lands on.
    func testCrewsRootFallsBackToTheGlobalRootWhenNoHostHasItsOwn() {
        XCTAssertEqual(
            HostResolution.crewsRoot(
                forHostName: "laptop", hosts: [mini, laptop], defaultHost: "mini",
                globalCrewsRoot: "~/Convivy"),
            "~/Convivy")
    }

    /// The case this phase adds: a host with its own root overrides the
    /// global fallback for a crew landing there.
    func testAHostsOwnRootOverridesTheGlobalFallback() {
        let guest = HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress,
                              crewsRoot: "\(TestHost.secondaryHomeRoot)/work")
        XCTAssertEqual(
            HostResolution.crewsRoot(
                forHostName: "guest", hosts: [mini, guest], defaultHost: "mini",
                globalCrewsRoot: "~/Convivy"),
            "\(TestHost.secondaryHomeRoot)/work")
    }

    /// A nil host name resolves through the CONFIGURED DEFAULT's own root —
    /// the same "one level up" fallback `target(forHostName:...)` follows —
    /// not straight to the global fallback.
    func testANilHostNameResolvesThroughTheDefaultsOwnRoot() {
        let guest = HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress,
                              crewsRoot: "\(TestHost.secondaryHomeRoot)/work")
        XCTAssertEqual(
            HostResolution.crewsRoot(
                forHostName: nil, hosts: [mini, guest], defaultHost: "guest",
                globalCrewsRoot: "~/Convivy"),
            "\(TestHost.secondaryHomeRoot)/work")
    }

    /// An unknown host name resolves through the DEFAULT's own root, the
    /// same fallback-to-default `target(forHostName:...)` uses — never
    /// straight to the global fallback while a default with its own root
    /// exists.
    func testAnUnknownHostNameResolvesThroughTheDefaultsOwnRootNotTheGlobalOne() {
        let guest = HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress,
                              crewsRoot: "\(TestHost.secondaryHomeRoot)/work")
        XCTAssertEqual(
            HostResolution.crewsRoot(
                forHostName: "no-such-host", hosts: [mini, guest], defaultHost: "guest",
                globalCrewsRoot: "~/Convivy"),
            "\(TestHost.secondaryHomeRoot)/work")
    }

    func testCrewsRootWithNoHostsTableAlwaysAnswersTheGlobalRoot() {
        XCTAssertEqual(
            HostResolution.crewsRoot(forHostName: nil, hosts: [], defaultHost: nil,
                                     globalCrewsRoot: "~/Convivy"),
            "~/Convivy")
    }
}
