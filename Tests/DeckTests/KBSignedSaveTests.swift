import CryptoKit
import XCTest
@testable import Deck

/// Cross-closure capture of the one message a `SoftwareKey` was asked to
/// sign. A lock rather than a plain `var`: `onSign` is `@Sendable` because
/// `SigningKey` requires `Sendable`, and a lock is what a `@Sendable` closure
/// needs to mutate anything, whether or not this test ever runs concurrently.
private final class SignedMessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _message: Data?
    var message: Data? {
        get { lock.lock(); defer { lock.unlock() }; return _message }
        set { lock.lock(); defer { lock.unlock() }; _message = newValue }
    }
}

/// A software P-256 key standing in for the Secure Enclave — see
/// `SigningKeyTests.swift`'s copy for why the real one cannot run here.
/// Duplicated rather than imported: that one is `private` to its file, and a
/// second small value type costs less than exporting a test-only symbol.
private struct SoftwareKey: SigningKey {
    let key: P256.Signing.PrivateKey
    var failure: Error?
    /// Set to capture the exact bytes this key was asked to sign, so a test
    /// can check the envelope `submit` built without re-deriving it.
    var onSign: (@Sendable (Data) -> Void)?

    var publicKeyX963: Data { key.publicKey.x963Representation }
    var dataRepresentation: Data { key.rawRepresentation }

    func sign(_ message: Data) throws -> Data {
        onSign?(message)
        if let failure { throw failure }
        return try key.signature(for: message).derRepresentation
    }
}

/// Records every ssh call `submit` makes, in order, and answers each from a
/// queue — the "fake transport" the build brief asks for, so the full
/// argv/stdin shape is testable without a real target or a person at a Touch
/// ID sensor.
private final class FakeTransport {
    struct Call { let argv: [String]; let stdin: String? }
    private(set) var calls: [Call] = []
    private var responses: [Result<Data, Error>]

    init(responses: [Result<Data, Error>]) { self.responses = responses }

