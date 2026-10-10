import XCTest
@testable import Deck

/// "Remove from Deck" for a catalog (`START`) row — the second gap
/// `deck/specs/multiple-sessions-per-project` §"The rail" names: a way IN
/// (the "+ New" sheet, or a hand-edited config) with no way out.
/// `LauncherRow` had no context menu at all before this, so `nyh`,
/// `write-better` and `ask` could only be removed from Settings › Sessions.
/// Mirrors `RemovePinnedSessionTests`/`RemoveCrewTests` one section over.
final class RemoveCatalogEntryTests: XCTestCase {
    // MARK: - The confirm's copy

    func testMessageWithNoRunningSessionHasNoRunningSentence() {
        let message = ContentView.removeCatalogEntryMessage(isRunning: false)
        XCTAssertEqual(message, "This removes it from Settings › Sessions.")
        XCTAssertFalse(message.contains("running"))
    }

    func testMessageWithARunningSessionNamesItStillRunning() {
        let message = ContentView.removeCatalogEntryMessage(isRunning: true)
        XCTAssertTrue(message.contains("still running"), message)
        XCTAssertTrue(message.contains("Other Sessions"), message)
    }

    /// Unlike the crew/child Remove messages, this one never names "Remove
    /// and Stop" — a catalog entry owns no children to fuse a Stop into, so
    /// there is no such button for the copy to point at.
    func testMessageNeverMentionsRemoveAndStop() {
        XCTAssertFalse(ContentView.removeCatalogEntryMessage(isRunning: true).contains("Remove and Stop"))
        XCTAssertFalse(ContentView.removeCatalogEntryMessage(isRunning: false).contains("Remove and Stop"))
    }

    // MARK: - removeCatalogEntry writes config only, via SessionRoster

    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-removecatalog-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    /// Exercises the exact write path `LauncherRow`'s "Remove from Deck…"
    /// drives: `SessionRoster(configuration:)`, `.remove(_:)`,
    /// `store.setRoster(_:)` — the same one Settings › Sessions already
    /// uses, per the brief ("wiring a menu to an existing write path rather
    /// than a new one").
    @MainActor
    func testRemovesOnlyTheNamedCatalogEntry() throws {
        let store = ThemeStore(fileURL: url())
        var updated = store.configuration
        updated.catalog = [
            LaunchableSession(id: "nyh", displayName: "NYH Studio"),
            LaunchableSession(id: "write-better", displayName: "Write Better"),
            LaunchableSession(id: "ask", displayName: "Ask"),
        ]
        store.setRoster(SessionRoster(configuration: updated))

        var roster = SessionRoster(configuration: store.configuration)
        roster.remove("write-better")
        store.setRoster(roster)

        XCTAssertEqual(store.configuration.catalog.map(\.id).sorted(), ["ask", "nyh"])
    }

    /// The rail — `railSessions` — is untouched by a catalog-only removal.
    /// `addCrew` materializes the full shipped catalog before appending
    /// "ask" (see `ThemeStore.addCrew`), so this compares a snapshot rather
    /// than hardcoding that list.
    @MainActor
    func testLeavesTheRailUntouched() throws {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask"))
        var updated = store.configuration
        updated.catalog = [LaunchableSession(id: "nyh", displayName: "NYH Studio")]
        store.setRoster(SessionRoster(configuration: updated))
        let railBefore = store.configuration.railSessions

        var roster = SessionRoster(configuration: store.configuration)
        roster.remove("nyh")
        store.setRoster(roster)

        XCTAssertEqual(store.configuration.railSessions, railBefore)
        XCTAssertTrue(store.configuration.catalog.isEmpty)
    }
}
