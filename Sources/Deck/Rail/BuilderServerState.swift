import Foundation

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
/// in a terminal pane over the host's ssh connection (CQ·160).
enum BuilderServerInstall {
    static let command = "curl -fsSL https://convivybuilder.org/install.sh | sh"

    /// ssh argv for the install. `-t` because sudo, on a Linux host with
    /// password sudo, reads its password from a terminal (Shipwright, E22's
    /// thread). The remote command is `command`, fixed text, passed as one
    /// argument for the remote shell to run; only the validated `user@host`
    /// varies.
    ///
    /// `ControlPath=none` rather than the shared master, for the same reason
    /// `sshArguments` carries it (CQ·165): this is a `-t` pane too, so a
    /// stalled installer terminal must not be able to freeze every other ssh
    /// call on the host.
    static func arguments(
        target: SSHTarget,
        home: String = NSHomeDirectory()
    ) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        return withDeckIdentity([
            "-t",
            "-o", "ControlPath=none",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            command,
        ], home: home)
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
