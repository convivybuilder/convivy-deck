import Foundation

/// The `vnc://` URL that hands a host to macOS Screen Sharing (CQ·140), so a
/// logged-out host's alert can open a session where the operator can choose
/// Log In.
enum ScreenSharingLink {
    /// Builds `vnc://<address>` from `URLComponents`, which percent-encodes the
    /// host rather than pasting the address into a string. An address that
    /// fails `validateHostAddress` yields nil, so the alert draws no button.
    /// `parseHosts` already applies the same check to configured hosts; this
    /// covers a `HostEntry` built anywhere else.
    static func url(forAddress address: String) -> URL? {
        guard (try? validateHostAddress(address)) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = address
        return components.url
    }
}
