import CryptoKit
import Foundation

/// Pairs a Mac Deck has never logged in to, in four steps: trust its host key
/// by fingerprint, use or create a laptop ed25519 key, install that key's
/// public half on the account with one password entry, then run Test.
///
/// The fingerprint comparison is the only authentication of the host key.
/// `keyscan` fetches the key over an unauthenticated connection, so Deck
/// writes exactly the key whose fingerprint the operator was shown, and it
/// never re-scans between the two steps.
///
/// Every filesystem path takes a `home` parameter, defaulting to
/// `NSHomeDirectory()`, so tests point the whole flow at a temporary
/// directory and never touch the real `~/.ssh`.
enum HostPairing {
    /// The only key type `keyscan` is asked for. A Mac running Remote Login
    /// has an ed25519 host key by default, and asking for one type keeps the
    /// fingerprint the operator compares a single value.
    static let scannedKeyType = "ssh-ed25519"

    /// Public key types a laptop identity may have. Deck does not generate
    /// these, only reads an existing `.pub` file of one of them.
    static let publicKeyTypes: Set<String> = [
        "ssh-ed25519", "ssh-rsa",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    ]

    /// The environment variable carrying the password to the askpass script.
    /// It is set on the one ssh child, never on Deck's own process.
    static let passwordVariable = "DECK_PAIR_PASSWORD"

    /// A host's key as `keyscan` returned it, with the fingerprint shown to
    /// the operator. Built only by `parseKeyscan`, so the fingerprint always
    /// matches the blob.
    struct ScannedHostKey: Equatable {
        let type: String
        let blob: String
        let fingerprint: String
    }

    /// A laptop public key. `line` is the trimmed file contents, which is what
    /// the remote install step reads from stdin.
    struct PublicKey: Equatable {
        let type: String
        let blob: String
        let line: String
    }

    enum TrustOutcome: Equatable {
        case added
        case alreadyTrusted
    }

    /// What the remote install step reported. `alreadyPresent` is success:
    /// the key was on the account before this run. Both success cases carry
    /// the absolute `authorized_keys` path the remote verified.
    enum InstallOutcome: Equatable {
        case added(path: String)
        case alreadyPresent(path: String)
        case passwordRefused
        case failed(String)
    }

    // MARK: - Argv

    /// argv for `ssh-keyscan`, which asks the host for its ed25519 key and
    /// nothing else. It never authenticates, so it needs no user; the user is
    /// still validated so every ssh-family call in this flow passes the same
    /// gate before argv.
    static func keyscanArguments(target: SSHTarget) throws -> [String] {
        _ = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        return ["-T", "5", "-t", "ed25519", host]
    }

