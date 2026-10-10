import Foundation

/// Why Deck refused a certificate or could not store one. Every refusal says
/// nothing was stored, so the person knows the stored certificate, if any, stands.
enum SigningCertificateError: Error, Equatable, LocalizedError {
    case notACertificate(String)
    case noSigningKey
    case forAnotherKey
    case notYetValid(notBefore: Date)
    case expired(notAfter: Date)
    case notSigningOnly(String)
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .notACertificate(let why):
            return "This file is not an X.509 certificate: \(why). Nothing was stored."
        case .noSigningKey:
            return "This Mac has no signing key yet. Create one, then import its certificate. Nothing was stored."
        case .forAnotherKey:
            return "This certificate certifies a different key from this Mac's signing key. Nothing was stored."
        case .notYetValid(let notBefore):
            return "This certificate is not valid until \(notBefore.formatted(.iso8601)). Nothing was stored."
        case .expired(let notAfter):
            return "This certificate expired at \(notAfter.formatted(.iso8601)). Nothing was stored."
        case .notSigningOnly(let why):
            return "This is not a signing-only certificate: \(why). Nothing was stored."
        case .storage(let why):
            return "The certificate could not be stored: \(why)"
        }
    }
}

/// Checks a certificate the person picked and stores it beside the signing key.
///
/// The checks run in this order and stop at the first failure: the public key
/// matches this Mac's key, `now` falls inside the validity window, and the
/// certificate is signing-only (keyUsage is critical and digitalSignature alone,
/// extendedKeyUsage is critical and names only the signing purpose, and it is
/// not a CA). The contract assigns the chain check to `kb apply`, so Deck does
/// not check that the Library root signed it.
///
/// The signing-only checks also require basicConstraints to be present with
/// cA false, as `library-protocol` §2.2 specifies.
enum SigningCertificateImport {
    /// Parses `fileData` and returns it when it passes every check for `spkiDER`,
    /// this Mac's key's `SubjectPublicKeyInfo`, at `now`.
    static func accept(fileData: Data, forSPKI spkiDER: Data, now: Date) throws -> SigningCertificate {
        let certificate = try SigningCertificate.parse(fileData: fileData)
        guard certificate.spkiDER == spkiDER else { throw SigningCertificateError.forAnotherKey }
        guard now >= certificate.notBefore else {
            throw SigningCertificateError.notYetValid(notBefore: certificate.notBefore)
        }
        guard now <= certificate.notAfter else {
            throw SigningCertificateError.expired(notAfter: certificate.notAfter)
        }
        try checkSigningOnly(certificate)
        return certificate
    }

    /// `accept`, then the write: nothing is stored unless every check passes.
    static func importCertificate(fileData: Data, forSPKI spkiDER: Data, now: Date,
                                  into store: SigningCertificateStore) throws -> SigningCertificate {
        let certificate = try accept(fileData: fileData, forSPKI: spkiDER, now: now)
        try store.save(certificate)
        return certificate
    }

    private static func checkSigningOnly(_ certificate: SigningCertificate) throws {
        guard let keyUsage = certificate.keyUsage else {
            throw SigningCertificateError.notSigningOnly("it has no keyUsage extension")
        }
        guard keyUsage.critical else {
            throw SigningCertificateError.notSigningOnly("keyUsage is not critical")
        }
        guard keyUsage.bits == [SigningCertificate.digitalSignatureBit] else {
            throw SigningCertificateError.notSigningOnly("keyUsage asserts more than digitalSignature")
        }
        guard let eku = certificate.extendedKeyUsage else {
            throw SigningCertificateError.notSigningOnly("it has no extendedKeyUsage extension")
        }
        guard eku.critical else {
            throw SigningCertificateError.notSigningOnly("extendedKeyUsage is not critical")
        }
        guard eku.purposes == [SigningCertificate.signingPurpose] else {
            throw SigningCertificateError.notSigningOnly("extendedKeyUsage names purposes other than signing")
        }
        guard let isCA = certificate.isCA else {
            throw SigningCertificateError.notSigningOnly("it has no basicConstraints extension")
        }
        guard !isCA else {
            throw SigningCertificateError.notSigningOnly("it is a CA certificate")
        }
    }
}
