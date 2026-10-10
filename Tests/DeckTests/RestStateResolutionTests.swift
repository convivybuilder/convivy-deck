import XCTest
@testable import Deck

/// `RestStateResolution` — what the `.cockpit` occupant's rest state
/// resolves to for a given crew: `.course`, `.board`, or `.service`. PURE,
/// no view code, the same discipline `CockpitResolution`'s own tests
/// follow. See the steward-board proposal
/// (`agent-runs/2026-09-09/run-83743d3c/proposal.md`) for the reasoning
/// this implements.
final class RestStateResolutionTests: XCTestCase {

    // MARK: - Shape.shape(for:)

    /// No crew selected — the same fallback the unresolved `.course` path
    /// already draws (`CockpitResolution.unresolvedReason`'s `hasSelection`
    /// guard). There is nothing to be a steward or a service crew, so this
    /// stays `.course` rather than guessing at either.
    func testNoCrewResolvesToCourse() {
        XCTAssertEqual(RestStateResolution.shape(for: nil), .course)
    }

    func testAnExplicitBoardShapeResolvesToBoard() {
        var crew = Crew(id: "placard", displayName: "Placard")
        crew.shape = "board"
        XCTAssertEqual(RestStateResolution.shape(for: crew), .board)
    }

    func testAnExplicitServiceShapeResolvesToService() {
        var crew = Crew(id: "ask", displayName: "ask")
        crew.shape = "service"
        XCTAssertEqual(RestStateResolution.shape(for: crew), .service)
    }

    func testAnExplicitCourseShapeResolvesToCourse() {
        var crew = Crew(id: "deck", displayName: "Deck")
        crew.shape = "course"
        XCTAssertEqual(RestStateResolution.shape(for: crew), .course)
    }

    /// The steward's by-id default: no `shape` field at all, but
    /// `crew.id == StewardCrew.id`, resolves to `.board`.
    func testAStewardWithNoShapeFieldDefaultsToBoard() {
        let crew = Crew(id: StewardCrew.id, displayName: "Steward")
        XCTAssertEqual(RestStateResolution.shape(for: crew), .board)
    }

    /// The common case: a non-steward crew with no `shape` field defaults
    /// to `.course`, exactly today's behaviour for every existing crew.
    func testANonStewardCrewWithNoShapeFieldDefaultsToCourse() {
        let crew = Crew(id: "convivy-deck", displayName: "Deck")
        XCTAssertEqual(RestStateResolution.shape(for: crew), .course)
    }

    /// An unrecognized string degrades the same way an absent field does —
    /// "field costs itself" rather than a fixed fallback that ignores which
    /// crew it is. A non-steward crew's garbage `shape` reads as `.course`.
    func testAGarbageShapeStringOnANonStewardCrewFallsBackToCourse() {
        var crew = Crew(id: "convivy-deck", displayName: "Deck")
        crew.shape = "spaceship"
        XCTAssertEqual(RestStateResolution.shape(for: crew), .course)
    }

    /// The same degrade, on the steward: a garbage string is exactly as
    /// unresolved as no field at all, so the steward's own by-id default
    /// still applies rather than being punished harder for having tried.
    func testAGarbageShapeStringOnTheStewardFallsBackToTheStewardsOwnDefault() {
        var crew = Crew(id: StewardCrew.id, displayName: "Steward")
        crew.shape = "spaceship"
        XCTAssertEqual(RestStateResolution.shape(for: crew), .board)
    }

    // MARK: - documentPaths(for:)

    func testNoCrewYieldsNoDocuments() {
        XCTAssertEqual(RestStateResolution.documentPaths(for: nil), [])
    }

    func testExplicitDocumentsResolveAgainstTheWorkingDirectory() {
        var crew = Crew(id: "steward", displayName: "Steward")
        crew.workingDirectory = "\(TestHost.homeRoot)/Convivy/steward"
        crew.documents = ["backlog.md", "handoff.md"]
        XCTAssertEqual(RestStateResolution.documentPaths(for: crew), [
            "\(TestHost.homeRoot)/Convivy/steward/backlog.md",
            "\(TestHost.homeRoot)/Convivy/steward/handoff.md",
        ])
    }

