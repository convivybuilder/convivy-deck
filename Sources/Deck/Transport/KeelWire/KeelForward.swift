import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// argv for a persistent local-TCP-port-to-remote-unix-socket forward:
/// `ssh -N -L 127.0.0.1:<port>:<remoteSocketPath> user@host`.
///
/// SHARES `defaultControlPath()` WITH EVERY OTHER SSH CALLER IN THIS
/// CODEBASE, deliberately — `SSHTarget.defaultControlPath`'s own doc
/// comment already names this case: "One ControlMaster socket carries every
/// pane plus the eventual fleetd forward". Multiplexing this forward onto
/// the same master a tmux pane or a render already opened means the first
/// Keel call after a pane is already up costs no new TCP/SSH handshake at
/// all — and a pane opened after this forward is already up gets the same
/// benefit in reverse.
func keelForwardArguments(
    target: SSHTarget, remoteSocketPath: String, localPort: UInt16,
    controlPath: String = defaultControlPath(),
    home: String = NSHomeDirectory()
) throws -> [String] {
    let user = try validateHostUser(target.user)
    let host = try validateHostAddress(target.host)
    // Reuses `validateWorkingDirectory`'s charset rather than inventing a
    // third one for this, and for a reason specific to THIS path: `-L`'s
    // argument is a colon-delimited field (`bind_address:port:host:hostport`,
    // here `127.0.0.1:<port>:<remoteSocketPath>`) that ssh's LOCAL client
    // parses and splits itself before ever opening a connection — a `:` in
    // `remoteSocketPath` would let a hostile path inject an extra field into
    // that local parse, not "reach a remote shell" (there is no remote shell
    // in this path at all: sshd receives an already-parsed path and
    // `connect()`s to it directly). A `%` is excluded for a different local
    // reason — ssh expands its own tokens (`%h`, `%r`, ...) inside strings
    // like this one. `validateWorkingDirectory`'s charset — letters, digits,
    // `._-/~`, no `..`, absolute or home-relative — already excludes both,
    // which is what makes it the right gate to reuse here, and it already
    // fits a unix-socket path like `~/.local/run/run-register-api.sock`.
    let path = try validateWorkingDirectory(remoteSocketPath)
    return withDeckIdentity([
        // No remote command — this ssh process exists only to hold a
        // forward open.
        "-N",
        "-o", "ControlMaster=auto",
        "-o", "ControlPersist=10m",
        "-o", "ControlPath=\(controlPath)",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        // Fails fast rather than starting a master that never actually
        // forwards anything: `KeelForward.attempt`'s readiness poll is what
        // turns a SLOW bind into a bounded wait, but this is what turns an
        // outright-refused one (e.g. the remote socket path does not exist)
        // into ssh exiting instead of sitting connected-but-useless.
        "-o", "ExitOnForwardFailure=yes",
        "-L", "127.0.0.1:\(localPort):\(path)",
        "\(user)@\(host)",
    ], home: home)
}

enum KeelForwardError: Error, Equatable, CustomStringConvertible {
    case couldNotReserveLocalPort(String)
    case forwardNeverBecameReady(String)

    var description: String {
        switch self {
        case .couldNotReserveLocalPort(let message), .forwardNeverBecameReady(let message):
            return message
        }
    }
}

/// Holds one ssh process open, forwarding a local TCP port to a remote
/// unix-domain socket — the production path `KeelClient` dials through
/// `.forwardedPort(_:)`. See `KeelConnection`'s doc for why a forwarded TCP
/// port is the production shape at all: Deck normally runs on the laptop,
/// remote from wherever the Keel's socket lives.
///
/// NOTHING IN DECK STARTS ONE OF THESE FOR A REAL CALL YET — no verb this
/// wire could carry has a producer serving it (see `KeelClient`'s own file
/// header). This exists so the mechanism is built, live-tested at the
/// pieces that can be, and ready the day a verb needs it.
final class KeelForward {
    let localPort: UInt16
    private let process: Process
    private let target: SSHTarget
    private let remoteSocketPath: String
    private let controlPath: String
    /// This forward's own slot in `SSHConnectionGate` for as long as it
    /// holds its `-N` process open — one of CQ·164's LONG-LIVED HOLDERS,
    /// released exactly once by `stop()`.
    private let gateKey: SSHConnectionGate.Key
    private var stopped = false

