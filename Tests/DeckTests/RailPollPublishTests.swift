import Combine
import XCTest
@testable import Deck

/// `ContentView` observes `RailStateModel` at the window's root, so every
/// `objectWillChange` re-evaluates the whole window. A poll tick that reads
/// back the same answers must fire once, for `generation`, rather than once
/// per published property it assigns (CQ·196).
@MainActor
final class RailPollPublishTests: XCTestCase {
    /// The host's answers, changed between ticks by the test. The fetch
    /// closures are `@Sendable` and run detached, but each tick awaits them
    /// before the test touches this again.
    private final class Answers: @unchecked Sendable {
        var phase: SessionState.Phase = .working
        var discovered = [DiscoveredSession(name: "alpha--research", host: TestHost.target)]
    }

    private let ref = SessionRef(host: nil, name: "alpha")

    private func model(_ answers: Answers) -> RailStateModel {
        let model = RailStateModel()
        model.sessions = [ref]
        model.resolveHost = { _ in TestHost.target }
        model.fetchStates = { _, _ in ["alpha": SessionState(session: "alpha", phase: answers.phase, alive: true)] }
        model.fetchDiscovered = { _ in answers.discovered }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in "host-a" }
        model.fetchDesktopSession = { _ in .unknown }
        return model
    }

    func testAnUnchangedTickFiresOnceAndAChangedOneCarriesTheChange() async {
        let answers = Answers()
        let model = model(answers)
        await model.refresh()
        XCTAssertEqual(model.states[ref]?.phase, .working)

        var fires = 0
        let subscription = model.objectWillChange.sink { fires += 1 }
        defer { subscription.cancel() }

        await model.refresh()
        XCTAssertEqual(fires, 1, "an identical tick should publish only its new generation")

        answers.phase = .idle
        await model.refresh()
        XCTAssertEqual(fires, 3, "a changed state publishes the generation and the state")
        XCTAssertEqual(model.states[ref]?.phase, .idle)

        answers.discovered = []
        await model.refresh()
        XCTAssertEqual(fires, 5, "a changed discovered set publishes the generation and the set")
        XCTAssertTrue(model.discovered.isEmpty)
    }
}
