import Foundation

/// What a co session is doing, as reported by `session-agent state`.
///
/// DECODED, NOT DERIVED. The state machine lives on the mini, in
/// `agent-platform/lib/agent-platform/session_state.py`, and Deck receives its
/// answer rather than the events behind it. A second implementation of those
/// transitions here would drift from the one that is tested, and it would have
/// to re-learn things that took live experiments to find — that a `Notification`
/// ends a working state, that a gate the transcript has outrun was already
/// answered.
struct SessionState: Equatable {
    /// The states the mini reports. `unknown` is not a failure mode to be hidden;
    /// it is the honest answer when the hook stream cannot be read, and the pane
    /// answers it by offering the terminal.
    enum Phase: String {
        case idle, working, waiting, blocked, ended, unknown
    }

    var session: String
    var phase: Phase
    /// Present only while `blocked`, and only when the payload carried something
    /// renderable. `blocked` with no gate means "stopped for you, and I cannot
    /// show you what it wants" — a real answer, and the pane's response to it is
    /// the raw terminal.
    var gate: Gate?
    var alive: Bool
    var reason: String?
    var lastEvent: String?

    /// The transcript's mtime, absolute, as the mini reports it.
    ///
    /// THE FIELD THE RE-RENDER GATE TURNS ON. `lastEvent` is an event type name
    /// rather than an id, so a whole turn of `PreToolUse` events compares equal
    /// and the pane concluded nothing had moved — it sat frozen for the length
    /// of a turn, and the reader went back to the raw terminal, which is the
    /// surface the pane exists to replace.
    ///
    /// Absolute rather than the `transcript_age` beside it on the wire: an age
    /// is relative to now, so it changes on every poll and would re-render
    /// constantly, throwing away the scroll position and expanded rows the gate
    /// protects. This is stable while the conversation is stable.
    ///
    /// `nil` when the mini could not stat the transcript, or when talking to a
    /// mini that predates the field. Both mean "fall back to the older
    /// signals", never "nothing changed" — see `session-agent-api`.
    var transcriptMTime: Double?

    /// The directory the session is working in, as the mini reports it. Used to
    /// open the scratch shell pane where the agent is, and nil when the session
    /// has not reported one.
    var cwd: String?

    /// Whether the transcript moved recently — the mini's fine-grained "still
    /// doing something" signal, independent of the hook stream, which goes quiet
    /// for long stretches during a single tool call.
    var progressing: Bool?

    /// Seconds since the newest hook event. What makes silence legible: a
    /// session working for ninety seconds with nothing new is the case where a
    /// static "Working" label is indistinguishable from a wedged one.
    ///
    /// ALSO THE AGE OF A STANDING GATE. A blocked session fires no further
    /// hooks — it is stopped, by definition — so while `phase == .blocked` the
    /// newest event IS the gate, and this is how long it has been waiting. That
    /// is what the mark's staleness ramp reads, and it costs no new field on a
    /// contract Deck does not control the deploy of.
    var lastEventAge: Double?

    /// Dispatched runs alive right now, from the mini's `active.json`, scoped to
    /// this session's crew.
    ///
    /// TOP-LEVEL RATHER THAN INSIDE `vitals`, and that is what makes the rail
    /// able to draw with it. The rail polls `session-agent states`, whose
    /// answers are `brief` and carry no vitals block at all, so anything the
    /// rail decorates a row with has to live out here. It is also the more
    /// honest home: `vitals` quotes the terminal's status line, and this comes
    /// from a different file entirely.
    ///
    /// Empty means "nothing dispatched", which is a real answer. A mini that
    /// predates the field also lands here, and that degradation is the safe
    /// direction: the row goes quiet rather than claiming work that is not
    /// running.
    var liveAgents: [String] = []

    /// Whether `liveAgents`/`agentRuns` list every repo's runs rather than
    /// just this session's own crew — true only for the steward, which works
    /// across all of them.
    ///
    /// TOP-LEVEL, THE SAME TREATMENT `liveAgents` GOT ABOVE, and for the same
    /// reason: `agentRuns` lives out here rather than inside `vitals`, so a
    /// reader of `agentRuns` — the cockpit's Dispatched panel — needs the
    /// scope flag on the same footing, not gated behind a vitals reading
    /// that may not have landed yet. The producer's own comment
    /// (`session_state.py:1650-1655`) marks the copy inside `vitals` for
    /// deletion once Deck stops reading it, so this is also what keeps the
    /// session pane's "(fleet)" chip alive past that day.
    var agentsAreFleetWide: Bool = false

    /// The one spelling of "this list is the whole fleet's, not just this
    /// session's crew" — appended by both the session pane's chip
    /// (`SessionPaneView.agentsLabel`) and the cockpit's Dispatched panel
    /// title (`CockpitView.dispatchedPanelTitle`). A shared constant rather
    /// than two string literals, so the two can't drift apart the way
    /// `agentsAreFleetWide` itself exists to keep its two JSON sources from
    /// drifting.
    static let fleetWideSuffix = " (fleet)"

