import SwiftUI

/// The Course as a route rather than a list, along the bottom of the frame —
/// the same data `CockpitView` draws as rows, at a different zoom
/// (`deck/bead/deck` §1: "a route reads differently when you can see what was
/// just passed"). About 26pt tall.
///
/// **It stays the last row.** A route drawn along the frame's edge is what
/// keeps the Bead in view while the reader works (the operator, 2026-08-25), which is
/// the whole reason it is a ribbon rather than another list.
///
/// **EVERY WAYPOINT CARRIES TEXT, NOT ONLY THE CURRENT ONE** (the operator,
/// 2026-08-25). Dots alone say how far along the route you are and not what
/// any stop is, and labelling the current one alone answers that question for
/// exactly one entry — the reader still cannot see what is coming.
///
/// **The labels are condensed, and the ribbon scrolls rather than shrinking
/// them further.** Ten labels at `labelCharacterLimit` need roughly 1750pt
/// against the ~1000pt this row gets while the cockpit column is open, so
/// about six are visible and the rest arrive by scrolling — the operator's call on
/// 2026-08-25, taken against a mock of the alternatives, over shorter labels
/// that would all fit. The cost is real and was chosen: a route this wide is
/// no longer readable in one glance.
///
/// Draws nothing when there is no Course to draw, rather than an empty
/// strip claiming a height — the conversation gets that space back instead.
struct WaypointRibbon: View {
    let course: LibraryClient.Course?

    /// What the co said it is working on, the same value `PaneStatusBar` draws
    /// above the conversation — taken here only for its LIVENESS, never its
    /// text.
    ///
    /// **The pulse means the co is still working, not "you are here."** A dot
    /// that always pulsed would be decoration: every Course has a current
    /// waypoint, so an unconditional animation carries no information and
    /// costs a redraw forever. Driven off `stale` it answers the question a
    /// glance at the bottom of the window actually asks — is anything
    /// happening right now — using the signal `co-working-on` already
    /// maintains, where a line unconfirmed for twenty minutes is stale.
    ///
    /// `nil` when the session recorded nothing, which draws still.
    var workingOn: SessionState.WorkingOn? = nil

    /// The shell's resolved appearance, needed only to pick a fallback
    /// surface for `accent` — see `CockpitView.indexSurface`, the same "no
    /// canvas to solve against" case. Defaulted so the existing pure-logic
    /// tests, which never touch a colour, keep constructing this unchanged.
    var appearance: Appearance = .light
    /// The Builder Default ground the ribbon is drawn on, set by the shell's pin.
    @Environment(\.statusGround) private var statusGround
    /// The selected crew's own hue — the same expression `ContentView`
    /// passes `SessionPaneView` and the rail's own dot, so the current
    /// waypoint draws in provably the same colour as everywhere else that
    /// crew's accent appears. `nil` falls back to `SessionPaneView.neutralAccent`.
    var accent: RGB? = nil

    private static let dotSize: CGFloat = 8
    static let height: CGFloat = 26

    /// What a waypoint's label is condensed to. The operator's "like 25 chars
    /// max or so", and the budget the FALLBACK path is held to.
    nonisolated static let labelCharacterLimit = 25

    /// The ceiling a SERVED `short_description` is held to, above the budget a
    /// truncated title gets.
    ///
    /// **THE LIBRARY BOUNDS THIS FIELD NOWHERE, SO DECK DOES.** An earlier
    /// version drew a served value as authored, reasoning that the field
    /// exists to be the short form and clamping it would truncate a label
    /// somebody wrote to fit. That trusts a bound nobody has written: the
    /// field is unbounded at the write path today
    /// (`issue_01M0XR0QSMKBSGBYD49CPTJ37E` asks for the clamp), and this
    /// label renders under `.lineLimit(1)` with `.fixedSize(horizontal: true)`,
    /// which lays the whole string out on one line at intrinsic width rather
    /// than truncating inside a bounded frame. An arbitrarily long value is
    /// therefore a plausible hang of the operator's own frame
    /// (`deck-security-reviewer`, PR #137).
    ///
    /// **And nobody will be watching when the first real value arrives** —
    /// the field is decoded ahead of the server precisely so no Deck release
    /// sits in that path, which is the same property that makes an unclamped
    /// render fail unobserved.
    ///
    /// Set above `labelCharacterLimit` rather than equal to it, so a label
    /// authored a little over budget survives as written and only a value
    /// that is not a short description at all gets cut. The trust level is
    /// unchanged either way: whoever can set `short_description` can already
    /// set `title`, which has always been condensed.
    static let servedLabelCeiling = 50

