import Foundation

/// One per-run read of the run register, shared by every section of the run
/// pane that needs one: `RunGivenDocuments` reads `/runs/<id>/docs_given` and
/// `RunFetchedDocuments` reads `/runs/<id>/docs_fetched`, both through here.
///
/// THE READ GOES THROUGH THE REGISTER'S SOCKET, not the run directory over ssh.
/// The register applies the private-crew gate that `/runs` applies, and a raw
/// read of the run directory would skip it.
enum RunRegisterRead {
    /// `curl` against the register's socket for one route of one run, over the
    /// ssh ControlMaster every other register read rides. `-f` turns an HTTP
    /// error, such as a register that predates the route, into a non-zero
    /// exit. The run id is checked against a charset with no shell
    /// metacharacters, because it is spliced into the remote command.
    static func arguments(target: SSHTarget, runId: String, route: String,
                          controlPath: String = defaultControlPath(),
                          home: String = NSHomeDirectory()) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        let id = try validateRunId(runId)
        let remoteCommand = "curl -sS -f -m 5 --unix-socket \"$HOME/.local/run/run-register-api.sock\" "
            + "http://x/runs/\(id)/\(route)"
        return withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            remoteCommand,
        ], home: home)
    }

    static func validateRunId(_ runId: String) throws -> String {
        guard !runId.isEmpty, runId.count <= 64,
              runId.unicodeScalars.allSatisfy(allowedRunIdCharacters.contains) else {
            throw SessionAgent.AgentError.failed("the run id \(runId) is not one Deck will ask the register about")
        }
        return runId
    }

    private static let allowedRunIdCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// The register's answer body for one route of one run. Throws when the
    /// ssh round trip or the curl exits non-zero.
    static func run(target: SSHTarget, runId: String, route: String) throws -> Data {
        try SessionAgent.run(try arguments(target: target, runId: runId, route: route),
                             classifyMissingCommand: false,
                             staleSocketRecovery: (target: target,
                                                   controlPath: defaultControlPath()))
    }
}
