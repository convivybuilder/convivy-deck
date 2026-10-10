import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// The right column's detail panes under Builder Default, read from pixels.
///
/// The cockpit draws light on its selected session's frame tint, and a detail
/// pane the cockpit opens draws on that same ground. The run pane is the one
/// native detail pane the cockpit opens, and it drew on the status green before
/// this change. The web panes (the item, review records, viewer and editor)
/// draw their page on the page's own background, which the renderer generates,
/// so their pin is pinned by a separate test below rather than changed here.
///
/// Each render hosts the pane under the pin `ContentView.columnPin` returns, the
/// same pin the column applies, so a change to the pin moves these checks. No
/// host is named, and the pane is taken down after each render.
@MainActor
final class BuilderDefaultDetailPaneRenderTests: XCTestCase {
    private let tolerance = 0.02
    private let size = NSSize(width: 320, height: 400)

    /// The cockpit's ground: the selected session's composer tint, drawn light
    /// under Builder Default. The same derivation `CockpitFrameTintInkTests` uses.
    private func cockpitGround(theme: TerminalTheme) -> RGB {
        let canvas = ContentView.paneCanvas(for: theme.palette(for: .light), appearance: .light)
        return SessionPaneView.frameTintRGB(canvas: canvas.hexString, appearance: .light)!
    }

    private func runDetail() -> RunDetail {
        RunDetail(runId: "run-1", agent: "deck-coder", modelLine: "sonnet",
                  instruction: .text("Build the frame."), hasEnded: true, startedAt: nil)
    }

    /// Renders the run pane under `pin`, saves the PNG when
    /// `DECK_BUILDER_DEFAULT_RENDER_DIR` is set, and returns the bitmap, after
    /// taking the hosted tree down.
    private func render(pin: PinnedSurface?, named name: String) throws -> NSBitmapImageRep {
        let pane = RunDetailPane(detail: runDetail(), given: .idle, fetched: .idle,
                                 onOpenDocument: { _ in }, onClose: {})
            .frame(width: size.width, height: size.height)
            .surfaceAppearance(pin)
        let host = NSHostingView(rootView: pane)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["DECK_BUILDER_DEFAULT_RENDER_DIR"] {
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
        return rep
    }

    private func matches(_ color: NSColor?, _ ground: RGB) -> Bool {
        guard let c = color else { return false }
        return abs(Double(c.redComponent) - ground.red) < tolerance
            && abs(Double(c.greenComponent) - ground.green) < tolerance
            && abs(Double(c.blueComponent) - ground.blue) < tolerance
    }

    /// The pane's empty lower corners, which carry no text and show the ground.
    private func corners(_ rep: NSBitmapImageRep) -> [NSColor?] {
        let right = rep.pixelsWide - 6
        let bottom = rep.pixelsHigh - 6
        return [rep.colorAt(x: 6, y: bottom), rep.colorAt(x: right, y: bottom)]
    }

    /// Under Builder Default the run pane draws on the cockpit's ground, and not
    /// on the status green it drew before. With the old pin this fails: the
    /// corners read `StatusGround.ground`.
    func testRunPaneDrawsOnTheCockpitGroundNotTheStatusGreen() throws {
        for theme in ThemeCatalog.all {
            let ground = cockpitGround(theme: theme)
            let pin = ContentView.columnPin(for: .run(runId: "run-1"), configuration: .empty,
                                            cockpitGround: ground)
            let rep = try render(pin: pin, named: "run-pane-\(theme.name).png")
            for color in corners(rep) {
                XCTAssertTrue(matches(color, ground), "\(theme.name): the run pane's ground should be the cockpit's")
                XCTAssertFalse(matches(color, StatusGround.ground), "\(theme.name): the run pane still draws the status green")
            }
        }
    }

    /// The secondary ink the run pane draws is solved against the cockpit's
    /// ground, so it clears 4.5:1 there. The pane takes it from the same
    /// `CockpitView.secondaryInkStyle` the cockpit's own rows take.
    func testRunPaneSecondaryInkClearsTheTextFloorOnTheCockpitGround() {
        for theme in ThemeCatalog.all {
            let ground = cockpitGround(theme: theme)
            let ink = ThemeRecipe.secondaryTextInk(on: ground)
            XCTAssertGreaterThanOrEqual(ink.contrastRatio(against: ground), 4.5, theme.name)
        }
    }

    /// Under System, Light and Dark the run pane keeps `pinnedSurface(for: .run)`.
    /// Pinned Light and Dark also pin the cockpit (#330), so the run pane must
    /// not take the cockpit ground there: that ground is the Builder Default
    /// frame tint, and the `builderDefault` guard in `columnPin` keeps it out.
    func testRunPanePinIsUnchangedUnderTheOtherPreferences() {
        let ground = cockpitGround(theme: ThemeCatalog.all[0])
        for preference in [ThemeConfiguration.AppearancePreference.system, .light, .dark] {
            var configuration = ThemeConfiguration.empty
            configuration.appearancePreference = preference
            let pin = ContentView.columnPin(for: .run(runId: "run-1"), configuration: configuration,
                                            cockpitGround: ground)
            XCTAssertEqual(pin, configuration.pinnedSurface(for: .run),
                           "\(preference): the run pane's pin must not change")
            XCTAssertNotEqual(pin?.ground, ground,
                              "\(preference): the run pane must not draw on the cockpit ground")
        }
    }

    /// The cockpit pin is the cockpit ground, as before.
    func testCockpitPinIsTheCockpitGroundUnderBuilderDefault() {
        let ground = cockpitGround(theme: ThemeCatalog.all[0])
        XCTAssertEqual(ContentView.columnPin(for: .cockpit, configuration: .empty, cockpitGround: ground),
                       PinnedSurface(appearance: .light, ground: ground))
    }

    /// The web detail panes keep their pin. Their page draws its own background,
    /// so changing the native pin would paint a native header over a light page.
    func testWebDetailPanesKeepTheirPinUnderBuilderDefault() {
        let ground = cockpitGround(theme: ThemeCatalog.all[0])
        let web: [ColumnOccupant] = [
            .item(id: "i", target: SSHTarget(user: "u", host: "h")),
            .reviewRecords(repo: "o/r", pr: 1, headSha: nil, target: SSHTarget(user: "u", host: "h")),
        ]
        for occupant in web {
            XCTAssertEqual(ContentView.columnPin(for: occupant, configuration: .empty, cockpitGround: ground),
                           ThemeConfiguration.empty.pinnedSurface(for: occupant.appearanceSurface))
        }
    }
}
