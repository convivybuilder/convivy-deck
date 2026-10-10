import SwiftUI

/// The find bar's own presentation state: whether it is open, and the term
/// typed into it — the one piece that is shared across a switch between the
/// conversation and Terminal View. Owned once by `ContentView` and handed to
/// both `SessionPaneView` (which renders `ConversationFindBar`) and the main
/// pane's `TerminalFindBar`, so there is exactly one bar rather than two that
/// happen to look alike.
///
/// A TERM DOES NOT CARRY ACROSS A SURFACE SWITCH. `ConversationFindBar` and
/// `TerminalFindBar` each clear `term` in their own `onDisappear` — which
/// runs whether the bar closed outright or the surface underneath it changed
/// — so the field is always empty against a backend that has not been
/// searched yet, rather than showing a count left over from the surface the
/// reader just left. See the PR body (issue_01M1S525RMHB9ENTG8DKM24VS6) for
/// why reset was chosen over re-running the same term against the new
/// surface.
@MainActor
final class FindBarState: ObservableObject {
    @Published var isPresented = false
    @Published var term = ""

    /// Flipped on every `open()` call, including a repeat ⌘F while the bar
    /// is already showing — `isPresented` alone does not change on a repeat
    /// press, so nothing would tell an already-mounted bar to reclaim focus
    /// from wherever it drifted (the composer, say). `FindBarRow` watches
    /// this rather than `isPresented` for that reason.
    @Published private(set) var focusToken = false

    func open() {
        isPresented = true
        focusToken.toggle()
    }

    /// Called by the bar's own close button, by Esc, and by `ContentView` on
    /// a session switch — a term typed against one session's content is not
    /// a search anybody meant to run against a different one.
    func closeAndClear() {
        isPresented = false
        term = ""
    }
}
