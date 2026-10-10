import XCTest
@testable import Deck

/// The rules that let one list stand in for two config keys. Every test here
/// guards a way the two representations could quietly stop agreeing.
final class SessionRosterTests: XCTestCase {

    private func roster(rail: [Crew]? = nil,
                        catalog: [LaunchableSession] = []) -> SessionRoster {
        var configuration = ThemeConfiguration.empty
        configuration.railSessions = rail
        configuration.catalog = catalog
        return SessionRoster(configuration: configuration)
    }

    // MARK: - What `nil` means depends on which list a row is in

    func testAPinnedRowWithoutACommandRefreshes() {
        let entry = RosterEntry(id: "vivy", displayName: "Vivy", isPinned: true)
        XCTAssertEqual(entry.resolvedCommand, "co -r")
        XCTAssertTrue(entry.refreshes)
    }

    func testAnUnpinnedRowWithoutACommandDoesNot() {
        let entry = RosterEntry(id: "ask", displayName: "Ask", isPinned: false)
        XCTAssertEqual(entry.resolvedCommand, "co")
        XCTAssertFalse(entry.refreshes)
    }

    func testTheLongFormFlagCounts() {
        // Someone who hand-wrote `--refresh` should not find the checkbox
        // disagreeing with their config file.
        var entry = RosterEntry(id: "nyh", displayName: "NYH", isPinned: false)
        entry.command = "co --refresh"
        XCTAssertTrue(entry.refreshes)
    }

    // MARK: - Pinning must not change what a session does

    /// The bug this exists to prevent: `nil` means `co -r` on the rail and `co`
    /// in the catalog, so flipping the flag alone would silently switch the
    /// refresh off for a row that had it on.
    func testUnpinningKeepsTheRefreshOn() {
        var entry = RosterEntry(id: "vivy", displayName: "Vivy", isPinned: true)
        XCTAssertTrue(entry.refreshes)

        entry.setPinned(false)

        XCTAssertTrue(entry.refreshes, "unpinning turned the refresh off")
        XCTAssertEqual(entry.command, "co -r", "the catalog needs it written out")
    }

    func testPinningKeepsTheRefreshOff() {
        var entry = RosterEntry(id: "ask", displayName: "Ask", isPinned: false)
        XCTAssertFalse(entry.refreshes)

        entry.setPinned(true)

        XCTAssertFalse(entry.refreshes, "pinning turned the refresh on")
        XCTAssertEqual(entry.command, "co", "the rail needs the opt-out written out")
    }

    func testPinningDropsAnOverrideThatMatchesTheNewDefault() {
        // `co -r` stored explicitly in the catalog becomes the rail's default,
        // so it goes back to nil rather than being written into the file.
        var entry = RosterEntry(id: "svc", displayName: "Kit",
                                command: "co -r", isPinned: false)
        entry.setPinned(true)
        XCTAssertNil(entry.command)
        XCTAssertTrue(entry.refreshes)
    }

    func testACustomCommandSurvivesPinning() {
        var entry = RosterEntry(id: "lab", displayName: "Lab",
                                command: "co --model kimi", isPinned: false)
        entry.setPinned(true)
        XCTAssertEqual(entry.resolvedCommand, "co --model kimi")
    }

    // MARK: - The checkbox

    func testTheCheckboxStoresNilWhenItMatchesTheDefault() {
        var entry = RosterEntry(id: "vivy", displayName: "Vivy",
                                command: "co", isPinned: true)
        entry.setRefreshes(true)
        XCTAssertNil(entry.command, "the rail default was written into the file")
    }

    func testTheCheckboxWritesTheOptOutExplicitly() {
        var entry = RosterEntry(id: "vivy", displayName: "Vivy", isPinned: true)
        entry.setRefreshes(false)
        XCTAssertEqual(entry.command, "co")
        XCTAssertFalse(entry.refreshes)
    }

    /// The checkbox produces `co` or `co -r` and nothing else, so it stands
    /// aside rather than rewriting a command it cannot express.
    func testTheCheckboxLeavesACustomCommandAlone() {
        var entry = RosterEntry(id: "lab", displayName: "Lab",
                                command: "cd ~/x && co", isPinned: true)
        XCTAssertTrue(entry.isCustomCommand)
        entry.setRefreshes(false)
        XCTAssertEqual(entry.command, "cd ~/x && co")
    }

