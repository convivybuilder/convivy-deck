import XCTest

/// **Deck has no control that creates a crew, and this keeps it that way.**
///
/// A crew is created by asking the steward. The rail's "+ New" and its context
/// menu item went first; Settings › Sessions still had a "+" that opened an add
/// sheet, and Settings › General still had a "New crews go in:" field that only
/// the removed sheet read. Both are gone, and this fails if either comes back.
///
/// **What it reads is source text, so it is a tripwire and not a proof.** It
/// looks for the names of the removed things on non-comment lines. Someone who
/// rebuilds the same affordance under a new name walks past it, and review is
/// what catches that. Its job is the cheap regression: the sheet, the field or
/// the derivation type reappearing under the name they had.
///
/// **The other direction is asserted too.** Removing creation must not remove
/// configuration, so the Sessions view is required to still carry the fields
/// that set an existing crew's folder, project, repos and bead. Those lines are
/// also this scan's positive control: if the walk stops reaching the file, the
/// required lines go missing and the test fails instead of passing on nothing.
final class NoCrewCreationControlsTests: XCTestCase {

    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/DeckTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
    }

    /// What was removed, by the name it went by. An occurrence on a code line
    /// means the surface is back.
    private static let removed = [
        "AddSessionSheet",
        "NewCrewSheet",
        "NewCrewDerivation",
        "New crews go in",
        "New Crew sheet",
        "setCrewsRoot",
    ]

    /// What must remain: the fields that configure a crew that already exists.
    private static let required: [(file: String, needle: String)] = [
        ("SessionsSettingsView.swift", #"LabeledContent("Folder:")"#),
        ("SessionsSettingsView.swift", #"LabeledContent("Project:")"#),
        ("SessionsSettingsView.swift", #"LabeledContent("Bead:")"#),
        ("SessionsSettingsView.swift", #"LabeledContent("Repos:")"#),
        ("SessionsSettingsView.swift", #".help("Remove the selected session")"#),
    ]

    private func isCommentLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    private func swiftFiles() throws -> [(name: String, lines: [String])] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: Self.sourcesDirectory, includingPropertiesForKeys: nil),
            "Sources/ must be reachable — if this fails the check is not running")
        var files: [(name: String, lines: [String])] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let contents = try String(contentsOf: url, encoding: .utf8)
            files.append((url.lastPathComponent, contents.components(separatedBy: .newlines)))
        }
        return files
    }

    func testNoCodeLineNamesARemovedCreationSurface() throws {
        let files = try swiftFiles()
        XCTAssertGreaterThan(files.count, 100, "scanned \(files.count) files; the tree is larger")

        var offenders: [String] = []
        for file in files {
            for (index, line) in file.lines.enumerated() where !isCommentLine(line) {
                for name in Self.removed where line.contains(name) {
                    offenders.append("\(file.name):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(offenders, [],
                       "a crew-creation surface is back; a crew is made by asking the steward:\n"
                       + offenders.joined(separator: "\n"))
    }

    /// Nothing in Settings › Sessions presents a sheet. The add panel was the
    /// only one, so a `.sheet(` returning to that file is the creation flow
    /// coming back under a new name.
    func testTheSessionsSettingsViewPresentsNoSheet() throws {
        let file = try XCTUnwrap(
            try swiftFiles().first { $0.name == "SessionsSettingsView.swift" },
            "SessionsSettingsView.swift must be reachable — if this fails the check is not running")
        let sheets = file.lines.enumerated()
            .filter { !isCommentLine($0.element) && $0.element.contains(".sheet(") }
            .map { "SessionsSettingsView.swift:\($0.offset + 1)" }
        XCTAssertEqual(sheets, [])
    }

    /// The direction that must still work. Editing an existing crew stays: this
    /// is how `project` and `bead` get set when a served spec leaves them empty.
    func testEditingAnExistingCrewStillHasItsFields() throws {
        let files = try swiftFiles()
        for (name, needle) in Self.required {
            let found = files.contains { $0.name == name && $0.lines.contains { $0.contains(needle) } }
            XCTAssertTrue(found, "\(name) no longer contains \(needle); "
                          + "configuring an existing crew must survive the removal of creation")
        }
    }
}
