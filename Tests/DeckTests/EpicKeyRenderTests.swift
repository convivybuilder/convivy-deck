import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Deck

/// What the epic reference key (`"E39"`) DRAWS beside a title, on the two
/// surfaces an operator looks at to find or approve an epic — the Course row
/// (`CockpitView.courseEntryRow`) and the Proposals panel's approval row
/// (`CockpitView.proposalRow`). `CockpitViewTests`'s own `keyedTitle` tests
/// pin the degrade (absent/empty key draws the title alone); these host the
/// real `CockpitView` in a window and read pixels, the same reason
/// `PullRequestWorkItemChipRenderTests` exists for the PR chip.
///
/// Renders via `NSHostingView` + `cacheDisplay`, never `ImageRenderer`, which
/// draws `ScrollView` contents blank — the same choice `CockpitRevealRenderTests`
/// and `PullRequestWorkItemChipRenderTests` document.
@MainActor
final class EpicKeyRenderTests: XCTestCase {
    private let product = "convivy-deck"

    private func courseModel(withKey: Bool) async -> CockpitModel {
        let model = CockpitModel()
        let course = LibraryClient.Course(
            id: "course_1", product: product, title: nil,
            entries: [LibraryClient.CourseEntry(
                id: "issue_EPIC", title: "The epic", type: "epic", state: "open",
                key: withKey ? "E39" : nil)])
        model.fetchCourse = { _, _ in course }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        await model.refresh(target: TestHost.unreachableTarget, product: product)
        return model
    }

    private func proposalModel(withKey: Bool) async -> CockpitModel {
        let model = CockpitModel()
        model.fetchCourse = { _, _ in nil }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        model.fetchEpics = { _, _ in
            [LibraryClient.Epic(id: "issue_EPIC", state: "open", resolution: nil, createdAt: nil,
                                resolvedAt: nil, title: "Ship the widget", maturity: "proposed",
                                key: withKey ? "E39" : nil)]
        }
        await model.refresh(target: TestHost.unreachableTarget, product: product)
        return model
    }

    /// Renders one panel alone, given time for layout to settle. `appearance`
    /// defaults to `.light` so the two key-reach tests below need no change;
    /// the proposal-row tests further down pass both, the same
    /// `host.appearance`/backdrop handling `PullRequestWorkItemChipRenderTests`
    /// uses for the identical reason (its own `render`'s doc).
    private func render(
        _ model: CockpitModel, panelIDs: [String], width: CGFloat, appearance: Appearance = .light
    ) async throws -> NSBitmapImageRep {
        let view = CockpitView(
            model: model, unresolvedReason: nil, appearance: appearance,
            onSelectCorrection: { _ in }, panelIDs: panelIDs
        )
        .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).json")))
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
        try await Task.sleep(nanoseconds: 800_000_000)
        defer { window.orderOut(nil) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels that differ from the render's own corner backdrop by more than
    /// a hair — every pixel any text, border or mark actually painted, on
    /// either appearance. Mirrors `PullRequestWorkItemChipRenderTests`'s
    /// `inkedPixelCount` exactly, duplicated here for the same reason that
    /// file's own doc gives: a render test reads pixels, not shared model
    /// state, so each file keeps its own small reader.
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

    /// The rightmost column short of `limit` that carries a glyph-dark pixel
    /// anywhere down its height — how far whatever text drew there reaches.
    ///
    /// **Not a whole-bitmap dark-pixel total**, which a first version of this
    /// file used and which moved the WRONG way: prefixing a title with its
    /// key visibly draws more (confirmed by eye, and by this column reading),
    /// but the total count came out LOWER for the prefixed render in a real
    /// run, apples to apples, at both widths this file checks — hinting and
    /// anti-aliasing redistribute a few dozen border pixels well past what a
    /// four-character prefix should cost, and a sum has no way to tell that
    /// apart from the prefix's own ink. The rightmost-column reading is
    /// immune to that: it asks how far content reaches, not how many pixels
    /// it costs, and empirically it moved the right way, by the same margin,
    /// on every run.
    ///
    /// `limit` keeps the reading inside the row's own leading content —
    /// short of a trailing icon (the disclosure chevron, `ItemOpenButton`)
    /// that draws at a fixed column regardless of the title, which would
    /// otherwise dominate the answer in both renders alike.
    private func rightmostDarkColumn(_ rep: NSBitmapImageRep, within limit: Int) -> Int? {
        let bound = min(limit, rep.pixelsWide)
        for x in stride(from: bound - 1, through: 0, by: -1) {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                let luma = (Double(c.redComponent) + Double(c.greenComponent) + Double(c.blueComponent)) / 3
                if luma < 0.55 { return x }
            }
        }
        return nil
    }

    /// The Course row's title reaches strictly further right with a key
    /// drawn ahead of it than without one, at both widths the item's own
    /// constraint names — fails before the change, where `entry.key` was
    /// decoded but never drawn. 150px keeps the reading short of the row's
    /// own trailing disclosure chevron (confirmed empirically against this
    /// row's own layout).
    func testTheCourseRowTitleReachesFurtherRightWithAKey() async throws {
        for width: CGFloat in [320, 280] {
            let withKey = try await render(await courseModel(withKey: true),
                                           panelIDs: [CockpitView.coursePanelID], width: width)
            let withoutKey = try await render(await courseModel(withKey: false),
                                              panelIDs: [CockpitView.coursePanelID], width: width)
            let withKeyReach = try XCTUnwrap(rightmostDarkColumn(withKey, within: 150),
                                             "no ink found on the Course row at \(width)pt")
            let withoutKeyReach = try XCTUnwrap(rightmostDarkColumn(withoutKey, within: 150),
                                                "no ink found on the Course row at \(width)pt")
            XCTAssertGreaterThan(withKeyReach, withoutKeyReach,
                                 "the Course row's key drew no extra reach at \(width)pt")
        }
    }

