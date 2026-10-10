import XCTest
@testable import Deck

/// `CockpitResolution` — what the cockpit and the bead link resolve to.
///
/// THESE EXIST BECAUSE A BUG HID WHERE THEY COULD NOT REACH. The bead action
/// resolved its host through the cockpit's own resolution, which requires
/// `crew.project`, so a crew carrying a bead and no project got a permanently
/// disabled button and a tooltip telling the operator to set a project — which
/// would not have helped. All four answers were `private` methods on
/// `ContentView`, so no test could say the two fields are orthogonal.
final class CockpitResolutionTests: XCTestCase {
    private let target = TestHost.target

    private func crew(project: String? = nil, bead: String? = nil, repo: String? = nil) -> Crew {
        var c = Crew(id: "deck", displayName: "Deck")
        c.project = project
        c.bead = bead
        c.repo = repo
        return c
    }

    // MARK: - The bug: bead and project are orthogonal

    /// The regression. A crew with a bead and NO project must still open it —
    /// a bead needs a bead and a host, and nothing else.
    func testABeadOpensWithNoProjectSet() {
        let open = CockpitResolution.beadAvailability(
            hasSelection: true, crew: crew(project: nil, bead: "deck/bead/deck"),
            target: target).openable

        XCTAssertEqual(open?.beadId, "deck/bead/deck")
        XCTAssertEqual(open?.target, target)
    }

    /// The mirror. A project without a bead draws a cockpit and no bead link,
    /// rather than one standing in for the other.
    func testAProjectWithoutABeadResolvesTheCockpitAndNoBead() {
        let c = crew(project: "convivy-deck", bead: nil)

        XCTAssertEqual(CockpitResolution.projectAndTarget(for: c, target: target)?.project,
                       "convivy-deck")
        XCTAssertNil(CockpitResolution.beadAvailability(
            hasSelection: true, crew: c, target: target).openable)
    }

    func testNeitherResolvesWithoutAHost() {
        let c = crew(project: "convivy-deck", bead: "deck/bead/deck")

        XCTAssertNil(CockpitResolution.beadAvailability(
            hasSelection: true, crew: c, target: nil).openable)
        XCTAssertNil(CockpitResolution.projectAndTarget(for: c, target: nil))
    }

    // MARK: - prLadderRepos

    /// Read straight off the crew's own `repos` field — never guessed from
    /// `project`, since the two are different naming spaces (see this
    /// function's own doc: the Keel crew's project is `bosun`, its repo is
    /// `convivy/agent-platform`).
    func testPrLadderReposReadsTheCrewsOwnRepoField() {
        let resolved = CockpitResolution.prLadderRepos(for: crew(project: "bosun", repo: "convivy/agent-platform"))
        XCTAssertEqual(resolved.repos.map(\.owner), ["convivy"])
        XCTAssertEqual(resolved.repos.map(\.repoName), ["agent-platform"])
        XCTAssertEqual(resolved.droppedByCap, 0)
    }

    /// The bug this replaces: a project alone must never be read as a repo.
    func testPrLadderReposIsEmptyWithAProjectAndNoRepo() {
        XCTAssertTrue(CockpitResolution.prLadderRepos(for: crew(project: "bosun", repo: nil)).repos.isEmpty)
    }

    func testPrLadderReposIsEmptyWithNoRepo() {
        XCTAssertTrue(CockpitResolution.prLadderRepos(for: crew(repo: nil)).repos.isEmpty)
    }

    func testPrLadderReposIsEmptyWithNoCrew() {
        XCTAssertTrue(CockpitResolution.prLadderRepos(for: nil).repos.isEmpty)
    }

    /// A malformed repo (missing the slash, an empty segment, a bad
    /// character) refuses that entry rather than guessing.
    func testPrLadderReposDropsAMalformedIdentity() {
        XCTAssertTrue(CockpitResolution.prLadderRepos(for: crew(repo: "convivy-deck")).repos.isEmpty)
        XCTAssertTrue(CockpitResolution.prLadderRepos(for: crew(repo: "convivy/")).repos.isEmpty)
        XCTAssertTrue(CockpitResolution.prLadderRepos(for: crew(repo: "convivy/deck; rm -rf /")).repos.isEmpty)
    }

    /// Several repos, in configured order — the case `crew.repo`'s own
    /// single-value setter can't build, so this constructs `Crew` directly.
    func testPrLadderReposReturnsEveryValidEntryInOrder() {
        var c = Crew(id: "selector", displayName: "Selector")
        c.repos = ["convivy/selector", "convivy/selector-backend"]
        let resolved = CockpitResolution.prLadderRepos(for: c)
        XCTAssertEqual(resolved.repos.map(\.identity), ["convivy/selector", "convivy/selector-backend"])
        XCTAssertEqual(resolved.droppedByCap, 0)
    }

