import XCTest
@testable import Deck

/// `HostProbe.outcome(forProbedName:)` — the pure classification the Test
/// button's landed probe runs through, on the actual path `HostProbe.test`
/// calls rather than a duplicate. See `deck/specs/multiple-sessions-per-project`
/// §"Crews on different hosts".
final class HostProbeTests: XCTestCase {
    func testCleanNameClassifiesAsReachableUnchanged() {
        XCTAssertEqual(HostProbe.outcome(forProbedName: "guests-mini"),
                       .reachable(machineName: "guests-mini"))
    }

    func testEmptyNameClassifiesAsRefused() {
        XCTAssertEqual(HostProbe.outcome(forProbedName: ""),
                       .refused("hostname -s returned nothing"))
    }

    /// The finding this pins: a mini that answers with Markdown link syntax
    /// (or anything else outside the charset gate) must not reach the badge
    /// or detail text unsanitized — it's replaced with `HostDisplay`'s
    /// placeholder, same as any other machine name that fails the gate.
    /// Mutation check: delete the `HostDisplay.machineLabel` call in
    /// `HostProbe.outcome(forProbedName:)` (return `.reachable(machineName: name)`
    /// directly) and this goes red.
    func testMarkdownLinkSyntaxIsReplacedWithPlaceholder() {
        XCTAssertEqual(HostProbe.outcome(forProbedName: "[click me](https://evil.example)"),
                       .reachable(machineName: HostDisplay.placeholder))
    }

    func testOverlongNameIsReplacedWithPlaceholder() {
        let tooLong = String(repeating: "a", count: HostDisplay.maximumMachineLength + 1)
        XCTAssertEqual(HostProbe.outcome(forProbedName: tooLong),
                       .reachable(machineName: HostDisplay.placeholder))
    }
}
