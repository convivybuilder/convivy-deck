import XCTest
@testable import Deck

/// `ThemeStore.addHost`/`updateHost`/`removeHost`/`setDefaultHost` — the
/// mutators the Hosts tab writes through. See
/// `deck/specs/multiple-sessions-per-project` §"Crews on different hosts".
final class HostMutatorsTests: XCTestCase {
    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-hostmutators-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    // MARK: - addHost

    @MainActor
    func testAddHostAppendsTheEntry() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        XCTAssertEqual(store.configuration.hosts, [HostEntry(name: "guest", user: "guest", address: "1.2.3.4")])
    }

    @MainActor
    func testAddHostIsANoOpOnADuplicateName() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        let before = store.configuration

        store.addHost(HostEntry(name: "guest", user: "someone-else", address: "9.9.9.9"))

        XCTAssertEqual(store.configuration, before)
    }

    @MainActor
    func testAddHostNeverTouchesDefaultHost() {
        let store = ThemeStore(fileURL: url())
        XCTAssertNil(store.configuration.defaultHost, "precondition")

        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))

        XCTAssertNil(store.configuration.defaultHost)
    }

    /// THE HAZARD from the spec's §"5": adding the first host must not
    /// silently repoint a crew that names no host of its own. Traced
    /// through `HostResolution.target` directly, before and after, rather
    /// than asserting on `defaultHost`'s literal value — the property under
    /// test is the RESOLUTION, and `defaultHost` staying nil is only the
    /// mechanism `addHost`'s doc comment claims produces it.
    @MainActor
    func testAddingTheFirstHostLeavesAHostlessCrewResolvingToTheSameTarget() {
        let store = ThemeStore(fileURL: url())
        let before = HostResolution.target(
            forHostName: nil, hosts: store.configuration.hosts, defaultHost: store.configuration.defaultHost)
        XCTAssertNil(before, "precondition: an unconfigured install resolves to nothing")

        store.addHost(HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress))

        let after = HostResolution.target(
            forHostName: nil, hosts: store.configuration.hosts, defaultHost: store.configuration.defaultHost)
        XCTAssertEqual(after, before, "adding a host must not silently repoint a crew naming none of its own")
    }

    /// The same guarantee for a crew with no `host` of its own — such a crew
    /// must keep resolving to nothing once a host table exists with no
    /// default set: `addHost` never touches `defaultHost`
    /// (`testAddHostNeverTouchesDefaultHost`), so there is still nothing for
    /// a hostless crew to fall back to. `CrewCatalog.known` carries no rows
    /// to loop over any more (`deck/specs/running-deck-as-someone-else`
    /// §"The defaults name Convivy"), so this exercises a hostless crew
    /// directly rather than iterating a shipped catalog.
    @MainActor
    func testAddingTheFirstHostLeavesAHostlessCrewResolvingToNothing() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "office", user: "operator", address: "10.0.0.9"))
        let crew = Crew(id: "ask", displayName: "Ask")

        let target = HostResolution.target(
            forHostName: crew.host, hosts: store.configuration.hosts,
            defaultHost: store.configuration.defaultHost)
        XCTAssertNil(target, "\(crew.id) must still resolve to nothing with no default host set")
    }

    // MARK: - updateHost

    @MainActor
    func testUpdateHostChangesFieldsInPlace() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))

        store.updateHost(named: "guest", to: HostEntry(name: "guest", user: "guest", address: "5.6.7.8"))

        XCTAssertEqual(store.configuration.hosts, [HostEntry(name: "guest", user: "guest", address: "5.6.7.8")])
    }

    @MainActor
    func testUpdateHostIsANoOpForAnUnknownName() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        let before = store.configuration

        store.updateHost(named: "no-such-host", to: HostEntry(name: "x", user: "x", address: "1.1.1.1"))

        XCTAssertEqual(store.configuration, before)
    }

    @MainActor
    func testUpdateHostIsANoOpWhenTheNewNameCollidesWithADifferentHost() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        store.addHost(HostEntry(name: "office", user: "operator", address: "5.6.7.8"))
        let before = store.configuration

        store.updateHost(named: "guest", to: HostEntry(name: "office", user: "guest", address: "1.2.3.4"))

        XCTAssertEqual(store.configuration, before)
    }

    /// A rename cascades to `defaultHost` in the SAME commit — leaving it
    /// pointed at a name no longer in `hosts` would fall every host-less
    /// crew back to unresolved behind the user's back, dressed up as a typo
    /// fix on an unrelated field.
    @MainActor
    func testRenamingTheDefaultHostUpdatesDefaultHostToo() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        store.setDefaultHost("guest")

        store.updateHost(named: "guest", to: HostEntry(name: "guest-mini", user: "guest", address: "1.2.3.4"))

        XCTAssertEqual(store.configuration.defaultHost, "guest-mini")
    }

    /// A rename also repoints every rail and catalog row naming the old
    /// name — otherwise a crew's `host` field silently stops resolving to
    /// the box it was pointed at and falls back to the default instead.
    @MainActor
    func testRenamingAHostRepointsCrewsAndCatalogRowsThatNamedIt() {
        let file = url()
        let store = ThemeStore(fileURL: file)
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        store.addCrew(Crew(id: "ask", displayName: "Ask", host: "guest"))

        // No dedicated catalog mutator exists; write the catalog row
        // directly through the config and reload, the same file round trip
        // `HostConfigTests` uses to exercise a catalog row's `host` field.
        var config = store.configuration
        config.catalog = [LaunchableSession(id: "nyh", displayName: "NYH Studio", host: "guest")]
        try? config.save(to: file)
        let reloaded = ThemeStore(fileURL: file)

        reloaded.updateHost(named: "guest", to: HostEntry(name: "guest2", user: "guest", address: "1.2.3.4"))

        XCTAssertEqual(reloaded.configuration.railSessions?.first { $0.id == "ask" }?.host, "guest2")
        XCTAssertEqual(reloaded.configuration.catalog.first { $0.id == "nyh" }?.host, "guest2")
    }

    @MainActor
    func testARenameThatKeepsTheSameNameNeverTouchesRailOrCatalog() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        store.addCrew(Crew(id: "ask", displayName: "Ask", host: "guest"))
        let railBefore = store.configuration.railSessions

        store.updateHost(named: "guest", to: HostEntry(name: "guest", user: "guest", address: "9.9.9.9"))

        XCTAssertEqual(store.configuration.railSessions, railBefore)
    }

    // MARK: - removeHost

    @MainActor
    func testRemoveHostDropsTheEntry() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))

        store.removeHost("guest")

        XCTAssertEqual(store.configuration.hosts, [])
    }

    @MainActor
    func testRemoveHostIsANoOpForAnUnknownName() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        let before = store.configuration

        store.removeHost("no-such-host")

        XCTAssertEqual(store.configuration, before)
    }

    @MainActor
    func testRemovingTheDefaultHostResetsDefaultHostToNil() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        store.setDefaultHost("guest")

        store.removeHost("guest")

        XCTAssertNil(store.configuration.defaultHost)
    }

    @MainActor
    func testRemovingANonDefaultHostLeavesDefaultHostUntouched() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        store.addHost(HostEntry(name: "office", user: "operator", address: "5.6.7.8"))
        store.setDefaultHost("office")

        store.removeHost("guest")

        XCTAssertEqual(store.configuration.defaultHost, "office")
    }

    /// `HostResolution`'s fallback stays EXACTLY as it is — a crew still
    /// naming the removed host is left alone here; the Hosts tab's confirm
    /// is what adds visibility, not this mutator.
    @MainActor
    func testRemoveHostNeverTouchesACrewsHostField() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        store.addCrew(Crew(id: "ask", displayName: "Ask", host: "guest"))

        store.removeHost("guest")

        XCTAssertEqual(store.configuration.railSessions?.first { $0.id == "ask" }?.host, "guest")
    }

    // MARK: - setDefaultHost

    @MainActor
    func testSetDefaultHostSetsIt() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))

        store.setDefaultHost("guest")

        XCTAssertEqual(store.configuration.defaultHost, "guest")
    }

    @MainActor
    func testSetDefaultHostClearsItWithNil() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        store.setDefaultHost("guest")

        store.setDefaultHost(nil)

        XCTAssertNil(store.configuration.defaultHost)
    }

    @MainActor
    func testSetDefaultHostIsANoOpForAnUnconfiguredName() {
        let store = ThemeStore(fileURL: url())
        let before = store.configuration

        store.setDefaultHost("no-such-host")

        XCTAssertEqual(store.configuration, before)
    }

    @MainActor
    func testSetDefaultHostIsANoOpWhenUnchanged() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        store.setDefaultHost("guest")
        let before = store.configuration

        store.setDefaultHost("guest")

        XCTAssertEqual(store.configuration, before)
    }

    // MARK: - renameCrew

    @MainActor
    func testRenameCrewChangesDisplayNameOnly() {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "library", displayName: "library"))

        store.renameCrew(SessionRef(host: nil, name: "library"), to: "Library")

        let row = store.configuration.railSessions?.first { $0.id == "library" }
        XCTAssertEqual(row?.displayName, "Library")
        XCTAssertEqual(row?.id, "library")
    }

    @MainActor
    func testRenameCrewIsANoOpForAnUnknownId() {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask"))
        let before = store.configuration

        store.renameCrew(SessionRef(host: nil, name: "no-such-crew"), to: "Whatever")

        XCTAssertEqual(store.configuration, before)
    }

    @MainActor
    func testRenameCrewIsANoOpForAnEmptyName() {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask"))
        let before = store.configuration

        store.renameCrew(SessionRef(host: nil, name: "ask"), to: "   ")

        XCTAssertEqual(store.configuration, before)
    }

    @MainActor
    func testRenameCrewIsANoOpWhenTheNameIsUnchanged() {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask"))
        let before = store.configuration

        store.renameCrew(SessionRef(host: nil, name: "ask"), to: "Ask")

        XCTAssertEqual(store.configuration, before)
    }
}