    /// A malformed entry among valid ones costs only itself — the "field
    /// costs itself" discipline this function's own doc claims.
    func testPrLadderReposDropsOnlyTheMalformedEntry() {
        var c = Crew(id: "selector", displayName: "Selector")
        c.repos = ["convivy/selector", "not a repo", "convivy/selector-backend"]
        let resolved = CockpitResolution.prLadderRepos(for: c)
        XCTAssertEqual(resolved.repos.map(\.identity), ["convivy/selector", "convivy/selector-backend"])
    }

    /// Duplicates collapse to their first occurrence, preserving order.
    func testPrLadderReposCollapsesDuplicatesToTheirFirstOccurrence() {
        var c = Crew(id: "selector", displayName: "Selector")
        c.repos = ["convivy/selector", "convivy/selector-backend", "convivy/selector"]
        let resolved = CockpitResolution.prLadderRepos(for: c)
        XCTAssertEqual(resolved.repos.map(\.identity), ["convivy/selector", "convivy/selector-backend"])
    }

    /// A crew naming more repos than `maxFollowedRepos` is capped, and the
    /// panel is told how many were dropped rather than silently seeing a
    /// shorter list than it configured.
    func testPrLadderReposCapsAtMaxFollowedReposAndReportsTheOverflow() {
        var c = Crew(id: "many", displayName: "Many")
        let all = (1...(CockpitResolution.maxFollowedRepos + 3)).map { "convivy/repo\($0)" }
        c.repos = all
        let resolved = CockpitResolution.prLadderRepos(for: c)
        XCTAssertEqual(resolved.repos.count, CockpitResolution.maxFollowedRepos)
        XCTAssertEqual(resolved.repos.map(\.identity), Array(all.prefix(CockpitResolution.maxFollowedRepos)))
        XCTAssertEqual(resolved.droppedByCap, 3)
    }

    // MARK: - prLadderUnresolvedReason

    func testPrLadderUnresolvedReasonNamesTheRepoWhenUnset() {
        let reason = CockpitResolution.prLadderUnresolvedReason(
            hasSelection: true, crew: crew(project: "bosun", repo: nil), target: target)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("repository"), reason!)
    }

    func testPrLadderUnresolvedReasonIsNilWhenEverythingResolves() {
        let reason = CockpitResolution.prLadderUnresolvedReason(
            hasSelection: true, crew: crew(repo: "convivy/convivy-deck"), target: target)
        XCTAssertNil(reason)
    }

    func testPrLadderUnresolvedReasonNoSelectionSaysSo() {
        XCTAssertNotNil(CockpitResolution.prLadderUnresolvedReason(
            hasSelection: false, crew: nil, target: nil))
    }

    func testPrLadderUnresolvedReasonNoHostSaysSo() {
        let reason = CockpitResolution.prLadderUnresolvedReason(
            hasSelection: true, crew: crew(repo: "convivy/convivy-deck"), target: nil)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("host"), reason!)
    }

    // MARK: - The bead is picked, never derived

    func testAnEmptyBeadIsNoBeadRatherThanAGuess() {
        XCTAssertNil(CockpitResolution.beadId(for: crew(project: "convivy-deck", bead: "")))
        XCTAssertNil(CockpitResolution.beadId(for: crew(project: "convivy-deck", bead: nil)))
    }

    /// Nothing derives a doc id from a product. `convivy-deck`'s own bead is
    /// `deck/bead/deck`, so a derivation would be wrong for Deck's own crew —
    /// which is exactly the crew an operator clicks first.
    func testTheProductNeverStandsInForTheBeadId() {
        XCTAssertNil(CockpitResolution.beadId(for: crew(project: "convivy-deck", bead: nil)))
    }

    // MARK: - The two tooltips answer different questions

    func testTheBeadReasonNamesTheBeadRatherThanTheProject() {
        let reason = CockpitResolution.beadUnavailableReason(
            hasSelection: true, crew: crew(project: "convivy-deck", bead: nil), target: target)

        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("bead"), "should name what is missing: \(reason!)")
        XCTAssertFalse(reason!.contains("Library project"),
                       "must not send the operator to set a project that is already set")
    }

    func testTheCockpitReasonNamesTheProject() {
        let reason = CockpitResolution.unresolvedReason(
            hasSelection: true, crew: crew(project: nil, bead: "deck/bead/deck"), target: target)

        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("Library project"))
    }

    func testBothAreSilentWhenEverythingResolves() {
        let c = crew(project: "convivy-deck", bead: "deck/bead/deck")

        XCTAssertNil(CockpitResolution.unresolvedReason(hasSelection: true, crew: c, target: target))
        XCTAssertNil(CockpitResolution.beadUnavailableReason(hasSelection: true, crew: c, target: target))
    }

    func testNoSelectionSaysSoForBoth() {
        XCTAssertNotNil(CockpitResolution.unresolvedReason(
            hasSelection: false, crew: nil, target: nil))
        XCTAssertNotNil(CockpitResolution.beadUnavailableReason(
            hasSelection: false, crew: nil, target: nil))
    }

    func testACrewlessSessionSaysSoForBoth() {
        XCTAssertNotNil(CockpitResolution.unresolvedReason(
            hasSelection: true, crew: nil, target: target))
        XCTAssertNotNil(CockpitResolution.beadUnavailableReason(
            hasSelection: true, crew: nil, target: target))
    }

    // MARK: - restStateUnresolvedReason: the `.board`/`.service` answer
    // never asks for a Library project — the bug `unresolvedReason` used to
    // reach the steward through, before `RestStateResolution` existed.

    /// The regression this exists to fix: a crew with no Library project —
    /// which the steward always is, since it has none to name — must never
    /// be told to set one when it is shaped `.board`/`.service`.
    func testARestStateCrewWithNoProjectIsNeverToldToSetOne() {
        let reason = CockpitResolution.restStateUnresolvedReason(
            hasSelection: true, crew: crew(project: nil, bead: nil), target: target)
        XCTAssertNil(reason, "a project-less crew resolves fine on the rest-state path")
    }

    func testRestStateNoSelectionSaysSo() {
        XCTAssertNotNil(CockpitResolution.restStateUnresolvedReason(
            hasSelection: false, crew: nil, target: nil))
    }

    func testRestStateACrewlessSessionSaysSo() {
        XCTAssertNotNil(CockpitResolution.restStateUnresolvedReason(
            hasSelection: true, crew: nil, target: target))
    }

    func testRestStateNoHostConfiguredSaysSoAndNamesTheHostNotTheProject() {
        let reason = CockpitResolution.restStateUnresolvedReason(
            hasSelection: true, crew: crew(project: nil, bead: nil), target: nil)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("host"), reason!)
        XCTAssertFalse(reason!.contains("Library project"),
                       "a board/service crew has no project to be missing")
    }

    func testRestStateResolvesWithAFullSessionAndNoProjectAtAll() {
        XCTAssertNil(CockpitResolution.restStateUnresolvedReason(
            hasSelection: true, crew: crew(project: nil, bead: nil), target: target))
    }
}

