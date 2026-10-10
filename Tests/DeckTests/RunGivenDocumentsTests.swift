import Foundation
import XCTest
@testable import Deck

/// The "Documents it was given" decoder: the record's rows, the activation
/// cross-check, the register's answers and the run-id gate on its fetch.
final class RunGivenDocumentsTests: XCTestCase {
    /// The `docs_consulted.json` of a finished run (`2026-10-05/run-ff27ab1f`),
    /// trimmed to the rows that show each kind. Its ids are knowledge-document
    /// ids and its hashes are content hashes, so nothing here is user data.
    private static let recordJSON = """
    {
      "profile": "deck/daytime",
      "materialized_at_activation": {"agents": ["deck-security-reviewer"], "skills": ["security-review-rubric"]},
      "individuated_at_activation": {"agents": ["deck-security-reviewer"], "skills": ["security-review-rubric"]},
      "queried_at_runtime": [],
      "docs": [
        {"id": "deck/agents/deck-security-reviewer", "kind": "agent", "body_sha256": "e994bbe163b18d92624f9563b784c7d2a560c3f2ad507ee97d05db426115b860"},
        {"id": "engineering-practice/skills/security-review-rubric", "kind": "skill", "body_sha256": "6df329ad29a06719221bcdba79c4b7293243c36da3a8bf988f7ab5f9ee583213"},
        {"id": "platform/instruction-blocks/orchestrator-waits-in-the-foreground", "kind": "instruction-block", "body_sha256": "0e39d3eee6c8ec52298d0774575d6e62d799301195f5604804cf2859ec4d0101", "scope": "crew"},
        {"id": "platform/instruction-blocks/review-a-pull-request", "kind": "instruction-block", "body_sha256": "231c4206536b11d27efb96407e52f11513d51c6212658e32e4478438f9b8f7c6", "scope": "agent"}
      ]
    }
    """

