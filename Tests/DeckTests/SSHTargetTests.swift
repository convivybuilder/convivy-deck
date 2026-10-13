import XCTest
@testable import Deck

final class SSHTargetTests: XCTestCase {
    /// A home with no Deck key, so the argv the assertions name holds on a
    /// machine that has one paired. Every builder call here passes it, so none
    /// reads the real `~/.ssh`.
    private let noDeckKeyHome = "/nonexistent/deck-test-home"

    /// CQ·165: a pane opens its own ssh connection rather than joining the
    /// shared ControlMaster, so a stalled pane terminal can only freeze
    /// itself — never every one-shot verb, Library composer and follower
    /// riding the shared master.
    func testArgumentsCarryNoSharedMasterAndTmuxAttach() throws {
        let args = try sshArguments(
            target: TestHost.target,
            tmuxSession: "steward",
            home: noDeckKeyHome
        )
        XCTAssertEqual(args, [
            "-t",
            "-o", "ControlPath=none",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(TestHost.user)@\(TestHost.address)",
            "tmux", "new-session", "-A", "-D", "-s", "steward",
        ])
    }

    /// Regression for the incident this closes: a pane's argv must never
    /// carry the options that would let it join or recreate the shared
    /// ControlMaster, however the option list above is edited later.
    func testArgumentsNeverJoinTheSharedMaster() throws {
        let args = try sshArguments(target: TestHost.target, tmuxSession: "steward", home: noDeckKeyHome)
        XCTAssertFalse(args.contains { $0.hasPrefix("ControlMaster=") })
        XCTAssertFalse(args.contains { $0.hasPrefix("ControlPersist=") })
        XCTAssertTrue(args.contains("ControlPath=none"))
        XCTAssertTrue(args.contains("-t"))
        XCTAssertTrue(args.contains("ServerAliveInterval=15"))
        XCTAssertTrue(args.contains("ServerAliveCountMax=3"))
    }

    /// Regression: the argv was `attach-session -t`, which fails outright on a
    /// session that is merely stopped. Every rail row but the running ones was
    /// dead. `-A` creates on miss, `-D` detaches another client so two windows
    /// cannot resize each other to the smaller one.
    func testArgumentsAttachOrCreateAndDetachOthers() throws {
        let args = try sshArguments(target: TestHost.target, tmuxSession: "steward", home: noDeckKeyHome)
        XCTAssertEqual(args.suffix(6), ["tmux", "new-session", "-A", "-D", "-s", "steward"])
    }

    func testWorkingDirectoryIsPassedOnlyWhenGiven() throws {
        let withDirectory = try sshArguments(
            target: TestHost.target, tmuxSession: "steward",
            workingDirectory: "\(TestHost.homeRoot)/Convivy/steward", home: noDeckKeyHome)
        XCTAssertEqual(
            withDirectory.suffix(8),
            ["tmux", "new-session", "-A", "-D", "-s", "steward",
             "-c", "\(TestHost.homeRoot)/Convivy/steward"])

        let without = try sshArguments(target: TestHost.target, tmuxSession: "steward", home: noDeckKeyHome)
        XCTAssertFalse(without.contains("-c"))
    }

    func testWorkingDirectoryRejectsShellMetacharacters() {
        for path in ["/tmp; rm -rf ~", "/$(whoami)", "/a b", "/`id`", "/tmp\n", "/tmp|cat"] {
            XCTAssertThrowsError(try validateWorkingDirectory(path)) { error in
                XCTAssertEqual(error as? SSHTargetError, .invalidWorkingDirectory(path))
            }
        }
    }

    /// A relative path would resolve against whatever directory the remote
    /// login lands in, making a rail row depend on the remote shell's profile.
    /// `..` is rejected outright rather than normalised, since normalising it
    /// correctly is the harder job and nothing needs it.
    func testWorkingDirectoryRequiresAnAbsoluteOrHomePath() {
        for path in ["work/vivy", "", "~operator/work", "\(TestHost.homeRoot)/../root"] {
            XCTAssertThrowsError(try validateWorkingDirectory(path))
        }
        for path in ["\(TestHost.homeRoot)/Convivy/deck", "~/work/vivy", "/"] {
            XCTAssertEqual(try validateWorkingDirectory(path), path)
        }
    }

    /// A session name that fails validation must never reach argv, and neither
    /// must a directory — the whole point of both gates is that ssh joins its
    /// trailing arguments and hands them to a remote shell.
    func testInvalidWorkingDirectoryStopsTheWholeCommand() {
        XCTAssertThrowsError(
            try sshArguments(target: TestHost.target, tmuxSession: "steward",
                              workingDirectory: "/tmp; rm -rf ~", home: noDeckKeyHome))
    }

    /// Regression: the argv shipped without `-t`, so ssh ran `tmux
    /// attach-session` with no remote PTY and tmux died with "open terminal
    /// failed: not a terminal". The whole-argv assertion above would catch a
    /// removal too, but this names the failure so the next person to touch
    /// the option list knows the flag is load-bearing.
    func testArgumentsRequestRemotePTY() throws {
        let args = try sshArguments(target: TestHost.target, tmuxSession: "steward", home: noDeckKeyHome)
        XCTAssertTrue(args.contains("-t"))
    }

    func testSessionNameAllowsCrewNamingConventions() throws {
        for name in ["steward", "sous-chef", "co-vivy-2245", "convivy_deck"] {
            XCTAssertEqual(try validateTmuxSessionName(name), name)
        }
    }

