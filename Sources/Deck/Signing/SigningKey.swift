import CryptoKit
import Foundation

/// A P-256 signing key, seen through only what Deck needs of it. The Secure
/// Enclave implementation cannot run under XCTest (it needs the Enclave and,
/// to sign, a person at the sensor), so tests stand a software key behind the
/// same protocol.
protocol SigningKey: Sendable {
    /// The 65-byte uncompressed public point.
    var publicKeyX963: Data { get }
    /// The blob `SigningKeyFactory.key(fromDataRepresentation:)` restores the
    /// key from. For the Enclave this is a wrapped handle, usable only on the
    /// Mac that made it.
    var dataRepresentation: Data { get }
    /// DER-encoded ECDSA signature. Throws `SigningKeyError.cancelled` when the
    /// person dismisses the user-presence prompt, in which case nothing is signed.
    func sign(_ message: Data) throws -> Data
    /// Signs like `sign(_:)`, and where the key can, shows `reason` in the user
    /// presence prompt. Each call asks once.
    func sign(_ message: Data, reason: String) throws -> Data
}

extension SigningKey {
    /// Keys that cannot set a prompt reason sign with the platform's default prompt.
    func sign(_ message: Data, reason: String) throws -> Data {
        try sign(message)
    }
}

protocol SigningKeyFactory: Sendable {
    func makeKey() throws -> SigningKey
    func key(fromDataRepresentation blob: Data) throws -> SigningKey
}

enum SigningKeyError: Error, Equatable, LocalizedError {
    /// The person dismissed the Touch ID or password prompt.
    case cancelled
    /// This Mac has no Secure Enclave, or it refused to make a key.
    case unavailable(String)
    /// The stored blob exists but does not restore to a key.
    case unreadableKey(String)
    /// The blob could not be read from or written to disk.
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "The prompt was cancelled."
        case .unavailable(let why): return "The Secure Enclave is unavailable: \(why)"
        case .unreadableKey(let why): return "The stored signing key cannot be read: \(why)"
        case .storage(let why): return "The signing key file could not be accessed: \(why)"
        }
    }
}

enum SigningKeyFingerprint {
    /// The first 16 hex characters of the SHA-256 of the x963 public key: enough
    /// for a person to tell two keys apart, not a identifier to verify against.
    static func of(publicKeyX963: Data) -> String {
        let hex = SHA256.hash(data: publicKeyX963).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}

/// Keeps one key per Mac in a file, and reuses it until it is deleted.
///
/// WHY A FILE AND NOT THE KEYCHAIN. What is stored is the Enclave's
/// `dataRepresentation`, a blob wrapped to this Mac's Enclave that is useless
/// anywhere else, so the file needs no secrecy beyond mode 0600. A login
/// keychain item would carry an ACL bound to the app's code signature, and Deck
/// is ad-hoc signed and rebuilt by its launcher: every build would present a new
/// identity and re-prompt for the item. The Enclave's own access control
/// (user presence on every signature) is what guards use of the key.
struct SigningKeyStore: Sendable {
    let fileURL: URL
    let factory: SigningKeyFactory

    /// Where Deck keeps the blob, beside its other Application Support state.
    static func defaultFileURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Deck/signing-key.blob")
    }

    /// The existing key, or nil when there is none. A blob that will not restore
    /// throws rather than reading as "no key": replacing it would orphan
    /// whatever the old key signed and hide the fault.
    func load() throws -> SigningKey? {
        let blob: Data
        do {
            blob = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw SigningKeyError.storage(error.localizedDescription)
        }
        do {
            return try factory.key(fromDataRepresentation: blob)
        } catch {
            throw SigningKeyError.unreadableKey(error.localizedDescription)
        }
    }

    func loadOrCreate() throws -> SigningKey {
        if let existing = try load() { return existing }
        let key = try factory.makeKey()
        try write(key.dataRepresentation)
        return key
    }

    func delete() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw SigningKeyError.storage(error.localizedDescription)
        }
    }

    /// Atomic and 0600 from the first byte: the temporary file is created with
    /// the mode already set, then renamed over the destination. `Data.write`'s
    /// `.atomic` option would create it with the process umask and leave a
    /// window at a wider mode.
    private func write(_ blob: Data) throws {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: temporary.path, contents: blob,
                                attributes: [.posixPermissions: 0o600]) else {
                throw SigningKeyError.storage("could not create \(temporary.path)")
            }
            if rename(temporary.path, fileURL.path) != 0 {
                throw SigningKeyError.storage(String(cString: strerror(errno)))
            }
        } catch {
            try? fm.removeItem(at: temporary)
            if let error = error as? SigningKeyError { throw error }
            throw SigningKeyError.storage(error.localizedDescription)
        }
    }
}

/// What a press of Settings' Test signature button came to.
enum SigningTestOutcome: Equatable, Sendable {
    case signed, cancelled, failed(String)

    static let testMessage = Data("Convivy Deck signing key test".utf8)

    /// Signs the fixed string. This is the call that raises the prompt, so it
    /// blocks until the person answers and must not run on the main thread.
    static func run(_ key: SigningKey) -> SigningTestOutcome {
        do {
            _ = try key.sign(testMessage)
            return .signed
        } catch SigningKeyError.cancelled {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// The wording Settings shows, kept out of the view so it can be tested.
struct SigningKeyPresentation: Equatable {
    enum KeyState: Equatable {
        case present(fingerprint: String)
        case absent
        case failed(String)
    }

    let state: KeyState
    let test: SigningTestOutcome?

    var headline: String {
        switch state {
        case .present: return "This Mac has a signing key."
        case .absent: return "This Mac has no signing key."
        case .failed(let why): return "The signing key could not be loaded: \(why)"
        }
    }

    var fingerprintLine: String? {
        if case .present(let fingerprint) = state { return fingerprint }
        return nil
    }

    var canTest: Bool { fingerprintLine != nil }

    var testLine: String? {
        switch test {
        case nil: return nil
        case .signed: return "Signed."
        case .cancelled: return "Cancelled. Nothing was signed."
        case .failed(let why): return "Failed: \(why)"
        }
    }
}
