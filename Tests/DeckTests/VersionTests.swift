import XCTest
@testable import Deck

/// `Scripts/make-app.sh` reads `VERSION` straight into
/// `CFBundleShortVersionString`. A missing or malformed value there produces a
/// bundle that builds and then behaves oddly — an updater comparing versions
/// needs something orderable, and Apple rejects some shapes outright. Cheaper
/// to assert here than to find out at release.
final class VersionTests: XCTestCase {
    private var versionFile: URL {
        URL(fileURLWithPath: #filePath)          // Tests/DeckTests/VersionTests.swift
            .deletingLastPathComponent()          // Tests/DeckTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("VERSION")
    }

    func testVersionFileExists() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: versionFile.path),
            "VERSION is missing; Scripts/make-app.sh reads it into CFBundleShortVersionString"
        )
    }

    func testVersionIsSemanticAndSingleLine() throws {
        let raw = try String(contentsOf: versionFile, encoding: .utf8)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertFalse(trimmed.isEmpty, "VERSION is empty")
        XCTAssertFalse(trimmed.contains("\n"), "VERSION must be a single version, not a list")

        // CFBundleShortVersionString wants one to three dot-separated integers.
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertTrue((1...3).contains(parts.count),
                      "\(trimmed) is not one to three dot-separated components")
        for part in parts {
            XCTAssertFalse(part.isEmpty, "\(trimmed) has an empty component")
            XCTAssertTrue(part.allSatisfy(\.isNumber), "\(trimmed) has a non-numeric component")
        }
    }
}
