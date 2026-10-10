import Foundation

/// One long-lived `session-agent state --follow` process for a pane.
///
/// See `deck/specs/session-pane-state-detection`, "How Deck reads it": the
/// mini already loops the one-shot reader and emits one JSON object per line,
/// flushed, on every state change — starting with the first reading. This
/// type is the client for that stream: it owns the `ssh` child process, reads
/// its stdout OFF THE MAIN ACTOR, and publishes one `Event` per line onto
/// `events`.
///
/// `events` IS THE WHOLE INTERFACE, deliberately narrower than a pair of
/// closures. A single `AsyncStream` consumed by one `for await` loop gives
/// the caller a total order for free — every line, and the eventual exit, in
/// the order they actually happened — where two independent callback
/// closures would leave the caller to reconstruct that order from whatever
/// order its own dispatched `Task`s happened to run in.
///
/// RECONNECTION NEEDS NO CURSOR. State is a level, not an event stream — the
/// mini's first line after a fresh launch is simply the current reading, the
/// same way a poll's answer always was. So a reconnect is just constructing a
/// new follower and calling `start()`; there is nothing to resume from and
/// nothing this type needs to remember across the gap.
///
/// `@unchecked Sendable`: `Process`, `Pipe`, and `FileHandle` predate Swift
/// concurrency and carry no `Sendable` conformance. Every mutation of this
/// type's state after `init` happens on `queue`, a private serial queue, so
/// the data race `Sendable` exists to catch cannot occur here — the compiler
/// simply has no way to see that discipline through a legacy API.
final class SessionStateFollower: @unchecked Sendable {
    /// One thing the follower observed, in the order it observed it.
    enum Event: Equatable {
        case state(SessionState)
        /// The process ended, for any reason: it crashed, ssh dropped, the
        /// mini rebooted. `status` is `nil` when the process never
        /// successfully launched at all — a bad session name, a missing
        /// `ssh` binary — which the caller treats exactly like any other
        /// exit, since either way there is nothing left to read from.
        case exited(status: Int32?)
        /// A line was dropped for exceeding `maxBufferedLineBytes` before a
        /// newline ever showed up — see `splitLines`. The process keeps
        /// running and the read loop keeps going; this is a signal for the
        /// caller to count, not a reason to tear anything down.
        case overflow
    }

    /// The ceiling on a single buffered (not-yet-newline-terminated) line,
    /// in bytes. `last_assistant_message` is model-generated text Deck does
    /// not size-control, so this has to sit far above any plausible real
    /// state line rather than at a "typical" size — a few KB is typical, but
    /// this is 1 MiB, chosen so that only a genuinely broken stream (one
    /// that never sends a newline at all) ever trips it. See
    /// `splitLines` for what happens when it's crossed.
    static let maxBufferedLineBytes = 1 << 20

