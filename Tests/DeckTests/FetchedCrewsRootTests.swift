import XCTest
@testable import Deck

/// `HostsSettingsView.applyingFetchedRoot` — where the root a host reports
/// lands after the ssh round trip that fetched it.
///
/// THE ROUND TRIP IS A WINDOW, AND THE WINDOW IS THE POINT. The host row and
/// its editable detail panel are on screen from the instant the row is added,
/// which is before the fetch has started; an operator fixing a mistyped
/// address is editing the same entry the fetch is about to write to. These
/// pin that the write lands on whatever the entry looks like when it
/// resolves, not on the snapshot taken when it began.
///
/// See `deck/specs/running-deck-as-someone-else` and the `crews-root` verb in
/// `platform/contracts/session-agent-api`.
final class FetchedCrewsRootTests: XCTestCase {
    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-fetchedroot-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    @MainActor
    func testTheFetchedRootLandsOnTheEntry() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))

        let offered = HostsSettingsView.applyingFetchedRoot(
            "\(TestHost.secondaryHomeRoot)/work", toHostNamed: "guest", in: store)

        XCTAssertEqual(offered?.crewsRoot, "\(TestHost.secondaryHomeRoot)/work")
        XCTAssertEqual(store.configuration.hosts.first?.crewsRoot, "\(TestHost.secondaryHomeRoot)/work")
    }

    /// The failure the review caught: an operator fixing a mistyped address
    /// while the fetch is in flight must not have that fix reverted when it
    /// resolves. Writing back the struct captured at add time would carry
    /// every field with it; reading the live entry carries only the root.
    @MainActor
    func testAConcurrentAddressEditSurvivesTheWriteBack() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        // The operator notices the address is wrong and fixes it while the
        // fetch is still running against the old one.
        store.updateHost(named: "guest",
                         to: HostEntry(name: "guest", user: "guest", address: "10.0.0.9"))

        let offered = HostsSettingsView.applyingFetchedRoot(
            "\(TestHost.secondaryHomeRoot)/work", toHostNamed: "guest", in: store)

        XCTAssertEqual(store.configuration.hosts.first?.address, "10.0.0.9",
                       "the fix must survive; the fetch only owns crewsRoot")
        XCTAssertEqual(store.configuration.hosts.first?.crewsRoot, "\(TestHost.secondaryHomeRoot)/work")
        XCTAssertEqual(offered?.address, "10.0.0.9")
    }

    /// The other half of the same window: a RENAME during the fetch used to
    /// make `updateHost`'s name guard miss, dropping the root silently.
    /// Renaming is still a miss here — the entry is looked up by the name it
    /// had — but it now fails as "nothing written" rather than as a stale
    /// write, and the caller falls back to what it already had.
    @MainActor
    func testARenameDuringTheFetchWritesNothingRatherThanStaleData() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        store.updateHost(named: "guest",
                         to: HostEntry(name: "renamed", user: "guest", address: "1.2.3.4"))
        let before = store.configuration

        let offered = HostsSettingsView.applyingFetchedRoot(
            "\(TestHost.secondaryHomeRoot)/work", toHostNamed: "guest", in: store)

        XCTAssertNil(offered)
        XCTAssertEqual(store.configuration, before, "nothing written under the old name")
    }

    @MainActor
    func testAnEntryRemovedDuringTheFetchWritesNothing() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        store.removeHost("guest")
        let before = store.configuration

        XCTAssertNil(HostsSettingsView.applyingFetchedRoot(
            "\(TestHost.secondaryHomeRoot)/work", toHostNamed: "guest", in: store))
        XCTAssertEqual(store.configuration, before)
    }

    @MainActor
    func testAFailedFetchWritesNothing() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        let before = store.configuration

        XCTAssertNil(HostsSettingsView.applyingFetchedRoot(
            nil, toHostNamed: "guest", in: store))
        XCTAssertEqual(store.configuration, before)
    }

    /// A root arriving from a HOST is the one nobody looked at, so it is
    /// gated the way the hand-typed Add and Edit Host forms are. Nothing
    /// exploitable rides on this — `startArguments` validates again before
    /// the value reaches argv — but a bad root must never become a value the
    /// operator reads in Settings and believes.
    @MainActor
    func testAMalformedRootFromTheHostIsRefusedRatherThanPersisted() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "guest", user: "guest", address: "1.2.3.4"))
        let before = store.configuration

        for bad in ["relative/path", "\(TestHost.secondaryHomeRoot)/../../etc", "\(TestHost.secondaryHomeRoot)/a b",
                    "\(TestHost.secondaryHomeRoot)/work\nrm -rf /", ""] {
            XCTAssertNil(HostsSettingsView.applyingFetchedRoot(
                bad, toHostNamed: "guest", in: store), "should refuse \(bad.debugDescription)")
        }
        XCTAssertEqual(store.configuration, before)
    }
}
