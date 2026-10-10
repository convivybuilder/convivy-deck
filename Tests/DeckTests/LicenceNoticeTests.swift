import XCTest
@testable import Deck

/// `LicenceNotice` reads the two files `Scripts/make-app.sh` ships in a bundle's
/// `Contents/Resources`. Every test drives it through a directory it builds,
/// because the bundle `swift test` runs in has neither file, and that is the one
/// case a test host can never show by accident.
final class LicenceNoticeTests: XCTestCase {
    private func resources(notice: String? = nil, license: String? = nil,
                           noticeData: Data? = nil) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("licence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        if let notice {
            try notice.write(to: dir.appendingPathComponent("NOTICE"),
                             atomically: true, encoding: .utf8)
        }
        if let noticeData {
            try noticeData.write(to: dir.appendingPathComponent("NOTICE"))
        }
        if let license {
            try license.write(to: dir.appendingPathComponent("LICENSE"),
                              atomically: true, encoding: .utf8)
        }
        return dir
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Present

    func testBothFilesAreReadBackByteForByte() throws {
        let notice = "Convivy Builder\nCopyright 2026 Convivy\n\nThis product includes software.\n"
        let license = "                                 Apache License\n   1. Definitions.\n"
        let loaded = LicenceNotice.load(from: try resources(notice: notice, license: license))

        XCTAssertEqual(loaded.notice, notice)
        XCTAssertEqual(loaded.license, license)
        XCTAssertFalse(loaded.isEmpty)
    }

    /// What Settings shows is what the repository ships. `make-app.sh` copies
    /// these two files unchanged, so reading them from the repo root is the same
    /// read a shipped bundle's `Contents/Resources` gets.
    func testTheRepositoryFilesLoadVerbatim() throws {
        let loaded = LicenceNotice.load(from: repositoryRoot)

        XCTAssertEqual(loaded.notice,
                       try String(contentsOf: repositoryRoot.appendingPathComponent("NOTICE"),
                                  encoding: .utf8))
        XCTAssertEqual(loaded.license,
                       try String(contentsOf: repositoryRoot.appendingPathComponent("LICENSE"),
                                  encoding: .utf8))
        XCTAssertNotNil(loaded.headline)
    }

    // MARK: - Missing

    /// A bundle built before the files were shipped, and the bare executable
    /// `swift test` runs.
    func testAnEmptyResourcesDirectoryReadsAsEmpty() throws {
        let loaded = LicenceNotice.load(from: try resources())

        XCTAssertNil(loaded.notice)
        XCTAssertNil(loaded.license)
        XCTAssertNil(loaded.headline)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testABundleWithNoResourcesDirectoryReadsAsEmpty() {
        XCTAssertTrue(LicenceNotice.load(from: nil as URL?).isEmpty)
    }

    func testADirectoryThatDoesNotExistReadsAsEmpty() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertTrue(LicenceNotice.load(from: missing).isEmpty)
    }

    /// One file present must not be lost because its sibling is absent.
    func testOneFileMissingLeavesTheOtherReadable() throws {
        let onlyNotice = LicenceNotice.load(from: try resources(notice: "Deck\nCopyright 2026\n"))
        XCTAssertEqual(onlyNotice.notice, "Deck\nCopyright 2026\n")
        XCTAssertNil(onlyNotice.license)
        XCTAssertFalse(onlyNotice.isEmpty)

        let onlyLicense = LicenceNotice.load(from: try resources(license: "Apache License\n"))
        XCTAssertNil(onlyLicense.notice)
        XCTAssertEqual(onlyLicense.license, "Apache License\n")
        XCTAssertFalse(onlyLicense.isEmpty)
    }

    /// A zero-byte or all-whitespace file would draw as a blank sheet, which
    /// reads as a bug. It reads as missing instead.
    func testABlankFileReadsAsMissing() throws {
        let loaded = LicenceNotice.load(from: try resources(notice: " \n\n\t\n", license: ""))
        XCTAssertTrue(loaded.isEmpty)
    }

    /// Not UTF-8: reads as missing rather than crashing or drawing mojibake.
    func testAFileThatIsNotUTF8ReadsAsMissing() throws {
        let loaded = LicenceNotice.load(from: try resources(noticeData: Data([0xFF, 0xFE, 0xC3, 0x28])))
        XCTAssertNil(loaded.notice)
    }

    func testTheMissingWordingIsPinned() {
        XCTAssertEqual(LicenceNotice.unavailableMessage,
                       "This build of Deck does not include its licence files.")
        XCTAssertEqual(LicenceNotice.missingFileMessage("LICENSE"),
                       "This build of Deck does not include LICENSE.")
    }

    // MARK: - Headline

    func testTheHeadlineIsNoticesFirstBlockVerbatim() {
        let licence = LicenceNotice(
            notice: "Convivy Builder\nCopyright 2026 Convivy\n\nThis product includes software.\n",
            license: nil)
        XCTAssertEqual(licence.headline, "Convivy Builder\nCopyright 2026 Convivy")
    }

    func testTheHeadlineSkipsLeadingBlankLines() {
        let licence = LicenceNotice(notice: "\n\nConvivy Builder\n\nMore.\n", license: nil)
        XCTAssertEqual(licence.headline, "Convivy Builder")
    }

    func testANoticeWithNoBlankLineIsItsOwnHeadline() {
        let licence = LicenceNotice(notice: "Convivy Builder\nCopyright 2026 Convivy\n", license: nil)
        XCTAssertEqual(licence.headline, "Convivy Builder\nCopyright 2026 Convivy")
    }

    func testThereIsNoHeadlineWithoutANotice() {
        XCTAssertNil(LicenceNotice(notice: nil, license: "Apache License\n").headline)
    }
}
