import XCTest
@testable import Deck

/// Validation for `deck-open:` URL refs.
///
/// `DeckOpenRef.validate` is a `nonisolated static func` that runs without
/// WebKit or a window — same convention as `SessionPaneModel.shouldRender` and
/// `SessionAgent.renderArguments`. Coverage here is the only check that the
/// intercept in `ConversationWebView` never routes a bad ref to a real file.
final class DeckOpenRefValidationTests: XCTestCase {

    /// Stands in for a real install's Settings › Hosts, which is what
    /// `allowedPathRoots(hosts:)` now derives every non-scratchpad root
    /// from — there is no compiled default any more, so every test that
    /// exercises an account's home-directory path has to supply the host that admits it.
    private let testHosts = [
        HostEntry(name: "test-host", user: TestHost.user, address: "203.0.113.10"),
    ]
    private var testRoots: [String] { DeckOpenRef.allowedPathRoots(hosts: testHosts) }

    // MARK: - Full URL parsing

    func testValidKBURL() {
        let url = URL(string: "deck-open:?origin=kb&ref=deck%2Fspecs%2Fsession-pane")!
        guard case .kb(let id) = DeckOpenRef.validate(url, hosts: testHosts) else {
            return XCTFail("expected .kb, got nil")
        }
        XCTAssertEqual(id, "deck/specs/session-pane")
    }

