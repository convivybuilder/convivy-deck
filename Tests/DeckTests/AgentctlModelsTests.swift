import XCTest
@testable import Deck

/// `agentctl models --json`, the list of models a dispatch will accept —
/// `platform/contracts/agentctl-models`. Every case here pins `decode` as a
/// pure function of bytes, the same discipline `SessionAgent`'s own decoders
/// (`decodeDelta`, `decodeUnqueue`) get, so the three "list unavailable"
/// cases the contract names — a non-zero exit's empty stdout, unparseable
/// stdout, and an unknown `schema_version` — can be pinned without an ssh
/// round trip.
final class AgentctlModelsTests: XCTestCase {

    /// The live sample from macstudio, 2026-09-28: two aliased models and one
    /// with none.
    private let sampleJSON = """
        {"schema_version": 1, "models": [
            {"alias": "opus", "model": "claude-opus-5", "provider": "anthropic"},
            {"alias": "deepseek", "model": "deepseek/deepseek-v4-flash", "provider": "gateway"},
            {"alias": null, "model": "claude-opus-4-8", "provider": "anthropic"}
        ]}
        """

    // MARK: - argv

    func testArgumentsNameTheHostAndTheJSONVerb() throws {
        let args = try AgentctlModels.arguments(target: TestHost.target, controlPath: "/tmp/cp")
        XCTAssertTrue(args.contains("agentctl"))
        XCTAssertTrue(args.contains("models"))
        XCTAssertTrue(args.contains("--json"))
        XCTAssertTrue(args.contains("\(TestHost.user)@\(TestHost.address)"))
    }

    func testAHostOrUserBeginningWithADashIsRefusedBeforeSshSeesIt() {
        XCTAssertThrowsError(try AgentctlModels.arguments(
            target: SSHTarget(user: TestHost.user, host: "-oProxyCommand=evil"), controlPath: "/tmp/cp"))
        XCTAssertThrowsError(try AgentctlModels.arguments(
            target: SSHTarget(user: "-oProxyCommand=evil", host: TestHost.address), controlPath: "/tmp/cp"))
    }

    func testArgumentsCarryTheSameControlMasterOptionsAsOtherHostWideVerbs() throws {
        let args = try AgentctlModels.arguments(target: TestHost.target, controlPath: "/tmp/cp")
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("ControlPath=/tmp/cp"))
        XCTAssertTrue(args.contains("ServerAliveInterval=15"))
    }

    // MARK: - Decoding a good list

    func testAGoodListDecodesEveryFieldInOrder() {
        guard case .models(let entries) = AgentctlModels.decode(Data(sampleJSON.utf8)) else {
            return XCTFail("expected .models")
        }
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0], AgentctlModels.ModelEntry(
            alias: "opus", model: "claude-opus-5", provider: "anthropic"))
        XCTAssertEqual(entries[1], AgentctlModels.ModelEntry(
            alias: "deepseek", model: "deepseek/deepseek-v4-flash", provider: "gateway"))
        XCTAssertEqual(entries[2], AgentctlModels.ModelEntry(
            alias: nil, model: "claude-opus-4-8", provider: "anthropic"))
    }

    /// THE ORDER IS FIXED BY THE CONTRACT AND NEVER SORTED. A list that
    /// arrives in an order a sort would not produce (aliased models are not
    /// alphabetical) must come back exactly as given.
    func testOrderIsPreservedExactlyAsGivenNeverSorted() {
        let json = """
            {"schema_version": 1, "models": [
                {"alias": "z-alias", "model": "z-model", "provider": "anthropic"},
                {"alias": "a-alias", "model": "a-model", "provider": "anthropic"}
            ]}
            """
        guard case .models(let entries) = AgentctlModels.decode(Data(json.utf8)) else {
            return XCTFail("expected .models")
        }
        XCTAssertEqual(entries.map(\.model), ["z-model", "a-model"])
    }

    /// A host that genuinely serves nothing is a real, decodable answer —
    /// distinct from `.unavailable`, which means the answer could not be
    /// trusted at all.
    func testAnEmptyModelsArrayIsAGoodEmptyListNotUnavailable() {
        let outcome = AgentctlModels.decode(Data(#"{"schema_version": 1, "models": []}"#.utf8))
        XCTAssertEqual(outcome, .models([]))
    }

    func testANullAliasDecodesToNilNotAnEmptyString() {
        let json = #"{"schema_version": 1, "models": [{"alias": null, "model": "m", "provider": "anthropic"}]}"#
        guard case .models(let entries) = AgentctlModels.decode(Data(json.utf8)) else {
            return XCTFail("expected .models")
        }
        XCTAssertNil(entries[0].alias)
    }

    // MARK: - The three "list unavailable" cases the contract names

    /// A non-zero exit prints nothing on stdout, per the contract — empty
    /// data is what a caller actually hands `decode` in that case.
    func testEmptyStdoutFromANonZeroExitIsUnavailable() {
        XCTAssertEqual(AgentctlModels.decode(Data()), .unavailable)
    }

    func testUnparseableStdoutIsUnavailable() {
        XCTAssertEqual(AgentctlModels.decode(Data("not json at all".utf8)), .unavailable)
        XCTAssertEqual(AgentctlModels.decode(Data(#"["an", "array", "not", "an", "object"]"#.utf8)), .unavailable)
    }

    func testAnUnknownSchemaVersionIsUnavailable() {
        let json = #"{"schema_version": 2, "models": [{"alias": null, "model": "m", "provider": "anthropic"}]}"#
        XCTAssertEqual(AgentctlModels.decode(Data(json.utf8)), .unavailable)
    }

    func testAMissingSchemaVersionIsUnavailable() {
        XCTAssertEqual(AgentctlModels.decode(Data(#"{"models": []}"#.utf8)), .unavailable)
    }

    /// ONE MALFORMED ENTRY INVALIDATES THE WHOLE LIST — the same discipline
    /// `SessionAgent.decodeDelta` gives a malformed row: a partial list a Set
    /// could dispatch against is a worse failure than an unavailable
    /// control.
    func testAnEntryMissingModelInvalidatesTheWholeList() {
        let json = """
            {"schema_version": 1, "models": [
                {"alias": "opus", "model": "claude-opus-5", "provider": "anthropic"},
                {"alias": "bad"}
            ]}
            """
        XCTAssertEqual(AgentctlModels.decode(Data(json.utf8)), .unavailable)
    }

    func testAnEntryWithAnEmptyModelInvalidatesTheWholeList() {
        let json = #"{"schema_version": 1, "models": [{"alias": null, "model": "", "provider": "anthropic"}]}"#
        XCTAssertEqual(AgentctlModels.decode(Data(json.utf8)), .unavailable)
    }

    // MARK: - Display label

    func testAnAliasedEntryLabelsTheAliasBesideTheModel() {
        let entry = AgentctlModels.ModelEntry(alias: "opus", model: "claude-opus-5", provider: "anthropic")
        XCTAssertTrue(entry.label.contains("opus"))
        XCTAssertTrue(entry.label.contains("claude-opus-5"))
    }

    func testAnUnaliasedEntryLabelsTheModelAlone() {
        let entry = AgentctlModels.ModelEntry(alias: nil, model: "claude-opus-4-8", provider: "anthropic")
        XCTAssertEqual(entry.label, "claude-opus-4-8")
    }
}
