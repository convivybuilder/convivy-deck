import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What the steward's board DRAWS with its corrections queue, at the two
/// widths CQ·170 (issue_01M5CRQCRX0JQSBH4918VB4QD0) names and in both
/// appearances. `StewardBoardPanelsTests` pins the panel list; a list that
/// names the queue passes whether or not the view draws it.
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

    private func render(
        _ panelIDs: [String], model: CockpitModel, width: CGFloat = 320, appearance: Appearance = .light
    ) async throws -> NSBitmapImageRep {
        let view = CockpitView(
            model: model, unresolvedReason: nil, appearance: appearance,
            onSelectCorrection: { _ in }, title: "Board", panelIDs: panelIDs,
            documents: .init(paths: ["\(TestHost.homeRoot)/Convivy/crews/steward/CLAUDE.md"], onOpen: { _ in })
        )
        .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).json")))
        .background(appearance == .dark ? Color(white: 0.145) : Color(white: 0.98))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 640))
        host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = host.appearance
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

    /// The board with the queue draws more than the same board without it,
    /// at both widths and in both appearances. Setting `DECK_SNAPSHOT_DIR`
    /// also writes each PNG for a look.
    func testTheBoardDrawsItsQueueRows() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let model = await model()
                let withQueue = try await render(CockpitView.boardPanelIDs, model: model, width: width, appearance: appearance)
                let withoutQueue = try await render(
                    CockpitView.boardPanelIDs.filter { $0 != CockpitView.correctionsQueuePanelID },
                    model: model, width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedRows(withQueue), inkedRows(withoutQueue) + 20,
                                     "the queue drew no extra rows at \(width)pt, \(appearance)")
                if let dir = ProcessInfo.processInfo.environment["DECK_SNAPSHOT_DIR"],
                   let png = withQueue.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("board-\(Int(width))-\(appearance).png"))
                }
            }
        }
    }

    /// A blocked queue item whose one prerequisite is `{item, missing:
    /// true}` draws strictly more rows than the same item with neither
    /// `blocked` nor a prerequisite — the lock mark and the "Needs first:
    /// \(CockpitView.missingPrerequisiteLabel)" caption `correctionsQueueContent`
    /// draws for a queue row, at both widths and in both appearances.
    func testABlockedQueueItemDrawsItsLockMarkAndNeedsFirstCaption() async throws {
        func model(blocked: Bool, prerequisites: [LibraryClient.PrerequisiteEntry]) async -> CockpitModel {
            let model = CockpitModel()
            let queue = LibraryClient.CorrectionsQueue(
                items: [
                    LibraryClient.QueueItem(
                        id: "issue_blocked", title: "Blocked without the prerequisite Deck can show",
                        type: "task", severity: "high", state: "open", claimedBy: nil, claimExpired: false,
                        prerequisites: prerequisites, blocked: blocked),
                ],
                total: 1, truncated: false, childParents: [:])
            model.fetchCourse = { _, _ in nil }
            model.fetchQueue = { _, _ in queue }
            model.fetchEpics = { _, _ in [] }
            await model.refresh(target: TestHost.unreachableTarget, product: product)
            return model
        }
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let plainRep = try await render(
                    [CockpitView.correctionsQueuePanelID],
                    model: await model(blocked: false, prerequisites: []), width: width, appearance: appearance)
                let blockedRep = try await render(
                    [CockpitView.correctionsQueuePanelID],
                    model: await model(blocked: true, prerequisites: [.missingItem(id: "missing_1")]),
                    width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedRows(blockedRep), inkedRows(plainRep),
                                     "the lock mark and \"Needs first:\" caption drew no extra rows at \(width)pt, \(appearance)")
            }
        }
    }
}
