import XCTest
@testable import Deck

/// `HostPairing`'s file operations, run against a temporary home directory
/// passed in as `home:`. Nothing here reads or writes the real `~/.ssh`.
final class HostPairingFilesTests: XCTestCase {
    private let fixtureBlob = "AAAAC3NzaC1lZDI1NTE5AAAAIM6sRsK3amkDYRbuadqksG932D45LU/YS/IHkVcI+jiU"
    private let address = "macmini.example.com"
    private var home: String!

    private var fixtureKey: HostPairing.ScannedHostKey {
        .init(type: "ssh-ed25519", blob: fixtureBlob, fingerprint: "SHA256:unused-in-these-tests")
    }

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-pairing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        home = directory.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private var knownHostsPath: String { "\(home!)/.ssh/known_hosts" }

    private func mode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - known_hosts

    func testTrustCreatesTheSSHDirectoryAndTheFileWithSSHModes() throws {
        XCTAssertEqual(try HostPairing.trust(fixtureKey, address: address, home: home), .added)
        XCTAssertEqual(try mode(of: "\(home!)/.ssh"), 0o700)
        XCTAssertEqual(try mode(of: knownHostsPath), 0o600)
    }

    func testTrustWritesExactlyTheShownKeyUnderTheConnectAddress() throws {
        try HostPairing.trust(fixtureKey, address: address, home: home)
        let text = try String(contentsOfFile: knownHostsPath, encoding: .utf8)
        XCTAssertEqual(text, "\(address) ssh-ed25519 \(fixtureBlob)\n")
    }

    /// Mutation: without the alreadyTrusted check, a second Trust appends the
    /// same line again. The file must stay byte-identical.
    func testTrustingTheSameKeyTwiceDoesNotDuplicateTheLine() throws {
        try HostPairing.trust(fixtureKey, address: address, home: home)
        let first = try String(contentsOfFile: knownHostsPath, encoding: .utf8)
        XCTAssertEqual(try HostPairing.trust(fixtureKey, address: address, home: home), .alreadyTrusted)
        XCTAssertEqual(try String(contentsOfFile: knownHostsPath, encoding: .utf8), first)
    }

    func testTrustKeepsExistingLinesAndSeparatesAnUnterminatedLastLine() throws {
        try write("github.com ssh-ed25519 AAAAOTHER", to: knownHostsPath)
        try HostPairing.trust(fixtureKey, address: address, home: home)
        let text = try String(contentsOfFile: knownHostsPath, encoding: .utf8)
        XCTAssertEqual(text, "github.com ssh-ed25519 AAAAOTHER\n\(address) ssh-ed25519 \(fixtureBlob)\n")
    }

    /// Mutation: overwrite on a mismatch and the changed key vanishes. The
    /// refusal must throw and leave the file exactly as it was.
    func testTrustRefusesAChangedKeyAndLeavesTheFileUntouched() throws {
        let original = "\(address) ssh-ed25519 AAAAOLDKEYOLDKEY\n"
        try write(original, to: knownHostsPath)
        XCTAssertThrowsError(try HostPairing.trust(fixtureKey, address: address, home: home)) { error in
            XCTAssertEqual(error as? HostPairingError, .conflictingHostKey)
        }
        XCTAssertEqual(try String(contentsOfFile: knownHostsPath, encoding: .utf8), original)
    }

    /// A line can name several hosts comma-separated, and a changed key on one
    /// of them is still a change.
    func testTrustRefusesAChangedKeyNamedInACommaSeparatedLine() throws {
        try write("other.example,\(address) ssh-ed25519 AAAAOLDKEYOLDKEY\n", to: knownHostsPath)
        XCTAssertThrowsError(try HostPairing.trust(fixtureKey, address: address, home: home)) { error in
            XCTAssertEqual(error as? HostPairingError, .conflictingHostKey)
        }
    }

