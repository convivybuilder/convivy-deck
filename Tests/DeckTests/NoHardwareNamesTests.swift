import XCTest

/// **Check 1 of `deck/specs/running-deck-as-someone-else`, made executable.**
///
/// That check says a scan of `Sources/` for a personal account name, a home
/// path or a host address returns nothing outside test fixtures and comments.
/// It was run by hand, and a hand-written pattern is what failed: the grep
/// that cleared this repo on 2026-09-18 was `"[^"]*the mini[^"]*"` — anchored
/// on "the mini" and case-sensitive — so `Text("This mini doesn't report
/// agent runs yet.")` fell straight through it, twice, and the PR running it
/// claimed to have removed the last hardware name. Review caught that.
///
/// **THE FIRST VERSION OF THIS TEST REPEATED THE MISTAKE ONE LAYER UP.** It
/// extracted string literals with a small lexer and asserted none named the
/// machine. Review ran that lexer against real shapes and found it blind to
/// two the repo contains: a literal nested inside interpolation
/// (`"Host: \(name ?? "the mini")"` — the inner quote ends the outer literal,
/// parity inverts, and the nested text is never seen), and every line of a
/// `"""` body, since the scanner held no state across lines. `SettingsView`,
/// `HostsSettingsView` and `ItemDetailPane` all carry the first shape; six
/// files carry the second, including user-visible HTML and the steward's own
/// prose. Its docstring meanwhile claimed it "over-collects rather than
/// under-collects". It under-collected in exactly the direction it disclaimed.
///
/// **So there is no lexer now.** This scans every line that is not a comment.
/// It over-collects by construction **with respect to literal SHAPES** — it
/// cannot be blind to one, because it no longer tries to recognise literals
/// at all. That is the narrow claim, and the earlier version of this comment
/// made a wider one it could not support.
///
/// **What it gets wrong, in both directions, because a guard that describes
/// only its good direction is how the last two rounds of this PR went:**
///
/// - **Noise.** A trailing `// the mini` on a code line is flagged. Loud,
///   fixed by rewording, and the tree has none today.
/// - **Silence, and this is a real blind spot.** `isCommentLine` is a
///   recognition step, and it has no idea whether the line sits inside a
///   `"""` body — where a `//`-led line is string CONTENT, not a comment.
///   The tree has 54 such lines, all in `ConversationWebView`'s embedded
///   JavaScript, and **two of them name the machine** (`:1039`, `:1051`).
///   Exempting them is the right answer, because they are JS comments and
///   the spec exempts comments — but this scanner reaches that answer by a
///   coincidence of syntax rather than by knowing what it is looking at.
///   **The blind spot is exactly a body line whose first non-blank
///   characters are `//`**, and nothing wider: an ordinary sentence inside a
///   `"""` body is scanned and caught, which
///   `testTheScannerSeesTheShapesTheLexerMissed` pins. So what could slip
///   through is a user-visible line that happens to begin with `//` — rare,
///   and worth knowing before someone adds one.
/// - **The dot exemption is broader than its reason.** It exists for
///   SwiftUI's `controlSize(.mini)`, but it silences any `x.mini` — a
///   hostname like `ops.mini.local` included. Nothing in the tree has that
///   shape, so under the seen-occurrence rule this is recorded rather than
///   guarded.
///
/// A check whose blind spot and whose clean result look identical is not a
/// check. This one is allowed to be noisy; where it is blind, it says so.
final class NoHardwareNamesTests: XCTestCase {

    /// Names of Convivy's own machines, matched as WHOLE WORDS — `mini` is a
    /// substring of `minimum`, which this repo uses constantly for typography
    /// and layout floors.
    private static let hardwareNames = ["mini"]