    private let session: String
    private let target: SSHTarget
    private let queue = DispatchQueue(label: "deck.session-state-follower")
    private var process: Process?
    private var buffer = Data()
    /// Set by `stop()`, and checked before yielding `.exited` so a pane that
    /// closes its own follower does not also see that closure reported as an
    /// unexpected exit — the two are different events for the caller: one is
    /// "I asked it to stop," the other is "it died on its own."
    private var stopped = false
    private var finished = false

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    init(session: String, target: SSHTarget) {
        self.session = session
        self.target = target
        var continuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    /// Launches the process. Never throws: a session name ssh would reject,
    /// or a missing `ssh` binary, is reported as `.exited(status: nil)` on
    /// `events` instead, so a caller consuming the stream has exactly one
    /// place to learn "this follower is done," whether it never started or
    /// ran for an hour first.
    func start() {
        // A `stop()` that landed before this ever ran — the pane opened and
        // closed within the gap between `Task.detached` being scheduled and
        // actually running. Not launching at all is the safe response; see
        // the check after `process.run()` below for the symmetric case where
        // `stop()` lands WHILE this is running.
        guard !(queue.sync { stopped }) else { return }

        let argv: [String]
        do {
            argv = try SessionAgent.stateArguments(target: target, session: session, follow: true)
        } catch {
            finishWithExit(nil)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = argv
        let out = Pipe()
        process.standardOutput = out
        // Discarded. A read failure on the mini is YIELDED as a JSON line
        // carrying `state: "unknown"`, not raised to stderr, so nothing on
        // stderr is worth a reader here.
        process.standardError = Pipe()
        // `state --follow` takes no stdin; giving it its own empty pipe
        // rather than leaving it unset keeps it fully detached from Deck's
        // own stdin.
        process.standardInput = Pipe()

        let fallbackSession = session
        let followerQueue = queue
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            followerQueue.async { [weak self] in
                self?.handleData(data, fallbackSession: fallbackSession)
            }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            followerQueue.async { [weak self] in self?.handleTermination(status) }
        }

        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            finishWithExit(nil)
            return
        }
        // ASSIGNING `self.process` AND CHECKING `stopped` HAPPEN UNDER THE
        // SAME LOCK, which is what closes the race `stop()` could otherwise
        // win: if a `stop()` in between `process.run()` succeeding and this
        // line landed while `process` was still nil, it had nothing to
        // terminate and would have leaked exactly this process. Checking
        // again here, atomically with the assignment, means a `stop()`
        // that arrived in that gap gets honoured now instead of losing the
        // race silently.
        let killedAlready: Bool = queue.sync {
            if stopped { return true }
            self.process = process
            return false
        }
        if killedAlready {
            process.terminationHandler = nil
            out.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
    }

    private func handleData(_ data: Data, fallbackSession: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Empty means EOF: the pipe closed because the process is exiting.
        // `terminationHandler` reports the exit itself; there is nothing to
        // decode here.
        guard !data.isEmpty else { return }
        let (lines, remainder, didOverflow) = SessionStateFollower.splitLines(
            buffer: buffer, appending: data)
        buffer = remainder
        for line in lines {
            guard let state = SessionAgent.decodeFollowLine(line, fallbackSession: fallbackSession)
            else { continue }
            continuation.yield(.state(state))
        }
        if didOverflow {
            continuation.yield(.overflow)
        }
    }

    private func handleTermination(_ status: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        process = nil
        finishWithExit(status)
    }

    private func finishWithExit(_ status: Int32?) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            continuation.yield(.exited(status: status))
            continuation.finish()
        }
    }

    /// Terminates the process. Idempotent — safe to call from the pane
    /// closing and from `deinit` both, and safe even if the process happened
    /// to die on its own at the same moment.
    ///
    /// THIS IS WHAT KEEPS THE PROCESS FROM OUTLIVING THE PANE. A `Process`
    /// is not tied to the life of the Swift object that spawned it — nothing
    /// in Foundation does that — so a caller that drops this type without
    /// calling `stop()` leaks a live `ssh` and a live `session-agent` on the
    /// mini, and nothing on screen says so.
    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            if let process {
                process.terminationHandler = nil
                (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
            }
            process = nil
            if !finished {
                finished = true
                continuation.finish()
            }
        }
    }

    /// Splits a byte buffer into complete, newline-terminated lines and the
    /// leftover partial line — so a JSON object split across two `read()`
    /// chunks, two objects landing in one chunk, and a trailing partial line
    /// all come out the same way. Static and pure, so it is testable without
    /// a process.
    ///
    /// `didOverflow` is `true` when a line (complete or still-pending) grew
    /// past `maxBufferedLineBytes`. That line is DROPPED rather than
    /// returned, and — for a still-pending one — the buffer is CLEARED
    /// rather than kept, which is the resync: an oversized line, or a stream
    /// that never sends a newline at all, gets its bytes discarded up to
    /// (and including) the next newline that shows up, instead of holding
    /// onto an ever-growing buffer for the follower's whole lifetime.
    /// Discarding here, rather than tearing the connection down, matters:
    /// if the mini re-emits the very same oversized line on reconnect, a
    /// teardown-based response would reconnect, hit the same overflow, and
    /// reconnect again forever. Dropping and resyncing has no such loop —
    /// the caller only needs to notice if it keeps happening.
    static func splitLines(
        buffer: Data, appending chunk: Data
    ) -> (lines: [String], remainder: Data, didOverflow: Bool) {
        var combined = buffer
        combined.append(chunk)
        var lines: [String] = []
        var didOverflow = false
        let newline = UInt8(ascii: "\n")
        while let index = combined.firstIndex(of: newline) {
            let lineData = combined[combined.startIndex..<index]
            if lineData.count > maxBufferedLineBytes {
                didOverflow = true
            } else if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
            combined.removeSubrange(combined.startIndex...index)
        }
        if combined.count > maxBufferedLineBytes {
            didOverflow = true
            combined.removeAll()
        }
        return (lines, combined, didOverflow)
    }
}