    func testSessionNameRejectsShellMetacharacters() {
        for name in ["steward; rm -rf ~", "$(whoami)", "a b", "`id`", "steward\n"] {
            XCTAssertThrowsError(try validateTmuxSessionName(name)) { error in
                XCTAssertEqual(error as? SSHTargetError, .invalidSessionName(name))
            }
        }
    }

    func testSessionNameRejectsEmptyAndOverlong() {
        XCTAssertThrowsError(try validateTmuxSessionName(""))
        XCTAssertThrowsError(try validateTmuxSessionName(String(repeating: "a", count: 65)))
        XCTAssertNoThrow(try validateTmuxSessionName(String(repeating: "a", count: 64)))
    }

    func testDefaultControlPathUsesSSHHashToken() {
        XCTAssertEqual(defaultControlPath(homeDirectory: "\(TestHost.homeRoot)"), "\(TestHost.homeRoot)/.ssh/deck-cm-%C")
    }

    // MARK: - host user/address validation

    /// A host built the ordinary way must keep passing both gates, or a
    /// configured host stops connecting the moment the charset changes.
    func testAnOrdinaryHostPassesBothHostValidators() {
        XCTAssertEqual(try validateHostUser(TestHost.target.user), TestHost.target.user)
        XCTAssertEqual(try validateHostAddress(TestHost.target.host), TestHost.target.host)
    }

    func testHostUserAllowsOrdinaryUsernames() throws {
        for user in ["operator", "ops", "deck-runner", "user_2"] {
            XCTAssertEqual(try validateHostUser(user), user)
        }
    }

    /// A leading `-` is the case that matters: it makes the whole
    /// `user@host` token look like another ssh option rather than a
    /// destination, which is the injection this gate exists to close.
    func testHostUserRejectsALeadingDash() {
        for user in ["-oProxyCommand=touch /tmp/pwned;", "-oProxyCommand=x", "-x"] {
            XCTAssertThrowsError(try validateHostUser(user)) { error in
                XCTAssertEqual(error as? SSHTargetError, .invalidHostUser(user))
            }
        }
    }

    func testHostUserRejectsEmptyWhitespaceAndOverlong() {
        XCTAssertThrowsError(try validateHostUser(""))
        XCTAssertThrowsError(try validateHostUser("two words"))
        XCTAssertThrowsError(try validateHostUser(String(repeating: "a", count: 65)))
        XCTAssertNoThrow(try validateHostUser(String(repeating: "a", count: 64)))
    }

    func testHostAddressAllowsHostnamesIPv4AndIPv6() throws {
        for address in [TestHost.address, "mini.local", "10.0.0.5", "fe80::1"] {
            XCTAssertEqual(try validateHostAddress(address), address)
        }
    }

    func testHostAddressRejectsALeadingDash() {
        for address in ["-oProxyCommand=touch /tmp/pwned;", "-x"] {
            XCTAssertThrowsError(try validateHostAddress(address)) { error in
                XCTAssertEqual(error as? SSHTargetError, .invalidHostAddress(address))
            }
        }
    }

    func testHostAddressRejectsEmptyAndWhitespace() {
        XCTAssertThrowsError(try validateHostAddress(""))
        XCTAssertThrowsError(try validateHostAddress("10.0.0.5 "))
        XCTAssertThrowsError(try validateHostAddress("evil host"))
    }

    /// The gate applies at argv construction, not just at parse time — a
    /// target built by any other means (a future host picker, a test) is
    /// still checked before it can reach ssh.
    func testSshArgumentsRejectsAnInjectionShapedUser() {
        let target = SSHTarget(user: "-oProxyCommand=touch /tmp/pwned;", host: "10.0.0.5")
        XCTAssertThrowsError(try sshArguments(target: target, tmuxSession: "steward", home: noDeckKeyHome))
    }

    func testSshArgumentsRejectsAnInjectionShapedAddress() {
        let target = SSHTarget(user: "operator", host: "-oProxyCommand=touch /tmp/pwned;")
        XCTAssertThrowsError(try sshArguments(target: target, tmuxSession: "steward", home: noDeckKeyHome))
    }

    // MARK: - host name validation

    func testHostNameAllowsCrewNamingConventions() throws {
        for name in ["mini", "laptop", "guest-macbook", "host_2"] {
            XCTAssertEqual(try validateHostName(name), name)
        }
    }

    /// The case `SessionRef.stringForm`'s `|`-join depends on: a host name
    /// containing `|` must never validate, or two distinct `(host, name)`
    /// pairs could collide on the same joined string — see
    /// `SessionRefTests.testAHostContainingThePipeSeparatorFailsValidation`
    /// for the pair this would otherwise produce.
    func testHostNameRejectsThePipeSeparator() {
        XCTAssertThrowsError(try validateHostName("a|b")) { error in
            XCTAssertEqual(error as? SSHTargetError, .invalidHostName("a|b"))
        }
    }

    func testHostNameRejectsShellMetacharacters() {
        for name in ["evil; rm -rf ~", "$(whoami)", "a b", "`id`"] {
            XCTAssertThrowsError(try validateHostName(name))
        }
    }

    func testHostNameRejectsEmptyAndOverlong() {
        XCTAssertThrowsError(try validateHostName(""))
        XCTAssertThrowsError(try validateHostName(String(repeating: "a", count: 65)))
        XCTAssertNoThrow(try validateHostName(String(repeating: "a", count: 64)))
    }
}
