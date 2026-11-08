import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// Settings › Hosts with a tall detail panel (issue_01M5CZ5JF1X2W56FFMAQ1Y6E7D).
///
/// THE BUG. `HostsSettingsView.body` was a plain `VStack` of the host list, the
/// +/− controls, and `detail(for:)`, under one fixed `.frame(minWidth: 460,
/// minHeight: 420)` with no `ScrollView` anywhere. A host whose detail is tall —
/// every field filled, a desktop-session status line, a missing-Builder-server
/// line, a test outcome, a pairing offer, the rollover section — squeezed the
/// flexible list to nothing and ran the rest off the bottom of the window, with
/// no way to scroll to it and no way to change or clear the selection.
///
/// A FIXTURE AS TALL AS CAN BE BUILT WITHOUT A REAL HOST. The operator's report
/// was about a real machine; this uses a synthetic one on a TEST-NET-1 address
/// (RFC 5737, same convention as `HostsSettingsView.hostAddressPlaceholder`) so
/// no real host name ships in a test fixture, and drives `RailStateModel`
/// through its fetch seams rather than an ssh round trip, so the fixture is
/// exactly as tall on every machine that runs this suite.
@MainActor
final class HostsSettingsDetailScrollTests: XCTestCase {
    /// The Settings window's own floor, unchanged by this fix — the size a
    /// freshly opened Hosts tab starts at before anything grows it.
    private let defaultWindowSize = NSSize(width: 460, height: 420)

    private let fixtureTarget = SSHTarget(user: "demouser", host: "192.0.2.50")

