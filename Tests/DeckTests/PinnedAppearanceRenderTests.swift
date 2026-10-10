import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// A pinned Light or Dark preference draws the rail and the right column's cockpit in
/// the pinned appearance, whatever the system scheme is, read from pixels.
///
/// Each render hosts the whole window at 1440×880 with no session selected and no
/// configured host, the same posture as `BuilderDefaultRenderTests`. The system scheme
/// comes from the host's `appearance`, set before layout, so a render never depends on
/// the machine running the suite. A region's mean luminance decides its scheme: dark
/// regions sit near 0, light regions near 1.
///
/// Set `DECK_PINNED_APPEARANCE_RENDER_DIR` to keep the full-window PNGs. Without it they
/// go to a temporary directory and are not kept.
@MainActor
final class PinnedAppearanceRenderTests: XCTestCase {
    private let windowSize = NSSize(width: 1440, height: 880)

    /// Large enough for the General tab's form at its floor, in the Settings scene's own
    /// minimum width.
    private let settingsSize = NSSize(width: 520, height: 480)

    /// Points, top-left origin, clear of text: the rail's leading strip.
    private let railRegion = NSRect(x: 8, y: 400, width: 52, height: 120)

    /// The cockpit's leading strip for a 320pt right column, inside the column and
    /// clear of its header text.
    private var cockpitRegion: NSRect {
        NSRect(x: windowSize.width - 320 + 4, y: 300, width: 12, height: 120)
    }

    /// The divider's hit strip between the main pane and the 320pt right column. The
    /// hairline sits inside it, and the rest of it is the strip's own ground, which is
    /// what a pinned scheme must reach. A region mean covers both.
    private var dividerRegion: NSRect {
        NSRect(x: windowSize.width - 320 - ResizableDivider.hitWidth, y: 300,
               width: ResizableDivider.hitWidth, height: 120)
    }

    /// The one-point hairline between the rail and the main pane, at the rail's 216pt
    /// expanded width. A region one point wide covers only the line's own pixels.
    private var railDividerLine: NSRect {
        NSRect(x: 216, y: 300, width: 1, height: 120)
    }

    /// The main pane's stretch of the header underline, across which the row is sampled.
    private let headerUnderlineX: ClosedRange<CGFloat> = 300...420

    /// The top of the window down to which the header underline is searched for. The
    /// header's height is content-sized, so the underline is found in the pixels rather
    /// than at a fixed row.
    private let headerBandHeight = 60

    /// The one-point hairline under the header, found in `rep`. A row is the underline
    /// when it departs from the row above and returns to that row's luminance on the
    /// row below, which is what a one-point line over a uniform fill looks like. Nil
    /// when no such row sits in the header band.
    private func headerUnderline(in rep: NSBitmapImageRep) -> NSRect? {
        func row(_ y: Int) -> Double {
            meanLuminance(rep, NSRect(x: headerUnderlineX.lowerBound, y: CGFloat(y),
                                      width: headerUnderlineX.upperBound - headerUnderlineX.lowerBound,
                                      height: 1))
        }
        for y in 1..<headerBandHeight {
            let above = row(y - 1)
            if abs(row(y) - above) > 0.02, abs(row(y + 1) - above) < 0.01 {
                return NSRect(x: headerUnderlineX.lowerBound, y: CGFloat(y),
                              width: headerUnderlineX.upperBound - headerUnderlineX.lowerBound,
                              height: 1)
            }
        }
        return nil
    }

