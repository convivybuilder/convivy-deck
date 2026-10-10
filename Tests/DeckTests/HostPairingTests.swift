import XCTest
@testable import Deck

/// The pure parts of `HostPairing`: argv, the scanned and public key parsers,
/// the fingerprint, the install classification, and the Test-failure gate. No
/// ssh runs here. The fixture key is a throwaway ed25519 public key; its
/// fingerprint was printed by `ssh-keygen -lf` on that same file.
final class HostPairingTests: XCTestCase {
    private let fixtureBlob = "AAAAC3NzaC1lZDI1NTE5AAAAIM6sRsK3amkDYRbuadqksG932D45LU/YS/IHkVcI+jiU"
    private let fixtureFingerprint = "SHA256:Plq+MMWufKltPrjcMwUwzob9upiqvfsR6t9dhF3YfWk"
    private let tailnetHost = "macmini.example.com"
    private var target: SSHTarget { SSHTarget(user: "builder-rehearsal", host: tailnetHost) }
    private let fakeHome = "/fake/account"

    private var fixtureKey: HostPairing.ScannedHostKey {
        .init(type: "ssh-ed25519", blob: fixtureBlob, fingerprint: fixtureFingerprint)
    }

    // MARK: - Argv

    func testKeyscanArgumentsAskForEd25519OnlyAndNamesTheAddress() throws {
        XCTAssertEqual(try HostPairing.keyscanArguments(target: target),
                       ["-T", "5", "-t", "ed25519", tailnetHost])
    }

    /// Mutation: drop the validator call from `keyscanArguments` and a leading
    /// `-` reaches ssh-keyscan as a flag. This must keep throwing.
    func testKeyscanRefusesAnAddressThatLooksLikeAFlag() {
        let hostile = SSHTarget(user: "builder", host: "-oProxyCommand=touch /tmp/x")
        XCTAssertThrowsError(try HostPairing.keyscanArguments(target: hostile))
    }

    func testKeyscanRefusesAUserThatLooksLikeAFlag() {
        let hostile = SSHTarget(user: "-oProxyCommand=x", host: "macmini.local")
        XCTAssertThrowsError(try HostPairing.keyscanArguments(target: hostile))
    }

