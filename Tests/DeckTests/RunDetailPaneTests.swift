import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// The Dispatched run pane: the full instruction from `/runs`, its join onto
/// the run list, the withheld case, and which column occupant a click yields.
@MainActor
final class RunDetailPaneTests: XCTestCase {
    private func run(_ id: String?, task: String? = nil, agent: String = "deck-coder",
                     startedAt: Double? = nil) -> SessionState.AgentRun {
        SessionState.AgentRun(runId: id, agent: agent, task: task, startedAt: startedAt, repo: nil,
                              model: "claude-haiku-4-5")
    }

    // MARK: - Decode

    func testTheRegisterDecodesTheFullTaskAndAMissingOneIsNil() throws {
        let long = String(repeating: "x", count: 2521)
        let table = try XCTUnwrap(RunRegister.decode(Data("""
        {"runs":[{"run_id":"a","task":"\(long)"},{"run_id":"b"},{"run_id":"c","task":7}]}
        """.utf8)))
        XCTAssertEqual(table["a"]?.task?.count, 2521)
        XCTAssertNil(table["b"]?.task)
        XCTAssertNil(table["c"]?.task, "a task of the wrong type costs only the task")
    }

    // MARK: - Join

    func testTheFullTaskJoinsByRunIdAndSessionAgentsTruncatedCopyIsLeftAlone() {
        let truncated = String(repeating: "t", count: 500)
        let full = String(repeating: "t", count: 2500)
        let joined = RunModelMark.withModelSources(
            [run("a", task: truncated), run("b", task: truncated), run(nil, task: truncated)],
            register: ["a": RunModelChoice(model: "m", source: .roster, task: full)])
        XCTAssertEqual(joined[0].fullTask, full)
        XCTAssertEqual(joined[0].task, truncated, "session-agent's copy is kept as it was")
        XCTAssertNil(joined[1].fullTask, "a run absent from the register has no full text")
        XCTAssertNil(joined[2].fullTask)
    }

    // MARK: - Detail

    func testTheDetailShowsAllOfTheInstructionAndTheModelLineWithItsQualifier() {
        let full = String(repeating: "line of instruction\n", count: 125)  // 2,500 characters
        var joined = run("run-1", task: "cut")
        joined.fullTask = full
        joined.modelSource = .overrideTyped
        let detail = RunDetail.make(runId: "run-1", runs: [joined])
        XCTAssertEqual(detail.instruction, .text(full))
        XCTAssertEqual(detail.modelLine, "haiku-4 (typed override)")
        XCTAssertEqual(detail.modelLine, CockpitView.agentRunModelLine(joined))
        XCTAssertEqual(detail.agent, "deck-coder")
        XCTAssertFalse(detail.hasEnded)
        XCTAssertNil(detail.startedAt, "the fixture run carries no startedAt")
    }

    func testTheDetailCarriesStartedAt() {
        let detail = RunDetail.make(runId: "run-1", runs: [run("run-1", startedAt: 12_345)])
        XCTAssertEqual(detail.startedAt, 12_345)
    }

    func testARunAbsentFromTheRegisterIsWithheldNeverTheTruncatedText() {
        // `task` is present but is session-agent's cut copy; `fullTask` is nil.
        let detail = RunDetail.make(runId: "run-1", runs: [run("run-1", task: String(repeating: "t", count: 500))])
        XCTAssertEqual(detail.instruction, .withheld)
        XCTAssertEqual(RunDetail.withheldNotice, "Instruction withheld or unavailable")
    }

    func testAnEmptyFullTaskIsWithheldToo() {
        var r = run("run-1")
        r.fullTask = ""
        XCTAssertEqual(RunDetail.make(runId: "run-1", runs: [r]).instruction, .withheld)
    }

    func testARunThatLeftTheListKeepsItsPaneAndSaysItEnded() {
        for runs in [[SessionState.AgentRun](), nil] {
            let detail = RunDetail.make(runId: "run-9", runs: runs)
            XCTAssertTrue(detail.hasEnded)
            XCTAssertEqual(detail.runId, "run-9")
        }
    }

    /// deck-reviewer, round 1 on #276: a run that left the list (it ended, or
    /// the rail moved to another crew) blanked the pane. With the detail the
    /// pane last saw, everything it showed stays, marked as no longer listed.
    func testARunThatLeftTheListKeepsWhatThePaneLastShowed() {
        var listed = run("run-1", task: "cut", startedAt: 500)
        listed.fullTask = String(repeating: "x", count: 2500)
        let seen = RunDetail.make(runId: "run-1", runs: [listed])
        let after = RunDetail.make(runId: "run-1", runs: [run("other")], last: seen)
        XCTAssertTrue(after.hasEnded)
        XCTAssertEqual(after.instruction, seen.instruction, "the instruction survives, not 'withheld'")
        XCTAssertEqual(after.agent, "deck-coder")
        XCTAssertEqual(after.modelLine, seen.modelLine)
        XCTAssertEqual(after.startedAt, 500, "the start time survives the same way the instruction does")
        XCTAssertFalse(RunDetail.endedNotice.contains("no longer in flight"),
                       "Deck can't know the run ended; the rail may just have moved")
    }

