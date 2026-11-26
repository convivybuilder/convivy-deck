import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Deck's own "does this machine serve sessions" check — run at every merge
/// or close press, BEFORE any credential is read
/// (`deck/decisions/0003-under-deterministic-deck-merges-with-the-operators-own-credential`):
///
/// > Deck checks at every press that its machine serves no sessions... Deck
/// > counts its own machine as serving sessions when either of these holds:
/// > a configured host's address resolves to Deck's own machine; or Deck
/// > finds a Builder install on its own machine, read from the install's own
/// > location and service records.
///
/// Both sub-checks are injected seams so a test never resolves a real
/// hostname or touches the real filesystem; `MachineIdentity.current()` and
/// `BuilderInstallProbe.foundHere()` are the real, production answers.
enum ServedSessionsCheck {
    /// Whether any configured host is this machine: its `address` names one
    /// of `localIdentities` (this machine's own hostnames and IP addresses,
    /// lower-cased), or `resolveAddress` turns it into one of them, which is
    /// how a host entered by a DNS or MagicDNS name is recognised. `user`
    /// plays no part, since two different accounts on the same machine still
    /// make it the machine that serves Deck's sessions.
    ///
    /// The real `resolveAddress` can block on DNS, so this never runs on the
    /// main actor.
    static func configuredHostResolvesHere(
        hosts: [HostEntry],
        localIdentities: Set<String>,
        resolveAddress: (String) -> Set<String> = { _ in [] }
    ) -> Bool {
        guard !localIdentities.isEmpty else { return false }
        if hosts.contains(where: { localIdentities.contains($0.address.lowercased()) }) {
            return true
        }
        return hosts.contains { !resolveAddress($0.address).isDisjoint(with: localIdentities) }
    }

    /// The whole check, in the order 0003 names: a configured host first,
    /// then a Builder install — `nil` when neither holds, which is the only
    /// case that lets a press continue to the credential read.
    static func evaluate(
        hosts: [HostEntry],
        localIdentities: () -> Set<String> = MachineIdentity.current,
        resolveAddress: (String) -> Set<String> = MachineIdentity.resolvedAddresses,
        builderInstalledHere: () -> Bool = { BuilderInstallProbe.foundHere() }
    ) -> MergeRefusal.ServesSessionsReason? {
        if configuredHostResolvesHere(
            hosts: hosts, localIdentities: localIdentities(), resolveAddress: resolveAddress) {
            return .configuredHostResolvesHere
        }
        if builderInstalledHere() {
            return .builderInstalledHere
        }
        return nil
    }
}

/// This machine's own hostnames and IP addresses, lower-cased — what a
/// configured host's `address` is checked against.
enum MachineIdentity {
    /// The real answer: the machine's local/short/full hostnames
    /// (`ProcessInfo`, `gethostname`) plus every IPv4/IPv6 address
    /// `getifaddrs` reports for a running interface, always including the
    /// loopback forms so a host entry typed as `127.0.0.1` or `localhost`
    /// is recognised as this machine too.
    static func current() -> Set<String> {
        var identities: Set<String> = ["127.0.0.1", "::1", "localhost"]
        identities.formUnion(hostnames())
        identities.formUnion(interfaceAddresses())
        return Set(identities.map { $0.lowercased() })
    }

    private static func hostnames() -> Set<String> {
        var names: Set<String> = []
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            names.insert(String(decoding: bytes, as: UTF8.self))
        }
        names.insert(ProcessInfo.processInfo.hostName)
        for name in names {
            // `hostname -s`'s own shape: the label before the first dot, so
            // a host entry naming the short form resolves too.
            if let dot = name.firstIndex(of: ".") {
                names.insert(String(name[name.startIndex..<dot]))
            }
        }
        return names.filter { !$0.isEmpty }
    }

    /// Every IPv4/IPv6 address bound to a running interface on this machine,
    /// via `getifaddrs` — the same POSIX call `KeelSocket`'s own file
    /// already imports `Darwin` for, not a new dependency.
    private static func interfaceAddresses() -> Set<String> {
        var addresses: Set<String> = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return addresses }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let addr = interface.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else { continue }
            let length = family == sa_family_t(AF_INET)
                ? socklen_t(MemoryLayout<sockaddr_in>.size) : socklen_t(MemoryLayout<sockaddr_in6>.size)
            if let text = numericHost(addr, length: length) {
                addresses.insert(text)
            }
        }
        return addresses
    }

    /// Every address `getaddrinfo` gives for a configured host's `address`,
    /// in the same numeric form `interfaceAddresses` reports, or an empty
    /// set when it does not resolve. Blocks on DNS.
    static func resolvedAddresses(of address: String) -> Set<String> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &head) == 0, let first = head else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: Set<String> = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            defer { cursor = info.pointee.ai_next }
            guard let addr = info.pointee.ai_addr else { continue }
            if let text = numericHost(addr, length: info.pointee.ai_addrlen) {
                addresses.insert(text.lowercased())
            }
        }
        return addresses
    }

    private static func numericHost(_ addr: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        let hostBytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let text = String(decoding: hostBytes, as: UTF8.self)
        // An IPv6 address off a real interface carries a zone id
        // (`fe80::1%en0`) that never appears in a hand-typed host entry.
        if let percent = text.firstIndex(of: "%") {
            return String(text[text.startIndex..<percent])
        }
        return text
    }
}

/// Whether a Convivy Builder install is on this machine — 0003's second
/// served-sessions finding, read from the install's own location and service
/// records. Any one marker is enough:
///
/// - the Individuator's install locations, present on an install with a
///   privileged half;
/// - the Library's launchd job, `com.convivy.library`, which every install
///   runs: a LaunchDaemon on a multi-account install, a LaunchAgent in the
///   account's own home on a single-account one
///   (`company/decisions/0017`), where there is no privileged half and so no
///   Individuator;
/// - the privileged installer's record at its default prefix.
enum BuilderInstallProbe {
    static let defaultKeyDirectory = "/var/db/individuator"
    static let defaultConfigPath = "/etc/individuator/config.json"
    static let defaultLaunchDaemonPlist = "/Library/LaunchDaemons/com.convivy.individuator.plist"
    static let libraryLaunchDaemonPlist = "/Library/LaunchDaemons/com.convivy.library.plist"
    static let privilegedInstallRecord = "/opt/builder/install.json"

    static func libraryLaunchAgentPlist(home: String) -> String {
        "\(home)/Library/LaunchAgents/com.convivy.library.plist"
    }

    static func markerPaths(home: String) -> [String] {
        [defaultKeyDirectory, defaultConfigPath, defaultLaunchDaemonPlist,
         libraryLaunchDaemonPlist, privilegedInstallRecord, libraryLaunchAgentPlist(home: home)]
    }

    /// The real answer: any one of the install markers existing on this
    /// machine's filesystem.
    static func foundHere(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        found(home: NSHomeDirectory(), fileExists: fileExists)
    }

    /// The pure check `foundHere` wraps, so a test can assert on the exact
    /// paths checked without touching the real filesystem.
    static func found(home: String, fileExists: (String) -> Bool) -> Bool {
        markerPaths(home: home).contains { fileExists($0) }
    }
}