    /// One dispatched run, alive right now, from the mini's `agent_runs` —
    /// the richer record the crew-stats panel draws with (model, task,
    /// runtime), where `liveAgents` above carries only a name.
    ///
    /// Every field but `runId`'s use as a sort tiebreak is drawn on faith
    /// that the record may not have it: `task` is withheld for a private
    /// crew whose dispatch prompt must not leave the machine, and so is
    /// `cost`, withheld by the same resolution. A record missing a field
    /// demotes that field, never the row.
    ///
    /// **A cost is no longer structurally absent while a run is alive.**
    /// The mini now writes a checkpoint beside the final figure and serves
    /// whichever exists (agent-platform#592 and #596), so an in-flight run
    /// carries real spend for a metered run and a list-price reading for a
    /// subscription one.
    struct AgentRun: Equatable {
        var runId: String?
        var agent: String?
        var task: String?
        /// Epoch seconds, absolute — a duration is computed against the
        /// reader's own now at render time, so a clock-skewed mini reads as
        /// a clamped-to-zero runtime rather than a negative one.
        ///
        /// PARSED FROM THE WIRE'S ISO-8601 STRING, NOT A NUMBER. The
        /// `active-json` contract types `started_at` as `%Y-%m-%dT%H:%M:%SZ`
        /// — it is `active.json`'s own registry timestamp, passed through
        /// unconverted — and `agent-platform#464`'s producer sends exactly
        /// that shape. A decoder that read it as `NSNumber` found `nil` for
        /// every real run: no runtime ever drew, and `sortedAgentRuns` fell
        /// through to its `runId` tiebreak on every poll because it never
        /// saw a `startedAt` to sort by.
        var startedAt: Double?
        var repo: String?
        var model: String?
        /// What this run has spent, or nil when the mini sent no readable
        /// figure. See `RunCost`.
        var cost: RunCost? = nil
        /// How the run's model was chosen, from the run register's `/runs`
        /// rather than from session-agent. `agent_runs` doesn't carry it, so
        /// `ContentView.selectedAgentRuns` joins it in by `run_id` from
        /// `RailStateModel.runChoices`. nil when the register had no row or
        /// no readable value for this run.
        var modelSource: RunModelSource? = nil
        /// The model the dispatch resolved before a fail-over, joined in the
        /// same way. Only names what a fail-over fell back from.
        var modelResolved: String? = nil
        /// The complete dispatch instruction, joined in from the run
        /// register's `/runs` by `run_id`. `task` above is session-agent's
        /// copy, cut near 500 characters, and must never stand in for this.
        /// nil when the register had no row for the run (private crew, or the
        /// read failed), which the run pane reports as withheld.
        var fullTask: String? = nil

        /// What a run has spent, and where that number came from.
        ///
        /// **THE SOURCE IS NOT OPTIONAL, AND THAT IS THE POINT.** The operator
        /// approved serving a list-price reading for a subscription run on
        /// condition that it never draws as though it were metered spend
        /// (2026-09-15). Pairing the two in one value means no later code
        /// path can carry the amount while dropping the marking — a
        /// `RunCost` cannot be constructed without saying which kind it is.
        struct RunCost: Equatable {
            enum Source: Equatable {
                /// Real metered spend, through the gateway's log. Only grows.
                case metered
                /// Token usage priced at list. Measured between 12% under and
                /// 16% over the final figure across five finished runs — a
                /// sample rather than a bound, so it is drawn as approximate
                /// and never as a total.
                case estimate
                /// A source this build does not know. Drawn as approximate,
                /// never plain: an unknown provenance is not a metered one.
                case unrecognized(String)

                init(wire: String) {
                    switch wire {
                    case "gateway_spend_log": self = .metered
                    case "estimate_fallback": self = .estimate
                    default: self = .unrecognized(wire)
                    }
                }

                /// Whether the figure is exact. Only `metered` is.
                var isExact: Bool { self == .metered }
            }

            let usd: Double
            let source: Source
            /// When the mini wrote the figure, as it sent it. Shown in the
            /// tooltip so a reader can tell a fresh reading from a stale one;
            /// never extrapolated past, which is the producer's own rule.
            var writtenAt: String? = nil
        }

        /// This element's position in the most recent `CockpitView.sortedAgentRuns`
        /// output — `nil` for an `AgentRun` built any other way (decode, a
        /// test fixture, a hand-built value). Exists solely to break the
        /// fallback `id`'s remaining tie; see the doc there for why value
        /// equality alone is not enough. NOT a durable identity: a run's
        /// index can shift between polls as sibling runs start or end, so
        /// this is stable only within the one render pass that stamped it.
        var snapshotIndex: Int? = nil

        /// Stable across polls when the mini gives us `run_id`; otherwise a
        /// composite of the fields least likely to collide, so a `ForEach`
        /// keyed on it does not tear a row down and rebuild it every poll
        /// merely because the record carries no id.
        ///
        /// A PRIVATE CREW REDACTS `run_id`, `started_at`, `repo` AND `model`
        /// TOGETHER — `agent-platform#464`'s `_agent_run_detail` nulls all
        /// four as one deliberate redaction on every read, so a private-crew
        /// row carries only the agent name. Two concurrent runs of the same
        /// agent under that crew therefore decode to byte-identical
        /// `AgentRun`s, and without more they'd produce the same fallback id
        /// — which tears one of the two rows out of `ForEach`'s diffing
        /// while the panel's own count badge still says two, exactly
        /// backwards from what the redaction is for ("the run still draws;
        /// the fleet is not under-reported"). The producer gives Deck no
        /// disambiguator for this case, so `snapshotIndex` — set fresh by
        /// `sortedAgentRuns` from that call's own array order — is folded in
        /// here as the tiebreak of last resort. It does NOT make the id
        /// durable across polls; a run's index can move as siblings start or
        /// end, so do not "simplify" this back into a pure value-based key.
        var id: String {
            if let runId { return runId }
            let startedPart: String = startedAt.map { String($0) } ?? ""
            let indexPart: String = snapshotIndex.map { "#\($0)" } ?? ""
            return (agent ?? "") + "|" + (model ?? "") + "|" + startedPart + "|" + indexPart
        }
    }

