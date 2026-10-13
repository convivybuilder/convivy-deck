import XCTest
@testable import Deck

/// `TransportLog`: the size-capped file Deck appends one line per ssh
/// transport event to — issue_01M4RZFFK250HBM735QSMP1GR0. Every test here
/// points its own instance at a temp directory, never the real Application
/// Support one.
final class TransportLogTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        // A SHORT BASE PATH, DELIBERATELY — the same reason
        // `SSHProcessRunnerTests.setUpWithError` gives: two of the tests
        // below bind a real AF_UNIX socket under this directory, and that
        // path is capped at ~104 bytes on macOS. `temporaryDirectory`'s own
        // long, hashed path leaves no room for one.
        tempDir = URL(fileURLWithPath: "/tmp/tl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func contents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Line format

    /// THE FORMAT THIS FILE PINS: one UTC timestamp, the host label, the
    /// event, space separated, one line per call. A future edit that
    /// reorders these or drops the trailing newline breaks every consumer
    /// that reads this file by eye over ssh, which is the whole point of it
    /// existing.
    func testAppendedLineCarriesATimestampHostAndEventSeparatedBySpaces() {
        let log = TransportLog(directory: tempDir)
        log.append(host: "vivy@fleet-mini", event: "control-check result=confirmedDead")

        let line = contents(tempDir.appendingPathComponent("transport.log"))
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z vivy@fleet-mini control-check result=confirmedDead\n$"#
        XCTAssertNotNil(line.range(of: pattern, options: .regularExpression),
                        "line did not match the pinned format: \(line)")
    }

    /// Two calls land as two lines, oldest first — an append, not an
    /// overwrite.
    func testTwoAppendsProduceTwoLinesInOrder() {
        let log = TransportLog(directory: tempDir)
        log.append(host: "vivy@fleet-mini", event: "first")
        log.append(host: "vivy@fleet-mini", event: "second")

        let lines = contents(tempDir.appendingPathComponent("transport.log"))
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("first"))
        XCTAssertTrue(lines[1].hasSuffix("second"))
    }

    /// Embedded newlines in `event` (ssh's own multi-line stderr, quoted by
    /// `TransportLog.quoted`) must not split into a second line — the
    /// escaping is what keeps "one line per event" true even when the
    /// underlying text was not one line.
    func testAQuotedMultilineEventStaysOnOneLine() {
        let log = TransportLog(directory: tempDir)
        log.append(host: "vivy@fleet-mini",
                   event: "transport-failure stderr=\(TransportLog.quoted("line one\nline two"))")

        let lines = contents(tempDir.appendingPathComponent("transport.log")).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("line one\\nline two"))
    }

    // MARK: - Host label

    func testHostLabelFromATargetIsUserAtHost() {
        XCTAssertEqual(
            TransportLog.hostLabel(target: SSHTarget(user: "vivy", host: "fleet-mini")),
            "vivy@fleet-mini")
    }

    /// Every destination token this codebase builds is `"\(user)@\(host)"`
    /// and no other argv element carries an `@` — see the production argv
    /// builders in `SessionAgent.swift`/`SSHTarget.swift`. This is what lets
    /// `SessionAgent.run` recover a host label from argv alone, without a
    /// `SSHTarget` in hand.
    func testHostLabelFromArgvFindsTheDestinationToken() {
        let argv = ["-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/deck-cm-%C", "vivy@fleet-mini",
                    "session-agent", "state", "deck"]
        XCTAssertEqual(TransportLog.hostLabel(fromArgv: argv), "vivy@fleet-mini")
    }

    func testHostLabelFromArgvWithNoDestinationTokenIsUnknown() {
        XCTAssertEqual(TransportLog.hostLabel(fromArgv: ["-O", "check"]), "unknown")
    }

    // MARK: - No payload, message text, or credential ever reaches the file

    /// THE CLAIM THIS TEST EXISTS TO HOLD: a message a person typed, sent on
    /// `SessionAgent.run`'s `stdin` parameter, never appears in the
    /// transport log even when the call fails at the transport layer and
    /// logs a `transport-failure` line for it. `stdin` carries exactly the
    /// kind of content issue_01M4RZFFK250HBM735QSMP1GR0 rules out — a
    /// message, here standing in for one with an embedded token.
    func testATransportFailureLogsNothingFromTheStdinPayload() throws {
        let socket = try WedgedControlSocket(directory: tempDir)
        defer { socket.stop() }
        let log = TransportLog(directory: tempDir)
        let target = SSHTarget(user: "someuser", host: "203.0.113.5")
        let secret = "do-not-log-this-token-f3a9c2"

        let argv = try SessionAgent.arguments(
            target: target, session: "deck", verb: ["send"], controlPath: socket.path) + ["--text", "-"]

        _ = try? SessionAgent.run(argv, stdin: secret, timeout: 1.5, transportLog: log)

        let line = contents(tempDir.appendingPathComponent("transport.log"))
        XCTAssertTrue(line.contains("transport-failure"), "expected a logged transport failure, got: \(line)")
        XCTAssertFalse(line.contains(secret), "the stdin payload must never reach the transport log")
    }

    /// `SSHControlSocket.clear` logs the resolved socket PATH it removed —
    /// never a payload, since there is none in this call at all. Exercised
    /// against a fast-failing orphaned socket (bind, then close with no
    /// listener) rather than the wedged fixture, so this does not pay
    /// `checkTimeout`'s bound for a check this test does not need.
    func testClearLogsTheSocketPathItRemoved() throws {
        let socketPath = tempDir.appendingPathComponent("orphan-cm").path
        try OrphanedSocket.create(at: socketPath)
        let log = TransportLog(directory: tempDir)
        let target = SSHTarget(user: "someuser", host: "203.0.113.5")

        SSHControlSocket.clear(target: target, controlPath: socketPath, transportLog: log)

        let line = contents(tempDir.appendingPathComponent("transport.log"))
        XCTAssertTrue(line.contains("socket-cleared"))
        XCTAssertTrue(line.contains("path=\(socketPath)"))
    }

    // MARK: - Size cap and rotation

    /// Appending past the cap rotates: the file that was `transport.log`
    /// becomes `transport.log.1`, a fresh `transport.log` starts with just
    /// the line that crossed the cap, and `transport.log` itself never grows
    /// past one line beyond `maxBytes`.
    func testAppendingPastTheCapRotatesTheCurrentFileToPrevious() {
        let log = TransportLog(directory: tempDir, maxBytes: 100)
        let filler = String(repeating: "x", count: 90)
        // The first line has no existing file to measure, so it always
        // writes rather than rotating — there is nothing yet to rotate.
        log.append(host: "vivy@fleet-mini", event: filler)
        // The second line's own size, added to the first's, crosses 100,
        // which is what triggers the rotation this test checks for.
        log.append(host: "vivy@fleet-mini", event: filler)

        let currentURL = tempDir.appendingPathComponent("transport.log")
        let previousURL = tempDir.appendingPathComponent("transport.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previousURL.path),
                     "a previous file must exist once the cap is crossed")
        let currentLines = contents(currentURL).split(separator: "\n")
        XCTAssertEqual(currentLines.count, 1, "the rotated-into file should hold only the line that crossed the cap")
        XCTAssertTrue(currentLines[0].hasSuffix(filler))
    }

    /// Only ONE previous file is ever kept — a second rotation overwrites
    /// `transport.log.1` rather than accumulating `.2`, `.3`, and so on.
    func testOnlyOnePreviousFileIsEverKept() {
        let log = TransportLog(directory: tempDir, maxBytes: 100)
        let filler = String(repeating: "x", count: 90)
        for n in 0..<5 {
            log.append(host: "vivy@fleet-mini", event: "\(filler)\(n)")
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        XCTAssertEqual(Set(entries), Set(["transport.log", "transport.log.1"]),
                       "exactly two files should exist regardless of how many rotations happened: \(entries)")
    }

    /// The file this test writes through five rotations never grows past
    /// roughly `maxBytes` — the cap is a size bound on the CURRENT file, not
    /// a budget that leaks across rotations.
    func testTheCurrentFileNeverGrowsUnboundedAcrossManyRotations() {
        let maxBytes = 500
        let log = TransportLog(directory: tempDir, maxBytes: maxBytes)
        let filler = String(repeating: "x", count: 50)
        for n in 0..<40 {
            log.append(host: "vivy@fleet-mini", event: "\(filler)\(n)")
        }

        let currentURL = tempDir.appendingPathComponent("transport.log")
        let size = (try? FileManager.default.attributesOfItem(atPath: currentURL.path))?[.size] as? Int ?? 0
        // One line's worth of slack past the cap, never the whole run's
        // worth of lines.
        XCTAssertLessThan(size, maxBytes + 200,
                          "the current file must stay bounded near maxBytes, not accumulate every line ever written")
    }
}
