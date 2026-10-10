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
    /// — the toolbar's segmented control, the viewer's "Edit" button,
    /// `openItem`, and `openViewer`'s two routed cases. A raw
    /// `columnOccupant = .editor(...)` (etc.) anywhere in the file would
    /// still change what the docked column shows, so nothing but a source
    /// check catches it leaving the narrow sheet unsummoned.
    func testEveryOccupantIsOpenedThroughPresentColumnOccupant() throws {
        let source = try contentView
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "presentColumnOccupant(").count - 1, 5,
            "expected the toolbar picker, the viewer's edit button, openItem, "
            + "and openViewer's .item/.pane cases to each call presentColumnOccupant")
    }

    /// Every close button returns to `.cockpit` through `closeColumnOccupant`,
    /// which also dismisses the narrow sheet — a raw `columnOccupant = .cockpit`
    /// would leave `isColumnSheetPresented` stuck `true`, so closing a pane in
    /// the narrow layout would appear to do nothing.
    func testClosingAnOccupantGoesThroughCloseColumnOccupant() throws {
        let source = try contentView
        // Exactly one occurrence: `closeColumnOccupant`'s own definition. Any
        // more means a close site is assigning `.cockpit` directly instead of
        // calling it — bypassing the sheet-dismiss it also performs.
        XCTAssertEqual(
            source.components(separatedBy: "columnOccupant = .cockpit").count - 1, 1,
            "a close site is assigning `.cockpit` directly instead of calling closeColumnOccupant()")
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "closeColumnOccupant").count - 1, 5,
            "expected the shell tab, the local-terminal tab, the editor, the "
            + "item pane, and the viewer header to each reference closeColumnOccupant")
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
