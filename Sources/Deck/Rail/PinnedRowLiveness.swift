import Foundation

/// What a pinned child's row should show about whether the tmux session
/// behind it is actually there — `RailView.childRow`'s decision, pulled out
/// pure so it is testable without a poll or a view.
///
/// A pinned child's config (`PinnedSession`) says nothing about whether its
/// session still exists: it can be renamed or killed outside Deck, and the
/// row has no way to tell until a poll answers. Attaching to a name with no
/// backing session runs `tmux new-session -A -D`, which CREATES one — so a
/// stale pin reads as ordinary right up until selecting it silently starts a
/// fresh, empty session under the old name.
enum PinnedRowLiveness: Equatable {
    /// No tmux session answers to this name — attaching would create one
    /// from nothing rather than resuming anything. Draws the same `⊞`
    /// treatment `RailChildRow.isTerminalOnly` gives a discovered session
    /// with no agent, so a stale pin does not read as an ordinary quiet one.
    case stale
    /// The tmux session is there but has no agent, so the pane shows a
    /// Start affordance and offers no Stop of its own
    /// (`SessionPaneView`: "only while there is an agent to stop"). The row
    /// is this session's only way to end it — the gap adopting a session
    /// opens, since an agent-less discovered child carried this via
    /// `RailView.discoveredChildRow`'s always-on `onStop` before adoption
    /// moved it here.
    case needsRowStop
    /// An ordinary running session, or one no poll has landed for yet.
    case ordinary

    /// `hasPolled` must come from the STATE reading
    /// (`RailStateModel.mark(for:) != .unpolled`), not from `hasTmuxSession`
    /// itself: `RailStateModel.discovered` starts empty and only fills after
    /// the first `session-agent sessions` response, which lands in the same
    /// tick as the states reading it's compared against
    /// (`RailStateModel.refresh()`). Without this gate every pinned row
    /// would read `.stale` for the length of the first poll, on every
    /// launch.
    static func choose(hasPolled: Bool, isStopped: Bool, hasTmuxSession: Bool) -> PinnedRowLiveness {
        guard hasPolled else { return .ordinary }
        guard hasTmuxSession else { return .stale }
        return isStopped ? .needsRowStop : .ordinary
    }
}
