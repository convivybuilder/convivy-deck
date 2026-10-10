import XCTest
@testable import Deck

/// `PinnedSessionReconcile.reconciling` — the pure rule that follows a
/// pinned sibling session through a tmux rename. See that type's doc for
/// the three rules and `ThemeStoreReconcilePinnedSessionsTests` for the
/// config-level driver these feed into.
final class PinnedSessionReconcileTests: XCTestCase {
    private let mini = TestHost.target

    private func discovered(_ name: String, sessionId: String? = nil) -> DiscoveredSession {
        DiscoveredSession(name: name, host: mini, sessionId: sessionId)
    }

    // MARK: - Rule (a): id match, name follows

    func testAPinWithAMatchingIdFollowsTheLiveSessionToItsNewName() {
        let pin = PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$19")
        let outcome = PinnedSessionReconcile.reconciling(
            [pin], discovered: [discovered("ask--research-v2", sessionId: "$19")])

        XCTAssertEqual(outcome.sessions, [
            PinnedSession(name: "ask--research-v2", displayName: "Research", sessionId: "$19"),
        ], "the name moves but displayName — the user's own label — is kept")
        XCTAssertEqual(outcome.renames, [.init(from: "ask--research", to: "ask--research-v2")])
    }

    /// An id match whose name already agrees is simply left alone — no
    /// rename to report, and the pin is unchanged.
    func testAnIdMatchWithNoNameChangeReportsNoRename() {
        let pin = PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$19")
        let outcome = PinnedSessionReconcile.reconciling(
            [pin], discovered: [discovered("ask--research", sessionId: "$19")])

        XCTAssertEqual(outcome.sessions, [pin])
        XCTAssertEqual(outcome.renames, [])
    }

    /// tmux accepts a name Deck's own config loader rejects. Following the
    /// rename would save a pin that `ThemeConfiguration.parseSessions` drops
    /// on the next launch, so the pin keeps its old name and id instead.
    func testAPinDoesNotFollowARenameToANameTheConfigLoaderWouldDrop() {
        let pin = PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$19")
        let outcome = PinnedSessionReconcile.reconciling(
            [pin], discovered: [discovered("My Research", sessionId: "$19")])

        XCTAssertEqual(outcome.sessions, [pin], "an unloadable name must not replace a loadable one")
        XCTAssertEqual(outcome.renames, [])
    }

    // MARK: - Rule (b): name match records the live id

    /// No id on the pin at all — the common case for every pin written
    /// before this feature — but a discovered session answers to its exact
    /// name: the pin adopts that session's id so a LATER rename has
    /// something to match by by rule (a).
    func testANameMatchWithNoPriorIdRecordsTheLiveId() {
        let pin = PinnedSession(name: "ask--research", displayName: "Research")
        let outcome = PinnedSessionReconcile.reconciling(
            [pin], discovered: [discovered("ask--research", sessionId: "$19")])

        XCTAssertEqual(outcome.sessions, [
            PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$19"),
        ])
        XCTAssertEqual(outcome.renames, [], "the name did not change, only the id was recorded")
    }

    /// The pin's id no longer matches anything live (that session is gone),
    /// but a session with the pin's exact name exists — a different session
    /// has taken over the name. The pin's old id is replaced, not kept
    /// alongside the new one.
    func testAStaleIdIsReplacedWhenADifferentSessionNowHoldsTheName() {
        let pin = PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$old")
        let outcome = PinnedSessionReconcile.reconciling(
            [pin], discovered: [discovered("ask--research", sessionId: "$new")])

        XCTAssertEqual(outcome.sessions, [
            PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$new"),
        ])
        XCTAssertEqual(outcome.renames, [])
    }

    // MARK: - Rule (c): no match at all leaves the pin alone

    func testAPinMatchingNothingIsLeftExactlyAsItWas() {
        let pin = PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$19")
        let outcome = PinnedSessionReconcile.reconciling(
            [pin], discovered: [discovered("ask--unrelated", sessionId: "$99")])

        XCTAssertEqual(outcome.sessions, [pin])
        XCTAssertEqual(outcome.renames, [])
    }

    func testAPinIsNeverRemovedEvenWithNoDiscoveredSessionsAtAll() {
        let pin = PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$19")
        let outcome = PinnedSessionReconcile.reconciling([pin], discovered: [])

        XCTAssertEqual(outcome.sessions, [pin])
    }

    // MARK: - No double-claim

    /// Two pins, one live session carrying an id that matches only the
    /// first pin's id — the second pin must not also claim it via the name
    /// rule once the first has already taken it.
    func testASessionAlreadyClaimedByIdIsNotAlsoClaimedByNameForAnotherPin() {
        let claimedByFirst = PinnedSession(name: "ask--old-name", displayName: "First", sessionId: "$19")
        let matchesSecondByNameOnly = PinnedSession(name: "ask--research", displayName: "Second")
        let outcome = PinnedSessionReconcile.reconciling(
            [claimedByFirst, matchesSecondByNameOnly],
            discovered: [discovered("ask--research", sessionId: "$19")])

        XCTAssertEqual(outcome.sessions, [
            PinnedSession(name: "ask--research", displayName: "First", sessionId: "$19"),
            PinnedSession(name: "ask--research", displayName: "Second"),
        ], "the first pin claims the only live session by id; the second is left unmatched")
        XCTAssertEqual(outcome.renames, [.init(from: "ask--old-name", to: "ask--research")])
    }

    /// The same guarantee from the other direction: two pins whose names
    /// could both match the SAME discovered session by name — only the
    /// first (in list order) claims it.
    func testTwoPinsSharingANameMatchOnlyTheFirstClaimsTheSession() {
        let first = PinnedSession(name: "ask--research", displayName: "First")
        let second = PinnedSession(name: "ask--research", displayName: "Second")
        let outcome = PinnedSessionReconcile.reconciling(
            [first, second], discovered: [discovered("ask--research", sessionId: "$19")])

        XCTAssertEqual(outcome.sessions, [
            PinnedSession(name: "ask--research", displayName: "First", sessionId: "$19"),
            PinnedSession(name: "ask--research", displayName: "Second"),
        ])
    }

    // MARK: - No-change-means-no-write, at the pure level

    /// The property `ThemeStore.reconcilePinnedSessions` depends on to skip
    /// writing `theme.json`: nothing to reconcile leaves the array
    /// identical, not merely equivalent.
    func testFullyReconciledPinsProduceAnIdenticalArrayAndNoRenames() {
        let pins = [
            PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$19"),
            PinnedSession(name: "ask--tax-2025", displayName: "Tax"),
        ]
        let outcome = PinnedSessionReconcile.reconciling(
            pins, discovered: [discovered("ask--research", sessionId: "$19")])

        XCTAssertEqual(outcome.sessions, pins)
        XCTAssertEqual(outcome.renames, [])
    }
}
