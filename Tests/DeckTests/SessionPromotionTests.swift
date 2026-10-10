import XCTest
@testable import Deck

/// `SessionPromotion.derive` — "Promote to Crew…" on an "OTHER SESSIONS"
/// row. See `deck/specs/multiple-sessions-per-project` §"An OTHER SESSIONS
/// row can be adopted into a crew but cannot BECOME one".
final class SessionPromotionTests: XCTestCase {
    // MARK: - The ordinary case

    func testDerivesACrewFromTheSessionsNameAndPath() throws {
        let session = DiscoveredSession(name: "comptroller", host: TestHost.target, path: "\(TestHost.homeRoot)/Convivy/comptroller")
        let crew = try SessionPromotion.derive(session, existingRefs: [], hosts: [])
        XCTAssertEqual(crew.id, "comptroller")
        XCTAssertEqual(crew.displayName, "comptroller")
        XCTAssertEqual(crew.workingDirectory, "\(TestHost.homeRoot)/Convivy/comptroller")
        XCTAssertNil(crew.host, "single-host install: nil means the configured default")
        XCTAssertNil(crew.command, "nil takes Crew.defaultLaunchCommand rather than baking in today's string")
    }

    /// The id is the session's own tmux name UNCHANGED — no slugify, no
    /// re-validation — since it already came from `session-agent sessions`
    /// as a real tmux session name.
    func testIdIsTheSessionsOwnNameRatherThanADerivedSlug() throws {
        let session = DiscoveredSession(name: "tax-2025", host: TestHost.target)
        let crew = try SessionPromotion.derive(session, existingRefs: [], hosts: [])
        XCTAssertEqual(crew.id, "tax-2025")
    }

    // MARK: - The nil-path case

    /// Per the `session-agent-api` contract, a row whose record could not be
    /// corroborated reports `name` only — `path: nil` is a legitimate real
    /// session, not a degraded one to refuse. A crew with no
    /// `workingDirectory` is legal (the name rule still groups its
    /// children), so promotion must succeed rather than force-unwrap.
    func testANilPathPromotesToACrewWithNoWorkingDirectory() throws {
        let session = DiscoveredSession(name: "ask", host: TestHost.target, path: nil)
        let crew = try SessionPromotion.derive(session, existingRefs: [], hosts: [])
        XCTAssertNil(crew.workingDirectory)
        XCTAssertEqual(crew.id, "ask")
    }

    // MARK: - The id-collision refusal

    func testACollisionWithAnExistingCrewIdIsRefused() {
        let session = DiscoveredSession(name: "ask", host: TestHost.target)
        XCTAssertThrowsError(
            try SessionPromotion.derive(session, existingRefs: [SessionRef(host: nil, name: "ask")], hosts: [])
        ) { error in
            XCTAssertEqual(error as? SessionPromotion.PromotionError, .collision("ask"))
        }
    }

    func testNoCollisionWhenTheIdIsNotAnExistingCrew() throws {
        XCTAssertNoThrow(
            try SessionPromotion.derive(
                DiscoveredSession(name: "ask", host: TestHost.target),
                existingRefs: [SessionRef(host: nil, name: "vivy"), SessionRef(host: nil, name: "deck")],
                hosts: []))
    }

    // MARK: - The host boundary (this epic's whole point)

