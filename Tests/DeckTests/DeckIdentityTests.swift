import XCTest
@testable import Deck

/// The Deck key every Deck ssh argv offers when it exists, and the one helper
/// that adds it. Each test points `home:` at a temporary directory, so the real
/// `~/.ssh` is never read.
final class DeckIdentityTests: XCTestCase {
    private var home: String!
    private var keyPath: String { DeckIdentity.path(home: home) }
    private let target = TestHost.target

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-identity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".ssh", isDirectory: true),
            withIntermediateDirectories: true)
        home = directory.path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func createKey() throws {
        try Data("key".utf8).write(to: URL(fileURLWithPath: keyPath))
    }

    func testPathIsTheDeckKeyUnderTheInjectedHome() {
        XCTAssertEqual(DeckIdentity.path(home: "/fake/account"), "/fake/account/.ssh/id_ed25519_deck")
    }

    func testArgvIsUnchangedWhenTheDeckKeyIsAbsent() {
        let argv = ["-o", "ControlMaster=auto", "\(TestHost.user)@\(TestHost.address)"]
        XCTAssertEqual(withDeckIdentity(argv, home: home), argv)
    }

    /// Mutation: prepend unconditionally, and a host with no Deck key gets an
    /// identity file that does not exist. The same call flips with the file:
    /// present adds `-i`, removed drops it again.
    func testArgvGetsTheDeckKeyInFrontOnlyWhileTheKeyExists() throws {
        let argv = ["-o", "x", "host"]
        try createKey()
        XCTAssertEqual(withDeckIdentity(argv, home: home), ["-i", keyPath] + argv)
        try FileManager.default.removeItem(atPath: keyPath)
        XCTAssertEqual(withDeckIdentity(argv, home: home), argv)
    }

    /// Mutation: add `IdentitiesOnly yes`, and the hosts that work through the
    /// user's ssh config lose the identities they depend on.
    func testSSHArgumentsOfferTheDeckKeyWithoutRestrictingOtherIdentities() throws {
        try createKey()
        let argv = try sshArguments(target: target, tmuxSession: "steward", home: home)
        XCTAssertEqual(Array(argv.prefix(2)), ["-i", keyPath])
        XCTAssertFalse(argv.contains { $0.contains("IdentitiesOnly") })
    }

    func testSSHArgumentsCarryNoIdentityWithoutTheDeckKey() throws {
        let argv = try sshArguments(target: target, tmuxSession: "steward", home: home)
        XCTAssertFalse(argv.contains("-i"))
    }

    /// Every Deck ssh argv builder returns through the helper. A builder that
    /// skipped it would fail the presence check here, so it cannot be missed
    /// silently. `ssh-keyscan` is not ssh and takes no identity, so it is not
    /// in this list.
    private var builders: [(name: String, argv: (String) throws -> [String])] {
        let controlPath = "/tmp/deck-cm-%C"
        return [
            ("sshArguments", { try sshArguments(target: self.target, tmuxSession: "steward", home: $0) }),
            ("sshControlSocketCheckArguments", {
                try sshControlSocketCheckArguments(target: self.target, controlPath: controlPath, home: $0)
            }),
            ("sshResolvedConfigArguments", {
                try sshResolvedConfigArguments(target: self.target, controlPath: controlPath, home: $0)
            }),
            ("sshCancelForwardArguments", {
                try sshCancelForwardArguments(target: self.target, remoteSocketPath: "/tmp/run.sock",
                                              localPort: 54321, controlPath: controlPath, home: $0)
            }),
            ("keelForwardArguments", {
                try keelForwardArguments(target: self.target, remoteSocketPath: "/tmp/run.sock",
                                         localPort: 54321, controlPath: controlPath, home: $0)
            }),
            ("HostPairing.installArguments", { try HostPairing.installArguments(target: self.target, home: $0) }),
            ("AgentctlModels.arguments", { try AgentctlModels.arguments(target: self.target, home: $0) }),
            ("HostProbe.arguments", { try HostProbe.arguments(target: self.target, home: $0) }),
            ("DesktopSessionProbe.arguments", { try DesktopSessionProbe.arguments(target: self.target, home: $0) }),
            ("RunRegister.arguments", { try RunRegister.arguments(target: self.target, home: $0) }),
            ("SessionAgent.arguments", {
                try SessionAgent.arguments(target: self.target, session: "steward", verb: ["state"], home: $0)
            }),
            ("SessionAgent.statesArguments", {
                try SessionAgent.statesArguments(target: self.target, sessions: ["steward"], home: $0)
            }),
            ("SessionAgent.crewsRootArguments", { try SessionAgent.crewsRootArguments(target: self.target, home: $0) }),
            ("SessionAgent.renderFileArguments", {
                SessionAgent.renderFileArguments(target: self.target, path: "/tmp/a.md",
                                                 appearance: .dark, home: $0)
            }),
            ("KnowledgeBase.checkoutArguments", {
                KnowledgeBase.checkoutArguments(target: self.target, id: "deck-spec", home: $0)
            }),
            ("WorkingCopyStore.readFileArguments", {
                WorkingCopyStore.readFileArguments(target: self.target, path: "/tmp/a.md", home: $0)
            }),
            ("TmuxWindowControl.selectWindowArguments", {
                try TmuxWindowControl.selectWindowArguments(target: self.target, session: "steward",
                                                            window: 2, home: $0)
            }),
        ]
    }

    func testEveryBuilderOffersTheDeckKeyWhenItExists() throws {
        try createKey()
        for builder in builders {
            let argv = try builder.argv(home)
            XCTAssertEqual(Array(argv.prefix(2)), ["-i", keyPath], builder.name)
        }
    }

    func testEveryBuilderOmitsTheIdentityWhenTheKeyIsAbsent() throws {
        for builder in builders {
            let argv = try builder.argv(home)
            XCTAssertFalse(argv.contains("-i"), builder.name)
        }
    }
}