    func testValidPathURL() {
        let path = "\(TestHost.homeRoot)/Convivy/vivy/README.md"
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "deck-open:?origin=path&ref=\(encoded)")!
        guard case .path(let p) = DeckOpenRef.validate(url, hosts: testHosts) else {
            return XCTFail("expected .path, got nil")
        }
        XCTAssertEqual(p, path)
    }

    func testUnknownOriginReturnsNil() {
        let url = URL(string: "deck-open:?origin=ftp&ref=deck%2Fspecs%2Fsession-pane")!
        XCTAssertNil(DeckOpenRef.validate(url, hosts: testHosts))
    }

    func testWrongSchemeReturnsNil() {
        let url = URL(string: "https://example.com?origin=kb&ref=deck%2Fspecs%2Fsession-pane")!
        XCTAssertNil(DeckOpenRef.validate(url, hosts: testHosts))
    }

    func testMissingOriginReturnsNil() {
        let url = URL(string: "deck-open:?ref=deck%2Fspecs%2Fsession-pane")!
        XCTAssertNil(DeckOpenRef.validate(url, hosts: testHosts))
    }

    func testMissingRefReturnsNil() {
        let url = URL(string: "deck-open:?origin=kb")!
        XCTAssertNil(DeckOpenRef.validate(url, hosts: testHosts))
    }

    func testEmptyQueryStringReturnsNil() {
        let url = URL(string: "deck-open:")!
        XCTAssertNil(DeckOpenRef.validate(url, hosts: testHosts))
    }

    func testKBWithMalformedIdReturnsNil() {
        let url = URL(string: "deck-open:?origin=kb&ref=deck%2Fspecs")!
        XCTAssertNil(DeckOpenRef.validate(url, hosts: testHosts))
    }

    func testPathWithRelativeRefReturnsNil() {
        let encoded = "relative/path.md"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "deck-open:?origin=path&ref=\(encoded)")!
        XCTAssertNil(DeckOpenRef.validate(url, hosts: testHosts))
    }

    func testPathOutsideAllowedRootReturnsNil() {
        let encoded = "/etc/passwd"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "deck-open:?origin=path&ref=\(encoded)")!
        XCTAssertNil(DeckOpenRef.validate(url, hosts: testHosts))
    }

    // MARK: - KB id validation

    func testKBIdAcceptsThreeSegments() {
        XCTAssertNotNil(DeckOpenRef.validateKBId("deck/specs/session-pane"))
        XCTAssertNotNil(DeckOpenRef.validateKBId("deck/specs/opening-a-file-from-the-session"))
        XCTAssertNotNil(DeckOpenRef.validateKBId("a/b/c"))
        XCTAssertNotNil(DeckOpenRef.validateKBId("abc123/def456/ghi789"))
    }

    func testKBIdRejectsFewerThanThreeSegments() {
        XCTAssertNil(DeckOpenRef.validateKBId("deck/specs"))
        XCTAssertNil(DeckOpenRef.validateKBId("deck"))
        XCTAssertNil(DeckOpenRef.validateKBId(""))
    }

    func testKBIdRejectsMoreThanThreeSegments() {
        XCTAssertNil(DeckOpenRef.validateKBId("deck/specs/session-pane/extra"))
    }

    func testKBIdRejectsUppercase() {
        XCTAssertNil(DeckOpenRef.validateKBId("Deck/Specs/session-pane"))
        XCTAssertNil(DeckOpenRef.validateKBId("deck/SPECS/session-pane"))
    }

    func testKBIdRejectsEmptySegments() {
        XCTAssertNil(DeckOpenRef.validateKBId("/specs/session-pane"))
        XCTAssertNil(DeckOpenRef.validateKBId("deck//session-pane"))
        XCTAssertNil(DeckOpenRef.validateKBId("deck/specs/"))
    }

    func testKBIdRejectsUnderscore() {
        XCTAssertNil(DeckOpenRef.validateKBId("deck/specs/session_pane"))
    }

    func testKBIdRejectsSlashTrailingNewline() {
        // Guard against the same \z vs $ issue SessionAgent caught with hexColour.
        XCTAssertNil(DeckOpenRef.validateKBId("deck/specs/session-pane\n"))
    }

    func testKBIdAllowsHyphens() {
        XCTAssertNotNil(DeckOpenRef.validateKBId("deck/specs/opening-a-file-from-the-session"))
        XCTAssertNotNil(DeckOpenRef.validateKBId("a-b/c-d/e-f"))
    }

    // MARK: - Path validation

    func testPathMustBeAbsolute() {
        XCTAssertNil(DeckOpenRef.validatePath("Users/\(TestHost.user)/file.md", allowedRoots: testRoots))
        XCTAssertNil(DeckOpenRef.validatePath("relative/path.md", allowedRoots: testRoots))
        // Tilde-relative paths are not absolute paths starting with /
        XCTAssertNil(DeckOpenRef.validatePath("~/file.md", allowedRoots: testRoots))
    }

    func testPathMustBeUnderAnAllowedRoot() {
        XCTAssertNil(DeckOpenRef.validatePath("/etc/passwd", allowedRoots: testRoots))
        XCTAssertNil(DeckOpenRef.validatePath("/tmp/evil.sh", allowedRoots: testRoots))
        XCTAssertNil(DeckOpenRef.validatePath("/Users/" + "other" + "/file.md", allowedRoots: testRoots))
        XCTAssertNil(DeckOpenRef.validatePath("\(TestHost.homeRoot)Extra/file.md", allowedRoots: testRoots))
    }

    func testPathTraversalThatEscapesRootIsRejected() {
        XCTAssertNil(DeckOpenRef.validatePath(
            "\(TestHost.homeRoot)/../../../etc/passwd", allowedRoots: testRoots))
        XCTAssertNil(DeckOpenRef.validatePath(
            "\(TestHost.homeRoot)/../../root/file", allowedRoots: testRoots))
    }

    func testPathTraversalThatStaysUnderRootIsNormalised() {
        let result = DeckOpenRef.validatePath(
            "\(TestHost.homeRoot)/Convivy/../Convivy/file.md", allowedRoots: testRoots)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "\(TestHost.homeRoot)/Convivy/file.md")
    }

    func testPathIsNormalisedBeforeRootCheck() {
        let result = DeckOpenRef.validatePath(
            "\(TestHost.homeRoot)/Convivy/deck/../hollis/file.md", allowedRoots: testRoots)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "\(TestHost.homeRoot)/Convivy/hollis/file.md")
    }

    func testValidPathsAreAccepted() {
        XCTAssertNotNil(DeckOpenRef.validatePath(
            "\(TestHost.homeRoot)/Convivy/vivy/README.md", allowedRoots: testRoots))
        XCTAssertNotNil(DeckOpenRef.validatePath(
            "\(TestHost.homeRoot)/Convivy/hollis/src/main.swift", allowedRoots: testRoots))
        XCTAssertNotNil(DeckOpenRef.validatePath(
            "\(TestHost.homeRoot)/Convivy/knowledge/projects/deck/specs/session-pane.md",
            allowedRoots: testRoots))
    }

    func testPathWithSpaceAndPunctuationIsAccepted() {
        // readFileArguments shell-quotes the path, so spaces and
        // metacharacters are safe. The validator now admits them.
        XCTAssertNotNil(DeckOpenRef.validatePath(
            "\(TestHost.homeRoot)/file with space.md", allowedRoots: testRoots))
        XCTAssertNotNil(DeckOpenRef.validatePath(
            "\(TestHost.homeRoot)/Library/Application Support/Convivy/file.md",
            allowedRoots: testRoots))
        XCTAssertNotNil(DeckOpenRef.validatePath(
            "\(TestHost.homeRoot)/Operator's Documents/file.md", allowedRoots: testRoots))
    }

    func testPathRejectsControlCharactersAndNewlines() {
        // Control characters corrupt log lines and are never in a user-visible path.
        XCTAssertNil(DeckOpenRef.validatePath("\(TestHost.homeRoot)/file\n.md", allowedRoots: testRoots))
        XCTAssertNil(DeckOpenRef.validatePath("\(TestHost.homeRoot)/file\r.md", allowedRoots: testRoots))
        XCTAssertNil(DeckOpenRef.validatePath("\(TestHost.homeRoot)/\0file.md", allowedRoots: testRoots))
    }

    // MARK: - Deriving roots from configured hosts

    /// The load-bearing behaviour change: no host configured means no
    /// `/Users/` root at all, and a `path` ref refuses — the same
    /// "unresolved resolves to nothing" posture #119 gave `SSHTarget.mini`.
    func testEmptyHostTableAdmitsNoUsersRootAndPathRefRefuses() {
        let roots = DeckOpenRef.allowedPathRoots(hosts: [])
        XCTAssertFalse(roots.contains { $0.hasPrefix("/Users/") },
                       "an empty host table must contribute no /Users/ root")
        XCTAssertNil(DeckOpenRef.validatePath("\(TestHost.homeRoot)/file.md", allowedRoots: roots))
    }

    /// Each configured host's own account name derives its own root — not
    /// one compiled-in operator's, and not every operator's at once.
    func testEachConfiguredHostDerivesItsOwnRoot() {
        let hosts = [
            HostEntry(name: "laptop", user: TestHost.secondaryUser, address: "203.0.113.5"),
            HostEntry(name: "mini", user: TestHost.user, address: "203.0.113.6"),
        ]
        let roots = DeckOpenRef.allowedPathRoots(hosts: hosts)
        XCTAssertNotNil(DeckOpenRef.validatePath("\(TestHost.secondaryHomeRoot)/notes.md", allowedRoots: roots))
        XCTAssertNotNil(DeckOpenRef.validatePath("\(TestHost.homeRoot)/notes.md", allowedRoots: roots))
        XCTAssertNil(DeckOpenRef.validatePath("/Users/" + "someoneElse" + "/notes.md", allowedRoots: roots))
    }

    /// Defense in depth: `allowedPathRoots` re-validates `entry.user` itself
    /// rather than trusting a `HostEntry` a future caller built by hand —
    /// the same "the gate holds regardless of who built it" posture
    /// `SessionAgent.arguments` takes with `SSHTarget`. A `user` that fails
    /// `validateHostUser` (contains a `/`, here) contributes no root, and
    /// critically does not widen the boundary through the literal string it
    /// would otherwise have produced.
    func testHostWithInvalidUserContributesNoRoot() {
        let hosts = [HostEntry(name: "bad", user: "../etc", address: "203.0.113.7")]
        let roots = DeckOpenRef.allowedPathRoots(hosts: hosts)
        XCTAssertFalse(roots.contains { $0.contains("..") })
        XCTAssertNil(DeckOpenRef.validatePath("/etc/passwd", allowedRoots: roots))
    }

    /// The scratchpad roots are unconditional — present whether or not any
    /// host is configured — since they are derived from `getuid()`, not from
    /// `hosts`.
    func testScratchpadRootsSurviveAnEmptyHostTable() {
        let uid = getuid()
        let roots = DeckOpenRef.allowedPathRoots(hosts: [])
        XCTAssertTrue(roots.contains("/private/tmp/claude-\(uid)/"))
        XCTAssertTrue(roots.contains("/tmp/claude-\(uid)/"))
    }

    // MARK: - Scratchpad root

    /// A real scratchpad directory the test owns end to end: created before
    /// the body runs, removed after, never the shared root itself.
    private func makeScratchpadSessionDir() throws -> String {
        let uid = getuid()
        let dir = "/private/tmp/claude-\(uid)/decktest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// A file that actually exists under the scratchpad root must be
    /// accepted. `standardizingPath` collapses `/private/tmp` to `/tmp` for
    /// exactly this case (existence-gated on the laptop), so the accept
    /// path exercised here is the `/tmp/claude-<uid>/` entry in
    /// `allowedPathRoots`, not the `/private/tmp` one.
    /// Mutation: remove the `/tmp/claude-\(uid)/` entry from
    /// `allowedPathRoots` and this fails, because the collapsed candidate no
    /// longer matches any remaining root.
    func testExistingScratchpadFileIsAccepted() throws {
        let dir = try makeScratchpadSessionDir()
        let file = dir + "/real.md"
        try "hello".write(toFile: file, atomically: true, encoding: .utf8)

        XCTAssertNotNil(DeckOpenRef.validatePath(file, allowedRoots: testRoots),
                        "a scratchpad file that actually exists must be accepted")
    }

    /// A path under the (existing) scratchpad root that does not itself
    /// exist locally is accepted, not rejected. `validatePath` runs on the
    /// laptop while every consumer opens the validated path over ssh on the
    /// mini, so a session-created scratchpad file the laptop has never seen
    /// is the ordinary case, not an edge case — the laptop can only ever
    /// observe it as "not there." Rejecting on local nonexistence would
    /// reject every real mini-only scratchpad link, which is the exact
    /// "scratchpad links are still dead" symptom this fix exists for.
    /// Mutation: reject when `standardizingPath` returns the unresolved
    /// `/private/tmp` spelling and this fails, since a phantom local path
    /// never collapses and always keeps that spelling.
    func testNonExistentScratchpadFileIsAccepted() throws {
        let dir = try makeScratchpadSessionDir()
        let phantom = dir + "/does-not-exist.md"

        XCTAssertNotNil(DeckOpenRef.validatePath(phantom, allowedRoots: testRoots),
                        "a scratchpad path with nothing behind it locally must still be accepted — it may be real on the mini")
    }

    /// Both spellings of the scratchpad root must match on their own, not
    /// only via the existence-gated collapse — a candidate can arrive in
    /// either spelling regardless of what standardizingPath does to it.
    /// Mutation: remove either `/private/tmp/claude-\(uid)/` or
    /// `/tmp/claude-\(uid)/` from `allowedPathRoots` and the corresponding
    /// assertion fails.
    func testBothScratchpadSpellingsAreAccepted() {
        let uid = getuid()
        XCTAssertNotNil(DeckOpenRef.validatePath(
            "/private/tmp/claude-\(uid)/session-abc/scratchpad/notes.md", allowedRoots: testRoots),
            "the /private/tmp spelling must be accepted on its own")
        XCTAssertNotNil(DeckOpenRef.validatePath(
            "/tmp/claude-\(uid)/session-abc/scratchpad/notes.md", allowedRoots: testRoots),
            "the /tmp spelling must be accepted on its own")
    }

    /// Pins the property that makes the root-symlink widening (the security
    /// finding on the reverted approach) structurally impossible now:
    /// `standardizingPath` does not follow a directory-level symlink the way
    /// `resolvingSymlinksInPath` does. The reverted code resolved each
    /// allowed root through `resolvingSymlinksInPath` at comparison time, so
    /// a session that replaced its own scratchpad root directory with a
    /// symlink to `/` made every absolute path pass containment.
    /// `validatePath` no longer calls `resolvingSymlinksInPath` at all — this
    /// test doesn't touch the real, shared, permanent scratchpad root (doing
    /// so would risk breaking a concurrently running session), so it proves
    /// the same property with a throwaway root+symlink pair instead: a path
    /// through a directory that has been replaced with a symlink to a
    /// sibling does not standardize to the sibling's own real path.
    /// Mutation: swap `standardizingPath` for `resolvingSymlinksInPath` on
    /// the assertion's input and it fails, because that call *does* follow
    /// the symlink and the two paths become equal.
    func testReplacingADirectoryWithASymlinkDoesNotChangeItsStandardizedPath() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("decktest-rootsymlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        let real = base.appendingPathComponent("real-target")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("unrelated.txt")
        try "unrelated".write(to: file, atomically: true, encoding: .utf8)

        let rootStandIn = base.appendingPathComponent("fake-root")
        try FileManager.default.createSymbolicLink(at: rootStandIn, withDestinationURL: real)

        let throughSymlink = rootStandIn.appendingPathComponent("unrelated.txt").path
        XCTAssertNotEqual((throughSymlink as NSString).standardizingPath, file.path,
            "standardizingPath must not resolve a directory-level symlink — that resolution is exactly what let a replaced allowed-root directory redirect containment")
    }

    func testTraversalOutOfScratchpadIsRejected() {
        let uid = getuid()
        // Two levels up escapes /private/tmp/claude-<uid>/ entirely.
        XCTAssertNil(DeckOpenRef.validatePath(
            "/private/tmp/claude-\(uid)/../../etc/passwd", allowedRoots: testRoots))
        // One level up lands in /private/tmp/ — not under any allowed root.
        XCTAssertNil(DeckOpenRef.validatePath(
            "/private/tmp/claude-\(uid)/../evil/escape", allowedRoots: testRoots))
    }

    func testScratchpadSiblingNearMissIsRejected() {
        let uid = getuid()
        // A directory named claude-<uid>extra must not fool the prefix check;
        // the trailing / in the root prevents this.
        XCTAssertNil(DeckOpenRef.validatePath(
            "/private/tmp/claude-\(uid)extra/file.md", allowedRoots: testRoots))
    }

    func testScratchpadWithDifferentUidIsRejected() {
        // uid 0 (root) will never equal the test process uid; this exercises the
        // uid-mismatch branch in validatePath without needing to manipulate state.
        let alienUid: UInt32 = 0
        XCTAssertNotEqual(alienUid, getuid(),
                          "test assumes uid 0 differs from the test process uid")
        XCTAssertNil(DeckOpenRef.validatePath(
            "/private/tmp/claude-\(alienUid)/session/scratchpad.md", allowedRoots: testRoots),
                     "a scratchpad path with a uid other than getuid() must be rejected")
    }

    /// A foreign-uid scratchpad path is never rejected on the file-existence
    /// grounds the two spellings above exist for — the regex matches the uid
    /// straight out of the candidate string, before any root comparison.
    /// Captures real stdout rather than asserting on rejection alone,
    /// because rejection alone would also pass if the diagnostic branch were
    /// deleted outright.
    /// Mutation: delete the `if embedded Uid != "\(getuid())"` guard's body
    /// (keep the branch reachable but drop the `print`) and this fails while
    /// `testScratchpadWithDifferentUidIsRejected` above keeps passing —
    /// which is exactly why that test alone isn't sufficient coverage.
    func testScratchpadUidMismatchDiagnosticStillPrints() throws {
        let alienUid: UInt32 = 0
        let path = "/private/tmp/claude-\(alienUid)/session/scratchpad.md"

        let pipe = Pipe()
        let savedStdout = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        _ = DeckOpenRef.validatePath(path, allowedRoots: testRoots)

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(savedStdout, STDOUT_FILENO)
        close(savedStdout)

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("scratchpad uid mismatch"),
                     "the uid-mismatch diagnostic must still print for a foreign-uid scratchpad path")
    }

    // MARK: - Allowed roots invariants

    func testAllowedRootsIsNonEmpty() {
        // Non-empty even with no host configured — the scratchpad roots are
        // unconditional. See testEmptyHostTableAdmitsNoUsersRootAndPathRefRefuses
        // for the home-root-specific half of this invariant.
        XCTAssertFalse(DeckOpenRef.allowedPathRoots(hosts: []).isEmpty)
    }

    /// Every root must end with `/` so the prefix check cannot match a sibling
    /// directory with a longer name (e.g. an `Extra`-suffixed sibling under the same root).
    func testAllAllowedRootsAreAbsoluteAndEndWithSlash() {
        for root in DeckOpenRef.allowedPathRoots(hosts: testHosts) {
            XCTAssertTrue(root.hasPrefix("/"), "\(root) must be an absolute path")
            XCTAssertTrue(root.hasSuffix("/"), "\(root) must end with / to prevent prefix collision")
        }
    }

    // MARK: - deck-open scheme safety

    /// `deck-open:` is an internal command and must never reach NSWorkspace.
    /// It must not appear in the allowlist that ExternalLink uses.
    func testDeckOpenIsNotInExternalLinkAllowedSchemes() {
        XCTAssertFalse(ExternalLink.allowedSchemes.contains("deck-open"),
                       "deck-open is internal and must never be dispatched to NSWorkspace")
    }
}

