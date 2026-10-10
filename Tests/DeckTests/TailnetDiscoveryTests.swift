import XCTest
@testable import Deck

/// `TailnetDiscovery` — the local `tailscale status --json` read that backs
/// `AddHostSheet`'s picker (`issue_01M0ECVNHX6XRT47EJJ8B5Z54T`). Exercises the
/// pure parsing/sanitizing path with JSON literals rather than the real
/// daemon, the same discipline `HostProbeTests` follows for `hostname -s`.
final class TailnetDiscoveryTests: XCTestCase {
    // MARK: - Decoding a realistic response

    func testDecodesSelfAndPeersSortedByHostname() {
        let json = """
        {
          "Self": {"HostName": "mini", "TailscaleIPs": ["203.0.113.1", "fe80::1"], "OS": "macOS"},
          "Peer": {
            "nodekey:1": {"HostName": "Macbook", "TailscaleIPs": ["203.0.113.2"], "OS": "macOS", "Online": true},
            "nodekey:2": {"HostName": "linuxbackup", "TailscaleIPs": ["203.0.113.3"], "OS": "linux", "Online": false}
          }
        }
        """
        let machines = TailnetDiscovery.parseMachines(from: Data(json.utf8))
        XCTAssertEqual(machines.map(\.hostName), ["linuxbackup", "Macbook", "mini"])
        XCTAssertEqual(machines.first { $0.hostName == "Macbook" }?.address, "203.0.113.2")
    }

    /// A box being asleep is not a reason to refuse to configure it — the
    /// picker must still offer it, only marked.
    func testAnOfflinePeerIsStillIncludedAndMarkedOffline() {
        let json = """
        {"Self": {"HostName": "mini", "TailscaleIPs": ["203.0.113.1"]},
         "Peer": {"n": {"HostName": "linuxbackup", "TailscaleIPs": ["203.0.113.3"], "Online": false}}}
        """
        let machines = TailnetDiscovery.parseMachines(from: Data(json.utf8))
        let peer = machines.first { $0.hostName == "linuxbackup" }
        XCTAssertEqual(peer?.isOnline, false)
    }

    /// `Self` carries no `Online` field in real output — absence must not
    /// read as offline.
    func testANodeWithNoOnlineFieldDefaultsToOnline() {
        let json = """
        {"Self": {"HostName": "mini", "TailscaleIPs": ["203.0.113.1"]}, "Peer": {}}
        """
        let machines = TailnetDiscovery.parseMachines(from: Data(json.utf8))
        XCTAssertEqual(machines.first?.isOnline, true)
    }

    // MARK: - Malformed / absent-binary degradation

    func testMalformedJSONProducesNoMachinesRatherThanCrashing() {
        XCTAssertEqual(TailnetDiscovery.parseMachines(from: Data("not json at all".utf8)), [])
    }

    func testEmptyDataProducesNoMachines() {
        XCTAssertEqual(TailnetDiscovery.parseMachines(from: Data()), [])
    }

    func testJSONWithNeitherSelfNorPeerProducesNoMachines() {
        XCTAssertEqual(TailnetDiscovery.parseMachines(from: Data("{}".utf8)), [])
    }

    // MARK: - Bounding what is displayed

    /// The finding this pins: a peer that answers with something outside
    /// `HostDisplay`'s charset gate must not reach the picker unsanitized —
    /// it is dropped, the same way `HostProbe.outcome` replaces (rather than
    /// shows) an unsanitary probed name. Mutation check: return the raw
    /// `HostName` directly instead of routing it through
    /// `HostDisplay.machineLabel` and this goes red.
    func testAHostnameWithMarkdownLinkSyntaxIsDropped() {
        let json = """
        {"Peer": {"n": {"HostName": "[click me](https://evil.example)", "TailscaleIPs": ["203.0.113.9"]}}}
        """
        XCTAssertEqual(TailnetDiscovery.parseMachines(from: Data(json.utf8)), [])
    }

