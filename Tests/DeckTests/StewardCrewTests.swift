import XCTest
@testable import Deck

/// `StewardCrew` is the first-run steward: "A fresh install ships a
/// steward" (the operator, 2026-08-19, `deck/specs/running-deck-as-someone-else`).
/// This pins the pure trigger condition, the argv it writes CLAUDE.md
/// with, idempotency against an existing steward, and that the generic
/// framing rule holds — no project, host, or person a stranger would not
/// recognise.
final class StewardCrewTests: XCTestCase {
    // MARK: - shouldCreate

    func testCreatesOnTheFirstHostWithNoCrewsYet() {
        XCTAssertTrue(StewardCrew.shouldCreate(hostCount: 1, crews: []))
    }

    /// Still the trigger on a later host: this is not gated on "the very
    /// first host was just added" — a second (or third) host with no crew
    /// yet still needs a steward.
    func testCreatesOnALaterHostToo() {
        XCTAssertTrue(StewardCrew.shouldCreate(hostCount: 2, crews: []))
    }

    /// Not the trigger: a crew already exists — created by hand, or a
    /// steward from an earlier run — so there is nothing this first-run
    /// act needs to do.
    func testDoesNotCreateWhenACrewAlreadyExists() {
        let existing = Crew(id: "ask", displayName: "Ask", workingDirectory: "~/ask")
        XCTAssertFalse(StewardCrew.shouldCreate(hostCount: 1, crews: [existing]))
    }

    /// Not the trigger: no host configured yet, so there is nowhere to put
    /// the steward's directory.
    func testDoesNotCreateWithNoHostConfigured() {
        XCTAssertFalse(StewardCrew.shouldCreate(hostCount: 0, crews: []))
    }

    /// The retry this condition exists to enable: a host is configured, an
    /// earlier create attempt on it failed (leaving no crew behind), and a
    /// later evaluation of the SAME state — the next launch, or the next
    /// host add — still triggers, because nothing here depends on whether
    /// this is the first time the condition has been checked. The old
    /// `hostCountBefore == 0` trigger would have missed this: after the
    /// first host add, `hostCountBefore` is never 0 again, so a failed
    /// create was stranded for good.
    func testRetriesOnALaterEvaluationAfterAFailedCreateLeftNoCrewBehind() {
        XCTAssertTrue(StewardCrew.shouldCreate(hostCount: 1, crews: []))
        // Evaluated again later against the identical state — as a retry
        // would — and it still fires.
        XCTAssertTrue(StewardCrew.shouldCreate(hostCount: 1, crews: []))
    }

    // MARK: - launchHostEntry

    /// The obvious pick when exactly one host is marked default.
    func testLaunchHostEntryPicksTheDefault() {
        let a = HostEntry(name: "a", user: "u", address: "1.2.3.4")
        let b = HostEntry(name: "b", user: "u", address: "5.6.7.8")
        XCTAssertEqual(StewardCrew.launchHostEntry(hosts: [a, b], defaultHost: "b"), b)
    }

    /// The common fresh-install case: one host, never marked default because
    /// `ThemeStore.addHost` deliberately never sets `defaultHost` on its
    /// own. Falling back to the first host is what keeps this case from
    /// resolving to nothing at all.
    func testLaunchHostEntryFallsBackToTheFirstHostWithNoDefaultSet() {
        let onlyHost = HostEntry(name: "studio", user: "u", address: "1.2.3.4")
        XCTAssertEqual(StewardCrew.launchHostEntry(hosts: [onlyHost], defaultHost: nil), onlyHost)
    }

    /// `defaultHost` naming a host no longer in the table degrades to the
    /// first configured host, the same "unknown name falls through" rule
    /// `HostResolution` follows elsewhere, rather than resolving to nothing.
    func testLaunchHostEntryFallsBackWhenDefaultHostNameMatchesNothing() {
        let a = HostEntry(name: "a", user: "u", address: "1.2.3.4")
        let b = HostEntry(name: "b", user: "u", address: "5.6.7.8")
        XCTAssertEqual(StewardCrew.launchHostEntry(hosts: [a, b], defaultHost: "gone"), a)
    }

