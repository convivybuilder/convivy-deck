import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// The Builder Default ground as drawn, read from pixels.
///
/// The whole window is hosted at 1440×880 with no session selected, the way
/// `SplitAppearanceRenderTests` hosts it, and the right column is set to the
/// two widths the cockpit draws at: 320pt (the default) and 280pt (the
/// minimum). A region reads as the ground when most of its pixels sit within
/// `tolerance` of `StatusGround.ground` in every sRGB channel. Text in a region
/// takes a minority of its pixels, so the fraction stays high on a clear ground
/// and falls to zero where the ground is not drawn.
///
/// The explicit `dark` render on a dark host is the control. Its status panes draw on the
/// system's dark ground, which is nowhere near the Builder green, so the same
/// regions must measure zero there.
///
/// Set `DECK_BUILDER_DEFAULT_RENDER_DIR` to keep the PNGs. Without it they go
/// to a temporary directory and are not kept.
@MainActor
final class BuilderDefaultRenderTests: XCTestCase {
    private let windowSize = NSSize(width: 1440, height: 880)
    private let tolerance = 0.02

    /// Points, top-left origin, clear of text: the rail's leading strip.
    private let railRegion = NSRect(x: 8, y: 400, width: 52, height: 120)

    /// The cockpit's leading strip for a right column `width` points wide,
    /// inside the column and clear of its header text.
    private func cockpitRegion(width: CGFloat) -> NSRect {
        NSRect(x: windowSize.width - width + 4, y: 300, width: 12, height: 120)
    }

    /// The green band on the cockpit's right edge: the column's trailing 12pt,
    /// clear of the window's own edge and of the cockpit's content.
    private let bandRegion = NSRect(x: 1432, y: 300, width: 6, height: 120)

    /// Points, top-left origin, in the top bar's own band above the pills and
    /// clear of the segmented controls and the host label.
    private let topBarRegion = NSRect(x: 300, y: 6, width: 40, height: 6)

    /// The Course strip's leading edge: the ribbon's padding, clear of the first
    /// waypoint's dot. The strip is hosted at its own height, so this spans it.
    private let stripRegion = NSRect(x: 0, y: 0, width: 8, height: WaypointRibbon.height)

