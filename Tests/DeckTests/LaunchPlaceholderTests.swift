import XCTest
@testable import Deck

/// `ContentView.showsLaunchPlaceholder`: the predicate that decides whether
/// the launch placeholder covers the pane, in place of the branch-switching
/// flicker the operator reported — "a flicker of the construction of the session
/// window, then back to splash, then eventually a session window that starts
/// populating."
///
/// Pure arithmetic on four booleans and a duration, so the properties that
/// matter are directly testable with no view, no model, and no poll: it
/// appears the instant a launch begins, clears once there is real evidence of
/// how the session resolved, and — since 2026-08-17 — also clears once it has
/// been up too long for "still loading" to remain an honest thing to say. See
/// the elapsed-time section below for why that exception exists.
///
/// THE FOURTH BOOLEAN IS THE WHOLE POINT and the earlier three-argument
/// version was inert without it. `isStopped` is already true when the user
/// presses Start on a stopped session — it is why `StartSessionView` is on
/// screen — so a predicate that reads it at face value treats its own
/// precondition as a verdict on the launch that follows. Restarting is the
/// common path, and every case below that pairs a reading with its age exists
/// because of it.
final class LaunchPlaceholderTests: XCTestCase {

    /// The button press. `launchPending` is entered synchronously, before
    /// `SessionAgent.start` is even dispatched, so this must read true with
    /// no poll having happened yet.
    func testAppearsImmediatelyOnLaunchWithNoReadingYet() {
        XCTAssertTrue(ContentView.showsLaunchPlaceholder(
            launchPending: true, isAlive: false, isStopped: false,
            hasReadingSinceLaunch: false, elapsedSinceLaunch: 0))
    }

    /// THE RESTART PATH, which is what a user actually does. The rail said
    /// stopped before the press and has not polled since; that reading is the
    /// reason the Start button was there, not evidence the start failed.
    func testAppearsOnARestartWhereTheStaleReadingSaysStopped() {
        XCTAssertTrue(ContentView.showsLaunchPlaceholder(
            launchPending: true, isAlive: false, isStopped: true,
            hasReadingSinceLaunch: false, elapsedSinceLaunch: 0))
    }

    /// The same shape for a stale ALIVE reading. Unreachable through the Start
    /// button today, which requires a stopped row, but the rule is about the
    /// reading's age rather than which answer it carries, and a predicate that
    /// held only for one of the two answers would be true by accident.
    func testAppearsWhenTheOnlyReadingPredatesTheLaunch() {
        XCTAssertTrue(ContentView.showsLaunchPlaceholder(
            launchPending: true, isAlive: true, isStopped: false,
            hasReadingSinceLaunch: false, elapsedSinceLaunch: 0))
    }

    /// The rail has real evidence now — the placeholder comes down, whatever
    /// `launchPending`'s own bookkeeping says. This is the guard that keeps
    /// the placeholder from outliving its purpose even if `launchPending`
    /// were never pruned.
    func testClearsTheMomentTheRailConfirmsAlive() {
        XCTAssertFalse(ContentView.showsLaunchPlaceholder(
            launchPending: true, isAlive: true, isStopped: false,
            hasReadingSinceLaunch: true, elapsedSinceLaunch: 0))
    }

    /// `SessionAgent.start` returns successfully, so nothing clears
    /// `launchPending` on that path, but the agent inside the new session
    /// dies immediately — wrong working directory, missing command, an
    /// ordinary launch crash — and a poll taken AFTER the launch reports the
    /// session stopped rather than alive. Without this case the placeholder
    /// covers `StartSessionView`'s own Start and Terminal buttons with no way
    /// out short of quitting Deck.
    func testClearsWhenAPollAfterTheLaunchConfirmsStopped() {
        XCTAssertFalse(ContentView.showsLaunchPlaceholder(
            launchPending: true, isAlive: false, isStopped: true,
            hasReadingSinceLaunch: true, elapsedSinceLaunch: 0))
    }

    /// A fresh poll that landed while the session is still coming up says
    /// neither alive nor stopped — the rail has not decided. Freshness alone
    /// must not bring the placeholder down, or the flicker returns for exactly
    /// as long as the session takes to answer.
    func testStaysUpWhenAFreshReadingIsStillUndecided() {
        XCTAssertTrue(ContentView.showsLaunchPlaceholder(
            launchPending: true, isAlive: false, isStopped: false,
            hasReadingSinceLaunch: true, elapsedSinceLaunch: 0))
    }

