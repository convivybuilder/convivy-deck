import XCTest
@testable import Deck

/// `SiblingSessionName` is the part of "move a window to its own session"
/// (`ContentView.moveWindowToOwnSession`) that can be silently wrong — a bad
/// derivation would look fine in the UI and fail (or worse, collide) only on
/// the mini. Pure, so every case here runs with no tmux session and no ssh
/// round trip.
final class SiblingSessionNameTests: XCTestCase {

    // MARK: - slugify

    func testSlugifyLowercasesAndKeepsAlphanumerics() {
        XCTAssertEqual(SiblingSessionName.slugify("research"), "research")
        XCTAssertEqual(SiblingSessionName.slugify("Research"), "research")
    }

    func testSlugifyCollapsesSeparatorsToASingleDash() {
        XCTAssertEqual(SiblingSessionName.slugify("Tax 2025"), "tax-2025")
        XCTAssertEqual(SiblingSessionName.slugify("tax   2025"), "tax-2025")
        XCTAssertEqual(SiblingSessionName.slugify("tax---2025"), "tax-2025")
        XCTAssertEqual(SiblingSessionName.slugify("tax—2025!!"), "tax-2025")
    }

    func testSlugifyDropsLeadingAndTrailingSeparatorsRatherThanDashing() {
        XCTAssertEqual(SiblingSessionName.slugify("  research  "), "research")
        XCTAssertEqual(SiblingSessionName.slugify("!!!research!!!"), "research")
    }

    func testSlugifyOfAllPunctuationIsEmpty() {
        XCTAssertEqual(SiblingSessionName.slugify("!!! ??? ---"), "")
        XCTAssertEqual(SiblingSessionName.slugify(""), "")
    }

    // MARK: - derive

    func testDerivesTheDoubleDashName() throws {
        let name = try SiblingSessionName.derive(
            crewId: "ask", label: "research", existingNames: [])
        XCTAssertEqual(name, "ask--research")
    }

    func testDerivesFromAMessyLabel() throws {
        let name = try SiblingSessionName.derive(
            crewId: "ask", label: "Tax 2025!", existingNames: [])
        XCTAssertEqual(name, "ask--tax-2025")
    }

    /// The whole reason for `--`: a crew id that already contains a single
    /// dash (`sous-chef`) must not be confused with a sibling boundary.
    func testDoubleDashSurvivesAHyphenatedCrewId() throws {
        let name = try SiblingSessionName.derive(
            crewId: "sous-chef", label: "prep", existingNames: [])
        XCTAssertEqual(name, "sous-chef--prep")
    }

    func testEmptyLabelIsRejected() {
        XCTAssertThrowsError(try SiblingSessionName.derive(
            crewId: "ask", label: "   ", existingNames: [])) { error in
            XCTAssertEqual(error as? SiblingSessionName.DerivationError, .emptyLabel)
        }
    }

    func testPurePunctuationLabelIsRejected() {
        XCTAssertThrowsError(try SiblingSessionName.derive(
            crewId: "ask", label: "!!!", existingNames: [])) { error in
            XCTAssertEqual(error as? SiblingSessionName.DerivationError, .emptyLabel)
        }
    }

    func testCollidingNameIsRejected() {
        XCTAssertThrowsError(try SiblingSessionName.derive(
            crewId: "ask", label: "research", existingNames: ["ask--research"])) { error in
            XCTAssertEqual(error as? SiblingSessionName.DerivationError,
                           .collision("ask--research"))
        }
    }

    /// A derived name over the 64-character budget `validateTmuxSessionName`
    /// enforces is refused rather than silently truncated — truncating here
    /// would let two different long labels collapse onto the same session.
    func testOverlongDerivedNameIsRejected() {
        let longLabel = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try SiblingSessionName.derive(
            crewId: "ask", label: longLabel, existingNames: [])) { error in
            guard case .invalidName = error as? SiblingSessionName.DerivationError else {
                return XCTFail("expected .invalidName, got \(error)")
            }
        }
    }

    /// The derived name is exactly what a real spawn will pass to
    /// `SessionAgent.start` and `validateTmuxSessionName`, so this is the
    /// seam that would catch a slug producing a character the validator
    /// rejects — nothing in `slugify`'s alphabet does, but the contract is
    /// worth pinning directly rather than only by construction.
    func testEveryDerivedNameValidatesAsATmuxSessionName() throws {
        for label in ["research", "Tax 2025", "a b c", "sous-chef helper"] {
            let name = try SiblingSessionName.derive(
                crewId: "ask", label: label, existingNames: [])
            XCTAssertNoThrow(try validateTmuxSessionName(name))
        }
    }

    /// The collision `existingNames.contains(name)` alone cannot see: two
    /// distinct, individually-valid 64-character names that agree on their
    /// first 53 characters produce the same `scratchShellSessionName`, which
    /// would let the second one's scratch shell attach to (and `-D` detach)
    /// the first's.
    func testRejectsANameThatWouldCollideOnlyAfterScratchShellTruncation() throws {
        let crewId = String(repeating: "a", count: 51)
        let first = try SiblingSessionName.derive(
            crewId: crewId, label: "sessionone1", existingNames: [])
        XCTAssertEqual(first.count, 64)

        XCTAssertThrowsError(try SiblingSessionName.derive(
            crewId: crewId, label: "sessiontwo1", existingNames: [first])) { error in
            guard case .collision = error as? SiblingSessionName.DerivationError else {
                return XCTFail("expected .collision, got \(error)")
            }
        }
    }
}
