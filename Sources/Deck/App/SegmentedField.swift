import SwiftUI

/// Fills the field under a native segmented picker on a status pane.
///
/// macOS draws a dark segmented picker's track and selected pill as
/// translucent washes, so the field takes the colour of whatever lies beneath
/// the control. A capsule under the picker matches the large control's track
/// exactly, and the native track, pill and labels still draw on top.
///
/// Only a pane with a status ground gets the fill. That is Builder Default's
/// dark surfaces, so System, Light and Dark draw the system picker untouched.
struct SegmentedFieldModifier: ViewModifier {
    /// The fill. A parameter so the render tests can measure other values.
    var field: RGB = StatusGround.segmentedField

    @Environment(\.statusGround) private var statusGround

    func body(content: Content) -> some View {
        if statusGround != nil {
            content.background(Capsule().fill(Color(field)))
        } else {
            content
        }
    }
}

extension View {
    /// Fills a segmented picker's field with `StatusGround.segmentedField` on a
    /// status pane. See `SegmentedFieldModifier`.
    func segmentedField() -> some View {
        modifier(SegmentedFieldModifier())
    }
}
