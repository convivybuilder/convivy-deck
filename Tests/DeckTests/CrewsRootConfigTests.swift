import XCTest
@testable import Deck

/// `ThemeConfiguration.crewsRoot` — the global fallback root the steward's
/// directory is derived from when its host has none of its own. No compiled-in
/// default — see `deck/specs/running-deck-as-someone-else` — so an unconfigured
/// install reads empty; round-trips through `save`/`load` like every other
/// preference. Nothing in Deck's UI writes it: it is read from `theme.json`.
final class CrewsRootConfigTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-crewsroot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("theme.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// No compiled-in default any more: an unconfigured install has no root
    /// until the operator sets one or a host reports its own. See
    /// `deck/specs/running-deck-as-someone-else`.
    func testAbsentRootReadsEmpty() throws {
        let file = try write("{}")
        XCTAssertEqual(ThemeConfiguration.load(from: file).crewsRoot, "")
    }

    func testReadsAConfiguredRoot() throws {
        let file = try write(#"{"crewsRoot": "\#(TestHost.secondaryHomeRoot)/work"}"#)
        XCTAssertEqual(ThemeConfiguration.load(from: file).crewsRoot, "\(TestHost.secondaryHomeRoot)/work")
    }

    /// An empty string in the file reads the same as the key being absent —
    /// both are "nothing configured" — rather than round-tripping a literal
    /// empty string through a different path.
    func testAnEmptyConfiguredRootReadsEmpty() throws {
        let file = try write(#"{"crewsRoot": ""}"#)
        XCTAssertEqual(ThemeConfiguration.load(from: file).crewsRoot, "")
    }

    func testRoundTripsThroughSaveAndLoad() throws {
        let file = try write("{}")
        var config = ThemeConfiguration.load(from: file)
        config.crewsRoot = "~/Convivy"
        try config.save(to: file)

        XCTAssertEqual(ThemeConfiguration.load(from: file).crewsRoot, "~/Convivy")
    }
}