    func testInstallArgumentsPinTheHostKeyFileAndRefuseUnknownKeys() throws {
        let argv = try HostPairing.installArguments(target: target, home: fakeHome)
        XCTAssertTrue(argv.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(argv.contains("UserKnownHostsFile=\(fakeHome)/.ssh/known_hosts"))
        XCTAssertTrue(argv.contains("ControlPath=none"))
        XCTAssertTrue(argv.contains("ControlMaster=no"))
    }

    func testInstallArgumentsEndWithTheDestinationThenTheFixedRemoteCommand() throws {
        let argv = try HostPairing.installArguments(target: target, home: fakeHome)
        XCTAssertEqual(argv.suffix(2), ["builder-rehearsal@\(tailnetHost)",
                                        HostPairing.remoteInstallCommand])
    }

    /// Mutation: if the password were ever passed as an argument, this is the
    /// line that would show it. The builder takes no password parameter, so
    /// this checks that argv stays free of the variable name and of any
    /// askpass wiring.
    func testInstallArgumentsCarryNoPasswordVariableOrAskpass() throws {
        let argv = try HostPairing.installArguments(target: target, home: fakeHome)
        let joined = argv.joined(separator: " ")
        XCTAssertFalse(joined.contains(HostPairing.passwordVariable))
        XCTAssertFalse(joined.contains("SSH_ASKPASS"))
    }

    func testInstallArgumentsRefuseAnInvalidTarget() {
        let hostile = SSHTarget(user: "-oProxyCommand=x", host: "macmini.local")
        XCTAssertThrowsError(try HostPairing.installArguments(target: hostile, home: fakeHome))
    }

    // MARK: - Remote install command

    /// The key is read from stdin and written with `printf '%s\n' "$key"`,
    /// never spliced into the command. A command that contains a key's blob
    /// would mean the key reached the remote shell's text.
    func testRemoteInstallCommandIsFixedAndHoldsNoKey() {
        let command = HostPairing.remoteInstallCommand
        XCTAssertFalse(command.contains(fixtureBlob))
        XCTAssertTrue(command.contains("read -r key"))
        XCTAssertTrue(command.contains("printf '%s\\n' \"$key\""))
    }

    func testRemoteInstallCommandSetsSSHModesOnEveryRun() {
        let command = HostPairing.remoteInstallCommand
        XCTAssertTrue(command.contains("chmod 700 \"$HOME/.ssh\""))
        XCTAssertTrue(command.contains("chmod 600 \"$HOME/.ssh/authorized_keys\""))
        XCTAssertTrue(command.contains("umask 077"))
    }

    /// Mutation: if the install step appended without checking for the blob, a
    /// second pairing would duplicate the line. The check matches the blob only
    /// where it follows a key-type token, on a line that does not start with
    /// `#`. A changed comment still counts, and a commented-out key or a blob in
    /// another key's comment field does not. Behaviour is pinned by the
    /// `/bin/sh` tests in `HostPairingFilesTests`; this pins the text.
    func testRemoteInstallCommandSkipsAKeyAlreadyPresentByBlob() {
        let command = HostPairing.remoteInstallCommand
        XCTAssertTrue(command.contains("awk -v b=\"$blob\" '$1 !~ /^#/ { for (i = 1; i <= NF; i++) if (i > 1 && $i == b && $(i-1) ~ /^(ssh-|ecdsa-|sk-)/)"))
        XCTAssertTrue(command.contains("mark=present"))
        XCTAssertTrue(command.hasSuffix("&& printf '%s\\n' \"$HOME/.ssh/authorized_keys\" && echo \"$mark\""))
    }

    // MARK: - Environment and askpass

    func testInstallEnvironmentCarriesThePasswordOnlyInTheChildEnvironment() {
        let sentinel = "pw-sentinel-7f3a"
        let env = HostPairing.installEnvironment(
            password: sentinel, askpassPath: "/tmp/deck-pair/askpass.sh",
            base: ["HOME": "\(TestHost.homeRoot)", "PATH": "/usr/bin"])
        XCTAssertEqual(env[HostPairing.passwordVariable], sentinel)
        XCTAssertEqual(env["SSH_ASKPASS"], "/tmp/deck-pair/askpass.sh")
        XCTAssertEqual(env["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(env["HOME"], "\(TestHost.homeRoot)")
    }

    /// The askpass script is written to disk, so it must hold no secret. It
    /// reads the variable and prints it without a trailing newline.
    func testAskpassScriptReadsTheVariableAndHoldsNoSecret() {
        let script = HostPairing.askpassScript
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("\"$DECK_PAIR_PASSWORD\""))
        XCTAssertFalse(script.contains("pw-sentinel"))
    }

    // MARK: - Parsing

    func testParseKeyscanReadsTheEd25519LineAndSkipsComments() throws {
        let text = "# \(tailnetHost):22 SSH-2.0-OpenSSH_10.0\n"
            + "\(tailnetHost) ssh-ed25519 \(fixtureBlob)\n"
        let key = try XCTUnwrap(HostPairing.parseKeyscan(text))
        XCTAssertEqual(key, fixtureKey)
    }

    /// Mutation: accept any key type and a host offering only RSA would pair
    /// with its RSA fingerprint shown as if it were the ed25519 one. Only the
    /// ed25519 line may be trusted.
    func testParseKeyscanRefusesAHostOfferingNoEd25519Key() {
        let text = "macmini.local ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ\n"
        XCTAssertNil(HostPairing.parseKeyscan(text))
    }

    func testParseKeyscanRefusesAnUndecodableBlob() {
        XCTAssertNil(HostPairing.parseKeyscan("macmini.local ssh-ed25519 not*base64!\n"))
    }

    func testFingerprintMatchesSSHKeygenForTheFixture() {
        XCTAssertEqual(HostPairing.fingerprint(forBlob: fixtureBlob), fixtureFingerprint)
    }

    /// The display line must match `ssh-keygen -lf` output for the same key:
    /// `SHA256:<base64> (ED25519)`. Mutation: drop the type suffix, or print it
    /// in lower case, and this goes red.
    func testDisplayFingerprintMatchesSSHKeygenFieldsForTheFixture() {
        XCTAssertEqual(HostPairing.displayFingerprint(fixtureKey),
                       "SHA256:Plq+MMWufKltPrjcMwUwzob9upiqvfsR6t9dhF3YfWk (ED25519)")
    }

    func testFingerprintRefusesANonBase64Blob() {
        XCTAssertNil(HostPairing.fingerprint(forBlob: "%%%"))
    }

    func testKnownHostsLineNamesTheAddressDeckConnectsTo() {
        XCTAssertEqual(HostPairing.knownHostsLine(address: tailnetHost, key: fixtureKey),
                       "\(tailnetHost) ssh-ed25519 \(fixtureBlob)")
    }

    func testParsePublicKeyAcceptsTheFixtureLine() throws {
        let line = "ssh-ed25519 \(fixtureBlob) fixture"
        let key = try XCTUnwrap(HostPairing.parsePublicKey(line + "\n"))
        XCTAssertEqual(key.type, "ssh-ed25519")
        XCTAssertEqual(key.blob, fixtureBlob)
        XCTAssertEqual(key.line, line)
    }

    /// Two lines in a `.pub` file would put a second key, or arbitrary text,
    /// on the remote side. Refuse the file.
    func testParsePublicKeyRefusesMoreThanOneLine() {
        XCTAssertNil(HostPairing.parsePublicKey("ssh-ed25519 \(fixtureBlob)\nssh-ed25519 \(fixtureBlob)\n"))
    }

    func testParsePublicKeyRefusesAnUnknownType() {
        XCTAssertNil(HostPairing.parsePublicKey("ssh-dss \(fixtureBlob)"))
    }

    func testParsePublicKeyRefusesANonBase64Blob() {
        XCTAssertNil(HostPairing.parsePublicKey("ssh-ed25519 not*base64!"))
    }

    func testParsePublicKeyRefusesEmptyContents() {
        XCTAssertNil(HostPairing.parsePublicKey("  \n"))
    }

    // MARK: - Install classification

    private let accountPath = "/Users/" + "builder-rehearsal" + "/.ssh/authorized_keys"

    func testAddedOnTheLastStdoutLineIsAddedWithThePathBeforeIt() {
        XCTAssertEqual(HostPairing.classifyInstall(
            stdout: "\(accountPath)\nadded\n", stderr: "", terminationStatus: 0, timedOut: false),
            .added(path: accountPath))
    }

    func testPresentOnTheLastStdoutLineIsAlreadyPresentWithThePathBeforeIt() {
        XCTAssertEqual(HostPairing.classifyInstall(
            stdout: "\(accountPath)\npresent\n", stderr: "", terminationStatus: 0, timedOut: false),
            .alreadyPresent(path: accountPath))
    }

    /// A success word with no path before it cannot say which file was
    /// written, so it is not read as success.
    func testSuccessWordWithoutAnAbsolutePathIsFailed() {
        let outcome = HostPairing.classifyInstall(
            stdout: "added\n", stderr: "", terminationStatus: 0, timedOut: false)
        if case .failed = outcome {} else { XCTFail("expected .failed, got \(outcome)") }
    }

    /// Mutation: read `added` without checking the exit status and a remote
    /// that printed the word then failed would count as installed.
    func testAddedWithANonZeroExitIsNotSuccess() {
        let outcome = HostPairing.classifyInstall(
            stdout: "\(accountPath)\nadded\n", stderr: "", terminationStatus: 1, timedOut: false)
        if case .failed = outcome {} else { XCTFail("expected .failed, got \(outcome)") }
    }

    func testExitZeroWithNoSuccessWordIsFailed() {
        let outcome = HostPairing.classifyInstall(
            stdout: "", stderr: "", terminationStatus: 0, timedOut: false)
        if case .failed = outcome {} else { XCTFail("expected .failed, got \(outcome)") }
    }

    func testPermissionDeniedIsAPasswordRefusal() {
        XCTAssertEqual(HostPairing.classifyInstall(
            stdout: "", stderr: "builder-rehearsal@macmini: Permission denied (publickey,password).",
            terminationStatus: 255, timedOut: false), .passwordRefused)
    }

    func testRetryPromptIsAPasswordRefusal() {
        XCTAssertEqual(HostPairing.classifyInstall(
            stdout: "", stderr: "Permission denied, please try again.\n",
            terminationStatus: 255, timedOut: false), .passwordRefused)
    }

    /// Mutation: map every "permission denied" to a refused password, and a
    /// remote `touch` that cannot write `authorized_keys` asks for the password
    /// again. The remote's own message must come back as the failure text.
    func testRemoteWriteFailureIsReportedNotAsARefusedPassword() {
        let remote = "touch: " + accountPath + ": Permission denied"
        XCTAssertEqual(HostPairing.classifyInstall(
            stdout: "", stderr: remote + "\n", terminationStatus: 1, timedOut: false),
            .failed(remote))
    }

    func testTimeoutIsFailedWhateverTheStreamsSay() {
        let outcome = HostPairing.classifyInstall(
            stdout: "added\n", stderr: "", terminationStatus: 15, timedOut: true)
        if case .failed = outcome {} else { XCTFail("expected .failed, got \(outcome)") }
    }

    // MARK: - Gate and notes

    func testUnknownHostKeyOffersPairing() {
        XCTAssertTrue(HostPairing.offersPairing(testError: "Host key verification failed."))
    }

    func testRefusedKeyLoginOffersPairing() {
        XCTAssertTrue(HostPairing.offersPairing(testError: "builder@macmini: Permission denied (publickey)."))
    }

    /// Pairing cannot fix a closed port or a dead address, so those must not
    /// offer it.
    func testNetworkFailuresDoNotOfferPairing() {
        XCTAssertFalse(HostPairing.offersPairing(testError: "ssh: connect to host 1.2.3.4 port 22: Connection refused"))
        XCTAssertFalse(HostPairing.offersPairing(testError: "ssh: connect to host 1.2.3.4 port 22: Operation timed out"))
    }

    func testReachableAfterPairingSaysToAddTheHost() {
        XCTAssertEqual(HostPairing.note(afterTest: .reachable(machineName: "macmini")),
                       "Paired. Add the host to finish.")
    }

    /// Mutation: fold the refusal into the unreachable wording, and the
    /// operator is told the host did not answer when it answered and refused.
    func testRefusedTestAfterInstallSaysTheKeyIsInstalledButRefused() {
        XCTAssertEqual(HostPairing.note(afterTest: .refused("Permission denied (publickey).")),
                       "Key installed, but Test was refused: Permission denied (publickey).")
    }

    func testUnreachableTestAfterPairingNamesTheFailure() {
        XCTAssertEqual(HostPairing.note(afterTest: .unreachable("Operation timed out")),
                       "Paired, but Test did not answer: Operation timed out")
    }

    // MARK: - Sheet cancel policy

    /// Pins the policy value only. The view wiring (`.disabled` on Cancel and
    /// `.interactiveDismissDisabled` on the sheet) is not covered by a test:
    /// the file's render tests snapshot pixels and cannot read a button's
    /// disabled state. Reverting the wiring leaves this test green. The
    /// detached step ignores cancellation, so a dismissed sheet still writes
    /// the key and known_hosts with no result shown. This must stay false.
    func testCancelIsOffWhileTrustOrInstallRuns() {
        XCTAssertFalse(HostPairingSheet.Phase.working("Writing the host key to known_hosts\u{2026}").allowsCancel)
        XCTAssertFalse(HostPairingSheet.Phase.working("Installing the key on the account\u{2026}").allowsCancel)
    }

    /// The phases that write nothing keep Cancel, so the operator can always
    /// back out of a prompt or a failure.
    func testCancelStaysOnWhereNothingIsBeingWritten() {
        XCTAssertTrue(HostPairingSheet.Phase.scanning.allowsCancel)
        XCTAssertTrue(HostPairingSheet.Phase.confirm.allowsCancel)
        XCTAssertTrue(HostPairingSheet.Phase.password.allowsCancel)
        XCTAssertTrue(HostPairingSheet.Phase.failed.allowsCancel)
    }
}
