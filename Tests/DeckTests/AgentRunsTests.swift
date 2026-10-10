import XCTest
@testable import Deck

/// The crew-stats panel's decode and its pure derivations —
/// `issue_01M0NWW3R742YGQZF9KBYHW8GQ`. `agentRuns` is the richer record the
/// panel draws with (model, task, runtime); everything here is testable
/// without a view, the same discipline `CockpitView.childProgress` and
/// `RailRow.summonsInk` already follow.
final class AgentRunsTests: XCTestCase {

    private func decode(_ json: String) -> SessionState {
        SessionState.decode(Data(json.utf8), fallbackSession: "deck")
    }

    // MARK: - The three-way decode: absent, empty, populated

    /// A mini that predates `agent_runs` entirely. `nil`, never `[]` —
    /// collapsing the two would draw an old mini's silence as an honest
    /// empty crew.
    func testAbsentAgentRunsDecodesToNilNotEmpty() {
        let state = decode(#"{"state":"idle"}"#)
        XCTAssertNil(state.agentRuns)
    }

    /// Nothing dispatched right now is a real, positive answer — distinct
    /// from a mini that has never heard of the field at all.
    func testEmptyAgentRunsDecodesToEmptyArray() {
        let state = decode(#"{"state":"idle","agent_runs":[]}"#)
        XCTAssertEqual(state.agentRuns, [])
    }

    /// The ordinary case: every field present. `started_at` is an ISO-8601
    /// string — copied verbatim from `agent-platform#464`'s own fixtures,
    /// which is what `active.json`'s registry actually writes — never a
    /// number; the decoder must parse the wire's shape, not the shape a
    /// stale test happens to assume.
    func testPopulatedAgentRunsDecodesEveryField() throws {
        let state = decode("""
            {"state":"working","agent_runs":[
              {"run_id":"run_1","agent":"deck-reviewer","task":"Review PR #150",
               "started_at":"2026-08-28T10:00:00Z","repo":"convivy-deck","model":"claude-sonnet-5"}
            ]}
            """)
        let run = try XCTUnwrap(state.agentRuns?.first)
        XCTAssertEqual(run.runId, "run_1")
        XCTAssertEqual(run.agent, "deck-reviewer")
        XCTAssertEqual(run.task, "Review PR #150")
        XCTAssertEqual(run.startedAt, 1_787_911_200)
        XCTAssertEqual(run.repo, "convivy-deck")
        XCTAssertEqual(run.model, "claude-sonnet-5")
    }

    /// A record missing a field demotes that field, never the row — a run
    /// still draws with no `task`, the shape a withheld private-crew
    /// dispatch takes (ADR-0043), or one the registry never carried.
    func testARunMissingOneFieldStillDecodesTheRow() throws {
        let state = decode("""
            {"state":"working","agent_runs":[
              {"agent":"deck-coder","started_at":"2026-08-28T19:36:03Z","model":"claude-sonnet-5"}
            ]}
            """)
        let run = try XCTUnwrap(state.agentRuns?.first)
        XCTAssertNil(run.runId)
        XCTAssertNil(run.task)
        XCTAssertNil(run.repo)
        XCTAssertEqual(run.agent, "deck-coder")
        XCTAssertEqual(run.startedAt, 1_787_945_763)
    }

    /// The wire's shape is a STRING, never a number — the producer's own
    /// shape, per `active-json`. A numeric `started_at` (what an earlier
    /// version of this decoder, and its fixtures, wrongly assumed) must not
    /// be coerced; it decodes to `nil` like any other field the wire sent in
    /// a shape this build cannot read, rather than the two shapes silently
    /// collapsing into one.
    func testNumericStartedAtDoesNotCoerceAndDecodesToNil() throws {
        let state = decode("""
            {"state":"working","agent_runs":[
              {"agent":"deck-coder","started_at":1000.5}
            ]}
            """)
        let run = try XCTUnwrap(state.agentRuns?.first)
        XCTAssertNil(run.startedAt)
    }

    /// An entry that is not even a JSON object cannot be drawn as a row at
    /// all, so it is dropped rather than kept as a blank one — the other
    /// entries in the same array are unaffected.
    func testANonObjectEntryIsDroppedButSiblingsSurvive() {
        let state = decode("""
            {"state":"working","agent_runs":[
              "not an object", {"agent":"deck-coder"}, null, 42
            ]}
            """)
        XCTAssertEqual(state.agentRuns?.count, 1)
        XCTAssertEqual(state.agentRuns?.first?.agent, "deck-coder")
    }

    /// A top-level shape this build does not recognise — the field present
    /// but not an array — degrades to nil, the same "could not read it"
    /// answer as a mini that never sent the key.
    func testAMalformedTopLevelShapeDecodesToNil() {
        for hostile in [#"{"state":"idle","agent_runs":"not an array"}"#,
                        #"{"state":"idle","agent_runs":{"nested":true}}"#] {
            XCTAssertNil(decode(hostile).agentRuns, hostile)
        }
    }

    // MARK: - hasDispatchedAgents / mark, falling back through agentRuns then liveAgents

    /// The richer shape wins when present, including when it disagrees with
    /// `liveAgents` — it is the fresher, more specific read.
    func testHasDispatchedAgentsPrefersAgentRunsOverLiveAgents() {
        let state = decode("""
            {"state":"idle","agents":[],
             "agent_runs":[{"agent":"deck-coder"}]}
            """)
        XCTAssertTrue(state.hasDispatchedAgents)
        XCTAssertEqual(state.mark, .listening)
    }

    /// An empty `agent_runs` is a positive "nothing running" — it does not
    /// fall back to `liveAgents` just because it is empty.
    func testEmptyAgentRunsDoesNotFallBackToLiveAgents() {
        let state = decode("""
            {"state":"idle","agents":["stale-from-vitals"],"agent_runs":[]}
            """)
        XCTAssertFalse(state.hasDispatchedAgents)
        XCTAssertEqual(state.mark, .ready)
    }

    /// A mini that predates `agent_runs` falls back to `liveAgents` exactly
    /// as it did before this field existed.
    func testAbsentAgentRunsFallsBackToLiveAgents() {
        let state = decode(#"{"state":"idle","agents":["deck-reviewer"]}"#)
        XCTAssertTrue(state.hasDispatchedAgents)
        XCTAssertEqual(state.mark, .listening)
    }

    // MARK: - sortedAgentRuns

    private func run(_ id: String?, startedAt: Double?) -> SessionState.AgentRun {
        SessionState.AgentRun(runId: id, agent: "a-\(id ?? "?")", task: nil,
                              startedAt: startedAt, repo: nil, model: nil)
    }

    /// Ascending by `startedAt`, so the longest-running row — the earliest
    /// start — sits at the top.
    func testSortedAgentRunsOrdersAscendingByStartedAt() {
        let runs = [run("c", startedAt: 300), run("a", startedAt: 100), run("b", startedAt: 200)]
        XCTAssertEqual(CockpitView.sortedAgentRuns(runs).map(\.runId), ["a", "b", "c"])
    }

    /// Equal start times break the tie on `runId`, so a poll that changes
    /// nothing reorders nothing.
    func testSortedAgentRunsBreaksTiesOnRunId() {
        let runs = [run("z", startedAt: 100), run("a", startedAt: 100)]
        XCTAssertEqual(CockpitView.sortedAgentRuns(runs).map(\.runId), ["a", "z"])
    }

    /// A run with no `startedAt` sorts after every run that has one, rather
    /// than being mistaken for the oldest (and so pinned to the top).
    func testSortedAgentRunsPushesAnUnknownStartToTheEnd() {
        let runs = [run("unknown", startedAt: nil), run("known", startedAt: 500)]
        XCTAssertEqual(CockpitView.sortedAgentRuns(runs).map(\.runId), ["known", "unknown"])
    }

    // MARK: - id collision (private-crew redaction)

    /// A private crew redacts `run_id`, `started_at`, `repo` AND `model`
    /// together (`agent-platform#464`), as one deliberate redaction on
    /// every read — so two concurrent runs of the same agent under that
    /// crew decode to byte-identical `AgentRun`s. Without a positional
    /// tiebreak the fallback composite id collides too, and a `ForEach`
    /// keyed on a colliding id silently drops one of the two rows while
    /// the panel's own count badge still says two (PR #148, round 2).
    func testTwoPrivateCrewRunsOfTheSameAgentGetDistinctIds() {
        let redacted = SessionState.AgentRun(runId: nil, agent: "deck-coder", task: nil,
                                             startedAt: nil, repo: nil, model: nil)
        let sorted = CockpitView.sortedAgentRuns([redacted, redacted])
        XCTAssertEqual(sorted.count, 2)
        XCTAssertNotEqual(sorted[0].id, sorted[1].id)
        XCTAssertEqual(Set(sorted.map(\.id)).count, 2)
    }

    // MARK: - modelGloss

    /// The spec's own example: a leading `claude-` and a trailing version
    /// segment both strip.
    func testModelGlossStripsClaudePrefixAndTrailingVersion() {
        XCTAssertEqual(CockpitView.modelGloss("claude-sonnet-5"), "sonnet")
    }

    /// Nothing in the `claude-` shape draws as received — this never
    /// invents a gloss for a model id it does not recognise.
    func testModelGlossPassesThroughAnUnrecognisedFormUnchanged() {
        XCTAssertEqual(CockpitView.modelGloss("gpt-4"), "gpt-4")
    }

    /// No trailing version segment to strip — the prefix strip alone still
    /// applies.
    func testModelGlossWithNoTrailingVersionStripsOnlyThePrefix() {
        XCTAssertEqual(CockpitView.modelGloss("claude-haiku"), "haiku")
    }

    // MARK: - taskGloss

    /// A prompt opening with a markdown heading still glosses to something
    /// useful — never just "Task…" alone, because flattening keeps the
    /// words a "first meaningful line" heuristic would have thrown away
    /// along with the heading.
    func testTaskGlossOnAHeadingOpenerKeepsWhatFollows() {
        let task = "## Task\n\nBuild the cockpit's crew-stats panel, one line per agent in flight."
        let gloss = CockpitView.taskGloss(task)
        XCTAssertTrue(gloss.hasPrefix("Task Build the cockpit's crew-stats panel"), gloss)
        XCTAssertNotEqual(gloss, "Task…")
    }

    /// Leading markdown markers strip from a bulleted or blockquoted line
    /// the same way they do from a heading.
    func testTaskGlossStripsBulletAndOrderedMarkers() {
        XCTAssertTrue(CockpitView.taskGloss("- do the thing").hasPrefix("do the thing"))
        XCTAssertTrue(CockpitView.taskGloss("1. do the thing").hasPrefix("do the thing"))
        XCTAssertTrue(CockpitView.taskGloss("> quoted thing").hasPrefix("quoted thing"))
    }

    /// Whitespace runs — including the newlines markdown structure leaves
    /// behind once every line is joined — collapse to single spaces.
    func testTaskGlossCollapsesWhitespaceRuns() {
        let gloss = CockpitView.taskGloss("first line\n\n\nsecond line\t\tthird")
        XCTAssertEqual(gloss, "first line second line third")
    }

    /// Only the first ~500 characters are ever considered — a marker placed
    /// past that point never surfaces, however short the final gloss is.
    func testTaskGlossOnlyReadsTheFirst500Characters() {
        let task = String(repeating: "a", count: 500) + " MARKER-BEYOND-500"
        XCTAssertFalse(CockpitView.taskGloss(task).contains("MARKER-BEYOND-500"))
    }

    /// A task built entirely of markdown markers strips every line to
    /// nothing, so the flattened join is empty though the task itself was
    /// not — the gloss must fall back to the raw head rather than
    /// contradicting its own documented "never empty" invariant.
    func testTaskGlossFallsBackWhenEveryLineStripsToNothing() {
        let gloss = CockpitView.taskGloss("##\n##\n##")
        XCTAssertFalse(gloss.isEmpty)
    }

    /// A hostile task carrying a single oversized grapheme cluster (the
    /// same shape `SessionPaneView.displayable` exists to defuse) must not
    /// reach `WaypointRibbon.condense`'s Character-counted cut unsanitised
    /// — `taskGloss` routes through `displayable()` first, so the gloss
    /// comes out short rather than carrying thousands of scalars in one
    /// cluster.
    func testTaskGlossSanitisesAnOversizedClusterBeforeCondensing() {
        let bomb = "e" + String(repeating: "\u{0301}", count: 4000)
        let gloss = CockpitView.taskGloss(bomb)
        XCTAssertLessThanOrEqual(gloss.unicodeScalars.count, 100)
    }

    /// Bounded to 90 characters via `WaypointRibbon.condense` — a long,
    /// marker-free prompt still comes out glanceable.
    func testTaskGlossIsBoundedToNinety() {
        let task = Array(repeating: "word", count: 60).joined(separator: " ")
        XCTAssertLessThanOrEqual(CockpitView.taskGloss(task).count, 91)
    }

    // MARK: - agentRunTrailingMetadata

    private let now = Date(timeIntervalSince1970: 10_000)
    /// A fixed zone and locale so the clock text in these tests reads the
    /// same on every machine, following `LibraryClientTests.arizona`/`posix`.
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")

    /// `now` (10,000s past the epoch, 1970-01-01T02:46:40Z) minus three
    /// hours is still 1969-12-31 in UTC — an earlier day — so this run's
    /// clock reading carries a date. All three fields present join as
    /// `"<model> · <clock> · <runtime>"`. `DateFormatter`'s locale-driven
    /// day-period separator is U+202F, a NARROW NO-BREAK SPACE, not a plain
    /// space — spelled out here rather than typed invisibly.
    func testTrailingMetadataJoinsModelClockAndRuntime() {
        let run = SessionState.AgentRun(runId: nil, agent: nil, task: nil,
                                        startedAt: 10_000 - 10_800, repo: nil,
                                        model: "claude-sonnet-5")
        let text = CockpitView.agentRunTrailingMetadata(run, now: now, timeZone: utc, locale: posix)
        XCTAssertEqual(text, "sonnet · Dec 31 at 11:46\u{202F}PM · 3h")
    }

    /// A run that started earlier the same UTC day carries no date in its
    /// clock reading; no `model` demotes that field alone, so only the clock
    /// and runtime draw.
    func testTrailingMetadataSameDayWithNoModelIsClockAndRuntimeAlone() {
        let run = SessionState.AgentRun(runId: nil, agent: nil, task: nil,
                                        startedAt: 10_000 - 45, repo: nil, model: nil)
        XCTAssertEqual(CockpitView.agentRunTrailingMetadata(run, now: now, timeZone: utc, locale: posix),
                       "2:45\u{202F}AM · 45s")
    }

    /// No `startedAt` demotes the clock and the runtime together — the model
    /// still draws, as today.
    func testTrailingMetadataWithNoStartedAtIsModelAlone() {
        let run = SessionState.AgentRun(runId: nil, agent: nil, task: nil,
                                        startedAt: nil, repo: nil, model: "claude-sonnet-5")
        XCTAssertEqual(CockpitView.agentRunTrailingMetadata(run, now: now, timeZone: utc, locale: posix), "sonnet")
    }

    /// Neither field draws nothing at all, rather than an empty string the
    /// row would still lay out space for.
    func testTrailingMetadataWithNeitherFieldIsNil() {
        let run = SessionState.AgentRun(runId: nil, agent: nil, task: nil,
                                        startedAt: nil, repo: nil, model: nil)
        XCTAssertNil(CockpitView.agentRunTrailingMetadata(run, now: now))
    }

    /// A clock-skewed mini can put `started_at` in the future; the runtime
    /// clamps to zero rather than going negative. The clock reading still
    /// draws the (future) start instant as given.
    func testTrailingMetadataClampsAFutureStartedAtToZero() {
        let run = SessionState.AgentRun(runId: nil, agent: nil, task: nil,
                                        startedAt: 10_000 + 500, repo: nil, model: nil)
        XCTAssertTrue(CockpitView.agentRunTrailingMetadata(run, now: now, timeZone: utc, locale: posix)!
            .hasSuffix("· 0s"))
    }

    // MARK: - agentRunHelpText

    /// Every present field appears; the task is bounded to 500 characters.
    /// `Started:` reads in the given zone and locale, not UTC ISO 8601.
    func testHelpTextCarriesEveryPresentField() throws {
        let run = SessionState.AgentRun(
            runId: "run_1", agent: "deck-coder", task: String(repeating: "x", count: 600),
            startedAt: 0, repo: "convivy-deck", model: "claude-sonnet-5")
        let help = try XCTUnwrap(CockpitView.agentRunHelpText(run, timeZone: utc, locale: posix))
        XCTAssertTrue(help.contains("claude-sonnet-5"))
        XCTAssertTrue(help.contains("run_1"))
        XCTAssertTrue(help.contains("convivy-deck"))
        XCTAssertTrue(help.contains("Started: Jan 1 at 12:00\u{202F}AM"), help)
        XCTAssertFalse(help.contains("1970-01-01T00:00:00Z"), "no longer the raw UTC ISO 8601 instant")
        XCTAssertEqual(help.components(separatedBy: "\n").last?.count, 500)
    }

    /// Nothing to show at all is `nil`, not an empty string.
    func testHelpTextIsNilWhenEveryFieldIsMissing() {
        let run = SessionState.AgentRun(runId: nil, agent: nil, task: nil,
                                        startedAt: nil, repo: nil, model: nil)
        XCTAssertNil(CockpitView.agentRunHelpText(run))
    }

    /// `model`, `run_id` and `repo` are attacker-influenced the same way
    /// `task` is, and the tooltip used to carry them with no cap at all — a
    /// bidi override in any of the three reaches the pane's `Text` unless
    /// this help text sanitises it too, not only the task line.
    func testHelpTextSanitisesAndBoundsModelRunIdAndRepo() throws {
        let bidi = "\u{202E}reversed"
        let run = SessionState.AgentRun(
            runId: bidi, agent: nil, task: nil, startedAt: nil,
            repo: String(repeating: "r", count: 900), model: bidi)
        let help = try XCTUnwrap(CockpitView.agentRunHelpText(run))
        XCTAssertFalse(help.unicodeScalars.contains(Unicode.Scalar(0x202E)!))
        XCTAssertTrue(help.contains(String(repeating: "r", count: 500)))
        XCTAssertFalse(help.contains(String(repeating: "r", count: 501)))
    }

    /// Pins the exact set of lines the operator's hover check looks for
    /// (`issue_01M3TSDXT6EZZF9X351VRE003H`): Model, Run, Repo, Started, Cost
    /// and Cost read. `CockpitView.agentRunRow` and `ServiceCrewPanel.runRow`
    /// moved `.help` from the row container onto the leaf `Text` views a
    /// person actually hovers, but both still build this same string from
    /// this same function — this test proves the string itself is
    /// unaffected by that move. It cannot prove the tooltip now shows on
    /// hover; that step is only verifiable by hand (see the PR body).
    func testHelpTextLinesMatchTheOperatorsHoverCheck() throws {
        let run = SessionState.AgentRun(
            runId: "run_1", agent: "deck-coder", task: "Fix the tooltip",
            startedAt: 0, repo: "convivy-deck", model: "claude-sonnet-5",
            cost: .init(usd: 1.23, source: .metered, writtenAt: "1970-01-01T00:00:10Z"))
        let help = try XCTUnwrap(CockpitView.agentRunHelpText(run, now: now, timeZone: utc, locale: posix))
        let lines = help.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Model: claude-sonnet-5")
        XCTAssertEqual(lines[1], "Run: run_1")
        XCTAssertEqual(lines[2], "Repo: convivy-deck")
        XCTAssertEqual(lines[3], "Started: Jan 1 at 12:00\u{202F}AM")
        XCTAssertEqual(lines[4], "Cost: $1.23 — metered spend")
        XCTAssertEqual(lines[5], "Cost read: 12:00\u{202F}AM")
        XCTAssertEqual(lines[6], "Fix the tooltip")
    }

    // MARK: - modelGloss sanitisation

    /// A bidi override in `model` must not survive into the glossed label —
    /// `modelGloss` routes through `SessionPaneView.displayable` before
    /// `condense`, the same guard the conversation pane applies to
    /// transcript text.
    func testModelGlossStripsBidiOverride() {
        let gloss = CockpitView.modelGloss("claude-\u{202E}sonnet-5")
        XCTAssertFalse(gloss.unicodeScalars.contains(Unicode.Scalar(0x202E)!))
    }
}