    /// Dispatched runs alive right now, from the mini's `agent_runs` — nil
    /// when the mini predates the field (never fetched, distinct from
    /// fetched-and-empty), populated (possibly empty) otherwise. See
    /// `AgentRun`.
    ///
    /// Defaulted to `nil`, unlike most of this struct's optional fields,
    /// so every existing test and call site constructing a `SessionState`
    /// by hand — none of which knows about this field — keeps compiling
    /// rather than needing a mechanical `agentRuns: nil` added everywhere.
    var agentRuns: [AgentRun]? = nil

    /// What the terminal's status area says about this session, or nil when the
    /// mini could not assemble it. See `Vitals`.
    var vitals: Vitals?

    /// How many messages the session is holding, queued but not yet read by
    /// the agent — a COUNT ONLY, never the text.
    ///
    /// DISCARDED AT DECODE, NOT A STYLE CHOICE. `held.messages` on the wire is
    /// text the reader typed that the agent has not read yet, and Slice B's
    /// security review settled that Deck has no reason to hold it at rest.
    /// The count is everything Rewrite's predicate and its button need. The
    /// text itself enters Deck exactly once — from `SessionAgent.unqueue`'s
    /// return value, at the instant the reader asks for it back — and is
    /// never folded into this struct, logged, or kept past landing in the
    /// composer. `draft` is not persisted today; this keeps it that way.
    ///
    /// FOUR PAYLOAD SHAPES ON THE WIRE, THREE ANSWERS HERE, because absent and
    /// `null` must stay distinguishable — the contract's standing rule that
    /// absent means "not established", never "not offered":
    ///
    /// | payload | meaning | here |
    /// |---|---|---|
    /// | key absent | not read (brief, not `working`, or an old mini) | `nil` |
    /// | `null` | read and could not be established | `.unknown` |
    /// | `messages: []` | positively nothing held | `.count(0)` |
    /// | `messages: […]` | this many held | `.count(n)` |
    var held: HeldCount?

    /// What the co last said it is working on, for the strip drawn under the
    /// conversation. `nil` whenever nothing was recorded — a mini predating
    /// the field, a session where the co never ran `co-working-on`, or a
    /// recording that failed to parse.
    var workingOn: WorkingOn?

    /// How full the session's context window is, as a percentage — the rail's
    /// meter. `nil` when there is no reading yet.
    ///
    /// TOP-LEVEL FIRST, `vitals` AS THE FALLBACK, the same order `liveAgents`
    /// follows and for the same reason: the rail's brief `states` poll carries
    /// `ctx_pct` at the top level (agent-platform#560) and no vitals block, while
    /// the open pane's full read carries both. One number, read from whichever
    /// place this payload has it, so the rail and the pane quote one reading.
    var contextPercent: Double? = nil

    /// What the rollover hook last decided for this session
    /// (`platform/decisions/0069-a-co-session-rolls-itself-over-before-it-runs-out-of-context`).
    /// `nil` when the key is absent — a mini that predates the hook — or when
    /// the object is unreadable. Carried top level on the brief poll, like
    /// `contextPercent`, so the rail can draw it.
    var rollover: Rollover? = nil

    /// The Slate's count of asks waiting on the operator — `asks_open` on the
    /// wire, carried top level like `contextPercent`/`rollover` so the rail's
    /// brief poll has it without a second call (steward epic
    /// issue_01M3WPJC2790N8JM8MGR7BQ5RJ, comment 4615).
    ///
    /// TWO ANSWERS, NOT THREE, unlike `held`: there is no `nil`-on-the-wire
    /// case to carry, only "the key is absent" (a mini that predates the
    /// Slate, or an unparseable count) and "the mini has a reading". `nil`
    /// here draws no badge at all. `.unknown` is what `slate_error`'s mere
    /// PRESENCE forces regardless of what `asks_open` says alongside it — the
    /// producer sets it beside a zero count, and a zero the mini itself
    /// cannot vouch for must not draw as "nothing waiting," which is what a
    /// bare `.count(0)` would claim.
    var asksOpen: AsksOpen? = nil

    /// See `asksOpen`.
    enum AsksOpen: Equatable {
        case unknown
        case count(Int)
    }

    /// The rollover hook's state for one session, decoded.
    struct Rollover: Equatable {
        /// A CLOSED SET, agreed with the Bosun (epic comment 2399): anything
        /// else decodes as `.unrecognized` and draws as "state unknown", never
        /// as a guess at the nearest known state.
        enum State: Equatable {
            /// Below the seek threshold. The wire calls it `none`; named `ok`
            /// here so it can never be confused with `Optional.none`.
            case ok
            /// Past the seek threshold, looking for a good moment.
            case seeking
            /// Past the hard floor or the call cap: rolls over at any moment.
            case rollNow
            /// The rotation is under way.
            case rolling
            /// An operator stopped it, until the limit `vetoedUntil` names.
            case vetoed
            /// The rollover stopped and will not retry on its own; `reason`
            /// says what the hook saw, and it is the only thing that does.
            /// Two of the four reasons (`spawn_error`, `verify_up_failed`)
            /// are a successor that was attempted; `declined` is a session
            /// told to roll over that did not; and `seeking_loop` records
            /// only the turn endings the hook counted, establishing nothing
            /// about whether a rollover happened. **So do not describe this
            /// state as a failed spawn, and do not describe `seeking_loop` as
            /// a rollover never attempted** — `ContextMeter.parkedText` has
            /// the per-reason wording and why each stops where it does.
            case parked
            case unrecognized(String)

