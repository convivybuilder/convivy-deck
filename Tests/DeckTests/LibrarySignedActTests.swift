import CryptoKit
import XCTest
@testable import Deck

/// A software P-256 key standing in for the Secure Enclave, as `HeldKBSavesTests`'
/// own `SoftwareKey` does: the real key cannot sign under XCTest without a
/// person at the sensor. `failure` makes every `sign` call throw it — set to
/// `SigningKeyError.cancelled` to stand in for a dismissed Touch ID prompt.
private final class FakeSigningKey: SigningKey, @unchecked Sendable {
    let key = P256.Signing.PrivateKey()
    var failure: Error?
    private let lock = NSLock()
    private var reasons: [String] = []

    var signReasons: [String] { lock.lock(); defer { lock.unlock() }; return reasons }
    var publicKeyX963: Data { key.publicKey.x963Representation }
    var dataRepresentation: Data { key.rawRepresentation }

    func sign(_ message: Data) throws -> Data { try sign(message, reason: "") }

    func sign(_ message: Data, reason: String) throws -> Data {
        lock.lock(); reasons.append(reason); lock.unlock()
        if let failure { throw failure }
        return try key.signature(for: message).derRepresentation
    }
}

/// Records every call `performSignedAct` makes — now exactly one, the signed
/// `POST`, since CQ·209 removed the fresh `GET /items/{id}` that used to
/// precede it — and answers each from a queue, the same single-shot shape
/// `HeldKBSavesTests`' own `FakeTransport` gives.
private final class FakeTransport {
    struct Call { let argv: [String]; let stdin: String? }
    private(set) var calls: [Call] = []
    private var responses: [Result<Data, Error>]

    init(responses: [Result<Data, Error>]) { self.responses = responses }

