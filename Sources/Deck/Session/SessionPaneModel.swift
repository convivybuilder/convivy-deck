import Foundation
import SwiftUI

/// Owns the pane's conversation with the mini: poll state, render, send input.
///
/// EVERY REMOTE CALL IS OFF THE MAIN ACTOR, and the results come back onto it.
/// An ssh round trip is tens of milliseconds at best and unbounded at worst, and
/// a pane that freezes its window while a session is thinking would be worse
/// than the terminal it replaces.
@MainActor
final class SessionPaneModel: ObservableObject {
    @Published private(set) var state = SessionState(
        session: "", phase: .unknown, gate: nil, alive: false,
        reason: nil, lastEvent: nil)
    @Published private(set) var html = SessionPaneModel.placeholder
    /// Backed by `draftStore`, which is what survives this model's own
    /// teardown on a session switch — see `SessionDraftStore`'s doc. Every
    /// write here (a slash-command insertion, `send()`'s optimistic clear,
    /// a failed-send restore, a landed rewrite) flows through `didSet`
    /// rather than needing its own call into the store, so none of those
    /// call sites change shape for this.
    @Published var draft = "" {
        didSet { draftStore.setDraft(draft, for: draftKey) }
    }
    @Published private(set) var sending = false
    @Published private(set) var lastError: String? {
        didSet { lastErrorWrites &+= 1 }
    }

    /// How many times `lastError` has been WRITTEN, which is a different
    /// question from what it currently holds.
    ///
    /// THE ONE THAT SURVIVES AN AWAIT. `send` and `rewrite` both need to know
    /// whether anything reported something while their own round trip was
    /// out, and the obvious test — snapshot the string going in, compare it
    /// coming back — answers "does it differ", not "did somebody write". Two
    /// identical strings compare equal, so a second, live failure worded the
    /// same as the stale one already on screen reads as nothing having
    /// happened and gets dropped. A persistent ssh error retried twice is
    /// exactly that shape. Counting writes has no such blind spot. Raised by
    /// deck-reviewer, as the root cause under two findings rather than one.
    private(set) var lastErrorWrites = 0

    /// Writes `lastError` the way the driving verbs do, for tests that need to
    /// exercise the write counter without an ssh round trip. `lastError` is
    /// `private(set)`, which is what makes the seam necessary rather than the
    /// test reaching in.
    func reportForTesting(_ message: String?) { lastError = message }
    /// Why the last render failed, or nil. Surfaced in the status line so a pane
    /// that cannot draw the conversation still says why.
    @Published private(set) var renderError: String?
    /// Whether the transcript is still moving while the phase reads idle or
    /// waiting — a subagent working on while the main agent looks done. Shown in
    /// the live bar so "Waiting for you" beside ongoing work is not mistaken for
    /// "your turn, nothing happening". See `backgroundActive`.
    @Published private(set) var backgroundActivity = false
    /// A heartbeat, incremented every `pollInterval` regardless of whether
    /// state changed — `SessionPaneView` observes it to drive the per-tick
    /// scroll check that clears the "new output" pill.
    ///
    /// STILL NEEDED NOW THAT STATE ARRIVES BY FOLLOWING RATHER THAN POLLING.
    /// A followed pane emits only on change, so a reader scrolled up in a
    /// quiet session would get no ticks at all if this counted state
    /// arrivals — the pill would stay up with nothing to jump to. `refreshState`
    /// still increments it on every one-shot read, and `startHeartbeat` ticks
    /// it independently while following, so the scroll check gets a pulse
    /// either way.
    @Published private(set) var pollCount = 0

    /// One batch of rows for `ConversationWebView` to splice into the live
    /// document, and the cursor to adopt once every row in it has landed
    /// without error. `removed` carries alongside `rows` the same way: keys
    /// to drop from the page rather than rows to place on it.
    struct PendingDelta: Equatable {
        let generation: Int
        let cursor: Int
        let rows: [SessionAgent.DeltaRow]
        let removed: [String]
    }

    /// The next delta to apply, or nil when nothing is pending. Cleared by
    /// nothing on this side — `ConversationWebView` tracks which generation
    /// it has already applied, the same way it tracks `lastLoaded` for a full
    /// page.
    @Published private(set) var pendingDelta: PendingDelta?
    private var deltaGeneration = 0

    /// The transcript line count as of the last successfully APPLIED delta.
    /// Nil before the first render, and while nil every poll takes the full
    /// `loadHTMLString` path exactly as it did before this bridge existed —
    /// see `deck/specs/session-pane-incremental-rendering`. `private(set)`
    /// rather than `private`, the way `localQuestionIndex` and `ticked` are,
    /// so the invariant that it only advances on a confirmed apply is
    /// testable from outside.
    @Published private(set) var cursor: Int?

    private let session: String
    private var appearance: Appearance = .dark
    /// The canvas colour the shell painted for this session, as a hex string.
    /// Passed to the renderer on every render so the document sits on the same
    /// theme as the terminal behind it.
    private var canvas: String?
    /// The pane's text scale, as a multiplier on the renderer's shipped size.
    /// Carried like `canvas`: the shell resolves it and tells the pane, so one
    /// preference moves the terminal and the conversation together.
    private var scale: Double = 1
    private var lineHeight: Double = SessionTypography.default.lineHeight

    /// Which render is the current one. A render is an ssh round trip, and
    /// holding Cmd-+ fires one per keystroke — several in flight at once, with
    /// no ordering guarantee between them. Without this the pane could settle on
    /// whichever finished LAST rather than whichever was asked for last, leaving
    /// text at a size the user did not choose. Raised in review.
    private var renderGeneration = 0
    private var pollTask: Task<Void, Never>?
    /// Bounds how many consecutive OpenSSH multiplexing-client refusals
    /// (`SSHStderrClassifier`) `reRender` and `refreshState` will each retry
    /// silently rather than surface in the live bar — see both call sites.
    /// Separate counters: a render and a state read are independent ssh
    /// round trips and can fail independently of each other.
    private var renderMuxAbsorption = MuxRefusalAbsorptionPolicy()
    private var stateMuxAbsorption = MuxRefusalAbsorptionPolicy()

    /// The pane's primary source of state — one long-lived `session-agent
    /// state --follow` process. See `SessionStateFollower` and
    /// `deck/specs/session-pane-state-detection`. nil whenever the pane is on
    /// the polling fallback instead, which is also nil's other meaning: the
    /// two never run at once, and `stopFollowing`/`fallBackToPolling` are what
    /// keep that true.
    private var follower: SessionStateFollower?
    /// Consumes `follower.events` one at a time, in order — see
    /// `SessionStateFollower.events` for why a single reader loop is what
    /// gives the pane a total order over the lines it delivers, rather than
    /// a pile of independently-scheduled callbacks racing each other onto
    /// the main actor.
    private var followReadTask: Task<Void, Never>?
    private var followReconnect = ConnectionStateMachine()
    private var followRetryTask: Task<Void, Never>?
    /// How many follow attempts in a row have failed to deliver even one
    /// line — reset the moment a line arrives, since that proves the
    /// connection genuinely works. See `shouldFallBackToPolling`.
    private var followerConsecutiveFailures = 0
    /// How many consecutive `.overflow` events the follower has reported —
    /// reset the moment a real line arrives, same as
    /// `followerConsecutiveFailures`. A single overflow is just one dropped
    /// line resyncing itself at the next newline (see
    /// `SessionStateFollower.splitLines`); this only matters if the ceiling
    /// keeps getting hit, which means the stream is genuinely broken rather
    /// than momentarily oversized. See `followerOverflowed`.
    private var followerConsecutiveOverflows = 0
    /// A quiet timer that exists only to keep `pollCount` ticking while
    /// following. See `pollCount` for why the tick has to survive a session
    /// with nothing new to report.
    private var heartbeatTask: Task<Void, Never>?

    /// Watches for a follower whose ssh child is wedged rather than idle —
    /// see `checkFollowerLiveness` for why silence alone cannot answer that
    /// question, and why this asks the control socket directly instead.
    private var followerWatchdogTask: Task<Void, Never>?
    /// Set by `handleFollowedState`/`followerOverflowed`, cleared by
    /// `checkFollowerLiveness` on every tick — whether the follower
    /// delivered anything during the silence window that just elapsed.
    private var followerActivitySinceLastWatchdogTick = false

    /// How long the follower may go with no `.state`/`.overflow` event
    /// before the pane asks the control socket directly whether the
    /// transport is still there.
    ///
    /// SILENCE ALONE CANNOT MEAN "DEAD". Per
    /// `deck/specs/session-pane-followed-state`, `session-agent state
    /// --follow` emits only on a changed reading: "on an idle session the
    /// transcript inevitably ages past the window, and emitting for that
    /// would tell a consumer nothing it did not already know." A session
    /// sitting genuinely idle for hours produces zero lines, so a bound
    /// keyed on line arrival alone would tear down a pane that is doing
    /// nothing wrong.
    ///
    /// What IS bounded here is asking the control socket —
    /// `SSHControlSocket.check`, the same probe `SessionAgent.run`'s
    /// stale-socket recovery already uses — which answers in single-digit
    /// milliseconds against a live master regardless of whether the session
    /// itself has anything to report, and in exactly
    /// `SSHControlSocket.checkTimeout` against the wedged one this exists
    /// for (`SSHProcessRunner.run`'s doc: a connection that accepts but
    /// never completes the mux handshake hangs identically whether it is a
    /// real connection attempt or `-O check`). A confirmed-alive answer
    /// resets the wait rather than proving anything was wrong, so an
    /// indefinitely idle session is never torn down; only a socket that
    /// fails or times out routes through `followerDied()`.
    ///
    /// Not `private`: `SessionStateFollowerTests` pins it against
    /// `launchPlaceholderTimeout` so the two bounds cannot drift apart
    /// silently.
    nonisolated static let followerSilenceTimeout = Duration.seconds(30)

    /// How many consecutive follow failures the pane tolerates — each already
    /// spaced out by `ReconnectPolicy`'s backoff — before giving up on
    /// following for the rest of this pane's life and falling back to the
    /// poll that already worked. A pane must never end up stateless, and the
    /// poll is the drift-proof path for that: a flapping ssh connection gets
    /// several backed-off retries, and only past this ceiling does it stop
    /// trying to follow at all.
    nonisolated static let maxConsecutiveFollowFailures = 5

    /// Whether the follow attempts so far have earned giving up on following.
    /// A pure decision, the same way `shouldRender` and `backgroundActive`
    /// are, so the ceiling is testable without a process.
    nonisolated static func shouldFallBackToPolling(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= maxConsecutiveFollowFailures
    }

    /// How often the pane asks the mini what changed, on the polling
    /// fallback — and, while following, how often `pollCount` ticks on its
    /// own so the "new output" pill still gets checked in a quiet session.
    /// See `pollCount`.
    ///
    /// NOT `private` — `SlateModel` reuses this exact value rather than a
    /// second literal, so "refresh on the cockpit's existing cadence"
    /// (issue_01M3WPYD8M0P8PD20Y3ZBNGBWG) names the cadence the open pane
    /// beside it already polls at, with no second constant to drift from it.
    static let pollInterval = Duration.seconds(2)

    /// The crew's resolved host — see `HostResolution`. Threaded from the
    /// shell rather than re-resolved here, since this type has no notion of
    /// crews or config, only of the one session it drives.
    private let target: SSHTarget

    /// Where the follower's liveness checks and restarts get logged — see
    /// `TransportLog`. Injectable so `SessionPaneModelTests` can point it at
    /// a temp directory rather than the real Application Support one.
    private let transportLog: TransportLog

