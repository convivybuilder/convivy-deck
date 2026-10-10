import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// The whole window in each appearance, read as pixels.
///
/// The window is hosted at the design's 1440×880 with nothing selected, which
/// is the launch state. The rail, the empty conversation pane and the cockpit
/// are the three regions that exist without a live session, so the split is
/// read from those. The `light` and `dark` renders are the controls: a region
/// that reads dark under `split` must read light under `light` and dark under
/// `dark`, or the sampling itself is what is wrong.
///
/// Every render sets the host's `NSAppearance` explicitly, so the result never
/// depends on the appearance of the machine running the suite.
///
/// Set `DECK_SPLIT_RENDER_DIR` to keep the PNGs. Without it they go to a
/// temporary directory and are not kept.
@MainActor
final class SplitAppearanceRenderTests: XCTestCase {
    private let windowSize = NSSize(width: 1440, height: 880)

    /// Points, top-left origin. Each rectangle sits clear of text and of the
    /// divider, so its mean reads the surface and not a label on it.
    private let railRegion = NSRect(x: 8, y: 400, width: 52, height: 120)
    private let conversationRegion = NSRect(x: 300, y: 300, width: 200, height: 100)
    private let cockpitRegion = NSRect(x: 1122, y: 300, width: 12, height: 120)

    private func themeStore(preference: String) throws -> ThemeStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-split-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("theme.json")
        try """
        {
          "appearance": "\(preference)",
          "defaultHost": "macstudio",
          "hosts": [{ "name": "macstudio", "user": "operator", "address": "192.0.2.1" }],
          "rail": [
            { "session": "vivy", "name": "Vivy" },
            { "session": "deck", "name": "Deck" },
            { "session": "steward", "name": "Steward" }
          ]
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        return ThemeStore(fileURL: file)
    }

    private func render(preference: String, host name: NSAppearance.Name) async throws -> NSBitmapImageRep {
        let hostAppearance = try XCTUnwrap(NSAppearance(named: name))
        let view = ContentView()
            .environmentObject(try themeStore(preference: preference))
            .environmentObject(WorkingCopyServer())
            .environmentObject(RailStateModel())
            .environmentObject(DesktopSessionAlertCenter())
            .environmentObject(SettingsNavigation())
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: windowSize)
        // The system scheme the shell reads comes from this host, so it is set
        // before anything lays out. Left unset, the render follows the machine.
        host.appearance = hostAppearance
        // A real window paints its own background behind the content, and
        // `cacheDisplay` does not. Without this, every area no view paints
        // comes out transparent, which reads as black. The colour is resolved
        // under the host's appearance, since a dynamic colour's `cgColor` is
        // fixed at the moment it is made.
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
        // A second pass, for the same reason `HoistedRowWidthDeliveryTests` takes
        // one: the column's width arrives through an `.onAppear`-set `@State`.
        host.layoutSubtreeIfNeeded()
        // Suspended, not spun: the rail's and cockpit's own `.task`s must run
        // before the frame is read, and a nested run loop never lets them.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        defer { window.orderOut(nil) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Mean relative luminance (0 black, 1 white) over `region`, in window
    /// points. Pixel rows are read top-down, matching the hosted view.
    private func meanLuminance(_ rep: NSBitmapImageRep, _ region: NSRect) -> Double {
        let scale = CGFloat(rep.pixelsWide) / windowSize.width
        var total = 0.0
        var count = 0.0
        for y in Int(region.minY * scale)..<Int(region.maxY * scale) {
            for x in Int(region.minX * scale)..<Int(region.maxX * scale) {
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
        let directory = ProcessInfo.processInfo.environment["DECK_SPLIT_RENDER_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name))
    }

    /// The split window draws the rail dark, and the conversation pane and the
    /// cockpit light. The cockpit draws on its session's frame tint, a light
    /// surface. The `light` render is the control: every region must
    /// read light there, so a dark reading under `split` cannot be a sampling
    /// artefact.
    ///
    /// There is no dark control. A pinned `dark` leaves the rail and cockpit on
    /// the system scheme, and the host is light here, so at launch nothing in
    /// that window is dark to sample. The `dark` render is written for review
    /// all the same.
    func testSplitWindowDrawsStatusDarkAndConversationLight() async throws {
        let light = try await render(preference: "light", host: .aqua)
        let split = try await render(preference: "split", host: .aqua)
        try save(light, named: "window-light.png")
        try save(split, named: "window-split.png")
        try save(try await render(preference: "dark", host: .aqua), named: "window-dark-pinned.png")

        XCTAssertGreaterThan(meanLuminance(light, railRegion), 0.7, "control: light rail")
        XCTAssertGreaterThan(meanLuminance(light, conversationRegion), 0.7, "control: light conversation")
        XCTAssertGreaterThan(meanLuminance(light, cockpitRegion), 0.7, "control: light cockpit")

        XCTAssertLessThan(meanLuminance(split, railRegion), 0.35,
                          "the rail should draw dark under split")
        XCTAssertGreaterThan(meanLuminance(split, conversationRegion), 0.7,
                             "the conversation pane should draw light under split")
        XCTAssertGreaterThan(meanLuminance(split, cockpitRegion), 0.7,
                             "the cockpit should draw light under split")
    }

    /// The same window with the host on dark. The system scheme is now dark, so
    /// any region that is not pinned reads dark. That makes the conversation
    /// assertion a check on the pinning itself: a light reading there can only
    /// come from the `light` pin the work pane sets. The `dark` render is the
    /// control, where every region must read dark.
    func testSplitUnderDarkSystemKeepsWorkPanesLightAndStatusPanesDark() async throws {
        let dark = try await render(preference: "dark", host: .darkAqua)
        let split = try await render(preference: "split", host: .darkAqua)
        try save(dark, named: "window-dark-system-dark-pinned.png")
        try save(split, named: "window-split-dark-system.png")

        XCTAssertLessThan(meanLuminance(dark, railRegion), 0.35, "control: dark rail")
        XCTAssertLessThan(meanLuminance(dark, conversationRegion), 0.35, "control: dark conversation")
        XCTAssertLessThan(meanLuminance(dark, cockpitRegion), 0.35, "control: dark cockpit")

        XCTAssertLessThan(meanLuminance(split, railRegion), 0.35,
                          "the rail should draw dark under split with a dark system")
        XCTAssertGreaterThan(meanLuminance(split, conversationRegion), 0.7,
                             "the conversation pane should draw light under split with a dark system")
        XCTAssertGreaterThan(meanLuminance(split, cockpitRegion), 0.7,
                             "the cockpit should draw light under split with a dark system")
    }

    /// `system` is left as it was. With the host on light, `system` and
    /// `light` must read the same at every region, so the new case cannot have
    /// changed the window the other presets draw.
    func testSystemDrawsTheSameAsLightWhileTheSystemIsLight() async throws {
        let system = try await render(preference: "system", host: .aqua)
        let light = try await render(preference: "light", host: .aqua)
        for region in [railRegion, conversationRegion, cockpitRegion] {
            XCTAssertEqual(meanLuminance(system, region), meanLuminance(light, region), accuracy: 0.01,
                           "system and light should draw region \(region) the same")
        }
    }
}
