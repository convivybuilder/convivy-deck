#!/usr/bin/env swift
//
// Draws Deck's app icon and emits an .iconset, which `make-app.sh` turns into
// an .icns with `iconutil`.
//
// WHY DRAWN IN CODE. The Convivy sunrise mark exists only as a raster
// (convivy-lab/assets/sunrise-logo.png) — there is no vector source anywhere in
// the repos. Tracing a PNG would bake in its resolution and its green; drawing
// the geometry means every icon size is rendered at native resolution and the
// palette is a parameter, which is what let this become Deck's teal-and-navy
// rather than a recolored screenshot.
//
// The mark is: a disc with a wedge cut to the right forming a C, plus a small
// counter-circle rounding the inner terminal. Colors and gradient are the
// operator's picks, rendered from options and confirmed against measured contrast (see
// the doc comment on drawSun).
import AppKit

// MARK: - Palette

/// The ground is a vertical gradient, teal at the top fading toward its
/// darker end at the bottom.
let groundTop = NSColor(srgbRed: 0x95 / 255.0, green: 0xf2 / 255.0, blue: 0xe8 / 255.0, alpha: 1)
let groundBottom = NSColor(srgbRed: 0x45 / 255.0, green: 0xc6 / 255.0, blue: 0xb8 / 255.0, alpha: 1)
let mark = NSColor(srgbRed: 0x01 / 255.0, green: 0x3a / 255.0, blue: 0x63 / 255.0, alpha: 1)

// MARK: - Drawing

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS 11+ icons sit in a rounded square inset from the canvas, with the
    // margin left transparent — the system draws shadow and reflection into it.
    // Filling the full canvas is the classic tell of an icon made from a
    // screenshot rather than for the platform.
    let margin = size * 0.098
    let art = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let radius = art.width * 0.2237  // Apple's continuous-corner approximation

    let plate = CGPath(roundedRect: art, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Everything below is clipped to the plate so it can't escape the rounded
    // corners.
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()

    drawGround(ctx, art)
    drawSun(ctx, art)

    ctx.restoreGState()
    return image
}

/// The plate's fill: a vertical gradient, top to bottom. Also called, clipped
/// to the counter-circle, so that punch matches the gradient behind it
/// instead of a flat approximation of it.
private func drawGround(_ ctx: CGContext, _ art: CGRect) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [groundTop.cgColor, groundBottom.cgColor] as CFArray,
        locations: [0, 1])
    else { return }
    ctx.drawLinearGradient(gradient,
                            start: CGPoint(x: art.midX, y: art.maxY),
                            end: CGPoint(x: art.midX, y: art.minY),
                            options: [])
}

/// The C: a disc with a wedge removed to the right, plus a small counter-circle
/// that rounds the inner corner where the wedge meets the centre.
///
/// THE THREE MARK CONSTANTS ARE SHARED WITH ORIENT AND ARE NOT FREE TO TUNE
/// HERE. `assets/generate_icons.py` in `convivy-orient` holds the same
/// geometry as `MOUTH_HALF_ANGLE_DEG`, `COUNTER_RADIUS_RATIO` and
/// `COUNTER_OFFSET_RATIO`, and the point of them agreeing is that Convivy has
/// one mark rather than one per surface. Changing a number here without
/// changing it there is how the two drifted apart the first time.
///
/// They come from the operator's reference file, `Convivy_Icons_Palm Green-04.png`,
/// with one deliberate departure. The reference measures a 45-degree mouth
/// half-angle, so a 90-degree mouth, and a counter-circle centred on the disc
/// centre (its measured offset is about one pixel, which is noise). Both are
/// taken as measured. The counter radius is NOT: the reference measures 0.191
/// of the disc radius, and the operator grew it to 0.24 by eye, asking to
/// "narrow the C a little bit, not too much".
///
/// **So do not "correct" 0.24 back to 0.191 by re-measuring the reference.**
/// The measurement is real and it is not what the operator approved. The disc radius of
/// 0.34 is Deck's and Orient's own, tuned for a full-bleed square icon rather
/// than taken from the reference at all.
private func drawSun(_ ctx: CGContext, _ art: CGRect) {
    let center = CGPoint(x: art.midX, y: art.midY)
    let radius = art.width * 0.34
    let mouthHalfAngle: CGFloat = 45 * .pi / 180

    ctx.saveGState()
    ctx.beginPath()
    ctx.move(to: center)
    // Counter-clockwise, i.e. the long way round: this traces the disc MINUS
    // the wedge, which is the C. Going clockwise here fills only the wedge —
    // the bite instead of the sun.
    ctx.addArc(center: center, radius: radius,
               startAngle: mouthHalfAngle, endAngle: -mouthHalfAngle, clockwise: false)
    ctx.closePath()
    ctx.setFillColor(mark.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // The counter-circle is a hole in the mark, not a fill: clip to it and
    // redraw the gradient so the punch matches the ground exactly at that y,
    // rather than approximating it with one flat sample.
    let counterRadius = radius * 0.24
    let counterCenter = center
    ctx.saveGState()
    ctx.beginPath()
    ctx.addArc(center: counterCenter, radius: counterRadius,
               startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.clip()
    drawGround(ctx, art)
    ctx.restoreGState()
}

// MARK: - Emit

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw NSError(domain: "icon", code: 1) }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Redraw at the target pixel size rather than scaling one large render:
    // the counter-circle breaks down under downsampling at 16 and 32px.
    drawIcon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 2)
    }
    try data.write(to: url)
}

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./Deck.iconset"
let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

// The names iconutil expects; anything else is silently ignored.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    try writePNG(drawIcon(size: CGFloat(variant.pixels)), pixels: variant.pixels,
                 to: outputURL.appendingPathComponent("\(variant.name).png"))
}
print("wrote \(variants.count) sizes to \(outputPath)")
