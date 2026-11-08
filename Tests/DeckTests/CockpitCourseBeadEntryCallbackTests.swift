import XCTest
@testable import Deck

/// `CockpitView.onOpenBead` carries the resolved bead id through unchanged
/// (issue_01M5CRQ3ETH6AMM5Y5M95RACDG) — `CockpitView` itself never derives
/// one from `Crew`. Built the same way `ContentView.openSelectedCrewBead()`
/// builds the closure it hands the rail (`{ openViewer(.kb(id: open.beadId),
/// target: open.target) }`), so this pins the whole path from
/// `CockpitResolution.beadAvailability` to the viewer open call without
/// needing `ContentView`'s own private state.
@MainActor
final class CockpitCourseBeadEntryCallbackTests: XCTestCase {
    private let target = TestHost.target

    private func crew(bead: String?) -> Crew {
        var c = Crew(id: "deck", displayName: "Deck")
        c.bead = bead
        return c
    }

    /// The entry's callback, invoked, opens exactly the bead
    /// `CockpitResolution.beadId` resolved for the crew — never a guess from
    /// the crew's id, display name, or project (`CockpitResolution.beadId`'s
    /// own "PICKED, NOT DERIVED").
    func testTheCallbackOpensTheResolvedBeadId() {
        let availability = CockpitResolution.beadAvailability(
            hasSelection: true, crew: crew(bead: "deck/bead/deck"), target: target)

        var openedRef: DeckOpenRef.Origin?
        var openedTarget: SSHTarget?
        let onOpenBead: (() -> Void)? = availability.openable.map { open in
            { openedRef = .kb(id: open.beadId); openedTarget = open.target }
        }

        let view = CockpitView(
            model: CockpitModel(), unresolvedReason: nil, appearance: .light,
            onSelectCorrection: { _ in }, onOpenBead: onOpenBead, beadHelp: availability.help)

        view.onOpenBead?()

        XCTAssertEqual(openedRef, .kb(id: "deck/bead/deck"))
        XCTAssertEqual(openedTarget, target)
    }

    /// A crew with no bead resolves `onOpenBead` to nil — the entry draws
    /// inert rather than calling through to a document that does not exist.
    func testNoBeadResolvesTheCallbackToNil() {
        let availability = CockpitResolution.beadAvailability(
            hasSelection: true, crew: crew(bead: nil), target: target)
        let onOpenBead: (() -> Void)? = availability.openable.map { open in
            { _ = open }
        }

        let view = CockpitView(
            model: CockpitModel(), unresolvedReason: nil, appearance: .light,
            onSelectCorrection: { _ in }, onOpenBead: onOpenBead, beadHelp: availability.help)

        XCTAssertNil(view.onOpenBead)
        XCTAssertEqual(view.beadHelp, "Deck names no bead. Choose one in Settings \u{203a} Sessions.")
    }

    /// A `CockpitView` built the way every call site that predates this item
    /// still builds one — naming neither `onOpenBead` nor `beadHelp` — draws
    /// NEITHER field, not a fallback sentence. `CockpitRevealRenderTests`
    /// pins the layout consequence (a render that doesn't name a bead keeps
    /// the exact row positions it had before this item); this pins the
    /// property values that render depends on.
    func testAViewBuiltWithNeitherFieldLeavesBothNil() {
        let view = CockpitView(
            model: CockpitModel(), unresolvedReason: nil, appearance: .light,
            onSelectCorrection: { _ in })

        XCTAssertNil(view.onOpenBead)
        XCTAssertNil(view.beadHelp)
    }
}
