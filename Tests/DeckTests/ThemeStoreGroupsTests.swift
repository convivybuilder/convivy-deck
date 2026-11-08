import XCTest
@testable import Deck

/// The editing line of E24's definition of done (CQ·184): the `ThemeStore`
/// mutators behind the rail's "Move to Group"/"Remove from Group" menu and
/// Settings › Sessions' Groups section. `RailNestingTests` covers the pure
/// draw-order and reorder rules these call into; this file covers what each
/// mutator actually commits, read back from a real file the same way
/// `ThemeStoreReconcilePinnedSessionsTests` does.
final class ThemeStoreGroupsTests: XCTestCase {
    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-groups-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    @MainActor
    private func store(_ crews: [Crew]) -> ThemeStore {
        let store = ThemeStore(fileURL: url())
        for crew in crews { store.addCrew(crew) }
        return store
    }

    // MARK: - New Group…

    @MainActor
    func testCreateGroupCreatesAGroupHoldingItsFirstMember() {
        let store = store([Crew(id: "a", displayName: "A")])
        store.createGroup(named: "Rentals", firstMember: "a")
        XCTAssertEqual(store.configuration.groups, [CrewGroup(name: "Rentals", members: ["a"], folded: false)])
    }

    @MainActor
    func testCreateGroupRefusesAnEmptyName() {
        let store = store([Crew(id: "a", displayName: "A")])
        store.createGroup(named: "   ", firstMember: "a")
        XCTAssertEqual(store.configuration.groups, [])
    }

