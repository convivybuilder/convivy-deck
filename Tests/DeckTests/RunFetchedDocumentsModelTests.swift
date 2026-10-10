import Foundation
import XCTest
@testable import Deck

/// The fetched-list model: a failed read says so, a success is shown, and a
/// new run never inherits the previous run's list.
@MainActor
final class RunFetchedDocumentsModelTests: XCTestCase {
    private let target = SSHTarget(user: TestHost.user, host: "mini.local")

    private struct ReadFailed: Error {}

    func testAFailedReadSaysSoAndNeverDrawsAnEmptyList() async {
        let model = RunFetchedDocumentsModel()
        model.fetchDocuments = { _, _ in throw ReadFailed() }
        await model.refresh(target: target, runId: "run-d74a51c0")
        guard case .failed(let sentence) = model.state else {
            return XCTFail("expected a failed read, got \(model.state)")
        }
        XCTAssertTrue(sentence.hasPrefix("Could not read this run's fetched documents"))
    }

    func testASuccessfulEmptyReadIsShownAsLoadedNotAsAFailure() async {
        let model = RunFetchedDocumentsModel()
        model.fetchDocuments = { _, _ in .listed(.init(documents: [])) }
        await model.refresh(target: target, runId: "run-d74a51c0")
        XCTAssertEqual(model.state, .loaded(.listed(.init(documents: []))))
    }

    /// A poll re-reads the same run; the list it already shows stays up while
    /// the read is in flight, so the pane does not flash back to a spinner.
    func testASecondReadOfTheSameRunKeepsTheListShowing() async {
        let model = RunFetchedDocumentsModel()
        model.fetchDocuments = { _, _ in .unavailable(.withheld) }
        await model.refresh(target: target, runId: "run-a")
        XCTAssertEqual(model.state, .loaded(.unavailable(.withheld)))
        model.fetchDocuments = { _, _ in .listed(.init(documents: [])) }
        await model.refresh(target: target, runId: "run-a")
        XCTAssertEqual(model.state, .loaded(.listed(.init(documents: []))))
    }
}
