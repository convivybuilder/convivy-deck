import XCTest
import SwiftUI
import AppKit
@testable import Deck

/// Whether `paneChrome(rowWidth:)`'s replacement delivery mechanism actually
/// delivers, headless — the same `NSHostingView` + `layoutSubtreeIfNeeded()`
/// technique `ResizableDividerLayoutTests` and `SettingsLayoutTests` already
/// use for exactly this class of question: no window server, no GUI session,
/// runs over ssh.
///
/// THE MECHANISM THIS REPLACES. `issue_01M249YXQESGX3D74AJMN1H5XN`: a
/// `PreferenceKey` set on a `Group` whose content is `_ConditionalContent`
/// (an `if`/`else` inside a `ViewBuilder`), read back through
/// `.onPreferenceChange` into `@State`, never advanced past its initial `0`
/// when hosted this way — confirmed on #212 with an internal print statement
/// across 20 forced layout passes. `paneChrome` now takes its row width as a
/// plain `CGFloat` from a `GeometryReader` hoisted above its parent `VStack`
/// (`ContentView.body`), which is a synchronous input to view-body
/// evaluation rather than an asynchronous callback with a stale value to get
/// stuck at.
///
/// THIS TEST REPRODUCES THE IDENTICAL SHAPE — a `GeometryReader` hoisted
/// above a `VStack` whose content is a `Group { if ... } else { ... }`,
/// receiving the measured width as a parameter rather than through a
/// preference — and checks the value reaches the conditional branch correct
/// on the FIRST `layoutSubtreeIfNeeded()` pass, with no retry loop, because
/// there is no `@State` write for a hosted-without-`App`/`Scene` run loop to
/// fail to drive.
final class HoistedRowWidthDeliveryTests: XCTestCase {
    private final class WidthBox {
        var seen: CGFloat?
    }

    @MainActor
    private func probe(usesFirstBranch: Bool, seenInto box: WidthBox) -> some View {
        GeometryReader { rowGeo in
            VStack(spacing: 0) {
                Group {
                    if usesFirstBranch {
                        Color.clear.onAppear { box.seen = rowGeo.size.width }
                    } else {
                        Color.clear
                    }
                }
            }
        }
    }

    @MainActor
    func testAWidthHoistedAboveConditionalContentArrivesOnTheFirstPass() {
        let box = WidthBox()
        let host = NSHostingView(rootView: probe(usesFirstBranch: true, seenInto: box))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 40)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(box.seen, 900,
                       "the hoisted width never reached the conditional branch "
                       + "on the first layout pass")
    }

    /// The same shape at the OTHER branch of the conditional — `paneChrome`
    /// reads `usesColumnSheet` to pick between two very different bodies, so
    /// delivery must not depend on which one is live.
    @MainActor
    func testAWidthHoistedAboveConditionalContentArrivesOnTheOtherBranchToo() {
        let box = WidthBox()
        let host = NSHostingView(rootView: probe(usesFirstBranch: false, seenInto: box))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 40)
        host.layoutSubtreeIfNeeded()

        // The first branch never appeared, so nothing wrote `box.seen` — this
        // pins that the earlier test's pass is about delivery, not a
        // tautology that always succeeds regardless of which branch is live.
        XCTAssertNil(box.seen)
    }
}

