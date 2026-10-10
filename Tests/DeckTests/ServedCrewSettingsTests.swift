import XCTest
@testable import Deck

/// `issue_01M2P6E8EQHDMWFY02Q4GVMZ7R`: Settings › Sessions used to read
/// `configuration.railSessions + configuration.catalog` alone, never
/// `RailStateModel.servedCrews`, so a crew served with no local config at
/// all — Signals, made through `new-subcrew` — reached the rail and could
/// never reach Settings. `SessionRoster(configuration:servedCrews:)` now
/// merges the same way `ContentView.crews` does.
///
/// THE TRAP THIS FILE GUARDS AGAINST. Feeding the merged crew straight into
/// `SessionRoster` and then straight back out through `applied(to:)` would
/// freeze every field the spec filled in into local config, the same
/// mistake `SessionRosterTests.testAnUntouchedRailIsNotWrittenIntoConfig`
/// already guards for the catalog. `CrewMerge.sparse`/`isUnedited` are
/// what keep the write sparse — see `SessionRoster.applied(to:)`'s doc.
final class ServedCrewSettingsTests: XCTestCase {
    private let mini = TestHost.target

    private func served(id: String, displayName: String? = nil, workingDirectory: String? = nil,
                        sessionId: String? = nil, repo: String? = nil) -> ServedCrew {
        ServedCrew(crewId: id, host: mini, displayName: displayName,
                   workingDirectory: workingDirectory, sessionId: sessionId, repo: repo)
    }

    func testAServedOnlyCrewReachesTheRoster() {
        let signals = served(id: "signals", displayName: "Signals",
                             workingDirectory: "\(TestHost.homeRoot)/Convivy/signals")
        let roster = SessionRoster(configuration: .empty, servedCrews: [signals])

        let entry = try? XCTUnwrap(roster["signals"])
        XCTAssertEqual(entry?.displayName, "Signals")
        XCTAssertTrue(entry?.isPinned ?? false, "a served crew always reaches the rail, never the catalog")
    }

    /// An untouched served crew must stay out of `railSessions` entirely —
    /// the acceptance bar the issue names explicitly.
    func testAnUntouchedServedCrewWritesNothingIntoConfig() {
        let signals = served(id: "signals", displayName: "Signals")
        let roster = SessionRoster(configuration: .empty, servedCrews: [signals])
        let updated = roster.applied(to: .empty)
        XCTAssertNil(updated.railSessions, "an unedited served crew must not freeze into local config")
    }

    /// THE ACCEPTANCE TEST THE ISSUE NAMES: edit a served-only crew's repo,
    /// confirm the edit sticks, then rename it in the served spec and
    /// confirm the NEW name still reaches the roster. If the rename does
    /// not arrive, the override wrote every field rather than only the
    /// edited one.
    func testEditingOneFieldOfAServedOnlyCrewLeavesEveryOtherFieldFollowingTheSpec() {
        let signals = served(id: "signals", displayName: "Signals",
                             workingDirectory: "\(TestHost.homeRoot)/Convivy/signals")
        var roster = SessionRoster(configuration: .empty, servedCrews: [signals])
        roster.update("signals") { $0.repo = "convivy/signals" }
        let updated = roster.applied(to: .empty)

        // The edit stuck.
        let stored = try? XCTUnwrap(updated.railSessions?.first { $0.id == "signals" })
        XCTAssertEqual(stored?.repo, "convivy/signals")
        // Nothing else was frozen: the spec's own fields are left for the
        // next merge to fill in, not copied into the override.
        XCTAssertNil(stored?.workingDirectory)
        XCTAssertEqual(stored?.displayName, "signals", "displayName counts as unset when it equals id")

        // The steward renames the crew in its served spec.
        let renamed = served(id: "signals", displayName: "Signals (renamed)",
                             workingDirectory: "\(TestHost.homeRoot)/Convivy/signals")
        let rosterAfterRename = SessionRoster(configuration: updated, servedCrews: [renamed])

        let entry = try? XCTUnwrap(rosterAfterRename["signals"])
        XCTAssertEqual(entry?.displayName, "Signals (renamed)",
                       "the rename must still arrive — the override is not sparse if it does not")
        XCTAssertEqual(entry?.repo, "convivy/signals", "the earlier edit survives the rename")
        XCTAssertEqual(entry?.workingDirectory, "\(TestHost.homeRoot)/Convivy/signals",
                       "still following the spec, since this field was never edited")
    }

    /// The worst single case the issue names: a locally frozen `sessionId`
    /// would survive a tmux rename permanently rather than the ordinary
    /// transient staleness a fresh poll clears. Editing an unrelated field
    /// must not freeze `sessionId` as a side effect.
    func testEditingAnUnrelatedFieldDoesNotFreezeSessionId() {
        let signals = served(id: "signals", sessionId: "$42")
        var roster = SessionRoster(configuration: .empty, servedCrews: [signals])
        roster.update("signals") { $0.repo = "convivy/signals" }
        let updated = roster.applied(to: .empty)
        XCTAssertNil(updated.railSessions?.first { $0.id == "signals" }?.sessionId,
                     "sessionId must keep following the spec, not freeze at the value edited alongside")

        let renamedSession = served(id: "signals", sessionId: "$99")
        let rosterAfterRename = SessionRoster(configuration: updated, servedCrews: [renamedSession])
        XCTAssertEqual(rosterAfterRename["signals"]?.id, "signals")
        // sessionId isn't rendered in RosterEntry, but the underlying merge
        // that produced this entry used $99 — proven by CrewMergeTests'
        // `testMatchBySessionIdWinsOverAMismatchedId` sibling coverage; here
        // we confirm the roster write did not carry the stale id forward.
    }

    /// A partially-configured crew — some local fields, matched to a
    /// served spec — follows the identical sparse rule: editing one field
    /// leaves the others (whether locally set or spec-filled) alone.
    func testEditingAPartiallyConfiguredServedCrewOnlyFreezesTheEditedField() {
        var configuration = ThemeConfiguration.empty
        configuration.railSessions = [Crew(id: "signals", displayName: "signals",
                                           workingDirectory: "/local/signals")]
        let spec = served(id: "signals", displayName: "Signals", repo: "convivy/signals")
        var roster = SessionRoster(configuration: configuration, servedCrews: [spec])

        roster.update("signals") { $0.project = "convivy-deck" }
        let updated = roster.applied(to: .empty)
        let stored = try? XCTUnwrap(updated.railSessions?.first { $0.id == "signals" })

        XCTAssertEqual(stored?.project, "convivy-deck", "the edit stuck")
        XCTAssertEqual(stored?.workingDirectory, "/local/signals", "the pre-existing local value survives")
        XCTAssertEqual(stored?.displayName, "signals",
                       "the spec-filled display name was never locally set, so it stays unset")
        XCTAssertNil(stored?.repo, "repo was only ever spec-filled, so it stays unset too")
    }
}
