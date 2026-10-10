import XCTest

/// `Scripts/make-app.sh` produces one of two bundle flavors. `shipped` (the
/// default) is self-contained: installing it needs no checkout, no Swift
/// toolchain, and no git remote, and the bundle records no path back to a
/// working copy. `developer` is what the script always produced before this
/// split — a bundle that updates itself from the checkout it was built from
/// on a Dock click (`deck-launcher.sh`).
///
/// THESE TESTS NEVER TRIGGER A REAL SWIFT BUILD. A launcher test in this repo
/// once reached the update path and ran `swift build -c release` against a
/// contended `.build`, taking 609 seconds. `swift` is shadowed on PATH with a
/// stub that fabricates the build product for a `build` invocation and fails
/// anything else — that is enough to exercise make-app.sh's own flavor
/// branching, which is what this file is testing, without compiling anything.
final class BundleFlavorTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/DeckTests/BundleFlavorTests.swift
            .deletingLastPathComponent()          // Tests/DeckTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
    }

    // MARK: - Fixtures

    /// A throwaway git checkout carrying copies of the three scripts under
    /// test, so BASH_SOURCE-derived REPO_ROOT inside make-app.sh resolves to
    /// this disposable tree rather than the real worktree — nothing here
    /// touches this repo's own `.build` or `Scripts/`.
    private func makeThrowawayRepoForMakeApp() throws -> URL {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-makeapp-repo-\(UUID().uuidString)")
        let scripts = repo.appendingPathComponent("Scripts")
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repo) }

        for name in ["make-app.sh", "write-bundle-metadata.sh", "deck-launcher.sh"] {
            let dest = scripts.appendingPathComponent(name)
            try fm.copyItem(at: repoRoot.appendingPathComponent("Scripts/\(name)"), to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
        try "9.9.9-test\n".write(to: repo.appendingPathComponent("VERSION"),
                                 atomically: true, encoding: .utf8)

        // COPIED FROM THE REAL REPO ROOT RATHER THAN FABRICATED, so this
        // fixture also asserts both files exist there — make-app.sh copies
        // them into the bundle for Apache-2.0 section 4(d) and fails hard if
        // either is missing, which is deliberate: a bundle that ships without
        // its licence is worse than a build that stops.
        for name in ["LICENSE", "NOTICE"] {
            try fm.copyItem(at: repoRoot.appendingPathComponent(name),
                            to: repo.appendingPathComponent(name))
        }

        for args in [["init", "--quiet"],
                     ["-c", "user.email=t@t", "-c", "user.name=T", "add", "."],
                     ["-c", "user.email=t@t", "-c", "user.name=T", "commit", "--quiet", "-m", "seed"]] {
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

    /// A directory containing a `swift` that make-app.sh's `swift build`
    /// finds first on PATH. It fabricates `.build/<config>/Deck` instead of
    /// compiling anything for a `build` invocation, and fails everything
    /// else — including the icon render write-bundle-metadata.sh attempts,
    /// which is already designed to treat a failed icon as a non-fatal,
    /// cosmetic warning rather than something these tests need to satisfy.
    private func makeStubSwiftBinDir() throws -> URL {
        let fm = FileManager.default
        let binDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-stub-swift-\(UUID().uuidString)")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: binDir) }

        let script = """
            #!/bin/bash
            if [ "$1" = "build" ]; then
                CONFIG="release"
                PKGPATH="."
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -c) CONFIG="$2"; shift 2 ;;
                        --package-path) PKGPATH="$2"; shift 2 ;;
                        *) shift ;;
                    esac
                done
                mkdir -p "$PKGPATH/.build/$CONFIG"
                printf '#!/bin/bash\\necho stand-in-deck\\n' > "$PKGPATH/.build/$CONFIG/Deck"
                chmod +x "$PKGPATH/.build/$CONFIG/Deck"
                exit 0
            fi
            exit 1
            """
        let stub = binDir.appendingPathComponent("swift")
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return binDir
    }

    private func makeOutputDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-makeapp-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// `environment` overrides the defaults key by key, so a case can swap
    /// OUTPUT_DIR for a relative value or add CDPATH. `workingDirectory` is where
    /// a relative OUTPUT_DIR resolves. `scriptPath`, when set, runs the script as
    /// `bash <scriptPath>` from `workingDirectory`, so `BASH_SOURCE[0]` is the
    /// relative path the caller typed rather than the absolute one Process needs.
    @discardableResult
    private func runMakeApp(repo: URL, binDir: URL, outputDir: URL, flavor: String?,
                            environment overrides: [String: String] = [:],
                            workingDirectory: URL? = nil,
                            scriptPath: String? = nil) throws
        -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        if let scriptPath {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
        } else {
            process.executableURL = repo.appendingPathComponent("Scripts/make-app.sh")
        }
        process.currentDirectoryURL = workingDirectory
        var environment = [
            "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "OUTPUT_DIR": outputDir.path,
            "CONFIGURATION": "release",
            "HOME": NSTemporaryDirectory(),
        ]
        if let flavor { environment["DECK_BUNDLE_FLAVOR"] = flavor }
        environment.merge(overrides) { _, override in override }
        process.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    // MARK: - shipped is the default, and it is genuinely self-contained

    func testDefaultFlavorIsShippedAndOmitsEverythingThatTiesToACheckout() throws {
        let repo = try makeThrowawayRepoForMakeApp()
        let binDir = try makeStubSwiftBinDir()
        let outputDir = try makeOutputDir()

        let result = try runMakeApp(repo: repo, binDir: binDir, outputDir: outputDir, flavor: nil)
        XCTAssertEqual(result.status, 0, "make-app.sh failed:\n\(result.stdout)\n\(result.stderr)")

        let appDir = outputDir.appendingPathComponent("Convivy Builder.app")
        let fm = FileManager.default
        let executable = appDir.appendingPathComponent("Contents/MacOS/Deck")
        XCTAssertTrue(fm.fileExists(atPath: executable.path))
        XCTAssertTrue(fm.isExecutableFile(atPath: executable.path))
        let content = try String(contentsOf: executable, encoding: .utf8)
        XCTAssertTrue(content.contains("stand-in-deck"),
                      "Contents/MacOS/Deck must be the compiled binary itself, not a wrapper script")

        XCTAssertFalse(fm.fileExists(atPath: appDir.appendingPathComponent("Contents/MacOS/deck-bin").path),
                       "a shipped bundle must have only one executable")
        XCTAssertFalse(fm.fileExists(atPath: appDir.appendingPathComponent("Contents/Resources/repo-path").path),
                       "a shipped bundle must record no path back to a checkout")
        XCTAssertFalse(fm.fileExists(atPath: appDir.appendingPathComponent("Contents/Resources/auto-update-opt-in").path),
                       "a shipped bundle must carry nothing that could turn on self-update")

        // APACHE-2.0 SECTION 4(d) ATTACHES TO THE BUNDLE, NOT ONLY THE REPO,
        // and this flavor is the one that proves it matters: its whole point
        // is a bundle installable with no checkout, so the repository's own
        // copies are exactly what its user does not have.
        for name in ["LICENSE", "NOTICE"] {
            XCTAssertTrue(
                fm.fileExists(atPath: appDir.appendingPathComponent("Contents/Resources/\(name)").path),
                "a shipped bundle must carry \(name) — its user has no checkout to read it from")
        }

        XCTAssertTrue(result.stderr.contains("flavor: shipped"),
                      "the report must say which flavor was built:\n\(result.stderr)")
    }

    /// Shipwright's install-deck (shipwright#141) locates the bundle by the name
    /// "Convivy Builder.app" and checks two things about it: the executable is
    /// Contents/MacOS/Deck, and CFBundleIdentifier is com.convivy.deck. The
    /// rename must not move either, so this pins both on the bundle make-app.sh
    /// produces. The reverse direction is covered too: a bundle under the old
    /// name is not the one the installer looks for.
    func testBundleKeepsTheExecutableAndIdentifierTheInstallerChecks() throws {
        let repo = try makeThrowawayRepoForMakeApp()
        let binDir = try makeStubSwiftBinDir()
        let outputDir = try makeOutputDir()

        let result = try runMakeApp(repo: repo, binDir: binDir, outputDir: outputDir, flavor: nil)
        XCTAssertEqual(result.status, 0, "make-app.sh failed:\n\(result.stdout)\n\(result.stderr)")

        let fm = FileManager.default
        let appDir = outputDir.appendingPathComponent("Convivy Builder.app")
        XCTAssertTrue(fm.fileExists(atPath: appDir.path), "the bundle must be named Convivy Builder.app")
        XCTAssertFalse(fm.fileExists(atPath: outputDir.appendingPathComponent("Deck.app").path),
                       "no bundle may be produced under the old name")

        let executable = appDir.appendingPathComponent("Contents/MacOS/Deck")
        XCTAssertTrue(fm.isExecutableFile(atPath: executable.path),
                      "the installer expects the executable at Contents/MacOS/Deck")

        let data = try Data(contentsOf: appDir.appendingPathComponent("Contents/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.convivy.deck",
                       "the installer keys on CFBundleIdentifier, which the rename must not change")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "Deck")
    }

    // MARK: - The output contract: stdout is the bundle path, stderr is for humans

    /// Another crew's installer runs `APP="$(./Scripts/make-app.sh)"`. That only
    /// works if stdout holds the path and nothing else, so this pins the stream
    /// split from outside, against the real script and a real assembled bundle.
    func testStdoutIsExactlyOneLineNamingTheAssembledBundle() throws {
        let repo = try makeThrowawayRepoForMakeApp()
        let binDir = try makeStubSwiftBinDir()
        let outputDir = try makeOutputDir()

        let result = try runMakeApp(repo: repo, binDir: binDir, outputDir: outputDir, flavor: nil)
        XCTAssertEqual(result.status, 0, "make-app.sh failed:\n\(result.stdout)\n\(result.stderr)")

        XCTAssertTrue(result.stdout.hasSuffix("\n"), "the path line must be newline-terminated")
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()  // the empty piece after the terminating newline
        XCTAssertEqual(lines.count, 1,
                       "stdout must carry exactly one line, the bundle path:\n\(result.stdout)")

        let path = String(lines.first ?? "")
        XCTAssertTrue(path.hasPrefix("/"), "the path must be absolute: \(path)")
        XCTAssertTrue(path.hasSuffix("/Convivy Builder.app"), "the path must name Convivy Builder.app: \(path)")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      "the path must exist: \(path)")
        XCTAssertTrue(isDirectory.boolValue, "the path must be a directory: \(path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(path)/Contents/Info.plist"),
                      "the path must be the assembled bundle, not merely a directory: \(path)")
    }

    /// The other direction. Every progress line is on stderr, and none of them
    /// leaks onto stdout, where a caller reading the path would swallow it.
    func testProgressReportGoesToStderrAndNotStdout() throws {
        let repo = try makeThrowawayRepoForMakeApp()
        let binDir = try makeStubSwiftBinDir()
        let outputDir = try makeOutputDir()

        let result = try runMakeApp(repo: repo, binDir: binDir, outputDir: outputDir, flavor: nil)
        XCTAssertEqual(result.status, 0, "make-app.sh failed:\n\(result.stdout)\n\(result.stderr)")

        for line in ["flavor: shipped", "version 9.9.9-test", "unsigned"] {
            XCTAssertTrue(result.stderr.contains(line),
                          "expected '\(line)' on stderr:\n\(result.stderr)")
            XCTAssertFalse(result.stdout.contains(line),
                           "'\(line)' must not reach stdout, the caller's data channel:\n\(result.stdout)")
        }
        XCTAssertFalse(result.stdout.contains("==>"),
                       "no progress marker may reach stdout:\n\(result.stdout)")
    }

    /// CI passes a relative OUTPUT_DIR, and the contract promises an absolute
    /// path either way. Run from a working directory the caller controls, so a
    /// relative value has something to resolve against.
    func testARelativeOutputDirIsReportedAsAnAbsolutePath() throws {
        let repo = try makeThrowawayRepoForMakeApp()
        let binDir = try makeStubSwiftBinDir()
        let workDir = try makeOutputDir()

        let process = Process()
        process.executableURL = repo.appendingPathComponent("Scripts/make-app.sh")
        process.currentDirectoryURL = workDir
        process.environment = [
            "PATH": "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "OUTPUT_DIR": "relative-out",
            "CONFIGURATION": "release",
            "HOME": NSTemporaryDirectory(),
        ]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let path = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
        XCTAssertTrue(path.hasPrefix("/"), "a relative OUTPUT_DIR must still be reported absolute: \(path)")
        XCTAssertTrue(path.hasSuffix("/relative-out/Convivy Builder.app"), path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(path)/Contents/Info.plist"), path)
    }

    /// An exported CDPATH must not change which directory the script resolves.
    /// With CDPATH set, `cd` looks a relative target up under each CDPATH entry
    /// first and, when it lands there, prints the directory to stdout. A decoy
    /// tree that mirrors the relative OUTPUT_DIR makes both halves visible: the
    /// captured path would name the decoy rather than the bundle just built, and
    /// stdout would carry a second line.
    func testCDPATHDoesNotChangeOrDuplicateTheReportedBundlePath() throws {
        let repo = try makeThrowawayRepoForMakeApp()
        let binDir = try makeStubSwiftBinDir()
        let workDir = try makeOutputDir()
        let decoyRoot = try makeOutputDir()
        let decoyBundle = decoyRoot.appendingPathComponent("relative-out/Convivy Builder.app")
        try FileManager.default.createDirectory(at: decoyBundle, withIntermediateDirectories: true)

        let result = try runMakeApp(repo: repo, binDir: binDir, outputDir: workDir, flavor: nil,
                                    environment: ["OUTPUT_DIR": "relative-out", "CDPATH": decoyRoot.path],
                                    workingDirectory: workDir)
        XCTAssertEqual(result.status, 0, "make-app.sh failed:\n\(result.stdout)\n\(result.stderr)")

        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        XCTAssertEqual(lines.count, 1,
                       "stdout must carry exactly one line even with CDPATH set:\n\(result.stdout)")

        // Compare on the resolved path: NSTemporaryDirectory sits under /var,
        // a symlink to /private/var, and `pwd` reports whichever the shell saw.
        let reported = URL(fileURLWithPath: String(lines.first ?? "")).resolvingSymlinksInPath().path
        let built = workDir.appendingPathComponent("relative-out/Convivy Builder.app").resolvingSymlinksInPath().path
        XCTAssertEqual(reported, built, "the reported path must be the bundle that was built, not the CDPATH decoy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(reported)/Contents/Info.plist"),
                      "the reported path must hold the assembled bundle: \(reported)")
    }

    /// The same hazard one step earlier. Run as a relative path, the script's
    /// own directory is `Scripts` and REPO_ROOT is `Scripts/..`, which CDPATH
    /// resolves under a decoy that has a `Scripts` directory. Unfixed, REPO_ROOT
    /// becomes the decoy and the script cannot find the files it copies.
    func testCDPATHDoesNotRedirectRepoRoot() throws {
        let repo = try makeThrowawayRepoForMakeApp()
        let binDir = try makeStubSwiftBinDir()
        let outputDir = try makeOutputDir()
        let decoyRoot = try makeOutputDir()
        try FileManager.default.createDirectory(
            at: decoyRoot.appendingPathComponent("Scripts"), withIntermediateDirectories: true)

        let result = try runMakeApp(repo: repo, binDir: binDir, outputDir: outputDir, flavor: nil,
                                    environment: ["CDPATH": decoyRoot.path],
                                    workingDirectory: repo, scriptPath: "Scripts/make-app.sh")
        XCTAssertEqual(result.status, 0, "make-app.sh failed:\n\(result.stdout)\n\(result.stderr)")
        XCTAssertEqual(result.stdout.split(separator: "\n").count, 1,
                       "stdout must carry exactly one line even with CDPATH set:\n\(result.stdout)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDir.appendingPathComponent("Convivy Builder.app/Contents/Resources/LICENSE").path),
            "the bundle must be assembled from the repo, not the CDPATH decoy")
    }

    // MARK: - developer is still exactly what a working checkout needs

    func testDeveloperFlavorViaEnvVarProducesAllThreeCouplingArtifacts() throws {
        let repo = try makeThrowawayRepoForMakeApp()
        let binDir = try makeStubSwiftBinDir()
        let outputDir = try makeOutputDir()

        let result = try runMakeApp(repo: repo, binDir: binDir, outputDir: outputDir, flavor: "developer")
        XCTAssertEqual(result.status, 0, "make-app.sh failed:\n\(result.stdout)\n\(result.stderr)")

        let appDir = outputDir.appendingPathComponent("Convivy Builder.app")
        let fm = FileManager.default
        let launcher = appDir.appendingPathComponent("Contents/MacOS/Deck")
        let binary = appDir.appendingPathComponent("Contents/MacOS/deck-bin")

        XCTAssertTrue(fm.fileExists(atPath: launcher.path))
        let launcherContent = try String(contentsOf: launcher, encoding: .utf8)
        XCTAssertTrue(launcherContent.contains("BUNDLE_MACOS="),
                      "the developer bundle's executable must be the launcher script, not the binary")

        XCTAssertTrue(fm.fileExists(atPath: binary.path))
        let binaryContent = try String(contentsOf: binary, encoding: .utf8)
        XCTAssertTrue(binaryContent.contains("stand-in-deck"),
                      "deck-bin must be the compiled product")

        for path in ["Contents/Resources/repo-path", "Contents/Resources/auto-update-opt-in"] {
            XCTAssertTrue(fm.fileExists(atPath: appDir.appendingPathComponent(path).path),
                          "the developer bundle must still get \(path)")
        }

        XCTAssertTrue(result.stderr.contains("flavor: developer"),
                      "the report must say which flavor was built:\n\(result.stderr)")
    }

    // MARK: - An unrecognized flavor fails before anything is built

    func testInvalidFlavorFailsBeforeBuilding() throws {
        let repo = try makeThrowawayRepoForMakeApp()
        let binDir = try makeStubSwiftBinDir()
        let outputDir = try makeOutputDir()

        let result = try runMakeApp(repo: repo, binDir: binDir, outputDir: outputDir, flavor: "bogus")

        XCTAssertNotEqual(result.status, 0, "an unrecognized flavor must not be accepted")
        XCTAssertTrue(result.stderr.contains("DECK_BUNDLE_FLAVOR must be"),
                      "it should say why it refused:\n\(result.stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("Convivy Builder.app").path),
                       "a rejected flavor must not produce a partial bundle")
    }

    // MARK: - The requirement's real claim: it launches without a checkout

    /// Everything above proves the shipped bundle's FILES are absent. This
    /// proves the actual behaviour the requirement is about: the assembled
    /// bundle, moved away from the build tree with its source checkout
    /// deleted entirely, still launches. Nothing here can be a wrapper script
    /// that could go looking for a checkout, because the shipped flavor
    /// never installs one.
    func testShippedBundleLaunchesWithNoCheckoutPresent() throws {
        let repo = try makeThrowawayRepoForMakeApp()
        let binDir = try makeStubSwiftBinDir()
        let outputDir = try makeOutputDir()

        let result = try runMakeApp(repo: repo, binDir: binDir, outputDir: outputDir, flavor: nil)
        XCTAssertEqual(result.status, 0, "make-app.sh failed:\n\(result.stdout)\n\(result.stderr)")

        let isolated = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-isolated-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: isolated) }

        let movedApp = isolated.appendingPathComponent("Convivy Builder.app")
        try FileManager.default.moveItem(at: outputDir.appendingPathComponent("Convivy Builder.app"), to: movedApp)
        // The checkout is gone entirely — not just unreadable, absent — so
        // there is nothing left anywhere on disk for the bundle to depend on.
        try FileManager.default.removeItem(at: repo)

        let launchHome = isolated.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: launchHome, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = movedApp.appendingPathComponent("Contents/MacOS/Deck")
        process.environment = ["HOME": launchHome.path, "PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = isolated
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0,
                       "a shipped bundle must launch with no checkout anywhere on disk")
    }
}
