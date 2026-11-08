import XCTest
@testable import Deck

/// `SSHControlSocketProbe.classify`: the pure decision behind
/// `SSHControlSocket.probe` — a bounded no-op session sent through a master
/// `-O check` already called `confirmedAlive`, because `-O check` only ever
/// reaches the local master process and never crosses the network (CQ·166:
/// 241 requests on the operator laptop failed transport with
/// `confirmedAlive` on every retry, because the master's local mux answered
/// truthfully while its connection to the server had already died).
final class SSHControlSocketProbeClassifyTests: XCTestCase {
    func testASuccessfulSessionPasses() {
        XCTAssertEqual(SSHControlSocketProbe.classify(exitCode: 0, timedOut: false), .passed)
    }

    func testANonZeroExitFails() {
        XCTAssertEqual(SSHControlSocketProbe.classify(exitCode: 1, timedOut: false), .failed)
    }

    /// Mirrors `SSHControlSocketCheck.classify`'s own reasoning for
    /// `-O check`: a probe that cannot even complete is not a shrug, it is
    /// the exact failure this mechanism exists to catch, regardless of
    /// whatever exit code happened to be sitting around when the watchdog
    /// fired.
    func testATimeoutIsTimedOutRegardlessOfExitCode() {
        XCTAssertEqual(SSHControlSocketProbe.classify(exitCode: 0, timedOut: true), .timedOut)
        XCTAssertEqual(SSHControlSocketProbe.classify(exitCode: 255, timedOut: true), .timedOut)
    }
}

/// `SessionAgent.run`'s recovery wired end to end for the one reading
/// `-O check` cannot give on its own: a master that answers `confirmedAlive`
/// while the connection it was supposed to carry is dead. No real fixture
/// can reproduce "a genuinely running ControlMaster whose own mux answers"
/// without a reachable host, so these tests swap in `FakeSSHMaster` via
/// `SessionAgent.run`'s own `sshExecutable` seam — the same
/// substitute-the-binary seam `SSHProcessRunner.run`'s `executable`
/// parameter already offered, now threaded through the recovery path.
final class SessionAgentControlProbeRecoveryTests: XCTestCase {
    private var tempDir: URL!
    private let target = SSHTarget(user: "someuser", host: "203.0.113.5")

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: "/tmp/dcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func transportLogContents() -> String {
        (try? String(contentsOf: tempDir.appendingPathComponent("transport.log"), encoding: .utf8)) ?? ""
    }

    /// THE CASE THIS PR EXISTS FOR. `-O check` answers `confirmedAlive`, but
    /// the probe — a real no-op session through the same master — fails.
    /// Must fail on `main`: without the probe, `confirmedAlive` alone kept
    /// the dead master in place and the caller never recovered.
    func testAliveCheckWithAFailingProbeStopsTheMasterAndRetries() throws {
        let controlPath = tempDir.appendingPathComponent("socket").path
        try "placeholder".write(toFile: controlPath, atomically: true, encoding: .utf8)
        let fakeSSH = tempDir.appendingPathComponent("fake-ssh").path
        let marker = tempDir.appendingPathComponent("primary-called").path
        try FakeSSHMaster.write(to: fakeSSH, controlPath: controlPath, primaryCallMarker: marker, probe: .fails)
        let log = TransportLog(directory: tempDir)
        let argv = try SessionAgent.arguments(
            target: target, session: "deck", verb: ["state"], controlPath: controlPath)

        _ = try SessionAgent.run(
            argv, timeout: 5, staleSocketRecovery: (target: target, controlPath: controlPath),
            transportLog: log, sshExecutable: fakeSSH)

        let lines = transportLogContents()
        XCTAssertTrue(lines.contains("control-check result=confirmedAlive"))
        XCTAssertTrue(lines.contains("control-probe result=failed"))
        XCTAssertTrue(lines.contains("master-stop result=exited"))
        XCTAssertFalse(lines.contains("socket-cleared"),
                       "a master that answered -O exit cleanly needs no forced clear")
        XCTAssertTrue(lines.contains("retry timed_out=false exit=0"),
                      "the retry must run and succeed against the fresh master, not repeat the dead one")
    }

    /// The companion failing-on-`main` shape named in the brief: the probe
    /// times out rather than exiting non-zero. Same unusable reading, same
    /// recovery — `probe != .passed` covers both without distinguishing them.
    func testAliveCheckWithATimedOutProbeStopsTheMasterAndRetries() throws {
        let controlPath = tempDir.appendingPathComponent("socket").path
        try "placeholder".write(toFile: controlPath, atomically: true, encoding: .utf8)
        let fakeSSH = tempDir.appendingPathComponent("fake-ssh").path
        let marker = tempDir.appendingPathComponent("primary-called").path
        try FakeSSHMaster.write(to: fakeSSH, controlPath: controlPath, primaryCallMarker: marker, probe: .hangs)
        let log = TransportLog(directory: tempDir)
        let argv = try SessionAgent.arguments(
            target: target, session: "deck", verb: ["state"], controlPath: controlPath)

        _ = try SessionAgent.run(
            argv, timeout: 5, staleSocketRecovery: (target: target, controlPath: controlPath),
            transportLog: log, sshExecutable: fakeSSH)

        let lines = transportLogContents()
        XCTAssertTrue(lines.contains("control-probe result=timedOut"))
        XCTAssertTrue(lines.contains("master-stop result=exited"))
        XCTAssertTrue(lines.contains("retry timed_out=false exit=0"))
    }

    /// The other half of the brief: a master that answers alive AND passes
    /// the probe is kept — no stop, no clear, no retry, the original
    /// failure surfaces unchanged. This is the regression guard for the
    /// opposite mistake: probing on every `confirmedAlive` would be no
    /// better than never probing if it also cleared a genuinely healthy
    /// master.
    func testAliveCheckWithAPassingProbeKeepsTheMaster() throws {
        let controlPath = tempDir.appendingPathComponent("socket").path
        try "placeholder".write(toFile: controlPath, atomically: true, encoding: .utf8)
        let fakeSSH = tempDir.appendingPathComponent("fake-ssh").path
        let marker = tempDir.appendingPathComponent("primary-called").path
        try FakeSSHMaster.write(to: fakeSSH, controlPath: controlPath, primaryCallMarker: marker, probe: .passes)
        let log = TransportLog(directory: tempDir)
        let argv = try SessionAgent.arguments(
            target: target, session: "deck", verb: ["state"], controlPath: controlPath)

        XCTAssertThrowsError(try SessionAgent.run(
            argv, timeout: 5, staleSocketRecovery: (target: target, controlPath: controlPath),
            transportLog: log, sshExecutable: fakeSSH))

        XCTAssertTrue(FileManager.default.fileExists(atPath: controlPath),
                     "a master that passes the probe must not have its socket file touched")
        let lines = transportLogContents()
        XCTAssertTrue(lines.contains("control-probe result=passed"))
        XCTAssertFalse(lines.contains("master-stop"))
        XCTAssertFalse(lines.contains("socket-cleared"))
        XCTAssertFalse(lines.contains("retry"))
    }

    /// The last-resort step: when even `-O exit` cannot get the master to
    /// answer, `clear` forces the socket file out of the way so the retry
    /// still opens a fresh master rather than tripping over the same one.
    func testAliveCheckWithAFailingProbeAndAnUnresponsiveStopForcesClear() throws {
        let controlPath = tempDir.appendingPathComponent("socket").path
        try "placeholder".write(toFile: controlPath, atomically: true, encoding: .utf8)
        let fakeSSH = tempDir.appendingPathComponent("fake-ssh").path
        let marker = tempDir.appendingPathComponent("primary-called").path
        try FakeSSHMaster.write(
            to: fakeSSH, controlPath: controlPath, primaryCallMarker: marker, probe: .fails, stop: .hangs)
        let log = TransportLog(directory: tempDir)
        let argv = try SessionAgent.arguments(
            target: target, session: "deck", verb: ["state"], controlPath: controlPath)

        _ = try SessionAgent.run(
            argv, timeout: 5, staleSocketRecovery: (target: target, controlPath: controlPath),
            transportLog: log, sshExecutable: fakeSSH)

        XCTAssertFalse(FileManager.default.fileExists(atPath: controlPath),
                       "an unresponsive -O exit must fall back to deleting the socket file")
        let lines = transportLogContents()
        XCTAssertTrue(lines.contains("master-stop result=unresponsive"))
        XCTAssertTrue(lines.contains("socket-cleared"))
        XCTAssertTrue(lines.contains("retry timed_out=false exit=0"))
    }
}

