import SwiftUI

/// A group's heading row — the only row `RailView` draws for a folded
/// group, and the row above an open one's members (E24). Pulled into its
/// own type the same way `RailRow`/`StartOpenerRow` are, so the toggle,
/// the marks, and the badge are each one small piece rather than another
/// branch inlined into `RailView`'s own `rows(for:)`.
struct RailGroupHeadingRow: View {
    let group: CrewGroup
    /// Each member's accent, in the member's own rail order — what a
    /// folded heading's colour marks are drawn from. `RailView` resolves
    /// these the same way a row resolves its own dot's accent.
    let memberColors: [RGB]
    /// The members' summed Slate badge, or nil to draw none — see
    /// `SlateBadge.summed`. CQ·192: drawn right after `group.name`, behind
    /// a middle dot, rather than in the trailing column a member row's own
    /// badge sits in, and in `SlateBadgeGlyph.groupTotalInk` rather than
    /// `SlateBadgeGlyph.ink` so it does not read as one more row in that
    /// column. CQ·195: at 216pt a `.count` reads as `totalText(for:)`'s
    /// words rather than `SlateBadge.label`'s bare digit, since this total
    /// sits beside a name rather than in a column of other counts, where a
    /// bare digit would read as one more of those; `.unknown` keeps the
    /// bare `?`, and the 44pt `foldedCollapsedRow` keeps the bare digit for
    /// both, since there is no room there for words.
    let badge: SessionState.AsksOpen?
    /// Resolved by the shell and handed down, per the appearance-authority
    /// rule — needed only to solve the badge's ink against the row's own
    /// ground, the same reason `RailRow.markBacking` takes it.
    var appearance: Appearance = .light
    /// The Builder Default ground this row is drawn on, set by the shell's
    /// pin — mirrors `RailRow.statusGround`.
    @Environment(\.statusGround) private var statusGround
    /// True in the 44pt dot rail — mirrors `RailRow.isCollapsed`.
    var isCollapsed: Bool = false
    /// The heading was clicked (expanded), or a tap landed on the 44pt
    /// square (folded) — `RailView` decides whether that opens or folds,
    /// since only it knows which one this heading currently is.
    let onToggle: () -> Void

    /// What the badge's ink is solved against — no selection wash ever
    /// applies to a heading, so this is `RailRow.markBacking`'s unselected
    /// branch with no accent to blend in.
    private var backing: RGB {
        RailRow.markBacking(appearance: appearance, isSelected: false,
                            accent: RGB(red: 0, green: 0, blue: 0), ground: statusGround)
    }

    /// One colour mark's side, open and expanded — small enough that
    /// several sit comfortably beside the group's name.
    static let markSize: CGFloat = 6

    /// The folded, 44pt square's side — `RailRow.rowHeight`'s own mark
    /// column width, so it reads as one more mark in that column rather
    /// than a row of its own shape.
    static let foldedSquareSize: CGFloat = 14

    /// The fold chevron's own fixed slot width, at 216pt only — fixed
    /// rather than the SF Symbol's own measured glyph width, so its centre
    /// x stays put regardless of glyph metrics.
    static let chevronSlotWidth: CGFloat = 10

    /// Where the chevron's centre sits at 216pt: the rail's `List` adds
    /// 10pt of its own on every row's leading edge regardless of
    /// `listRowInsets` (`RailRow.leadingPadding`'s own doc, measured the
    /// same way), plus this row's own `.padding(.horizontal, 10)`, plus
    /// half the chevron's fixed slot.
    static let chevronCenterX: CGFloat = 10 + 10 + chevronSlotWidth / 2

    /// How much more an open group's own members indent beyond an
    /// ungrouped top-level crew — ruled sufficient on its own, with no
    /// guide line beside it (the operator, 2026-10-25). Never applied at 44pt, where
    /// the rail draws no indent of any kind.
    static let memberIndent: CGFloat = 8

    /// VoiceOver's label for any of this row's three shapes — CQ·194: a
    /// group's own summed badge (CQ·192) was never spoken, so a reader
    /// heard a group's fold state but never that it had asks waiting. `state`
    /// is nil for the collapsed, open-group separator, which names no fold
    /// state today. Appends nothing when `badge` has nothing visible to show
    /// (`SlateBadge.isVisible`), so a group with no badge reads exactly as it
    /// did before this.
    static func accessibilityLabel(name: String, state: String?, badge: SessionState.AsksOpen?) -> String {
        var label = name
        if let state {
            label += ", \(state)"
        }
        if let badge, SlateBadge.isVisible(badge) {
            label += ", \(SlateBadge.accessibilityLabel(for: badge))"
        }
        return label
    }

