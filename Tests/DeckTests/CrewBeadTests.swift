import XCTest
@testable import Deck

/// `Crew.bead` — the Reference Room bead doc a crew's "Open bead" action
/// follows, picked in Settings › Sessions rather than derived from `project`.
/// Follows `CrewProjectTests`'s pattern exactly: decode with per-field
/// degrade, encode only when set, round-trip through save/load and through
/// pin/unpin.
final class CrewBeadTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-bead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testAFileWithNoBeadKeyDecodesToNil() throws {
        let file = try write(#"{"rail": [{"session": "vivy"}]}"#)
        XCTAssertNil(ThemeConfiguration.load(from: file).railSessions?.first?.bead)
    }

    func testARailRowsBeadDecodes() throws {
        let file = try write(#"{"rail": [{"session": "deck", "bead": "deck/bead/deck"}]}"#)
        XCTAssertEqual(ThemeConfiguration.load(from: file).railSessions?.first?.bead, "deck/bead/deck")
    }

    func testACatalogRowsBeadDecodes() throws {
        let file = try write(#"{"catalog": [{"session": "nyh", "bead": "selector/bead/selector"}]}"#)
        XCTAssertEqual(ThemeConfiguration.load(from: file).catalog.first?.bead, "selector/bead/selector")
    }

    /// A bead id shaped like shell injection costs the row its bead link, not
    /// its place on the rail — the same "field costs itself" pattern `host`
    /// and `project` already get, and load-bearing here specifically because
    /// a bead id reaches the viewer's `.kb(id:)` origin and, downstream, an
    /// unquoted remote URL (`WorkingCopyStore.libraryDocumentRemoteCommand`).
    func testARailRowWithAnInjectionShapedBeadKeepsTheRowButDropsTheBead() throws {
        let file = try write(#"{"rail": [{"session": "vivy", "bead": "$(rm -rf ~)"}]}"#)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(row.id, "vivy")
        XCTAssertNil(row.bead)
    }

    /// A bead id that isn't three slash-separated segments — the shape
    /// `DeckOpenRef.validateKBId` requires — is rejected the same way, even
    /// with no injection-shaped characters in it.
    func testARailRowWithAMalformedBeadShapeKeepsTheRowButDropsTheBead() throws {
        let file = try write(#"{"rail": [{"session": "vivy", "bead": "not-three-segments"}]}"#)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(row.id, "vivy")
        XCTAssertNil(row.bead)
    }

    func testBeadSurvivesSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "deck", displayName: "Deck", bead: "deck/bead/deck")]
        try config.save(to: file)

        let reloaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(reloaded.railSessions?.first?.bead, "deck/bead/deck")
    }

    /// A row with no bead must not grow the key on save, the same reasoning
    /// `CrewProjectTests.testAnUntouchedRowWritesNoProjectKey` pins for
    /// `project`.
    func testAnUntouchedRowWritesNoBeadKey() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "deck", displayName: "Deck")]
        try config.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rail = try XCTUnwrap(root["rail"] as? [[String: Any]])
        XCTAssertNil(rail.first?["bead"])
    }

    /// Unpinning a crew (rail → catalog) must not silently drop its bead —
    /// the same round trip `CrewProjectTests.testUnpinningACrewCarriesItsProjectToTheCatalog`
    /// pins for `project`.
    func testUnpinningACrewCarriesItsBeadToTheCatalog() {
        var roster = SessionRoster(entries: [
            RosterEntry(id: "deck", displayName: "Deck", isPinned: true, bead: "deck/bead/deck"),
        ])
        roster.update("deck") { $0.setPinned(false) }
        XCTAssertEqual(roster["deck"]?.bead, "deck/bead/deck")
        XCTAssertEqual(roster["deck"]?.asLaunchableSession.bead, "deck/bead/deck")
    }

    /// A crew with no bead set produces no bead link — the absent-rather-
    /// than-guessed posture `Crew.bead`'s doc comment promises, and the
    /// direct replacement for the old `selectedCrewBeadId()` heuristic that
    /// always produced a (sometimes wrong) guess.
    func testACrewWithNoBeadHasNoBeadLink() {
        let crew = Crew(id: "deck", displayName: "Deck", project: "convivy-deck")
        XCTAssertNil(crew.bead)
    }
}
