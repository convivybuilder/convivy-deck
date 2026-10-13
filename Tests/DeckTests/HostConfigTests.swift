import XCTest
@testable import Deck

/// Phase 6a of the multiple-sessions design (`deck/specs/multiple-sessions-
/// per-project` §"Crews on different boxes"): the `hosts` table, `defaultHost`,
/// and a per-crew `host` field, as config. "Migration costs nothing" is the
/// property under test throughout — an old `theme.json` with none of these
/// keys must decode exactly as it did before any of them existed, which is
/// what makes this phase invisible to an operator with one box.
final class HostConfigTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-hosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - Migration costs nothing

    func testAFileWithNoHostsKeyDecodesToAnEmptyTable() throws {
        let file = try write("{}")
        let config = ThemeConfiguration.load(from: file)
        XCTAssertEqual(config.hosts, [])
    }

    func testAFileWithNoDefaultHostKeyDecodesToNil() throws {
        let file = try write("{}")
        XCTAssertNil(ThemeConfiguration.load(from: file).defaultHost)
    }

    func testACrewRowWithNoHostKeyDecodesToNilHost() throws {
        let file = try write("""
        {"rail": [{"session": "ask"}]}
        """)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertNil(row.host)
    }

    func testACatalogRowWithNoHostKeyDecodesToNilHost() throws {
        let file = try write("""
        {"catalog": [{"session": "nyh"}]}
        """)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).catalog.first)
        XCTAssertNil(row.host)
    }

    /// `CrewCatalog.known` is empty
    /// (`deck/specs/running-deck-as-someone-else` §"The defaults name
    /// Convivy"), so an empty file's rail fallback has no rows to default a
    /// host on at all.
    func testAnEmptyFileHasNoRailAndNoCatalogFallbackRows() throws {
        let file = try write("{}")
        XCTAssertNil(ThemeConfiguration.load(from: file).railSessions)
        XCTAssertTrue(CrewCatalog.known.isEmpty)
    }

    // MARK: - All three present

    func testAllThreeHostFieldsDecodeTogether() throws {
        let file = try write("""
        {
          "hosts": [{"name": "mini", "user": "\(TestHost.user)", "address": "\(TestHost.address)"}],
          "defaultHost": "mini",
          "rail": [{"session": "vivy", "host": "mini"}]
        }
        """)
        let config = ThemeConfiguration.load(from: file)
        XCTAssertEqual(config.hosts, [HostEntry(name: "mini", user: TestHost.user,
                                                address: TestHost.address)])
        XCTAssertEqual(config.defaultHost, "mini")
        XCTAssertEqual(config.railSessions?.first?.host, "mini")
    }

    /// A host row missing any of its three required fields cannot become an
    /// `SSHTarget` at all, so it is dropped — the same per-field degradation
    /// every other key gets — rather than admitted half-built.
    func testAHostRowMissingAFieldIsDropped() throws {
        let file = try write("""
        {"hosts": [{"name": "broken", "user": "operator"}, {"name": "mini", "user": "operator", "address": "1.2.3.4"}]}
        """)
        XCTAssertEqual(ThemeConfiguration.load(from: file).hosts,
                       [HostEntry(name: "mini", user: "operator", address: "1.2.3.4")])
    }

    /// A `user` or `address` shaped like an ssh option (`-oProxyCommand=...`)
    /// would reach the destination token ssh itself parses, the same way an
    /// unvalidated session name or working directory would. Dropped here —
    /// `validateHostUser`/`validateHostAddress` — the same way a row missing
    /// a field already is, so a hand-edited `theme.json` can never smuggle
    /// one into the table at all.
    func testAHostRowWithAnInjectionShapedUserIsDropped() throws {
        let file = try write("""
        {"hosts": [
          {"name": "evil", "user": "-oProxyCommand=touch /tmp/pwned;", "address": "10.0.0.5"},
          {"name": "mini", "user": "operator", "address": "1.2.3.4"}
        ]}
        """)
        XCTAssertEqual(ThemeConfiguration.load(from: file).hosts,
                       [HostEntry(name: "mini", user: "operator", address: "1.2.3.4")])
    }

    func testAHostRowWithAnInjectionShapedAddressIsDropped() throws {
        let file = try write("""
        {"hosts": [
          {"name": "evil", "user": "operator", "address": "-oProxyCommand=touch /tmp/pwned;"},
          {"name": "mini", "user": "operator", "address": "1.2.3.4"}
        ]}
        """)
        XCTAssertEqual(ThemeConfiguration.load(from: file).hosts,
                       [HostEntry(name: "mini", user: "operator", address: "1.2.3.4")])
    }

    /// `SessionRef.stringForm` joins `host` and a session name with `|` on
    /// the assumption a host name can never contain one — this is the gate
    /// that makes the assumption true. Dropped the same way an injection-
    /// shaped `user`/`address` already is.
    func testAHostRowWithAPipeInItsNameIsDropped() throws {
        let file = try write("""
        {"hosts": [
          {"name": "a|b", "user": "operator", "address": "10.0.0.5"},
          {"name": "mini", "user": "operator", "address": "1.2.3.4"}
        ]}
        """)
        XCTAssertEqual(ThemeConfiguration.load(from: file).hosts,
                       [HostEntry(name: "mini", user: "operator", address: "1.2.3.4")])
    }

    /// A crew's `host` field references a name by the same charset a
    /// `hosts` entry's own `name` is validated to — a bad one costs the row
    /// its host designation (falls back to the default), not its place on
    /// the rail, the same "field costs itself" pattern a bad `workdir` or
    /// `command` already gets.
    func testACrewRowWithAPipeInItsHostFieldKeepsTheRowButDropsTheHost() throws {
        let file = try write("""
        {"rail": [{"session": "vivy", "host": "a|b"}]}
        """)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).railSessions?.first)
        XCTAssertEqual(row.id, "vivy")
        XCTAssertNil(row.host)
    }

    func testACatalogRowWithAPipeInItsHostFieldKeepsTheRowButDropsTheHost() throws {
        let file = try write("""
        {"catalog": [{"session": "nyh", "host": "a|b"}]}
        """)
        let row = try XCTUnwrap(ThemeConfiguration.load(from: file).catalog.first)
        XCTAssertEqual(row.id, "nyh")
        XCTAssertNil(row.host)
    }

    /// `HostResolution` resolves both directions ("OTHER SESSIONS" rows
    /// reverse-lookup a name from a target; Stop forward-looks-up a target
    /// from that name) by first match. Two entries sharing a name but
    /// differing in `(user, address)` would make those two lookups
    /// disagree — a session discovered on the SECOND entry's box round-
    /// tripping to the FIRST entry's target, sending a Stop to the wrong
    /// host. Dropping the later colliding row, the first-occurrence-wins
    /// rule `droppingScratchShellCollisions` already uses, keeps the two
    /// directions in agreement by construction.
    func testAHostRowWithADuplicateNameIsDropped() throws {
        let file = try write("""
        {"hosts": [
          {"name": "h", "user": "alice", "address": "1.1.1.1"},
          {"name": "h", "user": "bob", "address": "2.2.2.2"}
        ]}
        """)
        XCTAssertEqual(ThemeConfiguration.load(from: file).hosts,
                       [HostEntry(name: "h", user: "alice", address: "1.1.1.1")])
    }

    /// The round trip the duplicate-name check protects: once parsing keeps
    /// only one entry per name, the reverse lookup an "OTHER SESSIONS" row
    /// uses and the forward lookup a Stop button uses always agree.
    func testDuplicateNameDedupKeepsForwardAndReverseLookupsInAgreement() throws {
        let file = try write("""
        {"hosts": [
          {"name": "h", "user": "alice", "address": "1.1.1.1"},
          {"name": "h", "user": "bob", "address": "2.2.2.2"}
        ]}
        """)
        let hosts = ThemeConfiguration.load(from: file).hosts
        let kept = try XCTUnwrap(hosts.first)
        let keptTarget = SSHTarget(user: kept.user, host: kept.address)

        XCTAssertEqual(HostResolution.hostName(for: keptTarget, hosts: hosts), "h")
        XCTAssertEqual(HostResolution.target(forHostName: "h", hosts: hosts, defaultHost: nil), keptTarget)
    }

    // MARK: - HostEntry.crewsRoot (phase 6b-2)

    func testAHostEntryWithNoCrewsRootKeyDecodesToNil() throws {
        let file = try write("""
        {"hosts": [{"name": "mini", "user": "operator", "address": "1.2.3.4"}]}
        """)
        XCTAssertNil(ThemeConfiguration.load(from: file).hosts.first?.crewsRoot)
    }

    func testAHostEntrysOwnCrewsRootDecodes() throws {
        let file = try write("""
        {"hosts": [{"name": "guest", "user": "guest", "address": "1.2.3.4", "crewsRoot": "~/work"}]}
        """)
        XCTAssertEqual(ThemeConfiguration.load(from: file).hosts.first?.crewsRoot, "~/work")
    }

    /// A bad `crewsRoot` costs the host entry its own root and falls back to
    /// the global one — the same "field costs itself" pattern a bad
    /// `workdir`/`command`/`host` already gets — never the whole entry.
    func testAHostEntryWithAnInvalidCrewsRootKeepsTheEntryButDropsTheRoot() throws {
        let file = try write("""
        {"hosts": [{"name": "guest", "user": "guest", "address": "1.2.3.4", "crewsRoot": "relative/no-leading-slash"}]}
        """)
        let entry = try XCTUnwrap(ThemeConfiguration.load(from: file).hosts.first)
        XCTAssertEqual(entry.name, "guest")
        XCTAssertNil(entry.crewsRoot)
    }

    func testAHostEntrysCrewsRootSurvivesSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.hosts = [HostEntry(name: "guest", user: "guest", address: "1.2.3.4",
                                  crewsRoot: "\(TestHost.secondaryHomeRoot)/work")]
        try config.save(to: file)

        XCTAssertEqual(ThemeConfiguration.load(from: file).hosts.first?.crewsRoot, "\(TestHost.secondaryHomeRoot)/work")
    }

    /// An entry with no root of its own must not grow the key on save — the
    /// same reasoning `testAnUntouchedRowWritesNoHostKey` applies to a
    /// crew's `host` field.
    func testAHostEntryWithNoCrewsRootWritesNoCrewsRootKey() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.hosts = [HostEntry(name: "mini", user: "operator", address: "1.2.3.4")]
        try config.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hosts = try XCTUnwrap(root["hosts"] as? [[String: Any]])
        XCTAssertNil(hosts.first?["crewsRoot"])
    }

    // MARK: - HostEntry.runbookLink (CQ·124)

    func testAHostEntryWithNoRunbookLinkKeyDecodesToNil() throws {
        let file = try write("""
        {"hosts": [{"name": "mini", "user": "operator", "address": "1.2.3.4"}]}
        """)
        XCTAssertNil(ThemeConfiguration.load(from: file).hosts.first?.runbookLink)
    }

    func testAHostEntrysOwnHttpsRunbookLinkDecodes() throws {
        let file = try write("""
        {"hosts": [{"name": "guest", "user": "guest", "address": "1.2.3.4", \
        "runbookLink": "https://example.com/runbook"}]}
        """)
        XCTAssertEqual(ThemeConfiguration.load(from: file).hosts.first?.runbookLink,
                       "https://example.com/runbook")
    }

    func testAHostEntrysOwnKBIdRunbookLinkDecodes() throws {
        let file = try write("""
        {"hosts": [{"name": "guest", "user": "guest", "address": "1.2.3.4", \
        "runbookLink": "shipwright/runbooks/log-back-in"}]}
        """)
        XCTAssertEqual(ThemeConfiguration.load(from: file).hosts.first?.runbookLink,
                       "shipwright/runbooks/log-back-in")
    }

    /// A bad `runbookLink` costs the host entry only its own runbook, the
    /// same "field costs itself" pattern `crewsRoot` already gets above.
    func testAHostEntryWithAnInvalidRunbookLinkKeepsTheEntryButDropsTheLink() throws {
        let file = try write("""
        {"hosts": [{"name": "guest", "user": "guest", "address": "1.2.3.4", \
        "runbookLink": "javascript:alert(1)"}]}
        """)
        let entry = try XCTUnwrap(ThemeConfiguration.load(from: file).hosts.first)
        XCTAssertEqual(entry.name, "guest")
        XCTAssertNil(entry.runbookLink)
    }

    func testAHostEntrysRunbookLinkSurvivesSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.hosts = [HostEntry(name: "guest", user: "guest", address: "1.2.3.4",
                                  runbookLink: "https://example.com/runbook")]
        try config.save(to: file)

        XCTAssertEqual(ThemeConfiguration.load(from: file).hosts.first?.runbookLink,
                       "https://example.com/runbook")
    }

    func testAHostEntryWithNoRunbookLinkWritesNoRunbookLinkKey() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.hosts = [HostEntry(name: "mini", user: "operator", address: "1.2.3.4")]
        try config.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hosts = try XCTUnwrap(root["hosts"] as? [[String: Any]])
        XCTAssertNil(hosts.first?["runbookLink"])
    }

    // MARK: - Round trip

    func testHostsDefaultHostAndPerCrewHostSurviveSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.hosts = [
            HostEntry(name: "mini", user: TestHost.user, address: TestHost.address),
            HostEntry(name: "laptop", user: "operator", address: "10.0.0.5"),
        ]
        config.defaultHost = "mini"
        config.railSessions = [Crew(id: "vivy", displayName: "Vivy", host: "laptop")]
        try config.save(to: file)

        let reloaded = ThemeConfiguration.load(from: file)
        XCTAssertEqual(reloaded.hosts, config.hosts)
        XCTAssertEqual(reloaded.defaultHost, "mini")
        XCTAssertEqual(reloaded.railSessions?.first?.host, "laptop")
    }

    /// A row with no host must not grow the key on save — the same
    /// reasoning `railArray` already applies to an unset command or workdir:
    /// a row nobody touched should not accumulate keys nobody wrote.
    func testAnUntouchedRowWritesNoHostKey() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.railSessions = [Crew(id: "deck", displayName: "Deck")]
        try config.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rail = try XCTUnwrap(root["rail"] as? [[String: Any]])
        XCTAssertNil(rail.first?["host"])
    }

    /// An empty `hosts` table — today's only real case, since nothing
    /// writes it yet — must not freeze an empty array into a file that had
    /// no `hosts` key at all, the same reasoning `railArray` follows for an
    /// unconfigured rail.
    func testAnEmptyHostsTableWritesNoHostsKey() throws {
        let file = try write("{}")
        try ThemeConfiguration.empty.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(root["hosts"])
        XCTAssertNil(root["defaultHost"])
    }

    // MARK: - HostEntry.maxSessionsPerControlMaster (CQ·164)

    func testAHostEntryWithNoMaxSessionsKeyDecodesToNil() throws {
        let file = try write("""
        {"hosts": [{"name": "mini", "user": "operator", "address": "1.2.3.4"}]}
        """)
        XCTAssertNil(ThemeConfiguration.load(from: file).hosts.first?.maxSessionsPerControlMaster)
    }

    func testAHostEntrysOwnMaxSessionsDecodes() throws {
        let file = try write("""
        {"hosts": [{"name": "raised", "user": "guest", "address": "1.2.3.4", \
        "maxSessionsPerControlMaster": 20}]}
        """)
        XCTAssertEqual(ThemeConfiguration.load(from: file).hosts.first?.maxSessionsPerControlMaster, 20)
    }

    /// A zero or negative override is rejected rather than accepted as "no
    /// sessions" — the same "field costs itself" pattern `crewsRoot`'s own
    /// tests pin, not the whole entry.
    func testAHostEntryWithAZeroOrNegativeMaxSessionsKeepsTheEntryButDropsTheOverride() throws {
        let file = try write("""
        {"hosts": [{"name": "guest", "user": "guest", "address": "1.2.3.4", \
        "maxSessionsPerControlMaster": 0}]}
        """)
        let entry = try XCTUnwrap(ThemeConfiguration.load(from: file).hosts.first)
        XCTAssertEqual(entry.name, "guest")
        XCTAssertNil(entry.maxSessionsPerControlMaster)
    }

    func testAHostEntrysMaxSessionsSurvivesSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.hosts = [HostEntry(name: "guest", user: "guest", address: "1.2.3.4",
                                  maxSessionsPerControlMaster: 16)]
        try config.save(to: file)

        XCTAssertEqual(ThemeConfiguration.load(from: file).hosts.first?.maxSessionsPerControlMaster, 16)
    }

    func testAHostEntryWithNoMaxSessionsWritesNoMaxSessionsKey() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.empty
        config.hosts = [HostEntry(name: "mini", user: "operator", address: "1.2.3.4")]
        try config.save(to: file)

        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hosts = try XCTUnwrap(root["hosts"] as? [[String: Any]])
        XCTAssertNil(hosts.first?["maxSessionsPerControlMaster"])
    }
}
