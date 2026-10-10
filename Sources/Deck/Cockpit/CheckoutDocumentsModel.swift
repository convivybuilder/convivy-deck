import Foundation

/// Drives the cockpit's Checkout panel: the documents the selected session's
/// checkout brought, read through `session-agent documents`.
///
/// KEPT SEPARATE FROM `CockpitModel` because the two follow different keys.
/// The Course follows the crew's Library project; this follows the selected
/// SESSION, since two sessions of one crew can carry different checkouts.
///
/// FETCHES ON SELECTION CHANGE, ON THE COCKPIT'S REFRESH, AND ON A SLOW TIMER.
/// A checkout changes only when its session re-individuates, so the timer is
/// there to pick up a restart the operator did not follow with a refresh.
@MainActor
final class CheckoutDocumentsModel: ObservableObject {
    enum State: Equatable {
        /// No course-shaped session selected, so nothing was asked.
        case idle
        case loading
        case loaded(CheckoutDocuments)
        /// The verb could not be run or its reply not read. The string is
        /// the panel's sentence.
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private struct Key: Equatable {
        let target: SSHTarget
        let session: String
    }

    private var current: Key?
    private var timerTask: Task<Void, Never>?

    static let refreshInterval = Duration.seconds(600)

    /// The ssh round trip, as a seam so a test can answer without one — the
    /// same shape as `CockpitModel.fetchChildItems`.
    var fetchDocuments: @Sendable (SSHTarget, String) throws -> CheckoutDocuments = { target, session in
        try SessionAgent.documents(target: target, session: session)
    }

    init() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: CheckoutDocumentsModel.refreshInterval)
                guard !Task.isCancelled, let self else { continue }
                await self.reload()
            }
        }
    }

    deinit {
        timerTask?.cancel()
    }

    /// Points the model at a session, or clears it when either is nil. A new
    /// session shows `.loading` rather than the previous session's documents.
    func refresh(target: SSHTarget?, session: String?) async {
        guard let target, let session else {
            current = nil
            state = .idle
            return
        }
        let key = Key(target: target, session: session)
        guard key != current else { return }
        current = key
        state = .loading
        await fetch(key)
    }

    /// Re-reads the current session, keeping what is showing until the answer
    /// arrives, so a refresh does not flash the panel empty.
    func reload() async {
        guard let key = current else { return }
        await fetch(key)
    }

    private func fetch(_ key: Key) async {
        let fetchDocuments = self.fetchDocuments
        let result: State
        do {
            let documents = try await Task.detached {
                try fetchDocuments(key.target, key.session)
            }.value
            result = .loaded(documents)
        } catch {
            result = .failed(Self.failureSentence(error))
        }
        // A reply for a session the operator has since moved off is dropped,
        // or a slow answer would draw one session's checkout under another.
        guard key == current else { return }
        state = result
    }

    /// argparse's refusal of an unknown verb is how a host whose
    /// session-agent predates `documents` answers, and it deserves a sentence
    /// that says so rather than the raw usage text.
    nonisolated static func failureSentence(_ error: Error) -> String {
        let message = "\(error)"
        if message.contains("invalid choice: 'documents'") {
            return "This host's session-agent is too old to list a checkout's documents. Update it to see them."
        }
        return "Could not read this session's documents: \(message)"
    }
}
