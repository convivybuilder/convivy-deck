import XCTest
@testable import Deck

/// Phase 4 of `deck/specs/multiple-sessions-per-project` — nested crews.
/// `RailNesting` is the pure "one level only" rule; every case the spec
/// names by hand is pinned here rather than left to the view.
final class RailNestingTests: XCTestCase {
    // MARK: - flatten

    func testFlatListDrawsEveryCrewTopLevelInOrder() {
        let crews = [
            Crew(id: "steward", displayName: "Steward"),
            Crew(id: "vivy", displayName: "Vivy"),
            Crew(id: "constance", displayName: "Constance"),
        ]
        let rows = RailNesting.flatten(crews)
        XCTAssertEqual(rows.map(\.crew.id), ["steward", "vivy", "constance"])
        XCTAssertTrue(rows.allSatisfy { $0.depth == 0 })
    }

    /// The spec's own worked example: `vivy-commercial` nests under `vivy`.
    func testOneNestedCrewDrawsAfterItsParent() {
        let crews = [
            Crew(id: "vivy", displayName: "Vivy"),
            Crew(id: "constance", displayName: "Constance"),
            Crew(id: "vivy-commercial", displayName: "Commercial", parent: "vivy"),
        ]
        let rows = RailNesting.flatten(crews)
        XCTAssertEqual(rows.map(\.crew.id), ["vivy", "vivy-commercial", "constance"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0])
    }

    /// Several crews nested under the same parent draw together, in
    /// `crews`' own order — "config order", the same convention pinned
    /// children already follow.
    func testSeveralCrewsNestedUnderOneParentKeepConfigOrder() {
        let crews = [
            Crew(id: "vivy", displayName: "Vivy"),
            Crew(id: "vivy-commercial", displayName: "Commercial", parent: "vivy"),
            Crew(id: "vivy-labs", displayName: "Labs", parent: "vivy"),
            Crew(id: "constance", displayName: "Constance"),
        ]
        let rows = RailNesting.flatten(crews)
        XCTAssertEqual(rows.map(\.crew.id), ["vivy", "vivy-commercial", "vivy-labs", "constance"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0])
    }

    /// A two-level chain: the middle crew nests (its parent has no parent
    /// of its own), and the leaf does not (ITS parent — the middle crew —
    /// names a parent), so the leaf draws top-level.
    func testTwoLevelChainNestsOnlyTheMiddleCrew() {
        let crews = [
            Crew(id: "a", displayName: "A"),
            Crew(id: "b", displayName: "B", parent: "a"),
            Crew(id: "c", displayName: "C", parent: "b"),
        ]
        let rows = RailNesting.flatten(crews)
        XCTAssertEqual(Set(rows.map(\.crew.id)), Set(["a", "b", "c"]))
        XCTAssertEqual(RailNesting.nestingParent(of: crews[1], in: crews)?.id, "a")
        XCTAssertNil(RailNesting.nestingParent(of: crews[2], in: crews),
                     "c's parent (b) itself names a parent, so c must draw top-level")
        XCTAssertTrue(RailNesting.isTopLevel(crews[2], in: crews))
    }

    /// A parent naming no crew that exists draws top-level, same as `nil`.
    func testDanglingParentDrawsTopLevel() {
        let crews = [
            Crew(id: "ask", displayName: "Ask", parent: "no-such-crew"),
        ]
        XCTAssertNil(RailNesting.nestingParent(of: crews[0], in: crews))
        XCTAssertEqual(RailNesting.flatten(crews).map(\.depth), [0])
    }

    /// A crew naming itself as its own parent draws top-level rather than
    /// infinitely nesting.
    func testSelfParentDrawsTopLevel() {
        let crews = [
            Crew(id: "ask", displayName: "Ask", parent: "ask"),
        ]
        XCTAssertNil(RailNesting.nestingParent(of: crews[0], in: crews))
        XCTAssertEqual(RailNesting.flatten(crews).map(\.depth), [0])
    }

