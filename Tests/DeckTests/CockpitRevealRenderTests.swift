import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What a reveal DRAWS. `CockpitRevealTests` pins the model, and a model that
/// says `highlightedItemID == "issue_kid"` passes whether or not any view reads
/// it. That is how a reveal once shipped green with nothing highlighted. These
/// tests host the real `CockpitView` in a window and read pixels, so they fail
/// when the row draws the same highlighted as not.
///
/// The highlight is the proposal card's tint, `accentColor` at 8%. It bleeds 4pt
/// right of the row's content, into the 12pt padding the panel already has, and
/// nothing else draws in that strip on a child row. So one column of pixels
/// there reads as the window's margin on every row except a highlighted one.
/// `tintedRows` reads that column.
@MainActor
final class CockpitRevealRenderTests: XCTestCase {
    private let product = "convivy-deck"
    private let paneSize = NSSize(width: 320, height: 420)

    private func kids(_ count: Int) -> [LibraryClient.ChildItem] {
        (1...count).map { LibraryClient.ChildItem(id: "issue_kid\($0)", title: "Work item \($0)") }
    }

    /// A model following one project with one epic (`epic_A`) whose children are
    /// `children`, every one listed in the queue read's `childParents` so a
    /// reveal costs no request.
    private func model(children: [LibraryClient.ChildItem]) async -> CockpitModel {
        let model = CockpitModel()
        let course = LibraryClient.Course(
            id: "course_1", product: product, title: nil,
            entries: [LibraryClient.CourseEntry(id: "epic_A", title: "The epic", type: "epic", state: "claimed")])
        let queue = LibraryClient.CorrectionsQueue(
            items: [], total: 0, truncated: false,
            childParents: Dictionary(uniqueKeysWithValues: children.map { ($0.id, "epic_A") }))
        model.fetchCourse = { _, _ in course }
        model.fetchQueue = { _, _ in queue }
        model.fetchChildItems = { _, _ in children }
        await model.refresh(target: TestHost.unreachableTarget, product: product)
        return model
    }

    private func waitForChildren(_ model: CockpitModel) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let state = model.childrenByEntry["epic_A"], state != .loading { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The epic open with every child loaded and nothing highlighted, the
    /// control every highlighted render is compared against.
    private func openedByHand(_ children: [LibraryClient.ChildItem]) async -> CockpitModel {
        let model = await model(children: children)
        model.toggleExpansion(for: "epic_A")
        await waitForChildren(model)
        return model
    }

    private func revealed(_ id: String, among children: [LibraryClient.ChildItem]) async -> CockpitModel {
        let model = await model(children: children)
        let outcome = await model.reveal(itemID: id)
        XCTAssertEqual(outcome, .revealed)
        await waitForChildren(model)
        return model
    }

    private struct Render {
        let rep: NSBitmapImageRep
        let scale: CGFloat
    }

    /// The Course panel alone, in a window, given time for the layout to settle
    /// and for a `scrollTo` scheduled by the view to run. The scale
    /// is read from the bitmap, since every pixel index below is a device pixel.
    private func render(_ model: CockpitModel) async throws -> Render {
        let view = CockpitView(
            model: model, unresolvedReason: nil, appearance: .light,
            onSelectCorrection: { _ in }, panelIDs: [CockpitView.coursePanelID]
        )
        .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).json")))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: paneSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        // Suspended rather than spinning `RunLoop.current`: a nested run loop
        // inside this main-actor test never lets the view's own
        // `DispatchQueue.main.async` (the scroll) run, so the scroll tests
        // would fail for a reason that has nothing to do with the view.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        defer { window.orderOut(nil) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, scale: max(CGFloat(rep.pixelsWide) / host.bounds.width, 1))
    }

