import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// `issue_01M5N409TF90D81XGHVZ5NB6N3`: under Builder Default, `StartPickerView`'s
/// popover inherited the rail's dark colour-scheme pin through the environment —
/// its `.secondary` row name resolved light, as it should on a dark ground — but
/// the popover WINDOW kept drawing its own background from the system's light
/// appearance, since nothing painted the Builder Default ground behind the
/// content. The result was light text on a light system popover.
///
/// Opens the real `StartPickerView` through a real `.popover`, in a real
/// window, under the exact pin `ContentView` applies to the rail
/// (`ThemeConfiguration.empty.pinnedSurface(for: .rail)`), then samples the
/// popover's OWN window — never the anchor window — since that is the
/// surface the defect lived in.
///
/// OPENED BY A `@State` SET IN `onAppear`, NOT A SYNTHESIZED CLICK. A
/// `.popover` driven this way opens with no key window at all — proven while
/// building this file, before the fix existed — whereas a click would need to
/// reach `StartOpenerRow`'s `.onTapGesture`, which only a true key window
/// delivers to (`SlatePaneRenderTests`' click idiom reaches a `Button` the
/// same way AppKit's own click-through does, which a bare gesture recognizer
/// does not get, and this harness's host window never becomes key).
/// `StartPickerView` is `internal` rather than file-private for exactly
/// this: presenting it directly, the same content `StartOpenerRow`'s popover
/// shows, without needing the row's own trigger.
///
/// THE POPOVER'S MATERIAL BACKGROUND IS ITS OWN LAYER, OUTSIDE WHAT A
/// CONTENT-VIEW `cacheDisplay` CAN SEE. Below the filter field, every pixel
/// this file's own capture reads is fully transparent unless `.presentationBackground`
/// paints an opaque fill there — confirmed by scanning the capture before this
/// item's fix existed. That is the fix's own mechanism read back from pixels: a
/// transparent capture there means the system supplies the (light) material at
/// render time outside this file's reach; an opaque one means `StartPickerView`
/// painted it itself.
///
/// Set `DECK_START_PICKER_RENDER_DIR` to keep the popover's PNG. Without it it
/// goes to a temporary directory and is not kept.
@MainActor
final class StartPickerPopoverRenderTests: XCTestCase {
    private let scale = 2

    private func catalog() -> [LaunchableSession] {
        [LaunchableSession(id: "quarry", displayName: "Quarry", host: "mini")]
    }

    /// Opens on appearing, so no click — and no key window — is needed.
    private struct AutoOpeningAnchor<Content: View>: View {
        @State private var showing = false
        let content: () -> Content
        var body: some View {
            Color.clear
                .frame(width: 44, height: 26)
                .popover(isPresented: $showing, arrowEdge: .leading, content: content)
                .onAppear { showing = true }
        }
    }

    /// The real `StartPickerView`, built the way `RailView`'s own `.popover`
    /// closure builds it, wrapped in the anchor above and pinned the way
    /// `ContentView.rail` pins the whole rail.
    private func harness(pinned: PinnedSurface?) -> some View {
        let entries = catalog()
        return AutoOpeningAnchor {
            StartPickerView(
                catalog: entries,
                hasTmuxSession: { _ in false },
                mark: { _ in .unpolled },
                accent: { _ in RGB(red: 0, green: 0, blue: 0) },
                isStopped: { _ in false },
                appearance: .dark,
                onChoose: { _ in },
                onRemove: { _ in },
                onDismiss: {}
            )
        }
        .surfaceAppearance(pinned)
    }