    /// The 216pt heading's own wording for a `.count` total — "1 open ask"
    /// singular, "N open asks" otherwise — a pure function so the wording
    /// is testable without a view, the same split `SlateBadge.label` and
    /// `SlateBadgeGlyph.ink` already take. CQ·195: replaces the bare digit
    /// `SlateBadge.label` draws, because a number with no word beside it,
    /// sitting right after the group's name rather than in a column of
    /// other counts, read as part of the name rather than as a count of
    /// anything (the operator, 2026-10-25). `.unknown` keeps `SlateBadge.label`'s
    /// own bare `?` — a reading the host could not establish is not a count
    /// to put a word on.
    static func totalText(for asksOpen: SessionState.AsksOpen) -> String {
        switch asksOpen {
        case .unknown: return SlateBadge.label(for: asksOpen)
        case .count(let n): return n == 1 ? "1 open ask" : "\(n) open asks"
        }
    }

    var body: some View {
        if isCollapsed {
            if group.folded {
                foldedCollapsedRow
            } else {
                // The same rule `RailView.sectionHeader` draws collapsed —
                // an open group needs no heading of its own at 44pt, since
                // its members draw their own marks right below it; only the
                // section BOUNDARY matters here, exactly as it does for
                // "OTHER SESSIONS"/"START".
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityLabel(Self.accessibilityLabel(name: group.name, state: nil, badge: badge))
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggle)
            }
        } else {
            expandedRow
        }
    }

    private var expandedRow: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                // LEADING, before the name — CQ·188: the heading's own
                // disclosure state is what a reader scans for first, the
                // same reason a Finder/Mail outline puts its own fold
                // triangle before the row's label rather than after it.
                // Fixed slot width (`chevronSlotWidth`) so its centre x is
                // exactly `chevronCenterX` regardless of which glyph draws.
                Image(systemName: group.folded ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.chevronSlotWidth)
                if group.folded {
                    marks
                }
                // CQ·195: `.secondary`, not `.tertiary` — the operator,
                // 2026-10-25, "very hard to read." `lineLimit(1)` is what
                // truncates the name ahead of the total below, which keeps
                // its own full width with `.fixedSize()`.
                Text(group.name)
                    .frameFont(.label)
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // CQ·192: right after the name, behind a middle dot in the
                // name's own ink, rather than after the Spacer below in the
                // trailing column a member row's own count sits in — the operator,
                // 2026-10-25, "they are confusing that they are sort of all
                // in the same column." CQ·195: `totalText(for:)`'s words
                // ("N open asks"), not `SlateBadge.label`'s bare digit —
                // `.fixedSize()` so this, needing more width than the digit
                // it replaced, is what the name truncates ahead of rather
                // than what gets squeezed itself.
                if let badge, SlateBadge.isVisible(badge) {
                    Text("·")
                        .frameFont(.label)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text(Self.totalText(for: badge))
                        .frameFont(.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(SlateBadgeGlyph.groupTotalInk(for: badge, on: backing)))
                        .fixedSize()
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityLabel(name: group.name, state: group.folded ? "folded" : "open", badge: badge))
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Every member's colour, in rail order, as a short run of small
    /// squares — distinct from a session's own round dot, since this
    /// stands for several sessions rather than one.
    private var marks: some View {
        HStack(spacing: 2) {
            ForEach(Array(memberColors.enumerated()), id: \.offset) { _, color in
                Rectangle().fill(Color(color)).frame(width: Self.markSize, height: Self.markSize)
            }
        }
    }

    /// Folded, at 44pt: one square carrying up to four of the members'
    /// marks (a fifth has no room to read as its own tile), with the
    /// summed badge beside it — the one exception to "names go, marks
    /// stay" dropping every row's badge at 44pt, because a folded group's
    /// badge is the only thing at this width that says anything is waiting
    /// inside it at all.
    private var foldedCollapsedRow: some View {
        HStack(spacing: 4) {
            squareOfMarks
            if let badge, SlateBadge.isVisible(badge) {
                Text(SlateBadge.label(for: badge))
                    .frameFont(.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(SlateBadgeGlyph.groupTotalInk(for: badge, on: backing)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: RailRow.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .help("\(group.name) (folded)")
        .accessibilityLabel(Self.accessibilityLabel(name: group.name, state: "folded", badge: badge))
    }

    @ViewBuilder
    private var squareOfMarks: some View {
        let side = Self.foldedSquareSize / 2
        let colors = Array(memberColors.prefix(4))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tile(colors, 0, side)
                tile(colors, 1, side)
            }
            HStack(spacing: 0) {
                tile(colors, 2, side)
                tile(colors, 3, side)
            }
        }
        .frame(width: Self.foldedSquareSize, height: Self.foldedSquareSize)
        .overlay(
            Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    @ViewBuilder
    private func tile(_ colors: [RGB], _ index: Int, _ side: CGFloat) -> some View {
        if index < colors.count {
            Rectangle().fill(Color(colors[index])).frame(width: side, height: side)
        } else {
            Color(nsColor: .controlBackgroundColor).frame(width: side, height: side)
        }
    }
}