    /// The cache keeps each listed run's detail and the open pane's run, and
    /// drops everything else, so it doesn't grow for the app's lifetime.
    func testTheRememberedDetailsHoldOnlyListedRunsAndTheOpenOne() {
        var a = run("a", task: "cut"); a.fullTask = "A"
        var b = run("b", task: "cut"); b.fullTask = "B"
        let first = RunDetail.remembering([a, b], previous: [:], keeping: "a")
        XCTAssertEqual(Set(first.keys), ["a", "b"])
        var c = run("c", task: "cut"); c.fullTask = "C"
        let second = RunDetail.remembering([c], previous: first, keeping: "a")
        XCTAssertEqual(Set(second.keys), ["a", "c"], "b is dropped; a is kept because its pane is open")
        XCTAssertEqual(second["a"]?.instruction, .text("A"))
        XCTAssertEqual(RunDetail.remembering(nil, previous: second, keeping: "z").keys.count, 0)
    }

    func testTheInstructionIsSanitisedAndBoundedWithAVisibleCut() {
        var r = run("run-1")
        r.fullTask = "safe \u{202E}reversed" + String(repeating: "y", count: CockpitView.instructionCharacterLimit)
        guard case .text(let text) = RunDetail.make(runId: "run-1", runs: [r]).instruction else {
            return XCTFail("expected text")
        }
        XCTAssertFalse(text.unicodeScalars.contains("\u{202E}"), "bidi controls are stripped")
        XCTAssertTrue(text.hasSuffix("characters.]"), "a cut instruction says it was cut")
        XCTAssertLessThan(text.count, CockpitView.instructionCharacterLimit + 100)
    }

    func testAnInstructionUnderTheLimitIsNotCutAtFiveHundred() {
        let text = CockpitView.sanitizedInstruction(String(repeating: "z", count: 2500))
        XCTAssertEqual(text.count, 2500, "sanitizedAgentField's 500 cap must not apply here")
    }

    // MARK: - Started fact

    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")
    /// 2026-09-30T08:26:03Z.
    private let now = Date(timeIntervalSince1970: 1_790_756_763)

    /// A live run's `Started` fact reads the full local date and time, then
    /// the elapsed runtime.
    func testStartedFactValueOnALiveRunShowsTheDateTimeAndRuntime() {
        let detail = RunDetail.make(runId: "run-1", runs: [run("run-1", startedAt: 1_790_756_763 - 840)])
        XCTAssertEqual(detail.startedFactValue(now: now, timeZone: utc, locale: posix),
                       "Sep 30 at 8:12\u{202F}AM · 14m")
    }

    /// An ended run shows only the start time — Deck doesn't know when the
    /// run ended, so there is no runtime to append.
    func testStartedFactValueOnAnEndedRunShowsOnlyTheStartTime() {
        let seen = RunDetail.make(runId: "run-1", runs: [run("run-1", startedAt: 1_790_756_763 - 840)])
        let after = RunDetail.make(runId: "run-1", runs: [], last: seen)
        XCTAssertTrue(after.hasEnded)
        XCTAssertEqual(after.startedFactValue(now: now, timeZone: utc, locale: posix), "Sep 30 at 8:12\u{202F}AM")
    }

    /// A run with no `startedAt` at all shows no `Started` fact.
    func testStartedFactValueWithNoStartedAtIsNil() {
        let detail = RunDetail.make(runId: "run-1", runs: [run("run-1")])
        XCTAssertNil(detail.startedFactValue(now: now, timeZone: utc, locale: posix))
    }

    // MARK: - Selection

    func testClickingARowOpensItsPane() {
        XCTAssertEqual(ColumnOccupant.togglingRun("a", from: .cockpit), .run(runId: "a"))
    }

    func testClickingAnotherRowFollowsTheSelection() {
        XCTAssertEqual(ColumnOccupant.togglingRun("b", from: .run(runId: "a")), .run(runId: "b"))
    }

    func testClickingTheOpenRowClosesItAndOnlyThatRow() {
        XCTAssertEqual(ColumnOccupant.togglingRun("a", from: .run(runId: "a")), .cockpit)
        XCTAssertEqual(ColumnOccupant.togglingRun("a", from: .remoteShell), .run(runId: "a"),
                       "a run click over another occupant opens the pane rather than closing it")
    }

    // MARK: - Render