    /// The proof case: `steward` already exists on `mini`. Discovering
    /// another `steward` on a completely different host must promote
    /// cleanly — that name on two hosts is the normal case, not a collision.
    func testNoCollisionWhenTheMatchingCrewIsOnADifferentHost() throws {
        let guest = TestHost.secondaryTarget
        let hosts = [
            HostEntry(name: "mini", user: TestHost.user, address: TestHost.address),
            HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress),
        ]
        let session = DiscoveredSession(name: "steward", host: guest)
        let crew = try SessionPromotion.derive(
            session, existingRefs: [SessionRef(host: "mini", name: "steward")], hosts: hosts)
        XCTAssertEqual(crew.host, "guest")
    }

    /// The inverse: a name that already exists on THIS session's own host is
    /// still refused, exactly as a single-host collision always was.
    func testCollisionWhenTheMatchingCrewIsOnTheSameHost() {
        let guest = TestHost.secondaryTarget
        let hosts = [HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress)]
        let session = DiscoveredSession(name: "steward", host: guest)
        XCTAssertThrowsError(
            try SessionPromotion.derive(
                session, existingRefs: [SessionRef(host: "guest", name: "steward")], hosts: hosts)
        ) { error in
            XCTAssertEqual(error as? SessionPromotion.PromotionError, .collision("steward"))
        }
    }

    /// A crew still naming a host removed from Settings runs on the default
    /// host, so a same-named session discovered there collides with it.
    func testACrewNamingARemovedHostCollidesOnTheDefaultHost() {
        let hosts = [HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)]
        var crew = Crew(id: "steward", displayName: "steward")
        crew.host = "vacation-box"
        let refs = SessionPromotion.existingRefs(for: [crew], hosts: hosts, defaultHost: "mini")
        let session = DiscoveredSession(name: "steward", host: TestHost.target)
        XCTAssertThrowsError(
            try SessionPromotion.derive(session, existingRefs: refs, hosts: hosts)
        ) { error in
            XCTAssertEqual(error as? SessionPromotion.PromotionError, .collision("steward"))
        }
    }

    // MARK: - Host resolution

    /// `host` resolves back to the config host NAME the session was
    /// discovered on — `HostResolution.hostName(for:hosts:)`, the same
    /// reverse lookup `SessionRef.orphaned` already uses — not the raw
    /// `SSHTarget`, which is not what `Crew.host` stores.
    func testHostResolvesToTheConfigNameForTheDiscoveredTarget() throws {
        let guest = TestHost.secondaryTarget
        let hosts = [HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress)]
        let session = DiscoveredSession(name: "ask", host: guest)
        let crew = try SessionPromotion.derive(session, existingRefs: [], hosts: hosts)
        XCTAssertEqual(crew.host, "guest")
    }

    /// A session found on a target no `hosts` entry names resolves to `nil`
    /// — "the implied default" — the same fallback `HostResolution.hostName`
    /// itself gives, rather than inventing a name.
    func testAnUnnamedHostResolvesToNil() throws {
        let stray = SSHTarget(user: "someone", host: "10.0.0.9")
        let session = DiscoveredSession(name: "ask", host: stray)
        let crew = try SessionPromotion.derive(session, existingRefs: [], hosts: [])
        XCTAssertNil(crew.host)
    }

    // MARK: - End to end: a promoted crew is subsequently owned by SessionGrouping

    /// The same class of check #111 round 1 was missing: a promoted crew
    /// must actually be CLAIMED by `SessionGrouping.owningCrewId` afterward,
    /// not merely exist as a row nothing groups the session under — which
    /// would leave the session right back in `ungrouped` after promotion,
    /// exactly the bug promotion exists to fix.
    func testAPromotedSessionIsSubsequentlyOwnedByItsNewCrewAndLeavesUngrouped() throws {
        // A configured `mini` host, standing in for the target the session
        // was actually discovered on — `owningCrewId`/`ungrouped` resolve
        // the promoted crew's `nil` host against `hosts`/`defaultHost`
        // exactly as the shell would, and an unconfigured install (empty
        // `hosts`) resolves a `nil` host to nothing at all.
        let hosts = [HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)]
        let session = DiscoveredSession(name: "comptroller", host: TestHost.target, path: "\(TestHost.homeRoot)/Convivy/comptroller")
        let crew = try SessionPromotion.derive(session, existingRefs: [], hosts: hosts)

        let crews = [crew]
        XCTAssertEqual(
            SessionGrouping.owningCrewId(for: session, crews: crews, hosts: hosts, defaultHost: "mini"),
            crew.id)
        XCTAssertTrue(
            SessionGrouping.ungrouped([session], crews: crews, hosts: hosts, defaultHost: "mini").isEmpty)
    }

    /// The nil-path variant of the same end-to-end check: even with no
    /// `workingDirectory` to match by path, the NAME rule alone (the
    /// promoted crew's id equals the session's own name) is enough to claim
    /// it.
    func testANilPathPromotedSessionIsStillOwnedByNameAlone() throws {
        let hosts = [HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)]
        let session = DiscoveredSession(name: "ask", host: TestHost.target, path: nil)
        let crew = try SessionPromotion.derive(session, existingRefs: [], hosts: hosts)

        let crews = [crew]
        XCTAssertEqual(
            SessionGrouping.owningCrewId(for: session, crews: crews, hosts: hosts, defaultHost: "mini"),
            crew.id)
        XCTAssertTrue(
            SessionGrouping.ungrouped([session], crews: crews, hosts: hosts, defaultHost: "mini").isEmpty)
    }
}
