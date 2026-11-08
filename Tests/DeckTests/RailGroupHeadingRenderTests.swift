import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// E24's group heading render (CQ·183): an open heading draws the same
/// label style `sectionHeader("START")` draws with a disclosure chevron; a
/// folded heading draws its members' colour marks and their summed badge;
/// and at 44pt an open group draws the plain rule `sectionHeader` already
/// draws collapsed, while a folded one draws one square holding the marks
/// plus the badge.
///
/// Modeled on `StartPickerPopoverRenderTests`: a real window, captured with
/// `CGWindowListCreateImage(.null, .optionIncludingWindow, ...)` so the
/// window server's own compositing is what the pixels are read from, and
/// `NSApplication.shared` rather than `NSApp`, which is nil in a test
/// target.
///
/// FAILED ON THE CODE BEFORE THIS ITEM: `CrewGroup`, `RailView.groups` and
/// `RailGroupHeadingRow` did not exist at all, so this file could not
/// compile. Shown by saving `git diff` over every production file this
/// item touches (`RailView.swift`, `RailNesting.swift`, `SlateBadge.swift`,
/// `ThemeConfiguration.swift`, `ThemeStore.swift`, `ContentView.swift`) to
/// a patch, reverse-applying it with `git apply -R` and moving
/// `RailGroupHeading.swift` aside (`git stash` needs to write `refs/stash`,
/// outside this session's sandboxed write allowlist) — `swift build
/// --build-tests` then failed with "cannot find 'CrewGroup' in scope" and
/// "value of type 'ThemeConfiguration' has no member 'groups'" across this
/// file and its neighbours, before `git apply` and the file move restored
/// the change. See the PR body for the exact commands and output.
///
/// Set `DECK_GROUP_HEADING_RENDER_DIR` to keep the PNGs.
@MainActor
final class RailGroupHeadingRenderTests: XCTestCase {
    private let redAccent = RGB(red: 0.85, green: 0.1, blue: 0.1)
    private let greenAccent = RGB(red: 0.1, green: 0.75, blue: 0.1)

    private func crews() -> [Crew] {
        [Crew(id: "alpha", displayName: "Alpha"), Crew(id: "beta", displayName: "Beta"),
         Crew(id: "gamma", displayName: "Gamma")]
    }

