import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What the steward's board DRAWS with its corrections queue, hosted at the
/// narrow 320pt column width. `StewardBoardPanelsTests` pins the panel list; a
/// list that names the queue passes whether or not the view draws it.
@MainActor
final class StewardBoardQueueRenderTests: XCTestCase {
    private let product = "steward"

    private func model() async -> CockpitModel {
        let model = CockpitModel()
        let queue = LibraryClient.CorrectionsQueue(
            items: [
                LibraryClient.QueueItem(id: "issue_a", title: "Rotate the two mis-named Anthropic keys onto accurate names",
                                        type: "task", severity: nil, state: "open", claimedBy: nil, claimExpired: false),
                LibraryClient.QueueItem(id: "issue_b", title: "Give substrate's checks workflow least-privilege permissions",
                                        type: "improvement", severity: nil, state: "open", claimedBy: nil, claimExpired: false),
            ],
            total: 2, truncated: false, childParents: [:])
        model.fetchCourse = { _, _ in nil }
        model.fetchQueue = { _, _ in queue }
        model.fetchEpics = { _, _ in [] }
        await model.refresh(target: TestHost.unreachableTarget, product: product)
        return model
    }

    private func render(_ panelIDs: [String], model: CockpitModel) async throws -> NSBitmapImageRep {
        let view = CockpitView(
            model: model, unresolvedReason: nil, appearance: .light,
            onSelectCorrection: { _ in }, title: "Board", panelIDs: panelIDs,
            documents: .init(paths: ["\(TestHost.homeRoot)/Convivy/crews/steward/CLAUDE.md"], onOpen: { _ in })
        )
        .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).json")))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: 320, height: 640))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        defer { window.orderOut(nil) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixel rows holding anything other than the row's own background.
    private func inkedRows(_ rep: NSBitmapImageRep) -> Int {
        (0..<rep.pixelsHigh).filter { y in
            guard let base = rep.colorAt(x: 0, y: y) else { return false }
            return (0..<rep.pixelsWide).contains { x in
                guard let c = rep.colorAt(x: x, y: y) else { return false }
                return abs(c.redComponent - base.redComponent) + abs(c.greenComponent - base.greenComponent)
                    + abs(c.blueComponent - base.blueComponent) > 0.2
            }
        }.count
    }

    /// The board with the queue draws more than the same board without it.
    /// Setting `DECK_SNAPSHOT_DIR` also writes the PNG for a look.
    func testTheBoardDrawsItsQueueRows() async throws {
        let model = await model()
        let withQueue = try await render(CockpitView.boardPanelIDs, model: model)
        let withoutQueue = try await render(
            CockpitView.boardPanelIDs.filter { $0 != CockpitView.correctionsQueuePanelID }, model: model)
        XCTAssertGreaterThan(inkedRows(withQueue), inkedRows(withoutQueue) + 20)
        if let dir = ProcessInfo.processInfo.environment["DECK_SNAPSHOT_DIR"],
           let png = withQueue.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("board-320.png"))
        }
    }
}
