import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What `MergeRefusalRow` DRAWS for each of the six named causes plus
/// `.unrecognised`, at the two widths the item names and in both
/// appearances — the item's own instruction, the same
/// `NSHostingView` + `cacheDisplay` harness `SlatePaneRenderTests` and
/// `PullRequestWorkItemChipRenderTests` use.
///
/// Renders via `NSHostingView` + `cacheDisplay`, never `ImageRenderer`, which
/// draws `ScrollView` contents blank — the same choice those files document.
@MainActor
final class MergeRefusalRowRenderTests: XCTestCase {
    private let allCauses: [MergeRefusal] = [
        .movedHead,
        .conflict,
        .protectedBranch,
        .redRequiredCheck,
        .unauthorizedCredential(.account(login: "work-account"), status: 403, githubMessage: "Forbidden"),
        .servesSessions(.configuredHostResolvesHere),
        .servesSessions(.builderInstalledHere),
        .unrecognised(status: 422, message: "Validation Failed"),
    ]

    private func render(
        _ refusal: MergeRefusal, width: CGFloat, appearance: Appearance
    ) async throws -> NSBitmapImageRep {
        let view = MergeRefusalRow(refusal: refusal, appearance: appearance)
            .frame(width: width, alignment: .leading)
            .background(appearance == .dark ? Color(white: 0.145) : Color(white: 0.98))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 120))
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

    /// Whether `c` differs from `backdrop` by more than a hair —
    /// `SlatePaneRenderTests`' own measure.
    private func isInk(_ c: NSColor, against backdrop: NSColor) -> Bool {
        let delta = abs(c.redComponent - backdrop.redComponent)
            + abs(c.greenComponent - backdrop.greenComponent)
            + abs(c.blueComponent - backdrop.blueComponent)
        return delta > 0.05
    }

    private func inkedPixelCount(_ rep: NSBitmapImageRep) -> Int {
        guard let backdrop = rep.colorAt(x: 0, y: rep.pixelsHigh - 1) else { return 0 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if isInk(c, against: backdrop) { count += 1 }
            }
        }
        return count
    }

    /// Every one of the six causes plus `.unrecognised` draws real,
    /// non-blank ink at both widths the item names and in both
    /// appearances — a refusal line never silently drops out.
    func testEveryCauseDrawsNonBlankAtBothWidthsAndAppearances() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                for refusal in allCauses {
                    let rep = try await render(refusal, width: width, appearance: appearance)
                    XCTAssertGreaterThan(
                        inkedPixelCount(rep), 0,
                        "\(refusal) drew nothing at \(width)pt, \(appearance)")
                }
            }
        }
    }

    /// `.unrecognised` draws GitHub's own status and message verbatim — the
    /// item's own rule that nothing is ever drawn as a bare generic failure.
    /// Two different unrecognised refusals must draw differently ink-wise
    /// from each other, proving the message (not a fixed placeholder
    /// string) is what reaches the screen.
    func testUnrecognisedDrawsItsOwnMessageRatherThanAFixedPlaceholder() async throws {
        let short = MergeRefusal.unrecognised(status: 418, message: "teapot")
        let long = MergeRefusal.unrecognised(
            status: 500, message: "Something went wrong on GitHub's side, in a way nobody here has seen before")
        let shortRep = try await render(short, width: 320, appearance: .light)
        let longRep = try await render(long, width: 320, appearance: .light)
        XCTAssertNotEqual(inkedPixelCount(shortRep), inkedPixelCount(longRep),
                          "two different unrecognised messages drew identical ink")
    }

    /// No two of the eight fixtures share a message — the same "two things
    /// read as one" risk `PRLadderRowTests.testEveryPositionHasADistinctLabel`
    /// guards for the ladder's own positions.
    func testEveryCauseHasADistinctMessage() {
        let messages = allCauses.map(\.message)
        XCTAssertEqual(Set(messages).count, messages.count)
    }

    /// No two of the seven NAMED causes share a glyph — the shape channel
    /// the item asks for alongside the text, so the row never relies on
    /// colour alone. `servesSessions`'s two sub-reasons are the same named
    /// cause and share one glyph on purpose, so this checks one
    /// representative per case rather than `allCauses`, which carries both.
    func testEverySevenNamedCausesHasADistinctGlyph() {
        let sevenCauses: [MergeRefusal] = [
            .movedHead, .conflict, .protectedBranch, .redRequiredCheck,
            .unauthorizedCredential(.account(login: "work-account"), status: 403, githubMessage: "Forbidden"),
            .servesSessions(.configuredHostResolvesHere), .unrecognised(status: 422, message: "x"),
        ]
        let glyphs = sevenCauses.map(\.glyphName)
        XCTAssertEqual(Set(glyphs).count, glyphs.count)
    }
}
