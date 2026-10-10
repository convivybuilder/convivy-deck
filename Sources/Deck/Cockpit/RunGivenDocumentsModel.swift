import Foundation

/// Drives the Dispatched run pane's "Documents it was given" section: the
/// record `RunGivenDocuments` decodes, read through the run register.
///
/// FETCHES WHEN THE PANE'S KEY CHANGES, not on a timer. The pane's key includes
/// whether the register still lists the run, so a run that leaves the list is
/// read once more.
@MainActor
final class RunGivenDocumentsModel: ObservableObject {
    enum State: Equatable {
        /// No run is selected, so nothing was asked.
        case idle
        case loading
        case loaded(RunGivenDocuments)
        /// The read could not run or its reply was not read. The string is the
        /// section's sentence.
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private struct Key: Equatable {
        let target: SSHTarget
        let runId: String
    }

    private var current: Key?

    /// The ssh round trip, as a seam so a test can answer without one.
    var fetchDocuments: @Sendable (SSHTarget, String) throws -> RunGivenDocuments = { target, runId in
        try RunGivenDocuments.fetch(target: target, runId: runId)
    }

    /// Points the model at a run and reads its record. A new run shows
    /// `.loading` rather than the previous run's documents. The same run read
    /// again keeps what is showing until the answer arrives.
    func refresh(target: SSHTarget, runId: String) async {
        let key = Key(target: target, runId: runId)
        if key != current { state = .loading }
        current = key
        await fetch(key)
    }

    private func fetch(_ key: Key) async {
        let fetchDocuments = self.fetchDocuments
        let result: State
        do {
            let documents = try await Task.detached {
                try fetchDocuments(key.target, key.runId)
            }.value
            result = .loaded(documents)
        } catch {
            result = .failed(Self.failureSentence(error))
        }
        // A reply for a run the operator has since moved off is dropped, or a
        // slow answer would draw one run's documents under another run's pane.
        guard key == current else { return }
        state = result
    }

    nonisolated static func failureSentence(_ error: Error) -> String {
        "Could not read this run's documents: \(error)"
    }
}