    /// Where `draft` actually lives — see `draft`'s doc and
    /// `SessionDraftStore`. Owned by `ContentView`, above the `.id()` this
    /// model is torn down and rebuilt behind on every session switch.
    private let draftStore: SessionDraftStore
    /// This pane's key into `draftStore`. Not simply `session`: two crews on
    /// different hosts can share a tmux session name, and a `SessionRef`
    /// carries the host that disambiguates them — the same reason
    /// `ContentView` keys `sessionCwd` and `launchPending` by `SessionRef`
    /// rather than by name.
    private let draftKey: SessionRef

    /// `draftStore`/`draftKey` default rather than requiring every caller to
    /// pass them: most of this type's existing tests exercise rendering and
    /// delta behaviour that has nothing to do with the composer, and forcing
    /// them all to thread a draft key through would be a mechanical, unrelated
    /// edit at every one of those call sites. `SessionPaneView` (the real
    /// caller) always passes both explicitly.
    init(session: String, target: SSHTarget,
         draftStore: SessionDraftStore = SessionDraftStore(),
         draftKey: SessionRef = SessionRef(host: nil, name: ""),
         transportLog: TransportLog = .shared) {
        self.session = session
        self.target = target
        self.draftStore = draftStore
        self.draftKey = draftKey
        self.draft = draftStore.draft(for: draftKey)
        self.transportLog = transportLog
    }

    deinit {
        pollTask?.cancel()
        heartbeatTask?.cancel()
        followerWatchdogTask?.cancel()
        followRetryTask?.cancel()
        followReadTask?.cancel()
        // THE SAME DISCIPLINE `pollTask` GETS, AND THE ONE THAT MATTERS MORE
        // HERE. A cancelled `Task` costs nothing left running; a `Process`
        // costs a live ssh connection and a live `session-agent` on the mini
        // until something calls `terminate()` — see `SessionStateFollower.stop`.
        SessionPaneModel.retireFollower(follower)
    }

    /// Stops a follower and forgets it in `FollowerRegistry`, in that order —
    /// the same pair `stopFollowing` and `followerDied` both need, and the
    /// only one `deinit` can call: `nonisolated` because `deinit` on a
    /// `@MainActor` class runs nonisolated and cannot call an isolated
    /// instance method synchronously. Takes no `self`, only the follower in
    /// question, for the same reason.
    nonisolated private static func retireFollower(_ follower: SessionStateFollower?) {
        guard let follower else { return }
        follower.stop()
        FollowerRegistry.shared.unregister(follower)
    }

    func start(appearance: Appearance, canvas: String? = nil,
               scale: Double = 1,
               lineHeight: Double = SessionTypography.default.lineHeight) async {
        self.appearance = appearance
        self.canvas = canvas
        self.scale = scale
        self.lineHeight = lineHeight
        await reRender(appearance: appearance)
        beginFollowing()
        // ONCE PER SESSION, HERE, rather than when the menu opens. `Menu` has
        // no "opened" callback and an `.onTapGesture` on it never fires — its
        // own AppKit tracking session consumes the event, which deck-reviewer
        // demonstrated by sending a synthetic mouseDown/mouseUp pair. Deferring
        // the fetch to a callback that cannot run left the menu permanently
        // showing its not-yet-read placeholder: the feature looking like it
        // worked while never loading, which is the ambiguity it exists to end.
        //
        // The cost this was avoiding does not exist. One ssh round trip per
        // session is nothing beside the two-second poll already running, and
        // the answer changes only when a file appears on the mini — which the
        // menu's own Reload covers, since a Button inside a Menu does fire.
        loadCommands()
    }

    // MARK: - Reading

    /// Starts (or restarts) the follow path from scratch: no pending retry,
    /// no failure count carried over, and the polling fallback stood down if
    /// it was running. The only caller-visible effect is that state starts
    /// arriving again — the first line IS the current reading, per
    /// `SessionStateFollower`'s reconnection note, so nothing here needs a
    /// cursor to resume from.
    private func beginFollowing() {
        pollTask?.cancel()
        pollTask = nil
        stopFollowing()
        followerConsecutiveFailures = 0
        followerConsecutiveOverflows = 0
        followReconnect = ConnectionStateMachine()
        launchFollower()
        startHeartbeat()
    }

