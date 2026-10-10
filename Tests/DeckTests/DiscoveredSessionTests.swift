import XCTest
@testable import Deck

/// `DiscoveredSession.decode` reads `session-agent sessions`' envelope. Every
/// field but `name` degrades independently per
/// `platform/contracts/session-agent-api`'s "round 2" reconciliation: a row
/// with `path`, `windows`, and `attached` all null is a REAL session — an
/// unreadable path, a non-numeric window count, or a row a crafted directory
/// name kept the mini from corroborating — and must render as one, never be
/// dropped or crash the decoder. A TOTAL FUNCTION OF THE BYTES: every case
/// here runs with no tmux session and no ssh round trip.
final class DiscoveredSessionTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - the ordinary case

    func testDecodesAFullyCorroboratedRow() {
        let rows = DiscoveredSession.decode(data("""
        {"sessions": [{"name": "ask", "path": "\(TestHost.homeRoot)/Convivy/ask",
                        "windows": 2, "attached": true}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows, [DiscoveredSession(name: "ask", host: TestHost.target,
                                                path: "\(TestHost.homeRoot)/Convivy/ask",
                                                windows: 2, attached: true)])
    }

    // MARK: - the null-field degrade, point by point

    /// A row reconciliation could not corroborate arrives as name-only —
    /// this is a REAL session and must render as one, not be dropped.
    func testUncorroboratedRowKeepsItsNameWithEverythingElseNull() {
        let rows = DiscoveredSession.decode(data("""
        {"sessions": [{"name": "ghost", "path": null, "windows": null, "attached": null}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows, [DiscoveredSession(name: "ghost", host: TestHost.target, path: nil, windows: nil, attached: nil)])
    }

    /// A field that is simply absent from the object (rather than explicit
    /// JSON `null`) must degrade the same way as an explicit null — the mini
    /// is free to omit a field it cannot vouch for.
    func testAbsentFieldsDegradeTheSameAsExplicitNulls() {
        let rows = DiscoveredSession.decode(data("""
        {"sessions": [{"name": "ghost"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows, [DiscoveredSession(name: "ghost", host: TestHost.target, path: nil, windows: nil, attached: nil)])
    }

    /// "the count tmux reported is not a plain ASCII integer" — a string
    /// where an int is expected must degrade to nil, never crash and never
    /// silently read as `0`.
    func testNonIntegerWindowCountDegradesToNil() {
        let rows = DiscoveredSession.decode(data("""
        {"sessions": [{"name": "ask", "windows": "many"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.first?.windows, nil)
        XCTAssertEqual(rows.count, 1)
    }

    func testMalformedAttachedDegradesToNilRatherThanFalse() {
        let rows = DiscoveredSession.decode(data("""
        {"sessions": [{"name": "ask", "attached": "yes"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.first?.attached, nil)
    }

    func testMalformedPathDegradesToNilRatherThanEmptyString() {
        let rows = DiscoveredSession.decode(data("""
        {"sessions": [{"name": "ask", "path": 12345}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.first?.path, nil)
    }

    // MARK: - a bad row costs only itself

    func testARowWithNoUsableNameIsSkippedNotTheWholeBatch() {
        let rows = DiscoveredSession.decode(data("""
        {"sessions": [{"path": "/no/name/here"}, {"name": "ask"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.map(\.name), ["ask"])
    }

    func testAnEmptyNameIsSkipped() {
        let rows = DiscoveredSession.decode(data("""
        {"sessions": [{"name": ""}, {"name": "ask"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.map(\.name), ["ask"])
    }

    func testANonObjectEntryIsSkippedNotTheWholeBatch() {
        let rows = DiscoveredSession.decode(data("""
        {"sessions": ["not-an-object", {"name": "ask"}]}
        """), host: TestHost.target)
        XCTAssertEqual(rows.map(\.name), ["ask"])
    }

    // MARK: - total function of the bytes: never throws, degrades to []

    func testNotJSONDecodesToEmptyRatherThanCrashing() {
        XCTAssertEqual(DiscoveredSession.decode(data("not json at all"), host: TestHost.target), [])
    }

    func testNotAnObjectDecodesToEmpty() {
        XCTAssertEqual(DiscoveredSession.decode(data("[1, 2, 3]"), host: TestHost.target), [])
    }

    /// "No tmux server / no sessions both read as `{"sessions": []}`, never
    /// an error" — a genuinely empty host is indistinguishable from a
    /// malformed envelope at this layer, and both must produce `[]` rather
    /// than throwing, since the caller (`RailStateModel.refresh`) is what
    /// tells a transport failure (the ssh call throwing) apart from this.
    func testNoSessionsKeyDecodesToEmpty() {
        XCTAssertEqual(DiscoveredSession.decode(data("{}"), host: TestHost.target), [])
    }

    func testEmptySessionsArrayDecodesToEmpty() {
        XCTAssertEqual(DiscoveredSession.decode(data("""
        {"sessions": []}
        """), host: TestHost.target), [])
    }

    func testSessionsNotAnArrayDecodesToEmpty() {
        XCTAssertEqual(DiscoveredSession.decode(data("""
        {"sessions": "nope"}
        """), host: TestHost.target), [])
    }

    // MARK: - host provenance (phase 6b)

    /// "A discovered session already knows its host" —
    /// `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// hosts". `decode` stamps every row with the target the poll actually
    /// dispatched against, never derived from the bytes themselves.
    func testDecodeStampsEveryRowWithTheGivenHost() {
        let laptop = SSHTarget(user: "operator", host: "10.0.0.5")
        let rows = DiscoveredSession.decode(data("""
        {"sessions": [{"name": "vivy"}, {"name": "ask"}]}
        """), host: laptop)
        XCTAssertEqual(rows.map(\.host), [laptop, laptop])
    }

    /// The identity two rows sharing a name on different hosts need to stay
    /// distinct once `RailStateModel.discovered` keys on it.
    func testIDDiffersByHostForTheSameName() {
        let laptop = SSHTarget(user: "operator", host: "10.0.0.5")
        let firstRow = DiscoveredSession(name: "scratch", host: TestHost.target)
        let laptopRow = DiscoveredSession(name: "scratch", host: laptop)
        XCTAssertNotEqual(firstRow.id, laptopRow.id)
    }
}