    func run(_ argv: [String], _ stdin: String?) throws -> Data {
        calls.append(Call(argv: argv, stdin: stdin))
        guard !responses.isEmpty else {
            XCTFail("more ssh calls than the test queued responses for")
            return Data()
        }
        switch responses.removeFirst() {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}

final class KBSignedSaveTests: XCTestCase {

    private let doc = KnowledgeBase.CheckedOutDocument(
        id: "deck/specs/session-pane", content: "# T\n", contentSha: "3acf9780aa451c2f0d0e",
        sourceRef: "projects/deck/specs/session-pane.md", target: TestHost.target)

    private let signedAt = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z

    // MARK: - Envelope bytes, against a fixed vector

    func testEnvelopeBytesMatchTheContractsFixedFormat() {
        let bytes = SignedSaveEnvelope.bytes(
            document: "projects/deck/specs/session-pane.md",
            baseSha: "3acf9780aa451c2f0d0e",
            contentSha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            signedAt: "2027-01-15T08:00:00Z")

        let expected = """
        convivy-kb-save/1
        document:projects/deck/specs/session-pane.md
        base-sha:3acf9780aa451c2f0d0e
        content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        signed-at:2027-01-15T08:00:00Z\n
        """
        XCTAssertEqual(String(data: bytes, encoding: .utf8), expected)
    }

    func testSignedAtStringIsUTCWholeSecondsWithLiteralTAndZ() {
        XCTAssertEqual(SignedSaveEnvelope.signedAtString(signedAt), "2027-01-15T08:00:00Z")
    }

    // MARK: - The hash covers exactly the bytes sent

    func testTheContentHashCoversTheExactBytesSent() {
        let content = "---\nid: deck/specs/session-pane\n---\n\n# T\n"
        let expected = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(SignedSaveEnvelope.contentSha256Hex(content), expected)
    }

    func testBytesTamperedAfterSigningProduceADifferentHash() {
        let signed = "the bytes that were signed\n"
        let tampered = "the bytes that were signed, plus one more line\n"
        XCTAssertNotEqual(
            SignedSaveEnvelope.contentSha256Hex(signed),
            SignedSaveEnvelope.contentSha256Hex(tampered))
    }

    // MARK: - argv shape

    func testWriteRemoteContentFileArgumentsWritesStdinToAFreshPathAndPrintsIt() {
        let argv = KnowledgeBase.writeRemoteContentFileArguments(
            target: TestHost.target, controlPath: "/tmp/cm")
        let script = argv.last!
        XCTAssertTrue(script.contains("mktemp"))
        XCTAssertTrue(script.contains("cat > \"$f\""))
        XCTAssertTrue(script.contains("printf '%s' \"$f\""))
    }

    func testApplyArgumentsSendContentFileProvenancePersonAndNeverEdits() {
        let argv = KnowledgeBase.applyArguments(
            target: TestHost.target, id: "deck/specs/session-pane", baseSha: "3acf9780aa451c2f0d0e",
            contentFilePath: ("/home/" + "operator") + "/.cache/agentctl-deck-saves/deck-save.abc123",
            controlPath: "/tmp/cm")

        XCTAssertTrue(argv.contains("agentctl"))
        XCTAssertTrue(argv.contains("kb"))
        XCTAssertTrue(argv.contains("apply"))
        XCTAssertTrue(argv.contains("'deck/specs/session-pane'"))
        XCTAssertEqual(argv[argv.firstIndex(of: "--base-sha")! + 1], "'3acf9780aa451c2f0d0e'")
        XCTAssertEqual(argv[argv.firstIndex(of: "--provenance")! + 1], "person")
        XCTAssertEqual(argv[argv.firstIndex(of: "--content-file")! + 1],
                       "'" + ("/home/" + "operator") + "/.cache/agentctl-deck-saves/deck-save.abc123'")
        XCTAssertTrue(argv.contains("--allow-overwrite"))
        XCTAssertFalse(argv.contains("--edits"))
        XCTAssertFalse(argv.contains("--edits-file"))
    }

    func testApplyArgumentsQuotesBaseShaAgainstShellMetacharacters() {
        let argv = KnowledgeBase.applyArguments(
            target: TestHost.target, id: "deck/specs/session-pane",
            baseSha: "abc'; rm -rf ~ #",
            contentFilePath: ("/home/" + "operator") + "/.cache/agentctl-deck-saves/deck-save.abc123",
            controlPath: "/tmp/cm")

        XCTAssertEqual(argv[argv.firstIndex(of: "--base-sha")! + 1], "'abc'\\''; rm -rf ~ #'")
    }

    func testCleanupContentFileArgumentsRemovesTheQuotedPath() {
        let argv = KnowledgeBase.cleanupContentFileArguments(
            target: TestHost.target, path: "/tmp/deck-save.abc123", controlPath: "/tmp/cm")
        XCTAssertEqual(argv.suffix(3), ["rm", "-f", "'/tmp/deck-save.abc123'"])
    }

    // MARK: - submit(), end to end against a fake transport

    func testASuccessfulSubmitWritesContentThenAppliesThenCleansUp() throws {
        let remotePath = ("/home/" + "operator") + "/.cache/agentctl-deck-saves/deck-save.xyz789"
        let transport = FakeTransport(responses: [
            .success(Data(remotePath.utf8)), // write
            .success(Data()),                // apply
            .success(Data()),                // cleanup
        ])
        let signedMessage = SignedMessageBox()
        let key = SoftwareKey(key: P256.Signing.PrivateKey(), onSign: { signedMessage.message = $0 })

        let outcome = try KnowledgeBase.submit(
            target: TestHost.target, document: doc, content: "# T\n", signingKey: key,
            certificatePEM: "-----BEGIN CERTIFICATE-----\nMII\n-----END CERTIFICATE-----\n",
            now: signedAt, controlPath: "/tmp/cm", run: transport.run)

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(transport.calls.count, 3)

        // Call 1: the content, verbatim, as stdin — nothing else could carry it,
        // since call 2's stdin is reserved for the signature envelope.
        XCTAssertEqual(transport.calls[0].stdin, "# T\n")

        // Call 2: kb apply, referencing the path call 1 returned, with the
        // signature envelope — never the content — on stdin.
        XCTAssertEqual(transport.calls[1].argv[transport.calls[1].argv.firstIndex(of: "--content-file")! + 1],
                       "'\(remotePath)'")
        let proof = try XCTUnwrap(transport.calls[1].stdin)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(proof.utf8)) as? [String: String])
        XCTAssertEqual(object["proof"], "deck-signature")
        XCTAssertEqual(object["signed_at"], "2027-01-15T08:00:00Z")
        XCTAssertEqual(object.keys.sorted(), ["certificate", "proof", "signature", "signed_at"])

        // Call 3: cleanup of the same path, after the apply call — a defer,
        // proven by it running even though nothing in the do/catch reached it
        // directly.
        XCTAssertEqual(transport.calls[2].argv.suffix(3), ["rm", "-f", "'\(remotePath)'"])

        // The envelope the key actually signed carries the hash of the exact
        // content sent, `sourceRef` (not `id`) as `document`, and the checked-out
        // sha as `base-sha`.
        let expectedHash = SignedSaveEnvelope.contentSha256Hex("# T\n")
        let signedText = try XCTUnwrap(String(data: XCTUnwrap(signedMessage.message), encoding: .utf8))
        XCTAssertTrue(signedText.contains("document:projects/deck/specs/session-pane.md\n"))
        XCTAssertTrue(signedText.contains("base-sha:3acf9780aa451c2f0d0e\n"))
        XCTAssertTrue(signedText.contains("content-sha256:\(expectedHash)\n"))
    }