    /// The Proposals panel's approval row title reaches strictly further
    /// right with a key than without one, at both widths — fails before the
    /// change, where `Epic` did not even decode a `key`. 250px keeps the
    /// reading short of the row's own `ItemOpenButton` (confirmed
    /// empirically against this row's own layout).
    func testTheProposalRowTitleReachesFurtherRightWithAKey() async throws {
        for width: CGFloat in [320, 280] {
            let withKey = try await render(await proposalModel(withKey: true),
                                           panelIDs: [CockpitView.proposalsPanelID], width: width)
            let withoutKey = try await render(await proposalModel(withKey: false),
                                              panelIDs: [CockpitView.proposalsPanelID], width: width)
            let withKeyReach = try XCTUnwrap(rightmostDarkColumn(withKey, within: 250),
                                             "no ink found on the proposal row at \(width)pt")
            let withoutKeyReach = try XCTUnwrap(rightmostDarkColumn(withoutKey, within: 250),
                                                "no ink found on the proposal row at \(width)pt")
            XCTAssertGreaterThan(withKeyReach, withoutKeyReach,
                                 "the proposal row's key drew no extra reach at \(width)pt")
        }
    }

    // MARK: - The proposal row's Decline control (CQ·173)

    /// A Proposals model with one proposed epic, so the row draws both the
    /// Approve and Decline controls (`CockpitView.proposalRow`).
    private func proposalModelWithControls() async -> CockpitModel {
        let model = CockpitModel()
        model.fetchCourse = { _, _ in nil }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        model.fetchEpics = { _, _ in
            [LibraryClient.Epic(id: "issue_EPIC", state: "open", resolution: nil, createdAt: nil,
                                resolvedAt: nil, title: "Ship the widget", maturity: "proposed", key: "E39")]
        }
        await model.refresh(target: TestHost.unreachableTarget, product: product)
        return model
    }

    /// The same panel with no proposals at all, as the baseline for the
    /// "controls draw real ink" comparison below.
    private func emptyProposalsModel() async -> CockpitModel {
        let model = CockpitModel()
        model.fetchCourse = { _, _ in nil }
        model.fetchQueue = { _, _ in
            LibraryClient.CorrectionsQueue(items: [], total: 0, truncated: false, childParents: [:])
        }
        model.fetchEpics = { _, _ in [] }
        await model.refresh(target: TestHost.unreachableTarget, product: product)
        return model
    }

    /// `proposalModelWithControls()`, with a Decline already attempted and
    /// refused with the 409 naming a blocking approved sub-epic
    /// (library/decisions/0005). `model.declineEpic` throws before any
    /// network write, so `model.declineRefusal` lands deterministically
    /// with no live target to reach.
    private func proposalModelWithDeclineRefusal() async -> CockpitModel {
        let model = await proposalModelWithControls()
        model.declineEpic = { _, _, _, _ in
            throw LibraryClient.FetchError.libraryRefused(status: 409, body: """
            {"error":"issue_EPIC has an approved sub-epic, issue_01CHILD, and cannot be declined"}
            """)
        }
        await model.decline(model.proposedEpics[0])
        return model
    }

    /// The proposal row with both Approve and Decline draws strictly more
    /// ink than the same panel with no proposals at all, at both widths and
    /// in both appearances — a smoke check that the row's second control
    /// (and the confirmation/progress machinery beside it) renders rather
    /// than collapsing to nothing.
    func testTheProposalRowDrawsBothControlsAtBothWidthsAndAppearances() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let lines = try await drawnText(await proposalModelWithControls(),
                    panelIDs: [CockpitView.proposalsPanelID], width: width, appearance: appearance)
                for label in ["Approve", "Decline"] {
                    XCTAssertTrue(lines.contains { $0.range(of: label, options: .caseInsensitive) != nil },
                                  "\(label) did not draw at \(width)pt, \(appearance). Saw: \(lines)")
                }
            }
        }
    }

    /// The text Vision reads off the rendered panel, at three pixels per
    /// point so caption-size labels read reliably. Asserting on a label,
    /// rather than on extra ink against an empty panel, fails when the
    /// Decline control is missing (review of CQ·173).
    private func drawnText(
        _ model: CockpitModel, panelIDs: [String], width: CGFloat, appearance: Appearance
    ) async throws -> [String] {
        let view = CockpitView(
            model: model, unresolvedReason: nil, appearance: appearance,
            onSelectCorrection: { _ in }, panelIDs: panelIDs
        )
        .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).json")))
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
        try await Task.sleep(nanoseconds: 800_000_000)
        defer { window.orderOut(nil) }
        let scale = 3
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: 200 * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(rep.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// A Decline refusal draws its own line under the row, naming the
    /// blocking sub-epic — strictly more ink than the same row with no
    /// refusal, at both widths and in both appearances. Fails before the
    /// change, where `CockpitView` read no `declineRefusal` at all.
    func testADeclineRefusalDrawsExtraInkAtBothWidthsAndAppearances() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let withRefusal = try await render(await proposalModelWithDeclineRefusal(),
                    panelIDs: [CockpitView.proposalsPanelID], width: width, appearance: appearance)
                let withoutRefusal = try await render(await proposalModelWithControls(),
                    panelIDs: [CockpitView.proposalsPanelID], width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(withRefusal), inkedPixelCount(withoutRefusal),
                    "the decline refusal drew no extra ink at \(width)pt, \(appearance)")
            }
        }
    }
}