    /// argv for the password-authenticated install connection. `StrictHostKeyChecking=yes`
    /// refuses an unknown key rather than prompting, so a key that is not in
    /// `known_hosts` cannot be trusted here by accident. The connection uses
    /// no ControlMaster: a master that outlived this step would keep a
    /// password-authenticated session open for the life of the Deck process.
    ///
    /// The password is absent from argv by construction. It reaches ssh only
    /// through `installEnvironment`.
    static func installArguments(target: SSHTarget, home: String = NSHomeDirectory()) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        return withDeckIdentity([
            "-T",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(home)/.ssh/known_hosts",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ConnectTimeout=10",
            "-o", "NumberOfPasswordPrompts=1",
            "\(user)@\(host)",
            remoteInstallCommand,
        ], home: home)
    }

    /// The remote command that installs the key line read from stdin. It is a
    /// fixed string: the key never appears in it, so a key cannot break out of
    /// the remote shell. The key is appended only when no line already holds
    /// the same key blob, so a comment change never adds a duplicate.
    ///
    /// Both blob matches scan every line that does not start with `#`, and
    /// count the blob only where it follows a key-type token (`ssh-`, `ecdsa-`,
    /// `sk-`). A commented-out key therefore does not count as present. A blob
    /// in another key's comment field does not either. A line with options
    /// before the key type (`from=…`, `command=…`) still matches, so its key is
    /// not appended a second time without them.
    ///
    /// The command ends by printing the absolute `authorized_keys` path it
    /// verified, then the success word (`added` or `present`). The word follows
    /// a final scan that finds the blob in that file, so a write that lands
    /// nothing ends the command without it, and `classifyInstall` reads that as
    /// a failure. The path lets the sheet show which file was written, so a
    /// `$HOME` that differs from the account home is visible.
    ///
    /// Modes are set on every run, not only on creation, because `mkdir -p`
    /// leaves an existing `~/.ssh` as it found it and a loose mode there is the
    /// failure this step should fix. The `echo` before the key covers an
    /// `authorized_keys` that lacks a trailing newline, so the key does not
    /// join its last line.
    static let remoteInstallCommand = #"""
        umask 077; mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" && touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys" && read -r key && blob=$(printf '%s\n' "$key" | awk '{ print $2 }') && if awk -v b="$blob" '$1 !~ /^#/ { for (i = 1; i <= NF; i++) if (i > 1 && $i == b && $(i-1) ~ /^(ssh-|ecdsa-|sk-)/) found = 1 } END { exit !found }' "$HOME/.ssh/authorized_keys"; then mark=present; else { if [ -s "$HOME/.ssh/authorized_keys" ] && [ -n "$(tail -c 1 "$HOME/.ssh/authorized_keys")" ]; then echo; fi; printf '%s\n' "$key"; } >> "$HOME/.ssh/authorized_keys" && mark=added; fi && awk -v b="$blob" '$1 !~ /^#/ { for (i = 1; i <= NF; i++) if (i > 1 && $i == b && $(i-1) ~ /^(ssh-|ecdsa-|sk-)/) found = 1 } END { exit !found }' "$HOME/.ssh/authorized_keys" && printf '%s\n' "$HOME/.ssh/authorized_keys" && echo "$mark"
        """#

    /// The askpass program ssh runs to get the password. It prints the
    /// variable without a trailing newline, because ssh keeps every byte it
    /// reads from askpass.
    static let askpassScript = "#!/bin/sh\nprintf '%s' \"$\(passwordVariable)\"\n"

    /// The environment for the install ssh call: askpass forced on, with the
    /// password in the child's environment only.
    static func installEnvironment(
        password: String, askpassPath: String, base: [String: String]
    ) -> [String: String] {
        var environment = base
        environment["SSH_ASKPASS"] = askpassPath
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment[passwordVariable] = password
        return environment
    }

    // MARK: - Pure parsing

    /// Reads the ed25519 line out of `ssh-keyscan` output. Comment lines and
    /// lines of other types are skipped. Returns nil when no usable line is
    /// there.
    static func parseKeyscan(_ text: String) -> ScannedHostKey? {
        for raw in text.split(whereSeparator: \.isNewline) {
            guard !raw.hasPrefix("#") else { continue }
            let fields = raw.split(separator: " ")
            guard fields.count >= 3, fields[1] == scannedKeyType[...] else { continue }
            let blob = String(fields[2])
            guard let fingerprint = fingerprint(forBlob: blob) else { continue }
            return ScannedHostKey(type: scannedKeyType, blob: blob, fingerprint: fingerprint)
        }
        return nil
    }

    /// Reads a `.pub` file's contents. Refuses anything with more than one
    /// line, an unknown type, or a blob that is not base64, so a corrupt file
    /// cannot put arbitrary text on the remote side.
    static func parsePublicKey(_ text: String) -> PublicKey? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .newlines) == nil else { return nil }
        let fields = trimmed.split(separator: " ", maxSplits: 2)
        guard fields.count >= 2 else { return nil }
        let type = String(fields[0])
        let blob = String(fields[1])
        guard publicKeyTypes.contains(type), Data(base64Encoded: blob) != nil else { return nil }
        return PublicKey(type: type, blob: blob, line: trimmed)
    }

    /// The SHA256 fingerprint `ssh-keygen -lf` prints: the digest of the
    /// decoded key blob, base64 with the padding dropped.
    static func fingerprint(forBlob blob: String) -> String? {
        guard let data = Data(base64Encoded: blob) else { return nil }
        let digest = Data(SHA256.hash(data: data)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// The fingerprint line the operator compares, in the form `ssh-keygen -lf`
    /// prints its fingerprint and type fields: `SHA256:<base64> (ED25519)`.
    /// The installer on the Mac prints the same shape, so the two strings can
    /// be compared by eye.
    static func displayFingerprint(_ key: ScannedHostKey) -> String {
        "\(key.fingerprint) (ED25519)"
    }

    /// The `known_hosts` line for `key` under `address`, the name Deck connects
    /// to. Port 22 is the only port Deck uses, so no `[host]:port` form is
    /// needed.
    static func knownHostsLine(address: String, key: ScannedHostKey) -> String {
        "\(address) \(key.type) \(key.blob)"
    }

    /// Maps the install step's raw ssh result to an outcome. Success needs the
    /// remote's `added` or `present` word on the last stdout line, with the
    /// verified path on the line before it. An exit 0 with no word is not read
    /// as success, and a word with no absolute path is a failure too.
    static func classifyInstall(
        stdout: String, stderr: String, terminationStatus: Int32, timedOut: Bool
    ) -> InstallOutcome {
        if timedOut { return .failed("ssh did not finish within 60 seconds") }
        let lines = stdout.split(whereSeparator: \.isNewline).map(String.init)
        let mark = lines.last ?? ""
        let path = lines.count >= 2 ? lines[lines.count - 2] : ""
        if terminationStatus == 0, mark == "added" || mark == "present" {
            guard path.hasPrefix("/") else {
                return .failed("The remote did not report the authorized_keys path it wrote.")
            }
            return mark == "added" ? .added(path: path) : .alreadyPresent(path: path)
        }
        if stderr.split(whereSeparator: \.isNewline).contains(where: { isAuthenticationRefusal(String($0)) }) {
            return .passwordRefused
        }
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(text.isEmpty ? "ssh exited with status \(terminationStatus)" : text)
    }

    /// Whether one stderr line is ssh's own refusal to authenticate. OpenSSH
    /// prints `user@host: Permission denied (methods).` or `Permission denied,
    /// please try again.` A remote write error, such as `touch: …: Permission
    /// denied`, has neither shape, so it is reported as a failure rather than a
    /// wrong password.
    static func isAuthenticationRefusal(_ line: String) -> Bool {
        let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
        return lower.contains("permission denied (") || lower.hasSuffix("permission denied, please try again.")
    }

    /// The line Add Host shows after a pairing run's Test. The host is not in
    /// the list yet, so a reachable result says the next step is Add. A refusal
    /// means the key was installed but the login still failed, so the line says
    /// so. Any other outcome names the failure rather than hiding it.
    static func note(afterTest outcome: HostTestOutcome) -> String {
        switch outcome {
        case .reachable:
            return "Paired. Add the host to finish."
        case .refused(let text):
            return "Key installed, but Test was refused: \(text)"
        case .unreachable(let text):
            return "Paired, but Test did not answer: \(text)"
        }
    }

    /// Whether a failed Test should offer pairing. Both an unknown host key
    /// and a refused key login print a phrase ssh uses for nothing else; a
    /// timeout or a refused port is a network problem pairing cannot fix.
    static func offersPairing(testError: String) -> Bool {
        let lower = testError.lowercased()
        return lower.contains("host key verification failed") || lower.contains("permission denied")
    }

    // MARK: - Running ssh

    /// Fetches the host's ed25519 key. Throws `noHostKey` when the host
    /// answers without one, carrying ssh's stderr so the operator sees why.
    static func scan(target: SSHTarget) throws -> ScannedHostKey {
        let argv = try keyscanArguments(target: target)
        let outcome = try SSHProcessRunner.run(
            argv, timeout: 15, executable: "/usr/bin/ssh-keyscan")
        if let key = parseKeyscan(String(decoding: outcome.stdout, as: UTF8.self)),
           outcome.terminationStatus == 0, !outcome.timedOut {
            return key
        }
        throw HostPairingError.noHostKey(outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Installs `key` on the account, with `password` as the only credential.
    /// The askpass script lives in a fresh temporary directory, removed when
    /// the call returns. The script holds no secret: it reads the variable
    /// from its environment.
    static func install(
        _ key: PublicKey, target: SSHTarget, password: String, home: String = NSHomeDirectory()
    ) throws -> InstallOutcome {
        let argv = try installArguments(target: target, home: home)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-pair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let askpass = directory.appendingPathComponent("askpass.sh")
        try askpassScript.write(to: askpass, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)

        let environment = installEnvironment(
            password: password, askpassPath: askpass.path,
            base: ProcessInfo.processInfo.environment)
        let outcome = try SSHProcessRunner.run(
            argv, stdin: key.line + "\n", timeout: 60, environment: environment)
        return classifyInstall(
            stdout: String(decoding: outcome.stdout, as: UTF8.self),
            stderr: outcome.stderr,
            terminationStatus: outcome.terminationStatus,
            timedOut: outcome.timedOut)
    }

    // MARK: - Files under `home`

    /// Writes `key` to `known_hosts` under `address`, so a plain `ssh` from
    /// Terminal trusts the host too. Refuses when the file already names this
    /// address with a different key of the same type: that is a changed key,
    /// and overwriting it would make the mismatch invisible.
    @discardableResult
    static func trust(
        _ key: ScannedHostKey, address: String, home: String = NSHomeDirectory()
    ) throws -> TrustOutcome {
        try ensureSSHDirectory(home)
        let path = "\(home)/.ssh/known_hosts"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        for line in existing.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count >= 3,
                  fields[0].split(separator: ",").contains(where: { String($0) == address }),
                  fields[1] == key.type[...]
            else { continue }
            if fields[2] == key.blob[...] { return .alreadyTrusted }
            throw HostPairingError.conflictingHostKey
        }

        let entry = knownHostsLine(address: address, key: key) + "\n"
        if FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            let needsSeparator = !existing.isEmpty && !existing.hasSuffix("\n")
            try handle.write(contentsOf: Data(((needsSeparator ? "\n" : "") + entry).utf8))
        } else {
            FileManager.default.createFile(
                atPath: path, contents: Data(entry.utf8),
                attributes: [.posixPermissions: 0o600])
        }
        return .added
    }

    /// The laptop public key to install: Deck's own key (`DeckIdentity`), or a
    /// new one when it does not exist. The laptop's default identity is never
    /// used, so pairing never installs a key Deck's unattended ssh cannot
    /// answer with. A key file is never overwritten. A private key with no
    /// `.pub` beside it is refused rather than replaced. Any entry at either
    /// path that is not a regular file is refused, including a symlink whose
    /// target is missing, because ssh-keygen would write through it.
    static func ensureIdentity(home: String = NSHomeDirectory()) throws -> PublicKey {
        let path = DeckIdentity.path(home: home)
        let publicPath = path + ".pub"
        if entryExists(atPath: publicPath) {
            guard isRegularFile(atPath: publicPath) else {
                throw HostPairingError.identityPathOccupied(publicPath)
            }
            return try readPublicKey(atPath: publicPath)
        }
        if entryExists(atPath: path) {
            guard isRegularFile(atPath: path) else {
                throw HostPairingError.identityPathOccupied(path)
            }
            throw HostPairingError.identityWithoutPublicHalf(path)
        }
        return try createIdentity(home: home)
    }

    /// Creates Deck's key with no passphrase. Callers must have checked that
    /// neither the key nor its `.pub` exists; `ensureIdentity` does. After
    /// generation both results must be regular files, so a link that appeared
    /// in between is reported rather than read.
    static func createIdentity(home: String = NSHomeDirectory()) throws -> PublicKey {
        try ensureSSHDirectory(home)
        let path = DeckIdentity.path(home: home)
        let outcome = try SSHProcessRunner.run(
            ["-q", "-t", "ed25519", "-N", "", "-C", "deck", "-f", path],
            timeout: 30, executable: "/usr/bin/ssh-keygen")
        guard outcome.terminationStatus == 0, !outcome.timedOut else {
            throw HostPairingError.keyGenerationFailed(
                outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for written in [path, path + ".pub"] where !isRegularFile(atPath: written) {
            throw HostPairingError.keyGenerationFailed("\(written) is not a regular file")
        }
        return try readPublicKey(atPath: path + ".pub")
    }

    /// Whether anything is at `path`, including a symlink whose target is
    /// missing. `FileManager.fileExists` follows links, so it reads a dangling
    /// one as absent. `lstat` does not follow the final component.
    private static func entryExists(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Whether `path` is itself a regular file, not a link to one.
    private static func isRegularFile(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func readPublicKey(atPath path: String) throws -> PublicKey {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        guard let key = parsePublicKey(text) else {
            throw HostPairingError.fileFailed("\(path) is not a public key Deck can install")
        }
        return key
    }

    /// Creates `~/.ssh` at 700 when it is missing. An existing directory keeps
    /// its mode here: changing a directory the operator already has is not
    /// this flow's call. The install step tightens it on the remote side.
    private static func ensureSSHDirectory(_ home: String) throws {
        let directory = "\(home)/.ssh"
        guard !FileManager.default.fileExists(atPath: directory) else { return }
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}

/// A pairing step that could not finish. `message` is what the sheet shows.
enum HostPairingError: Error, Equatable {
    case noHostKey(String)
    case conflictingHostKey
    case identityWithoutPublicHalf(String)
    case identityPathOccupied(String)
    case keyGenerationFailed(String)
    case fileFailed(String)

    var message: String {
        switch self {
        case .noHostKey(let detail):
            return detail.isEmpty
                ? "The host did not offer an ed25519 host key."
                : "The host did not offer an ed25519 host key: \(detail)"
        case .conflictingHostKey:
            return "known_hosts already names this address with a different key. Deck did not "
                + "change it. If the Mac was reinstalled, remove the old line by hand, then pair again."
        case .identityWithoutPublicHalf(let path):
            return "\(path) exists without \(path).pub beside it. Deck did not replace it. "
                + "Restore the .pub file, or remove the private key by hand, then pair again."
        case .identityPathOccupied(let path):
            return "\(path) exists but is not a regular file, such as a symlink. Deck did not "
                + "write through it. Remove it by hand, then pair again."
        case .keyGenerationFailed(let detail):
            return "Could not create a laptop key: \(detail)"
        case .fileFailed(let detail):
            return detail
        }
    }
}
