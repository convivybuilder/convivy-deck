import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// The cockpit's secondary text and disclosure chevrons, measured against the
/// ground the cockpit draws on under Builder Default.
///
/// The frame tint comes from `ContentView.paneCanvas(for:appearance:)` through
/// `SessionPaneView.frameTintRGB`, the two calls `cockpitFrameGround` makes, so
/// a change to either one moves these measurements. With no session selected
/// the cockpit draws on the system's light window colour, and that is measured
/// too.
///
/// The probes read their ink through `CockpitView.secondaryInkStyle(on:)` and
/// `tertiaryInkStyle(on:)` from `\.statusGround`, the same path the cockpit's
/// own rows take. Each probe's ink is the darkest pixel its glyph draws, read
/// from a bitmap of the probe over its ground.
@MainActor
final class CockpitFrameTintInkTests: XCTestCase {
    private struct SecondaryProbe: View {
        @Environment(\.statusGround) private var ground
        var body: some View {
            Text("Secondary sample Wj")
                .frameFont(.label)
                .foregroundStyle(CockpitView.secondaryInkStyle(on: ground))
        }
    }

    private struct TertiaryProbe: View {
        @Environment(\.statusGround) private var ground
        var body: some View {
            Image(systemName: "chevron.right")
                .foregroundStyle(CockpitView.tertiaryInkStyle(on: ground))
        }
    }

    /// A fill the cockpit draws under secondary text. `quaternary` is the type
    /// chip's `.quaternary` fill; `accent` is the `Color.accentColor` wash the
    /// child-row highlight, the proposal card and the selected run row draw.
    /// `quaternaryOverAccent` is the type chip inside a highlighted child row:
    /// its `.quaternary` fill sits on the highlight wash, which sits on the ground.
    private enum SampleFill {
        case quaternary
        case accent(opacity: Double)
        case quaternaryOverAccent(opacity: Double)
    }

    /// Text drawn on a fill, shaped as the production site draws it. A nil `ink`
    /// clears the text, so the bitmap holds the fill alone.
    private struct FilledSample: View {
        @Environment(\.statusGround) private var ground
        let fill: SampleFill
        let ink: ((RGB?) -> AnyShapeStyle)?

        var body: some View {
            Text("Secondary sample Wj")
                .frameFont(.caption)
                .foregroundStyle(ink?(ground) ?? AnyShapeStyle(.clear))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background { fillShape }
                .background { underlay }
        }

        @ViewBuilder private var fillShape: some View {
            switch fill {
            case .quaternary, .quaternaryOverAccent:
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
            case .accent(let opacity):
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(opacity))
                    .padding(-4)
            }
        }

