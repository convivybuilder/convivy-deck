import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Deck

/// CQ·174's cockpit-state half: the cockpit keeps its scroll position and
/// its expanded epics across an occupant's lifetime. `ContentView` cannot be
/// instantiated in XCTest (convivy-deck#153, `CockpitView.topmostVisiblePanelID`'s
/// own doc), so where that item's navigation half is pinned against the pure
/// `ColumnOccupant.opening`/`.closing` functions (`ColumnOccupantTests`),
/// this half is pinned against the two things that actually hold the state:
/// `CockpitModel.expandedEntries`/`childrenByEntry`, already kept off
/// `CockpitView`'s own `@State` for the reason the model's doc gives, and
/// `CockpitModel.scrollAnchorPanelID`, this item's addition to the same
/// model. Both live on the model `ContentView` keeps for the whole window's
/// life, outliving any number of `CockpitView` instances the column's
/// `columnBody(for:)` switch builds and discards as the occupant changes —
/// rendering the SAME model through two independent `CockpitView` values is
/// what stands in for that swap here.
@MainActor
final class CockpitScrollAnchorAndExpansionRenderTests: XCTestCase {

    private func waitForChildren(_ model: CockpitModel, _ entryId: String) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let state = model.childrenByEntry[entryId], state != .loading { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Renders `panelIDs` off `model` as one column and returns the lines of
    /// text Vision reads off it — `CockpitCrossPanelFailureRenderTests`'s
    /// own rig, reused rather than re-derived. Tall enough that nothing
    /// scrolls off the fold, so the OCR assertions below are about WHAT
    /// draws, never about a pixel-exact scroll offset.
    private func renderColumn(model: CockpitModel, panelIDs: [String]) async throws -> [String] {
        let view = CockpitView(
            model: model, unresolvedReason: nil, appearance: .light,
            onSelectCorrection: { _ in }, panelIDs: panelIDs
        )
        .background(Color(white: 0.98))
        .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).json")))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: 320, height: 900))
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        defer { window.orderOut(nil) }
        let scale = 3
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width) * scale,
            pixelsHigh: Int(host.bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        return try recognisedLines(in: try XCTUnwrap(rep.cgImage))
    }

    private func recognisedLines(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    private func draws(_ needle: String, in strings: [String]) -> Bool {
        strings.contains { $0.range(of: needle, options: .caseInsensitive) != nil }
    }

    private func modelWithOneExpandedEpic() async -> CockpitModel {
        let model = CockpitModel()
        let course = LibraryClient.Course(
            id: "course_1", product: "convivy-deck", title: "T",
            entries: [LibraryClient.CourseEntry(id: "epic_A", title: "The epic")])
        model.fetchCourse = { _, _ in course }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        model.fetchEpics = { _, _ in [] }
        model.fetchChildItems = { _, _ in
            [LibraryClient.ChildItem(id: "item_1", title: "Chase the pagination bug")]
        }
        await model.refresh(target: TestHost.unreachableTarget, product: "convivy-deck")
        model.toggleExpansion(for: "epic_A")
        await waitForChildren(model, "epic_A")
        return model
    }

    /// The scenario CQ·174 names: an epic expanded with its children loaded,
    /// then the column swapped away to another occupant and back — a brand
    /// new `CockpitView`, built from the SAME model, the way
    /// `columnBody(for:)`'s `switch` rebuilds one. The epic is still
    /// expanded and its children still draw, because `expandedEntries` and
    /// `childrenByEntry` live on the model that survived the swap, not on
    /// the view that was torn down.
    func testAnExpandedEpicSurvivesTheCockpitViewBeingRebuilt() async throws {
        let model = await modelWithOneExpandedEpic()

        let first = try await renderColumn(model: model, panelIDs: [CockpitView.coursePanelID])
        XCTAssertTrue(draws("The epic", in: first))
        XCTAssertTrue(draws("Chase the pagination bug", in: first),
                      "expected the epic's own children to draw once expanded. Saw: \(first)")

        // A second, independent `CockpitView` value sharing the same model —
        // what the column's switch produces on the way back from another
        // occupant, since nothing here persists across two distinct SwiftUI
        // view identities except what the model itself holds.
        let second = try await renderColumn(model: model, panelIDs: [CockpitView.coursePanelID])
        XCTAssertTrue(draws("Chase the pagination bug", in: second),
                      "a CockpitView rebuilt from the same model must still show the epic expanded. Saw: \(second)")
    }

    /// The live wiring, not just the pure function: `CockpitView`'s own
    /// `.onPreferenceChange(PanelFramePreferenceKey.self)` handler must
    /// actually call `model.noteScrollAnchor`, so after a real render the
    /// model holds the panel that measured topmost — here, the Course,
    /// since it is the only (and so the topmost) panel in a frame tall
    /// enough that it never scrolls.
    func testRenderingTheColumnSavesTheTopmostPanelToTheModel() async throws {
        let model = await modelWithOneExpandedEpic()
        XCTAssertNil(model.scrollAnchorPanelID, "nothing has rendered yet")

        _ = try await renderColumn(model: model, panelIDs: [CockpitView.coursePanelID])

        XCTAssertEqual(model.scrollAnchorPanelID, CockpitView.coursePanelID,
                       "rendering the column must have measured the Course panel and saved it as the anchor")
    }
}
