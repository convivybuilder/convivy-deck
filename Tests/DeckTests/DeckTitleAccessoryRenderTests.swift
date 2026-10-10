import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// The title lockup drawn at the accessory's measured width, read from pixels.
///
/// The accessory is as wide as `DeckTitleLabel` fits. A host 60pt wider draws
/// the same label with room to spare. Translation does not change the ink count,
/// so the two hosts show the same number of ink pixels exactly when nothing is
/// clipped at the measured width.
///
/// The 72pt control is the width the accessory had before it measured its text.
/// It must clip, or the clipping check cannot fail.
@MainActor
final class DeckTitleAccessoryRenderTests: XCTestCase {
    private let tolerance = 0.02
    private let height: CGFloat = 28

    /// The label drawn in a host of `width` points. The label paints the ground
    /// only to its own width, so the host paints the rest of its frame the same
    /// ground. Without that, a wider host would count unpainted pixels as ink.
    private func render(width: CGFloat) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: DeckTitleLabel())
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.wantsLayer = true
        let ground = StatusGround.ground
        host.layer?.backgroundColor = NSColor(red: ground.red, green: ground.green,
                                              blue: ground.blue, alpha: 1).cgColor
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Whether the pixel is the lockup's ink rather than the status ground.
    /// Anti-aliased edges count as ink.
    private func isInk(_ rep: NSBitmapImageRep, _ px: Int, _ py: Int) -> Bool {
        guard let color = rep.colorAt(x: px, y: py) else { return false }
        let ground = StatusGround.ground
        let isGround = abs(Double(color.redComponent) - ground.red) < tolerance
            && abs(Double(color.greenComponent) - ground.green) < tolerance
            && abs(Double(color.blueComponent) - ground.blue) < tolerance
        return !isGround
    }

    private func inkPixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for py in 0..<rep.pixelsHigh {
            for px in 0..<rep.pixelsWide where isInk(rep, px, py) {
                count += 1
            }
        }
        return count
    }

    /// The number of separate ink runs across the lockup: a run is a stretch of
    /// columns with ink, and runs are split by at least `minGap` points of empty
    /// columns. Letters sit well under 1pt apart, while word spaces and the gaps
    /// around the dot are 2pt or more.
    private func inkRuns(_ rep: NSBitmapImageRep, width: CGFloat, minGap: CGFloat = 2) -> Int {
        let pixelsPerPoint = CGFloat(rep.pixelsWide) / width
        let gapNeeded = Int((minGap * pixelsPerPoint).rounded(.up))
        var runs = 0
        var emptyStreak = gapNeeded
        for px in 0..<rep.pixelsWide {
            let hasInk = (0..<rep.pixelsHigh).contains { isInk(rep, px, $0) }
            if hasInk {
                if emptyStreak >= gapNeeded { runs += 1 }
                emptyStreak = 0
            } else {
                emptyStreak += 1
            }
        }
        return runs
    }

    func testTheLockupIsNotClippedAtItsMeasuredWidth() throws {
        let measured = DeckTitleAccessory().view.frame.width
        let roomy = try inkPixels(render(width: measured + 60))
        let fitted = try inkPixels(render(width: measured))
        XCTAssertGreaterThan(roomy, 0, "the lockup should draw ink at all")
        XCTAssertEqual(fitted, roomy,
                       "the lockup must draw the same ink at its measured width of \(measured)pt as with room to spare")
    }

    /// "Convivy", "Builder", the middle dot and "Deck" are four separate runs. A
    /// lockup without the dot has three, because "Builder" and "Deck" then share
    /// one gap and read as one title.
    func testTheMiddleDotSeparatesTheBrandFromDeck() throws {
        let measured = DeckTitleAccessory().view.frame.width
        let rep = try render(width: measured)
        XCTAssertEqual(inkRuns(rep, width: measured), 4,
                       "the lockup should read as Convivy, Builder, a middle dot and Deck")
    }

    func testTheOld72PointWidthClipsTheLockup() throws {
        let measured = DeckTitleAccessory().view.frame.width
        XCTAssertGreaterThan(measured, 72, "the measured lockup should be wider than the old 72pt")
        let roomy = try inkPixels(render(width: measured + 60))
        let clipped = try inkPixels(render(width: 72))
        XCTAssertLessThan(clipped, roomy, "a 72pt host must clip the lockup, so the clipping check can fail")
    }
}
