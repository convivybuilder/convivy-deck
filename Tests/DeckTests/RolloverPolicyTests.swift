import XCTest
@testable import Deck

/// `session-agent rollover-policy`: its argv, its answer, and the Hosts pane's
/// parsing of what a person types before anything is sent.
final class RolloverPolicyTests: XCTestCase {

    private let target = SSHTarget(user: "operator", host: "10.0.0.5")

    // MARK: - argv

    /// A read sends no session name and no `--set`: the policy belongs to the
    /// machine, not to a session.
    func testAReadIsTheBareVerb() throws {
        let argv = try SessionAgent.rolloverPolicyArguments(target: target, updates: [])
        XCTAssertTrue(argv.contains("operator@10.0.0.5"))
        XCTAssertEqual(argv.last, "rollover-policy")
    }

    func testAnUpdateFormatsTheNumberNotTheTypedText() throws {
        let argv = try SessionAgent.rolloverPolicyArguments(target: target, updates: [
            .init(field: .seekPercent, value: 65),
            .init(field: .floorPercent, value: 87.5),
            .init(field: .seekCallCap, value: nil),
        ])
        XCTAssertEqual(Array(argv.suffix(7)), [
            "rollover-policy",
            "--set", "seek_pct=65",
            "--set", "floor_pct=87.5",
            "--set", "seek_call_cap=null",
        ])
    }

    // MARK: - The answer

    private func decode(_ json: String) -> SessionAgent.RolloverPolicyOutcome {
        SessionAgent.decodeRolloverPolicy(Data(json.utf8))
    }

    /// The shape the mini printed on 2026-09-13.
    func testDecodesThePolicyTheMachinePrints() {
        XCTAssertEqual(
            decode(#"{"floor_pct": null, "mode": "observe", "seek_call_cap": null, "seek_pct": 70}"#),
            .policy(SessionState.Rollover.Policy(seekPercent: 70, floorPercent: nil, seekCallCap: nil, mode: "observe")))
    }

    /// A refused edit prints `{"ok": false, "error": …}` at exit 1.
    func testARefusalCarriesTheMachinesReason() {
        XCTAssertEqual(
            decode(#"{"ok": false, "error": "floor_pct (60) must be above seek_pct (70)"}"#),
            .refused("floor_pct (60) must be above seek_pct (70)"))
    }

    /// Empty output is what an older `session-agent` without the verb leaves
    /// on stdout; neither it nor an object with no policy fields reads as a
    /// policy.
    func testAnUnreadableAnswerIsMalformed() {
        for json in ["", "not json", #"{"something": 1}"#] {
            XCTAssertEqual(decode(json), .malformed, json)
        }
    }

    // MARK: - What a person types

    private func parse(_ text: String, _ field: SessionAgent.RolloverPolicyField) -> RolloverPolicySection.Input {
        RolloverPolicySection.parse(text, field: field)
    }

    func testANumberIsAccepted() {
        XCTAssertEqual(parse("65", .seekPercent), .value(65))
        XCTAssertEqual(parse(" 87.5% ", .floorPercent), .value(87.5))
        XCTAssertEqual(parse("40", .seekCallCap), .value(40))
    }

    /// Blank unsets a limit, except where looking starts, which the machine
    /// refuses to leave unset.
    func testBlankUnsetsALimitButNotTheStartingPoint() {
        XCTAssertEqual(parse("", .floorPercent), .value(nil))
        XCTAssertEqual(parse("  ", .seekCallCap), .value(nil))
        guard case .invalid = parse("", .seekPercent) else { return XCTFail("a blank start must be refused") }
    }

    /// Nothing that isn't a finite, in-range number is sent. This is also what
    /// keeps typed text out of the remote command.
    func testOutOfRangeOrNonNumericInputIsRefusedBeforeSending() {
        for (text, field) in [("abc", SessionAgent.RolloverPolicyField.seekPercent),
                              ("70; rm -rf ~", .seekPercent), ("0", .seekPercent), ("100", .seekPercent),
                              ("150", .floorPercent), ("nan", .floorPercent), ("inf", .floorPercent),
                              ("0", .seekCallCap), ("2.5", .seekCallCap)] {
            guard case .invalid = parse(text, field) else {
                return XCTFail("\(text) for \(field.rawValue) should be refused")
            }
        }
    }

    func testFieldTextDropsTrailingZerosAndShowsUnsetAsBlank() {
        XCTAssertEqual(RolloverPolicySection.fieldText(70), "70")
        XCTAssertEqual(RolloverPolicySection.fieldText(87.5), "87.5")
        XCTAssertEqual(RolloverPolicySection.fieldText(nil), "")
    }

    func testRefusalsUseThePanesNames() {
        XCTAssertEqual(
            RolloverPolicySection.readableRefusal("floor_pct (60) must be above seek_pct (70)"),
            "the roll-over-regardless point (60) must be above where looking starts (70)")
    }

    func testModeIsDescribedNotOffered() {
        XCTAssertTrue(RolloverPolicySection.modeDescription("observe").hasPrefix("Not yet."))
        XCTAssertTrue(RolloverPolicySection.modeDescription("enforce").hasPrefix("Yes."))
        XCTAssertEqual(RolloverPolicySection.modeDescription("draining"), "Unknown (draining).")
    }

    /// There is no field for `mode`: Deck never switches whether the machine acts.
    func testDeckOffersNoModeField() {
        XCTAssertEqual(SessionAgent.RolloverPolicyField.allCases.map(\.rawValue),
                       ["seek_pct", "floor_pct", "seek_call_cap"])
    }
}