/// argv emitted by `WorkingCopyStore` — the shape check, without a real ssh hop.
///
/// Mirrors the pattern in `SessionAgentTests` for `arguments(session:verb:)`:
/// the functions are `static` so they can be called without any infrastructure.
final class WorkingCopyStoreArgvTests: XCTestCase {

    func testLibraryDocumentArgvCarriesControlMaster() {
        let args = WorkingCopyStore.libraryDocumentArguments(
            target: TestHost.target,
            kbId: "deck/specs/session-pane",
            controlPath: "/tmp/deck-cm-%C"
        )
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("ServerAliveInterval=15"))
    }

    func testLibraryDocumentUsesTheGivenTarget() {
        let args = WorkingCopyStore.libraryDocumentArguments(
            target: TestHost.target, kbId: "deck/specs/session-pane")
        XCTAssertTrue(args.contains("\(TestHost.user)@\(TestHost.address)"))
    }

    func testLibraryDocumentRemoteCommandCarriesTheDocIdAndProtocolHeader() {
        // The Library refuses every request with no `Library-Protocol`
        // header (`protocol.py:negotiate`), so a command missing it would
        // 400 on every fetch rather than serve the document.
        let command = WorkingCopyStore.libraryDocumentRemoteCommand(kbId: "deck/specs/session-pane")
        XCTAssertTrue(command.contains("/reference/documents/deck/specs/session-pane"))
        XCTAssertTrue(command.contains("Library-Protocol: 1"))
        // The Authorization header still gets built — inside the heredoc
        // curl reads over stdin, not as a `-H` argument. See the two tests
        // below for the property that actually matters: no `-H` element
        // carries it, and no argv token in the ssh-visible shape is the
        // token itself.
        XCTAssertTrue(command.contains("Authorization: Bearer"))
        XCTAssertTrue(command.contains(WorkingCopyStore.libraryTokenFile))
    }

    /// PINS THE FIX, NOT THE OLD DEFECT. This command used to build the
    /// header as `-H "Authorization: Bearer $(cat …)"`: the `$(…)` ran on
    /// the mini, but its result then became a literal element of curl's own
    /// argv there — readable by every account on that box via `ps` for the
    /// life of the request (the mini is multi-tenant, ADR-0002). The fix
    /// moves the header into curl's `--config -`, read over its own stdin
    /// from a heredoc the remote shell expands before curl ever sees it, so
    /// the header text never has to survive as one of curl's own arguments.
    func testTheAuthorizationHeaderIsNeverBuiltAsAnHArgument() {
        let command = WorkingCopyStore.libraryDocumentRemoteCommand(kbId: "deck/specs/session-pane")
        XCTAssertFalse(command.contains("-H \"Authorization"))
        XCTAssertFalse(command.contains("-H 'Authorization"))
    }

    /// The header line carrying the token must be reachable only through
    /// `--config -` (curl reading it over stdin, off argv), never through a
    /// bare `-H` flag sitting in the part of the command ssh hands to the
    /// remote shell as ordinary argv text.
    func testTheAuthorizationHeaderIsOnlyReachableThroughCurlConfigOverStdin() {
        let command = WorkingCopyStore.libraryDocumentRemoteCommand(kbId: "deck/specs/session-pane")
        XCTAssertTrue(command.contains("--config -"),
                      "the header must arrive over curl's own stdin, not argv")
        guard let headerLine = command.split(separator: "\n")
            .first(where: { $0.contains("Authorization: Bearer") }) else {
            return XCTFail("expected a header line carrying Authorization: Bearer")
        }
        // That line is heredoc BODY (stdin content for curl), not part of
        // the argv-shaped prefix before `<<EOF`. Splitting on the heredoc
        // marker confirms the header line falls after it, on the stdin side.
        guard let heredocRange = command.range(of: "<<EOF") else {
            return XCTFail("expected an unquoted heredoc marker")
        }
        let stdinPortion = command[heredocRange.upperBound...]
        XCTAssertTrue(stdinPortion.contains(headerLine))
    }

    func testLibraryDocumentRemoteCommandFallsBackToTheDefaultLoopbackPort() {
        let command = WorkingCopyStore.libraryDocumentRemoteCommand(kbId: "deck/specs/session-pane")
        XCTAssertTrue(command.contains("LIBRARY_BASE_URL:-http://127.0.0.1:8100"))
    }

    func testLibraryDocumentRemoteCommandDoesNotFailTheTransferOnANonSuccessStatus() {
        // No `-f`/`--fail`: a 404 or 403 has to reach `fetch` as a status
        // `curl` recorded on stdout, not as a nonzero exit `SessionAgent.run`
        // turns into a generic transport error indistinguishable from the
        // connection itself failing.
        let command = WorkingCopyStore.libraryDocumentRemoteCommand(kbId: "deck/specs/session-pane")
        XCTAssertFalse(command.contains(" -f "))
        XCTAssertFalse(command.contains("--fail"))
    }

    func testReadFileArgvCarriesControlMasterAndPath() {
        let args = WorkingCopyStore.readFileArguments(
            target: TestHost.target,
            path: "\(TestHost.homeRoot)/Convivy/file.md",
            controlPath: "/tmp/deck-cm-%C"
        )
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("ServerAliveInterval=15"))
        XCTAssertEqual(args.suffix(3),
                       ["session-agent", "read-file", "'\(TestHost.homeRoot)/Convivy/file.md'"])
    }

    func testReadFileNeverFallsBackToABareCat() {
        // `cat` follows a symlink on the mini that Deck's own string check on
        // the laptop cannot see. The whole point of the verb is that the open
        // and the containment check are one syscall, so a read composed as
        // `cat` again would silently give that back.
        let args = WorkingCopyStore.readFileArguments(
            target: TestHost.target, path: "\(TestHost.homeRoot)/file.md")
        XCTAssertFalse(args.contains("cat"))
    }

    func testReadFileShellQuotesPathWithSpace() {
        let args = WorkingCopyStore.readFileArguments(
            target: TestHost.target,
            path: "\(TestHost.homeRoot)/Library/Application Support/file.md",
            controlPath: "/tmp/deck-cm-%C"
        )
        XCTAssertEqual(args.last,
                       "'\(TestHost.homeRoot)/Library/Application Support/file.md'")
    }

    func testReadFileShellQuotesEmbeddedSingleQuote() {
        // An embedded ' becomes '\'' in POSIX single-quote escaping:
        // close the single-quoted string, backslash-escape the quote, reopen.
        let args = WorkingCopyStore.readFileArguments(
            target: TestHost.target,
            path: "\(TestHost.homeRoot)/Operator's Folder/file.md",
            controlPath: "/tmp/deck-cm-%C"
        )
        XCTAssertEqual(args.last, "'\(TestHost.homeRoot)/Operator'\\''s Folder/file.md'")
    }

    func testReadFileUsesTheGivenTarget() {
        let args = WorkingCopyStore.readFileArguments(
            target: TestHost.target, path: "\(TestHost.homeRoot)/file.md")
        XCTAssertTrue(args.contains("\(TestHost.user)@\(TestHost.address)"))
    }
}

