import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What the PR row's stable-key chip (issue_01M2P5D0D4EQEQX7BSRNFT5QGJ) DRAWS,
/// not merely what the join computes — `CockpitViewTests`'s
/// `pullRequestWorkItemChips` tests pin the join; these host the real
/// `CockpitView` in a window and read pixels, the same reason
/// `CockpitRevealRenderTests` exists for the highlight.
///
/// Renders via `NSHostingView` + `cacheDisplay`, never `ImageRenderer`, which
/// draws `ScrollView` contents blank — the same choice `CockpitRevealRenderTests`
/// made and documents.
@MainActor
final class PullRequestWorkItemChipRenderTests: XCTestCase {
    private let product = "convivy-deck"

    private func model(withChip: Bool) async -> CockpitModel {
        let model = CockpitModel()
        let course = LibraryClient.Course(
            id: "course_1", product: product, title: nil,
            entries: [LibraryClient.CourseEntry(
                id: "issue_EPIC", title: "The epic", type: "epic", state: "pr-open",
                key: withChip ? "E16" : nil, pr: "42", prURL: nil, prRepo: "convivy/convivy-deck")])
        model.fetchCourse = { _, _ in course }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        // The chip join now reads `allWorkItems`, not the Course directly
        // (issue_01M3WPNJ1ESJVCVJ85FVNQHNKC) — stubbed with the epic's own
        // row so this render test still exercises a real chip rather than
        // falling to the unstubbed default, which would hit
        // `TestHost.unreachableTarget` and draw none.
        model.fetchAllItems = { _, _ in
            [LibraryClient.WorkItemRecord(
                id: "issue_EPIC", title: "The epic", type: "epic",
                key: withChip ? "E16" : nil, pr: "42", prRepo: "convivy/convivy-deck")]
        }
        await model.refresh(target: TestHost.unreachableTarget, product: product)
        return model
    }

    private func panel() -> CockpitView.PullRequestsPanel {
        let row = PRLadder.LadderResult(
            repo: "convivy/convivy-deck", number: 42, title: "Add the thing", author: "agent-x",
            position: .inReview, staleReviewCount: 0, updatedAt: nil)
        return CockpitView.PullRequestsPanel(result: .ladder([row], truncated: false), fetchError: nil, isLoading: false)
    }

    /// Renders the Pull Requests panel alone, given time for layout to
    /// settle. `scale` reads off the bitmap, since every pixel index below
    /// is a device pixel.
    private func render(_ model: CockpitModel, width: CGFloat, appearance: Appearance) async throws -> NSBitmapImageRep {
        let view = CockpitView(
            model: model, unresolvedReason: nil, appearance: appearance,
            onSelectCorrection: { _ in }, panelIDs: [CockpitView.pullRequestsPanelID],
            pullRequests: panel()
        )
        .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).json")))
        // `CockpitView` itself takes `appearance` as an explicit parameter and
        // never reads `colorScheme` (CLAUDE.md: the shell is the single
        // appearance authority) — confirmed by this very test, since the
        // row's own explicit `ThemeRecipe` inks (the dot, the chip) draw
        // correctly either way with no backdrop below. `.primary`/`.secondary`,
        // the row's REMAINING text, are plain SwiftUI semantic colors with
        // nothing here to resolve them against: an `NSHostingView` with no
        // window chrome around it paints no backdrop of its own, so there is
        // no real surface for "dark text" or "light text" to clear against,
        // on EITHER appearance — `CockpitRevealRenderTests` never hit this
        // because it only ever renders `.light`, where the default backdrop
        // this produces happens to already read as light. The explicit
        // backdrop below is what the real shell window supplies and this
        // harness otherwise has no source for.
        .background(appearance == .dark ? Color(white: 0.145) : Color(white: 0.98))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 200))
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
    /// `render` paints, read back rather than assumed, so this stays correct
    /// if that colour ever changes) by more than a hair — every pixel any
    /// text, border or mark actually painted, on either appearance.
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

    /// A row with a chip draws strictly more ink than the same row without
    /// one — the chip's text and its border are real pixels, not a no-op —
    /// checked at both widths the item's own constraint names and in both
    /// appearances, so a contrast or layout regression at any corner fails
    /// here rather than shipping unverified.
    func testTheChipDrawsExtraInkAtBothWidthsAndAppearances() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let withChip = try await render(model(withChip: true), width: width, appearance: appearance)
                let withoutChip = try await render(model(withChip: false), width: width, appearance: appearance)
                XCTAssertGreaterThan(
                    inkedPixelCount(withChip), inkedPixelCount(withoutChip),
                    "the chip drew no extra ink at \(width)pt, \(appearance)")
            }
        }
    }
}
