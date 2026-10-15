import Foundation
import Security

/// The operator's own Library root certificate, per host — the only anchor
/// `LibraryServerTrustEvaluator` trusts for that host's mutual-TLS listener.
/// Injectable so a test can supply a throwaway root rather than a real one.
///
/// **NEVER FETCHED OVER SSH.** `platform/decisions/0066`'s root key lives only
/// on the operator's laptop, released by Touch ID; the Library holds the public certificate,
/// which is harmless to read, but this item's scope is the operator choosing
/// the root file in Settings as part of CQ·161's enrollment flow — a value
/// that reaches Deck by the operator's own hand, never by Deck asking the
/// host for it.
protocol LibraryServerTrustAnchorProviding: Sendable {
    /// `nil` means no root is configured for `host` yet, which
    /// `LibraryTransportSelector` reads the same way it reads a missing
    /// client identity: stay on the existing path rather than anchor trust
    /// to nothing and accept anything.
    func anchorCertificates(for host: SSHTarget) -> [SecCertificate]?
}

/// **THE SEAM CQ·161's ENROLLMENT FLOW FILLS IN.** Until an operator has
/// chosen a root file in Settings, nothing anchors trust for any host, so
/// this answers `nil` for every one and `LibraryTransportSelector` leaves
/// every host on the existing path — the same posture
/// `ProductionLibraryClientIdentityProvider` takes for the same reason.
struct ProductionLibraryServerTrustAnchorProvider: LibraryServerTrustAnchorProviding {
    func anchorCertificates(for host: SSHTarget) -> [SecCertificate]? { nil }
}

/// Evaluates a server's `SecTrust` against exactly the operator's own
/// anchors, per `platform/decisions/0066`'s revocation section and
/// `library-protocol`'s own refusal semantics: a certificate the Library's
/// root did not sign is refused, and a certificate signed by ANY other root —
/// including a real, generally-trusted one — is refused just the same,
/// because the only root that means anything here is the operator's.
enum LibraryServerTrustEvaluator {
    enum Outcome: Equatable {
        case trusted
        /// Carries `SecTrustEvaluateWithError`'s own `CFError` description,
        /// for whatever surfaces the handshake failure to the operator.
        case refused(String)
    }

    /// `SecTrustSetAnchorCertificatesOnly(true)` is the whole point of this
    /// function existing rather than leaving `trust` to the system's default
    /// evaluation: without it, a certificate chaining to any of the Mac's
    /// ordinary trusted roots would also pass, which is exactly the "pin to
    /// nothing, trust everything" failure CQ·162's done conditions name by
    /// requiring a foreign-root refusal.
    static func evaluate(_ trust: SecTrust, anchors: [SecCertificate]) -> Outcome {
        let setAnchorsStatus = SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        guard setAnchorsStatus == errSecSuccess else {
            return .refused("could not set anchor certificates (\(setAnchorsStatus))")
        }
        let onlyStatus = SecTrustSetAnchorCertificatesOnly(trust, true)
        guard onlyStatus == errSecSuccess else {
            return .refused("could not restrict trust to the given anchors (\(onlyStatus))")
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            return .refused(error.map { String(describing: $0) } ?? "trust evaluation failed")
        }
        return .trusted
    }
}