    // MARK: - No poll can resolve a launch before the session exists

    /// THE WINDOW BETWEEN THE PRESS AND THE SESSION EXISTING. `SessionAgent.start`
    /// and `SessionAgent.states` are separate ssh invocations over one
    /// ControlMaster with no ordering between them, so a routine 4-second tick
    /// can land inside a launch's own round trip. That poll answers "stopped"
    /// correctly — about a tmux session the mini has not created yet — and it
    /// is genuinely freshly issued, so no ticket comparison can disqualify it.
    /// Only the start call returning can. Until it does, `decidableFrom` is
    /// nil and the placeholder holds.
    func testNoReadingIsAdmissibleUntilTheStartCallReturns() {
        let inFlight = ContentView.LaunchInFlight()
        XCTAssertNil(inFlight.decidableFrom,
                     "a launch whose start call has not returned admits no poll")

        // Which is what the call site turns into `hasReadingSinceLaunch: false`,
        // and the predicate holds the placeholder up on exactly that.
        XCTAssertTrue(ContentView.showsLaunchPlaceholder(
            launchPending: true, isAlive: false, isStopped: true,
            hasReadingSinceLaunch: false, elapsedSinceLaunch: 0))
    }

    /// Once the start call has returned the session exists, so a poll issued
    /// from then on is a real verdict — including a "stopped" one, which is the
    /// launch-failed case the placeholder must come down for.
    func testAPollIssuedAfterTheSessionExistsDecidesIt() {
        var inFlight = ContentView.LaunchInFlight()
        inFlight.decidableFrom = 12
        XCTAssertFalse(ContentView.hasReadingSinceLaunch(reading: 11, launchedAt: 12))
        XCTAssertTrue(ContentView.hasReadingSinceLaunch(reading: 12, launchedAt: 12))
    }

    // MARK: - Which readings count as taken after the launch

    /// THE POLL ALREADY IN FLIGHT AT THE PRESS. A rail poll is an ssh round
    /// trip: one issued at 3.9s into a 4s interval asked the mini before the
    /// user pressed Start, and lands after. Dating readings by arrival stamped
    /// that answer newer than the press, so the placeholder cleared mid-launch
    /// on the stale "stopped" it carried — the round-1 bug again, narrowed to
    /// one round trip per interval. Ticketing at dispatch is what puts it back
    /// where it belongs.
    func testAPollIssuedBeforeThePressIsNotAReadingSinceTheLaunch() {
        // Poll 6 is dispatched, so the next ticket is 7 when the press lands.
        XCTAssertFalse(ContentView.hasReadingSinceLaunch(reading: 6, launchedAt: 7))
    }

    /// The first poll issued after the press carries exactly the captured
    /// ticket — the earliest reading entitled to an opinion about this launch,
    /// which is why the comparison is `>=` and not `>`.
    func testTheFirstPollIssuedAfterThePressCounts() {
        XCTAssertTrue(ContentView.hasReadingSinceLaunch(reading: 7, launchedAt: 7))
        XCTAssertTrue(ContentView.hasReadingSinceLaunch(reading: 8, launchedAt: 7))
    }

    /// Before any poll has landed the reading is -1, below every ticket a press
    /// can capture, so a launch pressed at app start holds the placeholder up
    /// rather than clearing on nothing.
    func testNoPollHasLandedYet() {
        XCTAssertFalse(ContentView.hasReadingSinceLaunch(reading: -1, launchedAt: 0))
    }

    /// A session that was never launched through this pane at all — an
    /// ordinary selection, or a genuinely stopped row showing
    /// `StartSessionView`. Neither is the artifact this covers, and the
    /// placeholder must not paper over a stopped session forever. True for
    /// every combination of the other three, since `launchPending` decides
    /// this one on its own.
    func testNeverAppearsForASessionThatWasNotLaunched() {
        for isAlive in [true, false] {
            for isStopped in [true, false] {
                for fresh in [true, false] {
                    XCTAssertFalse(ContentView.showsLaunchPlaceholder(
                        launchPending: false, isAlive: isAlive,
                        isStopped: isStopped, hasReadingSinceLaunch: fresh,
                        elapsedSinceLaunch: 0),
                        "alive=\(isAlive) stopped=\(isStopped) fresh=\(fresh)")
                }
            }
        }
    }