    func testAnOverlongHostnameIsDropped() {
        let tooLong = String(repeating: "a", count: HostDisplay.maximumMachineLength + 1)
        let json = """
        {"Peer": {"n": {"HostName": "\(tooLong)", "TailscaleIPs": ["203.0.113.9"]}}}
        """
        XCTAssertEqual(TailnetDiscovery.parseMachines(from: Data(json.utf8)), [])
    }

    /// An IPv6-only node has nothing to fill the picker's Address with, so
    /// it is dropped rather than shown unusable.
    func testANodeWithOnlyAnIPv6AddressIsDropped() {
        let json = """
        {"Peer": {"n": {"HostName": "ipv6only", "TailscaleIPs": ["fe80::9"]}}}
        """
        XCTAssertEqual(TailnetDiscovery.parseMachines(from: Data(json.utf8)), [])
    }

    /// A node with no `TailscaleIPs` at all degrades the same way as one
    /// with only an IPv6 address — nothing to fill Address with.
    func testANodeWithNoAddressesIsDropped() {
        let json = """
        {"Peer": {"n": {"HostName": "noaddr"}}}
        """
        XCTAssertEqual(TailnetDiscovery.parseMachines(from: Data(json.utf8)), [])
    }

    /// Defence in depth on top of `HostFormValidation`'s own gate at write
    /// time: an address candidate that isn't IPv4-shaped at all (an
    /// injected flag-looking string) never reaches the picker, even when it
    /// contains no colon.
    func testANonIPv4ShapedAddressCandidateIsIgnoredInFavorOfARealOne() {
        let json = """
        {"Peer": {"n": {"HostName": "evil", "TailscaleIPs": ["-oProxyCommand=touch", "203.0.113.9"]}}}
        """
        let machines = TailnetDiscovery.parseMachines(from: Data(json.utf8))
        XCTAssertEqual(machines.first?.address, "203.0.113.9")
    }

    func testANodeWithOnlyANonIPv4ShapedAddressIsDropped() {
        let json = """
        {"Peer": {"n": {"HostName": "evil", "TailscaleIPs": ["-oProxyCommand=touch"]}}}
        """
        XCTAssertEqual(TailnetDiscovery.parseMachines(from: Data(json.utf8)), [])
    }

    func testAnOutOfRangeOctetIsNotIPv4Shaped() {
        let json = """
        {"Peer": {"n": {"HostName": "evil", "TailscaleIPs": ["999.1.1.1", "203.0.113.9"]}}}
        """
        let machines = TailnetDiscovery.parseMachines(from: Data(json.utf8))
        XCTAssertEqual(machines.first?.address, "203.0.113.9")
    }

    // MARK: - The picked values still have to clear the real gates

    /// The picker only ever pre-fills Name/User/Address — this is the
    /// boundary the issue names explicitly: "validate anything reaching
    /// config through the existing `validateHostName` / `validateHostAddress`
    /// gates rather than trusting the JSON." A `Machine` built from a clean
    /// decode must produce a `HostEntry` the normal way.
    func testAPickedMachineValidatesThroughTheExistingGates() throws {
        let machine = TailnetDiscovery.Machine(hostName: "guests-mini", address: "203.0.113.21", isOnline: true)
        let entry = try HostFormValidation.makeEntry(
            name: machine.hostName, user: "guest", address: machine.address,
            crewsRoot: "", existingHosts: [])
        XCTAssertEqual(entry, HostEntry(name: "guests-mini", user: "guest", address: "203.0.113.21"))
    }

    // MARK: - Resolving the CLI's own location

    func testResolvesToTheFirstCandidateThatExists() {
        let path = TailnetDiscovery.resolvedExecutablePath(
            candidates: ["/nonexistent/tailscale", "/opt/homebrew/bin/tailscale"],
            isExecutable: { $0 == "/opt/homebrew/bin/tailscale" })
        XCTAssertEqual(path, "/opt/homebrew/bin/tailscale")
    }

    /// The absent-binary path — every candidate misses, so callers degrade
    /// to manual entry.
    func testResolvesToNilWhenNoCandidateExists() {
        let path = TailnetDiscovery.resolvedExecutablePath(
            candidates: ["/nonexistent/a", "/nonexistent/b"],
            isExecutable: { _ in false })
        XCTAssertNil(path)
    }
}
