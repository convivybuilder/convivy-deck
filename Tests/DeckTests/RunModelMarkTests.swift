import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// The run register's `model_source`, from the wire to the mark a rail row
/// draws. The register is read per run and per field, so every case here is
/// one field going wrong and the rest of the row surviving.
@MainActor
final class RunModelMarkTests: XCTestCase {
    // MARK: - Decoder

    private func decode(_ json: String) -> [String: RunModelChoice]? {
        RunRegister.decode(Data(json.utf8))
    }

    func testEachOfTheSixSourcesDecodes() throws {
        let table = try XCTUnwrap(decode("""
        {"generated_at":"x","runs":[
          {"run_id":"a","model":"m-a","model_source":"roster"},
          {"run_id":"b","model":"m-b","model_source":"override-typed"},
          {"run_id":"c","model":"m-c","model_source":"override-item"},
          {"run_id":"d","model":"m-d","model_source":"failover"},
          {"run_id":"e","model":"m-e","model_source":"override-co"},
          {"run_id":"f","model":"m-f","model_source":"override-unattributed"}]}
        """))
        XCTAssertEqual(table["a"], RunModelChoice(model: "m-a", source: .roster))
        XCTAssertEqual(table["b"], RunModelChoice(model: "m-b", source: .overrideTyped))
        XCTAssertEqual(table["c"], RunModelChoice(model: "m-c", source: .overrideItem))
        XCTAssertEqual(table["d"], RunModelChoice(model: "m-d", source: .failover))
        XCTAssertEqual(table["e"], RunModelChoice(model: "m-e", source: .overrideCo))
        XCTAssertEqual(table["f"], RunModelChoice(model: "m-f", source: .overrideUnattributed))
    }

    func testNullUnknownAndMissingFieldsCostOnlyThatField() throws {
        let table = try XCTUnwrap(decode("""
        {"runs":[
          {"run_id":"nulls","model":null,"model_source":null},
          {"run_id":"unknown","model":"m","model_source":"operator-whim"},
          {"run_id":"missing"},
          {"run_id":"wrongtype","model":7,"model_source":3},
          {"model":"m","model_source":"failover"}]}
        """))
        XCTAssertEqual(table["nulls"], RunModelChoice(model: nil, source: nil))
        XCTAssertEqual(table["unknown"], RunModelChoice(model: "m", source: nil))
        XCTAssertEqual(table["missing"], RunModelChoice(model: nil, source: nil))
        XCTAssertEqual(table["wrongtype"], RunModelChoice(model: nil, source: nil))
        XCTAssertEqual(table.count, 4, "an entry with no run_id has nothing to join on and is skipped")
    }

    func testABodyThatIsNotTheEnvelopeDecodesToNil() {
        XCTAssertNil(decode("not json"))
        XCTAssertNil(decode("[]"))
        XCTAssertNil(decode("{\"runs\":\"none\"}"))
    }

    // MARK: - Command

    func testTheCommandReadsTheSocketOverSSHAndFailsOnHTTPErrors() throws {
        let argv = try RunRegister.arguments(target: TestHost.target, controlPath: "/cp")
        XCTAssertEqual(argv.last, RunRegister.remoteCommand)
        XCTAssertTrue(RunRegister.remoteCommand.contains("--unix-socket \"$HOME/.local/run/run-register-api.sock\""))
        XCTAssertTrue(RunRegister.remoteCommand.hasSuffix("http://x/runs"))
        XCTAssertTrue(RunRegister.remoteCommand.contains(" -f "), "an HTTP error must be a failed read, not an empty table")
        XCTAssertTrue(argv.contains("\(TestHost.user)@\(TestHost.address)"))
        XCTAssertThrowsError(try RunRegister.arguments(target: SSHTarget(user: "-oProxyCommand=x", host: "h")))
    }

    // MARK: - Mark selection

    func testMarkKindPerSource() {
        XCTAssertNil(RunModelMark.kind(for: .roster))
        XCTAssertEqual(RunModelMark.kind(for: .overrideTyped), .override)
        XCTAssertEqual(RunModelMark.kind(for: .overrideCo), .override)
        XCTAssertEqual(RunModelMark.kind(for: .overrideItem), .override)
        XCTAssertEqual(RunModelMark.kind(for: .overrideUnattributed), .override)
        XCTAssertEqual(RunModelMark.kind(for: .failover), .failover)
        XCTAssertNil(RunModelMark.kind(for: nil))
    }

