import Foundation
import Security

/// This Mac's client identity for the Library's mutual-TLS listener, per
/// host — the seam CQ·161 (the Secure Enclave machine key, issue_01M4R2PP7Z1MFSH4HM0JAR1PCN)
/// fills in. Injectable so a test can supply a software identity without a
/// keychain or an Enclave.
protocol LibraryClientIdentityProviding: Sendable {
    /// `nil` means this Mac has no machine certificate for `host` yet, which
    /// is `LibraryTransportSelector`'s cue to leave that host on the existing
    /// bearer-token path — never a reason to retry with one invented here.
    func identity(for host: SSHTarget) -> SecIdentity?
}

/// **THE SEAM CQ·161 FILLS IN.** Until that item lands, no machine
/// certificate exists on any Mac this runs on, so this answers `nil` for
/// every host and every Library call stays on the bearer-token path — see
/// `platform/decisions/0065`'s "Measured before it is built" and comment
/// 5310 on this item (CQ·162) for why the transport is built ahead of the
/// key test rather than the other way around.
///
/// CQ·161 replaces this type's body with a read of the enclave-backed
/// `SecIdentity` it mints and stores, keyed by host the way `SigningKeyStore`
/// is keyed by Mac — it does not need a new protocol, only a new answer.
struct ProductionLibraryClientIdentityProvider: LibraryClientIdentityProviding {
    func identity(for host: SSHTarget) -> SecIdentity? { nil }
}
