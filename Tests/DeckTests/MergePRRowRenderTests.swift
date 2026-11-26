import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What `MergePRRow` DRAWS for a ready-to-merge row, a served-sessions
/// machine, each `MergePressState`, and the quiet advice line — at the two
/// widths the item names and in both appearances. Renders via
/// `NSHostingView` + `cacheDisplay`, the same harness
/// `MergeRefusalRowRenderTests` uses and for the same reason (`ImageRenderer`
/// draws `ScrollView` contents blank).
@MainActor
final class MergePRRowRenderTests: XCTestCase {
    private func row(position: PRLadder.Position = .readyToMerge, headSha: String? = "deadbeef1234") -> PRLadder.LadderResult {
        PRLadder.LadderResult(
            repo: "acme/widgets", number: 42, title: "A pull request", author: "someone",
            position: position, staleReviewCount: 0, updatedAt: nil, headSha: headSha)
    }

    private func render(
        _ view: MergePRRow, width: CGFloat, appearance: Appearance
    ) async throws -> NSBitmapImageRep {
        let framed = view
            .frame(width: width, alignment: .leading)
            .background(appearance == .dark ? Color(white: 0.145) : Color(white: 0.98))
        let host = NSHostingView(rootView: framed)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 160))
        host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        defer { window.orderOut(nil) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func isInk(_ c: NSColor, against backdrop: NSColor) -> Bool {
        let delta = abs(c.redComponent - backdrop.redComponent)
            + abs(c.greenComponent - backdrop.greenComponent)
            + abs(c.blueComponent - backdrop.blueComponent)
        return delta > 0.05
    }

    private func inkedPixelCount(_ rep: NSBitmapImageRep) -> Int {
        guard let backdrop = rep.colorAt(x: 0, y: rep.pixelsHigh - 1) else { return 0 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if isInk(c, against: backdrop) { count += 1 }
            }
        }
        return count
    }

    private let allStates: [MergePressState] = [
        .idle, .confirmingMerge, .confirmingClose, .working, .noCredential,
        .refused(.conflict), .refused(.servesSessions(.configuredHostResolvesHere)),
        .reported(.closed), .reported(.waitingOnLeaseHolder), .reported(.reportFailed(reason: "boom")),
        .closed,
    ]

    /// Every state draws something non-blank at both widths and both
    /// appearances — a row never silently disappears regardless of what
    /// state it is in.
    func testEveryStateDrawsNonBlankAtBothWidthsAndAppearances() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                for state in allStates {
                    let view = MergePRRow(
                        row: row(), state: state, appearance: appearance, advice: .notAvailable,
                        servedSessionsReason: nil)
                    let rep = try await render(view, width: width, appearance: appearance)
                    XCTAssertGreaterThan(
                        inkedPixelCount(rep), 0, "\(state) drew nothing at \(width)pt, \(appearance)")
                }
            }
        }
    }

    /// A ready-to-merge row with a known head offers a merge button naming
    /// it — drawn ink differs from the same row with no head at all (which
    /// offers nothing to confirm), proving the button's presence is what
    /// the extra ink is, not a coincidence of layout.
    func testAReadyToMergeRowWithAHeadDrawsMoreThanOneWithNone() async throws {
        let withHead = MergePRRow(
            row: row(headSha: "deadbeef1234"), state: .idle, appearance: .light, advice: .notAvailable,
            servedSessionsReason: nil)
        let withoutHead = MergePRRow(
            row: row(headSha: nil), state: .idle, appearance: .light, advice: .notAvailable,
            servedSessionsReason: nil)
        let withHeadRep = try await render(withHead, width: 320, appearance: .light)
        let withoutHeadRep = try await render(withoutHead, width: 320, appearance: .light)
        XCTAssertNotEqual(inkedPixelCount(withHeadRep), inkedPixelCount(withoutHeadRep))
    }

    /// A row not at `.readyToMerge` draws the close button alone (never a
    /// merge button) — still non-blank, since close is still offered.
    func testANonReadyToMergeOpenRowStillDrawsSomething() async throws {
        let view = MergePRRow(
            row: row(position: .inReview), state: .idle, appearance: .light, advice: .notAvailable,
            servedSessionsReason: nil)
        let rep = try await render(view, width: 320, appearance: .light)
        XCTAssertGreaterThan(inkedPixelCount(rep), 0)
    }

    /// A held row — passing reviews and CI, but labelled `hold` — offers no
    /// Merge button; it draws the same as any other non-ready open row
    /// (Close alone), and strictly less ink than the same head at
    /// `.readyToMerge`, which also offers the Merge button.
    func testAHeldRowOffersNoMergeButton() async throws {
        let ready = MergePRRow(
            row: row(position: .readyToMerge), state: .idle, appearance: .light, advice: .notAvailable,
            servedSessionsReason: nil)
        let held = MergePRRow(
            row: row(position: .held), state: .idle, appearance: .light, advice: .notAvailable,
            servedSessionsReason: nil)
        let readyRep = try await render(ready, width: 320, appearance: .light)
        let heldRep = try await render(held, width: 320, appearance: .light)
        XCTAssertGreaterThan(inkedPixelCount(heldRep), 0, "Close must still draw")
        XCTAssertGreaterThan(
            inkedPixelCount(readyRep), inkedPixelCount(heldRep),
            "ready-to-merge draws a Merge button on top of Close; held must not")
    }

    /// A row on a repository with no CI captured, every review approved,
    /// offers the Merge button: it draws as much ink as `.readyToMerge` and
    /// more than a held row, which offers Close alone.
    func testAReadyWithoutCIRowOffersTheMergeButton() async throws {
        let ready = MergePRRow(
            row: row(position: .readyToMerge), state: .idle, appearance: .light, advice: .notAvailable,
            servedSessionsReason: nil)
        let withoutCI = MergePRRow(
            row: row(position: .readyToMergeWithoutCI), state: .idle, appearance: .light, advice: .notAvailable,
            servedSessionsReason: nil)
        let held = MergePRRow(
            row: row(position: .held), state: .idle, appearance: .light, advice: .notAvailable,
            servedSessionsReason: nil)
        let readyRep = try await render(ready, width: 320, appearance: .light)
        let withoutCIRep = try await render(withoutCI, width: 320, appearance: .light)
        let heldRep = try await render(held, width: 320, appearance: .light)
        XCTAssertEqual(inkedPixelCount(withoutCIRep), inkedPixelCount(readyRep))
        XCTAssertGreaterThan(inkedPixelCount(withoutCIRep), inkedPixelCount(heldRep))
    }

    /// A closed/merged row offers neither button, but still draws the
    /// quiet advice line, so it is never fully blank.
    func testAClosedRowDrawsOnlyTheAdviceLine() async throws {
        let closedRow = row(position: .closed(.merged))
        let openRow = row(position: .inReview)
        let closedView = MergePRRow(
            row: closedRow, state: .idle, appearance: .light, advice: .notAvailable, servedSessionsReason: nil)
        let openView = MergePRRow(
            row: openRow, state: .idle, appearance: .light, advice: .notAvailable, servedSessionsReason: nil)
        let closedRep = try await render(closedView, width: 320, appearance: .light)
        let openRep = try await render(openView, width: 320, appearance: .light)
        XCTAssertGreaterThan(inkedPixelCount(closedRep), 0)
        // The open row offers a close button on top of the same advice line,
        // so it must draw strictly more ink.
        XCTAssertGreaterThan(inkedPixelCount(openRep), inkedPixelCount(closedRep))
    }

    /// On a machine that serves sessions, the row draws the served-sessions
    /// refusal line and a github.com link instead of any button — distinct
    /// ink from the ordinary button row, so the two can never be confused.
    func testAServedSessionsMachineDrawsTheLinkFormNotAButton() async throws {
        let withButton = MergePRRow(
            row: row(), state: .idle, appearance: .light, advice: .notAvailable, servedSessionsReason: nil)
        let withLink = MergePRRow(
            row: row(), state: .idle, appearance: .light, advice: .notAvailable,
            servedSessionsReason: .configuredHostResolvesHere)
        let buttonRep = try await render(withButton, width: 320, appearance: .light)
        let linkRep = try await render(withLink, width: 320, appearance: .light)
        XCTAssertGreaterThan(inkedPixelCount(buttonRep), 0)
        XCTAssertGreaterThan(inkedPixelCount(linkRep), 0)
        XCTAssertNotEqual(inkedPixelCount(buttonRep), inkedPixelCount(linkRep))
    }

    /// Both served-sessions sub-reasons draw the link form — neither ever
    /// shows a merge button.
    func testBothServedSessionsReasonsDrawTheLinkForm() async throws {
        for reason: MergeRefusal.ServesSessionsReason in [.configuredHostResolvesHere, .builderInstalledHere] {
            let view = MergePRRow(
                row: row(), state: .idle, appearance: .light, advice: .notAvailable, servedSessionsReason: reason)
            let rep = try await render(view, width: 320, appearance: .light)
            XCTAssertGreaterThan(inkedPixelCount(rep), 0)
        }
    }

    /// A row that already merged or closed no longer offers either button,
    /// before the ladder refresh has caught up with it.
    func testASettledRowDrawsDifferentlyFromAnIdleRow() async throws {
        let idle = MergePRRow(
            row: row(), state: .idle, appearance: .light, advice: .notAvailable, servedSessionsReason: nil)
        let idleRep = try await render(idle, width: 320, appearance: .light)
        for state: MergePressState in [.reported(.closed), .closed] {
            let settled = MergePRRow(
                row: row(), state: state, appearance: .light, advice: .notAvailable, servedSessionsReason: nil)
            let settledRep = try await render(settled, width: 320, appearance: .light)
            XCTAssertNotEqual(inkedPixelCount(settledRep), inkedPixelCount(idleRep), "\(state)")
        }
    }

    /// 0003's offer to remove a pasted token draws only when one is stored.
    func testTheRemoveTokenOfferDrawsOnlyWhenATokenIsStored() async throws {
        func view(stored: Bool) -> MergePRRow {
            MergePRRow(
                row: row(), state: .idle, appearance: .light, advice: .notAvailable,
                servedSessionsReason: .builderInstalledHere, pastedTokenStored: stored)
        }
        let without = try await render(view(stored: false), width: 320, appearance: .light)
        let with = try await render(view(stored: true), width: 320, appearance: .light)
        XCTAssertGreaterThan(inkedPixelCount(with), inkedPixelCount(without))
    }

    /// The quiet advice line draws differently depending on what it says —
    /// never a fixed string regardless of the answer.
    func testTheAdviceLineDrawsDifferentlyForDifferentAnswers() async throws {
        let notAvailable = MergePRRow(
            row: row(), state: .idle, appearance: .light, advice: .notAvailable, servedSessionsReason: nil)
        let advice = MergePRRow(
            row: row(), state: .idle, appearance: .light, advice: .advice("clear to merge"),
            servedSessionsReason: nil)
        let notAvailableRep = try await render(notAvailable, width: 320, appearance: .light)
        let adviceRep = try await render(advice, width: 320, appearance: .light)
        XCTAssertNotEqual(inkedPixelCount(notAvailableRep), inkedPixelCount(adviceRep))
    }

    // MARK: - MergePRRow.reportedLine

    func testReportedLineNamesEachOutcomeDistinctly() {
        let lines = [
            MergePRRow.reportedLine(.closed),
            MergePRRow.reportedLine(.waitingOnLeaseHolder),
            MergePRRow.reportedLine(.reportFailed(reason: "boom")),
        ]
        XCTAssertEqual(Set(lines).count, lines.count)
    }

    func testReportFailedLineCarriesTheReasonVerbatim() {
        XCTAssertTrue(MergePRRow.reportedLine(.reportFailed(reason: "a specific failure")).contains("a specific failure"))
    }
}
