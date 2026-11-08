import XCTest
@testable import Deck

/// `ServedCrew.decode` reads `session-agent crews`' envelope. Per
/// `platform/contracts/session-agent-api`'s `crews` section: `id` is the
/// only field a row cannot be served without, every other field degrades
/// independently, and a row it cannot parse is skipped rather than failing
/// the batch — only a malformed top-level payload fails (reads as `[]`,
/// the same total-function discipline `DiscoveredSession.decode` follows).
final class ServedCrewTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - the live envelope

    /// Verbatim output captured from the mini, 2026-09-07 — see the issue.
    func testDecodesTheLiveEnvelope() {
        let rows = ServedCrew.decode(data("""
        {"crews": [
          {"bead": "signpost/bead/signpost", "derived": ["project", "bead"],
           "displayName": "Signpost", "host": "mini", "id": "signpost",
           "project": "signpost", "sessionId": "$58", "sessions": [],
           "workingDirectory": "\(TestHost.homeRoot)/Convivy/signpost"},
          {"bead": "company/bead/convivy-builder", "derived": ["project"],
           "displayName": "Shipwright", "host": "mini", "id": "shipwright",
           "project": "shipwright", "sessionId": "$59", "sessions": [],
           "workingDirectory": "\(TestHost.homeRoot)/Convivy/shipwright"}
        ]}
        """), host: TestHost.target)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].crewId, "signpost")
        XCTAssertEqual(rows[0].displayName, "Signpost")
        XCTAssertEqual(rows[0].workingDirectory, "\(TestHost.homeRoot)/Convivy/signpost")
        XCTAssertEqual(rows[0].sessionId, "$58")
        XCTAssertEqual(rows[0].specHost, "mini")
        XCTAssertEqual(rows[0].project, "signpost")
        XCTAssertEqual(rows[0].bead, "signpost/bead/signpost")
        XCTAssertEqual(rows[0].sessions, [])
        XCTAssertEqual(rows[0].derived, ["project", "bead"])
        XCTAssertEqual(rows[0].host, TestHost.target)

        XCTAssertEqual(rows[1].crewId, "shipwright")
        XCTAssertEqual(rows[1].sessionId, "$59")
    }

    /// `repo` is not in the live envelope captured above (undocumented in
    /// the contract as of this field's introduction — see `Crew.repo`'s
    /// doc), but decodes the same raw, unvalidated way `project`/`bead` do
    /// when a spec does name one.
    func testRepoDecodesWhenPresent() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "signpost", "repo": "convivy/signpost"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.first?.repo, "convivy/signpost")
    }

    // MARK: - the null/absent-field degrade, point by point

    func testEveryFieldButIdIsOptional() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "orchard-commercial"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows, [ServedCrew(crewId: "orchard-commercial", host: TestHost.target)])
    }

    func testExplicitNullsDegradeTheSameAsAbsentFields() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "orchard-commercial", "displayName": null, "workingDirectory": null,
                    "sessionId": null, "host": null, "project": null, "bead": null, "repo": null,
                    "sessions": null, "derived": null}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows, [ServedCrew(crewId: "orchard-commercial", host: TestHost.target)])
    }

    /// Wrong-typed fields degrade to nil rather than crashing or coercing.
    func testWronglyTypedFieldsDegradeToNil() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "orchard-commercial", "displayName": 7, "sessionId": 58,
                    "project": true, "repo": 5, "sessions": "not-an-array", "derived": "not-an-array"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows, [ServedCrew(crewId: "orchard-commercial", host: TestHost.target)])
    }

    // MARK: - a row missing id costs only itself

    func testARowMissingIdIsSkippedButOthersAreKept() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"displayName": "No id here"},
                    {"id": "signpost", "displayName": "Signpost"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.map(\.crewId), ["signpost"])
    }

    func testAnEmptyIdIsSkipped() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": ""}, {"id": "signpost"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.map(\.crewId), ["signpost"])
    }

    func testANonObjectRowIsSkipped() {
        let rows = ServedCrew.decode(data("""
        {"crews": ["not-an-object", {"id": "signpost"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.map(\.crewId), ["signpost"])
    }

    // MARK: - only a malformed top-level payload fails

    func testNotJSONDecodesToEmpty() {
        XCTAssertEqual(ServedCrew.decode(data("not json"), host: TestHost.target), [])
    }

    func testNotAnObjectDecodesToEmpty() {
        XCTAssertEqual(ServedCrew.decode(data("[]"), host: TestHost.target), [])
    }

    func testMissingCrewsKeyDecodesToEmpty() {
        XCTAssertEqual(ServedCrew.decode(data("{}"), host: TestHost.target), [])
    }

    func testCrewsKeyOfTheWrongTypeDecodesToEmpty() {
        XCTAssertEqual(ServedCrew.decode(data("""
        {"crews": "not-an-array"}
        """), host: TestHost.target), [])
    }

    func testEmptyDataDecodesToEmpty() {
        XCTAssertEqual(ServedCrew.decode(Data(), host: TestHost.target), [])
    }

    // MARK: - workingDirectory is gated the same way an ssh command line gates it

    /// A working directory that would fail `validateWorkingDirectory` — a
    /// relative path, here — degrades to `nil`: the field costs itself, not
    /// the row, the same discipline `ThemeConfiguration.parseRail` applies
    /// to a hand-edited config's own `workdir`.
    func testAnInvalidWorkingDirectoryDegradesToNilRatherThanFailingTheRow() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "signpost", "workingDirectory": "not/absolute"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.workingDirectory)
    }

    func testAValidWorkingDirectoryPassesThrough() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "signpost", "workingDirectory": "\(TestHost.homeRoot)/Convivy/signpost"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.first?.workingDirectory, "\(TestHost.homeRoot)/Convivy/signpost")
    }

    // MARK: - children

    func testDecodesChildSessions() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "signpost",
                    "sessions": [{"name": "signpost--build", "displayName": "Build",
                                  "sessionId": "$19"}]}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.first?.sessions,
                       [ServedCrew.Child(name: "signpost--build", displayName: "Build", sessionId: "$19")])
    }

    /// A child missing `name` costs only itself, the same rule the crew row
    /// follows for `id`.
    func testAChildMissingNameIsSkippedButOthersAreKept() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "signpost",
                    "sessions": [{"displayName": "No name"},
                                 {"name": "signpost--build"}]}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.first?.sessions.map(\.name), ["signpost--build"])
    }

    // MARK: - shape/documents (steward-board proposal, 2026-09-09, phase A —
    // undocumented in the contract as of this field's introduction, see
    // `ServedCrew.shape`'s own doc)

    func testDecodesShapeAndDocuments() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "steward", "shape": "board", "documents": ["backlog.md", "CLAUDE.md"]}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.first?.shape, "board")
        XCTAssertEqual(rows.first?.documents, ["backlog.md", "CLAUDE.md"])
    }

    /// `validateDocumentEntry` is a decode-time sanity check, not the
    /// containment boundary (see that function's doc) — a `..` traversal
    /// component costs only that entry, the rest of the array survives.
    func testADocumentEntryContainingDotDotIsDropped() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "steward", "documents": ["../../../etc/passwd", "backlog.md"]}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.first?.documents, ["backlog.md"])
    }

    /// A control character (here, a newline) would corrupt a log line or a
    /// viewer, so it costs the entry the same way.
    func testADocumentEntryContainingAControlCharacterIsDropped() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "steward", "documents": ["backlog.md\\nrm -rf", "CLAUDE.md"]}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.first?.documents, ["CLAUDE.md"])
    }

    /// An already-absolute entry passes the decode-time sanity check —
    /// it is exactly the shape that later has to clear the real containment
    /// boundary (`DeckOpenRef.validatePath`) when opened, not this one.
    func testAnAbsoluteDocumentEntryPassesTheDecodeTimeCheck() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "steward", "documents": ["\(TestHost.homeRoot)/.config/convivy/llm-gateway.env"]}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.first?.documents, ["\(TestHost.homeRoot)/.config/convivy/llm-gateway.env"])
    }

    /// Absent, the same "every field but id is optional" degrade the rest
    /// of the row already follows: `shape` reads `nil`, `documents` reads
    /// `[]` — the same empty-array default `sessions`/`derived` fall back to.
    func testShapeAndDocumentsDefaultWhenAbsent() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "signpost"}]}
        """), host: TestHost.target)
        XCTAssertNil(rows.first?.shape)
        XCTAssertEqual(rows.first?.documents, [])
    }

    /// Wrong-typed `shape`/`documents` degrade the same way `project`/
    /// `sessions` do above — the field costs itself, not the row.
    func testWronglyTypedShapeAndDocumentsDegrade() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "signpost", "shape": 7, "documents": "not-an-array"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.shape)
        XCTAssertEqual(rows.first?.documents, [])
    }

    // MARK: - the host stamp

    func testDecodeStampsEveryRowWithTheGivenHost() {
        let rows = ServedCrew.decode(data("""
        {"crews": [{"id": "signpost"}]}
        """), host: TestHost.secondaryTarget)
        XCTAssertEqual(rows.first?.host, TestHost.secondaryTarget)
    }

    func testIDDiffersByHostForTheSameCrewId() {
        let a = ServedCrew.decode(data("""
        {"crews": [{"id": "signpost"}]}
        """), host: TestHost.target).first!
        let b = ServedCrew.decode(data("""
        {"crews": [{"id": "signpost"}]}
        """), host: TestHost.secondaryTarget).first!
        XCTAssertNotEqual(a.id, b.id)
    }
}
