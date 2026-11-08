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
        let entry = RosterEntry(id: "orchard", displayName: "Orchard", isPinned: true)
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
        var entry = RosterEntry(id: "lakeside", displayName: "Lakeside", isPinned: false)
        entry.command = "co --refresh"
        XCTAssertTrue(entry.refreshes)
    }

    // MARK: - Pinning must not change what a session does

    /// The bug this exists to prevent: `nil` means `co -r` on the rail and `co`
    /// in the catalog, so flipping the flag alone would silently switch the
    /// refresh off for a row that had it on.
    func testUnpinningKeepsTheRefreshOn() {
        var entry = RosterEntry(id: "orchard", displayName: "Orchard", isPinned: true)
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
        var entry = RosterEntry(id: "kit", displayName: "Kit",
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
        var entry = RosterEntry(id: "orchard", displayName: "Orchard",
                                command: "co", isPinned: true)
        entry.setRefreshes(true)
        XCTAssertNil(entry.command, "the rail default was written into the file")
    }

    func testTheCheckboxWritesTheOptOutExplicitly() {
        var entry = RosterEntry(id: "orchard", displayName: "Orchard", isPinned: true)
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
        var entry = RosterEntry(id: "lakeside", displayName: "Lakeside",
                                command: "co --refresh", isPinned: false)
        XCTAssertFalse(entry.isCustomCommand)
        XCTAssertTrue(entry.refreshes)

        entry.setRefreshes(false)
        XCTAssertFalse(entry.refreshes)
        XCTAssertEqual(entry.resolvedCommand, "co")
        XCTAssertNil(entry.command, "`co` is the catalog default and belongs in no file")
    }

    func testAnUnusableCommandClearsTheOverrideRatherThanStoringIt() {
        var entry = RosterEntry(id: "orchard", displayName: "Orchard", isPinned: true)
        entry.setCommand("co\nrm -rf /")
        XCTAssertNil(entry.command)
    }

    // MARK: - The list

    func testTheRosterPutsPinnedRowsFirst() {
        let list = roster(rail: [Crew(id: "orchard", displayName: "Orchard")],
                          catalog: [LaunchableSession(id: "ask", displayName: "Ask")])
        XCTAssertEqual(list.entries.map(\.id), ["orchard", "ask"])
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
        var list = roster(rail: [Crew(id: "orchard", displayName: "Orchard"),
                                 Crew(id: "deck", displayName: "Deck")])
        list.update("orchard") { $0.setPinned(false) }
        XCTAssertEqual(list.entries.map(\.id), ["deck", "orchard"])
        XCTAssertEqual(list.pinnedCount, 1)
    }

    func testAMoveThatWouldCrossTheBoundaryIsRefused() {
        // Dragging a catalog row up into the rail would pin it as a side effect
        // of a gesture that says nothing about pinning.
        var list = roster(rail: [Crew(id: "orchard", displayName: "Orchard")],
                          catalog: [LaunchableSession(id: "ask", displayName: "Ask")])
        list.moveRail(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(list.entries.map(\.id), ["orchard", "ask"])
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
        var list = roster(rail: [Crew(id: "orchard", displayName: "Orchard")],
                          catalog: [LaunchableSession(id: "ask", displayName: "Ask")])
        list.update("ask") { $0.setPinned(true) }
        let updated = list.applied(to: .empty)

        XCTAssertEqual(updated.railSessions?.map(\.id), ["orchard", "ask"])
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
        var list = roster(rail: [Crew(id: "orchard", displayName: "Orchard"),
                                 Crew(id: "deck", displayName: "Deck")])
        list.update("orchard") { $0.setPinned(false) }
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
            Crew(id: "orchard", displayName: "Orchard"),
            Crew(id: "orchard-commercial", displayName: "Orchard Commercial", parent: "orchard"),
        ])
        list.update("orchard") { $0.displayName = "Orchard (renamed)" }
        let updated = list.applied(to: .empty)
        XCTAssertEqual(updated.railSessions?.first { $0.id == "orchard-commercial" }?.parent, "orchard")
    }

    // MARK: - A position is an edit (dragging a served-only crew)

    /// THE BUG THIS GUARDS. A served-only crew (one with no local config at
    /// all, like Atlas on crews.d) draws pinned via `CrewMerge.merge`, so
    /// moving it in Settings only reorders `entries` — nothing about the
    /// row itself changed. The old `applied(to:)` dropped it anyway because
    /// `CrewMerge.isUnedited` only looks at the row's own fields, and
    /// `CrewMerge.merge` always re-appends a dropped served crew at the very
    /// END, in `servedCrews`' own order — so the drag silently undid itself
    /// on the next save.
    func testDraggingAServedOnlyCrewAboveAConfiguredOneSticks() {
        let atlas = ServedCrew(crewId: "atlas", host: mini, displayName: "Atlas")
        var list = SessionRoster(configuration: configuration(rail: [Crew(id: "orchard", displayName: "Orchard")]),
                                 servedCrews: [atlas])
        XCTAssertEqual(list.entries.map(\.id), ["orchard", "atlas"], "atlas arrives after orchard, unmerged")

        list.moveRail(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(list.entries.map(\.id), ["atlas", "orchard"])

        let updated = list.applied(to: configuration(rail: nil))
        XCTAssertEqual(updated.railSessions?.map(\.id), ["atlas", "orchard"],
                       "the drag must survive the write, even though atlas changed nothing but its spot")

        // Rebuilding from the written configuration, against the same served
        // crews, must reproduce the moved order rather than snapping atlas
        // back to the end.
        let rebuilt = SessionRoster(configuration: updated, servedCrews: [atlas])
        XCTAssertEqual(rebuilt.entries.map(\.id), ["atlas", "orchard"])
    }

    /// The companion case: a served-only crew left exactly where `merge`
    /// would put it (at the end, untouched) still drops out of
    /// `railSessions` entirely, exactly as before this fix.
    func testAnUntouchedServedOnlyCrewAtTheEndStillDoesNotWrite() {
        let atlas = ServedCrew(crewId: "atlas", host: mini, displayName: "Atlas")
        let list = SessionRoster(configuration: configuration(rail: [Crew(id: "orchard", displayName: "Orchard")]),
                                 servedCrews: [atlas])
        XCTAssertEqual(list.entries.map(\.id), ["orchard", "atlas"])

        let updated = list.applied(to: configuration(rail: nil))
        XCTAssertEqual(updated.railSessions?.map(\.id), ["orchard"],
                       "atlas was never touched, so it must stay out of local config")
    }

    /// The same drag, but the served-only crew is on a NON-default host — the
    /// case the host strip in `CrewMerge.sparse` touches. `match` must still
    /// find the same spec after the row round-trips through `asCrew`, and
    /// the host must still strip back to unset so a later rename on that
    /// host keeps reaching this row.
    func testDraggingAServedOnlyCrewOnANonDefaultHostSticks() {
        let guest = TestHost.secondaryTarget
        let hosts = [HostEntry(name: "mini", user: TestHost.user, address: TestHost.address),
                    HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress)]
        let atlas = ServedCrew(crewId: "atlas", host: guest, displayName: "Atlas")

        var configuration = ThemeConfiguration.empty
        configuration.hosts = hosts
        configuration.defaultHost = "mini"
        configuration.railSessions = [Crew(id: "orchard", displayName: "Orchard")]

        let atlasRef = SessionRef(host: "guest", name: "atlas")
        var list = SessionRoster(configuration: configuration, servedCrews: [atlas])
        XCTAssertEqual(list.entries.map(\.id), ["orchard", "atlas"])
        XCTAssertEqual(list[atlasRef]?.host, "guest")

        list.moveRail(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(list.entries.map(\.id), ["atlas", "orchard"])

        let updated = list.applied(to: configuration)
        XCTAssertEqual(updated.railSessions?.map(\.id), ["atlas", "orchard"])
        XCTAssertEqual(updated.railSessions?.first { $0.id == "atlas" }?.host, "guest",
                       "nil would mean the DEFAULT host on the next read, not guest — "
                       + "losing this would strand the row with no spec to match on reload")

        let rebuilt = SessionRoster(configuration: updated, servedCrews: [atlas])
        XCTAssertEqual(rebuilt.entries.map(\.id), ["atlas", "orchard"])
        XCTAssertEqual(rebuilt[atlasRef]?.host, "guest", "still resolves to the host it's actually served from")
    }

    // MARK: - Unpinning a served-only crew, and pinning it back

    /// THE BUG THIS GUARDS (issue_01M5MMDY7W78BNEH53R2SKGHXG). Unpinning a
    /// served-only crew used to write it into `catalog` while
    /// `CrewMerge.merge` kept drawing it pinned anyway, so a rebuilt roster
    /// showed the crew twice, sharing one `ref` — and each further unpin
    /// appended another catalog copy. Rebuilding after one unpin must show
    /// it unpinned exactly once.
    func testUnpinningAServedOnlyCrewLeavesItUnpinnedExactlyOnceAfterRebuild() {
        let atlas = ServedCrew(crewId: "atlas", host: mini, displayName: "Atlas")
        var list = SessionRoster(configuration: configuration(rail: nil), servedCrews: [atlas])
        XCTAssertEqual(list.entries.map(\.id), ["atlas"])
        XCTAssertEqual(list.entries.map(\.isPinned), [true])

        list.update("atlas") { $0.setPinned(false) }
        let updated = list.applied(to: configuration(rail: nil))
        XCTAssertEqual(updated.catalog.count, 1, "the unpin writes exactly one catalog row")
        XCTAssertNil(updated.railSessions, "nothing pinned survives to the rail")

        let rebuilt = SessionRoster(configuration: updated, servedCrews: [atlas])
        XCTAssertEqual(rebuilt.entries.map(\.id), ["atlas"],
                       "one row — not a pinned copy beside the catalog's")
        XCTAssertEqual(rebuilt.entries.map(\.isPinned), [false])
    }

    /// The companion half: pinning that same row again moves it back to the
    /// rail with no catalog copy left behind.
    func testPinningAnUnpinnedServedOnlyCrewAgainLeavesItOnTheRailExactlyOnce() {
        let atlas = ServedCrew(crewId: "atlas", host: mini, displayName: "Atlas")
        var list = SessionRoster(configuration: configuration(rail: nil), servedCrews: [atlas])
        list.update("atlas") { $0.setPinned(false) }
        let unpinned = list.applied(to: configuration(rail: nil))

        var rebuilt = SessionRoster(configuration: unpinned, servedCrews: [atlas])
        rebuilt.update("atlas") { $0.setPinned(true) }
        let repinned = rebuilt.applied(to: unpinned)
        XCTAssertTrue(repinned.catalog.isEmpty, "no catalog copy left behind")

        let rebuiltAgain = SessionRoster(configuration: repinned, servedCrews: [atlas])
        XCTAssertEqual(rebuiltAgain.entries.map(\.id), ["atlas"],
                       "one row — the pin must not leave a second, unpinned copy")
        XCTAssertEqual(rebuiltAgain.entries.map(\.isPinned), [true])
    }

    /// Writing an unpinned served crew out whole froze the spec's fill into
    /// the catalog row, so a later spec change never reached it. Unpin and
    /// save, change the spec, and the rebuilt row follows the new spec, both
    /// after the unpin's own save and after an unrelated save that rewrites
    /// the catalog again.
    func testASpecChangeStillReachesAnUnpinnedServedCrewAfterSaving() {
        let before = ServedCrew(crewId: "atlas", host: mini, displayName: "Atlas",
                                workingDirectory: "\(TestHost.homeRoot)/old", project: "old-project")
        let after = ServedCrew(crewId: "atlas", host: mini, displayName: "Atlas Renamed",
                               workingDirectory: "\(TestHost.homeRoot)/new", project: "new-project")
        var list = SessionRoster(configuration: configuration(rail: nil), servedCrews: [before])
        list.update("atlas") { $0.setPinned(false) }
        let unpinned = list.applied(to: configuration(rail: nil))
        XCTAssertNil(unpinned.catalog.first?.workingDirectory, "the spec's directory is not frozen locally")

        let resaved = SessionRoster(configuration: unpinned, servedCrews: [before]).applied(to: unpinned)
        XCTAssertEqual(resaved.catalog, unpinned.catalog, "an unrelated save writes the same sparse row")

        let rebuilt = SessionRoster(configuration: resaved, servedCrews: [after])
        XCTAssertEqual(rebuilt.entries.map(\.isPinned), [false])
        XCTAssertEqual(rebuilt.entries.first?.workingDirectory, "\(TestHost.homeRoot)/new")
        XCTAssertEqual(rebuilt.entries.first?.project, "new-project")
        XCTAssertEqual(rebuilt.entries.first?.displayName, "Atlas Renamed")
    }

    /// The operator's own edit to an unpinned served crew still persists.
    func testAnEditToAnUnpinnedServedCrewPersists() {
        let atlas = ServedCrew(crewId: "atlas", host: mini, displayName: "Atlas",
                               workingDirectory: "\(TestHost.homeRoot)/spec")
        var list = SessionRoster(configuration: configuration(rail: nil), servedCrews: [atlas])
        list.update("atlas") { $0.setPinned(false) }
        list.update("atlas") { $0.workingDirectory = "\(TestHost.homeRoot)/mine" }
        let saved = list.applied(to: configuration(rail: nil))
        XCTAssertEqual(saved.catalog.first?.workingDirectory, "\(TestHost.homeRoot)/mine")
    }

    /// `RosterEntry`'s own `subscript` is keyed by `ref`, not bare `id` — this
    /// is the one place in this file that needs it, since every fixture
    /// above is single-host.
    private var mini: SSHTarget { TestHost.target }

    private func configuration(rail: [Crew]?) -> ThemeConfiguration {
        var configuration = ThemeConfiguration.empty
        configuration.railSessions = rail
        return configuration
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

    // MARK: - The pinned list in rail draw order (CQ·188)

    /// The bug this exists to prevent: Settings › Sessions used to list the
    /// pinned block in whatever order `railSessions` happened to store it,
    /// so a group's members could land apart even though the rail always
    /// draws them as one contiguous block. `pinnedInRailOrder` must fold a
    /// group's members together exactly the way `RailNesting.drawOrderCrews`
    /// does, regardless of where storage interleaves an ungrouped crew
    /// between them.
    func testPinnedInRailOrderGroupsAGroupsMembersEvenWhenStorageInterleavesAnUngroupedCrew() {
        let group = CrewGroup(name: "Pair", members: ["alpha", "beta"], folded: false)
        let list = roster(rail: [Crew(id: "alpha", displayName: "Alpha"),
                                 Crew(id: "gamma", displayName: "Gamma"),
                                 Crew(id: "beta", displayName: "Beta")])
        let ordered = list.pinnedInRailOrder(groups: [group], hosts: [], defaultHost: nil)
        XCTAssertEqual(ordered.map(\.id), ["alpha", "beta", "gamma"],
                       "alpha and beta, the group's own members, should list together even though gamma "
                       + "sat between them in storage")
    }

    /// With no groups at all, the order is unchanged from storage — the
    /// common case, and the one every existing roster relies on.
    func testPinnedInRailOrderMatchesStorageWithNoGroups() {
        let list = roster(rail: [Crew(id: "c", displayName: "C"),
                                 Crew(id: "a", displayName: "A"),
                                 Crew(id: "b", displayName: "B")])
        XCTAssertEqual(list.pinnedInRailOrder(groups: [], hosts: [], defaultHost: nil).map(\.id),
                       ["c", "a", "b"])
    }

    /// A nested crew still lists, immediately after its own top-level
    /// parent — the same position `RailView.rowsContent` draws it in —
    /// rather than dropping out of the list entirely.
    func testPinnedInRailOrderKeepsANestedCrewAfterItsParent() {
        let list = roster(rail: [Crew(id: "child", displayName: "Child", parent: "parent"),
                                 Crew(id: "other", displayName: "Other"),
                                 Crew(id: "parent", displayName: "Parent")])
        XCTAssertEqual(list.pinnedInRailOrder(groups: [], hosts: [], defaultHost: nil).map(\.id),
                       ["other", "parent", "child"],
                       "parent is a top-level crew drawn where it sits; child, nested under it, "
                       + "follows immediately rather than staying at its own stored position")
    }

    /// A drag in Settings › Sessions reads its `source`/`destination` against
    /// the rail-draw-order list it shows, not `entries`' own storage order —
    /// dragging the group's block earlier must move BOTH members together.
    func testMoveRailAgainstADisplayOrderGroupsAGroupsMembers() {
        let group = CrewGroup(name: "Pair", members: ["alpha", "beta"], folded: false)
        var list = roster(rail: [Crew(id: "alpha", displayName: "Alpha"),
                                 Crew(id: "gamma", displayName: "Gamma"),
                                 Crew(id: "beta", displayName: "Beta")])
        let displayed = list.pinnedInRailOrder(groups: [group], hosts: [], defaultHost: nil)
        XCTAssertEqual(displayed.map(\.id), ["alpha", "beta", "gamma"], "precondition")

        // Drag gamma (display index 2) to the front (display index 0).
        list.moveRail(displayed, from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(list.entries.map(\.id), ["gamma", "alpha", "beta"])
    }

    /// An ungrouped crew still reorders normally through the same call.
    func testMoveRailAgainstADisplayOrderStillReordersAnUngroupedCrew() {
        var list = roster(rail: [Crew(id: "a", displayName: "A"),
                                 Crew(id: "b", displayName: "B"),
                                 Crew(id: "c", displayName: "C")])
        let displayed = list.pinnedInRailOrder(groups: [], hosts: [], defaultHost: nil)
        list.moveRail(displayed, from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(list.entries.map(\.id), ["c", "a", "b"])
    }
}
