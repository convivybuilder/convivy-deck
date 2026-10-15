import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// argv for a persistent local-TCP-port-to-remote-TCP-port forward:
/// `ssh -N -L 127.0.0.1:<local port>:127.0.0.1:<remote port> user@host`.
///
/// A BYTE FORWARD, NEVER A PROXY. `platform/decisions/0066`'s "An SSH or
/// Tailscale forward is not a proxy" is the property this depends on: `-L`
/// moves bytes, and the TLS session Deck opens through the resulting local
/// port runs end to end to the Library — nothing here terminates it. A
/// Tailscale `serve` HTTPS handler or any other TLS-terminating proxy would
/// end channel binding, which is why neither is an option this file offers.
///
/// SHARES `defaultControlPath()` WITH EVERY OTHER SSH CALLER, deliberately —
/// `KeelForward`'s own header names the same reason: multiplexing onto a
/// ControlMaster a tmux pane or another forward already opened costs no new
/// TCP/SSH handshake.
func libraryForwardArguments(
    target: SSHTarget, remotePort: UInt16 = libraryMutualTLSRemotePort, localPort: UInt16,
    controlPath: String = defaultControlPath(),
    home: String = NSHomeDirectory()
) throws -> [String] {
    let user = try validateHostUser(target.user)
    let host = try validateHostAddress(target.host)
    return withDeckIdentity([
        "-N",
        "-o", "ControlMaster=auto",
        "-o", "ControlPersist=10m",
        "-o", "ControlPath=\(controlPath)",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        // The same fail-fast choice `keelForwardArguments` makes, for the
        // same reason: a master that comes up but can never actually bind
        // this `-L` mapping should exit, not sit connected-but-useless.
        "-o", "ExitOnForwardFailure=yes",
        "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)",
        "\(user)@\(host)",
    ], home: home)
}

/// argv for `ssh -O cancel`, dropping this forward's own `-L` mapping without
/// risking the shared ControlMaster — see `KeelForward.stop()`'s doc for why
/// a bare `process.terminate()` is unsafe here and must never replace this.
func libraryCancelForwardArguments(
    target: SSHTarget, remotePort: UInt16 = libraryMutualTLSRemotePort, localPort: UInt16,
    controlPath: String, home: String = NSHomeDirectory()
) throws -> [String] {
    let user = try validateHostUser(target.user)
    let host = try validateHostAddress(target.host)
    return withDeckIdentity([
        "-O", "cancel",
        "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)",
        "-o", "ControlPath=\(controlPath)",
        "\(user)@\(host)",
    ], home: home)
}

/// The Library's mutual-TLS listener, fixed by `platform/decisions/0066`'s
/// "Migration ports: plain HTTP stays on `127.0.0.1:8100`; mutual TLS on
/// `127.0.0.1:8443`" — never operator- or host-specific.
let libraryMutualTLSRemotePort: UInt16 = 8443

enum LibraryForwardError: Error, Equatable, CustomStringConvertible {
    case couldNotReserveLocalPort(String)
    case forwardNeverBecameReady(String)

    var description: String {
        switch self {
        case .couldNotReserveLocalPort(let message), .forwardNeverBecameReady(let message):
            return message
        }
    }
}

/// Holds one ssh process open, forwarding a local TCP port to the Library's
/// mutual-TLS port on one host — `KeelForward`'s structure exactly, carried
/// over rather than generalized into it, because the two forward different
/// shapes (`-L port:remote_socket_path` there, `-L port:127.0.0.1:port` here)
/// and KeelForward's own header already says nothing wires it into a live
/// call site yet; duplicating the lifecycle here rather than reaching into
/// that type keeps CQ·162 from taking on KeelForward's own readiness.
final class LibraryForward {
    let localPort: UInt16
    private let process: Process
    private let target: SSHTarget
    private let remotePort: UInt16
    private let controlPath: String
    private let gateKey: SSHConnectionGate.Key
    private var stopped = false

    private init(
        localPort: UInt16, process: Process, target: SSHTarget,
        remotePort: UInt16, controlPath: String, gateKey: SSHConnectionGate.Key
    ) {
        self.localPort = localPort
        self.process = process
        self.target = target
        self.remotePort = remotePort
        self.controlPath = controlPath
        self.gateKey = gateKey
    }

