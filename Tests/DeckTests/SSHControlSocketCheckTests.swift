import XCTest
@testable import Deck

/// `SSHControlSocketCheck.classify`: turns one `ssh -O check` outcome into
/// the one decision `SessionAgent.run` needs — clear the socket and retry,
/// or leave it alone. Pure, so every reading `-O check` can actually produce
/// is pinned by a test with no ssh round trip.
///
/// The three phrases and the timeout branch below are not guesses — they are
/// what `ssh -O check` was observed to print, verbatim, against each of the
/// socket states reproduced by hand for the PR this shipped in (see the PR
/// body): a missing control path, a control path pointing at a plain file,
/// and a control path whose socket has no listener all fail in well under a
/// tenth of a second with one of these three messages; a control path whose
/// socket accepts a connection and never answers hangs `-O check` exactly as
/// long as it hangs a real connection attempt, with no output at all.
final class SSHControlSocketCheckTests: XCTestCase {
    func testMasterRunningIsConfirmedAlive() {
        XCTAssertEqual(
            SSHControlSocketCheck.classify(exitCode: 0, stderr: "Master running (pid=1234)\n", timedOut: false),
            .confirmedAlive)
    }

    func testMissingControlPathIsConfirmedDead() {
        XCTAssertEqual(
            SSHControlSocketCheck.classify(
                exitCode: 255,
                stderr: "Control socket connect(\(TestHost.homeRoot)/.ssh/deck-cm-abc): No such file or directory\n",
                timedOut: false),
            .confirmedDead)
    }

    func testOrphanedSocketWithNoListenerIsConfirmedDead() {
        XCTAssertEqual(
            SSHControlSocketCheck.classify(
                exitCode: 255,
                stderr: "Control socket connect(\(TestHost.homeRoot)/.ssh/deck-cm-abc): Connection refused\n",
                timedOut: false),
            .confirmedDead)
    }

    func testWrongFileTypeAtThePathIsConfirmedDead() {
        XCTAssertEqual(
            SSHControlSocketCheck.classify(
                exitCode: 255,
                stderr: "Control socket connect(\(TestHost.homeRoot)/.ssh/deck-cm-abc): Socket operation on non-socket\n",
                timedOut: false),
            .confirmedDead)
    }

    /// A check that produced no recognisable ssh wording is left alone rather
    /// than guessed at — the same "unrecognised means degrade, don't drop or
    /// invent" discipline every other classifier in this codebase follows.
    func testUnrecognisedFailureTextIsUnresponsiveNotDead() {
        XCTAssertEqual(
            SSHControlSocketCheck.classify(exitCode: 255, stderr: "some ssh message nobody has seen yet", timedOut: false),
            .unresponsive)
    }

    /// THE CASE THIS FILE EXISTS TO PIN. A `-O check` that could not complete
    /// at all is not a shrug — it reproduces the exact symptom of the wedged
    /// master this whole mechanism exists to recover from, so it counts as
    /// confirmation, not as "leave it alone". Reading `timedOut` as
    /// `.confirmedAlive` or as a fourth, do-nothing case would mean the one
    /// failure this exists for never clears — see the doc comment on
    /// `SSHControlSocketCheck.classify`.
    func testATimedOutCheckIsUnresponsiveRegardlessOfExitCodeOrStderr() {
        XCTAssertEqual(
            SSHControlSocketCheck.classify(exitCode: 0, stderr: "", timedOut: true),
            .unresponsive)
        XCTAssertEqual(
            SSHControlSocketCheck.classify(exitCode: 255, stderr: "Master running (pid=1234)\n", timedOut: true),
            .unresponsive)
    }

    func testConfirmedAliveDoesNotWarrantClearing() {
        XCTAssertFalse(SSHControlSocketCheck.confirmedAlive.warrantsClearing)
    }

    func testConfirmedDeadWarrantsClearing() {
        XCTAssertTrue(SSHControlSocketCheck.confirmedDead.warrantsClearing)
    }

    func testUnresponsiveWarrantsClearing() {
        XCTAssertTrue(SSHControlSocketCheck.unresponsive.warrantsClearing)
    }
}

/// `SSHControlSocket.resolvedControlPath(fromConfigOutput:)`: pulls the
/// token-expanded `ControlPath` back out of `ssh -G`'s plain `key value`
/// output, which is how `SSHControlSocket.clear` finds the concrete file to
/// delete without reimplementing ssh's own `%C` hash in Swift.
final class SSHControlSocketResolvedPathTests: XCTestCase {
    func testParsesTheControlPathLineFromMultilineOutput() {
        let output = """
        user \(TestHost.user)
        hostname \(TestHost.address)
        controlpath \(TestHost.homeRoot)/.ssh/deck-cm-68c10ad6efe674fa2f68627717c9dc4f68116f4e
        controlmaster auto
        """
        XCTAssertEqual(
            SSHControlSocket.resolvedControlPath(fromConfigOutput: Data(output.utf8)),
            "\(TestHost.homeRoot)/.ssh/deck-cm-68c10ad6efe674fa2f68627717c9dc4f68116f4e")
    }

    func testMissingControlPathLineResolvesToNil() {
        let output = "user \(TestHost.user)\nhostname \(TestHost.address)\n"
        XCTAssertNil(SSHControlSocket.resolvedControlPath(fromConfigOutput: Data(output.utf8)))
    }

    /// ssh prints `controlpath none` when the option is unset entirely —
    /// distinct from a missing line, but the same "nothing to delete" answer.
    func testControlPathNoneResolvesToNil() {
        let output = "user \(TestHost.user)\ncontrolpath none\n"
        XCTAssertNil(SSHControlSocket.resolvedControlPath(fromConfigOutput: Data(output.utf8)))
    }

    func testUndecodableBytesResolveToNil() {
        let bytes = Data([0xFF, 0xFE, 0x00, 0xD8])
        XCTAssertNil(SSHControlSocket.resolvedControlPath(fromConfigOutput: bytes))
    }
}
