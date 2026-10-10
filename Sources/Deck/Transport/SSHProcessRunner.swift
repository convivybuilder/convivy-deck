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
        // doing — including the two blocking reads below. A no-op once the
        // process has already exited: `terminate()` only signals a child
        // `Process` still reports as running, so a normal fast exit races
        // this harmlessly and always wins.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(
            data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        watchdog.cancel()

        // A process the watchdog killed exits via SIGTERM, which Foundation
        // reports as `.uncaughtSignal` — ssh has no other reason to die by
        // signal, so this is a clean, race-free way to tell "the watchdog
        // killed it" apart from "it happened to exit right as the timer
        // fired": `cancel()` on a `DispatchWorkItem` that has already started
        // running does not stop it, so the work item's own cancelled flag
        // cannot be trusted for this, but `terminationReason` reflects what
        // actually happened to the process rather than what we asked for.
        let timedOut = process.terminationReason == .uncaughtSignal
        return SSHProcessOutcome(
            stdout: stdoutData, stderr: stderrText,
            terminationStatus: process.terminationStatus, timedOut: timedOut)
    }
}
