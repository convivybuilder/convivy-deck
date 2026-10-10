import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// The unstarted session pane, read from pixels: a stopped session draws on the
/// session pane's canvas, the same colour the live pane's conversation draws on,
/// and not on the system's text background, which is black under Builder Default.
///
/// Each render hosts one pane in an `NSHostingView` inside a window, the way
/// `PinnedAppearanceRenderTests` does, and reads it with `cacheDisplay`.
/// `ImageRenderer` blanks a `ScrollView`, and these panes carry none, but the
/// hosted path is the one the app draws through, so it is the one measured.
///
/// The canvas comes from `ContentView.paneCanvas(for:appearance:)`, the same token
/// the live pane reads. The control test draws the old fill over the same pin and
/// asserts it fails the canvas check, so a pass here means the check can see black.
@MainActor
final class UnstartedSessionPaneRenderTests: XCTestCase {
    private let paneSize = NSSize(width: 480, height: 320)
    /// Per sRGB channel, the same tolerance `BuilderDefaultFrameRenderTests` uses.
    private let tolerance = 0.02
    /// Points, top-left origin, clear of the pane's text and buttons.
    private let fillRegion = NSRect(x: 4, y: 4, width: 8, height: 8)

    /// The canvas for `appearance`, from the token the live pane reads.
    private func canvas(_ appearance: Appearance) -> RGB {
        let theme = ThemeRecipe.theme(named: "Test", hue: 150)
        return ContentView.paneCanvas(for: theme.palette(for: appearance), appearance: appearance)
    }

    private func configuration(_ preference: ThemeConfiguration.AppearancePreference) -> ThemeConfiguration {
        var config = ThemeConfiguration.empty
        config.appearancePreference = preference
        return config
    }