    /// The long form is the same flag, so the checkbox stays usable. Before
    /// this it drew itself checked — `refreshes` reads the flag correctly — and
    /// then refused to be clicked.
    func testTheLongFormFlagIsStillExpressibleByTheCheckbox() {
        var entry = RosterEntry(id: "nyh", displayName: "NYH",
                                command: "co --refresh", isPinned: false)
        XCTAssertFalse(entry.isCustomCommand)
        XCTAssertTrue(entry.refreshes)

        entry.setRefreshes(false)
        XCTAssertFalse(entry.refreshes)
        XCTAssertEqual(entry.resolvedCommand, "co")
        XCTAssertNil(entry.command, "`co` is the catalog default and belongs in no file")
    }

    func testAnUnusableCommandClearsTheOverrideRatherThanStoringIt() {
        var entry = RosterEntry(id: "vivy", displayName: "Vivy", isPinned: true)
        entry.setCommand("co\nrm -rf /")
        XCTAssertNil(entry.command)
    }

    // MARK: - The list

    func testTheRosterPutsPinnedRowsFirst() {
        let list = roster(rail: [Crew(id: "vivy", displayName: "Vivy")],
                          catalog: [LaunchableSession(id: "ask", displayName: "Ask")])
        XCTAssertEqual(list.entries.map(\.id), ["vivy", "ask"])
        XCTAssertEqual(list.pinnedCount, 1)
    }

    /// `CrewCatalog.known` is empty (`deck/specs/running-deck-as-someone-else`
    /// §"The defaults name Convivy"), so an unconfigured rail draws nothing
    /// pinned — not Convivy's own org chart.
    func testAnUnconfiguredRailIsEmpty() {
        let list = roster()
        XCTAssertTrue(list.entries.isEmpty)
        XCTAssertEqual(list.pinnedCount, 0)
    }

    func testUnpinningMovesTheRowBelowTheRail() {
        var list = roster(rail: [Crew(id: "vivy", displayName: "Vivy"),
                                 Crew(id: "deck", displayName: "Deck")])
        list.update("vivy") { $0.setPinned(false) }
        XCTAssertEqual(list.entries.map(\.id), ["deck", "vivy"])
        XCTAssertEqual(list.pinnedCount, 1)
    }