    /// No documents named — falls back to the one default Deck ships:
    /// the role file, never a guessed list of "the" documents.
    func testNoDocumentsNamedFallsBackToTheRoleFile() {
        var crew = Crew(id: "steward", displayName: "Steward")
        crew.workingDirectory = "\(TestHost.homeRoot)/Convivy/steward"
        XCTAssertEqual(RestStateResolution.documentPaths(for: crew),
                       ["\(TestHost.homeRoot)/Convivy/steward/\(StewardCrew.roleFilename)"])
    }

    /// No working directory to resolve against — a relative document name
    /// with nothing to join it to is not a path `DeckOpenRef.Origin.path`
    /// could open, so this degrades to empty rather than inventing one.
    func testNoWorkingDirectoryYieldsNoDocumentsEvenWhenNamed() {
        var crew = Crew(id: "steward", displayName: "Steward")
        crew.documents = ["backlog.md"]
        XCTAssertEqual(RestStateResolution.documentPaths(for: crew), [])
    }

    /// An already-absolute document path is used as-is, not joined to the
    /// working directory a second time.
    func testAnAbsoluteDocumentPathIsUsedAsIs() {
        var crew = Crew(id: "steward", displayName: "Steward")
        crew.workingDirectory = "\(TestHost.homeRoot)/Convivy/steward"
        crew.documents = ["\(TestHost.homeRoot)/Convivy/shared/charter.md"]
        XCTAssertEqual(RestStateResolution.documentPaths(for: crew),
                       ["\(TestHost.homeRoot)/Convivy/shared/charter.md"])
    }

    // MARK: - documentPaths(for:) held to DeckOpenRef's containment boundary
    //
    // `documentPaths(for:)` itself stays unvalidated on purpose (it doesn't
    // know which hosts are configured) — but `ContentView.openRestStateDocument`
    // is required to pass every row through `DeckOpenRef.validatePath` before
    // opening it, the same boundary a `deck-open:` URL is held to. These pin
    // that composition, since a served crew's `documents` list is
    // spec-controlled, attacker-reachable content
    // (`~/.config/convivy/deck/crews.d/<id>.json`).

    private let boundaryTestHosts = [
        HostEntry(name: "test-host", user: TestHost.user, address: "203.0.113.10"),
    ]

    /// The concrete exploit a reviewer named: a spec pointing `documents` at
    /// an absolute path outside every configured host's home directory must
    /// not resolve to something `openViewer` would open.
    func testADocumentEntryOutsideEveryAllowedRootDoesNotValidate() {
        var crew = Crew(id: "steward", displayName: "Steward")
        crew.workingDirectory = "\(TestHost.homeRoot)/Convivy/steward"
        crew.documents = ["/etc/passwd"]
        let resolved = RestStateResolution.documentPaths(for: crew)
        let roots = DeckOpenRef.allowedPathRoots(hosts: boundaryTestHosts)
        XCTAssertEqual(resolved, ["/etc/passwd"])
        XCTAssertNil(DeckOpenRef.validatePath(resolved[0], allowedRoots: roots))
    }

    /// A legitimate relative entry, joined against a working directory that
    /// falls under a configured host's root, still validates and still
    /// opens.
    func testALegitimateRelativeDocumentEntryStillValidates() {
        var crew = Crew(id: "steward", displayName: "Steward")
        crew.workingDirectory = "\(TestHost.homeRoot)/Convivy/steward"
        crew.documents = ["backlog.md"]
        let resolved = RestStateResolution.documentPaths(for: crew)
        let roots = DeckOpenRef.allowedPathRoots(hosts: boundaryTestHosts)
        XCTAssertEqual(resolved, ["\(TestHost.homeRoot)/Convivy/steward/backlog.md"])
        XCTAssertEqual(DeckOpenRef.validatePath(resolved[0], allowedRoots: roots), resolved[0])
    }
}