/// `WorkingCopyStore.splitCurlStatusResponse` — pure, no ssh, no curl.
final class SplitCurlStatusResponseTests: XCTestCase {

    func testSplitsBodyAndStatusOnTheLastNewline() {
        let raw = "{\"body\":\"hello\"}\n200".data(using: .utf8)!
        let result = WorkingCopyStore.splitCurlStatusResponse(raw)
        XCTAssertEqual(result?.status, 200)
        XCTAssertEqual(result.map { String(data: $0.body, encoding: .utf8) } ?? nil,
                       "{\"body\":\"hello\"}")
    }

    func testSplitsOnTheLastNewlineEvenWhenTheBodyContainsOne() {
        // The Library's own encoder does not pretty-print, but this must not
        // assume that — a body with an embedded newline must not be mistaken
        // for the status line.
        let raw = "{\n  \"body\": \"hello\"\n}\n404".data(using: .utf8)!
        let result = WorkingCopyStore.splitCurlStatusResponse(raw)
        XCTAssertEqual(result?.status, 404)
        XCTAssertEqual(result.map { String(data: $0.body, encoding: .utf8) } ?? nil,
                       "{\n  \"body\": \"hello\"\n}")
    }

    func testReturnsNilForOutputWithNoNewline() {
        // No status line at all — a transport failure that never reached
        // curl's own write-out step, or an unexpectedly empty response.
        XCTAssertNil(WorkingCopyStore.splitCurlStatusResponse("200".data(using: .utf8)!))
    }

