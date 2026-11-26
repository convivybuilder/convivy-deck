import XCTest
@testable import Deck

/// `HostsSettingsView.entryForStewardAfterSetup`: after Deck's setup
/// succeeds on a host, the steward is created under the root that host
/// reports, never the global fallback. The Linux setup check on 2026-11-24
/// added builder-check before Builder existed on it, so its entry had no
/// root, and the steward was built as `<home>/steward`, outside the Builder
/// root, which session-agent refused.
final class StewardAfterSetupRootTests: XCTestCase {
    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-stewardaftersetup-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    @MainActor
    func testTheFetchedRootLandsAndTheStewardGoesUnderIt() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "linux-box", user: "u", address: "1.2.3.4"))
        XCTAssertNil(store.configuration.hosts.first?.crewsRoot,
                     "precondition: the add-time fetch found no Builder and landed nothing")

        let entry = HostsSettingsView.entryForStewardAfterSetup(
            fetchedRoot: "\(TestHost.secondaryHomeRoot)/builder", hostNamed: "linux-box", in: store)

        XCTAssertEqual(entry?.crewsRoot, "\(TestHost.secondaryHomeRoot)/builder")
        XCTAssertEqual(store.configuration.hosts.first?.crewsRoot, "\(TestHost.secondaryHomeRoot)/builder")
        let resolved = HostResolution.crewsRoot(
            forHostName: "linux-box", hosts: store.configuration.hosts,
            defaultHost: store.configuration.defaultHost, globalCrewsRoot: store.configuration.crewsRoot)
        XCTAssertEqual(StewardCrew.directory(crewsRoot: resolved), "\(TestHost.secondaryHomeRoot)/builder/steward")
    }

    /// A failed fetch on a host whose entry has no root must create nothing,
    /// since the only directory left is the global fallback.
    @MainActor
    func testAFailedFetchWithNoRootOnTheEntryCreatesNothing() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "linux-box", user: "u", address: "1.2.3.4"))
        XCTAssertNil(HostsSettingsView.entryForStewardAfterSetup(
            fetchedRoot: nil, hostNamed: "linux-box", in: store))
    }

    /// A root the operator set on the entry still serves when the fetch
    /// fails, as it does on the add path.
    @MainActor
    func testAFailedFetchFallsBackToARootAlreadyOnTheEntry() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "linux-box", user: "u", address: "1.2.3.4",
                                crewsRoot: "\(TestHost.secondaryHomeRoot)/builder"))
        let entry = HostsSettingsView.entryForStewardAfterSetup(
            fetchedRoot: nil, hostNamed: "linux-box", in: store)
        XCTAssertEqual(entry?.crewsRoot, "\(TestHost.secondaryHomeRoot)/builder")
    }

    @MainActor
    func testAnUnknownHostCreatesNothing() {
        let store = ThemeStore(fileURL: url())
        XCTAssertNil(HostsSettingsView.entryForStewardAfterSetup(
            fetchedRoot: "\(TestHost.secondaryHomeRoot)/builder", hostNamed: "gone", in: store))
    }
}
