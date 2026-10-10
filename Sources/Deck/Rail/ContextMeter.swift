import Foundation

/// The rail's context meter: a hairline along the bottom of a session's row,
/// filled to how much of its context window is in use, plus what the rollover
/// hook has decided about that session. Option A of the three the operator chose
/// between on 2026-09-13 (epic `issue_01M1S2Y2FMEM6WAKPYZ8YX4VMN`).
///
/// A PURE VALUE resolved from one poll reading, so every state's look is
/// pinned by a test without a view — the same split `RailRow.summonsInk` uses.
///
/// DECK DRAWS THE BOSUN'S DECISION AND NEVER MAKES ONE. The track turns amber
/// because `rollover.state` says the session is seeking, never because the
/// percentage crossed a number Deck holds: the policy belongs to the Bosun and
/// can change under a running session
/// (`platform/decisions/0069-a-co-session-rolls-itself-over-before-it-runs-out-of-context`).
struct ContextMeter: Equatable {
    enum Ink: Equatable {
        /// Below the seek threshold, vetoed, or a state Deck does not know.
        case neutral
        /// Looking for a moment, rolling over, or a successor that failed.
        case attention
        /// Rolling over at the next chance. Attention, pulsing, so it reads
        /// differently from looking.
        case attentionPulsing
    }

    enum Glyph: Equatable { case none, rollNow, rolling, vetoed }

    /// How far to fill the track, 0...1, or nil to draw no track at all.
    /// While rolling, the predecessor's reading no longer describes the
    /// session the row will be showing in a moment.
    var fill: Double?
    /// Where the seek threshold's tick sits along the track, 0...1.
    var threshold: Double
    var ink: Ink
    var glyph: Glyph
    /// A parked session needs a person, whichever of the four reasons parked
    /// it, so the row carries the same needs-you bar every other row asking
    /// for a person carries. **The bar is what asks; the hover text is what
    /// explains** — see `parkedText`, and do not restore the promise that an
    /// issue is already waiting, which was not true when measured.
    var summons: Bool
    /// The row's hover text: the exact number the track only approximates,
    /// and what the hook decided.
    var help: String
    /// The rollover state this reading carried, or nil for a mini with no
    /// rollover hook. Carried so `menuTitle` can tell a `.veto` offered from
    /// `.ok` apart from one offered from `.seeking` or `.rollNow` — the
    /// action is the same wire call in all three, so the action alone
    /// cannot say which the row is in.
    var rolloverState: SessionState.Rollover.State?

    /// The seek threshold ADR-0069 names, drawn when a reading carries no
    /// policy (a mini whose hook has not fired for this session yet).
    static let defaultSeekPercent = 70.0

    /// Nil when there is nothing to draw: no context reading and no rollover
    /// state, the shape of a mini that predates both fields.
    static func resolve(contextPercent: Double?, rollover: SessionState.Rollover?) -> ContextMeter? {
        guard contextPercent != nil || rollover != nil else { return nil }
        let seek = rollover?.policy?.seekPercent ?? defaultSeekPercent
        let clamped = contextPercent.map { min(max($0, 0), 100) }
        let reading = clamped.map { "\(Int($0.rounded()))% of context" } ?? "Context use not read yet"
        var meter = ContextMeter(fill: clamped.map { $0 / 100 },
                                 threshold: min(max(seek, 0), 100) / 100,
                                 ink: .neutral, glyph: .none, summons: false, help: reading,
                                 rolloverState: nil)
        guard let rollover else { return meter }
        meter.rolloverState = rollover.state
        switch rollover.state {
        case .ok:
            break
        case .seeking:
            meter.ink = .attention
            meter.help = reading + ", looking for a moment to roll over" + callsText(rollover)
        case .rollNow:
            meter.ink = .attentionPulsing
            meter.glyph = .rollNow
            meter.help = reading + ", rolling over at the next chance"
        case .rolling:
            meter.fill = nil
            meter.ink = .attention
            meter.glyph = .rolling
            meter.help = "Rolling over to a new session"
        case .vetoed:
            meter.glyph = .vetoed
            meter.help = reading + ", rollover vetoed " + vetoText(rollover.vetoedUntil)
        case .parked:
            meter.ink = .attention
            meter.summons = true
            meter.help = reading + ", " + parkedText(rollover.reason)
        case .unrecognized(let wire):
            meter.help = reading + ", rollover state not recognised (\(wire))"
        }
        return meter
    }

