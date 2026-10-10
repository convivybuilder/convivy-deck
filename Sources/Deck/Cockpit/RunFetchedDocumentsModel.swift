import Foundation

/// Drives the Dispatched run pane's "Documents it has fetched" section: the
/// list `RunFetchedDocuments` decodes, read through the run register.
///
/// FETCHES ON EVERY CALL. The pane's `.task(id:)` key carries the rail poll's
/// generation while the run is listed, so the list is read again on each poll
/// and grows as the run reads. A run that leaves the list gets one last read.
@MainActor
final class RunFetchedDocumentsModel: ObservableObject {
    enum State: Equatable {
        /// No run is selected, so nothing was asked.
        case idle
        case loading
        case loaded(RunFetchedDocuments)
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
    var fetchDocuments: @Sendable (SSHTarget, String) throws -> RunFetchedDocuments = { target, runId in
        try RunFetchedDocuments.fetch(target: target, runId: runId)
    }

    /// Points the model at a run and reads its list. A new run shows `.loading`
    /// rather than the previous run's documents. The same run read again keeps
    /// what is showing until the answer arrives, so a poll does not flash the
    /// list back to a spinner.
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
        "Could not read this run's fetched documents: \(error)"
    }
}
