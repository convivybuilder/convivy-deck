import XCTest
@testable import Deck

/// `Crew.project` — the Library product a crew's cockpit reads. Follows
/// `HostConfigTests`'s pattern exactly, since `project` is deliberately the
/// same shape as `host`: decode with per-field degrade, encode only when
/// set, round-trip through save/load.
final class CrewProjectTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testAFileWithNoProjectKeyDecodesToNil() throws {
        let file = try write(#"{"rail": [{"session": "vivy"}]}"#)
        XCTAssertNil(ThemeConfiguration.load(from: file).railSessions?.first?.project)
    }

    func testARailRowsProjectDecodes() throws {
        let file = try write(#"{"rail": [{"session": "deck", "project": "convivy-deck"}]}"#)
        XCTAssertEqual(ThemeConfiguration.load(from: file).railSessions?.first?.project, "convivy-deck")
    }

    func testACatalogRowsProjectDecodes() throws {
        let file = try write(#"{"catalog": [{"session": "nyh", "project": "selector"}]}"#)
        XCTAssertEqual(ThemeConfiguration.load(from: file).catalog.first?.project, "selector")
    }

    /// A project name shaped like shell injection costs the row its cockpit,
    /// not its place on the rail — the same "field costs itself" pattern
    /// `host` already gets, and load-bearing here specifically because
    /// `project` reaches an unquoted remote URL (`LibraryClient`).
    func testARailRowWithAnInjectionShapedProjectKeepsTheRowButDropsTheProject() throws {
        let file = try write(#"{"rail": [{"session": "vivy", "project": "$(rm -rf ~)"}]}"#)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(row.id, "vivy")
        XCTAssertNil(row.project)
    }

    func testProjectSurvivesSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "deck", displayName: "Deck", project: "convivy-deck")]
        try config.save(to: file)

        let reloaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(reloaded.railSessions?.first?.project, "convivy-deck")
    }

    /// A row with no project must not grow the key on save, the same
    /// reasoning `HostConfigTests.testAnUntouchedRowWritesNoHostKey` pins
    /// for `host`.
    func testAnUntouchedRowWritesNoProjectKey() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "deck", displayName: "Deck")]
        try config.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rail = try XCTUnwrap(root["rail"] as? [[String: Any]])
        XCTAssertNil(rail.first?["project"])
    }

    /// Unpinning a crew (rail → catalog) must not silently drop its project
    /// — the same round trip `RosterEntry.setPinned`'s doc promises `host`.
    func testUnpinningACrewCarriesItsProjectToTheCatalog() {
        var roster = SessionRoster(entries: [
            RosterEntry(id: "deck", displayName: "Deck", isPinned: true, project: "convivy-deck"),
        ])
        roster.update("deck") { $0.setPinned(false) }
        XCTAssertEqual(roster["deck"]?.project, "convivy-deck")
        XCTAssertEqual(roster["deck"]?.asLaunchableSession.project, "convivy-deck")
    }
}
