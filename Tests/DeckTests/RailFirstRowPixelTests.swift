import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// The rail's top edge under Builder Default, read from pixels of the real
/// window. At rest the first crew's row starts on the session pane's top line,
/// beside the pane's top edge (CQ·153); scrolled, no row draws above that line,
/// so nothing reaches the title bar (CQ·147).
///
/// The real `ContentView` is hosted the way `WindowGroup` hosts it, as an
/// `NSHostingController` that is the window's content view controller, with
/// SwiftUI's toolbar modifiers bridged into the window. `WindowChromeSetter`
/// applies Builder Default's full-size, transparent title bar and the title
/// accessory exactly as it does in the app. The SwiftUI tree therefore sees
/// the same 32pt top safe area the app's window gives it.
///
/// Two earlier fixes passed tests that read layout frames: row 0 rested at
/// the title bar's bottom edge, and a band painted over it hid it. Only
/// pixels show what the window draws.
///
/// Set `DECK_BUILDER_DEFAULT_RENDER_DIR` to keep the PNGs.
@MainActor
final class RailFirstRowPixelTests: XCTestCase {
    private let windowSize = NSSize(width: 1440, height: 880)
    private let railWidth: CGFloat = 216
    private let crewNames = ["Steward", "Library", "Bosun", "Orient"]
    private let tolerance = 0.02

