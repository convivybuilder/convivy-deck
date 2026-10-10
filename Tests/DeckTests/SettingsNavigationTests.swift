import XCTest
@testable import Deck

/// `SettingsNavigation` — the empty state's route into Settings › Hosts
/// with the Add sheet up (`issue_01M0ECVNHX6XRT47EJJ8B5Z54T`).
@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testOpeningHostsWithAddSheetSwitchesTheTab() {
        let navigation = SettingsNavigation()
        navigation.openHostsWithAddSheet()
        XCTAssertEqual(navigation.selectedTab, .hosts)
    }

    func testOpeningHostsWithAddSheetSetsARequestToken() {
        let navigation = SettingsNavigation()
        XCTAssertNil(navigation.addHostRequestToken)
        navigation.openHostsWithAddSheet()
        XCTAssertNotNil(navigation.addHostRequestToken)
    }

    /// A SECOND click while Settings is already showing Hosts must still
    /// produce a change `onChange` can observe — a bool already `true`
    /// would not fire again.
    func testASecondRequestProducesADifferentToken() {
        let navigation = SettingsNavigation()
        navigation.openHostsWithAddSheet()
        let first = navigation.addHostRequestToken
        navigation.openHostsWithAddSheet()
        XCTAssertNotEqual(navigation.addHostRequestToken, first)
    }

    /// `HostsSettingsView` reads `addHostRequestToken` with
    /// `.onChange(initial: true)` because on a cold launch — no hosts
    /// configured, Settings never opened this process — the `Settings`
    /// scene does not exist yet when `UnresolvedHostView` calls
    /// `openHostsWithAddSheet()`. By the time the scene materializes and
    /// the observer attaches, the token is already set, so a change-only
    /// `onChange` would never fire and the Add sheet would silently not
    /// open (`issue_01M0ECVNHX6XRT47EJJ8B5Z54T`'s regression). Driving the
    /// actual SwiftUI scene-materialization timing is out of reach for
    /// XCTest here (no ViewInspector/XCUITest in this target — see the PR
    /// body), so this pins the piece that IS at the model layer: consuming
    /// a request must be one-shot, since `initial: true` re-reads whatever
    /// value is currently set, and a token left non-nil would re-open the
    /// sheet on any later re-materialization of the view.
    func testConsumingAnAddHostRequestClearsTheToken() {
        let navigation = SettingsNavigation()
        navigation.openHostsWithAddSheet()
        XCTAssertTrue(navigation.consumeAddHostRequest())
        XCTAssertNil(navigation.addHostRequestToken)
    }

    /// Consuming with nothing pending — the token already nil, as it is on
    /// every `initial: true` read except a genuine unread request — is a
    /// no-op that reports there was nothing to act on, so a caller can tell
    /// a real request from a stale re-fire.
    func testConsumingWithNoPendingRequestReportsNothingToConsume() {
        let navigation = SettingsNavigation()
        XCTAssertFalse(navigation.consumeAddHostRequest())
        XCTAssertNil(navigation.addHostRequestToken)
    }

    /// The regression this PR fixes: consume, then request again. Before
    /// the fix, `isAdding` was driven off a change-only `onChange`, so a
    /// token that was already set at attach time (the cold-launch case)
    /// was invisible to it. This test does not exercise that timing
    /// directly — it can't, without a view-hosting harness — but it pins
    /// that the token IS one-shot, which is what makes `initial: true`
    /// safe to add rather than a source of repeat unbidden sheet opens.
    func testARequestAfterConsumingProducesAFreshToken() {
        let navigation = SettingsNavigation()
        navigation.openHostsWithAddSheet()
        navigation.consumeAddHostRequest()
        navigation.openHostsWithAddSheet()
        XCTAssertNotNil(navigation.addHostRequestToken)
    }

    /// `MissingDirectoryView`'s route (`issue_01M1KXWJDHMDATQM5K57FQ2PE7`) —
    /// no request token, unlike Hosts: there is no sheet to open, only the
    /// existing row to select in the list `SessionsSettingsView` already
    /// draws.
    func testOpeningSessionsSettingsSwitchesTheTab() {
        let navigation = SettingsNavigation()
        navigation.openSessionsSettings()
        XCTAssertEqual(navigation.selectedTab, .sessions)
    }
}
