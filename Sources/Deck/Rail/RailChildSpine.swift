import SwiftUI

/// The hairline that hangs a child row from its parent's mark column, plus
/// the short tick that reaches into the row itself — `design/redesign/03-
/// rail.html`'s `.row.child::before`/`::after`. Drawn UNDER the row's own
/// content (an overlay painted before the row's text and icon are composed
/// into that same layer has no effect on them, since the spine's x sits in
/// the empty gap between the parent's indent and this row's own), so a name
/// long enough to truncate never interrupts the line: nesting is legible
/// from the spine alone, not from the label surviving intact.
///
/// FIXED ROW HEIGHT, NOT MEASURED. `RailRow.rowHeight` is the one number the
/// whole rail draws every row at, so the segment's endpoints are known
/// without a `GeometryReader` — cheaper, and immune to a frame that has not
/// settled yet on the first layout pass.
struct RailChildSpine: ViewModifier {
    /// How far this row indents beyond the rail's own leading padding — the
    /// same value the row's own leading padding uses.
    let indent: CGFloat
    /// True when this is the LAST row in its immediate parent's child list —
    /// the segment stops at this row's vertical centre instead of running
    /// through it, so the line ends at the tick rather than reaching for a
    /// sibling that is not there. A child's own window leaves, drawn one
    /// level deeper, hang from a spine of their own and never extend this
    /// one: the parent's line ends here regardless of what sits beneath.
    let isLast: Bool

    /// Aligned with the mark column one indent step shallower — this row's
    /// own leading padding, minus the one step of indent this row adds
    /// beyond its parent, plus half the widest mark
    /// (`SessionDotView`'s triangle, 13.5pt at the rail's 10pt dot) so the
    /// line runs directly under the identity dot rather than beside it.
    private var spineX: CGFloat { RailRow.leadingPadding + (indent - RailChildRow.indent) + 6.75 }

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            // Nothing to hang from at indent 0 — an "OTHER SESSIONS" row has
            // no parent mark column, so it draws no spine at all rather than
            // one reaching off the rail's own leading edge.
            if indent > 0 {
                Path { path in
                    let bottom = isLast ? RailRow.rowHeight / 2 : RailRow.rowHeight
                    path.move(to: CGPoint(x: spineX, y: 0))
                    path.addLine(to: CGPoint(x: spineX, y: bottom))
                    path.move(to: CGPoint(x: spineX, y: RailRow.rowHeight / 2))
                    path.addLine(to: CGPoint(x: spineX + 7, y: RailRow.rowHeight / 2))
                }
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// See `RailChildSpine`. Applied by any row nested under a parent —
    /// `RailChildRow` and `WindowLeafRow` — never by a top-level or "OTHER
    /// SESSIONS" row, which has no parent mark column to hang from.
    func railChildSpine(indent: CGFloat, isLast: Bool) -> some View {
        modifier(RailChildSpine(indent: indent, isLast: isLast))
    }
}
