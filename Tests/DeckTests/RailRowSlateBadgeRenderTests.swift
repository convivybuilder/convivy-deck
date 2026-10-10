import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What `RailRow` DRAWS for its Slate badge (issue_01M3WPYSH0S1FZVZ6P3YMNJGXW),
/// at the row's real width, in both appearances, at the two widths the item
/// names — the same `NSHostingView` + `cacheDisplay` harness
/// `SlatePaneRenderTests` uses, never `ImageRenderer`
/// (`CockpitRevealRenderTests`'s own finding: it draws `ScrollView` contents
/// blank — not exercised here, but the row sits inside the rail's `List`).
@MainActor
final class RailRowSlateBadgeRenderTests: XCTestCase {
    private func row(asksOpen: SessionState.AsksOpen?, appearance: Appearance) -> some View {
        RailRow(crew: Crew(id: "deck-coder", displayName: "deck-coder"),
               isSelected: false,
               accent: RGB(red: 0.4, green: 0.5, blue: 0.8),
               appearance: appearance,
               mark: .unpolled,
               isStopped: false,
               themeMenu: { AnyView(EmptyView()) },
               asksOpen: asksOpen,
               onOpenSlate: {})
    }

    /// Renders one row alone, given time for layout to settle —
    /// `SlatePaneRenderTests.render`'s own harness, at the rail's real width
    /// (`design/redesign/03-rail.html`'s 216pt) rather than an arbitrary one.
    private func render(
        asksOpen: SessionState.AsksOpen?, width: CGFloat, appearance: Appearance
    ) async throws -> NSBitmapImageRep {
        let view = row(asksOpen: asksOpen, appearance: appearance)
            .background(appearance == .dark ? Color(white: 0.145) : Color(white: 0.98))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: RailRow.rowHeight))
        host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        defer { window.orderOut(nil) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Ink in the trailing 24 points — where the badge draws, between the
    /// context meter glyph and the (absent, in this fixture) disclosure
    /// chevron. Points, scaled to the bitmap's pixels: at 2x the badge's ink
    /// starts 25 pixels in, so a 24-pixel strip misses it.
    private func trailingInkedPixelCount(_ rep: NSBitmapImageRep) -> Int {
        guard let backdrop = rep.colorAt(x: 0, y: 0) else { return 0 }
        var count = 0
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let x0 = max(0, rep.pixelsWide - Int(24 * scale))
        for y in 0..<rep.pixelsHigh {
            for x in x0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(c.redComponent - backdrop.redComponent)
                    + abs(c.greenComponent - backdrop.greenComponent)
                    + abs(c.blueComponent - backdrop.blueComponent)
                if delta > 0.05 { count += 1 }
            }
        }
        return count
    }

    private func writeSnapshot(_ rep: NSBitmapImageRep, name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["DECK_SNAPSHOT_DIR"] else { return }
        if let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// A positive count draws something in the trailing strip, at both
    /// widths the item names and in both appearances.
    func testPositiveCountDrawsInTheTrailingStrip() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let rendered = try await render(asksOpen: .count(2), width: width, appearance: appearance)
                try writeSnapshot(rendered, name: "rail-row-asks-\(Int(width))-\(appearance)")
                XCTAssertGreaterThan(trailingInkedPixelCount(rendered), 0,
                                     "the badge drew nothing at \(width)pt, \(appearance)")
            }
        }
    }

    /// `.unknown` draws too, in both appearances — the "never drawn as zero,
    /// never silently dropped" half of the rule.
    func testUnknownDrawsInTheTrailingStrip() async throws {
        for appearance: Appearance in [.light, .dark] {
            let rendered = try await render(asksOpen: .unknown, width: 320, appearance: appearance)
            XCTAssertGreaterThan(trailingInkedPixelCount(rendered), 0,
                                 "the unknown badge drew nothing in \(appearance)")
        }
    }

    /// A zero count draws no badge, so the trailing strip is no more inked
    /// than a row with no reading at all — "draw a badge ... when it is
    /// above zero" is a visibility rule, not just a label choice.
    func testZeroCountDrawsNoMoreThanNoReadingAtAll() async throws {
        let zero = try await render(asksOpen: .count(0), width: 320, appearance: .light)
        let none = try await render(asksOpen: nil, width: 320, appearance: .light)
        XCTAssertEqual(trailingInkedPixelCount(zero), trailingInkedPixelCount(none),
                       "a zero count drew more than an absent reading")
    }
}
