import XCTest
@testable import Deck

/// `CrewMerge.merge` folds `session-agent crews`' served specs into Deck's
/// own configured rail rows — see `platform/contracts/session-agent-api`'s
/// `crews` section and `issue_01M1S58ZXTV4FX0V77JVP4FWNR`. PURE, no ssh, no
/// view code, the same discipline `SessionGrouping`'s own tests follow.
final class CrewMergeTests: XCTestCase {
    private let mini = TestHost.target
    private let miniHosts = [HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)]

    private func served(id: String, displayName: String? = nil, workingDirectory: String? = nil,
                        sessionId: String? = nil, project: String? = nil, bead: String? = nil,
                        repo: String? = nil, sessions: [ServedCrew.Child] = [],
                        shape: String? = nil, documents: [String] = []) -> ServedCrew {
        ServedCrew(crewId: id, host: mini, displayName: displayName,
                   workingDirectory: workingDirectory, sessionId: sessionId,
                   project: project, bead: bead, repo: repo, sessions: sessions,
                   shape: shape, documents: documents)
    }

    /// Every ordinary test in this file has exactly one real host — `mini` —
    /// so every configured crew's own `host` (nil, or explicit) resolves to
    /// the same target `served(...)` above stamps on every `ServedCrew`.
    /// The cross-host section below calls `CrewMerge.merge` directly with a
    /// second host instead.
    private func merge(configured: [Crew], served: [ServedCrew]) -> [Crew] {
        CrewMerge.merge(configured: configured, served: served, hosts: miniHosts, defaultHost: "mini")
    }

    // MARK: - the acceptance case: a spec with no configured counterpart

    /// `placard`, created through `new-crew` on 2026-09-05: no local config
    /// at all, yet it must draw a rail row with the spec's own display name
    /// (title case), working directory, project and bead — no Settings
    /// step, no change to the spec file.
    func testAServedOnlyCrewDrawsAsARowWithTheSpecsOwnFields() {
        let placard = served(id: "placard", displayName: "Placard",
                             workingDirectory: "\(TestHost.homeRoot)/Convivy/placard",
                             sessionId: "$58", project: "placard", bead: "placard/bead/placard")
        let merged = merge(configured: [], served: [placard])

        XCTAssertEqual(merged.count, 1)
        let crew = merged[0]
        XCTAssertEqual(crew.id, "placard")
        XCTAssertEqual(crew.displayName, "Placard", "title case from the spec, not the lowercase id")
        XCTAssertEqual(crew.workingDirectory, "\(TestHost.homeRoot)/Convivy/placard")
        XCTAssertEqual(crew.sessionId, "$58")
        XCTAssertEqual(crew.project, "placard")
        XCTAssertEqual(crew.bead, "placard/bead/placard")
    }

    /// A served crew with no `displayName` of its own falls back to its id —
    /// the same "nothing to show but the name" fallback a configured row
    /// without one already uses.
    func testAServedOnlyCrewWithNoDisplayNameFallsBackToItsId() {
        let merged = merge(configured: [], served: [served(id: "shipwright")])
        XCTAssertEqual(merged.first?.displayName, "shipwright")
    }

    // MARK: - a spec row and a configured row for the same crew are one row

    func testAConfiguredCrewMatchingByIdMergesIntoOneRow() {
        let configured = Crew(id: "placard", displayName: "placard")
        let spec = served(id: "placard", displayName: "Placard", sessionId: "$58",
                          project: "placard", bead: "placard/bead/placard")
        let merged = merge(configured: [configured], served: [spec])

        XCTAssertEqual(merged.count, 1, "one row, not two")
        XCTAssertEqual(merged[0].displayName, "Placard")
        XCTAssertEqual(merged[0].project, "placard")
        XCTAssertEqual(merged[0].bead, "placard/bead/placard")
        XCTAssertEqual(merged[0].sessionId, "$58")
    }

    /// A value Settings actually set is never overwritten by the spec —
    /// only a gap the configured row left open gets filled.
    func testASettingsValueIsNotOverwrittenByTheSpec() {
        var configured = Crew(id: "placard", displayName: "My Placard")
        configured.project = "convivy-deck"
        let spec = served(id: "placard", displayName: "Placard", project: "placard")
        let merged = merge(configured: [configured], served: [spec])

        XCTAssertEqual(merged[0].displayName, "My Placard", "an explicit display name wins over the spec's")
        XCTAssertEqual(merged[0].project, "convivy-deck", "Settings wins over the spec")
    }

    /// Matched by `sessionId` first: a configured row and a spec row whose
    /// `id`s have drifted apart still merge into one, as long as Deck
    /// already knows the configured row's live session id.
    func testMatchBySessionIdWinsOverAMismatchedId() {
        var configured = Crew(id: "old-name", displayName: "old-name")
        configured.sessionId = "$58"
        let spec = served(id: "new-name", displayName: "New Name", sessionId: "$58")
        let merged = merge(configured: [configured], served: [spec])

        XCTAssertEqual(merged.count, 1, "the sessionId match must win, not fall through to two rows")
        XCTAssertEqual(merged[0].id, "old-name", "the configured row's own id is never rewritten")
        XCTAssertEqual(merged[0].displayName, "New Name")
    }

    /// A configured row with no matching spec draws unchanged.
    func testAConfiguredCrewWithNoMatchingSpecIsUnchanged() {
        let configured = Crew(id: "legacy", displayName: "Legacy Crew")
        let merged = merge(configured: [configured], served: [served(id: "placard")])
        XCTAssertEqual(merged.map(\.id), ["legacy", "placard"])
        XCTAssertEqual(merged[0].displayName, "Legacy Crew")
    }

    // MARK: - project/bead resolution precedence: Settings > spec > nil

    func testProjectFollowsSettingsWhenSet() {
        var configured = Crew(id: "placard", displayName: "placard")
        configured.project = "convivy-deck"
        let merged = merge(
            configured: [configured], served: [served(id: "placard", project: "placard")])
        XCTAssertEqual(merged[0].project, "convivy-deck")
    }

    func testProjectFollowsSpecWhenSettingsLeavesItUnset() {
        let configured = Crew(id: "placard", displayName: "placard")
        let merged = merge(
            configured: [configured], served: [served(id: "placard", project: "placard")])
        XCTAssertEqual(merged[0].project, "placard")
        // The acceptance criterion this exists for: the cockpit can resolve
        // with no Settings step, once the spec supplies a project.
        XCTAssertNotNil(CockpitResolution.projectAndTarget(for: merged[0], target: mini))
    }

    func testProjectIsNilWhenNeitherSettingsNorTheSpecSetIt() {
        let configured = Crew(id: "placard", displayName: "placard")
        let merged = merge(configured: [configured], served: [served(id: "placard")])
        XCTAssertNil(merged[0].project)
        XCTAssertNil(CockpitResolution.projectAndTarget(for: merged[0], target: mini))
    }

    func testBeadFollowsTheSamePrecedenceAsProject() {
        var configured = Crew(id: "placard", displayName: "placard")
        configured.bead = "convivy-deck/bead/convivy-deck"
        let merged = merge(
            configured: [configured], served: [served(id: "placard", bead: "placard/bead/placard")])
        XCTAssertEqual(merged[0].bead, "convivy-deck/bead/convivy-deck")
    }

    func testRepoFollowsTheSamePrecedenceAsProject() {
        var configured = Crew(id: "placard", displayName: "placard")
        configured.repo = "convivy/convivy-deck"
        let merged = merge(
            configured: [configured], served: [served(id: "placard", repo: "convivy/placard")])
        XCTAssertEqual(merged[0].repo, "convivy/convivy-deck")
    }

    func testRepoFollowsSpecWhenSettingsLeavesItUnset() {
        let configured = Crew(id: "placard", displayName: "placard")
        let merged = merge(
            configured: [configured], served: [served(id: "placard", repo: "convivy/placard")])
        XCTAssertEqual(merged[0].repo, "convivy/placard")
    }

    // MARK: - shape/documents resolution precedence: Settings > spec > unset

    /// Settings wins over the spec, the same precedence `project`/`bead`
    /// already have.
    func testShapeFollowsSettingsWhenSet() {
        var configured = Crew(id: "steward", displayName: "steward")
        configured.shape = "service"
        let merged = merge(
            configured: [configured], served: [served(id: "steward", shape: "board")])
        XCTAssertEqual(merged[0].shape, "service")
    }

    func testShapeFollowsSpecWhenSettingsLeavesItUnset() {
        let configured = Crew(id: "ask", displayName: "ask")
        let merged = merge(
            configured: [configured], served: [served(id: "ask", shape: "service")])
        XCTAssertEqual(merged[0].shape, "service")
    }

    func testShapeIsNilWhenNeitherSettingsNorTheSpecSetIt() {
        let configured = Crew(id: "placard", displayName: "placard")
        let merged = merge(configured: [configured], served: [served(id: "placard")])
        XCTAssertNil(merged[0].shape)
    }

    /// `documents` is `[String]`, not optional, so "unset" is empty — the
    /// merge still prefers Settings' own (non-empty) list over the spec's.
    func testDocumentsFollowSettingsWhenNonEmpty() {
        var configured = Crew(id: "steward", displayName: "steward")
        configured.documents = ["my-backlog.md"]
        let merged = merge(
            configured: [configured], served: [served(id: "steward", documents: ["backlog.md"])])
        XCTAssertEqual(merged[0].documents, ["my-backlog.md"])
    }

    func testDocumentsFollowTheSpecWhenSettingsLeavesThemEmpty() {
        let configured = Crew(id: "steward", displayName: "steward")
        let merged = merge(
            configured: [configured], served: [served(id: "steward", documents: ["backlog.md"])])
        XCTAssertEqual(merged[0].documents, ["backlog.md"])
    }

    func testDocumentsAreEmptyWhenNeitherSettingsNorTheSpecSetThem() {
        let configured = Crew(id: "placard", displayName: "placard")
        let merged = merge(configured: [configured], served: [served(id: "placard")])
        XCTAssertEqual(merged[0].documents, [])
    }

    /// A served-only crew (the common case — see the acceptance test at the
    /// top of this file) still carries the spec's `shape`/`documents`
    /// straight through, the same way it already carries `project`/`bead`.
    func testAServedOnlyCrewCarriesShapeAndDocuments() {
        let merged = merge(
            configured: [], served: [served(id: "steward", shape: "board", documents: ["backlog.md"])])
        XCTAssertEqual(merged[0].shape, "board")
        XCTAssertEqual(merged[0].documents, ["backlog.md"])
    }

    // MARK: - children merge the same way, one level down

    func testAConfiguredChildAndASpecChildForTheSameSessionMergeIntoOneRow() {
        // The child's display name is left unset (equal to its own name),
        // the same sentinel the crew-level test above relies on, so the
        // spec's "Build" fills the gap.
        let configured = Crew(id: "placard", displayName: "Placard",
                              sessions: [PinnedSession(name: "placard--build",
                                                        displayName: "placard--build")])
        let spec = served(id: "placard", sessions: [
            ServedCrew.Child(name: "placard--build", displayName: "Build", sessionId: "$19"),
        ])
        let merged = merge(configured: [configured], served: [spec])

        XCTAssertEqual(merged[0].sessions.count, 1, "one child row, not two")
        XCTAssertEqual(merged[0].sessions[0].displayName, "Build")
        XCTAssertEqual(merged[0].sessions[0].sessionId, "$19")
    }

    /// An explicitly set child display name is never overwritten by the
    /// spec — the same "Settings wins" precedence as the crew level.
    func testAnExplicitChildDisplayNameIsNotOverwrittenByTheSpec() {
        let configured = Crew(id: "placard", displayName: "Placard",
                              sessions: [PinnedSession(name: "placard--build", displayName: "My Build")])
        let spec = served(id: "placard", sessions: [
            ServedCrew.Child(name: "placard--build", displayName: "Build", sessionId: "$19"),
        ])
        let merged = merge(configured: [configured], served: [spec])
        XCTAssertEqual(merged[0].sessions[0].displayName, "My Build")
        XCTAssertEqual(merged[0].sessions[0].sessionId, "$19", "sessionId still fills in even when the name stands")
    }

    func testASpecOnlyChildIsAppended() {
        let configured = Crew(id: "placard", displayName: "Placard")
        let spec = served(id: "placard", sessions: [
            ServedCrew.Child(name: "placard--build", displayName: "Build", sessionId: "$19"),
        ])
        let merged = merge(configured: [configured], served: [spec])
        XCTAssertEqual(merged[0].sessions.map(\.name), ["placard--build"])
        XCTAssertEqual(merged[0].sessions.map(\.sessionId), ["$19"])
    }

    // MARK: - the host boundary: two hosts serving the same id (this epic's whole point)

    private let guestHosts = [
        HostEntry(name: "mini", user: TestHost.user, address: TestHost.address),
        HostEntry(name: "guest", user: TestHost.secondaryUser, address: TestHost.secondaryAddress),
    ]

    /// Every Builder install has a `steward` crew, and the proof case: mini
    /// and guest each serve their own `steward` spec, and neither is
    /// configured locally. Before this, `servedByCrewId`'s bare-`crewId` key
    /// let one host's spec silently drop the other from the lookup table
    /// (recoverable only by luck of array order) — this pins that both
    /// survive as two separate rows, each on its own host.
    func testServedSpecsFromTwoHostsWithTheSameIdDrawAsTwoSeparateRows() {
        let guest = TestHost.secondaryTarget
        let mine = ServedCrew(crewId: "steward", host: mini, workingDirectory: "\(TestHost.homeRoot)/Convivy/steward")
        let guests = ServedCrew(crewId: "steward", host: guest, workingDirectory: "\(TestHost.secondaryHomeRoot)/Convivy/steward")
        let merged = CrewMerge.merge(configured: [], served: [mine, guests], hosts: guestHosts, defaultHost: "mini")

        XCTAssertEqual(merged.count, 2, "one row per host, not one row for the pair")
        XCTAssertEqual(Set(merged.map(\.host)), ["mini", "guest"])
        XCTAssertEqual(merged.first { $0.host == "mini" }?.workingDirectory, "\(TestHost.homeRoot)/Convivy/steward")
        XCTAssertEqual(merged.first { $0.host == "guest" }?.workingDirectory, "\(TestHost.secondaryHomeRoot)/Convivy/steward")
    }

    /// The failure mode this guards against directly: a CONFIGURED crew on
    /// `mini` must fill from `mini`'s own spec, never from `guest`'s spec of
    /// the same id, regardless of which one happens to iterate first.
    func testAConfiguredCrewFillsOnlyFromItsOwnHostsSpecNeverACollidingHostsSpec() {
        let guest = TestHost.secondaryTarget
        var configured = Crew(id: "steward", displayName: "steward")
        configured.host = "mini"
        let mine = ServedCrew(crewId: "steward", host: mini, project: "mini-project")
        let guests = ServedCrew(crewId: "steward", host: guest, project: "guest-project")
        let merged = CrewMerge.merge(
            configured: [configured], served: [mine, guests], hosts: guestHosts, defaultHost: "mini")

        XCTAssertEqual(merged.count, 2, "the configured row merges with mini's spec; guest's spec still draws its own row")
        XCTAssertEqual(merged.first { $0.host == "mini" }?.project, "mini-project")
        XCTAssertEqual(merged.first { $0.host == "guest" }?.project, "guest-project")
    }

    /// Two real machines' tmux servers each count their own `$<digits>`
    /// session ids from zero, so a raw sessionId match with no host in the
    /// key could conflate two entirely unrelated sessions that happen to
    /// share one.
    func testASessionIdCollisionAcrossTwoHostsDoesNotCrossMatch() {
        let guest = TestHost.secondaryTarget
        var configured = Crew(id: "old-name", displayName: "old-name")
        configured.host = "guest"
        configured.sessionId = "$3"
        let mine = ServedCrew(crewId: "new-name", host: mini, sessionId: "$3")
        let merged = CrewMerge.merge(
            configured: [configured], served: [mine], hosts: guestHosts, defaultHost: "mini")

        XCTAssertEqual(merged.count, 2, "mini's $3 spec must not fill guest's row of the same raw id")
        XCTAssertEqual(merged.first { $0.id == "old-name" }?.displayName, "old-name",
                       "the configured row on guest is untouched by mini's same-numbered session")
    }

    // MARK: - `sparse`/`match`/`isUnedited`, the inverse `SessionRoster.applied(to:)`
    // needs so persisting a merged crew cannot freeze a spec's own fill into
    // local config — see `issue_01M2P6E8EQHDMWFY02Q4GVMZ7R` and that
    // function's doc.

    func testMatchFindsTheServedRowMergeWouldHaveUsed() {
        let spec = served(id: "placard")
        XCTAssertEqual(
            CrewMerge.match(Crew(id: "placard", displayName: "placard"), in: [spec],
                            hosts: miniHosts, defaultHost: "mini")?.crewId,
            "placard")
    }

    func testMatchPrefersSessionIdOverCrewId() {
        var crew = Crew(id: "old-name", displayName: "old-name")
        crew.sessionId = "$58"
        let spec = served(id: "new-name", sessionId: "$58")
        XCTAssertEqual(
            CrewMerge.match(crew, in: [spec], hosts: miniHosts, defaultHost: "mini")?.crewId, "new-name")
    }

    func testMatchIsNilWithNoServedCounterpart() {
        XCTAssertNil(
            CrewMerge.match(Crew(id: "legacy", displayName: "Legacy"), in: [],
                            hosts: miniHosts, defaultHost: "mini"))
    }

    /// The finding this exists to close: a bare sessionId/crewId lookup let
    /// `SessionRoster.applied(to:)` diff a row against the OTHER host's spec
    /// the moment two hosts serve a crew of the same id — reachable the
    /// instant this PR's own `merge` fix lets both reach Settings as two
    /// pinned rows in the first place.
    func testMatchOnlyConsidersTheCrewsOwnHostsSpec() {
        let guest = TestHost.secondaryTarget
        var crew = Crew(id: "steward", displayName: "steward")
        crew.host = "mini"
        let mine = served(id: "steward", project: "mini-project")
        let guests = ServedCrew(crewId: "steward", host: guest, project: "guest-project")

        let match = CrewMerge.match(crew, in: [guests, mine], hosts: guestHosts, defaultHost: "mini")
        XCTAssertEqual(match?.project, "mini-project", "must never diff against guest's spec of the same id")
    }

    /// The sessionId branch is just as exposed: two tmux servers commonly
    /// report the same raw `$<digits>` counter for unrelated sessions.
    func testMatchsSessionIdBranchDoesNotCrossHosts() {
        let guest = TestHost.secondaryTarget
        var crew = Crew(id: "old-name", displayName: "old-name")
        crew.host = "guest"
        crew.sessionId = "$3"
        let minisSameId = ServedCrew(crewId: "new-name", host: mini, sessionId: "$3")

        XCTAssertNil(CrewMerge.match(crew, in: [minisSameId], hosts: guestHosts, defaultHost: "mini"),
                     "mini's $3 spec must not match guest's row of the same raw id")
    }

    /// A crew still naming a host removed from Settings resolves to the
    /// default host for every action, so it keeps matching the default
    /// host's spec; comparing the stale name would drop the match and let a
    /// Settings save freeze the spec's fill into local config.
    func testACrewNamingARemovedHostMatchesTheDefaultHostsSpec() {
        var crew = Crew(id: "steward", displayName: "steward")
        crew.host = "vacation-box"
        let mine = served(id: "steward", project: "mini-project")

        XCTAssertEqual(
            CrewMerge.match(crew, in: [mine], hosts: guestHosts, defaultHost: "mini")?.project,
            "mini-project")
        let merged = CrewMerge.merge(configured: [crew], served: [mine], hosts: guestHosts, defaultHost: "mini")
        XCTAssertEqual(merged.count, 1, "the configured row and mini's spec are one crew")
        XCTAssertEqual(merged.first?.project, "mini-project")
    }

    /// A merged crew, unedited, strips back down to exactly the "unset"
    /// state `isUnedited` recognizes — the round trip a served-only row
    /// must complete with nothing written to local config at all.
    func testSparseOfAnUntouchedServedOnlyCrewIsFullyUnset() {
        let spec = served(id: "placard", displayName: "Placard",
                          workingDirectory: "\(TestHost.homeRoot)/Convivy/placard",
                          sessionId: "$58", project: "placard", bead: "placard/bead/placard",
                          repo: "convivy/placard", shape: "board", documents: ["backlog.md"])
        let merged = merge(configured: [], served: [spec])[0]
        let sparse = CrewMerge.sparse(merged, relativeTo: spec, hosts: miniHosts)
        XCTAssertTrue(CrewMerge.isUnedited(sparse))
    }

    /// Editing exactly one field of a served-only crew's merged reading
    /// leaves every other field stripped back to unset — this is the sparse
    /// override itself, not merely the all-or-nothing case above.
    func testSparseKeepsOnlyTheFieldThatDiffersFromTheSpec() {
        let spec = served(id: "placard", displayName: "Placard",
                          workingDirectory: "\(TestHost.homeRoot)/Convivy/placard")
        var merged = merge(configured: [], served: [spec])[0]
        merged.repo = "convivy/placard"
        let sparse = CrewMerge.sparse(merged, relativeTo: spec, hosts: miniHosts)

        XCTAssertEqual(sparse.repo, "convivy/placard", "the edit survives")
        XCTAssertNil(sparse.workingDirectory, "untouched, so it keeps following the spec")
        XCTAssertEqual(sparse.displayName, "placard", "untouched, so displayName reverts to the unset sentinel")
        XCTAssertFalse(CrewMerge.isUnedited(sparse))
    }

    /// A crew with no served match is never sparsified — `sparse` is only
    /// ever called after `match` finds a counterpart.
    func testIsUneditedIsFalseForAnOrdinaryConfiguredCrew() {
        XCTAssertFalse(CrewMerge.isUnedited(Crew(id: "legacy", displayName: "Legacy Crew")))
    }
}