    func testLaunchHostEntryIsNilWithNoHosts() {
        XCTAssertNil(StewardCrew.launchHostEntry(hosts: [], defaultHost: nil))
    }

    // MARK: - launchTarget — the launch path's own decision, distinct from
    // the host-add path's inline guard in `HostsSettingsView.createStewardIfNeeded`

    /// The failing case the issue was most specific about: a fresh install,
    /// one host, no crews yet (an earlier create threw, or none was ever
    /// attempted) — the launch path must fire, and on the only host there is.
    func testLaunchTargetFiresOnAFreshInstallWithOneHostAndNoCrews() {
        let host = HostEntry(name: "studio", user: "u", address: "1.2.3.4")
        XCTAssertEqual(
            StewardCrew.launchTarget(hosts: [host], defaultHost: nil, crews: [], createInFlight: false),
            host)
    }

    /// A steward already exists — nothing for the launch path to do,
    /// exactly like `shouldCreate` alone.
    func testLaunchTargetIsNilWhenACrewAlreadyExists() {
        let host = HostEntry(name: "studio", user: "u", address: "1.2.3.4")
        let existing = Crew(id: StewardCrew.id, displayName: StewardCrew.displayName, workingDirectory: "~/steward")
        XCTAssertNil(
            StewardCrew.launchTarget(hosts: [host], defaultHost: nil, crews: [existing], createInFlight: false))
    }

    /// No host configured yet — nowhere to create against.
    func testLaunchTargetIsNilWithNoHostsConfigured() {
        XCTAssertNil(StewardCrew.launchTarget(hosts: [], defaultHost: nil, crews: [], createInFlight: false))
    }

    /// The launch path must not fire while a create — from EITHER
    /// evaluation path — is already in flight, even when the trigger
    /// condition itself holds. This is what `ThemeStore.stewardCreateInFlight`
    /// exists to prevent: a launch racing a host-add's own create sending
    /// two `session-agent create-crew` calls at the same directory.
    func testLaunchTargetIsNilWhileACreateIsAlreadyInFlight() {
        let host = HostEntry(name: "studio", user: "u", address: "1.2.3.4")
        XCTAssertNil(
            StewardCrew.launchTarget(hosts: [host], defaultHost: nil, crews: [], createInFlight: true))
    }

    // MARK: - directory

    func testDirectoryFollowsTheCrewsRootShape() {
        XCTAssertEqual(StewardCrew.directory(crewsRoot: "~/Convivy"), "~/Convivy/steward")
    }

    func testDirectoryTakesARootWithATrailingSlash() {
        XCTAssertEqual(StewardCrew.directory(crewsRoot: "~/Convivy/"), "~/Convivy/steward")
    }

    /// A NON-DEFAULT root: any directory other than the default `~/Convivy`.
    func testDirectoryFollowsANonDefaultRoot() {
        XCTAssertEqual(StewardCrew.directory(crewsRoot: "/srv/crews"),
                       "/srv/crews/steward")
    }

    func testARootOfBareSlashIsNotEmptied() {
        XCTAssertEqual(StewardCrew.directory(crewsRoot: "/"), "/steward")
    }

    /// An empty root — nobody has configured one and the host could not be
    /// asked, see `ThemeConfiguration.crewsRoot` — yields no directory rather
    /// than the bare `/steward` a naive join would produce. `/steward` looks
    /// like a real path and is one `validateWorkingDirectory` would accept; an
    /// empty result is what lets that same gate refuse it downstream instead
    /// of silently proposing a path off the disk's root.
    func testAnEmptyRootYieldsNoDirectory() {
        XCTAssertEqual(StewardCrew.directory(crewsRoot: ""), "")
    }

    // MARK: - writeRoleFileArguments

