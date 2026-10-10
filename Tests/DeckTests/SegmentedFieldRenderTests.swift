import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// The field under the top bar's segmented pickers, read from pixels.
///
/// The Cockpit/Shell/Local picker is hosted on the Builder Default chrome pin at
/// 2x, in an sRGB bitmap so the components read back as drawn. A row above the
/// labels crosses the ground, the field and the selected pill. The field is the
/// commonest colour on that row other than the ground, and the pill is the next.
/// The label ink is the brightest pixel across the labels.
///
/// There are two bounds:
/// - The field must separate from the ground at least as far as
///   `StatusGround.divider` does, the hairline the bar already relies on to be
///   seen (1.50:1). The native track alone measured 1.26:1.
/// - The label on the selected pill must clear `ThemeRecipe.minimumTextContrast`.
///   The pill is a wash over the field, so a field drawn too light pulls the
///   pill up under the system's white label.
@MainActor
final class SegmentedFieldRenderTests: XCTestCase {
    private let size = NSSize(width: 300, height: 44)
    private let scale = 2
    /// Points from the top: inside the track, above the labels.
    private let fieldRow = 11
    private let labelBand = 16..<28

    private var separationFloor: Double {
        StatusGround.divider.contrastRatio(against: StatusGround.ground)
    }

    private func pin(_ preference: ThemeConfiguration.AppearancePreference) -> PinnedSurface? {
        var config = ThemeConfiguration.empty
        config.appearancePreference = preference
        return config.pinnedSurface(for: .chrome)
    }

    private func plainPicker() -> some View {
        Picker("Right column", selection: .constant(ColumnOccupant.cockpit)) {
            columnSegment("Cockpit", "square.grid.2x2.fill", iconOnly: false, tag: .cockpit)
            columnSegment("Shell", "terminal.fill", iconOnly: false, tag: .remoteShell)
            columnSegment("Local", "laptopcomputer", iconOnly: false, tag: .localTerminal)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.large)
        .fixedSize()
    }

    /// The shipped picker, which carries `segmentedField()` itself.
    private func shippedPicker() -> some View {
        RightColumnPicker(selection: .constant(ColumnOccupant.cockpit), fittingWidth: size.width) { iconOnly in
            columnSegment("Cockpit", "square.grid.2x2.fill", iconOnly: iconOnly, tag: .cockpit)
            columnSegment("Shell", "terminal.fill", iconOnly: iconOnly, tag: .remoteShell)
            columnSegment("Local", "laptopcomputer", iconOnly: iconOnly, tag: .localTerminal)
        }
    }

    private struct Reading {
        let field: RGB
        let pill: RGB
        let ink: RGB
    }

    private func read<V: View>(_ picker: V, pinned: PinnedSurface?) async throws -> Reading {
        let view = picker
            .frame(width: size.width, height: size.height)
            .surfaceAppearance(pinned)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        // Tagged sRGB: the default calibrated space reads every colour back
        // shifted, which put the ground at #1a2b21 instead of #22382c.
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["DECK_BUILDER_DEFAULT_RENDER_DIR"] {
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("segmented-field-\(UUID().uuidString.prefix(8)).png"))
        }
        return try reading(rep)
    }

    private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> RGB {
        let c = rep.colorAt(x: x, y: y)!
        return RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }

    private func reading(_ rep: NSBitmapImageRep) throws -> Reading {
        let ground = StatusGround.ground.hexString
        var counts: [String: Int] = [:]
        for x in 0..<rep.pixelsWide {
            counts[pixel(rep, x, fieldRow * scale).hexString, default: 0] += 1
        }
        let ranked = counts.sorted { $0.value > $1.value }.map(\.key)
        // The ground is excluded only when it is present, so a pin drawing on
        // the system's own ground keeps its commonest colour as the backdrop.
        let backdrop = counts[ground] != nil ? ground : ranked[0]
        let rest = ranked.filter { $0 != backdrop }
        XCTAssertGreaterThanOrEqual(rest.count, 2, "the row should cross a field and a pill")
        let field = try XCTUnwrap(parseHexColor(String(rest[0].dropFirst())))
        let pill = try XCTUnwrap(parseHexColor(String(rest[1].dropFirst())))
        var ink = RGB(red: 0, green: 0, blue: 0)
        for y in (labelBand.lowerBound * scale)..<(labelBand.upperBound * scale) {
            for x in 0..<rep.pixelsWide {
                let c = pixel(rep, x, y)
                if c.relativeLuminance > ink.relativeLuminance { ink = c }
            }
        }
        return Reading(field: field, pill: pill, ink: ink)
    }

    /// The shipped field separates from the ground past the divider's ratio,
    /// and the selected label stays at text contrast on the pill.
    func testTheShippedFieldReadsAsAShapeAndKeepsThePillLabelLegible() async throws {
        let r = try await read(shippedPicker(), pinned: pin(.builderDefault))
        let separation = r.field.contrastRatio(against: StatusGround.ground)
        XCTAssertGreaterThanOrEqual(separation, separationFloor,
                                    "field \(r.field.hexString) should separate from the ground by at least \(separationFloor):1, measured \(separation):1")
        XCTAssertGreaterThan(r.pill.contrastRatio(against: r.field), 1.3,
                             "the selected pill \(r.pill.hexString) should stay distinct from the field \(r.field.hexString)")
        XCTAssertGreaterThanOrEqual(r.ink.contrastRatio(against: r.pill), ThemeRecipe.minimumTextContrast,
                                    "the selected label \(r.ink.hexString) should clear 4.5:1 on the pill \(r.pill.hexString)")
        XCTAssertGreaterThanOrEqual(r.ink.contrastRatio(against: r.field), ThemeRecipe.minimumTextContrast)
    }

    /// The native track with nothing under it, which is what shipped before:
    /// it falls under the separation floor.
    func testTheNativeTrackAloneFallsUnderTheSeparationFloor() async throws {
        let r = try await read(plainPicker(), pinned: pin(.builderDefault))
        XCTAssertLessThan(r.field.contrastRatio(against: StatusGround.ground), separationFloor,
                          "the unfilled track \(r.field.hexString) should measure under the floor")
    }

    /// A field lifted 0.12 instead of 0.06 separates further, but drags the
    /// selected pill up until its label falls under 4.5:1.
    func testAFieldTooLightFailsThePillLabel() async throws {
        var lifted = StatusGround.ground.toOKLCH()
        lifted.l += 0.12
        let r = try await read(plainPicker().modifier(SegmentedFieldModifier(field: lifted.toRGB())),
                               pinned: pin(.builderDefault))
        XCTAssertLessThan(r.ink.contrastRatio(against: r.pill), ThemeRecipe.minimumTextContrast,
                          "a 0.12 lift should put the selected label \(r.ink.hexString) under 4.5:1 on \(r.pill.hexString)")
    }

    /// Light and Dark pins carry no status ground, so the shipped picker draws
    /// the same field as the system picker there.
    func testLightAndDarkDrawTheSystemField() async throws {
        for preference in [ThemeConfiguration.AppearancePreference.light, .dark] {
            let shipped = try await read(shippedPicker(), pinned: pin(preference))
            let system = try await read(plainPicker(), pinned: pin(preference))
            XCTAssertEqual(shipped.field.hexString, system.field.hexString,
                           "\(preference) should draw the system's own field")
        }
    }
}
