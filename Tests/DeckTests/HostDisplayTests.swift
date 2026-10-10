import XCTest
@testable import Deck

/// Phase 6b-2 of `deck/specs/multiple-sessions-per-project` §"Crews on
/// different hosts": the `user@machine` label an operator reads for a host,
/// resolved from a probed `hostname -s` answer, the config host name, and
/// the address, in that order. PURE — no ssh, no view code, the same
/// discipline `HostResolution` follows.
final class HostDisplayTests: XCTestCase {
    private let mini = HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)
    private let laptop = HostEntry(name: "laptop", user: "operator", address: "10.0.0.5")

    // MARK: - machineLabel fallback order

    func testProbedNameWinsWhenPresent() {
        XCTAssertEqual(
            HostDisplay.machineLabel(probed: "mini", configName: "the-mini-host", address: "1.2.3.4"),
            "mini")
    }

    func testConfigNameIsUsedWhenNothingHasBeenProbedYet() {
        XCTAssertEqual(
            HostDisplay.machineLabel(probed: nil, configName: "mini", address: "1.2.3.4"),
            "mini")
    }

    func testAddressIsUsedWhenNeitherProbedNorConfigNameExist() {
        XCTAssertEqual(
            HostDisplay.machineLabel(probed: nil, configName: nil, address: TestHost.address),
            TestHost.address)
    }

    /// The state a freshly-added, still-unreachable host draws in: nothing
    /// has landed at all.
    func testPlaceholderWhenEveryCandidateIsAbsent() {
        XCTAssertEqual(HostDisplay.machineLabel(probed: nil, configName: nil, address: nil),
                       HostDisplay.placeholder)
    }

    // MARK: - the charset gate

    /// A probed answer outside the conservative charset is REPLACED, not
    /// truncated — the same treatment `session-agent-api` gives
    /// `paneVersion`. It falls through to the next candidate rather than
    /// poisoning the whole label.
    func testAProbedAnswerOutsideTheCharsetFallsThroughRatherThanBeingTruncated() {
        XCTAssertEqual(
            HostDisplay.machineLabel(probed: "mini; rm -rf ~", configName: "mini", address: "1.2.3.4"),
            "mini",
            "the malformed probe answer must be replaced, not truncated to a valid-looking prefix")
    }

    func testAnOverlongCandidateIsRejected() {
        let tooLong = String(repeating: "a", count: HostDisplay.maximumMachineLength + 1)
        XCTAssertEqual(
            HostDisplay.machineLabel(probed: tooLong, configName: "mini", address: nil),
            "mini")
    }

    func testEveryCandidateFailingTheGateFallsToThePlaceholder() {
        XCTAssertEqual(
            HostDisplay.machineLabel(probed: "bad;probe", configName: "also;bad", address: "still;bad"),
            HostDisplay.placeholder)
    }

    func testWhitespaceIsTrimmedBeforeTheGate() {
        XCTAssertEqual(
            HostDisplay.machineLabel(probed: "  mini\n", configName: nil, address: nil),
            "mini")
    }

    // MARK: - label(user:probed:configName:address:)

    func testLabelCombinesUserAndTheResolvedMachineName() {
        XCTAssertEqual(
            HostDisplay.label(user: TestHost.user, probed: "mini", configName: nil, address: nil),
            "\(TestHost.user)@mini")
    }

    // MARK: - label(for:hosts:probed:)

    func testLabelForATargetRecoversTheConfigNameViaHostResolution() {
        let target = SSHTarget(user: "operator", host: "10.0.0.5")
        XCTAssertEqual(
            HostDisplay.label(for: target, hosts: [mini, laptop], probed: { _ in nil }),
            "operator@laptop")
    }

    func testLabelForATargetWithNoConfigEntryFallsToTheAddress() {
        let target = TestHost.target
        XCTAssertEqual(
            HostDisplay.label(for: target, hosts: [], probed: { _ in nil }),
            "\(TestHost.user)@\(TestHost.address)")
    }

    func testLabelForATargetPrefersAProbedName() {
        let target = SSHTarget(user: "operator", host: "10.0.0.5")
        XCTAssertEqual(
            HostDisplay.label(for: target, hosts: [laptop], probed: { $0 == target ? "ops-mbp" : nil }),
            "operator@ops-mbp")
    }

    // MARK: - duplicateDisplayNames(among:)

    func testDuplicateDisplayNamesFindsANameSharedByTwoCrews() {
        let crews = [
            Crew(id: "steward", displayName: "steward", host: "mini"),
            Crew(id: "steward-2", displayName: "steward", host: "laptop"),
            Crew(id: "vivy", displayName: "vivy", host: "mini"),
        ]
        XCTAssertEqual(HostDisplay.duplicateDisplayNames(among: crews), ["steward"])
    }

    func testDuplicateDisplayNamesIsEmptyWhenEveryNameIsUnique() {
        let crews = [
            Crew(id: "steward", displayName: "steward", host: "mini"),
            Crew(id: "vivy", displayName: "vivy", host: "laptop"),
        ]
        XCTAssertTrue(HostDisplay.duplicateDisplayNames(among: crews).isEmpty)
    }

    /// The raw-strings overload `SessionsSettingsView` uses — its roster mixes
    /// pinned crews and catalog rows, neither of which is a `Crew`.
    func testDuplicateDisplayNamesAmongRawNamesFindsASharedName() {
        XCTAssertEqual(
            HostDisplay.duplicateDisplayNames(among: ["steward", "steward", "vivy"]),
            ["steward"])
        XCTAssertTrue(HostDisplay.duplicateDisplayNames(among: ["steward", "vivy"]).isEmpty)
    }

    /// issue_01M3TBDZX3XEYT2TWPZK4J9WKW: macstudio's "Steward" and a promoted
    /// macmini "steward" read as the same name to an operator, so they must
    /// fold to the same key even though the raw strings differ in case.
    func testDuplicateDisplayNamesFoldsCase() {
        let crews = [
            Crew(id: "steward-macstudio", displayName: "Steward", host: "macstudio"),
            Crew(id: "steward-macmini", displayName: "steward", host: "macmini"),
        ]
        XCTAssertFalse(HostDisplay.duplicateDisplayNames(among: crews).isEmpty)
        XCTAssertEqual(
            HostDisplay.duplicateDisplayNames(among: ["Steward", "steward"]),
            HostDisplay.duplicateDisplayNames(among: ["steward", "steward"]))
    }

    /// Surrounding whitespace must not hide an otherwise-shared name.
    func testDuplicateDisplayNamesTrimsWhitespace() {
        XCTAssertFalse(HostDisplay.duplicateDisplayNames(among: [" steward ", "steward"]).isEmpty)
    }

    /// Case-folding must not go further than case: "Steward" and "Stewart"
    /// are different names and stay unlabelled.
    func testDuplicateDisplayNamesDoesNotFoldUnrelatedNames() {
        XCTAssertTrue(HostDisplay.duplicateDisplayNames(among: ["Steward", "Stewart"]).isEmpty)
    }

    // MARK: - crewLabel(for:duplicateNames:hosts:defaultHost:probed:)

    /// A name drawn by only one entry on the rail shows nothing, whatever
    /// its own host or how many hosts are configured.
    func testCrewLabelIsNilWhenTheNameIsNotDuplicated() {
        let crew = Crew(id: "vivy", displayName: "Vivy", host: "mini")
        XCTAssertNil(HostDisplay.crewLabel(
            for: crew, duplicateNames: [], hosts: [mini, laptop], defaultHost: "mini", probed: { _ in nil }))
        XCTAssertNil(HostDisplay.crewLabel(
            for: crew, duplicateNames: [], hosts: [], defaultHost: nil, probed: { _ in nil }))
    }

    /// The proof case: "steward" drawn twice on the rail shows each entry's
    /// own host.
    func testCrewLabelResolvesTheCrewsOwnHostWhenTheNameIsDuplicated() {
        let crew = Crew(id: "steward", displayName: "steward", host: "laptop")
        XCTAssertEqual(
            HostDisplay.crewLabel(
                for: crew, duplicateNames: ["steward"], hosts: [mini, laptop], defaultHost: "mini",
                probed: { _ in nil }),
            "operator@laptop")
    }

    /// issue_01M3TBDZX3XEYT2TWPZK4J9WKW: both differently-cased rows draw
    /// their own host label, using the same `duplicateDisplayNames` set even
    /// though neither crew's raw `displayName` equals the other's.
    func testCrewLabelDrawsForBothCrewsWhenNamesDifferOnlyInCase() {
        let macstudio = HostEntry(name: "macstudio", user: "operator", address: "10.0.0.1")
        let macmini = HostEntry(name: "macmini", user: "operator", address: "10.0.0.2")
        let stewardOnMacstudio = Crew(id: "steward-macstudio", displayName: "Steward", host: "macstudio")
        let stewardOnMacmini = Crew(id: "steward-macmini", displayName: "steward", host: "macmini")
        let duplicateNames = HostDisplay.duplicateDisplayNames(among: [stewardOnMacstudio, stewardOnMacmini])

        XCTAssertEqual(
            HostDisplay.crewLabel(
                for: stewardOnMacstudio, duplicateNames: duplicateNames, hosts: [macstudio, macmini],
                defaultHost: "macstudio", probed: { _ in nil }),
            "operator@macstudio")
        XCTAssertEqual(
            HostDisplay.crewLabel(
                for: stewardOnMacmini, duplicateNames: duplicateNames, hosts: [macstudio, macmini],
                defaultHost: "macstudio", probed: { _ in nil }),
            "operator@macmini")
    }

    func testCrewLabelWithNoHostFieldResolvesTheDefault() {
        let crew = Crew(id: "ask", displayName: "ask")
        XCTAssertEqual(
            HostDisplay.crewLabel(
                for: crew, duplicateNames: ["ask"], hosts: [mini, laptop], defaultHost: "mini",
                probed: { _ in nil }),
            "\(TestHost.user)@mini")
    }

    // MARK: - unresolvedHostWarning(for:hosts:defaultHost:probed:)

    func testNoWarningWhenTheCrewHasNoHostField() {
        let crew = Crew(id: "ask", displayName: "Ask")
        XCTAssertNil(HostDisplay.unresolvedHostWarning(
            for: crew, hosts: [mini, laptop], defaultHost: "mini", probed: { _ in nil }))
    }

    func testNoWarningWhenTheCrewsHostMatchesAnEntry() {
        let crew = Crew(id: "vivy", displayName: "Vivy", host: "laptop")
        XCTAssertNil(HostDisplay.unresolvedHostWarning(
            for: crew, hosts: [mini, laptop], defaultHost: "mini", probed: { _ in nil }))
    }

    /// The case the feature exists for: a renamed or deleted host entry.
    /// `HostResolution` has already fallen back to the default silently —
    /// this names both the stale reference and where it actually landed.
    func testWarnsWhenTheCrewsHostNamesNothingInTheTable() {
        let crew = Crew(id: "vivy", displayName: "Vivy", host: "deleted-host")
        let warning = HostDisplay.unresolvedHostWarning(
            for: crew, hosts: [mini, laptop], defaultHost: "laptop", probed: { _ in nil })
        XCTAssertEqual(warning,
                       "\u{201c}deleted-host\u{201d} isn\u{2019}t a configured host \u{2014} using operator@laptop instead.")
    }

    /// Independent of host count — a stale reference is worth flagging even
    /// with only one host left in the table.
    func testWarningFiresEvenWithOnlyOneHostConfigured() {
        let crew = Crew(id: "vivy", displayName: "Vivy", host: "deleted-host")
        XCTAssertNotNil(HostDisplay.unresolvedHostWarning(
            for: crew, hosts: [mini], defaultHost: "mini", probed: { _ in nil }))
    }

    // MARK: - unreachableWarning(for:hosts:defaultHost:isUnreachable:probed:)
    //
    // `issue_01M23WC488NVYT6T5MDZN37ZBR`: the operator, on a plane with their laptop off
    // the tailnet, asked for "a cannot connect, tailnet may be down message."

    /// The message keeps the operator's own hedge: Deck knows the ssh attempt
    /// failed, not why, so it names the likeliest cause without asserting
    /// it as the diagnosis.
    func testMessageNamesTheHostAndKeepsTheTailnetHedge() {
        let crew = Crew(id: "vivy", displayName: "Vivy", host: "laptop")
        let warning = HostDisplay.unreachableWarning(
            for: crew, hosts: [mini, laptop], defaultHost: "mini",
            isUnreachable: { _ in true }, probed: { _ in nil })
        XCTAssertEqual(warning, "Cannot reach operator@laptop. The tailnet may be down.")
    }

    func testNoWarningWhenTheHostIsReachable() {
        let crew = Crew(id: "vivy", displayName: "Vivy", host: "laptop")
        XCTAssertNil(HostDisplay.unreachableWarning(
            for: crew, hosts: [mini, laptop], defaultHost: "mini",
            isUnreachable: { _ in false }, probed: { _ in nil }))
    }

    /// A crew whose `host` names nothing in the table has no `SSHTarget` to
    /// have been polled in the first place — `unresolvedHostWarning` is the
    /// one that fires for that crew, never this one.
    func testNoWarningWhenTheHostDoesNotResolveAtAll() {
        let crew = Crew(id: "vivy", displayName: "Vivy", host: "deleted-host")
        XCTAssertNil(HostDisplay.unreachableWarning(
            for: crew, hosts: [], defaultHost: nil,
            isUnreachable: { _ in true }, probed: { _ in nil }))
    }

    /// Per-host: a crew resolved to a DIFFERENT, still-reachable host draws
    /// no warning even while some other target is unreachable.
    func testNoWarningForACrewOnADifferentReachableHost() {
        let crew = Crew(id: "ask", displayName: "Ask", host: "mini")
        let laptopTarget = SSHTarget(user: "operator", host: "10.0.0.5")
        let warning = HostDisplay.unreachableWarning(
            for: crew, hosts: [mini, laptop], defaultHost: "mini",
            isUnreachable: { $0 == laptopTarget }, probed: { _ in nil })
        XCTAssertNil(warning, "mini is reachable; only laptop's target is flagged unreachable")
    }

    /// Settings shows the host a crew actually runs on: a crew still naming
    /// a removed host shows the default it falls back to, as the rail does.
    func testSettingsHostNameResolvesARemovedHostToTheDefault() {
        let hosts = [HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)]
        var stale = Crew(id: "steward", displayName: "steward")
        stale.host = "old-mini"
        XCTAssertEqual(HostDisplay.settingsHostName(for: stale, hosts: hosts, defaultHost: "mini"), "mini")
        XCTAssertEqual(
            HostDisplay.settingsHostName(for: Crew(id: "s", displayName: "s"), hosts: [], defaultHost: nil),
            "default")
    }
}