    /// The argv reaches `session-agent write-file` — the contained verb
    /// `#122` moved Deck's document writes onto — with the role file's
    /// absolute path, not a raw `cat >` composition.
    func testWriteRoleFileArgumentsReachesSessionAgentWriteFileWithTheRoleFilePath() throws {
        let argv = try StewardCrew.writeRoleFileArguments(target: TestHost.target, directory: "~/Convivy/steward")
        XCTAssertEqual(argv.suffix(3),
            [SessionAgent.remoteCommand, "write-file", SessionAgent.shellQuotePath("~/Convivy/steward/CLAUDE.md")])
    }

    func testWriteRoleFileArgumentsCarryTheControlMaster() throws {
        let argv = try StewardCrew.writeRoleFileArguments(target: TestHost.target, directory: "~/Convivy/steward")
        XCTAssertTrue(argv.contains("ControlMaster=auto"))
    }

    func testWriteRoleFileArgumentsRejectADirectoryThatEscapes() {
        XCTAssertThrowsError(
            try StewardCrew.writeRoleFileArguments(target: TestHost.target, directory: "../../etc"))
    }

    func testWriteRoleFileArgumentsRejectAnInjectionShapedTargetUser() {
        let evil = SSHTarget(user: "-oProxyCommand=touch /tmp/pwned;", host: TestHost.address)
        XCTAssertThrowsError(
            try StewardCrew.writeRoleFileArguments(target: evil, directory: "~/Convivy/steward"))
    }

    // MARK: - create: idempotency against an existing steward

    /// A steward already on the rail means `create` must return without
    /// touching the network at all — no ssh call attempted, so this never
    /// blocks or fails on a real connection even in a sandboxed test run.
    func testCreateIsANoOpWhenAStewardAlreadyExists() throws {
        let existing = Crew(id: StewardCrew.id, displayName: StewardCrew.displayName,
                             workingDirectory: "~/Convivy/steward")
        let created = try StewardCrew.create(
            target: TestHost.target, directory: "~/Convivy/steward", existingCrews: [existing])
        XCTAssertFalse(created, "an existing steward must not be recreated or overwritten")
    }

    /// A fresh Builder install has already put the steward's charter at the
    /// role-file path, so Deck creates the crew and leaves the file alone.
    func testCreateKeepsARoleFileThatAlreadyExists() throws {
        var steps: [String] = []
        let created = try StewardCrew.create(
            target: TestHost.target, directory: "~/Convivy/steward", existingCrews: [],
            createCrew: { _, _ in steps.append("createCrew") },
            roleFileExists: { _, _ in steps.append("check"); return true },
            writeRoleFile: { _, _ in steps.append("write") })
        XCTAssertTrue(created)
        XCTAssertEqual(steps, ["createCrew", "check"])
    }

    func testCreateWritesTheRoleFileWhenNoneExists() throws {
        var steps: [String] = []
        let created = try StewardCrew.create(
            target: TestHost.target, directory: "~/Convivy/steward", existingCrews: [],
            createCrew: { _, _ in steps.append("createCrew") },
            roleFileExists: { _, _ in steps.append("check"); return false },
            writeRoleFile: { _, _ in steps.append("write") })
        XCTAssertTrue(created)
        XCTAssertEqual(steps, ["createCrew", "check", "write"])
    }

    /// A check that fails for any reason but a missing file throws, so an
    /// unreadable host is never taken as permission to overwrite.
    func testCreateDoesNotWriteWhenTheExistenceCheckFails() {
        var wrote = false
        XCTAssertThrowsError(try StewardCrew.create(
            target: TestHost.target, directory: "~/Convivy/steward", existingCrews: [],
            createCrew: { _, _ in },
            roleFileExists: { _, _ in throw SessionAgent.AgentError.failed("Permission denied") },
            writeRoleFile: { _, _ in wrote = true }))
        XCTAssertFalse(wrote)
    }

