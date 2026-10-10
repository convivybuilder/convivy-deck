import XCTest
@testable import Deck

/// `Crew.shape`/`Crew.documents` — the steward-board proposal's phase A
/// fields (`agent-runs/2026-09-09/run-83743d3c/proposal.md`, contract item
/// 4, deliberately undocumented in `platform/contracts/session-agent-api`
/// as of this field's introduction). Follows `CrewProjectTests`'s pattern
/// exactly, since both are the same shape as `project`/`bead`: decode with
/// per-field degrade, encode only when set, round-trip through save/load
/// and through pin/unpin.
final class CrewShapeAndDocumentsTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-shape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - decode

    func testAFileWithNoShapeOrDocumentsKeyDecodesToUnset() throws {
        let file = try write(#"{"rail": [{"session": "steward"}]}"#)
        let row = ThemeConfiguration.load(from: file).railSessions?.first
        XCTAssertNil(row?.shape)
        XCTAssertEqual(row?.documents, [])
    }

    func testARailRowsShapeAndDocumentsDecode() throws {
        let file = try write("""
        {"rail": [{"session": "steward", "shape": "board", "documents": ["backlog.md", "CLAUDE.md"]}]}
        """)
        let row = ThemeConfiguration.load(from: file).railSessions?.first
        XCTAssertEqual(row?.shape, "board")
        XCTAssertEqual(row?.documents, ["backlog.md", "CLAUDE.md"])
    }

    func testACatalogRowsShapeAndDocumentsDecode() throws {
        let file = try write("""
        {"catalog": [{"session": "ask", "shape": "service", "documents": ["notes.md"]}]}
        """)
        let row = ThemeConfiguration.load(from: file).catalog.first
        XCTAssertEqual(row?.shape, "service")
        XCTAssertEqual(row?.documents, ["notes.md"])
    }

    // MARK: - round trip

    func testShapeAndDocumentsSurviveSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [
            Crew(id: "steward", displayName: "Steward", shape: "board", documents: ["backlog.md"]),
        ]
        try config.save(to: file)

        let reloaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(reloaded.railSessions?.first?.shape, "board")
        XCTAssertEqual(reloaded.railSessions?.first?.documents, ["backlog.md"])
    }

    /// A row with neither field set must not grow either key on save — the
    /// same reasoning `CrewProjectTests.testAnUntouchedRowWritesNoProjectKey`
    /// pins for `project`.
    func testAnUntouchedRowWritesNeitherKey() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "steward", displayName: "Steward")]
        try config.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rail = try XCTUnwrap(root["rail"] as? [[String: Any]])
        XCTAssertNil(rail.first?["shape"])
        XCTAssertNil(rail.first?["documents"])
    }

    /// Unpinning a crew (rail → catalog) must not silently drop `shape`/
    /// `documents` — the same round trip `RosterEntry.setPinned`'s doc
    /// promises `project`/`bead`.
    func testUnpinningACrewCarriesItsShapeAndDocumentsToTheCatalog() {
        var roster = SessionRoster(entries: [
            RosterEntry(id: "steward", displayName: "Steward", isPinned: true,
                        shape: "board", documents: ["backlog.md"]),
        ])
        roster.update("steward") { $0.setPinned(false) }
        XCTAssertEqual(roster["steward"]?.shape, "board")
        XCTAssertEqual(roster["steward"]?.documents, ["backlog.md"])
        XCTAssertEqual(roster["steward"]?.asLaunchableSession.shape, "board")
        XCTAssertEqual(roster["steward"]?.asLaunchableSession.documents, ["backlog.md"])
    }
}
