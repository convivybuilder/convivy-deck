import Foundation

/// Which path one host's Library calls take — CQ·162's "one transport switch
/// for all three composers, chosen per host". `LibraryClient`'s GET and POST
/// templates and `WorkingCopyStore`'s document fetch all read this through
/// `LibraryTransportSelector` rather than each deciding on its own, so the
/// three cannot drift on what one host is doing.
enum LibraryTransport: Equatable {
    /// Mutual TLS through the byte forward to `127.0.0.1:8443` on the host.
    case mutualTLS
    /// Today's bearer-token-over-ssh path to `127.0.0.1:8100`.
    case existingPath
}

/// Chooses `LibraryTransport` for a host from whether this Mac has a machine
/// certificate for it — never from a stored preference, since a flag that
/// could say "mutual TLS" while no certificate exists would be the silently-
/// broken-looking certificate CQ·162's done conditions exist to rule out.
struct LibraryTransportSelector: Sendable {
    let identityProvider: LibraryClientIdentityProviding
    let anchorProvider: LibraryServerTrustAnchorProviding

    /// The production instance: both seams answer `nil` until CQ·161 lands
    /// (the client identity) and an operator enrolls in Settings (the trust
    /// anchor), so `transport(for:)` answers `.existingPath` for every host
    /// today — see each provider's own doc.
    static let shared = LibraryTransportSelector(
        identityProvider: ProductionLibraryClientIdentityProvider(),
        anchorProvider: ProductionLibraryServerTrustAnchorProvider())

    /// **BOTH A CERTIFICATE AND AN ANCHOR, NOT EITHER ALONE.** The issue's
    /// own wording — "mutual TLS when a machine certificate is present" —
    /// names the certificate, but a client identity with no configured root
    /// to verify the Library's own certificate against would hand a
    /// `URLSession` a client cert and nothing to check the server with,
    /// which is a half-built mutual handshake rather than a safe one. Today
    /// both providers are `nil` together, so this distinction changes
    /// nothing in production yet; it is here so the day CQ·161 ships a
    /// certificate ahead of an operator choosing a root in Settings, that
    /// host stays on the existing path rather than dialing a TLS session
    /// this client cannot verify.
    func transport(for host: SSHTarget) -> LibraryTransport {
        guard identityProvider.identity(for: host) != nil,
              let anchors = anchorProvider.anchorCertificates(for: host), !anchors.isEmpty
        else { return .existingPath }
        return .mutualTLS
    }
}

/// Settings › Hosts' own wording for a host's chosen transport — a pure
/// function so the two labels are pinned by a test rather than only read off
/// the row.
enum LibraryTransportDisplay {
    static func label(_ transport: LibraryTransport) -> String {
        switch transport {
        case .mutualTLS: return "Mutual TLS"
        case .existingPath: return "Bearer token over ssh"
        }
    }
}
