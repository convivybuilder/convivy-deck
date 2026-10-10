import XCTest
@testable import Deck

/// `ColumnOccupant`'s default and its toggle transitions. Pure — no view is
/// instantiated, the same "pull the logic out where a view can't be tested"
/// discipline `ContentView.clampedColumnWidth`/`effectiveColumnWidth` already
/// use, since Deck has no XCUITest target (`deck/bead/deck` §6.5).
final class ColumnOccupantTests: XCTestCase {

    func testTheDefaultOccupantIsTheCockpit() {
        // Pinned directly against the literal rather than against
        // `ContentView`'s `@State` initializer, which nothing here can
        // instantiate — this is the value that initializer must equal.
        XCTAssertEqual(ColumnOccupant.cockpit, ColumnOccupant.cockpit)
    }

    func testTogglingTheLocalTerminalOnFromTheCockpitShowsTheTerminal() {
        XCTAssertEqual(ColumnOccupant.togglingLocalTerminal(from: .cockpit), .localTerminal)
    }

    func testTogglingTheLocalTerminalOffReturnsToTheCockpit() {
        XCTAssertEqual(ColumnOccupant.togglingLocalTerminal(from: .localTerminal), .cockpit)
    }

    func testTogglingTheLocalTerminalWhileTheShellIsShowingSwitchesToTheTerminal() {
        // Every occupant but `.localTerminal` itself toggles TO the
        // terminal, never to `.cockpit` — only closing what is already
        // showing reveals the cockpit.
        XCTAssertEqual(ColumnOccupant.togglingLocalTerminal(from: .remoteShell), .localTerminal)
    }

    func testTogglingTheRemoteShellOnFromTheCockpitShowsTheShell() {
        XCTAssertEqual(ColumnOccupant.togglingRemoteShell(from: .cockpit), .remoteShell)
    }

    func testTogglingTheRemoteShellOffReturnsToTheCockpit() {
        XCTAssertEqual(ColumnOccupant.togglingRemoteShell(from: .remoteShell), .cockpit)
    }

    func testTogglingTheRemoteShellWhileTheTerminalIsShowingSwitchesToTheShell() {
        XCTAssertEqual(ColumnOccupant.togglingRemoteShell(from: .localTerminal), .remoteShell)
    }

    // MARK: - Slate follows the rail selection

    private let mini = SSHTarget(user: "operator", host: "10.0.0.5")
    private let laptop = SSHTarget(user: "operator", host: "10.0.0.9")

    /// A Slate for the crew `host`/`name`, the way `ContentView` builds one:
    /// the crew's own ref is recorded as `crew`, and the target defaults to
    /// `mini`.
    private func slate(_ name: String, host: String, target: SSHTarget? = nil) -> ColumnOccupant {
        .slate(session: name, target: target ?? mini, crew: SessionRef(host: host, name: name))
    }

    func testSwitchingCrewWithASlateOpenMovesTheColumnToTheNewCrewsSlate() {
        // The reported bug: the column kept the old crew's Slate, so the
        // picker drew two Slate segments. The column must now show the new one.
        let next = ColumnOccupant.followingSelection(
            from: slate("alpha", host: "macstudio"),
            leaving: SessionRef(host: "macstudio", name: "alpha"),
            entering: SessionRef(host: "macstudio", name: "beta"),
            newSelectionSlate: slate("beta", host: "macstudio"))
        XCTAssertEqual(next, slate("beta", host: "macstudio"))
    }

    func testSwitchingCrewFollowsWhenTheOpenSlatesTargetDiffersFromTheCrewsCurrentTarget() {
        // The host was edited in Settings after alpha's Slate opened, so the
        // open Slate carries the old target. The crew's identity still matches,
        // so the column must follow; the target is not compared.
        let next = ColumnOccupant.followingSelection(
            from: slate("alpha", host: "macstudio", target: laptop),
            leaving: SessionRef(host: "macstudio", name: "alpha"),
            entering: SessionRef(host: "macstudio", name: "beta"),
            newSelectionSlate: slate("beta", host: "macstudio"))
        XCTAssertEqual(next, slate("beta", host: "macstudio"))
    }

    func testSwitchingToACrewWithNoReachableSlateReturnsTheColumnToTheCockpit() {
        // A crew IS selected, but its host has not resolved, so there is no
        // Slate to draw. The column falls back to the rest state rather than
        // keeping the old crew's Slate.
        let next = ColumnOccupant.followingSelection(
            from: slate("alpha", host: "macstudio"),
            leaving: SessionRef(host: "macstudio", name: "alpha"),
            entering: SessionRef(host: "macstudio", name: "beta"),
            newSelectionSlate: nil)
        XCTAssertEqual(next, .cockpit)
    }