    /// Drives the halo's animation, toggled by the HALO'S OWN appearance
    /// rather than the ribbon's.
    ///
    /// **THE ANIMATION BELONGS ON THE VIEW THAT APPEARS, AND SO DOES THE
    /// TOGGLE.** The first version set this once in the ScrollView's
    /// `.onAppear` inside `withAnimation`, which animates only the render
    /// diff produced by THAT mutation. The halo is mounted conditionally, so
    /// unless work was already live at the instant the ribbon appeared, the
    /// halo mounted later — read `pulsePhase` already `true`, and rendered
    /// the animation's END state statically: scaled out at zero opacity, an
    /// invisible halo rather than a pulsing one. The common sequence (pane
    /// opens idle, the co starts working a moment later; or the waypoint
    /// advances while work stays live) got no pulse at all
    /// (`deck-reviewer`, PR #140).
    ///
    /// **`SessionDotView` documents this exact failure and says it "shipped
    /// twice in the view this replaces"** — its `.busy` disc binds
    /// `.animation(_:value:)` to the animated modifier and resets the flag in
    /// `.onDisappear`, so every appearance is a genuine `false → true`
    /// transition. This is the same shape; a third instance of a bug this
    /// codebase already names in a comment is not one to invent again.
    @State private var pulsePhase = false