    /// `RailNesting.DrawItem` identifies a group as `"group:<name>"`, so two
    /// groups sharing a name would collide on SwiftUI list identity — PR
    /// #397's security review.
    @MainActor
    func testCreateGroupRefusesANameAnotherGroupAlreadyUses() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")])
        store.createGroup(named: "Rentals", firstMember: "a")
        store.createGroup(named: "Rentals", firstMember: "b")
        XCTAssertEqual(store.configuration.groups, [CrewGroup(name: "Rentals", members: ["a"], folded: false)])
    }

    @MainActor
    func testCreateGroupTakesTheCrewOutOfItsExistingGroup() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")])
        store.createGroup(named: "Old", firstMember: "a")
        store.createGroup(named: "New", firstMember: "a")
        XCTAssertEqual(store.configuration.groups, [CrewGroup(name: "New", members: ["a"], folded: false)])
    }

    /// A group that loses its last member through the move is deleted.
    @MainActor
    func testCreateGroupDeletesTheOldGroupWhenItsLastMemberLeaves() {
        let store = store([Crew(id: "a", displayName: "A")])
        store.createGroup(named: "Old", firstMember: "a")
        store.createGroup(named: "New", firstMember: "a")
        XCTAssertNil(store.configuration.groups.first { $0.name == "Old" })
    }

    // MARK: - Move to Group ▸ <existing group>

    @MainActor
    func testMoveCrewMovesIntoAnExistingGroup() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")])
        store.createGroup(named: "Rentals", firstMember: "a")
        store.moveCrew("b", toGroup: "Rentals")
        XCTAssertEqual(store.configuration.groups, [CrewGroup(name: "Rentals", members: ["a", "b"], folded: false)])
    }

    @MainActor
    func testMoveCrewTakesItOutOfItsPriorGroup() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")])
        store.createGroup(named: "Old", firstMember: "a")
        store.createGroup(named: "New", firstMember: "b")
        store.moveCrew("a", toGroup: "New")
        XCTAssertEqual(store.configuration.groups, [CrewGroup(name: "New", members: ["b", "a"], folded: false)])
    }

    /// The old group is deleted when the moved crew was its last member.
    @MainActor
    func testMoveCrewDeletesTheOldGroupWhenItsLastMemberLeaves() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")])
        store.createGroup(named: "Old", firstMember: "a")
        store.createGroup(named: "New", firstMember: "b")
        store.moveCrew("a", toGroup: "New")
        XCTAssertNil(store.configuration.groups.first { $0.name == "Old" })
    }

    @MainActor
    func testMoveCrewIsANoOpForAnUnknownGroupName() {
        let store = store([Crew(id: "a", displayName: "A")])
        store.createGroup(named: "Rentals", firstMember: "a")
        let before = store.configuration.groups
        store.moveCrew("a", toGroup: "Nonexistent")
        XCTAssertEqual(store.configuration.groups, before)
    }

    // MARK: - Remove from Group

    @MainActor
    func testRemoveCrewFromGroupRemovesMembershipButKeepsTheGroup() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")])
        store.createGroup(named: "Rentals", firstMember: "a")
        store.moveCrew("b", toGroup: "Rentals")
        store.removeCrewFromGroup("b")
        XCTAssertEqual(store.configuration.groups, [CrewGroup(name: "Rentals", members: ["a"], folded: false)])
    }

    /// A group that loses its last member through the removal is deleted.
    @MainActor
    func testRemoveCrewFromGroupDeletesTheGroupWhenItsLastMemberLeaves() {
        let store = store([Crew(id: "a", displayName: "A")])
        store.createGroup(named: "Rentals", firstMember: "a")
        store.removeCrewFromGroup("a")
        XCTAssertEqual(store.configuration.groups, [])
    }

    @MainActor
    func testRemoveCrewFromGroupIsANoOpWhenTheCrewIsInNoGroup() {
        let store = store([Crew(id: "a", displayName: "A")])
        store.removeCrewFromGroup("a")
        XCTAssertEqual(store.configuration.groups, [])
    }

    // MARK: - Rename

    @MainActor
    func testRenameGroupRenamesIt() {
        let store = store([Crew(id: "a", displayName: "A")])
        store.createGroup(named: "Rentals", firstMember: "a")
        store.renameGroup(CrewGroup(name: "Rentals", members: ["a"], folded: false), to: "Lettings")
        XCTAssertEqual(store.configuration.groups,
                       [CrewGroup(name: "Lettings", members: ["a"], folded: false)])
    }

    @MainActor
    func testRenameGroupRefusesANameAnotherGroupAlreadyUses() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")])
        store.createGroup(named: "First", firstMember: "a")
        store.createGroup(named: "Second", firstMember: "b")
        store.renameGroup(CrewGroup(name: "Second", members: ["b"], folded: false), to: "First")
        XCTAssertEqual(store.configuration.groups.map(\.name), ["First", "Second"])
    }

    @MainActor
    func testRenameGroupIsANoOpForAGroupNotInTheList() {
        let store = store([Crew(id: "a", displayName: "A")])
        store.createGroup(named: "Rentals", firstMember: "a")
        store.renameGroup(CrewGroup(name: "Stale", members: ["a"], folded: false), to: "Whatever")
        XCTAssertEqual(store.configuration.groups, [CrewGroup(name: "Rentals", members: ["a"], folded: false)])
    }

    // MARK: - Delete

    @MainActor
    func testDeleteGroupLeavesItsMembersOnTheRailUngrouped() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")])
        store.createGroup(named: "Rentals", firstMember: "a")
        store.moveCrew("b", toGroup: "Rentals")
        store.deleteGroup(CrewGroup(name: "Rentals", members: ["a", "b"], folded: false))
        XCTAssertEqual(store.configuration.groups, [])
        XCTAssertEqual((store.configuration.railSessions ?? []).map(\.id), ["a", "b"])
    }

    // MARK: - Reorder rewrites `rail`

    @MainActor
    func testMoveGroupRewritesRailOrderWithMembersContiguous() {
        let store = store([
            Crew(id: "a", displayName: "A"),
            Crew(id: "b", displayName: "B"),
            Crew(id: "c", displayName: "C"),
        ])
        store.createGroup(named: "G", firstMember: "b")
        store.moveGroup(CrewGroup(name: "G", members: ["b"], folded: false), up: true,
                        in: SessionRoster(configuration: store.configuration))
        XCTAssertEqual((store.configuration.railSessions ?? []).map(\.id), ["b", "a", "c"])
    }

    /// Everything else in each rail row stays as it was: `a` and `c` are
    /// untouched structs, merely reordered.
    @MainActor
    func testMoveGroupLeavesOtherRowsFieldsUntouched() {
        let store = store([
            Crew(id: "a", displayName: "A", workingDirectory: "/work/a"),
            Crew(id: "b", displayName: "B"),
            Crew(id: "c", displayName: "C", workingDirectory: "/work/c"),
        ])
        store.createGroup(named: "G", firstMember: "b")
        store.moveGroup(CrewGroup(name: "G", members: ["b"], folded: false), up: true,
                        in: SessionRoster(configuration: store.configuration))
        let rail = store.configuration.railSessions ?? []
        XCTAssertEqual(rail.first { $0.id == "a" }?.workingDirectory, "/work/a")
        XCTAssertEqual(rail.first { $0.id == "c" }?.workingDirectory, "/work/c")
    }

    @MainActor
    func testMoveGroupIsANoOpAtTheTop() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")])
        store.createGroup(named: "G", firstMember: "a")
        let before = store.configuration.railSessions
        store.moveGroup(CrewGroup(name: "G", members: ["a"], folded: false), up: true,
                        in: SessionRoster(configuration: store.configuration))
        XCTAssertEqual(store.configuration.railSessions, before)
    }

    /// The reorder persists and reads back the same way from disk.
    @MainActor
    func testMoveGroupPersistsAcrossAReload() throws {
        let fileURL = url()
        let store = ThemeStore(fileURL: fileURL)
        store.addCrew(Crew(id: "a", displayName: "A"))
        store.addCrew(Crew(id: "b", displayName: "B"))
        store.createGroup(named: "G", firstMember: "b")
        store.moveGroup(CrewGroup(name: "G", members: ["b"], folded: false), up: true,
                        in: SessionRoster(configuration: store.configuration))

        let reloaded = ThemeConfiguration.load(from: fileURL)
        XCTAssertEqual((reloaded.railSessions ?? []).map(\.id), ["b", "a"])
        XCTAssertEqual(reloaded.groups, [CrewGroup(name: "G", members: ["b"], folded: false)])
    }

    // MARK: - setRoster prunes on the resolved host (CQ·189)

    /// THE BUG: `setRoster`'s own prune compared a group's members, stored
    /// resolved (`CrewMerge.crewHostKey`), against `rail`'s raw rows, whose
    /// `host` is nil for a crew left at the default — see
    /// `ThemeStore.setRoster`'s doc. Every member of a default-host group
    /// failed that match, so pinning anything through the roster editor
    /// (an unrelated crew here) emptied and dropped the group even though
    /// none of its own members left the rail.
    @MainActor
    func testSetRosterKeepsAGroupOfDefaultHostCrewsStoredWithoutAHost() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "host-a", user: TestHost.user, address: TestHost.address))
        store.setDefaultHost("host-a")
        store.addCrew(Crew(id: "alpha", displayName: "Alpha"))
        store.addCrew(Crew(id: "beta", displayName: "Beta"))
        store.addCrew(Crew(id: "gamma", displayName: "Gamma"))
        // Members stored resolved, the way a group's own members are
        // written — see `CrewGroup`'s doc.
        store.createGroup(named: "Properties", firstMember: SessionRef(host: "host-a", name: "alpha"))
        store.moveCrew(SessionRef(host: "host-a", name: "beta"), toGroup: "Properties")

        var roster = SessionRoster(configuration: store.configuration)
        roster.update(SessionRef(host: nil, name: "gamma")) { $0.setPinned(true) }
        store.setRoster(roster)

        XCTAssertEqual(store.configuration.groups, [
            CrewGroup(name: "Properties",
                      members: [SessionRef(host: "host-a", name: "alpha"), SessionRef(host: "host-a", name: "beta")],
                      folded: false),
        ])
    }

    /// A member that is really unpinned through the roster editor still
    /// leaves its group, and a group emptied that way is still dropped —
    /// the fix narrows the match, it does not widen it into keeping a
    /// group whose member genuinely left the rail.
    @MainActor
    func testSetRosterStillDropsADefaultHostMemberThatWasActuallyUnpinned() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "host-a", user: TestHost.user, address: TestHost.address))
        store.setDefaultHost("host-a")
        store.addCrew(Crew(id: "alpha", displayName: "Alpha"))
        store.addCrew(Crew(id: "beta", displayName: "Beta"))
        store.createGroup(named: "Properties", firstMember: SessionRef(host: "host-a", name: "alpha"))
        store.moveCrew(SessionRef(host: "host-a", name: "beta"), toGroup: "Properties")

        var roster = SessionRoster(configuration: store.configuration)
        roster.update(SessionRef(host: nil, name: "beta")) { $0.setPinned(false) }
        store.setRoster(roster)

        XCTAssertEqual(store.configuration.groups, [
            CrewGroup(name: "Properties", members: [SessionRef(host: "host-a", name: "alpha")], folded: false),
        ])
    }

    /// A group that loses every member that way is dropped outright, same
    /// as `removeCrew`'s own rule.
    @MainActor
    func testSetRosterDropsAnEmptiedGroupOfDefaultHostCrews() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "host-a", user: TestHost.user, address: TestHost.address))
        store.setDefaultHost("host-a")
        store.addCrew(Crew(id: "alpha", displayName: "Alpha"))
        store.createGroup(named: "Properties", firstMember: SessionRef(host: "host-a", name: "alpha"))

        var roster = SessionRoster(configuration: store.configuration)
        roster.update(SessionRef(host: nil, name: "alpha")) { $0.setPinned(false) }
        store.setRoster(roster)

        XCTAssertEqual(store.configuration.groups, [])
    }

    /// A group of explicit-host crews (the case that already worked)
    /// behaves exactly as before: unaffected by the resolved-host match.
    @MainActor
    func testSetRosterKeepsAGroupOfExplicitHostCrews() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "host-a", user: TestHost.user, address: TestHost.address))
        store.addCrew(Crew(id: "alpha", displayName: "Alpha", host: "host-a"))
        store.addCrew(Crew(id: "beta", displayName: "Beta", host: "host-a"))
        store.addCrew(Crew(id: "gamma", displayName: "Gamma", host: "host-a"))
        store.createGroup(named: "Properties", firstMember: SessionRef(host: "host-a", name: "alpha"))
        store.moveCrew(SessionRef(host: "host-a", name: "beta"), toGroup: "Properties")

        var roster = SessionRoster(configuration: store.configuration)
        roster.update(SessionRef(host: "host-a", name: "gamma")) { $0.setPinned(true) }
        store.setRoster(roster)

        XCTAssertEqual(store.configuration.groups, [
            CrewGroup(name: "Properties",
                      members: [SessionRef(host: "host-a", name: "alpha"), SessionRef(host: "host-a", name: "beta")],
                      folded: false),
        ])
    }

    // MARK: - Probe: removeCrew/setParent called with a resolved ref (CQ·189)

    /// `removeCrew`/`setParent` take a caller-supplied `SessionRef`, and the
    /// rail's own callers (`ContentView`) pass the MERGED crew's `ref` —
    /// resolved, when a served spec currently fills the row's `host` — not
    /// the raw, possibly-sparse rail row. This probes whether that same
    /// nil-versus-default mismatch reaches `removeCrew`'s group prune when
    /// called the way production actually calls it.
    @MainActor
    func testRemoveCrewCalledWithAResolvedRefStillPrunesTheGroup() {
        let host = HostEntry(name: "host-a", user: TestHost.user, address: TestHost.address)
        let store = ThemeStore(fileURL: url())
        store.addHost(host)
        store.setDefaultHost("host-a")
        store.addCrew(Crew(id: "alpha", displayName: "Alpha"))
        store.addCrew(Crew(id: "beta", displayName: "Beta"))
        store.createGroup(named: "Properties", firstMember: SessionRef(host: "host-a", name: "alpha"))
        store.moveCrew(SessionRef(host: "host-a", name: "beta"), toGroup: "Properties")

        let served = ServedCrew(crewId: "alpha", host: TestHost.target, displayName: "Alpha")
        let merged = CrewMerge.merge(
            configured: store.configuration.railSessions ?? [], served: [served],
            hosts: store.configuration.hosts, defaultHost: store.configuration.defaultHost)
        let resolvedRef = merged.first { $0.id == "alpha" }!.ref
        XCTAssertEqual(resolvedRef, SessionRef(host: "host-a", name: "alpha"),
                       "the merge fills a sparse row's host from the served spec's resolved target")

        store.removeCrew(resolvedRef)

        XCTAssertNil((store.configuration.railSessions ?? []).first { $0.id == "alpha" },
                     "the row itself is removed")
        XCTAssertEqual(store.configuration.groups,
                       [CrewGroup(name: "Properties", members: [SessionRef(host: "host-a", name: "beta")],
                                  folded: false)])
    }

    /// The same probe for `setParent`.
    @MainActor
    func testSetParentCalledWithAResolvedRefStillPrunesTheGroup() {
        let host = HostEntry(name: "host-a", user: TestHost.user, address: TestHost.address)
        let store = ThemeStore(fileURL: url())
        store.addHost(host)
        store.setDefaultHost("host-a")
        store.addCrew(Crew(id: "alpha", displayName: "Alpha"))
        store.addCrew(Crew(id: "beta", displayName: "Beta"))
        store.createGroup(named: "Properties", firstMember: SessionRef(host: "host-a", name: "beta"))

        let served = ServedCrew(crewId: "beta", host: TestHost.target, displayName: "Beta")
        let merged = CrewMerge.merge(
            configured: store.configuration.railSessions ?? [], served: [served],
            hosts: store.configuration.hosts, defaultHost: store.configuration.defaultHost)
        let resolvedRef = merged.first { $0.id == "beta" }!.ref
        XCTAssertEqual(resolvedRef, SessionRef(host: "host-a", name: "beta"))

        store.setParent("alpha", forCrew: resolvedRef)

        XCTAssertEqual((store.configuration.railSessions ?? []).first { $0.id == "beta" }?.parent, "alpha",
                       "the row itself is nested")
        XCTAssertEqual(store.configuration.groups, [])
    }

    /// `addPinnedSession`, `removePinnedSession` and `renameCrew` find their
    /// row the same way `removeCrew` does, so a resolved ref against a
    /// sparse default-host row has to reach the row for each of them too.
    @MainActor
    func testRowLookupsByAResolvedRefReachASparseDefaultHostRow() {
        let host = HostEntry(name: "host-a", user: TestHost.user, address: TestHost.address)
        let store = ThemeStore(fileURL: url())
        store.addHost(host)
        store.setDefaultHost("host-a")
        store.addCrew(Crew(id: "alpha", displayName: "Alpha"))

        let served = ServedCrew(crewId: "alpha", host: TestHost.target, displayName: "Alpha")
        let merged = CrewMerge.merge(
            configured: store.configuration.railSessions ?? [], served: [served],
            hosts: store.configuration.hosts, defaultHost: store.configuration.defaultHost)
        let resolvedRef = merged.first { $0.id == "alpha" }!.ref
        XCTAssertEqual(resolvedRef, SessionRef(host: "host-a", name: "alpha"))
        func alpha() -> Crew? { (store.configuration.railSessions ?? []).first { $0.id == "alpha" } }

        store.addPinnedSession(PinnedSession(name: "alpha--notes", displayName: "notes"), toCrew: resolvedRef)
        XCTAssertEqual(alpha()?.sessions, [PinnedSession(name: "alpha--notes", displayName: "notes")])

        store.renameCrew(resolvedRef, to: "Alpha Prime")
        XCTAssertEqual(alpha()?.displayName, "Alpha Prime")

        store.removePinnedSession("alpha--notes", fromCrew: resolvedRef)
        XCTAssertEqual(alpha()?.sessions, [])
    }

    // MARK: - Unpinning removes group membership

    @MainActor
    func testRemovingACrewFromTheRailRemovesItFromItsGroup() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")])
        store.createGroup(named: "Rentals", firstMember: "a")
        store.moveCrew("b", toGroup: "Rentals")
        store.removeCrew("b")
        XCTAssertEqual(store.configuration.groups, [CrewGroup(name: "Rentals", members: ["a"], folded: false)])
    }

    /// The group itself is deleted when the removed crew was its last
    /// member — the same rule a move or an explicit "Remove from Group"
    /// follows.
    @MainActor
    func testRemovingACrewsLastGroupMembershipDeletesTheGroup() {
        let store = store([Crew(id: "a", displayName: "A")])
        store.createGroup(named: "Rentals", firstMember: "a")
        store.removeCrew("a")
        XCTAssertEqual(store.configuration.groups, [])
    }

    /// `setRoster` is the Settings › Sessions unpin path — a roster edit
    /// that takes a grouped crew off the rail prunes its membership the
    /// same way `removeCrew` does.
    @MainActor
    func testUnpinningThroughTheRosterEditorRemovesGroupMembership() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")])
        store.createGroup(named: "Rentals", firstMember: "a")
        store.moveCrew("b", toGroup: "Rentals")

        var roster = SessionRoster(configuration: store.configuration)
        roster.update(SessionRef(host: nil, name: "b")) { $0.setPinned(false) }
        store.setRoster(roster)

        XCTAssertEqual(store.configuration.groups, [CrewGroup(name: "Rentals", members: ["a"], folded: false)])
    }

    // MARK: - Settings reaches a served crew with no rail row (PR #398 review)

    /// THE BUG THIS GUARDS: a group whose only member is a crew served but
    /// never written into `rail` draws no `.group` item at all when
    /// `RailNesting` is fed the raw array — the crew never appears in it —
    /// so its "move up"/"move down" buttons would silently no-op, a
    /// clickable dead button with no error. Fed the same merged list the
    /// rail itself draws (`roster.entries`, which already carries the
    /// served crew pinned), the group draws and reorders normally.
    @MainActor
    func testMoveGroupReachesAGroupWhoseOnlyMemberIsAServedOnlyCrew() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "c", displayName: "C")])
        store.createGroup(named: "Rentals", firstMember: "b")

        XCTAssertNil(RailNesting.movingGroup(
            CrewGroup(name: "Rentals", members: ["b"], folded: false), up: true,
            in: store.configuration.railSessions ?? [], groups: store.configuration.groups,
            hosts: [], defaultHost: nil),
            "b never appears in the raw array, so there is no draw item to find")

        let b = ServedCrew(crewId: "b", host: TestHost.target, displayName: "B")
        let roster = SessionRoster(configuration: store.configuration, servedCrews: [b])
        XCTAssertEqual(roster.entries.map(\.id), ["a", "c", "b"])

        store.moveGroup(CrewGroup(name: "Rentals", members: ["b"], folded: false), up: true, in: roster)
        XCTAssertEqual((store.configuration.railSessions ?? []).map(\.id), ["a", "b", "c"],
                       "b is materialized sparse, contiguous at its group's new position")
    }

    /// `ThemeStore.moveGroup` reorders over the same merged list — a member
    /// with no `rail` row yet is materialized sparse rather than silently
    /// left out, the same way an unpinned served crew already saves sparse
    /// (PR #395), so the group's members land contiguous at the new
    /// position even when one of them has never been written to disk.
    @MainActor
    func testMoveGroupMaterializesAServedCrewWithNoRailRowSparse() {
        let store = store([
            Crew(id: "a", displayName: "A"), Crew(id: "c", displayName: "C"), Crew(id: "d", displayName: "D"),
        ])
        store.createGroup(named: "Rentals", firstMember: "a")
        store.moveCrew("b", toGroup: "Rentals")

        let b = ServedCrew(crewId: "b", host: TestHost.target, displayName: "B")
        let roster = SessionRoster(configuration: store.configuration, servedCrews: [b])
        XCTAssertEqual(roster.entries.map(\.id), ["a", "c", "d", "b"],
                       "b draws through the merge alone, with no rail row yet")
        XCTAssertNil((store.configuration.railSessions ?? []).first { $0.id == "b" })

        store.moveGroup(CrewGroup(name: "Rentals", members: ["a", "b"], folded: false), up: false, in: roster)

        let rail = store.configuration.railSessions ?? []
        XCTAssertEqual(rail.map(\.id), ["c", "a", "b", "d"],
                       "a and b land contiguous at the new position, and b is materialized rather than dropped")
    }

    // MARK: - Nesting a grouped crew (PR #398 review)

    /// `CrewGroup`'s own doc: membership is only ever a top-level ref.
    /// Nesting a grouped crew under another takes it out of its group, the
    /// same way unpinning it does.
    @MainActor
    func testNestingAGroupedCrewRemovesItFromItsGroup() {
        let store = store([Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B")])
        store.createGroup(named: "Rentals", firstMember: "b")
        store.setParent("a", forCrew: "b")
        XCTAssertEqual(store.configuration.groups, [])
    }

    /// The group itself survives when another member stays top-level.
    @MainActor
    func testNestingAGroupedCrewLeavesOtherMembersInTheGroup() {
        let store = store([
            Crew(id: "a", displayName: "A"), Crew(id: "b", displayName: "B"), Crew(id: "c", displayName: "C"),
        ])
        store.createGroup(named: "Rentals", firstMember: "b")
        store.moveCrew("c", toGroup: "Rentals")
        store.setParent("a", forCrew: "b")
        XCTAssertEqual(store.configuration.groups, [CrewGroup(name: "Rentals", members: ["c"], folded: false)])
    }

    /// A parent id that fails `RailNesting.nestingParent`'s own rule (here,
    /// a dangling id naming no crew at all) leaves the crew top-level still,
    /// so its group membership is untouched.
    @MainActor
    func testNestingThatFailsLeavesGroupMembershipUntouched() {
        let store = store([Crew(id: "a", displayName: "A")])
        store.createGroup(named: "Rentals", firstMember: "a")
        store.setParent("missing", forCrew: "a")
        XCTAssertEqual(store.configuration.groups, [CrewGroup(name: "Rentals", members: ["a"], folded: false)])
    }
}