    /// A cycle draws every member top-level rather than recursing forever —
    /// no crew in the cycle has a `nil` parent to nest cleanly under.
    func testCycleDrawsEveryMemberTopLevel() {
        let crews = [
            Crew(id: "a", displayName: "A", parent: "b"),
            Crew(id: "b", displayName: "B", parent: "a"),
        ]
        XCTAssertNil(RailNesting.nestingParent(of: crews[0], in: crews))
        XCTAssertNil(RailNesting.nestingParent(of: crews[1], in: crews))
        let rows = RailNesting.flatten(crews)
        XCTAssertEqual(rows.map(\.depth), [0, 0])
        XCTAssertEqual(Set(rows.map(\.crew.id)), Set(["a", "b"]))
    }

    /// A longer cycle (three crews) draws every member top-level too — the
    /// rule falls out of `nestingParent` with no extra cycle detection.
    func testLongerCycleDrawsEveryMemberTopLevel() {
        let crews = [
            Crew(id: "a", displayName: "A", parent: "c"),
            Crew(id: "b", displayName: "B", parent: "a"),
            Crew(id: "c", displayName: "C", parent: "b"),
        ]
        for crew in crews {
            XCTAssertNil(RailNesting.nestingParent(of: crew, in: crews), "\(crew.id) is in a cycle")
        }
    }

    /// Nesting is not transitive through a crew nested for a bad reason: a
    /// crew cannot nest under something that is itself only "top-level"
    /// because its own parent dangles or self-refers.
    func testCannotNestUnderACrewWithADanglingParent() {
        let crews = [
            Crew(id: "a", displayName: "A", parent: "nowhere"),
            Crew(id: "b", displayName: "B", parent: "a"),
        ]
        XCTAssertNil(RailNesting.nestingParent(of: crews[1], in: crews),
                     "a itself carries a (dangling) parent, so b cannot nest under it")
    }

    // MARK: - eligibleParents ("Nest under ▸")

    func testEligibleParentsExcludesSelf() {
        let crews = [Crew(id: "ask", displayName: "Ask"), Crew(id: "vivy", displayName: "Vivy")]
        let eligible = RailNesting.eligibleParents(for: crews[0], in: crews)
        XCTAssertFalse(eligible.map(\.id).contains("ask"))
    }

    func testEligibleParentsExcludesTheCurrentParent() {
        let crews = [
            Crew(id: "vivy", displayName: "Vivy"),
            Crew(id: "constance", displayName: "Constance"),
            Crew(id: "vivy-commercial", displayName: "Commercial", parent: "vivy"),
        ]
        let eligible = RailNesting.eligibleParents(for: crews[2], in: crews)
        XCTAssertEqual(eligible.map(\.id), ["constance"])
    }

    /// Only a crew with no `parent` of its own can be offered — nesting
    /// under an already-nested crew would violate the one-level rule the
    /// instant it was chosen.
    func testEligibleParentsExcludesAlreadyNestedCrews() {
        let crews = [
            Crew(id: "vivy", displayName: "Vivy"),
            Crew(id: "vivy-commercial", displayName: "Commercial", parent: "vivy"),
            Crew(id: "ask", displayName: "Ask"),
        ]
        let eligible = RailNesting.eligibleParents(for: crews[2], in: crews)
        XCTAssertEqual(eligible.map(\.id), ["vivy"])
    }

    func testEligibleParentsForAnUnnestedCrewListsEveryOtherTopLevelCrew() {
        let crews = [
            Crew(id: "vivy", displayName: "Vivy"),
            Crew(id: "constance", displayName: "Constance"),
            Crew(id: "ask", displayName: "Ask"),
        ]
        let eligible = RailNesting.eligibleParents(for: crews[2], in: crews)
        XCTAssertEqual(eligible.map(\.id), ["vivy", "constance"])
    }

    // MARK: - Accent inheritance composes with ThemeConfiguration.theme(forSession:fallbackParent:)

