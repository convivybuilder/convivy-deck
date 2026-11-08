import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// CQ·188's two rail refinements to a group, plus CQ·191's removal of its
/// third: the fold chevron leads the heading's name for both open and
/// folded headings, a member of an open group indents
/// `RailGroupHeadingRow.memberIndent` beyond an ungrouped crew, and — since
/// the operator ruled the indent alone is enough (2026-10-25) — an open group's
/// members draw no vertical guide line beside them at all.
///
/// Modeled on `RailGroupHeadingRenderTests`: a real window, captured with
/// `CGWindowListCreateImage(.null, .optionIncludingWindow, ...)` so the
/// window server's own compositing is what the pixels are read from.
///
/// Set `DECK_GROUP_LAYOUT_RENDER_DIR` to keep the PNGs.
@MainActor
final class RailGroupLayoutRenderTests: XCTestCase {
    private let redAccent = RGB(red: 0.85, green: 0.1, blue: 0.1)
    private let greenAccent = RGB(red: 0.1, green: 0.75, blue: 0.1)

    /// Alpha and Beta join the group under test; Gamma stays ungrouped and
    /// draws after it.
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
        /// Every row's own rect, top-left origin, in the same space pixels
        /// are read from — row 0 is always the heading.
        let rowRects: [NSRect]
    }

    /// Mounts `RailView` with one group over `crews()`, at 216pt.
    private func mount(group: CrewGroup, name: String) async throws -> Capture {
        try await mount(group: group, asksOpen: { _ in nil }, name: name)
    }

    /// `mount(group:name:)`, with a per-session Slate reading — CQ·192's
    /// render test needs alpha and beta to each carry their own count, so
    /// the heading's summed total and a member row's own badge both draw
    /// in the same capture.
    private func mount(group: CrewGroup, asksOpen: @escaping (SessionRef) -> SessionState.AsksOpen?,
                       name: String) async throws -> Capture {
        let width: CGFloat = 216
        let view = RailView(
            crews: crews(),
            groups: [group],
            accent: accent,
            mark: { _ in .unpolled },
            isStopped: { _ in false },
            hasOpenGate: { _ in false },
            isTerminalOnly: { _ in false },
            asksOpen: asksOpen,
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
            isCollapsed: false,
            selection: .constant(nil))
        let windowSize = NSSize(width: width, height: 220)
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

        var rowRects: [NSRect] = []
        for row in 0..<table.numberOfRows {
            let converted = table.convert(table.rect(ofRow: row), to: nil)
            let top = frame.bounds.height - converted.maxY
            rowRects.append(NSRect(x: converted.minX, y: top, width: converted.width, height: converted.height))
        }

        let app = NSApplication.shared
        app.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let image = try XCTUnwrap(CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]), "the window server returned no image")
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = frame.bounds.size
        if let dir = ProcessInfo.processInfo.environment["DECK_GROUP_LAYOUT_RENDER_DIR"] {
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        return Capture(rep: rep, scale: scale, rowRects: rowRects)
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

    /// The leftmost x within `rect` carrying `target` (within tolerance), or
    /// nil if it never appears there.
    private func leftmostX(_ c: Capture, matching target: RGB, in rect: NSRect) -> CGFloat? {
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
            for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
                if let p = pixel(c, x, y), closeEnough(p, target) { return x }
            }
        }
        return nil
    }

    /// Whether any pixel darker than `luminance` appears anywhere in `rect`.
    private func hasDarkInk(_ c: Capture, in rect: NSRect, below luminance: Double = 0.55) -> Bool {
        for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
                if let p = pixel(c, x, y), p.relativeLuminance < luminance { return true }
            }
        }
        return false
    }

    /// Whether a vertical guide line runs through `rect` at `x`: pixels there
    /// differ from the row's own ground both 8pt above and 8pt below the
    /// row's middle, the same differential
    /// `RailGroupHeadingRenderTests.testOpenGroupDrawsTheSectionRuleAt44pt`
    /// already uses to tell a hairline from a plain background. Sampling off
    /// the middle is what separates the line from an ungrouped crew's own
    /// dot, which sits in this same column but is 10pt tall and centred in
    /// its row; a scan of the whole height read that dot as a guide line.
    /// The row's very edges are not sampled, because the table's row rect is
    /// taller than the overlay the line is drawn in.
    private func hasGuideLine(_ c: Capture, at x: CGFloat, in rect: NSRect) -> Bool {
        guard let ground = pixel(c, rect.maxX - 5, rect.minY + rect.height / 2) else { return false }
        let edges = [rect.midY - 8, rect.midY + 8]
        return edges.allSatisfy { y in
            guard let p = pixel(c, x, y) else { return false }
            return !closeEnough(p, ground, tolerance: 0.03)
        }
    }

    /// The chevron's centre x as drawn: the middle of the first run of ink
    /// in the heading row (row 0), which the chevron leads. Measured, rather
    /// than read from `RailGroupHeadingRow.chevronCenterX`, because "the line
    /// sits directly under the chevron" is a claim about two drawn things,
    /// and the constant was 2pt off what the window server drew.
    private func measuredChevronCenterX(_ c: Capture) throws -> CGFloat {
        let heading = c.rowRects[0]
        guard let ground = pixel(c, heading.maxX - 5, heading.minY + heading.height / 2) else {
            throw XCTSkip("no ground pixel in the heading row")
        }
        // Every inked column left of the name (which starts past x 30), over
        // the heading row widened 4pt each way. The table's row rect sits a
        // couple of points off the drawn glyph, and stopping at the first
        // column without ink inside it measured a chevron drawn across x 19
        // to 26 as centred at 20.5.
        var inked: [CGFloat] = []
        for x in stride(from: heading.minX, to: heading.minX + 30, by: 1) {
            // The default 0.12 tolerance, not the hairline 0.03: the chevron is
            // solid secondary-label ink, and 0.03 also caught faint window-edge
            // pixels near x 3, which stretched the span to a 14.5 centre.
            let hit = stride(from: heading.minY - 4, to: heading.maxY + 4, by: 1).contains { y in
                guard let p = pixel(c, x, y) else { return false }
                return !closeEnough(p, ground)
            }
            if hit { inked.append(x) }
        }
        let first = try XCTUnwrap(inked.first, "the heading should draw its chevron first")
        return (first + inked.last!) / 2
    }

    /// The leftmost x within `rect` that differs from the row's own ground
    /// (sampled at its own trailing edge, empty for every row in this
    /// fixture) — a row's first drawn content, whatever it is. The same
    /// differential `hasGuideLine` uses, rather than matching a row's
    /// identity dot to its raw accent colour: `SessionDotView` solves that
    /// colour's lightness against the row's surface (`ThemeRecipe.dotInk`),
    /// so the rendered dot is not always bit-identical to the accent it was
    /// given.
    private func firstContentX(_ c: Capture, in rect: NSRect) -> CGFloat? {
        guard let ground = pixel(c, rect.maxX - 5, rect.minY + rect.height / 2) else { return nil }
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
            for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
                if let p = pixel(c, x, y), !closeEnough(p, ground, tolerance: 0.03) { return x }
            }
        }
        return nil
    }

    // MARK: - 1. The chevron leads the name (CQ·188 bullet 1)

    /// A folded heading's marks used to draw first and the chevron last;
    /// moved to the leading edge, the marks must now start to the right of
    /// the chevron's own reserved slot rather than right at the row's own
    /// padding.
    func testFoldedHeadingChevronLeadsItsMembersMarksAt216pt() async throws {
        let group = CrewGroup(name: "Folded", members: ["alpha", "beta"], folded: true)
        let c = try await mount(group: group, name: "chevron-folded")
        let headingRow = c.rowRects[0]
        let redX = try XCTUnwrap(leftmostX(c, matching: redAccent, in: headingRow),
                                 "the folded heading should draw alpha's mark")
        let chevronSlotTrailingEdge = RailGroupHeadingRow.chevronCenterX + RailGroupHeadingRow.chevronSlotWidth / 2
        XCTAssertGreaterThan(redX, chevronSlotTrailingEdge,
                             "alpha's mark (x \(redX)) should sit to the right of the chevron's own slot "
                             + "(trailing edge x \(chevronSlotTrailingEdge)) now that the chevron leads it")
    }

    /// An open heading's chevron used to be its last element, right before
    /// the row's own trailing padding. Moved to the leading edge (with no
    /// badge in this fixture), that trailing band now draws nothing at all.
    func testOpenHeadingChevronIsNoLongerTrailingAt216pt() async throws {
        let group = CrewGroup(name: "Open", members: ["alpha", "beta"], folded: false)
        let c = try await mount(group: group, name: "chevron-open")
        let headingRow = c.rowRects[0]
        let trailingBand = NSRect(x: headingRow.maxX - 20, y: headingRow.minY,
                                  width: 20, height: headingRow.height)
        XCTAssertFalse(hasDarkInk(c, in: trailingBand),
                       "the open heading should draw no ink in its trailing band once the chevron leads")
    }

    // MARK: - 2. No guide line, and the member indent alone (CQ·191, CQ·188 bullet 2)

    /// Neither of the open group's own member rows draws a vertical line in
    /// the chevron column beside it — the 8pt member indent is enough on
    /// its own (the operator, 2026-10-25).
    ///
    /// FAILS ON ORIGIN/MAIN (74e7be70, before this item): `RailOpenGroupGuide`
    /// drew a 1.5pt line at the chevron's own centre x down both member
    /// rows, so `hasGuideLine` read true there.
    func testOpenGroupDrawsNoGuideLineBesideItsMembersAt216pt() async throws {
        let group = CrewGroup(name: "Open", members: ["alpha", "beta"], folded: false)
        let c = try await mount(group: group, name: "guide-absent")
        XCTAssertEqual(c.rowRects.count, 4, "precondition: heading, alpha, beta, then gamma ungrouped")
        let x = try measuredChevronCenterX(c)
        for member in [1, 2] {
            XCTAssertFalse(hasGuideLine(c, at: x, in: c.rowRects[member]),
                           "member row \(member) should carry no guide line at the chevron's x \(x) "
                           + "(row rect \(c.rowRects[member]), heading \(c.rowRects[0]), scale \(c.scale))")
        }
    }

    /// An open group's member indents `RailGroupHeadingRow.memberIndent`
    /// beyond an ungrouped crew — alpha's own row content starts that much
    /// further right than gamma's.
    func testOpenGroupMembersIndentBeyondAnUngroupedCrewAt216pt() async throws {
        let group = CrewGroup(name: "Open", members: ["alpha", "beta"], folded: false)
        let c = try await mount(group: group, name: "member-indent")
        // Start past the chevron column, so the scan lands on alpha's own
        // dot rather than anything the heading drew in that column above it.
        let pastChevron = try measuredChevronCenterX(c) + 2
        let alphaRow = c.rowRects[1]
        let alphaX = try XCTUnwrap(
            firstContentX(c, in: NSRect(x: pastChevron, y: alphaRow.minY,
                                        width: alphaRow.maxX - pastChevron, height: alphaRow.height)),
            "alpha's own row should draw something")
        let gammaX = try XCTUnwrap(firstContentX(c, in: c.rowRects[3]), "gamma's own row should draw something")
        XCTAssertEqual(alphaX - gammaX, RailGroupHeadingRow.memberIndent, accuracy: 2,
                       "alpha, an open group's member, should indent \(RailGroupHeadingRow.memberIndent)pt "
                       + "beyond gamma (alpha's content at x \(alphaX), gamma's at x \(gammaX))")
    }

    // MARK: - 3. The group total sits beside the name, not in the badge column (CQ·192)

    /// Every column within `rect` where `a` and `b` differ — the pixels a
    /// changed Slate reading draws that an unchanged one does not. Diffing
    /// two captures isolates exactly the new ink a badge adds, whatever the
    /// group name's own width happens to render as.
    private func inkDiffColumns(_ a: Capture, _ b: Capture, in rect: NSRect) -> [CGFloat] {
        var columns: [CGFloat] = []
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
            var differs = false
            for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
                let pa = pixel(a, x, y)
                let pb = pixel(b, x, y)
                if let pa, let pb {
                    if !closeEnough(pa, pb, tolerance: 0.03) { differs = true; break }
                } else if (pa == nil) != (pb == nil) {
                    differs = true; break
                }
            }
            if differs { columns.append(x) }
        }
        return columns
    }

    /// CQ·192: the heading's summed total draws right after the group
    /// name, not in the trailing column alpha's own count uses — diffs a
    /// capture where alpha and beta each carry a Slate reading against one
    /// where neither does, in both the heading row and alpha's own row, so
    /// this isolates exactly the new ink each badge adds rather than
    /// pinning a glyph shape or the name's rendered width.
    ///
    /// FAILS ON MAIN: there, the heading's badge draws after the trailing
    /// `Spacer`, inside the same trailing column alpha's own badge uses.
    func testGroupTotalDrawsNearTheNameAndLeftOfTheTrailingBadgeColumnAt216pt() async throws {
        let group = CrewGroup(name: "Open", members: ["alpha", "beta"], folded: false)
        let withBadges: (SessionRef) -> SessionState.AsksOpen? = { ref in
            switch ref.name {
            case "alpha": return .count(2)
            case "beta": return .count(1)
            default: return nil
            }
        }
        let withBadge = try await mount(group: group, asksOpen: withBadges, name: "total-with-badge")
        let withoutBadge = try await mount(group: group, asksOpen: { _ in nil }, name: "total-without-badge")
        XCTAssertEqual(withBadge.rowRects.count, 4, "precondition: heading, alpha, beta, then gamma ungrouped")

        // The trailing column is wherever alpha's own count draws, measured
        // rather than assumed: a fixed `maxX - 24` guessed 192 while the
        // count draws from 188, which failed the fixed build too.
        let alphaRow = withBadge.rowRects[1]
        let alphaDiff = inkDiffColumns(withBadge, withoutBadge, in: alphaRow)
        let alphaMinX = try XCTUnwrap(alphaDiff.min(), "alpha's own badge (2) drew no new ink")
        XCTAssertGreaterThan(alphaMinX, alphaRow.midX,
                             "precondition: alpha's own badge (new ink at x \(alphaMinX)) draws in the row's "
                             + "trailing half, the column the heading's total must stay clear of")

        let heading = withBadge.rowRects[0]
        let headingDiff = inkDiffColumns(withBadge, withoutBadge, in: heading)
        let headingMaxX = try XCTUnwrap(headingDiff.max(), "the heading's summed total (3) drew no new ink")
        XCTAssertLessThan(headingMaxX, alphaMinX - 8,
                          "the heading's total (rightmost new ink at x \(headingMaxX)) should sit well left "
                          + "of the trailing badge column alpha's own count draws in (from x \(alphaMinX))")
    }

    // MARK: - 4. The name ink is brighter, and the total reads as words (CQ·195)

    /// The largest luminance distance from `ground` of any pixel in
    /// `rect` — how strongly the ink there stands off its own backing,
    /// whichever way (dark ink on a light rail or light ink on a dark one).
    private func peakContrast(_ c: Capture, in rect: NSRect, against ground: RGB) -> Double {
        var peak = 0.0
        for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
                guard let p = pixel(c, x, y) else { continue }
                peak = max(peak, abs(p.relativeLuminance - ground.relativeLuminance))
            }
        }
        return peak
    }

    /// CQ·195: the group name drew `.tertiary`, which the operator called
    /// "very hard to read" (2026-10-25); it now draws `.secondary`, the
    /// same style the heading's own chevron already uses. The check is
    /// relative to that chevron, measured against the row's own backing,
    /// so it holds on a light or a dark rail: a darkest-pixel threshold
    /// passed on main too, since on a dark rail the darkest pixel is the
    /// ground itself.
    ///
    /// FAILS ON ORIGIN/MAIN (a823b68d, before this item): there the name's
    /// `.tertiary` ink stands off the backing far less than the chevron's.
    func testGroupNameInkIsBrighterThanTertiaryAt216pt() async throws {
        let group = CrewGroup(name: "Open", members: ["alpha", "beta"], folded: false)
        let c = try await mount(group: group, name: "name-ink")
        let heading = c.rowRects[0]
        let ground = try XCTUnwrap(pixel(c, heading.maxX - 4, heading.midY), "the heading's backing")
        // x 30 is the bound `measuredChevronCenterX` scans up to.
        let chevronRegion = NSRect(x: heading.minX, y: heading.minY, width: 30, height: heading.height)
        let nameRegion = NSRect(x: heading.minX + 30, y: heading.minY,
                                width: heading.width - 30, height: heading.height)
        let chevron = peakContrast(c, in: chevronRegion, against: ground)
        let name = peakContrast(c, in: nameRegion, against: ground)
        XCTAssertGreaterThan(chevron, 0.05, "precondition: the chevron should draw visible ink")
        XCTAssertGreaterThanOrEqual(name, chevron * 0.8,
                                    "the name's ink (peak contrast \(name)) should stand off the backing about "
                                    + "as strongly as the .secondary chevron's (\(chevron)), not .tertiary's fainter")
    }

    /// A long group name must truncate at 216pt before the heading's own
    /// total does: `totalText(for:)`'s words need more width than the bare
    /// digit they replaced, which is what `.fixedSize()` on the total,
    /// against the name's own `lineLimit(1)`, is for.
    ///
    /// FAILS ON ORIGIN/MAIN (a823b68d, before this item): there the total
    /// is a bare digit ("10"), narrow enough that this long a name already
    /// leaves it room with no layout priority to enforce — the new ink
    /// this diff finds is `"·10"`, too narrow a span to be the worded
    /// phrase this item adds.
    func testLongGroupNameTruncatesWhileTheWordedTotalStillDrawsInsideTheRowAt216pt() async throws {
        let group = CrewGroup(name: "Growth Retention And Expansion Working Crew",
                              members: ["alpha", "beta"], folded: false)
        let withAsks: (SessionRef) -> SessionState.AsksOpen? = { ref in
            switch ref.name {
            case "alpha": return .count(7)
            case "beta": return .count(3)
            default: return nil
            }
        }
        let withTotal = try await mount(group: group, asksOpen: withAsks, name: "long-name-with-total")
        let withoutTotal = try await mount(group: group, asksOpen: { _ in nil }, name: "long-name-without-total")
        XCTAssertEqual(withTotal.rowRects.count, 4, "precondition: heading, alpha, beta, then gamma ungrouped")

        let heading = withTotal.rowRects[0]
        let diff = inkDiffColumns(withTotal, withoutTotal, in: heading)
        let diffMin = try XCTUnwrap(diff.min(), "the heading's worded total (10 open asks) drew no new ink")
        let diffMax = try XCTUnwrap(diff.max())
        XCTAssertGreaterThan(diffMax - diffMin, 40,
                             "\"10 open asks\" (new ink from x \(diffMin) to x \(diffMax)) should span much "
                             + "more width than a bare digit would, now that the total reads as words")
        XCTAssertLessThan(diffMax, heading.maxX - 2,
                          "the worded total (new ink ending at x \(diffMax)) should still draw inside the "
                          + "row (maxX \(heading.maxX)), which only holds if the long name truncated ahead "
                          + "of it")
    }
}