    func testReturnsNilWhenTheTrailingLineIsNotAStatusCode() {
        XCTAssertNil(WorkingCopyStore.splitCurlStatusResponse("body\nnot-a-status".data(using: .utf8)!))
    }
}

/// `WorkingCopyStore.libraryDocumentContent` — the read path's response
/// handling, and every failure mode it has to tell apart, pinned without an
/// ssh round trip.
final class LibraryDocumentContentTests: XCTestCase {

    private func curlOutput(status: Int, jsonBody: String) -> Data {
        (jsonBody + "\n\(status)").data(using: .utf8)!
    }

    func testExtractsTheBodyFieldOnA200() throws {
        let raw = curlOutput(status: 200, jsonBody: #"{"id":"deck/specs/x","body":"Hello"}"#)
        let content = try WorkingCopyStore.libraryDocumentContent(from: raw, kbId: "deck/specs/x")
        XCTAssertEqual(content, "Hello")
    }

    func testA404BecomesDocumentNotFound() {
        let raw = curlOutput(status: 404, jsonBody: #"{"error":"not found"}"#)
        XCTAssertThrowsError(
            try WorkingCopyStore.libraryDocumentContent(from: raw, kbId: "deck/specs/missing")
        ) { error in
            guard case WorkingCopyStore.FetchError.documentNotFound(let id) = error else {
                return XCTFail("expected .documentNotFound, got \(error)")
            }
            XCTAssertEqual(id, "deck/specs/missing")
        }
    }

    func testA403BecomesLibraryRefusedRatherThanDocumentNotFound() {
        // 403 and 404 mean different things to a caller — a document that
        // exists but this identity may not see it vs. one that plainly does
        // not — and the Library's own 404-for-both rule (contract §8) only
        // ever applies to actual not-found responses, not to every non-200.
        let raw = curlOutput(status: 403, jsonBody: #"{"error":"reference.read missing"}"#)
        XCTAssertThrowsError(
            try WorkingCopyStore.libraryDocumentContent(from: raw, kbId: "deck/specs/x")
        ) { error in
            guard case WorkingCopyStore.FetchError.libraryRefused(let status, let body) = error else {
                return XCTFail("expected .libraryRefused, got \(error)")
            }
            XCTAssertEqual(status, 403)
            XCTAssertTrue(body.contains("reference.read"))
        }
    }

    func testMalformedJSONBecomesUnexpectedResponse() {
        let raw = curlOutput(status: 200, jsonBody: "not json")
        XCTAssertThrowsError(
            try WorkingCopyStore.libraryDocumentContent(from: raw, kbId: "deck/specs/x")
        ) { error in
            guard case WorkingCopyStore.FetchError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }

    func testA200WithNoBodyFieldBecomesUnexpectedResponse() {
        // Confirms this does not fall back to `content`, `kb checkout`'s key
        // — the two routes do not share a response shape.
        let raw = curlOutput(status: 200, jsonBody: #"{"content":"Hello"}"#)
        XCTAssertThrowsError(
            try WorkingCopyStore.libraryDocumentContent(from: raw, kbId: "deck/specs/x")
        ) { error in
            guard case WorkingCopyStore.FetchError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }

    func testOutputWithNoStatusLineBecomesUnexpectedResponse() {
        XCTAssertThrowsError(
            try WorkingCopyStore.libraryDocumentContent(
                from: "not curl output at all".data(using: .utf8)!, kbId: "deck/specs/x")
        ) { error in
            guard case WorkingCopyStore.FetchError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }
}

/// `WorkingCopyStore.libraryDocumentMetadata` — the bead-progress pane's
/// read, same route and response shape as `LibraryDocumentContentTests`
/// above but reading `title`/`last_reviewed` instead of `body`.
final class LibraryDocumentMetadataTests: XCTestCase {

    private func curlOutput(status: Int, jsonBody: String) -> Data {
        (jsonBody + "\n\(status)").data(using: .utf8)!
    }

    func testExtractsTitleAndLastReviewedOnA200() throws {
        let raw = curlOutput(status: 200, jsonBody: #"""
        {"id":"deck/bead/deck","title":"Deck","last_reviewed":"2026-08-24","body":"..."}
        """#)
        let metadata = try WorkingCopyStore.libraryDocumentMetadata(from: raw, kbId: "deck/bead/deck")
        XCTAssertEqual(metadata.title, "Deck")
        XCTAssertEqual(metadata.lastReviewed, "2026-08-24")
    }

    /// A field costs itself — a document with no `last_reviewed` at all
    /// still yields a title, rather than the whole read failing.
    func testAMissingLastReviewedDegradesToNilRatherThanThrowing() throws {
        let raw = curlOutput(status: 200, jsonBody: #"{"id":"deck/bead/deck","title":"Deck"}"#)
        let metadata = try WorkingCopyStore.libraryDocumentMetadata(from: raw, kbId: "deck/bead/deck")
        XCTAssertEqual(metadata.title, "Deck")
        XCTAssertNil(metadata.lastReviewed)
    }

    func testA404BecomesDocumentNotFound() {
        let raw = curlOutput(status: 404, jsonBody: #"{"error":"not found"}"#)
        XCTAssertThrowsError(
            try WorkingCopyStore.libraryDocumentMetadata(from: raw, kbId: "deck/bead/missing")
        ) { error in
            guard case WorkingCopyStore.FetchError.documentNotFound(let id) = error else {
                return XCTFail("expected .documentNotFound, got \(error)")
            }
            XCTAssertEqual(id, "deck/bead/missing")
        }
    }

    func testMalformedJSONBecomesUnexpectedResponse() {
        let raw = curlOutput(status: 200, jsonBody: "not json")
        XCTAssertThrowsError(
            try WorkingCopyStore.libraryDocumentMetadata(from: raw, kbId: "deck/bead/deck")
        ) { error in
            guard case WorkingCopyStore.FetchError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }
}

/// HTML generation for the viewer pane, without WebKit or a window.
final class FileViewerPaneHTMLTests: XCTestCase {

    func testLoadingPageCarriesDataTheme() {
        let dark = FileViewerPane.loadingPage(appearance: .dark)
        XCTAssertTrue(dark.contains("data-theme=\"dark\""))

        let light = FileViewerPane.loadingPage(appearance: .light)
        XCTAssertTrue(light.contains("data-theme=\"light\""))
    }

    func testErrorPageCarriesDataTheme() {
        let page = FileViewerPane.errorPage("something broke", appearance: .dark)
        XCTAssertTrue(page.contains("data-theme=\"dark\""))
        XCTAssertTrue(page.contains("something broke"))
    }

    func testPageDoesNotContainPreferColorScheme() {
        // The shell is the appearance authority; panes must never self-decide.
        for appearance in [Appearance.light, .dark] {
            let page = FileViewerPane.loadingPage(appearance: appearance)
            XCTAssertFalse(page.contains("prefers-color-scheme"),
                           "viewer must not self-decide appearance via CSS media query")
        }
    }

    func testHTMLEscapingBlocksInjection() {
        let malicious = "<script>alert(1)</script>"
        let escaped = FileViewerPane.htmlEscape(malicious)
        XCTAssertFalse(escaped.contains("<script>"))
        XCTAssertTrue(escaped.contains("&lt;script&gt;"))
    }

    func testHTMLEscapingCoversAllFourEntities() {
        let input = "& < > \""
        let escaped = FileViewerPane.htmlEscape(input)
        XCTAssertEqual(escaped, "&amp; &lt; &gt; &quot;")
    }

    func testSharedStyleContainsDataThemeSelector() {
        XCTAssertTrue(viewerSharedStyle.contains("[data-theme=\"dark\"]"),
                      "dark variant must be selector-driven, not prefers-color-scheme")
    }

    // MARK: - Remote renderer dispatch

    /// A Markdown file opened from an absolute path must use the remote renderer
    /// so it matches the session pane's prose styling.
    func testMarkdownPathRefUsesRemoteRenderer() {
        let url = URL(fileURLWithPath: "/local/working-copy/file.md")
        let ref = DeckOpenRef.Origin.path(absolutePath: "\(TestHost.homeRoot)/Convivy/file.md")
        XCTAssertTrue(FileViewerPane.usesRemoteRenderer(url: url, ref: ref))
    }

    /// A KB ref always uses the remote renderer regardless of extension:
    /// `session-view --render-kb` produces the same self-contained HTML that
    /// `--render-file` does, so KB documents look like session messages rather
    /// than escaped monospace.
    func testKBRefUsesRemoteRenderer() {
        let url = URL(fileURLWithPath: "/local/working-copy/file.md")
        let ref = DeckOpenRef.Origin.kb(id: "deck/specs/session-pane")
        XCTAssertTrue(FileViewerPane.usesRemoteRenderer(url: url, ref: ref))
    }

    /// Non-Markdown files (source, images) use the local page generator regardless
    /// of origin.
    func testNonMarkdownPathRefDoesNotUseRemoteRenderer() {
        let url = URL(fileURLWithPath: "/local/working-copy/main.swift")
        let ref = DeckOpenRef.Origin.path(absolutePath: "\(TestHost.homeRoot)/Convivy/main.swift")
        XCTAssertFalse(FileViewerPane.usesRemoteRenderer(url: url, ref: ref))
    }

    /// An image path ref stays with the local page generator, which embeds the
    /// data as a base64 data URI so no network block needs to be relaxed.
    func testImagePathRefDoesNotUseRemoteRenderer() {
        let url = URL(fileURLWithPath: "/local/working-copy/screenshot.png")
        let ref = DeckOpenRef.Origin.path(absolutePath: "\(TestHost.homeRoot)/Convivy/screenshot.png")
        XCTAssertFalse(FileViewerPane.usesRemoteRenderer(url: url, ref: ref))
    }

    func testNilRefDoesNotUseRemoteRenderer() {
        let url = URL(fileURLWithPath: "/local/working-copy/file.md")
        XCTAssertFalse(FileViewerPane.usesRemoteRenderer(url: url, ref: nil))
    }

    /// When session-view exits non-zero for a KB render, the thrown error
    /// surfaces in the viewer's error state rather than a blank pane.
    ///
    /// The full path is: renderKB throws AgentError.failed → renderHTML
    /// throws → load/reRender catches → html = errorPage(…). The ssh call
    /// itself requires the mini, so this test pins the two reachable ends:
    /// that usesRemoteRenderer routes KB refs through the remote path (so
    /// errors can propagate), and that errorPage renders any thrown message.
    func testKBRenderNonZeroExitSurfacesInViewerErrorState() {
        let url = URL(fileURLWithPath: "/working-copy/doc.md")
        XCTAssertTrue(FileViewerPane.usesRemoteRenderer(
            url: url, ref: .kb(id: "deck/specs/session-pane")),
            "KB refs must go through the remote path so errors are not swallowed")

        let page = FileViewerPane.errorPage(
            "AgentError.failed(\"document not found\")", appearance: .light)
        XCTAssertTrue(page.contains("document not found"))
        XCTAssertTrue(page.contains("data-theme=\"light\""))
    }
}

/// Filename derivation for the viewer's download affordance.
///
/// `DeckOpenRef.suggestedFilename` is `nonisolated static`, so these tests run
/// without a window, WebKit, or the mini — same pattern as `DeckOpenRefValidationTests`.
final class ViewerDownloadFilenameTests: XCTestCase {

    // MARK: - path ref

    func testPathRefFilenameIsBasename() {
        let origin = DeckOpenRef.Origin.path(absolutePath: "\(TestHost.homeRoot)/Convivy/vivy/README.md")
        XCTAssertEqual(DeckOpenRef.suggestedFilename(for: origin), "README.md")
    }

    func testPathRefPreservesExtension() {
        let origin = DeckOpenRef.Origin.path(absolutePath: "\(TestHost.homeRoot)/Convivy/main.swift")
        XCTAssertEqual(DeckOpenRef.suggestedFilename(for: origin), "main.swift")
    }

    func testPathRefFilenameWithNoExtension() {
        let origin = DeckOpenRef.Origin.path(absolutePath: "\(TestHost.homeRoot)/Convivy/Makefile")
        XCTAssertEqual(DeckOpenRef.suggestedFilename(for: origin), "Makefile")
    }

    // MARK: - kb ref

    func testKBRefFilenameIsLastSegmentPlusMD() {
        let origin = DeckOpenRef.Origin.kb(id: "deck/specs/session-pane")
        XCTAssertEqual(DeckOpenRef.suggestedFilename(for: origin), "session-pane.md")
    }

    func testKBRefFilenameUsesLastSegmentOnly() {
        let origin = DeckOpenRef.Origin.kb(id: "deck/specs/opening-a-file-from-the-session")
        XCTAssertEqual(DeckOpenRef.suggestedFilename(for: origin), "opening-a-file-from-the-session.md")
    }

    /// A doc id with no slash uses the whole id as the name.
    func testKBRefFilenameWithNoSlash() {
        let origin = DeckOpenRef.Origin.kb(id: "standalone")
        XCTAssertEqual(DeckOpenRef.suggestedFilename(for: origin), "standalone.md")
    }

    /// A trailing slash must not produce an empty name segment.
    func testKBRefFilenameWithTrailingSlash() {
        let origin = DeckOpenRef.Origin.kb(id: "deck/specs/session-pane/")
        XCTAssertEqual(DeckOpenRef.suggestedFilename(for: origin), "session-pane.md")
    }

    // MARK: - empty / degenerate fallback

    /// An all-separator id (only slashes) falls back to a non-empty default.
    func testKBRefAllSeparatorsFallsBackToDefault() {
        let origin = DeckOpenRef.Origin.kb(id: "///")
        let name = DeckOpenRef.suggestedFilename(for: origin)
        XCTAssertFalse(name.isEmpty, "all-separator id must not produce an empty filename")
    }

    /// An empty kb id falls back to a non-empty default.
    func testKBRefEmptyIdFallsBackToDefault() {
        let origin = DeckOpenRef.Origin.kb(id: "")
        let name = DeckOpenRef.suggestedFilename(for: origin)
        XCTAssertFalse(name.isEmpty, "empty id must not produce an empty filename")
    }

    // MARK: - saveCopy

    /// A scratch directory that cleans itself up.
    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-savecopy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testSaveCopyWritesToAFreshDestination() throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("source.md")
        let destination = dir.appendingPathComponent("out.md")
        try "hello".write(to: source, atomically: true, encoding: .utf8)

        try DeckOpenRef.saveCopy(of: source, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "hello")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "the working copy must survive — this is a copy, not a move")
    }

    func testSaveCopyReplacesAnExistingDestination() throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("source.md")
        let destination = dir.appendingPathComponent("out.md")
        try "new".write(to: source, atomically: true, encoding: .utf8)
        try "old".write(to: destination, atomically: true, encoding: .utf8)

        try DeckOpenRef.saveCopy(of: source, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
    }

    /// The reason `saveCopy` exists. Removing the destination and copying over
    /// the gap loses the reader's file when the copy fails; staging and
    /// swapping leaves it intact.
    func testSaveCopyLeavesTheDestinationIntactWhenTheSourceCannotBeRead() throws {
        let dir = try makeScratch()
        let destination = dir.appendingPathComponent("out.md")
        try "precious".write(to: destination, atomically: true, encoding: .utf8)
        let missingSource = dir.appendingPathComponent("does-not-exist.md")

        XCTAssertThrowsError(try DeckOpenRef.saveCopy(of: missingSource, to: destination))

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "precious",
                       "a failed save must not destroy the file it was replacing")
    }

    func testSaveCopyLeavesNoStagingFileBehind() throws {
        let dir = try makeScratch()
        let source = dir.appendingPathComponent("source.md")
        let destination = dir.appendingPathComponent("out.md")
        try "hello".write(to: source, atomically: true, encoding: .utf8)

        try DeckOpenRef.saveCopy(of: source, to: destination)
        _ = try? DeckOpenRef.saveCopy(of: dir.appendingPathComponent("nope"), to: destination)

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".deck-save-") }
        XCTAssertTrue(leftovers.isEmpty, "staging files must not survive either path: \(leftovers)")
    }
}

/// `.task(id:)` identity for `FileViewerPane` and `EditorPane`.
///
/// #119 threaded `target` into both panes' load closures without adding it
/// to the task's identity, so switching from a session on one host to a
/// session on another that resolves to the same `Origin` (a KB doc id, a
/// shared namespace across hosts) left SwiftUI thinking nothing had changed
/// — the `@StateObject` survived, the task never refired, and the pane went
/// on showing the first host's content. `PaneLoadIdentity` is what both
/// panes now key `.task(id:)` on instead of `ref` alone; these tests pin
/// its equality rather than SwiftUI's scheduler, which nothing here can
/// drive directly.
final class PaneLoadIdentityTests: XCTestCase {
    private let ref = DeckOpenRef.Origin.kb(id: "deck/specs/session-pane")
    private let otherRef = DeckOpenRef.Origin.kb(id: "deck/specs/other-doc")

    func testDiffersWhenOnlyTheTargetDiffers() {
        XCTAssertNotEqual(
            PaneLoadIdentity(ref: ref, target: TestHost.target),
            PaneLoadIdentity(ref: ref, target: TestHost.secondaryTarget))
    }

    func testDiffersWhenOnlyTheRefDiffers() {
        XCTAssertNotEqual(
            PaneLoadIdentity(ref: ref, target: TestHost.target),
            PaneLoadIdentity(ref: otherRef, target: TestHost.target))
    }

    func testEqualWhenBothRefAndTargetMatch() {
        XCTAssertEqual(
            PaneLoadIdentity(ref: ref, target: TestHost.target),
            PaneLoadIdentity(ref: ref, target: TestHost.target))
    }
}

// MARK: - The `item` origin

/// `deck-open:?origin=item&ref=<id>` — the ref an item id arrives on when a
/// conversation links one. Its own class rather than an append to
/// `DeckOpenRefTests`, so nothing about where it sits is ambiguous.
final class DeckOpenRefItemTests: XCTestCase {

    private let testHosts: [HostEntry] = []

    func testValidItemURL() {
        let url = URL(string: "deck-open:?origin=item&ref=issue_01M0Y7PWHF2Z91BWM28V6NT4PE")!
        guard case .item(let id) = DeckOpenRef.validate(url, hosts: testHosts) else {
            return XCTFail("expected .item, got nil")
        }
        XCTAssertEqual(id, "issue_01M0Y7PWHF2Z91BWM28V6NT4PE")
    }

    func testAnItemURLWithNoRefIsRejected() {
        XCTAssertNil(DeckOpenRef.validate(URL(string: "deck-open:?origin=item")!, hosts: testHosts))
    }

    func testAnUnknownOriginIsRejected() {
        let url = URL(string: "deck-open:?origin=wat&ref=issue_01ABC")!
        XCTAssertNil(DeckOpenRef.validate(url, hosts: testHosts))
    }

    func testItemIdAcceptsTheIdShapesTheLibraryIssues() {
        for id in ["issue_01M0Y7PWHF2Z91BWM28V6NT4PE", "bug_01ABC", "course_01ABC",
                   "sig_01ABC", "a", "a.b-c_d"] {
            XCTAssertNotNil(DeckOpenRef.validateItemId(id), "should accept \(id)")
        }
    }

    func testItemIdRejectsEmptyAndOverLength() {
        XCTAssertNil(DeckOpenRef.validateItemId(""))
        XCTAssertNotNil(DeckOpenRef.validateItemId(String(repeating: "a", count: 128)))
        XCTAssertNil(DeckOpenRef.validateItemId(String(repeating: "a", count: 129)))
    }

    /// **The characters that would matter if one got through.** This ref
    /// reaches a URL embedded unquoted inside a double-quoted string inside an
    /// UNQUOTED heredoc (`LibraryClient.remoteGETCommand`), so a shell-active
    /// character here is command execution on the host as the operator.
    func testItemIdRejectsShellActiveAndPathCharacters() {
        for id in ["issue_$(id)", "issue_`id`", "issue_${HOME}", "issue_a b",
                   "issue_a\nb", "issue_a/b", "../etc/passwd", "issue_a;b",
                   "issue_a|b", "issue_a&b", "issue_a'b", "issue_a\"b",
                   "issue_a\\b", "issue_a*b"] {
            XCTAssertNil(DeckOpenRef.validateItemId(id), "should reject \(id)")
        }
    }

    /// **Makes the drift-detection real rather than asserted in a comment.**
    /// `validateItemId` MIRRORS `LibraryClient.validateLibraryId` rather than
    /// calling it, and a doc comment naming which is authoritative cannot stop
    /// the two diverging. Sweeping every printable ASCII character and
    /// asserting the two validators agree on each one does — if either charset
    /// is edited alone, this fails and names the character.
    func testTheItemIdCharsetMatchesTheLibraryClientsExactly() {
        for scalar in UInt8(0x20)...UInt8(0x7E) {
            let character = String(UnicodeScalar(scalar))
            let deckAccepts = DeckOpenRef.validateItemId(character) != nil
            let libraryAccepts = LibraryClient.validateLibraryId(character) != nil
            XCTAssertEqual(deckAccepts, libraryAccepts,
                           "charsets disagree on \(character.debugDescription): "
                           + "DeckOpenRef \(deckAccepts), LibraryClient \(libraryAccepts)")
        }
    }

    /// The length bound is part of the same mirror and drifts the same way.
    func testTheItemIdLengthBoundMatchesTheLibraryClients() {
        for count in [1, 128, 129] {
            let id = String(repeating: "a", count: count)
            XCTAssertEqual(DeckOpenRef.validateItemId(id) != nil,
                           LibraryClient.validateLibraryId(id) != nil,
                           "length bounds disagree at \(count)")
        }
    }
}
