import XCTest
@testable import Deck

/// `DesktopSessionTracker.apply` — the one-alert-per-transition rule
/// (CQ·124), pinned without an ssh round trip.
final class DesktopSessionTrackerTests: XCTestCase {
    func testTheFirstReadingEverBeingLoggedOutRaisesAnAlert() {
        let (next, notify) = DesktopSessionTracker.apply(reading: .loggedOut, lastKnown: nil)
        XCTAssertEqual(next, .loggedOut)
        XCTAssertTrue(notify, "the first reading counts as a transition, per CQ·124's own wording")
    }

    func testTheFirstReadingEverBeingLoggedInRaisesNoAlert() {
        let (next, notify) = DesktopSessionTracker.apply(reading: .loggedIn, lastKnown: nil)
        XCTAssertEqual(next, .loggedIn)
        XCTAssertFalse(notify)
    }

    func testLoggedInToLoggedOutRaisesAnAlert() {
        let (next, notify) = DesktopSessionTracker.apply(reading: .loggedOut, lastKnown: .loggedIn)
        XCTAssertEqual(next, .loggedOut)
        XCTAssertTrue(notify)
    }

    /// The state HOLDS, so a second logged-out reading in a row must not
    /// raise a second alert — CQ·124: "Don't repeat it while the state holds."
    func testLoggedOutToLoggedOutDoesNotRaiseAnotherAlert() {
        let (next, notify) = DesktopSessionTracker.apply(reading: .loggedOut, lastKnown: .loggedOut)
        XCTAssertEqual(next, .loggedOut)
        XCTAssertFalse(notify)
    }

    /// CQ·124: "Notify again only after a logged-in reading followed by
    /// another logged-out one."
    func testLoggedOutThenLoggedInThenLoggedOutRaisesAnAlertAgain() {
        var known: DesktopSessionKnownState? = .loggedOut
        (known, _) = DesktopSessionTracker.apply(reading: .loggedIn, lastKnown: known)
        let (next, notify) = DesktopSessionTracker.apply(reading: .loggedOut, lastKnown: known)
        XCTAssertEqual(next, .loggedOut)
        XCTAssertTrue(notify, "a logged-in reading in between must re-arm the alert")
    }

    /// CQ·124: "A run of unknown readings doesn't reset or trigger
    /// anything" — the known state passes through unchanged, whatever it
    /// was, and no alert is raised.
    func testAnUnknownReadingHoldsTheKnownStateAndNeverRaisesAnAlert() {
        for lastKnown: DesktopSessionKnownState? in [nil, .loggedIn, .loggedOut] {
            let (next, notify) = DesktopSessionTracker.apply(reading: .unknown, lastKnown: lastKnown)
            XCTAssertEqual(next, lastKnown)
            XCTAssertFalse(notify)
        }
    }

    /// A run of unknowns between two logged-out readings must not let the
    /// second one raise an alert again — the known state survived the unknowns
    /// unchanged, so the gate still reads "already logged out."
    func testUnknownReadingsBetweenTwoLoggedOutReadingsDoNotReArmTheAlert() {
        var known: DesktopSessionKnownState? = .loggedOut
        (known, _) = DesktopSessionTracker.apply(reading: .unknown, lastKnown: known)
        (known, _) = DesktopSessionTracker.apply(reading: .unknown, lastKnown: known)
        let (next, notify) = DesktopSessionTracker.apply(reading: .loggedOut, lastKnown: known)
        XCTAssertEqual(next, .loggedOut)
        XCTAssertFalse(notify)
    }
}