    /// Pixel rows where the gutter column (310pt, inside the tint and past the
    /// row's own content, which ends at 308pt) differs from the margin column
    /// (3pt, left of everything). A row is listed only if a highlight was
    /// painted there.
    private func tintedRows(_ render: Render) -> [Int] {
        let gutter = Int(310 * render.scale)
        let margin = Int(3 * render.scale)
        return (0..<render.rep.pixelsHigh).filter { y in
            guard let a = render.rep.colorAt(x: gutter, y: y),
                  let b = render.rep.colorAt(x: margin, y: y) else { return false }
            let delta = abs(a.alphaComponent - b.alphaComponent)
                + abs(a.redComponent - b.redComponent)
                + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent)
            return delta > 0.01
        }
    }

    /// The row bands `tintedRows` found, as `(first, last)` runs of consecutive
    /// pixel rows.
    private func bands(_ rows: [Int]) -> [(first: Int, last: Int)] {
        var out: [(first: Int, last: Int)] = []
        for y in rows {
            if let last = out.last, y == last.last + 1 { out[out.count - 1].last = y }
            else { out.append((first: y, last: y)) }
        }
        return out
    }

    // MARK: - The measurement can tell

    /// The positive control for everything below. An epic opened by hand has
    /// every child row on screen and nothing highlighted, so an empty result
    /// here means "no highlight drawn" and not "the gutter cannot be read".
    func testAnEpicOpenedByHandDrawsNoHighlight() async throws {
        let children = kids(3)
        let handOpened = await openedByHand(children)
        let render = try await render(handOpened)
        XCTAssertTrue(tintedRows(render).isEmpty,
                      "rows tinted with no reveal: the gutter column is not a clean background")
        // The rows are actually there, so the empty result above is not an
        // empty pane.
        let inked = (0..<render.rep.pixelsHigh).filter { y in
            (0..<render.rep.pixelsWide).contains { x in
                (render.rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            }
        }
        XCTAssertGreaterThan(inked.count, Int(30 * render.scale), "the pane rendered without its rows")
    }

    // MARK: - A reveal draws a highlight

    /// The case the feature exists for, and the one no model assertion could
    /// see: the revealed row is filled and its neighbours are not.
    func testARevealedRowIsFilledAndItsNeighboursAreNot() async throws {
        let children = kids(3)
        let model = await revealed("issue_kid2", among: children)
        let render = try await render(model)
        let found = bands(tintedRows(render))
        XCTAssertEqual(found.count, 1, "expected exactly one highlighted row, found \(found)")
        let band = try XCTUnwrap(found.first)
        // One row tall: a single-line child plus its 4pt bleed each side. The
        // bounds only rule out "the whole panel tinted" and "a sliver".
        let height = CGFloat(band.last - band.first + 1) / render.scale
        XCTAssertGreaterThan(height, 12)
        XCTAssertLessThan(height, 60)
    }

    /// Now-must-fail: the highlight follows the reveal. A second reveal moves the
    /// fill to the second row's position, below the first, and leaves one band.
    func testTheHighlightMovesWithTheNextReveal() async throws {
        let children = kids(3)
        let firstModel = await revealed("issue_kid1", among: children)
        let firstRender = try await render(firstModel)
        let first = try XCTUnwrap(bands(tintedRows(firstRender)).first)
        let secondModel = await revealed("issue_kid3", among: children)
        let secondRender = try await render(secondModel)
        let second = try XCTUnwrap(bands(tintedRows(secondRender)).first)
        XCTAssertGreaterThan(second.first, first.last,
                             "issue_kid3's fill should sit wholly below issue_kid1's")
    }

    /// Collapsing the epic clears the highlight, and the rows it comes back to
    /// draw no fill. The first render is what keeps the last from passing on an
    /// empty pane: it must show the fill before the collapse.
    func testCollapsingTheEpicRemovesTheHighlight() async throws {
        let children = kids(3)
        let model = await revealed("issue_kid2", among: children)
        let before = try await render(model)
        XCTAssertEqual(bands(tintedRows(before)).count, 1)
        model.toggleExpansion(for: "epic_A")
        model.toggleExpansion(for: "epic_A")
        await waitForChildren(model)
        XCTAssertNil(model.highlightedItemID)
        let afterwards = try await render(model)
        XCTAssertTrue(tintedRows(afterwards).isEmpty)
    }

    // MARK: - A reveal scrolls to the row

    /// A row far below the fold. With no scroll the tinted row is off screen and
    /// the render shows no tint at all, so a band here means the pane scrolled
    /// to it as well as drawing it. The control is the same list with nothing
    /// revealed, which must show none.
    func testARevealScrollsAChildBelowTheFoldIntoView() async throws {
        let children = kids(80)
        let handOpened = await openedByHand(children)
        let control = try await render(handOpened)
        XCTAssertTrue(tintedRows(control).isEmpty)
        let revealedModel = await revealed("issue_kid80", among: children)
        let render = try await render(revealedModel)
        XCTAssertEqual(bands(tintedRows(render)).count, 1,
                       "the highlighted row is not on screen after the reveal")
    }

    // MARK: - When the scroll fires

    private func target(
        _ id: String?, count: Int = 1, children: [String: CockpitModel.ChildrenState]
    ) -> CockpitView.RevealScrollTarget? {
        CockpitView.revealScrollTarget(highlightedItemID: id, revealCount: count, children: children)
    }

    /// `reveal` can return while the epic's children are still loading. A target
    /// then would scroll to a row nothing draws yet, so there is none until the
    /// item is in a loaded list.
    func testThereIsNoScrollTargetUntilTheRowExists() {
        let kid = LibraryClient.ChildItem(id: "issue_kid", title: "t")
        XCTAssertNil(target("issue_kid", children: [:]))
        XCTAssertNil(target("issue_kid", children: ["epic_A": .loading]))
        XCTAssertNil(target("issue_kid", children: ["epic_A": .failed("x")]))
        XCTAssertNil(target("issue_kid", children: ["epic_A": .loaded([])]))
        XCTAssertEqual(target("issue_kid", children: ["epic_A": .loaded([kid])]),
                       CockpitView.RevealScrollTarget(itemID: "issue_kid", revealCount: 1))
    }

    func testThereIsNoScrollTargetWithoutAHighlight() {
        let kid = LibraryClient.ChildItem(id: "issue_kid", title: "t")
        XCTAssertNil(target(nil, children: ["epic_A": .loaded([kid])]))
    }

    /// Each reveal bumps the count, including a repeat of the same id, so the
    /// view scrolls again for it.
    func testEachRevealCountsEvenForTheSameItem() async {
        let children = kids(2)
        let model = await model(children: children)
        XCTAssertEqual(model.revealCount, 0)
        _ = await model.reveal(itemID: "issue_kid1")
        XCTAssertEqual(model.revealCount, 1)
        _ = await model.reveal(itemID: "issue_kid1")
        XCTAssertEqual(model.revealCount, 2)
        _ = await model.reveal(itemID: "issue_unknown")
        XCTAssertEqual(model.revealCount, 2, "a reveal that found no row must not count")
    }
}