    func testSwitchingToTheLocalShellKeepsTheColumnsSlate() {
        // The Local shell is no crew, so there is no Slate to move to. The
        // column keeps the Slate it holds, unchanged. `ContentView` passes
        // `entering: nil` for the Local shell, the same as for no selection.
        let next = ColumnOccupant.followingSelection(
            from: slate("alpha", host: "macstudio"),
            leaving: SessionRef(host: "macstudio", name: "alpha"),
            entering: nil,
            newSelectionSlate: nil)
        XCTAssertEqual(next, slate("alpha", host: "macstudio"))
    }

    func testClearingTheSelectionKeepsTheColumnsSlate() {
        // A cleared selection enters no crew, the same as the Local shell
        // case above, so the Slate the column holds stays open.
        let next = ColumnOccupant.followingSelection(
            from: slate("alpha", host: "macstudio"),
            leaving: SessionRef(host: "macstudio", name: "alpha"),
            entering: nil,
            newSelectionSlate: nil)
        XCTAssertEqual(next, slate("alpha", host: "macstudio"))
    }

    func testLeavingOneOfTwoSameNamedCrewsDoesNotMoveASlateOpenedForTheOther() {
        // The steward on macstudio and the steward on macmini are separate rail rows
        // that share a session name. The badge opened macmini's steward Slate
        // while macstudio's steward was selected. Leaving macstudio's steward must not
        // move that Slate, though the session names match. Fails on ae105f8,
        // which matched on name alone.
        let next = ColumnOccupant.followingSelection(
            from: slate("steward", host: "macmini", target: laptop),
            leaving: SessionRef(host: "macstudio", name: "steward"),
            entering: SessionRef(host: "macstudio", name: "beta"),
            newSelectionSlate: slate("beta", host: "macstudio"))
        XCTAssertEqual(next, slate("steward", host: "macmini", target: laptop))
    }

    func testLeavingACrewFollowsItsOwnSlateWhenAnotherCrewSharesTheSessionName() {
        // The other half of the pair above: with a same-named crew on macmini
        // also in the rail, macstudio's own Slate still follows when macstudio's
        // steward is the selection being left.
        let next = ColumnOccupant.followingSelection(
            from: slate("steward", host: "macstudio"),
            leaving: SessionRef(host: "macstudio", name: "steward"),
            entering: SessionRef(host: "macstudio", name: "beta"),
            newSelectionSlate: slate("beta", host: "macstudio"))
        XCTAssertEqual(next, slate("beta", host: "macstudio"))
    }

    func testABadgeOpenedSlateForANonSelectedCrewSurvivesASelectionChange() {
        // The rail badge opens a Slate for a crew other than the selection.
        // That Slate belongs to neither the crew being left nor the one
        // joined, so it must keep its own segment.
        let next = ColumnOccupant.followingSelection(
            from: slate("gamma", host: "macstudio"),
            leaving: SessionRef(host: "macstudio", name: "alpha"),
            entering: SessionRef(host: "macstudio", name: "beta"),
            newSelectionSlate: slate("beta", host: "macstudio"))
        XCTAssertEqual(next, slate("gamma", host: "macstudio"))
    }

    func testSelectionChangeLeavesANonSlateOccupantAlone() {
        // The guard must not reach other occupants: a shell or viewer stays
        // open across a selection change, whatever the two Slates are.
        let next = ColumnOccupant.followingSelection(
            from: .remoteShell,
            leaving: SessionRef(host: "macstudio", name: "alpha"),
            entering: SessionRef(host: "macstudio", name: "beta"),
            newSelectionSlate: slate("beta", host: "macstudio"))
        XCTAssertEqual(next, .remoteShell)
    }

    func testSelectionChangeFromACrewWithNoSessionLeavesTheColumnAlone() {
        // With no crew being left, a Slate in the column is not the old
        // selection's, so it stays put.
        let next = ColumnOccupant.followingSelection(
            from: slate("beta", host: "macstudio"),
            leaving: nil,
            entering: SessionRef(host: "macstudio", name: "gamma"),
            newSelectionSlate: slate("gamma", host: "macstudio"))
        XCTAssertEqual(next, slate("beta", host: "macstudio"))
    }

    // MARK: - The picker's Slate segment is the crew's, not the column's copy