    /// A line the scan must reach for its result to mean anything, and the
    /// file it lives in. Reworded from `"This mini …"` by this PR, so it is
    /// also the regression these tests exist around.
    private static let canary = "This host doesn't report agent runs yet."
    private static let canaryFiles = ["CockpitView.swift", "ServiceCrewPanel.swift"]

    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/DeckTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
    }

    /// Whether a line is comment-only. Comments are exempt because the spec
    /// exempts them: a doc comment saying something runs on the mini describes
    /// Convivy's deployment to a reader of the code, not an operator's machine.
    private func isCommentLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// A whole-word hardware name, **not preceded by a dot** — which is what
    /// exempts SwiftUI's own `controlSize(.mini)`, the only non-comment
    /// occurrence in the tree today.
    private func namesHardware(_ line: String) -> Bool {
        let lowered = line.lowercased()
        for name in Self.hardwareNames {
            var searchRange = lowered.startIndex..<lowered.endIndex
            while let found = lowered.range(of: name, range: searchRange) {
                let before: Character? = found.lowerBound == lowered.startIndex
                    ? nil : lowered[lowered.index(before: found.lowerBound)]
                let after: Character? = found.upperBound == lowered.endIndex
                    ? nil : lowered[found.upperBound]
                let boundedBefore = before.map { !$0.isLetter && $0 != "." } ?? true
                let boundedAfter = after.map { !$0.isLetter } ?? true
                if boundedBefore && boundedAfter { return true }
                guard found.upperBound < lowered.endIndex else { break }
                searchRange = found.upperBound..<lowered.endIndex
            }
        }
        return false
    }

    func testNoLineInSourcesNamesConvivysHardware() throws {
        let root = Self.sourcesDirectory
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "Sources/ must be reachable — if this fails the check is not running")

        var offenders: [String] = []
        var filesScanned = 0
        var linesScanned = 0
        var canarySeenIn: Set<String> = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            filesScanned += 1
            let contents = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
                linesScanned += 1
                if line.contains(Self.canary) { canarySeenIn.insert(url.lastPathComponent) }
                guard !isCommentLine(line) else { continue }
                if namesHardware(line) {
                    offenders.append("\(url.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        // POSITIVE CONTROL, NAMED RATHER THAN COUNTED. Round-2 review pointed
        // out that a floor ("more than 50 files") catches a walk reaching
        // nothing and passes a walk reaching a fifth of the tree. Asserting a
        // specific line was seen in specific files fails if either file drops
        // out of the walk or the reader stops returning content.
        for file in Self.canaryFiles {
            XCTAssertTrue(canarySeenIn.contains(file),
                          """
                          the canary line was not found in \(file), so this scan's clean \
                          result means nothing. Either the walk no longer reaches that file, \
                          or the line was reworded without updating `canary` here — check \
                          which before trusting anything else this test says.
                          """)
        }
        XCTAssertGreaterThan(filesScanned, 100, "scanned \(filesScanned) files; the tree is larger")
        XCTAssertGreaterThan(linesScanned, 10_000, "scanned \(linesScanned) lines; the tree is larger")

        XCTAssertEqual(offenders, [], "lines naming Convivy's hardware:\n" + offenders.joined(separator: "\n"))
    }

    /// **The two shapes the lexer was blind to**, pinned so the line scanner
    /// cannot regress into missing them, plus the exemptions that stop it
    /// crying wolf.
    func testTheScannerSeesTheShapesTheLexerMissed() {
        // The literal nested in interpolation that inverted the lexer's parity.
        XCTAssertTrue(namesHardware(#"Text("Host: \(name ?? "the mini") is down")"#))
        // A line of a multi-line body, which the lexer never had state for.
        XCTAssertTrue(namesHardware(#"    This mini is down"#))
        // The plain case the lexer did catch.
        XCTAssertTrue(namesHardware(#"Text("This mini doesn't report agent runs yet.")"#))
        XCTAssertTrue(namesHardware("the mini\u{2019}s answer could not be read"))

        // Comments are exempt, per the spec.
        XCTAssertTrue(isCommentLine("    // runs on the mini"))
        XCTAssertTrue(isCommentLine("    /// runs on the mini"))
        XCTAssertFalse(isCommentLine(#"Text("This mini is down") // trailing"#))

        // Exemptions that keep it from crying wolf. A test that does gets deleted.
        XCTAssertFalse(namesHardware("static let minimumScale = 0.5"))
        XCTAssertFalse(namesHardware("ProgressView().controlSize(.mini)"),
                       "SwiftUI's own API is not our hardware")
        XCTAssertFalse(namesHardware("let minimum = 3"))
        XCTAssertFalse(namesHardware("administration"))
    }
}
