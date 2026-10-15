import Foundation

/// The one switch CQ·162's issue body asks for: "one transport switch for
/// all three composers". `LibraryClient`'s GET and POST execution points and
/// `WorkingCopyStore`'s document fetch all call `run(target:argv:stdin:)`
/// instead of calling `SessionAgent.run` on their composed ssh argv
/// directly, so a host's choice of transport is made in exactly one place
/// rather than three that could disagree.
enum LibraryTransportDispatch {
    /// `argv` is the ssh argv the existing path runs completely unchanged —
    /// the same array `LibraryClient.coursesListArguments` and its siblings
    /// have always built. The mutual-TLS path never executes it: it reads
    /// its own method/path/token-file back out of `argv`'s own composed
    /// remote command (`LibraryCurlCommand.parse`) and dials the forward
    /// instead. **That `argv` is built either way, by the caller, before
    /// this function is ever reached, is exactly how CQ·162's "no composer
    /// targets `127.0.0.1:8100` on a mutual-TLS host" is provable from
    /// outside this function**: the production `mutualTLSPath` closure never
    /// calls `existingPath`, so a test that injects a spy for `existingPath`
    /// and a stub for `mutualTLSPath`, with the selector forced to
    /// `.mutualTLS`, proves the spy — the one thing that could reach
    /// `8100` — is never called.
    ///
    /// A FAILURE IN THE MUTUAL-TLS BRANCH IS NEVER RETRIED ON THE EXISTING
    /// ONE. There is no `catch` here that falls through from `mutualTLSPath`
    /// to `existingPath` — a handshake, trust or 401 failure throws out of
    /// this function exactly as thrown, per CQ·162's done conditions.
    static func run(
        target: SSHTarget, argv: [String], stdin: String? = nil,
        selector: LibraryTransportSelector = .shared,
        existingPath: ([String], String?) throws -> Data = { argv, stdin in
            try SessionAgent.run(argv, stdin: stdin, classifyMissingCommand: false)
        },
        mutualTLSPath: (SSHTarget, [String], String?) throws -> Data = runMutualTLS
    ) throws -> Data {
        switch selector.transport(for: target) {
        case .existingPath:
            return try existingPath(argv, stdin)
        case .mutualTLS:
            return try mutualTLSPath(target, argv, stdin)
        }
    }

    /// The production mutual-TLS path. Parses the request back out of its
    /// own composed argv, opens (or reuses) this host's forward and bearer
    /// token, performs the request, and re-encodes the result into the
    /// exact `body\n%{http_code}` shape `WorkingCopyStore.splitCurlStatusResponse`
    /// already parses — **this is "response handling stays shared" from the
    /// issue body**: every decoder in `LibraryClient` and `WorkingCopyStore`
    /// reads a mutual-TLS response exactly as it reads a curl one, with no
    /// branch of its own anywhere downstream of this function.
    static func runMutualTLS(target: SSHTarget, argv: [String], stdin: String?) throws -> Data {
        guard let remoteCommand = argv.last, let parsed = LibraryCurlCommand.parse(remoteCommand) else {
            throw LibraryMutualTLSError.transportFailed(
                "could not read a Library request back out of its own argv")
        }
        guard let identity = LibraryTransportSelector.shared.identityProvider.identity(for: target),
              let anchors = LibraryTransportSelector.shared.anchorProvider.anchorCertificates(for: target)
        else {
            throw LibraryMutualTLSError.noClientIdentity
        }
        let pool = LibraryHostConnectionPool.shared
        let connection = try pool.connection(for: target)
        let token = try connection.bearerToken(tokenFile: parsed.tokenFile)
        var headers = ["Library-Protocol": "1", "Authorization": "Bearer \(token)"]
        if stdin != nil { headers["Content-Type"] = "application/json" }
        guard let baseURL = URL(string: "https://localhost:\(connection.forward.localPort)") else {
            throw LibraryMutualTLSError.transportFailed("could not build a URL for the forwarded port")
        }
        let status: Int
        let body: Data
        do {
            (status, body) = try LibraryMutualTLSClient.perform(
                method: parsed.method, baseURL: baseURL, path: parsed.path, headers: headers,
                body: stdin.map { Data($0.utf8) }, identity: identity, anchors: anchors)
        } catch let error as LibraryMutualTLSError {
            // Drop this connection so the next call opens a fresh forward on a
            // fresh port. A forward riding a master that died or was cleared
            // goes with it (a transport failure). And a handshake or trust
            // failure can mean another local process took the forward's port
            // between reservation and use; pinned trust refuses that listener,
            // and keeping the forward would leave the host refused until it is
            // removed. The failure still surfaces as itself, and nothing
            // retries on the plain port.
            pool.close(target)
            throw error
        }
        if status == 401 { throw refusal(body: body) }
        return encodeCurlStyleResponse(status: status, body: body)
    }

    /// The Library's 8443 listener answers 401 for two different reasons,
    /// and they need different fixes. A Bearer token not bound to this
    /// machine (or not valid at all) is refused by the binding middleware
    /// before any route runs, and only when a token is present. A certificate
    /// that chained to the root but is not one active registered machine
    /// with clientAuth reads "no resolvable identity". A bad, missing or
    /// foreign certificate never gets this far: it fails the handshake.
    static func refusal(body: Data) -> LibraryMutualTLSError {
        let text = String(data: body, encoding: .utf8) ?? ""
        if text.contains("not bound to the presenting machine") {
            return .credentialNotBound(text)
        }
        if text.contains("no resolvable identity") {
            return .machineNotRegistered(text)
        }
        return .unauthorized(text)
    }

    /// The inverse of `WorkingCopyStore.splitCurlStatusResponse`: `body`
    /// followed by a newline and the status, exactly `curl -w
    /// '\n%{http_code}'`'s own output shape.
    static func encodeCurlStyleResponse(status: Int, body: Data) -> Data {
        body + Data("\n\(status)".utf8)
    }
}
