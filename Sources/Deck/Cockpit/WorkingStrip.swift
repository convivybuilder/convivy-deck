import SwiftUI

/// The co's working-on sentence, formatting helpers only.
///
/// **The window splits by who drives a surface, not by how wide its scope is**
/// (the operator, 2026-08-25). What sits above the conversation is the co's; what sits
/// below is the operator's. This line is written by the co — by
/// `agent-platform/bin/co-working-on` — which is why `PaneStatusBar` draws it
/// at the top of the pane, pre-empted only by something more urgent to say.
///
/// Formerly its own row, drawn directly under the conversation until
/// 2026-08-25 and then above it. Both were a layout rule describing where the
/// text sat; neither survives as a row of its own now that `PaneStatusBar`
/// merges the crew's mark and name, this sentence (or whatever pre-empts it),
/// and the vitals into one line above the conversation — see that type's doc.
/// This enum keeps only the formatting `PaneStatusBar` and `CockpitView` both
/// need, so the two draw one number rather than computing it twice.
enum WorkingStrip {
    /// The line's trailing duration, or nil to draw the text alone.
    ///
    /// STALE TAKES `age`, NEVER `since` — a sentence shown stale must carry
    /// how old it is, and `since` answers a different question (how long
    /// this text has been the current work) that a reader would misread as
    /// freshness. `since` is drawn only when the recording is not stale, and
    /// never invented from `age` when `since` is nil — an older writer's
    /// recording gets no duration at all rather than a wrong one.
    static func durationSuffix(for workingOn: SessionState.WorkingOn) -> String? {
        if workingOn.stale == true, let age = workingOn.age {
            return "· \(durationLabel(age)) ago"
        }
        if workingOn.stale != true, let since = workingOn.since {
            return "· \(durationLabel(since))"
        }
        return nil
    }

    /// A short duration label — "45s", "12m", "3h" — for a value that is
    /// SECONDS OF ELAPSED TIME, never a clock time. Purely a function of the
    /// number handed to it, so it never touches the mini's clock or its
    /// timezone; the reader's own now is the only "now" involved, at the
    /// call site that computed `age`/`since` in the first place.
    ///
    /// Clamped to a week, past which the exact count tells a reader nothing
    /// a mini restarting or a clock skew wouldn't invent anyway.
    nonisolated static func durationLabel(_ seconds: Double) -> String {
        tieredDuration(seconds, maxSeconds: 7 * 86_400)
    }

    /// The seconds/minutes/hours tiering shared by every duration label in
    /// the app, so two readings of "how long ago" never disagree on where
    /// the tiers change. `maxSeconds` is the caller's own clamp, applied
    /// BEFORE any arithmetic touches the value — `Int(_:)` on a Double TRAPS
    /// beyond `Int`'s range, and an age from the mini can arrive as `1e30`
    /// (JSONSerialization accepts it; only NaN and Infinity are refused), so
    /// skipping the clamp would let a clock skew take the whole app down.
    /// Measured, not assumed. Callers choose their own `maxSeconds` because
    /// what a reader should infer from "the exact count doesn't matter past
    /// here" differs by context — see call sites.
    nonisolated static func tieredDuration(_ seconds: Double, maxSeconds: Double) -> String {
        let clamped = max(0, min(seconds, maxSeconds))
        if clamped < 90 { return "\(Int(clamped))s" }
        if clamped < 5_400 { return "\(Int((clamped / 60).rounded()))m" }
        return "\(Int((clamped / 3_600).rounded()))h"
    }
}
