import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// The Builder Default frame as drawn, read from pixels of the whole window.
///
/// The window is hosted with its title bar, at 1440×880 of content, with no
/// session selected. The Course strip is seeded through `CockpitModel.seedCourse`,
/// because a Library read needs a target this test does not have. The Course
/// is the state an operator runs, so the frame is checked with it drawn. No host is named, for the reason `BuilderDefaultRenderTests`
/// gives.
///
/// The frame is the green ground drawn along the window's edges and at each
/// join between two frame elements: the title bar, the rail, the top bar, the
/// cockpit's right band and the Course strip. Every pixel of those strips must
/// be the ground, within `tolerance` in every sRGB channel. A divider, a
/// hairline or a window-background pixel fails. The one exception is text on
/// the title bar, which must lie on the line between the ground and
/// `StatusGround.primaryInk`. The traffic-light buttons are exempt.
///
/// The `dark` control is the same window under an explicit dark preference. Its
/// frame is the system's own, so the same strips must fail there.
///
/// Set `DECK_BUILDER_DEFAULT_RENDER_DIR` to keep the PNGs.
@MainActor
final class BuilderDefaultFrameRenderTests: XCTestCase {
    private let windowSize = NSSize(width: 1440, height: 880)
    private let tolerance = 0.02
    private let inkTolerance = 0.03

    /// `RailView` draws at 216pt when it is not collapsed.
    private let railWidth: CGFloat = 216
    private let bandWidth = ContentView.cockpitFrameBandWidth
    /// A point inside the session pane, past the rounded corner, where the pane's
    /// top edge is measured.
    private var paneX: CGFloat { railWidth + 40 }

    /// What one render produced: the window's pixels, top row first, in points
    /// with the title bar at the top. `frame` is the theme frame, which holds the
    /// title bar and the content, and it gives the window's geometry.
    private struct Capture {
        let rep: NSBitmapImageRep
        let frame: NSView
        let window: NSWindow
        /// The title bar's height in points, the strip above the content.
        var titleBarHeight: CGFloat { frame.bounds.height - window.contentLayoutRect.maxY }
        /// The window's bottom edge in points.
        var bottom: CGFloat { frame.bounds.height }
    }

