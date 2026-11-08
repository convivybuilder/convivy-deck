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
    /// What the strip's one flexible slot shows for the co's current work —
    /// `PaneStatusBar.slot` draws whichever case this resolves to, and
    /// nothing else decides it. Pulled out as a pure function of the two
    /// readings, the same split `RunDetail` uses for `RunDetailPane`, so the
    /// precedence is testable without hosting a view.
    enum Presentation: Equatable {
        /// The co's own line, fresh — drawn alone, never alongside the
        /// dispatch fallback.
        case authored(SessionState.WorkingOn)
        /// The co's own line is stale or absent, and the last dispatch task
        /// is what's left to show — labelled as such, never mistaken for
        /// the co's own words.
        case dispatch(SessionState.WorkingOnDerived)
        /// Neither reading has anything this slot will draw: no authored
        /// line, and either no derived record or one `UserPromptSubmit`
        /// gave rather than a dispatch — the operator's own ruling,
        /// 2026-10-20, is that this slot never echoes the operator's own
        /// latest message back, which `UserPromptSubmit` often is.
        case none
    }

    /// CQ-167: FRESH AUTHORED WINS OUTRIGHT; the dispatch fallback is
    /// considered only once the authored line is stale or missing, and only
    /// `"agentctl spawn --task"` ever furnishes it — see `Presentation`.
    ///
    /// A STALE OR ABSENT AUTHORED LINE STILL FALLS BACK TO THE STALE LINE
    /// ITSELF, not to nothing, when there is no usable dispatch to show in
    /// its place — the contract's `working_on` section requires a stale line
    /// be drawn with its age, never dropped
    /// ([[platform/contracts/session-agent-api]]). A usable dispatch record
    /// replaces it only when it is the newer of the two readings: absent
    /// authored, or a dispatch age younger than the authored age. Either
    /// age missing counts as "dispatch is newer" — there is no older
    /// authored age to lose to.
    static func presentation(
        workingOn: SessionState.WorkingOn?, workingOnDerived: SessionState.WorkingOnDerived?
    ) -> Presentation {
        // TRIMMED — see `PaneStatusBar.slot`'s own doc on this same check.
        let authored = workingOn.flatMap {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        if let authored, authored.stale != true {
            return .authored(authored)
        }
        let dispatch = workingOnDerived.flatMap {
            $0.derivedFrom == SessionState.WorkingOnDerived.dispatchTaskSource
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0 : nil
        }
        guard let authored else {
            // No authored line at all: the dispatch is all there is.
            return dispatch.map(Presentation.dispatch) ?? .none
        }
        guard let dispatch else {
            // No usable dispatch record: fall back to the stale authored
            // line exactly as it drew before CQ-167, rather than to nothing.
            return .authored(authored)
        }
        if let authoredAge = authored.age, let dispatchAge = dispatch.age, dispatchAge >= authoredAge {
            return .authored(authored)
        }
        return .dispatch(dispatch)
    }

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

    /// The dispatch fallback's trailing duration (`PaneStatusBar`'s
    /// `dispatchRow`), or nil when the record carries no `since` to draw.
    ///
    /// `since` IS ALREADY A DURATION, computed by the mini at the moment it
    /// answered — unlike `AgentRun.startedAt`, there is no epoch time here
    /// to measure against the reader's own clock. Formatted the same way
    /// `durationSuffix` formats `workingOn.since`, and NEVER falls back to
    /// `age` — a dispatch with no `since` draws no duration at all, the same
    /// rule `workingOn.since` follows.
    static func dispatchDurationSuffix(for derived: SessionState.WorkingOnDerived) -> String? {
        guard let since = derived.since else { return nil }
        return "· \(durationLabel(since))"
    }

    /// The dispatch fallback's text as both rows draw it: sanitised, then
    /// with every Library item id taken out.
    ///
    /// A co's brief names work items by their raw ids (`issue_01M5…`,
    /// `cq_01M4…`), twenty-six characters a reader cannot use, and they
    /// crowd the one line this row has (the operator, 2026-10-20). The
    /// human key beside an id (`CQ·169`) stays. A parenthesised id goes
    /// with its parentheses, so "CQ·169 (issue_…) in deck" reads
    /// "CQ·169 in deck".
    ///
    /// SANITISED AGAIN AFTER THE IDS GO. Removing an id splices the clusters
    /// on either side of it, and combining marks that followed the id attach
    /// to whatever now precedes them, so two clusters each within
    /// `SessionPaneView.maxScalarsPerCluster` can join into one past it
    /// (security review of this change, 2026-10-20). The second pass
    /// re-segments the result and bounds it again.
    nonisolated static func dispatchDisplayText(_ text: String) -> String {
        var out = CockpitView.sanitizedAgentField(text)
        let id = #"(?:issue|cq)_[0-9A-Z]{26}"#
        for pattern in [#"\s*\(\s*"# + id + #"\s*\)"#, id] {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+([,.;:)])"#, with: "$1", options: .regularExpression)
        return CockpitView.sanitizedAgentField(out.trimmingCharacters(in: .whitespaces))
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
