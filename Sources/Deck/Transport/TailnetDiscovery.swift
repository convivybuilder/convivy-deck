import Foundation

/// Discovers candidate hosts from the local Tailscale daemon so
/// `AddHostSheet` can offer a picker instead of a bare Address field — see
/// `issue_01M0ECVNHX6XRT47EJJ8B5Z54T`: "it was not obvious what to do, or
/// how to find the IP address."
///
/// A LOCAL SUBPROCESS ONLY. `tailscale status --json` reports on the
/// machine Deck itself runs on; this never becomes an ssh call, and no
/// Tailscale dependency, API token, or network call is added here.
///
/// Every field below is untrusted input the daemon hands back as JSON —
/// another program's answer, not Deck's own state. A hostname is bounded
/// and charset-gated the same way `HostDisplay.machineLabel` already bounds
/// a probed `hostname -s` answer, and a machine's `hostName`/`address` a
/// person actually PICKS still has to clear `HostFormValidation.makeEntry`'s
/// own gates before it becomes a `HostEntry` — this enum only decides what
/// to show, never what to write.
enum TailnetDiscovery {
    /// One machine on the Tailnet, as `AddHostSheet`'s picker shows it.
    struct Machine: Identifiable, Equatable {
        var id: String { "\(hostName)|\(address)" }
        let hostName: String
        let address: String
        let isOnline: Bool
    }

    enum Outcome: Equatable {
        case machines([Machine])
        /// Covers both "no `tailscale` binary" and "it ran but produced
        /// nothing usable" — `AddHostSheet` treats both identically: fall
        /// back to manual entry.
        case unavailable
    }

    /// Where the Tailscale app's own CLI shim is known to land. There is no
    /// package-manager convention to rely on, so this is checked in order
    /// rather than trusting `$PATH` — a GUI-launched app's PATH is not a
    /// login shell's, so `/usr/local/bin` or `/opt/homebrew/bin` may not be
    /// on it even when the binary is there.
    static let candidateExecutablePaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// The first candidate that actually exists and is executable —
    /// `isExecutable` is injected so a test can simulate "no Tailscale
    /// installed" without touching the real filesystem.
    static func resolvedExecutablePath(
        candidates: [String] = candidateExecutablePaths,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        candidates.first(where: isExecutable)
    }

    /// Runs `tailscale status --json` and returns what it found, off the
    /// main actor. Bounded by the same watchdog-timeout shape
    /// `SSHProcessRunner` uses for the equivalent reason: a hung daemon must
    /// not hang the Add sheet. Absence of the binary, a non-zero exit, a
    /// killed-by-watchdog process, or undecodable output all degrade to
    /// `.unavailable` — manual entry is always the fallback, never a dead
    /// sheet.
    static func fetch(timeout: TimeInterval = 3) async -> Outcome {
        guard let executablePath = resolvedExecutablePath() else { return .unavailable }
        return await Task.detached {
            guard let data = try? run(executablePath: executablePath, timeout: timeout) else {
                return .unavailable
            }
            let machines = parseMachines(from: data)
            return machines.isEmpty ? .unavailable : .machines(machines)
        }.value
    }

    private static func run(executablePath: String, timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["status", "--json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        try process.run()
        // Same shape as `SSHProcessRunner.run`'s watchdog: fires on a
        // background queue regardless of the blocking read below, a no-op
        // once the process has already exited.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0, process.terminationReason != .uncaughtSignal else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }

    // MARK: - Parsing — pure, so a test drives it with a JSON literal
    // rather than the real daemon.

    private struct StatusJSON: Decodable {
        struct Node: Decodable {
            let hostName: String?
            let tailscaleIPs: [String]?
            let online: Bool?

            enum CodingKeys: String, CodingKey {
                case hostName = "HostName"
                case tailscaleIPs = "TailscaleIPs"
                case online = "Online"
            }
        }

        let selfNode: Node?
        let peer: [String: Node]?

        enum CodingKeys: String, CodingKey {
            case selfNode = "Self"
            case peer = "Peer"
        }
    }

    /// `tailscale status --json`'s own shape: `Self` is one node, `Peer` is
    /// a dictionary keyed by node key rather than an array — decoded here
    /// so nothing downstream has to know that. Returns `[]` for anything
    /// that doesn't decode, rather than throwing: malformed output degrades
    /// to manual entry exactly like an absent binary.
    static func parseMachines(from data: Data) -> [Machine] {
        guard let status = try? JSONDecoder().decode(StatusJSON.self, from: data) else { return [] }
        let nodes = [status.selfNode].compactMap { $0 } + Array(status.peer?.values ?? [:].values)
        return nodes.compactMap(machine(from:))
            .sorted { $0.hostName.localizedCaseInsensitiveCompare($1.hostName) == .orderedAscending }
    }

    /// One node's own answer, sanitized. The hostname goes through the same
    /// bounded charset gate `HostDisplay.machineLabel` applies to a probed
    /// `hostname -s` answer — the same shape of input, another program's
    /// string about to be rendered — and a node whose name fails that gate,
    /// or that has no IPv4 address to fill Address with (an IPv6-only
    /// entry, or a decode gap), is dropped rather than shown unusable.
    /// `online` defaults to reachable when the daemon omits the field
    /// (observed for `Self`, which is always the local machine), matching
    /// the issue's requirement that a box being asleep is not a reason to
    /// refuse to configure it — this only ever demotes a peer to "offline",
    /// never promotes one.
    private static func machine(from node: StatusJSON.Node) -> Machine? {
        guard let rawName = node.hostName, !rawName.isEmpty else { return nil }
        let hostName = HostDisplay.machineLabel(probed: rawName, configName: nil, address: nil)
        guard hostName != HostDisplay.placeholder else { return nil }
        guard let ipv4 = (node.tailscaleIPs ?? []).first(where: isIPv4Shaped) else { return nil }
        return Machine(hostName: hostName, address: ipv4, isOnline: node.online ?? true)
    }

    /// A defence-in-depth shape check on top of `HostFormValidation`'s own
    /// gate at write time: four dot-separated groups, each `0...255`. Not a
    /// full RFC parse — it doesn't need to be, since anything that survives
    /// this and still isn't a usable address is caught by
    /// `validateHostAddress` before it can reach `theme.json`. What this
    /// guards is display: a crafted `TailscaleIPs` entry that isn't
    /// address-shaped at all (e.g. an injected `-oProxyCommand=...`) never
    /// makes it into the picker in the first place.
    private static func isIPv4Shaped(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }
}
