@testable import Deck
import XCTest

/// CQ·158: which `session-agent` outcomes mark a host as having no Builder
/// server, and that only that mark offers the install.
final class BuilderServerStateTests: XCTestCase {
    private struct Unrelated: Error {}

    func testASuccessfulCallReadsAsInstalled() {
        XCTAssertEqual(
            BuilderServerTracker.apply(Result<Int, Error>.success(1), lastKnown: .missing), .installed)
    }

    func testNotInstalledReadsAsMissing() {
        XCTAssertEqual(
            BuilderServerTracker.apply(
                Result<Int, Error>.failure(SessionAgent.AgentError.notInstalled), lastKnown: .installed),
            .missing)
    }

    /// An ssh failure, a timeout or a refusal says nothing about whether
    /// Builder is installed, so the last reading stands, including "unknown".
    func testAnyOtherFailureKeepsTheLastReading() {
        let failures: [Error] = [
            SessionAgent.AgentError.failed("ssh: connect to host x port 22: Connection refused"),
            SessionAgent.AgentError.failed("ssh did not respond within 20s — the connection may be wedged"),
            SessionAgent.AgentError.invalidSessionName("a b"),
            Unrelated(),
        ]
        for error in failures {
            XCTAssertEqual(
                BuilderServerTracker.apply(Result<Int, Error>.failure(error), lastKnown: .installed),
                .installed, "\(error)")
            XCTAssertNil(
                BuilderServerTracker.apply(Result<Int, Error>.failure(error), lastKnown: nil), "\(error)")
        }
    }

    func testOnlyAMissingServerOffersTheInstall() {
        XCTAssertTrue(BuilderServerInstall.offersInstall(.missing))
        XCTAssertFalse(BuilderServerInstall.offersInstall(.installed))
        XCTAssertFalse(BuilderServerInstall.offersInstall(nil))
    }

    /// The published installer at its current release, with nothing of
    /// Deck's own added (E22's specification).
    func testTheInstallCommandIsThePublishedInstallerUnpinned() {
        XCTAssertEqual(BuilderServerInstall.command,
                       "curl -fsSL https://convivybuilder.org/install.sh | sh")
    }

    // MARK: - Wiring through `RailStateModel.refresh()`

    @MainActor
    private func model(discovered: @escaping @Sendable (SSHTarget) throws -> [DiscoveredSession]) -> RailStateModel {
        let model = RailStateModel()
        model.sessions = []
        model.configuredTargets = { [TestHost.target] }
        model.fetchStates = { _, _ in [:] }
        model.fetchDiscovered = discovered
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .unknown }
        return model
    }

    /// A crew-less configured host is polled too, so a host just added in
    /// Settings is marked without any crew on it.
    @MainActor
    func testARefreshMarksACrewLessHostWithNoSessionAgentAsMissing() async {
        let model = model { _ in throw SessionAgent.AgentError.notInstalled }
        await model.refresh()
        XCTAssertEqual(model.builderServerState[TestHost.target], .missing)
    }

    @MainActor
    func testAnUnreachableHostIsNotMarkedMissing() async {
        let model = model { _ in throw SessionAgent.AgentError.failed("ssh: Could not resolve hostname") }
        await model.refresh()
        XCTAssertNil(model.builderServerState[TestHost.target])
    }

    @MainActor
    func testAHostThatAnswersIsMarkedInstalled() async {
        let model = model { _ in [] }
        await model.refresh()
        XCTAssertEqual(model.builderServerState[TestHost.target], .installed)
    }
}