// MARK: - Fixture

/// A fake stand-in for the real `/usr/bin/ssh` executable, playing the one
/// scenario no real socket fixture can reproduce without a reachable host:
/// a master whose own `-O check` answers truthfully while its actual
/// transport to the server is dead. Dispatches purely on the flags each of
/// `SessionAgent.run`'s own calls is already pinned to send — `-O check`,
/// `-G`, `-O exit`, `ControlMaster=no` for the probe, `ControlMaster=auto`
/// for everything else — never a real ssh round trip.
enum FakeSSHMaster {
    enum ProbeOutcome { case passes, fails, hangs }
    enum StopOutcome { case exits, hangs }

    /// `primaryCallMarker` is how the script tells its own first invocation
    /// (the one that must fail transport, to put `SessionAgent.run` into
    /// its recovery path at all) apart from the retry that follows
    /// recovery: it touches the marker on the first call and exits 255,
    /// then exits 0 once the marker exists.
    static func write(
        to path: String, controlPath: String, primaryCallMarker: String,
        probe: ProbeOutcome, stop: StopOutcome = .exits
    ) throws {
        let probeBody: String
        switch probe {
        case .passes: probeBody = "exit 0"
        case .fails: probeBody = "exit 1"
        case .hangs: probeBody = "sleep 30"
        }
        let stopBody = stop == .exits ? "exit 0" : "sleep 30"
        let script = """
        #!/bin/bash
        args="$*"
        if [[ "$args" == *"-O check"* ]]; then
          echo "Master running (pid=12345)" >&2
          exit 0
        fi
        if [[ "$args" == *"-G"* ]]; then
          echo "controlpath \(controlPath)"
          exit 0
        fi
        if [[ "$args" == *"-O exit"* ]]; then
          \(stopBody)
        fi
        if [[ "$args" == *"ControlMaster=no"* ]]; then
          \(probeBody)
        fi
        if [[ -f "\(primaryCallMarker)" ]]; then
          exit 0
        fi
        touch "\(primaryCallMarker)"
        exit 255
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
