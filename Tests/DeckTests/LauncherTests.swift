import XCTest

/// `Scripts/deck-launcher.sh` is the bundle executable — the thing macOS runs on
/// a Dock click. Nothing in the Swift build touches it, so a mistake there
/// produces an app that compiles, tests green, and then will not start.
///
/// THE PROMISE UNDER TEST is the one that matters most: **an update failure never
/// costs the operator the app.** Every path below ends in the already-built binary being
/// exec'd, however badly the update went. The happy path (fetch, build, swap) is
/// not tested here, because exercising it means a release build of this package
/// inside its own test suite.
final class LauncherTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/DeckTests/LauncherTests.swift
            .deletingLastPathComponent()          // Tests/DeckTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
    }

    private var launcherSource: URL {
        repoRoot.appendingPathComponent("Scripts/deck-launcher.sh")
    }

    // MARK: - A disposable bundle

    /// A fake app bundle, named `Convivy Builder.app` unless a test asks for the
    /// legacy name, whose `deck-bin` records that it ran, so a test can tell
    /// "launched" from "exited without launching" — the distinction the whole
    /// suite turns on.
    private struct Bundle {
        let root: URL
        let home: URL
        let marker: URL
        var launcher: URL { root.appendingPathComponent("Contents/MacOS/Deck") }
        var binary: URL { root.appendingPathComponent("Contents/MacOS/deck-bin") }
        var resources: URL { root.appendingPathComponent("Contents/Resources") }
        var launched: Bool { FileManager.default.fileExists(atPath: marker.path) }
    }

    private func makeBundle(binary hasBinary: Bool = true,
                            name: String = "Convivy Builder.app") throws -> Bundle {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-launcher-\(UUID().uuidString)")
        let root = tmp.appendingPathComponent(name)
        let home = tmp.appendingPathComponent("home")
        let marker = tmp.appendingPathComponent("launched")

        try fm.createDirectory(at: root.appendingPathComponent("Contents/MacOS"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Contents/Resources"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        // A fresh FileManager inside the block rather than the captured `fm`:
        // the teardown closure is main-actor isolated and capturing the shared
        // instance is a data race under strict concurrency.
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }

        let bundle = Bundle(root: root, home: home, marker: marker)
        try fm.copyItem(at: launcherSource, to: bundle.launcher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.launcher.path)

        if hasBinary {
            // Stands in for the compiled app: it only has to prove it was
            // reached, and `exec` means its exit status becomes the launcher's.
            try "#!/bin/bash\ntouch \"\(marker.path)\"\nexit 0\n"
                .write(to: bundle.binary, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.binary.path)
        }
        return bundle
    }

    @discardableResult
    private func run(_ bundle: Bundle, env extra: [String: String] = [:]) throws -> Int32 {
        let process = Process()
        process.executableURL = bundle.launcher
        // HOME is redirected so the launcher's log and its update lock land in
        // the throwaway tree rather than in the real ~/Library/Logs/Deck, and so
        // a test can never collide with a launch happening on the same machine.
        var environment = ["HOME": bundle.home.path, "DECK_NO_UI": "1", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment.merge(extra) { _, new in new }
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func writeRepoPath(_ path: String, in bundle: Bundle) throws {
        try (path + "\n").write(to: bundle.resources.appendingPathComponent("repo-path"),
                                atomically: true, encoding: .utf8)
    }

    /// The affirmative write-bundle-metadata.sh writes into every bundle it
    /// builds — the one that works without an environment variable, since a
    /// GUI app launched from the Dock does not inherit a shell's exports.
    private func writeOptInMarker(in bundle: Bundle) throws {
        try "1\n".write(to: bundle.resources.appendingPathComponent("auto-update-opt-in"),
                        atomically: true, encoding: .utf8)
    }

    // MARK: - The update is skipped, and the app still starts

    /// PINS THE DEFECT THIS PR FIXES. Before this change, an unset
    /// `APP_AUTO_UPDATE_ENABLED` fell through the launcher's `*` case to
    /// "update" — a bundle copied to a Mac with nothing configured would
    /// fast-forward `origin/main` and compile it as whoever clicked the Dock
    /// icon. Absence of configuration must mean off.
    ///
    /// No repo-path is written: the launcher logs its auto-update decision
    /// before it ever reads one, so this needs nothing that could build. The
    /// first version of this test pointed at `repoRoot` — this worktree's own
    /// checkout — and asserted only on the generic "skipping update"
    /// substring, which every early-exit path in the launcher shares. Against
    /// the unflipped launcher that assertion never fires from the flag check
    /// at all: the value falls through to "update", the launcher finds itself
    /// on a feature branch, and it runs a REAL `swift build -c release`
    /// against this worktree's own `.build`, contending with the `swift test`
    /// run driving this very test until the launcher's 600s timeout fires.
    /// Asserting on the specific decision line closes both problems at once —
    /// it only exists when the flag path is actually taken, and it fires
    /// before any repo access, so there is nothing left to build.
    func testUnsetAndNoMarkerMeansOff() throws {
        let bundle = try makeBundle()

        XCTAssertEqual(try run(bundle), 0)
        XCTAssertTrue(bundle.launched, "the app must still start")
        let log = try launcherLog(bundle)
        XCTAssertTrue(log.contains("auto-update decision: off (no APP_AUTO_UPDATE_ENABLED and no opt-in marker)"),
                      "unset APP_AUTO_UPDATE_ENABLED with no opt-in marker must be off:\n\(log)")
    }

    /// An explicitly empty value must be read the same way absence is —
    /// nobody typed an affirmative, so there is nothing to turn the update on.
    func testEmptyMeansOff() throws {
        let bundle = try makeBundle()

        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": ""]), 0)
        XCTAssertTrue(bundle.launched, "the app must still start")
        let log = try launcherLog(bundle)
        XCTAssertTrue(log.contains("auto-update decision: off (no APP_AUTO_UPDATE_ENABLED and no opt-in marker)"),
                      "an empty APP_AUTO_UPDATE_ENABLED must be treated the same as unset:\n\(log)")
    }

    /// A typo read silently as off and a typo read silently as on look
    /// identical to whoever mistyped it, and only one of those is safe — so an
    /// unrecognized value must be off, and must say in the log that it was
    /// unrecognized rather than a false spelling nobody chose on purpose.
    func testUnrecognizedValueMeansOffAndIsLogged() throws {
        let bundle = try makeBundle()

        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "banana"]), 0)
        XCTAssertTrue(bundle.launched, "the app must still start")
        let log = try launcherLog(bundle)
        XCTAssertTrue(log.contains("auto-update decision: off (APP_AUTO_UPDATE_ENABLED=banana is unrecognized)"),
                      "an unrecognized value must be off and must say so:\n\(log)")
    }

    /// The marker alone, with no environment variable at all, must turn the
    /// update on — this is the path a bundle assembled by
    /// `write-bundle-metadata.sh` takes every time.
    func testMarkerAloneMeansOn() throws {
        let bundle = try makeBundle()
        let repo = try makeThrowawayCheckout(launchMarker: bundle.marker)
        try writeRepoPath(repo.path, in: bundle)
        try writeOptInMarker(in: bundle)

        XCTAssertEqual(try run(bundle), 0)
        let log = try launcherLog(bundle)
        XCTAssertTrue(log.contains("auto-update decision: on (auto-update-opt-in marker present)"),
                      "the opt-in marker alone must turn the update on:\n\(log)")
        XCTAssertTrue(bundle.launched, "the marker must still result in a launch:\n\(log)")
    }

    /// `APP_AUTO_UPDATE_ENABLED=false` is CLAUDE.md's documented kill switch,
    /// and it must win even over a bundle that opted in via the marker.
    func testExplicitFalseBeatsTheMarker() throws {
        let bundle = try makeBundle()
        try writeOptInMarker(in: bundle)

        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "false"]), 0)
        XCTAssertTrue(bundle.launched, "APP_AUTO_UPDATE_ENABLED=false must still launch the app")
        let log = try launcherLog(bundle)
        XCTAssertTrue(log.contains("auto-update decision: off (APP_AUTO_UPDATE_ENABLED=false)"),
                      "an explicit false must win over the opt-in marker:\n\(log)")
    }

    func testLaunchesWithoutUpdatingWhenDisabled() throws {
        let bundle = try makeBundle()
        try writeRepoPath(repoRoot.path, in: bundle)

        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "false"]), 0)
        XCTAssertTrue(bundle.launched, "APP_AUTO_UPDATE_ENABLED=false must still launch the app")
        let log = try launcherLog(bundle)
        XCTAssertTrue(log.contains("skipping update"), "the log must say why:\n\(log)")
    }

    /// `FALSE`, `False`, `0`, `no` and their kin all mean the same thing —
    /// matched case-insensitively so a launchd plist or a shell export using
    /// any of the obvious spellings behaves the same.
    func testSkipsUpdateOnAnyRecognizedFalseSpelling() throws {
        for spelling in ["FALSE", "False", "0", "no", "NO"] {
            let bundle = try makeBundle()
            try writeRepoPath(repoRoot.path, in: bundle)

            XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": spelling]), 0)
            let log = try launcherLog(bundle)
            XCTAssertTrue(log.contains("skipping update"), "'\(spelling)' should skip the update:\n\(log)")
        }
    }

    /// A value that means "false" but isn't the exact string `case` matches —
    /// a stray space from a hand-edited plist, `off`/`disabled` as the natural
    /// guess for an `*_ENABLED` flag, or a value copied whole out of JSON with
    /// its quotes still on — must still be read as an explicit false. Found
    /// independently by deck-reviewer and deck-security-reviewer on PR #128:
    /// unnormalized exact-string matching let all of these fall through to
    /// "update", silently defeating the anti-RCE control this flag backs.
    ///
    /// `"false "` and `" false"` pin the follow-up deck-security-reviewer
    /// caught on the same PR: trimming once and then dequoting leaves
    /// whitespace that was INSIDE the quotes exposed at the new outer edge
    /// once the quotes come off, so a single trim pass missed exactly the
    /// values this flag exists to catch.
    func testSkipsUpdateOnMalformedFalseSpelling() throws {
        for spelling in ["False ", " false", "off", "disabled", "\"false\"", "\"false \"", "\" false\""] {
            let bundle = try makeBundle()
            try writeRepoPath(repoRoot.path, in: bundle)

            XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": spelling]), 0)
            let log = try launcherLog(bundle)
            XCTAssertTrue(log.contains("skipping update"), "'\(spelling)' should skip the update:\n\(log)")
        }
    }

    /// A value split across LINES by an embedded newline — the shape a
    /// pretty-printed LaunchAgents plist `EnvironmentVariables` entry produces.
    /// Found by deck-reviewer by running this block, not by reading the diff:
    /// `sed`'s `^`/`$` anchor to line boundaries rather than to the value, so a
    /// leading newline is never at the start of the final line's content and
    /// survived two rounds of line-anchored trimming. A trailing newline alone
    /// looked trimmed only because `$(...)` strips a trailing newline as a
    /// side effect of command substitution, not because the trim did it —
    /// which is why that case alone was never enough to catch the bug.
    func testSkipsUpdateWhenTheValueSpansMultipleLines() throws {
        for spelling in ["\nfalse\n", "\nfalse", "false\n", "\n\"false\"\n"] {
            let bundle = try makeBundle()
            try writeRepoPath(repoRoot.path, in: bundle)

            XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": spelling]), 0)
            let log = try launcherLog(bundle)
            XCTAssertTrue(log.contains("skipping update"),
                          "\(spelling.debugDescription) should skip the update:\n\(log)")
        }
    }

    /// Every spelling that means "yes" must update — matched case-
    /// insensitively, mirroring the false spellings above.
    func testEachAffirmativeSpellingMeansOn() throws {
        for spelling in ["true", "TRUE", "1", "yes", "on", "enabled"] {
            let bundle = try makeBundle()
            let repo = try makeThrowawayCheckout(launchMarker: bundle.marker)
            try writeRepoPath(repo.path, in: bundle)

            XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": spelling]), 0)
            let log = try launcherLog(bundle)
            XCTAssertTrue(log.contains("auto-update decision: on (APP_AUTO_UPDATE_ENABLED=\(spelling))"),
                          "'\(spelling)' must turn the update on:\n\(log)")
            XCTAssertTrue(bundle.launched, "'\(spelling)' must still launch:\n\(log)")
        }
    }

    /// Opts in via the env var: with the flag off by default, a bundle with
    /// nothing configured would short-circuit before ever reading repo-path
    /// at all, which would make this test pass without exercising the
    /// repo-path-missing branch it exists to cover.
    func testLaunchesWhenRepoPathIsMissing() throws {
        let bundle = try makeBundle()

        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "true"]), 0)
        XCTAssertTrue(bundle.launched, "a bundle with no recorded checkout must still launch")
    }

    /// A relative path would resolve against whatever directory macOS happened
    /// to start the app in — `/` for a Dock click — so the launcher refuses it
    /// rather than guessing. Opted in for the same reason as the test above.
    func testLaunchesWhenRepoPathIsRelative() throws {
        let bundle = try makeBundle()
        try writeRepoPath("some/relative/path", in: bundle)

        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "true"]), 0)
        XCTAssertTrue(bundle.launched)
    }

    /// Opted in for the same reason as the two tests above.
    func testLaunchesWhenRepoPathIsNotACheckout() throws {
        let bundle = try makeBundle()
        try writeRepoPath(bundle.home.path, in: bundle)

        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "true"]), 0)
        XCTAssertTrue(bundle.launched, "a repo-path that is not a git checkout must not block launch")
    }

    // MARK: - The failure this must never produce

    func testFailsLoudlyWhenThereIsNothingToLaunch() throws {
        let bundle = try makeBundle(binary: false)

        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "false"]), 1,
                       "a bundle with no binary is the one case that must not exit 0")
    }

    // MARK: - The lock

    /// A second click while an update is running launches immediately, and — the
    /// part that actually bites — leaves the running update's lock alone. An
    /// earlier draft released the lock in an `EXIT` trap, which `exec` never
    /// runs, so the lock leaked on every successful launch instead.
    func testConcurrentLaunchLeavesTheLockAlone() throws {
        let fm = FileManager.default
        let bundle = try makeBundle()
        try writeRepoPath(repoRoot.path, in: bundle)
        let lock = bundle.home.appendingPathComponent("Library/Logs/Deck/update.lock")
        try fm.createDirectory(at: lock, withIntermediateDirectories: true)

        // Opted in: with updates off by default, an unconfigured bundle would
        // short-circuit before ever attempting to take the lock, which would
        // make this pass without exercising the "already held" branch at all.
        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "true"]), 0)
        XCTAssertTrue(bundle.launched, "a held lock must not stop the app from starting")
        XCTAssertTrue(fm.fileExists(atPath: lock.path),
                      "the launcher released a lock it did not hold")
    }

    /// A lock left behind by a crashed update must not stop the app updating
    /// forever, so a lock older than 30 minutes is broken. Untested, that is
    /// exactly the kind of thing a wrong `find` flag breaks silently — nobody
    /// notices until an update stops happening.
    ///
    /// This case also walks the whole update path against a git repo that is not
    /// a Swift package, so the build failure and its fall-through to the
    /// existing binary are covered here too.
    func testBreaksAStaleLockAndStillLaunches() throws {
        let fm = FileManager.default
        let bundle = try makeBundle()
        let checkout = bundle.home.appendingPathComponent("checkout")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        try gitInit(checkout)
        try writeRepoPath(checkout.path, in: bundle)

        let lock = bundle.home.appendingPathComponent("Library/Logs/Deck/update.lock")
        try fm.createDirectory(at: lock, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -40 * 60)],
                             ofItemAtPath: lock.path)

        // Opted in, or this would short-circuit before ever reaching the lock.
        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "true"]), 0)
        XCTAssertTrue(bundle.launched, "a failed build must still launch the existing binary")
        XCTAssertFalse(fm.fileExists(atPath: lock.path),
                       "the launcher kept the lock it took — the next 30 minutes of clicks would skip updating")

        let log = try String(contentsOf: bundle.home.appendingPathComponent("Library/Logs/Deck/launcher.log"),
                             encoding: .utf8)
        XCTAssertTrue(log.contains("broke a stale lock"), "the stale lock was not broken:\n\(log)")
    }

    /// The one path that leaves without passing through `launch()`: the build
    /// failed and there is no binary to fall back on. It still holds the lock,
    /// and releasing it explicitly in `launch()` alone missed this — every click
    /// for the next 30 minutes would then blame a phantom concurrent update
    /// instead of showing the build failure. Both reviewers caught it on the
    /// first head; this is what stops it coming back.
    func testReleasesTheLockWhenItExitsWithoutLaunching() throws {
        let fm = FileManager.default
        let bundle = try makeBundle(binary: false)
        let checkout = bundle.home.appendingPathComponent("checkout")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        try gitInit(checkout)
        try writeRepoPath(checkout.path, in: bundle)

        // Opted in, or this would short-circuit before ever taking the lock.
        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "true"]), 1)
        XCTAssertFalse(
            fm.fileExists(atPath: bundle.home.appendingPathComponent("Library/Logs/Deck/update.lock").path),
            "the launcher exited holding its own lock"
        )
    }

    private func gitInit(_ directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--quiet", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "git init failed")
    }

    // MARK: - A bundle whose metadata make-app.sh never refreshed

    /// A checkout the launcher will not fetch from: a real repository, so
    /// `rev-list --count` answers, on a branch that is not `main`, so the
    /// launcher skips the network entirely and the test stays offline and fast.
    private func makeThrowawayCheckout(launchMarker: URL? = nil) throws -> URL {
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }
        // A REAL, MINIMAL SwiftPM PACKAGE, because the launcher builds the
        // checkout before it touches the bundle and takes an early exit when
        // that fails — so a fixture that cannot build tests nothing past the
        // build. One file, no dependencies; it compiles in a couple of seconds.
        try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(
                name: "Deck",
                targets: [.executableTarget(name: "Deck", path: "Sources/Deck")])
            """.write(to: repo.appendingPathComponent("Package.swift"),
                      atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("Sources/Deck"), withIntermediateDirectories: true)
        // The launcher installs what it built over `deck-bin` and execs THAT,
        // so the stand-in is what actually runs — and it has to leave the same
        // evidence the fixture binary would, or `launched` reads false for a
        // launch that worked. That the mark now comes from a binary the
        // launcher compiled makes these tests more end-to-end, not less.
        let mark = launchMarker.map {
            "import Foundation\ntry? \"x\".write(toFile: \"\($0.path)\", atomically: true, encoding: .utf8)\n"
        } ?? "print(\"stand-in\")\n"
        try mark.write(
            to: repo.appendingPathComponent("Sources/Deck/main.swift"),
            atomically: true, encoding: .utf8)
        for args in [["init", "--quiet"],
                     ["-c", "user.email=t@t", "-c", "user.name=T", "add", "."],
                     ["-c", "user.email=t@t", "-c", "user.name=T", "commit", "--quiet", "-m", "seed"],
                     ["checkout", "--quiet", "-b", "scratch"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        return repo
    }

    private func writeInfoPlist(build: String, in bundle: Bundle) throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleVersion</key><string>\(build)</string>
            </dict></plist>
            """
        try plist.write(to: bundle.root.appendingPathComponent("Contents/Info.plist"),
                        atomically: true, encoding: .utf8)
    }

    private func launcherLog(_ bundle: Bundle) throws -> String {
        let log = bundle.home.appendingPathComponent("Library/Logs/Deck/launcher.log")
        return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    /// A stand-in for `write-bundle-metadata.sh` inside the throwaway
    /// checkout. The real one needs a VERSION file, a commit count, `swift` and
    /// `iconutil`; what these tests are asking is whether the LAUNCHER decides
    /// to run it and hands it the right arguments. `testTheWriterWritesEvery\
    /// FileTheBundleNeeds` covers the real one.
    private func installStubWriter(in repo: URL, marker: URL) throws {
        let scripts = repo.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let writer = scripts.appendingPathComponent("write-bundle-metadata.sh")
        try """
            #!/bin/bash
            # $1 is the app dir, $2 the checkout.
            printf '%s\n%s\n' "$1" "$2" > "\(marker.path)"
            """.write(to: writer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: writer.path)
    }

    /// The failure this closes is silent: `deck-bin` gets swapped on every
    /// launch, so the app behaves as though it updated while the icon and the
    /// version string stay frozen at whenever make-app.sh last ran. The
    /// launcher now refreshes them itself rather than telling the operator to.
    func testRefreshesTheBundleWhenItIsOlderThanTheCheckout() throws {
        let bundle = try makeBundle()
        let repo = try makeThrowawayCheckout()
        let marker = repo.appendingPathComponent("writer-ran")
        try installStubWriter(in: repo, marker: marker)
        try writeRepoPath(repo.path, in: bundle)
        try writeInfoPlist(build: "92", in: bundle)

        // Opted in, or this would short-circuit before ever reaching the
        // refresh logic it exists to test.
        _ = try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "true"])

        let log = try launcherLog(bundle)
        XCTAssertTrue(log.contains("refreshing bundle metadata"),
                      "a bundle at 92 against a one-commit checkout must refresh:\n\(log)")
        let ran = try String(contentsOf: marker, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(ran.count, 2, "the writer must be given the app dir and the checkout")
        XCTAssertEqual(URL(fileURLWithPath: ran[0]).standardizedFileURL.path,
                       bundle.root.standardizedFileURL.path,
                       "the writer must be pointed at the bundle, not at Contents")
        XCTAssertEqual(ran[1], repo.path)
    }

    /// The refresh runs `swift` to draw the icon, so doing it on every launch
    /// rather than only a stale one would add seconds to every Dock click.
    func testDoesNotRefreshWhenTheBundleMatchesTheCheckout() throws {
        let bundle = try makeBundle()
        let repo = try makeThrowawayCheckout()
        let marker = repo.appendingPathComponent("writer-ran")
        try installStubWriter(in: repo, marker: marker)
        try writeRepoPath(repo.path, in: bundle)
        // The throwaway checkout has exactly one commit.
        try writeInfoPlist(build: "1", in: bundle)

        // Opted in, or this would short-circuit before ever reaching the
        // refresh logic it exists to test.
        _ = try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "true"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "a current bundle must not pay for a refresh it does not need")
    }

    /// THE TRANSITION FROM THE OLD NAME. A developer bundle built before the
    /// rename is still `Deck.app`, and an operator's Dock tile points at it. Its
    /// launcher is a frozen copy, so this runs the current launcher inside a
    /// bundle carrying the legacy name, which is what that frozen launcher
    /// does against a renamed checkout. It must still take the update and
    /// launch, refresh the bundle it was handed rather than a renamed one, say
    /// the launcher has changed, and leave the directory holding only that
    /// bundle. Only make-app.sh names or creates `Convivy Builder.app`.
    func testALegacyDeckAppStillUpdatesAndCreatesNoSecondBundle() throws {
        let bundle = try makeBundle(name: "Deck.app")
        let repo = try makeThrowawayCheckout(launchMarker: bundle.marker)
        let writerMarker = repo.appendingPathComponent("writer-ran")
        try installStubWriter(in: repo, marker: writerMarker)
        try writeRepoPath(repo.path, in: bundle)
        // A checkout whose launcher differs from the bundle's copy, which is
        // what a commit that changes the launcher looks like from the bundle.
        let launcherText = try String(contentsOf: launcherSource, encoding: .utf8)
        try (launcherText + "\n# checkout copy\n").write(
            to: repo.appendingPathComponent("Scripts/deck-launcher.sh"),
            atomically: true, encoding: .utf8)

        // Opted in, or this would short-circuit before the update it exists to test.
        _ = try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "true"])

        let log = try launcherLog(bundle)
        XCTAssertTrue(log.contains("installed new binary"),
                      "a legacy-named bundle must still take the update:\n\(log)")
        XCTAssertTrue(bundle.launched, "the rebuilt binary must be the one that launched:\n\(log)")
        XCTAssertTrue(log.contains("launcher differs from the checkout"),
                      "the bundle must say its launcher is stale:\n\(log)")

        let ran = try String(contentsOf: writerMarker, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(ran.count, 2, "the writer must be given the app dir and the checkout")
        XCTAssertEqual(URL(fileURLWithPath: ran[0]).standardizedFileURL.path,
                       bundle.root.standardizedFileURL.path,
                       "the refresh must target the bundle it was handed, not a renamed one")

        let directory = bundle.root.deletingLastPathComponent()
        let bundles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".app") }
        XCTAssertEqual(bundles, ["Deck.app"],
                       "the launcher must never create a second bundle beside the one it runs from")
    }

    /// A bundle assembled by something other than make-app.sh has no build
    /// number to compare, which is a reason to refresh rather than to give up.
    func testRefreshesWhenThereIsNoBuildNumberToCompare() throws {
        let bundle = try makeBundle()
        let repo = try makeThrowawayCheckout(launchMarker: bundle.marker)
        let marker = repo.appendingPathComponent("writer-ran")
        try installStubWriter(in: repo, marker: marker)
        try writeRepoPath(repo.path, in: bundle)

        // Opted in, or this would short-circuit before ever reaching the
        // refresh logic it exists to test.
        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "true"]), 0)
        XCTAssertTrue(bundle.launched, "a bundle with no Info.plist must still start")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// A checkout too old to contain the writer, or one where it is not
    /// executable. The launch is what matters and must not be held up by a
    /// cosmetic refresh that cannot run.
    func testLaunchesWhenTheCheckoutHasNoWriter() throws {
        let bundle = try makeBundle()
        let repo = try makeThrowawayCheckout(launchMarker: bundle.marker)
        try writeRepoPath(repo.path, in: bundle)
        try writeInfoPlist(build: "92", in: bundle)

        // Opted in, or this would short-circuit before ever reaching the
        // no-writer branch it exists to test.
        XCTAssertEqual(try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "true"]), 0)
        XCTAssertTrue(bundle.launched)
    }

    /// A FAILED BINARY INSTALL MUST NOT LEAVE THE METADATA AHEAD OF IT. The
    /// launcher falls back to the previous binary there, so stamping the
    /// checkout's build number would describe code that is not running — the
    /// stale-bundle lie told in the other direction. Found by deck-reviewer.
    func testDoesNotRefreshWhenTheNewBinaryCouldNotBeInstalled() throws {
        let bundle = try makeBundle()
        let repo = try makeThrowawayCheckout()
        let marker = repo.appendingPathComponent("writer-ran")
        try installStubWriter(in: repo, marker: marker)
        try writeRepoPath(repo.path, in: bundle)
        try writeInfoPlist(build: "92", in: bundle)

        // Read-only, so the launcher cannot write `deck-bin.incoming` and takes
        // its could-not-install branch. Restored first in teardown, or the
        // bundle's own cleanup cannot remove the directory.
        let macOS = bundle.root.appendingPathComponent("Contents/MacOS")
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: macOS.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: macOS.path)

        // Opted in, or this would short-circuit before ever reaching the
        // install logic it exists to test.
        _ = try run(bundle, env: ["APP_AUTO_UPDATE_ENABLED": "true"])

        let log = try launcherLog(bundle)
        XCTAssertTrue(log.contains("could not install new binary"),
                      "the fixture must actually reach that branch:\n\(log)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "metadata must not be stamped ahead of the binary that will run")
        XCTAssertTrue(bundle.launched, "and the previous binary must still launch")
    }

    /// The writer itself, against the real checkout — the half the stub above
    /// deliberately does not exercise.
    func testTheWriterWritesEveryFileTheBundleNeeds() throws {
        let appDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-writer-\(UUID().uuidString)")
            .appendingPathComponent("Convivy Builder.app")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: appDir.deletingLastPathComponent())
        }

        let process = Process()
        process.executableURL = repoRoot.appendingPathComponent("Scripts/write-bundle-metadata.sh")
        process.arguments = [appDir.path, repoRoot.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let printed = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let fm = FileManager.default
        for path in ["Contents/Info.plist", "Contents/PkgInfo",
                     "Contents/Resources/repo-path", "Contents/Resources/Deck.icns",
                     "Contents/Resources/auto-update-opt-in"] {
            XCTAssertTrue(fm.fileExists(atPath: appDir.appendingPathComponent(path).path),
                          "the writer must produce \(path)")
        }

        // It prints the version and build it wrote, so make-app.sh and the
        // launcher both report the numbers that actually landed in the plist.
        let fields = printed.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(fields.count, 2, "expected 'VERSION BUILD', got \(printed)")
        let plist = try String(contentsOf: appDir.appendingPathComponent("Contents/Info.plist"),
                               encoding: .utf8)
        XCTAssertTrue(plist.contains("<string>\(fields[1])</string>"),
                      "the printed build must be the one written")

        // And nothing half-written is left where the app would read it.
        let contents = try fm.contentsOfDirectory(atPath: appDir.appendingPathComponent("Contents").path)
        XCTAssertFalse(contents.contains { $0.hasPrefix(".metadata.") },
                       "the writer must clean up its temporaries: \(contents)")
    }

    /// The SHIPPED flavor: what a bundle built for someone else's Mac gets.
    /// It must carry nothing that ties it back to this checkout — the test
    /// above already pins that omitting the flavor argument keeps writing
    /// both files, so this is the other side of that same branch.
    func testTheWriterOmitsCheckoutFilesForTheShippedFlavor() throws {
        let appDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-writer-shipped-\(UUID().uuidString)")
            .appendingPathComponent("Convivy Builder.app")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: appDir.deletingLastPathComponent())
        }

        let process = Process()
        process.executableURL = repoRoot.appendingPathComponent("Scripts/write-bundle-metadata.sh")
        process.arguments = [appDir.path, repoRoot.path, "shipped"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let fm = FileManager.default
        for path in ["Contents/Info.plist", "Contents/PkgInfo", "Contents/Resources/Deck.icns"] {
            XCTAssertTrue(fm.fileExists(atPath: appDir.appendingPathComponent(path).path),
                          "the shipped flavor must still get \(path) — only the checkout-coupling files are gated")
        }
        for path in ["Contents/Resources/repo-path", "Contents/Resources/auto-update-opt-in"] {
            XCTAssertFalse(fm.fileExists(atPath: appDir.appendingPathComponent(path).path),
                           "the shipped flavor must never write \(path)")
        }
    }

    /// The writer sets CFBundleName and CFBundleDisplayName to "Convivy Builder".
    /// The identifier, executable and icon file stay as they were, because the
    /// updater, the launcher and the install paths key on them.
    func testTheWriterNamesTheBundleConvivyBuilderAndKeepsItsIdentifiers() throws {
        let appDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-writer-names-\(UUID().uuidString)")
            .appendingPathComponent("Convivy Builder.app")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: appDir.deletingLastPathComponent())
        }

        let process = Process()
        process.executableURL = repoRoot.appendingPathComponent("Scripts/write-bundle-metadata.sh")
        process.arguments = [appDir.path, repoRoot.path, "shipped"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let data = try Data(contentsOf: appDir.appendingPathComponent("Contents/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleName"] as? String, "Convivy Builder")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Convivy Builder")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.convivy.deck")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "Deck")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "Deck")
    }

    /// An unrecognized flavor is refused rather than silently treated as one
    /// of the two real ones — the same "unrecognized is not the same as
    /// false" principle the auto-update flag tests above pin.
    func testTheWriterRejectsAnUnknownFlavor() throws {
        let appDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-writer-badflavor-\(UUID().uuidString)")
            .appendingPathComponent("Convivy Builder.app")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: appDir.deletingLastPathComponent())
        }

        let process = Process()
        process.executableURL = repoRoot.appendingPathComponent("Scripts/write-bundle-metadata.sh")
        process.arguments = [appDir.path, repoRoot.path, "bogus"]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        try process.run()
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0, "an unknown flavor must not be accepted")
        XCTAssertTrue(stderr.contains("flavor must be"), "it should say why it refused:\n\(stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: appDir.appendingPathComponent("Contents/Info.plist").path),
                       "a rejected flavor must not produce a partial bundle")
    }

    /// A `CFBundleVersion` carrying a double quote closes the AppleScript
    /// string literal `notify()` builds, and what follows is executed —
    /// deck-security-reviewer demonstrated `1" & (do shell script "…") & "`
    /// writing a file. Two things stop it now, and this pins the first: a build
    /// number that is not digits is not compared and never reaches a dialog.
    func testAHostileBuildNumberIsRefusedRatherThanInterpolated() throws {
        let bundle = try makeBundle()
        let repo = try makeThrowawayCheckout()
        let canary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-injection-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: canary) }
        try writeRepoPath(repo.path, in: bundle)
        try writeInfoPlist(
            build: "1\" &amp; (do shell script \"touch \(canary.path)\") &amp; \"",
            in: bundle)

        // DECK_NO_UI is deliberately NOT set here: the point is that osascript
        // would run for real, so the canary proves refusal rather than the
        // suppression every other test relies on. Opted in via the env var,
        // or this would short-circuit before ever reaching the build-number
        // check it exists to test.
        _ = try run(bundle, env: ["DECK_NO_UI": "0", "APP_AUTO_UPDATE_ENABLED": "true"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path),
                       "a CFBundleVersion carrying AppleScript must not execute")
        let log = try launcherLog(bundle)
        XCTAssertTrue(log.contains("not a build number"),
                      "it should say why it refused:\n\(log)")
        XCTAssertFalse(log.contains("bundle metadata stale"),
                       "nothing to compare against, so nothing to report stale")
    }

    /// The escaping itself, independent of who calls it. A caller nobody has
    /// written yet is the reason it lives in `notify` rather than at one site.
    func testTheDialogHelperEscapesAQuoteRatherThanClosingTheLiteral() throws {
        let launcher = try String(contentsOf: launcherSource, encoding: .utf8)
        XCTAssertTrue(launcher.contains("escape_applescript"),
                      "notify/alert must escape what they paste into AppleScript")
        // Comments stripped first, indentation and all — the same trap the
        // sibling test above fell into. Prose about osascript is not a call to
        // it, and the reason this helper exists is discussed in a comment
        // directly beside it.
        let code = launcher
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        for line in code where line.contains("osascript") {
            XCTAssertTrue(line.contains("escape_applescript"),
                          "an osascript line pasting a raw value: \(line)")
        }
    }

    // MARK: - The bundle layout make-app.sh has to produce

    /// The launcher and the packaging script are one mechanism split across two
    /// files: the launcher swaps `deck-bin` and reads `Resources/repo-path`, and
    /// nothing but `make-app.sh` puts either of them there.
    func testPackagingScriptInstallsWhatTheLauncherReads() throws {
        // Comments stripped first: the paths below are also discussed in
        // make-app.sh's prose, and a test that a comment satisfies asserts
        // nothing about what the script does.
        let script = try String(contentsOf: repoRoot.appendingPathComponent("Scripts/make-app.sh"),
                                encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")

        XCTAssertTrue(script.contains("MacOS/deck-bin"),
                      "make-app.sh must install the compiled binary as deck-bin")
        XCTAssertTrue(script.contains("Scripts/deck-launcher.sh"),
                      "make-app.sh must install the launcher as the bundle executable")
        // `Resources/repo-path` moved into write-bundle-metadata.sh, which
        // make-app.sh calls and the launcher calls too — one definition rather
        // than a copy in each. So the assertion follows it there, and checks
        // the call still exists here.
        XCTAssertTrue(script.contains("write-bundle-metadata.sh"),
                      "make-app.sh must call the script that writes the bundle's data")
        let writer = try String(
            contentsOf: repoRoot.appendingPathComponent("Scripts/write-bundle-metadata.sh"),
            encoding: .utf8)
        XCTAssertTrue(writer.contains("repo-path"),
                      "something must record the checkout the launcher updates from")
        XCTAssertFalse(writer.contains("MacOS/Deck\""),
                       "the writer must never replace the running launcher script")
    }

    /// `make-app.sh` opens with `rm -rf "$APP_DIR"`. Calling it from the launcher
    /// would delete the launcher mid-execution, and bash resumes a replaced
    /// script at a byte offset into the new content.
    func testLauncherNeverInvokesThePackagingScript() throws {
        let launcher = try String(contentsOf: launcherSource, encoding: .utf8)
        // Comments and user-facing messages name the script on purpose — one of
        // the launcher's notifications is "run ./Scripts/make-app.sh". What must
        // not exist is a line that RUNS it, so both are removed before looking:
        // comments, then the contents of every double-quoted string.
        let code = launcher
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                // Trimmed before the test, because an INDENTED comment is still
                // a comment — reading one as code failed this test for a comment
                // inside an `if` block that merely named the script.
                let uncommented = line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                    ? "" : String(line)
                return uncommented.replacingOccurrences(
                    of: "\"[^\"]*\"", with: "\"\"", options: .regularExpression)
            }
            .joined(separator: "\n")
        let callsIt = code.contains("make-app.sh")

        XCTAssertFalse(callsIt, "the launcher must never run make-app.sh — it would delete itself")
    }

    /// A bundle running `deck-launcher.sh` is a developer bundle by construction,
    /// and `make-app.sh` defaults to the `shipped` flavor, which `rm -rf`s the
    /// bundle and rebuilds it with no launcher, no `repo-path` and no auto-update
    /// marker. An operator who follows a bare `./Scripts/make-app.sh` from one of
    /// the launcher's own messages therefore loses self-update with nothing saying
    /// so. That makes a bare invocation in an operator-facing string a defect, not
    /// a style preference: the message must name the flavor that reinstalls a
    /// developer bundle. Comments are skipped, since they discuss the script
    /// without telling anyone to run it.
    func testLauncherMessagesNameTheDeveloperFlavorWhenTheyNameMakeApp() throws {
        let launcher = try String(contentsOf: launcherSource, encoding: .utf8)
        let required = "DECK_BUNDLE_FLAVOR=developer ./Scripts/make-app.sh"
        let quoted = try NSRegularExpression(pattern: "\"[^\"]*\"")

        var messages: [String] = []
        for line in launcher.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            for match in quoted.matches(in: text, range: range) {
                let literal = (text as NSString).substring(with: match.range)
                if literal.contains("make-app.sh") { messages.append(literal) }
            }
        }

        // Two messages name it today (the missing-binary alert and the
        // launcher-changed notification). Requiring both keeps this from passing
        // vacuously if the extraction stops matching them.
        XCTAssertEqual(messages.count, 2, "expected exactly the two operator messages, got \(messages)")
        for message in messages {
            XCTAssertTrue(message.contains(required),
                          "\(message) names make-app.sh without DECK_BUNDLE_FLAVOR=developer; "
                          + "the default shipped flavor would delete the launcher")
        }
    }

    func testLauncherIsSyntacticallyValid() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", launcherSource.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "bash -n rejected the launcher")
    }
}
