import XCTest
@testable import Deck

/// `RailDerivedCache` backs the rail's derived crew model (CQ·196):
/// `ContentView.crews`, `childParentByRef`, `discoveredParentByRef`,
/// `railSessionRefs` and `themeForSession`, `RailView.groupedDiscovered`/`otherSessions`, and
/// `SessionsSettingsView.groupHeadingsByRef` all run an expensive walk
/// through this cache now rather than on every property access. These
/// tests pin the cache's own contract directly, without rendering a view:
/// a hit must not recompute, and a real input change must.
final class RailDerivedCacheTests: XCTestCase {
    func testUnchangedInputIsNotRecomputed() {
        let cache = RailDerivedCache<Int, String>()
        var recomputeCount = 0
        cache.onRecompute = { recomputeCount += 1 }

        XCTAssertEqual(cache.value(for: 1) { "a" }, "a")
        XCTAssertEqual(cache.value(for: 1) { "b" }, "a")
        XCTAssertEqual(cache.value(for: 1) { "c" }, "a")

        XCTAssertEqual(recomputeCount, 1)
    }

    func testChangedInputIsRecomputed() {
        let cache = RailDerivedCache<Int, String>()
        var recomputeCount = 0
        cache.onRecompute = { recomputeCount += 1 }

        XCTAssertEqual(cache.value(for: 1) { "a" }, "a")
        XCTAssertEqual(cache.value(for: 2) { "b" }, "b")
        XCTAssertEqual(cache.value(for: 2) { "c" }, "b")
        XCTAssertEqual(cache.value(for: 3) { "d" }, "d")

        XCTAssertEqual(recomputeCount, 3)
    }

    // MARK: - The production wiring: a session's own poll never touches
    // the derived crew model's inputs.

    private func crew(_ id: String, host: String? = nil) -> Crew {
        Crew(id: id, displayName: id, host: host)
    }

    /// `ContentView.CrewsCacheInput` deliberately carries nothing from
    /// `RailStateModel.states` — a session's poll result can never be one
    /// of its fields, by construction, so this is the regression CQ·196
    /// asks for: one session's state changing must not re-run
    /// `CrewMerge.merge`. Simulated here by calling the cache repeatedly
    /// with the IDENTICAL `CrewsCacheInput` while varying what `compute`
    /// would have seen from `railState.states` — which, having no field to
    /// read it from, cannot vary the input at all.
    func testASessionsPollResultDoesNotRecomputeTheMergedCrewList() {
        let cache = RailDerivedCache<ContentView.CrewsCacheInput, [Crew]>()
        var recomputeCount = 0
        cache.onRecompute = { recomputeCount += 1 }

        let input = ContentView.CrewsCacheInput(
            configured: [crew("alpha")], served: [], catalog: [], hosts: [], defaultHost: nil)

        // Three "renders", standing in for three separate poll ticks that
        // each changed a different session's `SessionState` — none of
        // which `CrewsCacheInput` has anywhere to carry.
        for _ in 0..<3 {
            _ = cache.value(for: input) {
                CrewMerge.merge(configured: input.configured, served: input.served,
                                catalog: input.catalog, hosts: input.hosts, defaultHost: input.defaultHost)
            }
        }

        XCTAssertEqual(recomputeCount, 1)
    }

    /// The converse: a real input — here, a newly served crew — does
    /// force a recompute, so the cache never hands back a stale merged
    /// list.
    func testAServedCrewChangeRecomputesTheMergedCrewList() {
        let cache = RailDerivedCache<ContentView.CrewsCacheInput, [Crew]>()
        var recomputeCount = 0
        cache.onRecompute = { recomputeCount += 1 }

        let before = ContentView.CrewsCacheInput(
            configured: [crew("alpha")], served: [], catalog: [], hosts: [], defaultHost: nil)
        let served = ServedCrew(crewId: "orchard", host: SSHTarget(user: "operator", host: "macstudio"))
        let after = ContentView.CrewsCacheInput(
            configured: [crew("alpha")], served: [served], catalog: [], hosts: [], defaultHost: nil)

        func merged(_ input: ContentView.CrewsCacheInput) -> [Crew] {
            cache.value(for: input) {
                CrewMerge.merge(configured: input.configured, served: input.served,
                                catalog: input.catalog, hosts: input.hosts, defaultHost: input.defaultHost)
            }
        }

        XCTAssertEqual(merged(before).count, 1)
        XCTAssertEqual(merged(after).count, 2)
        XCTAssertEqual(recomputeCount, 2)
    }

    // MARK: - Each memo empties when its own inputs change

    private let hosts = [HostEntry(name: "host-a", user: TestHost.user, address: TestHost.address)]

    /// A session discovered after the first read joins its crew, and one
    /// that goes away leaves it: the memo must not keep serving the map it
    /// built before.
    @MainActor
    func testADiscoveredSessionJoinsAndLeavesItsCrewThroughTheCache() {
        let alpha = crew("alpha")
        let cache = RailDerivedCache<ContentView.DiscoveredParentCacheInput, [SessionRef: Crew]>()
        func parents(_ discovered: [DiscoveredSession]) -> [SessionRef: Crew] {
            ContentView.discoveredParents(
                .init(discovered: discovered, crews: [alpha], hosts: hosts, defaultHost: "host-a"),
                cache: cache)
        }
        let research = DiscoveredSession(name: "alpha--research", host: TestHost.target)

        XCTAssertTrue(parents([]).isEmpty)
        XCTAssertEqual(parents([research])[SessionRef.owned(by: alpha, name: "alpha--research")]?.id, "alpha")
        XCTAssertTrue(parents([]).isEmpty)
    }

    /// A theme picked for a crew reaches its row, a discovered child picks
    /// up its crew's theme once the parent map names the crew, and clearing
    /// the pick restores the default. Each step changes one field of the
    /// memo's key, so a key missing that field serves the old theme.
    @MainActor
    func testThemePicksAndParentsReachThroughTheThemeMemo() throws {
        let alpha = crew("alpha")
        let childRef = SessionRef.owned(by: alpha, name: "alpha--research")
        let cache = RailDerivedCache<ContentView.ThemeMapCacheInput, ContentView.ThemeMemo>()
        func theme(_ ref: SessionRef, picks: [SessionRef: String],
                   discoveredParents: [SessionRef: Crew] = [:]) -> String {
            let configuration = ThemeConfiguration(
                sessions: picks, appearancePreference: .system,
                typography: TerminalTypography(fontName: "Menlo", fontSize: 14, lineSpacing: 1.35))
            let input = ContentView.ThemeMapCacheInput(
                crews: [alpha], childParentByRef: [:], discoveredParentByRef: discoveredParents,
                hosts: hosts, defaultHost: "host-a", sessionThemes: configuration.sessions)
            return ContentView.theme(for: ref, input: input, cache: cache, configuration: configuration).name
        }
        let unthemed = theme(alpha.ref, picks: [:])
        let childUnthemed = theme(childRef, picks: [:])
        let picked = try XCTUnwrap(ThemeCatalog.all.first { $0.name != unthemed && $0.name != childUnthemed }).name

        XCTAssertEqual(theme(alpha.ref, picks: [alpha.ref: picked]), picked)
        XCTAssertEqual(theme(childRef, picks: [alpha.ref: picked]), childUnthemed)
        XCTAssertEqual(theme(childRef, picks: [alpha.ref: picked], discoveredParents: [childRef: alpha]), picked)
        XCTAssertEqual(theme(alpha.ref, picks: [:]), unthemed)
    }
}
