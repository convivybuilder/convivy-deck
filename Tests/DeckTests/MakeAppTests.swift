import XCTest

/// `Scripts/make-app.sh` runs under `set -euo pipefail` and ends with a few
/// purely cosmetic progress lines. A write to stdout can return EINTR when a
/// signal lands mid-write; bash does not retry it, so under `set -e` that
/// failure — with none of the script's real work at fault — used to fail the
/// whole script (convivy-deck#133, run 32771831461: build completed, bundle
/// assembled, all three report lines printed, and the log shows "failed"
/// appear immediately after them). `report()` in make-app.sh exists to make
/// that class of failure non-fatal. EINTR itself is not reproducible on
/// demand, so these tests demonstrate the mechanism — a write that fails
/// does not stop the script — rather than the exact signal.
final class MakeAppTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/DeckTests/MakeAppTests.swift
            .deletingLastPathComponent()          // Tests/DeckTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @discardableResult
    private func runBash(_ script: String) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Hardened runtime

    /// Both flavors' executables get hardened runtime. Running make-app.sh
    /// needs a full release build, so this pins the two signing lines; the
    /// launcher's own tests show a signed install still launches.
    func testBothFlavorsSignTheirExecutableWithHardenedRuntime() throws {
        let makeApp = try source("Scripts/make-app.sh")
        for executable in ["Contents/MacOS/Deck", "Contents/MacOS/deck-bin"] {
            XCTAssertTrue(makeApp.contains(#"codesign --force --sign - --options runtime "$APP_DIR/\#(executable)" >&2"#),
                          "\(executable) must be signed ad-hoc with hardened runtime")
        }
    }

    // MARK: - The mechanism: a failing progress write must not be fatal

    /// `report` is exactly `echo "$@" >&2 || true` — pinned here so a future
    /// edit that drops the `|| true` (and silently reintroduces the bug) fails
    /// a test instead of waiting for the next EINTR, and one that drops the
    /// `>&2` puts progress prose on the stdout a caller reads the path from.
    func testReportHelperToleratesAFailingWrite() throws {
        let makeApp = try source("Scripts/make-app.sh")
        XCTAssertTrue(makeApp.contains(#"report() { echo "$@" >&2 || true; }"#),
                      "the report helper's shape changed — re-check it still swallows a failing echo and stays on stderr")

        // A synthetic stand-in for "echo returned non-zero", the observable
        // effect of EINTR on a write bash does not retry. Shadowing `echo`
        // with a function is how a script overrides a builtin.
        let script = """
        set -euo pipefail
        report() { echo "$@" >&2 || true; }
        echo() { return 1; }
        report "cosmetic progress line"
        command echo "REACHED_AFTER_REPORT"
        """
        let result = try runBash(script)
        XCTAssertEqual(result.status, 0,
                       "a failing progress write must not fail the script")
        XCTAssertTrue(result.stdout.contains("REACHED_AFTER_REPORT"),
                      "the script must keep running past a failed report call:\n\(result.stdout)")
    }

    /// The negative control: without the wrapper, the exact same failing
    /// write DOES kill the script under `set -e` — proof `report` changes
    /// behavior, not that `set -e` was already forgiving of this.
    func testABareFailingEchoWouldHaveBeenFatalWithoutTheHelper() throws {
        let script = """
        set -euo pipefail
        echo() { return 1; }
        echo "cosmetic progress line"
        command echo "UNREACHABLE"
        """
        let result = try runBash(script)
        XCTAssertNotEqual(result.status, 0,
                          "a bare echo under set -e should die on a failing write — this is why the helper is needed")
        XCTAssertFalse(result.stdout.contains("UNREACHABLE"))
    }

    // MARK: - Every print site, not just the three the incident happened to hit

    /// The filing named only the three lines the incident hit (the "Built"
    /// report). There are five write sites under `set -e` in this file;
    /// leaving the other two as bare `echo` would leave them exposed to the
    /// identical failure.
    func testEveryProgressLineInMakeAppGoesThroughTheHelper() throws {
        let makeApp = try source("Scripts/make-app.sh")
        let codeLines = makeApp
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }

        for line in codeLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("report()") { continue }  // the helper's own definition
            // The flavor-validation error, like write-bundle-metadata.sh's
            // shallow-clone error, sits immediately before `exit 1` — the
            // script is already failing, so a lost write here changes
            // nothing, unlike the cosmetic progress lines `report` exists for.
            if trimmed.contains("DECK_BUNDLE_FLAVOR must be") { continue }
            XCTAssertFalse(trimmed.hasPrefix("echo "),
                           "found a bare echo under set -e outside report(): \(line)")
        }

        for call in [
            #"report "==> Building Deck ($CONFIGURATION, $FLAVOR)""#,
            #"report "==> Assembling $APP_DIR""#,
            #"report "==> Built $APP_DIR""#,
            #"report "    flavor: $FLAVOR ($FLAVOR_NOTE)""#,
            #"report "    version $VERSION (build $BUILD_NUMBER)""#,
            #"report "    ad-hoc signed with hardened runtime, no Developer ID — see knowledge deck/runbooks/releasing-deck before distributing""#,
        ] {
            XCTAssertTrue(makeApp.contains(call), "expected report call not found: \(call)")
        }
    }

    /// The bundle path on stdout is a DATA write and must stay a bare command,
    /// never routed through `report`. `report` swallows a failed write, which
    /// is right for a progress line and wrong here: a lost write would hand the
    /// caller an empty path with exit 0, a wrong artifact rather than a
    /// missing progress line. Same reasoning as write-bundle-metadata.sh's
    /// version/build line, pinned in `testDataWritesInMetadataWriterAreNotTolerant`.
    func testBundlePathPrintfIsBareAndNotRoutedThroughReport() throws {
        let makeApp = try source("Scripts/make-app.sh")
        let bundlePathLine = #"printf '%s\n' "$ABSOLUTE_APP_DIR""#

        let occurrences = makeApp.components(separatedBy: bundlePathLine).count - 1
        XCTAssertEqual(occurrences, 1, "expected exactly one bundle-path printf in make-app.sh")

        let codeLines = makeApp
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }
        XCTAssertTrue(codeLines.contains(bundlePathLine),
                      "the bundle-path printf must be a bare command on its own line")
        XCTAssertFalse(makeApp.contains("\(bundlePathLine) ||"),
                       "a data write must stay fatal under set -e, not tolerate a failed write")
        XCTAssertFalse(codeLines.contains { $0.hasPrefix("report ") && $0.contains("ABSOLUTE_APP_DIR") },
                       "the bundle path must never be routed through report")
        // Nothing else in the script may write to stdout: `swift build` is the
        // one external command that does, and it is sent to stderr.
        XCTAssertTrue(makeApp.contains(#"swift build -c "$CONFIGURATION" --package-path "$REPO_ROOT" >&2"#),
                      "swift build must write to stderr so stdout carries only the bundle path")
    }

    /// Pins the flavor-validation error as bare and fatal, the same category
    /// as write-bundle-metadata.sh's shallow-clone error: it precedes `exit
    /// 1`, so wrapping it would only hide which value was rejected.
    func testFlavorValidationErrorStaysBareAndFatal() throws {
        let makeApp = try source("Scripts/make-app.sh")
        XCTAssertTrue(
            makeApp.contains(
                #"echo "error: DECK_BUNDLE_FLAVOR must be 'shipped' or 'developer', got '$FLAVOR'" >&2"#),
            "the flavor-validation error must stay a bare, fatal echo to stderr")
    }

    func testMakeAppIsSyntacticallyValid() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", repoRoot.appendingPathComponent("Scripts/make-app.sh").path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "bash -n rejected make-app.sh")
    }

    // MARK: - The trap: not every write in a sibling script is cosmetic

    /// `write-bundle-metadata.sh` writes real files the bundle depends on —
    /// the recorded checkout path, PkgInfo, and the version/build line
    /// `make-app.sh` reads back as its data channel (the `read -r VERSION
    /// BUILD_NUMBER < <(...)` in make-app.sh). A failure on any of those must
    /// stay fatal; wrapping them the way `report` wraps a progress echo would
    /// turn a loud spurious failure into a quiet wrong artifact — an empty
    /// version and build number silently reaching the bundle's plist.
    func testDataWritesInMetadataWriterAreNotTolerant() throws {
        let writer = try source("Scripts/write-bundle-metadata.sh")
        for dataLine in [
            #"printf '%s\n' "$REPO_ROOT" > "$TMP/repo-path""#,
            #"printf 'APPL????' > "$TMP/PkgInfo""#,
            #"printf '%s %s\n' "$VERSION" "$BUILD_NUMBER""#,
        ] {
            XCTAssertTrue(writer.contains(dataLine), "expected data-writing line not found: \(dataLine)")
            XCTAssertFalse(writer.contains("\(dataLine) || true"),
                           "a data-writing line must stay fatal under set -e: \(dataLine)")
        }

        // The shallow-clone error lines sit immediately before `exit 1` — the
        // script is already failing, so a lost write there changes nothing —
        // and stay bare on purpose, unlike the icon-generation warning below
        // them, which deliberately continues. Pinned so a later pass doesn't
        // "finish the job" by routing these through warn() too.
        for shallowCloneLine in [
            #"echo "error: shallow git clone — CFBundleVersion would be 1 for every build." >&2"#,
            #"echo "       Use fetch-depth: 0 in CI, or 'git fetch --unshallow' locally." >&2"#,
        ] {
            XCTAssertTrue(writer.contains(shallowCloneLine), "expected shallow-clone line not found: \(shallowCloneLine)")
        }
        XCTAssertFalse(writer.contains(#"warn "error: shallow clone"#),
                       "the shallow-clone lines must stay bare echo — they precede exit 1, unlike the icon warning")
    }

    // MARK: - The icon-generation warning: a diagnostic that DOES continue

    /// Unlike the shallow-clone lines above, `warning: icon generation
    /// failed…` sits in an `if` BODY after the icon step already failed, and
    /// its own comment says it deliberately continues — a missing icon is
    /// cosmetic, not a broken app. Being inside an `if` body doesn't exempt
    /// it from `set -e`, so before this change an EINTR on that write killed
    /// the script at exactly the moment it was designed to survive. `warn()`
    /// fixes that the same way `report()` fixes make-app.sh's progress
    /// lines, but keeps the `>&2` redirection the bare echo had.
    func testWarnHelperInMetadataWriterToleratesAFailingWrite() throws {
        let writer = try source("Scripts/write-bundle-metadata.sh")
        XCTAssertTrue(writer.contains(#"warn() { echo "$@" >&2 || true; }"#),
                      "the warn helper's shape changed — re-check it still swallows a failing echo and stays on stderr")
        XCTAssertTrue(writer.contains(#"warn "warning: icon generation failed; leaving the existing icon in place""#),
                      "the icon-generation warning must go through warn(), not a bare echo")

        let script = """
        set -euo pipefail
        warn() { echo "$@" >&2 || true; }
        echo() { return 1; }
        warn "warning: icon generation failed; leaving the existing icon in place"
        command echo "REACHED_AFTER_WARN"
        """
        let result = try runBash(script)
        XCTAssertEqual(result.status, 0,
                       "a failing write on the icon-generation warning must not fail the script")
        XCTAssertTrue(result.stdout.contains("REACHED_AFTER_WARN"),
                      "the script must keep running past a failed warn call:\n\(result.stdout)")
    }

    /// The same check made real: a genuine failure writing one of those data
    /// files — here, a read-only Resources directory blocking the `mv` that
    /// lands `repo-path` — must still fail the script rather than being
    /// swallowed.
    func testMetadataWriterFailsLoudlyWhenItCannotWriteADataFile() throws {
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-writer-fail-\(UUID().uuidString)")
        let appDir = scratch.appendingPathComponent("Convivy Builder.app")
        let resources = appDir.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        // A fresh FileManager inside the block rather than the captured `fm`:
        // the teardown closure is main-actor isolated and capturing the
        // shared instance is a data race under strict concurrency.
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resources.path)
            try? FileManager.default.removeItem(at: scratch)
        }
        // No write permission on Resources: the `mv … "$RESOURCES/repo-path"`
        // inside the writer cannot land its first data file.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: resources.path)

        let process = Process()
        process.executableURL = repoRoot.appendingPathComponent("Scripts/write-bundle-metadata.sh")
        process.arguments = [appDir.path, repoRoot.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0,
                          "a real failure writing a bundle data file must still fail the script")
        XCTAssertFalse(fm.fileExists(atPath: appDir.appendingPathComponent("Contents/Info.plist").path),
                       "the writer should die before producing the rest of the bundle")
    }

    // MARK: - The same full-file scan as make-app.sh's, now for the sibling script

    /// The mutation-testing gap the issue named: the pins above catch nothing
    /// when a reviewer adds a brand-new bare `echo "..." >&2` inside this
    /// file's icon-generation `if` body — the exact bug class `warn()` exists
    /// to fix, in a spot no test inspected. This mirrors
    /// `testEveryProgressLineInMakeAppGoesThroughTheHelper`'s shape: scan
    /// every line, exempt only the lines already pinned above as deliberately
    /// bare and fatal (the flavor-validation and shallow-clone errors, which
    /// all precede `exit 1`), and fail on anything else.
    func testEveryProgressLineInMetadataWriterGoesThroughTheHelper() throws {
        let writer = try source("Scripts/write-bundle-metadata.sh")
        let codeLines = writer
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }

        for line in codeLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("warn()") { continue }  // the helper's own definition
            // These three sit immediately before `exit 1` — the script is
            // already failing, so a lost write here changes nothing, unlike
            // the icon-generation warning below, which deliberately
            // continues. Pinned bare and fatal in
            // testDataWritesInMetadataWriterAreNotTolerant above.
            if trimmed.contains("error: flavor must be") { continue }
            if trimmed.contains("error: shallow git clone") { continue }
            if trimmed.contains("Use fetch-depth: 0 in CI") { continue }
            XCTAssertFalse(trimmed.hasPrefix("echo "),
                           "found a bare echo outside warn(): \(line)")
        }

        XCTAssertTrue(writer.contains(#"warn "warning: icon generation failed; leaving the existing icon in place""#),
                      "expected warn call not found: the icon-generation warning")
    }

    // MARK: - deck-launcher.sh needs nothing here

    /// The filing worried about deck-launcher.sh too. It runs `set -uo
    /// pipefail` — deliberately without `-e`, per its own header — so it is
    /// already immune to this failure class. Pinned so nobody "fixes" it by
    /// adding `set -e` or scattering `|| true` there.
    func testLauncherDeliberatelyRunsWithoutDashE() throws {
        let launcher = try source("Scripts/deck-launcher.sh")
        XCTAssertTrue(launcher.contains("set -uo pipefail"),
                      "deck-launcher.sh must keep running without -e — see its own header for why")
        XCTAssertFalse(launcher.contains("set -euo pipefail"),
                       "deck-launcher.sh must not gain -e: an update failure must never cost the operator the app")
    }
}
