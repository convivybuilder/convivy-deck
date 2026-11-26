import XCTest
@testable import Deck

/// `Crew.servedTheme` — a crew's colour, per the host's own spec
/// (agent-platform#1212, `platform/contracts/session-agent-api`'s `crews`
/// section, `theme` row). Server-owned: there is no local override, no
/// `theme.json` key, and no Settings control for this field, unlike
/// `project`/`bead`/`shape` — see `Crew.servedTheme`'s own doc for why it
/// still rides the same `ServedCrew`/`CrewMerge` pipeline as those fields.
final class CrewServedThemeTests: XCTestCase {
    private let mini = TestHost.target
    private let miniHosts = [HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)]

    private func served(id: String, displayName: String? = nil, theme: String? = nil) -> ServedCrew {
        ServedCrew(crewId: id, host: mini, displayName: displayName, theme: theme)
    }

    private func merge(configured: [Crew], served: [ServedCrew]) -> [Crew] {
        CrewMerge.merge(configured: configured, served: served, hosts: miniHosts, defaultHost: "mini")
    }

    // MARK: - decode (ServedCrew.decode)

    func testAValidCatalogNameDecodes() {
        let rows = ServedCrew.decode(Data(#"{"crews": [{"id": "deck", "theme": "gold"}]}"#.utf8), host: mini)
        XCTAssertEqual(rows.first?.theme, "gold")
    }

    func testAnUnknownNameDecodesToNilButKeepsTheRow() {
        let rows = ServedCrew.decode(Data(#"{"crews": [{"id": "deck", "theme": "chartreuse"}]}"#.utf8), host: mini)
        XCTAssertEqual(rows.first?.crewId, "deck")
        XCTAssertNil(rows.first?.theme)
    }

    /// The contract is explicit that case matters: "the spec's value when
    /// it equals one of them exactly, case included".
    func testTheWrongCaseDecodesToNil() {
        let rows = ServedCrew.decode(Data(#"{"crews": [{"id": "deck", "theme": "Gold"}]}"#.utf8), host: mini)
        XCTAssertNil(rows.first?.theme)
    }

    func testANonStringValueDecodesToNil() {
        let rows = ServedCrew.decode(Data(#"{"crews": [{"id": "deck", "theme": 7}]}"#.utf8), host: mini)
        XCTAssertEqual(rows.first?.crewId, "deck")
        XCTAssertNil(rows.first?.theme)
    }

    func testAnAbsentKeyDecodesToNil() {
        let rows = ServedCrew.decode(Data(#"{"crews": [{"id": "deck"}]}"#.utf8), host: mini)
        XCTAssertNil(rows.first?.theme)
    }

    // MARK: - merge (CrewMerge carries it onto Crew)

    func testAServedOnlyCrewCarriesItsTheme() {
        let merged = merge(configured: [], served: [served(id: "deck", theme: "gold")])
        XCTAssertEqual(merged.first?.servedTheme, "gold")
    }

    func testAPurelyLocalCrewHasNoServedTheme() {
        let merged = merge(configured: [Crew(id: "legacy", displayName: "Legacy")], served: [])
        XCTAssertNil(merged.first?.servedTheme)
    }

    func testAMatchedConfiguredCrewPicksUpTheSpecsTheme() {
        let configured = Crew(id: "deck", displayName: "My Deck")
        let merged = merge(configured: [configured], served: [served(id: "deck", theme: "azure")])
        XCTAssertEqual(merged.first?.servedTheme, "azure")
    }

    /// Unlike `project`/`bead`, there is no local value this could ever
    /// defer to — the spec's value always applies once matched, the same
    /// way `sessionId` does.
    func testAnUnknownSpecThemeNameMergesAsNoServedTheme() {
        let configured = Crew(id: "deck", displayName: "My Deck")
        let merged = merge(configured: [configured], served: [served(id: "deck", theme: nil)])
        XCTAssertNil(merged.first?.servedTheme)
    }

    // MARK: - sparse never lets it survive into what persists

    func testSparseAlwaysClearsServedTheme() {
        let spec = served(id: "deck", displayName: "Deck", theme: "gold")
        let merged = merge(configured: [], served: [spec]).first!
        XCTAssertEqual(merged.servedTheme, "gold", "merge did carry it, or this test proves nothing")
        let sparse = CrewMerge.sparse(merged, relativeTo: spec, hosts: miniHosts)
        XCTAssertNil(sparse.servedTheme)
    }

    /// A served theme alone must never make an otherwise-untouched row read
    /// as edited — `isUnedited` is what `SessionRoster.applied(to:)` relies
    /// on to leave such a row out of `railSessions` entirely.
    func testAServedThemeAloneDoesNotMakeAnUneditedRowReadAsEdited() {
        let spec = served(id: "deck", displayName: "Deck", theme: "gold")
        let merged = merge(configured: [], served: [spec]).first!
        let sparse = CrewMerge.sparse(merged, relativeTo: spec, hosts: miniHosts)
        XCTAssertTrue(CrewMerge.isUnedited(sparse))
    }

    // MARK: - never written to theme.json (ThemeStore.commit)

    private func write(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-served-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    /// Even a `Crew` that somehow reached disk carrying a `servedTheme` —
    /// never possible through the merge/sparse path above, but pinned here
    /// directly against `save()` itself — must not grow a `theme` key: the
    /// row dictionary `railArray` builds never reads this field at all.
    func testSaveNeverWritesAThemeKeyEvenWhenServedThemeIsSet() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "deck", displayName: "Deck", servedTheme: "gold")]
        try config.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rail = try XCTUnwrap(root["rail"] as? [[String: Any]])
        XCTAssertNil(rail.first?["theme"])
    }

    /// The realistic path: a served-only crew with a theme, edited once on
    /// an unrelated field through `ThemeStore`, must still never write a
    /// `theme` key — the same sparse discipline `ServedCrewSettingsTests`
    /// pins for `repo`/`sessionId`.
    @MainActor
    func testThemeStoreCommitNeverPersistsAServedTheme() throws {
        let file = try write("{}")
        let store = ThemeStore(fileURL: file, railDefaults: UserDefaults(suiteName: #function)!)
        var roster = SessionRoster(configuration: .empty, servedCrews: [served(id: "deck", theme: "gold")])
        roster.update(SessionRef(host: nil, name: "deck")) { $0.repo = "convivy/convivy-deck" }
        store.setRoster(roster)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rail = try XCTUnwrap(root["rail"] as? [[String: Any]])
        let row = try XCTUnwrap(rail.first { $0["session"] as? String == "deck" })
        XCTAssertNil(row["theme"])
        XCTAssertEqual(row["repos"] as? [String], ["convivy/convivy-deck"], "the real edit still survives")
    }

    // MARK: - ThemeConfiguration.theme(forSession:fallbackParent:servedTheme:) precedence

    private let deck = SessionRef(host: nil, name: "deck")
    private let ask = SessionRef(host: nil, name: "ask")
    private let askChild = SessionRef(host: nil, name: "ask--research")

    /// An explicit pick in `theme.json`'s `sessions` map outranks a served
    /// theme — "Deck takes it after a pick ... and before its name-hash
    /// default" (the contract's own wording for this field).
    func testAnExplicitPickBeatsAServedTheme() {
        let config = ThemeConfiguration(
            sessions: [deck: "rose"], appearancePreference: .system, typography: .default)
        let theme = config.theme(forSession: deck, servedTheme: { _ in "gold" })
        XCTAssertEqual(theme.name, "rose")
    }

    /// With no pick, the served theme wins over the hashed default.
    /// `"deck"` itself hashes to `"gold"` (pinned by
    /// `testWithNoPickAndNoServedThemeTheHashedDefaultApplies` below), so
    /// this uses a different name to prove the served value actually won
    /// rather than coinciding with the hash.
    func testAServedThemeBeatsTheHashedDefault() {
        let config = ThemeConfiguration.empty
        let theme = config.theme(forSession: deck, servedTheme: { _ in "azure" })
        XCTAssertEqual(theme.name, "azure")
    }

    /// With neither a pick nor a served theme, resolution is exactly the
    /// hashed default — the pre-existing behaviour, unchanged.
    func testWithNoPickAndNoServedThemeTheHashedDefaultApplies() {
        let config = ThemeConfiguration.empty
        XCTAssertEqual(config.theme(forSession: deck).name,
                       ThemeCatalog.defaultTheme(forSession: deck.name).name)
    }

    /// A child with no pick of its own, and no served theme of its own
    /// (children never carry one — only crews do), inherits its PARENT
    /// crew's served theme through the `fallbackParent` recursion — this is
    /// the mechanism `ContentView.resolvedTheme` wires `crews` into live.
    func testAChildWithNoPickInheritsItsParentsServedTheme() {
        let config = ThemeConfiguration.empty
        let servedTheme: (SessionRef) -> String? = { ref in ref == self.ask ? "gold" : nil }
        let childTheme = config.theme(forSession: askChild, fallbackParent: ask, servedTheme: servedTheme)
        let parentTheme = config.theme(forSession: ask, servedTheme: servedTheme)
        XCTAssertEqual(childTheme.name, "gold")
        XCTAssertEqual(childTheme.name, parentTheme.name)
    }

    /// An explicit pick on the child still wins over the parent's served
    /// theme — inheritance is only the fallback for a child with none of
    /// its own, the same rule `PinnedSessionConfigTests
    /// .testAChildsOwnMappingBeatsItsParentsFallback` pins for an explicit
    /// parent mapping.
    func testAChildsOwnPickBeatsItsParentsServedTheme() {
        let config = ThemeConfiguration(
            sessions: [askChild: "rose"], appearancePreference: .system, typography: .default)
        let servedTheme: (SessionRef) -> String? = { ref in ref == self.ask ? "gold" : nil }
        let childTheme = config.theme(forSession: askChild, fallbackParent: ask, servedTheme: servedTheme)
        XCTAssertEqual(childTheme.name, "rose")
    }
}