            init(wire: String) {
                switch wire {
                case "none": self = .ok
                case "seeking": self = .seeking
                case "roll_now": self = .rollNow
                case "rolling": self = .rolling
                case "vetoed": self = .vetoed
                case "parked": self = .parked
                default: self = .unrecognized(wire)
                }
            }
        }

        /// The global rollover policy the hook evaluated against. Every limit
        /// is optional and means it: `floorPercent` and `seekCallCap` stay
        /// null until the Bosun has measured enough sessions to set them.
        struct Policy: Equatable {
            var seekPercent: Double?
            var floorPercent: Double?
            var seekCallCap: Int?
            /// `observe` (the hook decides and records but never acts) or
            /// `enforce`.
            var mode: String?
        }

        var state: State
        var reason: String?
        /// Epoch seconds the session entered `state`. Absolute, so a duration
        /// is computed against the reader's own clock.
        var since: Double?
        /// Model calls spent looking for a moment, out of `cap`.
        var callsSeeking: Int?
        var cap: Int?
        /// Which policy key a veto holds until — `seek_pct`, `floor_pct` or
        /// `seek_call_cap` — or `nil` when the veto has no limit to wait for.
        /// **`seek_pct` is the one a live veto actually returned** (measured
        /// 2026-09-18 under `mode: enforce`, `floor_pct: 88`), and it was
        /// missing from this list and from `ContextMeter.vetoText`, which
        /// rendered the raw wire word to the operator.
        var vetoedUntil: String?
        /// The successor's tmux window index while `rolling`, so the rail can
        /// label that window rather than draw it as an unexplained leaf.
        var successorWindow: Int?
        var policy: Policy?
    }

    /// One recording from `co-working-on`, decoded.
    ///
    /// TWO CONSUMER RULES, AND THEY ARE THE POINT OF THE FIELD — see
    /// `WorkingStrip`, which is where they are enforced:
    ///
    /// 1. When `stale` is true, the text is drawn WITH `age`, never alone —
    ///    a sentence from hours ago shown as current is the exact failure
    ///    this field exists to prevent.
    /// 2. When `since` is `nil`, no duration is drawn — never `age` in its
    ///    place. A recording from an older writer carries no start time, and
    ///    deriving one from the last write would report hours-old work as
    ///    seconds old.
    struct WorkingOn: Equatable {
        /// Sanitised by the producer, and at most 203 characters: `sanitise`
        /// cuts at 200 and appends a literal `...`, so the marker is part of
        /// the value rather than something to add here. Sanitising does NOT
        /// HTML-escape — `<`, `>`, `&`, `"` and `'` come through untouched —
        /// which is safe on this path only because the strip draws native
        /// SwiftUI text, where markup is inert. A surface that builds markup
        /// from this escapes it itself
        /// ([[platform/contracts/session-agent-api]]).
        var text: String
        /// Seconds since the co last confirmed this line, or `nil` when the
        /// recording carries no timestamp.
        var age: Double?
        /// `age > 1200` (twenty minutes), or `nil` alongside `age`.
        var stale: Bool?
        /// Seconds the current text has been the recorded work, or `nil`
        /// when the recording predates this field. A DURATION, not a clock
        /// time — format it against the reader's own now, never the mini's.
        var since: Double?
    }

    /// See `held`.
    enum HeldCount: Equatable {
        /// The mini looked and could not tell — a version mismatch or an
        /// unreadable tail. A marker belongs here, not silence: "nothing
        /// waiting" and "cannot tell" are different facts and a reader acts
        /// on them differently.
        case unknown
        /// Positively this many messages are waiting, oldest first — the
        /// strings never reach this type. Zero is a real positive answer:
        /// the queue was checked and found empty.
        case count(Int)
    }

    /// The facts the TUI keeps in its status area, for a frame that is not the
    /// TUI.
    ///
    /// The operator asked for these because living in the pane meant losing
    /// them: the one line that says how much context is left, which
    /// subscription is being billed, whether the session is reachable from
    /// their phone, what is running under it and which model is answering.
    /// All of it was a terminal away.
    ///
    /// DECODED, NOT DERIVED — the same rule the phase follows, and for a sharper
    /// reason here. The context numbers and the model name come from the payload
    /// Claude Code hands the status-line command inside the session, so the
    /// terminal and this frame quote one reading rather than computing two. A
    /// pane that said 44% beside a terminal saying 48% would make both suspect.
    ///
    /// EVERY FIELD IS OPTIONAL AND MEANS IT. A session that has not taken a turn
    /// since this shipped has no reading at all, and one Claude Code release can
    /// take any single field away. Missing is rendered as missing; nothing here
    /// is defaulted to a number that would read as measured.
    struct Vitals: Equatable {
        /// How close the context is to the degradation the status line warns
        /// about. Decided on the mini, where the thresholds live, so the badge
        /// here and the colour there cannot disagree.
        enum Tier: String { case ok, soft, hard, corrupt }

