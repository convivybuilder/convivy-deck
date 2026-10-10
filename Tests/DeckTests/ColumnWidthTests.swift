import XCTest
@testable import Deck

/// `ContentView.clampedColumnWidth`: the divider's own arithmetic, tested the
/// way `SessionPaneModel`'s other pure predicates are — directly, with no
/// view hosted — at both minimums and past them.
final class ColumnWidthTests: XCTestCase {
    private let totalWidth: Double = 1_000

    // MARK: - Within range

    func testALegalWidthPassesThrough() {
        XCTAssertEqual(ContentView.clampedColumnWidth(400, totalWidth: totalWidth), 400)
    }

    // MARK: - The right column's own floor

    func testAtTheRightColumnMinimumPassesThrough() {
        XCTAssertEqual(
            ContentView.clampedColumnWidth(ThemeConfiguration.minimumColumnWidth,
                                           totalWidth: totalWidth),
            ThemeConfiguration.minimumColumnWidth)
    }

    func testBelowTheRightColumnMinimumClampsUpToIt() {
        XCTAssertEqual(
            ContentView.clampedColumnWidth(10, totalWidth: totalWidth),
            ThemeConfiguration.minimumColumnWidth)
    }

    func testANegativeProposalClampsUpToTheMinimum() {
        XCTAssertEqual(
            ContentView.clampedColumnWidth(-500, totalWidth: totalWidth),
            ThemeConfiguration.minimumColumnWidth)
    }

    // MARK: - The conversation's floor, on the other side of the divider

    func testAtTheConversationMinimumPassesThrough() {
        let maxRight = totalWidth - ContentView.mainPaneMinWidth
        XCTAssertEqual(ContentView.clampedColumnWidth(maxRight, totalWidth: totalWidth), maxRight)
    }

    func testPastTheConversationMinimumClampsDownToItsFloor() {
        let maxRight = totalWidth - ContentView.mainPaneMinWidth
        XCTAssertEqual(
            ContentView.clampedColumnWidth(totalWidth, totalWidth: totalWidth), maxRight,
            "dragging past the conversation's floor must not squeeze it to nothing")
    }

    // MARK: - A window too narrow to honour both floors at once

    /// Neither floor can be fully honoured when the row itself is narrower
    /// than their sum — the divider still returns something sane (the right
    /// column's own minimum) rather than a negative or nonsensical width.
    func testADegenerateTotalWidthStillReturnsTheRightColumnMinimum() {
        let tiny = ThemeConfiguration.minimumColumnWidth + ContentView.mainPaneMinWidth - 200
        XCTAssertEqual(
            ContentView.clampedColumnWidth(9_999, totalWidth: tiny),
            ThemeConfiguration.minimumColumnWidth)
    }

    // MARK: - A drag in flight is shown without being stored

    /// The store is `@Published`, so writing it on every tick of a drag
    /// re-evaluates the whole shell — the "herky-jerky" redrawing the operator
    /// reported. The drag's width lives in local state instead, and this is
    /// the choice that lets the column follow the pointer without it.
    func testADragInFlightIsWhatTheColumnShows() {
        XCTAssertEqual(
            ContentView.effectiveColumnWidth(dragging: 500, stored: 320,
                                             totalWidth: totalWidth),
            500)
    }

    /// And once the gesture ends the column reads the stored value again, so a
    /// later change from Settings or a shortcut is not masked by a finished
    /// drag's leftover.
    func testWithNoDragTheStoredWidthIsWhatTheColumnShows() {
        XCTAssertEqual(
            ContentView.effectiveColumnWidth(dragging: nil, stored: 320,
                                             totalWidth: totalWidth),
            320)
    }

    /// A drag is clamped by the same floors as a stored width — it must not be
    /// able to show a width the config would refuse to hold, or releasing the
    /// mouse would snap the column somewhere the drag never went.
    func testADragIsHeldToTheSameFloorsAsAStoredWidth() {
        XCTAssertEqual(
            ContentView.effectiveColumnWidth(dragging: 10, stored: 320,
                                             totalWidth: totalWidth),
            ThemeConfiguration.minimumColumnWidth)
        XCTAssertEqual(
            ContentView.effectiveColumnWidth(dragging: 9_999, stored: 320,
                                             totalWidth: totalWidth),
            totalWidth - ContentView.mainPaneMinWidth)
    }
}

/// The one thing about the divider a unit test can reach.
///
/// The handle's real failures were a cursor that never appeared and a drag
/// that re-rendered the app per pixel, and neither is visible to a suite with
/// no UI target — which is why they shipped past two reviews and a green CI
/// with `ColumnWidthTests` above passing throughout. These guard the two
/// patterns that caused them, at the only level available. They are a
/// backstop, not coverage: the fix itself was verified by hand.
final class DividerImplementationGuardTests: XCTestCase {

    private var contentView: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // DeckTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // repo root
            return try String(
                contentsOf: root.appendingPathComponent("Sources/Deck/App/ContentView.swift"),
                encoding: .utf8)
        }
    }

    /// `NSCursor.push()` puts a cursor on a stack that any AppKit view can
    /// overwrite, and the divider's two neighbours — SwiftTerm's terminal view
    /// and WKWebView — both set their own from their tracking areas as the
    /// mouse moves. The push won once and was gone by the next mouse-moved
    /// event, so the resize glyph never appeared. `.set()` on every hover tick
    /// is what survives that.
    func testTheDividerDoesNotPushACursorOntoTheStack() throws {
        let source = try contentView
        XCTAssertFalse(source.contains("NSCursor.resizeLeftRight.push()"),
                       "a pushed cursor loses to the panes either side of the handle")
    }

    /// A drag tick that writes `ThemeStore.configuration` republishes it, and
    /// the whole shell re-evaluates — rail, chrome, terminals, web panes — once
    /// per pixel of travel. The store is written once, at the end of the
    /// gesture, from `onCommit`.
    func testTheDragDoesNotWriteTheStoreOnEveryTick() throws {
        let source = try contentView
        // The per-tick path is everything between the binding's setter and the
        // commit that follows it. Failing loudly when either landmark moves
        // beats passing on a substring that no longer means anything.
        guard let setter = source.range(of: "set: { newValue in"),
              let commit = source.range(of: "onCommit: {"),
              setter.upperBound < commit.lowerBound else {
            return XCTFail("could not isolate the divider's per-tick setter — update this guard")
        }
        // Comments stripped, indentation and all. A guard that reads prose as
        // code fails on the sentence explaining why the code is right — three
        // times over in one day, across this suite and the launcher's.
        let perTick = source[setter.upperBound..<commit.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(perTick.contains("store."),
                       "the per-tick setter must not touch the store:\n\(perTick)")
    }
}