    private init(
        localPort: UInt16, process: Process, target: SSHTarget,
        remoteSocketPath: String, controlPath: String, gateKey: SSHConnectionGate.Key
    ) {
        self.localPort = localPort
        self.process = process
        self.target = target
        self.remoteSocketPath = remoteSocketPath
        self.controlPath = controlPath
        self.gateKey = gateKey
    }

    /// Reserves a local port, launches the forward, and waits for it to
    /// actually accept a connection before returning — so a caller holding
    /// a `KeelForward` has a real, dialable forward rather than a process
    /// that might still be negotiating the ssh handshake.
    ///
    /// ONE RETRY, THROUGH `SSHControlSocket`, ONLY ON A FAILED FIRST
    /// ATTEMPT — the same discipline `SessionAgent.run`'s
    /// `staleSocketRecovery` parameter follows for the tmux/render paths. A
    /// wedged ControlMaster (the mux socket accepts a connection and never
    /// completes the handshake — reproduced by hand, see
    /// `SSHProcessRunner.run`'s own doc for the failure this guards) is
    /// exactly the shape of failure that would otherwise leave a forward
    /// attempt hanging or silently unusable; `SSHControlSocket.check`/
    /// `.clear` is the existing, tested mechanism for recognising and
    /// clearing that, reused here rather than reimplemented. THIS IS WHAT
    /// MAKES A STALE FORWARD SURFACE AS `KeelForwardError`/`KeelError
    /// .transport` RATHER THAN HANG: `attempt`'s own readiness poll is
    /// itself bounded (`readinessTimeout`), so even with no stale-socket
    /// recovery available this method cannot wait past twice that bound.
    static func start(
        target: SSHTarget, remoteSocketPath: String,
        controlPath: String = defaultControlPath(),
        readinessTimeout: TimeInterval = 5,
        transportLog: TransportLog = .shared
    ) throws -> KeelForward {
        do {
            return try attempt(target: target, remoteSocketPath: remoteSocketPath,
                               controlPath: controlPath, readinessTimeout: readinessTimeout)
        } catch {
            // THE SAME CHECK-AND-CLEAR DECISION `SessionAgent.run`'s
            // `staleSocketRecovery` makes, reused rather than duplicated —
            // see its own doc. `check`/`clear` log themselves, so this
            // forward's attempt is covered the same way every other caller
            // of either is.
            let check = SSHControlSocket.check(target: target, controlPath: controlPath, transportLog: transportLog)
            guard check.warrantsClearing else { throw error }
            SSHControlSocket.clear(target: target, controlPath: controlPath, transportLog: transportLog)
            return try attempt(target: target, remoteSocketPath: remoteSocketPath,
                               controlPath: controlPath, readinessTimeout: readinessTimeout)
        }
    }

