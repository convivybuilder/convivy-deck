import XCTest
@testable import Deck

/// Phase 1 of the multiple-sessions design (see
/// `design-multiple-sessions.md` §A): `Crew.sessions` (pinned siblings)
/// and `Crew.parent` (decoded and round-tripped, not yet rendered) as
/// config fields. "Migration costs nothing" is the property under test
/// throughout — an old `theme.json` with neither key must parse exactly as
/// it did before either existed.
final class PinnedSessionConfigTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-pinned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - Migration costs nothing

    func testAFileWithNeitherKeyDecodesToEmptySessionsAndNilParent() throws {
        let file = try write("""
        {"rail": [{"session": "ask"}]}
        """)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(row.sessions, [])
        XCTAssertNil(row.parent)
    }

    /// `CrewCatalog.known` no longer ships `vivy-commercial` or any other
    /// row — it is empty (`deck/specs/running-deck-as-someone-else` §"The
    /// defaults name Convivy") — so an empty file's rail fallback has no
    /// rows to default at all.
    func testAnEmptyFileHasNoRailAndNoCatalogFallbackRows() throws {
        let file = try write("{}")
        XCTAssertNil(ThemeConfiguration.load(from: file).railSessions)
        XCTAssertTrue(CrewCatalog.known.isEmpty)
    }

    // MARK: - Reading `sessions`

    func testPinnedChildrenAreParsedInOrder() throws {
        let file = try write("""
        {"rail": [{"session": "ask", "sessions": [
            {"name": "ask--research", "displayName": "research"},
            {"name": "ask--tax-2025", "displayName": "tax-2025"}
        ]}]}
        """)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(row.sessions.map(\.name), ["ask--research", "ask--tax-2025"])
        XCTAssertEqual(row.sessions.map(\.displayName), ["research", "tax-2025"])
    }

    /// A child's `displayName` is optional, the same as a rail row's `name` —
    /// absent falls back to the session name itself.
    func testAPinnedChildWithNoDisplayNameFallsBackToItsSessionName() throws {
        let file = try write("""
        {"rail": [{"session": "ask", "sessions": [{"name": "ask--research"}]}]}
        """)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(row.sessions.first?.displayName, "ask--research")
    }

    /// A malformed child's name costs THAT CHILD its place, not the whole
    /// row — the same per-row degradation `parseRail` itself already gives a
    /// bad top-level session name.
    func testAChildWithAnUnusableNameIsDroppedNotTheWholeRow() throws {
        let file = try write("""
        {"rail": [{"session": "ask", "sessions": [
            {"name": "ask research; rm -rf /"},
            {"name": "ask--research"}
        ]}]}
        """)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(row.sessions.map(\.name), ["ask--research"])
    }

    // MARK: - Reading `parent`

    func testParentIsDecodedButUnrelatedToRendering() throws {
        let file = try write("""
        {"rail": [{"session": "vivy"}, {"session": "vivy-commercial", "parent": "vivy"}]}
        """)
        let rail = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions)
        XCTAssertEqual(rail.first { $0.id == "vivy-commercial" }?.parent, "vivy")
        XCTAssertNil(rail.first { $0.id == "vivy" }?.parent)
    }

    func testADanglingOrMissingParentIsStillJustDecoded() throws {
        let file = try write("""
        {"rail": [{"session": "orphan", "parent": "no-such-crew"}]}
        """)
        let rail = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions)
        XCTAssertEqual(rail.first?.parent, "no-such-crew")
    }

    // MARK: - Reading and round-tripping `sessionId`

    /// An older file with no `sessionId` key decodes to `nil` — the same
    /// "migration costs nothing" every other field in this file follows.
    func testAChildWithNoSessionIdKeyDecodesToNil() throws {
        let file = try write("""
        {"rail": [{"session": "ask", "sessions": [{"name": "ask--research"}]}]}
        """)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertNil(row.sessions.first?.sessionId)
    }

    func testAChildsSessionIdIsDecoded() throws {
        let file = try write("""
        {"rail": [{"session": "ask", "sessions": [
            {"name": "ask--research", "sessionId": "$19"}
        ]}]}
        """)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(row.sessions.first?.sessionId, "$19")
    }

    func testAChildsSessionIdSurvivesSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [
            Crew(id: "ask", displayName: "Ask",
                   sessions: [PinnedSession(name: "ask--research", displayName: "research", sessionId: "$19")]),
        ]
        try config.save(to: file)

        let reloaded = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions)
        XCTAssertEqual(reloaded.first { $0.id == "ask" }?.sessions.first?.sessionId, "$19")
    }

    // MARK: - Round trip

    func testSessionsAndParentSurviveSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [
            Crew(id: "ask", displayName: "Ask",
                   sessions: [PinnedSession(name: "ask--research", displayName: "research")]),
            Crew(id: "vivy-commercial", displayName: "Vivy Commercial", parent: "vivy"),
        ]
        try config.save(to: file)

        let reloaded = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions)
        XCTAssertEqual(reloaded.first { $0.id == "ask" }?.sessions,
                       [PinnedSession(name: "ask--research", displayName: "research")])
        XCTAssertEqual(reloaded.first { $0.id == "vivy-commercial" }?.parent, "vivy")
    }

    /// A row with no children and no parent must not grow either key on save
    /// — the same reasoning `railArray` already applies to an unset command
    /// or workdir: a row nobody touched should not accumulate keys nobody
    /// wrote.
    ///
    /// Reads the RAIL ROW's own dictionary rather than grepping the file for
    /// `"sessions"` — the top level already carries an unrelated `sessions`
    /// key, the session-to-theme-name map, so a text search would pass
    /// vacuously against the wrong key entirely.
    func testAnUntouchedRowWritesNeitherKey() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "deck", displayName: "Deck")]
        try config.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rail = try XCTUnwrap(root["rail"] as? [[String: Any]])
        let row = try XCTUnwrap(rail.first)
        XCTAssertNil(row["sessions"])
        XCTAssertNil(row["parent"])
    }

    // MARK: - Theme inheritance (design §A: "a child session with no theme of
    // its own resolves to its crew's")

    func testAnUnmappedChildResolvesToItsParentsTheme() {
        let config = ThemeConfiguration(
            sessions: [SessionRef(host: nil, name: "ask"): "azure"], appearancePreference: .system, typography: .default)
        XCTAssertEqual(
            config.theme(forSession: SessionRef(host: nil, name: "ask--research"), fallbackParent: SessionRef(host: nil, name: "ask")).name,
            config.theme(forSession: SessionRef(host: nil, name: "ask")).name)
    }

    /// An explicit mapping on the CHILD still wins — inheritance is only the
    /// fallback for a child with no theme of its own.
    func testAChildsOwnMappingBeatsItsParentsFallback() {
        let config = ThemeConfiguration(
            sessions: [SessionRef(host: nil, name: "ask"): "azure", SessionRef(host: nil, name: "ask--research"): "gold"],
            appearancePreference: .system, typography: .default)
        XCTAssertEqual(
            config.theme(forSession: SessionRef(host: nil, name: "ask--research"), fallbackParent: SessionRef(host: nil, name: "ask")).name,
            ThemeCatalog.named("gold")?.name)
    }

    /// With no `fallbackParent` at all, resolution is exactly what it was
    /// before this field existed — the hashed default.
    func testNoFallbackParentIsUnchangedBehaviour() {
        let config = ThemeConfiguration.empty
        XCTAssertEqual(config.theme(forSession: SessionRef(host: nil, name: "deck")).name,
                       config.theme(forSession: SessionRef(host: nil, name: "deck"), fallbackParent: nil).name)
    }

    // MARK: - Scratch-shell collision guard (config-parse path)
    //
    // `SiblingSessionName.derive` only ever sees a name typed through "New
    // session in…", so it cannot catch two names that arrive already written
    // in `theme.json` — `parseRail`/`parseSessions`/`parseCatalog` validate
    // each with `validateTmuxSessionName` alone. These pin the pass that
    // covers that gap: two names sharing their first 53 characters (the
    // `64 - "deck-shell-".count` budget `scratchShellSessionName` truncates
    // to) resolve to the same scratch shell no matter which two fields they
    // came from.

    /// A 53-character shared prefix, so two 64-character names built from it
    /// agree on everything `scratchShellSessionName` keeps and differ only
    /// in the part it truncates away.
    private static let scratchCollisionPrefix = String(repeating: "a", count: 53)

    func testTwoRailRowsCollidingAfterTruncationDropsTheSecond() throws {
        let idA = Self.scratchCollisionPrefix + "11111111111"
        let idB = Self.scratchCollisionPrefix + "22222222222"
        XCTAssertEqual(idA.count, 64)
        XCTAssertEqual(idB.count, 64)
        let file = try write("""
        {"rail": [{"session": "\(idA)"}, {"session": "\(idB)"}]}
        """)
        let rail = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions)
        XCTAssertEqual(rail.map(\.id), [idA])
    }

    func testTwoChildrenOfOneCrewCollidingAfterTruncationDropsTheSecond() throws {
        let nameA = Self.scratchCollisionPrefix + "11111111111"
        let nameB = Self.scratchCollisionPrefix + "22222222222"
        let file = try write("""
        {"rail": [{"session": "ask", "sessions": [
            {"name": "\(nameA)"}, {"name": "\(nameB)"}
        ]}]}
        """)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(row.sessions.map(\.name), [nameA])
    }

    /// A child and a DIFFERENT crew's row id share the same scratch-shell
    /// namespace — the guard has to compare across rows, not just within
    /// one, or a child pinned under crew B could still silently detach
    /// crew A's shell.
    func testAChildCollidingWithADifferentCrewsIdIsDropped() throws {
        let crewId = Self.scratchCollisionPrefix + "11111111111"
        let childName = Self.scratchCollisionPrefix + "22222222222"
        let file = try write("""
        {"rail": [
            {"session": "\(crewId)"},
            {"session": "other", "sessions": [{"name": "\(childName)"}]}
        ]}
        """)
        let rail = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions)
        XCTAssertEqual(rail.map(\.id), [crewId, "other"])
        XCTAssertEqual(rail.first { $0.id == "other" }?.sessions, [])
    }

    /// The row itself survives a colliding child — only the child is
    /// dropped, the same per-row degradation a child with an unusable name
    /// already gets from `parseSessions`.
    func testARowWithAOneCollidingChildKeepsTheRowAndItsOtherChildren() throws {
        let crewId = Self.scratchCollisionPrefix + "11111111111"
        let collidingChild = Self.scratchCollisionPrefix + "22222222222"
        let file = try write("""
        {"rail": [
            {"session": "\(crewId)"},
            {"session": "ask", "sessions": [
                {"name": "ask--research"}, {"name": "\(collidingChild)"}
            ]}
        ]}
        """)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?
            .first { $0.id == "ask" })
        XCTAssertEqual(row.sessions.map(\.name), ["ask--research"])
    }

    /// A normal, short-named config — the overwhelming common case — must
    /// lose nothing: the guard only fires on an actual scratch-shell
    /// collision, never on distinct short names that could not possibly
    /// truncate onto each other.
    func testAnOrdinaryShortNameConfigDropsNothing() throws {
        let file = try write("""
        {"rail": [
            {"session": "ask", "sessions": [
                {"name": "ask--research"}, {"name": "ask--tax-2025"}
            ]},
            {"session": "vivy"}
        ], "catalog": [{"session": "nyh"}]}
        """)
        let config = ThemeConfiguration.load(from: file)
        let rail = try XCTUnwrap(config.railSessions)
        XCTAssertEqual(rail.map(\.id), ["ask", "vivy"])
        XCTAssertEqual(rail.first { $0.id == "ask" }?.sessions.map(\.name),
                       ["ask--research", "ask--tax-2025"])
        XCTAssertEqual(config.catalog.map(\.id), ["nyh"])
    }

    /// First occurrence wins, checked by identity rather than just count: of
    /// two rows that collide, the SURVIVING one is the one that appeared
    /// first in the file, not whichever the guard happened to keep.
    func testFirstOccurrenceWinsRegardlessOfWhichRowItIs() throws {
        let railId = Self.scratchCollisionPrefix + "11111111111"
        let catalogId = Self.scratchCollisionPrefix + "22222222222"
        let file = try write("""
        {"rail": [{"session": "\(railId)"}], "catalog": [{"session": "\(catalogId)"}]}
        """)
        let config = ThemeConfiguration.load(from: file)
        XCTAssertEqual(config.railSessions?.map(\.id), [railId])
        XCTAssertEqual(config.catalog.map(\.id), [])
    }
}
