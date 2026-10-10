// Perceptual color space for generating terminal palettes.
//
// WHY NOT HSL. Terminal palettes live or die on readability, which is a
// contrast property, and contrast tracks perceived lightness. HSL's "lightness"
// does not: HSL yellow and HSL blue at L=50% differ by roughly 6:1 in actual
// luminance, so a palette generated at a fixed HSL lightness has some colors
// that vanish into the background and others that shout. OKLCH's L is
// perceptually uniform, so "every ANSI color at L=0.55" is a statement about
// how they will actually look, which is what makes the contrast tests in
// ThemeContrastTests meaningful rather than decorative.
import Foundation

/// A color in the OKLCH cylindrical space: perceptual lightness (0...1),
/// chroma (0 is gray, ~0.37 is the sRGB maximum for some hues), and hue in
/// degrees.
struct OKLCH: Equatable {
    var l: Double
    var c: Double
    var h: Double

    init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }
}

// `RGB` itself is the rail's existing type (Rail/HexColor.swift) — straight
// sRGB, components 0...1. Reused rather than redeclared: two color structs in
// one app is exactly the fragmentation a token source exists to remove.

// MARK: - sRGB transfer function

private func linearize(_ c: Double) -> Double {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

private func delinearize(_ c: Double) -> Double {
    c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055
}

// MARK: - OKLab

extension OKLCH {
    /// Converts to sRGB, reducing chroma until the result fits the gamut.
    ///
    /// Out-of-gamut handling is the whole reason this is not a naive matrix
    /// multiply. A saturated OKLCH color can sit outside sRGB entirely, and
    /// clamping each channel independently — the obvious approach — shifts the
    /// hue, so a "blue" can come back visibly purple. Walking chroma down
    /// preserves hue and lightness, which are the two properties the palette
    /// recipe is actually asserting.
    func toRGB() -> RGB {
        var chroma = c
        // 0.0005 steps: finer than any 8-bit channel can express, so the loop
        // cannot terminate one step short of a representable in-gamut color.
        while chroma > 0 {
            let candidate = OKLCH(l: l, c: chroma, h: h).unclampedRGB()
            if candidate.isInGamut { return candidate.clamped() }
            chroma -= 0.0005
        }
        // Chroma exhausted: an achromatic color at this lightness always fits.
        return OKLCH(l: l, c: 0, h: h).unclampedRGB().clamped()
    }

    private func unclampedRGB() -> RGB {
        let hRad = h * .pi / 180
        let a = c * cos(hRad)
        let bb = c * sin(hRad)

        let lp = l + 0.3963377774 * a + 0.2158037573 * bb
        let mp = l - 0.1055613458 * a - 0.0638541728 * bb
        let sp = l - 0.0894841775 * a - 1.2914855480 * bb

        let lc = lp * lp * lp
        let mc = mp * mp * mp
        let sc = sp * sp * sp

        return RGB(
            red: delinearize(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
            green: delinearize(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
            blue: delinearize(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc)
        )
    }
}

extension RGB {
    /// A hair outside 0...1 is floating-point noise from the matrix, not a real
    /// gamut miss; the tolerance keeps the chroma walk from stepping past a
    /// color that is representable.
    var isInGamut: Bool {
        let tolerance = 1e-6
        return red >= -tolerance && red <= 1 + tolerance
            && green >= -tolerance && green <= 1 + tolerance
            && blue >= -tolerance && blue <= 1 + tolerance
    }

    func clamped() -> RGB {
        RGB(red: min(max(red, 0), 1), green: min(max(green, 0), 1), blue: min(max(blue, 0), 1))
    }

    /// WCAG 2.1 relative luminance.
    var relativeLuminance: Double {
        0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    /// WCAG contrast ratio, 1...21. Order-independent.
    func contrastRatio(against other: RGB) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour with its perceptual lightness raised by `delta`.
    ///
    /// The session pane's canvas is the terminal's background lifted a little,
    /// so the document reads as a surface on the same theme rather than a window
    /// from somewhere else — which means the lift has to keep the theme's hue.
    ///
    /// RAISING OKLCH L, NOT MIXING TOWARD WHITE. Mixing was the first attempt
    /// and it is wrong in both spaces. In linear light a 6% mix takes a warm
    /// near-black `#16100b` to `#494847`: an enormous jump, because 0.06 of
    /// linear light is a quarter of the way up the encoded scale down there, and
    /// neutral grey, because mixing toward white pulls chroma out. In sRGB the
    /// jump is better behaved but still desaturates. Adding to L moves exactly
    /// the property the word "lighter" refers to and leaves hue and chroma
    /// where the theme put them.
    func lightened(by delta: Double) -> RGB {
        var lch = toOKLCH()
        lch.l = min(max(lch.l + delta, 0), 1)
        return lch.toRGB()
    }

    /// The session pane's canvas: this colour moved AWAY from the appearance's
    /// extreme, with its hue strengthened.
    ///
    /// DIRECTION IS THE WHOLE FIX. `lightened` always moved toward white, which
    /// is away from black on a dark theme and *toward the background* on a light
    /// one — so in light mode every canvas came out `#ffffff` and the theme was
    /// erased. The operator ran light mode and saw a white pane on white.
    ///
    /// Chroma is raised as well as lightness moved, because on a near-white or
    /// near-black background a lightness step alone reads as "slightly grey"
    /// rather than as the theme's colour. The multiplier is what makes deck read
    /// warm and vivy read green instead of both reading "a bit off-white".
    func canvasTint(for appearance: Appearance, lift: Double, chroma: Double) -> RGB {
        var lch = toOKLCH()
        lch.l = min(max(appearance == .dark ? lch.l + lift : lch.l - lift, 0), 1)
        lch.c = min(lch.c * chroma, 0.4)
        return lch.toRGB()
    }

    /// The inverse of `OKLCH.unclampedRGB`, for a colour already inside sRGB.
    func toOKLCH() -> OKLCH {
        let r = linearize(red), g = linearize(green), b = linearize(blue)

        let lc = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let mc = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let sc = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

        let lp = cbrt(lc), mp = cbrt(mc), sp = cbrt(sc)

        let l = 0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp
        let a = 1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp
        let bb = 0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp

        let chroma = (a * a + bb * bb).squareRoot()
        // atan2 gives -180...180; the forward direction takes any angle, but a
        // canonical 0...360 keeps a round trip comparable to its input.
        var hue = atan2(bb, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return OKLCH(l: l, c: chroma, h: hue)
    }

    var hexString: String {
        String(format: "#%02x%02x%02x",
               Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}
