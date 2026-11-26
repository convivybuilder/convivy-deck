import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Whether a host has Builder's server installed, as Deck last read it
/// (E22, CQ·158). Settings › Hosts marks a `.missing` host and offers the
/// install from its row; nothing else in Deck reads it.
enum BuilderServerState: Equatable {
    case installed
    case missing
}

/// Folds one `session-agent` outcome into a host's `BuilderServerState`.
///
/// ONLY `SessionAgent.AgentError.notInstalled` READS AS MISSING. That is the
/// one failure whose meaning is "the command is not there"; an ssh failure,
/// a timeout or a refusal from a `session-agent` that did run says nothing
/// about whether Builder is installed, so it keeps whatever was last known
/// rather than offering an install onto a host that already has one.
enum BuilderServerTracker {
    static func apply<T>(_ outcome: Result<T, Error>, lastKnown: BuilderServerState?) -> BuilderServerState? {
        switch outcome {
        case .success:
            return .installed
        case .failure(let error):
            return isNotInstalled(error) ? .missing : lastKnown
        }
    }

    static func isNotInstalled(_ error: Error) -> Bool {
        (error as? SessionAgent.AgentError) == .notInstalled
    }
}

/// How Deck installs Builder's server: the published installer, at its
/// current release, with no steps of Deck's own (E22's specification), run
/// in a terminal pane over the host's ssh connection (CQ·160). `setupArguments`
/// (CQ·200) composes `command` with Claude Code's install and sign-in into
/// the one setup pane a host missing those also needs.
enum BuilderServerInstall {
    static let command = "curl -fsSL https://convivybuilder.org/install.sh | sh"

    /// `commands` joined with `&&` so each runs only if the one before it
    /// succeeded, and the pane exits with the failing step's own status.
    ///
    /// `pipefail` IS WHAT MAKES THAT TRUE OF A DOWNLOAD. Two steps are
    /// `curl … | shell`, whose status is otherwise the shell's: when curl
    /// fails the shell reads an empty script and exits 0, so the next step
    /// runs and the pane reports the wrong step. Measured on builder-check,
    /// 2026-11-06: a failed `curl | bash && echo` ran the echo.
    ///
    /// `$HOME/.local/bin` goes on PATH because Claude Code's installer puts
    /// `claude` there, and a login shell started before that step ran may
    /// not have picked it up yet.
    static func chain(commands: [String]) -> String {
        let joined = commands.joined(separator: " && ")
        return #"set -o pipefail; export PATH="$HOME/.local/bin:$PATH"; \#(joined)"#
    }

    /// `steps` composed by `chain`, run through the user's LOGIN shell for
    /// the reason `PreInstallCheck.claudeCommand` gives. The Builder
    /// installer also refuses a host where `command -v claude` fails. None
    /// of the fixed step text has a single quote to escape.
    ///
    /// `githubAppPort` is the only varying part of any step's text: when
    /// non-nil, `.installBuilderServer`'s command gets Shipwright's
    /// `-s -- --github-app-port <n>` appended (shipwright PR 295, Builder
    /// 0.7.1), passed straight to `create-github-app --port <n>`; every
    /// other step's text, and this one's when `githubAppPort` is nil, is
    /// unchanged fixed text.
    static func remoteCommand(steps: [SetupStep], githubAppPort: UInt16? = nil) -> String {
        let commands = steps.map { step -> String in
            guard step == .installBuilderServer, let port = githubAppPort else { return step.command }
            return "\(step.command) -s -- --github-app-port \(port)"
        }
        return #"exec "$SHELL" -lc '\#(chain(commands: commands))'"#
    }

    /// `githubAppPort` only when `steps` actually runs the installer step it
    /// is for — the single place both `setupArguments`'s `-L` and
    /// `remoteCommand`'s flag decide whether to forward at all, so the two
    /// can never disagree about it.
    static func forwardedPort(steps: [SetupStep], requested: UInt16?) -> UInt16? {
        steps.contains(.installBuilderServer) ? requested : nil
    }

    /// ssh argv for the setup pane. `-t` because sudo, on a Linux host with
    /// password sudo, reads its password from a terminal (Shipwright, E22's
    /// thread), and so does a sign-in step's confirmation. The remote
    /// command is `steps` composed by `remoteCommand`, fixed text, passed
    /// as one argument for the remote shell to run; only the validated
    /// `user@host` varies.
    ///
    /// `ControlPath=none` rather than the shared master, for the same reason
    /// `sshArguments` carries it (CQ·165): this is a `-t` pane too, so a
    /// stalled setup terminal must not be able to freeze every other ssh
    /// call on the host.
    ///
    /// `githubAppPort`, when `steps` includes `.installBuilderServer`, adds
    /// `-L <port>:127.0.0.1:<port>` so the installer's `create-github-app`
    /// page, served on the HOST's own loopback, reaches this Mac's browser
    /// (CQ·202) — and `ExitOnForwardFailure=yes`, so a lost race against
    /// `reserveGithubAppPort`'s own narrow window (another process claiming
    /// the port first) fails the pane outright rather than running the
    /// install with a forward that silently never worked. The port is the
    /// only varying part this adds; everything else here is fixed text,
    /// same as before this parameter existed.
    static func setupArguments(
        target: SSHTarget,
        steps: [SetupStep],
        githubAppPort: UInt16? = nil,
        home: String = NSHomeDirectory()
    ) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        let port = forwardedPort(steps: steps, requested: githubAppPort)
        var argv = [
            "-t",
            "-o", "ControlPath=none",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        if let port {
            argv += ["-L", "\(port):127.0.0.1:\(port)", "-o", "ExitOnForwardFailure=yes"]
        }
        argv += ["\(user)@\(host)", remoteCommand(steps: steps, githubAppPort: port)]
        return withDeckIdentity(argv, home: home)
    }

    enum PortReservationError: Error, CustomStringConvertible, Equatable {
        case couldNotReserveLocalPort(String)

        var description: String {
            switch self {
            case .couldNotReserveLocalPort(let message): return message
            }
        }
    }

    /// A local TCP port the OS confirms is free at the moment of the check,
    /// for `create-github-app`'s page — the same narrow, documented race
    /// `KeelForward.reserveEphemeralLocalPort` accepts (see its doc): the
    /// probe socket is closed before ssh binds the same number, so another
    /// process could in principle claim it first. `setupArguments`'s own
    /// `ExitOnForwardFailure=yes` is what turns a lost race into the pane
    /// failing outright rather than a silently useless forward.
    static func reserveGithubAppPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PortReservationError.couldNotReserveLocalPort(
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
            throw PortReservationError.couldNotReserveLocalPort(
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
            throw PortReservationError.couldNotReserveLocalPort(
                "getsockname() failed: \(String(cString: strerror(errno)))")
        }
        return CFSwapInt16BigToHost(bound.sin_port)
    }

    /// How a finished install reads. SUCCESS IS DECIDED BY THE RE-PROBE,
    /// not the exit status alone: `curl … | sh` reports `sh`'s status, so a
    /// download that fails hands `sh` nothing and still exits 0.
    enum Outcome: Equatable {
        case installed
        case exitedWithoutServer
        case failed(exitCode: Int32?)
    }

    static func outcome(exitCode: Int32?, serverFound: Bool) -> Outcome {
        guard exitCode == 0 else { return .failed(exitCode: exitCode) }
        return serverFound ? .installed : .exitedWithoutServer
    }

    /// Whether a host's row offers the install. An unknown state (not yet
    /// polled, or only ever unreachable) offers nothing.
    static func offersInstall(_ state: BuilderServerState?) -> Bool {
        state == .missing
    }
}