    private func launchFollower() {
        let follower = SessionStateFollower(session: session, target: target)
        self.follower = follower
        followerActivitySinceLastWatchdogTick = false
        followerWatchdogTask?.cancel()
        followerWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SessionPaneModel.followerSilenceTimeout)
                guard let self, !Task.isCancelled else { return }
                await self.checkFollowerLiveness()
            }
        }
        // Registered before `start()` is even dispatched, so a follower that
        // never gets past `SessionAgent.stateArguments` — a bad session name,
        // caught before any process is ever spawned — is still in the
        // registry and `stopAll()` still reaches it. `stop()` on a follower
        // that never launched is safe; see `SessionStateFollower.stop`.
        FollowerRegistry.shared.register(follower)
        // THE LAUNCH ITSELF IS OFF THE MAIN ACTOR — spawning the process and
        // reading its stdout both happen inside `SessionStateFollower`, on
        // its own private queue, never on this one.
        Task.detached { follower.start() }
        // ONE READER, so every line and the eventual exit are handled in the
        // order they actually happened — see `SessionStateFollower.events`.
        followReadTask = Task { [weak self] in
            for await event in follower.events {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .state(let state):
                    await self.handleFollowedState(state)
                case .exited:
                    self.followerDied()
                case .overflow:
                    self.followerOverflowed()
                }
            }
        }
    }

    /// Applies one line the follower delivered — everything a poll tick does
    /// to `state`, `backgroundActivity`, and the render decision, via the
    /// same `applyStateTransition` a poll uses, plus resetting the failure
    /// count: a delivered line proves the connection genuinely works, however
    /// many attempts it took to get here.
    private func handleFollowedState(_ next: SessionState) async {
        followerConsecutiveFailures = 0
        followerConsecutiveOverflows = 0
        followerActivitySinceLastWatchdogTick = true
        followReconnect.connectSucceeded()
        await applyStateTransition(to: next)
    }

    /// Called for a `.overflow` event: the follower dropped a line that
    /// crossed `SessionStateFollower.maxBufferedLineBytes` and resynced at
    /// the next newline on its own — see `splitLines`. The connection is
    /// left running rather than torn down, deliberately: an oversized line
    /// is often the mini re-emitting the same `last_assistant_message` on
    /// every reading, and a teardown-and-reconnect response to that would
    /// just hit the same overflow again on the very next connect, forever.
    /// Only past `maxConsecutiveFollowFailures` IN A ROW of these — the
    /// stream never producing a usable line at all — does the pane give up
    /// on following, the same ceiling and the same fallback `followerDied`
    /// uses for outright connection failures.
    private func followerOverflowed() {
        followerActivitySinceLastWatchdogTick = true
        followerConsecutiveOverflows += 1
        if SessionPaneModel.shouldFallBackToPolling(consecutiveFailures: followerConsecutiveOverflows) {
            fallBackToPolling()
        }
    }

    /// Called once for an UNEXPECTED exit — never for a `stop()` the pane
    /// itself asked for, which `SessionStateFollower.stopped` filters out
    /// before this is ever reached. Either retries after `ReconnectPolicy`'s
    /// backoff or, past `maxConsecutiveFollowFailures`, gives up on following
    /// for good and falls back to polling.
    private func followerDied() {
        // The process is already gone — `stop()` here is a no-op on the
        // process itself — but the registry still holds a reference until
        // this runs, and `stopAll()` would otherwise re-stop (harmlessly,
        // but pointlessly) a follower that has nothing left to tear down.
        SessionPaneModel.retireFollower(follower)
        follower = nil
        followerConsecutiveFailures += 1
        let host = TransportLog.hostLabel(target: target)
        if SessionPaneModel.shouldFallBackToPolling(consecutiveFailures: followerConsecutiveFailures) {
            transportLog.append(
                host: host,
                event: "follow-fallback-to-polling consecutive_failures=\(followerConsecutiveFailures)")
            fallBackToPolling()
            return
        }
        let phase = followReconnect.connectionLost()
        guard case .reconnecting(let attempt, let delay) = phase else { return }
        transportLog.append(
            host: host,
            event: "follow-restart attempt=\(attempt) delay=\(String(format: "%.3f", delay))s")
        followRetryTask?.cancel()
        followRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.launchFollower()
        }
    }

    private func stopFollowing() {
        followerWatchdogTask?.cancel()
        followerWatchdogTask = nil
        followRetryTask?.cancel()
        followRetryTask = nil
        followReadTask?.cancel()
        followReadTask = nil
        SessionPaneModel.retireFollower(follower)
        follower = nil
    }

    /// Called every `followerSilenceTimeout` while following. A tick that
    /// saw the follower deliver something since the last one is not asked
    /// to prove anything further — see `followerSilenceTimeout` for why
    /// silence by itself is not evidence.
    ///
    /// A tick that saw nothing asks `SSHControlSocket.check` directly,
    /// off the main actor since it is a blocking ssh round trip. A
    /// confirmed-alive master means the session is genuinely quiet, and the
    /// wait simply resets — no different from any other tick that saw
    /// activity. Anything else (`.confirmedDead`, `.unresponsive`) is the
    /// same evidence `SessionAgent.run`'s stale-socket recovery already
    /// acts on, so it is cleared here too, before the follower is routed
    /// through `followerDied()` — clearing first means the retry
    /// `followerDied()` schedules opens a fresh master instead of hanging
    /// on the same wedged socket a second time.
    private func checkFollowerLiveness() async {
        guard follower != nil else { return }
        if followerActivitySinceLastWatchdogTick {
            followerActivitySinceLastWatchdogTick = false
            return
        }
        let target = self.target
        let controlPath = defaultControlPath()
        let transportLog = self.transportLog
        // `check`/`clear` log their own result and path removal — see
        // `TransportLog`'s callers in `SSHControlSocket` — so this tick
        // needs no event of its own beyond those.
        let check: SSHControlSocketCheck = await Task.detached {
            SSHControlSocket.check(target: target, controlPath: controlPath, transportLog: transportLog)
        }.value
        guard check.warrantsClearing else { return }
        guard follower != nil else { return }
        await Task.detached {
            SSHControlSocket.clear(target: target, controlPath: controlPath, transportLog: transportLog)
        }.value
        guard follower != nil else { return }
        followerDied()
    }

    /// The last resort: the poll this surface shipped with, kept rather than
    /// deleted so a pane whose follow path cannot work at all — an ssh
    /// binary that moved, a mini that has not installed `--follow` — still
    /// shows something, which is the whole point of a fallback existing.
    private func fallBackToPolling() {
        stopFollowing()
        stopHeartbeat()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SessionPaneModel.pollInterval)
                guard let self, !Task.isCancelled else { return }
                await self.refreshState()
            }
        }
    }

    /// Keeps `pollCount` ticking while following, on the same cadence the
    /// polling fallback used to provide for free. See `pollCount`.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SessionPaneModel.pollInterval)
                guard let self, !Task.isCancelled else { return }
                self.pollCount += 1
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// A one-shot re-read, used by the polling fallback's own tick and by
    /// every driving action (`send`, `choose`, …) that wants a fresh reading
    /// right after acting — independent of whether the pane is following or
    /// polling at the time.
    private func refreshState() async {
        pollCount += 1
        let session = self.session
        let target = self.target
        let outcome: Result<SessionState, Error> = await Task.detached {
            do { return .success(try SessionAgent.state(target: target, session: session)) }
            catch { return .failure(error) }
        }.value
        switch outcome {
        case .success(let next):
            stateMuxAbsorption.succeeded()
            await applyStateTransition(to: next)
        case .failure(let error):
            // OpenSSH's multiplexing-client refusal is retryable by
            // construction — the ControlMaster is alive, only momentarily
            // out of channels — so a bounded run of them is left for the
            // next poll tick to clear rather than reported as "cannot reach
            // the session" on the first occurrence. Any other failure
            // reports exactly as it always has.
            if stateMuxAbsorption.shouldAbsorb(classification: SSHStderrClassifier.classify("\(error)")) {
                return
            }
            await applyStateTransition(to: SessionState(
                session: session, phase: .unknown, gate: nil,
                alive: false, reason: "cannot reach the session", lastEvent: nil))
        }
    }

    /// Everything a new reading of the state does to the pane, wherever the
    /// reading came from: the poll's one-shot fetch and the follower's
    /// pushed line both funnel through here, so the gate-change resets,
    /// `backgroundActivity`, and the render decision cannot drift between
    /// the two paths.
    private func applyStateTransition(to next: SessionState) async {
        // Re-render only when something the document reflects has moved: a
        // reading that found nothing new must not throw away the reader's
        // scroll position and expanded rows, which is the one thing this
        // surface exists to let them do.
        let worthRendering = SessionPaneModel.shouldRender(from: state, to: next)
        // A different question is a different set of boxes. Without this, ticks
        // from an answered multiselect would be drawn against whatever came
        // next, showing answers to a question nobody asked. The error goes with
        // them: it belonged to the question that has just been replaced, and
        // leaving it sitting above the next one's options reads as a failure to
        // answer THAT.
        if next.gate != state.gate {
            ticked = []
            lastError = nil
            // Typed text belongs to the question it was typed for. Carrying it to
            // the next one would offer to answer a question nobody asked with
            // words meant for another, and the user would have to notice.
            freeText = ""
            // A NEW GATE IS THE RE-SYNC for the local cursor. It is Deck's own
            // guess at where the TUI's picker has got to, and a fresh gate is the
            // one moment the guess can be replaced with a fact — the only moment,
            // where the mini cannot read the tab bar. Where it can,
            // `questionIndex` is re-observed on every reading and this matters
            // much less.
            localQuestionIndex = 0
        }
        // Computed against the OLD state, before it is replaced, so it compares
        // this reading's transcript position with the last one's.
        backgroundActivity = SessionPaneModel.backgroundActive(from: state, to: next)
        state = next
        if worthRendering {
            if let cursor {
                await applyDelta(since: SessionPaneModel.nextFetchCursor(
                    cursor: cursor, pendingDelta: pendingDelta), appearance: appearance)
            } else {
                await reRender(appearance: appearance)
            }
        }
    }

    /// The cursor to send as the NEXT `--delta-since`, once a cursor is
    /// known at all — the last fetch's own answer when one is still sitting
    /// unconfirmed in `pendingDelta`, never the last CONFIRMED-drawn `cursor`
    /// itself.
    ///
    /// WHY THE LAST FETCH, NOT THE LAST DRAW. `cursor` only advances once
    /// `ConversationWebView` has actually applied a batch — `deltaApplied`'s
    /// own doc explains why — and that requires SwiftUI to call
    /// `updateNSView` for this pane, which does not happen while the pane is
    /// off screen. Two significant state transitions in quick succession (a
    /// message queued, then absorbed, which is a hold's whole life) each
    /// fetch a delta before either is confirmed drawn; sending the same
    /// stale `cursor` for both means the second fetch is scoped from before
    /// the hold ever started; confirmed live against a real held message
    /// (issue_01M3NWD9SFBS9DT434MVM0D663), the mini's answer to a
    /// `--delta-since` spanning a hold's ENTIRE life never mentions it at
    /// all — no row, no withdrawal — while the same request scoped from the
    /// FIRST fetch's own returned cursor (which does span just the part
    /// after that fetch already saw the hold) correctly answers with its
    /// withdrawal. `applyDeltaOutcome`'s merge is what keeps that first
    /// fetch's row alive long enough for the second's withdrawal to reach it.
    ///
    /// `nonisolated` for the reason `shouldRender` and `backgroundActive`
    /// are: a pure function of two values, testable without a pane.
    nonisolated static func nextFetchCursor(cursor: Int, pendingDelta: PendingDelta?) -> Int {
        pendingDelta?.cursor ?? cursor
    }

    /// Merges two unconfirmed fetches' rows into one array with at most one
    /// entry per key — see `applyDeltaOutcome`'s merge doc for why plain
    /// concatenation duplicates a still-held row.
    ///
    /// A repeated key takes its LATER content, since the second fetch is the
    /// more recent read of that row. A transcript row keeps its EARLIER
    /// position, which the transcript fixes. A `newest` row (a held message)
    /// goes AFTER every transcript row in the merged batch, in the order the
    /// latest fetch carrying it placed it: `applyDeltaBody` stacks rows in
    /// array order, so keeping a held row's first-fetch slot would draw it
    /// above a transcript row the second fetch added. A key present in
    /// `removed` is dropped from the merged rows outright, even if it is
    /// still sitting in `existing` from the first fetch — the mini's most
    /// recent word on that key is that it left the page, and a stale row for
    /// it would only be re-inserted a moment before `removed` deletes it.
    ///
    /// `nonisolated` for the reason `nextFetchCursor` is: a pure function,
    /// testable without a pane.
    nonisolated static func mergedRows(existing: [SessionAgent.DeltaRow], incoming: [SessionAgent.DeltaRow],
                                       removed: [String]) -> [SessionAgent.DeltaRow] {
        let removedKeys = Set(removed)
        var transcriptOrder: [String] = []
        var newestOrder: [String] = []
        var byKey: [String: SessionAgent.DeltaRow] = [:]
        for row in existing + incoming {
            if row.newest {
                // Latest placement wins, and it lands after every transcript row.
                transcriptOrder.removeAll { $0 == row.key }
                newestOrder.removeAll { $0 == row.key }
                newestOrder.append(row.key)
            } else if byKey[row.key] == nil || byKey[row.key]?.newest == true {
                newestOrder.removeAll { $0 == row.key }
                transcriptOrder.append(row.key)
            }
            byKey[row.key] = row
        }
        return (transcriptOrder + newestOrder).compactMap { removedKeys.contains($0) ? nil : byKey[$0] }
    }

    /// Whether the transcript is still moving while the main agent looks done —
    /// a subagent writing its own records while the session reads idle or waiting.
    ///
    /// The confusion this answers: a session says "Waiting for you" while a
    /// subagent is still churning, so it looks like your turn when work is
    /// ongoing. Only `idle` and `waiting` qualify — in `working` the pulse
    /// already says busy, in `blocked` the gate is the point, and `ended`/
    /// `unknown` are not live. Measured across polls rather than off the mini's
    /// `progressing`, whose five-minute window would keep saying "active" for
    /// minutes after the last write; a poll-to-poll change is the transcript
    /// moving NOW.
    ///
    /// A quiet background shell — an `agentctl wait` with no output — moves
    /// nothing and so shows nothing, which is honest: the session genuinely is
    /// idle until that shell wakes it.
    nonisolated static func backgroundActive(from previous: SessionState,
                                             to next: SessionState) -> Bool {
        guard next.phase == .idle || next.phase == .waiting else { return false }
        guard let now = next.transcriptMTime, now.isFinite,
              let before = previous.transcriptMTime else { return false }
        return now != before
    }

    /// Whether a poll found something the rendered document reflects.
    ///
    /// A free decision rather than a few clauses inside the poll, because it is
    /// the thing that was wrong: it is worth being able to test directly.
    ///
    /// `transcriptMTime` LEADS, because it is the only input that answers the
    /// question directly — the transcript IS the document being rendered, so
    /// its mtime moving is the conversation changing.
    ///
    /// The others were the whole gate until 2026-07-23 and could not carry it.
    /// `lastEvent` is an event TYPE NAME, not an id, so a turn's worth of
    /// `PreToolUse` events compares equal, and phase and gate hold still across
    /// that same stretch. The pane froze for the length of a turn and the
    /// operator went back to the raw terminal, which is the surface it exists to replace.
    /// They stay because they move on transitions worth showing, and because
    /// they are the fallback when the mtime is absent.
    ///
    /// A nil mtime means the mini could not stat the transcript, or predates
    /// the field. Neither means "nothing changed" — so the older signals decide
    /// alone, rather than the gate comparing nil to nil and going quiet.
    /// `nonisolated` because it is a pure function of two values and reaches no
    /// actor state — the main actor buys it nothing and would only force every
    /// caller, tests included, onto the main thread to ask a question about two
    /// structs.
    nonisolated static func shouldRender(from previous: SessionState,
                                         to next: SessionState) -> Bool {
        // `isFinite` is not decoration. `NaN != NaN` is true in IEEE 754, so a
        // NaN here would report a change on every poll and reload the document
        // every two seconds, destroying the scroll position and expanded rows
        // this gate exists to protect. JSONSerialization rejects NaN and
        // Infinity today, so nothing on the wire can produce one — this guards
        // the day the parsing path changes, which is exactly when nobody would
        // think to look here. Raised by deck-security-reviewer.
        if let mtime = next.transcriptMTime, mtime.isFinite,
           mtime != previous.transcriptMTime {
            return true
        }
        return next.lastEvent != previous.lastEvent
            || next.phase != previous.phase
            || next.gate != previous.gate
            // A queued message joining or leaving the queue moves nothing
            // else in the state object — it is not a transcript record, so
            // `lastEvent` does not name it, and `transcriptMTime` is a proxy
            // for it rather than the fact itself, computed from the same
            // read but not guaranteed to differ in lockstep with it. `held`
            // is decoded already; checking it directly, alongside the proxy
            // rather than instead of it, is what makes this gate ask the
            // mini for a delta on the one change the proxy exists to catch
            // and might not. issue_01M3NWD9SFBS9DT434MVM0D663.
            || next.held != previous.held
    }

    func reRender(appearance: Appearance, canvas: String? = nil,
                  scale: Double? = nil,
                  lineHeight: Double? = nil) async {
        self.appearance = appearance
        if let canvas { self.canvas = canvas }
        if let scale { self.scale = scale }
        if let lineHeight { self.lineHeight = lineHeight }
        let session = self.session
        let target = self.target
        let background = self.canvas
        let textScale = self.scale
        let leading = self.lineHeight
        renderGeneration += 1
        let generation = renderGeneration
        // The renderer runs on the mini and returns a self-contained page. Deck
        // passes the appearance it resolved rather than letting the page follow
        // the OS, which is the appearance-authority rule.
        // THE FAILURE IS REPORTED, NOT SWALLOWED. This was `try?`, so a render
        // that died instantly looked exactly like one still in flight: the pane
        // sat on "Loading the conversation…" forever with nothing to act on.
        // The operator hit precisely that, and the placeholder is why it read as a hang.
        // A surface whose whole job is showing you what is happening must not be
        // the one thing that cannot say what went wrong.
        let outcome: Result<String, Error> = await Task.detached {
            do {
                return .success(try SessionAgent.render(
                    target: target, session: session, appearance: appearance,
                    background: background, scale: textScale,
                    lineHeight: leading))
            } catch {
                return .failure(error)
            }
        }.value
        // Discarded if a newer render started while this one was in flight. The
        // work is wasted either way; showing its result would be worse, because
        // it is a page rendered for a size the user has already moved past.
        guard generation == renderGeneration else { return }
        switch outcome {
        case .success(let page):
            renderMuxAbsorption.succeeded()
            applyFullPage(page)
            // The cursor is established once this page has actually
            // finished loading into the web view — see
            // `cursorRead(fromMeta:)`, which `ConversationWebView` calls
            // back into once it can read the page's own `transcript-lines`
            // meta. Nothing to do here yet: `html` has been set, but the web
            // view has not drawn it.
        case .failure(let error):
            // OpenSSH's multiplexing-client refusal is retryable by
            // construction — the ControlMaster is alive, only momentarily
            // out of channels — so a bounded run of them is retried silently
            // rather than shown in the live bar beside the phase pulse.
            // Bounded by `renderMuxAbsorption`: a refusal that keeps
            // recurring still surfaces, exactly as any other render failure
            // always has.
            if renderMuxAbsorption.shouldAbsorb(classification: SSHStderrClassifier.classify("\(error)")) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await reRender(appearance: self.appearance)
                return
            }
            // The last good page is KEPT rather than replaced by an error card:
            // a conversation you can still read beats a blank pane, and the
            // status line carries the reason. Only a pane that never rendered
            // shows the failure as its whole content, because there it is the
            // only thing there is to show.
            renderError = "\(error)"
            if html == SessionPaneModel.placeholder {
                html = SessionPaneModel.failurePage("\(error)")
            }
        }
    }

    /// Applies a whole page, exactly as `reRender`'s success case always has.
    /// Shared with the delta path's `full:true` escape hatch, so that answer
    /// is applied directly rather than paying for a second round trip to
    /// fetch the same page again through `render`.
    private func applyFullPage(_ page: String) {
        html = page
        renderError = nil
        // Whatever was pending belonged to the document this just replaced.
        pendingDelta = nil
    }

    /// Called by `ConversationWebView` once a full page has actually
    /// finished loading, with the delta cursor read off its own
    /// `transcript-lines` meta (agent-platform #379) — or nil when the meta
    /// was absent, unparseable, or negative.
    ///
    /// PREFERRED OVER THE PROBE BELOW. The meta carries exactly the line
    /// count `render_delta` computes for its own `lines` field, read for
    /// free off the page that is already on screen — no second round trip to
    /// the mini just to throw its answer away. `establishCursorIfNeeded`'s
    /// `--delta-since 0` probe stays as the fallback for a mini that has not
    /// yet pulled #379 and so renders a page with no meta in it — without
    /// that fallback, such a mini would leave the pane in full-reload mode
    /// permanently, since nothing else here would ever learn a starting
    /// cursor. Once every mini serves the meta, the probe is dead code; it
    /// stays only for that transition, and it is safe to delete once every
    /// mini has pulled #379.
    ///
    /// A no-op whenever the cursor is already known — the same guard
    /// `establishCursorIfNeeded` applies. This fires on every full page
    /// load, cosmetic re-renders included, so the guard is what keeps that
    /// cheap and keeps a later, stale read from overwriting a good cursor.
    func cursorRead(fromMeta lines: Int?) {
        guard cursor == nil else { return }
        if let lines {
            cursor = lines
            return
        }
        Task { await establishCursorIfNeeded(appearance: appearance) }
    }

    /// Learns the delta cursor by asking `--delta-since 0` — the way the
    /// pane learned it before agent-platform #379 taught the page to carry
    /// its own line count.
    ///
    /// THE FALLBACK, NOT THE PRIMARY PATH — see `cursorRead(fromMeta:)`,
    /// which is preferred because it costs no round trip: it reads a number
    /// already on the page instead of asking the mini a second time. This
    /// probe is what keeps a not-yet-updated mini from leaving the pane in
    /// full-reload mode forever, so it stays even once it looks redundant —
    /// delete it only once every mini in the fleet has pulled #379.
    ///
    /// `--delta-since 0` is asked rather than the page's own line count,
    /// because this path exists precisely for a mini whose render endpoint
    /// does not report one. The rows that comes back are the whole
    /// transcript again, and THEY ARE APPLIED, not discarded down to just
    /// the count — see `applyDeltaOutcome`. Discarding them was the bug: this
    /// probe is a SECOND ssh round trip taken after the page's own render,
    /// and a transcript only ever grows, so the count it returns is
    /// systematically at least as high as what the page holds, even with
    /// nothing racing it. A cursor set ahead of the page means the rows
    /// between them are never sent again — a turn silently missing forever.
    /// Applying the rows instead removes the bias rather than narrowing its
    /// window: they land idempotently on the rows the page already has (same
    /// `data-k`, replaced in place) and insert whatever arrived between the
    /// render and the probe, so the cursor and the page agree by
    /// construction. `deltaApplied` is still the only place the cursor
    /// itself advances.
    ///
    /// A no-op whenever the cursor is already known — `cursorRead(fromMeta:)`
    /// applies the same guard before ever calling this, and `applyDeltaOutcome`
    /// applies it again after the round trip, since another path (a
    /// concurrent full page's own meta, or a second probe) may have set the
    /// cursor while this one was in flight.
    private func establishCursorIfNeeded(appearance: Appearance) async {
        guard cursor == nil else { return }
        let session = self.session
        let target = self.target
        let background = self.canvas
        let textScale = self.scale
        let leading = self.lineHeight
        let generation = renderGeneration
        let outcome: SessionAgent.DeltaOutcome? = await Task.detached {
            try? SessionAgent.delta(target: target, session: session, cursor: 0, appearance: appearance,
                                    background: background, scale: textScale,
                                    lineHeight: leading)
        }.value
        await applyDeltaOutcome(outcome, fetchedAtGeneration: generation,
                                isProbe: true, appearance: appearance)
    }

    /// Fetches one delta and either hands its rows to the view or falls back.
    ///
    /// THE CURSOR DOES NOT ADVANCE HERE. It moves only in `deltaApplied`,
    /// once `ConversationWebView` confirms every row actually landed — see
    /// that method for why an optimistic advance here would be wrong.
    private func applyDelta(since knownCursor: Int, appearance: Appearance) async {
        let session = self.session
        let target = self.target
        let background = self.canvas
        let textScale = self.scale
        let leading = self.lineHeight
        let generation = renderGeneration
        let outcome: SessionAgent.DeltaOutcome? = await Task.detached {
            try? SessionAgent.delta(target: target, session: session, cursor: knownCursor, appearance: appearance,
                                    background: background, scale: textScale,
                                    lineHeight: leading)
        }.value
        await applyDeltaOutcome(outcome, fetchedAtGeneration: generation,
                                isProbe: false, appearance: appearance)
    }

    /// Applies one delta fetch's outcome — shared by `applyDelta`'s ordinary
    /// poll and `establishCursorIfNeeded`'s probe, so both get the same
    /// generation and cursor discipline `reRender` already has for itself.
    /// Split out rather than inlined in each so the decision is callable
    /// directly with a synthetic outcome, the same split `shouldRender` and
    /// `backgroundActive` use: the part that decides, testable without an
    /// ssh round trip; the part that reaches the mini, not. Returns whether
    /// the outcome was accepted, so a test can assert a stale fetch was
    /// refused.
    ///
    /// GATED ON THE RENDER STILL BEING THE ONE ACTIVE WHEN THE FETCH WAS
    /// SENT. An appearance/canvas/scale change that fires a re-render while
    /// this fetch was in flight repaints the page under a new theme; this
    /// batch was rendered for the OLD one, and its rows would match the
    /// fresh page's by `data-k` and land as a silent replace — splicing
    /// stale-theme content in behind the new cursor, where nothing would
    /// ever re-offer it, since the re-render already replaced the document
    /// and re-established its own cursor. `reRender` bumps
    /// `renderGeneration` synchronously before its own await, exactly like
    /// this bumps nothing but reads it the same way.
    ///
    /// `isProbe` IS THE ONLY DIFFERENCE FROM AN ORDINARY DELTA, in two
    /// places:
    ///   - `cursor == nil` is re-checked here, after the fetch's await —
    ///     not just `establishCursorIfNeeded`'s guard before it started.
    ///     The probe exists to learn a cursor that is currently unknown; if
    ///     something else (a concurrent full page's own meta, or a second
    ///     probe) learned one while this fetch was in flight, publishing
    ///     this batch anyway would not corrupt the page — the rows still
    ///     apply idempotently — but it would hand `deltaApplied` a cursor
    ///     racing whatever the other path just set, silently overwriting
    ///     the loser.
    ///   - `.full` and `.unavailable`/`nil` do nothing further for the
    ///     probe, rather than chasing them with the fallbacks below. The
    ///     probe is already running against a page that was just rendered;
    ///     chasing a non-`.rows` outcome with another render would just
    ///     re-trigger the render that spawned it. Leaving the cursor nil
    ///     keeps the pane on the full-render path, which is always correct.
    @discardableResult
    func applyDeltaOutcome(_ outcome: SessionAgent.DeltaOutcome?,
                          fetchedAtGeneration generation: Int,
                          isProbe: Bool, appearance: Appearance) async -> Bool {
        if isProbe {
            guard cursor == nil else { return false }
        }
        guard generation == renderGeneration else { return false }
        switch outcome {
        case .rows(let lines, let rows, let removed):
            deltaGeneration += 1
            // MERGED ONTO AN UNCONFIRMED BATCH, NOT REPLACING IT, whenever
            // `cursor` (only advanced by `deltaApplied`, once the view has
            // actually drawn a batch) has not yet caught up to the batch
            // already sitting in `pendingDelta`. `ConversationWebView`
            // applies `pendingDelta` only when SwiftUI calls `updateNSView`
            // for it, which does not happen while the pane is off screen —
            // two significant transitions in quick succession (a message
            // queued, then absorbed) each fetch off the same un-applied
            // cursor (see `applyStateTransition`'s `pendingDelta?.cursor ??
            // cursor`), and the second fetch's mini-side answer, scoped from
            // that same base, cannot see a hold that resolved inside its own
            // window — confirmed live against a real held message
            // (issue_01M3NWD9SFBS9DT434MVM0D663): `--delta-since` at the
            // stale base cursor never mentions the held row at all, while
            // `--delta-since` at the FIRST fetch's own returned cursor
            // correctly answers with its withdrawal. Replacing `pendingDelta`
            // here would discard the first fetch's held row before the view
            // ever drew it; merging keeps both fetches' rows so the view
            // inserts and withdraws the row in the same batch once it is
            // finally drawn, which is the same visible outcome as an insert
            // and a removal that happened to land one render apart.
            //
            // MERGED BY KEY, NOT CONCATENATED. `render_delta` (the mini's own
            // endpoint) resends the CURRENT held set in full on every call, so
            // a message still held across both fetches carries the identical
            // key in `existing.rows` and `rows`. Plain concatenation put that
            // key in the merged batch twice; `ConversationWebView.applyDeltaBody`
            // snapshots the page's existing rows once before its loop, so the
            // second occurrence read as unseen and inserted a second DOM node
            // (round 2 review, `deck-reviewer`). `mergedRows` keeps one entry
            // per key — the later fetch's content, at the earlier fetch's
            // position — and drops a key this fetch's `removed` names even if
            // it is still sitting in `existing.rows` from the first fetch.
            if let existing = pendingDelta, existing.cursor > (cursor ?? -1) {
                let mergedRemoved = existing.removed + removed
                pendingDelta = PendingDelta(generation: deltaGeneration, cursor: lines,
                                            rows: SessionPaneModel.mergedRows(
                                                existing: existing.rows, incoming: rows,
                                                removed: mergedRemoved),
                                            removed: mergedRemoved)
            } else {
                pendingDelta = PendingDelta(generation: deltaGeneration, cursor: lines,
                                            rows: rows, removed: removed)
            }
        case .full(let page):
            guard !isProbe else { return true }
            // The escape hatch: the cursor is stale (a rotated or truncated
            // transcript is one of the documented reasons) or unusable for
            // some other reason the mini judged, so it is dropped rather than
            // trusted for the next call. `cursorRead(fromMeta:)`
            // re-establishes it once this page has actually loaded — see
            // `reRender`.
            cursor = nil
            applyFullPage(page)
        case .unavailable, nil:
            guard !isProbe else { return true }
            // Cleared for the same reason the `.full` case above clears it:
            // `cursorRead(fromMeta:)` only adopts a fresh page's own count
            // when `cursor == nil`, so leaving the stale value here would
            // stop the render this triggers from ever re-syncing off its
            // own meta.
            cursor = nil
            await reRender(appearance: appearance)
        }
        return true
    }

    /// Called by `ConversationWebView` once every row in `pendingDelta` has
    /// been applied to the live document without error.
    ///
    /// THE ONLY PLACE THE CURSOR ADVANCES. Setting it in `applyDelta` instead
    /// would claim rows were on the page before they were — a JS error or an
    /// unreachable web view between the fetch and the apply would then leave
    /// the next `--delta-since` call starting past content that was never
    /// drawn, and nothing would ever re-offer it.
    func deltaApplied(cursor newCursor: Int) {
        cursor = newCursor
    }

    /// Called by `ConversationWebView` when applying the delta could not be
    /// trusted to have left the page consistent: a JS error, a document with
    /// no `.turns` to insert into, or an apply superseded before it finished.
    ///
    /// THE CURSOR IS DROPPED, NOT KEPT. Whatever the document holds now is
    /// unknown, so the only safe recovery is the full reload every fallback
    /// in this design bottoms out at — `reRender` replaces the document
    /// outright and needs no cursor to already be right, and its success
    /// re-establishes one.
    func deltaFailed() {
        cursor = nil
        Task { await reRender(appearance: appearance) }
    }

    func refresh() {
        Task { await refreshState(); await reRender(appearance: appearance) }
    }

    /// What this session can be told to do by name, once someone has asked.
    ///
    /// NIL MEANS NOBODY HAS LOOKED, which is not the same as an empty list and
    /// the menu says so differently. Loaded on demand rather than polled: it
    /// changes only when a file appears on the mini, so a menu nobody opened is
    /// not worth a round trip per tick.
    @Published private(set) var commands: SessionCommands?

    /// Why the last attempt to read them failed, or nil. A menu that silently
    /// shows nothing is the failure this whole feature exists to remove, so a
    /// read that did not work has to say so rather than look like "none".
    @Published private(set) var commandsError: String?

    /// True while the round trip is out, so the menu can say it is looking
    /// rather than showing an empty list for the length of an ssh hop.
    @Published private(set) var loadingCommands = false

    /// Put a picked command in the composer rather than sending it.
    ///
    /// A slash command usually takes an argument, so sending a bare one would
    /// be a guess about what the reader meant. Appends to whatever is already
    /// there instead of replacing it, because a composer with text in it is a
    /// message being written and clearing it would lose work.
    func insertCommand(_ slash: String) {
        if draft.isEmpty {
            draft = slash + " "
        } else if draft.hasSuffix(" ") || draft.hasSuffix("\n") {
            draft += slash + " "
        } else {
            draft += " " + slash + " "
        }
    }

    /// Reads what this session can be invoked with. Called once from `start`
    /// and again from the menu's Reload; the guard makes a second call while
    /// one is in flight a no-op rather than a second round trip.
    func loadCommands() {
        guard !loadingCommands else { return }
        loadingCommands = true
        let name = session
        let target = self.target
        Task {
            let result: Result<SessionCommands?, Error> = await Task.detached {
                do { return .success(try SessionAgent.commands(target: target, session: name)) }
                catch { return .failure(error) }
            }.value
            loadingCommands = false
            switch result {
            case .success(let loaded):
                commands = loaded
                // A nil decode is not an empty list — the mini answered with
                // something that was not the shape this expects, and reporting
                // "no commands" for it would be the lie.
                commandsError = loaded == nil
                    ? "The host's reply could not be read." : nil
            case .failure(let error):
                commandsError = "\(error)"
            }
        }
    }

    // MARK: - Driving

    /// True once Rewrite has pulled the queue into the composer and the
    /// reader has not yet sent it back. What makes `Send` become `Replace`:
    /// the composer's content came out of the session's own queue rather
    /// than being typed fresh, so sending it is putting those messages back
    /// rather than adding new ones alongside them.
    ///
    /// Cleared on a SUCCESSFUL send, since the messages have then been
    /// requeued and the next thing typed here is an ordinary new message.
    /// Restored if that send fails, so the label does not flip back to
    /// `Send` under text that is still the pulled, unsent content.
    @Published private(set) var isRewrite = false

    /// True while an `unqueue` round trip is out, so a second up-press or
    /// button click cannot start another one. See `rewrite()`.
    @Published private(set) var rewriting = false

    func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        let wasRewrite = isRewrite
        // THE MIRROR OF `rewrite`'s GUARD, and it needs one for the same
        // reason. A `rewrite` started before this send can report its own
        // outcome — a refusal, or "nothing waiting" — while this ssh call is
        // still out, and assigning `lastError` outright on the way back
        // erases it. A CLEAN SEND DOES THIS TOO, since `error` is then nil:
        // the reader's up-arrow produced no visible effect and no
        // explanation. Raised by deck-reviewer.
        let writesBefore = lastErrorWrites
        // Cleared optimistically. A message that reappears in the box after a
        // successful send reads as not sent, and the state poll will show the
        // turn arriving within a couple of seconds either way.
        draft = ""
        isRewrite = false
        let session = self.session
        let target = self.target
        Task {
            let error: String? = await Task.detached {
                do { try SessionAgent.send(target: target, session: session, text: text); return nil }
                catch { return "\(error)" }
            }.value
            sending = false
            let arrivedDuring = lastErrorWrites == writesBefore ? nil : lastError
            lastError = Self.report(error, keeping: arrivedDuring)
            // On failure the text comes back, since the alternative is losing
            // something the user typed.
            //
            // WHAT IT COMES BACK ON TOP OF IS RE-READ, NOT ASSUMED. This
            // failure branch used to assign over the composer unconditionally,
            // which is the same defect `composerAfterRewrite` fixed one
            // mutator over — and the mirror image is worse. A `rewrite()`
            // started before this send can land its pulled messages into an
            // empty composer while this ssh call is still out; overwriting
            // them here destroys the only copy in existence, since `popAll`
            // has already taken them off the session's queue. Found by
            // deck-reviewer, who traced the interleaving the first fix left
            // open.
            if error != nil {
                let restored = Self.composerAfterFailedSend(returning: text, landed: draft)
                draft = restored.text
                if restored.mergedWithALanding {
                    // The composer now holds pulled queue content, whatever
                    // this send was. Saying otherwise would flip the button
                    // back to `Send` over messages that need requeueing.
                    isRewrite = true
                    lastError = Self.report(
                        "A Rewrite landed while this was in flight; both are in the composer.",
                        keeping: lastError)
                } else {
                    isRewrite = wasRewrite
                }
            }
            await refreshState()
        }
    }

    /// What the composer should hold when a send fails and its text has to come
    /// back, given whatever is in the box by the time the failure lands.
    ///
    /// THE BOX IS USUALLY EMPTY HERE, because `send` cleared it optimistically
    /// on the way out and nothing else normally writes to it. The case this
    /// exists for is the one where something did: a `rewrite()` that was
    /// already in flight, landing its pulled messages into that empty box
    /// while this send's own round trip was still out. Those messages have
    /// been popped off the session's queue and exist nowhere else, so the
    /// returning text must not be assigned over them.
    ///
    /// Pulled content goes FIRST for the same reason it does in
    /// `composerAfterRewrite`: those messages were queued before this one was
    /// typed. Pure, because the interleaving that produces it is a race
    /// between two `Task`s and cannot be reproduced reliably in a live test.
    nonisolated static func composerAfterFailedSend(
        returning: String, landed: String
    ) -> (text: String, mergedWithALanding: Bool) {
        guard !landed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (returning, false)
        }
        return (landed + "\n" + returning, true)
    }

    /// Whether an up-arrow press should trigger Rewrite rather than falling
    /// through to the editor.
    ///
    /// NOT `modifiers.isEmpty`, WHICH NEVER MATCHES AN ARROW KEY. macOS
    /// reports arrow presses with `.numericPad` set in the event's modifier
    /// flags — and usually `.function` too — so an empty-set test is false on
    /// every press and made this handler dead code from the day it was
    /// written. The Rewrite button worked and the keystroke it exists to
    /// mirror did nothing, which is exactly what the operator found the first time
    /// anyone drove the composer by hand.
    ///
    /// NO UNIT TEST COULD HAVE CAUGHT IT IN THE OLD SHAPE, and that is why
    /// this is a function rather than a condition inline in the handler: the
    /// predicate underneath (`rewriteTriggers`) was correct and passing the
    /// whole time, and the dead guard sat in a closure nothing could call.
    /// Pulled out here, the regression is one assertion.
    ///
    /// What actually has to be absent is the modifiers that mean something
    /// ELSE on this key: Shift/Option/Command/Control-Up are the editor's own
    /// selection and jump gestures, and taking those would break editing.
    nonisolated static func upArrowTakesTheKey(
        modifiers: EventModifiers, canRewrite: Bool
    ) -> Bool {
        guard canRewrite else { return false }
        return modifiers.isDisjoint(with: rewriteBlockingModifiers)
    }

    /// The modifiers that mean the editor's gesture rather than Rewrite. The
    /// hardware flags an arrow key always carries (`.numericPad`, `.function`)
    /// are deliberately absent — they say which key it is, not what the reader
    /// meant by it.
    nonisolated static let rewriteBlockingModifiers: EventModifiers =
        [.shift, .option, .command, .control]

    /// Whether up-arrow in the composer should trigger Rewrite rather than
    /// moving the cursor or doing nothing.
    ///
    /// A PURE FUNCTION OF THE DRAFT AND THE HELD COUNT, so the one property
    /// that makes this gesture safe — that it never fires over a live edit —
    /// is testable without a keystroke. The caller returns `.ignored` when
    /// this is false: up-arrow in a non-empty composer is an ordinary
    /// text-editor cursor move, and stealing it there would break editing a
    /// multi-line message.
    ///
    /// TRIGGERS ONLY ON A POSITIVELY KNOWN, NONZERO COUNT. `nil` (not read)
    /// and `.unknown` (the mini looked and could not tell) both decline —
    /// offering Rewrite over a guess would let the reader press a gesture
    /// this session cannot honour. `unqueue` itself still refuses a
    /// non-empty remote box regardless of what this predicate decides, so a
    /// stale `.count(0)` that raced a fresh arrival costs nothing but a
    /// foregone gesture on this one press.
    nonisolated static func rewriteTriggers(draft: String, held: SessionState.HeldCount?) -> Bool {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard case .count(let n) = held, n > 0 else { return false }
        return true
    }

    /// What the composer should hold once a Rewrite lands, given what came
    /// back and whatever is in the box by then.
    ///
    /// PURE, BECAUSE THE CASE IT EXISTS FOR IS A RACE and a race is the thing
    /// a live test reproduces least reliably. `rewriteTriggers` proved the
    /// composer empty at the moment of the press, but `unqueue` is an ssh
    /// round trip away — a couple of hundred milliseconds on the pop path,
    /// and up to the verb's whole deadline on the slow ones — and the reader
    /// can type throughout. Assigning the pulled text over that would destroy
    /// something they had just written, which is the exact class of loss this
    /// slice exists to prevent.
    ///
    /// NEITHER SIDE MAY BE DROPPED, which is why they are joined rather than
    /// one winning. The pulled messages are already OUT of the session's
    /// queue and this is their only copy; the typed text is the reader's. The
    /// queued messages go first because they were written first, and the note
    /// explains the arrangement, since text appearing above the cursor is
    /// otherwise a surprise.
    nonisolated static func composerAfterRewrite(
        pulled: [String], typed: String
    ) -> (text: String, note: String?) {
        let queued = pulled.joined(separator: "\n")
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (queued, nil)
        }
        return (queued + "\n" + typed,
                "Your queued messages came back above what you were typing.")
    }

    /// What to show after a Rewrite lands, given the note it wants to leave
    /// and any failure that arrived while it was in flight.
    ///
    /// A FAILURE THAT LANDED DURING THE ROUND TRIP OUTRANKS THE NOTE, and is
    /// never dropped for it. A send failing inside a Rewrite's ssh call used
    /// to be replaced by whatever the Rewrite had to say, so the reader was
    /// told their queued messages had come back and never told their message
    /// had not gone out. Both are shown, the failure first, because the
    /// failure is the one that needs acting on.
    ///
    /// Only an error that CHANGED during the call counts. One already on
    /// screen when the reader pressed up-arrow has been seen, and carrying it
    /// forward would pin a stale complaint above every later message.
    nonisolated static func report(_ note: String?, keeping arrivedDuring: String?) -> String? {
        switch (arrivedDuring, note) {
        case (nil, let note): return note
        case (let during, nil): return during
        case (let during?, let note?): return during + " " + note
        }
    }

    /// Pulls the session's queue back into the composer for editing.
    ///
    /// THE MINI DOES THE WHOLE READ-VERIFY-ACT SEQUENCE; THIS JUST TAKES THE
    /// ANSWER. `unqueue` reads the remote input box, presses `Up`, and reads
    /// the transcript back — all mini-side, because every discriminator
    /// between a real pop and a stray history recall lives on that side of
    /// the ssh hop (`deck/specs/session-pane-input-channel` M1-M5). Deck's
    /// job is to place the returned text and say what happened; it never
    /// reads `held` for the text, only for the count that gates the gesture.
    ///
    /// AN EMPTY SUCCESS IS NOT A REFUSAL. It means the queue had already
    /// drained — the common race, where the turn finished and released the
    /// messages a beat before the press landed — and `lastError` carries a
    /// light, true note rather than silence, because the reader pressed a
    /// key expecting their message back.
    func rewrite() {
        // ONE PULL AT A TIME. Nothing else stops a second up-press or button
        // click landing inside the first call's round trip, and two concurrent
        // `unqueue`s against one tmux session are outside anything the verb's
        // measurements cover: the second would press `Up` into a queue the
        // first has already emptied, take the history recall that follows, and
        // race the first call's box clear. Cheap to refuse, and the reader
        // loses nothing — the pull they asked for is already on its way.
        // Raised by deck-reviewer.
        guard !rewriting else { return }
        rewriting = true
        let session = self.session
        let target = self.target
        // WHAT `lastError` HELD WHEN THIS STARTED, so a failure that arrives
        // WHILE the pull is out can be told from one that was already on
        // screen. Every branch below used to assign `lastError` outright, and
        // a send failing inside this round trip then vanished behind a note
        // about queued messages — the reader never learned their message had
        // not gone. `reRender` records this codebase being burned by exactly
        // that once already. Raised by deck-reviewer.
        let writesBefore = lastErrorWrites
        Task {
            defer { rewriting = false }
            let outcome: Result<SessionAgent.UnqueueOutcome, Error> = await Task.detached {
                do { return .success(try SessionAgent.unqueue(target: target, session: session)) }
                catch { return .failure(error) }
            }.value
            let arrivedDuring = lastErrorWrites == writesBefore ? nil : lastError
            switch outcome {
            case .success(.messages(let messages)) where !messages.isEmpty:
                // THE COMPOSER IS RE-READ HERE, NOT ASSUMED. `rewriteTriggers`
                // proved it empty at the moment of the press, but the call
                // above is an ssh round trip — a couple of hundred
                // milliseconds on the pop path and up to `unqueue`'s whole
                // deadline on the slow ones — and the reader can type into
                // the composer throughout. Assigning over that would destroy
                // something they had just written, which is the exact class
                // of loss this slice exists to prevent.
                //
                // NEITHER SIDE MAY BE DROPPED, so they are joined rather than
                // one winning: the pulled messages are already OUT of the
                // session's queue and this is their only copy, and the typed
                // text is the reader's. The queued messages go first because
                // they were written first, and `lastError` explains the
                // arrangement, since text appearing above the cursor is
                // otherwise a surprise.
                let landed = Self.composerAfterRewrite(pulled: messages, typed: draft)
                draft = landed.text
                lastError = Self.report(landed.note, keeping: arrivedDuring)
                isRewrite = true
            case .success(.messages):
                lastError = Self.report("Nothing waiting — the session already read it.",
                                        keeping: arrivedDuring)
            case .success(.refused(let reason)):
                lastError = Self.report(reason, keeping: arrivedDuring)
            case .success(.malformed):
                lastError = Self.report("Could not read the queue back.",
                                        keeping: arrivedDuring)
            case .failure(let error):
                lastError = Self.report("\(error)", keeping: arrivedDuring)
            }
            await refreshState()
        }
    }

    /// Which options of a multiselect question are ticked, by 1-based index.
    ///
    /// HELD HERE BECAUSE THE GATE DOES NOT REPORT IT. The payload says what the
    /// question is, never what has been answered so far, and the ticks live in
    /// the TUI's own picker. So this is Deck's record of the digits it has sent
    /// — sound only under the one-driver assumption the mini already states, and
    /// wrong the moment somebody ticks a box in the terminal instead. That costs
    /// a checkmark drawn in the wrong place, not a wrong answer: the digits
    /// still went where they were aimed.
    ///
    /// Cleared when the gate changes, so a new question starts blank rather than
    /// inheriting the last one's ticks.
    @Published private(set) var ticked: Set<Int> = []

    /// What the user has typed into the free-text card, when the picker offers one.
    ///
    /// Separate from `draft`, which is the composer's message text. They are
    /// different destinations — a draft becomes a message to a session that is
    /// listening, this becomes the ANSWER to a question that is blocking — and a
    /// blocked session refuses the first outright. Sharing one field would put the
    /// user's half-typed message into a picker.
    @Published var freeText: String = ""

    /// Which of the gate's questions the pane is showing, 0-based.
    ///
    /// WHY DECK MAY HOLD THIS AT ALL. The gate arrives carrying every question,
    /// the TUI asks them one at a time, and the payload never says which one is
    /// on screen. The pane used to answer the first and send the rest to the
    /// terminal for exactly that reason.
    ///
    /// But the pane is what sent the digit. Answering question 1 is what
    /// advances the TUI to question 2, so after a successful `choose` the pane
    /// knows where the picker went — it put it there. This is that knowledge,
    /// held rather than re-derived.
    ///
    /// IT IS A GUESS WHENEVER THE MINI CANNOT SEE THE SCREEN, and the window is
    /// longer than it looks: somebody answering in the terminal instead. The
    /// gate's payload does not change as the TUI walks through its questions — it
    /// carries all of them for the gate's whole lifetime — so
    /// `state.gate == next.gate` holds from the moment the gate appears until it
    /// fully resolves. The re-sync below therefore does NOT fire between
    /// questions. A pane that fell out of step stays out of step for the rest of
    /// that gate, not for one 2s poll.
    ///
    /// Two consequences, both real:
    ///
    /// - A digit sent from the pane goes to whatever picker is actually up, not
    ///   to the question drawn here. The digit is never misdelivered, but it can
    ///   answer a question the reader was not looking at.
    /// - The multiselect flag is read from the DISPLAYED question. If the pane
    ///   shows a single-select question while the TUI has moved to a multiselect
    ///   one, the digit ticks a box over there while this side treats the
    ///   question as resolved and advances — a second desync on top of the first.
    ///
    /// `questionIndex` prefers `rendered.questionIndex` for exactly that reason,
    /// and this is the local cursor it falls back to. Where the mini can read the
    /// tab bar the desync above cannot happen at all: the cursor is re-observed
    /// every poll, so answering in the terminal corrects the pane on the next one
    /// instead of costing the rest of the gate.
    @Published private(set) var localQuestionIndex: Int = 0

    /// The question index the mini observed on the picker's tab bar, or nil.
    ///
    /// THE ONLY VALUE SAFE TO ASSERT. `questionIndex` falls back to the local
    /// cursor when the observed value is absent, which is the right thing for
    /// RENDERING — the pane should draw something — and the wrong thing for
    /// ASSERTING. Deck's cursor is a local inference, and a gate the mini
    /// cannot read is exactly when the guess is most likely stale. Asserting
    /// a locally-invented index would either refuse a correct keystroke or
    /// pass a wrong one. When this is nil, no `--expect-question` is sent and
    /// the mini degrades permissively — the policy §5.5 records.
    var observedQuestionIndex: Int? {
        state.gate?.rendered?.questionIndex
    }

    /// Which of the gate's questions the pane is showing, 0-based.
    ///
    /// AN OBSERVATION WHERE THERE IS ONE, A GUESS WHERE THERE IS NOT. The mini
    /// reads the live tab off the picker's own highlight, which is the only place
    /// the fact exists — see `deck/specs/reading-the-rendered-picker` §7.2. When it
    /// reports one, that wins over anything this side inferred, because it is the
    /// screen and the local cursor is a memory of what the pane last did to it.
    ///
    /// Out-of-range is ignored rather than clamped. A reported index past the last
    /// question would mean the review tab, which `isAwaitingSubmit` answers from
    /// `onSubmitTab`; taking it as a cursor here would draw the last question's
    /// options over a review screen, where the digits mean something else.
    var questionIndex: Int {
        if let observed = state.gate?.rendered?.questionIndex,
           let count = state.gate?.questions.count,
           observed >= 0, observed < count {
            return observed
        }
        return localQuestionIndex
    }

    // NO NOTE FIELD, AND IT CANNOT BE ONE FROM HERE. #54 shipped one; every
    // attempt failed, and the reason is a guard on the mini that is correct.
    //
    // `session_input.send_message` refuses outright while a session is
    // `blocked`: "answer it before sending a message, or the message becomes
    // the answer". A picker eats a paste — `send` does clear, paste, Enter, so
    // the text lands in the picker's filter box and the Enter takes whichever
    // row is highlighted. The operator watched that happen on 2026-07-24, which is why
    // the guard exists. The only other primitive, `send_key`, takes named keys
    // from an allowlist and cannot carry literal text.
    //
    // So a note needs a verb that does not exist: type text into a live picker
    // WITHOUT submitting. That is mini-side work. Until it exists the pane has
    // no honest way to offer this, and offering it anyway cost the picker its
    // main path — a typed note failed the send, and the failure correctly
    // aborted the choice, so the question could not be answered at all.

    /// The question the pane should be drawing, or nil when the cursor has run
    /// past the end — which means the last answer resolved the gate and the
    /// next poll is about to clear it.
    var currentQuestion: SessionState.Question? {
        SessionPaneModel.question(at: questionIndex, in: state.gate)
    }

    /// How many questions remain after the one on screen.
    var questionsRemaining: Int {
        SessionPaneModel.questionsRemaining(after: questionIndex, in: state.gate)
    }

    /// Every question answered, the gate still open, waiting on its review tab.
    ///
    /// Prefers the observation over the inference, for the reason `questionIndex`
    /// does: `onSubmitTab` is read off the highlighted tab, where the local answer
    /// is "my cursor ran past the last question and I assume the TUI followed".
    var isAwaitingSubmit: Bool {
        SessionPaneModel.isAwaitingSubmit(index: questionIndex, in: state.gate,
                                          observed: state.gate?.rendered?.onSubmitTab)
    }

    /// What committing this multiselect would do, or nil where the pane may not.
    /// See the static.
    var choiceCommit: SessionState.Rendered.Commit? {
        SessionPaneModel.choiceCommit(in: state.gate)
    }

    // MARK: - The cursor, as pure functions
    //
    // Static for the reason `shouldRender` and `backgroundActive` are: the
    // instance reaches the mini over ssh, so the part worth testing is the part
    // that decides, separated from the part that sends.

    /// The question at `index`, or nil when the cursor has run past the end —
    /// which means the last answer resolved the gate and the next poll is about
    /// to clear it.
    nonisolated static func question(at index: Int, in gate: SessionState.Gate?) -> SessionState.Question? {
        guard let gate, index >= 0, index < gate.questions.count else { return nil }
        return gate.questions[index]
    }

    nonisolated static func questionsRemaining(after index: Int, in gate: SessionState.Gate?) -> Int {
        guard let gate else { return 0 }
        return max(0, gate.questions.count - index - 1)
    }

    /// Where the cursor goes after the question at `index` is answered.
    ///
    /// FOR A MULTI-QUESTION GATE IT RUNS ONE PAST THE END, and that is the fix
    /// for a defect, not a tidy-up. Observed against Claude Code 2.1.220: after
    /// the last question is answered the TUI advances to a `✔ Submit` review tab
    /// and **the gate stays open** until `Submit answers` is chosen there.
    ///
    /// The old version stopped at the last question, so the pane went on drawing
    /// that question's cards at a picker which had moved on. The review tab reads
    /// `1. Submit answers` / `2. Cancel`, so clicking what the pane labelled
    /// option 2 would have **cancelled the whole gate**. Hanging was the mild
    /// reading of it.
    ///
    /// A single-question gate resolves on its digit with no review tab, so it
    /// still stops where it is.
    nonisolated static func nextIndex(after index: Int, in gate: SessionState.Gate?) -> Int {
        guard let gate else { return index }
        // One past the last question means "the review tab", for a gate that has
        // one. See `isAwaitingSubmit`.
        let ceiling = gate.questions.count > 1 ? gate.questions.count : gate.questions.count - 1
        return min(index + 1, max(0, ceiling))
    }

    /// Whether the gate is sitting on its review tab with every question answered.
    ///
    /// `kind == .question` IS A SAFETY CHECK, not a tidy-up. On a permission-class
    /// gate the digit this state's button sends — `1` — means "Yes, allow the tool
    /// call". Today that cannot be reached, because the mini normalises a
    /// permission gate to a single question and the `> 1` test rejects it. But
    /// that is a fact about the mini's normalisation, not about this code, and it
    /// is the kind of unwritten cross-component assumption that has cost this
    /// surface two reverts already. The field is decoded; consult it.
    /// `observed` is `rendered.onSubmitTab`, and it OVERRULES the index when
    /// present — in both directions, which is the point. It says the review tab is
    /// showing when the local cursor has not got there (somebody answered the last
    /// question in the terminal), and it says it is NOT when the cursor thinks it
    /// is (the user tabbed back to a question). Either way the pane draws what is
    /// on screen instead of what it last did.
    ///
    /// The `kind` and `count` guards still apply to it. A permission-class gate's
    /// digits do not mean what a question's mean, and a single-question gate has no
    /// review tab to be on, so an observation claiming otherwise is not one this
    /// function will act on.
    nonisolated static func isAwaitingSubmit(index: Int, in gate: SessionState.Gate?,
                                             observed: Bool? = nil) -> Bool {
        guard let gate, gate.kind == .question, gate.questions.count > 1 else { return false }
        if let observed { return observed }
        return index >= gate.questions.count
    }

    /// What committing this multiselect question from the pane would do, or nil
    /// where the pane may not commit it at all.
    ///
    /// THE KEYSTROKES ARE NOT OURS — they are `session_input.submit_choices`'s.
    /// That function presses `Right`, which off a multiselect IS the whole commit,
    /// because the ticks were recorded as they were made. Where the `Right` lands
    /// is what separates the two cases: off the LAST question it lands on the
    /// review tab, off any earlier one it lands on the NEXT QUESTION.
    ///
    /// BOTH ARE SAFE TO ASK FOR, and it took a live gate to notice the pane was
    /// treating only one of them that way. The dangerous keystroke is the trailing
    /// `1` that takes "Submit answers" — off an earlier question that same `1`
    /// answers it with its first option, silently, attributed to the user — and
    /// `submit_choices` reads `multiSelectCommit` itself, returning right after the
    /// `Right` when it says `next`. The pane's job is to name the action, not to
    /// withhold it.
    ///
    /// WHAT THIS FIXES. Deck kept the caller-side precondition after the mini moved
    /// the check inside `submit_choices`, so on question 1 of a multi-question gate
    /// it drew a dead end telling the user to finish in the terminal — at a
    /// question the mini would have committed on request. Found by driving a real
    /// two-question gate, which is the only way it could have been: every unit test
    /// agreed with the pane.
    ///
    /// A SINGLE-QUESTION GATE STILL NEEDS NO OBSERVATION. It is trivially on its
    /// last question, so `Right` can only land on the review tab. This is what
    /// shipped first and it holds with the reader blind, which is why it does not
    /// consult `rendered` at all.
    ///
    /// Otherwise the mini has to say so. `rendered.multiSelectCommit` is read off
    /// the TUI's own button under the options, which reads `Submit` on the last
    /// question and `Next` before it (spec §7.10).
    ///
    /// ABSENT IS STILL NO, which is the whole degradation. A Claude Code version
    /// the markers have not been checked against drops `rendered`, and the pane
    /// goes back to routing this to the terminal rather than committing on a guess
    /// about which question is on screen. Two earlier rules have been narrower than
    /// this one and both were wrong in the same direction: "single-question gates
    /// only" was over-broad about the constraint, and "only where the commit
    /// submits" withheld an action that was already safe.
    ///
    /// The `kind` test is here for the reason it is on `isAwaitingSubmit`: a
    /// permission gate carrying one question with `multiSelect` set would
    /// otherwise pass, and its digits do not mean what a question's digits mean.
    nonisolated static func choiceCommit(in gate: SessionState.Gate?) -> SessionState.Rendered.Commit? {
        guard let gate, gate.kind == .question else { return nil }
        if gate.questions.count == 1 { return .submit }
        return gate.rendered?.multiSelectCommit
    }

    /// What to call the button that commits a multiselect.
    ///
    /// A FUNCTION RATHER THAN A LITERAL IN THE VIEW, so the wording is pinned by a
    /// test. It cannot be pinned at the view: a SwiftUI `Button` inside an
    /// `NSHostingView` surfaces as neither an `NSButton` nor an accessibility
    /// element with a title — measured both ways while writing this — so an
    /// introspection test for the label asserts against something it cannot see.
    /// `PickerTests` has the same note about the free-text card's row number.
    ///
    /// THE TWO NAMES DESCRIBE DIFFERENT EVENTS. Off the last question the gate
    /// ends and the session gets every answer. Off any earlier one the ticks are
    /// saved and the picker moves on, with nothing reaching the session yet —
    /// calling that "Send answer" would tell the user their answer had gone when
    /// it is still sitting on the picker's review tab.
    nonisolated static func choiceCommitLabel(_ commit: SessionState.Rendered.Commit) -> String {
        switch commit {
        case .submit: return "Send answer"
        case .next: return "Save and go to the next question"
        }
    }

    /// Whether a multiselect question's commit has anything to send.
    ///
    /// TICKS OR TEXT, WHERE THIS USED TO BE TICKS ALONE. The free-text field is an
    /// input to this question's answer exactly as the checkboxes are — the picker
    /// returns them comma-joined — so a question carrying only typed words is
    /// answered and must be committable. Requiring a tick would strand it.
    nonisolated static func canCommitQuestion(tickCount: Int, freeText: String) -> Bool {
        tickCount > 0 || commitCarriesText(freeText)
    }

    /// Whether the commit has to carry the field through the free-text walk.
    ///
    /// Whitespace is not an answer, and the same trim decides this and
    /// `answerWithText`'s own guard — so a field holding only spaces neither
    /// enables the button nor sends an empty answer if it somehow did.
    nonisolated static func commitCarriesText(_ freeText: String) -> Bool {
        !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The line beside the commit button, which has to say what the button will
    /// actually send.
    ///
    /// It names the typed words because they are the part a reader cannot otherwise
    /// tell will be included: the ticks are visible as ticks, and the field looks
    /// like a separate control until the button claims it. That ambiguity is the
    /// defect this replaced — two buttons, one of which silently discarded what had
    /// been typed.
    nonisolated static func commitHint(tickCount: Int, freeText: String) -> String {
        let hasText = commitCarriesText(freeText)
        switch (tickCount, hasText) {
        case (0, false): return "Tick what applies, or answer in your own words."
        case (0, true): return "Sending your own words."
        case (let n, false): return "\(n) selected"
        case (let n, true): return "\(n) selected, plus your own words"
        }
    }

    /// Take option `option` on the gate's first question.
    ///
    /// ONE DIGIT IS THE WHOLE ANSWER ONLY FOR A SINGLE-SELECT QUESTION. On a
    /// multiselect it ticks a box and the picker stays up until `submitChoices`,
    /// which is why this records the tick rather than assuming the gate is now
    /// resolved.
    func choose(_ option: Int, multiSelect: Bool = false) {
        let session = self.session
        let target = self.target
        let gateId = state.gate?.gateId
        let obsIdx = observedQuestionIndex
        Task {
            // THE FAILURE IS REPORTED, NOT SWALLOWED. This was `try?`, so a
            // refused digit, an unreachable mini and a session that had already
            // moved on all looked identical from the outside: a button that did
            // nothing. The operator reported exactly that, and the swallowed error is why
            // there was nothing to go on — the same shape as the render bug this
            // pane already learned from.
            let error: String? = await Task.detached {
                do {
                    try SessionAgent.choose(target: target, session: session, choice: option,
                                            gateId: gateId, questionIndex: obsIdx)
                    return nil
                }
                catch { return "\(error)" }
            }.value
            lastError = error
            if error == nil {
                if multiSelect {
                    if ticked.contains(option) { ticked.remove(option) } else { ticked.insert(option) }
                } else {
                    // A single-select digit resolved this question, so the TUI
                    // has moved to the next one and the pane follows it there.
                    advanceQuestion()
                }
            }
            await refreshState()
        }
    }

    /// Step the cursor onto the next question after one is answered.
    ///
    /// Ticks are cleared with it for the reason a new gate clears them: they
    /// belonged to the question just answered, and drawing them against the next
    /// one would show answers to a question nobody asked.
    /// Advances the LOCAL cursor. Where the mini reads the tab bar this is
    /// overruled on the next poll anyway, and it is still worth doing: the poll is
    /// 2s away and the pane should not draw the answered question until then.
    private func advanceQuestion() {
        let next = SessionPaneModel.nextIndex(after: questionIndex, in: state.gate)
        guard next != localQuestionIndex else { return }
        localQuestionIndex = next
        ticked = []
    }

    /// The row a free-text answer is taken on, when the mini could see one AND the
    /// pane knows how to take it. See the static.
    var freeTextRow: Int? {
        SessionPaneModel.freeTextRow(in: state.gate, at: questionIndex)
    }

    /// The row a free-text answer is taken on, or nil where the pane must not
    /// offer one.
    ///
    /// `nil` is not "this picker has no free-text row" — it is "the pane may not
    /// take one here", for either of two reasons, and the pane draws nothing
    /// either way. The affordance is missing on an unrecognised Claude Code
    /// version even though the TUI is still offering it, and the terminal is how
    /// it gets used then.
    ///
    /// OFFERED ON BOTH KINDS OF QUESTION AGAIN, on two different sequences.
    /// `answerWithText` branches; this only decides whether a row exists to answer
    /// on. #60 withheld it on a multiselect because the single-select sequence was
    /// being driven against both and its `Enter` ticked whatever row the highlight
    /// sat on — a phantom answer nobody chose, attributed to the user, which
    /// reached the payload in the observation: a question answered "Olives, …"
    /// where nobody had selected Olives.
    ///
    /// THE WITHDRAWAL WAS ABOUT THE SEQUENCE, NOT ABOUT THE ROW, which is why
    /// restoring it needed a mini-side verb rather than a change here.
    /// `session-agent focus-free-text` walks the highlight onto the row by reading
    /// the pane between arrows, and `answerWithText` commits through the button
    /// rather than through `Enter`. Verified end to end against a live two-question
    /// 2.1.220 gate: the review tab showed the typed text as the whole answer, with
    /// no option ticked alongside it.
    ///
    /// STILL NIL ON AN UNRECOGNISED VERSION, and the guard is unchanged — a Claude
    /// Code build the markers have not been checked against drops `rendered`
    /// entirely, so the card disappears even though the TUI is still offering the
    /// row, and the terminal is how it gets used then. The withdrawal was
    /// per-question rather than per-gate and the restoration keeps that shape: a
    /// gate mixing a multiselect and a single-select offers the card on whichever
    /// question is on screen.
    nonisolated static func freeTextRow(in gate: SessionState.Gate?, at index: Int) -> Int? {
        guard let row = gate?.rendered?.freeTextRow else { return nil }
        guard question(at: index, in: gate) != nil else { return nil }
        return row
    }

    /// One step of a free-text answer, as a value rather than as a call.
    ///
    /// SO THE SEQUENCE CAN BE ASSERTED. The steps reach the mini over ssh, so a
    /// test of `answerWithText` itself would need a live session; naming them makes
    /// the part worth testing — WHICH keystrokes go, in WHICH order — separable
    /// from the part that sends them, the same split `choiceCommit` and
    /// `shouldRender` already use. The safety property is that no multiselect
    /// sequence contains a digit or an `Enter`, and that is a test rather than a
    /// comment because a phantom answer cannot be undone from the pane.
    enum FreeTextStep: Equatable {
        /// A digit. FOCUSES the field on a single-select; TICKS the row on a
        /// multiselect, which is why it appears in only one of the two sequences.
        case choose(Int)
        /// Walks the highlight onto the row by reading the pane between arrows.
        case focusFreeText
        /// The bracketed paste. The one step both sequences share.
        case type
        /// A named key. `Enter` commits on a single-select and ticks a row on a
        /// multiselect, so it is likewise in only one of them.
        case key(String)
        /// Commits through the button, which is the only commit that works with the
        /// highlight in the free-text group.
        case submit

        func send(target: SSHTarget, session: String, text: String,
                  gateId: String? = nil, questionIndex: Int? = nil) throws {
            switch self {
            case .choose(let row):
                try SessionAgent.choose(target: target, session: session, choice: row,
                                        gateId: gateId, questionIndex: questionIndex)
            case .focusFreeText:
                try SessionAgent.focusFreeText(target: target, session: session,
                                               gateId: gateId, questionIndex: questionIndex)
            case .type:
                try SessionAgent.type(target: target, session: session, text: text,
                                      gateId: gateId, questionIndex: questionIndex)
            case .key(let key):
                // `key` is not a picker-state verb; the mini accepts no expectation
                // flags on it. `Enter` committing a single-select answer belongs to
                // the same gate, and that gate has already been re-checked by the
                // preceding `type` step.
                try SessionAgent.key(target: target, session: session, key: key)
            case .submit:
                try SessionAgent.submit(target: target, session: session,
                                        gateId: gateId, questionIndex: questionIndex)
            }
        }
    }

    /// The steps that take a free-text answer on a question of this kind, in order.
    /// The reasoning for each is on `answerWithText`.
    nonisolated static func freeTextSequence(multiSelect: Bool, row: Int) -> [FreeTextStep] {
        multiSelect
            ? [.focusFreeText, .type, .submit]
            : [.choose(row), .type, .key("enter")]
    }

    /// Answer the live question with typed text.
    ///
    /// THREE STEPS EITHER WAY, AND ALL THREE DIFFER BY QUESTION KIND. Every step of
    /// the single-select sequence is wrong on a multiselect, which is what made #60
    /// a withdrawal rather than a patch — the sequence below was recorded without a
    /// scope and driven against both (spec §7.11).
    ///
    /// On a SINGLE-SELECT question the first step does not confirm, which is the
    /// opposite of every other row and the correction that made this possible at
    /// all (§7.7). A digit on a model-supplied option selects AND confirms; the same
    /// digit on the appended free-text row only moves the highlight onto it and
    /// leaves the picker up. So:
    ///
    /// 1. `choose <row>` focuses the field.
    /// 2. `type <text>` replaces its placeholder, submitting nothing.
    /// 3. `key Enter` commits it as the answer.
    ///
    /// On a MULTISELECT question that digit TICKS the row instead and the highlight
    /// never moves, so the paste is swallowed and the `Enter` ticks whatever row the
    /// highlight still sits on — the phantom answer #60 withdrew this card over. The
    /// field is reached by navigating to it and left by pressing the commit button:
    ///
    /// 1. `focus-free-text` walks the highlight onto the row, reading the pane
    ///    between arrows. The mini owns that walk because the option list wraps and
    ///    no counted walk is safe.
    /// 2. `type <text>` — the same middle step.
    /// 3. `submit` commits through the button. `Enter` here would tick a row, and
    ///    `Right` is inert with the highlight in the free-text group, so neither of
    ///    the other commits works from this position.
    ///
    /// SEQUENTIAL AND ABORTING, because a half-done sequence is worse than none.
    /// Step 2 failing after step 1 leaves the picker with its free-text row focused
    /// and nothing typed, which the user can finish or escape in the terminal.
    /// Carrying on to step 3 regardless would commit an EMPTY answer, and #54's
    /// actual harm was a failed note aborting a choice — the same shape, so the
    /// same rule: stop at the first failure and say so.
    ///
    /// Step 3 is deliberately not adjacent to a paste in the same call. The
    /// inherited hazard is that paste and Enter cannot be adjacent, and these are
    /// separate round trips to the mini, which is what keeps them apart.
    func answerWithText(_ text: String) {
        let session = self.session
        let target = self.target
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let row = freeTextRow else { return }
        let multiSelect = SessionPaneModel.question(at: questionIndex, in: state.gate)?
            .multiSelect ?? false
        let steps = SessionPaneModel.freeTextSequence(multiSelect: multiSelect, row: row)
        // Capture the gate binding before the Task: these are what the user
        // acted on, and the mini re-checks them at each step. The observed
        // question index is separate from `questionIndex` because the fallback
        // to the local cursor is correct for rendering and wrong for asserting.
        let gateId = state.gate?.gateId
        let obsIdx = observedQuestionIndex
        Task {
            let error: String? = await Task.detached {
                do {
                    for step in steps {
                        try step.send(target: target, session: session, text: trimmed,
                                      gateId: gateId, questionIndex: obsIdx)
                    }
                    return nil
                } catch { return "\(error)" }
            }.value
            lastError = error
            if error == nil {
                freeText = ""
                // The ticks this question already carried went with the commit —
                // the answer arrives comma-joined with them — so the pane's copy of
                // them belongs to a question that is no longer on screen.
                ticked = []
                // The text WAS the answer, so this question is resolved and the
                // TUI has moved on: to the next question, or one past the end onto
                // the review tab, exactly as a committed multiselect does.
                advanceQuestion()
            }
            await refreshState()
        }
    }

    /// Press `Submit answers` on the review tab.
    ///
    /// A plain digit, because that tab is an ordinary picker: `1` is
    /// "Submit answers" and `2` is "Cancel" (observed, 2.1.220). Deck offers only
    /// the first — cancelling discards every answer already given, and a button
    /// that throws away work belongs where its consequence is visible.
    func submitAnswers() {
        let session = self.session
        let target = self.target
        let gateId = state.gate?.gateId
        let obsIdx = observedQuestionIndex
        Task {
            let error: String? = await Task.detached {
                do {
                    try SessionAgent.choose(target: target, session: session, choice: 1,
                                            gateId: gateId, questionIndex: obsIdx)
                    return nil
                }
                catch { return "\(error)" }
            }.value
            lastError = error
            await refreshState()
        }
    }

    /// Commit a multiselect question whose boxes are already ticked.
    ///
    /// The same call whichever way `choiceCommit` reads, because the mini decides
    /// what the commit does from the same field the pane labelled the button with.
    /// `advanceQuestion` is right for both: off an earlier question the cursor
    /// moves to the next one, and off the last it runs one past the end onto the
    /// review tab, which is where the picker now is.
    func submitChoices() {
        let session = self.session
        let target = self.target
        let gateId = state.gate?.gateId
        let obsIdx = observedQuestionIndex
        Task {
            let error: String? = await Task.detached {
                do {
                    try SessionAgent.submit(target: target, session: session,
                                            gateId: gateId, questionIndex: obsIdx)
                    return nil
                }
                catch { return "\(error)" }
            }.value
            lastError = error
            if error == nil {
                ticked = []
                advanceQuestion()
            }
            await refreshState()
        }
    }

    func interrupt() {
        let session = self.session
        let target = self.target
        Task {
            _ = await Task.detached { try? SessionAgent.interrupt(target: target, session: session) }.value
            // An interrupt restores the interrupted message into the session's
            // OWN input box, so the next send clears before pasting. That is
            // handled on the mini; nothing is needed here beyond re-reading.
            await refreshState()
        }
    }

    /// Shown when the FIRST render fails, because a placeholder that never
    /// resolves is indistinguishable from a slow one — which is exactly how the
    /// bug this replaces presented.
    nonisolated static func failurePage(_ reason: String) -> String {
        let escaped = reason
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
            <!doctype html><meta charset=utf-8>
            <style>body{font:13px -apple-system,sans-serif;padding:2rem;line-height:1.6}
            code{font:12px ui-monospace,Menlo,monospace;opacity:.8;\
            display:block;margin-top:1rem;white-space:pre-wrap}</style>
            <p><strong>The conversation could not be rendered.</strong></p>
            <p>The terminal button still works, and it cannot drift.</p>
            <code>\(escaped)</code>
            """
    }

    /// The composer's stand-in for a phase it will not put a composer or a
    /// gate under: `.blocked` and `.unknown` both end here, and both end at
    /// "open the terminal", but they are not the same sentence, because they
    /// are not the same fact. `.blocked` means the pane read the session
    /// cleanly and the session is stopped, waiting on something the pane has
    /// no renderer for — it knows exactly what happened. `.unknown` means the
    /// pane could not read the session's state at all; saying "waiting on
    /// something" there would be a guess dressed as an observation. Split out
    /// as a pure function of the phase, the same way `failurePage` is, so the
    /// distinction is pinned by a test rather than living only in two nearby
    /// `Text` literals a future edit could quietly merge.
    nonisolated static func composerFallbackMessage(for phase: SessionState.Phase) -> String? {
        switch phase {
        case .blocked:
            return "This session is waiting on something the pane cannot show."
        case .unknown:
            return "Deck cannot read this session's state."
        case .idle, .working, .waiting, .ended:
            return nil
        }
    }

    /// Shown until the first render arrives, so the pane is never blank.
    private static let placeholder = """
        <!doctype html><meta charset=utf-8>
        <style>body{font:13px -apple-system,sans-serif;opacity:.5;padding:2rem}</style>
        <p>Loading the conversation…</p>
        """
}
