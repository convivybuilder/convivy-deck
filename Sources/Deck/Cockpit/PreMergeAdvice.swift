import Foundation

/// The Keel's pre-press advice: "before the press, the Keel answers whether
/// the merge is clear on its side... The Keel advises and does not enforce"
/// (`deck/decisions/0003-under-deterministic-deck-merges-with-the-operators-own-credential`).
///
/// **THE ROUTE DOES NOT EXIST YET** — Bosun item E5·1. This is an injected
/// advisory step so the row has somewhere to draw the answer the day that
/// route lands; its production implementation answers `.notAvailable` and
/// nothing else, and `MergePressModel` never waits on it or lets it refuse a
/// press — see that type's own doc for why it is fetched but never
/// consulted before a press proceeds.
enum PreMergeAdviceResult: Equatable {
    case notAvailable
    case advice(String)
}

enum PreMergeAdvice {
    /// The one producer today. Carries no network call, no target, nothing
    /// to inject beyond itself — there is nothing yet to ask.
    static func fetch() -> PreMergeAdviceResult {
        .notAvailable
    }

    /// The quiet line a row draws for `fetch()`'s answer — one line, never
    /// styled as a refusal or a success, since 0003 is explicit that this is
    /// advice, not a gate.
    static func line(_ result: PreMergeAdviceResult) -> String {
        switch result {
        case .notAvailable:
            return "Pre-merge check: not available yet."
        case .advice(let text):
            return "Pre-merge check: \(text)"
        }
    }
}
