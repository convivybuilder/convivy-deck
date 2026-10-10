import XCTest
import SwiftUI
import AppKit
@testable import Deck

/// Layout tests that host the real SwiftUI view and measure what AppKit builds.
///
/// WHY THIS FILE EXISTS. The Sessions tab shipped in #51 clipped its list at
/// about eight of eleven rows, would not scroll to the rest, and sat in a
/// window that could not be resized. Every unit test passed, both reviewers
/// approved, and CI was green, because nothing in the suite could see a window.
/// The operator found it by opening Settings.
///
/// NOT XCUITest. SwiftPM cannot build a UI test target — that needs an
/// `.xcodeproj`, and the repo deliberately keeps `swift build && swift test` as
/// its single CI command (`Scripts/make-app.sh` explains why). Most of this hosts
/// the view in an `NSHostingView` and reads the AppKit hierarchy underneath, which
/// runs headless: no window server, no GUI session, no Screen Recording
/// permission. It works over ssh, which is where those were written.
///
/// THE CAPTION TESTS AT THE BOTTOM ARE THE EXCEPTION, and it is worth knowing
/// which before you run these somewhere new. They need a window server, because
/// what they measure cannot be reached any other way: the pin button and the
/// Refresh checkbox live inside a SwiftUI `List` and appear NOWHERE in the AppKit
/// hierarchy, so they have to be drawn and read as pixels. They skip rather than
/// fail where no window can be opened.
///
/// WHAT IT CAN AND CANNOT SEE. It measures structure and geometry — how many
/// scroll views there are, whether a view grows when given more room, whether
/// content fits its container, and now whether two things line up. It cannot see
/// colour, blur, font rendering, or anything about how a person reads the result.
/// Those still need eyes: both caption misalignments were reported by the operator looking
/// at the tab, and only then measured.
@MainActor
final class SettingsLayoutTests: XCTestCase {

    /// The width the Settings window starts at, and the tab's own floor.
    private let minimumSize = NSSize(width: 460, height: 470)

