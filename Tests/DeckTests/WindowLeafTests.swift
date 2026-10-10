import XCTest
@testable import Deck

/// `WindowLeaf` owns a hand-made tmux window's synthetic row identity and
/// the pure rule for how many leaves a window count produces. PURE — no
/// ssh, no view — see `deck/specs/multiple-sessions-per-project`
/// §"Windows created by hand".
final class WindowLeafTests: XCTestCase {
    // MARK: - numbers(forWindowCount:)

    /// `nil` (unknown) means no leaves — never assume there is a second
    /// window from a count the mini could not corroborate.
    func testUnknownWindowCountProducesNoLeaves() {
        XCTAssertEqual(WindowLeaf.numbers(forWindowCount: nil), [])
    }

    func testZeroWindowsProducesNoLeaves() {
        XCTAssertEqual(WindowLeaf.numbers(forWindowCount: 0), [])
    }

    /// A session's own first window is never drawn as a leaf of itself.
    func testOneWindowProducesNoLeaves() {
        XCTAssertEqual(WindowLeaf.numbers(forWindowCount: 1), [])
    }

    func testTwoWindowsProducesOneLeaf() {
        XCTAssertEqual(WindowLeaf.numbers(forWindowCount: 2), [2])
    }

    func testFiveWindowsProducesFourLeaves() {
        XCTAssertEqual(WindowLeaf.numbers(forWindowCount: 5), [2, 3, 4, 5])
    }

    /// A negative count must never produce a crashing range.
    func testNegativeWindowCountProducesNoLeaves() {
        XCTAssertEqual(WindowLeaf.numbers(forWindowCount: -1), [])
    }

    // MARK: - id / parse round trip

    func testIdAndParseRoundTrip() {
        let id = WindowLeaf.id(session: "ask--research", window: 3)
        XCTAssertEqual(id, "ask--research:3")
        let parsed = WindowLeaf.parse(id)
        XCTAssertEqual(parsed?.session, "ask--research")
        XCTAssertEqual(parsed?.window, 3)
    }

    /// A real tmux session name never contains a colon (the validator
    /// rejects it), so `parse` must not mistake one for a leaf id.
    func testParseRejectsAPlainSessionNameWithNoColon() {
        XCTAssertNil(WindowLeaf.parse("ask"))
    }

    func testParseRejectsAZeroOrNegativeWindowNumber() {
        XCTAssertNil(WindowLeaf.parse("ask:0"))
        XCTAssertNil(WindowLeaf.parse("ask:-1"))
    }

    func testParseRejectsANonNumericWindowSuffix() {
        XCTAssertNil(WindowLeaf.parse("ask:many"))
    }

    func testParseRejectsAnEmptySessionName() {
        XCTAssertNil(WindowLeaf.parse(":3"))
    }

    /// Splits on the LAST colon, so a pathological id carrying more than one
    /// still yields a sane parse rather than mis-splitting on the first.
    func testParseSplitsOnTheLastColon() {
        let parsed = WindowLeaf.parse("weird:name:4")
        XCTAssertEqual(parsed?.session, "weird:name")
        XCTAssertEqual(parsed?.window, 4)
    }

    // MARK: - ref / parse(SessionRef) — phase 6b, "sits under a host"

    /// `ref`/`parse` are the `SessionRef` form: the host carries straight
    /// through unchanged, and only the name half gets split — a window
    /// leaf lives in the same tmux server as the session that owns it.
    func testRefAndParseRoundTripCarryingTheHostThrough() {
        let session = SessionRef(host: "laptop", name: "ask--research")
        let leaf = WindowLeaf.ref(session: session, window: 3)
        XCTAssertEqual(leaf, SessionRef(host: "laptop", name: "ask--research:3"))
        let parsed = WindowLeaf.parse(leaf)
        XCTAssertEqual(parsed?.session, session)
        XCTAssertEqual(parsed?.window, 3)
    }

    /// Two sessions sharing a bare name on different hosts must produce
    /// distinct leaf refs — the same collision the tuple exists to
    /// resolve, one level down.
    func testTwoHostsWithTheSameSessionNameProduceDistinctLeafRefs() {
        let miniLeaf = WindowLeaf.ref(session: SessionRef(host: "mini", name: "vivy"), window: 2)
        let guestLeaf = WindowLeaf.ref(session: SessionRef(host: "guest", name: "vivy"), window: 2)
        XCTAssertNotEqual(miniLeaf, guestLeaf)
    }

    func testParseOfARefWithNoColonInTheNameIsNil() {
        XCTAssertNil(WindowLeaf.parse(SessionRef(host: "mini", name: "ask")))
    }

    /// The local shell's reserved ref, `"local:shell"`, must not parse as a
    /// window leaf of a session named `"local"` — it carries no digit
    /// suffix, so `Int(windowText)` already refuses it, but this pins the
    /// refusal at the `SessionRef` layer directly.
    func testParseRefusesTheLocalShellSentinel() {
        XCTAssertNil(WindowLeaf.parse(SessionRef.localShell))
    }
}