    /// The Dispatched panel beside the open pane, each at the default column
    /// width, with a 2,500-character instruction. Writes a PNG for a person
    /// to look at; asserts the pane draws differently for a long instruction
    /// than for the withheld notice.
    func testDispatchedPanelWithThePaneOpen() throws {
        let sentence = "Build the run pane so a click on a Dispatched row shows the whole instruction. "
        var instruction = ""
        while instruction.count < 2500 { instruction += sentence }
        instruction = String(instruction.prefix(2500))

        var open = run("run-6b775801", task: String(instruction.prefix(500)))
        open.fullTask = instruction
        open.modelSource = .overrideTyped
        let other = run("run-7c886912", task: "Another run", agent: "reviewer")
        let runs = [open, other]

        let width = CGFloat(ThemeConfiguration.defaultColumnWidth)
        let png = try render(runs: runs, openRunId: "run-6b775801", width: width, name: "with-instruction")
        let withheld = try render(runs: runs, openRunId: "run-7c886912", width: width, name: "withheld")
        XCTAssertNotEqual(png, withheld)
    }

    /// The Dispatched row at 320pt and 280pt, with a long agent name and a
    /// full trailing line (model, clock time, runtime, cost) competing for
    /// the same space. Writes a PNG at each width for a person to check that
    /// the name still truncates before the metadata does, the way it did
    /// before the clock time was added as a fourth field.
    func testDispatchedRowAtTwoColumnWidths() throws {
        let run = SessionState.AgentRun(
            runId: "run-width", agent: "a-very-long-crew-agent-name-for-this-row",
            task: nil, startedAt: 1_790_756_763 - 840, repo: nil, model: "claude-sonnet-5",
            cost: SessionState.AgentRun.RunCost(usd: 0.79, source: .metered))

        for width in [CGFloat(320), CGFloat(280)] {
            let png = try renderPanel(runs: [run], width: width, name: "\(Int(width))pt")
            XCTAssertFalse(png.isEmpty)
        }
    }

    /// deck-reviewer, round 1 on #293: the test above only asserted the PNG
    /// was non-empty, so nothing checked the row comment's claim that the
    /// name truncates before the metadata does. The metadata text is
    /// `.fixedSize()`, so its own pixels must come out identical whether the
    /// agent name is long or short; if a regression let it compete for space
    /// instead of the name, the long name would compress it and this would
    /// differ.
    func testTheAgentNameTruncatesBeforeTheMetadataDoes() throws {
        let width: CGFloat = 280
        func fixture(agent: String) -> SessionState.AgentRun {
            SessionState.AgentRun(runId: "run-width", agent: agent, task: nil,
                                  startedAt: 1_790_756_763 - 840, repo: nil, model: "claude-sonnet-5",
                                  cost: SessionState.AgentRun.RunCost(usd: 0.79, source: .metered))
        }
        let long = fixture(agent: "a-very-long-crew-agent-name-for-this-row")
        let short = fixture(agent: "a")
        XCTAssertEqual(CockpitView.agentRunTrailingMetadata(long, now: now),
                       CockpitView.agentRunTrailingMetadata(short, now: now),
                       "only the agent name differs between the two fixtures")

        let longRep = try renderPanelBitmap(runs: [long], width: width)
        let shortRep = try renderPanelBitmap(runs: [short], width: width)
        XCTAssertEqual(longRep.pixelsWide, shortRep.pixelsWide, "same frame width, so same backing pixel width")
        XCTAssertEqual(trailingStrip(longRep), trailingStrip(shortRep),
                       "the metadata's own pixels must match; a long agent name must not compress them")
    }

    /// The rightmost strip of the row, wide enough to hold the trailing
    /// metadata text in full at this font size. `.fixedSize()` pins that text
    /// to its own ideal width against the trailing edge, so this strip is
    /// unaffected by how much of the agent name got truncated to make room.
    private func trailingStrip(_ rep: NSBitmapImageRep) -> [UInt8] {
        guard let data = rep.bitmapData else { return [] }
        let stripWidth = min(rep.pixelsWide, 140)
        let x0 = rep.pixelsWide - stripWidth
        let bytesPerPixel = max(1, rep.bitsPerPixel / 8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rep.pixelsHigh * stripWidth * bytesPerPixel)
        for y in 0..<rep.pixelsHigh {
            let rowStart = y * rep.bytesPerRow + x0 * bytesPerPixel
            bytes.append(contentsOf: UnsafeBufferPointer(start: data + rowStart, count: stripWidth * bytesPerPixel))
        }
        return bytes
    }

