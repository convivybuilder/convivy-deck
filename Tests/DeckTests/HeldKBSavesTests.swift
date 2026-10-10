import CryptoKit
import Darwin
import XCTest
@testable import Deck

/// A thread-safe, ordered record of strings, such as the prompt reason of each
/// signature a `SoftwareKey` was asked for. A lock because `SigningKey` requires
/// `Sendable`, and a notification observer may run off the test's thread.
private final class SigningLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var reasons: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func record(_ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(reason)
    }
}

/// A software P-256 key standing in for the Secure Enclave, as `KBSignedSaveTests`
/// does: the real key cannot sign under XCTest without a person at the sensor.
/// `log` records each call that reaches the key, so a test can assert the key was
/// never asked to sign.
private struct SoftwareKey: SigningKey {
    let key = P256.Signing.PrivateKey()
    let log = SigningLog()
    var failure: Error?

    var publicKeyX963: Data { key.publicKey.x963Representation }
    var dataRepresentation: Data { key.rawRepresentation }

    func sign(_ message: Data) throws -> Data {
        log.record("")
        return try signing(message)
    }

    func sign(_ message: Data, reason: String) throws -> Data {
        log.record(reason)
        return try signing(message)
    }

    private func signing(_ message: Data) throws -> Data {
        if let failure { throw failure }
        return try key.signature(for: message).derRepresentation
    }
}

/// Records every ssh call `submit` makes and answers each from a queue.
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

final class HeldKBSavesTests: XCTestCase {
    private var directory: URL!
    /// Stands in for `WorkingCopyStore.directory(forKBId:)`, the directory every
    /// draft of this document must sit in.
    private var workingCopy: URL!
    private var certificatePEM = ""

    private let heldAt = ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!
    /// Inside the fixture certificate's window: notBefore 2026-10-05, notAfter 2027-01-03.
    private let inWindow = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
    private let afterWindow = ISO8601DateFormatter().date(from: "2027-01-04T00:00:00Z")!

