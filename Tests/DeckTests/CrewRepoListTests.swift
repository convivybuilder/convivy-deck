import XCTest
@testable import Deck

/// `Crew.repos` — issue_01M2P5JHM1G8XCMKM4HEHVJB2P's crew-model half: a
/// crew follows an ORDERED LIST of repos rather than exactly one. Real
/// crews this covers: Selector (`selector`, `selector-backend`), Constance
/// (`constance`, `constance-commercial`, `constance-landing`,
/// `constance-updates`), Vivy (`vivy`, `vivy-landing`,
/// `vivy-ownerrez-sandbox-tools`) and the Library crew (`library`,
/// `knowledge`).
///
/// `Crew.repo` (singular) stays as a computed `repos.first` — the accessor
/// the cockpit (`PRLadderModel`/`PRLadder`/`CockpitResolution`, all
/// untouched by this PR) still reads. `CrewRepoTests` already pins that
/// single-repo behaviour end to end; this file is additive, covering the
/// list itself.
final class CrewRepoListTests: XCTestCase {
    private let mini = TestHost.target
    private let miniHosts = [HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)]

    private func merge(configured: [Crew], served: [ServedCrew]) -> [Crew] {
        CrewMerge.merge(configured: configured, served: served, hosts: miniHosts, defaultHost: "mini")
    }

    // MARK: - ServedCrew decode: the plural key alongside the singular one

    func testAPluralReposKeyDecodes() {
        let rows = ServedCrew.decode(Data("""
        {"crews": [{"id": "selector", "repos": ["convivy/selector", "convivy/selector-backend"]}]}
        """.utf8), host: mini)
        XCTAssertEqual(rows.first?.resolvedRepos, ["convivy/selector", "convivy/selector-backend"])
    }

    /// A spec written before this issue only ever has the singular key —
    /// it must still decode as a one-element list, so no existing spec has
    /// to be rewritten and no crew loses its panel on upgrade.
    func testASingularRepoKeyStillResolvesAsAOneElementList() {
        let rows = ServedCrew.decode(Data("""
        {"crews": [{"id": "deck", "repo": "convivy/convivy-deck"}]}
        """.utf8), host: mini)
        XCTAssertEqual(rows.first?.resolvedRepos, ["convivy/convivy-deck"])
        XCTAssertEqual(rows.first?.repo, "convivy/convivy-deck", "the singular field itself is unchanged")
    }

    /// The plural key wins when both are present, rather than being unioned
    /// or the singular winning — a spec migrating from one to the other
    /// should not double up.
    func testThePluralKeyWinsOverTheSingularWhenBothArePresent() {
        let rows = ServedCrew.decode(Data("""
        {"crews": [{"id": "constance", "repo": "convivy/constance",
                     "repos": ["convivy/constance", "convivy/constance-commercial",
                               "convivy/constance-landing", "convivy/constance-updates"]}]}
        """.utf8), host: mini)
        XCTAssertEqual(rows.first?.resolvedRepos,
                       ["convivy/constance", "convivy/constance-commercial",
                        "convivy/constance-landing", "convivy/constance-updates"])
    }

    func testNeitherKeyResolvesToAnEmptyList() {
        let rows = ServedCrew.decode(Data(#"{"crews": [{"id": "vivy"}]}"#.utf8), host: mini)
        XCTAssertEqual(rows.first?.resolvedRepos, [])
    }

    /// A `repos` value of the wrong JSON type degrades to the singular
    /// fallback rather than losing the row's repos entirely — the same
    /// "field costs itself" discipline `ServedCrew.decode` already applies
    /// to every other key.
    func testAMalformedPluralValueFallsBackToTheSingularKey() {
        let rows = ServedCrew.decode(Data("""
        {"crews": [{"id": "vivy", "repo": "convivy/vivy", "repos": "not-an-array"}]}
        """.utf8), host: mini)
        XCTAssertEqual(rows.first?.resolvedRepos, ["convivy/vivy"])
    }

    /// A producer that always emits the plural key, even naming no repos,
    /// while still writing the singular for compatibility, must not have
    /// its valid `repo` shadowed by the empty `repos` sitting beside it.
    func testAPresentButEmptyPluralKeyFallsBackToTheSingularKey() {
        let rows = ServedCrew.decode(Data("""
        {"crews": [{"id": "vivy", "repo": "convivy/vivy", "repos": []}]}
        """.utf8), host: mini)
        XCTAssertEqual(rows.first?.resolvedRepos, ["convivy/vivy"])
    }

    /// Same failure mode as the empty-array case, reached a different way:
    /// `repos` decodes to a non-nil array whose every entry is unusable
    /// (`compactMap`'s cast drops all of them), so it must fall back to the
    /// singular exactly as the empty-array case does rather than reading as
    /// "the spec said no repos".
    func testAPluralKeyWithNoUsableEntriesFallsBackToTheSingularKey() {
        let rows = ServedCrew.decode(Data("""
        {"crews": [{"id": "vivy", "repo": "convivy/vivy", "repos": [123, 456]}]}
        """.utf8), host: mini)
        XCTAssertEqual(rows.first?.resolvedRepos, ["convivy/vivy"])
    }

    /// The gap this PR closes: a served `repos` entry that is a string but
    /// not a valid `owner/repo` identity must not be accepted — the same
    /// `LibraryClient.validateRepoIdentity` gate `ThemeConfiguration.parseRepos`
    /// already runs, and the identical string typed into Settings would be
    /// refused. An entry that fails costs only itself.
    func testAnEntryThatIsNotAValidRepoIdentityIsDropped() {
        let rows = ServedCrew.decode(Data("""
        {"crews": [{"id": "vivy", "repos": ["convivy/vivy", "not a repo", "no-slash-here"]}]}
        """.utf8), host: mini)
        XCTAssertEqual(rows.first?.resolvedRepos, ["convivy/vivy"])
    }

    /// The singular `repo` field gets the identical validation — it has
    /// been unvalidated since `#238` introduced it, harmlessly while only
    /// `repos.first` was ever read; this function is what starts actually
    /// querying it.
    func testAnInvalidSingularRepoIsRefused() {
        let rows = ServedCrew.decode(Data("""
        {"crews": [{"id": "vivy", "repo": "not a repo"}]}
        """.utf8), host: mini)
        XCTAssertEqual(rows.first?.resolvedRepos, [])
    }

    // MARK: - Crew.repos / Crew.repo

    func testCrewRepoIsTheFirstEntryOfRepos() {
        var crew = Crew(id: "selector", displayName: "Selector")
        crew.repos = ["selector", "selector-backend"]
        XCTAssertEqual(crew.repo, "selector")
    }

    func testSettingCrewRepoReplacesTheWholeList() {
        var crew = Crew(id: "selector", displayName: "Selector")
        crew.repos = ["selector", "selector-backend"]
        crew.repo = "convivy/convivy-deck"
        XCTAssertEqual(crew.repos, ["convivy/convivy-deck"], "the singular setter is not additive")
    }

    func testClearingCrewRepoClearsTheWholeList() {
        var crew = Crew(id: "selector", displayName: "Selector")
        crew.repos = ["selector", "selector-backend"]
        crew.repo = nil
        XCTAssertEqual(crew.repos, [])
    }

    /// `repo:` and `repos:` are two ways to set the same storage at
    /// construction — `repos:` wins when non-empty.
    func testConstructingWithRepoAndReposPrefersRepos() {
        let crew = Crew(id: "vivy", displayName: "Vivy", repo: "convivy/vivy",
                        repos: ["vivy", "vivy-landing", "vivy-ownerrez-sandbox-tools"])
        XCTAssertEqual(crew.repos, ["vivy", "vivy-landing", "vivy-ownerrez-sandbox-tools"])
    }

    // MARK: - CrewMerge: fan-out through the same precedence as `documents`

    private func served(id: String, repo: String? = nil, repos: [String]? = nil) -> ServedCrew {
        ServedCrew(crewId: id, host: mini, repo: repo, repos: repos)
    }

    func testAServedOnlyCrewCarriesItsWholeRepoList() {
        let spec = served(id: "library", repos: ["convivy/library", "convivy/knowledge"])
        let merged = merge(configured: [], served: [spec])
        XCTAssertEqual(merged.first?.repos, ["convivy/library", "convivy/knowledge"])
    }

    /// Settings' own (non-empty) list wins over the spec's, the same
    /// precedence `project`/`bead`/`documents` already have.
    func testAConfiguredReposListIsNotOverwrittenByTheSpec() {
        var configured = Crew(id: "constance", displayName: "constance")
        configured.repos = ["constance"]
        let spec = served(id: "constance",
                          repos: ["constance", "constance-commercial", "constance-landing", "constance-updates"])
        let merged = merge(configured: [configured], served: [spec])
        XCTAssertEqual(merged.first?.repos, ["constance"])
    }

    func testReposFollowsTheSpecWhenSettingsLeavesThemEmpty() {
        let configured = Crew(id: "constance", displayName: "constance")
        let spec = served(id: "constance",
                          repos: ["convivy/constance", "convivy/constance-commercial",
                                  "convivy/constance-landing", "convivy/constance-updates"])
        let merged = merge(configured: [configured], served: [spec])
        XCTAssertEqual(merged.first?.repos,
                       ["convivy/constance", "convivy/constance-commercial",
                        "convivy/constance-landing", "convivy/constance-updates"])
    }

    // MARK: - sparse: editing the repo list must not freeze anything else

    /// THE ACCEPTANCE TEST THE PR BODY NAMES: editing only a served-only
    /// crew's repo list must leave every other served field (here,
    /// `workingDirectory` and `project`) following the spec rather than
    /// freezing into local config — the exact trap `CrewMergeTests`
    /// already guards for `project`/`bead`/`shape`, now for a list field.
    func testEditingTheRepoListDoesNotFreezeOtherServedFields() {
        let spec = ServedCrew(crewId: "vivy", host: mini,
                              workingDirectory: "\(TestHost.homeRoot)/Convivy/vivy",
                              project: "vivy", repos: ["convivy/vivy", "convivy/vivy-landing"])
        var merged = merge(configured: [], served: [spec])[0]
        merged.repos = ["convivy/vivy", "convivy/vivy-landing", "convivy/vivy-ownerrez-sandbox-tools"]

        let sparse = CrewMerge.sparse(merged, relativeTo: spec, hosts: miniHosts)
        XCTAssertEqual(sparse.repos, ["convivy/vivy", "convivy/vivy-landing", "convivy/vivy-ownerrez-sandbox-tools"],
                       "the edit survives")
        XCTAssertNil(sparse.workingDirectory, "untouched, so it keeps following the spec")
        XCTAssertNil(sparse.project, "untouched, so it keeps following the spec")
        XCTAssertFalse(CrewMerge.isUnedited(sparse), "the repo edit itself must still persist")
    }

    /// An untouched served-only crew's list strips fully back to unset, the
    /// same round trip `documents` already completes.
    func testSparseOfAnUntouchedReposListIsFullyUnset() {
        let spec = served(id: "library", repos: ["convivy/library", "convivy/knowledge"])
        let merged = merge(configured: [], served: [spec])[0]
        let sparse = CrewMerge.sparse(merged, relativeTo: spec, hosts: miniHosts)
        XCTAssertEqual(sparse.repos, [])
        XCTAssertTrue(CrewMerge.isUnedited(sparse))
    }

    /// Reducing the list (dropping one repo of several) is still a real
    /// edit and must survive `sparse` — the common case the list editor
    /// exists for.
    func testRemovingOneRepoFromASpecsListSurvivesSparse() {
        let spec = served(id: "vivy", repos: ["convivy/vivy", "convivy/vivy-landing", "convivy/vivy-ownerrez-sandbox-tools"])
        var merged = merge(configured: [], served: [spec])[0]
        merged.repos = ["convivy/vivy", "convivy/vivy-landing"]
        let sparse = CrewMerge.sparse(merged, relativeTo: spec, hosts: miniHosts)
        XCTAssertEqual(sparse.repos, ["convivy/vivy", "convivy/vivy-landing"])
        XCTAssertFalse(CrewMerge.isUnedited(sparse))
    }

    // MARK: - ThemeConfiguration: local config persists the plural key

    private func write(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-repo-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testARailRowsPluralReposKeyDecodes() throws {
        let file = try write("""
        {"rail": [{"session": "selector", "repos": ["convivy/selector", "convivy/selector-backend"]}]}
        """)
        XCTAssertEqual(ThemeConfiguration.load(from: file).railSessions?.first?.repos,
                       ["convivy/selector", "convivy/selector-backend"])
    }

    /// Each entry is validated independently — one bad entry costs only
    /// itself, not the whole list.
    func testAnInvalidEntryInThePluralListIsDroppedButTheRestSurvive() throws {
        let file = try write("""
        {"rail": [{"session": "vivy", "repos": ["convivy/vivy", "no-slash-here", "convivy/vivy-landing"]}]}
        """)
        XCTAssertEqual(ThemeConfiguration.load(from: file).railSessions?.first?.repos,
                       ["convivy/vivy", "convivy/vivy-landing"])
    }

    func testReposListSurvivesSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "library", displayName: "Library",
                                    repos: ["convivy/library", "convivy/knowledge"])]
        try config.save(to: file)

        let reloaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(reloaded.railSessions?.first?.repos, ["convivy/library", "convivy/knowledge"])
    }

    /// A row with no repos must not grow the key on save, the same
    /// reasoning `CrewRepoTests.testAnUntouchedRowWritesNoRepoKey` pins for
    /// the singular field.
    func testAnUntouchedRowWritesNoReposKey() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "deck", displayName: "Deck")]
        try config.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rail = try XCTUnwrap(root["rail"] as? [[String: Any]])
        XCTAssertNil(rail.first?["repos"])
        XCTAssertNil(rail.first?["repo"])
    }

    /// Unpinning a crew with several repos must not silently drop any of
    /// them — `CrewRepoTests` pins this for one repo; this is the same
    /// round trip for the list.
    func testUnpinningACrewCarriesItsWholeRepoListToTheCatalog() {
        var roster = SessionRoster(entries: [
            RosterEntry(id: "constance", displayName: "Constance", isPinned: true,
                       repos: ["constance", "constance-commercial", "constance-landing", "constance-updates"]),
        ])
        roster.update("constance") { $0.setPinned(false) }
        XCTAssertEqual(roster["constance"]?.repos,
                       ["constance", "constance-commercial", "constance-landing", "constance-updates"])
        XCTAssertEqual(roster["constance"]?.asLaunchableSession.repos,
                       ["constance", "constance-commercial", "constance-landing", "constance-updates"])
    }
}
