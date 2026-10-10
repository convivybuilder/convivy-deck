import XCTest

/// The scaffold's only job is to prove the toolchain and CI path work end to end.
/// Real coverage now lives with the components: the reconnect/veil state
/// machine (SSHTargetTests/ReconnectPolicyTests, WS2.1), the SwiftTerm replay
/// fixtures (SwiftTermReplayTests, WS2.2), and the rail catalog
/// (CrewCatalogTests/HexColorTests, WS2.3).
final class ScaffoldTests: XCTestCase {
    func testTheSuiteRuns() {
        XCTAssertTrue(true, "if this fails, the runner or toolchain is broken, not the code")
    }
}