    /// A different key type for the same address is not a conflict with an
    /// ed25519 one, so it is appended beside it.
    func testTrustAddsAnEd25519KeyBesideAnRSAOneForTheSameAddress() throws {
        try write("\(address) ssh-rsa AAAAB3RSAKEY\n", to: knownHostsPath)
        XCTAssertEqual(try HostPairing.trust(fixtureKey, address: address, home: home), .added)
    }

    // MARK: - Laptop identity

    private var deckKeyPath: String { "\(home!)/.ssh/id_ed25519_deck" }

    func testEnsureIdentityUsesAnExistingDeckPublicKeyWithoutCreatingAnything() throws {
        let line = "ssh-ed25519 \(fixtureBlob) deck"
        try write(line + "\n", to: deckKeyPath + ".pub")
        let key = try HostPairing.ensureIdentity(home: home)
        XCTAssertEqual(key.line, line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deckKeyPath))
    }

    /// Mutation: fall back to the default identity when no Deck key exists,
    /// and pairing installs the laptop's own key, the one that needs a
    /// passphrase. The default `.pub` must not be the one returned, and the
    /// Deck key must be created beside it.
    func testEnsureIdentityNeverChoosesTheDefaultIdentity() throws {
        let defaultLine = "ssh-ed25519 \(fixtureBlob) default-identity"
        try write(defaultLine + "\n", to: "\(home!)/.ssh/id_ed25519.pub")
        let key = try HostPairing.ensureIdentity(home: home)
        XCTAssertNotEqual(key.line, defaultLine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: deckKeyPath))
        XCTAssertEqual(try String(contentsOfFile: "\(home!)/.ssh/id_ed25519.pub", encoding: .utf8),
                       defaultLine + "\n")
    }

    /// Mutation: a create path that ignores the existing private key would
    /// replace it. The refusal names the problem and leaves both files alone.
    func testEnsureIdentityRefusesADeckPrivateKeyWithNoPublicHalf() throws {
        let privateText = "placeholder private key\nkept\n"
        try write(privateText, to: deckKeyPath)
        XCTAssertThrowsError(try HostPairing.ensureIdentity(home: home)) { error in
            XCTAssertEqual(error as? HostPairingError, .identityWithoutPublicHalf(deckKeyPath))
        }
        XCTAssertEqual(try String(contentsOfFile: deckKeyPath, encoding: .utf8), privateText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deckKeyPath + ".pub"))
    }

    /// With no Deck key present, one is created in the injected home. Private
    /// key mode 600, a public half beside it, and the returned line is that
    /// public half. `ssh-keygen -y` with an empty passphrase reads the private
    /// key only if it has no passphrase, which is what unattended ssh needs.
    func testEnsureIdentityCreatesAnUnencryptedEd25519DeckKeyWhenNoneExists() throws {
        let key = try HostPairing.ensureIdentity(home: home)
        XCTAssertEqual(key.type, "ssh-ed25519")
        XCTAssertEqual(try mode(of: deckKeyPath), 0o600)
        let stored = try String(contentsOfFile: deckKeyPath + ".pub", encoding: .utf8)
        XCTAssertEqual(key.line, stored.trimmingCharacters(in: .whitespacesAndNewlines))

        let unlocked = try SSHProcessRunner.run(
            ["-y", "-P", "", "-f", deckKeyPath], timeout: 10, executable: "/usr/bin/ssh-keygen")
        XCTAssertEqual(unlocked.terminationStatus, 0, unlocked.stderr)
    }

    /// Mutation: a create path that runs when it should not would replace an
    /// existing key. Both files of an existing pair must keep their bytes.
    func testEnsureIdentityNeverOverwritesAnExistingDeckPair() throws {
        let privateText = "placeholder private key\nexisting\n"
        let publicLine = "ssh-ed25519 \(fixtureBlob) existing\n"
        try write(privateText, to: deckKeyPath)
        try write(publicLine, to: deckKeyPath + ".pub")
        _ = try HostPairing.ensureIdentity(home: home)
        XCTAssertEqual(try String(contentsOfFile: deckKeyPath, encoding: .utf8), privateText)
        XCTAssertEqual(try String(contentsOfFile: deckKeyPath + ".pub", encoding: .utf8), publicLine)
    }

    // MARK: - Dangling links at Deck's key paths

    /// `ssh-keygen -f` writes through a symlink, and `FileManager.fileExists`
    /// reads a dangling one as absent. Pairing must refuse the link itself, so
    /// nothing is created at its target and the link stays in place.
    /// Mutation: check with `fileExists`, and ssh-keygen creates the key at the
    /// target and this does not throw.
    func testEnsureIdentityRefusesADanglingLinkAtTheDeckPrivateKeyPath() throws {
        let target = "\(home!)/elsewhere/key"
        try FileManager.default.createDirectory(atPath: "\(home!)/elsewhere", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(home!)/.ssh", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: deckKeyPath, withDestinationPath: target)

        XCTAssertThrowsError(try HostPairing.ensureIdentity(home: home)) { error in
            XCTAssertEqual(error as? HostPairingError, .identityPathOccupied(deckKeyPath))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + ".pub"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: deckKeyPath), target)
    }

    /// The same check for the `.pub` path. Mutation: with `fileExists`, a
    /// dangling `.pub` link reads as absent, ssh-keygen writes the public half
    /// through it, and the private key is created beside it.
    func testEnsureIdentityRefusesADanglingLinkAtTheDeckPublicKeyPath() throws {
        let target = "\(home!)/elsewhere/pub"
        try FileManager.default.createDirectory(atPath: "\(home!)/elsewhere", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(home!)/.ssh", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: deckKeyPath + ".pub", withDestinationPath: target)

        XCTAssertThrowsError(try HostPairing.ensureIdentity(home: home)) { error in
            XCTAssertEqual(error as? HostPairingError, .identityPathOccupied(deckKeyPath + ".pub"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deckKeyPath))
    }

    // MARK: - Remote install command, run under /bin/sh

    private var keyLine: String { "ssh-ed25519 \(fixtureBlob) deck" }

    private var remoteEnvironment: [String: String] {
        ["HOME": home, "PATH": "/usr/bin:/bin"]
    }

    /// Runs the fixed remote command under `/bin/sh` with `HOME` at the
    /// temporary home, feeding `line` on stdin as ssh does. The command must
    /// exit 0 for the caller to read its output.
    private func runRemoteInstall(_ line: String) throws -> SSHProcessOutcome {
        let outcome = try SSHProcessRunner.run(
            ["-c", HostPairing.remoteInstallCommand], stdin: line + "\n", timeout: 10,
            executable: "/bin/sh", environment: remoteEnvironment)
        XCTAssertEqual(outcome.terminationStatus, 0, outcome.stderr)
        return outcome
    }

    private func lastStdoutLine(_ outcome: SSHProcessOutcome) -> String? {
        String(decoding: outcome.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)
    }

    private func authorizedKeysLines() throws -> [String] {
        let text = try String(contentsOfFile: "\(home!)/.ssh/authorized_keys", encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// The first run adds the line and the second finds the blob and writes
    /// nothing. A changed comment on the same blob is the same key, so it is
    /// not appended either. Mutation: match the whole line, or drop the check,
    /// and the second and third runs add a duplicate.
    func testRemoteInstallAddsTheKeyOnceAcrossRepeatedRuns() throws {
        XCTAssertEqual(lastStdoutLine(try runRemoteInstall(keyLine)), "added")
        XCTAssertEqual(lastStdoutLine(try runRemoteInstall(keyLine)), "present")
        XCTAssertEqual(lastStdoutLine(try runRemoteInstall("ssh-ed25519 \(fixtureBlob) renamed")), "present")
        XCTAssertEqual(try authorizedKeysLines(), [keyLine])
    }

    /// The key comment is data. Quotes, `$()` and backticks in it must run
    /// nothing, and the stored line must match the input byte for byte. The
    /// control runs a substitution through the same runner, so the markers
    /// staying absent is evidence that the comment ran nothing, not that the
    /// runner never executes substitutions.
    func testKeyCommentWithShellSyntaxExecutesNothing() throws {
        let markers = ["\(home!)/marker-a", "\(home!)/marker-b", "\(home!)/marker-c"]
        let comment = "x \"q\" '$(touch \(markers[0]))' `touch \(markers[1])`; touch \(markers[2])"
        let hostileLine = "ssh-ed25519 \(fixtureBlob) \(comment)"

        XCTAssertEqual(lastStdoutLine(try runRemoteInstall(hostileLine)), "added")
        XCTAssertEqual(try authorizedKeysLines(), [hostileLine])
        for marker in markers {
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker), marker)
        }

        _ = try SSHProcessRunner.run(
            ["-c", "echo \"$(touch \(home!)/control)\""], timeout: 10,
            executable: "/bin/sh", environment: remoteEnvironment)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(home!)/control"))
    }

    /// Modes are set on every run, so a loose `~/.ssh` and `authorized_keys`
    /// from an earlier install are tightened. The key also starts on its own
    /// line when the existing file lacks a trailing newline. Mutation: drop a
    /// chmod, or the separator echo, and this goes red.
    func testRemoteInstallTightensModesAndStartsTheKeyOnANewLine() throws {
        let sshDirectory = "\(home!)/.ssh"
        let authorizedKeys = "\(sshDirectory)/authorized_keys"
        try write("ssh-ed25519 OTHER other", to: authorizedKeys)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sshDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: authorizedKeys)

        XCTAssertEqual(lastStdoutLine(try runRemoteInstall(keyLine)), "added")
        XCTAssertEqual(try mode(of: sshDirectory), 0o700)
        XCTAssertEqual(try mode(of: authorizedKeys), 0o600)
        XCTAssertEqual(try authorizedKeysLines(), ["ssh-ed25519 OTHER other", keyLine])
    }

    /// The success word is printed only after the key blob is found on the
    /// account, and the verified path comes before it. Mutation: print the word
    /// without the final scan, and a write that lands nothing still reads as
    /// success.
    func testRemoteInstallReportsAddedOnlyAfterTheExactLineIsOnTheAccount() throws {
        let outcome = try runRemoteInstall(keyLine)
        XCTAssertEqual(HostPairing.classifyInstall(
            stdout: String(decoding: outcome.stdout, as: UTF8.self), stderr: "",
            terminationStatus: outcome.terminationStatus, timedOut: false),
            .added(path: "\(home!)/.ssh/authorized_keys"))
        XCTAssertTrue(try authorizedKeysLines().contains(keyLine))
    }

    /// A key line commented out with the `#` glued to the type is not an
    /// active key, so the install adds the live line rather than reporting
    /// the key present. The second run then finds the live line. Mutation:
    /// match `$2` without skipping `#` lines, and the commented line counts as
    /// present and nothing is written.
    func testRemoteInstallDoesNotCountACommentedOutKeyAsPresent() throws {
        let commented = "#ssh-ed25519 \(fixtureBlob) deck"
        try write(commented + "\n", to: "\(home!)/.ssh/authorized_keys")
        XCTAssertEqual(lastStdoutLine(try runRemoteInstall(keyLine)), "added")
        XCTAssertEqual(try authorizedKeysLines(), [commented, keyLine])
        XCTAssertEqual(lastStdoutLine(try runRemoteInstall(keyLine)), "present")
    }

    /// The blob sits in the comment field of another key's line, after that
    /// key's type and blob. The laptop key is not authorized by that line, so
    /// the install must append it. Mutation: match any field, and the blob in
    /// the comment position counts as present and nothing is written.
    func testRemoteInstallDoesNotCountABlobInAnotherKeysCommentAsPresent() throws {
        let other = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTHERKEYOTHERKEYOTHERKEYOTHERKEYOTHER note \(fixtureBlob)"
        try write(other + "\n", to: "\(home!)/.ssh/authorized_keys")
        XCTAssertEqual(lastStdoutLine(try runRemoteInstall(keyLine)), "added")
        XCTAssertEqual(try authorizedKeysLines(), [other, keyLine])
    }

    /// A key already on the account behind options (`from=`, `command=`) is
    /// the same key, so an unrestricted copy must not be appended beside it.
    /// Mutation: match only `$2`, as before, and the unrestricted line is added
    /// and the operator's limit no longer applies to that key.
    func testRemoteInstallDoesNotAppendAnUnrestrictedCopyOfARestrictedKey() throws {
        let restricted = "from=\"10.0.0.1\",command=\"false\" \(keyLine)"
        try write(restricted + "\n", to: "\(home!)/.ssh/authorized_keys")
        XCTAssertEqual(lastStdoutLine(try runRemoteInstall(keyLine)), "present")
        XCTAssertEqual(try authorizedKeysLines(), [restricted])
    }

    /// The append exits 0, but its bytes go to `/dev/null`, so `authorized_keys`
    /// gains nothing. The command must not print a success word. The swap is
    /// asserted to match the real command, so a change to that line cannot make
    /// this pass vacuously. The file holds only a commented blob, so the final
    /// scan must skip comments as well. Mutation: print the word after the
    /// append chain without the final scan, and this reads `.added` with
    /// nothing on the account.
    func testRemoteInstallReportsNoSuccessWhenTheAppendLandsNoBytes() throws {
        let commented = "#ssh-ed25519 \(fixtureBlob) deck"
        try write(commented + "\n", to: "\(home!)/.ssh/authorized_keys")
        let append = #"} >> "$HOME/.ssh/authorized_keys" && mark=added"#
        XCTAssertTrue(HostPairing.remoteInstallCommand.contains(append))
        let swapped = HostPairing.remoteInstallCommand.replacingOccurrences(
            of: append, with: #"} >> /dev/null && mark=added"#)

        let outcome = try SSHProcessRunner.run(
            ["-c", swapped], stdin: keyLine + "\n", timeout: 10,
            executable: "/bin/sh", environment: remoteEnvironment)
        let stdout = String(decoding: outcome.stdout, as: UTF8.self)
        let classified = HostPairing.classifyInstall(
            stdout: stdout, stderr: outcome.stderr,
            terminationStatus: outcome.terminationStatus, timedOut: outcome.timedOut)
        guard case .failed = classified else {
            return XCTFail("expected .failed, got \(classified)")
        }
        XCTAssertFalse(stdout.contains("added"), stdout)
        XCTAssertEqual(try authorizedKeysLines(), [commented])
    }

    /// `authorized_keys` is a directory, so the append cannot land. The command
    /// must exit non-zero with no success word, and the classifier must read
    /// that as a failure. Mutation: keep the word after the append chain and
    /// this reports `.added` with nothing on the account.
    func testRemoteInstallFailsLoudlyWhenTheWriteLandsNothing() throws {
        try FileManager.default.createDirectory(
            atPath: "\(home!)/.ssh/authorized_keys", withIntermediateDirectories: true)
        let outcome = try SSHProcessRunner.run(
            ["-c", HostPairing.remoteInstallCommand], stdin: keyLine + "\n", timeout: 10,
            executable: "/bin/sh", environment: remoteEnvironment)
        XCTAssertNotEqual(outcome.terminationStatus, 0)
        let classified = HostPairing.classifyInstall(
            stdout: String(decoding: outcome.stdout, as: UTF8.self), stderr: outcome.stderr,
            terminationStatus: outcome.terminationStatus, timedOut: outcome.timedOut)
        guard case .failed = classified else {
            return XCTFail("expected .failed, got \(classified)")
        }
    }
}