    /// The overrides a row's menu offers in each state. Empty wherever an
    /// override would mean nothing (a rotation already under way, a failed
    /// successor the filed issue owns, or a state Deck cannot read), and for
    /// a mini with no rollover hook, whose `session-agent` has no such verb.
    static func actions(for rollover: SessionState.Rollover?) -> [SessionAgent.RolloverAction] {
        guard let rollover else { return [] }
        switch rollover.state {
        case .ok: return [.veto, .seek, .force]
        case .seeking: return [.veto, .force]
        case .rollNow: return [.veto]
        case .vetoed: return [.clear, .force]
        case .rolling, .parked, .unrecognized: return []
        }
    }

    /// The menu item for an override. "Roll Over Now…" carries an ellipsis
    /// because it confirms first: it ends the session's current context.
    ///
    /// `.veto` reads differently depending on `state`, because it means
    /// different things to an operator: offered from `.ok`, nothing is
    /// looking for a moment yet, so the veto is preempting one; offered from
    /// `.seeking` or `.rollNow`, one is already under way, and "This" names
    /// it. `state` is nil only for a mini with no rollover hook, where no
    /// action is ever offered to begin with.
    static func menuTitle(_ action: SessionAgent.RolloverAction,
                          state: SessionState.Rollover.State?) -> String {
        switch action {
        case .veto: return state == .ok ? "Veto the Next Rollover" : "Veto This Rollover"
        case .force: return "Roll Over Now…"
        case .seek: return "Start Looking for a Moment"
        case .clear: return "Lift the Veto"
        }
    }

    private static func callsText(_ rollover: SessionState.Rollover) -> String {
        guard let calls = rollover.callsSeeking else { return "" }
        // SINGULAR AT ONE, because that is the reading a row shows most often:
        // the first firing after a session crosses the threshold says "1 call
        // so far", and "1 calls" was on screen for every session that crossed
        // it (seen live on this session's own row, 2026-09-15).
        guard let cap = rollover.cap else {
            return calls == 1 ? " (1 call so far)" : " (\(calls) calls so far)"
        }
        return " (\(calls) of \(cap) calls)"
    }

    private static func vetoText(_ until: String?) -> String {
        switch until {
        case "seek_pct": return "until it reaches the seek threshold"
        case "floor_pct": return "until it reaches the hard floor"
        case "seek_call_cap": return "until it reaches the call cap"
        case nil: return "until you lift it"
        case let other?: return "until \(other)"
        }
    }

