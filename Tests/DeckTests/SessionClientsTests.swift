import XCTest
@testable import Deck

/// `clients` — who is attached to a session's terminal
/// (`platform/contracts/session-agent-api`'s own section of that name,
/// added by agent-platform#956 for this item). This is the first time Deck
/// decodes this field, so every shape the contract names is covered here:
/// a list with labels, a client whose label is `null`, a client whose `via`
/// is `null`, `[]`, `null`, the key absent, and a malformed value.
final class SessionClientsTests: XCTestCase {

    private func decode(_ json: String) -> SessionState.Clients? {
        SessionState.decode(Data(json.utf8), fallbackSession: "x").clients
    }

    // MARK: - A list with labels

    func testDecodesAListWithLabels() throws {
        guard case .attached(let clients) = decode("""
        {"clients": [
            {"pid": 111, "via": "local", "label": "Deck on orchard"},
            {"pid": 222, "via": "ssh", "label": "SSH from harbor"}
        ]}
        """) else { return XCTFail("expected .attached") }
        XCTAssertEqual(clients, [
            SessionState.Client(pid: 111, via: .local, label: "Deck on orchard"),
            SessionState.Client(pid: 222, via: .ssh, label: "SSH from harbor"),
        ])
    }

    // MARK: - A client whose label is null

    /// Still present, still counted — never dropped for lacking a name.
    func testALabelOfNullIsStillCountedNotDropped() throws {
        guard case .attached(let clients) = decode(#"{"clients": [{"pid": 333, "via": "local", "label": null}]}"#)
        else { return XCTFail("expected .attached") }
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients.first?.pid, 333)
        XCTAssertNil(clients.first?.label)
    }

    // MARK: - A client whose via is null

