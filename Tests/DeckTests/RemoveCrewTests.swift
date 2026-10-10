import XCTest
@testable import Deck

/// "Remove from Deck" — see `deck/specs/multiple-sessions-per-project`
/// §"Remove". Two things are pinned here: the confirm's copy, including the
/// conditional running-sessions sentence at 0, 1 and 2+, and that
/// `ThemeStore.removeCrew` writes config only — the crew's row is
/// gone, its pinned children go with it (they are nested inside that same
/// row), and every OTHER row is untouched.
final class RemoveCrewTests: XCTestCase {
    // MARK: - The confirm's copy

    func testMessageWithNoRunningSessionsHasNoRunningSentence() {
        let message = ContentView.removeCrewMessage(runningSessionCount: 0)
        XCTAssertEqual(message,
            "This removes the rail entry only. The folder and its files are untouched.")
        XCTAssertFalse(message.contains("running"))
    }

    /// A crew whose host resolves names it, in place of Convivy's own
    /// machine — see `deck/specs/running-deck-as-someone-else`.
    func testMessageNamesTheResolvedHostWhenOneIsGiven() {
        let message = ContentView.removeCrewMessage(runningSessionCount: 0, hostLabel: "mini")
        XCTAssertEqual(message,
            "This removes the rail entry only. The folder on mini and its files are untouched.")
    }

    /// No configured host resolves: the location clause drops rather than
    /// naming a host that is not really there.
    func testMessageDropsTheLocationClauseWithNoHostLabel() {
        let message = ContentView.removeCrewMessage(runningSessionCount: 0, hostLabel: nil)
        XCTAssertEqual(message,
            "This removes the rail entry only. The folder and its files are untouched.")
    }

    /// Singular wording — "1 session IS", "if you want IT ended" — not the
    /// plural grammar the 2+ case uses. A message that reads "1 sessions are
    /// still running" is the bug this pins.
    func testMessageWithOneRunningSessionUsesSingularGrammar() {
        let message = ContentView.removeCrewMessage(runningSessionCount: 1)
        XCTAssertTrue(message.contains("1 session is still running"), message)
        XCTAssertTrue(message.contains("if you want it ended"), message)
        XCTAssertFalse(message.contains("sessions"), message)
    }

    func testMessageWithTwoRunningSessionsUsesPluralGrammar() {
        let message = ContentView.removeCrewMessage(runningSessionCount: 2)
        XCTAssertTrue(message.contains("2 sessions are still running"), message)
        XCTAssertTrue(message.contains("if you want them ended"), message)
    }

    /// Points at the "Remove and Stop" button — the mechanism that can
    /// actually end a running session from this alert — rather than the
    /// stale "use Stop first", which named a step outside the alert
    /// entirely.
    func testRunningSessionsSentencePointsAtRemoveAndStop() {
        XCTAssertTrue(ContentView.removeCrewMessage(runningSessionCount: 1)
            .contains("Remove and Stop"))
        XCTAssertTrue(ContentView.removeCrewMessage(runningSessionCount: 2)
            .contains("Remove and Stop"))
        XCTAssertFalse(ContentView.removeCrewMessage(runningSessionCount: 1)
            .contains("use Stop first"))
    }

    /// The example from the spec itself, verbatim modulo the leading
    /// sentence — pinned directly so a reformat of the boilerplate cannot
    /// drift from what was approved.
    func testMessageMatchesTheSpecExampleAtTwoSessions() {
        let message = ContentView.removeCrewMessage(runningSessionCount: 2)
        XCTAssertEqual(message,
            "This removes the rail entry only. The folder and its files are "
            + "untouched. 2 sessions are still running and will keep running; choose "
            + "Remove and Stop if you want them ended.")
    }

    func testMessageStillNamesTheFolderAsUntouchedEvenWithSessionsRunning() {
        let message = ContentView.removeCrewMessage(runningSessionCount: 3)
        XCTAssertTrue(message.contains("The folder and its files are untouched"))
    }

    // MARK: - removeCrew writes config only

    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-removecrew-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    @MainActor
    func testRemoveDropsOnlyTheNamedCrewRow() {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask"))

        store.removeCrew(SessionRef(host: nil, name: "ask"))

        XCTAssertNil(store.configuration.railSessions?.first { $0.id == "ask" })
    }

    /// EVERY OTHER ROW SURVIVES. `removeCrew` filters the rail rather
    /// than rebuilding it, so a sibling crew's own row, its own pinned
    /// children, and its own working directory are byte-for-byte unchanged
    /// by removing an unrelated crew.
    @MainActor
    func testRemoveLeavesEveryOtherCrewRowUntouched() {
        let store = ThemeStore(fileURL: url())
        // Neither id is in `CrewCatalog.known` — a crew the steward made
        // rather than one that happens to collide with a shipped
        // catalog row and gets silently skipped by `addCrew`'s own
        // duplicate guard.
        let nyh = Crew(id: "nyh", displayName: "NYH Studio", workingDirectory: "~/Convivy/nyh",
                       sessions: [PinnedSession(name: "nyh--research", displayName: "research")])
        store.addCrew(Crew(id: "ask", displayName: "Ask"))
        store.addCrew(nyh)

        store.removeCrew(SessionRef(host: nil, name: "ask"))

        XCTAssertEqual(store.configuration.railSessions?.first { $0.id == "nyh" }, nyh)
    }

    /// A crew's pinned children live NESTED inside its own row
    /// (`Crew.sessions`) — there is no separate config key for them — so
    /// removing the row is what drops them. This is the "sensible handling"
    /// the spec asks for: a child with no parent row left to draw under has
    /// nowhere on the rail to be, the same as an unconfigured session today.
    @MainActor
    func testRemovingACrewDropsItsPinnedChildrenWithIt() {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(
            id: "ask", displayName: "Ask",
            sessions: [PinnedSession(name: "ask--research", displayName: "research"),
                       PinnedSession(name: "ask--tax-2025", displayName: "tax-2025")]))

        store.removeCrew(SessionRef(host: nil, name: "ask"))

        // Not just absent from the removed row — there is no row left at
        // all for a child's name to be looked up against, which is what
        // "nowhere on the rail to be" means in practice.
        let allChildNames = (store.configuration.railSessions ?? []).flatMap { $0.sessions.map(\.name) }
        XCTAssertFalse(allChildNames.contains("ask--research"))
        XCTAssertFalse(allChildNames.contains("ask--tax-2025"))
    }

    /// Removing an id that is not on the rail is a no-op rather than a
    /// crash or an unrelated write — defence in depth against a stale
    /// caller, the same posture `addPinnedSession` takes for an unknown
    /// crew id.
    @MainActor
    func testRemovingAnUnknownIdIsANoOp() {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask"))
        let before = store.configuration

        store.removeCrew(SessionRef(host: nil, name: "no-such-crew"))

        XCTAssertEqual(store.configuration, before)
    }

    /// The purest form of the no-op: an UNCONFIGURED rail (`railSessions ==
    /// nil`) stays unconfigured after removing an id nothing has ever used —
    /// it must not materialize the shipped catalog into an explicit `rail`
    /// key just because a remove was attempted and found nothing.
    @MainActor
    func testRemovingFromAnUnconfiguredRailWritesNothing() {
        let store = ThemeStore(fileURL: url())
        XCTAssertNil(store.configuration.railSessions, "precondition: rail starts unconfigured")

        store.removeCrew(SessionRef(host: nil, name: "no-such-crew"))

        XCTAssertNil(store.configuration.railSessions)
    }
}