    /// Hosts `view` at the pane's size, with the system scheme set before layout,
    /// and returns the pixels. The window is torn down before the return.
    private func render<V: View>(_ view: V, systemIsDark: Bool = false) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: paneSize)
        host.appearance = try XCTUnwrap(NSAppearance(named: systemIsDark ? .darkAqua : .aqua))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The mean colour of `region`, with points scaled to the bitmap's pixels.
    ///
    /// Read in the bitmap's own space, not converted to sRGB. `cacheDisplay` writes
    /// Generic RGB, whose components match the 8-bit values the canvas rounds to.
    /// Converting to sRGB shifts them by up to 0.04, which reads as a failure here
    /// that is only the conversion.
    private func meanColor(_ rep: NSBitmapImageRep, _ region: NSRect) -> (r: Double, g: Double, b: Double) {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        for y in stride(from: Int(region.minY * scale), to: Int(region.maxY * scale), by: 1) {
            for x in stride(from: Int(region.minX * scale), to: Int(region.maxX * scale), by: 1) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                r += color.redComponent
                g += color.greenComponent
                b += color.blueComponent
                count += 1
            }
        }
        return (r / count, g / count, b / count)
    }

    private func assertDraws(_ canvas: RGB, _ rep: NSBitmapImageRep, file: StaticString = #filePath,
                             line: UInt = #line) {
        let mean = meanColor(rep, fillRegion)
        XCTAssertEqual(mean.r, canvas.red, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(mean.g, canvas.green, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(mean.b, canvas.blue, accuracy: tolerance, file: file, line: line)
    }

    private func stopped(_ configuration: ThemeConfiguration, canvas: RGB) -> some View {
        StartSessionView(name: "Vivy", canvas: canvas, onStart: {}, onTerminal: {})
            .surfaceAppearance(configuration.pinnedSurface(for: .conversation))
    }

    // MARK: - Builder Default

    /// Under Builder Default the stopped pane draws the session canvas. Fails if
    /// the pane draws black, which is what it drew when it filled with the text
    /// background under the dark status pin.
    func testUnstartedPaneDrawsTheSessionCanvasUnderBuilderDefault() throws {
        let config = configuration(.builderDefault)
        let expected = canvas(config.appearance(for: .conversation, systemIsDark: false))
        assertDraws(expected, try render(stopped(config, canvas: expected)))
    }

    /// The control: the old fill, the system's text background, under the same
    /// dark pin the stopped pane used to take. It must fail the canvas check, or
    /// the check above cannot see black.
    func testControlOldBlackFillFailsTheCanvasCheckUnderBuilderDefault() throws {
        let config = configuration(.builderDefault)
        let expected = canvas(config.appearance(for: .conversation, systemIsDark: false))
        let oldFill = Color(nsColor: .textBackgroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .surfaceAppearance(config.pinnedSurface(for: .start))
        let mean = meanColor(try render(oldFill), fillRegion)
        let channels = [(mean.r, expected.red), (mean.g, expected.green), (mean.b, expected.blue)]
        XCTAssertTrue(channels.contains { abs($0.0 - $0.1) > tolerance },
                      "the old fill matched the canvas; the check cannot tell black apart")
    }

    /// The inks the stopped pane draws its text in clear the text floor against
    /// the canvas it draws on, under the scheme the canvas was resolved for. This
    /// is the solve `StartSessionView.textInk` reads, so a canvas that moved
    /// without its inks re-solving fails here.
    func testUnstartedPaneInksClearTheTextFloorOnTheCanvasUnderBuilderDefault() {
        let config = configuration(.builderDefault)
        let expected = canvas(config.appearance(for: .conversation, systemIsDark: false))
        XCTAssertGreaterThanOrEqual(ThemeRecipe.secondaryTextInk(on: expected)
                                        .contrastRatio(against: expected),
                                    ThemeRecipe.minimumTextContrast)
        XCTAssertGreaterThanOrEqual(ThemeRecipe.neutralMarkInk(on: expected)
                                        .contrastRatio(against: expected),
                                    ThemeRecipe.markContrast)
    }

    // MARK: - Other presets keep the same ground

    /// `light`, `dark` and `system` take the same token path. Under each, the
    /// stopped pane draws the canvas the live pane would, not the text background.
    func testUnstartedPaneDrawsTheSessionCanvasUnderEveryPreference() throws {
        for (preference, systemIsDark) in [
            (ThemeConfiguration.AppearancePreference.light, false),
            (.dark, true),
            (.system, false),
            (.system, true),
        ] {
            let config = configuration(preference)
            let appearance = config.appearance(for: .conversation, systemIsDark: systemIsDark)
            let expected = canvas(appearance)
            let rep = try render(stopped(config, canvas: expected), systemIsDark: systemIsDark)
            assertDraws(expected, rep)
        }
    }

    // MARK: - Loading

    /// The "Loading…" cover is drawn from the Start press until the live session
    /// renders, so it must draw the stopped pane's ground. It was pinned to the
    /// start surface, dark under Builder Default, and filled with the system text
    /// background, which is black there: the black frame between Start and the
    /// live pane.
    func testLoadingPaneDrawsTheSessionCanvasUnderBuilderDefault() throws {
        let config = configuration(.builderDefault)
        let expected = canvas(config.appearance(for: .conversation, systemIsDark: false))
        let view = LaunchPlaceholderView(canvas: expected)
            .surfaceAppearance(config.pinnedSurface(for: .conversation))
        assertDraws(expected, try render(view))
    }

    /// The same cover under every preset, on the pin the live call site uses.
    func testLoadingPaneDrawsTheSessionCanvasUnderEveryPreference() throws {
        for (preference, systemIsDark) in [
            (ThemeConfiguration.AppearancePreference.light, false),
            (.dark, true),
            (.system, false),
            (.system, true),
        ] {
            let config = configuration(preference)
            let expected = canvas(config.appearance(for: .conversation, systemIsDark: systemIsDark))
            let view = LaunchPlaceholderView(canvas: expected)
                .surfaceAppearance(config.pinnedSurface(for: .conversation))
            assertDraws(expected, try render(view, systemIsDark: systemIsDark))
        }
    }

    // MARK: - Missing directory

    /// The stopped-without-a-directory pane is the same unstarted state, so it
    /// draws the same canvas under Builder Default.
    func testMissingDirectoryPaneDrawsTheSessionCanvasUnderBuilderDefault() throws {
        let config = configuration(.builderDefault)
        let expected = canvas(config.appearance(for: .conversation, systemIsDark: false))
        let view = MissingDirectoryView(name: "Vivy", folder: nil, canvas: expected, onTerminal: {})
            .environmentObject(SettingsNavigation())
            .surfaceAppearance(config.pinnedSurface(for: .conversation))
        assertDraws(expected, try render(view))
    }
}