    /// The client's ancestry could not be read; the field demotes to nil,
    /// and the client itself is still kept.
    func testAViaOfNullDemotesOnlyThatFieldNotTheClient() throws {
        guard case .attached(let clients) = decode(#"{"clients": [{"pid": 444, "via": null, "label": "a terminal on studio-one"}]}"#)
        else { return XCTFail("expected .attached") }
        XCTAssertEqual(clients.count, 1)
        XCTAssertNil(clients.first?.via)
        XCTAssertEqual(clients.first?.label, "a terminal on studio-one")
    }

    /// A `via` string this build does not recognise degrades the same way a
    /// `null` does, rather than throwing the client away.
    func testAnUnrecognisedViaDemotesToNilRatherThanDroppingTheClient() throws {
        guard case .attached(let clients) = decode(#"{"clients": [{"pid": 555, "via": "carrier-pigeon", "label": "x"}]}"#)
        else { return XCTFail("expected .attached") }
        XCTAssertEqual(clients.count, 1)
        XCTAssertNil(clients.first?.via)
    }

    // MARK: - []

    /// tmux answered and nobody is attached by tmux — a real, positive
    /// answer, never the same as the field being unreadable.
    func testEmptyListDecodesAsAttachedNothing() {
        XCTAssertEqual(decode(#"{"clients": []}"#), .attached([]))
    }

    // MARK: - null

    /// The read failed. Must draw as unknown, never as "nobody" — that is
    /// `.attached([])`'s job, not this one's.
    func testNullDecodesAsUnknown() {
        XCTAssertEqual(decode(#"{"clients": null}"#), .unknown)
    }

    // MARK: - field absent

    /// A mini that predates the field: nothing was ever asked, so this is
    /// distinct from either `null` or `[]`.
    func testFieldAbsentDecodesAsNil() {
        XCTAssertNil(decode(#"{"session": "x"}"#))
    }

    // MARK: - malformed

    /// A value that is present but neither a list nor `null` cannot say
    /// anything about who is attached, so it folds into the same answer as
    /// `null` — the per-field degrade rule, not a dropped row.
    func testAMalformedValueDecodesAsUnknown() {
        for json in [#"{"clients": "oops"}"#, #"{"clients": 5}"#, #"{"clients": {"not": "a list"}}"#] {
            XCTAssertEqual(decode(json), .unknown, json)
        }
    }

    /// Within an otherwise-valid list, an entry that is not a JSON object,
    /// or carries no readable `pid`, is dropped rather than drawn as a
    /// blank client — the list itself still decodes.
    func testAMalformedEntryIsDroppedNotTheWholeList() throws {
        guard case .attached(let clients) = decode("""
        {"clients": [
            {"pid": 1, "label": "kept"},
            "not an object",
            {"via": "local", "label": "no pid, dropped"},
            {"pid": "not a number", "label": "also dropped"}
        ]}
        """) else { return XCTFail("expected .attached") }
        XCTAssertEqual(clients, [SessionState.Client(pid: 1, via: nil, label: "kept")])
    }

    /// The whole row still decodes when `clients` is the only field present
    /// — a record missing a field demotes that field, never the row.
    func testARecordWithNoClientsFieldStillDecodesEverythingElse() {
        let state = SessionState.decode(Data(#"{"session": "s", "state": "working"}"#.utf8), fallbackSession: "x")
        XCTAssertEqual(state.session, "s")
        XCTAssertEqual(state.phase, .working)
        XCTAssertNil(state.clients)
    }

    // MARK: - `CockpitView.clientsLine` — the wording, apart from drawing it

    /// Absent draws nothing: a mini that predates the field leaves no trace
    /// on the row.
    func testLineIsNilWhenTheFieldIsAbsent() {
        XCTAssertNil(CockpitView.clientsLine(nil))
    }

    func testLineMarksUnknownForNull() {
        XCTAssertEqual(CockpitView.clientsLine(.unknown), "Attached: unknown")
    }

    /// `[]` reads as a fact about tmux alone, never as "nobody is
    /// watching" — Remote Control's own viewers are invisible to this
    /// field either way.
    func testLineForEmptyNeverClaimsNobodyIsWatching() {
        let text = CockpitView.clientsLine(.attached([]))
        XCTAssertEqual(text, "Attached: no terminal client")
        XCTAssertFalse(text!.lowercased().contains("nobody"))
        XCTAssertFalse(text!.lowercased().contains("no one"))
    }

    func testLineForOneNamedClientIsJustTheLabel() {
        XCTAssertEqual(
            CockpitView.clientsLine(.attached([.init(pid: 1, via: .local, label: "Deck on orchard")])),
            "Attached: Deck on orchard")
    }

    /// Summarised to the first label plus a count, never one line per
    /// client — what keeps the row inside its existing height budget.
    func testLineForTwoNamedClientsSummarisesAsFirstLabelPlusACount() {
        XCTAssertEqual(
            CockpitView.clientsLine(.attached([
                .init(pid: 1, via: .local, label: "Deck on orchard"),
                .init(pid: 2, via: .ssh, label: "SSH from harbor"),
            ])),
            "Attached: Deck on orchard +1 more")
    }

    /// A client with no label is still counted, as an unnamed one — never
    /// dropped from the tally.
    func testLineForAnUnnamedClientCountsItRatherThanDroppingIt() {
        XCTAssertEqual(
            CockpitView.clientsLine(.attached([.init(pid: 1, via: nil, label: nil)])),
            "Attached: 1 unnamed client")
        XCTAssertEqual(
            CockpitView.clientsLine(.attached([
                .init(pid: 1, via: nil, label: nil),
                .init(pid: 2, via: nil, label: nil),
            ])),
            "Attached: 2 unnamed clients")
    }

    /// A mix of named and unnamed folds the unnamed ones into the count
    /// alongside any other named clients past the first.
    func testLineForAMixOfNamedAndUnnamedFoldsTheUnnamedIntoTheCount() {
        XCTAssertEqual(
            CockpitView.clientsLine(.attached([
                .init(pid: 1, via: .local, label: "Deck on orchard"),
                .init(pid: 2, via: nil, label: nil),
            ])),
            "Attached: Deck on orchard +1 more")
    }
}
