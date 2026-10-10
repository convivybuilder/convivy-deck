import SwiftUI

/// Lays the cockpit's panel index out left to right, starting a new line
/// when the next entry would not fit, so an entry is never squeezed.
///
/// An `HStack` compresses every entry to fit its width, and at the default
/// 320pt column a fifth entry broke words mid-letter ("Dispatc / hed").
/// Wrapping whole entries keeps each label readable at any column width
/// down to the 280pt minimum.
struct PanelIndexFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 10
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = Self.rows(sizes: subviews.map { $0.sizeThatFits(.unspecified) },
                             maxWidth: proposal.width ?? .infinity, spacing: horizontalSpacing)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in Self.rows(sizes: sizes, maxWidth: bounds.width, spacing: horizontalSpacing) {
            var x = bounds.minX
            for index in row.indices {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    struct Row: Equatable {
        var indices: [Int]
        var width: CGFloat
        var height: CGFloat
    }

    /// Greedy line breaking: an entry joins the current row when it fits,
    /// and otherwise starts the next one. An entry wider than `maxWidth` gets
    /// a row to itself rather than an empty row before it.
    static func rows(sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat) -> [Row] {
        var rows: [Row] = []
        for (index, size) in sizes.enumerated() {
            if var last = rows.last, !last.indices.isEmpty,
               last.width + spacing + size.width <= maxWidth {
                last.indices.append(index)
                last.width += spacing + size.width
                last.height = max(last.height, size.height)
                rows[rows.count - 1] = last
            } else {
                rows.append(Row(indices: [index], width: size.width, height: size.height))
            }
        }
        return rows
    }
}
