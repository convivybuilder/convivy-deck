import XCTest
@testable import Deck

/// `ContentView.deriveWindowSessionName` is the pure part of "Move to its
/// own session": the `window-<n>` label convention, and that it is fed to
/// `SiblingSessionName.derive` correctly so a promoted window inherits
/// Phase 1's collision checks, including the scratch-shell truncation one.
/// `SiblingSessionNameTests` already pins `derive` itself; this only pins
/// the call site.
final class WindowLeafPromotionTests: XCTestCase {
    func testDerivesTheWindowNumberLabelConvention() throws {
        let name = try ContentView.deriveWindowSessionName(
            crewId: "ask", window: 2, existingNames: [])
        XCTAssertEqual(name, "ask--window-2")
    }

    /// A promoted window's derived name must collide with an existing
    /// sibling the same way a typed label would — this is what carries
    /// Phase 1's collision checking forward rather than reimplementing it.
    func testCollidesWithAnExistingSessionOfTheSameDerivedName() {
        XCTAssertThrowsError(try ContentView.deriveWindowSessionName(
            crewId: "ask", window: 2, existingNames: ["ask--window-2"]))
    }

    /// The scratch-shell truncation check `SiblingSessionName.derive` runs
    /// must fire here too — a long crew id whose derived name would
    /// truncate to the same scratch shell as an existing session must be
    /// refused, not silently promoted into a collision. `derive`'s own
    /// 64-character session-name budget and the scratch shell's 53-character
    /// one are different limits: the derived name here (60 chars) has to
    /// clear the first and still exceed the second, or this test would pass
    /// for the wrong reason (a plain `invalidName` on a too-long candidate)
    /// rather than the truncation collision it names.
    func testInheritsTheScratchShellCollisionCheck() {
        let longId = String(repeating: "p", count: 50)
        let derived = "\(longId)--window-2"
        XCTAssertLessThanOrEqual(derived.count, 64, "precondition: a valid tmux session name")
        XCTAssertGreaterThan(derived.count, 64 - scratchShellPrefix.count,
                             "precondition: long enough that the scratch shell truncates it")
        // Shares `derived`'s first 53 characters but differs after — a
        // distinct real session name that nonetheless collides with
        // `derived` only once both are truncated to the scratch budget.
        let collider = String(derived.prefix(64 - scratchShellPrefix.count)) + "-different-tail"
        XCTAssertNotEqual(collider, derived, "precondition: a genuinely different name")
        XCTAssertEqual(scratchShellSessionName(for: collider), scratchShellSessionName(for: derived),
                       "precondition: the two names truncate to the same scratch shell")
        XCTAssertThrowsError(try ContentView.deriveWindowSessionName(
            crewId: longId, window: 2, existingNames: [collider]))
    }
}