    /// deck-reviewer, round 1 on #293: the facts block's label column was a
    /// fixed 44pt, and "Started" measures wider than that at the largest
    /// frame-size setting (baseSize 14, caption 13pt), so it wrapped to two
    /// lines. The label column now sizes to its widest label, so a row with
    /// the long "Started" label is the same height as one with only short
    /// labels — this must fail on 661b30f, where it is one line taller.
    /// Both fixtures carry exactly two facts — `Run` plus one more — so the
    /// only difference between them is the second label's length: "Started"
    /// against "Model". `RunDetail` is built directly rather than through
    /// `run()`/`RunDetail.make`, whose `agent` defaults to "deck-coder" and
    /// would add a third, unwanted row.
    private func twoFactDetails(secondLabelIsStarted: Bool) -> RunDetail {
        RunDetail(runId: "run-1", agent: nil,
                 modelLine: secondLabelIsStarted ? nil : "claude-sonnet-5",
                 instruction: .withheld, hasEnded: false,
                 startedAt: secondLabelIsStarted ? 1_790_756_763 - 840 : nil)
    }

    func testTheStartedLabelStaysOnOneLineAtTheLargestFrameSize() throws {
        let long = try factsHeight(twoFactDetails(secondLabelIsStarted: true), baseSize: 14, name: "started-14")
        let short = try factsHeight(twoFactDetails(secondLabelIsStarted: false), baseSize: 14, name: "model-14")
        XCTAssertEqual(long, short, accuracy: 1,
                       "'Run' + 'Started' (long label) must be the same height as 'Run' + 'Model' (short label)")
    }

    /// The same comparison at the default base size (11), where the fixed
    /// 44pt column happened to fit: guards against a fix that only sizes the
    /// column correctly at the largest setting.
    func testTheStartedLabelStaysOnOneLineAtTheDefaultFrameSize() throws {
        let long = try factsHeight(twoFactDetails(secondLabelIsStarted: true),
                                   baseSize: FrameTypography.default.baseSize, name: "started-default")
        let short = try factsHeight(twoFactDetails(secondLabelIsStarted: false),
                                    baseSize: FrameTypography.default.baseSize, name: "model-default")
        XCTAssertEqual(long, short, accuracy: 1)
    }

    /// Renders `RunDetailPane.facts` alone (no header, no scroll view) through
    /// `NSHostingView` + `cacheDisplay`, the file's usual snapshot idiom, and
    /// reads back the block's own intrinsic height via `fittingSize` — the
    /// quantity that grows when a label wraps, where a fixed-height frame
    /// would just clip the second line and hide it.
    private func factsHeight(_ detail: RunDetail, baseSize: CGFloat, name: String) throws -> CGFloat {
        let pane = RunDetailPane(detail: detail, given: .idle, fetched: .idle,
                                 onOpenDocument: { _ in }, onClose: {})
        let facts = pane.facts.environment(\.frameTypography, FrameTypography(baseSize: baseSize))
        let host = NSHostingView(rootView: facts)
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("run-pane-facts-\(name).png")
        try data.write(to: url)
        return height
    }

    private func renderPanel(runs: [SessionState.AgentRun], width: CGFloat, name: String) throws -> [UInt8] {
        let rep = try renderPanelBitmap(runs: runs, width: width)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dispatched-row-\(name).png")
        try data.write(to: url)
        return [UInt8](data)
    }

    private func renderPanelBitmap(runs: [SessionState.AgentRun], width: CGFloat) throws -> NSBitmapImageRep {
        let panel = CockpitView(
            model: CockpitModel(), unresolvedReason: nil, agentRuns: runs, appearance: .light,
            onSelectCorrection: { _ in }, onSelectRun: { _ in }, openRunId: nil,
            panelIDs: [CockpitView.dispatchedPanelID])
            .frame(width: width, height: 100)
            .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("theme-\(UUID().uuidString).json")))
        let host = NSHostingView(rootView: panel)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func render(runs: [SessionState.AgentRun], openRunId: String, width: CGFloat, name: String) throws -> [UInt8] {
        let panel = CockpitView(
            model: CockpitModel(), unresolvedReason: nil, agentRuns: runs, appearance: .light,
            onSelectCorrection: { _ in }, onSelectRun: { _ in }, openRunId: openRunId,
            panelIDs: [CockpitView.dispatchedPanelID])
            .frame(width: width)
        let pane = RunDetailPane(detail: RunDetail.make(runId: openRunId, runs: runs), given: .idle,
                                 fetched: .idle, onOpenDocument: { _ in }, onClose: {})
            .frame(width: width)
        let both = HStack(alignment: .top, spacing: 0) { panel; Divider(); pane }
            .frame(height: 620)
            .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("theme-\(UUID().uuidString).json")))
        let host = NSHostingView(rootView: both)
        host.frame = NSRect(x: 0, y: 0, width: width * 2 + 1, height: 620)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        // The per-user temporary directory, not /tmp: /tmp is shared and sticky, so
        // a snapshot one account wrote there cannot be overwritten by another, and
        // CI (deck-runner) and a local run (an operator account) share the Studio.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("run-pane-\(name).png")
        try data.write(to: url)
        return [UInt8](data)
    }
}
