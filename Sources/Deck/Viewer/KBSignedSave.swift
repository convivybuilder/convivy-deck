import CryptoKit
import Foundation

/// The envelope a Deck-signed KB save signs over
/// (`platform/contracts/library-protocol` §2.2). `kb apply` rebuilds this
/// exact byte sequence from its own state — the canonical path it resolved,
/// the `--base-sha` it is holding the write to, the sha256 of the bytes it is
/// about to commit, and the `signed-at` that travelled with the save — and
/// refuses the save when the signature does not verify against it. Deck must
/// reproduce the same bytes for the same reason a checksum must: one byte off
/// and the signature never verifies.
enum SignedSaveEnvelope {
    /// The literal four-line message, UTF-8, every line ending in `\n`
    /// including the last: the format's version line, then `key:value` with
    /// no whitespace around the colon, in this fixed order.
    static func bytes(document: String, baseSha: String, contentSha256: String,
                      signedAt: String) -> Data {
        Data((
            "convivy-kb-save/1\n"
            + "document:\(document)\n"
            + "base-sha:\(baseSha)\n"
            + "content-sha256:\(contentSha256)\n"
            + "signed-at:\(signedAt)\n"
        ).utf8)
    }

    /// UTC, whole seconds, the literal `T` and `Z` — the one `signed-at`
    /// shape `kb apply` accepts. Built with a fixed POSIX locale and a fixed
    /// `DateFormatter` rather than `ISO8601DateFormatter`'s default options,
    /// which include fractional seconds `kb apply`'s regex refuses.
    static func signedAtString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    /// The SHA-256 of `content`'s UTF-8 bytes, in 64 lowercase hex characters
    /// — the same bytes `submit` below sends, computed before signing so a
    /// signature never covers a serialization that lost content.
    static func contentSha256Hex(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The stdin object `kb apply --provenance person` reads a Deck signature
/// from (library-protocol.md §2.2): exactly these four keys, told apart from
/// a Cloudflare Access JWT by starting with `{`.
private struct DeckSignatureProof: Encodable {
    let proof = "deck-signature"
    let signedAt: String
    let signature: String
    let certificate: String

    enum CodingKeys: String, CodingKey {
        case proof, signedAt = "signed_at", signature, certificate
    }
}

extension KnowledgeBase {
    /// Why a stored certificate cannot sign at a given moment. The window is
    /// inclusive at both ends, the same rule `SigningCertificateImport` applies.
    enum CertificateValidityProblem: Equatable {
        case notYetValid(notBefore: Date)
        case expired(notAfter: Date)
    }

    /// What became of a signed save.
    enum SignedSaveOutcome: Equatable {
        /// `kb apply` accepted the write and recorded it as the certificate's
        /// person.
        case sent
        /// This Mac has no signing certificate stored yet, so nothing was
        /// sent.
        case noCertificate
        /// The stored certificate's validity window does not include the
        /// moment of signing, so nothing was signed and nothing was sent. The
        /// save stays on this Mac until a renewed certificate is imported.
        case outsideValidity(CertificateValidityProblem)
        /// The Touch ID (or password) prompt was dismissed, so nothing was
        /// signed and nothing was sent.
        case cancelled
        /// `kb apply` refused the write; the message is its stderr, shown to
        /// the person. Nothing about the document changed on either side.
        case refused(String)
    }

    /// Checks the stored certificate's validity window at `now`, then signs and
    /// sends through `submit`. A certificate outside its window returns before
    /// `submit` runs, so the key is never asked to sign and no ssh call is made.
    ///
    /// `certificatePEM` is the text `SigningCertificateStore.loadPEM(forSPKI:)`
    /// returned, already matched to `signingKey`. Parsing it here can throw; the
    /// caller's catch reports that as a refusal.
    static func submitIfCurrent(
        target: SSHTarget,
        document: CheckedOutDocument,
        content: String,
        signingKey: SigningKey,
        certificatePEM: String,
        now: Date,
        signReason: String? = nil,
        controlPath: String = defaultControlPath(),
        run: ([String], String?) throws -> Data = { argv, stdin in
            try SessionAgent.run(argv, stdin: stdin)
        }
    ) throws -> SignedSaveOutcome {
        let certificate = try SigningCertificate.parse(fileData: Data(certificatePEM.utf8))
        if now < certificate.notBefore {
            return .outsideValidity(.notYetValid(notBefore: certificate.notBefore))
        }
        if now > certificate.notAfter {
            return .outsideValidity(.expired(notAfter: certificate.notAfter))
        }
        return try submit(
            target: target, document: document, content: content, signingKey: signingKey,
            certificatePEM: certificatePEM, now: now, signReason: signReason,
            controlPath: controlPath, run: run)
    }

    /// Signs `content` as a save of `document` and sends it to
    /// `agentctl kb apply --provenance person`
    /// (`platform/contracts/library-protocol` §2.2).
    ///
    /// The content reaches `kb apply` through `--content-file`, never
    /// `--edits`: a signed save carries the whole file, because anchors are
    /// matched at apply time and the signer cannot know the bytes they would
    /// produce. `kb apply`'s stdin is reserved for the signature envelope, so
    /// the bytes travel first, over their own ssh call, to a fresh path in a
    /// per-Mac scratch directory on the target; that path is what
    /// `--content-file` names. The scratch file is removed after, best
    /// effort, the same way `release` drops a lease: nothing downstream
    /// depends on the cleanup succeeding.
    ///
    /// `run` defaults to a real ssh round trip and is a parameter so a test
    /// can substitute a fake transport and inspect exactly what crossed it,
    /// without a signing key that needs a person at a Touch ID sensor.
    static func submit(
        target: SSHTarget,
        document: CheckedOutDocument,
        content: String,
        signingKey: SigningKey,
        certificatePEM: String?,
        now: Date = Date(),
        signReason: String? = nil,
        controlPath: String = defaultControlPath(),
        run: ([String], String?) throws -> Data = { argv, stdin in
            try SessionAgent.run(argv, stdin: stdin)
        }
    ) throws -> SignedSaveOutcome {
        guard let certificatePEM else { return .noCertificate }

        let contentSha256 = SignedSaveEnvelope.contentSha256Hex(content)
        let signedAt = SignedSaveEnvelope.signedAtString(now)
        let envelope = SignedSaveEnvelope.bytes(
            document: document.sourceRef, baseSha: document.contentSha,
            contentSha256: contentSha256, signedAt: signedAt)

        // `signReason` names the save in the Touch ID prompt. Nil keeps the
        // platform's default prompt, which is what a normal save shows.
        let signature: Data
        do {
            if let signReason {
                signature = try signingKey.sign(envelope, reason: signReason)
            } else {
                signature = try signingKey.sign(envelope)
            }
        } catch SigningKeyError.cancelled {
            return .cancelled
        }

        let proof = DeckSignatureProof(
            signedAt: signedAt, signature: signature.base64EncodedString(),
            certificate: certificatePEM)
        guard let proofJSON = String(data: try JSONEncoder().encode(proof), encoding: .utf8) else {
            throw KBError.unexpectedResponse("could not encode the signature envelope")
        }

        let pathData = try run(
            writeRemoteContentFileArguments(target: target, controlPath: controlPath), content)
        guard let remotePath = String(data: pathData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !remotePath.isEmpty else {
            throw KBError.unexpectedResponse(
                String(data: pathData, encoding: .utf8) ?? "(unreadable)")
        }
        defer {
            _ = try? run(
                cleanupContentFileArguments(target: target, path: remotePath, controlPath: controlPath), nil)
        }

        do {
            _ = try run(
                applyArguments(target: target, id: document.id, baseSha: document.contentSha,
                               contentFilePath: remotePath, controlPath: controlPath), proofJSON)
        } catch SessionAgent.AgentError.failed(let message) {
            return .refused(message)
        }
        return .sent
    }

    /// ssh argv that writes stdin to a fresh path under a per-Mac scratch
    /// directory on the target and prints that path — the step that gets the
    /// save's bytes onto the remote filesystem so `--content-file` can name
    /// them, since `kb apply`'s own stdin is reserved for the signature
    /// envelope and cannot also carry the document.
    static func writeRemoteContentFileArguments(
        target: SSHTarget,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            "mkdir -p \"$HOME/.cache/agentctl-deck-saves\" && "
            + "f=$(mktemp \"$HOME/.cache/agentctl-deck-saves/deck-save.XXXXXX\") && "
            + "cat > \"$f\" && printf '%s' \"$f\"",
        ], home: home)
    }

    /// ssh argv for `agentctl kb apply <id> --base-sha <sha> --provenance
    /// person --content-file <path> --allow-overwrite`. Never `--edits` or
    /// `--edits-file`: `kb apply` refuses either on a Deck signature, with
    /// exit 8, because the signer cannot know the bytes an anchor match would
    /// produce. `--allow-overwrite` is unconditional because `document` was
    /// checked out, so the file it names already exists on `origin/main`.
    ///
    /// `baseSha` is quoted like `id` and `contentFilePath`: ssh joins its
    /// trailing arguments with spaces and hands the joined string to the
    /// remote shell, which re-splits it, so an unquoted value with a space,
    /// `;`, a backtick, or `$()` would be interpreted by the mini's login
    /// shell rather than passed through as one token. `baseSha` comes from
    /// `KnowledgeBase.checkout`, which now refuses a `content_sha` that is
    /// not 64 lowercase hex characters before it ever reaches a
    /// `CheckedOutDocument` — but quoting it here too is the actual fix, not
    /// that upstream check: a charset assumption is a weaker guarantee than
    /// quoting. Found by `deck-security-reviewer` on #286.
    static func applyArguments(
        target: SSHTarget,
        id: String,
        baseSha: String,
        contentFilePath: String,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            "agentctl", "kb", "apply", SessionAgent.shellQuotePath(id),
            "--base-sha", SessionAgent.shellQuotePath(baseSha),
            "--provenance", "person",
            "--content-file", SessionAgent.shellQuotePath(contentFilePath),
            "--allow-overwrite",
        ], home: home)
    }

    /// ssh argv that removes the scratch content file `submit` wrote,
    /// ignoring failure the way `release` ignores a lease it could not drop —
    /// nothing downstream depends on this succeeding.
    static func cleanupContentFileArguments(
        target: SSHTarget,
        path: String,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            "rm", "-f", SessionAgent.shellQuotePath(path),
        ], home: home)
    }
}
