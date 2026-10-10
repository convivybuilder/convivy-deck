import CryptoKit
import Foundation
import XCTest
@testable import Deck

/// Builds a DER certificate by hand, so each test sets exactly the fields it
/// checks. The SPKI is encoded here rather than by Deck's builder, so the
/// key-match test compares two encoders. The issuer's signature is real, though
/// Deck never verifies it.
struct CertificateFixture {
    /// A validity time written as given, for the malformed-time tests: its tag
    /// (0x17 UTCTime or 0x18 GeneralizedTime) and its text.
    struct RawTime {
        let tag: UInt8
        let text: String
    }

    var subjectKey: P256.Signing.PrivateKey
    var notBefore = ISO8601DateFormatter().date(from: "2026-10-05T03:24:32Z")!
    var notAfter = ISO8601DateFormatter().date(from: "2027-01-03T03:24:32Z")!
    /// Replaces the encoded notBefore or notAfter with the given bytes.
    var notBeforeRaw: RawTime?
    var notAfterRaw: RawTime?
    /// Encodes the dates as GeneralizedTime rather than UTCTime.
    var generalizedTime = false
    var commonName = "operator@example.com"
    var machineURI: String? = "convivy://signer/macbook"
    /// digitalSignature is 0x80. nil leaves out the keyUsage extension.
    var keyUsage: UInt8? = 0x80
    var keyUsageCritical = true
    /// nil leaves out the extendedKeyUsage extension.
    var extendedKeyUsage: [[UInt8]]? = [SigningCertificate.signingPurpose]
    var extendedKeyUsageCritical = true
    /// nil leaves out basicConstraints.
    var isCA: Bool? = false
    /// An extra extension to add: its OID content and whether it is critical.
    var extraExtension: (oid: [UInt8], critical: Bool)?
    /// The content octet of the extra extension's critical BOOLEAN. 0xFF is the DER TRUE.
    var extraCriticalByte: UInt8 = 0xFF
    /// The algorithm in the tbsCertificate and in the outer certificate.
    var tbsSignatureOID = CertificateFixture.ecdsaWithSHA256
    var outerSignatureOID = CertificateFixture.ecdsaWithSHA256