    /// The message `session-agent read-file` prints for a missing
    /// file, and one for a refused path.
    func testOnlyANoSuchFileRefusalReadsAsMissing() {
        XCTAssertTrue(StewardCrew.isMissingFileMessage(
            "session-agent: cannot open '/srv/builder/steward/CLAUDE.md': [Errno 2] No such file or directory: 'CLAUDE.md'"))
        XCTAssertFalse(StewardCrew.isMissingFileMessage(
            "session-agent: cannot open '/srv/builder/steward/CLAUDE.md': [Errno 13] Permission denied"))
    }

    /// A genuine failure throws rather than swallowing — "do NOT silently
    /// fall back to creating nothing." A directory that fails validation
    /// never reaches the network; it fails the same way `createCrew`
    /// itself already does for a directory that escapes.
    func testCreateThrowsRatherThanSwallowingAFailure() {
        XCTAssertThrowsError(
            try StewardCrew.create(target: TestHost.target, directory: "../../etc", existingCrews: []))
    }

    // MARK: - The framing is generic

    /// The rule that decides the whole feature: no Convivy project, no
    /// Convivy vocabulary a stranger would not recognise, no host, no
    /// person. `CrewCatalog.known` used to carry Convivy's own org chart
    /// and was emptied for exactly this reason — this pins the framing so
    /// a later edit cannot quietly reintroduce it.
    func testRoleFramingNamesNoConvivySpecifics() {
        let lowered = StewardCrew.roleFraming.lowercased()
        let forbidden = [
            "convivy",
            // the org chart CrewCatalog.known used to carry
            "vivy", "constance", "selector", "hollis", "sous-chef", "sous chef",
            // hardware and network names named elsewhere in the epic
            "mini", "tailnet", "fleetd", "keel",
        ]
        for word in forbidden {
            XCTAssertFalse(lowered.contains(word), "role framing must not mention \u{201c}\(word)\u{201d}")
        }
    }

    /// The people's names the framing must never carry. The tree is
    /// published, and it cannot hold them in any form: a short name's hash
    /// reverses in under a second. So they live outside it, one per line,
    /// in the file `DECK_PRIVATE_NAMES_FILE` names, or else in
    /// `~/.config/convivy/private-names`. Without that file the check is
    /// skipped, and the skip says where it looked. The release scan
    /// (Shipwright's publish-engine) is the gate that does not skip.
    func testRoleFramingNamesNoPrivatePerson() throws {
        let path = ProcessInfo.processInfo.environment["DECK_PRIVATE_NAMES_FILE"]
            ?? NSHomeDirectory() + "/.config/convivy/private-names"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw XCTSkip("no private names file at \(path)")
        }
        let names = Self.privateNames(from: text)
        XCTAssertFalse(names.isEmpty, "the private names file at \(path) lists no name")
        for index in Self.namesMentioned(names, in: StewardCrew.roleFraming) {
            XCTFail("role framing names private person #\(index) of \(path)")
        }
    }

    /// The lowercase names in a private names file: one per line, blank
    /// lines and `#` comments ignored.
    private static func privateNames(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// The indices of `names` that occur anywhere in `text`, ignoring case.
    private static func namesMentioned(_ names: [String], in text: String) -> [Int] {
        let lowered = text.lowercased()
        return names.indices.filter { lowered.contains(names[$0]) }
    }

    /// The private-name check finds a planted name, inside a longer word
    /// too, and reads a file the way the operator writes one. The names here
    /// are synthetic.
    func testPrivateNameCheckFindsAPlantedName() {
        let names = Self.privateNames(from: "# people\nAlex\n\n  Sam  \n")
        XCTAssertEqual(names, ["alex", "sam"])
        XCTAssertEqual(Self.namesMentioned(names, in: "Ask Sam before you start."), [1])
        XCTAssertEqual(Self.namesMentioned(names, in: "alexsmachine is a host"), [0])
        XCTAssertEqual(Self.namesMentioned(names, in: "You work for whoever runs this machine."), [])
    }

    func testRoleFramingIsNonEmpty() {
        XCTAssertFalse(StewardCrew.roleFraming.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
