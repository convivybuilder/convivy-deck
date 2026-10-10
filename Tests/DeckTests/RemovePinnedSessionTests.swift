import XCTest
@testable import Deck

/// "Remove from Deck" for a pinned sibling — the phase-1-through-4 gap:
/// `ThemeStore` had `addPinnedSession` and `removeCrew` but nothing that
/// took a child back out on its own. See
/// `deck/specs/multiple-sessions-per-project` §"Remove" and
/// `RemoveCrewTests`, whose crew-level cases this mirrors one level down.
final class RemovePinnedSessionTests: XCTestCase {
    // MARK: - The confirm's copy

    func testMessageWithNoRunningSessionHasNoRunningSentence() {
        let message = ContentView.removeChildMessage(isRunning: false)
        XCTAssertEqual(message,
            "This removes the rail entry only. The folder and its files are untouched.")
        XCTAssertFalse(message.contains("running"))
    }

    func testMessageWithARunningSessionNamesRemoveAndStop() {
        let message = ContentView.removeChildMessage(isRunning: true)
        XCTAssertTrue(message.contains("still running"), message)
        XCTAssertTrue(message.contains("Remove and Stop"), message)
    }

    func testMessageWithARunningSessionStillNamesTheFolderAsUntouched() {
        let message = ContentView.removeChildMessage(isRunning: true)
        XCTAssertTrue(message.contains("The folder and its files are untouched"))
    }

    /// A child's folder is its parent crew's, so a resolved host names it —
    /// see `RailRunningSessions.hostLabel(for:)`.
    func testMessageNamesTheResolvedHostWhenOneIsGiven() {
        let message = ContentView.removeChildMessage(isRunning: false, hostLabel: "mini")
        XCTAssertEqual(message,
            "This removes the rail entry only. The folder on mini and its files are untouched.")
    }

    // MARK: - removePinnedSession writes config only

    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-removepinned-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    @MainActor
    func testRemovesOnlyTheNamedChild() throws {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask"))
        store.addPinnedSession(PinnedSession(name: "ask--research", displayName: "research"), toCrew: SessionRef(host: nil, name: "ask"))
        store.addPinnedSession(PinnedSession(name: "ask--tax-2025", displayName: "tax-2025"), toCrew: SessionRef(host: nil, name: "ask"))

        store.removePinnedSession("ask--research", fromCrew: SessionRef(host: nil, name: "ask"))

        let ask = try XCTUnwrap((store.configuration.railSessions ?? []).first { $0.id == "ask" })
        XCTAssertEqual(ask.sessions.map(\.name), ["ask--tax-2025"])
    }

    /// The crew row itself, and every other crew's row, is untouched — the
    /// same guarantee `RemoveCrewTests` pins for `removeCrew`.
    @MainActor
    func testLeavesTheCrewRowAndEveryOtherCrewUntouched() throws {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask", workingDirectory: "~/Convivy/ask"))
        let nyh = Crew(id: "nyh", displayName: "NYH Studio")
        store.addCrew(nyh)
        store.addPinnedSession(PinnedSession(name: "ask--research", displayName: "research"), toCrew: SessionRef(host: nil, name: "ask"))

        store.removePinnedSession("ask--research", fromCrew: SessionRef(host: nil, name: "ask"))

        let ask = try XCTUnwrap((store.configuration.railSessions ?? []).first { $0.id == "ask" })
        XCTAssertEqual(ask.displayName, "Ask")
        XCTAssertEqual(ask.workingDirectory, "~/Convivy/ask")
        XCTAssertEqual(store.configuration.railSessions?.first { $0.id == "nyh" }, nyh)
    }

    /// A name that is not pinned on the named crew is a no-op — defence in
    /// depth against a stale caller, the same posture `removeCrew` and
    /// `addPinnedSession` take.
    @MainActor
    func testAnUnpinnedNameIsANoOp() {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask"))
        let before = store.configuration

        store.removePinnedSession("ask--nonexistent", fromCrew: SessionRef(host: nil, name: "ask"))

        XCTAssertEqual(store.configuration, before)
    }

    /// An unknown crew id is a no-op too.
    @MainActor
    func testAnUnknownCrewIdIsANoOp() {
        let store = ThemeStore(fileURL: url())
        let before = store.configuration

        store.removePinnedSession("ghost--x", fromCrew: SessionRef(host: nil, name: "no-such-crew"))

        XCTAssertEqual(store.configuration, before)
    }

    /// The purest form of the no-op: an unconfigured rail stays
    /// unconfigured, rather than materializing the shipped catalog for a
    /// removal that changed nothing.
    @MainActor
    func testRemovingFromAnUnconfiguredRailWritesNothing() {
        let store = ThemeStore(fileURL: url())
        XCTAssertNil(store.configuration.railSessions, "precondition: rail starts unconfigured")

        store.removePinnedSession("deck--scratch", fromCrew: SessionRef(host: nil, name: "deck"))

        XCTAssertNil(store.configuration.railSessions)
    }
}