    static let clientAuth: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02]
    static let sha1WithRSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x05]
    static let nameConstraints: [UInt8] = [0x55, 0x1D, 0x1E]

    static let ecdsaWithSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
    private static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let prime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    private static let commonNameOID: [UInt8] = [0x55, 0x04, 0x03]

    /// The DER of the certificate, signed by a throwaway issuer key.
    func der() throws -> Data {
        let issuerKey = P256.Signing.PrivateKey()
        var items: [[UInt8]] = [
            tlv(0xA0, tlv(0x02, [0x02])),          // version v3
            tlv(0x02, [0x01]),                     // serial
            seq([tlv(0x06, tbsSignatureOID)]),
            name("Convivy Library Root"),
            seq([validityTime(notBefore, raw: notBeforeRaw), validityTime(notAfter, raw: notAfterRaw)]),
            name(commonName),
            spki(subjectKey.publicKey.x963Representation),
        ]
        let extensions = extensionList()
        if !extensions.isEmpty { items.append(tlv(0xA3, seq(extensions))) }
        let tbs = seq(items)
        let signature = try issuerKey.signature(for: Data(tbs)).derRepresentation
        return Data(seq([tbs, seq([tlv(0x06, outerSignatureOID)]), tlv(0x03, [0x00] + [UInt8](signature))]))
    }

    /// The given DER as PEM text, the form a person most often picks. Pass the
    /// same `der()` result the test checks against: each call signs afresh.
    static func pem(_ der: Data) -> Data {
        let base64 = Array(der.base64EncodedString())
        var lines = ["-----BEGIN CERTIFICATE-----"]
        for start in stride(from: 0, to: base64.count, by: 64) {
            lines.append(String(base64[start..<min(start + 64, base64.count)]))
        }
        lines.append("-----END CERTIFICATE-----")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: - Extensions

    private func extensionList() -> [[UInt8]] {
        var list: [[UInt8]] = []
        if let keyUsage {
            list.append(extensionEntry([0x55, 0x1D, 0x0F], critical: keyUsageCritical,
                                       value: tlv(0x03, [UInt8(keyUsage.trailingZeroBitCount)] + [keyUsage])))
        }
        if let extendedKeyUsage {
            list.append(extensionEntry([0x55, 0x1D, 0x25], critical: extendedKeyUsageCritical,
                                       value: seq(extendedKeyUsage.map { tlv(0x06, $0) })))
        }
        if let isCA {
            list.append(extensionEntry([0x55, 0x1D, 0x13], critical: true,
                                       value: seq(isCA ? [tlv(0x01, [0xFF])] : [])))
        }
        // subjectAltName: the email as rfc822Name and the machine URI, when given.
        var names = [tlv(0x81, Array(commonName.utf8))]
        if let machineURI { names.append(tlv(0x86, Array(machineURI.utf8))) }
        list.append(extensionEntry([0x55, 0x1D, 0x11], critical: false, value: seq(names)))
        if let extraExtension {
            list.append(extensionEntry(extraExtension.oid, critical: extraExtension.critical, value: seq([]),
                                       criticalByte: extraCriticalByte))
        }
        return list
    }

    private func extensionEntry(_ oid: [UInt8], critical: Bool, value: [UInt8], criticalByte: UInt8 = 0xFF) -> [UInt8] {
        seq([tlv(0x06, oid)] + (critical ? [tlv(0x01, [criticalByte])] : []) + [tlv(0x04, value)])
    }

    // MARK: - DER

    private func name(_ commonName: String) -> [UInt8] {
        seq([tlv(0x31, seq([tlv(0x06, Self.commonNameOID), tlv(0x0C, Array(commonName.utf8))]))])
    }

    private func spki(_ x963: Data) -> [UInt8] {
        seq([seq([tlv(0x06, Self.ecPublicKey), tlv(0x06, Self.prime256v1)]),
             tlv(0x03, [0x00] + [UInt8](x963))])
    }

    /// The encoded time: the raw bytes when given, otherwise the date in the
    /// encoding `generalizedTime` selects.
    private func validityTime(_ date: Date, raw: RawTime?) -> [UInt8] {
        if let raw { return tlv(raw.tag, Array(raw.text.utf8)) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        if generalizedTime {
            let text = String(format: "%04ld%02ld%02ld%02ld%02ld%02ldZ",
                              c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
            return tlv(0x18, Array(text.utf8))
        }
        let text = String(format: "%02ld%02ld%02ld%02ld%02ld%02ldZ",
                          c.year! % 100, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        return tlv(0x17, Array(text.utf8))
    }

    private func seq(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }

    private func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    private func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var octets: [UInt8] = []
        var rest = count
        while rest > 0 {
            octets.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return [0x80 | UInt8(octets.count)] + octets
    }
}

/// The SPKI Deck's own key produces, which the import compares against.
private func deckSPKI(for key: P256.Signing.PrivateKey) -> Data {
    CertificateSigningRequest.subjectPublicKeyInfo(x963: key.publicKey.x963Representation)
}

final class SigningCertificateImportTests: XCTestCase {
    /// The instant inside the fixture's validity window.
    private let now = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!

    private var directory: URL!
    private var store: SigningCertificateStore!
    private var enclaveKey: P256.Signing.PrivateKey!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("signing-certificate-import-tests-\(UUID().uuidString)")
        store = SigningCertificateStore(fileURL: directory.appendingPathComponent("Deck/signing-certificate.pem"))
        enclaveKey = P256.Signing.PrivateKey()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func importFile(_ data: Data, forKey key: P256.Signing.PrivateKey? = nil,
                            at moment: Date? = nil) throws -> SigningCertificate {
        try SigningCertificateImport.importCertificate(
            fileData: data, forSPKI: deckSPKI(for: key ?? enclaveKey), now: moment ?? now, into: store)
    }

    /// Asserts the refusal's error, and that nothing was stored.
    private func assertRefused(_ data: Data, expected: SigningCertificateError,
                               forKey key: P256.Signing.PrivateKey? = nil,
                               at moment: Date? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try importFile(data, forKey: key, at: moment), file: file, line: line) { error in
            XCTAssertEqual(error as? SigningCertificateError, expected, file: file, line: line)
        }
        assertNothingStored(file: file, line: line)
    }

    /// Asserts the stored-certificate file is absent. Checking the file itself,
    /// not `loadCertificate`, so a file that was written but does not parse fails here.
    private func assertNothingStored(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path),
                       "a refused certificate must not be stored", file: file, line: line)
    }

    /// Asserts a certificate whose notBefore is `time` fails to parse, with `reason`.
    private func assertTimeRefused(_ time: CertificateFixture.RawTime, because reason: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.notBeforeRaw = time
        let der = try fixture.der()
        XCTAssertThrowsError(try SigningCertificate.parse(der: der), time.text, file: file, line: line) { error in
            XCTAssertEqual(error as? SigningCertificateError, .notACertificate(reason), file: file, line: line)
        }
    }

    // MARK: - Accepted

    func testAMatchingCertificateIsAcceptedAndStoredWithItsFields() throws {
        let fixture = CertificateFixture(subjectKey: enclaveKey)
        let stored = try importFile(try fixture.der())

        XCTAssertEqual(stored.commonName, "operator@example.com")
        XCTAssertEqual(stored.machine, "macbook")
        XCTAssertEqual(stored.notAfter, fixture.notAfter)
        XCTAssertEqual(stored.derSHA256Hex, sha256Hex(stored.der))
        XCTAssertEqual(stored.spkiDER, deckSPKI(for: enclaveKey),
                       "the certificate's SPKI bytes must equal Deck's own encoding of the key")

        let reloaded = try XCTUnwrap(try store.loadCertificate())
        XCTAssertEqual(reloaded, stored)
    }

    func testAPEMFileIsAcceptedTheSameAsADERFile() throws {
        let der = try CertificateFixture(subjectKey: enclaveKey).der()
        let fromPEM = try importFile(CertificateFixture.pem(der))
        XCTAssertEqual(fromPEM.der, der)
    }

    func testAGeneralizedTimeValidityIsAcceptedWithItsDates() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.generalizedTime = true
        let stored = try importFile(try fixture.der())

        XCTAssertEqual(stored.notBefore, fixture.notBefore)
        XCTAssertEqual(stored.notAfter, fixture.notAfter)
    }

    /// RFC 5280 §4.2: a relying party may ignore a non-critical extension it does not read.
    func testANonCriticalUnknownExtensionIsAccepted() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.extraExtension = (oid: CertificateFixture.nameConstraints, critical: false)
        XCTAssertNoThrow(try importFile(try fixture.der()))
    }

    func testTheSigningPurposeConstantIsTheOIDTheContractNames() throws {
        // Checked against the decimal in library-protocol §2.2, through the
        // independent parser: openssl must print that arc for the same bytes.
        let path = try writePEM(CertificateFixture.pem(try CertificateFixture(subjectKey: enclaveKey).der()))
        let text = try openssl(["x509", "-in", path, "-noout", "-text"])
        XCTAssertTrue(text.contains("2.25.332679538808142797592760871621889796493"), text)
    }

    /// openssl reads the same bytes Deck parsed: it prints the same SHA-256 of
    /// the DER, and the basicConstraints and keyUsage lines the fixture sets.
    func testOpensslReadsTheFixtureWithTheFingerprintDeckComputes() throws {
        let der = try CertificateFixture(subjectKey: enclaveKey).der()
        let parsed = try SigningCertificate.parse(der: der)
        let path = try writePEM(CertificateFixture.pem(der))

        let fingerprint = try openssl(["x509", "-in", path, "-noout", "-fingerprint", "-sha256"])
        let opensslHex = fingerprint.split(separator: "=").last!
            .replacingOccurrences(of: ":", with: "").lowercased()
        XCTAssertEqual(opensslHex.trimmingCharacters(in: .whitespacesAndNewlines), parsed.derSHA256Hex)

        let text = try openssl(["x509", "-in", path, "-noout", "-text"])
        XCTAssertTrue(text.contains("CA:FALSE"), "positive control: openssl shows the basicConstraints line")
        XCTAssertTrue(text.contains("Digital Signature"), text)
    }

    // MARK: - Refused

    func testACertificateForAnotherKeyIsRefusedAndNothingIsStored() throws {
        let other = P256.Signing.PrivateKey()
        let data = try CertificateFixture(subjectKey: other).der()
        assertRefused(data, expected: .forAnotherKey)
    }

    func testACertificatePastNotAfterIsRefusedAndNothingIsStored() throws {
        let fixture = CertificateFixture(subjectKey: enclaveKey)
        let afterWindow = ISO8601DateFormatter().date(from: "2027-01-04T00:00:00Z")!
        assertRefused(try fixture.der(), expected: .expired(notAfter: fixture.notAfter), at: afterWindow)
    }

    func testACertificateBeforeNotBeforeIsRefusedAndNothingIsStored() throws {
        let fixture = CertificateFixture(subjectKey: enclaveKey)
        let beforeWindow = ISO8601DateFormatter().date(from: "2026-10-04T00:00:00Z")!
        assertRefused(try fixture.der(), expected: .notYetValid(notBefore: fixture.notBefore), at: beforeWindow)
    }

    func testAMachineCertificateWithClientAuthIsRefused() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.extendedKeyUsage = [CertificateFixture.clientAuth]
        assertRefused(try fixture.der(),
                      expected: .notSigningOnly("extendedKeyUsage names purposes other than signing"))
    }

    /// Signing plus clientAuth must fail too: a check that only asked whether
    /// the signing purpose is present would accept it.
    func testASigningCertificateThatAlsoNamesClientAuthIsRefused() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.extendedKeyUsage = [SigningCertificate.signingPurpose, CertificateFixture.clientAuth]
        assertRefused(try fixture.der(),
                      expected: .notSigningOnly("extendedKeyUsage names purposes other than signing"))
    }

    func testANonCriticalExtendedKeyUsageIsRefused() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.extendedKeyUsageCritical = false
        assertRefused(try fixture.der(), expected: .notSigningOnly("extendedKeyUsage is not critical"))
    }

    func testAKeyUsageThatAssertsMoreThanDigitalSignatureIsRefused() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.keyUsage = 0xA0 // digitalSignature and keyEncipherment
        assertRefused(try fixture.der(),
                      expected: .notSigningOnly("keyUsage asserts more than digitalSignature"))
    }

    func testAMissingKeyUsageIsRefused() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.keyUsage = nil
        assertRefused(try fixture.der(), expected: .notSigningOnly("it has no keyUsage extension"))
    }

    func testANonCriticalKeyUsageIsRefused() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.keyUsageCritical = false
        assertRefused(try fixture.der(), expected: .notSigningOnly("keyUsage is not critical"))
    }

    func testACACertificateIsRefused() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.isCA = true
        assertRefused(try fixture.der(), expected: .notSigningOnly("it is a CA certificate"))
    }

    /// Absent basicConstraints leaves cA unstated, which is not the cA FALSE the contract requires.
    func testACertificateWithoutBasicConstraintsIsRefused() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.isCA = nil
        assertRefused(try fixture.der(), expected: .notSigningOnly("it has no basicConstraints extension"))
    }

    /// RFC 5280 §4.2: a critical extension Deck does not process must refuse the certificate.
    func testACriticalUnknownExtensionIsRefused() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.extraExtension = (oid: CertificateFixture.nameConstraints, critical: true)
        assertRefused(try fixture.der(),
                      expected: .notACertificate("it has a critical extension Deck does not read"))
    }

    /// BER reads any nonzero BOOLEAN content octet as TRUE, so a 0x01 critical flag must refuse
    /// the certificate as 0xFF does, and a 0x00 flag reads as non-critical and is accepted.
    func testACriticalFlagOfAnyNonzeroByteIsRefusedAndZeroIsNot() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.extraExtension = (oid: CertificateFixture.nameConstraints, critical: true)
        fixture.extraCriticalByte = 0x01
        assertRefused(try fixture.der(),
                      expected: .notACertificate("it has a critical extension Deck does not read"))

        fixture.extraCriticalByte = 0x00
        XCTAssertNoThrow(try importFile(try fixture.der()))
    }

    func testAnOuterSignatureAlgorithmOtherThanEcdsaSHA256IsRefused() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.outerSignatureOID = CertificateFixture.sha1WithRSA
        assertRefused(try fixture.der(),
                      expected: .notACertificate("the signature algorithm is not ecdsa-with-SHA256"))
    }

    func testATbsSignatureAlgorithmOtherThanEcdsaSHA256IsRefused() throws {
        var fixture = CertificateFixture(subjectKey: enclaveKey)
        fixture.tbsSignatureOID = CertificateFixture.sha1WithRSA
        assertRefused(try fixture.der(),
                      expected: .notACertificate("the signature algorithm is not ecdsa-with-SHA256"))
    }

    func testBytesAfterTheOuterSequenceAreRefused() throws {
        let der = try CertificateFixture(subjectKey: enclaveKey).der()
        assertRefused(der + Data([0x00]), expected: .notACertificate("the bytes are not one DER certificate"))
    }

    /// `Int(_:)` reads `+5` and `-5` as numbers, so a signed digit is refused as a non-digit.
    func testASignedDigitInAValidityTimeIsRefused() throws {
        let signed = "non-digit characters"
        try assertTimeRefused(.init(tag: 0x17, text: "26+501000000Z"), because: "a validity time has \(signed)")
        try assertTimeRefused(.init(tag: 0x17, text: "26-501000000Z"), because: "a validity time has \(signed)")
        try assertTimeRefused(.init(tag: 0x18, text: "2026+501000000Z"), because: "a validity time has \(signed)")
        try assertTimeRefused(.init(tag: 0x18, text: "2026-501000000Z"), because: "a validity time has \(signed)")
    }

    /// Calendar rolls these into another date, so each must be refused by the read-back check.
    func testAnOutOfRangeValidityTimeIsRefused() throws {
        let range = "a validity time is out of range"
        let utcTimes = ["261301000000Z", "260140000000Z", "260101240000Z",
                        "260230000000Z", "260101000060Z", "260100000000Z"]
        for text in utcTimes {
            try assertTimeRefused(.init(tag: 0x17, text: text), because: range)
        }
        let generalizedTimes = ["20261301000000Z", "20260140000000Z", "20260101240000Z",
                                "20260230000000Z", "20260101000060Z", "20260100000000Z"]
        for text in generalizedTimes {
            try assertTimeRefused(.init(tag: 0x18, text: text), because: range)
        }
    }

    func testAValidityTimeOfTheWrongShapeIsRefused() throws {
        let shape = "a validity time is not a UTC time"
        try assertTimeRefused(.init(tag: 0x17, text: "26010100000Z"), because: shape) // one digit short
        try assertTimeRefused(.init(tag: 0x17, text: "260101000000"), because: shape) // no Z
        try assertTimeRefused(.init(tag: 0x16, text: "260101000000Z"), because: shape) // IA5String tag
    }

    func testAFileThatIsNotACertificateIsRefusedAndNothingIsStored() throws {
        let garbage = Data("not a certificate at all".utf8)
        XCTAssertThrowsError(try importFile(garbage)) { error in
            guard case SigningCertificateError.notACertificate = error else {
                return XCTFail("expected notACertificate, got \(error)")
            }
        }
        assertNothingStored()
    }

    func testATruncatedCertificateIsRefused() throws {
        let der = try CertificateFixture(subjectKey: enclaveKey).der()
        XCTAssertThrowsError(try importFile(Data(der.prefix(der.count / 2)))) { error in
            guard case SigningCertificateError.notACertificate = error else {
                return XCTFail("expected notACertificate, got \(error)")
            }
        }
        assertNothingStored()
    }

    // MARK: - Store

    func testNoStoredCertificateReadsAsNilNotAnError() {
        XCTAssertNil(store.loadPEM(forSPKI: deckSPKI(for: enclaveKey)))
    }

    func testAStoredCertificateIsReadBackVerbatim() throws {
        let pem = CertificateFixture.pem(try CertificateFixture(subjectKey: enclaveKey).der())
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pem.write(to: store.fileURL)

        XCTAssertEqual(store.loadPEM(forSPKI: deckSPKI(for: enclaveKey)), String(decoding: pem, as: UTF8.self))
    }

    func testDeleteRemovesTheStoredCertificateAndIsIdempotent() throws {
        _ = try importFile(try CertificateFixture(subjectKey: enclaveKey).der())
        try store.delete()
        XCTAssertNil(try store.loadCertificate())
        XCTAssertNoThrow(try store.delete())
    }

    /// A save signs with the key it reads, so the certificate it attaches must
    /// certify that key. A key replaced outside Deck leaves its old certificate on disk.
    func testTheStoredCertificateIsReturnedOnlyForTheKeyItCertifies() throws {
        XCTAssertNil(store.loadPEM(forSPKI: deckSPKI(for: enclaveKey)), "nothing is stored yet")

        let stored = try importFile(try CertificateFixture(subjectKey: enclaveKey).der())
        XCTAssertEqual(store.loadPEM(forSPKI: deckSPKI(for: enclaveKey)), stored.pem)

        let rotated = P256.Signing.PrivateKey()
        XCTAssertNil(store.loadPEM(forSPKI: deckSPKI(for: rotated)),
                     "the old certificate must not attach to the replacement key's signatures")
    }

    // MARK: - Helpers

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writePEM(_ data: Data) throws -> String {
        let path = directory.appendingPathComponent("fixture.pem").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Runs `/usr/bin/openssl` and returns its stdout, failing on a non-zero exit.
    private func openssl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: stdout, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: stderr, as: UTF8.self))
        return text
    }
}
