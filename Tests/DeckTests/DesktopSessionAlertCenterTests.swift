import XCTest
@testable import Deck

/// `DesktopSessionAlertCenter` — the logged-out alert state (CQ·130): one
/// alert per transition, cleared when the host reads logged in again, two
/// hosts kept apart, and the runbook and no-runbook variants. No test
/// touches a notification center, because none exists any more.
@MainActor
final class DesktopSessionAlertCenterTests: XCTestCase {
    private let macmini = HostEntry(name: "macmini", user: "builder-rehearsal", address: "10.0.0.9")
    private let estudio = HostEntry(name: "estudio", user: "operator", address: "10.0.0.12")

    private func target(_ host: HostEntry) -> SSHTarget {
        SSHTarget(user: host.user, host: host.address)
    }

    func testLoggedOutTransitionRaisesOneAlertNamingTheHostAndAccount() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini])

        XCTAssertEqual(center.alerts.count, 1)
        XCTAssertEqual(center.alerts.first?.hostName, "macmini")
        XCTAssertEqual(center.alerts.first?.account, "builder-rehearsal")
    }

    /// A target that no longer matches any configured host — removed from
    /// Settings between the poll dispatching and landing — raises nothing.
    func testLoggedOutForAnUnknownTargetRaisesNothing() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: SSHTarget(user: "nobody", host: "nowhere"), hosts: [macmini])

        XCTAssertTrue(center.alerts.isEmpty)
    }

    /// The tracker already gates this to once per transition; a second raise
    /// for the same host still must not stack a second alert.
    func testRaisingTheSameHostTwiceKeepsOneAlert() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini])
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini])

        XCTAssertEqual(center.alerts.count, 1)
    }

    /// Two hosts logging out show two alerts, and dismissing one leaves the
    /// other on screen.
    func testTwoHostsLoggingOutShowTwoAlertsAndDismissingOneKeepsTheOther() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini, estudio])
        center.raiseLoggedOut(target: target(estudio), hosts: [macmini, estudio])

        XCTAssertEqual(center.alerts.map(\.hostName), ["macmini", "estudio"])

        center.dismiss(hostName: "macmini")

        XCTAssertEqual(center.alerts.map(\.hostName), ["estudio"])
    }

    func testDismissRemovesTheAlert() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini])
        center.dismiss(hostName: "macmini")

        XCTAssertTrue(center.alerts.isEmpty)
    }

    /// A dismissed alert stays down while the host is still logged out, since
    /// the tracker never re-raises within one transition. Reconciling against
    /// that same state must not bring it back either.
    func testADismissedAlertStaysDownWhileTheHostIsStillLoggedOut() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini])
        center.dismiss(hostName: "macmini")
        center.reconcile(knownStates: [target(macmini): .loggedOut], hosts: [macmini])

        XCTAssertTrue(center.alerts.isEmpty)
    }

    /// A host reading logged in clears its alert. Without this, the alert
    /// would sit on screen after the account is back.
    func testALoggedInReadingClearsThatHostsAlertOnly() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini, estudio])
        center.raiseLoggedOut(target: target(estudio), hosts: [macmini, estudio])

        center.reconcile(
            knownStates: [target(macmini): .loggedIn, target(estudio): .loggedOut],
            hosts: [macmini, estudio])

        XCTAssertEqual(center.alerts.map(\.hostName), ["estudio"])
    }

    /// An unknown reading never reaches the known states: `DesktopSessionTracker`
    /// holds the last definite state through it, so the alert survives a run of
    /// unknown polls.
    func testAnUnknownReadingDoesNotClearTheAlert() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini])

        var known: DesktopSessionKnownState? = .loggedOut
        (known, _) = DesktopSessionTracker.apply(reading: .unknown, lastKnown: known)
        (known, _) = DesktopSessionTracker.apply(reading: .unknown, lastKnown: known)
        center.reconcile(knownStates: [target(macmini): known!], hosts: [macmini])

        XCTAssertEqual(center.alerts.map(\.hostName), ["macmini"])
    }

    /// A host removed from Settings drops its alert, even if its last known
    /// state still reads logged out.
    func testARemovedHostDropsItsAlert() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini])
        center.reconcile(knownStates: [target(macmini): .loggedOut], hosts: [])

        XCTAssertTrue(center.alerts.isEmpty)
    }

    /// The full cycle: log out, clear on logged in, log out again. The second
    /// logout is a new transition and must raise a fresh alert, which the
    /// tracker reports as `notify` only because the reading went back to
    /// logged in in between.
    func testALogoutAfterALoginRaisesAFreshAlert() {
        let center = DesktopSessionAlertCenter()
        var known: DesktopSessionKnownState? = .loggedIn

        var (next, notify) = DesktopSessionTracker.apply(reading: .loggedOut, lastKnown: known)
        known = next
        if notify { center.raiseLoggedOut(target: target(macmini), hosts: [macmini]) }
        XCTAssertEqual(center.alerts.count, 1)

        center.reconcile(knownStates: [target(macmini): .loggedIn], hosts: [macmini])
        XCTAssertTrue(center.alerts.isEmpty)

        (next, notify) = DesktopSessionTracker.apply(reading: .loggedOut, lastKnown: .loggedIn)
        known = next
        if notify { center.raiseLoggedOut(target: target(macmini), hosts: [macmini]) }
        XCTAssertEqual(known, .loggedOut)
        XCTAssertEqual(center.alerts.map(\.hostName), ["macmini"])
    }

    // MARK: - The runbook variant

    func testAValidHTTPSRunbookIsCarriedAsAURL() {
        let host = HostEntry(
            name: "macmini", user: "builder-rehearsal", address: "10.0.0.9",
            runbookLink: "https://example.com/runbook")
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(host), hosts: [host])

        XCTAssertEqual(center.alerts.first?.runbook, .url(URL(string: "https://example.com/runbook")!))
    }

    func testAKBIdRunbookIsCarriedAsAKBRef() {
        let host = HostEntry(
            name: "macmini", user: "builder-rehearsal", address: "10.0.0.9",
            runbookLink: "shipwright/runbooks/log-your-builder-account-back-in-after-a-restart")
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(host), hosts: [host])

        XCTAssertEqual(
            center.alerts.first?.runbook,
            .kb(id: "shipwright/runbooks/log-your-builder-account-back-in-after-a-restart"))
    }

    /// A stored link that `RunbookLink.parse` refuses gives the no-runbook
    /// variant, so the alert never offers a runbook it cannot open.
    func testAnInvalidStoredRunbookGivesTheNoRunbookVariant() {
        let host = HostEntry(
            name: "macmini", user: "builder-rehearsal", address: "10.0.0.9",
            runbookLink: "http://example.com/runbook")
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(host), hosts: [host])

        XCTAssertNil(center.alerts.first?.runbook)
    }

    func testAHostWithNoRunbookGivesTheNoRunbookVariant() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini])

        XCTAssertNil(center.alerts.first?.runbook)
    }

    /// Open Runbook hands the stored text to the shell, which re-validates it
    /// with `RunbookLink.parse` before opening anything.
    func testOpenRunbookPassesTheStoredLinkAndConsumeClearsIt() {
        let host = HostEntry(
            name: "macmini", user: "builder-rehearsal", address: "10.0.0.9",
            runbookLink: "https://example.com/runbook")
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(host), hosts: [host])
        center.openRunbook(for: center.alerts[0])

        XCTAssertEqual(center.pendingRunbookOpen?.hostName, "macmini")
        XCTAssertEqual(center.pendingRunbookOpen?.rawLink, "https://example.com/runbook")
        XCTAssertEqual(center.alerts.count, 1, "opening a runbook does not clear the alert")

        center.consumePendingRunbookOpen()
        XCTAssertNil(center.pendingRunbookOpen)
    }

    /// Each press is a fresh request, so pressing twice for the same host is
    /// acted on twice.
    func testEachOpenRunbookPressGetsAFreshToken() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini])
        center.openRunbook(for: center.alerts[0])
        let first = center.pendingRunbookOpen
        center.consumePendingRunbookOpen()
        center.openRunbook(for: center.alerts[0])
        let second = center.pendingRunbookOpen

        XCTAssertNotEqual(first, second)
    }

    func testOpenRunbookWithNoRunbookPassesNilSoTheShellSelectsTheHostRow() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini])
        center.openRunbook(for: center.alerts[0])

        XCTAssertEqual(center.pendingRunbookOpen?.hostName, "macmini")
        XCTAssertNil(center.pendingRunbookOpen?.rawLink)
    }

    // MARK: - The Screen Sharing button

    func testAHostNameBuildsTheVNCURLForItsAddress() {
        let tailnetHost = "macmini.example.com"
        let host = HostEntry(name: "macmini", user: "builder-rehearsal", address: tailnetHost)
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(host), hosts: [host])

        XCTAssertEqual(center.alerts.first?.screenSharing, URL(string: "vnc://\(tailnetHost)"))
    }

    func testAnIPAddressBuildsTheVNCURLForItsAddress() {
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini])

        XCTAssertEqual(center.alerts.first?.screenSharing, URL(string: "vnc://10.0.0.9"))
    }

    /// An address that `validateHostAddress` refuses (here a leading `-`, the
    /// case that reads as an option flag) forms no URL, so the alert draws no
    /// Screen Sharing button.
    func testAnAddressThatCannotFormAVNCURLGivesNoScreenSharingButton() {
        let host = HostEntry(name: "macmini", user: "builder-rehearsal", address: "-oProxyCommand=x")
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(host), hosts: [host])

        XCTAssertNil(center.alerts.first?.screenSharing)
        XCTAssertEqual(center.alerts.first?.buttons, [])
    }

    /// The button set per branch: a runbook adds Open Runbook, a reachable
    /// address adds Open Screen Sharing, and the two sit together when both hold.
    func testEachBranchDrawsItsOwnButtons() {
        let withRunbook = HostEntry(
            name: "macmini", user: "builder-rehearsal", address: "10.0.0.9",
            runbookLink: "https://example.com/runbook")
        let center = DesktopSessionAlertCenter()
        center.raiseLoggedOut(target: target(withRunbook), hosts: [withRunbook])
        XCTAssertEqual(center.alerts.first?.buttons, [.openRunbook, .openScreenSharing])

        center.dismiss(hostName: "macmini")
        center.raiseLoggedOut(target: target(macmini), hosts: [macmini])
        XCTAssertEqual(center.alerts.first?.buttons, [.openScreenSharing])

        let unreachable = HostEntry(name: "macmini", user: "builder-rehearsal", address: "-oBad")
        center.dismiss(hostName: "macmini")
        center.raiseLoggedOut(target: target(unreachable), hosts: [unreachable])
        XCTAssertEqual(center.alerts.first?.buttons, [])
    }
}
