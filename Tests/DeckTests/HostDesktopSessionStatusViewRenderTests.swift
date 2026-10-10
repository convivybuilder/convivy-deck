import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What `HostDesktopSessionStatusView` DRAWS (CQ·124's own instruction:
/// render at 320pt/280pt in both appearances before committing, the same
/// discipline `SlatePaneRenderTests` and `PullRequestWorkItemChipRenderTests`
/// already follow for their own panes).
///
/// Renders via `NSHostingView` + `cacheDisplay`, never `ImageRenderer` — see
/// `SlatePaneRenderTests`'s own doc for why.
@MainActor
final class HostDesktopSessionStatusViewRenderTests: XCTestCase {
    private func render(
        _ view: HostDesktopSessionStatusView, width: CGFloat, appearance: Appearance
    ) async throws -> NSBitmapImageRep {
        // Fixed height, so the "draws nothing" case (logged in, authorized)
        // doesn't collapse `NSHostingView`'s own bounds to zero — an empty
        // `VStack` has no intrinsic size to hand back, and a zero-size rect
        // makes `bitmapImageRepForCachingDisplay(in:)` return nil instead
        // of an image with nothing inked.
        let backed = view
            .frame(height: 40)
            .background(appearance == .dark ? Color(white: 0.145) : Color(white: 0.98))
        let host = NSHostingView(rootView: backed)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 60))
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

    /// Logged out: the status line draws, at both widths this line is
    /// measured at and in both appearances.
    func testLoggedOutDrawsTheStatusLineAtBothWidthsAndAppearances() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let rep = try await render(
                    HostDesktopSessionStatusView(hostName: "macmini", knownState: .loggedOut),
                    width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(rep), 0,
                                     "drew nothing at \(width)pt, \(appearance)")
            }
        }
    }

    /// Logged in: there is nothing wrong to report, so this draws nothing —
    /// confirmed against the SAME backdrop the populated case clears, at both
    /// widths and appearances.
    func testLoggedInDrawsNothingAtBothWidthsAndAppearances() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let rep = try await render(
                    HostDesktopSessionStatusView(hostName: "macmini", knownState: .loggedIn),
                    width: width, appearance: appearance)
                XCTAssertEqual(inkedPixelCount(rep), 0,
                               "drew something with nothing to report at \(width)pt, \(appearance)")
            }
        }
    }
}
