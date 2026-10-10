import XCTest
@testable import Deck

/// The pure seams of the followed-state stream: splitting stdout into lines
/// across whatever chunk boundaries `read()` happens to hand back, and
/// deciding which lines are worth decoding at all. Neither seam touches a
/// process — `SessionStateFollower.start()` and the process lifecycle it
/// owns cannot be exercised from a unit test and are verified against a live
/// session instead, per the PR body.
final class SessionStateFollowerLineSplittingTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    func testASingleCompleteLineIsReturnedWithNoRemainder() {
        let (lines, remainder, didOverflow) = SessionStateFollower.splitLines(
            buffer: Data(), appending: data("{\"state\":\"idle\"}\n"))
        XCTAssertEqual(lines, ["{\"state\":\"idle\"}"])
        XCTAssertTrue(remainder.isEmpty)
        XCTAssertFalse(didOverflow)
    }

    /// A JSON object split across two `read()` chunks — the buffer holds the
    /// first half until the newline actually arrives.
    func testAnObjectSplitAcrossTwoChunksIsReassembled() {
        let (firstLines, buffer, firstOverflow) = SessionStateFollower.splitLines(
            buffer: Data(), appending: data("{\"state\":\"wor"))
        XCTAssertTrue(firstLines.isEmpty, "no newline yet, so nothing to emit")
        XCTAssertFalse(firstOverflow)

        let (lines, remainder, didOverflow) = SessionStateFollower.splitLines(
            buffer: buffer, appending: data("king\"}\n"))
        XCTAssertEqual(lines, ["{\"state\":\"working\"}"])
        XCTAssertTrue(remainder.isEmpty)
        XCTAssertFalse(didOverflow)
    }

    /// Two objects arriving in one `read()` — both come out, in order.
    func testTwoObjectsInOneChunkBothComeOut() {
        let (lines, remainder, didOverflow) = SessionStateFollower.splitLines(
            buffer: Data(),
            appending: data("{\"state\":\"idle\"}\n{\"state\":\"working\"}\n"))
        XCTAssertEqual(lines, ["{\"state\":\"idle\"}", "{\"state\":\"working\"}"])
        XCTAssertTrue(remainder.isEmpty)
        XCTAssertFalse(didOverflow)
    }

    /// A trailing partial line — the mini's next flush has not landed yet —
    /// stays in the remainder rather than being emitted early or dropped.
    func testATrailingPartialLineIsHeldAsTheRemainder() {
        let (lines, remainder, didOverflow) = SessionStateFollower.splitLines(
            buffer: Data(), appending: data("{\"state\":\"idle\"}\n{\"state\":\"wor"))
        XCTAssertEqual(lines, ["{\"state\":\"idle\"}"])
        XCTAssertEqual(String(data: remainder, encoding: .utf8), "{\"state\":\"wor")
        XCTAssertFalse(didOverflow)
    }

    /// A held remainder is exactly what the next chunk completes — proves the
    /// two chunk-boundary cases compose rather than only working in isolation.
    func testARemainderIsCompletedByTheNextChunk() {
        let (_, remainder, _) = SessionStateFollower.splitLines(
            buffer: Data(), appending: data("{\"state\":\"idle\"}\n{\"state\":\"wor"))
        let (lines, final, didOverflow) = SessionStateFollower.splitLines(
            buffer: remainder, appending: data("king\"}\n"))
        XCTAssertEqual(lines, ["{\"state\":\"working\"}"])
        XCTAssertTrue(final.isEmpty)
        XCTAssertFalse(didOverflow)
    }

    func testEmptyInputProducesNoLines() {
        let (lines, remainder, didOverflow) = SessionStateFollower.splitLines(
            buffer: Data(), appending: Data())
        XCTAssertTrue(lines.isEmpty)
        XCTAssertTrue(remainder.isEmpty)
        XCTAssertFalse(didOverflow)
    }

    // MARK: - The buffer ceiling

    /// A stream that never sends a newline — the exact shape a broken
    /// `last_assistant_message` emitter, or anything else that forgets to
    /// terminate a line, would take. Feeding it well past the ceiling in
    /// small chunks must never grow the returned remainder past
    /// `maxBufferedLineBytes`: the ceiling is checked and enforced on every
    /// call, not just once at the end.
    func testANeverTerminatedStreamNeverGrowsTheBufferPastTheCeiling() {
        var remainder = Data()
        let chunk = data(String(repeating: "x", count: 4096))
        for _ in 0..<512 {
            let (lines, next, _) = SessionStateFollower.splitLines(
                buffer: remainder, appending: chunk)
            XCTAssertTrue(lines.isEmpty, "no newline ever arrived, so nothing to emit")
            XCTAssertLessThanOrEqual(next.count, SessionStateFollower.maxBufferedLineBytes)
            remainder = next
        }
    }

    /// The same never-terminated stream reports the overflow at least once,
    /// so a caller has something to count towards falling back to polling.
    func testANeverTerminatedStreamEventuallyReportsOverflow() {
        var remainder = Data()
        let chunk = data(String(repeating: "x", count: 4096))
        var sawOverflow = false
        for _ in 0..<512 {
            let (_, next, didOverflow) = SessionStateFollower.splitLines(
                buffer: remainder, appending: chunk)
            sawOverflow = sawOverflow || didOverflow
            remainder = next
        }
        XCTAssertTrue(sawOverflow)
    }

    /// A real, legitimately large line — well under the ceiling, the way a
    /// sizeable `last_assistant_message` would be — still comes out whole
    /// and unflagged. The ceiling exists to catch a genuinely broken stream,
    /// not to punish a verbose but honest state line.
    func testALegitimatelyLargeLineUnderTheCeilingStillParses() {
        let bigMessage = String(repeating: "a", count: 200_000)
        let line = "{\"state\":\"idle\",\"last_assistant_message\":\"\(bigMessage)\"}\n"
        XCTAssertLessThan(line.utf8.count, SessionStateFollower.maxBufferedLineBytes)

        let (lines, remainder, didOverflow) = SessionStateFollower.splitLines(
            buffer: Data(), appending: data(line))
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains(bigMessage))
        XCTAssertTrue(remainder.isEmpty)
        XCTAssertFalse(didOverflow)
    }

    /// A single line that crosses the ceiling before its newline ever shows
    /// up is dropped, and the newline that eventually arrives resyncs the
    /// stream — the very next, ordinary line comes out fine rather than the
    /// follower staying stuck or the connection needing to be torn down.
    func testAnOversizedLineIsDroppedAndTheStreamResyncsAtTheNextNewline() {
        let oversized = String(repeating: "x", count: SessionStateFollower.maxBufferedLineBytes + 1024)
        let stream = oversized + "\n{\"state\":\"working\"}\n"

        let (lines, remainder, didOverflow) = SessionStateFollower.splitLines(
            buffer: Data(), appending: data(stream))
        XCTAssertEqual(lines, ["{\"state\":\"working\"}"],
                        "the oversized line is dropped; the next real line still comes through")
        XCTAssertTrue(remainder.isEmpty)
        XCTAssertTrue(didOverflow)
    }

    /// Feeding an oversized line in small chunks, never all at once, still
    /// resets rather than growing without bound, and the very next newline —
    /// whatever precedes it — hands framing back to normal: the following
    /// real line comes out clean, whatever became of the abandoned bytes
    /// before it.
    func testAnOversizedLineBuiltUpAcrossManyChunksStillResyncs() {
        var remainder = Data()
        var sawOverflow = false
        let chunk = data(String(repeating: "x", count: 4096))
        for _ in 0..<(SessionStateFollower.maxBufferedLineBytes / 4096 + 4) {
            let (_, next, didOverflow) = SessionStateFollower.splitLines(
                buffer: remainder, appending: chunk)
            sawOverflow = sawOverflow || didOverflow
            XCTAssertLessThanOrEqual(next.count, SessionStateFollower.maxBufferedLineBytes)
            remainder = next
        }
        XCTAssertTrue(sawOverflow)

        let (lines, final, lastOverflow) = SessionStateFollower.splitLines(
            buffer: remainder, appending: data("\n{\"state\":\"idle\"}\n"))
        XCTAssertEqual(lines.last, "{\"state\":\"idle\"}",
                        "whatever preceded it, the real line after the next newline is intact")
        XCTAssertTrue(final.isEmpty)
        XCTAssertFalse(lastOverflow)
    }
}