        var model: String?
        var contextTokens: Int?
        var contextWindow: Int?
        var contextPercent: Double?
        var tier: Tier?
        /// Which Claude subscription this session is spending, as `slot
        /// (account)`. Two Max subscriptions share the mini, and a session bills
        /// the credential it launched with.
        var sub: String?
        /// How old the reading is, in seconds. Carried so a stale one can be
        /// shown as stale rather than as now — an idle session's numbers stay
        /// true for hours, but a reader deserves to know which they are looking
        /// at.
        var age: Double?
        var stale: Bool?
        /// Whether the session is bridged to claude.ai, which is what the `/rc`
        /// in the TUI's status row means. `nil` is "could not tell", kept
        /// distinct from `false`: co passes `--remote-control` unconditionally
        /// and the operator has lately had to turn it on by hand anyway, so this is the
        /// difference between an answer and a guess.
        var remoteControlOn: Bool?
        /// The name the session is registered under, which is what the phone's
        /// list shows.
        var remoteName: String?
        /// Dispatched agents alive right now, by agent name.
        var agents: [String]
        /// Whether that list is every repo's rather than this session's own.
        /// True only for the steward, which works across all of them.
        ///
        /// THE PRODUCER'S DEPRECATED COPY — the top-level
        /// `SessionState.agentsAreFleetWide` is what every reader outside
        /// this file should use now, the same way `liveAgents` supersedes
        /// `agents` above. Kept here only as that field's fallback source
        /// for a mini that predates the top-level key.
        var agentsAreFleetWide: Bool
        /// The PR this session is working on, the same one the TUI footer shows.
        /// nil until Claude Code finds one for the branch, and again once it
        /// merges — so most sessions most of the time have none.
        var pr: PullRequest?

        struct PullRequest: Equatable {
            var number: Int
            var url: String?
        }
    }

    /// A question the session has stopped on.
    ///
    /// The two classes DO NOT SHARE a payload shape upstream — an asking-class
    /// gate carries questions and options, a permission-class gate carries the
    /// gated tool's own input — so the mini normalises them and this type mirrors
    /// that normalisation rather than re-deriving it.
    struct Gate: Equatable {
        enum Kind: String { case question, permission }
        var kind: Kind
        var tool: String?
        var questions: [Question]
        /// The permission class's "don't ask again" affordance, carried so the
        /// pane can offer it honestly rather than hiding a settings write behind
        /// a button. Unused by the question class.
        var hasSuggestions: Bool
        /// The tool-use id the mini folded forward from the PreToolUse event
        /// that preceded this gate's PermissionRequest. Absent when none could
        /// be folded — the permanent case for permission-class gates, whose
        /// PreToolUse matcher excludes them.
        ///
        /// WHAT THIS ENABLES. A keystroke Deck sends is aimed at the gate Deck
        /// drew the card from. Binding it to this id lets the mini re-check
        /// before the key lands and refuse when the session has moved on —
        /// see `deck/specs/reading-the-rendered-picker` §5.5.
        ///
        /// Absent is normal and non-fatal. The mini omits the key when it could
        /// not fold an id, and the caller passes no `--expect-gate` in that
        /// case, so the keystroke travels as it did before this field existed.
        var gateId: String?
        /// What the TUI is actually showing, read off the pane by the mini. Absent
        /// when the mini could not establish it, or predates the field.
        var rendered: Rendered?
    }

    /// The picker as drawn, for the facts the payload cannot carry.
    ///
    /// WHY THIS EXISTS AT ALL. `AskUserQuestion`'s payload is passed through
    /// verbatim, so it holds exactly the options the model wrote and nothing the
    /// TUI adds at render time. Which question is live, the appended free-text
    /// row, and whether a multiselect's commit will submit are all rendering
    /// facts, and Deck acted on guesses for the first two until the mini began
    /// reading them. See `deck/specs/reading-the-rendered-picker`.
    ///
    /// EVERY FIELD IS OPTIONAL AND ABSENT MEANS "NOT ESTABLISHED", never "not
    /// offered". A missing `freeTextRow` is not a picker without a free-text row;
    /// it is a picker whose free-text row nobody could see. The two answers differ
    /// in what Deck may draw, so they must not collapse: the pane offers an
    /// affordance only where it was observed, and the terminal covers the rest.
    ///
    /// The whole block disappears on a Claude Code version the mini's markers
    /// have not been checked against, which is deliberate — see the spec's §6. So
    /// every consumer here has to keep working without it, and does: `nil` falls
    /// back to the cursor Deck was keeping before any of this existed.
    struct Rendered: Equatable {
        /// Which question of the gate is on screen, 0-based, from the highlighted
        /// tab. This is what turns Deck's cursor from a guess into an
        /// observation, and with it a question answered in the terminal
        /// mid-sequence no longer desyncs the pane for the rest of the gate.
        var questionIndex: Int?
        /// The 1-based row of the TUI's appended `Type something.`, which is the
        /// only route to a free-text answer. Deck sends this as a digit, so a
        /// wrong one answers a real option — which is why the mini refuses to
        /// guess it.
        var freeTextRow: Int?
        /// Whether the gate is sitting on its `✔ Submit` review tab.
        var onSubmitTab: Bool?
        /// What committing a multiselect question will do: `next` lands on
        /// another question, `submit` lands on the review tab. Present only on a
        /// multiselect.
        ///
        /// Deck reads this to decide whether it may commit the question and what
        /// to call the button, since the two cases do different things: `next`
        /// saves the ticks and moves on, `submit` ends the gate. The keystrokes
        /// are the mini's either way. Absent means Deck may not commit at all,
        /// which is the behaviour before this field existed.
        var multiSelectCommit: Commit?
        /// The Claude Code build the markers were read against, carried so a
        /// reader can see which release the observation belongs to.
        var claudeVersion: String?

