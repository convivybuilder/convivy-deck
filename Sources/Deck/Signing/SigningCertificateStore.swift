import Foundation

/// Where Deck keeps this Mac's signing certificate.
///
/// The import writes it (`SigningCertificateImport`) after checking it is for
/// the Secure Enclave key `SigningKeyStore` holds. Signed saves read it through
/// `loadPEM(forSPKI:)`, which returns it only for the key they sign with, and
/// Settings reads it through `loadCertificate`.
struct SigningCertificateStore: Sendable {
    let fileURL: URL

    /// Beside the signing key blob, in the same Application Support directory.
    static func defaultFileURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Deck/signing-certificate.pem")
    }

    /// The stored certificate's PEM text when it certifies `spkiDER`, or nil when
    /// there is none, the file does not parse, or it certifies another key. The
    /// key can be replaced outside Deck while its certificate stays on disk; a
    /// signature made with the new key must not carry the old certificate.
    func loadPEM(forSPKI spkiDER: Data) -> String? {
        guard let certificate = try? loadCertificate(), certificate.spkiDER == spkiDER else { return nil }
        return certificate.pem
    }

    /// The stored certificate, parsed, or nil when there is none. A file that is
    /// present but does not parse throws, so Settings shows the fault rather
    /// than reading as "no certificate".
    func loadCertificate() throws -> SigningCertificate? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw SigningCertificateError.storage(error.localizedDescription)
        }
        return try SigningCertificate.parse(fileData: data)
    }

    func save(_ certificate: SigningCertificate) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(certificate.pem.utf8).write(to: fileURL, options: .atomic)
        } catch {
            throw SigningCertificateError.storage(error.localizedDescription)
        }
    }

    /// Removes the stored certificate. A certificate for a deleted key would
    /// otherwise travel with the next key's signatures and fail at `kb apply`.
    func delete() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw SigningCertificateError.storage(error.localizedDescription)
        }
    }
}
