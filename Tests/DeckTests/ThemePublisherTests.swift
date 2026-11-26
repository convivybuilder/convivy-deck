import XCTest
@testable import Deck

/// `ThemePublisher` — the digest-gated palette write and the resend-on-
/// change project write, CQ·211. Every test drives `publishSync` directly
/// (no `Task` to await) against fakes; nothing here reaches a real ssh
/// process or the network.
final class ThemePublisherTests: XCTestCase {
    private let mini = TestHost.target

    private func crew(id: String, project: String?, theme: String? = nil) -> ServedCrew {
        ServedCrew(crewId: id, host: mini, project: project, theme: theme)
    }

    /// A fresh temp directory per test, held by the caller rather than read
    /// back off `TransportLog` (which exposes no such accessor) — the same
    /// pattern `TransportLogTests` follows.
    private func makePublisher() -> (publisher: ThemePublisher, logDirectory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("theme-publisher-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let publisher = ThemePublisher()
        publisher.transportLog = TransportLog(directory: directory)
        return (publisher, directory)
    }

    // MARK: - palette: once per launch, then only on change

    func testThePaletteIsSentOnTheFirstPublish() {
        let (publisher, _) = makePublisher()
        var calls = 0
        publisher.putPalette = { _, _, _ in calls += 1 }
        publisher.putProjectTheme = { _, _, _, _ in }

        publisher.publishSync(target: mini, servedCrews: [])
        XCTAssertEqual(calls, 1)
    }

    /// The catalog is a pure function of compiled-in constants, so its
    /// digest never changes within one run — a second publish in the same
    /// launch must not resend it.
    func testASecondPublishInTheSameLaunchDoesNotResendTheUnchangedPalette() {
        let (publisher, _) = makePublisher()
        var calls = 0
        publisher.putPalette = { _, _, _ in calls += 1 }
        publisher.putProjectTheme = { _, _, _, _ in }

        publisher.publishSync(target: mini, servedCrews: [])
        publisher.publishSync(target: mini, servedCrews: [])
        XCTAssertEqual(calls, 1)
    }

    /// A 403 (today's expected answer — Deck's credential has no
    /// `theme.write` grant yet, comment 7424/7441 on
    /// issue_01M7G7W6JJ7XHSD5ACZ32X2A09) is still a settled answer about
    /// this digest, so it must not be retried on the very next poll tick.
    func testA403OnThePaletteDoesNotLoopOnTheNextTick() {
        let (publisher, _) = makePublisher()
        var calls = 0
        publisher.putPalette = { _, _, _ in
            calls += 1
            throw LibraryClient.FetchError.libraryRefused(status: 403, body: #"{"error":"this identity lacks theme.write"}"#)
        }
        publisher.putProjectTheme = { _, _, _, _ in }

        publisher.publishSync(target: mini, servedCrews: [])
        publisher.publishSync(target: mini, servedCrews: [])
        XCTAssertEqual(calls, 1, "a refused palette must not be retried on an unchanged digest")
    }

    /// A transport failure (no Library listening, host unreachable) is NOT
    /// a settled answer, unlike a clean HTTP refusal — the next tick must
    /// still try again.
    func testATransportFailureOnThePaletteIsRetriedNextTick() {
        let (publisher, _) = makePublisher()
        var calls = 0
        publisher.putPalette = { _, _, _ in
            calls += 1
            throw SessionAgent.AgentError.failed("connection refused")
        }
        publisher.putProjectTheme = { _, _, _, _ in }

        publisher.publishSync(target: mini, servedCrews: [])
        publisher.publishSync(target: mini, servedCrews: [])
        XCTAssertEqual(calls, 2)
    }

    // MARK: - project theme: first poll sends all, then only on change

    func testTheFirstServedCrewsPollSendsEveryProjectsTheme() {
        let (publisher, _) = makePublisher()
        var sent: [String] = []
        publisher.putPalette = { _, _, _ in }
        publisher.putProjectTheme = { _, slug, _, _ in sent.append(slug) }

        let crews = [
            crew(id: "deck", project: "convivy-deck", theme: "gold"),
            crew(id: "library", project: "library", theme: "azure"),
        ]
        publisher.publishSync(target: mini, servedCrews: crews)
        XCTAssertEqual(Set(sent), ["convivy-deck", "library"])
    }

    func testAnUnchangedResolvedThemeIsNotResentOnTheNextPoll() {
        let (publisher, _) = makePublisher()
        var calls = 0
        publisher.putPalette = { _, _, _ in }
        publisher.putProjectTheme = { _, _, _, _ in calls += 1 }

        let crews = [crew(id: "deck", project: "convivy-deck", theme: "gold")]
        publisher.publishSync(target: mini, servedCrews: crews)
        publisher.publishSync(target: mini, servedCrews: crews)
        XCTAssertEqual(calls, 1)
    }

    /// A crews.d edit changing the served theme is a new resolved value, so
    /// it IS resent even though the project's identity has not changed.
    func testAChangedServedThemeIsResent() {
        let (publisher, _) = makePublisher()
        var sources: [String] = []
        publisher.putPalette = { _, _, _ in }
        publisher.putProjectTheme = { _, _, theme, source in sources.append("\(theme):\(source)") }

        publisher.publishSync(target: mini, servedCrews: [crew(id: "deck", project: "convivy-deck", theme: "gold")])
        publisher.publishSync(target: mini, servedCrews: [crew(id: "deck", project: "convivy-deck", theme: "azure")])
        XCTAssertEqual(sources, ["gold:crews-d", "azure:crews-d"])
    }

    /// Same "a refusal is a settled answer about this value" rule as the
    /// palette's: a 400 on a project write means not published, never proof
    /// the slug does not exist (comment 7441), and resending the identical
    /// theme/source pair would only repeat the same answer.
    func testA400OnAProjectThemeDoesNotLoopOnAnUnchangedValue() {
        let (publisher, _) = makePublisher()
        var calls = 0
        publisher.putPalette = { _, _, _ in }
        publisher.putProjectTheme = { _, _, _, _ in
            calls += 1
            throw LibraryClient.FetchError.libraryRefused(status: 400, body: #"{"error":"unknown project"}"#)
        }

        let crews = [crew(id: "deck", project: "convivy-deck", theme: "gold")]
        publisher.publishSync(target: mini, servedCrews: crews)
        publisher.publishSync(target: mini, servedCrews: crews)
        XCTAssertEqual(calls, 1)
    }

    func testATransportFailureOnAProjectThemeIsRetriedNextTick() {
        let (publisher, _) = makePublisher()
        var calls = 0
        publisher.putPalette = { _, _, _ in }
        publisher.putProjectTheme = { _, _, _, _ in
            calls += 1
            throw SessionAgent.AgentError.failed("connection refused")
        }

        let crews = [crew(id: "deck", project: "convivy-deck", theme: "gold")]
        publisher.publishSync(target: mini, servedCrews: crews)
        publisher.publishSync(target: mini, servedCrews: crews)
        XCTAssertEqual(calls, 2)
    }

    // MARK: - refusals are logged exactly once per distinct cause

    func testARefusalIsLoggedExactlyOnceEvenAcrossSeveralTicks() throws {
        let (publisher, directory) = makePublisher()
        publisher.putPalette = { _, _, _ in
            throw LibraryClient.FetchError.libraryRefused(status: 403, body: "{}")
        }
        publisher.putProjectTheme = { _, _, _, _ in }

        publisher.publishSync(target: mini, servedCrews: [])
        publisher.publishSync(target: mini, servedCrews: [])
        publisher.publishSync(target: mini, servedCrews: [])

        let logFile = directory.appendingPathComponent("transport.log")
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        let matches = contents.components(separatedBy: "theme-palette-refused status=403").count - 1
        XCTAssertEqual(matches, 1)
    }

    /// Two distinct causes (two different projects refused, or a palette
    /// refusal alongside a project refusal) each get their own line — this
    /// is "once per distinct cause," not "once ever."
    func testTwoDistinctProjectRefusalsEachLogOnce() throws {
        let (publisher, directory) = makePublisher()
        publisher.putPalette = { _, _, _ in }
        publisher.putProjectTheme = { _, slug, _, _ in
            throw LibraryClient.FetchError.libraryRefused(status: 400, body: "{}")
        }

        let crews = [
            crew(id: "deck", project: "convivy-deck", theme: "gold"),
            crew(id: "library", project: "library", theme: "azure"),
        ]
        publisher.publishSync(target: mini, servedCrews: crews)
        publisher.publishSync(target: mini, servedCrews: crews)

        let logFile = directory.appendingPathComponent("transport.log")
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertEqual(contents.components(separatedBy: "project=convivy-deck").count - 1, 1)
        XCTAssertEqual(contents.components(separatedBy: "project=library").count - 1, 1)
    }
}
