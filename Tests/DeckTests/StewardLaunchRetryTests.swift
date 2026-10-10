import XCTest
@testable import Deck

/// `ContentView.evaluateStewardAtLaunch`'s fetch-and-land step — the retry
/// for the case `deck-reviewer` found on PR #207: a host added while
/// unreachable never got a real `crewsRoot` landed into its entry (only
/// `HostsSettingsView.addHost` ever writes one), so every launch retry that
/// skipped the fetch and only re-ran `HostResolution.crewsRoot` against the
/// stale entry would resolve to the `~/Convivy` fallback forever.
///
/// The method itself lives on `ContentView`, a view with no seam for a fake
/// ssh call, so these pin the same three calls it makes in sequence —
/// `HostsSettingsView.applyingFetchedRoot` then `HostResolution.crewsRoot`
/// then `StewardCrew.directory` — the way `evaluateStewardAtLaunch` chains
/// them, rather than exercising the private method directly.
///
/// The `~/Convivy` fallback itself is unchanged and correct — see
/// `platform/contracts/session-agent-api`: "Deck defaults its crewsRoot to
/// ~/Convivy for exactly this reason, and adds no containment check of its
/// own, since it cannot stat a path on the mini anyway." This is about the
/// retry self-healing once the real root becomes reachable, not about
/// second-guessing that default.
final class StewardLaunchRetryTests: XCTestCase {
    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-stewardlaunch-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    /// The case the fix is for: a host whose fetch never landed at add time
    /// (`crewsRoot` still nil) reaches a later launch evaluation, the fetch
    /// now succeeds, and the retry lands the real root and creates against
    /// it — never against the `~/Convivy` fallback the earlier evaluation
    /// would have used forever.
    @MainActor
    func testALaterLaunchLandsTheRootAFetchAtAddTimeMissed() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "studio", user: "u", address: "1.2.3.4"))
        XCTAssertNil(store.configuration.hosts.first?.crewsRoot,
                     "precondition: the add-time fetch never landed anything")

        let landed = HostsSettingsView.applyingFetchedRoot(
            "\(TestHost.secondaryHomeRoot)/work", toHostNamed: "studio", in: store)

        XCTAssertEqual(landed?.crewsRoot, "\(TestHost.secondaryHomeRoot)/work")
        let resolvedRoot = HostResolution.crewsRoot(
            forHostName: "studio", hosts: store.configuration.hosts,
            defaultHost: store.configuration.defaultHost,
            globalCrewsRoot: store.configuration.crewsRoot)
        XCTAssertEqual(resolvedRoot, "\(TestHost.secondaryHomeRoot)/work",
                       "the retry must resolve to the host's real root, not the fallback")
        XCTAssertEqual(StewardCrew.directory(crewsRoot: resolvedRoot), "\(TestHost.secondaryHomeRoot)/work/steward")
    }

    /// `addHost`'s own tolerance carries over: a fetch that fails on this
    /// retry too is not an error to shout about, and the create still
    /// proceeds — here, against the unchanged `~/Convivy` global fallback,
    /// exactly the documented behaviour the review confirmed is correct.
    @MainActor
    func testAFetchThatFailsAgainStillResolvesToTheDocumentedFallback() {
        let store = ThemeStore(fileURL: url())
        store.addHost(HostEntry(name: "studio", user: "u", address: "1.2.3.4"))

        let landed = HostsSettingsView.applyingFetchedRoot(
            nil, toHostNamed: "studio", in: store) ?? store.configuration.hosts.first!

        XCTAssertNil(landed.crewsRoot)
        let resolvedRoot = HostResolution.crewsRoot(
            forHostName: "studio", hosts: store.configuration.hosts,
            defaultHost: store.configuration.defaultHost,
            globalCrewsRoot: store.configuration.crewsRoot)
        XCTAssertEqual(resolvedRoot, store.configuration.crewsRoot,
                       "an unreachable retry still creates against the global ~/Convivy fallback")
    }
}