/// `BeadAvailability` — the button's state and its tooltip as one value.
///
/// THESE EXIST BECAUSE THE PAIR DRIFTED TWICE. First the tooltip named a
/// Library project the bead action does not need, so it was wrong for every
/// crew with a project and no bead. Then the fix computed a correct reason,
/// threaded it into the view, and never read it — the enabled state was right
/// while the tooltip stayed the old wrong string, and the pure-function test
/// passed because it called the resolver directly. One value makes the
/// disagreement unrepresentable; these pin that it stays one.
final class BeadAvailabilityTests: XCTestCase {
    private let target = TestHost.target

    private func crew(project: String? = nil, bead: String? = nil) -> Crew {
        var c = Crew(id: "deck", displayName: "Deck")
        c.project = project
        c.bead = bead
        return c
    }

    private func availability(_ c: Crew?, _ t: SSHTarget?) -> CockpitResolution.BeadAvailability {
        CockpitResolution.beadAvailability(hasSelection: true, crew: c, target: t)
    }

    /// The invariant the type exists for: openable and the default help go
    /// together, and a reason and no action go together. Neither half can be
    /// true alone, whatever the inputs.
    func testTheActionAndTheTooltipNeverDisagree() {
        let cases: [(Crew?, SSHTarget?)] = [
            (crew(project: "convivy-deck", bead: "deck/bead/deck"), target),
            (crew(project: nil, bead: "deck/bead/deck"), target),
            (crew(project: "convivy-deck", bead: nil), target),
            (crew(project: "convivy-deck", bead: "deck/bead/deck"), nil),
            (crew(project: nil, bead: nil), nil),
            (nil, target),
        ]

        for (c, t) in cases {
            let a = availability(c, t)
            if a.openable != nil {
                XCTAssertEqual(a.help, "Open this project's bead",
                               "an openable bead must not carry a refusal")
            } else {
                XCTAssertNotEqual(a.help, "Open this project's bead",
                                  "a refused bead must say why, not invite a click")
            }
        }
    }

    /// The regression that started this: a bead with no project opens, and its
    /// tooltip is the open one rather than an explanation.
    func testABeadWithNoProjectIsOpenable() {
        let a = availability(crew(project: nil, bead: "deck/bead/deck"), target)

        XCTAssertEqual(a.openable?.beadId, "deck/bead/deck")
        XCTAssertEqual(a.help, "Open this project's bead")
    }

    /// The second drift: a project with no bead must be refused for the bead's
    /// own reason, never told to set a project it already has.
    func testAProjectWithNoBeadIsRefusedForTheRightReason() {
        let a = availability(crew(project: "convivy-deck", bead: nil), target)

        XCTAssertNil(a.openable)
        XCTAssertTrue(a.help.contains("bead"), a.help)
        XCTAssertFalse(a.help.contains("Library project"),
                       "must not send the operator to set a project that is already set")
    }

    func testNoHostIsRefusedForTheHost() {
        let a = availability(crew(project: "convivy-deck", bead: "deck/bead/deck"), nil)

        XCTAssertNil(a.openable)
        XCTAssertTrue(a.help.contains("host"), a.help)
    }
}
