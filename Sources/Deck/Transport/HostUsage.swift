import Foundation

/// How many rail and catalog rows name a given host — the count the Hosts
/// tab's remove confirm shows, mirroring `ContentView.removeCrewMessage`'s
/// "how many crews will fall back" one level up (crews naming a host,
/// rather than sessions running). PURE, so the count is pinned by a test
/// rather than only read off the alert.
enum HostUsage {
    static func crewsNaming(_ hostName: String, rail: [Crew], catalog: [LaunchableSession]) -> Int {
        rail.filter { $0.host == hostName }.count + catalog.filter { $0.host == hostName }.count
    }
}
