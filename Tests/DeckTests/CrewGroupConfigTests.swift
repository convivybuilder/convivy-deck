import XCTest
@testable import Deck

/// `ThemeConfiguration.groups` — E24's storage half (CQ·183). Follows
/// `CrewRepoTests`'s pattern: write a fixture by hand, decode, and pin the
/// per-field degrade; then round-trip through `save`/`load` the way
/// `testRepoSurvivesSaveAndLoad` does for `repo`.
final class CrewGroupConfigTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-groups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - Decoding

    /// A file with no `groups` key at all loads exactly as it did before
    /// this field existed.
    func testAFileWithNoGroupsKeyLoadsAsToday() throws {
        let file = try write(#"{"rail": [{"session": "alpha"}]}"#)
        let config = ThemeConfiguration.load(from: file)
        XCTAssertEqual(config.groups, [])
        XCTAssertEqual(config.railSessions?.map(\.id), ["alpha"])
    }

    func testAGroupDecodesItsNameMembersAndFolded() throws {
        let file = try write(#"""
        {"rail": [{"session": "alpha", "host": "host-a"}, {"session": "beta", "host": "host-a"}],
         "groups": [{"name": "Rentals", "members": ["host-a|alpha", "host-a|beta"], "folded": true}]}
        """#)
        let config = ThemeConfiguration.load(from: file)
        XCTAssertEqual(config.groups, [
            CrewGroup(name: "Rentals", members: [SessionRef(host: "host-a", name: "alpha"),
                                            SessionRef(host: "host-a", name: "beta")], folded: true),
        ])
    }

    /// `folded` absent means open — a group written before that key
    /// existed, or one Settings never explicitly closed.
    func testFoldedAbsentMeansOpen() throws {
        let file = try write(#"{"groups": [{"name": "G", "members": ["|a"]}]}"#)
        let config = ThemeConfiguration.load(from: file)
        XCTAssertEqual(config.groups.first?.folded, false)
    }

    /// A row missing `name` is dropped outright — a heading with nothing
    /// to draw as its label.
    func testARowWithNoNameIsDropped() throws {
        let file = try write(#"{"groups": [{"members": ["|a"], "folded": true}]}"#)
        XCTAssertEqual(ThemeConfiguration.load(from: file).groups, [])
    }

    /// A member string that fails to parse (no `|`, or malformed) costs
    /// only itself, the same "field costs itself" degrade every list entry
    /// in this file gets — the group and its other members survive.
    func testAMalformedMemberIsDroppedButItsGroupSurvives() throws {
        let file = try write(#"{"groups": [{"name": "G", "members": ["|a", "no-pipe-at-all"], "folded": false}]}"#)
        let config = ThemeConfiguration.load(from: file)
        XCTAssertEqual(config.groups.first?.name, "G")
        XCTAssertEqual(config.groups.first?.members, [SessionRef(host: nil, name: "a")])
    }

    // MARK: - Round-trip

    func testGroupsSurviveSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "alpha", displayName: "Alpha", host: "host-a"),
                               Crew(id: "beta", displayName: "Beta", host: "host-a")]
        config.groups = [CrewGroup(name: "Rentals", members: [SessionRef(host: "host-a", name: "alpha"),
                                                          SessionRef(host: "host-a", name: "beta")],
                                   folded: true)]
        try config.save(to: file)

        let reloaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(reloaded.groups, config.groups)
    }

    /// Writing groups must not disturb the `rail` array it sits beside —
    /// the steward reads `rail` before bulk relaunches, so this key is
    /// load-bearing on its own.
    func testSavingGroupsLeavesTheRailArrayByteIdenticalOnReload() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        let rail = [Crew(id: "alpha", displayName: "Alpha", workingDirectory: "\(TestHost.homeRoot)/work/alpha",
                         host: "host-a"),
                   Crew(id: "beta", displayName: "Beta", host: "host-a")]
        config.railSessions = rail
        config.groups = [CrewGroup(name: "Rentals", members: [SessionRef(host: "host-a", name: "alpha")], folded: false)]
        try config.save(to: file)

        let reloaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(reloaded.railSessions, rail)
    }

    /// Omitted from the written file when empty — the same "a save
    /// triggered by something unrelated must not freeze an empty key in"
    /// rule `railArray`/`hostsArray` already follow.
    func testAnEmptyGroupsListWritesNoGroupsKey() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "alpha", displayName: "Alpha")]
        try config.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(root["groups"])
    }
}