    func run(_ argv: [String], _ stdin: String?) throws -> Data {
        calls.append(Call(argv: argv, stdin: stdin))
        guard !responses.isEmpty else {
            XCTFail("more calls than the test queued responses for")
            return Data()
        }
        switch responses.removeFirst() {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}

/// `LibraryClient.approveEpic`/`declineEpic`/`setItemModel`: the signed-act
/// core (`performSignedAct`) they all share. Fakes stand in for the key and
/// the remote command, as `KBSignedSaveTests`/`HeldKBSavesTests` already do
/// for the KB save's own signed write — this file never touches the real
/// Keychain or the Secure Enclave.
final class LibrarySignedActTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-13T23:30:00Z")!
    /// Inside the fixture certificate's default window: notBefore
    /// 2026-10-05, notAfter 2027-01-03.
    private let outOfWindow = ISO8601DateFormatter().date(from: "2027-02-01T00:00:00Z")!

    /// The snapshot every test signs over — a caller's own displayed item,
    /// never a read this file's fakes make, per `ItemActSnapshot`'s doc.
    private let snapshot = LibraryClient.ItemActSnapshot(
        specification: "Every invoice is reconciled by Friday.",
        definitionOfDone: "- Zero unmatched rows.", maturity: "proposed", model: nil)

    /// The operator label every signed act still sends in its body
    /// (`LibraryClient.validateActingHuman`'s doc: the running Library
    /// predates the route that makes `acting_human` optional).
    private let actingHuman = "deck:operator@host.example"

    private func curlResponse(status: Int, body: String) -> Data {
        Data("\(body)\n\(status)".utf8)
    }

    private func certificatePEM(key: FakeSigningKey) throws -> String {
        let fixture = CertificateFixture(subjectKey: key.key)
        return String(decoding: CertificateFixture.pem(try fixture.der()), as: UTF8.self)
    }

    /// The base64 value of one `-H 'Library-Act-<Name>: <value>'` flag in a
    /// composed remote command — the same shape `LibraryClient.remoteWriteCommand`
    /// builds, read back without a general shell parser since every value
    /// in that position is base64 (see that function's own doc).
    private func actHeaderValue(_ command: String, header: String) -> String? {
        guard let marker = command.range(of: "-H 'Library-Act-\(header): ") else { return nil }
        let after = command[marker.upperBound...]
        guard let end = after.firstIndex(of: "'") else { return nil }
        return String(after[..<end])
    }

    // MARK: - Approve: signs the displayed snapshot, never a fresh read

    /// Decodes a signed act's stdin JSON into a dictionary — never a raw
    /// string compare, since `JSONSerialization` makes no promise about key
    /// order once a body carries more than one field.
    private func decodedBody(_ stdin: String?) throws -> [String: Any] {
        let rawData = try XCTUnwrap(stdin).data(using: .utf8)
        let data = try XCTUnwrap(rawData)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testApproveSignsOverTheDisplayedSnapshotWithOneWriteAndNoRead() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [.success(curlResponse(status: 200, body: "{}"))])
        let outcome = try LibraryClient.approveEpic(
            target: TestHost.target, itemId: "issue_01ABC", snapshot: snapshot, actingHuman: actingHuman,
            signingKey: key, certificatePEM: cert, now: now, transport: transport.run)

        XCTAssertEqual(outcome, .wrote)
        XCTAssertEqual(transport.calls.count, 1, "no read precedes the write — the one call is the signed POST")
        let postCommand = try XCTUnwrap(transport.calls[0].argv.last)
        XCTAssertTrue(postCommand.contains("/items/issue_01ABC/approve\""))
        let sentBody = try decodedBody(transport.calls[0].stdin)
        XCTAssertEqual(sentBody["maturity"] as? String, "approved")
        XCTAssertEqual(sentBody["acting_human"] as? String, actingHuman)

        // The envelope signed is built over the snapshot this test passed
        // in, not a read this file's transport never offered — decoded back
        // out of the header and checked against the hashes the worked
        // example itself pins.
        let envelopeBase64 = try XCTUnwrap(actHeaderValue(postCommand, header: "Envelope"))
        let envelope = try XCTUnwrap(Data(base64Encoded: envelopeBase64))
        let envelopeText = String(decoding: envelope, as: UTF8.self)
        XCTAssertTrue(envelopeText.contains("action:approve\n"))
        XCTAssertTrue(envelopeText.contains("item:issue_01ABC\n"))
        XCTAssertTrue(envelopeText.contains("maturity:proposed\n"))
        XCTAssertTrue(envelopeText.contains("model:\n"))
        // The same specification text and digest the worked example pins
        // (`LibraryItemActSignatureTests`), confirming this is the snapshot's
        // own text that got hashed, not some other string.
        XCTAssertTrue(envelopeText.contains(
            "specification-sha256:9abdb6aeea0504824cbd3f8ebf02811274bc729839d42314483851c4e8f6b4c4\n"), envelopeText)

        // `body-sha256` covers the exact bytes sent as stdin, `acting_human`
        // included — the envelope is signed before `acting_human` could be
        // appended or altered after the fact.
        let bodyData = try XCTUnwrap(transport.calls[0].stdin).data(using: .utf8)
        let expectedBodySHA256 = SHA256.hash(data: try XCTUnwrap(bodyData)).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(envelopeText.contains("body-sha256:\(expectedBodySHA256)\n"), envelopeText)

        // One Touch ID press, with a reason naming the act and the item.
        XCTAssertEqual(key.signReasons, ["Approve issue_01ABC in the Library"])

        // The signature itself verifies against the fake key's own public point.
        let signatureBase64 = try XCTUnwrap(actHeaderValue(postCommand, header: "Signature"))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: XCTUnwrap(Data(base64Encoded: signatureBase64)))
        XCTAssertTrue(key.key.publicKey.isValidSignature(signature, for: envelope))