    /// A nested crew with no theme of its own resolves to its parent's —
    /// the same rule a pinned child already follows (design §"Accent
    /// inheritance"). `ContentView.themeForSession` is what wires this up
    /// live; this pins the pure half of it, `nestingParent` feeding
    /// `fallbackParent`.
    func testNestedCrewWithNoThemeResolvesToItsParents() {
        let crews = [
            Crew(id: "vivy", displayName: "Vivy"),
            Crew(id: "vivy-commercial", displayName: "Commercial", parent: "vivy"),
        ]
        let config = ThemeConfiguration(
            sessions: [SessionRef(host: nil, name: "vivy"): "azure"], appearancePreference: .system, typography: .default)
        let parent = RailNesting.nestingParent(of: crews[1], in: crews)
        XCTAssertEqual(parent?.id, "vivy")
        XCTAssertEqual(
            config.theme(forSession: SessionRef(host: nil, name: "vivy-commercial"), fallbackParent: parent?.ref).name,
            config.theme(forSession: SessionRef(host: nil, name: "vivy")).name)
    }

    /// A nested crew that HAS its own theme keeps it — inheritance is only
    /// the fallback for a crew with none of its own.
    func testNestedCrewWithItsOwnThemeKeepsIt() {
        let crews = [
            Crew(id: "vivy", displayName: "Vivy"),
            Crew(id: "vivy-commercial", displayName: "Commercial", parent: "vivy"),
        ]
        let config = ThemeConfiguration(
            sessions: [SessionRef(host: nil, name: "vivy"): "azure", SessionRef(host: nil, name: "vivy-commercial"): "gold"],
            appearancePreference: .system, typography: .default)
        let parent = RailNesting.nestingParent(of: crews[1], in: crews)
        XCTAssertEqual(
            config.theme(forSession: SessionRef(host: nil, name: "vivy-commercial"), fallbackParent: parent?.ref).name,
            ThemeCatalog.named("gold")?.name)
    }

    // MARK: - Cmd-1…9 over a list containing nested rows

    /// Nested rows must never occupy one of the first nine shortcut slots,
    /// and a nested row must never shift a later top-level row into an
    /// earlier slot than it would otherwise have drawn in.
    func testCmdNumberSlotsSkipNestedRows() {
        var crews: [Crew] = []
        for i in 1...10 {
            crews.append(Crew(id: "top\(i)", displayName: "Top \(i)"))
            // A nested crew interleaved right after each top-level one, the
            // shape the rail actually draws them in.
            crews.append(Crew(id: "nested\(i)", displayName: "Nested \(i)", parent: "top\(i)"))
        }
        let firstNine = RailNesting.topLevelCrews(crews).prefix(9)
        XCTAssertEqual(firstNine.map(\.id), (1...9).map { "top\($0)" })
        XCTAssertTrue(firstNine.allSatisfy { !$0.id.hasPrefix("nested") })
    }

    /// A crew still naming a host removed from Settings runs on the default
    /// host, so it nests under its parent there and is offered that parent.
    func testACrewNamingARemovedHostNestsUnderItsParentOnTheDefaultHost() {
        let hosts = [HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)]
        let parent = Crew(id: "p", displayName: "p")
        var child = Crew(id: "c", displayName: "c")
        child.host = "vacation-box"
        child.parent = "p"
        let crews = [parent, child]

        XCTAssertEqual(RailNesting.nestingParent(of: child, in: crews, hosts: hosts, defaultHost: "mini")?.id, "p")
        XCTAssertEqual(RailNesting.topLevelCrews(crews, hosts: hosts, defaultHost: "mini").map(\.id), ["p"])
        var loose = child
        loose.parent = nil
        XCTAssertEqual(
            RailNesting.eligibleParents(for: loose, in: [parent, loose], hosts: hosts, defaultHost: "mini").map(\.id),
            ["p"])
    }
}
