import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What an expanded epic's child rows DRAW — `CockpitView.epicDetail` ->
/// `childItemsSection` -> `childItemRow` — at the two widths CQ·170
/// (issue_01M5CRQCRX0JQSBH4918VB4QD0) names and in both appearances, the
/// same `NSHostingView` + `cacheDisplay` harness `EpicKeyRenderTests` and
/// `SlatePaneRenderTests` use.
///
/// Renders via `NSHostingView` + `cacheDisplay`, never `ImageRenderer`, which
/// draws `ScrollView` contents blank — `CockpitRevealRenderTests`' own choice.
@MainActor
final class ChildItemRowRenderTests: XCTestCase {
    private let product = "convivy-deck"
    private let epicID = "issue_EPIC"

    /// A Course of one epic, expanded, with `child` as its only child.
    /// `toggleExpansion` kicks off `fetchChildItems` on a detached task, so
    /// this polls `childrenByEntry` until it lands rather than racing a
    /// `.loading` render.
    private func model(child: LibraryClient.ChildItem) async -> CockpitModel {
        let model = CockpitModel()
        let course = LibraryClient.Course(
            id: "course_1", product: product, title: nil,
            entries: [LibraryClient.CourseEntry(id: epicID, title: "The epic", type: "epic", state: "open")])
        model.fetchCourse = { _, _ in course }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        model.fetchChildItems = { _, _ in [child] }
        await model.refresh(target: TestHost.unreachableTarget, product: product)
        model.toggleExpansion(for: epicID)
        let deadline = Date().addingTimeInterval(5)
        while model.childrenByEntry[epicID] == nil || model.childrenByEntry[epicID] == .loading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return model
    }

    /// Mounts the Course panel alone, the epic already expanded. `2000pt`
    /// tall so an unclamped title would still draw whole rather than running
    /// out of window before the clamp this file checks even matters.
    private func render(
        _ model: CockpitModel, width: CGFloat, appearance: Appearance
    ) async throws -> NSBitmapImageRep {
        let view = CockpitView(
            model: model, unresolvedReason: nil, appearance: appearance,
            onSelectCorrection: { _ in }, panelIDs: [CockpitView.coursePanelID]
        )
        .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).json")))
        .frame(width: width, alignment: .leading)
        .background(appearance == .dark ? Color(white: 0.145) : Color(white: 0.98))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 2000))
        host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 800_000_000)
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
        // The bottom-left pixel sits below everything this file ever draws
        // (the host is 2000pt tall), so it is always the plain backdrop.
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

    /// The farthest-down row carrying any ink — how tall the content drew,
    /// regardless of what drew it.
    private func lowestInkRow(_ rep: NSBitmapImageRep) -> Int {
        guard let backdrop = rep.colorAt(x: 0, y: rep.pixelsHigh - 1) else { return 0 }
        var lowest = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if isInk(c, against: backdrop) { lowest = max(lowest, y); break }
            }
        }
        return lowest
    }

    private func plainChild(id: String, title: String) -> LibraryClient.ChildItem {
        LibraryClient.ChildItem(id: id, title: title, type: nil, state: "open", parentId: epicID)
    }

    /// A blocked child draws its lock mark — strictly more ink than the same
    /// child with neither `blocked` nor a prerequisite, isolated from the
    /// "Needs first:" caption the next test checks.
    func testABlockedChildDrawsItsLockMark() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let blocked = LibraryClient.ChildItem(
                    id: "child_1", title: "Rotate the two mis-named keys", type: nil, state: "open",
                    parentId: epicID, prerequisites: [], blocked: true)
                let plain = plainChild(id: "child_1", title: "Rotate the two mis-named keys")
                let blockedRep = try await render(await model(child: blocked), width: width, appearance: appearance)
                let plainRep = try await render(await model(child: plain), width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(blockedRep), inkedPixelCount(plainRep),
                                     "the lock mark drew nothing at \(width)pt, \(appearance)")
            }
        }
    }

    /// A blocked child whose one prerequisite is `{item, missing: true}`
    /// draws the "Needs first: \(CockpitView.missingPrerequisiteLabel)"
    /// caption — strictly more ink than the same blocked child with no
    /// prerequisite at all, isolating the caption from the lock mark both
    /// draw.
    func testABlockedChildWithAMissingPrerequisiteDrawsTheNeedsFirstCaption() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let blockedAlone = LibraryClient.ChildItem(
                    id: "child_1", title: "Rotate the two mis-named keys", type: nil, state: "open",
                    parentId: epicID, prerequisites: [], blocked: true)
                let blockedWithMissingPrereq = LibraryClient.ChildItem(
                    id: "child_1", title: "Rotate the two mis-named keys", type: nil, state: "open",
                    parentId: epicID, prerequisites: [.missingItem(id: "missing_1")], blocked: true)
                let aloneRep = try await render(await model(child: blockedAlone), width: width, appearance: appearance)
                let withCaptionRep = try await render(
                    await model(child: blockedWithMissingPrereq), width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(withCaptionRep), inkedPixelCount(aloneRep),
                                     "the \"Needs first: \(CockpitView.missingPrerequisiteLabel)\" caption drew nothing at \(width)pt, \(appearance)")
            }
        }
    }

    /// A title long enough to need far more than two lines unclamped still
    /// stops at the same row as one that needs only a little more than
    /// two — `childItemRow`'s `.lineLimit(2)` truncates rather than growing
    /// the row without bound. Fails if the clamp is lost: an unclamped
    /// title would push the far-longer fixture's lowest ink row well past
    /// the shorter one's.
    func testALongChildTitleClampsRatherThanGrowingTheRowWithoutBound() async throws {
        let mediumTitle = String(repeating: "Convivy fleet work item ", count: 20)
        let veryLongTitle = String(repeating: "Convivy fleet work item ", count: 160)
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let mediumRep = try await render(
                    await model(child: plainChild(id: "child_1", title: mediumTitle)), width: width, appearance: appearance)
                let veryLongRep = try await render(
                    await model(child: plainChild(id: "child_1", title: veryLongTitle)), width: width, appearance: appearance)
                let mediumBottom = lowestInkRow(mediumRep)
                let veryLongBottom = lowestInkRow(veryLongRep)
                XCTAssertGreaterThan(mediumBottom, 0, "the medium title drew nothing at \(width)pt, \(appearance)")
                XCTAssertLessThanOrEqual(
                    abs(veryLongBottom - mediumBottom), 4,
                    "a title 8x longer reached a different row (\(mediumBottom) vs \(veryLongBottom)) at "
                        + "\(width)pt, \(appearance) — the title did not clamp to two lines")
            }
        }
    }
}