    private let document = KnowledgeBase.CheckedOutDocument(
        id: "deck/specs/session-pane", content: "# Held\n", contentSha: "3acf9780aa451c2f0d0e",
        sourceRef: "projects/deck/specs/session-pane.md", target: TestHost.target)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("held-kb-saves-\(UUID().uuidString)", isDirectory: true)
        workingCopy = directory.appendingPathComponent("working-copy", isDirectory: true)
        try FileManager.default.createDirectory(at: workingCopy, withIntermediateDirectories: true)
        let fixture = CertificateFixture(subjectKey: P256.Signing.PrivateKey())
        certificatePEM = String(decoding: CertificateFixture.pem(try fixture.der()), as: UTF8.self)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("held-kb-saves.json") }

    /// Writes `content` where `KnowledgeBase.saveLocally` would, and returns its path.
    private func writeDraft(_ content: String, named name: String = "session-pane.draft.md") throws -> String {
        let url = workingCopy.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func hash(_ content: String) -> String {
        SignedSaveEnvelope.contentSha256Hex(content)
    }

    private func held(draftPath: String, content: String = "# Held\n") -> HeldKBSave {
        HeldKBSave(document: document, draftSha256: hash(content), draftPath: draftPath, heldAt: heldAt)
    }

    /// Sends `saves` against the fixture certificate, at a moment inside its window
    /// unless the test says otherwise, to the configured host.
    private func send(
        _ saves: [HeldKBSave], store: HeldKBSaveStore, key: SigningKey,
        certificatePEM: String? = nil, now: Date? = nil,
        configured: [SSHTarget] = [TestHost.target],
        run: ([String], String?) throws -> Data
    ) -> HeldKBSaves.SendBatch {
        HeldKBSaves.send(
            saves, store: store, signingKey: key,
            certificatePEM: certificatePEM ?? self.certificatePEM,
            configuredTargets: configured, now: now ?? inWindow,
            draftDirectory: { _ in self.workingCopy }, run: run)
    }

    func testExpiredHoldIsRecordedAndSurvivesAReload() throws {
        let draft = try writeDraft("# Held\n")
        try HeldKBSaves.holdIfExpired(.outsideValidity(.expired(notAfter: heldAt)),
                                      document: document, content: "# Held\n", draftPath: draft,
                                      heldAt: heldAt, store: HeldKBSaveStore(fileURL: storeURL))

        // A new store on the same file stands in for a Deck restart.
        let reloaded = try HeldKBSaveStore(fileURL: storeURL).all()
        XCTAssertEqual(reloaded, [held(draftPath: draft)])
        XCTAssertEqual(reloaded.first?.target, TestHost.target)
        XCTAssertEqual(reloaded.first?.contentSha, "3acf9780aa451c2f0d0e")
        XCTAssertEqual(reloaded.first?.draftSha256, hash("# Held\n"))
    }

    func testOnlyAnExpiryHoldIsQueued() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        let notQueued: [KnowledgeBase.SignedSaveOutcome] = [
            .noCertificate, .cancelled, .refused("kb apply: refused"), .sent,
        ]
        for outcome in notQueued {
            try HeldKBSaves.holdIfExpired(outcome, document: document, content: "# Held\n",
                                          draftPath: draft, heldAt: heldAt, store: store)
        }
        XCTAssertEqual(try store.all(), [])

        // Positive control: the same call does record an expiry hold.
        try HeldKBSaves.holdIfExpired(.outsideValidity(.notYetValid(notBefore: heldAt)),
                                      document: document, content: "# Held\n", draftPath: draft,
                                      heldAt: heldAt, store: store)
        XCTAssertEqual(try store.all().count, 1)
    }

    func testALaterHoldOfTheDocumentReplacesTheEarlierOne() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        try HeldKBSaves.holdIfExpired(.outsideValidity(.expired(notAfter: heldAt)),
                                      document: document, content: "# Held\n", draftPath: draft,
                                      heldAt: heldAt, store: store)

        // The person saves again while the certificate is still outside its window.
        try HeldKBSaves.holdIfExpired(.outsideValidity(.expired(notAfter: heldAt)),
                                      document: document, content: "# Edited\n", draftPath: draft,
                                      heldAt: heldAt, store: store)

        let saves = try store.all()
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(saves.first?.draftSha256, hash("# Edited\n"))
    }

    func testSendAfterImportLeavesTheListAndSignsTheEnvelope() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: draft))
        let key = SoftwareKey()
        let transport = FakeTransport(responses: [
            .success(Data("/remote/deck-save.1\n".utf8)), // write content file
            .success(Data()),                             // kb apply
            .success(Data()),                             // cleanup
        ])

        let batch = send(try store.all(), store: store, key: key, run: transport.run)

        XCTAssertEqual(batch.results.map(\.outcome), [.sent])
        XCTAssertNil(batch.storeError)
        XCTAssertEqual(try store.all(), [])
        let apply = transport.calls[1]
        XCTAssertTrue(apply.argv.joined(separator: " ").contains("3acf9780aa451c2f0d0e"))

        // The proof on kb apply's stdin verifies against the envelope for this save.
        let proof = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(apply.stdin).utf8)) as? [String: String])
        let signature = try P256.Signing.ECDSASignature(derRepresentation: try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(proof["signature"]))))
        let envelope = SignedSaveEnvelope.bytes(
            document: document.sourceRef, baseSha: document.contentSha,
            contentSha256: hash("# Held\n"), signedAt: try XCTUnwrap(proof["signed_at"]))
        XCTAssertTrue(key.key.publicKey.isValidSignature(signature, for: envelope))
    }

    func testEachSendAsksOnceAndThePromptNamesTheDocument() throws {
        let other = KnowledgeBase.CheckedOutDocument(
            id: "deck/specs/other", content: "# Other\n", contentSha: "bbbb", sourceRef: "projects/deck/specs/other.md",
            target: TestHost.target)
        let draftA = try writeDraft("# Held\n")
        let draftB = try writeDraft("# Other\n", named: "other.draft.md")
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: draftA))
        try store.record(HeldKBSave(document: other, draftSha256: hash("# Other\n"),
                                    draftPath: draftB, heldAt: heldAt))
        let key = SoftwareKey()
        let transport = FakeTransport(responses: (0..<6).map { _ in
            Result<Data, Error>.success(Data("/remote/deck-save.n\n".utf8))
        })

        _ = send(try store.all(), store: store, key: key, run: transport.run)

        // One press per save: two saves, two prompts, each naming its own document.
        let reasons = key.log.reasons
        XCTAssertEqual(reasons.count, 2)
        XCTAssertTrue(reasons[0].contains(document.id))
        XCTAssertTrue(reasons[1].contains(other.id))
        XCTAssertTrue(reasons.allSatisfy { $0.contains("held save") && $0.contains("knowledge base") })
    }

    func testStaleBaseRefusalStaysOnTheListWithItsReasonAcrossAReload() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: draft))
        let stderr = "kb apply: base-sha 3acf9780aa451c2f0d0e is stale; the document moved"
        let transport = FakeTransport(responses: [
            .success(Data("/remote/deck-save.1\n".utf8)),
            .failure(SessionAgent.AgentError.failed(stderr)),
            .success(Data()),
        ])

        let batch = send(try store.all(), store: store, key: SoftwareKey(), run: transport.run)

        XCTAssertEqual(batch.results.map(\.outcome), [.refused(stderr)])
        XCTAssertEqual(batch.results.first?.summary, "\(document.id) not sent: \(stderr)")
        let reloaded = try HeldKBSaveStore(fileURL: storeURL).all()
        XCTAssertEqual(reloaded.map(\.reason), [stderr])
    }

    func testRetryOfARefusedSaveSendsItAndClearsTheList() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: draft))
        let refusal = FakeTransport(responses: [
            .success(Data("/remote/deck-save.1\n".utf8)),
            .failure(SessionAgent.AgentError.failed("stale")),
            .success(Data()),
        ])
        _ = send(try store.all(), store: store, key: SoftwareKey(), run: refusal.run)
        XCTAssertEqual(try store.all().map(\.reason), ["stale"])

        let retry = FakeTransport(responses: [
            .success(Data("/remote/deck-save.2\n".utf8)),
            .success(Data()),
            .success(Data()),
        ])
        let batch = send(try store.all(), store: store, key: SoftwareKey(), run: retry.run)

        XCTAssertEqual(batch.results.map(\.outcome), [.sent])
        XCTAssertEqual(try HeldKBSaveStore(fileURL: storeURL).all(), [])
    }

    func testCancelledPromptStaysOnTheListWithItsReasonAndNothingIsSent() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: draft))
        let transport = FakeTransport(responses: [])

        let batch = send(try store.all(), store: store,
                         key: SoftwareKey(failure: SigningKeyError.cancelled), run: transport.run)

        XCTAssertEqual(batch.results.map(\.outcome), [.cancelled])
        XCTAssertTrue(transport.calls.isEmpty, "a cancelled prompt must not reach ssh")
        XCTAssertEqual(try store.all().map(\.reason),
                       ["The Touch ID prompt was cancelled. Nothing was sent."])
    }

    func testMissingDraftStaysOnTheListWithItsReason() throws {
        let store = HeldKBSaveStore(fileURL: storeURL)
        // The derived path for this document, never written.
        let gone = workingCopy.appendingPathComponent("session-pane.draft.md").path
        try store.record(held(draftPath: gone))
        let transport = FakeTransport(responses: [])

        let batch = send(try store.all(), store: store, key: SoftwareKey(), run: transport.run)

        XCTAssertEqual(batch.results.count, 1)
        guard case .refused(let why) = batch.results[0].outcome else {
            return XCTFail("expected a refusal, got \(batch.results[0].outcome)")
        }
        XCTAssertTrue(why.contains("could not be read"))
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertEqual(try store.all().count, 1)
    }

    // MARK: - The checks before anything is signed

    func testAnExpiredStoredCertificateSendsNothingAndNeverAsksTheKeyToSign() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: draft))
        let key = SoftwareKey()
        let transport = FakeTransport(responses: [])

        let batch = send(try store.all(), store: store, key: key, now: afterWindow, run: transport.run)

        XCTAssertEqual(batch.results.map(\.outcome),
                       [.refused("the signing certificate is outside its validity window")])
        XCTAssertTrue(transport.calls.isEmpty, "an expired certificate must reach ssh not at all")
        XCTAssertTrue(key.log.reasons.isEmpty, "an expired certificate must not reach the key")
        XCTAssertEqual(try store.all().map(\.reason),
                       ["the signing certificate is outside its validity window"])
    }

    func testAModifiedDraftIsRefusedAndNeverSigned() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: draft))
        // Someone edits the draft after the save was held, outside Deck.
        _ = try writeDraft("# Edited after the hold\n")
        let key = SoftwareKey()
        let transport = FakeTransport(responses: [])

        let batch = send(try store.all(), store: store, key: key, run: transport.run)

        guard case .refused(let why) = batch.results.first?.outcome else {
            return XCTFail("expected a refusal, got \(String(describing: batch.results.first?.outcome))")
        }
        XCTAssertTrue(why.contains("changed after this save was held"), why)
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertTrue(key.log.reasons.isEmpty, "a changed draft must not reach the key")
        XCTAssertEqual(try store.all().count, 1, "the save stays on the list")
        XCTAssertEqual(try store.all().first?.reason, why)
    }

    // `attempt` now derives the path it reads from the document id (see
    // `testADraftPathForAnotherDocumentIsRefusedAndNeverSigned`), so a record naming
    // a path outside the working copy is refused by that cross-check before
    // `HeldDraftFile` is reached. This test calls `HeldDraftFile.readDraft` directly
    // and never sends, so it checks only `HeldDraftFile`'s own containment refusal.
    func testReadDraftRefusesAFileOutsideTheWorkingCopy() throws {
        let outside = directory.appendingPathComponent("elsewhere.draft.md")
        try "# Held\n".write(to: outside, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try HeldDraftFile.readDraft(at: outside.path, inside: workingCopy)) { error in
            XCTAssertEqual(error as? HeldDraftFile.Failure, .outsideWorkingCopy)
        }
    }

    func testASymlinkAtTheDraftLeafIsRefusedAndNeverSigned() throws {
        // The bytes match the hold, so only the leaf check can refuse this one.
        let outside = directory.appendingPathComponent("elsewhere.md")
        try "# Held\n".write(to: outside, atomically: true, encoding: .utf8)
        let link = workingCopy.appendingPathComponent("session-pane.draft.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: link.path))
        let key = SoftwareKey()
        let transport = FakeTransport(responses: [])

        let batch = send(try store.all(), store: store, key: key, run: transport.run)

        guard case .refused(let why) = batch.results.first?.outcome else {
            return XCTFail("expected a refusal, got \(String(describing: batch.results.first?.outcome))")
        }
        XCTAssertTrue(why.contains("is not a regular file"), why)
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertTrue(key.log.reasons.isEmpty, "a symlink at the leaf must not reach the key")
    }

    // Reached directly, as the comment above
    // `testReadDraftRefusesAFileOutsideTheWorkingCopy` explains: `attempt`'s
    // derived path never has a symlinked directory in the middle, so this exercises
    // `HeldDraftFile`'s own check rather than `attempt`'s.
    func testADraftReachedThroughASymlinkedDirectoryOutsideTheWorkingCopyIsRefused() throws {
        let outsideDirectory = directory.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try "# Held\n".write(to: outsideDirectory.appendingPathComponent("session-pane.draft.md"),
                             atomically: true, encoding: .utf8)
        let linkedDirectory = workingCopy.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: outsideDirectory)
        let draftPath = linkedDirectory.appendingPathComponent("session-pane.draft.md").path

        XCTAssertThrowsError(try HeldDraftFile.readDraft(at: draftPath, inside: workingCopy)) { error in
            XCTAssertEqual(error as? HeldDraftFile.Failure, .outsideWorkingCopy)
        }
    }

    func testAHardLinkInTheWorkingCopyToAFileOutsideItIsRefusedAndNeverSigned() throws {
        // The hard link sits inside the working copy, so a path check passes. The
        // file's second name is what refuses it, and the hash is the outside file's
        // own, as a forged record would carry.
        let outside = directory.appendingPathComponent("llm-gateway.env")
        try "TOKEN=not-a-draft\n".write(to: outside, atomically: true, encoding: .utf8)
        let link = workingCopy.appendingPathComponent("session-pane.draft.md")
        try FileManager.default.linkItem(at: outside, to: link)
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: link.path, content: "TOKEN=not-a-draft\n"))
        let key = SoftwareKey()
        let transport = FakeTransport(responses: [])

        let batch = send(try store.all(), store: store, key: key, run: transport.run)

        guard case .refused(let why) = batch.results.first?.outcome else {
            return XCTFail("expected a refusal, got \(String(describing: batch.results.first?.outcome))")
        }
        XCTAssertTrue(why.contains("another hard link"), why)
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertTrue(key.log.reasons.isEmpty, "a hard-linked draft must not reach the key")
        XCTAssertEqual(try store.all().count, 1, "the save stays on the list")
    }

    func testAFIFOAtTheLeafIsRefusedPromptly() throws {
        // A same-user process could swap a FIFO into the leaf in the window between
        // the pre-open `fstatat` check and the open. `O_NONBLOCK` on that open keeps
        // it from blocking on a FIFO with no writer. This test checks only the
        // pre-open `fstatat` refusal: that check refuses the FIFO already in place
        // before `openat` is reached, so `O_NONBLOCK` is never exercised here. The
        // flag covers only the race window between that check and the open, and no
        // test covers that window. The expectation bounds the call so a hang fails.
        let fifoPath = workingCopy.appendingPathComponent("session-pane.draft.md").path
        XCTAssertEqual(mkfifo(fifoPath, 0o600), 0, "mkfifo failed: \(String(cString: strerror(errno)))")

        let outcomes = SigningLog()
        let finished = expectation(description: "readDraft returns")
        DispatchQueue.global().async {
            do {
                _ = try HeldDraftFile.readDraft(at: fifoPath, inside: self.workingCopy)
                outcomes.record("no-throw")
            } catch let failure as HeldDraftFile.Failure {
                outcomes.record("\(failure)")
            } catch {
                outcomes.record("other: \(error)")
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(outcomes.reasons, ["notRegularFile"])
    }

    func testAnInvalidDocumentIdIsRefusedBeforeAnyPrompt() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        let invalid = KnowledgeBase.CheckedOutDocument(
            id: "deck/specs/Session Pane", content: "# Held\n", contentSha: document.contentSha,
            sourceRef: document.sourceRef, target: TestHost.target)
        try store.record(HeldKBSave(document: invalid, draftSha256: hash("# Held\n"),
                                    draftPath: draft, heldAt: heldAt))
        let key = SoftwareKey()
        let transport = FakeTransport(responses: [])

        let batch = send(try store.all(), store: store, key: key, run: transport.run)

        guard case .refused(let why) = batch.results.first?.outcome else {
            return XCTFail("expected a refusal, got \(String(describing: batch.results.first?.outcome))")
        }
        XCTAssertTrue(why.contains("not a knowledge-base id"), why)
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertTrue(key.log.reasons.isEmpty, "an invalid document id must not reach the prompt")
    }

    func testASourceRefContainingALineBreakIsRefusedBeforeAnyPrompt() throws {
        // "\r\n" is one Character, so CRLF is the case a per-character "\n" or "\r"
        // check misses. Each break is tried alone too, so a guard that drops one of
        // the three fails here.
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        let path = "projects/deck/specs/session-pane.md"
        for lineBreak in ["\n", "\r", "\r\n"] {
            let tampered = KnowledgeBase.CheckedOutDocument(
                id: document.id, content: document.content, contentSha: document.contentSha,
                sourceRef: path + lineBreak + "rm -rf /", target: TestHost.target)
            try store.record(HeldKBSave(document: tampered, draftSha256: hash("# Held\n"),
                                        draftPath: draft, heldAt: heldAt))
            let key = SoftwareKey()
            let transport = FakeTransport(responses: [])

            let batch = send(try store.all(), store: store, key: key, run: transport.run)

            guard case .refused(let why) = batch.results.first?.outcome else {
                return XCTFail("\(String(reflecting: lineBreak)): expected a refusal, got "
                    + "\(String(describing: batch.results.first?.outcome))")
            }
            XCTAssertTrue(why.contains("line break"), "\(String(reflecting: lineBreak)): \(why)")
            XCTAssertTrue(transport.calls.isEmpty, String(reflecting: lineBreak))
            XCTAssertTrue(key.log.reasons.isEmpty,
                          "a sourceRef with \(String(reflecting: lineBreak)) must not reach the prompt")
        }
    }

    func testADraftPathForAnotherDocumentIsRefusedAndNeverSigned() throws {
        // The record names this document, but `draftPath` is another document's
        // draft in the same working copy, hashing to the value a forged record
        // would carry for it.
        let other = try writeDraft("# Held\n", named: "another-document.draft.md")
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: other))
        let key = SoftwareKey()
        let transport = FakeTransport(responses: [])

        let batch = send(try store.all(), store: store, key: key, run: transport.run)

        guard case .refused(let why) = batch.results.first?.outcome else {
            return XCTFail("expected a refusal, got \(String(describing: batch.results.first?.outcome))")
        }
        XCTAssertTrue(why.contains("does not match its working copy"), why)
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertTrue(key.log.reasons.isEmpty, "a draftPath for another document must not reach the key")
    }

    func testAHostOrUserOutsideTheHostsSettingsIsRefusedAndNeverSigned() throws {
        let draft = try writeDraft("# Held\n")
        let cases: [(target: SSHTarget, reason: String)] = [
            (SSHTarget(user: TestHost.user, host: "198.51.100.9"), "is not a host in Deck's Hosts settings"),
            (SSHTarget(user: "-oProxyCommand=touch", host: TestHost.address), "is not a valid ssh target"),
        ]
        for (target, reason) in cases {
            let store = HeldKBSaveStore(fileURL: directory.appendingPathComponent("\(UUID().uuidString).json"))
            let other = KnowledgeBase.CheckedOutDocument(
                id: document.id, content: document.content, contentSha: document.contentSha,
                sourceRef: document.sourceRef, target: target)
            try store.record(HeldKBSave(document: other, draftSha256: hash("# Held\n"),
                                        draftPath: draft, heldAt: heldAt))
            let key = SoftwareKey()
            let transport = FakeTransport(responses: [])

            let batch = send(try store.all(), store: store, key: key, run: transport.run)

            guard case .refused(let why) = batch.results.first?.outcome else {
                return XCTFail("expected a refusal for \(target), got \(String(describing: batch.results.first?.outcome))")
            }
            XCTAssertTrue(why.contains(reason), why)
            XCTAssertTrue(transport.calls.isEmpty, "\(target) must not reach ssh")
            XCTAssertTrue(key.log.reasons.isEmpty, "\(target) must not reach the key")
        }
    }

    // MARK: - A record read at send time against a store that changes meanwhile

    func testAHoldRecordedDuringASuccessfulSendSurvivesIt() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        let original = held(draftPath: draft)
        try store.record(original)
        let newer = newerHold(draftPath: draft)

        var calls = 0
        let batch = send(try store.all(), store: store, key: SoftwareKey(), run: { _, _ in
            calls += 1
            switch calls {
            case 1: return Data("/remote/deck-save.1\n".utf8)
            case 2:
                // The person saves again while kb apply runs, and the editor holds it.
                try "# Edited\n".write(toFile: draft, atomically: true, encoding: .utf8)
                try store.record(newer)
                return Data()
            default: return Data()
            }
        })

        XCTAssertEqual(batch.results.map(\.outcome), [.sent])
        XCTAssertEqual(try store.all(), [newer], "the newer hold must not be deleted or overwritten")
    }

    func testAHoldRecordedDuringARefusedSendIsNotOverwrittenWithTheStaleOne() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: draft))
        let newer = newerHold(draftPath: draft)

        var calls = 0
        let batch = send(try store.all(), store: store, key: SoftwareKey(), run: { _, _ in
            calls += 1
            switch calls {
            case 1: return Data("/remote/deck-save.1\n".utf8)
            case 2:
                try "# Edited\n".write(toFile: draft, atomically: true, encoding: .utf8)
                try store.record(newer)
                throw SessionAgent.AgentError.failed("stale")
            default: return Data()
            }
        })

        XCTAssertEqual(batch.results.map(\.outcome), [.refused("stale")])
        XCTAssertEqual(try store.all(), [newer],
                       "the refusal must not replace the newer hold with the stale one")
    }

    /// A hold for the same document recorded while a send is in flight: new base
    /// sha and new draft bytes.
    private func newerHold(draftPath: String) -> HeldKBSave {
        let newerDocument = KnowledgeBase.CheckedOutDocument(
            id: document.id, content: "# Edited\n", contentSha: "9f1e0c2d7a6b5a4f3e2d1c0b9a8f7e6d",
            sourceRef: document.sourceRef, target: TestHost.target)
        return HeldKBSave(document: newerDocument, draftSha256: hash("# Edited\n"),
                          draftPath: draftPath, heldAt: heldAt)
    }

    // MARK: - A direct save of the document clears its hold

    func testADirectSaveOfTheSameDocumentClearsItsHold() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: draft))

        try store.removeHolds(documentId: document.id, target: TestHost.target)

        XCTAssertEqual(try store.all(), [], "a direct save that reached the knowledge base clears the older hold")
    }

    func testADirectSaveOfAnotherDocumentOrOnAnotherHostLeavesTheHold() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        let original = held(draftPath: draft)
        try store.record(original)

        try store.removeHolds(documentId: "deck/specs/another-document", target: TestHost.target)
        XCTAssertEqual(try store.all(), [original], "a different document keeps its hold")

        try store.removeHolds(documentId: document.id, target: TestHost.secondaryTarget)
        XCTAssertEqual(try store.all(), [original], "the same document on a different host keeps its hold")
    }

    func testTheEditorsDirectSaveStepClearsTheHoldAndTellsSettings() throws {
        let draft = try writeDraft("# Held\n")
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(held(draftPath: draft))
        let center = NotificationCenter()
        let notifications = SigningLog()
        let observer = center.addObserver(forName: .heldKBSavesDidChange, object: nil, queue: nil) { _ in
            notifications.record("posted")
        }
        defer { center.removeObserver(observer) }

        HeldKBSaves.clearHoldsAfterDirectSave(documentId: document.id, target: TestHost.target,
                                              store: store, center: center)

        XCTAssertEqual(try store.all(), [], "the direct save clears the hold the editor's step is for")
        XCTAssertEqual(notifications.reasons, ["posted"], "an open Settings list reloads once")
    }

    // MARK: - A store failure mid-batch

    func testAStoreFailureMidBatchStillReportsTheSendsAlreadyMade() throws {
        let draftA = try writeDraft("# A\n", named: "a.draft.md")
        let draftB = try writeDraft("# B\n", named: "b.draft.md")
        let docA = KnowledgeBase.CheckedOutDocument(
            id: "deck/specs/a", content: "# A\n", contentSha: "aaaa", sourceRef: "projects/deck/specs/a.md",
            target: TestHost.target)
        let docB = KnowledgeBase.CheckedOutDocument(
            id: "deck/specs/b", content: "# B\n", contentSha: "bbbb", sourceRef: "projects/deck/specs/b.md",
            target: TestHost.target)
        let store = HeldKBSaveStore(fileURL: storeURL)
        try store.record(HeldKBSave(document: docA, draftSha256: hash("# A\n"), draftPath: draftA, heldAt: heldAt))
        try store.record(HeldKBSave(document: docB, draftSha256: hash("# B\n"), draftPath: draftB, heldAt: heldAt))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        // A's three calls go through. Then B's first call makes the store's directory
        // read-only, so B's refusal cannot be written back to the store. The store is
        // written atomically through a temporary file, which that directory now refuses.
        var calls = 0
        let batch = send(try store.all(), store: store, key: SoftwareKey(), run: { _, _ in
            calls += 1
            switch calls {
            case 1: return Data("/remote/deck-save.a\n".utf8)              // A: write content file
            case 2: return Data()                                           // A: kb apply
            case 4:                                                         // B: write content file
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: self.directory.path)
                return Data("/remote/deck-save.b\n".utf8)
            case 5: throw SessionAgent.AgentError.failed("stale")          // B: kb apply
            default: return Data()                                          // cleanups
            }
        })

        XCTAssertEqual(batch.results.map(\.outcome), [.sent, .refused("stale")],
                       "the send that went out is reported even though the batch then stopped")
        XCTAssertNotNil(batch.storeError)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(try store.all().map(\.documentId), [docB.id],
                       "A left the store; B was not updated because the store could not be written")
    }

    func testUnparseableStoreThrowsRatherThanReadingAsEmpty() throws {
        try Data("not json".utf8).write(to: storeURL)
        XCTAssertThrowsError(try HeldKBSaveStore(fileURL: storeURL).all()) { error in
            guard case HeldKBSaveError.storage = error else {
                return XCTFail("expected a storage error, got \(error)")
            }
        }
    }
}
