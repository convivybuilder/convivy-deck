import CryptoKit
import LocalAuthentication
import Security
import XCTest
@testable import Deck

/// A software P-256 key standing in for the Secure Enclave, which cannot run
/// under XCTest: it needs the Enclave and, to sign, a person at the Touch ID
/// sensor.
private struct SoftwareKey: SigningKey {
    let key: P256.Signing.PrivateKey
    /// Set to make `sign` throw, as a cancelled or failed prompt does.
    var failure: Error?

    var publicKeyX963: Data { key.publicKey.x963Representation }
    var dataRepresentation: Data { key.rawRepresentation }

    func sign(_ message: Data) throws -> Data {
        if let failure { throw failure }
        return try key.signature(for: message).derRepresentation
    }
}

private final class SoftwareFactory: SigningKeyFactory, @unchecked Sendable {
    private(set) var created = 0
    func makeKey() throws -> SigningKey {
        created += 1
        return SoftwareKey(key: P256.Signing.PrivateKey())
    }
    func key(fromDataRepresentation blob: Data) throws -> SigningKey {
        SoftwareKey(key: try P256.Signing.PrivateKey(rawRepresentation: blob))
    }
}

private struct Boom: LocalizedError {
    var errorDescription: String? { "the Enclave said no" }
}

final class SigningKeyTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("Deck/signing-key.blob") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("signing-key-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Store

    func testFirstLoadCreatesAKeyAndPersistsItsBlob() throws {
        let factory = SoftwareFactory()
        let store = SigningKeyStore(fileURL: file, factory: factory)

        let key = try store.loadOrCreate()

        XCTAssertEqual(factory.created, 1)
        XCTAssertEqual(try Data(contentsOf: file), key.dataRepresentation)
    }

    func testAnExistingBlobIsReusedNotReplaced() throws {
        let factory = SoftwareFactory()
        let store = SigningKeyStore(fileURL: file, factory: factory)
        let first = try store.loadOrCreate()

        let second = try store.loadOrCreate()

        XCTAssertEqual(factory.created, 1, "the second load must not mint a key")
        XCTAssertEqual(first.publicKeyX963, second.publicKeyX963)
    }

    func testACorruptBlobSurfacesAnErrorAndIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let garbage = Data("not a key".utf8)
        try garbage.write(to: file)
        let factory = SoftwareFactory()
        let store = SigningKeyStore(fileURL: file, factory: factory)

        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            guard case SigningKeyError.unreadableKey = error else {
                return XCTFail("expected unreadableKey, got \(error)")
            }
        }
        XCTAssertEqual(factory.created, 0, "a corrupt blob must not silently become a new key")
        XCTAssertEqual(try Data(contentsOf: file), garbage)
    }

    func testTheBlobIsWrittenReadableByTheOwnerOnly() throws {
        _ = try SigningKeyStore(fileURL: file, factory: SoftwareFactory()).loadOrCreate()

        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testWritingLeavesNoTemporaryFileBehind() throws {
        _ = try SigningKeyStore(fileURL: file, factory: SoftwareFactory()).loadOrCreate()

        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(names, [file.lastPathComponent])
    }

    func testLoadReportsNoKeyBeforeOneExistsAndDeleteRemovesIt() throws {
        let store = SigningKeyStore(fileURL: file, factory: SoftwareFactory())
        XCTAssertNil(try store.load())

        _ = try store.loadOrCreate()
        XCTAssertNotNil(try store.load())

        try store.delete()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.delete(), "deleting a key that is gone is not an error")
    }

    // MARK: - Fingerprint

    func testFingerprintIsTheFirstSixteenHexOfTheSHA256OfTheX963Bytes() {
        let bytes = Data([0x04, 0x01, 0x02, 0x03])
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(16)

        let fingerprint = SigningKeyFingerprint.of(publicKeyX963: bytes)

        XCTAssertEqual(fingerprint, String(expected))
        XCTAssertEqual(fingerprint.count, 16)
        XCTAssertEqual(fingerprint, fingerprint.lowercased())
    }

    func testDifferentKeysGiveDifferentFingerprints() {
        let a = SigningKeyFingerprint.of(publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation)
        let b = SigningKeyFingerprint.of(publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Test signature outcome

    func testASuccessfulSignatureIsReportedAsSignedAndVerifies() throws {
        let key = SoftwareKey(key: P256.Signing.PrivateKey())

        let outcome = SigningTestOutcome.run(key)

        XCTAssertEqual(outcome, .signed)
    }

    func testACancelledPromptIsReportedAsCancelled() {
        var key = SoftwareKey(key: P256.Signing.PrivateKey())
        key.failure = SigningKeyError.cancelled

        XCTAssertEqual(SigningTestOutcome.run(key), .cancelled)
    }

    func testAnyOtherErrorIsReportedWithItsDescription() {
        var key = SoftwareKey(key: P256.Signing.PrivateKey())
        key.failure = Boom()

        XCTAssertEqual(SigningTestOutcome.run(key), .failed("the Enclave said no"))
    }

    func testTheTestStringIsSignedAndTheSignatureVerifiesAgainstThePublicKey() throws {
        let key = SoftwareKey(key: P256.Signing.PrivateKey())
        let der = try key.sign(SigningTestOutcome.testMessage)
        let publicKey = try P256.Signing.PublicKey(x963Representation: key.publicKeyX963)
        XCTAssertTrue(publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: der),
                                                 for: SigningTestOutcome.testMessage))
    }

    // MARK: - Settings state

    func testSettingsPresentationForEachKeyState() {
        let present = SigningKeyPresentation(state: .present(fingerprint: "0123456789abcdef"), test: nil)
        XCTAssertTrue(present.headline.contains("has a signing key"))
        XCTAssertEqual(present.fingerprintLine, "0123456789abcdef")
        XCTAssertTrue(present.canTest)

        let absent = SigningKeyPresentation(state: .absent, test: nil)
        XCTAssertTrue(absent.headline.contains("no signing key"))
        XCTAssertNil(absent.fingerprintLine)
        XCTAssertFalse(absent.canTest)

        let failed = SigningKeyPresentation(state: .failed("unreadable"), test: nil)
        XCTAssertTrue(failed.headline.contains("unreadable"))
        XCTAssertFalse(failed.canTest)
    }

    func testSettingsPresentationForEachTestOutcome() {
        let state = SigningKeyPresentation.KeyState.present(fingerprint: "0123456789abcdef")
        XCTAssertNil(SigningKeyPresentation(state: state, test: nil).testLine)
        XCTAssertEqual(SigningKeyPresentation(state: state, test: .signed).testLine, "Signed.")
        XCTAssertEqual(SigningKeyPresentation(state: state, test: .cancelled).testLine,
                       "Cancelled. Nothing was signed.")
        XCTAssertEqual(SigningKeyPresentation(state: state, test: .failed("boom")).testLine,
                       "Failed: boom")
    }

    /// `translate` is what turns a dismissed prompt into "Cancelled". The
    /// `SoftwareKey` tests inject `.cancelled` directly and never reach it.
    func testTranslateMapsEachCancellationToCancelled() {
        let cancellations = [
            NSError(domain: LAError.errorDomain, code: LAError.userCancel.rawValue),
            NSError(domain: LAError.errorDomain, code: LAError.appCancel.rawValue),
            NSError(domain: LAError.errorDomain, code: LAError.systemCancel.rawValue),
            NSError(domain: NSOSStatusErrorDomain, code: Int(errSecUserCanceled)),
        ]
        for error in cancellations {
            XCTAssertEqual(SecureEnclaveSigningKey.translate(error) as? SigningKeyError, .cancelled,
                           "\(error.domain) \(error.code)")
        }
    }

    func testTranslatePassesAnyOtherErrorThroughUnchanged() {
        let others = [
            NSError(domain: LAError.errorDomain, code: LAError.authenticationFailed.rawValue),
            NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed)),
            NSError(domain: "CryptoKit.CryptoKitError", code: LAError.userCancel.rawValue),
        ]
        for error in others {
            let translated = SecureEnclaveSigningKey.translate(error) as NSError
            XCTAssertEqual(translated.domain, error.domain)
            XCTAssertEqual(translated.code, error.code)
        }
    }
}