    private func themeStore(json: String) throws -> ThemeStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-builder-default-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return ThemeStore(fileURL: file)
    }

    /// The config is written without an `appearance` key for Builder Default,
    /// which is the never-set case this work changes. The `dark` control keeps
    /// the key, so it is an explicit choice.
    ///
    /// It names no host and no rail session. The rail polls every configured
    /// host over ssh, and a poll blocks a thread of Swift's cooperative pool
    /// for as long as the ssh call runs. A host that never answers holds that
    /// thread for the whole timeout, and the poll repeats every few seconds, so
    /// the tests that follow starve: the same run of `CockpitRevealTests` took
    /// 143s per reveal when this fixture named a host. With no host and no
    /// session the rail's refresh returns before it starts any work.
    private func themeJSON(appearance: String?, columnWidth: Int) -> String {
        let appearanceLine = appearance.map { "\"appearance\": \"\($0)\"," } ?? ""
        return """
        {
          \(appearanceLine)
          "columnWidth": \(columnWidth)
        }
        """
    }

    private func render(appearance: String?, columnWidth: Int,
                        host name: NSAppearance.Name = .aqua) async throws -> NSBitmapImageRep {
        let hostAppearance = try XCTUnwrap(NSAppearance(named: name))
        let view = ContentView()
            .environmentObject(try themeStore(json: themeJSON(appearance: appearance,
                                                              columnWidth: columnWidth)))
            .environmentObject(WorkingCopyServer())
            .environmentObject(RailStateModel())
            .environmentObject(DesktopSessionAlertCenter())
            .environmentObject(SettingsNavigation())
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: windowSize)
        // The system scheme comes from this host, so it is set before layout:
        // the render must not depend on the machine running the suite.
        host.appearance = hostAppearance
        host.wantsLayer = true
        var backdrop: CGColor?
        hostAppearance.performAsCurrentDrawingAppearance {
            backdrop = NSColor.windowBackgroundColor.cgColor
        }
        host.layer?.backgroundColor = backdrop
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        // A second pass, for the same reason `SplitAppearanceRenderTests` takes
        // one: the column's width arrives through an `.onAppear`-set `@State`.
        host.layoutSubtreeIfNeeded()
        // Suspended, not spun, so the rail's and cockpit's `.task`s can run.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        defer { tearDown(window) }
        // Only the content below the title bar. Under Builder Default the host
        // reaches up under a transparent title bar, and every region below is
        // measured from the content's top edge.
        let titleBar = window.frame.height - window.contentLayoutRect.height
        let content = NSRect(x: 0, y: titleBar, width: host.bounds.width, height: host.bounds.height - titleBar)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: content))
        host.cacheDisplay(in: content, to: rep)
        return rep
    }

    /// Takes the window and the tree it hosts down. Hiding the window alone
    /// leaves the hosted tree and its rail poll alive into later tests.
    private func tearDown(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }

    /// The share of pixels in `region` that sit within `tolerance` of the
    /// ground in every channel. Points are scaled to the bitmap's pixels.
    ///
    /// The components are read as `colorAt` returns them. The bitmap is in the
    /// calibrated RGB space the view drew into, whose components equal the
    /// colour the view was given. Converting to sRGB shifts them by about 0.04,
    /// which is more than the tolerance, so the conversion would fail a correct
    /// ground.
    private func groundFraction(_ rep: NSBitmapImageRep, _ region: NSRect) -> Double {
        let ground = StatusGround.ground
        // The rep's own point width, so a strip hosted narrower than the window
        // scales against its own bitmap.
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var near = 0.0
        var count = 0.0
        for y in Int(region.minY * scale)..<Int(region.maxY * scale) {
            for x in Int(region.minX * scale)..<Int(region.maxX * scale) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let matches = abs(Double(color.redComponent) - ground.red) < tolerance
                    && abs(Double(color.greenComponent) - ground.green) < tolerance
                    && abs(Double(color.blueComponent) - ground.blue) < tolerance
                if matches { near += 1 }
                count += 1
            }
        }
        return near / count
    }

    private func save(_ rep: NSBitmapImageRep, named name: String) throws {
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let directory = ProcessInfo.processInfo.environment["DECK_BUILDER_DEFAULT_RENDER_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name))
    }

    /// A never-set preference draws the rail on the Builder Default ground and
    /// the green band down the 320pt cockpit's edge. The cockpit body draws on
    /// its session's frame tint, and with no session selected that is the
    /// system's light ground, not green. The `dark` control draws none of it on
    /// the green.
    func testNeverSetDrawsTheStatusPanesOnTheGroundAt320() async throws {
        let builder = try await render(appearance: nil, columnWidth: 320)
        let control = try await render(appearance: "dark", columnWidth: 320, host: .darkAqua)
        try save(builder, named: "window-builder-default-320.png")
        try save(control, named: "window-dark-control-320.png")

        XCTAssertGreaterThan(groundFraction(builder, railRegion), 0.6,
                             "the rail should draw on the Builder Default ground")
        XCTAssertGreaterThan(groundFraction(builder, bandRegion), 0.6,
                             "the green band should close the window's frame on the cockpit's right edge")
        XCTAssertEqual(groundFraction(builder, cockpitRegion(width: 320)), 0,
                       "with no session selected the cockpit body must not draw on the green")
        XCTAssertEqual(groundFraction(control, railRegion), 0,
                       "control: an explicit dark rail must not draw on the Builder green")
        XCTAssertEqual(groundFraction(control, bandRegion), 0,
                       "control: no band under an explicit dark preference")
        XCTAssertEqual(groundFraction(control, cockpitRegion(width: 320)), 0,
                       "control: an explicit dark cockpit must not draw on the Builder green")
    }

    /// The same at the 280pt minimum, where the column is narrowest. The band
    /// stays on the window's own edge at both widths.
    func testNeverSetDrawsTheStatusPanesOnTheGroundAt280() async throws {
        let builder = try await render(appearance: nil, columnWidth: 280)
        try save(builder, named: "window-builder-default-280.png")

        XCTAssertGreaterThan(groundFraction(builder, railRegion), 0.6,
                             "the rail should draw on the Builder Default ground")
        XCTAssertGreaterThan(groundFraction(builder, bandRegion), 0.6,
                             "the green band should close the window's frame at 280pt")
        XCTAssertEqual(groundFraction(builder, cockpitRegion(width: 280)), 0,
                       "with no session selected the 280pt cockpit body must not draw on the green")
    }

    /// The band is laid out beside the cockpit, so the cockpit's header and its
    /// refresh button stay clear of it. At both widths the band's full 12pt is
    /// pure ground, and the header's rightmost dark ink, the refresh glyph, ends
    /// at least 2pt left of the band. Under the old overlay the band covered the
    /// glyph's trailing edge, so its ink ended at the band's leading edge.
    func testCockpitHeaderAndRefreshClearTheBandAt320AndAt280() async throws {
        let bandStart = windowSize.width - ContentView.cockpitFrameBandWidth
        let band = NSRect(x: bandStart, y: 300, width: ContentView.cockpitFrameBandWidth, height: 120)
        for columnWidth in [320, 280] {
            let builder = try await render(appearance: nil, columnWidth: columnWidth)
            XCTAssertGreaterThanOrEqual(groundFraction(builder, band), 0.98,
                                        "the band's full 12pt should be pure ground at \(columnWidth)pt")

            // The header strip, from the cockpit's leading edge to the band. Its
            // ink is the title and the refresh glyph, and the rightmost of it is
            // the refresh glyph's trailing edge.
            let cockpitLeading = windowSize.width - CGFloat(columnWidth)
            let header = NSRect(x: cockpitLeading, y: 34, width: bandStart - cockpitLeading, height: 20)
            let inkEdge = try XCTUnwrap(rightmostInkX(builder, header),
                                        "the cockpit header should draw ink at \(columnWidth)pt; a nil here is a failed render, not a pass")
            XCTAssertLessThanOrEqual(inkEdge, bandStart - 2,
                                     "the refresh button should end left of the band at \(columnWidth)pt, not under it")
        }
    }

    /// The rightmost x, in points, of a neutral pixel in `region` whose mean
    /// channel is under 0.5: the cockpit header's grey label ink on its light
    /// ground. Nil when the region holds no such pixel.
    ///
    /// The cockpit pane's rounded top-right corner meets the band inside this
    /// strip. At 2x its anti-aliased edge lands in the half-point column beside
    /// the band, a blend of the pane's white and the band's green that is dark
    /// enough to pass the mean test. A blend that dark is at least 60% ground, so
    /// its channels spread by 0.05 or more; label ink's spread is zero.
    private func rightmostInkX(_ rep: NSBitmapImageRep, _ region: NSRect) -> CGFloat? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        for x in stride(from: Int(region.maxX * scale) - 1, through: Int(region.minX * scale), by: -1) {
            for y in Int(region.minY * scale)..<Int(region.maxY * scale) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let channels = [Double(color.redComponent), Double(color.greenComponent),
                                Double(color.blueComponent)]
                let mean = channels.reduce(0, +) / 3
                let spread = channels.max()! - channels.min()!
                if mean < 0.5 && spread < 0.03 { return CGFloat(x) / scale }
            }
        }
        return nil
    }

    // MARK: - The top bar and the Course strip

    /// The Session/Terminal and Cockpit/Shell pills' bar draws on the ground
    /// under Builder Default, and stays the system's light chrome under `dark`,
    /// the control, which must measure zero there.
    func testTopBarDrawsOnTheGroundAt320AndAt280() async throws {
        for columnWidth in [320, 280] {
            let builder = try await render(appearance: nil, columnWidth: columnWidth)
            XCTAssertGreaterThan(groundFraction(builder, topBarRegion), 0.6,
                                 "the top bar should draw on the Builder Default ground at \(columnWidth)pt")
            if columnWidth == 320 {
                try save(builder, named: "window-top-bar-builder-default-320.png")
                let control = try await render(appearance: "dark", columnWidth: 320, host: .darkAqua)
                XCTAssertEqual(groundFraction(control, topBarRegion), 0,
                               "control: an explicit dark top bar must not draw on the Builder green")
            }
        }
    }

    /// The Course strip, hosted at the widths the bottom of the session pane gets,
    /// draws on the ground under Builder Default. `course` needs a live Library
    /// fetch, so the strip is hosted alone with the same pin the shell applies.
    func testCourseStripDrawsOnTheGroundAt320AndAt280() async throws {
        for width in [CGFloat(320), 280] {
            let builder = try await renderStrip(preference: .builderDefault, width: width)
            XCTAssertGreaterThan(groundFraction(builder, stripRegion), 0.6,
                                 "the Course strip should draw on the Builder Default ground at \(Int(width))pt")
            if width == 320 {
                try save(builder, named: "course-strip-builder-default-320.png")
                let control = try await renderStrip(preference: .light, width: width)
                XCTAssertEqual(groundFraction(control, stripRegion), 0,
                               "control: a light strip must not draw on the Builder green")
            }
        }
    }

    /// The ribbon hosted under the same pin the shell applies, with three
    /// stops: one passed, one current, one ahead.
    private func renderStrip(preference: ThemeConfiguration.AppearancePreference,
                             width: CGFloat) async throws -> NSBitmapImageRep {
        var config = ThemeConfiguration.empty
        config.appearancePreference = preference
        let course = LibraryClient.Course(id: "course", product: "convivy-deck", title: "A course", entries: [
            LibraryClient.CourseEntry(id: "a", title: "Passed stop", type: "epic", state: "fixed",
                                      maturity: nil, resolution: "fixed"),
            LibraryClient.CourseEntry(id: "b", title: "Current stop", type: "epic", state: "claimed",
                                      maturity: nil, resolution: nil),
            LibraryClient.CourseEntry(id: "c", title: "Next stop", type: "epic", state: "open",
                                      maturity: nil, resolution: nil),
        ])
        let view = WaypointRibbon(course: course, workingOn: nil, appearance: .dark, accent: nil)
            .surfaceAppearance(config.pinnedSurface(for: .strip))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: WaypointRibbon.height)
        host.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        defer { tearDown(window) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}
