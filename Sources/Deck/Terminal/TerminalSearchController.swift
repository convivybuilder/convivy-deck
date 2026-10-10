import Combine
import SwiftTerm

/// Bridges terminal text search between the find bar — a separate feature,
/// child 3 of the text-search epic — and the live SwiftTerm view. This type
/// is the narrow surface that bar drives: `search`, `next`, `previous`,
/// `clear`, and the `index`/`total` a "3 of 17" counter reads. It owns no UI
/// of its own.
///
/// Mirrors `ConversationScrollState`'s shape: an `ObservableObject` the
/// parent holds and the native-view wrapper's coordinator attaches to the
/// live view once it exists, so chrome above can drive a view it never
/// touches directly. `TerminalPaneView.Coordinator` sets `view` on connect
/// and clears it on teardown.
@MainActor
final class TerminalSearchController: ObservableObject {
    /// The live terminal view. Set by `TerminalPaneView.Coordinator.connect`,
    /// cleared by its `tearDown` — both run whether the reconnect is a fresh
    /// process or a session switch, so `view` is never stale once set.
    weak var view: SSHStderrWatchingTerminalView?

    /// `searchMatchSummary`'s own scan cap (SwiftTerm's default). A
    /// scrollback holding more matches than this reports a count truncated
    /// at the cap, never the true total — `label(index:total:limit:)` is
    /// what turns that into an honest "1000+" rather than a flat, wrong
    /// "1000".
    nonisolated static let matchLimit = 1000

    @Published private(set) var index: Int = 0
    @Published private(set) var total: Int = 0

    private var term: String = ""
    private var options: SearchOptions = .init()

    /// Runs a fresh search for `term`, moving to and scrolling the first
    /// match. An empty term clears instead of searching — SwiftTerm has no
    /// notion of "search for nothing", and leaving the previous highlight up
    /// would be exactly the stale-highlight failure `clear()` exists to
    /// prevent.
    func search(_ term: String, options: SearchOptions = SearchOptions()) {
        self.term = term
        self.options = options
        guard !term.isEmpty else {
            clear()
            return
        }
        guard let view else { return }
        _ = view.findNext(term, options: options)
        refreshSummary()
    }

    func next() {
        guard let view, !term.isEmpty else { return }
        _ = view.findNext(term, options: options)
        refreshSummary()
    }

    func previous() {
        guard let view, !term.isEmpty else { return }
        _ = view.findPrevious(term, options: options)
        refreshSummary()
    }

    /// Called when the term empties, the find bar closes, or the pane
    /// switches away from Terminal View (`TerminalPaneView.Coordinator.tearDown`)
    /// — the three moments the epic names as where a stale highlight would
    /// otherwise survive in a surface nobody is looking at.
    func clear() {
        term = ""
        index = 0
        total = 0
        view?.clearSearch()
    }

    private func refreshSummary() {
        guard let view else {
            index = 0
            total = 0
            return
        }
        let summary = view.searchMatchSummary(
            term, options: options, limit: TerminalSearchController.matchLimit)
        index = summary.index
        total = summary.total
    }

    /// "3 of 17", "No results", or "1 of 1000+" once the scan hits `limit` —
    /// `nonisolated` because it is pure and takes no actor-isolated state, so
    /// a test can call it synchronously without hopping onto the main actor.
    nonisolated static func label(index: Int, total: Int, limit: Int = TerminalSearchController.matchLimit) -> String {
        guard total > 0 else { return "No results" }
        let totalLabel = total >= limit ? "\(limit)+" : "\(total)"
        return "\(index) of \(totalLabel)"
    }

    /// The label for this controller's current `index`/`total` — a plain
    /// computed property, not `@Published`, so it stays correct automatically
    /// whenever either backing field changes.
    var resultsLabel: String { TerminalSearchController.label(index: index, total: total) }
}