    private func themeStore(crews: [String], appearance: String? = nil) throws -> ThemeStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-rail-first-row-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("theme.json")
        let rail = crews
            .map { "{ \"session\": \"\($0.lowercased().replacingOccurrences(of: " ", with: "-"))\", \"name\": \"\($0)\" }" }
            .joined(separator: ", ")
        let appearanceKey = appearance.map { "\"appearance\": \"\($0)\", " } ?? ""
        try "{ \(appearanceKey)\"rail\": [ \(rail) ] }".write(to: file, atomically: true, encoding: .utf8)
        return ThemeStore(fileURL: file)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }

    private func findView(named className: String, in view: NSView) -> NSView? {
        if String(describing: Swift.type(of: view)) == className { return view }
        for subview in view.subviews {
            if let found = findView(named: className, in: subview) { return found }
        }
        return nil
    }

    private struct Capture {
        /// The compositor's picture of the window, title bar included. A
        /// `cacheDisplay` of the hosting view cannot stand in for it: on
        /// macOS 26 it leaves the rail's `List` out entirely.
        let window: NSBitmapImageRep
        /// The height of AppKit's own title bar container, in points.
        let titleBarHeight: CGFloat
        /// Row 0's top as laid out, in points from the window's top edge.
        let row0Top: CGFloat?
        let log: String
    }

    /// `scrolledToEnd` also clears the title bar of the traffic lights and
    /// the title accessory, so that anything drawn in the rail's part of it
    /// can only be a row.
    private func capture(crews: [String], scrolledToEnd: Bool, name: String,
                         width: CGFloat? = nil, appearance: String? = nil) async throws -> Capture {
        let windowSize = NSSize(width: width ?? self.windowSize.width, height: self.windowSize.height)
        let view = ContentView(cockpitModel: CockpitModel())
            .environmentObject(try themeStore(crews: crews, appearance: appearance))
            .environmentObject(WorkingCopyServer())
            .environmentObject(RailStateModel())
            .environmentObject(DesktopSessionAlertCenter())
            .environmentObject(SettingsNavigation())
        let controller = NSHostingController(rootView: view)
        if #available(macOS 14, *) { controller.sceneBridgingOptions = .all }
        // The window takes the test's size; the content only sets its minimum.
        controller.sizingOptions = .minSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: windowSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        // Set before and after the window is on screen: the hosting
        // controller resizes the window to its minimum when it is installed,
        // and the second call is the one that holds.
        window.setContentSize(windowSize)
        window.orderFront(nil)
        window.setContentSize(windowSize)
        let host = controller.view
        host.layoutSubtreeIfNeeded()
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        // Suspended, not spun, so the rail's `.task`s settle, the same wait
        // `BuilderDefaultFrameRenderTests` uses.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        host.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(find(NSScrollView.self, in: host), "the rail's List should host an NSScrollView")
        if scrolledToEnd {
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX,
                                    y: documentHeight - clip.bounds.height + scrollView.contentInsets.bottom))
            scrollView.reflectScrolledClipView(clip)
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            while let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 is DeckTitleAccessory }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        let frame = try XCTUnwrap(host.superview, "the window should have a theme frame")
        let titlebar = try XCTUnwrap(findView(named: "NSTitlebarContainerView", in: frame),
                                     "the window should have an AppKit title bar to measure")

        var log = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        log += "window.frame=\(window.frame) contentLayoutRect=\(window.contentLayoutRect)\n"
        log += "frame minus contentLayoutRect=\(window.frame.height - window.contentLayoutRect.maxY) "
        log += "real title bar=\(titlebar.frame)\n"
        log += "host.safeAreaInsets=\(host.safeAreaInsets)\n"
        log += "rail scrollView frame in window=\(scrollView.convert(scrollView.bounds, to: nil)) "
        log += "contentInsets=\(scrollView.contentInsets) clipView bounds=\(scrollView.contentView.bounds)\n"
        var row0Top: CGFloat?
        if let table = find(NSTableView.self, in: host), table.numberOfRows > 0 {
            let row0 = table.convert(table.rect(ofRow: 0), to: nil)
            row0Top = frame.bounds.height - row0.maxY
            log += "row0 in window=\(row0)\n"
        }

        let image = try XCTUnwrap(CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                          CGWindowID(window.windowNumber),
                                                          [.boundsIgnoreFraming, .bestResolution]),
                                  "the window server returned no image of the test window")
        let windowRep = NSBitmapImageRep(cgImage: image)
        // Points, so a Retina display reads at its own scale.
        windowRep.size = frame.bounds.size
        if let dir = ProcessInfo.processInfo.environment["DECK_BUILDER_DEFAULT_RENDER_DIR"] {
            let url = URL(fileURLWithPath: dir)
            try? windowRep.representation(using: .png, properties: [:])?
                .write(to: url.appendingPathComponent("\(name)-window.png"))
        }
        return Capture(window: windowRep, titleBarHeight: titlebar.frame.height,
                       row0Top: row0Top, log: log)
    }

    private func matches(_ color: NSColor, _ reference: NSColor) -> Bool {
        abs(color.redComponent - reference.redComponent) < tolerance
            && abs(color.greenComponent - reference.greenComponent) < tolerance
            && abs(color.blueComponent - reference.blueComponent) < tolerance
    }

    /// The rail's own ground, read from its left margin halfway down, where
    /// no row draws, so a comparison holds in whatever colour space the
    /// capture comes back in.
    private func railGround(in rep: NSBitmapImageRep) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        return try XCTUnwrap(rep.colorAt(x: Int(4 * scale), y: rep.pixelsHigh / 2))
    }

    /// The session pane's top edge in points from the window's top: the first
    /// pixel below the title bar, 40pt into the pane past its rounded corner,
    /// that is not the ground. The toolbar row above the pane draws nothing
    /// there with no host configured.
    private func paneTop(in c: Capture) throws -> Int {
        let rep = c.window
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let ground = try railGround(in: rep)
        let px = Int((railWidth + 40) * scale)
        for py in Int(c.titleBarHeight * scale)..<rep.pixelsHigh {
            guard let color = rep.colorAt(x: px, y: py) else { continue }
            if !matches(color, ground) { return Int((CGFloat(py) / scale).rounded()) }
        }
        XCTFail("found no session pane below the title bar")
        return 0
    }

    /// The rows of the rail's label column, in points from the window's top,
    /// where a crew name's ink is drawn, merged into one band per name. Ink is
    /// a pixel far brighter than the ground; the names draw near
    /// `StatusGround.primaryInk`.
    private func labelBands(in rep: NSBitmapImageRep) -> [ClosedRange<Int>] {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let ground = StatusGround.ground
        let groundLuma = (ground.red + ground.green + ground.blue) / 3
        // Past the row's leading mark, short of the rail's trailing edge.
        let columns = Int(36 * scale)..<Int(180 * scale)
        var inkRows: [Int] = []
        for py in 0..<rep.pixelsHigh {
            let hasInk = columns.contains { px in
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return false }
                let luma = (Double(c.redComponent) + Double(c.greenComponent) + Double(c.blueComponent)) / 3
                return luma - groundLuma > 0.35
            }
            if hasInk { inkRows.append(Int(CGFloat(py) / scale)) }
        }
        var bands: [ClosedRange<Int>] = []
        for y in inkRows {
            if let last = bands.last, y <= last.upperBound + 2 {
                bands[bands.count - 1] = last.lowerBound...y
            } else {
                bands.append(y...y)
            }
        }
        // A name is several points tall; a shorter run is a stray pixel.
        return bands.filter { $0.count >= 4 }
    }

    /// CQ·153: the first crew's row starts on the session pane's top line.
    /// Fails while a band covers the first crew (only three names draw), and
    /// fails when the first crew draws above that line, beside the toolbar
    /// row, where a fix that only cleared the title bar put it.
    func testFirstCrewRowStartsOnTheSessionPaneTopLine() async throws {
        let c = try await capture(crews: crewNames, scrolledToEnd: false, name: "rail-rest")
        let bands = labelBands(in: c.window)
        let top = try paneTop(in: c)
        print("CQ153-DIAG rest\n\(c.log)session pane top=\(top)pt label bands (pt from top)=\(bands)")
        // The title accessory's own text sits inside the title bar, so it
        // never counts as a crew.
        let crewBands = bands.filter { $0.lowerBound >= Int(c.titleBarHeight) }
        XCTAssertEqual(crewBands.count, crewNames.count,
                       "expected all \(crewNames.count) crew names drawn; found \(crewBands)\n\(c.log)")
        guard crewBands.count >= 2 else { return }
        // A name sits the same distance into every row, so the first name
        // lies in the first row slot below the line only if it is closer to
        // the line than one row pitch, and below it.
        let pitch = crewBands[1].lowerBound - crewBands[0].lowerBound
        let offset = crewBands[0].lowerBound - top
        XCTAssertTrue(offset > 0 && offset < pitch,
                      "the first crew's name starts \(offset)pt below the session pane's top line at \(top)pt; "
                          + "it should lie within the first row slot, 0..<\(pitch)pt\n\(c.log)")
        let row0Top = try XCTUnwrap(c.row0Top)
        XCTAssertEqual(row0Top, CGFloat(top), accuracy: 1,
                       "row 0 is laid out at \(row0Top)pt; the session pane's top is at \(top)pt")
    }

    /// CQ·147: with the rail scrolled to its end, nothing of a row draws above
    /// the session pane's top line, so nothing reaches the title bar.
    func testScrolledRowsNeverDrawAboveTheSessionPaneTopLine() async throws {
        let crews = (0..<60).map { "Crew \($0)" }
        let c = try await capture(crews: crews, scrolledToEnd: true, name: "rail-scrolled")
        let rep = c.window
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let ground = try railGround(in: rep)
        let top = try paneTop(in: c)
        var offenders = 0
        var first: (Int, Int)?
        // From 1pt down: on macOS 26 the window server draws the frame's own
        // top edge as a lighter 1pt line across the whole width.
        // The ship mark is the one thing the band draws on purpose; its own
        // test pins where. Its 22x14pt box, plus 1pt of antialiasing.
        let bandMid = (c.titleBarHeight + CGFloat(top)) / 2
        let boatX = Int(10 * scale)..<Int(34 * scale)
        let boatY = Int((bandMid - 8) * scale)..<Int((bandMid + 8) * scale)
        for py in Int(scale)..<Int(CGFloat(top) * scale) {
            for px in 0..<Int(railWidth * scale) {
                if boatX.contains(px) && boatY.contains(py) { continue }
                // The window's rounded corner leaves its outside transparent.
                guard let color = rep.colorAt(x: px, y: py), color.alphaComponent > 0.99 else { continue }
                if !matches(color, ground) {
                    offenders += 1
                    if first == nil { first = (px, py) }
                }
            }
        }
        // Where the rail's ground ends: the first point, down the label
        // column, where a scrolled row draws anything.
        let labelX = Int(60 * scale)
        let groundBottom = (Int(scale)..<rep.pixelsHigh).first { py in
            rep.colorAt(x: labelX, y: py).map { !matches($0, ground) } ?? false
        }.map { CGFloat($0) / scale }
        // The rail must have scrolled for this to test anything.
        let bands = labelBands(in: c.window).filter { $0.lowerBound >= top }
        print("CQ153-DIAG scrolled\n\(c.log)session pane top=\(top)pt first row ink at x=60pt: "
              + "\(groundBottom.map { "\($0)pt" } ?? "-") crews drawn=\(bands.count) offenders=\(offenders)")
        XCTAssertGreaterThan(bands.count, 0, "the scrolled rail should still draw crews\n\(c.log)")
        XCTAssertEqual(offenders, 0,
                       "the rail above the session pane's top line (\(top)pt) should be the ground; \(offenders) "
                           + "pixels are not, first at \(first.map { "(\($0.0), \($0.1))" } ?? "-")\n\(c.log)")
    }

    // MARK: - The ship mark in the band

    /// Hull ink is far brighter than the ground, the same rule as
    /// `labelBands`; runner ink is the avatar's gold, `#c9892a`.
    private func boatInk(in rep: NSBitmapImageRep, xRange: ClosedRange<CGFloat>, yRange: ClosedRange<CGFloat>,
                         runnerTolerance: Double = 0.08) -> (hull: CGFloat, runner: CGFloat, box: CGRect?) {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let ground = StatusGround.ground
        let groundLuma = (ground.red + ground.green + ground.blue) / 3
        var hull = 0, runner = 0
        var box: CGRect?
        for py in Int(yRange.lowerBound * scale)..<Int(yRange.upperBound * scale) {
            for px in Int(xRange.lowerBound * scale)..<Int(xRange.upperBound * scale) {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB), c.alphaComponent > 0.99 else { continue }
                let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
                let isHull = (r + g + b) / 3 - groundLuma > 0.35
                let isRunner = abs(r - 0xc9 / 255.0) < runnerTolerance && abs(g - 0x89 / 255.0) < runnerTolerance
                    && abs(b - 0x2a / 255.0) < runnerTolerance
                guard isHull || isRunner else { continue }
                if isHull { hull += 1 } else { runner += 1 }
                let point = CGRect(x: CGFloat(px) / scale, y: CGFloat(py) / scale, width: 1 / scale, height: 1 / scale)
                box = box.map { $0.union(point) } ?? point
            }
        }
        let perPoint = scale * scale
        return (CGFloat(hull) / perPoint, CGFloat(runner) / perPoint, box)
    }

    /// The centre x, in points, of the first crew's dot: the saturated pixels
    /// across the rail's leading 60pt on row 0's middle line. Crew names and
    /// the ground are unsaturated, so only the dot counts.
    private func firstDotCenterX(in c: Capture) throws -> CGFloat {
        let rep = c.window
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let row0Top = try XCTUnwrap(c.row0Top, "the rail should lay out a first row\n\(c.log)")
        let py = Int((row0Top + RailRow.rowHeight / 2) * scale)
        let xs = (0..<Int(60 * scale)).filter { px in
            guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return false }
            let channels = [c.redComponent, c.greenComponent, c.blueComponent]
            return channels.max()! - channels.min()! > 0.35
        }
        let first = try XCTUnwrap(xs.first, "no dot found on row 0\n\(c.log)")
        return CGFloat(first + xs.last! + 1) / 2 / scale
    }

    /// The operator, 2026-10-09: the dots hold still when the rail expands or
    /// collapses. Fails if the expanded row's leading padding drifts from the
    /// collapsed row's centring.
    func testDotColumnHoldsStillBetweenExpandedAndCollapsed() async throws {
        let expanded = try await capture(crews: crewNames, scrolledToEnd: false, name: "rail-dots-expanded")
        let collapsed = try await capture(crews: crewNames, scrolledToEnd: false, name: "rail-dots-collapsed",
                                          width: CGFloat(LayoutBreakpoints.railCollapse) - 80)
        let e = try firstDotCenterX(in: expanded), k = try firstDotCenterX(in: collapsed)
        XCTAssertEqual(e, k, accuracy: 1, "the first dot centres at \(e)pt expanded but \(k)pt collapsed")
        XCTAssertEqual(e, RailRow.dotColumnCenterX, accuracy: 1, "the dot column should centre at x 22")
    }

    /// The boat draws in the band above the first crew, centred on the dot
    /// column and on the toolbar row. Fails when the boat is missing (no ink),
    /// moved off the dots, resized, or aligned to the band's top or bottom.
    func testBoatSitsInTheRailBandOnTheToolbarRowCentre() async throws {
        let c = try await capture(crews: crewNames, scrolledToEnd: false, name: "rail-boat")
        let top = CGFloat(try paneTop(in: c))
        let ink = boatInk(in: c.window, xRange: 0...railWidth, yRange: c.titleBarHeight...top)
        XCTAssertGreaterThanOrEqual(ink.hull, 40, "the boat's hull should draw in the band\n\(c.log)")
        let box = try XCTUnwrap(ink.box, "nothing of the boat drew in the band\n\(c.log)")
        let dot = try firstDotCenterX(in: c)
        XCTAssertEqual(box.midX, dot, accuracy: 1, "the boat should centre on the dot column at \(dot)pt; box \(box)")
        XCTAssertEqual(box.width, BuilderBoatMark.size.width, accuracy: 2, "the boat should draw 22pt wide; box \(box)")
        XCTAssertEqual(box.midY, (c.titleBarHeight + top) / 2, accuracy: 1,
                       "the boat should centre on the toolbar row; box \(box), band \(c.titleBarHeight)-\(top)")
    }

    /// Below `LayoutBreakpoints.railCollapse` the rail keeps its marks, and the
    /// boat still centres on the dots.
    func testCollapsedRailCentresTheBoatOnTheDotColumn() async throws {
        let width = CGFloat(LayoutBreakpoints.railCollapse) - 80
        let c = try await capture(crews: crewNames, scrolledToEnd: false, name: "rail-boat-collapsed", width: width)
        let top = CGFloat(try paneTop(in: c))
        let ink = boatInk(in: c.window, xRange: 0...60, yRange: c.titleBarHeight...top)
        XCTAssertGreaterThanOrEqual(ink.hull, 40, "the collapsed rail should still draw the boat\n\(c.log)")
        let box = try XCTUnwrap(ink.box, "nothing of the boat drew in the collapsed band\n\(c.log)")
        let dot = try firstDotCenterX(in: c)
        XCTAssertEqual(box.midX, dot, accuracy: 1, "the boat should centre on the collapsed dots at \(dot)pt; box \(box)")
    }

    /// Outside Builder Default the band is 0pt and the boat draws nowhere. An
    /// ungated overlay on that 0pt band centres on row 0's top edge, so it
    /// would draw from 7pt above it to 7pt below, in the mark column. The first
    /// crew's own dot starts 8pt below that edge, so the region stops short of
    /// it; the runner's gold is read loosely, since at 1x it is mostly
    /// antialiased.
    func testNoBoatOutsideBuilderDefault() async throws {
        let c = try await capture(crews: crewNames, scrolledToEnd: false, name: "rail-boat-dark", appearance: "dark")
        let row0Top = try XCTUnwrap(c.row0Top, "the rail should lay out a first row\n\(c.log)")
        let ink = boatInk(in: c.window, xRange: 11...35, yRange: (row0Top - 7)...(row0Top + 6), runnerTolerance: 0.15)
        XCTAssertEqual(ink.runner, 0, "no boat runner should draw outside Builder Default\n\(c.log)")
    }
}
