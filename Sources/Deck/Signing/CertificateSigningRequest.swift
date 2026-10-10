import CryptoKit
import Foundation

/// A PKCS#10 certificate signing request (RFC 2986) for this Mac's signing key.
/// The Library's root-ca ceremony certifies the key from this request.
///
/// The request has an empty subject. root-ca takes the certificate's identity
/// from its own `--email` and `--machine` flags and never reads the request's
/// subject, so an empty one loses nothing and claims no name.
///
/// The request is self-signed by the key: `SigningKey.sign` runs once, which is
/// the one Touch ID press. root-ca verifies that self-signature before it
/// prints the fingerprint Deck shows beside the file.
enum CertificateSigningRequest {
    struct Request: Equatable {
        /// The PEM text, labelled `CERTIFICATE REQUEST`, which root-ca reads.
        let pem: String
        /// The `SubjectPublicKeyInfo` DER. root-ca fingerprints these bytes.
        let spkiDER: Data
        /// Lowercase hex SHA-256 of `spkiDER`, the value root-ca prints for the
        /// same key. The full 64 characters, not Settings' 16-character key label.
        let spkiFingerprint: String
    }

    static let pemLabel = "CERTIFICATE REQUEST"

    /// Where Deck writes the request, beside the signing key and certificate.
    static func defaultFileURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Deck/signing-request.pem")
    }

    /// Builds and self-signs the request. The signature is the call that raises
    /// Touch ID, so this blocks until the person answers.
    static func make(for key: SigningKey) throws -> Request {
        let spki = subjectPublicKeyInfo(x963: key.publicKeyX963)
        let info = tlv(0x30, integer(0) + tlv(0x30, Data()) + spki + tlv(0xA0, Data()))
        let signature = try key.sign(info)
        let algorithm = tlv(0x30, tlv(0x06, oidEcdsaWithSHA256))
        let csr = tlv(0x30, info + algorithm + tlv(0x03, Data([0x00]) + signature))
        return Request(pem: pem(csr), spkiDER: spki, spkiFingerprint: sha256Hex(spki))
    }

    // MARK: - DER

    /// `SubjectPublicKeyInfo` for an id-ecPublicKey key on prime256v1. The
    /// certificate import compares a certificate's SPKI against this output, so
    /// the two must stay byte-identical.
    static func subjectPublicKeyInfo(x963: Data) -> Data {
        let algorithm = tlv(0x30, tlv(0x06, oidEcPublicKey) + tlv(0x06, oidPrime256v1))
        return tlv(0x30, algorithm + tlv(0x03, Data([0x00]) + x963))
    }

    private static let oidEcPublicKey = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
    private static let oidPrime256v1 = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
    private static let oidEcdsaWithSHA256 = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])

    /// The INTEGER 0 that CertificationRequestInfo's version field requires.
    private static func integer(_ value: UInt8) -> Data { tlv(0x02, Data([value])) }

    private static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    /// DER length: short form below 128 bytes, otherwise long form with the
    /// fewest big-endian octets.
    private static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var octets: [UInt8] = []
        var rest = count
        while rest > 0 {
            octets.insert(UInt8(rest & 0xFF), at: 0)
            rest >>= 8
        }
        return Data([0x80 | UInt8(octets.count)] + octets)
    }

    // MARK: - PEM and hashing

    private static func pem(_ der: Data) -> String {
        let base64 = Array(der.base64EncodedString())
        var lines = ["-----BEGIN \(pemLabel)-----"]
        for start in stride(from: 0, to: base64.count, by: 64) {
            lines.append(String(base64[start..<min(start + 64, base64.count)]))
        }
        lines.append("-----END \(pemLabel)-----")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What a press of Settings' Export signing request button came to.
enum SigningRequestExportOutcome: Equatable, Sendable {
    case written(path: String, fingerprint: String)
    case cancelled
    case failed(String)

    /// Signs a request for `key` and writes it to `url`. Nothing is written
    /// unless the signature succeeds. Blocks on Touch ID, so it must not run
    /// on the main thread.
    static func run(_ key: SigningKey, to url: URL) -> SigningRequestExportOutcome {
        do {
            let request = try CertificateSigningRequest.make(for: key)
            try Data(request.pem.utf8).write(to: url, options: .atomic)
            return .written(path: url.path, fingerprint: request.spkiFingerprint)
        } catch SigningKeyError.cancelled {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
