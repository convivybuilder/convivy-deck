import CryptoKit
import Foundation
import XCTest
@testable import Deck

/// A software P-256 key standing in for the Secure Enclave key, which CI does
/// not have. `failure` makes `sign` throw, as a cancelled or refused prompt does.
private struct SoftwareSigner: SigningKey {
    let key: P256.Signing.PrivateKey
    var failure: Error?

    var publicKeyX963: Data { key.publicKey.x963Representation }
    var dataRepresentation: Data { key.rawRepresentation }

    func sign(_ message: Data) throws -> Data {
        if let failure { throw failure }
        return try key.signature(for: message).derRepresentation
    }
}

/// Checks each request with `/usr/bin/openssl`, an independent parser, rather
/// than with Deck's own code.
final class CertificateSigningRequestTests: XCTestCase {
    private var directory: URL!

    private struct Refused: LocalizedError {
        var errorDescription: String? { "the Enclave said no" }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("csr-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func openssl(_ arguments: [String], stdin: Data = Data()) throws
        -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(stdin)
        try input.fileHandleForWriting.close()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, String(decoding: stderr, as: UTF8.self))
    }

    private func writeFile(_ text: String, named name: String = "request.pem") throws -> String {
        let path = directory.appendingPathComponent(name).path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// The DER inside a `CERTIFICATE REQUEST` PEM block, read without Deck's code.
    private func der(in pem: String) throws -> Data {
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return try XCTUnwrap(Data(base64Encoded: body))
    }

    private func pem(wrapping der: Data) -> String {
        let base64 = Array(der.base64EncodedString())
        var lines = ["-----BEGIN CERTIFICATE REQUEST-----"]
        for start in stride(from: 0, to: base64.count, by: 64) {
            lines.append(String(base64[start..<min(start + 64, base64.count)]))
        }
        lines.append("-----END CERTIFICATE REQUEST-----")
        return lines.joined(separator: "\n") + "\n"
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// LibreSSL's `req -verify` exits 0 even when the signature fails, so the
    /// "verify OK" line is the signal, not the exit status.
    private func verifies(_ pemText: String) throws -> Bool {
        let path = try writeFile(pemText)
        let result = try openssl(["req", "-verify", "-in", path, "-noout"])
        let text = String(decoding: result.stdout, as: UTF8.self) + result.stderr
        return result.status == 0 && text.contains("verify OK")
    }

    // MARK: - Accepted by an independent parser

    func testTheRequestIsLabelledAsRootCAReads() throws {
        let csr = try CertificateSigningRequest.make(for: SoftwareSigner(key: P256.Signing.PrivateKey()))

        XCTAssertTrue(csr.pem.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----\n"))
        XCTAssertTrue(csr.pem.hasSuffix("-----END CERTIFICATE REQUEST-----\n"))
    }

    func testOpenSSLVerifiesTheSelfSignature() throws {
        let csr = try CertificateSigningRequest.make(for: SoftwareSigner(key: P256.Signing.PrivateKey()))

        XCTAssertTrue(try verifies(csr.pem))
    }

    func testOpenSSLReadsTheKeysPublicPointAndFingerprintMatchesIt() throws {
        let key = SoftwareSigner(key: P256.Signing.PrivateKey())
        let csr = try CertificateSigningRequest.make(for: key)
        let path = try writeFile(csr.pem)

        let publicPEM = try openssl(["req", "-in", path, "-pubkey", "-noout"])
        XCTAssertEqual(publicPEM.status, 0, publicPEM.stderr)
        let spki = try openssl(["pkey", "-pubin", "-outform", "DER"], stdin: publicPEM.stdout)
        XCTAssertEqual(spki.status, 0, spki.stderr)

        XCTAssertEqual(spki.stdout, csr.spkiDER, "the request must carry the key's own SubjectPublicKeyInfo")
        XCTAssertEqual(Data(csr.spkiDER.suffix(65)), key.publicKeyX963)
        XCTAssertEqual(csr.spkiFingerprint, sha256Hex(spki.stdout),
                       "the fingerprint must be the SHA-256 of the SPKI root-ca fingerprints")
        XCTAssertEqual(csr.spkiFingerprint.count, 64)
    }

    // MARK: - Refused when altered or mismatched

    func testATamperedRequestFailsVerification() throws {
        let csr = try CertificateSigningRequest.make(for: SoftwareSigner(key: P256.Signing.PrivateKey()))
        var bytes = try der(in: csr.pem)
        bytes[bytes.count - 1] ^= 0x01

        XCTAssertFalse(try verifies(pem(wrapping: bytes)))
    }

    func testARequestWithAnotherKeysPublicKeyFailsVerification() throws {
        let signer = SoftwareSigner(key: P256.Signing.PrivateKey())
        let other = SoftwareSigner(key: P256.Signing.PrivateKey())
        let signed = try CertificateSigningRequest.make(for: signer)
        let otherSPKI = try CertificateSigningRequest.make(for: other).spkiDER
        var bytes = try der(in: signed.pem)
        let range = try XCTUnwrap(bytes.firstRange(of: signed.spkiDER))
        bytes.replaceSubrange(range, with: otherSPKI)

        XCTAssertFalse(try verifies(pem(wrapping: bytes)))
    }

    func testTwoKeysGiveTwoFingerprints() throws {
        let a = try CertificateSigningRequest.make(for: SoftwareSigner(key: P256.Signing.PrivateKey()))
        let b = try CertificateSigningRequest.make(for: SoftwareSigner(key: P256.Signing.PrivateKey()))

        XCTAssertNotEqual(a.spkiFingerprint, b.spkiFingerprint)
    }

    // MARK: - Export

    func testExportWritesAVerifiableRequestAndReportsItsPathAndFingerprint() throws {
        let url = directory.appendingPathComponent("signing-request.pem")

        let outcome = SigningRequestExportOutcome.run(SoftwareSigner(key: P256.Signing.PrivateKey()), to: url)

        guard case .written(let path, let fingerprint) = outcome else {
            return XCTFail("expected written, got \(outcome)")
        }
        XCTAssertEqual(path, url.path)
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertTrue(try verifies(String(contentsOf: url, encoding: .utf8)))
    }

    func testACancelledPromptWritesNothing() {
        let url = directory.appendingPathComponent("signing-request.pem")
        var key = SoftwareSigner(key: P256.Signing.PrivateKey())
        key.failure = SigningKeyError.cancelled

        XCTAssertEqual(SigningRequestExportOutcome.run(key, to: url), .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAFailedSignatureWritesNothingAndReportsIt() {
        let url = directory.appendingPathComponent("signing-request.pem")
        var key = SoftwareSigner(key: P256.Signing.PrivateKey())
        key.failure = Refused()

        XCTAssertEqual(SigningRequestExportOutcome.run(key, to: url), .failed("the Enclave said no"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