    private func themeStore(json: String) throws -> ThemeStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-builder-default-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return ThemeStore(fileURL: file)
    }

    /// Names no host and no session, for the reason `BuilderDefaultRenderTests`
    /// gives: a rail poll over ssh starves the tests that follow.
    private func themeJSON(appearance: String?, columnWidth: Int) -> String {
        let appearanceLine = appearance.map { "\"appearance\": \"\($0)\"," } ?? ""
        return """
        {
          \(appearanceLine)
          "columnWidth": \(columnWidth)
        }
        """
    }

    private static let course = LibraryClient.Course(id: "course", product: "convivy-deck", title: "A course", entries: [
        LibraryClient.CourseEntry(id: "a", title: "Passed stop", type: "epic", state: "fixed",
                                  maturity: nil, resolution: "fixed"),
        LibraryClient.CourseEntry(id: "b", title: "Current stop", type: "epic", state: "claimed",
                                  maturity: nil, resolution: nil),
        LibraryClient.CourseEntry(id: "c", title: "Next stop", type: "epic", state: "open",
                                  maturity: nil, resolution: nil),
    ])

    private func capture(appearance: String?, columnWidth: Int = 320, course: Bool = true,
                         host name: NSAppearance.Name = .aqua, scale: Int = 1,
                         width: CGFloat = 1440, occupant: ColumnOccupant = .cockpit) async throws -> Capture {
        let hostAppearance = try XCTUnwrap(NSAppearance(named: name))
        let model = CockpitModel()
        let view = ContentView(cockpitModel: model, columnOccupant: occupant)
            .environmentObject(try themeStore(json: themeJSON(appearance: appearance,
                                                              columnWidth: columnWidth)))
            .environmentObject(WorkingCopyServer())
            .environmentObject(RailStateModel())
            .environmentObject(DesktopSessionAlertCenter())
            .environmentObject(SettingsNavigation())
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: windowSize.height))
        host.appearance = hostAppearance
        // No layer background on the host. A transparent title bar shows the
        // window's own background, and a painted host would cover it.
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        defer { tearDown(window) }
        // Suspended, not spun, so the rail's and cockpit's `.task`s can run. The
        // cockpit's refresh clears a course it has no target for, so the course
        // goes in after that refresh.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        if course { model.seedCourse(Self.course) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)

        let frame = try XCTUnwrap(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let rep: NSBitmapImageRep
        if scale == 1 {
            // The compositor's own picture of the window, title bar included.
            // `cacheDisplay` leaves a transparent title bar empty, because the window
            // server paints the window background under it, not the views.
            let image = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                              CGWindowID(window.windowNumber),
                                                              [.boundsIgnoreFraming, .bestResolution]),
                                      "the window server returned no image of the test window")
            // The capture is in the display's colour space, and the ground is sRGB.
            // A headless host tags it sRGB, so this is a no-op there; a Display P3
            // screen reads the ground's red 0.0196 high raw, against a 0.02 tolerance.
            rep = try XCTUnwrap(NSBitmapImageRep(cgImage: image).converting(to: .sRGB, renderingIntent: .default))
            // Points, not pixels, so a Retina host reads at its own scale.
            rep.size = frame.bounds.size
        } else {
            rep = try backingRep(of: frame, scale: scale)
        }
        return Capture(rep: rep, frame: frame, window: window)
    }

    /// The layer tree drawn into a bitmap `scale` times the points, as a Retina
    /// display would draw it. The window server's capture is at the test
    /// display's own scale, which is 1x on a headless host, so this is the only
    /// way the 2x edges are read there.
    private func backingRep(of frame: NSView, scale: Int) throws -> NSBitmapImageRep {
        let size = frame.bounds.size
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        // The layer tree, not `cacheDisplay`: a 2x `cacheDisplay` of the frame
        // left the rail's rows empty.
        frame.layer?.render(in: cg)
        NSGraphicsContext.restoreGraphicsState()
        rep.size = size
        return rep
    }

    /// Takes the window and the tree it hosts down. Hiding the window alone
    /// leaves the hosted tree and its rail poll alive into later tests.
    private func tearDown(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }

    // MARK: - Pixels

    private func isGround(_ color: NSColor) -> Bool {
        let ground = StatusGround.ground
        return abs(Double(color.redComponent) - ground.red) < tolerance
            && abs(Double(color.greenComponent) - ground.green) < tolerance
            && abs(Double(color.blueComponent) - ground.blue) < tolerance
    }

    /// Whether `color` lies on the line from the ground to the primary ink, which
    /// is what an anti-aliased edge of that ink on the ground draws.
    private func isSolvedInk(_ color: NSColor) -> Bool {
        let base = StatusGround.ground
        let ink = StatusGround.primaryInk
        let basis = [base.red, base.green, base.blue]
        let target = [ink.red, ink.green, ink.blue]
        let pixel = [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
        let channel = (0..<3).max { abs(target[$0] - basis[$0]) < abs(target[$1] - basis[$1]) } ?? 0
        let span = target[channel] - basis[channel]
        guard span != 0 else { return false }
        let t = (pixel[channel] - basis[channel]) / span
        guard (-inkTolerance...(1 + inkTolerance)).contains(t) else { return false }
        return (0..<3).allSatisfy { abs(basis[$0] + t * (target[$0] - basis[$0]) - pixel[$0]) < inkTolerance }
    }

    /// Whether row `y` is one of the rail's own section rules. A rule runs the
    /// rail's full width, so it crosses the rail's left edge too. The capture
    /// shows it as one colour across the rail's interior, which is not the
    /// ground. Rail text never has one colour across its row.
    private func isRailRule(_ c: Capture, y: CGFloat) -> Bool {
        let scale = CGFloat(c.rep.pixelsWide) / c.rep.size.width
        var reference: NSColor?
        for x in Int(8 * scale)..<Int((railWidth - 8) * scale) {
            guard let color = c.rep.colorAt(x: x, y: Int(y * scale)) else { return false }
            if isGround(color) { return false }
            guard let first = reference else {
                reference = color
                continue
            }
            let differs = abs(color.redComponent - first.redComponent) > 0.01
                || abs(color.greenComponent - first.greenComponent) > 0.01
                || abs(color.blueComponent - first.blueComponent) > 0.01
            if differs { return false }
        }
        return reference != nil
    }

    /// How many pixels in `rect` are not the ground: the title's ink.
    private func inkPixels(_ c: Capture, _ rect: NSRect) -> Int {
        let scale = CGFloat(c.rep.pixelsWide) / c.rep.size.width
        var count = 0
        for py in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for px in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                if let color = c.rep.colorAt(x: px, y: py), !isGround(color) { count += 1 }
            }
        }
        return count
    }

    /// The points in `rect` that are not the ground. `rect` is in points, top-left
    /// origin, in the theme frame's own coordinates. A point inside `exempt` is
    /// skipped, a point inside `inkRegion` may instead be solved ink, and a row
    /// `skipRow` accepts is skipped whole.
    private func offGround(_ c: Capture, _ rect: NSRect, exempt: [NSRect] = [],
                           inkRegion: NSRect? = nil,
                           skipRow: ((CGFloat) -> Bool)? = nil) -> [NSPoint] {
        let scale = CGFloat(c.rep.pixelsWide) / c.rep.size.width
        var offenders: [NSPoint] = []
        for py in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            if let skipRow, skipRow(CGFloat(py) / scale) { continue }
            for px in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                let point = NSPoint(x: CGFloat(px) / scale, y: CGFloat(py) / scale)
                if exempt.contains(where: { $0.contains(point) }) { continue }
                guard let color = c.rep.colorAt(x: px, y: py) else {
                    offenders.append(point)
                    continue
                }
                // The window's outline is anti-aliased where it is clipped, at its
                // rounded corners and along its bottom edge. A pixel that is not
                // opaque is that outline, not a frame element.
                if color.alphaComponent < 1 { continue }
                if isGround(color) { continue }
                if let inkRegion, inkRegion.contains(point), isSolvedInk(color) { continue }
                offenders.append(point)
            }
        }
        return offenders
    }

    /// The first row under the title bar where the column at `x` stops being the
    /// ground. That is the bottom edge of the top bar, which the seams are checked
    /// down to. Measured, because the top bar's height is a layout result.
    private func topBarBottom(_ c: Capture, x: CGFloat) -> CGFloat {
        let scale = CGFloat(c.rep.pixelsWide) / c.rep.size.width
        let top = c.titleBarHeight
        for py in Int((top + 1) * scale)..<Int(c.bottom * scale) {
            guard let color = c.rep.colorAt(x: Int(x * scale), y: py) else { return CGFloat(py) / scale }
            if !isGround(color) { return CGFloat(py) / scale }
        }
        return c.bottom
    }

    /// The traffic-light buttons, and the title accessory, in the capture's
    /// top-left coordinates. The buttons are the system's controls and are
    /// exempt. The accessory draws the title in ink and is held to the ink rule.
    private func titleBarInk(_ c: Capture) -> (exempt: [NSRect], ink: NSRect?) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let exempt = buttons.compactMap { type -> NSRect? in
            guard let button = c.window.standardWindowButton(type) else { return nil }
            return c.frame.convert(button.bounds, from: button).flipped(within: c.bottom)
        }
        let ink = c.window.titlebarAccessoryViewControllers.first.map { accessory in
            c.frame.convert(accessory.view.bounds, from: accessory.view).flipped(within: c.bottom)
        }
        return (exempt, ink)
    }

    // MARK: - Checks

    /// One strip of the frame, named so a failure says which join it is.
    private struct Strip {
        let name: String
        let rect: NSRect
        var exempt: [NSRect] = []
        var inkRegion: NSRect?
        var skipRow: ((CGFloat) -> Bool)?
    }

    /// Every strip the Builder Default frame must draw in the ground, measured
    /// from the render itself.
    private func frameStrips(_ c: Capture, course: Bool) -> [Strip] {
        let top = c.titleBarHeight
        let width = c.frame.bounds.width
        let bottom = c.bottom
        let (exempt, ink) = titleBarInk(c)
        var strips: [Strip] = [
            Strip(name: "title bar", rect: NSRect(x: 0, y: 0, width: width, height: top),
                  exempt: exempt, inkRegion: ink),
            Strip(name: "left edge of the rail", rect: NSRect(x: 0, y: top, width: 3, height: bottom - top),
                  skipRow: { self.isRailRule(c, y: $0) }),
            Strip(name: "cockpit's right band, from the title bar to the Course strip",
                  rect: NSRect(x: width - bandWidth, y: 0, width: bandWidth, height: bottom)),
            Strip(name: "seam between the rail and the top bar",
                  rect: NSRect(x: railWidth - 2, y: top, width: 4,
                               height: topBarBottom(c, x: paneX) - top)),
        ]
        // The bottom bar is there with or without a Course (observed 2026-10-06).
        let stripTop = bottom - WaypointRibbon.height
        strips.append(Strip(name: "top edge of the Course strip across the full width",
                            rect: NSRect(x: 0, y: stripTop, width: width, height: 2)))
        strips.append(Strip(name: "join between the rail and the Course strip",
                            rect: NSRect(x: 0, y: stripTop - 2, width: railWidth - 2, height: 2)))
        if !course {
            // With nothing to draw in it, the whole bar is the ground.
            strips.append(Strip(name: "the empty bottom bar with no Course, full width and height",
                                rect: NSRect(x: 0, y: stripTop, width: width, height: WaypointRibbon.height)))
        }
        return strips
    }

    private func assertFrameIsGround(_ c: Capture, course: Bool, file: StaticString = #filePath,
                                     line: UInt = #line) {
        for strip in frameStrips(c, course: course) {
            let offenders = offGround(c, strip.rect, exempt: strip.exempt, inkRegion: strip.inkRegion,
                                      skipRow: strip.skipRow)
            XCTAssertTrue(offenders.isEmpty,
                          "\(strip.name): \(offenders.count) pixels are not the ground; first at "
                              + "\(offenders.first.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "-")",
                          file: file, line: line)
        }
    }

    private func save(_ c: Capture, named name: String) throws {
        let png = try XCTUnwrap(c.rep.representation(using: .png, properties: [:]))
        let directory = ProcessInfo.processInfo.environment["DECK_BUILDER_DEFAULT_RENDER_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - Tests

    /// With no Course the bottom bar is still drawn, one strip tall and empty,
    /// so the frame keeps its foot. Before 2026-10-06 the bar disappeared and the
    /// panes ran to the window's edge.
    func testBuilderDefaultFrameKeepsItsBottomBarWithNoCourse() async throws {
        let builder = try await capture(appearance: nil, course: false)
        try save(builder, named: "frame-builder-default-320-no-course.png")
        assertFrameIsGround(builder, course: false)
    }

    /// The whole frame under Builder Default, at the default and the minimum
    /// cockpit width, with the Course strip drawn. The `dark` control must fail
    /// the same strips: the system's own frame is not the ground.
    func testBuilderDefaultFrameIsOneUnbrokenGround() async throws {
        for columnWidth in [320, 280] {
            let builder = try await capture(appearance: nil, columnWidth: columnWidth)
            try save(builder, named: "frame-builder-default-\(columnWidth).png")
            assertFrameIsGround(builder, course: true)
            // The strip is one strip tall: the light conversation draws directly
            // above its top edge, so a second strip stacked on the first fails here.
            let stripTop = builder.bottom - WaypointRibbon.height
            let scale = CGFloat(builder.rep.pixelsWide) / builder.rep.size.width
            let above = try XCTUnwrap(builder.rep.colorAt(x: Int(600 * scale), y: Int((stripTop - 2) * scale)))
            XCTAssertFalse(isGround(above),
                           "the Course strip should be one strip tall; the pane above it draws the ground")
            // The title is drawn in the title bar's accessory, in ink on the ground.
            let title = titleBarInk(builder)
            let inkRegion = try XCTUnwrap(title.ink, "the title bar should host the Deck title accessory")
            let drawn = inkPixels(builder, inkRegion)
            XCTAssertGreaterThan(drawn, 0, "the Deck title should draw ink in the title bar")
        }

        let control = try await capture(appearance: "dark", host: .darkAqua)
        try save(control, named: "frame-dark-control-320.png")
        let controlTitle = titleBarInk(control)
        XCTAssertFalse(offGround(control, NSRect(x: 0, y: 0, width: windowSize.width,
                                                 height: control.titleBarHeight),
                                 exempt: controlTitle.exempt, inkRegion: controlTitle.ink).isEmpty,
                       "control: an explicit dark title bar must not draw on the Builder green")
        XCTAssertFalse(offGround(control, NSRect(x: railWidth - 2, y: control.titleBarHeight, width: 4,
                                                 height: 40)).isEmpty,
                       "control: the dark seam must not draw on the Builder green")
    }

    /// The chrome restores the system's own title bar under every other
    /// preference, and applying Builder Default twice adds one accessory, not two.
    /// The frame at 2x, the scale of a Retina screen. The rail's far-left
    /// column is where a pale line showed up, so every strip below must be the ground
    /// at this scale too. The title bar is left to the 1x capture: its traffic-light
    /// exemptions were measured there, and this layer render does not match them.
    func testBuilderDefaultFrameAtTwoXIsOneUnbrokenGround() async throws {
        let retina = try await capture(appearance: nil, scale: 2)
        try save(retina, named: "frame-builder-default-320-2x.png")
        for strip in frameStrips(retina, course: true) where strip.name != "title bar" {
            let offenders = offGround(retina, strip.rect, exempt: strip.exempt, inkRegion: strip.inkRegion,
                                      skipRow: strip.skipRow)
            XCTAssertTrue(offenders.isEmpty,
                          "2x \(strip.name): \(offenders.count) pixels are not the ground; first at "
                              + "\(offenders.first.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "-")")
        }
    }

    /// The gap between the session pane and the column is the divider's strip. It
    /// stays the window's own colour, as it was before #331 gave the window the
    /// Builder green for its title bar. Samples sit either side of the hairline,
    /// which runs at the strip's centre, so the hairline itself is not read.
    func testGapBetweenPaneAndColumnStaysTheWindowColour() async throws {
        let columnWidth = 320
        let c = try await capture(appearance: nil, columnWidth: columnWidth)
        let columnLeft = Int(c.frame.bounds.width) - columnWidth
        let top = Int(topBarBottom(c, x: paneX))
        let stripTop = Int(c.bottom - WaypointRibbon.height)
        let row = (top + stripTop) / 2
        let scale = CGFloat(c.rep.pixelsWide) / c.rep.size.width
        var expected: NSColor?
        try XCTUnwrap(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
            expected = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
        }
        let window = try XCTUnwrap(expected)
        for offset in [12, 10, 4, 2] {
            let x = columnLeft - offset
            let color = try XCTUnwrap(c.rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(row) * scale)))
            XCTAssertFalse(isGround(color),
                           "the gap \(offset)pt left of the column is the Builder green; it should be the window colour")
            XCTAssertEqual(Double(color.redComponent), Double(window.redComponent), accuracy: 0.03)
            XCTAssertEqual(Double(color.greenComponent), Double(window.greenComponent), accuracy: 0.03)
            XCTAssertEqual(Double(color.blueComponent), Double(window.blueComponent), accuracy: 0.03)
        }
    }

    /// The interior corners of the frame. Each pane corner that meets the green
    /// is rounded: a pixel one point in from the corner is the ground, and a pixel
    /// three points in, inside the arc, is the pane. The rail and top bar meet the
    /// session pane; the band and top bar meet the column.
    func testInteriorCornersOfTheFrameAreRounded() async throws {
        let c = try await capture(appearance: nil, columnWidth: 320)
        let top = Int(topBarBottom(c, x: paneX))
        let stripTop = Int(c.bottom - WaypointRibbon.height)
        let paneLeft = Int(railWidth)
        let columnRight = Int(c.frame.bounds.width - bandWidth)
        let scale = CGFloat(c.rep.pixelsWide) / c.rep.size.width
        func color(_ x: Int, _ y: Int) throws -> NSColor {
            try XCTUnwrap(c.rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale)))
        }
        let corners: [(name: String, x: Int, y: Int, inward: Int, down: Int)] = [
            ("session pane, top-left", paneLeft, top, 1, 1),
            ("session pane, bottom-left", paneLeft, stripTop, 1, -1),
            ("column, top-right", columnRight, top, -1, 1),
            ("column, bottom-right", columnRight, stripTop, -1, -1),
        ]
        for corner in corners {
            let outside = try color(corner.x + corner.inward * 1, corner.y + corner.down * 1)
            XCTAssertTrue(isGround(outside), "\(corner.name): the corner's outside pixel should be the Builder green")
            let inside = try color(corner.x + corner.inward * 3, corner.y + corner.down * 3)
            XCTAssertFalse(isGround(inside), "\(corner.name): three points in is inside the arc, so it should be the pane")
            let edge = try color(corner.x + corner.inward * 20, corner.y + corner.down * 1)
            XCTAssertFalse(isGround(edge), "\(corner.name): past the radius the pane's own edge should draw")
        }
    }

    /// The docked column closes the frame on the right under Builder Default for
    /// every occupant the segmented control can show, not only the cockpit. The
    /// band is the ground; the column's body must stop short of it, so a column
    /// that runs to the window's edge reads as an open frame.
    func testFrameBandClosesTheDockedColumnForEveryOccupant() async throws {
        let slate = ColumnOccupant.slate(session: "deck",
                                         target: SSHTarget(user: TestHost.user, host: "band-check.invalid"),
                                         crew: SessionRef(host: nil, name: "deck"))
        for (index, occupant) in [ColumnOccupant.run(runId: "run-band-check"), slate].enumerated() {
            let c = try await capture(appearance: nil, occupant: occupant)
            try save(c, named: "frame-band-occupant-\(index)-320.png")
            let width = Int(c.frame.bounds.width)
            let top = Int(topBarBottom(c, x: paneX))
            let stripTop = Int(c.bottom - WaypointRibbon.height)
            let row = (top + stripTop) / 2
            let scale = CGFloat(c.rep.pixelsWide) / c.rep.size.width
            func color(_ x: Int) throws -> NSColor {
                try XCTUnwrap(c.rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(row) * scale)))
            }
            let band = try color(width - 6)
            XCTAssertTrue(isGround(band), "\(occupant): the band's right half should be the Builder green")
            let body = try color(width - Int(bandWidth) - 4)
            XCTAssertFalse(isGround(body), "\(occupant): the column's body should stop short of the band")
        }
    }

    func testBuilderDefaultChromeRestoresTheSystemTitleBarWhenItIsLeft() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let system = window.backgroundColor
        let systemMask = window.styleMask
        let systemContent = window.contentLayoutRect.size

        DeckWindowChrome.apply(to: window, builderDefault: true)
        DeckWindowChrome.apply(to: window, builderDefault: true)
        XCTAssertEqual(window.contentLayoutRect.size, systemContent,
                       "the title bar's transparency must not shrink the content")
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1,
                       "applying Builder Default twice must not add a second title accessory")
        let ground = window.backgroundColor?.usingColorSpace(.sRGB)
        XCTAssertEqual(Double(ground?.redComponent ?? -1), StatusGround.ground.red, accuracy: 0.002)
        XCTAssertEqual(Double(ground?.greenComponent ?? -1), StatusGround.ground.green, accuracy: 0.002)

        DeckWindowChrome.apply(to: window, builderDefault: false)
        XCTAssertEqual(window.contentLayoutRect.size, systemContent)
        XCTAssertEqual(window.styleMask, systemMask)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 0)
        XCTAssertEqual(window.backgroundColor, system)
    }
}

private extension NSRect {
    /// This rect, given in a bottom-left frame `height` points tall, as the
    /// top-left rect the capture uses.
    func flipped(within height: CGFloat) -> NSRect {
        NSRect(x: minX, y: height - maxY, width: width, height: self.height)
    }
}