    // MARK: - The elapsed-time bound (2026-08-17 incident)

    /// A transport failure reads exactly like "not polled yet" through
    /// `isAlive`/`isStopped` alone — `RailStateModel.isStopped`'s own doc
    /// says a transport failure is deliberately NOT stopped, and it is
    /// obviously not alive either — so a host that will never answer sits in
    /// the same ambiguous branch as one that answered a beat ago. Short of the
    /// bound this predicate must still hold the placeholder up on that
    /// ambiguity, exactly as it always has: this is the same case
    /// `testStaysUpWhenAFreshReadingIsStillUndecided` covers, just below the
    /// new threshold instead of at zero.
    func testStaysUpBeforeTheElapsedBound() {
        XCTAssertTrue(ContentView.showsLaunchPlaceholder(
            launchPending: true, isAlive: false, isStopped: false,
            hasReadingSinceLaunch: true,
            elapsedSinceLaunch: ContentView.launchPlaceholderTimeout - 1))
    }

    /// Past the bound the placeholder comes down even though nothing else
    /// changed — the one case this predicate now decides on a timer, and the
    /// reason it exists: see `showsLaunchPlaceholder`'s doc for the incident.
    func testClearsPastTheElapsedBoundEvenWithNoReadingAtAll() {
        XCTAssertFalse(ContentView.showsLaunchPlaceholder(
            launchPending: true, isAlive: false, isStopped: false,
            hasReadingSinceLaunch: false,
            elapsedSinceLaunch: ContentView.launchPlaceholderTimeout))
    }

    /// The bound applies to the "still undecided" branch just as much as to
    /// "no reading yet" — both are the shape a truly dead host produces
    /// forever, so both must give up on the same clock.
    func testClearsPastTheElapsedBoundWhenAFreshReadingIsStillUndecided() {
        XCTAssertFalse(ContentView.showsLaunchPlaceholder(
            launchPending: true, isAlive: false, isStopped: false,
            hasReadingSinceLaunch: true,
            elapsedSinceLaunch: ContentView.launchPlaceholderTimeout))
    }

    /// The bound does not fire early for a launch that resolves normally —
    /// clearing on real evidence is unconditional on elapsed time, the same
    /// as it always was.
    func testRealEvidenceStillClearsItRegardlessOfElapsedTime() {
        XCTAssertFalse(ContentView.showsLaunchPlaceholder(
            launchPending: true, isAlive: true, isStopped: false,
            hasReadingSinceLaunch: true, elapsedSinceLaunch: 0))
    }

    /// Finding #2 of the 2026-08-18 round (deck-reviewer, PR #116): the bound
    /// must sit with REAL MARGIN above the actual worst case, not just above
    /// a rough estimate of it that the doc comment got wrong by 10s. Pinning
    /// the arithmetic itself — `SessionAgent.defaultTimeout` for the first
    /// bounded attempt, `SSHControlSocket.checkTimeout` for `check`, the same
    /// bound again for `clear`'s config-resolve step, and a second
    /// `defaultTimeout` for the retry — means a change to any of those three
    /// inputs is caught here rather than by the doc comment quietly going
    /// stale again.
    func testLaunchPlaceholderTimeoutHasRealMarginAboveTheStaleSocketRecoveryWorstCase() {
        let worstCase = 2 * SessionAgent.defaultTimeout + 2 * SSHControlSocket.checkTimeout
        XCTAssertGreaterThan(ContentView.launchPlaceholderTimeout, worstCase,
                             "the placeholder must outlast a full check+clear+retry cycle, not equal or fall short of it")
    }

    /// `LaunchInFlight` carries its own start time, which is what
    /// `elapsedSinceLaunch` is measured from at the call site — a fresh one
    /// reads as just started, not as already timed out.
    func testLaunchInFlightStampsItsOwnStartTime() {
        let inFlight = ContentView.LaunchInFlight()
        XCTAssertLessThan(Date().timeIntervalSince(inFlight.startedAt), 1,
                          "a freshly constructed LaunchInFlight should not read as already elapsed")
    }
}