    func testAMoveThatWouldCrossTheBoundaryIsRefused() {
        // Dragging a catalog row up into the rail would pin it as a side effect
        // of a gesture that says nothing about pinning.
        var list = roster(rail: [Crew(id: "vivy", displayName: "Vivy")],
                          catalog: [LaunchableSession(id: "ask", displayName: "Ask")])
        list.moveRail(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(list.entries.map(\.id), ["vivy", "ask"])
        XCTAssertFalse(list[ "ask" ]?.isPinned ?? true)
    }

    func testTheRailReorders() {
        var list = roster(rail: [Crew(id: "a", displayName: "A"),
                                 Crew(id: "b", displayName: "B"),
                                 Crew(id: "c", displayName: "C")])
        list.moveRail(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(list.entries.map(\.id), ["c", "a", "b"])
    }

    // MARK: - Writing back

    func testTheRosterRoundTripsThroughAConfiguration() {
        var list = roster(rail: [Crew(id: "vivy", displayName: "Vivy")],
                          catalog: [LaunchableSession(id: "ask", displayName: "Ask")])
        list.update("ask") { $0.setPinned(true) }
        let updated = list.applied(to: .empty)

        XCTAssertEqual(updated.railSessions?.map(\.id), ["vivy", "ask"])
        XCTAssertTrue(updated.catalog.isEmpty)
        XCTAssertEqual(updated.railSessions?.last?.command, "co",
                       "Ask kept its no-refresh behaviour across the move")
    }

    /// A user who edits a catalog folder must not thereby freeze the shipped
    /// rail into their config and stop receiving later changes to it.
    func testAnUntouchedRailIsNotWrittenIntoConfig() {
        var list = roster(catalog: [LaunchableSession(id: "ask", displayName: "Ask")])
        list.update("ask") { $0.workingDirectory = "~/ask" }
        let updated = list.applied(to: .empty)
        XCTAssertNil(updated.railSessions, "editing the catalog froze the rail")
        XCTAssertEqual(updated.catalog.map(\.id), ["ask"])
        XCTAssertEqual(updated.catalog.first?.workingDirectory, "~/ask")
    }

    func testAnEditedRailIsWrittenOut() {
        var list = roster(rail: [Crew(id: "vivy", displayName: "Vivy"),
                                 Crew(id: "deck", displayName: "Deck")])
        list.update("vivy") { $0.setPinned(false) }
        let updated = list.applied(to: .empty)
        XCTAssertEqual(updated.railSessions?.count, 1)
    }

    // MARK: - Two crews of one name on different hosts (part 3 of the epic)

    /// THE BUG THIS GUARDS. `subscript`/`update`/`remove` used to key on the
    /// bare `id`, which two same-named crews on different hosts share, so an
    /// edit meant for one always landed on whichever came first in `entries`.
    /// Keyed by `ref` (host + name) instead, each row's own edit — pin,
    /// project, command — must reach only that row.
    func testEditingOneOfTwoSameNamedCrewsLeavesTheOtherUnchanged() {
        let minisRow = RosterEntry(id: "steward", displayName: "steward", command: "co",
                                   isPinned: true, host: "mini", project: "mini-project")
        let guestsRow = RosterEntry(id: "steward", displayName: "steward", command: "co",
                                    isPinned: true, host: "guest", project: "guest-project")
        var list = SessionRoster(entries: [minisRow, guestsRow])

        let minisRef = SessionRef(host: "mini", name: "steward")
        let guestsRef = SessionRef(host: "guest", name: "steward")

        list.update(minisRef) {
            $0.setPinned(false)
            $0.project = "mini-project-renamed"
            $0.setCommand("co --model kimi")
        }

        XCTAssertFalse(list[minisRef]?.isPinned ?? true, "mini's row took the pin edit")
        XCTAssertEqual(list[minisRef]?.project, "mini-project-renamed")
        XCTAssertEqual(list[minisRef]?.command, "co --model kimi")

        XCTAssertTrue(list[guestsRef]?.isPinned ?? false, "guest's row kept its own pin")
        XCTAssertEqual(list[guestsRef]?.project, "guest-project", "guest's row kept its own project")
        XCTAssertEqual(list[guestsRef]?.command, "co", "guest's row kept its own command")
    }

    /// `remove` is the same lookup as `update`/`subscript` — a bare-id match
    /// would have dropped whichever of the two rows came first, not the one
    /// the operator actually asked to remove.
    func testRemovingOneOfTwoSameNamedCrewsLeavesTheOtherInPlace() {
        let minisRow = RosterEntry(id: "steward", displayName: "steward", isPinned: true, host: "mini")
        let guestsRow = RosterEntry(id: "steward", displayName: "steward", isPinned: true, host: "guest")
        var list = SessionRoster(entries: [minisRow, guestsRow])

        list.remove(SessionRef(host: "mini", name: "steward"))

        XCTAssertNil(list[SessionRef(host: "mini", name: "steward")])
        XCTAssertNotNil(list[SessionRef(host: "guest", name: "steward")])
        XCTAssertEqual(list.entries.count, 1)
    }

    /// The round trip a previous fix's `CrewMerge.match` protects: two hosts
    /// serving a crew of the same id, with a raw sessionId collision on top
    /// (the same coincidence `CrewMergeTests`' cross-host section pins for
    /// `merge` itself). Built via `init(entries:servedCrews:)` directly, not
    /// `roster(rail:)` + `update(id:)`, so this exercises `applied(to:)`
    /// rather than the `ref`-keyed lookups the tests above cover.
    func testSavingTwoHostsSameIdRowsKeepsEachRowsOwnFields() {
        let mini = TestHost.target
        let guest = TestHost.secondaryTarget
        let hosts = [
            HostEntry(name: "mini", user: TestHost.user, address: TestHost.address),
            HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress),
        ]
        let minisSpec = ServedCrew(crewId: "steward", host: mini,
                                   workingDirectory: "\(TestHost.homeRoot)/Convivy/steward",
                                   sessionId: "$3", project: "mini-project")
        let guestsSpec = ServedCrew(crewId: "steward", host: guest,
                                    workingDirectory: "\(TestHost.secondaryHomeRoot)/Convivy/steward",
                                    sessionId: "$3", project: "guest-project")

        // Mini's row edited (project changed from the spec's own value);
        // guest's row left exactly as the spec fills it.
        let minisRow = RosterEntry(id: "steward", displayName: "steward",
                                   workingDirectory: "\(TestHost.homeRoot)/Convivy/steward",
                                   isPinned: true, host: "mini", project: "mini-project-2")
        let guestsRow = RosterEntry(id: "steward", displayName: "steward",
                                    workingDirectory: "\(TestHost.secondaryHomeRoot)/Convivy/steward",
                                    isPinned: true, host: "guest", project: "guest-project")
        let list = SessionRoster(entries: [minisRow, guestsRow], servedCrews: [minisSpec, guestsSpec])

        var configuration = ThemeConfiguration.empty
        configuration.hosts = hosts
        configuration.defaultHost = "mini"
        let updated = list.applied(to: configuration)

        XCTAssertEqual(updated.railSessions?.count, 1, "guest's untouched row drops out; mini's edit survives")
        let written = updated.railSessions?.first
        XCTAssertEqual(written?.project, "mini-project-2",
                       "the edit survives, and identifies this as mini's row: guest's spec never has this value")
        XCTAssertNil(written?.host,
                     "matches what mini's OWN spec would fill in, so it strips back to unset like any other field")
        XCTAssertNil(written?.workingDirectory,
                     "equal to mini's OWN spec, so it strips to unset; guest's spec differs here, so this " +
                     "would wrongly survive if match crossed hosts")
    }

    // MARK: - Pinned children survive an ordinary Settings edit

    /// THE REGRESSION THIS GUARDS. `RosterEntry` used to carry only the fields
    /// Settings itself edits, so round-tripping a row through it — even to
    /// change something unrelated, like its command — rebuilt the `Crew`
    /// from scratch and silently dropped any pinned sibling sessions it had.
    /// Every row in the roster goes through this path on every edit (`applied`
    /// rebuilds the whole rail from `entries`), so this was not a one-row bug:
    /// renaming any session in Settings would have wiped every crew's
    /// children in the same write.
    func testAnUnrelatedEditToAnotherRowDoesNotDropACrewsChildren() {
        let ask = Crew(id: "ask", displayName: "Ask",
                          sessions: [PinnedSession(name: "ask--research", displayName: "research")])
        var list = roster(rail: [ask, Crew(id: "deck", displayName: "Deck")])

        list.update("deck") { $0.setCommand("co --model kimi") }
        let updated = list.applied(to: .empty)

        XCTAssertEqual(updated.railSessions?.first { $0.id == "ask" }?.sessions,
                       [PinnedSession(name: "ask--research", displayName: "research")])
    }

    /// The same row's own edit must not cost it its children either.
    func testRenamingACrewKeepsItsChildren() {
        let ask = Crew(id: "ask", displayName: "Ask",
                          sessions: [PinnedSession(name: "ask--research", displayName: "research")])
        var list = roster(rail: [ask])

        list.update("ask") { $0.displayName = "Ask (renamed)" }
        let updated = list.applied(to: .empty)

        let row = updated.railSessions?.first { $0.id == "ask" }
        XCTAssertEqual(row?.displayName, "Ask (renamed)")
        XCTAssertEqual(row?.sessions, [PinnedSession(name: "ask--research", displayName: "research")])
    }

    /// `parent` round-trips through the same path, for the same reason —
    /// design §D's nav field is decoded today even though nothing renders it
    /// yet, and Settings must not be a second place that quietly drops it.
    func testAParentFieldSurvivesAnUnrelatedEdit() {
        var list = roster(rail: [
            Crew(id: "vivy", displayName: "Vivy"),
            Crew(id: "vivy-commercial", displayName: "Vivy Commercial", parent: "vivy"),
        ])
        list.update("vivy") { $0.displayName = "Vivy (renamed)" }
        let updated = list.applied(to: .empty)
        XCTAssertEqual(updated.railSessions?.first { $0.id == "vivy-commercial" }?.parent, "vivy")
    }

    /// THE GAP `RosterEntry.sessions`'s doc comment used to disclose:
    /// `LaunchableSession` had no field to carry children into, so unpinning a
    /// crew through Settings' own pin toggle — reachable today with no
    /// children-management UI needed — silently lost them. `LaunchableSession`
    /// now carries `sessions`/`parent` the same way `Crew` does, so a
    /// pin/unpin/re-pin round trip through the roster keeps both.
    func testUnpinningAndRePinningACrewKeepsItsChildren() {
        let ask = Crew(id: "ask", displayName: "Ask", sessions: [
            PinnedSession(name: "ask--research", displayName: "research"),
            PinnedSession(name: "ask--drafts", displayName: "drafts"),
        ])
        var list = roster(rail: [ask])

        list.update("ask") { $0.setPinned(false) }
        XCTAssertEqual(list["ask"]?.sessions,
                       [PinnedSession(name: "ask--research", displayName: "research"),
                        PinnedSession(name: "ask--drafts", displayName: "drafts")],
                       "unpinning dropped the children before they were ever written out")

        let unpinned = list.applied(to: .empty)
        XCTAssertEqual(unpinned.catalog.first { $0.id == "ask" }?.sessions,
                       [PinnedSession(name: "ask--research", displayName: "research"),
                        PinnedSession(name: "ask--drafts", displayName: "drafts")],
                       "the catalog row this crew became has no field to hold its children")

        list.update("ask") { $0.setPinned(true) }
        let rePinned = list.applied(to: .empty)
        XCTAssertEqual(rePinned.railSessions?.first { $0.id == "ask" }?.sessions,
                       [PinnedSession(name: "ask--research", displayName: "research"),
                        PinnedSession(name: "ask--drafts", displayName: "drafts")],
                       "re-pinning did not recover the children the catalog row lost")
    }
}