    func testACancelledPromptSendsNothing() throws {
        let transport = FakeTransport(responses: [])
        var key = SoftwareKey(key: P256.Signing.PrivateKey())
        key.failure = SigningKeyError.cancelled

        let outcome = try KnowledgeBase.submit(
            target: TestHost.target, document: doc, content: "# T\n", signingKey: key,
            certificatePEM: "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n",
            now: signedAt, controlPath: "/tmp/cm", run: transport.run)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(transport.calls.isEmpty, "a cancelled prompt must reach the transport not at all")
    }

    func testAMissingCertificateSendsNothing() throws {
        let transport = FakeTransport(responses: [])
        let key = SoftwareKey(key: P256.Signing.PrivateKey())

        let outcome = try KnowledgeBase.submit(
            target: TestHost.target, document: doc, content: "# T\n", signingKey: key,
            certificatePEM: nil, now: signedAt, controlPath: "/tmp/cm", run: transport.run)

        XCTAssertEqual(outcome, .noCertificate)
        XCTAssertTrue(transport.calls.isEmpty, "no certificate means no signature and no ssh call at all")
    }

    // MARK: - The validity window, checked before anything is signed

    /// A stored certificate PEM with the fixture's window: notBefore
    /// 2026-10-05T03:24:32Z, notAfter 2027-01-03T03:24:32Z.
    private func storedCertificatePEM() throws -> String {
        let fixture = CertificateFixture(subjectKey: P256.Signing.PrivateKey())
        return String(decoding: CertificateFixture.pem(try fixture.der()), as: UTF8.self)
    }

    private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testACertificatePastNotAfterSendsNothingAndNeverAsksTheKeyToSign() throws {
        let transport = FakeTransport(responses: [])
        let signedMessage = SignedMessageBox()
        let key = SoftwareKey(key: P256.Signing.PrivateKey(), onSign: { signedMessage.message = $0 })

        let outcome = try KnowledgeBase.submitIfCurrent(
            target: TestHost.target, document: doc, content: "# T\n", signingKey: key,
            certificatePEM: try storedCertificatePEM(), now: instant("2027-01-04T00:00:00Z"),
            controlPath: "/tmp/cm", run: transport.run)

        XCTAssertEqual(outcome, .outsideValidity(.expired(notAfter: instant("2027-01-03T03:24:32Z"))))
        XCTAssertTrue(transport.calls.isEmpty, "an expired certificate must reach the transport not at all")
        XCTAssertNil(signedMessage.message, "an expired certificate must not reach the key")
    }

