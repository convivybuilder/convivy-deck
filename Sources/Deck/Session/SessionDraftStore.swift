import Foundation

/// In-memory storage for a composer's typed-but-unsent text, keyed by
/// session and owned by `ContentView` as a `@StateObject` — above the
/// `.id("pane-\(selection.stringForm)")` boundary that tears
/// `SessionPaneModel` down on every session switch (see `ContentView.mainPane`).
///
/// A REFERENCE, NOT A BINDING INTO `@State`. convivy-deck#153 tried a
/// `Binding` built from a closure over `ContentView`'s struct `self`
/// (`get: { sessionDrafts[selection, default: ""] }`), and the closure
/// captured a COPY of that struct rather than live storage: a write went
/// through, but a read from a different pane's already-evaluated closure came
/// back stale, so `send()`'s `draft = ""` never reached the box, Return
/// looked dead, and pressing again re-sent the same stale text three times
/// over. Reverted in #156. A class instance held by reference has no such
/// copy to go stale — every holder points at the same storage, and a read
/// after a write always sees the write.
///
/// Drafts live only as long as the app runs. Nothing here persists to disk,
/// `UserDefaults`, `@AppStorage`, `@SceneStorage`, or `NSUserActivity` — that
/// would put typed prompt text at rest on the laptop, a decision nobody has
/// taken.
@MainActor
final class SessionDraftStore: ObservableObject {
    private var drafts: [SessionRef: String] = [:]

    func draft(for ref: SessionRef) -> String {
        drafts[ref, default: ""]
    }

    func setDraft(_ text: String, for ref: SessionRef) {
        drafts[ref] = text
    }

    /// Drops every entry whose session is no longer in the rail's roster —
    /// mirrors `ContentView`'s own `railSessionRefs` `.onChange`, which
    /// prunes `launchPending` at the same point for the same reason: that
    /// list is every ref currently configured, independent of any single
    /// poll's outcome, so a ref missing from it means the session left
    /// Deck's config entirely rather than merely missed a beat. A poll that
    /// comes back nil for a host leaves that host's sessions standing in
    /// `railSessionRefs` (`RailStateModel`/`SessionGrouping` never drop a
    /// host's entries on a failed reading), so this can never prune a draft
    /// out from under a session that is only between polls.
    func prune(keeping refs: Set<SessionRef>) {
        drafts = drafts.filter { refs.contains($0.key) }
    }
}
