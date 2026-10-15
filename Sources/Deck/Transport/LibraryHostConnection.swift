import Foundation

/// One host's mutual-TLS forward plus the bearer token read over it —
/// CQ·162's "read from the host over ssh into memory once per host
/// connection and is never written to disk on the laptop." The connection,
/// not the request, is the unit a token is cached against: every request
/// this host's forward carries while it stays open reuses the one read.
/// `@unchecked Sendable`: `lock` is the actual synchronization for
/// `cachedTokens`, the same discipline `SSHConnectionGate` and `TransportLog`
/// already use for the identical shape.
final class LibraryHostConnection: @unchecked Sendable {
    let forward: LibraryForward
    private let target: SSHTarget
    /// Keyed by token file rather than holding one string, because
    /// `LibraryClient` reads two different credentials
    /// (`WorkingCopyStore.libraryTokenFile` and `.libraryApprovalTokenFile`)
    /// over the same forward — see that file's doc for why the two must
    /// never be confused.
    private var cachedTokens: [String: String] = [:]
    private let lock = NSLock()

    init(target: SSHTarget, forward: LibraryForward) {
        self.target = target
        self.forward = forward
    }

    /// The token at `tokenFile`, read over ssh exactly once for the life of
    /// this connection and held in memory only — never written to a file on
    /// this Mac, matching `WorkingCopyStore.libraryTokenFile`'s own doc for
    /// why the existing path already avoids argv but still reads the file
    /// fresh on the host each time; this path additionally avoids the
    /// repeat read, since a mutual-TLS connection is long-lived rather than
    /// one ssh invocation per request.
    func bearerToken(tokenFile: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedTokens[tokenFile] { return cached }
        let data = try SessionAgent.run(
            try Self.readTokenArguments(target: target, tokenFile: tokenFile), classifyMissingCommand: false)
        let token = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cachedTokens[tokenFile] = token
        return token
    }

    /// `tokenFile` is one of two compiled-in constants, never operator text,
    /// so it reaches this remote command the same way `remoteGETCommand`
    /// embeds it in a heredoc — safe for the identical reason that function
    /// states.
    /// The user and address are validated before they reach the destination
    /// token, the same check `libraryForwardArguments` and `sshArguments`
    /// run, so a config-sourced host cannot smuggle an option in.
    static func readTokenArguments(
        target: SSHTarget, tokenFile: String, controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        return withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            "cat \(tokenFile) 2>/dev/null",
        ], home: home)
    }

    /// Tears down the forward — `-O cancel`, never a bare process kill, per
    /// `LibraryForward.stop()`'s own doc.
    func close() {
        forward.stop()
    }
}

/// One `LibraryHostConnection` per host, created on first use and reused by
/// every later call against the same target — the "one host connection" a
/// bearer token is cached per, and the one ssh forward a host's requests
/// multiplex onto rather than opening a new one per call.
/// `@unchecked Sendable`, same reason as `LibraryHostConnection` above.
final class LibraryHostConnectionPool: @unchecked Sendable {
    static let shared = LibraryHostConnectionPool()

    private var connections: [SSHTarget: LibraryHostConnection] = [:]
    private let lock = NSLock()

    func connection(for target: SSHTarget) throws -> LibraryHostConnection {
        lock.lock()
        defer { lock.unlock() }
        if let existing = connections[target] { return existing }
        let forward = try LibraryForward.start(target: target)
        let made = LibraryHostConnection(target: target, forward: forward)
        connections[target] = made
        return made
    }

    /// Torn down when the host goes away (`ThemeStore.removeHost`), and when a
    /// request through the forward fails at the transport, since a forward
    /// riding a master that died or was cleared is gone with it. The next
    /// call then opens a fresh forward and reads the token again.
    func close(_ target: SSHTarget) {
        lock.lock()
        defer { lock.unlock() }
        connections.removeValue(forKey: target)?.close()
    }

    func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        let existing = connections
        connections.removeAll()
        existing.values.forEach { $0.close() }
    }
}
