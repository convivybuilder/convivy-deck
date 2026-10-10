import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What `ColumnBand` DRAWS at the two column widths the right column takes
/// (320pt by default, 280pt at its minimum), in both appearances.
///
/// Rendered through `NSHostingView` + `cacheDisplay`, never `ImageRenderer`,
/// which draws `ScrollView` contents blank (`SlatePaneRenderTests`' own note).
/// The assertions sample pixels. Each expected colour is itself a swatch drawn
/// through the same pipeline, because SwiftUI's colour conversion moves a
/// saturated ink a few hundredths off its raw value on the way to the bitmap.
@MainActor
final class ColumnBandRenderTests: XCTestCase {
    private let bandHeight: CGFloat = 32

    /// Draws `view` in a titled window's content view at `size` and returns
    /// what `cacheDisplay` captured.
    private func snapshot<V: View>(_ view: V, size: NSSize, appearance: Appearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func render(_ colours: ColumnBandColours, width: CGFloat, place: String?,
                        appearance: Appearance) throws -> NSBitmapImageRep {
        let band = ColumnBand(title: "Shell", icon: "terminal.fill", place: place, colours: colours) {
            Image(systemName: "xmark")
        }
        return try snapshot(band.frame(width: width, height: bandHeight, alignment: .top),
                            size: NSSize(width: width, height: bandHeight), appearance: appearance)
    }

    /// The colour SwiftUI paints for `rgb`, read back from a swatch.
    private func swatch(_ rgb: RGB, _ appearance: Appearance) throws -> RGB {
        let rep = try snapshot(Rectangle().fill(Color(rgb)).frame(width: 40, height: 40),
                               size: NSSize(width: 40, height: 40), appearance: appearance)
        return try colour(rep, x: 20, y: 20, width: 40)
    }

    /// The colour at a point, measured from the top-left of the band, so the
    /// rule and the fill can be sampled without knowing the bitmap's scale.
    private func colour(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat, width: CGFloat) throws -> RGB {
        let scale = CGFloat(rep.pixelsWide) / width
        let sampled = try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        return RGB(red: Double(sampled.redComponent),
                   green: Double(sampled.greenComponent),
                   blue: Double(sampled.blueComponent))
    }

    private func assertClose(_ actual: RGB, _ expected: RGB, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let tolerance = 0.03
        XCTAssertEqual(actual.red, expected.red, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(actual.green, expected.green, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(actual.blue, expected.blue, accuracy: tolerance, message, file: file, line: line)
    }

    /// An identity band fills with its surface and closes with a 2pt rule in
    /// its ink. Both must reach the screen, in both appearances at both widths,
    /// for a warm crew (amber, the summons' neighbour) and a cool one (teal).
    func testAnIdentityBandPaintsItsSurfaceAndItsRule() throws {
        for (themeName, hueTheme) in [("amber", ThemeCatalog.all[1]), ("teal", ThemeCatalog.all[4])] {
            for appearance in [Appearance.light, .dark] {
                let palette = hueTheme.palette(for: appearance)
                let canvas = palette.background.canvasTint(for: appearance,
                                                           lift: ContentView.canvasLift,
                                                           chroma: ContentView.canvasChroma)
                let colours = ColumnBandColours.identity(canvas: canvas, accent: palette.cursor, appearance)
                let expectedFill = try swatch(colours.surface, appearance)
                let expectedRule = try swatch(colours.ink, appearance)
                for width in [CGFloat(320), 280] {
                    let rep = try render(colours, width: width, place: "macstudio", appearance: appearance)
                    let label = "\(themeName) \(appearance) at \(width)pt"
                    assertClose(try colour(rep, x: width - 6, y: 4, width: width), expectedFill,
                                "fill, \(label)")
                    assertClose(try colour(rep, x: 4, y: bandHeight - 1, width: width), expectedRule,
                                "rule, \(label)")
                }
            }
        }
    }

    /// The neutral band fills with the window background and has no rule. Its
    /// bottom row is the plain separator, not the identity ink.
    func testTheNeutralBandPaintsTheWindowBackgroundWithoutARule() throws {
        for appearance in [Appearance.light, .dark] {
            let colours = ColumnBandColours.neutral(appearance)
            XCTAssertFalse(colours.hasRule)
            let expectedFill = try swatch(colours.surface, appearance)
            let rep = try render(colours, width: 320, place: nil, appearance: appearance)
            assertClose(try colour(rep, x: 306, y: 4, width: 320), expectedFill,
                        "neutral fill, \(appearance)")
        }
    }

    /// A long host at the narrow width still fills to the trailing edge: the
    /// place line truncates inside the band rather than pushing it wider.
    func testALongHostAtTwoEightyKeepsTheBandInItsFrame() throws {
        let palette = ThemeCatalog.all[0].palette(for: .light)
        let canvas = palette.background.canvasTint(for: .light,
                                                   lift: ContentView.canvasLift,
                                                   chroma: ContentView.canvasChroma)
        let colours = ColumnBandColours.identity(canvas: canvas, accent: palette.cursor, .light)
        let expectedFill = try swatch(colours.surface, .light)
        let rep = try render(colours, width: 280, place: "deck-coder-on-a-very-long-host.example.internal",
                             appearance: .light)
        assertClose(try colour(rep, x: 274, y: 4, width: 280), expectedFill, "fill, long host at 280pt")
    }
}

/// The right column's picker, drawn by the real `ContentView` the way the app
/// draws it at rest: one selection-free Cockpit, Shell and Local.
///
/// A segmented control's labels are read back off the `NSSegmentedControl`
/// that `ContentView` hosts. The rest state has three segments, which is what
/// `HostedPaneChromeRowWidthTests` relies on too. The icon-only form needs a
/// fourth or fifth segment (a Slate, an open item), which a freshly hosted
/// view never has, so `RightColumnPickerFormTests` draws those counts directly.
@MainActor
final class RightColumnPickerRenderTests: XCTestCase {
    private func store(columnWidth: Double) throws -> ThemeStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-column-picker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("theme.json")
        try #"{"columnWidth": \#(columnWidth)}"#.write(to: file, atomically: true, encoding: .utf8)
        return ThemeStore(fileURL: file)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    /// Hosts the real `ContentView` at a 1400pt window, which docks the column
    /// at `columnWidth`, and returns the three-segment right column picker.
    private func rightColumnPicker(columnWidth: Double) throws -> NSSegmentedControl {
        let themeStore = try store(columnWidth: columnWidth)
        let view = ContentView()
            .environmentObject(themeStore)
            .environmentObject(WorkingCopyServer())
            .environmentObject(RailStateModel())
            .environmentObject(DesktopSessionAlertCenter())
            .environmentObject(SettingsNavigation())
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let segmented = descendants(of: host).compactMap { $0 as? NSSegmentedControl }
        return try XCTUnwrap(segmented.first { $0.segmentCount == 3 },
                             "no 3-segment control — is the Right column picker even hosted?")
    }

    /// At 320pt and at 280pt the rest state's labelled form fits, so every
    /// segment keeps its title. The 225pt labelled form is the reason a
    /// three-segment picker never falls back at either width.
    func testTheRestStatePickerIsLabelledAtBothColumnWidths() throws {
        for columnWidth in [320.0, 280.0] {
            let picker = try rightColumnPicker(columnWidth: columnWidth)
            XCTAssertEqual(picker.label(forSegment: 0), "Cockpit", "\(columnWidth)pt")
            XCTAssertEqual(picker.label(forSegment: 1), "Shell", "\(columnWidth)pt")
            XCTAssertEqual(picker.label(forSegment: 2), "Local", "\(columnWidth)pt")
        }
    }
}

/// The form `RightColumnPicker` draws for a segment count at a column width:
/// every segment labelled, or every segment icon-only. SwiftUI makes that
/// choice (`ViewThatFits`), so each test reads the form the segmented control
/// drew rather than a model of it.
///
/// A labelled segment reads back its title; an icon-only segment reads back an
/// empty label and an image. The labelled four-segment case at 320pt is the
/// positive control for that read: were `label(forSegment:)` empty everywhere,
/// the icon-only assertions would pass for any picker.
@MainActor
final class RightColumnPickerFormTests: XCTestCase {
    private enum Form: Equatable { case labelled, iconOnly }

    private struct Item {
        let tag: ColumnOccupant
        let title: String
        let icon: String
    }

    private static let items = [
        Item(tag: .run(runId: "run-1"), title: "Cockpit", icon: "square.grid.2x2.fill"),
        Item(tag: .run(runId: "run-2"), title: "Shell", icon: "terminal.fill"),
        Item(tag: .run(runId: "run-3"), title: "Local", icon: "laptopcomputer"),
        Item(tag: .run(runId: "run-4"), title: "Slate", icon: "list.bullet.clipboard.fill"),
        Item(tag: .run(runId: "run-5"), title: "Viewer", icon: "doc.text"),
    ]

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    /// Hosts a `RightColumnPicker` of the first `count` items at `width` and
    /// returns the segmented control it drew.
    private func picker(segments count: Int, width: CGFloat) throws -> NSSegmentedControl {
        let shown = Array(Self.items.prefix(count))
        let view = RightColumnPicker(selection: .constant(Self.items[0].tag), fittingWidth: width) { iconOnly in
            ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                columnSegment(item.title, item.icon, iconOnly: iconOnly, tag: item.tag)
            }
        }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 40)
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let control = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(control.segmentCount, count, "segment count at \(width)pt")
        return control
    }

    /// The form the control drew, or nil when its segments are neither every
    /// title nor every icon.
    private func form(of control: NSSegmentedControl) -> Form? {
        let labels = (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
        if labels == Self.items.prefix(control.segmentCount).map(\.title) { return .labelled }
        let iconsOnly = labels.allSatisfy(\.isEmpty)
            && (0..<control.segmentCount).allSatisfy { control.image(forSegment: $0) != nil }
        return iconsOnly ? .iconOnly : nil
    }

    /// Three segments fit labelled at 280pt, the rest state's own width.
    func testThreeSegmentsStayLabelledAtTwoEightyPoints() throws {
        XCTAssertEqual(form(of: try picker(segments: 3, width: 280)), .labelled)
    }

    /// Four labelled segments fit at 320pt, so every title is drawn.
    func testFourSegmentsStayLabelledAtThreeTwentyPoints() throws {
        XCTAssertEqual(form(of: try picker(segments: 4, width: 320)), .labelled)
    }

    /// Four labelled segments overflow 280pt, so the picker draws icons. A
    /// regression that kept the labels here would fail this test.
    func testFourSegmentsDrawIconsAtTwoEightyPoints() throws {
        XCTAssertEqual(form(of: try picker(segments: 4, width: 280)), .iconOnly)
    }

    /// Five segments are icon-only at 280pt, the column's minimum.
    func testFiveSegmentsDrawIconsAtTwoEightyPoints() throws {
        XCTAssertEqual(form(of: try picker(segments: 5, width: 280)), .iconOnly)
    }

    /// Five segments are icon-only at 320pt too: five titles do not fit the
    /// default column, so the icon form is the only one offered.
    func testFiveSegmentsDrawIconsAtThreeTwentyPoints() throws {
        XCTAssertEqual(form(of: try picker(segments: 5, width: 320)), .iconOnly)
    }
}