    func testOverrideAndFailoverDrawDifferentGlyphs() {
        XCTAssertNotEqual(RunModelMarkGlyph.symbolName(for: .override),
                          RunModelMarkGlyph.symbolName(for: .failover))
        for kind in [RunModelMarkKind.override, .failover] {
            XCTAssertNotNil(NSImage(systemSymbolName: RunModelMarkGlyph.symbolName(for: kind),
                                    accessibilityDescription: nil),
                            "\(kind) names an SF Symbol this macOS does not have")
        }
    }

    func testHoverNamesTheModelAndSaysHowItWasChosen() throws {
        let typed = try XCTUnwrap(RunModelMark.sentence(
            agent: "coder", choice: RunModelChoice(model: "claude-opus-5-5", source: .overrideTyped)))
        XCTAssertTrue(typed.contains("claude-opus-5-5") && typed.contains("typed"))
        let co = try XCTUnwrap(RunModelMark.sentence(
            agent: "coder", choice: RunModelChoice(model: "claude-opus-5-5", source: .overrideCo)))
        XCTAssertTrue(co.contains("claude-opus-5-5") && co.contains("a co that passed --model"))
        let item = try XCTUnwrap(RunModelMark.sentence(
            agent: "coder", choice: RunModelChoice(model: "claude-opus-5-5", source: .overrideItem)))
        XCTAssertTrue(item.contains("claimed, not verified"))
        XCTAssertFalse(item.contains("verified by"))
        let unattributed = try XCTUnwrap(RunModelMark.sentence(
            agent: "coder", choice: RunModelChoice(model: "claude-opus-5-5", source: .overrideUnattributed)))
        XCTAssertTrue(unattributed.contains("not recorded"))
        XCTAssertFalse(unattributed.contains("operator") || unattributed.contains("typed"))
        let failover = try XCTUnwrap(RunModelMark.sentence(
            agent: "coder", choice: RunModelChoice(model: "claude-haiku-4-5", source: .failover)))
        XCTAssertTrue(failover.contains("claude-haiku-4-5") && failover.contains("Nobody chose"))
        XCTAssertNil(RunModelMark.sentence(agent: "coder", choice: RunModelChoice(model: "m", source: .roster)))
    }

    // MARK: - Join

    private func run(_ id: String?, agent: String = "coder") -> SessionState.AgentRun {
        SessionState.AgentRun(runId: id, agent: agent)
    }

    func testRosterDrawsNoMarkAndAnOverrideDoes() {
        let register = ["r1": RunModelChoice(model: "m", source: .roster),
                        "r2": RunModelChoice(model: "m", source: .overrideItem)]
        XCTAssertNil(RunModelMark.resolve(runs: [run("r1")], register: register))
        XCTAssertEqual(RunModelMark.resolve(runs: [run("r2")], register: register)?.kind, .override)
    }

    func testARunAbsentFromTheRegisterOrWithoutAnIdDrawsNoMarkAndDropsNothing() {
        let register = ["r2": RunModelChoice(model: "m", source: .failover)]
        XCTAssertNil(RunModelMark.resolve(runs: [run("gone"), run(nil)], register: register))
        let mark = RunModelMark.resolve(runs: [run("gone"), run(nil), run("r2")], register: register)
        XCTAssertEqual(mark?.kind, .failover, "the run that IS in the register still marks the row")
    }

    func testFailoverWinsOverAnOverrideOnTheSameRowAndBothAreInTheHover() throws {
        let register = ["a": RunModelChoice(model: "m1", source: .overrideTyped),
                        "b": RunModelChoice(model: "m2", source: .failover)]
        let mark = try XCTUnwrap(RunModelMark.resolve(
            runs: [run("a", agent: "one"), run("b", agent: "two")], register: register))
        XCTAssertEqual(mark.kind, .failover)
        XCTAssertTrue(mark.help.contains("m1") && mark.help.contains("m2"))
    }