    func testACertificateBeforeNotBeforeSendsNothingAndNeverAsksTheKeyToSign() throws {
        let transport = FakeTransport(responses: [])
        let signedMessage = SignedMessageBox()
        let key = SoftwareKey(key: P256.Signing.PrivateKey(), onSign: { signedMessage.message = $0 })

        let outcome = try KnowledgeBase.submitIfCurrent(
            target: TestHost.target, document: doc, content: "# T\n", signingKey: key,
            certificatePEM: try storedCertificatePEM(), now: instant("2026-10-05T03:24:31Z"),
            controlPath: "/tmp/cm", run: transport.run)

        XCTAssertEqual(outcome, .outsideValidity(.notYetValid(notBefore: instant("2026-10-05T03:24:32Z"))))
        XCTAssertTrue(transport.calls.isEmpty, "a not-yet-valid certificate must reach the transport not at all")
        XCTAssertNil(signedMessage.message, "a not-yet-valid certificate must not reach the key")
    }

    func testACertificateInsideItsWindowSignsAndSends() throws {
        let remotePath = ("/home/" + "operator") + "/.cache/agentctl-deck-saves/deck-save.window"
        let transport = FakeTransport(responses: [
            .success(Data(remotePath.utf8)), // write
            .success(Data()),                // apply
            .success(Data()),                // cleanup
        ])
        let signedMessage = SignedMessageBox()
        let key = SoftwareKey(key: P256.Signing.PrivateKey(), onSign: { signedMessage.message = $0 })

        let outcome = try KnowledgeBase.submitIfCurrent(
            target: TestHost.target, document: doc, content: "# T\n", signingKey: key,
            certificatePEM: try storedCertificatePEM(), now: instant("2026-11-01T00:00:00Z"),
            controlPath: "/tmp/cm", run: transport.run)

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(transport.calls.count, 3)
        XCTAssertNotNil(signedMessage.message, "a current certificate must reach the key")
    }

    func testTheWindowIncludesBothEndInstants() throws {
        for moment in ["2026-10-05T03:24:32Z", "2027-01-03T03:24:32Z"] {
            let transport = FakeTransport(responses: [
                .success(Data((("/home/" + "operator") + "/.cache/agentctl-deck-saves/deck-save.edge").utf8)),
                .success(Data()),
                .success(Data()),
            ])
            let key = SoftwareKey(key: P256.Signing.PrivateKey())

            let outcome = try KnowledgeBase.submitIfCurrent(
                target: TestHost.target, document: doc, content: "# T\n", signingKey: key,
                certificatePEM: try storedCertificatePEM(), now: instant(moment),
                controlPath: "/tmp/cm", run: transport.run)

            XCTAssertEqual(outcome, .sent, "\(moment) is inside the window, inclusive at both ends")
        }
    }

    func testARefusalFromKBApplyIsReportedAndStillCleansUp() throws {
        let remotePath = ("/home/" + "operator") + "/.cache/agentctl-deck-saves/deck-save.refused"
        let transport = FakeTransport(responses: [
            .success(Data(remotePath.utf8)),
            .failure(SessionAgent.AgentError.failed("kb apply: refused — stale base sha")),
            .success(Data()),
        ])
        let key = SoftwareKey(key: P256.Signing.PrivateKey())

        let outcome = try KnowledgeBase.submit(
            target: TestHost.target, document: doc, content: "# T\n", signingKey: key,
            certificatePEM: "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n",
            now: signedAt, controlPath: "/tmp/cm", run: transport.run)

        XCTAssertEqual(outcome, .refused("kb apply: refused — stale base sha"))
        XCTAssertEqual(transport.calls.count, 3, "the scratch file is still cleaned up after a refusal")
    }
}