    /// Mounts the harness in a real window and gives the popover time to
    /// open. The caller owns the window and must `orderOut` it.
    private func mount(pinned: PinnedSurface?) async throws -> NSWindow {
        let host = NSHostingView(rootView: harness(pinned: pinned))
        host.frame = NSRect(origin: .zero, size: NSSize(width: 216, height: 60))
        host.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.orderFront(nil)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let opened = try XCTUnwrap(
            NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible },
            "the popover never opened")
        return opened
    }

    /// `rep`'s pixel at `(x, y)` in its own scaled pixel space, or nil when
    /// it is transparent. A popover window carries room around its rounded
    /// card for the arrow and its shadow, and — see this file's own header —
    /// whatever this picker does not itself paint stays transparent in a
    /// content-view capture even where it reads opaque on screen.
    private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> RGB? {
        guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { return nil }
        return RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }

    /// The popover window's own content, as a tagged-sRGB bitmap at `scale` —
    /// `SegmentedFieldRenderTests.read`'s own capture, so colours read back
    /// as drawn rather than shifted by the default calibrated space.
    private func capture(_ window: NSWindow) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView)
        let size = view.bounds.size
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["DECK_START_PICKER_RENDER_DIR"] {
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("start-picker-popover-\(UUID().uuidString.prefix(8)).png"))
        }
        return rep
    }

    /// Column `x`'s last row of the field's own flat fill within
    /// `searchRange`, found in the pixels rather than assumed —
    /// `PinnedAppearanceRenderTests.headerUnderline`'s own idiom. `x` sits
    /// inside the filter field, clear of its rounded corners and the
    /// "Filter" placeholder text, so the first opaque pixel found there is
    /// the field's own fill colour — the one thing this picker always paints
    /// itself, fix or no fix — and the run of matching colour ends exactly
    /// where the field gives way to whatever draws below it (the row list,
    /// this file's own subject). A colour match rather than a mere opacity
    /// check, because after this item's fix the row list is ALSO opaque: an
    /// opacity-only scan would run straight through the field into the row.
    private func fieldBottomScaledY(_ rep: NSBitmapImageRep, x: Int, searchRange: Range<Int>) -> Int? {
        guard let fieldStart = searchRange.first(where: { pixel(rep, x, $0) != nil }),
              let fieldColor = pixel(rep, x, fieldStart) else { return nil }
        var last = fieldStart
        for y in searchRange where y > fieldStart {
            guard let c = pixel(rep, x, y),
                  abs(c.red - fieldColor.red) < 0.004, abs(c.green - fieldColor.green) < 0.004,
                  abs(c.blue - fieldColor.blue) < 0.004
            else { break }
            last = y
        }
        return last
    }

    /// The row's own vertical reach, in points, derived from the field's
    /// measured bottom rather than guessed: `StartPickerView`'s `VStack`
    /// places the row list `spacing: 6` below the field block, and the one
    /// catalog entry this file seeds draws at exactly `RailRow.rowHeight`.
    private func rowReach(fieldBottomPoints: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let top = fieldBottomPoints + 6
        return (top, top + RailRow.rowHeight)
    }

    /// Clear of the row's own leading icon and name, where nothing but the
    /// row's background fill (or, before this item's fix, nothing at all)
    /// draws — the `Spacer` between the name and the row's trailing edge.
    private let rowBackgroundX = 200

    /// The defect itself: under Builder Default, a point behind the row list
    /// — past the field, inside the row's own vertical reach — must be an
    /// OPAQUE, dark pixel (the ground, not the system's light material), and
    /// the row name's ink, light by the rail's own dark colour-scheme pin,
    /// must clear the 4.5:1 text floor against it.
    ///
    /// FAILS on the code before this item's fix at the very first assertion:
    /// nothing paints that point at all there (see this file's header), so
    /// the `XCTUnwrap` throws rather than reaching a wrong colour — the
    /// clearest evidence this picker leaves its background to the system.
    func testPopoverDrawsOnTheGroundWithLegibleRowNameUnderBuilderDefault() async throws {
        let pinned = try XCTUnwrap(ThemeConfiguration.empty.pinnedSurface(for: .rail))
        let popover = try await mount(pinned: pinned)
        defer { popover.orderOut(nil) }
        let rep = try capture(popover)

        let fieldBottomScaled = try XCTUnwrap(
            fieldBottomScaledY(rep, x: rowBackgroundX * scale, searchRange: 0..<(150 * scale)),
            "no opaque field fill found to measure the row's position from")
        let reach = rowReach(fieldBottomPoints: CGFloat(fieldBottomScaled) / CGFloat(scale))
        let rowCenterScaled = Int((reach.top + reach.bottom) / 2 * CGFloat(scale))

        let background = try XCTUnwrap(
            pixel(rep, rowBackgroundX * scale, rowCenterScaled),
            "nothing paints the row's own background at (\(rowBackgroundX), \(rowCenterScaled/scale)pt); " +
            "the system's light popover material is what would show through there on screen")
        XCTAssertLessThan(background.relativeLuminance, 0.3,
                          "the row's background \(background.hexString) should read as the dark ground, not light")

        var ink = RGB(red: 0, green: 0, blue: 0)
        let rowTopScaled = Int(reach.top * CGFloat(scale))
        let rowBottomScaled = Int(reach.bottom * CGFloat(scale))
        for y in rowTopScaled..<rowBottomScaled {
            for x in 0..<rep.pixelsWide {
                guard let c = pixel(rep, x, y) else { continue }
                if c.relativeLuminance > ink.relativeLuminance { ink = c }
            }
        }
        XCTAssertGreaterThanOrEqual(ink.contrastRatio(against: background), ThemeRecipe.minimumTextContrast,
                                    "row name ink \(ink.hexString) should clear 4.5:1 on the row background \(background.hexString)")
    }

    /// The arrow and the card's edges, read from the popover window AS THE
    /// WINDOW SERVER COMPOSITED IT, which is the only capture that includes
    /// the system's popover material; the `cacheDisplay` capture above sees
    /// only what this view paints itself.
    ///
    /// The edges must read as the ground's own green, not merely dark: which
    /// material the system draws depends on the macOS release (on the
    /// operator's macOS 26 laptop it was light, under the same pin it is a
    /// neutral dark grey on macOS 27), and either one showing means the ground
    /// was not painted. An exact match to `StatusGround.ground` is the wrong
    /// check, because the composited popover lifts it slightly (measured
    /// #2c473a over #22382c); the system materials are neutral, so the test
    /// asks for a dark pixel whose green channel clearly leads.
    /// The arrow must match the card body beside it at the same height, since
    /// the focused row's highlight crosses it. Fails on the code before this
    /// item's fix: the edges read as the system material.
    ///
    /// The app is forced to the light system appearance, the operator's own
    /// setting when the defect was reported.
    func testPopoverArrowAndEdgesDrawOnTheGround() async throws {
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        defer { app.appearance = previous }
        let pinned = try XCTUnwrap(ThemeConfiguration.empty.pinnedSurface(for: .rail))
        let ground = try XCTUnwrap(pinned.ground)
        let popover = try await mount(pinned: pinned)
        defer { popover.orderOut(nil) }
        let image = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(popover.windowNumber), [.boundsIgnoreFraming, .bestResolution]))
        let rep = NSBitmapImageRep(cgImage: image)
        if let directory = ProcessInfo.processInfo.environment["DECK_START_PICKER_RENDER_DIR"] {
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("start-picker-popover-window-\(UUID().uuidString.prefix(8)).png"))
        }
        let size = popover.frame.size
        let factor = CGFloat(rep.pixelsWide) / size.width
        func color(_ x: CGFloat, _ y: CGFloat) throws -> RGB {
            let c = try XCTUnwrap(rep.colorAt(x: Int(x * factor), y: Int(y * factor))?.usingColorSpace(.sRGB),
                                  "no pixel at (\(x), \(y))pt")
            return RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
        }
        func assertClose(_ a: RGB, _ b: RGB, _ message: String) {
            XCTAssertLessThan(max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)), 0.03, message)
        }

        // Points, from the window's top-left; the edge samples sit just inside
        // the card's top and bottom-left, clear of text and corners.
        for (name, x, y) in [("top edge", size.width / 2, CGFloat(17)), ("bottom-left", CGFloat(20), size.height - 18)] {
            let edge = try color(x, y)
            XCTAssertLessThan(edge.relativeLuminance, 0.3,
                              "the popover's \(name) \(edge.hexString) should be dark like the ground \(ground.hexString)")
            XCTAssertGreaterThan(edge.green - max(edge.red, edge.blue), 0.04,
                                 "the popover's \(name) \(edge.hexString) should carry the ground's green " +
                                 "\(ground.hexString), not a neutral system material")
        }

        // Column x = 8pt crosses only the leading arrow (the card starts
        // further in), so every opaque pixel there is the arrow, found in the
        // pixels rather than assumed.
        let arrowX = Int(8 * factor)
        let arrowYs = (0..<rep.pixelsHigh).filter { (rep.colorAt(x: arrowX, y: $0)?.alphaComponent ?? 0) > 0.5 }
        let arrowY = CGFloat(try XCTUnwrap(arrowYs.isEmpty ? nil : arrowYs[arrowYs.count / 2],
                                           "no arrow found in column 8pt")) / factor
        let arrow = try color(8, arrowY)
        let body = try color(size.width - 30, arrowY)
        assertClose(arrow, body, "the arrow \(arrow.hexString) should match the card body \(body.hexString) beside it")
    }

    /// With no status ground — `light`/`dark`, not Builder Default — the
    /// picker keeps the system's own popover material: the same point behind
    /// the row list stays unpainted (transparent in this capture), exactly as
    /// it drew before this item's fix. The fix must not force a ground fill
    /// where there is none to draw on.
    func testPopoverKeepsTheSystemMaterialWithNoStatusGround() async throws {
        var config = ThemeConfiguration.empty
        config.appearancePreference = .dark
        let pinned = try XCTUnwrap(config.pinnedSurface(for: .rail))
        XCTAssertNil(pinned.ground, "a `dark` preference pins no status ground; this control would be meaningless against one")
        let popover = try await mount(pinned: pinned)
        defer { popover.orderOut(nil) }
        let rep = try capture(popover)

        let fieldBottomScaled = try XCTUnwrap(
            fieldBottomScaledY(rep, x: rowBackgroundX * scale, searchRange: 0..<(150 * scale)),
            "no opaque field fill found to measure the row's position from")
        let reach = rowReach(fieldBottomPoints: CGFloat(fieldBottomScaled) / CGFloat(scale))
        let rowCenterScaled = Int((reach.top + reach.bottom) / 2 * CGFloat(scale))

        XCTAssertNil(pixel(rep, rowBackgroundX * scale, rowCenterScaled),
                    "with no status ground the fix should not paint anything behind the row; " +
                    "the system's own popover material belongs there, as it always has")
    }
}