    private func accent(_ ref: SessionRef) -> RGB {
        switch ref.name {
        case "alpha": return redAccent
        case "beta": return greenAccent
        default: return RGB(red: 0.3, green: 0.3, blue: 0.9)
        }
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = find(type, in: subview) { return found }
        }
        return nil
    }

    private struct Capture {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        let rowTop: CGFloat
        let rowHeight: CGFloat
    }

    /// Mounts `RailView` alone (not the whole `ContentView`) with one
    /// group and three crews, so the group heading is always the first
    /// row — the row `NSTableView.rect(ofRow: 0)` measures directly,
    /// regardless of what height this item's own padding resolves to.
    private func mount(group: CrewGroup, isCollapsed: Bool, badge: SessionState.AsksOpen?,
                       name: String) async throws -> Capture {
        let width: CGFloat = isCollapsed ? 44 : 216
        let view = RailView(
            crews: crews(),
            groups: [group],
            accent: accent,
            mark: { _ in .unpolled },
            isStopped: { _ in false },
            hasOpenGate: { _ in false },
            isTerminalOnly: { _ in false },
            asksOpen: { ref in group.members.contains(ref) ? badge : nil },
            themeMenu: { _ in AnyView(EmptyView()) },
            catalog: [],
            onLaunch: { _ in },
            appearance: .light,
            discoveredSessions: [],
            onMoveWindowToOwnSession: { _, _, _ in },
            onRequestRemoveCrew: { _ in },
            onRequestRemoveChild: { _, _ in },
            onSetCrewParent: { _, _ in },
            onStopDiscoveredSession: { _ in },
            onAdoptSession: { _, _ in },
            onRequestPromoteSession: { _ in },
            isCollapsed: isCollapsed,
            selection: .constant(nil))
        let windowSize = NSSize(width: width, height: 200)
        let controller = NSHostingController(rootView: view)
        if #available(macOS 14, *) { controller.sceneBridgingOptions = .all }
        controller.sizingOptions = .minSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: windowSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        window.contentViewController = controller
        window.setContentSize(windowSize)
        window.orderFront(nil)
        window.setContentSize(windowSize)
        let host = controller.view
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 800_000_000)
        host.layoutSubtreeIfNeeded()

        let frame = try XCTUnwrap(host.superview, "the window should have a theme frame")
        let table = try XCTUnwrap(find(NSTableView.self, in: host), "the rail's List should host an NSTableView")
        XCTAssertGreaterThan(table.numberOfRows, 0, "the heading should be the rail's first row")
        let row0 = table.convert(table.rect(ofRow: 0), to: nil)
        let rowTop = frame.bounds.height - row0.maxY

        let app = NSApplication.shared
        app.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let image = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]), "the window server returned no image")
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = frame.bounds.size
        if let dir = ProcessInfo.processInfo.environment["DECK_GROUP_HEADING_RENDER_DIR"] {
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        return Capture(rep: rep, scale: scale, rowTop: rowTop, rowHeight: row0.height)
    }

    private func pixel(_ c: Capture, _ xPt: CGFloat, _ yPt: CGFloat) -> RGB? {
        guard xPt >= 0, yPt >= 0, let color = c.rep.colorAt(x: Int(xPt * c.scale), y: Int(yPt * c.scale))?
            .usingColorSpace(.sRGB), color.alphaComponent > 0.5
        else { return nil }
        return RGB(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent))
    }

    private func closeEnough(_ a: RGB, _ b: RGB, tolerance: Double = 0.12) -> Bool {
        abs(a.red - b.red) < tolerance && abs(a.green - b.green) < tolerance && abs(a.blue - b.blue) < tolerance
    }

    /// Whether `target` appears anywhere in the heading row's own band.
    private func rowContains(_ c: Capture, _ target: RGB) -> Bool {
        for y in stride(from: c.rowTop, to: c.rowTop + c.rowHeight, by: 1) {
            for x in stride(from: CGFloat(0), to: CGFloat(c.rep.size.width), by: 1) {
                if let p = pixel(c, x, y), closeEnough(p, target) { return true }
            }
        }
        return false
    }

    /// The row's own darkest ink anywhere in its band — for diffing a
    /// capture that carries a badge against one that does not, rather than
    /// asserting an exact glyph shape.
    private func darkestInkCount(_ c: Capture, below luminance: Double) -> Int {
        var count = 0
        for y in stride(from: c.rowTop, to: c.rowTop + c.rowHeight, by: 1) {
            for x in stride(from: CGFloat(0), to: CGFloat(c.rep.size.width), by: 1) {
                if let p = pixel(c, x, y), p.relativeLuminance < luminance { count += 1 }
            }
        }
        return count
    }

    // MARK: - 216pt

    /// An open heading draws no member marks at all — those are a folded
    /// heading's own signal (E24: "Each member draws exactly as it does
    /// ungrouped" once open, so the heading itself carries nothing of
    /// theirs).
    func testOpenHeadingDrawsNoMemberMarksAt216pt() async throws {
        let group = CrewGroup(name: "Open", members: ["alpha", "beta"], folded: false)
        let c = try await mount(group: group, isCollapsed: false, badge: nil, name: "open-216")
        XCTAssertFalse(rowContains(c, redAccent), "an open heading should not draw alpha's mark")
        XCTAssertFalse(rowContains(c, greenAccent), "an open heading should not draw beta's mark")
    }

    /// A folded heading carries both members' colour marks.
    func testFoldedHeadingDrawsEveryMembersMarkAt216pt() async throws {
        let group = CrewGroup(name: "Folded", members: ["alpha", "beta"], folded: true)
        let c = try await mount(group: group, isCollapsed: false, badge: nil, name: "folded-216")
        XCTAssertTrue(rowContains(c, redAccent), "a folded heading should draw alpha's mark")
        XCTAssertTrue(rowContains(c, greenAccent), "a folded heading should draw beta's mark")
    }

    /// The summed badge draws extra ink a folded heading with none does
    /// not — diffed against a no-badge capture rather than pinning an
    /// exact glyph shape, the same reasoning `RailFirstRowPixelTests`
    /// gives for reading ink bands rather than OCR.
    func testFoldedHeadingDrawsTheSummedBadgeAt216pt() async throws {
        let group = CrewGroup(name: "Folded", members: ["alpha", "beta"], folded: true)
        let withBadge = try await mount(group: group, isCollapsed: false, badge: .count(5), name: "folded-216-badge")
        let withoutBadge = try await mount(group: group, isCollapsed: false, badge: nil, name: "folded-216-nobadge")
        let inkWith = darkestInkCount(withBadge, below: 0.55)
        let inkWithout = darkestInkCount(withoutBadge, below: 0.55)
        XCTAssertGreaterThan(inkWith, inkWithout,
                             "a badge of 5 should draw more dark ink (\(inkWith)) than no badge at all (\(inkWithout))")
    }

    // MARK: - 44pt

    /// An open group at 44pt draws the same rule `sectionHeader` draws
    /// collapsed for "START"/"OTHER SESSIONS" — a thin line distinct from
    /// the rail's own ground, never a square.
    func testOpenGroupDrawsTheSectionRuleAt44pt() async throws {
        let group = CrewGroup(name: "Open", members: ["alpha", "beta"], folded: false)
        let c = try await mount(group: group, isCollapsed: true, badge: nil, name: "open-44")
        let ground = try XCTUnwrap(pixel(c, 2, c.rowTop + c.rowHeight / 2), "no ground pixel found")
        var sawARuleDistinctFromTheGround = false
        for y in stride(from: c.rowTop, to: c.rowTop + c.rowHeight, by: 1) {
            if let p = pixel(c, c.rep.size.width / 2, y), !closeEnough(p, ground, tolerance: 0.03) {
                sawARuleDistinctFromTheGround = true
                break
            }
        }
        XCTAssertTrue(sawARuleDistinctFromTheGround, "an open group at 44pt should draw a rule distinct from the ground")
        XCTAssertFalse(rowContains(c, redAccent), "an open group's 44pt rule should carry no member marks")
    }

    /// A folded group at 44pt draws one square carrying its members' marks
    /// (both accent colours, inside the SAME row — a single-session dot
    /// never carries two colours), with the summed badge beside it.
    func testFoldedGroupDrawsOneSquareOfMarksAndTheBadgeAt44pt() async throws {
        let group = CrewGroup(name: "Folded", members: ["alpha", "beta"], folded: true)
        let withBadge = try await mount(group: group, isCollapsed: true, badge: .count(5), name: "folded-44-badge")
        let withoutBadge = try await mount(group: group, isCollapsed: true, badge: nil, name: "folded-44-nobadge")

        XCTAssertTrue(rowContains(withBadge, redAccent), "the folded square should carry alpha's mark")
        XCTAssertTrue(rowContains(withBadge, greenAccent), "the folded square should carry beta's mark")

        let inkWith = darkestInkCount(withBadge, below: 0.55)
        let inkWithout = darkestInkCount(withoutBadge, below: 0.55)
        XCTAssertGreaterThan(inkWith, inkWithout,
                             "a badge of 5 should draw more dark ink (\(inkWith)) beside the square than none (\(inkWithout))")
    }
}
