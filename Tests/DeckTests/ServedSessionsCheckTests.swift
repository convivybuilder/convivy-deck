import XCTest
@testable import Deck

/// `ServedSessionsCheck.evaluate` — 0003's two served-sessions findings,
/// each exercised through its own injected seam, so the only real resolution
/// here is `localhost` and no test touches the real filesystem.
final class ServedSessionsCheckTests: XCTestCase {
    private func host(_ address: String) -> HostEntry {
        HostEntry(name: "h", user: "operator", address: address)
    }

    // MARK: - configuredHostResolvesHere

    func testAConfiguredHostAddressMatchingALocalIdentityResolvesHere() {
        XCTAssertTrue(ServedSessionsCheck.configuredHostResolvesHere(
            hosts: [host("this-mac.example")], localIdentities: ["this-mac.example", "127.0.0.1"]))
    }

    func testAConfiguredHostAddressMatchingNoLocalIdentityDoesNotResolveHere() {
        XCTAssertFalse(ServedSessionsCheck.configuredHostResolvesHere(
            hosts: [host("elsewhere.example")], localIdentities: ["this-mac.example", "127.0.0.1"]))
    }

    func testTheComparisonIsCaseInsensitive() {
        XCTAssertTrue(ServedSessionsCheck.configuredHostResolvesHere(
            hosts: [host("THIS-MAC.example")], localIdentities: ["this-mac.example"]))
    }

    func testNoConfiguredHostsNeverResolvesHere() {
        XCTAssertFalse(ServedSessionsCheck.configuredHostResolvesHere(
            hosts: [], localIdentities: ["this-mac.example"]))
    }

    func testEmptyLocalIdentitiesNeverResolvesHereRegardlessOfHosts() {
        XCTAssertFalse(ServedSessionsCheck.configuredHostResolvesHere(
            hosts: [host("this-mac.example")], localIdentities: []))
    }

    func testAHostNameThatResolvesToALocalAddressResolvesHere() {
        XCTAssertTrue(ServedSessionsCheck.configuredHostResolvesHere(
            hosts: [host("laptop.tailnet.example")], localIdentities: ["192.0.2.7", "127.0.0.1"],
            resolveAddress: { $0 == "laptop.tailnet.example" ? ["192.0.2.7"] : [] }))
    }

    func testAHostNameThatResolvesElsewhereDoesNotResolveHere() {
        XCTAssertFalse(ServedSessionsCheck.configuredHostResolvesHere(
            hosts: [host("server.tailnet.example")], localIdentities: ["192.0.2.7", "127.0.0.1"],
            resolveAddress: { _ in ["192.0.2.9"] }))
    }

    func testAHostThatDoesNotResolveDoesNotResolveHere() {
        XCTAssertFalse(ServedSessionsCheck.configuredHostResolvesHere(
            hosts: [host("gone.example")], localIdentities: ["192.0.2.7"], resolveAddress: { _ in [] }))
    }

    func testAStringMatchNeverAsksTheResolver() {
        var asked = false
        XCTAssertTrue(ServedSessionsCheck.configuredHostResolvesHere(
            hosts: [host("this-mac.example")], localIdentities: ["this-mac.example"],
            resolveAddress: { _ in asked = true; return [] }))
        XCTAssertFalse(asked)
    }

    // MARK: - evaluate: order and refusal reasons

    func testNeitherCheckHoldingAnswersNil() {
        let reason = ServedSessionsCheck.evaluate(
            hosts: [host("elsewhere.example")],
            localIdentities: { ["this-machine.local"] },
            resolveAddress: { _ in [] },
            builderInstalledHere: { false })
        XCTAssertNil(reason)
    }

    func testAConfiguredHostResolvingHereAnswersThatReasonWithoutCheckingBuilderInstall() {
        var builderInstallChecked = false
        let reason = ServedSessionsCheck.evaluate(
            hosts: [host("this-machine.local")],
            localIdentities: { ["this-machine.local"] },
            resolveAddress: { _ in [] },
            builderInstalledHere: { builderInstallChecked = true; return true })
        XCTAssertEqual(reason, .configuredHostResolvesHere)
        XCTAssertFalse(builderInstallChecked, "evaluate must not run the second check once the first already refused")
    }

    func testABuilderInstallAnswersThatReasonWhenNoConfiguredHostResolvesHere() {
        let reason = ServedSessionsCheck.evaluate(
            hosts: [host("elsewhere.example")],
            localIdentities: { ["this-machine.local"] },
            resolveAddress: { _ in [] },
            builderInstalledHere: { true })
        XCTAssertEqual(reason, .builderInstalledHere)
    }

    // MARK: - BuilderInstallProbe

    func testBuilderInstallProbeChecksEveryMarker() {
        var checked: [String] = []
        _ = BuilderInstallProbe.found(home: "/h", fileExists: { path in checked.append(path); return false })
        XCTAssertEqual(Set(checked), [
            "/var/db/individuator",
            "/etc/individuator/config.json",
            "/Library/LaunchDaemons/com.convivy.individuator.plist",
            "/Library/LaunchDaemons/com.convivy.library.plist",
            "/opt/builder/install.json",
            "/h/Library/LaunchAgents/com.convivy.library.plist",
        ])
    }

    func testBuilderInstallProbeFindsItFromAnyOneMarker() {
        for marker in BuilderInstallProbe.markerPaths(home: "/h") {
            XCTAssertTrue(BuilderInstallProbe.found(home: "/h", fileExists: { $0 == marker }), marker)
        }
    }

    func testASingleAccountInstallIsFoundWithNoPrivilegedHalf() {
        let agent = BuilderInstallProbe.libraryLaunchAgentPlist(home: "/h")
        XCTAssertTrue(BuilderInstallProbe.found(home: "/h", fileExists: { $0 == agent }))
    }

    func testBuilderInstallProbeFindsNothingWhenNoMarkerExists() {
        XCTAssertFalse(BuilderInstallProbe.found(home: "/h", fileExists: { _ in false }))
    }

    // MARK: - MachineIdentity

    /// The real probe always includes the loopback forms, regardless of
    /// what the machine running the test actually reports — a host entry
    /// hand-typed as `127.0.0.1` must always be recognised as this machine.
    func testResolvingLocalhostReachesALoopbackAddress() {
        XCTAssertFalse(MachineIdentity.resolvedAddresses(of: "localhost")
            .isDisjoint(with: ["127.0.0.1", "::1"]))
    }

    func testMachineIdentityCurrentAlwaysIncludesLoopbackForms() {
        let identities = MachineIdentity.current()
        XCTAssertTrue(identities.contains("127.0.0.1"))
        XCTAssertTrue(identities.contains("::1"))
        XCTAssertTrue(identities.contains("localhost"))
    }
}
