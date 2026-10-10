import Foundation

/// The pure logic behind `START`'s picker — option C of
/// `design/start-section/index.html` (`issue_01M1SV8QKJ7ADH87PCNC0Q0YE8`):
/// a fixed-height opener row that reveals the catalog in a popover instead
/// of drawing every entry on the rail itself. Kept apart from the views so
/// the filter's matching, the keyboard path, and the running-entry
/// exclusion are each pinned by a test without a view-level test target —
/// the same split `SessionGrouping`/`RailRunningSessions` already follow.
enum StartPicker {
    /// The catalog entries the picker offers — every entry EXCEPT one
    /// `isRunning` already claims. This is the one correctness fix the
    /// issue ties to option C: a catalog entry that has been launched
    /// belongs under `OTHER SESSIONS`, not here, so it is excluded on this
    /// side rather than left to draw twice.
    static func availableEntries(
        _ catalog: [LaunchableSession], isRunning: (LaunchableSession) -> Bool
    ) -> [LaunchableSession] {
        catalog.filter { !isRunning($0) }
    }

    /// The picker's own filtered order — a case-insensitive substring match
    /// on display name. An empty (or all-whitespace) query returns `entries`
    /// untouched, so a picker that has not been typed into yet shows
    /// everything `availableEntries` offered it.
    static func filter(_ entries: [LaunchableSession], query: String) -> [LaunchableSession] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.displayName.localizedCaseInsensitiveContains(trimmed) }
    }

    /// ↑↓'s own arithmetic: the id `delta` rows away from `current` within
    /// `entries`, clamped to the ends rather than wrapping — the same
    /// "stop at the edge" behaviour a `List(selection:)` gives for free,
    /// reproduced here because the filter field, not the list, holds
    /// keyboard focus. `current` absent, or no longer present after a
    /// filter narrowed the list, starts from the first row moving down and
    /// the last row moving up.
    static func move(current: String?, in entries: [LaunchableSession], delta: Int) -> String? {
        guard !entries.isEmpty else { return nil }
        guard let current, let index = entries.firstIndex(where: { $0.id == current }) else {
            return delta >= 0 ? entries.first?.id : entries.last?.id
        }
        let clamped = min(max(index + delta, 0), entries.count - 1)
        return entries[clamped].id
    }

    /// The popover's foot label — `design/start-section/index.html`'s
    /// `.pop .foot`: "16 not running" at rest, "6 of 16" once a filter has
    /// narrowed the list.
    static func footLabel(matchCount: Int, totalCount: Int) -> String {
        matchCount == totalCount
            ? "\(totalCount) not running"
            : "\(matchCount) of \(totalCount)"
    }
}