    /// **Honoured rather than assumed.** A perpetual animation is exactly what
    /// Reduce Motion exists to switch off, and this one runs at the edge of
    /// the frame where a reader is not looking directly — the worst place for
    /// motion somebody has asked not to see.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let course, !course.entries.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(course.entries.enumerated()), id: \.element.id) { index, entry in
                        waypoint(entry)
                        label(entry)
                        if index < course.entries.count - 1 {
                            Rectangle()
                                .fill(ruleStyle)
                                .frame(width: 14, height: 1)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: WaypointRibbon.height)
        }
    }

    /// Where the traveller is, which is NOT the same question as which epic is
    /// claimed.
    ///
    /// `isInProgress` requires a state past `open`, and a Course whose entries
    /// are all filed-but-unclaimed has none — which is the ordinary case, not an
    /// edge one. Deck's own Course on 2026-08-25 had one `fixed` entry and nine
    /// `open` ones, so a ribbon keyed on `isInProgress` alone drew no current
    /// waypoint at all and the route had no "you are here".
    ///
    /// So: the claimed epic when there is one, and otherwise the first entry not
    /// yet finished — the next thing on the route, which is where you are
    /// standing when nothing is underway. `nil` only when every entry is done,
    /// where a route with nothing ahead correctly labels nothing.
    var currentId: String? {
        guard let course else { return nil }
        if let inProgress = course.entries.first(where: { $0.isInProgress }) {
            return inProgress.id
        }
        return course.entries.first(where: { !$0.isCompleted })?.id
    }

    /// What one waypoint says, condensed to fit a route rather than a list.
    ///
    /// **`short_description` when the Library serves one, a condensed title
    /// otherwise.** The field does not exist on the item record today (see
    /// `LibraryClient.CourseEntry.shortDescription`), so every label goes
    /// through the fallback until it does. Truncating a title is a poor
    /// substitute and visibly so — Deck's own Course has four entries whose
    /// first 25 characters begin "Deck ", so the fallback draws near-duplicate
    /// labels where authored ones would read as four different things. That is
    /// the argument for the field, and it is why this reads one the moment it
    /// arrives.
    ///
    /// **BOTH PATHS ARE BOUNDED**, at different limits and for different
    /// reasons: a title is condensed to `labelCharacterLimit` because a route
    /// has no room for one, and a served short description is cut at
    /// `servedLabelCeiling` because nothing upstream bounds it — see that
    /// constant.
    ///
    /// Static and pure so it is testable — Deck has no view-level test target
    /// (`deck/bead/deck` §6.5), so anything that must be checked has to live
    /// outside the `body`.
    ///
    /// **`SessionPaneView.displayable` FIRST, THEN `condense`, in that order
    /// deliberately.** `condense`'s bound is counted in Characters (grapheme
    /// clusters), and a cluster absorbs any number of combining scalars, so a
    /// title built as one cluster of thousands of marks reads as a single
    /// Character and passes `condense` untouched. `displayable` caps every
    /// cluster at 16 scalars first, so the Character-counted cut that follows
    /// bounds total scalars too. `CockpitView.sanitizedAgentField` sanitises
    /// its own served-field text the same way, for the same reason; this
    /// duplicates the two-line call rather than hoisting it, since hoisting
    /// would give `WaypointRibbon` a dependency on `CockpitView`.
    static func label(for entry: LibraryClient.CourseEntry) -> String {
        if let short = entry.shortDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !short.isEmpty {
            return condense(SessionPaneView.displayable(short), to: servedLabelCeiling)
        }
        return condense(SessionPaneView.displayable(entry.title))
    }

    /// A string cut to `limit`, **at a word boundary where one leaves enough
    /// of the label standing**, with an ellipsis marking what was dropped.
    ///
    /// Cutting mid-word ("Deck's client side of the") reads as a rendering
    /// fault rather than as an abbreviation, so the cut walks back to the last
    /// space — but only while the boundary still leaves at least
    /// `minimumWordBoundary(for:)` characters. A string whose first word runs
    /// past the limit has no boundary worth finding, and preferring one anyway
    /// would return a two-character label.
    ///
    /// Counts Characters (grapheme clusters) rather than UTF-16 units, so an
    /// emoji or a combining mark costs one column's worth of budget rather
    /// than two — the limit is about how much room the label takes, and
    /// `String.count` is the measure closest to that.
    ///
    /// **A negative `limit` would trap** at `index(offsetBy:)`, moving before
    /// `startIndex` — the guard admits it because `count > limit` passes for
    /// every non-empty string when the limit is below zero. Unreachable from
    /// either call site, and asserted rather than left implied now that the
    /// limit is caller-supplied (`deck-security-reviewer`, PR #137).
    nonisolated static func condense(_ title: String, to limit: Int = labelCharacterLimit) -> String {
        precondition(limit >= 0, "condense limit must be non-negative, got \(limit)")
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: limit)
        let head = trimmed[trimmed.startIndex..<cut]
        if let lastSpace = head.lastIndex(of: " "),
           head.distance(from: head.startIndex, to: lastSpace) >= minimumWordBoundary(for: limit) {
            return head[head.startIndex..<lastSpace]
                .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// How much of the label a word-boundary cut has to leave standing before
    /// a hard cut is preferred instead. Below this the boundary is not an
    /// abbreviation of the string, it is a different word.
    ///
    /// **IT SCALES WITH THE LIMIT, and a fixed floor was wrong** — the title
    /// path's 12 reused at the served path's ceiling of 50 let the walk-back
    /// discard up to 38 characters, so a description with two short words
    /// followed by one long unbroken token collapsed to about the length the
    /// ceiling had just been raised above (`deck-reviewer`, PR #137, with the
    /// case: `condense("Word one two " + 60 x's, to: 50)` returned 13
    /// characters rather than the ~49 available). That is the opposite of what
    /// raising the ceiling was for.
    ///
    /// Half the limit, which reproduces the tuned value exactly at the title
    /// budget — 25 / 2 is 12 — so the fallback path's behaviour is unchanged
    /// and only the served path moves.
    nonisolated static func minimumWordBoundary(for limit: Int) -> Int { limit / 2 }

    /// What hovering a waypoint says: the whole title, which is the escape
    /// hatch for a label that had to be condensed.
    ///
    /// **BOUNDED, generously.** AppKit lays the tooltip window out itself
    /// rather than at the app frame's intrinsic width, so an extreme title
    /// costs an oversized slow tooltip rather than the frame hang
    /// `servedLabelCeiling` closes — a lesser surface, and a distinct one
    /// (`deck-security-reviewer`, PR #137). It predates this change, which
    /// widens it by adding a second `.help` site, so it is closed here rather
    /// than left. The bound is far above any real title so the escape hatch
    /// still answers the question it exists for.
    static let tooltipCharacterLimit = 500

    /// What hovering a waypoint's dot says at ribbon zoom: the whole title,
    /// which is the escape hatch for a label that had to be condensed — the
    /// same trade `label(for:)` makes for a route with no room to spell out
    /// a full title.
    ///
    /// `displayable` before `condense`, same reason and same order as
    /// `label(for:)` documents: `condense` counts Characters, not scalars.
    ///
    /// Not `private` — a scalar-bounded regression test calls this directly,
    /// the same way `label(for:)` is reached.
    static func tooltip(_ entry: LibraryClient.CourseEntry) -> String {
        condense(SessionPaneView.displayable(entry.title), to: tooltipCharacterLimit)
    }

    /// Whether the current waypoint's dot should pulse: the co has recorded
    /// work and that recording is fresh.
    ///
    /// A recording with no `stale` field at all (an older writer) counts as
    /// fresh rather than stale — the field's absence says the producer did not
    /// compute it, not that the work stopped, and `WorkingStrip` takes the
    /// same reading with `stale != true`.
    ///
    /// Static and pure so it is testable; Deck has no view-level test target
    /// (`deck/bead/deck` §6.5).
    static func isWorkLive(_ workingOn: SessionState.WorkingOn?) -> Bool {
        guard let workingOn,
              !workingOn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return workingOn.stale != true
    }

    /// One full beat, in seconds. Slow enough to read as breathing rather
    /// than blinking — a fast pulse on a 8pt dot at the frame's edge reads as
    /// an error indicator, which is the opposite of what this says.
    static let pulsePeriod: Double = 1.8

    /// No session canvas reaches this ribbon. Under a status pin the ribbon
    /// sits on the Builder Default ground, which is the colour drawn. Anywhere
    /// else it is the same approximation `CockpitView.indexSurface` uses for
    /// its "no canvas" fallback, a legibility floor and not a colour match.
    private var surface: RGB {
        statusGround ?? (appearance == .dark
            ? RGB(red: 0.12, green: 0.12, blue: 0.13)
            : RGB(red: 0.98, green: 0.98, blue: 0.98))
    }

    private var resolvedAccent: RGB { accent ?? SessionPaneView.neutralAccent(appearance) }

    /// The current waypoint's dot and halo — the crew's own hue, or the
    /// primary ink where `ThemeRecipe.progressCollidesWithSummons` says the
    /// two would read as one colour. Shared by both so they move together.
    private var currentMarkStyle: AnyShapeStyle {
        guard let mark = ThemeRecipe.progressMarkInk(accent: resolvedAccent, on: surface) else {
            return AnyShapeStyle(.primary)
        }
        return AnyShapeStyle(Color(mark))
    }

    /// The current waypoint's label — `currentMarkStyle`'s text-weight twin.
    private var currentTextStyle: AnyShapeStyle {
        guard let text = ThemeRecipe.progressTextInk(accent: resolvedAccent, on: surface) else {
            return AnyShapeStyle(.primary)
        }
        return AnyShapeStyle(Color(text))
    }

    @ViewBuilder
    private func waypoint(_ entry: LibraryClient.CourseEntry) -> some View {
        let pulses = entry.id == currentId && WaypointRibbon.isWorkLive(workingOn)
        Circle()
            .fill(waypointStyle(entry))
            .frame(width: WaypointRibbon.dotSize, height: WaypointRibbon.dotSize)
            // THE HALO GROWS, THE DOT DOES NOT. Animating the dot's own frame
            // would reflow the HStack on every frame — every label and rule to
            // its right would shift, which is motion sickness in a strip a
            // reader keeps in peripheral vision. An overlay scales outside the
            // layout instead, so nothing moves but the halo.
            .overlay {
                if pulses {
                    Circle()
                        .stroke(currentMarkStyle, lineWidth: 1)
                        .scaleEffect(pulsePhase ? 2.1 : 1.0)
                        .opacity(pulsePhase ? 0 : 0.7)
                        // BOTH HALVES, for the reason `pulsePhase` documents
                        // and `SessionDotView` learned twice: the animation
                        // binds to the modifier that changes, and the flag
                        // resets on disappear so re-mounting is a real
                        // false → true transition rather than true → true,
                        // which `value:` would see as no change at all.
                        .animation(reduceMotion ? nil
                                   : .easeOut(duration: WaypointRibbon.pulsePeriod)
                                       .repeatForever(autoreverses: false),
                                   value: pulsePhase)
                        .onAppear { pulsePhase = true }
                        .onDisappear { pulsePhase = false }
                        .allowsHitTesting(false)
                }
            }
            .help(WaypointRibbon.tooltip(entry))
            .accessibilityLabel(pulses
                ? "\(WaypointRibbon.label(for: entry)), work in progress"
                : WaypointRibbon.label(for: entry))
    }

    /// The full title stays reachable on hover, because the label is a
    /// condensation and a reader who cannot tell two waypoints apart needs
    /// somewhere to go. `.help` on the dot AND on the text, so either half of
    /// a waypoint answers.
    @ViewBuilder
    private func label(_ entry: LibraryClient.CourseEntry) -> some View {
        Text(WaypointRibbon.label(for: entry))
            .frameFont(.body)
            .fontWeight(entry.id == currentId ? .semibold : .regular)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .strikethrough(entry.isCompleted)
            .foregroundStyle(labelStyle(entry))
            .padding(.leading, 4)
            .padding(.trailing, 2)
            .help(WaypointRibbon.tooltip(entry))
    }

    /// Passed, current, or ahead — the three states a route shows a
    /// traveller, drawn as filled/accented/hollow so the whole Course reads at
    /// a glance. The current one is accented here AND emphasised in its label;
    /// the mark and the text are one answer rather than two, so `currentId`
    /// decides both.
    private func waypointStyle(_ entry: LibraryClient.CourseEntry) -> AnyShapeStyle {
        if entry.isCompleted { return completedInkStyle }
        if entry.id == currentId { return currentMarkStyle }
        return upcomingMarkStyle
    }

    /// The label's three states, tracking `waypointStyle`'s. A passed entry
    /// draws struck through and dimmed the way `CockpitView`'s rows do, so the
    /// same entry reads the same at both zooms.
    private func labelStyle(_ entry: LibraryClient.CourseEntry) -> AnyShapeStyle {
        if entry.id == currentId { return currentTextStyle }
        return completedInkStyle
    }

    /// The passed waypoints' dot and label, and the upcoming labels. Under the
    /// status pin they are solved against the ground at the text floor; a
    /// system colour otherwise, as before.
    private var completedInkStyle: AnyShapeStyle {
        guard statusGround != nil else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(Color(ThemeRecipe.workItemChipInk(on: surface)))
    }

    /// An upcoming waypoint's hollow dot. Under the status pin it is solved to
    /// the mark floor; otherwise it keeps the system's dimmed secondary.
    private var upcomingMarkStyle: AnyShapeStyle {
        guard statusGround != nil else { return AnyShapeStyle(Color.secondary.opacity(0.35)) }
        return AnyShapeStyle(Color(ThemeRecipe.routeMarkInk(on: surface)))
    }

    /// The hairlines between waypoints. Under the status pin they take the
    /// ground's own divider token.
    private var ruleStyle: AnyShapeStyle {
        guard statusGround != nil else { return AnyShapeStyle(Color.secondary.opacity(0.25)) }
        return AnyShapeStyle(Color(StatusGround.divider))
    }
}
