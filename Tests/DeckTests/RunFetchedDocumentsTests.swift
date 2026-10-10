import Foundation
import XCTest
@testable import Deck

/// The "Documents it has fetched" decoder: the register's list in fetch order,
/// its unavailable answers, the failed-read cases that must never draw as an
/// empty list, and the route and run-id gate on its fetch.
final class RunFetchedDocumentsTests: XCTestCase {
    /// The `docs_fetched` answer for a finished run (`2026-10-05/run-d74a51c0`),
    /// which the producer derives from that run's `tool_calls.jsonl`. Its ids
    /// are knowledge-document ids, so nothing here is user data.
    private static let answerJSON = """
    {
      "found": true,
      "docs_fetched": [
        {"id": "platform/instruction-blocks/review-a-pull-request", "kind": "knowledge", "fetched_at": "2026-10-05T13:12:56Z"},
        {"id": "deck/agents/deck-security-reviewer", "kind": "knowledge", "fetched_at": "2026-10-05T13:12:56Z"},
        {"id": "sig-42", "kind": "signal", "fetched_at": "2026-10-05T13:14:01Z"}
      ]
    }
    """

    private func decode(_ json: String) -> RunFetchedDocuments? {
        RunFetchedDocuments.decodeRegister(Data(json.utf8))
    }

    private func documents(_ decoded: RunFetchedDocuments?,
                           file: StaticString = #filePath, line: UInt = #line) throws -> [RunFetchedDocuments.Document] {
        guard case .listed(let listing) = try XCTUnwrap(decoded, file: file, line: line) else {
            XCTFail("expected a listed answer", file: file, line: line)
            return []
        }
        return listing.documents
    }

    private func listing(_ decoded: RunFetchedDocuments?,
                         file: StaticString = #filePath, line: UInt = #line) throws -> RunFetchedDocuments.Listing {
        guard case .listed(let listing) = try XCTUnwrap(decoded, file: file, line: line) else {
            XCTFail("expected a listed answer", file: file, line: line)
            return .init(documents: [])
        }
        return listing
    }

    /// A `searches` value for the tests below: a KB search, an Archives search,
    /// and a KB search with no timestamp.
    private static let searchesJSON = """
    "searches": [
      {"tool": "kb_search", "query": "review a pull request", "searched_at": "2026-10-05T13:12:50Z"},
      {"tool": "signal_search", "query": "deploy incident", "searched_at": "2026-10-05T13:13:10Z"},
      {"tool": "kb_search", "query": "dispatch", "searched_at": null}
    ]
    """

    // MARK: - Listing

    func testTheListIsServedInFetchOrderWithItsIdKindAndTime() throws {
        let rows = try documents(decode(Self.answerJSON))
        XCTAssertEqual(rows.map(\.documentId), [
            "platform/instruction-blocks/review-a-pull-request",
            "deck/agents/deck-security-reviewer",
            "sig-42",
        ])
        XCTAssertEqual(rows.map(\.position), [0, 1, 2])
        XCTAssertEqual(rows.map(\.kind), ["knowledge", "knowledge", "signal"])
        XCTAssertEqual(rows[2].fetchedAt, "2026-10-05T13:14:01Z")
        XCTAssertNotNil(rows[0].fetchedLabel(now: Date()))
    }

    func testAKnowledgeDocumentLabelsWithItsLastIdSegmentAndAnArchivesRecordWithItsWholeId() throws {
        let rows = try documents(decode(Self.answerJSON))
        XCTAssertEqual(rows[0].label, "review-a-pull-request")
        XCTAssertEqual(rows[2].label, "sig-42")
    }

    func testAKnowledgeDocumentOpensAndAnArchivesRecordDoesNot() throws {
        let rows = try documents(decode(Self.answerJSON))
        XCTAssertEqual(rows[0].openableId, "platform/instruction-blocks/review-a-pull-request")
        XCTAssertNil(rows[2].openableId, "Deck has no open path for an Archives record")
    }

