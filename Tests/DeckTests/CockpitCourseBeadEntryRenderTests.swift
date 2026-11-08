import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What the Course panel's own bead entry DRAWS (issue_01M5CRQ3ETH6AMM5Y5M95RACDG),
/// for a crew that carries a bead and one that does not, at the 320pt and
/// 280pt column widths the item names. `CockpitViewTests` covers pure
/// derivations only; this follows `PullRequestsExpanderRenderTests`'s own
/// choice to host the real `CockpitView` and read pixels — nothing else can
/// see a SwiftUI `Text`.
///
/// Renders via `NSHostingView` + `cacheDisplay`, never `ImageRenderer`, which
/// draws `ScrollView` contents blank — `CockpitRevealRenderTests`'s own
/// choice.
@MainActor
final class CockpitCourseBeadEntryRenderTests: XCTestCase {
    private let product = "convivy-deck"

    /// A course-less, queue-less model, the same fixture
    /// `PullRequestsExpanderRenderTests.model()` builds — this file only
    /// cares about the bead entry at the top of the panel, not the Course
    /// rows below it.
    private func model() async -> CockpitModel {
        let model = CockpitModel()
        model.fetchCourse = { _, _ in nil }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        await model.refresh(target: TestHost.unreachableTarget, product: product)
        return model
    }

    /// Renders the Course panel alone, given time for layout to settle —
    /// `PullRequestsExpanderRenderTests`'s own harness and backdrop, so a
    /// failure here reads against the same measure that panel's own tests do.
    private func render(
        _ model: CockpitModel, onOpenBead: (() -> Void)?, beadHelp: String?,
        width: CGFloat, appearance: Appearance
    ) async throws -> NSBitmapImageRep {
        let view = CockpitView(
            model: model, unresolvedReason: nil, appearance: appearance,
            onSelectCorrection: { _ in }, onOpenBead: onOpenBead, beadHelp: beadHelp,
            panelIDs: [CockpitView.coursePanelID]
        )
        .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).json")))
        .background(appearance == .dark ? Color(white: 0.145) : Color(white: 0.98))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 480))
        host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        defer { window.orderOut(nil) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels that differ from the render's own corner (the solid backdrop
    /// `render` paints) by more than a hair — `PullRequestsExpanderRenderTests`'s
    /// own measure.
    private func inkedPixelCount(_ rep: NSBitmapImageRep) -> Int {
        guard let backdrop = rep.colorAt(x: 0, y: rep.pixelsHigh - 1) else { return 0 }
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

    /// A crew with a bead draws the tappable entry's own text, at both
    /// widths and both appearances the item names.
    func testTheBeadEntryDrawsForACrewWithABead() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let rep = try await render(
                    await model(), onOpenBead: {}, beadHelp: "Open this project's bead",
                    width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(rep), 0,
                    "no bead entry drew at \(width)pt, \(appearance)")
            }
        }
    }

    /// A crew with no bead draws the same reason the rail's own bead button
    /// gives, in place, at both widths and both appearances.
    func testTheBeadEntryShowsTheRailsReasonInPlaceForACrewWithNoBead() async throws {
        let reason = "Deck names no bead. Choose one in Settings \u{203a} Sessions."
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let rep = try await render(
                    await model(), onOpenBead: nil, beadHelp: reason,
                    width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(rep), 0,
                    "no reason text drew at \(width)pt, \(appearance)")
            }
        }
    }

    /// A `CockpitView` built the way every call site that predates this item
    /// still builds one — naming neither `onOpenBead` nor `beadHelp` — draws
    /// strictly LESS ink than the same render with a reason set. The bug
    /// this pins: `beadHelp`'s first draft defaulted to a non-nil sentence,
    /// so every pre-existing Course panel render grew an extra row it never
    /// asked for and `CockpitRevealRenderTests`'s own fixed-height,
    /// fixed-position assertion broke on it.
    func testANeitherFieldSetViewDrawsLessInkThanOneWithAReason() async throws {
        let unconfigured = try await render(
            await model(), onOpenBead: nil, beadHelp: nil, width: 320, appearance: .light)
        let withReason = try await render(
            await model(), onOpenBead: nil, beadHelp: "Deck names no bead. Choose one in Settings \u{203a} Sessions.",
            width: 320, appearance: .light)
        XCTAssertLessThan(inkedPixelCount(unconfigured), inkedPixelCount(withReason),
            "an unconfigured view should draw no bead entry at all")
    }

    /// The reason text wraps onto more lines at the narrow width rather than
    /// clipping — `EditorStatusBannerRenderTests`'s own technique: a narrower
    /// host must draw height, not less of it, since this `Text` carries no
    /// `lineLimit`.
    func testTheNoBeadReasonWrapsRatherThanClipsAt280pt() async throws {
        let reason = "This crew's display name is long enough that the sentence explaining " +
            "it names no bead has to wrap onto more than one line. Choose one in Settings " +
            "\u{203a} Sessions."

        func height(width: CGFloat) async -> CGFloat {
            let view = CockpitView(
                model: await model(), unresolvedReason: nil, appearance: .light,
                onSelectCorrection: { _ in }, onOpenBead: nil, beadHelp: reason,
                panelIDs: [CockpitView.coursePanelID])
                .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("theme-\(UUID().uuidString).json")))
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

        let narrow = await height(width: 280)
        let normal = await height(width: 320)
        XCTAssertGreaterThan(narrow, 0)
        XCTAssertGreaterThanOrEqual(narrow, normal,
            "the no-bead reason should wrap onto more lines, not clip, as the pane narrows")
    }
}