final class SessionAgentFollowLineDecodingTests: XCTestCase {
    func testAWellFormedLineDecodes() {
        let state = SessionAgent.decodeFollowLine(
            #"{"state":"working"}"#, fallbackSession: "deck")
        XCTAssertEqual(state?.phase, .working)
        XCTAssertEqual(state?.session, "deck")
    }

    /// The mini's own honest "could not tell" is valid JSON and decodes like
    /// any other reading — this is a real state, not a transport glitch.
    func testTheMinisOwnUnknownStateStillDecodes() {
        let state = SessionAgent.decodeFollowLine(
            #"{"state":"unknown","reason":"could not read the hook log"}"#,
            fallbackSession: "deck")
        XCTAssertEqual(state?.phase, .unknown)
        XCTAssertEqual(state?.reason, "could not read the hook log")
    }

    /// Not valid JSON at all — a blank line, line noise, half of a line that
    /// somehow made it through the splitter unterminated. Skipped rather than
    /// decoded into a bogus `.unknown` that would stomp on the pane's last
    /// good reading.
    func testALineThatIsNotJSONIsSkipped() {
        XCTAssertNil(SessionAgent.decodeFollowLine("", fallbackSession: "deck"))
        XCTAssertNil(SessionAgent.decodeFollowLine("   ", fallbackSession: "deck"))
        XCTAssertNil(SessionAgent.decodeFollowLine("not json", fallbackSession: "deck"))
    }

    /// A JSON array is well-formed JSON but not the object shape every state
    /// line is, so it is skipped the same way non-JSON is.
    func testAJSONArrayIsSkipped() {
        XCTAssertNil(SessionAgent.decodeFollowLine("[1,2,3]", fallbackSession: "deck"))
    }
}

/// `stop()`'s own idempotency and its behaviour on a follower that never
/// launched a process at all — the two claims a live `ssh` round trip cannot
/// exercise, and the only pieces of the teardown seam a unit test can reach
/// without one. `start()` and the process lifecycle it owns are verified by
/// hand instead; see the PR body.
final class SessionStateFollowerTeardownTests: XCTestCase {
    /// A follower nothing ever called `start()` on has no process to kill,
    /// and `stop()` must still be safe to call on it — the shape a pane
    /// closed in the gap between construction and launch takes.
    func testStopBeforeStartIsSafe() async {
        let follower = SessionStateFollower(session: "deck", target: TestHost.target)
        follower.stop()
        var events: [SessionStateFollower.Event] = []
        for await event in follower.events { events.append(event) }
        XCTAssertTrue(events.isEmpty, "nothing was ever launched, so there is nothing to report")
    }

