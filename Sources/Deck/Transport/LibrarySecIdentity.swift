import Foundation
import Security

/// Builds a `SecIdentity` from a certificate and a private key that were never
/// imported into a keychain — the shape both Deck's production client
/// certificate (CQ·161, once it exists) and this file's test doubles need:
/// neither wants a keychain item, and `SecIdentity` otherwise only comes from
/// one.
///
/// `SecIdentityCreate` DOES EXACTLY THIS AND IS NOT IN ANY PUBLIC HEADER.
/// Security.framework exports the symbol — `nm` on the installed dylib shows
/// it — but Apple has never published its signature, so the normal `import
/// Security` route to it does not exist. `dlsym` against the already-loaded
/// framework is the standard workaround for a private, exported-but-
/// undeclared Apple symbol, and it is what CQ·162's issue body itself
/// prescribes. The signature below —
/// `(CFAllocator?, SecCertificate, SecKey) -> SecIdentity?`, one retained
/// reference returned — matches every third-party description of the symbol
/// still findable in open-source code that has shipped against it for years
/// (e.g. libimobiledevice, several TLS test harnesses); there is no first-party
/// text to cite instead.
enum LibrarySecIdentity {
    private typealias CreateFunction = @convention(c) (
        CFAllocator?, SecCertificate, SecKey
    ) -> Unmanaged<SecIdentity>?

    /// Bound once, lazily, the same cost `DeckIdentity`'s file check pays
    /// once per process rather than once per call.
    private static let create: CreateFunction? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "SecIdentityCreate") else { return nil }
        return unsafeBitCast(symbol, to: CreateFunction.self)
    }()

    /// `nil` when the symbol could not be bound (an OS this library has never
    /// been checked against) or when `SecIdentityCreate` itself refused —
    /// either way, a caller treats this exactly like "no identity available"
    /// rather than crashing.
    static func make(certificate: SecCertificate, privateKey: SecKey) -> SecIdentity? {
        guard let create else { return nil }
        // "Create" is Apple's own ownership convention for a +1 reference:
        // the caller is handed one retain and must release it, which
        // `takeRetainedValue()` does on Swift's behalf.
        return create(nil, certificate, privateKey)?.takeRetainedValue()
    }
}