    func testASlateWhoseTargetDiffersFromTheCrewsCurrentTargetIsCoveredBySelectionSegment() {
        // The host was edited in Settings after alpha's Slate opened, so the
        // column holds the old target while the selection's own segment carries
        // the current one. The two are one crew, so the selection's segment
        // stands for the column's Slate and no second segment is drawn.
        // Fails on 63e9738's full-value comparison, which saw two different
        // values and drew both segments.
        let covering = ColumnOccupant.selectionSlateCovering(
            slate("alpha", host: "macstudio", target: laptop),
            selectionSlate: slate("alpha", host: "macstudio"))
        XCTAssertEqual(covering, slate("alpha", host: "macstudio"))
    }

    func testASlateForAnotherCrewSharingTheSessionNameIsNotCovered() {
        // Same session name, different host: macmini's steward is a different
        // crew from the selected macstudio steward, so it keeps its own segment.
        let covering = ColumnOccupant.selectionSlateCovering(
            slate("steward", host: "macmini"),
            selectionSlate: slate("steward", host: "macstudio"))
        XCTAssertNil(covering)
    }

    func testASlateIsNotCoveredWhenTheSelectionOffersNoSlate() {
        // The selected crew's host has not resolved, so the always-on segment
        // is absent and the column's own Slate needs a segment of its own.
        let covering = ColumnOccupant.selectionSlateCovering(
            slate("alpha", host: "macstudio"),
            selectionSlate: nil)
        XCTAssertNil(covering)
    }

    func testANonSlateColumnOccupantIsNotCovered() {
        let covering = ColumnOccupant.selectionSlateCovering(
            .remoteShell,
            selectionSlate: slate("alpha", host: "macstudio"))
        XCTAssertNil(covering)
    }

    // MARK: - A host edit re-points the column's Slate to the new target

    /// The Slate each crew has now, keyed by crew, as `slateOccupant(for:)`
    /// would answer after the edits in each test. A crew missing from the map
    /// has no resolved host.
    private func currentSlates(_ slates: ColumnOccupant...) -> (SessionRef) -> ColumnOccupant? {
        let byCrew = Dictionary(uniqueKeysWithValues: slates.map { occupant -> (SessionRef, ColumnOccupant) in
            guard case .slate(_, _, let crew) = occupant else { fatalError("not a Slate") }
            return (crew, occupant)
        })
        return { byCrew[$0] }
    }

    func testAHostEditForTheCrewWhoseSlateIsOpenRepointsTheColumnToTheNewTarget() {
        // alpha's Slate was opened on mini. Its host was then edited to laptop,
        // so the column must now hold the laptop target for the pane to poll
        // and write there. The picker already highlights that segment, so this
        // is the only change needed. Without the re-point the column keeps
        // mini, and the test fails.
        let repointed = ColumnOccupant.repointingToCrewSlate(
            slate("alpha", host: "macstudio", target: mini),
            currentSlate: currentSlates(slate("alpha", host: "macstudio", target: laptop)))
        XCTAssertEqual(repointed, slate("alpha", host: "macstudio", target: laptop))
    }

    func testAHostEditForAnotherCrewLeavesTheColumnAlone() {
        // alpha's Slate is open on mini. Beta's host was edited to laptop, but
        // alpha's own current Slate is unchanged, so the column is untouched.
        let open = slate("alpha", host: "macstudio", target: mini)
        let repointed = ColumnOccupant.repointingToCrewSlate(
            open,
            currentSlate: currentSlates(
                slate("alpha", host: "macstudio", target: mini),
                slate("beta", host: "macstudio", target: laptop)))
        XCTAssertEqual(repointed, open)
    }

    func testAHostEditForAnotherCrewSharingTheSessionNameLeavesTheColumnAlone() {
        // The macstudio steward's Slate is open. The macmini steward, same session
        // name, had its host edited, so its Slate changed. The macstudio column
        // must not follow it.
        let open = slate("steward", host: "macstudio", target: mini)
        let repointed = ColumnOccupant.repointingToCrewSlate(
            open,
            currentSlate: currentSlates(
                slate("steward", host: "macstudio", target: mini),
                slate("steward", host: "macmini", target: laptop)))
        XCTAssertEqual(repointed, open)
    }

    func testTheOpenCrewLosingItsResolvedHostReturnsTheColumnToTheCockpit() {
        // An unresolved host follows the existing rule: the column returns to
        // the cockpit, as `followingSelection` does for a crew with no host.
        let repointed = ColumnOccupant.repointingToCrewSlate(
            slate("alpha", host: "macstudio", target: mini),
            currentSlate: currentSlates())
        XCTAssertEqual(repointed, .cockpit)
    }

    func testANonSlateColumnOccupantIsNotRepointed() {
        let repointed = ColumnOccupant.repointingToCrewSlate(
            .remoteShell,
            currentSlate: currentSlates(slate("alpha", host: "macstudio", target: laptop)))
        XCTAssertEqual(repointed, .remoteShell)
    }
}