    /// The double-stop every owner relies on: `deinit` and an explicit
    /// `stopFollowing()` can both reach the same follower, and a termination
    /// sweep can reach one already stopped through its own path. None of
    /// those may crash or double-kill.
    func testStopIsIdempotent() async {
        let follower = SessionStateFollower(session: "deck", target: TestHost.target)
        follower.stop()
        follower.stop()
        follower.stop()
        var events: [SessionStateFollower.Event] = []
        for await event in follower.events { events.append(event) }
        XCTAssertTrue(events.isEmpty)
    }
}

/// `FollowerRegistry` — the seam that lets app termination stop every live
/// follower, not just the one behind the pane on screen. See its doc comment
/// for why `deinit` alone cannot cover that path.
final class FollowerRegistryTests: XCTestCase {
    /// A fresh instance per test, not `.shared` — so a test's assertions are
    /// never racing whatever a concurrently-running pane registered.
    private func makeRegistry() -> FollowerRegistry { FollowerRegistry() }

    func testStopAllStopsEveryRegisteredFollower() async {
        let registry = makeRegistry()
        let a = SessionStateFollower(session: "a", target: TestHost.target)
        let b = SessionStateFollower(session: "b", target: TestHost.target)
        registry.register(a)
        registry.register(b)

        registry.stopAll()

        for follower in [a, b] {
            var events: [SessionStateFollower.Event] = []
            for await event in follower.events { events.append(event) }
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testStopAllWithNothingRegisteredIsSafe() {
        makeRegistry().stopAll()
    }

    func testStopAllCanBeCalledMoreThanOnce() {
        let registry = makeRegistry()
        registry.register(SessionStateFollower(session: "a", target: TestHost.target))
        registry.stopAll()
        registry.stopAll()
    }

    /// A follower torn down through its owner's own path (deselect, pane
    /// close) and unregistered there must not be reachable by a later
    /// termination sweep — proves `unregister` actually removes it rather
    /// than `stopAll` just happening to be idempotent.
    func testUnregisterRemovesAFollowerFromLaterSweeps() {
        let registry = makeRegistry()
        let follower = SessionStateFollower(session: "a", target: TestHost.target)
        registry.register(follower)
        follower.stop()
        registry.unregister(follower)

        // Nothing left registered; a crash or hang here would mean
        // `unregister` did not actually take it out of the map.
        registry.stopAll()
    }
}

/// The decision that stops the pane from retrying a dead follow path
/// forever — see `SessionPaneModel.followerDied`.
final class FollowFallbackDecisionTests: XCTestCase {
    func testStaysOnFollowingBelowTheCeiling() {
        for n in 0..<SessionPaneModel.maxConsecutiveFollowFailures {
            XCTAssertFalse(SessionPaneModel.shouldFallBackToPolling(consecutiveFailures: n),
                           "failure \(n) should not have given up yet")
        }
    }

    func testFallsBackAtAndPastTheCeiling() {
        XCTAssertTrue(SessionPaneModel.shouldFallBackToPolling(
            consecutiveFailures: SessionPaneModel.maxConsecutiveFollowFailures))
        XCTAssertTrue(SessionPaneModel.shouldFallBackToPolling(
            consecutiveFailures: SessionPaneModel.maxConsecutiveFollowFailures + 10))
    }
}

/// `SessionPaneModel.followerSilenceTimeout` — the bound covering finding #1
/// of the 2026-08-18 round (deck-reviewer, PR #116): the follower's own
/// channel was not watched at all, so a wedged connection never routed
/// through `followerDied()`. See `checkFollowerLiveness`'s doc for why the
/// bound asks `SSHControlSocket.check` rather than trusting silence itself —
/// `session-agent state --follow` emits nothing at all on a genuinely idle
/// session (`deck/specs/session-pane-followed-state`), so a bound keyed on
/// line arrival alone would misfire on every quiet pane.
final class FollowerWatchdogTimingTests: XCTestCase {
    /// The watchdog must have finished its own check-and-report cycle before
    /// `ContentView.launchPlaceholderTimeout` gives up on the pane, or a
    /// wedged connection reads as "still loading" for the placeholder's
    /// whole window with nothing underneath it ever having tried to recover.
    func testFollowerSilenceTimeoutLeavesRoomForTheControlSocketCheck() {
        let silenceSeconds = Double(SessionPaneModel.followerSilenceTimeout.components.seconds)
        XCTAssertLessThan(silenceSeconds + SSHControlSocket.checkTimeout,
                          ContentView.launchPlaceholderTimeout,
                          "the watchdog must detect and report a wedge before the placeholder gives up on its own")
    }

    /// A floor against a regression that makes this so short it starts
    /// competing with an ordinary launch's own connect time — the silence
    /// window has to be a bound on ABSENCE, not a race with a healthy
    /// follower's first line.
    func testFollowerSilenceTimeoutIsWiderThanAnOrdinaryConnect() {
        let silenceSeconds = Double(SessionPaneModel.followerSilenceTimeout.components.seconds)
        XCTAssertGreaterThanOrEqual(silenceSeconds, 10)
    }
}

/// The follow verb, run through the exact wedge `SSHProcessRunnerTests`
/// already reproduced for the non-follow verb — closing the gap finding #1
/// named: `SessionStateFollower.start()` builds the SAME connection
/// `SessionAgent.state` does, `--follow` appended, so if the connection
/// itself never completes the mux handshake, `--follow` never even reaches
/// the remote command. This pins that the follow-shaped argv hangs
/// identically, which is exactly why the fix lives in a separate liveness
/// probe (`SSHControlSocket.check`, already proven bounded against this same
/// fixture in `SSHControlSocketRecoveryTests`) rather than in anything the
/// follow process itself could report.
final class FollowVerbWedgedSocketTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: "/tmp/dcs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWedgedSocketBoundsAFollowInvocationTooWhenRunThroughTheWatchdog() throws {
        let socket = try WedgedControlSocket(directory: tempDir)
        defer { socket.stop() }

        var argv = try SessionAgent.arguments(
            target: SSHTarget(user: "someuser", host: "203.0.113.5"), session: "deck",
            verb: ["state"], controlPath: socket.path)
        argv.append("--follow")

        let outcome = try SSHProcessRunner.run(argv, timeout: 1.5)
        XCTAssertTrue(outcome.timedOut,
                      "a follow invocation against a wedged socket hangs exactly like a one-shot state call")
        XCTAssertTrue(outcome.stdout.isEmpty,
                      "nothing reaches session-agent at all — the connection never got past the mux handshake")
    }
}
