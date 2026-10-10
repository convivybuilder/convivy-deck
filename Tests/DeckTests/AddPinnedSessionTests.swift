import XCTest
@testable import Deck

/// `ThemeStore.addPinnedSession` is what pins a sibling session into a
/// crew's config row — `ContentView.moveWindowToOwnSession` (a promoted
/// window survives as a normal pinned sibling) and `ContentView.adoptSession`
/// ("Adopt into <Crew>" on a discovered session) both still call it; the
/// "New session in <Crew>…" flow that used to be its third caller is gone
/// (issue_01M1Y9CXM1X86TCKF4XC3S227Y — crew and child creation now go
/// through the steward and the new-subcrew skill, not a Deck button).
final class AddPinnedSessionTests: XCTestCase {
    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-addpinned-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    /// "deck" — a real row on the rail — the same way every call site does
    /// it: the menu item only ever exists on a crew row that is already
    /// rendered, so the id it captures is always one the resolved rail
    /// actually has. `CrewCatalog.known` is empty
    /// (`deck/specs/running-deck-as-someone-else` §"The defaults name
    /// Convivy"), so the row is added explicitly rather than assumed shipped.
    @MainActor
    func testAppendsTheChildToItsCrewAndPersists() throws {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "deck", displayName: "Deck"))

        store.addPinnedSession(PinnedSession(name: "deck--research", displayName: "research"),
                               toCrew: SessionRef(host: nil, name: "deck"))

        let deck = try XCTUnwrap((store.configuration.railSessions ?? []).first { $0.id == "deck" })
        XCTAssertEqual(deck.sessions, [PinnedSession(name: "deck--research", displayName: "research")])
    }

    /// The rail is still unconfigured (no explicit `rail` key ever written)
    /// and `CrewCatalog.known` is empty, so there is no row for any crew id
    /// to append to — a genuine no-op, the same as `testAnUnknownCrewIdIsANoOp`.
    @MainActor
    func testUnconfiguredRailHasNoRowToAppendTo() {
        let store = ThemeStore(fileURL: url())
        XCTAssertNil(store.configuration.railSessions, "precondition: rail starts unconfigured")

        store.addPinnedSession(PinnedSession(name: "deck--scratch", displayName: "scratch"),
                               toCrew: SessionRef(host: nil, name: "deck"))

        XCTAssertNil(store.configuration.railSessions,
                     "an unconfigured, catalog-less rail has no crew row to append to")
    }

    @MainActor
    func testSecondChildAppendsRatherThanReplacingTheFirst() {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "deck", displayName: "Deck"))
        store.addPinnedSession(PinnedSession(name: "deck--research", displayName: "research"),
                               toCrew: SessionRef(host: nil, name: "deck"))
        store.addPinnedSession(PinnedSession(name: "deck--tax-2025", displayName: "tax-2025"),
                               toCrew: SessionRef(host: nil, name: "deck"))

        let names = (store.configuration.railSessions ?? [])
            .first { $0.id == "deck" }?.sessions.map(\.name)
        XCTAssertEqual(names, ["deck--research", "deck--tax-2025"])
    }

    /// A crew id matching no row is a no-op rather than a crash or a
    /// fabricated row — this should not arise from the UI, since the flow
    /// only ever offers the menu item on a real crew row, but a store
    /// method has to be safe against a stale caller regardless.
    @MainActor
    func testAnUnknownCrewIdIsANoOp() {
        let store = ThemeStore(fileURL: url())
        let before = store.configuration
        store.addPinnedSession(PinnedSession(name: "ghost--x", displayName: "x"),
                               toCrew: SessionRef(host: nil, name: "no-such-crew"))
        XCTAssertEqual(store.configuration, before)
    }
}
