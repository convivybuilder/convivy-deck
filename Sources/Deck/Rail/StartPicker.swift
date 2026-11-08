import Foundation

/// The pure logic behind `START`'s picker — option C of
/// `design/start-section/index.html` (`issue_01M1SV8QKJ7ADH87PCNC0Q0YE8`):
/// a fixed-height opener row that reveals the catalog in a popover instead
/// of drawing every entry on the rail itself. Kept apart from the views so
/// the filter's matching, the keyboard path, and the choose-vs-launch
/// routing are each pinned by a test without a view-level test target —
/// the same split `SessionGrouping`/`RailRunningSessions` already follow.
enum StartPicker {
    /// What choosing a catalog entry does — `issue_01M5MME44FPVHRQB4KDBXZA5YR`:
    /// a catalog entry with no session behind it launches one, but a
    /// running one already has a pane to attach to, and launching a
    /// second would duplicate it. `LaunchableSession.ref` is what `.select`
    /// carries, the same ref `RailView` resolves a running entry to
    /// everywhere else.
    enum ChooseAction: Equatable {
        case select(SessionRef)
        case launch(LaunchableSession)
    }

    /// Chooses the action for an entry picked from `START`, pure so the
    /// routing is pinned by a test rather than only read off the popover.
    static func choose(_ entry: LaunchableSession, isRunning: Bool) -> ChooseAction {
        isRunning ? .select(entry.ref) : .launch(entry)
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

    /// The popover's foot label — "16 sessions" at rest, "6 of 16" once a
    /// filter has narrowed the list. Every catalog entry is offered here now
    /// regardless of whether it is running (`issue_01M5MME44FPVHRQB4KDBXZA5YR`),
    /// so the rest wording can no longer claim the whole count is "not
    /// running".
    static func footLabel(matchCount: Int, totalCount: Int) -> String {
        matchCount == totalCount
            ? "\(totalCount) session\(totalCount == 1 ? "" : "s")"
            : "\(matchCount) of \(totalCount)"
    }
}
