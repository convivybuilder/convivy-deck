import XCTest
@testable import Deck

/// `ThemeStore.setParent` is what "Nest under…" and "Move to Top Level"
/// commit — see `RailRow`'s context menu and
/// `deck/specs/multiple-sessions-per-project` §"Setting a parent is a UI
/// act": config is storage, never the interface.
final class SetCrewParentTests: XCTestCase {
    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-setparent-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    @MainActor
    func testNestingWritesTheParentIdOntoTheChosenRow() throws {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask"))

        store.setParent("vivy", forCrew: SessionRef(host: nil, name: "ask"))

        let ask = try XCTUnwrap((store.configuration.railSessions ?? []).first { $0.id == "ask" })
        XCTAssertEqual(ask.parent, "vivy")
    }

    /// "Move to Top Level" is the same call with `nil` — it clears the
    /// field rather than needing a second method.
    @MainActor
    func testMoveToTopLevelClearsAnExistingParent() throws {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask", parent: "vivy"))

        store.setParent(nil, forCrew: SessionRef(host: nil, name: "ask"))

        let ask = try XCTUnwrap((store.configuration.railSessions ?? []).first { $0.id == "ask" })
        XCTAssertNil(ask.parent)
    }

    /// Every other row is untouched — the same guarantee `RemoveCrewTests`
    /// pins for `removeCrew`.
    @MainActor
    func testEveryOtherCrewRowIsUntouched() throws {
        let store = ThemeStore(fileURL: url())
        let vivy = Crew(id: "vivy", displayName: "Vivy")
        store.addCrew(vivy)
        store.addCrew(Crew(id: "ask", displayName: "Ask"))

        store.setParent("vivy", forCrew: SessionRef(host: nil, name: "ask"))

        XCTAssertEqual(store.configuration.railSessions?.first { $0.id == "vivy" }, vivy)
    }

    /// The rail is still unconfigured (no explicit `rail` key ever written)
    /// and `CrewCatalog.known` is empty
    /// (`deck/specs/running-deck-as-someone-else` §"The defaults name
    /// Convivy"), so there is no "deck" row to set a parent on — a genuine
    /// no-op, the same as `testAnUnknownCrewIdIsANoOp`.
    @MainActor
    func testUnconfiguredRailHasNoRowToSetAParentOn() {
        let store = ThemeStore(fileURL: url())
        XCTAssertNil(store.configuration.railSessions, "precondition: rail starts unconfigured")

        store.setParent("vivy", forCrew: SessionRef(host: nil, name: "deck"))

        XCTAssertNil(store.configuration.railSessions,
                     "an unconfigured, catalog-less rail has no crew row to set a parent on")
    }

    /// A crew id matching no row is a no-op — the menu only ever offers
    /// this on a real crew row, but the store method stays safe against a
    /// stale caller regardless, the same posture `addPinnedSession` takes.
    @MainActor
    func testAnUnknownCrewIdIsANoOp() {
        let store = ThemeStore(fileURL: url())
        let before = store.configuration
        store.setParent("vivy", forCrew: SessionRef(host: nil, name: "no-such-crew"))
        XCTAssertEqual(store.configuration, before)
    }
}