    /// The mark's text reaches the ROW's tooltip, under the context line,
    /// because a `.help` on the glyph itself never showed on hover (the operator,
    /// 2026-09-24: the hover said only "49% of context").
    func testTheRowTooltipCarriesTheMarkUnderTheContextLine() throws {
        let register = ["a": RunModelChoice(model: "claude-haiku-4-5", source: .overrideTyped)]
        let mark = try XCTUnwrap(RunModelMark.resolve(runs: [run("a", agent: "deck-reviewer")], register: register))
        XCTAssertEqual(
            RailRow.rowHelp(isCollapsed: false, name: "deck", meterHelp: "49% of context", markHelp: mark.help),
            "49% of context\n" + mark.help)
        XCTAssertEqual(RailRow.rowHelp(isCollapsed: false, name: "deck", meterHelp: nil, markHelp: mark.help), mark.help)
        XCTAssertEqual(RailRow.rowHelp(isCollapsed: false, name: "deck", meterHelp: "49% of context", markHelp: nil),
                       "49% of context", "no mark leaves the tooltip exactly as before")
        XCTAssertEqual(RailRow.rowHelp(isCollapsed: true, name: "deck", meterHelp: "49% of context", markHelp: mark.help),
                       "deck", "the collapsed dot rail keeps its name-only tooltip")
    }