        /// The wash beneath a chip. `.background` stacks outward, so this sits
        /// behind `fillShape`.
        @ViewBuilder private var underlay: some View {
            if case .quaternaryOverAccent(let opacity) = fill {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(opacity))
                    .padding(-4)
            }
        }
    }

    /// The composer's frame tint for every catalog theme, as the cockpit reads it.
    private var frameTints: [(name: String, ground: RGB)] {
        ThemeCatalog.all.map { theme in
            let canvas = ContentView.paneCanvas(for: theme.palette(for: .light), appearance: .light)
            return (theme.name, SessionPaneView.frameTintRGB(canvas: canvas.hexString, appearance: .light)!)
        }
    }

    /// The system window colour the cockpit draws on with no session selected.
    private var noSelectionGround: (name: String, ground: RGB) {
        ("no selection", ColumnBandColours.systemRGB(.windowBackgroundColor, .light))
    }

    /// Renders `probe` over `ground` and returns the darkest pixel the probe
    /// draws. A nil ground hosts the probe with no pin, which is what System,
    /// Light and Dark do.
    private func darkestInk<Probe: View>(_ probe: Probe, over ground: RGB?) throws -> RGB {
        let backdrop = ground.map(Color.init) ?? Color(nsColor: .windowBackgroundColor)
        let root = ZStack {
            Rectangle().fill(backdrop)
            probe.padding(6)
        }
        .frame(width: 160, height: 40)
        let pinned = ground.map { _ in PinnedSurface(appearance: .light, ground: ground) }
        let host = NSHostingView(rootView: root.surfaceAppearance(pinned))
        host.frame = NSRect(x: 0, y: 0, width: 160, height: 40)
        host.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        // The predictions are sRGB, so the window draws in sRGB. A headless host
        // already does; on a Display P3 screen the window takes the screen's space,
        // the accent resolves as a P3 colour, and its wash reads up to 0.017 redder.
        window.colorSpace = .sRGB
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        var darkest: RGB?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let pixel = RGB(red: Double(c.redComponent), green: Double(c.greenComponent),
                                blue: Double(c.blueComponent))
                let sum = pixel.red + pixel.green + pixel.blue
                if darkest == nil || sum < darkest!.red + darkest!.green + darkest!.blue { darkest = pixel }
            }
        }
        return try XCTUnwrap(darkest)
    }

    /// The cockpit's secondary text clears the text floor on every frame tint
    /// and on the system ground with no session selected.
    func testSecondaryTextClearsTheTextFloorOnEveryFrameTint() throws {
        for (name, ground) in frameTints + [noSelectionGround] {
            let ink = try darkestInk(SecondaryProbe(), over: ground)
            XCTAssertGreaterThanOrEqual(ink.contrastRatio(against: ground), ThemeRecipe.minimumTextContrast,
                                        "\(name): cockpit secondary text under-contrasts its ground")
        }
    }

    /// The disclosure chevrons are non-text marks, so they clear the mark floor.
    func testTertiaryChevronsClearTheMarkFloorOnEveryFrameTint() throws {
        for (name, ground) in frameTints + [noSelectionGround] {
            let ink = try darkestInk(TertiaryProbe(), over: ground)
            XCTAssertGreaterThanOrEqual(ink.contrastRatio(against: ground), ThemeRecipe.markContrast,
                                        "\(name): cockpit disclosure chevron under-contrasts its ground")
        }
    }

    /// The control. The system secondary style is what the cockpit drew before
    /// the solve, and it sits under the text floor on every frame tint. A probe
    /// that clears the floor above could only do so by reading a solved ink.
    func testTheSystemSecondaryStyleFailsTheFloorOnEveryFrameTint() throws {
        for (name, ground) in frameTints {
            let system = Text("Secondary sample Wj").frameFont(.label).foregroundStyle(.secondary)
            let ink = try darkestInk(system, over: ground)
            XCTAssertLessThan(ink.contrastRatio(against: ground), ThemeRecipe.minimumTextContrast,
                              "\(name): the system secondary style should under-contrast the frame tint")
        }
    }

    /// With no pin, the probe reads the system style, so System, Light and Dark
    /// draw the secondary text exactly as they did before this change.
    func testUnpinnedSecondaryTextDrawsTheSystemStyle() throws {
        let system = Text("Secondary sample Wj").frameFont(.label).foregroundStyle(.secondary)
        let routed = try darkestInk(SecondaryProbe(), over: nil)
        let unrouted = try darkestInk(system, over: nil)
        XCTAssertEqual(routed.red, unrouted.red, accuracy: 0)
        XCTAssertEqual(routed.green, unrouted.green, accuracy: 0)
        XCTAssertEqual(routed.blue, unrouted.blue, accuracy: 0)
    }

    /// The type chip's text against the chip's `.quaternary` fill, composited
    /// over each frame tint, through the same ink function the chip draws with.
    func testTypeChipTextClearsTheTextFloorOnItsCompositedFill() throws {
        try assertInk(on: .quaternary, clears: ThemeRecipe.minimumTextContrast, "type chip") {
            CockpitView.typeChipInkStyle(on: $0, highlighted: false)
        }
    }

    /// The surface the chip's ink solves against is the fill as it renders.
    /// If this drifted, the solve would target a colour the chip never draws.
    func testTypeChipSolveSurfaceMatchesTheRenderedFill() throws {
        for (name, ground) in frameTints + [noSelectionGround] {
            let rendered = try darkestInk(FilledSample(fill: .quaternary, ink: nil), over: ground)
            let predicted = CockpitView.quaternaryComposite(over: ground)
            XCTAssertEqual(predicted.red, rendered.red, accuracy: 0.01, "\(name): red")
            XCTAssertEqual(predicted.green, rendered.green, accuracy: 0.01, "\(name): green")
            XCTAssertEqual(predicted.blue, rendered.blue, accuracy: 0.01, "\(name): blue")
        }
    }

    /// The highlight wash as it renders, composited over each frame tint. The
    /// highlighted chip's solve predicts this surface, so it must match the bitmap.
    func testHighlightWashSurfaceMatchesTheRenderedWash() throws {
        for (name, ground) in frameTints + [noSelectionGround] {
            let rendered = try darkestInk(FilledSample(fill: .accent(opacity: 0.08), ink: nil), over: ground)
            let predicted = CockpitView.highlightWashComposite(over: ground)
            XCTAssertEqual(predicted.red, rendered.red, accuracy: 0.01, "\(name): red")
            XCTAssertEqual(predicted.green, rendered.green, accuracy: 0.01, "\(name): green")
            XCTAssertEqual(predicted.blue, rendered.blue, accuracy: 0.01, "\(name): blue")
        }
    }

    /// The chip's fill over the highlight wash, as the highlighted chip renders it.
    /// The highlighted chip's solve must predict this stacked surface.
    func testTypeChipSolveSurfaceMatchesTheRenderedStack() throws {
        for (name, ground) in frameTints + [noSelectionGround] {
            let rendered = try darkestInk(FilledSample(fill: .quaternaryOverAccent(opacity: 0.08), ink: nil),
                                          over: ground)
            let predicted = CockpitView.quaternaryComposite(over: CockpitView.highlightWashComposite(over: ground))
            XCTAssertEqual(predicted.red, rendered.red, accuracy: 0.01, "\(name): red")
            XCTAssertEqual(predicted.green, rendered.green, accuracy: 0.01, "\(name): green")
            XCTAssertEqual(predicted.blue, rendered.blue, accuracy: 0.01, "\(name): blue")
        }
    }

    /// With no pin, the chip's text draws the system secondary style, so System,
    /// Light and Dark keep the chip as it was.
    func testUnpinnedTypeChipTextDrawsTheSystemStyle() throws {
        let routed = try darkestInk(FilledSample(fill: .quaternary,
                                                 ink: { CockpitView.typeChipInkStyle(on: $0, highlighted: true) }),
                                    over: nil)
        let unrouted = try darkestInk(FilledSample(fill: .quaternary, ink: { _ in AnyShapeStyle(.secondary) }),
                                      over: nil)
        XCTAssertEqual(routed.red, unrouted.red, accuracy: 0)
        XCTAssertEqual(routed.green, unrouted.green, accuracy: 0)
        XCTAssertEqual(routed.blue, unrouted.blue, accuracy: 0)
    }

    /// The child-row highlight's wash sits under a highlighted row's secondary
    /// title, its open button and its copy icon.
    func testChildRowHighlightTextClearsTheTextFloorOnItsCompositedFill() throws {
        try assertInk(on: .accent(opacity: 0.08), clears: ThemeRecipe.minimumTextContrast,
                      "child-row highlight") { CockpitView.secondaryInkStyle(on: $0) }
    }

    /// The selected run row's wash sits under its trailing metadata and task gloss.
    func testSelectedRunRowTextClearsTheTextFloorOnItsCompositedFill() throws {
        try assertInk(on: .accent(opacity: 0.14), clears: ThemeRecipe.minimumTextContrast,
                      "selected run row") { CockpitView.secondaryInkStyle(on: $0) }
    }

    /// The type chip inside a highlighted child row. Its `.quaternary` fill sits
    /// on the 0.08 highlight wash, so the text clears the floor only if the ink
    /// solves against that stack, not against the ground beneath it.
    func testTypeChipOnHighlightedRowClearsTheTextFloor() throws {
        try assertInk(on: .quaternaryOverAccent(opacity: 0.08), clears: ThemeRecipe.minimumTextContrast,
                      "type chip on highlighted row") { CockpitView.typeChipInkStyle(on: $0, highlighted: true) }
    }

    /// The blocked-row lock icon on a highlighted child row. It draws the
    /// attention ink solved against the index surface, which is the ground, and
    /// sits on the 0.08 wash. Icons hold the mark floor.
    func testBlockedLockOnHighlightedRowClearsTheMarkFloor() throws {
        try assertInk(on: .accent(opacity: 0.08), clears: ThemeRecipe.markContrast,
                      "blocked lock on highlighted row") { ground in
            AnyShapeStyle(Color(ThemeRecipe.attentionTextInk(
                on: CockpitView.resolvedIndexSurface(appearance: .light, ground: ground))))
        }
    }

    /// Asserts `ink` clears `floor` against `fill` drawn over every frame tint
    /// and the no-selection ground. The fill is read from the bitmap with its
    /// text cleared, and checked to be darker than its ground, so a sample that
    /// missed the fill cannot pass.
    private func assertInk(on fill: SampleFill, clears floor: Double, _ label: String,
                           ink: @escaping (RGB?) -> AnyShapeStyle) throws {
        for (name, ground) in frameTints + [noSelectionGround] {
            let drawn = try darkestInk(FilledSample(fill: fill, ink: ink), over: ground)
            let surface = try darkestInk(FilledSample(fill: fill, ink: nil), over: ground)
            XCTAssertLessThan(surface.red + surface.green + surface.blue,
                              ground.red + ground.green + ground.blue,
                              "\(name): the \(label) fill should darken its ground")
            let ratio = drawn.contrastRatio(against: surface)
            XCTAssertGreaterThanOrEqual(ratio, floor,
                                        "\(name): \(label) text is \(String(format: "%.2f", ratio)):1 on its fill")
        }
    }
}