    private func record(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func listing(_ decoded: RunGivenDocuments,
                         file: StaticString = #filePath, line: UInt = #line) -> RunGivenDocuments.Listing {
        guard case .listed(let listing) = decoded else {
            XCTFail("expected a listing, got \(decoded)", file: file, line: line)
            return RunGivenDocuments.Listing(documents: [], unmatchedNames: [])
        }
        return listing
    }

    // MARK: - Rows

    func testTheRecordsRowsAreAllListedInItsOrderWithTheirIdKindHashAndScope() throws {
        let listing = try listing(RunGivenDocuments.decodeRecord(try record(Self.recordJSON)))
        XCTAssertEqual(listing.documents.map(\.recordId), [
            "deck/agents/deck-security-reviewer",
            "engineering-practice/skills/security-review-rubric",
            "platform/instruction-blocks/orchestrator-waits-in-the-foreground",
            "platform/instruction-blocks/review-a-pull-request",
        ])
        XCTAssertEqual(listing.documents.map(\.kind), ["agent", "skill", "instruction-block", "instruction-block"])
        XCTAssertEqual(listing.documents[0].bodyHash,
                       "e994bbe163b18d92624f9563b784c7d2a560c3f2ad507ee97d05db426115b860")
        XCTAssertEqual(listing.documents[2].scope, "crew")
        XCTAssertNil(listing.documents[0].scope, "only instruction blocks carry a scope")
        XCTAssertEqual(listing.unmatchedNames, [], "the list agrees with the activation block")
    }

    func testARowWithNoIdStaysListedAndSaysItCannotOpen() throws {
        let listing = try listing(RunGivenDocuments.decodeRecord(try record("""
        {"docs": [{"kind": "agent", "body_sha256": null}, "not-an-object"]}
        """)))
        XCTAssertEqual(listing.documents.count, 2, "a row the record cannot name is still a row it holds")
        XCTAssertNil(listing.documents[0].recordId)
        XCTAssertNil(listing.documents[0].openableId)
        XCTAssertNil(listing.documents[1].recordId)
        XCTAssertEqual(listing.documents[1].kind, "")
    }

    func testAnIdThatIsNotAKnowledgeIdStaysListedButDoesNotOpen() throws {
        let listing = try listing(RunGivenDocuments.decodeRecord(try record("""
        {"docs": [{"id": "../../etc/passwd", "kind": "decision"},
                  {"id": "deck/decisions/0001-real", "kind": "decision"}]}
        """)))
        XCTAssertEqual(listing.documents.count, 2)
        XCTAssertNil(listing.documents[0].openableId, "a path-shaped id is refused by the open gate")
        XCTAssertEqual(listing.documents[1].openableId, "deck/decisions/0001-real")
    }

    func testAListWithNoDocumentsKeyIsReportedNotDrawnAsEmpty() throws {
        XCTAssertEqual(RunGivenDocuments.decodeRecord(try record(#"{"materialized_at_activation": {}}"#)),
                       .unavailable(.noDocumentList))
    }

    // MARK: - Activation cross-check

    func testAnAgentOrSkillTheActivationNamesAndNoRowCarriesIsReported() throws {
        let listing = try listing(RunGivenDocuments.decodeRecord(try record("""
        {"individuated_at_activation": {"agents": ["deck-security-reviewer"], "skills": ["security-review-rubric"]},
         "docs": [{"id": "engineering-practice/skills/security-review-rubric", "kind": "skill"}]}
        """)))
        XCTAssertEqual(listing.unmatchedNames, ["deck-security-reviewer"])
    }

    func testTheNewActivationKeyWinsOverTheOlderOne() throws {
        let listing = try listing(RunGivenDocuments.decodeRecord(try record("""
        {"materialized_at_activation": {"agents": ["a"], "skills": []},
         "individuated_at_activation": {"agents": ["b"], "skills": []},
         "docs": [{"id": "deck/agents/a", "kind": "agent"}]}
        """)))
        XCTAssertEqual(listing.unmatchedNames, ["b"], "b is the name checked; a is ignored")
    }

    func testTheOlderActivationKeyIsCheckedWhenTheNewOneIsAbsent() throws {
        let listing = try listing(RunGivenDocuments.decodeRecord(try record("""
        {"materialized_at_activation": {"agents": ["a"], "skills": []},
         "docs": [{"id": "deck/agents/z", "kind": "agent"}]}
        """)))
        XCTAssertEqual(listing.unmatchedNames, ["a"])
    }

    // MARK: - Register answers

    func testTheRegisterAnswersUnknownWithheldAndNoRecord() throws {
        XCTAssertEqual(RunGivenDocuments.decodeRegister(Data(#"{"found": false}"#.utf8)),
                       .unavailable(.unknownRun))
        XCTAssertEqual(RunGivenDocuments.decodeRegister(Data(#"{"found": true, "private": true}"#.utf8)),
                       .unavailable(.withheld))
        XCTAssertEqual(RunGivenDocuments.decodeRegister(Data(#"{"found": true, "docs_consulted": null}"#.utf8)),
                       .unavailable(.noRecord))
        XCTAssertEqual(RunGivenDocuments.decodeRegister(Data(#"{"found": true, "docs_consulted": "x"}"#.utf8)),
                       .unavailable(.unreadable))
    }

    /// A null record names the missing part without saying why it is missing:
    /// the register does not say, and a sentence about a run still going would
    /// be a guess.
    func testANullRecordReadsAsMissingOrUnreadableWithoutGuessingWhy() {
        XCTAssertEqual(RunGivenDocuments.Reason.noRecord.explanation,
                       "This run's record of the documents it was given is missing or unreadable.")
    }

    func testARegisterAnswerThatIsNotTheEnvelopeIsAFailedRead() {
        XCTAssertNil(RunGivenDocuments.decodeRegister(Data("<html>502</html>".utf8)),
                     "nil is the caller's failed read, not an empty list")
    }

    func testARegisterAnswerCarriesTheRecordsRows() throws {
        let data = Data("{\"found\": true, \"docs_consulted\": \(Self.recordJSON)}".utf8)
        let listing = try listing(XCTUnwrap(RunGivenDocuments.decodeRegister(data)))
        XCTAssertEqual(listing.documents.count, 4)
    }

    // MARK: - Groups

    func testGroupsPutAgentsThenSkillsThenInstructionBlocksThenTheRest() {
        let docs = [
            RunGivenDocuments.Document(position: 0, recordId: "x/decisions/a", kind: "decision", bodyHash: nil, scope: nil),
            RunGivenDocuments.Document(position: 1, recordId: "x/instruction-blocks/b", kind: "instruction-block", bodyHash: nil, scope: nil),
            RunGivenDocuments.Document(position: 2, recordId: "x/skills/c", kind: "skill", bodyHash: nil, scope: nil),
            RunGivenDocuments.Document(position: 3, recordId: "x/agents/d", kind: "agent", bodyHash: nil, scope: nil),
            RunGivenDocuments.Document(position: 4, recordId: "x/architecture/e", kind: "architecture", bodyHash: nil, scope: nil),
        ]
        XCTAssertEqual(RunGivenDocuments.groups(docs).map(\.kind),
                       ["agent", "skill", "instruction-block", "architecture", "decision"])
        XCTAssertEqual(RunGivenDocuments.groups(docs).map(\.title),
                       ["Agents", "Skills", "Instruction blocks", "Architecture", "Decisions"])
    }

    // MARK: - Fetch command

    func testTheFetchAsksTheRegisterForOneRunsRecord() throws {
        let args = try RunGivenDocuments.arguments(
            target: SSHTarget(user: TestHost.user, host: "mini.local"), runId: "run-ff27ab1f",
            controlPath: "/tmp/cm", home: TestHost.homeRoot)
        XCTAssertEqual(args.last?.hasSuffix("http://x/runs/run-ff27ab1f/docs_given"), true)
    }

    func testARunIdWithShellMetacharactersIsRefusedBeforeItReachesTheRemoteCommand() {
        XCTAssertThrowsError(try RunGivenDocuments.arguments(
            target: SSHTarget(user: TestHost.user, host: "mini.local"), runId: "run-1; rm -rf ~",
            controlPath: "/tmp/cm", home: TestHost.homeRoot))
        XCTAssertThrowsError(try RunGivenDocuments.validateRunId(""))
    }
}