        /// Normalised by the mini, so Anthropic's display strings stop there.
        enum Commit: String { case next, submit }
    }

    struct Question: Equatable {
        var question: String
        var header: String?
        var options: [Option]
        /// Whether the picker takes several answers.
        ///
        /// THE FIELD WHOSE ABSENCE WAS THE BUG. A digit on a single-select
        /// question selects and confirms, so one click answers it. On a
        /// multiselect it only ticks a box and the picker stays up — so Deck,
        /// which decoded every question as if it were single-select, sent one
        /// digit and waited for a gate that was never going to clear. That is
        /// what "clicking the buttons does nothing" was.
        ///
        /// Defaulted to single-select, matching what an absent field means on
        /// the wire: it takes one digit and resolves, so a question read this way
        /// gets answered rather than left standing.
        var multiSelect: Bool = false
    }

    struct Option: Equatable {
        var label: String
        var detail: String?
    }
}

extension SessionState {
    /// Decodes one line of `session-agent` output.
    ///
    /// Every field is optional on the wire and defaulted here, deliberately: the
    /// mini adds fields as the design grows, and a Deck that refuses to parse a
    /// state carrying one new key would go blind on an upgrade. An unreadable
    /// state decodes to `unknown` rather than throwing, for the same reason the
    /// transcript consumers demote a row instead of dropping it.
    static func decode(_ data: Data, fallbackSession: String) -> SessionState {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return SessionState(
                session: fallbackSession, phase: .unknown, gate: nil, alive: false,
                reason: "could not read the session state", lastEvent: nil,
                transcriptMTime: nil, cwd: nil, progressing: nil, lastEventAge: nil)
        }
        return SessionState(
            session: root["session"] as? String ?? fallbackSession,
            phase: (root["state"] as? String).flatMap(Phase.init(rawValue:)) ?? .unknown,
            gate: decodeGate(root["gate"]),
            alive: root["alive"] as? Bool ?? false,
            reason: root["reason"] as? String,
            lastEvent: root["last_event"] as? String,
            transcriptMTime: (root["transcript_mtime"] as? NSNumber)?.doubleValue,
            cwd: root["cwd"] as? String,
            progressing: root["progressing"] as? Bool,
            lastEventAge: (root["last_event_age"] as? NSNumber)?.doubleValue,
            // Top-level first, `vitals` as the fallback. Deck runs against a
            // mini it does not control the deploy of, so it has to read the
            // older shape too — otherwise the open pane loses a badge it has
            // been drawing for weeks the moment this ships, and gets it back
            // only when the mini pulls.
            liveAgents: (root["agents"] as? [Any]).map { $0.compactMap { $0 as? String } }
                ?? decodeVitals(root["vitals"])?.agents
                ?? [],
            // Same top-level-first, vitals-as-fallback order as `liveAgents`
            // just above.
            agentsAreFleetWide: (root["agents_fleet_wide"] as? Bool)
                ?? decodeVitals(root["vitals"])?.agentsAreFleetWide
                ?? false,
            agentRuns: decodeAgentRuns(root["agent_runs"]),
            vitals: decodeVitals(root["vitals"]),
            held: decodeHeld(root),
            workingOn: decodeWorkingOn(root["working_on"]),
            // Same top-level-first, vitals-as-fallback order as `liveAgents`.
            contextPercent: finiteNumber(root["ctx_pct"])
                ?? decodeVitals(root["vitals"])?.contextPercent.flatMap { $0.isFinite ? $0 : nil },
            rollover: decodeRollover(root["rollover"]),
            asksOpen: decodeAsksOpen(root)
        )
    }

    /// Decodes `asks_open`/`slate_error` to the badge's reading — see
    /// `asksOpen`'s own doc for the precedence between them.
    ///
    /// READS `root["slate_error"]` RATHER THAN CASTING IT, the same
    /// `decodeHeld` idiom: the key's mere presence is what the contract
    /// defines as "unreadable," whatever the value underneath is, so a caller
    /// checking a cast would miss a `slate_error: null` the producer still
    /// means as a flag.
    private static func decodeAsksOpen(_ root: [String: Any]) -> AsksOpen? {
        guard root["slate_error"] == nil else { return .unknown }
        guard let count = wholeNumber(root["asks_open"]) else { return nil }
        return .count(count)
    }

    /// Decodes `rollover`, or nil when the key is absent or the object carries
    /// no `state` string — the one field every other field is read against.
    static func decodeRollover(_ raw: Any?) -> Rollover? {
        guard let dict = raw as? [String: Any], let wire = dict["state"] as? String else { return nil }
        return Rollover(state: Rollover.State(wire: wire),
                        reason: dict["reason"] as? String,
                        since: finiteNumber(dict["since"]),
                        callsSeeking: wholeNumber(dict["calls_seeking"]),
                        cap: wholeNumber(dict["cap"]),
                        vetoedUntil: dict["vetoed_until"] as? String,
                        successorWindow: wholeNumber(dict["successor_window"]),
                        policy: decodeRolloverPolicy(dict["policy"]))
    }

    /// Decodes a rollover policy object — the one carried inside `rollover`,
    /// and the one `session-agent rollover-policy` prints — or nil when it is
    /// not an object. Shared so the two readings can never disagree on a field.
    static func decodeRolloverPolicy(_ raw: Any?) -> Rollover.Policy? {
        guard let p = raw as? [String: Any] else { return nil }
        return Rollover.Policy(seekPercent: finiteNumber(p["seek_pct"]),
                               floorPercent: finiteNumber(p["floor_pct"]),
                               seekCallCap: wholeNumber(p["seek_call_cap"]),
                               mode: p["mode"] as? String)
    }

    /// A JSON number as a finite `Double`, or nil. `JSONSerialization` bridges
    /// `true`/`false` to `NSNumber` too, so a boolean is refused explicitly
    /// rather than read as 1 or 0.
    private static func finiteNumber(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    /// A JSON number as an `Int`, or nil for a non-number, a boolean, or a
    /// value `Int` cannot hold — `Int(_:)` traps on an out-of-range double.
    private static func wholeNumber(_ raw: Any?) -> Int? {
        guard let value = finiteNumber(raw) else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }

    /// Decodes `working_on`, or nil when there is nothing to draw a strip
    /// for. A block that is present but carries no usable `text` — the
    /// producer's all-null shape for "nothing recorded", or a malformed
    /// document — decodes the same as an absent key: the field is costed,
    /// never the state.
    private static func decodeWorkingOn(_ raw: Any?) -> WorkingOn? {
        guard let dict = raw as? [String: Any],
              let text = dict["text"] as? String, !text.isEmpty
        else { return nil }
        return WorkingOn(
            text: text,
            age: (dict["age"] as? NSNumber)?.doubleValue,
            stale: dict["stale"] as? Bool,
            since: (dict["since"] as? NSNumber)?.doubleValue)
    }

    /// Decodes `agent_runs` — nil when the key is absent (a mini that
    /// predates it, or a top-level shape this build does not recognise),
    /// an array otherwise, empty included. An entry that is not a JSON
    /// object is dropped rather than drawn as a blank row; every field
    /// inside a surviving entry is independently optional, so a run
    /// missing `task` (a withheld private-crew dispatch, per ADR-0043) or
    /// any other single field still decodes, just without that field.
    private static func decodeAgentRuns(_ raw: Any?) -> [AgentRun]? {
        guard let list = raw as? [Any] else { return nil }
        return list.compactMap { entry -> AgentRun? in
            guard let dict = entry as? [String: Any] else { return nil }
            return AgentRun(
                runId: dict["run_id"] as? String,
                agent: dict["agent"] as? String,
                task: dict["task"] as? String,
                startedAt: parseAgentRunStartedAt(dict["started_at"]),
                repo: dict["repo"] as? String,
                model: dict["model"] as? String,
                cost: decodeRunCost(dict))
        }
    }

    /// Decodes `usd`, `cost_source` and `written_at` into one value, or nil.
    ///
    /// **A FIGURE WITHOUT ITS SOURCE IS DROPPED, NOT DRAWN BARE.** The operator
    /// approved showing a list-price reading only on condition that an
    /// estimate never draws unmarked (2026-09-15), and `RunCost` makes the
    /// source non-optional so no later code path can lose it. The producer
    /// enforces the same pairing on its side; this is the client half of the
    /// same rule rather than a guard against a producer nobody has seen fail.
    ///
    /// A negative or non-finite amount is refused for the reason a missing
    /// source is: a row saying `-$4.00` is worse than a row saying nothing.
    private static func decodeRunCost(_ dict: [String: Any]) -> AgentRun.RunCost? {
        guard let usd = finiteNumber(dict["usd"]), usd >= 0,
              let wire = dict["cost_source"] as? String, !wire.isEmpty else { return nil }
        return AgentRun.RunCost(usd: usd,
                                source: AgentRun.RunCost.Source(wire: wire),
                                writtenAt: dict["written_at"] as? String)
    }

    /// `started_at` on the wire is `%Y-%m-%dT%H:%M:%SZ`, `active.json`'s own
    /// registry timestamp — see `AgentRun.startedAt`. Anything not a string
    /// in exactly that shape (a number, a malformed string, absent) decodes
    /// to `nil`, the same demote-the-field-not-the-row rule every other
    /// `AgentRun` field follows.
    private static func parseAgentRunStartedAt(_ raw: Any?) -> Double? {
        guard let string = raw as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)?.timeIntervalSince1970
    }

    /// Decodes `held` to a count, discarding the message strings at the
    /// door — see `held`'s own doc for why.
    ///
    /// READS THE RAW `Any?` BEFORE TOUCHING IT, because `root["held"]`
    /// returning Swift `nil` (the key absent) and returning `NSNull` (the key
    /// present as JSON `null`) are two different facts on the wire, and
    /// collapsing them here would collapse the very distinction this field
    /// exists to carry.
    private static func decodeHeld(_ root: [String: Any]) -> HeldCount? {
        guard let raw = root["held"] else { return nil }
        guard let dict = raw as? [String: Any],
              let messages = dict["messages"] as? [Any] else { return .unknown }
        return .count(messages.count)
    }

    /// Decodes the vitals block, or nil when there is nothing to decode.
    ///
    /// A block present but empty still decodes, and that matters: it is how a
    /// session with no status-line reading yet reports "asked, nothing to tell"
    /// — remote control and the running agents resolve without one, so there is
    /// usually something worth showing even then.
    private static func decodeVitals(_ raw: Any?) -> Vitals? {
        guard let dict = raw as? [String: Any] else { return nil }
        let remote = dict["remote_control"] as? [String: Any] ?? [:]
        return Vitals(
            model: dict["model"] as? String,
            contextTokens: (dict["ctx_tokens"] as? NSNumber)?.intValue,
            contextWindow: (dict["ctx_window"] as? NSNumber)?.intValue,
            contextPercent: (dict["ctx_pct"] as? NSNumber)?.doubleValue,
            tier: (dict["tier"] as? String).flatMap(Vitals.Tier.init(rawValue:)),
            sub: dict["sub"] as? String,
            age: (dict["age"] as? NSNumber)?.doubleValue,
            stale: dict["stale"] as? Bool,
            remoteControlOn: remote["on"] as? Bool,
            remoteName: remote["name"] as? String,
            agents: (dict["agents"] as? [Any] ?? []).compactMap { $0 as? String },
            agentsAreFleetWide: dict["fleet_wide"] as? Bool ?? false,
            pr: decodePR(dict["pr"])
        )
    }

    /// The PR object, or nil. A number is required — a PR the mini could not name
    /// is not one worth a chip — and the rest is optional the way every vitals
    /// field is.
    private static func decodePR(_ raw: Any?) -> Vitals.PullRequest? {
        guard let dict = raw as? [String: Any],
              let number = (dict["number"] as? NSNumber)?.intValue
        else { return nil }
        return Vitals.PullRequest(
            number: number,
            url: dict["url"] as? String)
    }

    private static func decodeGate(_ raw: Any?) -> Gate? {
        guard let dict = raw as? [String: Any],
              let kind = (dict["kind"] as? String).flatMap(Gate.Kind.init(rawValue:))
        else { return nil }

        let questions = (dict["questions"] as? [[String: Any]] ?? []).compactMap { q -> Question? in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> Option? in
                guard let label = o["label"] as? String else { return nil }
                return Option(label: label, detail: o["description"] as? String)
            }
            return Question(question: text, header: q["header"] as? String,
                            options: options,
                            // Absent means single-select, which is both the
                            // common case and the safe default: it takes one
                            // digit and resolves, so a gate decoded this way is
                            // answered rather than left standing.
                            multiSelect: q["multiSelect"] as? Bool ?? false)
        }
        let suggestions = (dict["suggestions"] as? [Any])?.isEmpty == false
        return Gate(kind: kind, tool: dict["tool"] as? String,
                    questions: questions, hasSuggestions: suggestions,
                    gateId: dict["gateId"] as? String,
                    rendered: decodeRendered(dict["rendered"]))
    }

    /// The `rendered` block, or nil when the mini reported none.
    ///
    /// DECODED FIELD BY FIELD, AND A BLOCK THAT DECODES TO NOTHING IS STILL A
    /// BLOCK. The mini omits the whole key when it could establish nothing, so its
    /// presence carries information: the reader ran and the version matched. A
    /// present-but-empty block is then "it looked and saw none of these", which is
    /// a different answer from "it did not look" and is the honest one to keep.
    ///
    /// An unrecognised `multiSelectCommit` decodes to nil rather than throwing,
    /// which matters more than it looks: this field gates whether Deck offers to
    /// finish a multiselect at all, so a word this build does not know has to mean
    /// "do not offer" rather than "offer anyway".
    private static func decodeRendered(_ raw: Any?) -> Rendered? {
        guard let dict = raw as? [String: Any] else { return nil }
        return Rendered(
            questionIndex: (dict["questionIndex"] as? NSNumber)?.intValue,
            freeTextRow: (dict["freeTextRow"] as? NSNumber)?.intValue,
            onSubmitTab: dict["onSubmitTab"] as? Bool,
            multiSelectCommit: (dict["multiSelectCommit"] as? String)
                .flatMap(Rendered.Commit.init(rawValue:)),
            claudeVersion: dict["claudeVersion"] as? String)
    }
}

extension SessionState {
    /// What the live bar says, in words.
    ///
    /// DEFERS TO THE PHASE EXCEPT WHERE THE PHASE IS NOT THE WHOLE ANSWER. A co
    /// at its prompt with three reviewers running is `idle` on the wire, and
    /// "Ready" beside a pulsing ring is the bar contradicting the mark next to
    /// it. The mark learned this distinction; the words have to know it too.
    var liveLabel: String {
        if case .listening = mark { return "Agents working" }
        return phase.label
    }
}

extension SessionState.Phase {
    /// What the pane tells the user, in words rather than a state name.
    var label: String {
        switch self {
        case .idle: return "Ready"
        case .working: return "Working"
        case .waiting: return "Waiting for you"
        case .blocked: return "Needs an answer"
        case .ended: return "Session ended"
        case .unknown: return "State unknown"
        }
    }

    /// Whether the pane accepts a typed message in this state. Blocked takes an
    /// answer rather than a message, and an ended session takes nothing.
    var acceptsMessage: Bool {
        switch self {
        case .idle, .working, .waiting: return true
        case .blocked, .ended, .unknown: return false
        }
    }
}
