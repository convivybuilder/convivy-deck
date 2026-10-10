import XCTest
@testable import Deck

/// A real `theme.json` written before crews were scoped by host, read back by
/// the code that scopes them.
///
/// WHY A CAPTURED FILE RATHER THAN A HAND-WRITTEN ONE. The claim the epic's
/// definition of done makes is about an operator's actual settings opening
/// intact, and a hand-written sample proves it only for the shapes whoever
/// wrote the sample thought of. `Fixtures/theme-pre-host-scope.json` is a
/// real operator's `theme.json` from the day before this change, with the
/// account name and addresses swapped for placeholders: 16 rail rows, 7
/// catalog rows, 16 theme mappings, two `hosts` entries, a `defaultHost`,
/// three rows naming a host explicitly and thirteen naming none, and a mix
/// of `~`-relative and absolute `workdir`s. Nothing here depends on whose
/// file it was — every assertion reads the counts and values out of the
/// fixture itself where it can — but reading a real file's shape is what
/// makes a pass mean anything.
///
/// The fixture carries no credentials. Its `hosts` entries hold a username
/// and two placeholder addresses, which is what an operator's own hosts
/// table holds; there is no token, key or password in `theme.json` at all.
final class PreHostScopeConfigFixtureTests: XCTestCase {
    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "theme-pre-host-scope", withExtension: "json",
                              subdirectory: "Fixtures"),
            "the fixture must be in the test bundle — without it this whole file proves nothing")
        return try Data(contentsOf: url)
    }

    private func fixtureConfig() throws -> ThemeConfiguration {
        try XCTUnwrap(ThemeConfiguration.parse(try fixtureData()))
    }

    /// The counts the old file carries, read from the JSON rather than
    /// hardcoded, so the comparison is "everything survived" rather than
    /// "sixteen things survived".
    private struct Census: Equatable {
        var rail: Int
        var catalog: Int
        var themes: Int
        var pins: Int
        var hosts: Int
    }

    private func census(ofRawJSON data: Data) throws -> Census {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rail = (root["rail"] as? [[String: Any]]) ?? []
        let catalog = (root["catalog"] as? [[String: Any]]) ?? []
        let pins = (rail + catalog).reduce(0) { $0 + (($1["sessions"] as? [Any])?.count ?? 0) }
        return Census(rail: rail.count, catalog: catalog.count,
                      themes: ((root["sessions"] as? [String: String]) ?? [:]).count,
                      pins: pins, hosts: ((root["hosts"] as? [[String: Any]]) ?? []).count)
    }

    private func census(of config: ThemeConfiguration) -> Census {
        let rail = config.railSessions ?? []
        return Census(rail: rail.count, catalog: config.catalog.count,
               themes: config.sessions.count,
               pins: rail.reduce(0) { $0 + $1.sessions.count }
                   + config.catalog.reduce(0) { $0 + $1.sessions.count },
               hosts: config.hosts.count)
    }

    // MARK: - It opens intact

    func testNothingIsLostReadingTheOldFile() throws {
        let onDisk = try census(ofRawJSON: try fixtureData())
        XCTAssertEqual(census(of: try fixtureConfig()), onDisk)
        // The fixture has to be substantial for that equality to mean
        // anything: an empty file compares equal to an empty parse.
        XCTAssertGreaterThan(onDisk.rail, 10)
        XCTAssertGreaterThan(onDisk.catalog, 5)
        XCTAssertGreaterThan(onDisk.themes, 10)
        XCTAssertEqual(onDisk.hosts, 2)
    }

    /// The settings that are not per-crew come through untouched — the parse
    /// was reordered so hosts and the default host are read first, and this is
    /// what pins that nothing fell out of the reorder.
    func testTheRestOfTheFileIsUnaffected() throws {
        let config = try fixtureConfig()
        XCTAssertEqual(config.defaultHost, "macstudio")
        XCTAssertEqual(config.hosts.map(\.name), ["macstudio", "macmini"])
        XCTAssertEqual(config.appearancePreference, .system)
        XCTAssertEqual(config.sendKey, .returnKey)
        XCTAssertEqual(config.queueSortOrder, .arrival)
        XCTAssertEqual(config.typography.fontName, "Monaco")
        XCTAssertEqual(config.crewsRoot, "~")
    }

    /// Every crew now names a host: the three rows that said `macstudio`
    /// explicitly, and the thirteen that said nothing and take the default.
    func testEveryCrewAndCatalogRowNamesAHost() throws {
        let config = try fixtureConfig()
        let rail = config.railSessions ?? []
        XCTAssertFalse(rail.isEmpty)
        for crew in rail {
            XCTAssertEqual(crew.host, "macstudio", "crew \(crew.id) lost its host")
        }
        for entry in config.catalog {
            XCTAssertEqual(entry.host, "macstudio", "catalog row \(entry.id) lost its host")
        }
    }

    /// Every theme mapping moved to the default host, since every row in this
    /// file resolves there — and each one is still reachable through the
    /// resolution the rail actually calls, not only present in the map.
    func testEveryThemeMappingSurvivesUnderItsCrewsHost() throws {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try fixtureData()) as? [String: Any])
        let written = try XCTUnwrap(root["sessions"] as? [String: String])
        let config = try fixtureConfig()

        for (name, themeName) in written {
            let ref = SessionRef(host: "macstudio", name: name)
            XCTAssertEqual(config.sessions[ref], themeName, "\(name) lost its mapping")
            XCTAssertEqual(config.theme(forSession: ref).name, themeName,
                           "\(name) no longer resolves to the theme it was given")
        }
    }

    /// Spot checks by hand, so a bug that rewrote every key identically
    /// wrong would still be caught by something other than the loop above.
    func testTwoThemesAndOneCrewByHand() throws {
        let config = try fixtureConfig()
        XCTAssertEqual(config.sessions[SessionRef(host: "macstudio", name: "deck")], "gold")
        XCTAssertEqual(config.sessions[SessionRef(host: "macstudio", name: "steward")], "ember")

        let deck = try XCTUnwrap((config.railSessions ?? []).first { $0.id == "deck" })
        XCTAssertEqual(deck.displayName, "Deck")
        XCTAssertEqual(deck.project, "convivy-deck")
        XCTAssertEqual(deck.repos, ["convivy/convivy-deck"])
        XCTAssertEqual(deck.bead, "deck/bead/deck")
    }

    // MARK: - It round-trips in the new form

    func testSavingAndReloadingChangesNothingFurther() throws {
        let original = try fixtureConfig()
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-prehost-\(UUID().uuidString)")
            .appendingPathComponent("theme.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        try original.save(to: file)
        let reloaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(reloaded, original)

        // And again, so a first save that happened to normalise something is
        // told apart from one that keeps changing the file.
        try reloaded.save(to: file)
        XCTAssertEqual(ThemeConfiguration.load(from: file), original)
    }

    /// The saved file is in the new form: every crew carries `host`, and every
    /// theme key carries one. This is what makes the next launch read the same
    /// crews without consulting `defaultHost` at all.
    func testTheSavedFileIsWrittenInTheNewForm() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-prehost-\(UUID().uuidString)")
            .appendingPathComponent("theme.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try fixtureConfig().save(to: file)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for row in try XCTUnwrap(root["rail"] as? [[String: Any]]) {
            XCTAssertEqual(row["host"] as? String, "macstudio", "\(row["session"] ?? "?") wrote no host")
        }
        for row in try XCTUnwrap(root["catalog"] as? [[String: Any]]) {
            XCTAssertEqual(row["host"] as? String, "macstudio", "\(row["session"] ?? "?") wrote no host")
        }
        for key in try XCTUnwrap(root["sessions"] as? [String: String]).keys {
            XCTAssertTrue(key.hasPrefix("macstudio|"), "theme key \(key) is not host-qualified")
        }
    }

    /// Reading the file the NEW way twice must land in the same place as
    /// reading the old one once, which is the migration's whole claim: a crew
    /// keeps its identity when `defaultHost` later changes, because its host
    /// is written down rather than resolved afresh.
    func testACrewKeepsItsHostWhenTheDefaultLaterMoves() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-prehost-\(UUID().uuidString)")
            .appendingPathComponent("theme.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        var config = try fixtureConfig()
        config.defaultHost = "macmini"
        try config.save(to: file)

        let reloaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(reloaded.defaultHost, "macmini")
        for crew in reloaded.railSessions ?? [] {
            XCTAssertEqual(crew.host, "macstudio", "crew \(crew.id) followed the moved default")
        }
    }
}