/// Hosts the REAL `ContentView` — the code path the two tests above only
/// reproduce the shape of — and reads the Main pane picker's actual AppKit
/// frame back out, the same `NSHostingView` + `layoutSubtreeIfNeeded()`
/// technique `SettingsLayoutTests` uses. Where the tests above would still
/// pass with the hoist fully reverted (nothing in them touches `ContentView`
/// or `paneChrome`), this one exercises `paneChrome(rowWidth:)` itself: if
/// `rowWidth` stopped arriving — the `PaneChromeWidthPreferenceKey` bug this
/// PR removes — `mainPaneChromeWidth` would floor at `0` and the picker
/// would land at the row's far left instead of the divider, on this exact
/// assertion.
///
/// #212 already showed hosting the real `ContentView` headless is possible
/// (`PaneChromeWidthTests`'s doc), just not useful THERE because the old
/// `@State` round trip needed a second layout pass this harness cannot
/// drive. The hoisted value has no such round trip — it is a plain
/// parameter resolved during the first `body` evaluation — so that
/// limitation does not apply here.
@MainActor
final class HostedPaneChromeRowWidthTests: XCTestCase {
    private func store() throws -> ThemeStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-hosted-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("theme.json")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        return ThemeStore(fileURL: file)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    /// Neither picker exposes a stable identifier through `NSHostingView`
    /// (`.help()`'s tooltip does not bridge to `NSView.toolTip` here), so
    /// this keys off segment count instead: the Main pane picker always has
    /// exactly 2 (Session, Terminal); the Right column picker has 3 at rest
    /// (Cockpit, Shell, Local — the viewer/editor/item segments only appear
    /// once one of those is the live occupant, which a freshly hosted view
    /// never is).
    private func segmentedControls(in host: NSView) throws
        -> (mainPane: NSSegmentedControl, rightColumn: NSSegmentedControl) {
        let segmented = descendants(of: host).compactMap { $0 as? NSSegmentedControl }
        let mainPane = try XCTUnwrap(segmented.first { $0.segmentCount == 2 },
                                    "no 2-segment control — is the Main pane picker even hosted?")
        let rightColumn = try XCTUnwrap(segmented.first { $0.segmentCount == 3 },
                                        "no 3-segment control — is the Right column picker even hosted?")
        return (mainPane, rightColumn)
    }

    func testMainPanePickerLandsExactlyWhereMainPaneChromeWidthPredicts() throws {
        let themeStore = try store()
        let view = ContentView()
            .environmentObject(themeStore)
            .environmentObject(WorkingCopyServer())
            .environmentObject(RailStateModel())
            .environmentObject(DesktopSessionAlertCenter())
            .environmentObject(SettingsNavigation())
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        host.layoutSubtreeIfNeeded()
        // A second pass: `usesColumnSheet`'s own `windowWidth` still arrives
        // through an `.onAppear`/`.onChange`-set `@State` (unchanged by this
        // PR), which needs one more pass to be reflected in the branch this
        // test depends on (the non-column-sheet, two-box `paneChrome` split).
        host.layoutSubtreeIfNeeded()

        let (mainPanePicker, rightColumnPicker) = try segmentedControls(in: host)
        let mainPaneFrame = mainPanePicker.convert(mainPanePicker.bounds, to: host)
        let rightColumnFrame = rightColumnPicker.convert(rightColumnPicker.bounds, to: host)

        // `rightColumnPicker` is the ONLY view in `paneChrome`'s trailing
        // `HStack { Spacer(); rightColumnPicker }` now that the toolbar's
        // own "Stop session" menu is gone (convivy-deck
        // `issue_01M2715540KEV1P6Z831R6TAWA`: two Stop controls existed,
        // `PaneStatusBar`'s ellipsis is the one that stays) — so its
        // trailing edge lands flush with the row's own trailing edge BY
        // CONSTRUCTION, not merely because nothing happened to follow it in
        // this no-selection fixture the way the deleted menu used to. That
        // is the same "ends exactly at its own pane's edge, no tuned
        // constant" property the Main pane picker's assertion below checks
        // for the divider side, so pin it explicitly here rather than only
        // using it as `rowWidth`'s source of truth.
        //
        // The empty `{}` config is Builder Default with the cockpit docked, and
        // that draws the frame's 12pt band at the row's trailing edge. The picker
        // stops at the band's inner edge, so the band never sits under its track.
        let rowWidth = host.frame.width
        let bandWidth = ContentView.cockpitFrameBandWidth
        XCTAssertEqual(rightColumnFrame.maxX, rowWidth - bandWidth, accuracy: 1,
                       "the Right column picker's box ended at \(rightColumnFrame.maxX)pt in a "
                       + "\(rowWidth)pt-wide host — with the Stop-session menu removed, nothing "
                       + "should sit between it and the cockpit's band")
        let expectedBoxWidth = CGFloat(ContentView.mainPaneChromeWidth(
            chromeRowWidth: Double(rowWidth), dragging: nil,
            stored: themeStore.configuration.columnWidth))

        XCTAssertGreaterThan(expectedBoxWidth, 100,
                             "the row width this test measured (\(rowWidth)pt) is degenerate")
        XCTAssertEqual(mainPaneFrame.maxX, expectedBoxWidth, accuracy: 1,
                       "the Main pane picker's box ended at \(mainPaneFrame.maxX)pt in a "
                       + "\(rowWidth)pt row, not the \(expectedBoxWidth)pt "
                       + "mainPaneChromeWidth predicts — paneChrome is not receiving the "
                       + "real row width")
    }
}
