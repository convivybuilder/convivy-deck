import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What `EditorStatusBanner` DRAWS for a certificate outside its validity
/// window, at the editor's default column width and at the narrow width the
/// rest of the editor's renders use.
///
/// Renders via `NSHostingView` in a live window, never `ImageRenderer`, the
/// same choice `SlatePaneRenderTests` documents. The banner has no
/// `lineLimit`, so a narrow pane wraps the instruction onto more lines instead
/// of cutting it off; the height comparison pins that.
@MainActor
final class EditorStatusBannerRenderTests: XCTestCase {
    private func expired() -> EditorModel.Status {
        .certificateOutsideValidity(
            .expired(notAfter: ISO8601DateFormatter().date(from: "2027-01-03T03:24:32Z")!))
    }

    /// The laid-out height of the banner at `width`, or 0 when it draws
    /// nothing. The caller owns the window and must `orderOut` it.
    private func height(of status: EditorModel.Status, width: CGFloat) -> CGFloat {
        let view = EditorStatusBanner(status: status)
            .frame(width: width, alignment: .leading)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 600))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testTheBannerDrawsForAnExpiredCertificateAtDefaultWidth() {
        XCTAssertGreaterThan(height(of: expired(), width: 320), 0)
    }

    func testTheBannerDrawsForAnExpiredCertificateAtNarrowWidthAndWrapsInsteadOfTruncating() {
        let narrow = height(of: expired(), width: 280)
        XCTAssertGreaterThan(narrow, 0)
        XCTAssertGreaterThan(narrow, height(of: expired(), width: 320),
                             "the instruction should wrap onto more lines when the pane narrows")
    }

    func testTheBannerDoesNotDrawForAStatusThatHasNoBanner() {
        // The positive controls above would also pass if the view drew a
        // banner for every status. This is the case that must stay empty.
        XCTAssertEqual(height(of: .clean, width: 320), 0)
        XCTAssertEqual(height(of: .edited, width: 320), 0)
    }
}
