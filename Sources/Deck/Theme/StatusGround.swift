import SwiftUI

/// The dark ground the status panes draw on under Builder Default: the rail,
/// the unresolved-host pane, the bead pane, the top bar and the Course strip. The cockpit
/// draws on its session's frame tint instead, and the green frame around it is
/// this ground.
///
/// ONE VALUE SETS THE GROUND. `ground` is the only literal here. The raised
/// surface, the divider and the primary ink are derived from it in OKLCH, so
/// moving the ground to another colour (Builder green `#1d3026`, for one)
/// re-solves every value below without touching them. The contrast tests in
/// `StatusGroundTests` read these tokens, so a later ground change re-checks
/// the status inks and the crew marks.
///
/// Deck has no generated design-token source yet, so `ground` is a value copied
/// by hand. It is Builder's hero band in the light scheme of the Builder site
/// (`--hero-bg: #22382c`, in `shipwright/tools/build-site.py`). Replace the
/// literal with the generated token once Deck has a token source. The operator
/// picked this value on 2026-10-04 from a rendered set of options; the darker
/// `#1d3026` was the design pass's recommendation, and they may switch to it
/// after living with this.
enum StatusGround {
    /// The status panes' ground. Change this one literal to change the ground.
    static let ground: RGB = parseHexColor("22382c")!

    /// A control or a raised strip on the ground, such as the rail's filter
    /// field: `ground` lifted by 0.045 OKLCH lightness.
    static let raised: RGB = lightened(ground, by: 0.045)

    /// A hairline on the ground: `ground` lifted by 0.10 OKLCH lightness, so
    /// it stays visible on `raised` too.
    static let divider: RGB = lightened(ground, by: 0.10)

    /// The field under a segmented picker on the ground, such as the top bar's
    /// Session/Terminal and Cockpit/Shell pills: `ground` lifted by 0.060
    /// OKLCH lightness, which is `#31483b` from `#22382c`.
    ///
    /// The native picker draws its dark track as a translucent white wash, so
    /// on screen this field reads about 0.11 lighter than the ground (1.59:1),
    /// past `divider`'s 1.50:1. With no fill under it the wash alone measured
    /// 1.26:1, and the operator could not tell the field from the ground. The selected
    /// pill is a stronger wash over this fill, and its label sets the ceiling:
    /// a fill at 0.090 puts that label at 4.20:1, under the 4.5:1 text floor.
    /// `SegmentedFieldRenderTests` measures both bounds.
    static let segmentedField: RGB = lightened(ground, by: 0.060)

    /// The text the status panes draw at full strength: a near-white tinted
    /// toward the ground's hue.
    static let primaryInk: RGB = OKLCH(l: 0.94, c: 0.012, h: ground.toOKLCH().h).toRGB()

    private static func lightened(_ color: RGB, by step: Double) -> RGB {
        var lifted = color.toOKLCH()
        lifted.l += step
        return lifted.toRGB()
    }
}

private struct StatusGroundKey: EnvironmentKey {
    static let defaultValue: RGB? = nil
}

extension EnvironmentValues {
    /// The ground of the status pane a view is drawn in, or `nil` when that
    /// pane draws on the system's own dark ground (or is not a status pane).
    ///
    /// `AppearanceSurface`'s `surfaceAppearance` sets this for each pinned
    /// subtree, from the shell's resolved preference. A view reads it to
    /// choose its own fill and to solve its inks. It never decides the ground
    /// for itself.
    var statusGround: RGB? {
        get { self[StatusGroundKey.self] }
        set { self[StatusGroundKey.self] = newValue }
    }
}
