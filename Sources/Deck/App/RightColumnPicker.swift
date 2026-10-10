import SwiftUI

/// The right column's segmented picker, drawn in the form that fits the
/// column's width: every segment labelled, or icon-only.
///
/// SwiftUI picks the first form whose ideal width fits the proposal, and
/// `.frame(maxWidth:)` caps that proposal at `fittingWidth`, the column the
/// picker has to fit. The labelled form wins when it fits and the icon-only form
/// takes over when it does not. `maxWidth` rather than `width`: a fixed width
/// made the trailing box 8pt wider than the column and pushed the row past its
/// edge. Both forms carry the same segments, so only the drawing changes.
///
/// Generic over the tag so a test can draw the picker with any segment set.
struct RightColumnPicker<Tag: Hashable, Segments: View>: View {
    let selection: Binding<Tag>
    let fittingWidth: CGFloat
    let segments: (_ iconOnly: Bool) -> Segments

    init(selection: Binding<Tag>, fittingWidth: CGFloat,
         @ViewBuilder segments: @escaping (_ iconOnly: Bool) -> Segments) {
        self.selection = selection
        self.fittingWidth = fittingWidth
        self.segments = segments
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker(iconOnly: false)
            picker(iconOnly: true)
        }
        .frame(maxWidth: fittingWidth, alignment: .trailing)
    }

    private func picker(iconOnly: Bool) -> some View {
        Picker("Right column", selection: selection) {
            segments(iconOnly)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.large)
        .fixedSize()
        .segmentedField()
    }
}

/// One segment of a `RightColumnPicker`. The labelled form is the title and
/// icon, which macOS draws as the title alone in a segmented picker, so the
/// icon-only form draws the icon and carries the title as its accessibility
/// label and tooltip.
@ViewBuilder
func columnSegment(_ title: String, _ icon: String, iconOnly: Bool,
                   tag: ColumnOccupant) -> some View {
    if iconOnly {
        Image(systemName: icon)
            .accessibilityLabel(title)
            .help(title)
            .tag(tag)
    } else {
        Label(title, systemImage: icon).tag(tag)
    }
}