    private func store() throws -> ThemeStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-hosts-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("theme.json")
        let store = ThemeStore(fileURL: file)
        // Several hosts, so the list has rows to squeeze in the first place —
        // one row alone cannot show the bug item 2 is about.
        for name in ["driftwood", "ridge", "harbor", "overlook"] {
            store.addHost(HostEntry(name: name, user: "demouser", address: "192.0.2.\(50 + name.count)"))
        }
        store.addHost(HostEntry(
            name: "canopy", user: "demouser", address: fixtureTarget.host,
            crewsRoot: "/srv/crews", runbookLink: "team/runbooks/log-back-in"))
        return store
    }

    /// Drives `RailStateModel.refresh()` through its fetch seams so the
    /// fixture host reads as logged out, missing its Builder server, and
    /// refused on its last Test — every optional line in `detail(for:)` that a
    /// real tall host (desktop-session status, the install offer, a pairing
    /// offer) can show, without any ssh round trip.
    private func railState() async -> RailStateModel {
        let model = RailStateModel()
        let target = fixtureTarget
        model.configuredTargets = { [target] }
        model.fetchStates = { _, _ in [:] }
        model.fetchDiscovered = { _ in throw SessionAgent.AgentError.notInstalled }
        model.fetchServedCrews = { _ in [] }
        model.fetchRunRegister = { _ in [:] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe in this test") }
        model.fetchDesktopSession = { _ in .loggedOut }
        await model.refresh()
        return model
    }

    private func mount() async throws -> (window: NSWindow, host: NSHostingView<some View>) {
        let navigation = SettingsNavigation()
        let rail = await railState()
        let view = HostsSettingsView()
            .environmentObject(try store())
            .environmentObject(navigation)
            .environmentObject(rail)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: defaultWindowSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        // Selects the tall fixture host the same way the logged-out alert's
        // own button does, via the navigation seam `HostsSettingsView`
        // already reads (`selectHostRequest`) rather than reaching into
        // `@State` directly.
        navigation.openHostsSettings(selecting: "canopy")
        try await Task.sleep(nanoseconds: 500_000_000)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let here = (view as? NSScrollView).map { [$0] } ?? []
        return here + view.subviews.flatMap(scrollViews)
    }

    /// Whether `view` or any descendant is one of `List`'s own private row/
    /// header classes — `ListTableRowView`, `ListTableCellView`,
    /// `ListTableHeaderView`. SwiftUI's `List` on macOS realizes these rather
    /// than a plain `NSTableRowView`, which is what distinguishes the host
    /// list's own scroll view from the detail panel's plain `ScrollView`.
    private func isListBacked(_ view: NSView) -> Bool {
        String(describing: type(of: view)).hasPrefix("ListTable")
    }

    /// The list's own scroll view, found by the private `List` classes
    /// somewhere underneath it.
    private func listScrollView(in view: NSView) -> NSScrollView? {
        scrollViews(in: view).first { descendants(of: $0).contains(where: isListBacked) }
    }

    /// Every row the list actually realized — `ListTableRowView`s that are
    /// not the section header, which is a `ListTableRowView` of its own
    /// wrapping a `ListTableHeaderView`. SwiftUI's `List` only materializes
    /// these inside a live window, the same reason `SettingsLayoutTests`'
    /// caption tests need one.
    private func tableRowViews(in scroll: NSScrollView) -> [NSView] {
        descendants(of: scroll).filter { view in
            String(describing: type(of: view)) == "ListTableRowView"
                && !descendants(of: view).contains { String(describing: type(of: $0)) == "ListTableHeaderView" }
        }
    }

    // MARK: - The list must keep a floor

    /// However tall the selected host's detail is, the list keeps at least
    /// three rows' worth of height — the squeeze-to-nothing this item names.
    func testTheListKeepsAMinimumHeightWithATallDetailSelected() async throws {
        let (window, host) = try await mount()
        defer { window.orderOut(nil) }

        let list = try XCTUnwrap(listScrollView(in: host), "no table-backed scroll view for the host list")
        let rows = tableRowViews(in: list)
        XCTAssertGreaterThanOrEqual(rows.count, 3,
                                    "only \(rows.count) host rows realized — the list was squeezed below "
                                    + "three rows by the tall detail panel")

        let visibleRowCount = rows.filter { row in
            let frameInList = list.convert(row.bounds, from: row)
            return list.contentView.bounds.intersects(frameInList)
        }.count
        XCTAssertGreaterThanOrEqual(visibleRowCount, 3,
                                    "only \(visibleRowCount) of \(rows.count) rows are inside the list's own "
                                    + "visible area — the list's clip view is shorter than three rows")
    }

    // MARK: - The detail panel scrolls rather than overflowing the window

    /// The detail panel is its own scroll area, separate from the list's, and
    /// its content (the tall fixture's full field set) extends past what the
    /// window shows — i.e. there is something to scroll TO, not just a
    /// clipped view with nothing scrollable behind it.
    func testTheDetailPanelIsItsOwnScrollAreaAndCanReachThePastTheFold() async throws {
        let (window, host) = try await mount()
        defer { window.orderOut(nil) }

        let allScrollViews = scrollViews(in: host)
        XCTAssertGreaterThanOrEqual(allScrollViews.count, 2,
                                    "expected the list's own scroll view and a separate one for the detail "
                                    + "panel; found \(allScrollViews.count)")

        let detailScroll = try XCTUnwrap(
            allScrollViews.first { $0 !== listScrollView(in: host) },
            "no scroll view distinct from the host list was found for the detail panel")
        let content = try XCTUnwrap(detailScroll.documentView)
        XCTAssertGreaterThan(content.frame.height, detailScroll.contentView.bounds.height,
                             "the detail panel's content (\(content.frame.height)pt) does not exceed its "
                             + "own viewport (\(detailScroll.contentView.bounds.height)pt) at the default "
                             + "window size, so the tall fixture is not actually exercising scroll")
    }

    /// Whether `c` differs from the render's own corner (its solid backdrop)
    /// by more than a hair — `SlatePaneRenderTests`' own measure, composited
    /// over white first since a transparent pixel's own channels read as
    /// black otherwise and the whole band would falsely read as ink.
    private func isInk(_ c: NSColor, against backdrop: NSColor) -> Bool {
        let backdropOnWhite = (backdrop.redComponent + backdrop.greenComponent + backdrop.blueComponent) / 3
            * backdrop.alphaComponent + (1 - backdrop.alphaComponent)
        let onWhite = (c.redComponent + c.greenComponent + c.blueComponent) / 3
            * c.alphaComponent + (1 - c.alphaComponent)
        return abs(onWhite - backdropOnWhite) > 0.08
    }

    /// Whether any pixel in `rows` (bitmap pixel rows, top-down) differs from
    /// the rep's own top-left corner — the band's own backdrop, since the
    /// detail panel draws no chrome of its own behind its text.
    private func hasInk(in rep: NSBitmapImageRep, rows: Range<Int>) -> Bool {
        guard let backdrop = rep.colorAt(x: 0, y: 0) else { return false }
        for y in rows where y >= 0 && y < rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if isInk(c, against: backdrop) { return true }
            }
        }
        return false
    }

    /// Both ends of the fixture's detail — the header naming the host plus
    /// its close button, and `RolloverPolicySection`'s own trailing caption —
    /// draw ink somewhere in the detail scroll view's DOCUMENT, the same
    /// `NSHostingView` + `cacheDisplay` technique `SlatePaneRenderTests` uses.
    /// Rendering the document view directly, rather than the window's
    /// visible viewport, is what lets this see past the fold: AppKit draws
    /// whatever portion of a view's own bounds `cacheDisplay` asks for,
    /// independent of how much of it a clip view currently shows — which is
    /// exactly what "reachable by scrolling" means for content that is never
    /// otherwise materialized outside a live window.
    func testTheFirstAndLastDetailFieldsDrawInkInsideTheScrollAreasDocument() async throws {
        let (window, host) = try await mount()
        defer { window.orderOut(nil) }

        let allScrollViews = scrollViews(in: host)
        let detailScroll = try XCTUnwrap(
            allScrollViews.first { $0 !== listScrollView(in: host) },
            "no detail scroll view found")
        let document = try XCTUnwrap(detailScroll.documentView)
        let rep = try XCTUnwrap(document.bitmapImageRepForCachingDisplay(in: document.bounds))
        document.cacheDisplay(in: document.bounds, to: rep)

        let scale = document.bounds.height > 0 ? CGFloat(rep.pixelsHigh) / document.bounds.height : 1
        let bandHeight = Int(24 * scale)
        XCTAssertTrue(hasInk(in: rep, rows: 0..<bandHeight),
                     "no ink in the document's first \(bandHeight)px — the host's own name header "
                     + "did not draw")
        XCTAssertTrue(hasInk(in: rep, rows: (rep.pixelsHigh - bandHeight)..<rep.pixelsHigh),
                     "no ink in the document's last \(bandHeight)px — the rollover section's own "
                     + "trailing caption did not draw, so the document is shorter than the fixture's "
                     + "real content")
    }
}