    private static func attempt(
        target: SSHTarget, remoteSocketPath: String, controlPath: String, readinessTimeout: TimeInterval
    ) throws -> KeelForward {
        let port = try reserveEphemeralLocalPort()
        let argv = try keelForwardArguments(
            target: target, remoteSocketPath: remoteSocketPath, localPort: port, controlPath: controlPath)
        // Held for this forward's whole life as one of CQ·164's long-lived
        // holders — see `gateKey`'s own doc.
        let gateKey = SSHConnectionGate.Key(
            destination: "\(target.user)@\(target.host)", controlPath: controlPath)
        try SSHConnectionGate.shared.acquire(
            gateKey, cap: SSHConnectionGate.shared.cap(forDestination: gateKey.destination),
            queueTimeout: SSHConnectionGate.defaultQueueTimeout)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = argv
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            SSHConnectionGate.shared.release(gateKey)
            throw KeelForwardError.forwardNeverBecameReady("could not launch ssh: \(error)")
        }
        do {
            try waitUntilReady(port: port, process: process, timeout: readinessTimeout)
        } catch {
            SSHConnectionGate.shared.release(gateKey)
            throw error
        }
        return KeelForward(
            localPort: port, process: process, target: target,
            remoteSocketPath: remoteSocketPath, controlPath: controlPath, gateKey: gateKey)
    }

    /// Polls `connect()` against the just-launched forward's local port
    /// until it succeeds, the ssh process exits (a fast, authoritative
    /// "this forward is never coming up" — `ExitOnForwardFailure=yes` in
    /// `keelForwardArguments` is what makes that exit promptly rather than
    /// sit connected-but-useless), or `timeout` runs out.
    ///
    /// A BARE `connect()` RIGHT AFTER `Process.run()` IS NOT RELIABLE ON ITS
    /// OWN: ssh has not necessarily bound the local listener yet at that
    /// instant, and an attempt that early gets `ECONNREFUSED` rather than a
    /// queued connection — so this retries on a short interval rather than
    /// treating the first refusal as final.
    private static func waitUntilReady(port: UInt16, process: Process, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            if !process.isRunning {
                throw KeelForwardError.forwardNeverBecameReady(
                    "the forward's ssh process exited before its local port became reachable")
            }
            do {
                let fd = try KeelSocket.connect(.forwardedPort(port), timeout: 0.5)
                Darwin.close(fd)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        process.terminate()
        let detail = lastError.map { ": \($0)" } ?? ""
        throw KeelForwardError.forwardNeverBecameReady(
            "the forward never accepted a connection within \(timeout)s\(detail)")
    }

    /// A local TCP port the OS confirms is free at the moment of the check.
    ///
    /// NARROW, DOCUMENTED RACE: the probe socket this function binds is
    /// closed before ssh binds the SAME port number, so another process
    /// could in principle claim it first. Accepted rather than closed off —
    /// handing an already-open, still-listening socket off to a freshly
    /// spawned ssh child is not something POSIX offers a clean way to do,
    /// so this takes the same trade every "find a free port" utility makes.
    /// `waitUntilReady`'s retry loop is what catches the rare case where the
    /// race is lost: ssh fails to bind and exits, which surfaces as a plain
    /// `forwardNeverBecameReady` rather than a silently wrong connection.
    private static func reserveEphemeralLocalPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw KeelForwardError.couldNotReserveLocalPort(
                "socket() failed: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw KeelForwardError.couldNotReserveLocalPort(
                "bind() failed: \(String(cString: strerror(errno)))")
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &bound) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &length)
            }
        }
        guard getResult == 0 else {
            throw KeelForwardError.couldNotReserveLocalPort(
                "getsockname() failed: \(String(cString: strerror(errno)))")
        }
        return CFSwapInt16BigToHost(bound.sin_port)
    }

    /// Best-effort. Sends `ssh -O cancel` for this forward's own `-L`
    /// mapping over the shared control socket rather than calling
    /// `process.terminate()` on the forward's own `ssh -N` process.
    ///
    /// A BARE `terminate()` HERE WOULD BE A CONTROLMASTER HAZARD, not merely
    /// a cleanup detail — this file's own header names why this forward
    /// deliberately shares `defaultControlPath()` with every other ssh
    /// caller in the codebase. IF THIS FORWARD'S OWN `ssh -N` PROCESS IS THE
    /// FIRST SSH CONNECTION TO A GIVEN HOST, `ControlMaster=auto` PROMOTES IT
    /// TO THE MASTER, and every tmux pane and render opened against that
    /// host afterward multiplexes onto it. Killing this process outright
    /// would then take that shared connection down the moment any single
    /// `KeelForward` is stopped — the exact hazard `SSHControlSocket`'s own
    /// doc names for a different operation ("deleting a live master's socket
    /// out from under it would take a working ControlMaster down for every
    /// other pane sharing it, not just the one that happened to check").
    /// `-O cancel` asks whichever process actually holds the control socket
    /// (this one, or another) to drop just this forward's `-L` mapping,
    /// leaving that process — master or not — running either way. DO NOT
    /// SIMPLIFY THIS BACK TO `process.terminate()`.
    ///
    /// Silent on failure, matching `SSHControlSocket.clear`'s own stance. A
    /// caller that never stops a forward, or a cancel that cannot reach an
    /// already-gone control socket, leaves this forward's own ssh process
    /// running until Deck exits — the same lifecycle every
    /// ControlMaster-backed process in this codebase already has, and
    /// acceptable for what this type is used for today (see this type's own
    /// file header: nothing wires it into a live call site yet).
    func stop() {
        guard !stopped else { return }
        stopped = true
        defer { SSHConnectionGate.shared.release(gateKey) }
        guard let argv = try? sshCancelForwardArguments(
            target: target, remoteSocketPath: remoteSocketPath,
            localPort: localPort, controlPath: controlPath)
        else { return }
        _ = try? SSHProcessRunner.run(argv, timeout: SSHControlSocket.checkTimeout)
    }

    deinit { stop() }
}
