import Foundation

/// What one bounded `/usr/bin/ssh` invocation produced.
struct SSHProcessOutcome {
    let stdout: Data
    let stderr: String
    let terminationStatus: Int32
    /// True when THIS invocation was killed by the watchdog rather than
    /// exiting on its own — see `SSHProcessRunner.run`'s doc for the failure
    /// shape that exists to bound.
    let timedOut: Bool
}

/// Accumulates one process's stderr as it arrives and flags the instant it
/// reads as a master-full refusal (`SSHStderrClassifier`) — the live
/// counterpart to reading stderr only after the process exits, which is
/// what let the 26.4s direct-connection fallback CQ·164 closes run to
/// completion unnoticed. `@unchecked Sendable`: `lock` is the actual
/// synchronisation, held across every read and write of `accumulated`/
/// `killedForMasterFull`, so the two threads that touch this (the
/// readability handler's background queue, and `SSHProcessRunner.run`'s own
/// thread after the process exits) never see a value the other is mid-write
/// on.
private final class StderrWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulated = Data()
    private var killedForMasterFull = false

    /// Appends `chunk` and reports whether THIS call is the one that just
    /// crossed into a master-full classification — true at most once per
    /// instance, which is what keeps a caller from calling `terminate()` on
    /// an already-terminating process over and over as more bytes arrive.
    func appendAndCheckMasterFull(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        accumulated.append(chunk)
        guard !killedForMasterFull,
              SSHStderrClassifier.classify(String(data: accumulated, encoding: .utf8) ?? "")
                == .transientMuxRefusal
        else { return false }
        killedForMasterFull = true
        return true
    }

    func snapshot() -> (text: String, killedForMasterFull: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (String(data: accumulated, encoding: .utf8) ?? "", killedForMasterFull)
    }
}

enum SSHProcessRunner {
    /// Runs `/usr/bin/ssh` with `argv`, killing it after `timeout` seconds if
    /// it has not exited on its own.
    ///
    /// THE BOUND THAT DID NOT EXIST BEFORE THIS. Every ssh invocation in this
    /// codebase used to call `Process.waitUntilExit()` with nothing beside
    /// it — fine while ssh always eventually exits, and wrong for the one
    /// case that started this: a ControlMaster whose local mux socket still
    /// accepts a connection but never completes the multiplexing handshake,
    /// because the master is blocked on a transport that died under it (a
    /// laptop sleep/wake that dropped the underlying TCP session without the
    /// master noticing). Reproduced by hand for the PR that added this: a
    /// listening AF_UNIX socket that `accept()`s a connection and then never
    /// writes a byte back hangs a plain `ssh -o ControlPath=<that socket>`
    /// call the same way it hangs `ssh -O check` against the same socket,
    /// indefinitely, with zero output on either stream. Neither
    /// `ConnectTimeout` nor `ControlMaster=auto`'s own stale-socket recovery
    /// (which does fire, reliably, for a socket file nothing is listening on
    /// — see `SSHControlSocket`'s doc) bounds this, because the local IPC
    /// `connect()` succeeds; there is no "connect" step left to time out on.
    /// Nothing but a caller-side timer on the whole child process closes
    /// that gap.
    ///
    /// `environment` replaces the child's environment when given, and is nil
    /// for every existing caller, so they inherit Deck's own. Pairing uses it
    /// to hand one ssh call its askpass settings and the password, without
    /// either reaching argv.
    static func run(_ argv: [String], stdin: String? = nil,
                    timeout: TimeInterval,
                    executable: String = "/usr/bin/ssh",
                    environment: [String: String]? = nil) throws -> SSHProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = argv
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        process.standardInput = input

        try process.run()
        if let stdin, let data = stdin.data(using: .utf8) {
            input.fileHandleForWriting.write(data)
        }
        input.fileHandleForWriting.closeFile()