    func testAKnowledgeIdThatFailsTheOpenGateStaysListedAndCannotOpen() throws {
        let rows = try documents(decode(#"{"found": true, "docs_fetched": [{"id": "not a valid id", "kind": "knowledge", "fetched_at": null}]}"#))
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].openableId)
        XCTAssertNil(rows[0].fetchedAt)
        XCTAssertNil(rows[0].fetchedLabel(now: Date()))
    }

    /// An empty list from a read that succeeded is a real answer: the run has
    /// fetched nothing yet. It is not the failed-read case below.
    func testAnEmptyListFromASuccessfulReadIsAListedAnswer() throws {
        XCTAssertEqual(decode(#"{"found": true, "docs_fetched": []}"#), .listed(.init(documents: [])))
    }

    // MARK: - Searches

    func testSearchesArePresentInCallOrderAndApartFromTheDocuments() throws {
        let answer = try listing(decode(#"{"found": true, "docs_fetched": [{"id": "sig-42", "kind": "signal", "fetched_at": null}], \#(Self.searchesJSON)}"#))
        XCTAssertEqual(answer.documents.map(\.documentId), ["sig-42"], "a search never joins the fetched list")
        let searches = try XCTUnwrap(answer.searches)
        XCTAssertEqual(searches.map(\.tool), ["kb_search", "signal_search", "kb_search"])
        XCTAssertEqual(searches.map(\.query), ["review a pull request", "deploy incident", "dispatch"])
        XCTAssertEqual(searches.map(\.position), [0, 1, 2])
        XCTAssertEqual(searches.map(\.kindLabel), ["Knowledge search", "Archives search", "Knowledge search"])
        XCTAssertNotNil(searches[0].searchedLabel(now: Date()))
        XCTAssertNil(searches[2].searchedLabel(now: Date()), "a null timestamp draws no time")
        XCTAssertEqual(answer.unreadableSearches, 0)
    }

    func testAnEmptySearchesArrayMeansNoneWereMade() throws {
        let answer = try listing(decode(#"{"found": true, "docs_fetched": [], "searches": []}"#))
        XCTAssertEqual(answer.searches, [], "an empty array is a shown, empty list")
    }

    func testAnAbsentSearchesKeyMeansNotShownNotNone() throws {
        // The producer as it stands today: no `searches` key at all.
        let answer = try listing(decode(Self.answerJSON))
        XCTAssertNil(answer.searches, "a missing key is not the same as no searches")
        XCTAssertEqual(answer.unreadableSearches, 0)
    }

    func testANonArraySearchesValueIsNotShown() throws {
        let answer = try listing(decode(#"{"found": true, "docs_fetched": [], "searches": null}"#))
        XCTAssertNil(answer.searches)
    }

    func testAPrivateRunCarriesNoSearches() {
        XCTAssertEqual(decode(#"{"found": true, "private": true, "searches": [{"tool": "kb_search", "query": "x", "searched_at": null}]}"#),
                       .unavailable(.withheld))
    }

    /// A malformed search row is counted and skipped. The other search rows
    /// and every document row still draw.
    func testAMalformedSearchRowDemotesOnlyThatRow() throws {
        let answer = try listing(decode(#"""
        {"found": true, "docs_fetched": [{"id": "platform/x/y", "kind": "knowledge", "fetched_at": null}],
         "searches": [
           {"tool": "kb_search", "query": "good one", "searched_at": null},
           {"tool": "kb_get", "query": "wrong tool", "searched_at": null},
           {"tool": "signal_search", "searched_at": null},
           42,
           {"tool": "signal_search", "query": "also good", "searched_at": null}
         ]}
        """#))
        XCTAssertEqual(answer.documents.map(\.documentId), ["platform/x/y"])
        XCTAssertEqual(answer.searches?.map(\.query), ["good one", "also good"])
        XCTAssertEqual(answer.searches?.map(\.position), [0, 4])
        XCTAssertEqual(answer.unreadableSearches, 3)
    }

    /// The producer bounds the query, but control characters still reach the
    /// pane as text, so the query is cleaned before it is drawn.
    func testControlCharactersInAQueryAreReplacedForDisplay() throws {
        let answer = try listing(decode(#"{"found": true, "docs_fetched": [], "searches": [{"tool": "kb_search", "query": "a\u001b[31mb\nc\u0007d", "searched_at": null}]}"#))
        let query = try XCTUnwrap(answer.searches?.first?.query)
        // ESC is U+241B and BEL is U+2407 in the Control Pictures block; the newline is a space.
        XCTAssertEqual(query, "a\u{241B}[31mb c\u{2407}d")
        XCTAssertFalse(query.unicodeScalars.contains { $0.properties.generalCategory == .control })
    }

    // MARK: - Unavailable

    func testAnUnknownRunSaysSoRatherThanListingNothing() {
        XCTAssertEqual(decode(#"{"found": false}"#), .unavailable(.unknownRun))
    }

    func testAPrivateRunIsWithheldAndItsListIsNotRead() {
        XCTAssertEqual(decode(#"{"found": true, "private": true}"#), .unavailable(.withheld))
        // A private answer that somehow carries a list must not draw it.
        XCTAssertEqual(decode(#"{"found": true, "private": true, "docs_fetched": [{"id": "x/y/z", "kind": "knowledge", "fetched_at": null}]}"#),
                       .unavailable(.withheld))
    }

    // MARK: - Failed read

    /// Every shape here is a failed read: `decodeRegister` answers nil, which
    /// the model turns into a failure sentence. None may decode to an empty list.
    func testAMalformedAnswerIsAFailedReadNeverAnEmptyList() {
        XCTAssertNil(decode("<html>502</html>"))
        XCTAssertNil(decode(#"{"docs_fetched": []}"#), "no found key")
        XCTAssertNil(decode(#"{"found": true}"#), "found but no list")
        XCTAssertNil(decode(#"{"found": true, "docs_fetched": "x"}"#), "list is not an array")
        XCTAssertNil(decode(#"{"found": true, "docs_fetched": null}"#), "list is null")
    }

    /// A document row with no id or kind, or one that is not an object, costs
    /// only that row. The good rows still draw, and the bad ones are counted.
    /// Before this change, one such row failed the whole answer, so the pane
    /// showed the failure sentence in place of the list.
    func testAMalformedDocumentRowDemotesOnlyThatRow() throws {
        let answer = try listing(decode(#"""
        {"found": true, "docs_fetched": [
           {"id": "platform/x/y", "kind": "knowledge", "fetched_at": null},
           {"kind": "knowledge", "fetched_at": null},
           42,
           {"id": "sig-7", "fetched_at": null},
           {"id": "sig-42", "kind": "signal", "fetched_at": null}
         ]}
        """#))
        XCTAssertEqual(answer.documents.map(\.documentId), ["platform/x/y", "sig-42"])
        XCTAssertEqual(answer.documents.map(\.position), [0, 4], "the place is the register's index, so a skipped row leaves a gap")
        XCTAssertEqual(answer.unreadableDocuments, 3)
    }

    /// Every row unreadable is still a read that succeeded: the answer lists
    /// no documents and counts the rows, so the pane says they could not be
    /// read rather than that none were fetched.
    func testAnAnswerWhoseRowsAreAllUnreadableListsNoneAndCountsThem() throws {
        let answer = try listing(decode(#"{"found": true, "docs_fetched": [{"kind": "knowledge"}, 7]}"#))
        XCTAssertEqual(answer.documents, [])
        XCTAssertEqual(answer.unreadableDocuments, 2)
    }

    // MARK: - Fetch command

    func testTheFetchAsksTheDocsFetchedRouteForOneRun() throws {
        let args = try RunFetchedDocuments.arguments(
            target: SSHTarget(user: TestHost.user, host: "mini.local"), runId: "run-d74a51c0",
            controlPath: "/tmp/cm", home: TestHost.homeRoot)
        XCTAssertEqual(args.last?.hasSuffix("http://x/runs/run-d74a51c0/docs_fetched"), true)
        XCTAssertEqual(args.last?.contains("docs_given"), false)
    }

    func testARunIdWithShellMetacharactersIsRefusedBeforeItReachesTheRemoteCommand() {
        XCTAssertThrowsError(try RunFetchedDocuments.arguments(
            target: SSHTarget(user: TestHost.user, host: "mini.local"), runId: "run-1; rm -rf ~",
            controlPath: "/tmp/cm", home: TestHost.homeRoot))
    }
}
