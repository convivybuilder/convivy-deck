import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The Secure Enclave implementation of `SigningKey`.
///
/// The key requires user presence for every signature: Touch ID, or the account
/// password on a Mac without it. It is `ThisDeviceOnly`, so it never leaves this
/// Mac. No entitlement or Developer ID signing is needed; an ad-hoc-signed
/// binary created such a key on the mini.
struct SecureEnclaveSigningKey: SigningKey, @unchecked Sendable {
    // CryptoKit does not mark the Enclave key Sendable. It is an immutable
    // handle, and signing serialises inside the Enclave.
    private let key: SecureEnclave.P256.Signing.PrivateKey
    /// The wrapped handle `key` was made from. `sign(_:reason:)` restores a handle
    /// from it so each signature can carry its own prompt context.
    private let blob: Data

    var publicKeyX963: Data { key.publicKey.x963Representation }
    var dataRepresentation: Data { blob }

    func sign(_ message: Data) throws -> Data {
        do {
            return try key.signature(for: message).derRepresentation
        } catch {
            throw SecureEnclaveSigningKey.translate(error)
        }
    }

    /// Signs with a fresh `LAContext` whose `localizedReason` is `reason`, so the
    /// Touch ID prompt names what it signs. The context is not reused, so every
    /// call presents its own prompt.
    func sign(_ message: Data, reason: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason
        do {
            let handle = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: blob, authenticationContext: context)
            return try handle.signature(for: message).derRepresentation
        } catch {
            throw SecureEnclaveSigningKey.translate(error)
        }
    }

    /// Cancellation surfaces as an `LAError` or as Security's
    /// `errSecUserCanceled`, depending on which layer raised the prompt.
    static func translate(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == LAError.errorDomain,
           [LAError.userCancel.rawValue, LAError.appCancel.rawValue, LAError.systemCancel.rawValue].contains(ns.code) {
            return SigningKeyError.cancelled
        }
        if ns.domain == NSOSStatusErrorDomain, ns.code == Int(errSecUserCanceled) {
            return SigningKeyError.cancelled
        }
        return error
    }

    fileprivate init(_ key: SecureEnclave.P256.Signing.PrivateKey) {
        self.key = key
        blob = key.dataRepresentation
    }
}

struct SecureEnclaveSigningKeyFactory: SigningKeyFactory {
    func makeKey() throws -> SigningKey {
        guard SecureEnclave.isAvailable else {
            throw SigningKeyError.unavailable("this Mac has no Secure Enclave")
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence], &error
        ) else {
            let why = error?.takeRetainedValue().localizedDescription ?? "access control was refused"
            throw SigningKeyError.unavailable(why)
        }
        do {
            return SecureEnclaveSigningKey(try SecureEnclave.P256.Signing.PrivateKey(accessControl: access))
        } catch {
            throw SigningKeyError.unavailable(error.localizedDescription)
        }
    }

    func key(fromDataRepresentation blob: Data) throws -> SigningKey {
        SecureEnclaveSigningKey(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob))
    }
}