    private func themeStore(json: String) throws -> ThemeStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-pinned-appearance-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return ThemeStore(fileURL: file)
    }

    /// Names no host and no session, so the rail's refresh returns before it starts any
    /// ssh work. See `BuilderDefaultRenderTests.themeJSON` for why a named host starves
    /// the suite.
    private func themeJSON(appearance: String) -> String {
        """
        {
          "appearance": "\(appearance)",
          "columnWidth": 320
        }
        """
    }

    private func render(appearance: String, systemIsDark: Bool) async throws -> NSBitmapImageRep {
        let hostAppearance = try XCTUnwrap(NSAppearance(named: systemIsDark ? .darkAqua : .aqua))
        let view = ContentView()
            .environmentObject(try themeStore(json: themeJSON(appearance: appearance)))
            .environmentObject(WorkingCopyServer())
            .environmentObject(RailStateModel())
            .environmentObject(DesktopSessionAlertCenter())
            .environmentObject(SettingsNavigation())
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: windowSize)
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
        // A second pass: the column's width arrives through an `.onAppear`-set `@State`.
        host.layoutSubtreeIfNeeded()
        // Suspended, not spun, so the rail's and cockpit's `.task`s can run.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        defer { tearDown(window) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Takes the window and the tree it hosts down. Hiding the window alone leaves the
    /// hosted tree and its rail poll alive into later tests.
    private func tearDown(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }

    /// The mean sRGB luminance of `region`, with points scaled to the bitmap's pixels.
    private func meanLuminance(_ rep: NSBitmapImageRep, _ region: NSRect, step: Int = 1) -> Double {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var total = 0.0
        var count = 0.0
        for y in stride(from: Int(region.minY * scale), to: Int(region.maxY * scale), by: step) {
            for x in stride(from: Int(region.minX * scale), to: Int(region.maxX * scale), by: step) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 0.2126 * color.redComponent + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                count += 1
            }
        }
        return total / count
    }

    private func save(_ rep: NSBitmapImageRep, named name: String) throws {
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let directory = ProcessInfo.processInfo.environment["DECK_PINNED_APPEARANCE_RENDER_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name))
    }

    /// Pinned Dark on a light system draws the rail and the cockpit dark. The
    /// `system` control on the same light host draws both light, so the dark result
    /// comes from the pin and not from the host.
    func testPinnedDarkOnLightSystemDrawsRailAndCockpitDark() async throws {
        let pinned = try await render(appearance: "dark", systemIsDark: false)
        let control = try await render(appearance: "system", systemIsDark: false)
        try save(pinned, named: "window-pinned-dark-on-light-system.png")
        try save(control, named: "window-system-on-light-system.png")
        let underline = try XCTUnwrap(headerUnderline(in: pinned), "no header underline in the header band")
        XCTAssertEqual(headerUnderline(in: control), underline,
                       "the control's header underline is the same row as the pinned one")

        XCTAssertLessThan(meanLuminance(pinned, railRegion), 0.3,
                          "pinned Dark must draw the rail dark on a light system")
        XCTAssertLessThan(meanLuminance(pinned, cockpitRegion), 0.3,
                          "pinned Dark must draw the cockpit dark on a light system")
        XCTAssertLessThan(meanLuminance(pinned, dividerRegion), 0.3,
                          "pinned Dark must draw the divider dark on a light system")
        XCTAssertGreaterThan(meanLuminance(control, railRegion), 0.7,
                             "control: system on a light host draws the rail light")
        XCTAssertGreaterThan(meanLuminance(control, cockpitRegion), 0.7,
                             "control: system on a light host draws the cockpit light")
        XCTAssertGreaterThan(meanLuminance(control, dividerRegion), 0.7,
                             "control: system on a light host draws the divider's strip light")
        XCTAssertLessThan(meanLuminance(pinned, railDividerLine), 0.5,
                          "pinned Dark must draw the rail's hairline dark on a light system")
        XCTAssertLessThan(meanLuminance(pinned, underline), 0.5,
                          "pinned Dark must draw the header's underline dark on a light system")
        XCTAssertGreaterThan(meanLuminance(control, railDividerLine), 0.7,
                             "control: system on a light host draws the rail's hairline light")
        XCTAssertGreaterThan(meanLuminance(control, underline), 0.7,
                             "control: system on a light host draws the header's underline light")
    }

    /// Pinned Light on a dark system draws the rail and the cockpit light. The `system`
    /// control on the same dark host draws both dark.
    func testPinnedLightOnDarkSystemDrawsRailAndCockpitLight() async throws {
        let pinned = try await render(appearance: "light", systemIsDark: true)
        let control = try await render(appearance: "system", systemIsDark: true)
        try save(pinned, named: "window-pinned-light-on-dark-system.png")
        try save(control, named: "window-system-on-dark-system.png")
        let underline = try XCTUnwrap(headerUnderline(in: pinned), "no header underline in the header band")
        XCTAssertEqual(headerUnderline(in: control), underline,
                       "the control's header underline is the same row as the pinned one")

        XCTAssertGreaterThan(meanLuminance(pinned, railRegion), 0.7,
                             "pinned Light must draw the rail light on a dark system")
        XCTAssertGreaterThan(meanLuminance(pinned, cockpitRegion), 0.7,
                             "pinned Light must draw the cockpit light on a dark system")
        XCTAssertGreaterThan(meanLuminance(pinned, dividerRegion), 0.7,
                             "pinned Light must draw the divider light on a dark system")
        XCTAssertLessThan(meanLuminance(control, railRegion), 0.3,
                          "control: system on a dark host draws the rail dark")
        XCTAssertLessThan(meanLuminance(control, cockpitRegion), 0.3,
                          "control: system on a dark host draws the cockpit dark")
        XCTAssertLessThan(meanLuminance(control, dividerRegion), 0.3,
                          "control: system on a dark host draws the divider's strip dark")
        XCTAssertGreaterThan(meanLuminance(pinned, railDividerLine), 0.5,
                             "pinned Light must draw the rail's hairline light on a dark system")
        XCTAssertGreaterThan(meanLuminance(pinned, underline), 0.5,
                             "pinned Light must draw the header's underline light on a dark system")
        XCTAssertLessThan(meanLuminance(control, railDividerLine), 0.5,
                          "control: system on a dark host draws the rail's hairline dark")
        XCTAssertLessThan(meanLuminance(control, underline), 0.5,
                          "control: system on a dark host draws the header's underline dark")
    }

    // MARK: - Settings window

    /// The Settings window's root, hosted in an `NSWindow` as the Settings scene hosts
    /// it. Names no host and no session, so the Hosts and Sessions tabs have nothing to
    /// probe. Returns the pixels and the window's own appearance name, which is `nil`
    /// when the window follows the system.
    private func renderSettings(appearance: String,
                                systemIsDark: Bool) async throws -> (NSBitmapImageRep, NSAppearance.Name?) {
        let hostAppearance = try XCTUnwrap(NSAppearance(named: systemIsDark ? .darkAqua : .aqua))
        let view = SettingsView(licence: LicenceNotice(notice: nil, license: nil))
            .environmentObject(try themeStore(json: themeJSON(appearance: appearance)))
            .environmentObject(SettingsNavigation())
            .environmentObject(RailStateModel())
            .environmentObject(DesktopSessionAlertCenter())
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: settingsSize)
        host.appearance = hostAppearance
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        defer { tearDown(window) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, window.appearance?.name)
    }

    /// The whole Settings window: the General tab's background and form, which is a
    /// majority of its pixels. The text and controls take a minority, so the mean sits
    /// near 0.2 on a dark window and near 0.9 on a light one.
    private var settingsRegion: NSRect { NSRect(origin: .zero, size: settingsSize) }

    /// Pinned Dark on a light system draws the Settings window dark, with its own
    /// appearance set to dark. The `system` control draws it light with no window
    /// appearance of its own.
    func testPinnedDarkOnLightSystemDrawsSettingsDark() async throws {
        let (pinned, pinnedName) = try await renderSettings(appearance: "dark", systemIsDark: false)
        let (control, controlName) = try await renderSettings(appearance: "system", systemIsDark: false)
        try save(pinned, named: "settings-pinned-dark-on-light-system.png")
        try save(control, named: "settings-system-on-light-system.png")

        XCTAssertLessThan(meanLuminance(pinned, settingsRegion, step: 4), 0.5,
                          "pinned Dark must draw the Settings window dark on a light system")
        XCTAssertEqual(pinnedName, .darkAqua, "pinned Dark must set the Settings window's appearance")
        XCTAssertGreaterThan(meanLuminance(control, settingsRegion, step: 4), 0.5,
                             "control: system on a light host draws Settings light")
        XCTAssertNil(controlName, "control: system leaves the Settings window's appearance to the system")
    }

    /// Pinned Light on a dark system draws the Settings window light, with its own
    /// appearance set to aqua. The `system` control draws it dark.
    func testPinnedLightOnDarkSystemDrawsSettingsLight() async throws {
        let (pinned, pinnedName) = try await renderSettings(appearance: "light", systemIsDark: true)
        let (control, controlName) = try await renderSettings(appearance: "system", systemIsDark: true)
        try save(pinned, named: "settings-pinned-light-on-dark-system.png")
        try save(control, named: "settings-system-on-dark-system.png")

        XCTAssertGreaterThan(meanLuminance(pinned, settingsRegion, step: 4), 0.5,
                             "pinned Light must draw the Settings window light on a dark system")
        XCTAssertEqual(pinnedName, .aqua, "pinned Light must set the Settings window's appearance")
        XCTAssertLessThan(meanLuminance(control, settingsRegion, step: 4), 0.5,
                          "control: system on a dark host draws Settings dark")
        XCTAssertNil(controlName, "control: system leaves the Settings window's appearance to the system")
    }
}