        // The certificate travels as its own DER, base64, matching what was signed with.
        let certificateBase64 = try XCTUnwrap(actHeaderValue(postCommand, header: "Certificate"))
        let certificateDER = try XCTUnwrap(Data(base64Encoded: certificateBase64))
        XCTAssertEqual(try SigningCertificate.parse(der: certificateDER).spkiDER,
                       try SigningCertificate.parse(fileData: Data(cert.utf8)).spkiDER)
    }

    /// **THE GAP PR #429'S ROUND 1 REVIEW FOUND.** A proposed epic that
    /// carries a `model_choice` must sign that model, never an empty line —
    /// `ItemActSnapshot(epic:)` reads `Epic.modelChoice`, which
    /// `LibraryClient.decodeEpics` now decodes from the same
    /// `GET /items?type=epic` response the Proposals region draws the row
    /// from. Without this, the signed envelope would always disagree with
    /// the Library's own held `model`, and every approve/decline of such an
    /// epic from that region would be refused 409 `stale`.
    func testApproveSignsAnEpicsOwnModelChoice() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [.success(curlResponse(status: 200, body: "{}"))])
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_01ABC","state":"open","maturity":"proposed","model_choice":{"model":"opus"}}]}
        """)
        let epic = try XCTUnwrap(LibraryClient.decodeEpics(raw).first)
        let outcome = try LibraryClient.approveEpic(
            target: TestHost.target, itemId: epic.id, snapshot: LibraryClient.ItemActSnapshot(epic: epic),
            actingHuman: actingHuman, signingKey: key, certificatePEM: cert, now: now, transport: transport.run)

        XCTAssertEqual(outcome, .wrote)
        let postCommand = try XCTUnwrap(transport.calls[0].argv.last)
        let envelopeBase64 = try XCTUnwrap(actHeaderValue(postCommand, header: "Envelope"))
        let envelope = try XCTUnwrap(Data(base64Encoded: envelopeBase64))
        let envelopeText = String(decoding: envelope, as: UTF8.self)
        XCTAssertTrue(envelopeText.contains("model:opus\n"), envelopeText)
    }

    /// The other side of `testApproveSignsAnEpicsOwnModelChoice`: an epic
    /// with no `model_choice` at all signs an empty `model` line, the same
    /// way it always has — the fix must not invent a model that was never
    /// set.
    func testApproveSignsAnEmptyModelWhenTheEpicHasNoModelChoice() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [.success(curlResponse(status: 200, body: "{}"))])
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_01ABC","state":"open","maturity":"proposed"}]}
        """)
        let epic = try XCTUnwrap(LibraryClient.decodeEpics(raw).first)
        let outcome = try LibraryClient.approveEpic(
            target: TestHost.target, itemId: epic.id, snapshot: LibraryClient.ItemActSnapshot(epic: epic),
            actingHuman: actingHuman, signingKey: key, certificatePEM: cert, now: now, transport: transport.run)

        XCTAssertEqual(outcome, .wrote)
        let postCommand = try XCTUnwrap(transport.calls[0].argv.last)
        let envelopeBase64 = try XCTUnwrap(actHeaderValue(postCommand, header: "Envelope"))
        let envelope = try XCTUnwrap(Data(base64Encoded: envelopeBase64))
        let envelopeText = String(decoding: envelope, as: UTF8.self)
        XCTAssertTrue(envelopeText.contains("model:\n"), envelopeText)
    }

    func testDeclineSignsAndSendsTheReason() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [.success(curlResponse(status: 200, body: "{}"))])
        let outcome = try LibraryClient.declineEpic(
            target: TestHost.target, itemId: "issue_01ABC", reason: "Product retired", snapshot: snapshot,
            actingHuman: actingHuman, signingKey: key, certificatePEM: cert, now: now, transport: transport.run)

        XCTAssertEqual(outcome, .wrote)
        XCTAssertEqual(transport.calls.count, 1)
        let sentBody = try decodedBody(transport.calls[0].stdin)
        XCTAssertEqual(sentBody["reason"] as? String, "Product retired")
        XCTAssertEqual(sentBody["acting_human"] as? String, actingHuman)
        XCTAssertEqual(key.signReasons, ["Decline issue_01ABC in the Library"])
    }

    func testSetModelSignsAndSendsTheModelAndReason() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [.success(curlResponse(status: 200, body: "{}"))])
        let outcome = try LibraryClient.setItemModel(
            target: TestHost.target, itemId: "issue_01ABC", model: "opus", reason: "needs judgment",
            snapshot: LibraryClient.ItemActSnapshot(maturity: "approved"), actingHuman: actingHuman,
            signingKey: key, certificatePEM: cert, now: now, transport: transport.run)

        XCTAssertEqual(outcome, .wrote)
        XCTAssertEqual(transport.calls.count, 1)
        let postCommand = try XCTUnwrap(transport.calls[0].argv.last)
        let envelopeBase64 = try XCTUnwrap(actHeaderValue(postCommand, header: "Envelope"))
        let envelope = try XCTUnwrap(Data(base64Encoded: envelopeBase64))
        XCTAssertTrue(String(decoding: envelope, as: UTF8.self).contains("action:model\n"))
        let sentBody = try decodedBody(transport.calls[0].stdin)
        XCTAssertEqual(sentBody["model"] as? String, "opus")
        XCTAssertEqual(sentBody["reason"] as? String, "needs judgment")
        XCTAssertEqual(sentBody["acting_human"] as? String, actingHuman)
        XCTAssertEqual(key.signReasons, ["Set issue_01ABC's model in the Library"])
    }

    // MARK: - `acting_human` is validated before any Touch ID press

    func testABlankActingHumanRefusesBeforeTheTouchIDPress() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [])
        XCTAssertThrowsError(try LibraryClient.approveEpic(
            target: TestHost.target, itemId: "issue_01ABC", snapshot: snapshot, actingHuman: "   ",
            signingKey: key, certificatePEM: cert, now: now, transport: transport.run)) { error in
            guard case LibraryClient.FetchError.invalidActingHuman = error else {
                return XCTFail("expected invalidActingHuman, got \(error)")
            }
        }
        XCTAssertTrue(key.signReasons.isEmpty, "a blank operator name must never reach the Touch ID prompt")
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testAnOverLongActingHumanRefusesBeforeTheTouchIDPress() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [])
        let tooLong = String(repeating: "x", count: LibraryClient.maxActingHumanLength + 1)
        XCTAssertThrowsError(try LibraryClient.declineEpic(
            target: TestHost.target, itemId: "issue_01ABC", snapshot: snapshot, actingHuman: tooLong,
            signingKey: key, certificatePEM: cert, now: now, transport: transport.run)) { error in
            guard case LibraryClient.FetchError.invalidActingHuman = error else {
                return XCTFail("expected invalidActingHuman, got \(error)")
            }
        }
        XCTAssertTrue(key.signReasons.isEmpty, "an over-long operator name must never reach the Touch ID prompt")
        XCTAssertTrue(transport.calls.isEmpty)
    }

    // MARK: - A cancelled Touch ID prompt sends nothing

    func testACancelledPromptSendsNoWriteAndReturnsCancelled() throws {
        let key = FakeSigningKey()
        key.failure = SigningKeyError.cancelled
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [])
        let outcome = try LibraryClient.approveEpic(
            target: TestHost.target, itemId: "issue_01ABC", snapshot: snapshot, actingHuman: actingHuman,
            signingKey: key, certificatePEM: cert, now: now, transport: transport.run)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(transport.calls.isEmpty, "nothing is sent for a dismissed Touch ID prompt")
    }

    // MARK: - A certificate outside its validity window signs nothing

    func testAnExpiredCertificateReturnsSigningUnavailableAndTouchesNeitherKeyNorTransport() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [])
        let outcome = try LibraryClient.approveEpic(
            target: TestHost.target, itemId: "issue_01ABC", snapshot: snapshot, actingHuman: actingHuman,
            signingKey: key, certificatePEM: cert, now: outOfWindow, transport: transport.run)

        XCTAssertEqual(outcome, .signingUnavailable)
        XCTAssertTrue(transport.calls.isEmpty, "a certificate outside its window must not even reach the transport")
        XCTAssertTrue(key.signReasons.isEmpty, "the key must never be asked to sign")
    }

    func testAMalformedCertificateReturnsSigningUnavailable() throws {
        let key = FakeSigningKey()
        let transport = FakeTransport(responses: [])
        let outcome = try LibraryClient.approveEpic(
            target: TestHost.target, itemId: "issue_01ABC", snapshot: snapshot, actingHuman: actingHuman,
            signingKey: key, certificatePEM: "not a certificate", now: now, transport: transport.run)

        XCTAssertEqual(outcome, .signingUnavailable)
        XCTAssertTrue(transport.calls.isEmpty)
    }

    // MARK: - A Library refusal comes back as `.refused`, never a throw

    func testALibraryRefusalComesBackAsRefusedWithItsOwnWords() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [
            .success(curlResponse(status: 403, body: #"{"error":"this identity lacks item.signed_act"}"#)),
        ])
        let outcome = try LibraryClient.approveEpic(
            target: TestHost.target, itemId: "issue_01ABC", snapshot: snapshot, actingHuman: actingHuman,
            signingKey: key, certificatePEM: cert, now: now, transport: transport.run)

        XCTAssertEqual(outcome, .refused("this identity lacks item.signed_act"))
    }

    /// A transport failure propagates as a throw, never a `SignedActOutcome`
    /// — only a genuine Library answer is folded into one.
    func testATransportFailureStillThrows() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [.failure(FetchError.transportFailure)])
        XCTAssertThrowsError(try LibraryClient.approveEpic(
            target: TestHost.target, itemId: "issue_01ABC", snapshot: snapshot, actingHuman: actingHuman,
            signingKey: key, certificatePEM: cert, now: now, transport: transport.run))
    }

    private enum FetchError: Error { case transportFailure }

    // MARK: - A stale 409 or a replayed 403 come back as `.needsFreshRead`, never retried

    /// The act was never applied — the signed snapshot no longer matched
    /// what the Library held — and this is distinct from an ordinary
    /// `.refused`: both readers of `SignedActOutcome` (`CockpitModel`,
    /// `ItemDetailModel`) re-read the item on this case, never resending the
    /// same proof.
    func testAStale409ComesBackAsNeedsFreshReadNeverRefused() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [
            .success(curlResponse(status: 409, body: #"{"error":"stale","changed":["maturity"]}"#)),
        ])
        let outcome = try LibraryClient.approveEpic(
            target: TestHost.target, itemId: "issue_01ABC", snapshot: snapshot, actingHuman: actingHuman,
            signingKey: key, certificatePEM: cert, now: now, transport: transport.run)

        guard case .needsFreshRead(let message) = outcome else {
            return XCTFail("expected .needsFreshRead, got \(outcome)")
        }
        XCTAssertTrue(message.contains("maturity"), message)
    }

    /// A replayed proof (403 `proof-refused`/`replayed`) means the act most
    /// likely already happened — the same "re-read, never resend" case as
    /// `stale`.
    func testAReplayedProofComesBackAsNeedsFreshReadNeverRefused() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [
            .success(curlResponse(status: 403, body: #"{"error":"proof-refused","reason":"replayed"}"#)),
        ])
        let outcome = try LibraryClient.declineEpic(
            target: TestHost.target, itemId: "issue_01ABC", snapshot: snapshot, actingHuman: actingHuman,
            signingKey: key, certificatePEM: cert, now: now, transport: transport.run)

        guard case .needsFreshRead(let message) = outcome else {
            return XCTFail("expected .needsFreshRead, got \(outcome)")
        }
        XCTAssertFalse(message.contains("proof-refused"), "a code leaked into the words an operator reads: \(message)")
    }

    /// A different `proof-refused` reason (not a replay) is an ordinary
    /// `.refused` — re-reading buys nothing when the certificate itself, not
    /// the freshness of the proof, is what the Library refused.
    func testAProofRefusedForAReasonOtherThanReplayStaysRefused() throws {
        let key = FakeSigningKey()
        let cert = try certificatePEM(key: key)
        let transport = FakeTransport(responses: [
            .success(curlResponse(status: 403, body: #"{"error":"proof-refused","reason":"signature"}"#)),
        ])
        let outcome = try LibraryClient.approveEpic(
            target: TestHost.target, itemId: "issue_01ABC", snapshot: snapshot, actingHuman: actingHuman,
            signingKey: key, certificatePEM: cert, now: now, transport: transport.run)

        guard case .refused = outcome else {
            return XCTFail("expected .refused, got \(outcome)")
        }
    }

    // MARK: - Refusal classification: `proof-refused`

    private func refused(_ status: Int, _ body: String) -> String {
        LibraryClient.approvalRefusalMessage(LibraryClient.FetchError.libraryRefused(status: status, body: body))
    }

    func testEachProofRefusedReasonGetsItsOwnWords() {
        let malformed = refused(403, #"{"error":"proof-refused","reason":"malformed"}"#)
        let window = refused(403, #"{"error":"proof-refused","reason":"window"}"#)
        let certificate = refused(403, #"{"error":"proof-refused","reason":"certificate"}"#)
        let signature = refused(403, #"{"error":"proof-refused","reason":"signature"}"#)
        let mismatch = refused(403, #"{"error":"proof-refused","reason":"mismatch"}"#)
        let inputs = refused(403, #"{"error":"proof-refused","reason":"inputs"}"#)
        let missing = refused(403, #"{"error":"proof-refused","reason":"missing"}"#)
        let replayed = refused(403, #"{"error":"proof-refused","reason":"replayed"}"#)
        let unknown = refused(403, #"{"error":"proof-refused","reason":"something-new"}"#)

        let messages = [malformed, window, certificate, signature, mismatch, inputs, missing, replayed, unknown]
        XCTAssertEqual(Set(messages).count, messages.count, "every reason reads as its own distinct message: \(messages)")
        for message in messages {
            XCTAssertFalse(message.contains("proof-refused"), "a code leaked into the words an operator reads: \(message)")
        }
    }

    /// `not-active` names the certificate's own status, when the Library sends it.
    func testNotActiveNamesTheCertificateStatus() {
        let revoked = refused(403, #"{"error":"proof-refused","reason":"not-active","certificate_status":"revoked"}"#)
        XCTAssertTrue(revoked.contains("revoked"), revoked)
        let expired = refused(403, #"{"error":"proof-refused","reason":"not-active","certificate_status":"expired"}"#)
        XCTAssertTrue(expired.contains("expired"), expired)
    }

    /// `missing` — a request with no proof at all from a bearer without the
    /// reserved capability.
    func testMissingNamesTheAbsenceOfAProof() {
        let message = refused(403, #"{"error":"proof-refused","reason":"missing"}"#)
        XCTAssertTrue(message.contains("no signed proof"), message)
    }

    /// `replayed` — this exact proof was already used; the words must point
    /// at reopening the item, never at resending anything.
    func testReplayedNamesTheProofAsAlreadyUsed() {
        let message = refused(403, #"{"error":"proof-refused","reason":"replayed"}"#)
        XCTAssertTrue(message.contains("already used"), message)
        XCTAssertTrue(message.contains("Reopen"), message)
    }

    // MARK: - Refusal classification: `stale`

    func testAStaleRefusalNamesTheChangedFieldsAndNeverTheRawCode() {
        let message = refused(409, #"{"error":"stale","changed":["maturity","specification-sha256"]}"#)
        XCTAssertTrue(message.contains("maturity"), message)
        XCTAssertTrue(message.contains("specification-sha256"), message)
        XCTAssertFalse(message.contains(#""stale""#), message)
    }

    func testAStaleRefusalWithNoChangedListStillReadsAsWords() {
        let message = refused(409, #"{"error":"stale"}"#)
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains(#""stale""#), message)
    }

    // MARK: - The control's own wording when nothing can be signed yet

    func testTheNoCertificateMessageNamesSettingsAndSigning() {
        XCTAssertTrue(LibraryClient.signedActNeedsCertificateMessage.contains("Settings"))
        XCTAssertTrue(LibraryClient.signedActNeedsCertificateMessage.contains("Signing"))
    }
}
