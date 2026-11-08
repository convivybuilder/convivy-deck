import XCTest
@testable import Deck

/// `ContentView`'s narrow-column sheet has no view-level test target to
/// exercise it in, so its one real failure mode — a call site quietly going
/// back to a raw `columnOccupant = ...` assignment instead of
/// `presentColumnOccupant`/`closeColumnOccupant` — would pass every other
/// test in this suite while silently breaking the sheet in the narrow
/// layout: the docked layout ignores `isColumnSheetPresented` entirely, so
/// nothing there would notice.
///
/// A backstop on the source, the same posture `DividerImplementationGuardTests`
/// takes on the divider: this does not verify the sheet LOOKS right, only
/// that the wiring a regression would silently drop is still present.
final class ColumnSheetImplementationGuardTests: XCTestCase {

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

    /// Every occupant-opening call site funnels through `presentColumnOccupant`
    /// — directly (the toolbar's segmented control, `revealOrOpenItem`'s
    /// cockpit-reveal case) or through `openNestedColumnOccupant` (the
    /// viewer's "Edit" button, `openItem`, `openSlate`, `toggleRunPane`,
    /// `openReviewRecords`, `openViewer`'s two routed cases, and
    /// `ItemDetailPane`'s own "open item" link) — which itself calls
    /// `presentColumnOccupant` for the occupant-and-sheet mechanics rather
    /// than repeating it (CQ·174). A raw `columnOccupant = .editor(...)`
    /// (etc.) anywhere in the file would still change what the docked
    /// column shows, so nothing but a source check catches it leaving the
    /// narrow sheet unsummoned.
    func testEveryOccupantIsOpenedThroughPresentColumnOccupant() throws {
        let source = try contentView
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "presentColumnOccupant(").count - 1, 2,
            "expected the toolbar picker and revealOrOpenItem's cockpit case to call presentColumnOccupant directly")
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "openNestedColumnOccupant(").count - 1, 6,
            "expected the viewer's edit button, openItem, openSlate, toggleRunPane, openReviewRecords, "
            + "openViewer's .item/.pane cases, and ItemDetailPane's onOpenItem to each call openNestedColumnOccupant")
        XCTAssertTrue(
            source.contains("func openNestedColumnOccupant(_ occupant: ColumnOccupant) {\n        let opened = ColumnOccupant.opening(occupant, from: columnOccupant, trail: columnOccupantStack)\n        presentColumnOccupant(opened.occupant)"),
            "openNestedColumnOccupant must reach presentColumnOccupant for the occupant-and-sheet mechanics, "
            + "not repeat it, so every nested open still summons the narrow sheet the one way the column does")
    }

    /// Every close either returns to `.cockpit` through `closeColumnOccupant`
    /// (the shell tab, the local-terminal tab) or retraces the occupant's own
    /// back trail through `closeNestedColumnOccupant` (the viewer, the
    /// editor, the item pane, the run pane, the reviews pane, the Slate —
    /// CQ·174's generalized back step), which falls back to
    /// `closeColumnOccupant` once its trail is empty. A raw
    /// `columnOccupant = .cockpit` anywhere else would leave
    /// `isColumnSheetPresented` stuck `true`, so closing a pane in the
    /// narrow layout would appear to do nothing.
    func testClosingAnOccupantGoesThroughCloseColumnOccupant() throws {
        let source = try contentView
        // Exactly one occurrence: `closeColumnOccupant`'s own definition. Any
        // more means a close site is assigning `.cockpit` directly instead of
        // calling it — bypassing the sheet-dismiss it also performs.
        XCTAssertEqual(
            source.components(separatedBy: "columnOccupant = .cockpit").count - 1, 1,
            "a close site is assigning `.cockpit` directly instead of calling closeColumnOccupant()")
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "closeNestedColumnOccupant").count - 1, 6,
            "expected the viewer header, the editor's Done and Close, the item pane, the run pane, "
            + "the reviews pane, and the Slate to each reference closeNestedColumnOccupant")
        XCTAssertTrue(
            source.contains("guard next.occupant != .cockpit else {\n            closeColumnOccupant()"),
            "closeNestedColumnOccupant must fall back to closeColumnOccupant once its trail is empty, "
            + "so a close that reaches the cockpit still dismisses the narrow sheet")
    }

    /// The toolbar's segmented control must not bind `$columnOccupant`
    /// directly — that would set the column's content without ever
    /// summoning the narrow sheet.
    func testTheToolbarPickerDoesNotBindTheRawState() throws {
        let source = try contentView
        XCTAssertFalse(source.contains("selection: $columnOccupant"),
                       "the picker must summon the sheet via presentColumnOccupant, not bind $columnOccupant directly")
    }
}
