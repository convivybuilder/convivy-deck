import Foundation

/// The width thresholds that make Deck's layout give way below its old fixed
/// floor — `design/redesign/04-narrow.html`, "What gives way, in order".
/// Nothing in Deck read a window width before this phase; every value here
/// is a threshold on the window's own measured row width, not on the pane
/// row `ContentView.clampedColumnWidth` already clamps against.
///
/// PICKS THE SPEC'S OWN PROSE OVER ITS FRAME LABELS. `04-narrow.html` draws
/// its two collapsed states at 1100pt and 820pt, but its own "What gives
/// way" list states the thresholds as 1280pt and 1000pt — the frame widths
/// are comfortably inside each range rather than sitting AT the edge (1100 <
/// 1280, 820 < 1000), so the two are consistent rather than contradictory,
/// and the prose is the more precise of the two. See the PR body for why
/// this reading was chosen over the work item's own paraphrase, which cites
/// 1100/820 as if they were the thresholds themselves.
enum LayoutBreakpoints {
    /// Below this, the rail collapses from 216pt to a 44pt dot rail — names
    /// go, marks stay.
    static let railCollapse: Double = 1280
    /// Below this, the right column stops splitting the row and arrives as
    /// a sheet over the conversation instead, summoned by the toolbar's
    /// segmented control and dismissed by clicking outside it.
    static let columnSheet: Double = 1000
    /// The window's new floor, replacing the old fixed 900: 44 (the
    /// collapsed rail) + 640 (the conversation's own reading measure) + 36
    /// (divider allowances) — `04-narrow.html`.
    static let windowMinWidth: Double = 720

    static func isRailCollapsed(totalWidth: Double) -> Bool { totalWidth < railCollapse }
    static func usesColumnSheet(totalWidth: Double) -> Bool { totalWidth < columnSheet }
}
