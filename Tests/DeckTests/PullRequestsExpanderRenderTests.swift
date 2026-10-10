import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What the Pull Requests panel's closed-tier toggle DRAWS
/// (issue_01M3WPNPZD9P4VPFESYMK7PEWY), not merely what
/// `PRLadder.orderedForDisplay`/`hiddenClosedCount` compute — those are
/// `PRLadderTests`' own job. These host the real `CockpitView` in a window
/// and read pixels, the same reason `PullRequestWorkItemChipRenderTests`
/// exists for the chip.
///
/// Renders via `NSHostingView` + `cacheDisplay`, never `ImageRenderer`, which
/// draws `ScrollView` contents blank — `CockpitRevealRenderTests`' own choice.
@MainActor
final class PullRequestsExpanderRenderTests: XCTestCase {
    private let product = "convivy-deck"

    private func model() async -> CockpitModel {
        let model = CockpitModel()
        model.fetchCourse = { _, _ in nil }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        await model.refresh(target: TestHost.unreachableTarget, product: product)
        return model
    }

    /// Eight closed rows — three past `recentClosedLimit` (5), so the
    /// collapsed default hides three and the toggle has something to reveal.
    private func panelWithMoreClosedRowsThanTheLimit() -> CockpitView.PullRequestsPanel {
        let rows = (1...8).map { number in
            PRLadder.LadderResult(
                repo: "convivy/convivy-deck", number: number, title: "PR \(number)", author: "agent-x",
                position: .closed(.merged), staleReviewCount: 0,
                updatedAt: "2026-09-\(String(format: "%02d", number))T00:00:00Z")
        }
        return CockpitView.PullRequestsPanel(result: .ladder(rows, truncated: false), fetchError: nil, isLoading: false)
    }

    /// Five closed rows exactly at the limit — nothing for the toggle to
    /// reveal, so it must draw nothing.
    private func panelAtTheLimit() -> CockpitView.PullRequestsPanel {
        let rows = (1...PRLadder.recentClosedLimit).map { number in
            PRLadder.LadderResult(
                repo: "convivy/convivy-deck", number: number, title: "PR \(number)", author: "agent-x",
                position: .closed(.merged), staleReviewCount: 0,
                updatedAt: "2026-09-\(String(format: "%02d", number))T00:00:00Z")
        }
        return CockpitView.PullRequestsPanel(result: .ladder(rows, truncated: false), fetchError: nil, isLoading: false)
    }

    /// Renders the Pull Requests panel alone, given time for layout to
    /// settle — `PullRequestWorkItemChipRenderTests`' own harness, including
    /// its explicit backdrop (that test's comment explains why one is
    /// needed: `CockpitView` takes `appearance` as a parameter and paints no
    /// window chrome of its own in this harness).
    private func render(
        _ model: CockpitModel, panel: CockpitView.PullRequestsPanel, width: CGFloat, appearance: Appearance
    ) async throws -> NSBitmapImageRep {
        let view = CockpitView(
            model: model, unresolvedReason: nil, appearance: appearance,
            onSelectCorrection: { _ in }, panelIDs: [CockpitView.pullRequestsPanelID],
            pullRequests: panel
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
    /// `render` paints) by more than a hair — `PullRequestWorkItemChipRenderTests`'
    /// own measure.
    private func inkedPixelCount(_ rep: NSBitmapImageRep) -> Int {
        // The bottom-left pixel is the backdrop. The top-left is the Cockpit's
        // header band now, which would count every backdrop pixel as ink.
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

    /// Expanding the closed tier draws strictly more ink than collapsed —
    /// the three extra rows plus the toggle's own "Show fewer" text, at both
    /// widths the item names and in both appearances. Setting
    /// `DECK_SNAPSHOT_DIR` also writes each PNG for a look
    /// (`StewardBoardQueueRenderTests`'s own pattern).
    func testExpandingDrawsMoreInkThanCollapsedAtBothWidthsAndAppearances() async throws {
        let snapshotDir = ProcessInfo.processInfo.environment["DECK_SNAPSHOT_DIR"]
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let collapsedModel = await model()
                let collapsed = try await render(
                    collapsedModel, panel: panelWithMoreClosedRowsThanTheLimit(), width: width, appearance: appearance)
                let expandedModel = await model()
                expandedModel.togglePullRequestsExpansion()
                let expanded = try await render(
                    expandedModel, panel: panelWithMoreClosedRowsThanTheLimit(), width: width, appearance: appearance)
                XCTAssertGreaterThan(
                    inkedPixelCount(expanded), inkedPixelCount(collapsed),
                    "expanding drew no extra ink at \(width)pt, \(appearance)")
                if let snapshotDir {
                    for (name, rep) in [("collapsed", collapsed), ("expanded", expanded)] {
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try png.write(to: URL(fileURLWithPath: snapshotDir)
                                .appendingPathComponent("pr-expander-\(name)-\(Int(width))-\(appearance).png"))
                        }
                    }
                }
            }
        }
    }

    /// A closed tier at or below `recentClosedLimit` draws no toggle, so
    /// toggling `isPullRequestsExpanded` changes nothing on screen.
    func testNoToggleDrawsWhenTheClosedTierAlreadyFitsTheLimit() async throws {
        let collapsedModel = await model()
        let collapsed = try await render(
            collapsedModel, panel: panelAtTheLimit(), width: 320, appearance: .light)
        let expandedModel = await model()
        expandedModel.togglePullRequestsExpansion()
        let expanded = try await render(
            expandedModel, panel: panelAtTheLimit(), width: 320, appearance: .light)
        XCTAssertEqual(inkedPixelCount(expanded), inkedPixelCount(collapsed))
    }
}