        // Fires on a background queue regardless of what this thread is
        // doing — including the blocking stdout read below. A no-op once the
        // process has already exited: `terminate()` only signals a child
        // `Process` still reports as running, so a normal fast exit races
        // this harmlessly and always wins.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Watched LIVE, not just read at the end, so a master-full refusal
        // can be cut off the instant ssh announces it rather than waiting
        // out the full direct connection `ControlMaster=auto` is about to
        // fall back to — CQ·164's own diagnosis measured that fallback alone
        // at 26.4s. `StderrWatch` guards its own state against the race
        // between this handler (fired on a background queue as bytes
        // arrive) and the main sequence below reading it back after the
        // process exits.
        let stderrWatch = StderrWatch()
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if stderrWatch.appendAndCheckMasterFull(chunk), process.isRunning {
                process.terminate()
            }
        }

        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        err.fileHandleForReading.readabilityHandler = nil

        let (stderrText, wasKilledForMasterFull) = stderrWatch.snapshot()

        // A process the watchdog killed, OR one killed early on detecting a
        // master-full refusal above, exits via SIGTERM, which Foundation
        // reports as `.uncaughtSignal` — ssh has no other reason to die by
        // signal, so this is a clean, race-free way to tell "something here
        // killed it" apart from "it happened to exit right as the timer
        // fired": `cancel()` on a `DispatchWorkItem` that has already started
        // running does not stop it, so the work item's own cancelled flag
        // cannot be trusted for this, but `terminationReason` reflects what
        // actually happened to the process rather than what we asked for.
        // `wasKilledForMasterFull` is excluded here deliberately: that kill
        // is not "ssh did not respond," it is ssh responding with exactly
        // the refusal `SSHProcessRunner.runQueued` requeues on, and the two
        // must read as different things to a caller.
        let timedOut = process.terminationReason == .uncaughtSignal && !wasKilledForMasterFull
        return SSHProcessOutcome(
            stdout: stdoutData, stderr: stderrText,
            terminationStatus: process.terminationStatus, timedOut: timedOut)
    }

    /// Runs one ssh call through the shared per-control-path gate
    /// (`SSHConnectionGate`), so Deck's own concurrency through one
    /// ControlMaster never asks sshd for more channels than
    /// `SSHConnectionGate.defaultCap` budgets for. `SessionAgent.run` calls
    /// this instead of `run` directly, which covers every one-shot verb
    /// behind it plus the Library composers (`LibraryClient`,
    /// `WorkingCopyStore`) that call `SessionAgent.run` themselves —
    /// CQ·164's "one-shot calls queue FIFO" bucket.
    ///
    /// `argv` carrying no shared control socket at all — a control command
    /// (`-O check`/`-O cancel`), a local config dump (`-G`), or an explicit
    /// `ControlPath=none` (`HostPairing`'s first-contact probe) — skips the
    /// gate entirely and runs exactly as `run` always has, via
    /// `SSHConnectionGate.Key.from(argv:)` returning nil: none of those
    /// opens a new session on a ControlMaster, so none of them is what
    /// `MaxSessions` bounds.
    ///
    /// A GATED CALL NEVER FALLS BACK TO A DIRECT CONNECTION. ssh's own
    /// stderr wording for a refused mux session, or for the fallback itself
    /// ("disabling multiplexing") — both read by `SSHStderrClassifier` as
    /// `.transientMuxRefusal` — releases this call's slot and sends it back
    /// to the end of the queue instead of returning the fallback's eventual
    /// answer, however it exits. Bounded by `MuxRefusalAbsorptionPolicy`'s
    /// own retry budget, the same policy every interactive pane already
    /// uses to absorb this exact refusal, so a connection that keeps
    /// refusing past that budget throws `SSHConnectionGateError.masterFull`
    /// rather than being read as a slow success.
    ///
    /// `run` IS INJECTABLE, defaulting to the real `SSHProcessRunner.run`,
    /// so tests can pin the retry/requeue behaviour against a fake outcome
    /// sequence with no real ssh involved — see `SSHConnectionGateTests`.
    static func runQueued(
        _ argv: [String], stdin: String? = nil,
        timeout: TimeInterval,
        queueTimeout: TimeInterval = SSHConnectionGate.defaultQueueTimeout,
        gate: SSHConnectionGate = .shared,
        run: (_ argv: [String], _ stdin: String?, _ timeout: TimeInterval) throws -> SSHProcessOutcome
            = { argv, stdin, timeout in try SSHProcessRunner.run(argv, stdin: stdin, timeout: timeout) }
    ) throws -> SSHProcessOutcome {
        guard let key = SSHConnectionGate.Key.from(argv: argv) else {
            return try run(argv, stdin, timeout)
        }
        let cap = gate.cap(forDestination: key.destination)
        var absorption = MuxRefusalAbsorptionPolicy()
        while true {
            try gate.acquire(key, cap: cap, queueTimeout: queueTimeout)
            let outcome: SSHProcessOutcome
            do {
                outcome = try run(argv, stdin, timeout)
            } catch {
                gate.release(key)
                throw error
            }
            guard SSHStderrClassifier.classify(outcome.stderr) == .transientMuxRefusal else {
                absorption.succeeded()
                gate.release(key)
                return outcome
            }
            gate.release(key)
            guard absorption.shouldAbsorb(classification: .transientMuxRefusal) else {
                throw SSHConnectionGateError.masterFull
            }
            // Requeued: back to `acquire`'s own FIFO line rather than an
            // immediate retry, so a run of refusals paces itself against
            // whatever else is actually draining the master instead of
            // hammering it.
        }
    }
}