    /// A store on a throwaway file, seeded with an explicit rail plus a
    /// catalog so the roster is the eleven rows the reported bug involved.
    ///
    /// THE RAIL IS WRITTEN OUT EXPLICITLY rather than left to fall back to
    /// `CrewCatalog.known`: that fallback carried Convivy's own org chart
    /// until `deck/specs/running-deck-as-someone-else` §"The defaults name
    /// Convivy" emptied it, and this file needs pinned rows to reproduce the
    /// caption-alignment bug regardless of what an unconfigured install's
    /// rail happens to default to.
    private func store() throws -> ThemeStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("theme.json")
        try #"""
        {"rail": [{"session": "crew-1"}, {"session": "crew-2"}, {"session": "crew-3"},
                  {"session": "crew-4"}, {"session": "crew-5"}, {"session": "crew-6"},
                  {"session": "crew-7"}, {"session": "crew-8"}],
         "catalog": [{"session": "nyh", "name": "NYH Studio"},
                     {"session": "write-better", "name": "Write Better"},
                     {"session": "ask", "name": "Ask"}]}
        """#.write(to: file, atomically: true, encoding: .utf8)
        return ThemeStore(fileURL: file)
    }

    private func hostSessionsTab(height: CGFloat? = nil) throws -> NSHostingView<some View> {
        let view = SessionsSettingsView().environmentObject(try store())
            .environmentObject(RailStateModel())
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero,
                            size: NSSize(width: minimumSize.width,
                                         height: height ?? minimumSize.height))
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Depth-first, so the outermost scroll view comes first and the innermost
    /// last. That ordering is what the list assertions below depend on: when
    /// the tab was nested, the list was the INNER one, and a test that measured
    /// the outer container passed while the bug was live.
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let here = (view as? NSScrollView).map { [$0] } ?? []
        return here + view.subviews.flatMap(scrollViews)
    }

    /// The list, whether or not something is wrapped around it.
    private func listScrollView(in view: NSView) throws -> NSScrollView {
        try XCTUnwrap(scrollViews(in: view).last, "no scroll view in the tab at all")
    }

    /// Every view in the tree, for asking how wide the content actually got.
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    // MARK: - The three symptoms

    /// THE BUG THAT MADE THE OTHERS FATAL. The list sat inside a `.grouped`
    /// Form, which is itself a scroll view. The outer one took the gesture and
    /// the inner one never scrolled, so rows past the clip were unreachable by
    /// any means at all.
    ///
    /// One scroll view is the invariant. Two is the defect, and it is invisible
    /// in source until you know to look for it, which is exactly what a test is
    /// for.
    func testTheSessionsTabHasExactlyOneScrollView() throws {
        let host = try hostSessionsTab()
        let found = scrollViews(in: host)
        XCTAssertEqual(found.count, 1,
                       "\(found.count) scroll views: nested scrolling means the "
                       + "inner one never receives the gesture")
    }

    /// The list must take the height it is given rather than naming its own,
    /// or a roster longer than the window hides its tail with no way to reach it.
    func testTheListGrowsWithTheWindow() throws {
        let short = try listScrollView(in: try hostSessionsTab())
        let tall = try listScrollView(in: try hostSessionsTab(height: 760))

        XCTAssertGreaterThan(
            tall.frame.height, short.frame.height + 100,
            "the list did not take the extra height, so it is pinned to a fixed one")
    }

    /// At the window's own floor, every session is on screen. This is the
    /// symptom the operator reported first — "I can't see all the projects" — and the
    /// one a person notices before they discover the scrolling is broken too.
    func testEverySessionIsVisibleAtTheMinimumWindowSize() throws {
        let host = try hostSessionsTab()
        let list = try listScrollView(in: host)
        let content = try XCTUnwrap(list.documentView)

        XCTAssertLessThanOrEqual(
            content.frame.height, list.contentView.bounds.height + 1,
            "the roster is \(content.frame.height)pt in a \(list.contentView.bounds.height)pt "
            + "list, so its last rows are off screen before the user has resized anything")
    }

    // MARK: - The window

    /// A fixed `frame(width:)` on the TabView left the window no axis to grow
    /// along, so a user could not resize their way out of a clipped list.
    /// Asking whether the CONTENT widens, not whether the host frame took the
    /// value it was handed — the host always does, which is why the first
    /// version of this test passed while the bug was live.
    ///
    /// Under a fixed `frame(width: 460)` the tabs stay 460 wide inside a larger
    /// host and sit centred, so nothing in the tree approaches the new width.
    func testTheSettingsContentWidensWithTheWindow() throws {
        let host = NSHostingView(rootView: SettingsView().environmentObject(try store())
            .environmentObject(SettingsNavigation())
            .environmentObject(RailStateModel()))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 800)
        host.layoutSubtreeIfNeeded()

        let widest = descendants(of: host).map(\.frame.width).max() ?? 0
        XCTAssertGreaterThan(
            widest, 700,
            "nothing inside the settings window grew past \(widest)pt in a 900pt "
            + "host, so the content is pinned and the window cannot be resized")
    }

    // MARK: - The other tabs, which the fix also touched

    /// Relaxing the TabView's width to a floor must not shrink the tabs that
    /// were relying on it.
    func testTheOtherTabsStillMeetTheMinimumWidth() throws {
        let host = NSHostingView(rootView: SettingsView().environmentObject(try store())
            .environmentObject(SettingsNavigation())
            .environmentObject(RailStateModel()))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(host.fittingSize.width, 460)
        XCTAssertGreaterThan(host.fittingSize.height, 0, "the settings window has no height")
    }

    // MARK: - The column captions sit over the controls they name
    //
    // MEASURED OFF A RENDER, because nothing else can see this. The pin button and
    // the Refresh checkbox live inside a SwiftUI `List` and appear nowhere in the
    // AppKit hierarchy, so the introspection the rest of this file uses returns
    // nothing for them — a walk of every subview finds only the +/− buttons. The
    // captions are `Text`, which is not an `NSTextField` either. So the only way to
    // check the alignment is to draw it and look at the pixels.
    //
    // The operator reported both halves by eye on 2026-07-29: "Rail is definitely too far
    // right", and Refresh "flush right with the column". The numbers agreed — Rail
    // centred at x=43 against a pin at 30.5, Refresh at 420 against a checkbox at
    // 435.5 — and the cause was one thing: the band was padded to the tab's 20pt
    // margin while `.listStyle(.inset)` insets its rows to 15.5.

    /// The rendered tab as a bitmap, or nil where this cannot be drawn.
    ///
    /// A WINDOW IS REQUIRED, and that is not ceremony: an unhosted `List` realizes
    /// no rows at all, so the bitmap comes back with a header and an empty table,
    /// and every measurement below would pass by finding nothing to disagree with.
    /// A rendered tab, with the scale needed to read it in points.
    ///
    /// THE SCALE IS NOT DECORATION. Every band and every column index below is a
    /// BITMAP PIXEL, and on a Retina display there are two of those per point — so
    /// bands written as points miss the ink entirely and the tests report "no
    /// caption was drawn" when the caption is drawn, just twice as far down. Raised
    /// in review of #58, where the offscreen path happened to be 1x on the machine
    /// it was written on and on the CI runner, which is exactly the kind of
    /// environment luck that makes a test pass for the wrong reason somewhere else.
    private struct Render {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        /// A band given in points, as the pixel rows it covers.
        func rows(_ points: ClosedRange<Int>) -> ClosedRange<Int> {
            Int(CGFloat(points.lowerBound) * scale)...Int(CGFloat(points.upperBound) * scale)
        }
        func points(_ pixels: Double) -> Double { pixels / Double(scale) }
    }

    private func renderSessionsTab() throws -> Render? {
        let host = try hostSessionsTab()
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        // From the bitmap rather than the window: this rep is what was measured, and
        // its own pixel count against the view's point size is the honest ratio.
        let scale = host.bounds.width > 0
            ? CGFloat(rep.pixelsWide) / host.bounds.width : 1
        return Render(rep: rep, scale: max(scale, 1))
    }

    /// The horizontal spans of drawn content in a band of rows, left to right.
    ///
    /// Composited over white first. The tab draws on a transparent background, so
    /// reading the colour channels directly reports every untouched pixel as black
    /// and the whole band as one span — which is how the first version of this
    /// measurement "found" content everywhere.
    private func spans(in render: Render,
                       pointRows band: ClosedRange<Int>) -> [(first: Int, last: Int)] {
        let rep = render.rep
        let band = render.rows(band)
        var columns: [Int] = []
        for x in 0..<rep.pixelsWide {
            let inked = band.contains { y in
                guard let c = rep.colorAt(x: x, y: y) else { return false }
                let alpha = c.alphaComponent
                // Over white: the darker the ink and the more opaque, the lower this.
                let onWhite = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                    * alpha + (1 - alpha)
                return onWhite < 0.78
            }
            if inked { columns.append(x) }
        }
        var out: [(first: Int, last: Int)] = []
        for c in columns {
            if let last = out.last, c == last.last + 1 { out[out.count - 1].last = c }
            else { out.append((first: c, last: c)) }
        }
        return out
    }

    /// The caption band and the first row's band, IN POINTS. `Render.rows` converts
    /// them to the bitmap's pixel rows.
    private let captionBand = 10...30
    private let firstRowBand = 46...62

    /// How much blank can sit INSIDE one control before it reads as two.
    ///
    /// `spans(in:pointRows:)` reports CONTIGUOUS ink, and a control is not
    /// obliged to be contiguous. The Refresh checkbox is a rounded OUTLINE, so
    /// its left and right borders are separate spans with the box's own empty
    /// middle between them.
    ///
    /// THE TWO NUMBERS THAT BOUND THIS, measured on the Sessions tab and
    /// computed the way the loops below do it (`next.first - previous.last`,
    /// in points at scale 2):
    ///
    /// - the checkbox's own internal gap, which MUST merge: **3.5pt**
    ///   (px 870 - 863 = 7)
    /// - the gap from the pin to the THEME-COLOUR DOT beside it, which must
    ///   NOT: **19.5pt** (px 108 - 69 = 39)
    ///
    /// 8.0 sits well clear of both: 4.5pt of margin over the gap that has to
    /// close, 11.5pt under the one that has to stay open.
    ///
    /// THE DOT IS NOT THE SESSION NAME, and an earlier version of this comment
    /// said it was. The row is pin, then `Circle().frame(width: 8)`, then
    /// `Text(entry.displayName)` (`SessionsSettingsView.swift:151-156`), so
    /// px 108...123 is the dot's 8pt frame and the name does not ink until
    /// px 141. `deck-reviewer` derived that from the layout source on PR #208
    /// after the label had been asserted rather than checked twice in a row —
    /// in a file whose entire subject is a measurement trusted without being
    /// re-derived.
    ///
    /// THERE IS A THIRD GAP, dot to name at **9pt** (px 141 - 123 = 18). It is
    /// worth knowing and it is NOT the bound this constant answers to.
    ///
    /// Neither loop reaches it: `leadingControl` breaks at the 19.5pt pin gap
    /// and `trailingControl` at the 321pt gap before the checkbox. Nor can a
    /// modest raise make it reachable, which is the part that is easy to get
    /// wrong — each loop breaks on the FIRST failing gap and never resumes, so
    /// evaluating dot-to-name at all means pin-to-dot has already merged, and
    /// that needs 19.5. By then `testLeadingControlStopsAtTheNextControl` has
    /// failed. So 19.5 is the operative ceiling, and everything in (9, 17.5)
    /// is safe on this row. That interval sits inside the (5.5, 17.5) band
    /// `testTheGapThresholdClearsBothMeasuredGapsWithMargin` enforces, whose
    /// lower bound comes from the checkbox gap rather than from this one.
    ///
    /// An earlier version of this paragraph called 9pt "the tightest ceiling"
    /// and said crossing it merges the dot into the name "the moment either
    /// loop gets there". `deck-reviewer` traced the values on PR #208 and
    /// showed that overstates it. Keep 9pt recorded as the conservative
    /// structural number — measurement noise already split a gap once in this
    /// file — but do not read it as the limit the algorithm enforces.
    ///
    /// IT IS 8.0 RATHER THAN SOMETHING SNUGGER BECAUSE THE TIGHT SIDE IS THE
    /// SIDE THAT BIT. The first version of this fix used 4.0, which clears
    /// 3.5pt by only half a point — one pixel of anti-aliasing movement at
    /// scale 2 lands exactly on the threshold, and two splits the checkbox
    /// again, which is the bug this whole change exists to end. The wide side
    /// has 11.5pt to give away and the narrow side had none, so the slack
    /// belongs where it was missing. `deck-reviewer` measured both gaps on
    /// PR #208 and found the doc claiming 3pt and 27.5pt; 27.5 was the pin's
    /// own left-edge coordinate misread as a gap.
    private static let intraControlGap = 8.0

    /// The leading and trailing control in a row, as ONE span each.
    ///
    /// TAKING `row.first` OR `row.last` DIRECTLY IS THE BUG THESE REPLACE, and
    /// it produced a test that passed and failed on an unchanged commit. When
    /// the checkbox drew as two spans, `row.last` was its RIGHT BORDER rather
    /// than the checkbox, putting the measured centre 2.5pt right of the true
    /// one and failing a ±2pt assertion. Whether it splits is decided by
    /// anti-aliasing against the 0.78 ink threshold in `spans`, which is not
    /// stable across display states: on the mini this test passed at 21:51 on
    /// 2026-09-07 and failed at 10:20 the next morning, same commit, same
    /// machine, nothing in the repo touched.
    ///
    /// The caption side never had this bug, because it already spans
    /// `captionFirst.first ... captionLast.last`. These make the column side
    /// symmetric with it rather than widening the tolerance — the failure was
    /// 0.5pt outside the band, so any tolerance loose enough to absorb it would
    /// be too loose to catch the real misalignment the operator reported by eye.
    /// Taking `scale` rather than a `Render` so both are reachable from a test
    /// with no window — the merging rule is the part that broke, and pinning it
    /// must not itself depend on the environment that made it break.
    static func leadingControl(in row: [(first: Int, last: Int)],
                               scale: CGFloat) -> (first: Int, last: Int)? {
        guard var control = row.first else { return nil }
        for span in row.dropFirst() {
            guard Double(span.first - control.last) / Double(scale) <= intraControlGap else { break }
            control.last = span.last
        }
        return control
    }

    static func trailingControl(in row: [(first: Int, last: Int)],
                                scale: CGFloat) -> (first: Int, last: Int)? {
        guard var control = row.last else { return nil }
        for span in row.dropLast().reversed() {
            guard Double(control.first - span.last) / Double(scale) <= intraControlGap else { break }
            control.first = span.first
        }
        return control
    }

    // MARK: - The merging rule itself

    /// The spans below are the REAL ones, dumped from this tab on the mini at
    /// scale 2 while the ±2pt assertion was failing. They are the evidence the
    /// fix was built from, kept as a test so the rule is pinned somewhere that
    /// needs no window — the caption tests skip headlessly, so without this the
    /// regression would only reappear on a machine with a display, hours later.
    ///
    /// The checkbox is the last TWO spans: px 860...863 and 870...879, a 3.5pt
    /// gap apart. Merged, its centre is 434.75, exactly where the Refresh
    /// caption sits. Taking `row.last` alone gives 437.25 and fails by 2.5pt.
    private static let measuredFirstRow: [(first: Int, last: Int)] = [
        (55, 69), (108, 123), (141, 152), (156, 163), (165, 176), (179, 182),
        (185, 190), (194, 197), (211, 218), (860, 863), (870, 879),
    ]

    func testTrailingControlMergesTheCheckboxBothBorders() {
        let checkbox = SettingsLayoutTests.trailingControl(in: Self.measuredFirstRow, scale: 2)
        XCTAssertEqual(checkbox?.first, 860,
                       "the checkbox's left border was dropped, so this measures its right border")
        XCTAssertEqual(checkbox?.last, 879)
        let centre = Double((checkbox?.first ?? 0) + (checkbox?.last ?? 0)) / 2 / 2
        XCTAssertEqual(centre, 434.75, accuracy: 0.01,
                       "the merged checkbox centre must match where the Refresh caption sits")
    }

    /// The other half of the rule: merging must STOP at the next control. The
    /// pin is px 55...69 and the theme-colour dot beside it starts at 108,
    /// 19.5pt away — well past the 8pt bar — so the pin stays itself.
    func testLeadingControlStopsAtTheNextControl() {
        let pin = SettingsLayoutTests.leadingControl(in: Self.measuredFirstRow, scale: 2)
        XCTAssertEqual(pin?.first, 55)
        XCTAssertEqual(pin?.last, 69,
                       "the pin swallowed the dot beside it — the gap bar is too loose")
    }

    /// The threshold sits between the two measured gaps WITH ROOM, which the
    /// two tests above cannot say on their own: they pass anywhere in
    /// (3.5, 19.5), including at 3.6, where one pixel of anti-aliasing would
    /// split the checkbox again exactly as it did on 2026-09-08.
    ///
    /// So this asserts the MARGIN rather than the bare ordering, and it is the
    /// test that would have caught the first version of this fix, which chose
    /// 4.0 and cleared the tight side by half a point.
    func testTheGapThresholdClearsBothMeasuredGapsWithMargin() {
        let checkboxInternal = 3.5   // px 870 - 863, at scale 2
        let pinToDot = 19.5  // px 108 - 69, at scale 2 — the dot, not the name
        XCTAssertGreaterThan(SettingsLayoutTests.intraControlGap, checkboxInternal + 2,
                             "too close to the gap that must CLOSE: a pixel of "
                             + "anti-aliasing would split the checkbox again")
        XCTAssertLessThan(SettingsLayoutTests.intraControlGap, pinToDot - 2,
                          "too close to the gap that must STAY OPEN: the pin would "
                          + "start swallowing the theme-colour dot beside it")
    }

    /// An empty row yields nothing rather than crashing, which is what lets the
    /// caption tests report "no pin was drawn" instead of trapping.
    func testControlsAreNilOnAnEmptyRow() {
        XCTAssertNil(SettingsLayoutTests.leadingControl(in: [], scale: 2))
        XCTAssertNil(SettingsLayoutTests.trailingControl(in: [], scale: 2))
    }

    func testTheRailCaptionSitsOverThePinColumn() throws {
        guard let render = try renderSessionsTab() else {
            throw XCTSkip("this environment cannot draw the tab, so it cannot be measured")
        }
        let midpoint = Int(200 * render.scale)
        let caption = spans(in: render, pointRows: captionBand).filter { $0.first < midpoint }
        let row = spans(in: render, pointRows: firstRowBand)
        let captionFirst = try XCTUnwrap(caption.first, "no Rail caption was drawn")
        let captionLast = try XCTUnwrap(caption.last, "the caption span vanished")
        let pin = try XCTUnwrap(Self.leadingControl(in: row, scale: render.scale),
                                "no pin was drawn — did the list realize its rows?")

        let captionCentre = render.points(Double(captionFirst.first + captionLast.last) / 2)
        let pinCentre = render.points(Double(pin.first + pin.last) / 2)
        XCTAssertEqual(captionCentre, pinCentre, accuracy: 2,
                       "Rail is \(captionCentre - pinCentre)pt off the pin column")
    }

    func testTheRefreshCaptionSitsOverTheCheckboxColumn() throws {
        guard let render = try renderSessionsTab() else {
            throw XCTSkip("this environment cannot draw the tab, so it cannot be measured")
        }
        let midpoint = Int(200 * render.scale)
        let caption = spans(in: render, pointRows: captionBand).filter { $0.first >= midpoint }
        let row = spans(in: render, pointRows: firstRowBand)
        let captionFirst = try XCTUnwrap(caption.first, "no Refresh caption was drawn")
        let captionLast = try XCTUnwrap(caption.last, "the caption span vanished")
        let checkbox = try XCTUnwrap(Self.trailingControl(in: row, scale: render.scale),
                                    "no checkbox was drawn")

        let captionCentre = render.points(Double(captionFirst.first + captionLast.last) / 2)
        let checkboxCentre = render.points(Double(checkbox.first + checkbox.last) / 2)
        XCTAssertEqual(captionCentre, checkboxCentre, accuracy: 2,
                       "Refresh is \(captionCentre - checkboxCentre)pt off the checkbox column")
    }

    /// The caption must not run off the edge to achieve that centring.
    ///
    /// The cost of centring, pinned so it cannot get worse. `Refresh` is about twice
    /// the width of the column it names, and that column sits close to the window
    /// edge, so a centred caption has roughly 7pt of trailing margin at the minimum
    /// width. The operator chose the centring knowing that; this fails if a later change eats
    /// the rest of it.
    func testTheRefreshCaptionStaysInsideTheTab() throws {
        guard let render = try renderSessionsTab() else {
            throw XCTSkip("this environment cannot draw the tab, so it cannot be measured")
        }
        let midpoint = Int(200 * render.scale)
        let caption = spans(in: render, pointRows: captionBand).filter { $0.first >= midpoint }
        let last = try XCTUnwrap(caption.last, "no Refresh caption was drawn")
        XCTAssertLessThan(render.points(Double(last.last)),
                          render.points(Double(render.rep.pixelsWide)) - 3,
                          "the Refresh caption is touching the tab's edge")
    }
}