    /// Why a session parked, in the operator's words rather than the wire's.
    ///
    /// **EACH REASON SAYS ONLY WHAT THE HOOK OBSERVED, AND SAYING MORE IS WHY
    /// THIS FUNCTION EXISTS.** A single sentence covering all four said "the
    /// new session failed to start", which asserts a successor on reasons
    /// where none was ever spawned. Measured against a real parked session on
    /// 2026-09-18, whose first reading was `declined` and whose second was
    /// `verify_up_failed` (`issue_01M2HNWAJVK8MHMSNWE0RT1A6C`).
    ///
    /// - `spawn_error` and `verify_up_failed` are a successor that WAS
    ///   attempted: `spawn_successor` raised, or it returned and `verify_up`
    ///   failed. Naming the successor is accurate here.
    /// - `declined` is N re-issues of `roll_now` with no `/rollover` invoked,
    ///   which the hook observes directly, so "was told to roll over and did
    ///   not" is what happened.
    /// - **`seeking_loop` ESTABLISHES NOTHING ABOUT WHAT THE SESSION DID**,
    ///   and an earlier draft of this function got that wrong in the exact
    ///   way the function exists to prevent. `_park_stuck`'s own docstring
    ///   says a session in this state "has not necessarily decided
    ///   anything": the shape is N consecutive turn endings with no tool
    ///   call and no operator prompt between, "a loop this hook is itself
    ///   driving". Its filed body names a rollover that ALREADY SUCCEEDED
    ///   without recording state as the first thing to rule out, and says
    ///   that is what the one measured instance turned out to be. So a
    ///   `seeking_loop` session may well have rolled over already, and text
    ///   saying it "never took a moment" would be false for the only case
    ///   anyone has seen. This says what the hook saw and stops there.
    ///
    /// **NO REASON'S TEXT PROMISES AN ISSUE IS WAITING**, because Deck cannot see
    /// whether one was filed and must not assert what it cannot read. The old
    /// copy promised it on the platform's word alone.
    ///
    /// **DO NOT "FIX" THIS BY QUERYING THE QUEUE FOR THE ISSUE.** The obvious
    /// read is wrong twice over.
    ///
    /// **The product a park files under is derived, and the two park paths
    /// derive it differently.** `bin/co-rollover` uses
    /// `basename(_git_toplevel())` unless `--product` overrides it, so a
    /// crew's park lands under its repo's name rather than its crew name, and
    /// both spellings can be live products in the queue — a rail reading the
    /// wrong one shows "no issue" for a park that filed one correctly. The
    /// hook's own path (`rollover-trigger.py`'s `_park_and_file`) instead
    /// uses `basename(payload["cwd"])`, falling back to `"unknown"`. So the
    /// bucket depends on which path parked the session.
    ///
    /// **And a park files nothing at all when `post_issue` errors.** Both
    /// paths take only `.get("id")` and never read `status`, so the reason is
    /// discarded where it existed. `bin/co-rollover` at least prints
    /// "could not file an issue for this failure" to stderr; the hook path
    /// swallows it, and stderr is not somewhere Deck can read.
    ///
    /// **THE FIX FOR BOTH IS THREE FIELDS ON THE ROLLOVER BLOCK, NOT A QUERY.**
    /// `issue_id`, `issue_status` and `issue_product` land in
    /// agent-platform#622. **None of them is on the SERVED rollover block yet**
    /// — the phrasing matters, because `rollover_policy.py` on `main` already
    /// has `issue_id` in its own default and `mark_parked` already writes it;
    /// what #622 adds is `session_state._ROLLOVER_DEFAULT`, and that dict is
    /// what Deck receives. A field written but absent from it is persisted and
    /// still invisible here. So this text asserts nothing about filing. When
    /// the three arrive:
    ///
    /// - `issue_status` carries `post_issue`'s own answer — `created`,
    ///   `duplicate`, `error:<code>`, or `skip` when there was no token — so
    ///   a park that filed is distinguishable from one that did not, which a
    ///   null `issue_id` alone never was. That ambiguity is what let the live
    ///   parked state on this machine sit for four days looking healthy.
    /// - `issue_product` names the bucket it landed in, which is the derived
    ///   product above and cannot be inferred from the crew.
    ///
    /// So the wording to add then is "parked, filing failed: error:400", read
    /// off the payload. Do not reintroduce a promise the payload does not
    /// carry, and do not reach for the queue: `handoff_path` was deliberately
    /// left off that block, and a product string is filtered exactly.
    ///
    /// The row's own needs-you bar is what asks for the operator; the hover
    /// text says only what happened.
    ///
    /// An unrecognised reason says only that the session parked, since the
    /// honest reading of a word Deck does not know is that it does not know.
    private static func parkedText(_ reason: String?) -> String {
        switch reason {
        case "spawn_error": return "the new session could not be started"
        case "verify_up_failed": return "the new session was started but never came up"
        case "declined": return "it was told to roll over and did not"
        case "seeking_loop": return "it ended its turn repeatedly when told to look for a rollover moment"
        case nil: return "its rollover stopped and it is parked"
        case let other?: return "its rollover stopped and it is parked (\(other))"
        }
    }
}