    /// The operator, 2026-09-24: the Dispatched line reads "haiku 4.5 (set on the
    /// item)" or "haiku 4.5 (failover)" (relabeled off the old unqualified
    /// "operator override", issue_01M3NTZP9W8WEYWVERW2F9NARP). The word
    /// joins by `run_id` from the register, a roster run reads exactly as
    /// before, and the tooltip says how the model was chosen.
    func testTheDispatchedLineNamesAnOverrideOrAFailover() {
        let register = ["o": RunModelChoice(model: "claude-haiku-4-5", source: .overrideItem),
                        "f": RunModelChoice(model: "m", source: .failover),
                        "r": RunModelChoice(model: "m", source: .roster)]
        func runWith(_ id: String?) -> SessionState.AgentRun {
            SessionState.AgentRun(runId: id, agent: "deck-reviewer", model: "claude-haiku-4-5")
        }
        let joined = RunModelMark.withModelSources([runWith("o"), runWith("f"), runWith("r"), runWith("absent"), runWith(nil)],
                                                   register: register)
        XCTAssertEqual(joined.map(\.modelSource), [.overrideItem, .failover, .roster, nil, nil])

        let now = Date()
        let lines = joined.map { CockpitView.agentRunTrailingMetadata($0, now: now) ?? "" }
        XCTAssertTrue(lines[0].hasPrefix(CockpitView.modelGloss("claude-haiku-4-5") + " (set on the item)"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix(CockpitView.modelGloss("claude-haiku-4-5") + " (failover)"), lines[1])
        XCTAssertEqual(lines[2], CockpitView.agentRunTrailingMetadata(runWith("r"), now: now),
                       "a roster run's line is unchanged")
        XCTAssertEqual(lines[3], CockpitView.agentRunTrailingMetadata(runWith("absent"), now: now))

        XCTAssertTrue(CockpitView.agentRunHelpText(joined[0])?.contains("claimed, not verified") == true)
        XCTAssertTrue(CockpitView.agentRunHelpText(joined[1])?.contains("nobody chose this model") == true)
        XCTAssertFalse(CockpitView.agentRunHelpText(joined[2])?.contains("Model chosen") == true)
    }

    /// The two new sources (issue_01M3NTZP9W8WEYWVERW2F9NARP) get their own
    /// truthful labels: a co's own `--model` never reads as "operator", and
    /// a pre-provenance run never claims a source it doesn't have.
    func testTheDispatchedLineNamesACoOverrideAndAnUnattributedOverride() {
        let register = ["c": RunModelChoice(model: "claude-haiku-4-5", source: .overrideCo),
                        "u": RunModelChoice(model: "claude-haiku-4-5", source: .overrideUnattributed)]
        func runWith(_ id: String?) -> SessionState.AgentRun {
            SessionState.AgentRun(runId: id, agent: "deck-reviewer", model: "claude-haiku-4-5")
        }
        let joined = RunModelMark.withModelSources([runWith("c"), runWith("u")], register: register)
        let now = Date()
        let lines = joined.map { CockpitView.agentRunTrailingMetadata($0, now: now) ?? "" }
        XCTAssertTrue(lines[0].hasPrefix(CockpitView.modelGloss("claude-haiku-4-5") + " (co override)"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix(CockpitView.modelGloss("claude-haiku-4-5") + " (override (source unknown))"), lines[1])
        XCTAssertFalse(lines[0].contains("operator"))
        XCTAssertFalse(lines[1].contains("operator") || lines[1].contains("typed"))
    }

    /// the operator's "haiku 4.5 (failover from Deepseek)": `model_resolved`, when the
    /// register serves it, names what the run fell back from. Absent, the line
    /// says plain "failover".
    func testAFailoverNamesTheModelItFellBackFromWhenServed() throws {
        let table = try XCTUnwrap(decode("""
        {"runs":[{"run_id":"f","model":"claude-haiku-4-5","model_source":"failover","model_resolved":"claude-opus-5-5"},
                 {"run_id":"g","model":"claude-haiku-4-5","model_source":"failover"}]}
        """))
        XCTAssertEqual(table["f"]?.modelResolved, "claude-opus-5-5")
        XCTAssertNil(table["g"]?.modelResolved)
        let runs = RunModelMark.withModelSources(
            [SessionState.AgentRun(runId: "f", agent: "a", model: "claude-haiku-4-5"),
             SessionState.AgentRun(runId: "g", agent: "a", model: "claude-haiku-4-5")], register: table)
        let now = Date()
        let from = CockpitView.agentRunTrailingMetadata(runs[0], now: now) ?? ""
        XCTAssertTrue(from.hasPrefix(CockpitView.modelGloss("claude-haiku-4-5")
                                     + " (failover from " + CockpitView.modelGloss("claude-opus-5-5") + ")"), from)
        let plain = CockpitView.agentRunTrailingMetadata(runs[1], now: now) ?? ""
        XCTAssertTrue(plain.hasPrefix(CockpitView.modelGloss("claude-haiku-4-5") + " (failover)"), plain)
    }

    func testAnUnknownSourceDrawsNoMark() throws {
        let table = try XCTUnwrap(decode(#"{"runs":[{"run_id":"a","model":"m","model_source":"future"}]}"#))
        XCTAssertNil(RunModelMark.resolve(runs: [run("a")], register: table))
    }

    // MARK: - The model: a failed /runs read leaves rows unmarked

    private func state(fleetWide: Bool = false) -> SessionState {
        var s = SessionState(session: "ask", phase: .working, gate: nil, alive: true,
                             reason: nil, lastEvent: nil)
        s.agentRuns = [SessionState.AgentRun(runId: "r1", agent: "coder")]
        s.agentsAreFleetWide = fleetWide
        return s
    }

    private func model(fleetWide: Bool = false,
                       register: @escaping @Sendable (SSHTarget) throws -> [String: RunModelChoice])
        -> (RailStateModel, SessionRef) {
        let model = RailStateModel()
        let ref = SessionRef(host: "h", name: "ask")
        model.sessions = [ref]
        model.resolveHost = { _ in TestHost.target }
        model.fetchStates = { [state = state(fleetWide: fleetWide)] _, _ in ["ask": state] }
        model.fetchDiscovered = { _ in [] }
        model.fetchServedCrews = { _ in [] }
        model.fetchProbe = { _ in throw SessionAgent.AgentError.failed("no probe") }
        model.fetchDesktopSession = { _ in .unknown }
        model.fetchRunRegister = register
        return (model, ref)
    }

    func testAMarkAppearsFromTheRegisterAndVanishesWhenTheReadFails() async {
        let healthy = LockedFlag(true)
        let (model, ref) = model { _ in
            if healthy.value { return ["r1": RunModelChoice(model: "m", source: .failover)] }
            throw SessionAgent.AgentError.failed("socket gone")
        }
        await model.refresh()
        XCTAssertEqual(model.runModelMark(for: ref)?.kind, .failover)

        healthy.value = false
        await model.refresh()
        XCTAssertNotNil(model.states[ref], "the row itself survives the failed /runs read")
        XCTAssertNil(model.runModelMark(for: ref))
    }

    func testARosterRunOnAHealthyRegisterDrawsNoMark() async {
        let (model, ref) = model { _ in ["r1": RunModelChoice(model: "m", source: .roster)] }
        await model.refresh()
        XCTAssertNil(model.runModelMark(for: ref))
    }

    /// The steward's row (a `substrate` session) carries every crew's live
    /// runs, flagged fleet-wide. A fail-over in that list belongs to some
    /// other crew, so the row draws no mark; the same list scoped to the
    /// session's own product does draw it.
    func testAFleetWideRunListDrawsNoMarkWhereTheScopedOneDoes() async {
        let register: @Sendable (SSHTarget) throws -> [String: RunModelChoice] = { _ in
            ["r1": RunModelChoice(model: "m", source: .failover)]
        }
        let (fleet, fleetRef) = model(fleetWide: true, register: register)
        await fleet.refresh()
        XCTAssertNotNil(fleet.states[fleetRef], "the row itself still draws")
        XCTAssertNil(fleet.runModelMark(for: fleetRef))

        let (scoped, scopedRef) = model(fleetWide: false, register: register)
        await scoped.refresh()
        XCTAssertEqual(scoped.runModelMark(for: scopedRef)?.kind, .failover)
    }

    // MARK: - Render

    /// Renders the row through `NSHostingView` + `cacheDisplay` for each
    /// source at the two widths the rail is drawn at, and writes PNGs to a
    /// scratch directory for a person to look at. The assertion is that a
    /// marked row differs from the roster row in the mark's own column, and
    /// that the two marks differ from each other.
    func testRowRendersAtBothWidthsForEachSource() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-model-marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sources: [(String, RunModelSource)] = [
            ("roster", .roster), ("override-typed", .overrideTyped),
            ("override-co", .overrideCo), ("override-item", .overrideItem),
            ("override-unattributed", .overrideUnattributed), ("failover", .failover)]
        for appearance in [Appearance.light, .dark] {
            for width in [320.0, 280.0] {
                var pixels: [String: [UInt8]] = [:]
                for (name, source) in sources {
                    let mark = RunModelMark.resolve(
                        runs: [run("r")], register: ["r": RunModelChoice(model: "claude-opus-5-5", source: source)])
                    let bytes = try render(mark: mark, width: width, appearance: appearance,
                                           to: dir.appendingPathComponent("\(name)-\(Int(width))-\(appearance).png"))
                    pixels[name] = bytes
                }
                XCTAssertNotEqual(pixels["roster"], pixels["override-typed"])
                XCTAssertEqual(pixels["override-typed"], pixels["override-item"], "the two overrides share one mark")
                XCTAssertNotEqual(pixels["override-typed"], pixels["failover"])
            }
        }
        print("run-model mark renders: \(dir.path)")
    }

    private func render(mark: RunModelMark?, width: CGFloat, appearance: Appearance, to url: URL) throws -> [UInt8] {
        let crew = Crew(id: "shipwright", displayName: "shipwright")
        let row = RailRow(crew: crew, isSelected: false, accent: RGB(red: 0.8, green: 0.6, blue: 0.2),
                          appearance: appearance, mark: .ready, isStopped: false,
                          themeMenu: { AnyView(EmptyView()) }, runModelMark: mark)
            .frame(width: width)
            .background(appearance == .dark ? Color(white: 0.16) : Color(white: 0.92))
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: width, height: RailRow.rowHeight)
        host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        // Only the trailing 40pt, where the mark draws, so a change to the
        // name or dot column cannot make two sources look different.
        let scale = CGFloat(rep.pixelsWide) / width
        var out: [UInt8] = []
        for y in 0..<rep.pixelsHigh {
            for x in Int((width - 40) * scale)..<rep.pixelsWide {
                let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                out.append(UInt8((c?.redComponent ?? 0) * 255))
                out.append(UInt8((c?.greenComponent ?? 0) * 255))
                out.append(UInt8((c?.blueComponent ?? 0) * 255))
            }
        }
        return out
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ flag: Bool) { self.flag = flag }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); defer { lock.unlock() }; flag = newValue }
    }
}
