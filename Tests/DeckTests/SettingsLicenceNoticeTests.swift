import XCTest
import SwiftUI
import AppKit
@testable import Deck

/// What the General tab draws for the licence notice, hosted in an
/// `NSHostingView` like `SettingsLayoutTests`: headless, no window server.
@MainActor
final class SettingsLicenceNoticeTests: XCTestCase {
    private let full = LicenceNotice(
        notice: "Convivy Builder\nCopyright 2026 Convivy\n\nThis product includes software.\n",
        license: "Apache License\n")

    private func host<V: View>(_ view: V, width: CGFloat = 460, height: CGFloat = 200)
        -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    // MARK: - What the section draws
    //
    // Decided by `LicenceNotice.presentation`, so it is asserted there. The
    // accessibility tree of a headless `NSHostingView` is empty, which leaves no
    // way to read a SwiftUI `Text` back from one; what the rendered pixels look
    // like was checked by eye, in both appearances (see the PR body).

    func testANoticeShowsItsHeadlineAndOffersTheRest() {
        XCTAssertEqual(full.presentation,
                       .available(headline: "Convivy Builder\nCopyright 2026 Convivy"))
    }

    /// The case that must now fail to show a button: nothing to open.
    func testAMissingNoticeSaysSoAndOffersNothingToOpen() {
        XCTAssertEqual(LicenceNotice(notice: nil, license: nil).presentation, .unavailable)
    }

    /// A LICENSE-only bundle still offers the sheet, with no headline over it.
    func testALicenseOnlyBundleStillOffersTheFullText() {
        XCTAssertEqual(LicenceNotice(notice: nil, license: "Apache License\n").presentation,
                       .available(headline: nil))
    }

    func testTheSheetHoldsBothFilesInFullAndInOrder() {
        XCTAssertEqual(full.files, [
            LicenceNotice.File(name: "NOTICE", text: full.notice),
            LicenceNotice.File(name: "LICENSE", text: full.license),
        ])
    }

    func testTheSheetNamesAFileThatIsMissing() {
        let files = LicenceNotice(notice: full.notice, license: nil).files
        XCTAssertEqual(files.map(\.name), ["NOTICE", "LICENSE"])
        XCTAssertNotNil(files[0].text)
        XCTAssertNil(files[1].text, "a nil text is what draws the missing-file message")
    }

    // MARK: - The height floor

    private func settings(showing licence: LicenceNotice, tab: SettingsNavigation.Tab,
                          generalFloor: CGFloat = SettingsView.generalMinimumHeight)
        throws -> NSHostingView<some View> {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("licence-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let navigation = SettingsNavigation()
        navigation.selectedTab = tab
        var settingsView = SettingsView(licence: licence)
        settingsView.generalFloor = generalFloor
        let view = settingsView
            .environmentObject(ThemeStore(fileURL: directory.appendingPathComponent("theme.json")))
            .environmentObject(navigation)
            .environmentObject(RailStateModel())
        return host(view, height: 700)
    }

    /// THE FLOOR IS THE NATURAL HEIGHT, and a change that outgrows it fails here.
    /// The Text tab is pinned at 420pt, so whatever its hosted height exceeds
    /// that by is the window's own chrome (tab bar and top padding); taking it
    /// off the General tab's hosted height leaves the form's height. A grouped
    /// Form is List-backed, so a form taller than its floor scrolls, and the last
    /// rows it hides are the version and the licence notice.
    func testTheGeneralFormFitsItsFloorWithTheNoticeShowing() throws {
        let chrome = try settings(showing: full, tab: .text).fittingSize.height - 420
        let form = try settings(showing: full, tab: .general).fittingSize.height - chrome

        XCTAssertLessThanOrEqual(
            form, SettingsView.generalMinimumHeight,
            "the General form is \(form)pt against a \(SettingsView.generalMinimumHeight)pt "
            + "floor, so a window dragged to the floor scrolls the version and licence away")
    }

    /// Both directions: a floor left above the form's natural height would still
    /// pass the test above, so this measures the form with the floor taken away
    /// and holds the floor to within a few points of it. This is what caught the
    /// floor going stale when the crews-root rows left the tab: the hosted height
    /// still read 454pt, because 454pt was the floor.
    func testTheFloorIsNotStale() throws {
        let chrome = try settings(showing: full, tab: .text).fittingSize.height - 420
        let natural = try settings(showing: full, tab: .general, generalFloor: 0)
            .fittingSize.height - chrome

        XCTAssertEqual(
            natural, SettingsView.generalMinimumHeight, accuracy: 8,
            "the General form is \(natural)pt naturally against a "
            + "\(SettingsView.generalMinimumHeight)pt floor, so the floor no longer "
            + "describes the form")
    }
}
