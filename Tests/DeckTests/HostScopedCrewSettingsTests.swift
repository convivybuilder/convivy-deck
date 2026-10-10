import XCTest
@testable import Deck

/// A crew is identified by its host together with its name, so everything
/// Deck stores per crew is keyed by both: its theme, its expanded state, its
/// pinned children, and a nested crew's link to its parent.
///
/// THE CASE THIS EXISTS FOR. Every Builder install has a crew named
/// `steward`, and one operator runs several machines, so the same crew name
/// on two hosts is the normal case rather than a collision. Keyed by bare
/// name, as all of this was, the second host's crew could not be promoted at
/// all, and the two that did exist shared one colour and one disclosure.
///
/// EACH CLAIM IS PINNED IN BOTH DIRECTIONS — the crew that must change, and
/// the crew on the other host that must not. The second assertion is the one
/// that fails if the keying regresses, and the first alone would pass on a
/// bare-name lookup.
final class HostScopedCrewSettingsTests: XCTestCase {
    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-hostscoped-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    private static let onFirst = SessionRef(host: "first-box", name: "steward")
    private static let onSecond = SessionRef(host: "second-box", name: "steward")

    /// Two crews of one name, one per host — the shape every test here starts
    /// from, and the shape that could not previously reach the rail.
    @MainActor
    private func storeWithBothStewards(fileURL: URL? = nil) -> ThemeStore {
        let store = ThemeStore(fileURL: fileURL ?? url())
        store.addCrew(Crew(id: "steward", displayName: "Steward", host: "first-box"))
        store.addCrew(Crew(id: "steward", displayName: "Steward", host: "second-box"))
        return store
    }

    // MARK: - Both crews reach the rail at all

    @MainActor
    func testTwoCrewsOfOneNameOnTwoHostsAreBothOnTheRail() {
        let store = storeWithBothStewards()
        XCTAssertEqual((store.configuration.railSessions ?? []).map(\.ref),
                       [Self.onFirst, Self.onSecond])
    }

    /// The same name on the SAME host is still one crew — `addCrew`'s
    /// collision guard, which host scoping must narrow rather than remove.
    @MainActor
    func testASecondCrewOfOneNameOnTheSameHostIsRefused() {
        let store = storeWithBothStewards()
        store.addCrew(Crew(id: "steward", displayName: "Impostor", host: "first-box"))
        XCTAssertEqual((store.configuration.railSessions ?? []).count, 2)
        XCTAssertEqual((store.configuration.railSessions ?? []).first?.displayName, "Steward")
    }

