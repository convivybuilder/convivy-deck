import AppKit

/// Font and spacing for the terminal canvas.
///
/// SwiftTerm's defaults are `monospacedSystemFont(ofSize: NSFont.systemFontSize)`
/// — 13pt, which is macOS's *UI* text size rather than a terminal size — and
/// `lineSpacing` 1.0, meaning no leading beyond the font's own. Neither was
/// ever chosen for Deck; the pane simply never set them, the same way it never
/// set colors.
struct TerminalTypography: Equatable {
    var fontName: String?
    var fontSize: CGFloat
    /// Multiplier on the font's natural line height. 1.0 is SwiftTerm's
    /// default and packs rows tight enough that dense output (a diff, a log)
    /// reads as a block rather than as lines.
    var lineSpacing: CGFloat

    /// Monaco at natural line spacing — measured against the iTerm2 setup the
    /// operator has actually read all day for years, rather than picked.
    ///
    /// WHY 11.5 AND NOT THE 12 THEIR iTERM USES. SwiftTerm computes cell width as
    /// `ceil(advance * scale) / scale` (AppleTerminalView.computeFontDimensions).
    /// Monaco 12's advance is 7.201pt = 14.402 device pixels on a 2x display,
    /// which `ceil` rounds to 15 — a 7.5pt cell. iTerm does not round up, so it
    /// draws the same font at 7.0pt. Deck was therefore ~7% wider per column at
    /// an identical font and size, which is what the operator saw and reported.
    ///
    /// 11.5 has an advance of 6.901pt = 13.802 pixels, which ceils to 14 — a
    /// 7.0pt cell, exactly matching iTerm. Glyphs render 4% smaller; column
    /// widths match. The snapping makes this a step function, so 11.0 gives the
    /// same 7.0 cell and 11.5 is simply the largest size that fits it.
    ///
    /// This is a workaround for SwiftTerm's rounding, not a preference.
    /// `computeFontDimensions` and `cellDimension` are both internal to
    /// SwiftTerm, so Deck cannot override them. Filed upstream as
    /// migueldeicaza/SwiftTerm#606. If that rounding is ever fixed, revisit
    /// this — Monaco 12 would then match iTerm at full glyph size.
    ///
    /// Why not the monospaced system font (SF Mono), which is what SwiftTerm
    /// falls back to: its advance is 7.42pt at 12pt against Monaco's 7.20, so
    /// every column is 2.9% wider and a 120-column line runs 26pt longer. That
    /// reads as loose letter spacing, which is exactly what the operator reported.
    ///
    /// `lineSpacing` is 1.0 because Monaco already carries the leading. Its
    /// natural line height at 12pt gives a 17pt cell — the same cell an earlier
    /// pass reached by applying 1.2 spacing to SF Mono's tighter 14.1. The
    /// multiplier was compensating for the wrong font; with the right one it is
    /// not needed, and stacking both would over-space the rows.
    ///
    /// Monaco ships with every macOS install, so this resolves for any user,
    /// and `resolvedFont` falls back regardless.
    static let `default` = TerminalTypography(fontName: "Monaco", fontSize: 11.5, lineSpacing: 1.0)

    /// The terminal size the session pane's scale USED to be derived from,
    /// frozen at the value that was live when the two were coupled.
    ///
    /// A HISTORICAL CONSTANT, NOT THE LIVE DEFAULT, and the difference is the
    /// whole point. `parseSession` reproduces what the old
    /// `terminalSize / default` formula gave a user who has not yet saved a
    /// config, so it has to divide by what that formula actually divided by. It
    /// read `default.fontSize` instead, which is the same number today and stops
    /// being the same number the moment the default moves — and it is about to:
    /// SwiftTerm's cell-width rounding was fixed upstream (87a7888, "Fix cell
    /// width rounding to avoid excess spacing"), so `.rounded()` replaces `ceil`
    /// and Monaco 12 lands on the same 7.0pt cell that forced 11.5 in the first
    /// place. When the default follows, a config carrying `fontSize: 13` and no
    /// `session` key would have silently re-inherited 1.083 instead of the 1.130
    /// it had been reading.
    ///
    /// So this never changes. It is a record of what a past version computed,
    /// and a migration that reproduces history cannot be written against a value
    /// that is free to move.
    static let scaleInheritanceBase: CGFloat = 11.5

    /// Bounds keep a mis-set config or a stuck key from producing a terminal
    /// that cannot be read or that computes a nonsensical cell size — SwiftTerm
    /// divides the view by cell dimensions to get rows and columns, so a
    /// near-zero font would ask for an enormous grid.
    static let minimumFontSize: CGFloat = 8
    static let maximumFontSize: CGFloat = 32
    static let minimumLineSpacing: CGFloat = 0.8
    static let maximumLineSpacing: CGFloat = 2.5

    /// Resolves to a concrete font, falling back rather than failing.
    ///
    /// A `fontName` naming a font that isn't installed — a config copied from
    /// another machine — returns nil from `NSFont(name:size:)`. Falling back to
    /// the monospaced system font keeps the terminal usable; refusing to draw
    /// would be a worse answer to a typo.
    var resolvedFont: NSFont {
        let size = clampedFontSize
        if let fontName, let named = NSFont(name: fontName, size: size) {
            return named
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// True when `fontName` was set but could not be resolved, so a caller can
    /// tell "using the default because none was asked for" from "using the
    /// default because the requested one is missing".
    var fontNameIsUnresolvable: Bool {
        guard let fontName else { return false }
        return NSFont(name: fontName, size: clampedFontSize) == nil
    }

    var clampedFontSize: CGFloat {
        Self.clamp(fontSize, Self.minimumFontSize, Self.maximumFontSize,
                   fallback: Self.default.fontSize)
    }

    var clampedLineSpacing: CGFloat {
        Self.clamp(lineSpacing, Self.minimumLineSpacing, Self.maximumLineSpacing,
                   fallback: Self.default.lineSpacing)
    }

    /// NaN-safe clamp.
    ///
    /// `min(max(nan, lo), hi)` returns **nan** — every comparison against NaN
    /// is false, so the value passes straight through a naive clamp. That
    /// matters more than it looks: SwiftTerm derives rows and columns by
    /// dividing the view by cell dimensions, and a NaN font size propagates
    /// into `Int(frame.width / cellDimension.width)`, where converting a NaN
    /// Double to Int traps.
    ///
    /// JSON cannot deliver a NaN today — `JSONSerialization` rejects the
    /// literal, and `-1e999` arrives as -infinity, which a plain clamp does
    /// handle. This is guarding the arithmetic path rather than the parse
    /// path, so a future caller computing a size cannot reintroduce the trap.
    private static func clamp(
        _ value: CGFloat, _ low: CGFloat, _ high: CGFloat, fallback: CGFloat
    ) -> CGFloat {
        guard value.isFinite else { return value.isNaN ? fallback : min(max(value, low), high) }
        return min(max(value, low), high)
    }

    /// One step of Cmd-+ / Cmd--. A point at a time, because terminal text at
    /// these sizes changes character noticeably per point.
    func adjustingFontSize(by delta: CGFloat) -> TerminalTypography {
        var updated = self
        updated.fontSize = min(max(fontSize + delta, Self.minimumFontSize), Self.maximumFontSize)
        return updated
    }
}
