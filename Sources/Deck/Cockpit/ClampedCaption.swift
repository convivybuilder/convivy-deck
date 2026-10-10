import SwiftUI

/// A caption in the expanded epic that clamps to two lines and expands in
/// place when the reader asks for the rest.
///
/// **THE ELLIPSIS IS THE AFFORDANCE, because it is what the operator already clicked**
/// (2026-09-03, choosing this over a hover icon and over the right-click Copy
/// that shipped in PR #176). Clicking a truncated `Done when:` line is what
/// surfaced the overdraw bug in the first place — the reader's instinct was
/// right and the code had nothing behind it. A control nobody can see is the
/// same mistake right-click-only made, one gesture over.
///
/// **Expanding is what makes the text selectable again, and that is the whole
/// design.** Clamped AND selectable is precisely the combination that drew a
/// third line over `Severity: medium` (PR #171): AppKit laid out the full
/// string while the stack had reserved two lines' height. Collapsed, the text
/// sits inside a `Button` label, which SwiftUI exempts from the container's
/// inherited `.textSelection(.enabled)` — so there is nothing to overdraw and
/// nothing competing with the tap. Expanded, the clamp is gone, so selection
/// is safe by construction and copying is an ordinary drag.
///
/// That retires two workarounds rather than adding a third: the reader no
/// longer depends on the `.help` tooltip to read the rest, and no longer
/// depends on a context menu to copy it. Both stay, and neither is now the
/// only way in.
struct ClampedCaption: View {
    /// The styled, possibly multi-run text — `Done when: ` in semibold
    /// followed by the value.
    let content: Text
    /// The same value as a plain string, for the tooltip and the pasteboard.
    let full: String
    /// Bounded for AppKit's tooltip layout. The pasteboard gets `full`
    /// unbounded — truncating a copy is a worse failure than a long paste.
    let tooltip: String
    /// The chrome role `content`, and the "more"/"Show less" affordance
    /// beside it, size themselves by — `.caption` for a child row's `Until`
    /// line, `.body` for an epic's own detail lines (`CockpitView.epicFields`),
    /// so the two tiers this view serves stay each at their own size rather
    /// than both flattening to one hardcoded role.
    var role: FrameTypography.Role = .caption
    /// The "more" affordance's ink — `ThemeRecipe.progressTextInk`, the same
    /// crew-hue text tier `WaypointRibbon.currentTextStyle` draws the current
    /// waypoint's label in, so the two cannot drift onto different hues.
    let moreInk: AnyShapeStyle

    @State private var isExpanded = false
    /// Whether two lines actually cut anything off. Measured rather than
    /// guessed: SwiftUI reports no truncation, and a "more" control on a
    /// caption that already fits is noise that teaches the eye to ignore it.
    @State private var isTruncated = false
    @Environment(\.statusGround) private var statusGround

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isExpanded {
                // Plain text, so the container's `.textSelection(.enabled)`
                // reaches it. Safe now: nothing is clamped, so nothing can
                // lay out past its reserved height.
                styled
                Button("Show less") { isExpanded = false }
                    .buttonStyle(.plain)
                    .frameFont(role)
                    .foregroundStyle(CockpitView.secondaryInkStyle(on: statusGround))
            } else {
                Button {
                    isExpanded = true
                } label: {
                    styled
                        .lineLimit(2)
                        .background(measurement)
                }
                .buttonStyle(.plain)
                // The whole line is the target rather than the ellipsis
                // glyph alone — an 8pt hit area at the end of a wrapped line
                // is not a control, and the reader is already pointing at
                // the text they want more of.
                .disabled(!isTruncated)
                if isTruncated {
                    Button("more") { isExpanded = true }
                        .buttonStyle(.plain)
                        .frameFont(role)
                        .foregroundStyle(moreInk)
                }
            }
        }
        .help(tooltip)
        .contextMenu {
            Button("Copy") { CockpitView.copyTitleToPasteboard(full) }
        }
    }

    private var styled: some View {
        content
            .frameFont(role)
            .foregroundStyle(CockpitView.secondaryInkStyle(on: statusGround))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Draws the same text unclamped and hidden behind the clamped copy, and
    /// compares heights. Taller unclamped means two lines cut something off.
    ///
    /// `.hidden()` rather than zero opacity, so it is out of the
    /// accessibility tree as well as invisible, and it never contributes to
    /// layout because it sits in a `.background`.
    private var measurement: some View {
        GeometryReader { clamped in
            styled
                .hidden()
                .background(
                    GeometryReader { whole in
                        Color.clear
                            .onAppear { update(clamped.size.height, whole.size.height) }
                            .onChange(of: whole.size.height) { _, new in
                                update(clamped.size.height, new)
                            }
                    })
        }
    }

    private func update(_ clampedHeight: CGFloat, _ wholeHeight: CGFloat) {
        // A point of slack: the two layouts agree exactly when nothing is
        // cut, and a sub-pixel difference is rounding rather than a third
        // line.
        let truncated = wholeHeight > clampedHeight + 1
        if truncated != isTruncated { isTruncated = truncated }
    }
}
