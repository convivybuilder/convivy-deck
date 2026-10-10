import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What `DesktopSessionAlertCard` DRAWS at Deck's window widths, in both
/// appearances (CQ·130's render check). The card sits centred at the top of
/// the window, so it is hosted at the window's own width.
///
/// Renders via `NSHostingView` + `cacheDisplay`, never `ImageRenderer` — see
/// `SlatePaneRenderTests`'s own doc for why.
@MainActor
final class DesktopSessionAlertCardRenderTests: XCTestCase {
    private let withRunbook = LoggedOutAlert(
        target: SSHTarget(user: "builder-rehearsal", host: "10.0.0.9"),
        hostName: "macmini", account: "builder-rehearsal",
        runbook: .kb(id: "shipwright/runbooks/log-your-builder-account-back-in-after-a-restart"),
        screenSharing: URL(string: "vnc://10.0.0.9"))

    private let withoutRunbook = LoggedOutAlert(
        target: SSHTarget(user: "builder-rehearsal", host: "10.0.0.9"),
        hostName: "macmini", account: "builder-rehearsal", runbook: nil,
        screenSharing: URL(string: "vnc://10.0.0.9"))

    private let bare = LoggedOutAlert(
        target: SSHTarget(user: "builder-rehearsal", host: "-oBad"),
        hostName: "macmini", account: "builder-rehearsal", runbook: nil, screenSharing: nil)

    private func render(
        _ alert: LoggedOutAlert, width: CGFloat, appearance: Appearance
    ) async throws -> NSBitmapImageRep {
        let card = DesktopSessionAlertCard(
            alert: alert, onOpenRunbook: {}, onOpenScreenSharing: {}, onDismiss: {})
            .frame(width: width, height: 260, alignment: .top)
            .background(appearance == .dark ? Color(white: 0.145) : Color(white: 0.98))
        let host = NSHostingView(rootView: card)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 260))
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

    private func inkedPixelCount(_ rep: NSBitmapImageRep) -> Int {
        guard let backdrop = rep.colorAt(x: 0, y: 0) else { return 0 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(c.redComponent - backdrop.redComponent)
                    + abs(c.greenComponent - backdrop.greenComponent)
                    + abs(c.blueComponent - backdrop.blueComponent)
                if delta > 0.05 { count += 1 }
            }
        }
        return count
    }

    /// Both variants draw at the narrowest window Deck allows and at the
    /// width where the rail stops collapsing, in both appearances.
    func testBothVariantsDrawAtWindowWidthsInBothAppearances() async throws {
        for width in [LayoutBreakpoints.windowMinWidth, LayoutBreakpoints.railCollapse] {
            for appearance: Appearance in [.light, .dark] {
                for alert in [withRunbook, withoutRunbook, bare] {
                    let rep = try await render(alert, width: CGFloat(width), appearance: appearance)
                    XCTAssertGreaterThan(
                        inkedPixelCount(rep), 0,
                        "drew nothing at \(width)pt, \(appearance), buttons: \(alert.buttons)")
                }
            }
        }
    }

    /// The two variants carry different copy and a different action, so they
    /// must not draw the same pixels. Equal counts would mean one variant's
    /// content never reached the card.
    func testTheRunbookAndNoRunbookVariantsDrawDifferently() async throws {
        let runbook = try await render(withRunbook, width: CGFloat(LayoutBreakpoints.windowMinWidth), appearance: .light)
        let noRunbook = try await render(withoutRunbook, width: CGFloat(LayoutBreakpoints.windowMinWidth), appearance: .light)

        XCTAssertNotEqual(inkedPixelCount(runbook), inkedPixelCount(noRunbook))
    }
}