    /// Reserves a local port, launches the forward, and waits for it to
    /// accept a connection — the same one-retry-through-`SSHControlSocket`
    /// discipline `KeelForward.start` follows, for the identical wedged-
    /// ControlMaster failure. See that function's doc.
    static func start(
        target: SSHTarget, remotePort: UInt16 = libraryMutualTLSRemotePort,
        controlPath: String = defaultControlPath(),
        readinessTimeout: TimeInterval = 5,
        transportLog: TransportLog = .shared
    ) throws -> LibraryForward {
        do {
            return try attempt(target: target, remotePort: remotePort,
                               controlPath: controlPath, readinessTimeout: readinessTimeout)
        } catch {
            let check = SSHControlSocket.check(target: target, controlPath: controlPath, transportLog: transportLog)
            guard check.warrantsClearing else { throw error }
            SSHControlSocket.clear(target: target, controlPath: controlPath, transportLog: transportLog)
            return try attempt(target: target, remotePort: remotePort,
                               controlPath: controlPath, readinessTimeout: readinessTimeout)
        }
    }

    private static func attempt(
        target: SSHTarget, remotePort: UInt16, controlPath: String, readinessTimeout: TimeInterval
    ) throws -> LibraryForward {
        let port = try reserveEphemeralLocalPort()
        let argv = try libraryForwardArguments(
            target: target, remotePort: remotePort, localPort: port, controlPath: controlPath)
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
            throw LibraryForwardError.forwardNeverBecameReady("could not launch ssh: \(error)")
        }
        do {
            try waitUntilReady(port: port, process: process, timeout: readinessTimeout)
        } catch {
            SSHConnectionGate.shared.release(gateKey)
            throw error
        }
        return LibraryForward(
            localPort: port, process: process, target: target,
            remotePort: remotePort, controlPath: controlPath, gateKey: gateKey)
    }

    /// Polls a plain TCP connect against the forward's local port — reusing
    /// `KeelSocket.connect(.forwardedPort(_:))` rather than a second dialer,
    /// since a byte forward's readiness is "something accepts a connection
    /// here" whether the remote end is a unix socket or, as here, a TCP
    /// port. See `KeelForward.waitUntilReady`'s doc for why a bare `connect()`
    /// right after `Process.run()` is not reliable on its own.
    private static func waitUntilReady(port: UInt16, process: Process, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            if !process.isRunning {
                throw LibraryForwardError.forwardNeverBecameReady(
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
        throw LibraryForwardError.forwardNeverBecameReady(
            "the forward never accepted a connection within \(timeout)s\(detail)")
    }

    /// A local TCP port the OS confirms is free at the moment of the check —
    /// the same narrow, documented race `KeelForward.reserveEphemeralLocalPort`
    /// accepts, for the same reason: handing an open, listening socket off to
    /// a freshly spawned ssh child has no clean POSIX path, so `waitUntilReady`
    /// is what catches the rare case this loses.
    private static func reserveEphemeralLocalPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LibraryForwardError.couldNotReserveLocalPort(
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
            throw LibraryForwardError.couldNotReserveLocalPort(
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
            throw LibraryForwardError.couldNotReserveLocalPort(
                "getsockname() failed: \(String(cString: strerror(errno)))")
        }
        return CFSwapInt16BigToHost(bound.sin_port)
    }

    /// `-O cancel` for this forward's own `-L` mapping, never
    /// `process.terminate()` — see `KeelForward.stop()`'s doc for why that
    /// would be a ControlMaster hazard rather than a cleanup detail; the
    /// reasoning is identical here. Best-effort and silent on failure,
    /// matching `SSHControlSocket.clear`'s own stance.
    func stop() {
        guard !stopped else { return }
        stopped = true
        defer { SSHConnectionGate.shared.release(gateKey) }
        guard let argv = try? libraryCancelForwardArguments(
            target: target, remotePort: remotePort, localPort: localPort, controlPath: controlPath)
        else { return }
        _ = try? SSHProcessRunner.run(argv, timeout: SSHControlSocket.checkTimeout)
    }

    deinit { stop() }
}
