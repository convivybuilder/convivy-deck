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
            Crew(id: "orchard", displayName: "Orchard"),
            Crew(id: "meridian", displayName: "Meridian"),
        ]
        let rows = RailNesting.flatten(crews)
        XCTAssertEqual(rows.map(\.crew.id), ["steward", "orchard", "meridian"])
        XCTAssertTrue(rows.allSatisfy { $0.depth == 0 })
    }

    /// The spec's own worked example: `orchard-commercial` nests under `orchard`.
    func testOneNestedCrewDrawsAfterItsParent() {
        let crews = [
            Crew(id: "orchard", displayName: "Orchard"),
            Crew(id: "meridian", displayName: "Meridian"),
            Crew(id: "orchard-commercial", displayName: "Commercial", parent: "orchard"),
        ]
        let rows = RailNesting.flatten(crews)
        XCTAssertEqual(rows.map(\.crew.id), ["orchard", "orchard-commercial", "meridian"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0])
    }

    /// Several crews nested under the same parent draw together, in
    /// `crews`' own order — "config order", the same convention pinned
    /// children already follow.
    func testSeveralCrewsNestedUnderOneParentKeepConfigOrder() {
        let crews = [
            Crew(id: "orchard", displayName: "Orchard"),
            Crew(id: "orchard-commercial", displayName: "Commercial", parent: "orchard"),
            Crew(id: "orchard-labs", displayName: "Labs", parent: "orchard"),
            Crew(id: "meridian", displayName: "Meridian"),
        ]
        let rows = RailNesting.flatten(crews)
        XCTAssertEqual(rows.map(\.crew.id), ["orchard", "orchard-commercial", "orchard-labs", "meridian"])
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
        let crews = [Crew(id: "ask", displayName: "Ask"), Crew(id: "orchard", displayName: "Orchard")]
        let eligible = RailNesting.eligibleParents(for: crews[0], in: crews)
        XCTAssertFalse(eligible.map(\.id).contains("ask"))
    }

    func testEligibleParentsExcludesTheCurrentParent() {
        let crews = [
            Crew(id: "orchard", displayName: "Orchard"),
            Crew(id: "meridian", displayName: "Meridian"),
            Crew(id: "orchard-commercial", displayName: "Commercial", parent: "orchard"),
        ]
        let eligible = RailNesting.eligibleParents(for: crews[2], in: crews)
        XCTAssertEqual(eligible.map(\.id), ["meridian"])
    }

    /// Only a crew with no `parent` of its own can be offered — nesting
    /// under an already-nested crew would violate the one-level rule the
    /// instant it was chosen.
    func testEligibleParentsExcludesAlreadyNestedCrews() {
        let crews = [
            Crew(id: "orchard", displayName: "Orchard"),
            Crew(id: "orchard-commercial", displayName: "Commercial", parent: "orchard"),
            Crew(id: "ask", displayName: "Ask"),
        ]
        let eligible = RailNesting.eligibleParents(for: crews[2], in: crews)
        XCTAssertEqual(eligible.map(\.id), ["orchard"])
    }

    func testEligibleParentsForAnUnnestedCrewListsEveryOtherTopLevelCrew() {
        let crews = [
            Crew(id: "orchard", displayName: "Orchard"),
            Crew(id: "meridian", displayName: "Meridian"),
            Crew(id: "ask", displayName: "Ask"),
        ]
        let eligible = RailNesting.eligibleParents(for: crews[2], in: crews)
        XCTAssertEqual(eligible.map(\.id), ["orchard", "meridian"])
    }

    // MARK: - Accent inheritance composes with ThemeConfiguration.theme(forSession:fallbackParent:)

    /// A nested crew with no theme of its own resolves to its parent's —
    /// the same rule a pinned child already follows (design §"Accent
    /// inheritance"). `ContentView.themeForSession` is what wires this up
    /// live; this pins the pure half of it, `nestingParent` feeding
    /// `fallbackParent`.
    func testNestedCrewWithNoThemeResolvesToItsParents() {
        let crews = [
            Crew(id: "orchard", displayName: "Orchard"),
            Crew(id: "orchard-commercial", displayName: "Commercial", parent: "orchard"),
        ]
        let config = ThemeConfiguration(
            sessions: [SessionRef(host: nil, name: "orchard"): "azure"], appearancePreference: .system, typography: .default)
        let parent = RailNesting.nestingParent(of: crews[1], in: crews)
        XCTAssertEqual(parent?.id, "orchard")
        XCTAssertEqual(
            config.theme(forSession: SessionRef(host: nil, name: "orchard-commercial"), fallbackParent: parent?.ref).name,
            config.theme(forSession: SessionRef(host: nil, name: "orchard")).name)
    }

    /// A nested crew that HAS its own theme keeps it — inheritance is only
    /// the fallback for a crew with none of its own.
    func testNestedCrewWithItsOwnThemeKeepsIt() {
        let crews = [
            Crew(id: "orchard", displayName: "Orchard"),
            Crew(id: "orchard-commercial", displayName: "Commercial", parent: "orchard"),
        ]
        let config = ThemeConfiguration(
            sessions: [SessionRef(host: nil, name: "orchard"): "azure", SessionRef(host: nil, name: "orchard-commercial"): "gold"],
            appearancePreference: .system, typography: .default)
        let parent = RailNesting.nestingParent(of: crews[1], in: crews)
        XCTAssertEqual(
            config.theme(forSession: SessionRef(host: nil, name: "orchard-commercial"), fallbackParent: parent?.ref).name,
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

    // MARK: - drawItems / drawOrderCrews / foldedGroup (E24, CQ·183)

    /// No groups: every crew draws ungrouped, in rail order — identical to
    /// today's `topLevelCrews`.
    func testDrawItemsWithNoGroupsMatchesTopLevelOrder() {
        let crews = [
            Crew(id: "steward", displayName: "Steward"),
            Crew(id: "orchard", displayName: "Orchard"),
            Crew(id: "meridian", displayName: "Meridian"),
        ]
        let items = RailNesting.drawItems(for: crews, groups: [])
        XCTAssertEqual(items.map(\.id), crews.map { "crew:\($0.ref.stringForm)" })
        for item in items {
            guard case .crew = item.kind else { return XCTFail("expected every item to be an ungrouped crew") }
        }
        XCTAssertEqual(RailNesting.drawOrderCrews(for: crews, groups: []).map(\.id), crews.map(\.id))
    }

    /// An open group draws at its first member's rail position, carrying
    /// every member still on the rail in rail order; ungrouped crews keep
    /// their own places around it.
    func testOpenGroupDrawsAtItsFirstMembersPosition() {
        let crews = [
            Crew(id: "a", displayName: "A"),
            Crew(id: "b", displayName: "B"),
            Crew(id: "c", displayName: "C"),
            Crew(id: "d", displayName: "D"),
        ]
        let group = CrewGroup(name: "Rentals", members: ["b", "d"], folded: false)
        let items = RailNesting.drawItems(for: crews, groups: [group])
        XCTAssertEqual(items.count, 3, "a, the Rentals group, c")
        guard case .crew(let first) = items[0].kind else { return XCTFail("expected a to draw ungrouped") }
        XCTAssertEqual(first.id, "a")
        guard case .group(let drawnGroup, let members) = items[1].kind else {
            return XCTFail("expected the group to draw at b's position")
        }
        XCTAssertEqual(drawnGroup, group)
        XCTAssertEqual(members.map(\.id), ["b", "d"], "members draw in rail order")
        guard case .crew(let last) = items[2].kind else { return XCTFail("expected c to draw ungrouped") }
        XCTAssertEqual(last.id, "c")
    }

    /// A folded group still carries its members in the draw item — what a
    /// folded heading's colour marks and summed badge are built from —
    /// even though `RailView` draws only the heading for it.
    func testFoldedGroupStillCarriesItsMembers() {
        let crews = [Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")]
        let group = CrewGroup(name: "Folded", members: ["a", "b"], folded: true)
        let items = RailNesting.drawItems(for: crews, groups: [group])
        XCTAssertEqual(items.count, 1)
        guard case .group(let drawnGroup, let members) = items[0].kind else {
            return XCTFail("expected a single group item")
        }
        XCTAssertTrue(drawnGroup.folded)
        XCTAssertEqual(members.map(\.id), ["a", "b"])
    }

    /// A member that is itself a parent, with its own nested crew and
    /// pinned sessions, carries both unaffected — group membership buckets
    /// a top-level crew's own row; its children are unrelated to grouping.
    func testGroupMemberKeepsItsNestedCrewAndPinnedSessions() {
        let pinned = PinnedSession(name: "a--sibling", displayName: "Sibling")
        let crews = [
            Crew(id: "a", displayName: "A", sessions: [pinned]),
            Crew(id: "a-nested", displayName: "Nested", parent: "a"),
            Crew(id: "b", displayName: "B"),
        ]
        let group = CrewGroup(name: "G", members: ["a"], folded: false)
        let items = RailNesting.drawItems(for: crews, groups: [group])
        guard case .group(_, let members) = items[0].kind else { return XCTFail("expected a group item") }
        XCTAssertEqual(members.map(\.id), ["a"])
        XCTAssertEqual(members[0].sessions, [pinned])
        // The nested crew is not itself a group member — it travels with
        // `a` via the existing one-level nesting rule, unrelated to groups.
        XCTAssertEqual(RailNesting.nestingParent(of: crews[1], in: crews)?.id, "a")
    }

    /// A member naming a crew not on the rail is ignored.
    func testDanglingGroupMemberIsIgnored() {
        let crews = [Crew(id: "a", displayName: "A")]
        let group = CrewGroup(name: "G", members: ["a", "ghost"], folded: false)
        let items = RailNesting.drawItems(for: crews, groups: [group])
        guard case .group(_, let members) = items[0].kind else { return XCTFail("expected a group item") }
        XCTAssertEqual(members.map(\.id), ["a"], "the dangling member should not appear")
    }

    /// A group none of whose members are on the rail draws nothing at all.
    func testGroupWithNoLiveMembersDrawsNothing() {
        let crews = [Crew(id: "a", displayName: "A")]
        let group = CrewGroup(name: "Ghosts", members: ["ghost1", "ghost2"], folded: false)
        let items = RailNesting.drawItems(for: crews, groups: [group])
        XCTAssertEqual(items.count, 1)
        guard case .crew(let only) = items[0].kind else { return XCTFail("expected a to draw ungrouped") }
        XCTAssertEqual(only.id, "a")
    }

    /// A crew named in two groups belongs to the first.
    func testCrewNamedInTwoGroupsBelongsToTheFirst() {
        let crews = [Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")]
        let first = CrewGroup(name: "First", members: ["a"], folded: false)
        let second = CrewGroup(name: "Second", members: ["a", "b"], folded: false)
        let items = RailNesting.drawItems(for: crews, groups: [first, second])
        XCTAssertEqual(items.count, 2, "First (carrying a), then Second (carrying only b)")
        guard case .group(let firstDrawn, let firstMembers) = items[0].kind else {
            return XCTFail("expected First to draw")
        }
        XCTAssertEqual(firstDrawn.name, "First")
        XCTAssertEqual(firstMembers.map(\.id), ["a"])
        guard case .group(let secondDrawn, let secondMembers) = items[1].kind else {
            return XCTFail("expected Second to draw, carrying only b")
        }
        XCTAssertEqual(secondDrawn.name, "Second")
        XCTAssertEqual(secondMembers.map(\.id), ["b"])
    }

    /// `drawOrderCrews` flattens a group's members into the sequence
    /// Cmd-1…9 counts against, even when the group reorders non-contiguous
    /// rail rows next to each other.
    func testDrawOrderCrewsFlattensGroupMembersInPlace() {
        let crews = [
            Crew(id: "a", displayName: "A"),
            Crew(id: "b", displayName: "B"),
            Crew(id: "c", displayName: "C"),
            Crew(id: "d", displayName: "D"),
        ]
        let group = CrewGroup(name: "G", members: ["b", "d"], folded: true)
        XCTAssertEqual(RailNesting.drawOrderCrews(for: crews, groups: [group]).map(\.id), ["a", "b", "d", "c"])
    }

    // MARK: - foldedGroup(containing:) (selection opens a folded group)

    func testFoldedGroupContainingReturnsTheGroupForAFoldedMember() {
        let group = CrewGroup(name: "G", members: ["a", "b"], folded: true)
        XCTAssertEqual(RailNesting.foldedGroup(containing: "a", in: [group]), group)
    }

    func testFoldedGroupContainingReturnsNilWhenTheGroupIsAlreadyOpen() {
        let group = CrewGroup(name: "G", members: ["a"], folded: false)
        XCTAssertNil(RailNesting.foldedGroup(containing: "a", in: [group]))
    }

    func testFoldedGroupContainingReturnsNilForANonMember() {
        let group = CrewGroup(name: "G", members: ["a"], folded: true)
        XCTAssertNil(RailNesting.foldedGroup(containing: "elsewhere", in: [group]))
    }

    /// A crew in two folded groups opens the first, the same group it
    /// actually draws under.
    func testFoldedGroupContainingPicksTheFirstGroupForADoubleMember() {
        let first = CrewGroup(name: "First", members: ["a"], folded: true)
        let second = CrewGroup(name: "Second", members: ["a"], folded: true)
        XCTAssertEqual(RailNesting.foldedGroup(containing: "a", in: [first, second]), first)
    }

    // MARK: - group(containing:) (CQ·184's own menu)

    func testGroupContainingReturnsTheGroupRegardlessOfFoldState() {
        let group = CrewGroup(name: "G", members: ["a"], folded: false)
        XCTAssertEqual(RailNesting.group(containing: "a", in: [group]), group)
    }

    func testGroupContainingReturnsNilForANonMember() {
        let group = CrewGroup(name: "G", members: ["a"], folded: false)
        XCTAssertNil(RailNesting.group(containing: "elsewhere", in: [group]))
    }

    func testGroupContainingPicksTheFirstGroupForADoubleMember() {
        let first = CrewGroup(name: "First", members: ["a"], folded: false)
        let second = CrewGroup(name: "Second", members: ["a"], folded: false)
        XCTAssertEqual(RailNesting.group(containing: "a", in: [first, second]), first)
    }

    // MARK: - orderedGroups (Settings › Sessions' own listing order)

    func testOrderedGroupsMatchesTheirDrawOrder() {
        let crews = [
            Crew(id: "a", displayName: "A"),
            Crew(id: "b", displayName: "B"),
            Crew(id: "c", displayName: "C"),
        ]
        let first = CrewGroup(name: "First", members: ["c"], folded: false)
        let second = CrewGroup(name: "Second", members: ["a"], folded: false)
        // `a` draws before `c`, so Second — drawn at a's position — should
        // list before First, even though First sits earlier in `groups`.
        XCTAssertEqual(
            RailNesting.orderedGroups(for: crews, groups: [first, second]).map(\.name),
            ["Second", "First"])
    }

    func testOrderedGroupsAppendsAGroupWithNoLiveMembers() {
        let crews = [Crew(id: "a", displayName: "A")]
        let drawn = CrewGroup(name: "Drawn", members: ["a"], folded: false)
        let ghost = CrewGroup(name: "Ghosts", members: ["gone"], folded: false)
        XCTAssertEqual(
            RailNesting.orderedGroups(for: crews, groups: [drawn, ghost]).map(\.name),
            ["Drawn", "Ghosts"])
    }

    // MARK: - movingGroup (Settings › Sessions' up/down reorder)

    func testMovingGroupUpSwapsWithThePrecedingUngroupedCrew() {
        let crews = [
            Crew(id: "a", displayName: "A"),
            Crew(id: "b", displayName: "B"),
            Crew(id: "c", displayName: "C"),
        ]
        let group = CrewGroup(name: "G", members: ["b"], folded: false)
        let moved = try! XCTUnwrap(RailNesting.movingGroup(group, up: true, in: crews, groups: [group]))
        XCTAssertEqual(moved.map(\.id), ["b", "a", "c"])
    }

    func testMovingGroupDownSwapsWithTheFollowingUngroupedCrew() {
        let crews = [
            Crew(id: "a", displayName: "A"),
            Crew(id: "b", displayName: "B"),
            Crew(id: "c", displayName: "C"),
        ]
        let group = CrewGroup(name: "G", members: ["a"], folded: false)
        let moved = try! XCTUnwrap(RailNesting.movingGroup(group, up: false, in: crews, groups: [group]))
        XCTAssertEqual(moved.map(\.id), ["b", "a", "c"])
    }

    /// A group's members land contiguous at the new position, in their
    /// existing relative order, when the move carries them past a crew that
    /// used to sit between two of them.
    func testMovingGroupMakesNonContiguousMembersContiguous() {
        let crews = [
            Crew(id: "a", displayName: "A"),
            Crew(id: "b", displayName: "B"),
            Crew(id: "c", displayName: "C"),
        ]
        let group = CrewGroup(name: "G", members: ["a", "c"], folded: false)
        let moved = try! XCTUnwrap(RailNesting.movingGroup(group, up: false, in: crews, groups: [group]))
        XCTAssertEqual(moved.map(\.id), ["b", "a", "c"], "a and c become contiguous, in their own order")
    }

    /// A nested crew's own array position is untouched by a reorder of its
    /// unrelated top-level neighbors — nesting is derived from `parent`,
    /// never from array order, so leaving it exactly where it was changes
    /// nothing about what the rail draws.
    func testMovingGroupLeavesANestedCrewsRowExactlyWhereItWas() {
        let crews = [
            Crew(id: "a", displayName: "A"),
            Crew(id: "a-nested", displayName: "Nested", parent: "a"),
            Crew(id: "b", displayName: "B"),
        ]
        let group = CrewGroup(name: "G", members: ["b"], folded: false)
        let moved = try! XCTUnwrap(RailNesting.movingGroup(group, up: true, in: crews, groups: [group]))
        XCTAssertEqual(moved.map(\.id), ["b", "a-nested", "a"])
        XCTAssertEqual(moved[1].id, "a-nested", "the nested row's own index is untouched")
    }

    func testMovingGroupReturnsNilAtTheTop() {
        let crews = [Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")]
        let group = CrewGroup(name: "G", members: ["a"], folded: false)
        XCTAssertNil(RailNesting.movingGroup(group, up: true, in: crews, groups: [group]))
    }

    func testMovingGroupReturnsNilAtTheBottom() {
        let crews = [Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")]
        let group = CrewGroup(name: "G", members: ["b"], folded: false)
        XCTAssertNil(RailNesting.movingGroup(group, up: false, in: crews, groups: [group]))
    }

    func testMovingGroupReturnsNilWhenItDrawsNowhere() {
        let crews = [Crew(id: "a", displayName: "A")]
        let group = CrewGroup(name: "Ghosts", members: ["gone"], folded: false)
        XCTAssertNil(RailNesting.movingGroup(group, up: true, in: crews, groups: [group]))
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

    // MARK: - Sessions settings draws the rail's indents

    func testRailIndentMatchesTheRailsOffsets() {
        let parent = Crew(id: "parent", displayName: "Parent")
        let nested = Crew(id: "nested", displayName: "Nested", parent: "parent")
        let member = Crew(id: "member", displayName: "Member")
        let nestedInMember = Crew(id: "inner", displayName: "Inner", parent: "member")
        let crews = [parent, nested, member, nestedInMember]
        let groups = [CrewGroup(name: "Group", members: ["member"], folded: false)]
        func indent(_ crew: Crew) -> CGFloat {
            RailNesting.railIndent(of: crew, in: crews, groups: groups)
        }

        XCTAssertEqual(indent(parent), 0)
        XCTAssertEqual(indent(nested), RailChildRow.indent)
        XCTAssertEqual(indent(member), RailGroupHeadingRow.memberIndent)
        XCTAssertEqual(indent(nestedInMember), RailGroupHeadingRow.memberIndent + RailChildRow.indent)
    }
}
