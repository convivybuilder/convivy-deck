import XCTest
@testable import Deck

/// `ProjectThemeResolution` — which served crew speaks for a project, and
/// what its theme resolves to, CQ·211.
final class ProjectThemeResolutionTests: XCTestCase {
    private let mini = TestHost.target

    private func crew(id: String, project: String?, theme: String? = nil) -> ServedCrew {
        ServedCrew(crewId: id, host: mini, project: project, theme: theme)
    }

    // MARK: - primary-crew choice

    func testASingleCrewNamingAProjectIsItsPrimary() {
        let resolved = ProjectThemeResolution.resolved(from: [crew(id: "deck", project: "convivy-deck")])
        XCTAssertEqual(resolved.map(\.slug), ["convivy-deck"])
    }

    /// Two crews name the same project with neither crew id equal to the
    /// slug — the first by sorted id wins.
    func testATieWithNoIdMatchingTheSlugPicksTheFirstBySortedId() {
        let crews = [
            crew(id: "orchard-two", project: "orchard"),
            crew(id: "orchard-one", project: "orchard"),
        ]
        let resolved = ProjectThemeResolution.resolved(from: crews)
        XCTAssertEqual(resolved.first?.slug, "orchard")
        // "orchard-one" < "orchard-two"
        XCTAssertEqual(ProjectThemeResolution.resolvedTheme(for: crews[1]).theme, resolved.first?.theme)
    }

    /// Same tie, but one crew's id equals the slug — that crew wins over the
    /// sort order (comment 7443 on issue_01M7G7W6JJ7XHSD5ACZ32X2A09).
    func testATieWhereOneCrewsIdEqualsTheSlugPicksThatCrewEvenOutOfSortOrder() {
        let matching = crew(id: "orchard", project: "orchard", theme: "sage")
        let other = crew(id: "orchard-zzz", project: "orchard", theme: "gold")
        let resolved = ProjectThemeResolution.resolved(from: [other, matching])
        XCTAssertEqual(resolved.first?.theme, "sage")
        XCTAssertEqual(resolved.first?.source, "crews-d")
    }

    func testACrewWithNoProjectIsNeverPublished() {
        let resolved = ProjectThemeResolution.resolved(from: [crew(id: "deck", project: nil)])
        XCTAssertTrue(resolved.isEmpty)
    }

    func testABlankProjectIsTreatedAsNoProject() {
        let resolved = ProjectThemeResolution.resolved(from: [crew(id: "deck", project: "   ")])
        XCTAssertTrue(resolved.isEmpty)
    }

    func testTwoDistinctProjectsEachGetTheirOwnPrimary() {
        let crews = [
            crew(id: "deck", project: "convivy-deck", theme: "gold"),
            crew(id: "library", project: "library", theme: "azure"),
        ]
        let resolved = ProjectThemeResolution.resolved(from: crews)
        XCTAssertEqual(Set(resolved.map(\.slug)), ["convivy-deck", "library"])
    }

    // MARK: - crews-d versus hash source

    func testAServedThemeResolvesWithSourceCrewsD() {
        let (theme, source) = ProjectThemeResolution.resolvedTheme(for: crew(id: "deck", project: "convivy-deck", theme: "gold"))
        XCTAssertEqual(theme, "gold")
        XCTAssertEqual(source, "crews-d")
    }

    func testNoServedThemeResolvesToTheHashedDefaultWithSourceHash() {
        let (theme, source) = ProjectThemeResolution.resolvedTheme(for: crew(id: "deck", project: "convivy-deck", theme: nil))
        XCTAssertEqual(theme, ThemeCatalog.defaultTheme(forSession: "deck").name)
        XCTAssertEqual(source, "hash")
    }

    /// The hash is taken from the crew's own id, not the project slug — the
    /// two can differ (`Crew.project`'s own doc: "a crew id and a Library
    /// product are two different naming spaces").
    func testTheHashedFallbackHashesTheCrewIdNotTheProjectSlug() {
        let (theme, _) = ProjectThemeResolution.resolvedTheme(
            for: crew(id: "keel", project: "bosun", theme: nil))
        XCTAssertEqual(theme, ThemeCatalog.defaultTheme(forSession: "keel").name)
        XCTAssertNotEqual(ThemeCatalog.defaultTheme(forSession: "keel").name,
                          ThemeCatalog.defaultTheme(forSession: "bosun").name,
                          "coincidental equality would make this test prove nothing")
    }

    func testResolvedThroughTheFullPipelineCarriesTheRightSourceForEachCase() {
        let crews = [
            crew(id: "deck", project: "convivy-deck", theme: "gold"),
            crew(id: "library", project: "library", theme: nil),
        ]
        let resolved = ProjectThemeResolution.resolved(from: crews)
        let bySlug = Dictionary(uniqueKeysWithValues: resolved.map { ($0.slug, $0) })
        XCTAssertEqual(bySlug["convivy-deck"]?.source, "crews-d")
        XCTAssertEqual(bySlug["library"]?.source, "hash")
    }
}