    /// Both rows survive the parse, which they did not when the scratch-shell
    /// collision check was global: `steward` and `steward` resolve to one
    /// scratch name, so the second row was dropped outright before it could
    /// be drawn. The check still refuses two on ONE host, which the next test
    /// pins.
    func testBothCrewsSurviveTheScratchShellCollisionCheck() throws {
        let json = #"""
        {"defaultHost": "first-box",
         "rail": [{"session": "steward", "host": "first-box"},
                  {"session": "steward", "host": "second-box"}]}
        """#
        let config = try XCTUnwrap(ThemeConfiguration.parse(Data(json.utf8)))
        XCTAssertEqual((config.railSessions ?? []).map(\.ref), [Self.onFirst, Self.onSecond])
    }

    func testTwoRowsOfOneNameOnOneHostStillCollide() throws {
        let json = #"""
        {"rail": [{"session": "steward", "host": "first-box"},
                  {"session": "steward", "host": "first-box"}]}
        """#
        let config = try XCTUnwrap(ThemeConfiguration.parse(Data(json.utf8)))
        XCTAssertEqual((config.railSessions ?? []).map(\.ref), [Self.onFirst])
    }

    // MARK: - Theme

    @MainActor
    func testThemingOneHostsCrewLeavesTheOthersAlone() {
        let store = storeWithBothStewards()
        store.setTheme("gold", forSession: Self.onFirst)

        XCTAssertEqual(store.configuration.theme(forSession: Self.onFirst).name, "gold")
        XCTAssertNil(store.configuration.sessions[Self.onSecond])
        XCTAssertEqual(store.configuration.theme(forSession: Self.onSecond).name,
                       ThemeCatalog.defaultTheme(forSession: "steward").name)
    }

    /// Each host's crew holds its own pick at the same time, which one key
    /// per name cannot represent at all.
    @MainActor
    func testEachHostsCrewHoldsItsOwnTheme() throws {
        let file = url()
        let store = storeWithBothStewards(fileURL: file)
        store.setTheme("gold", forSession: Self.onFirst)
        store.setTheme("azure", forSession: Self.onSecond)

        XCTAssertEqual(store.configuration.theme(forSession: Self.onFirst).name, "gold")
        XCTAssertEqual(store.configuration.theme(forSession: Self.onSecond).name, "azure")

        let reloaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(reloaded.theme(forSession: Self.onFirst).name, "gold")
        XCTAssertEqual(reloaded.theme(forSession: Self.onSecond).name, "azure")
    }

    /// Resetting one to the hashed default leaves the other's pick standing —
    /// the removal is keyed the same way the write is.
    @MainActor
    func testResettingOneHostsThemeLeavesTheOthersPick() {
        let store = storeWithBothStewards()
        store.setTheme("gold", forSession: Self.onFirst)
        store.setTheme("azure", forSession: Self.onSecond)

        store.setTheme(nil, forSession: Self.onFirst)

        XCTAssertNil(store.configuration.sessions[Self.onFirst])
        XCTAssertEqual(store.configuration.sessions[Self.onSecond], "azure")
    }

    // MARK: - Expand state

    func testEachHostsCrewExpandsOnItsOwn() {
        var expansion = CrewExpansion(raw: "")
        expansion.toggle(Self.onFirst)

        XCTAssertTrue(expansion.isExpanded(Self.onFirst))
        XCTAssertFalse(expansion.isExpanded(Self.onSecond))
        XCTAssertEqual(expansion.raw, "first-box|steward")
    }

    func testCollapsingOneHostsCrewLeavesTheOtherOpen() {
        var expansion = CrewExpansion(raw: "")
        expansion.toggle(Self.onFirst)
        expansion.toggle(Self.onSecond)

        expansion.toggle(Self.onFirst)

        XCTAssertFalse(expansion.isExpanded(Self.onFirst))
        XCTAssertTrue(expansion.isExpanded(Self.onSecond))
    }

    /// An entry written before the host half existed is a bare crew id, and a
    /// user who upgrades finds the rows they left open still open.
    func testALegacyBareEntryStillOpensTheRow() {
        let expansion = CrewExpansion(raw: "steward,vivy")
        XCTAssertTrue(expansion.isExpanded(Self.onFirst))
        XCTAssertTrue(expansion.isExpanded(SessionRef(host: nil, name: "vivy")))
        XCTAssertFalse(expansion.isExpanded(SessionRef(host: "first-box", name: "selector")))
    }

    /// Collapsing a row read as expanded through a legacy entry has to drop
    /// that entry too, or the row could never be closed.
    func testCollapsingARowOpenedByALegacyEntryClosesIt() {
        var expansion = CrewExpansion(raw: "steward")
        expansion.toggle(Self.onFirst)

        XCTAssertFalse(expansion.isExpanded(Self.onFirst))
        XCTAssertEqual(expansion.raw, "")
    }

    /// The first toggle of a legacy row writes it back host-qualified, so the
    /// bare form does not persist indefinitely.
    func testTogglingALegacyRowTwiceRewritesItHostQualified() {
        var expansion = CrewExpansion(raw: "steward")
        expansion.toggle(Self.onFirst)
        expansion.toggle(Self.onFirst)

        XCTAssertEqual(expansion.raw, "first-box|steward")
        XCTAssertFalse(expansion.isExpanded(Self.onSecond))
    }

    // MARK: - Pinned children

    @MainActor
    func testAPinLandsOnlyOnTheCrewOnThatHost() throws {
        let store = storeWithBothStewards()
        store.addPinnedSession(PinnedSession(name: "steward--build", displayName: "build"),
                               toCrew: Self.onSecond)

        let rail = store.configuration.railSessions ?? []
        XCTAssertEqual(try XCTUnwrap(rail.first { $0.ref == Self.onFirst }).sessions, [])
        XCTAssertEqual(try XCTUnwrap(rail.first { $0.ref == Self.onSecond }).sessions.map(\.name),
                       ["steward--build"])
    }

    @MainActor
    func testRemovingAPinNamedOnAnotherHostIsANoOp() throws {
        let store = storeWithBothStewards()
        store.addPinnedSession(PinnedSession(name: "steward--build", displayName: "build"),
                               toCrew: Self.onSecond)

        store.removePinnedSession("steward--build", fromCrew: Self.onFirst)

        let rail = store.configuration.railSessions ?? []
        XCTAssertEqual(try XCTUnwrap(rail.first { $0.ref == Self.onSecond }).sessions.map(\.name),
                       ["steward--build"])
    }

    /// A child's theme is keyed on its CREW's host, so the same child name
    /// under two same-named crews is two mappings.
    @MainActor
    func testAChildsThemeIsKeyedOnItsCrewsHost() {
        let store = storeWithBothStewards()
        let childOnSecond = SessionRef(host: "second-box", name: "steward--build")
        store.setTheme("gold", forSession: childOnSecond)

        XCTAssertEqual(store.configuration.theme(forSession: childOnSecond).name, "gold")
        XCTAssertNil(store.configuration.sessions[SessionRef(host: "first-box",
                                                             name: "steward--build")])
    }

    // MARK: - Removal and rename

    @MainActor
    func testRemovingOneHostsCrewLeavesTheOther() {
        let store = storeWithBothStewards()
        store.removeCrew(Self.onFirst)
        XCTAssertEqual((store.configuration.railSessions ?? []).map(\.ref), [Self.onSecond])
    }

    @MainActor
    func testRenamingOneHostsCrewLeavesTheOthersLabel() throws {
        let store = storeWithBothStewards()
        store.renameCrew(Self.onSecond, to: "Second Steward")

        let rail = store.configuration.railSessions ?? []
        XCTAssertEqual(try XCTUnwrap(rail.first { $0.ref == Self.onFirst }).displayName, "Steward")
        XCTAssertEqual(try XCTUnwrap(rail.first { $0.ref == Self.onSecond }).displayName,
                       "Second Steward")
    }

    // MARK: - Parent links

    /// A nested crew and its parent are on the same host, so a `parent`
    /// naming a crew that exists only elsewhere is as dangling as one naming
    /// no crew at all.
    func testACrewNestsUnderTheParentOnItsOwnHost() throws {
        let crews = [
            Crew(id: "vivy", displayName: "Vivy", host: "first-box"),
            Crew(id: "vivy", displayName: "Vivy", host: "second-box"),
            Crew(id: "vivy-labs", displayName: "Labs", parent: "vivy", host: "second-box"),
        ]
        let parent = try XCTUnwrap(RailNesting.nestingParent(of: crews[2], in: crews))
        XCTAssertEqual(parent.ref, SessionRef(host: "second-box", name: "vivy"))
        XCTAssertEqual(RailNesting.nestedCrews(of: crews[0], in: crews), [])
        XCTAssertEqual(RailNesting.nestedCrews(of: crews[1], in: crews).map(\.id), ["vivy-labs"])
    }

    func testAParentThatExistsOnlyOnAnotherHostDrawsTheRowTopLevel() {
        let crews = [
            Crew(id: "vivy", displayName: "Vivy", host: "first-box"),
            Crew(id: "vivy-labs", displayName: "Labs", parent: "vivy", host: "second-box"),
        ]
        XCTAssertNil(RailNesting.nestingParent(of: crews[1], in: crews))
        XCTAssertEqual(RailNesting.topLevelCrews(crews).map(\.ref),
                       [SessionRef(host: "first-box", name: "vivy"),
                        SessionRef(host: "second-box", name: "vivy-labs")])
    }

    func testOnlyCrewsOnTheSameHostAreOfferedAsParents() {
        let crews = [
            Crew(id: "vivy", displayName: "Vivy", host: "first-box"),
            Crew(id: "constance", displayName: "Constance", host: "second-box"),
            Crew(id: "vivy-labs", displayName: "Labs", host: "second-box"),
        ]
        XCTAssertEqual(RailNesting.eligibleParents(for: crews[2], in: crews).map(\.id),
                       ["constance"])
    }

    // MARK: - Reading a file written before hosts scoped a crew

    /// A crew naming no host belongs to the default host, and says so once
    /// the file is written again — that is what keeps its identity stable when
    /// the default moves later.
    func testACrewNamingNoHostTakesTheDefaultHostAndIsWrittenDown() throws {
        let json = #"{"defaultHost": "first-box", "rail": [{"session": "deck"}]}"#
        let config = try XCTUnwrap(ThemeConfiguration.parse(Data(json.utf8)))
        XCTAssertEqual(config.railSessions?.first?.host, "first-box")

        let url = url()
        try config.save(to: url)
        let written = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rail = try XCTUnwrap(written["rail"] as? [[String: Any]])
        XCTAssertEqual(rail.first?["host"] as? String, "first-box")
    }

    /// With no `hosts` table and no default, a crew still has no host — the
    /// state an install that has configured nothing is in, and one the fill
    /// must not invent a value for.
    func testACrewOnAnInstallWithNoDefaultHostKeepsNoHost() throws {
        let json = #"{"rail": [{"session": "deck"}]}"#
        let config = try XCTUnwrap(ThemeConfiguration.parse(Data(json.utf8)))
        XCTAssertNil(config.railSessions?.first?.host)
        XCTAssertEqual(config.railSessions?.first?.ref, SessionRef(host: nil, name: "deck"))
    }

    /// A bare theme key belonged to whichever row carried the name, because
    /// the old map was global by name. Resolving it to the default host
    /// instead would lose the colour of every crew on another host.
    func testABareThemeKeyTakesTheHostOfTheRowCarryingItsName() throws {
        let json = #"""
        {"defaultHost": "first-box",
         "rail": [{"session": "deck", "host": "second-box"}],
         "sessions": {"deck": "gold"}}
        """#
        let config = try XCTUnwrap(ThemeConfiguration.parse(Data(json.utf8)))
        XCTAssertEqual(config.sessions[SessionRef(host: "second-box", name: "deck")], "gold")
        XCTAssertNil(config.sessions[SessionRef(host: "first-box", name: "deck")])
    }

    /// Including a name only a pinned child carries, which inherits its
    /// crew's host.
    func testABareThemeKeyForAChildTakesItsCrewsHost() throws {
        let json = #"""
        {"defaultHost": "first-box",
         "rail": [{"session": "deck", "host": "second-box",
                   "sessions": [{"name": "deck--build"}]}],
         "sessions": {"deck--build": "azure"}}
        """#
        let config = try XCTUnwrap(ThemeConfiguration.parse(Data(json.utf8)))
        XCTAssertEqual(config.sessions[SessionRef(host: "second-box", name: "deck--build")],
                       "azure")
    }

    /// A name no row carries — a session typed into the new-session field, or
    /// a row deleted since the theme was picked — lands on the default host,
    /// which is where a row naming no host lands too.
    func testABareThemeKeyForANameNoRowCarriesTakesTheDefaultHost() throws {
        let json = #"{"defaultHost": "first-box", "sessions": {"ghost": "gold"}}"#
        let config = try XCTUnwrap(ThemeConfiguration.parse(Data(json.utf8)))
        XCTAssertEqual(config.sessions[SessionRef(host: "first-box", name: "ghost")], "gold")
    }

    func testAHostQualifiedThemeKeyIsTakenAsWritten() throws {
        let json = #"""
        {"defaultHost": "first-box", "sessions": {"second-box|steward": "gold", "|deck": "azure"}}
        """#
        let config = try XCTUnwrap(ThemeConfiguration.parse(Data(json.utf8)))
        XCTAssertEqual(config.sessions[Self.onSecond], "gold")
        XCTAssertEqual(config.sessions[SessionRef(host: nil, name: "deck")], "azure")
        XCTAssertNil(config.sessions[Self.onFirst])
    }

    /// The written form, which is the format change this carries.
    func testThemeKeysAreWrittenHostQualified() throws {
        var config = ThemeConfiguration.empty
        config.sessions = [Self.onSecond: "gold"]

        let url = url()
        try config.save(to: url)
        let written = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(written["sessions"] as? [String: String], ["second-box|steward": "gold"])
    }

    /// Renaming a host has always repointed every crew naming it; a theme key
    /// carries a host now, so it has to move in the same commit or every crew
    /// on that host silently loses its colour.
    @MainActor
    func testRenamingAHostMovesTheThemeKeysNamingIt() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "first-box", user: "operator", address: "10.0.0.1"))
        store.addCrew(Crew(id: "steward", displayName: "Steward", host: "first-box"))
        store.setTheme("gold", forSession: Self.onFirst)

        store.updateHost(named: "first-box",
                         to: HostEntry(name: "renamed-box", user: "operator", address: "10.0.0.1"))

        XCTAssertEqual(store.configuration.sessions[SessionRef(host: "renamed-box",
                                                               name: "steward")], "gold")
        XCTAssertNil(store.configuration.sessions[Self.onFirst])
        XCTAssertEqual(
            store.configuration.theme(forSession: SessionRef(host: "renamed-box",
                                                             name: "steward")).name, "gold")
    }

    /// The rail's expand state is host-qualified like a theme key, so a host
    /// rename moves it; a bare legacy key and another host's key stay put.
    @MainActor
    func testRenamingAHostMovesTheRailExpandStateNamingIt() throws {
        let suite = "HostScopedCrewSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("first-box|steward,second-box|steward,deck",
                     forKey: CrewExpansion.storageKey)

        let store = ThemeStore(fileURL: url(), railDefaults: defaults)
        store.addHost(HostEntry(name: "first-box", user: "operator", address: "10.0.0.1"))
        store.addCrew(Crew(id: "steward", displayName: "Steward", host: "first-box"))

        store.updateHost(named: "first-box",
                         to: HostEntry(name: "renamed-box", user: "operator", address: "10.0.0.1"))

        let expansion = CrewExpansion(
            raw: defaults.string(forKey: CrewExpansion.storageKey) ?? "")
        XCTAssertTrue(expansion.isExpanded(SessionRef(host: "renamed-box", name: "steward")))
        XCTAssertTrue(expansion.isExpanded(Self.onSecond))
        XCTAssertEqual(expansion.raw, "deck,renamed-box|steward,second-box|steward")
    }
}
