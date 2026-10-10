import XCTest
@testable import Deck

/// `Crew.repo` — the GitHub `owner/repo` the cockpit's Pull Requests panel
/// reads. Follows `CrewProjectTests`'s pattern exactly, since `repo` is
/// deliberately the same shape as `project`/`bead`: decode with per-field
/// degrade (both segments validated via `LibraryClient.validateRepoIdentity`),
/// encode only when set, round-trip through save/load and through pin/unpin.
final class CrewRepoTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testAFileWithNoRepoKeyDecodesToNil() throws {
        let file = try write(#"{"rail": [{"session": "vivy"}]}"#)
        XCTAssertNil(ThemeConfiguration.load(from: file).railSessions?.first?.repo)
    }

    func testARailRowsRepoDecodes() throws {
        let file = try write(#"{"rail": [{"session": "deck", "repo": "convivy/convivy-deck"}]}"#)
        XCTAssertEqual(ThemeConfiguration.load(from: file).railSessions?.first?.repo, "convivy/convivy-deck")
    }

    func testACatalogRowsRepoDecodes() throws {
        let file = try write(#"{"catalog": [{"session": "nyh", "repo": "convivy/vivy"}]}"#)
        XCTAssertEqual(ThemeConfiguration.load(from: file).catalog.first?.repo, "convivy/vivy")
    }

    /// A repo missing the slash costs the row its Pull Requests panel, not
    /// its place on the rail — the same "field costs itself" pattern
    /// `project`/`host` already get.
    func testARailRowWithNoSlashKeepsTheRowButDropsTheRepo() throws {
        let file = try write(#"{"rail": [{"session": "vivy", "repo": "convivy-deck"}]}"#)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(row.id, "vivy")
        XCTAssertNil(row.repo)
    }

    /// A repo shaped like shell injection costs the row its Pull Requests
    /// panel, not its place on the rail — load-bearing here specifically
    /// because `repo` reaches an unquoted remote URL (`PRLadder.fetchLadder`).
    func testARailRowWithAnInjectionShapedRepoKeepsTheRowButDropsTheRepo() throws {
        let file = try write(#"{"rail": [{"session": "vivy", "repo": "convivy/deck; rm -rf ~"}]}"#)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(row.id, "vivy")
        XCTAssertNil(row.repo)
    }

    /// An empty segment on either side of the slash is dropped the same way.
    func testARailRowWithAnEmptySegmentDropsTheRepo() throws {
        let file = try write(#"{"rail": [{"session": "vivy", "repo": "convivy/"}]}"#)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertNil(row.repo)
    }

    func testRepoSurvivesSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "deck", displayName: "Deck", repo: "convivy/convivy-deck")]
        try config.save(to: file)

        let reloaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(reloaded.railSessions?.first?.repo, "convivy/convivy-deck")
    }

    /// A row with no repo must not grow the key on save, the same reasoning
    /// `CrewProjectTests.testAnUntouchedRowWritesNoProjectKey` pins.
    func testAnUntouchedRowWritesNoRepoKey() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "deck", displayName: "Deck")]
        try config.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rail = try XCTUnwrap(root["rail"] as? [[String: Any]])
        XCTAssertNil(rail.first?["repo"])
    }

    /// Unpinning a crew (rail → catalog) must not silently drop its repo —
    /// the same round trip `CrewProjectTests.testUnpinningACrewCarriesItsProjectToTheCatalog`
    /// pins for `project`.
    func testUnpinningACrewCarriesItsRepoToTheCatalog() {
        var roster = SessionRoster(entries: [
            RosterEntry(id: "deck", displayName: "Deck", isPinned: true, repo: "convivy/convivy-deck"),
        ])
        roster.update("deck") { $0.setPinned(false) }
        XCTAssertEqual(roster["deck"]?.repo, "convivy/convivy-deck")
        XCTAssertEqual(roster["deck"]?.asLaunchableSession.repo, "convivy/convivy-deck")
    }

    // MARK: - LibraryClient.validateRepoIdentity

    func testValidateRepoIdentityAcceptsTwoValidSegments() {
        let parsed = LibraryClient.validateRepoIdentity("convivy/convivy-deck")
        XCTAssertEqual(parsed?.owner, "convivy")
        XCTAssertEqual(parsed?.repoName, "convivy-deck")
    }

    func testValidateRepoIdentityRejectsMissingSlash() {
        XCTAssertNil(LibraryClient.validateRepoIdentity("convivy-deck"))
    }

    func testValidateRepoIdentityRejectsAThirdSegment() {
        XCTAssertNil(LibraryClient.validateRepoIdentity("convivy/convivy-deck/extra"))
    }

    func testValidateRepoIdentityRejectsAnEmptySegment() {
        XCTAssertNil(LibraryClient.validateRepoIdentity("convivy/"))
        XCTAssertNil(LibraryClient.validateRepoIdentity("/convivy-deck"))
    }

    func testValidateRepoIdentityRejectsShellCharacters() {
        XCTAssertNil(LibraryClient.validateRepoIdentity("convivy/deck; rm -rf /"))
    }
}
