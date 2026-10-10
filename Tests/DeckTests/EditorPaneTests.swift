import XCTest
@testable import Deck

/// Tests for phase 3's editor: the remote render verb, the atomic write back,
/// what the page is allowed to say to Swift, and what it is allowed to load.
///
/// None of these needs a browser, and that is deliberate rather than
/// convenient. `md-serial`'s own suite has no real browser in its path either,
/// which is precisely how a save that returned an empty document passed 606
/// corpus documents (knowledge #170, fixed in #175). What Deck CAN pin without
/// one is every decision Swift makes: where the bytes go, what shapes are
/// accepted, what navigations are refused. Those are pinned here. What happens
/// inside the page is the page's suite's job, and Deck should not pretend to
/// cover it.
final class EditorPaneTests: XCTestCase {

    /// Stands in for a real install's Settings › Hosts — `EditorPageBridge.policy`
    /// now takes the configured hosts explicitly rather than reading a
    /// compiled default, so every navigation-policy test needs one to admit
    /// the absolute-path refs this file already exercises.
    private let testHosts = [HostEntry(name: "test", user: TestHost.user, address: TestHost.address)]

    // MARK: - The render verb

    func testRenderEditorArgumentsNameTheVerbAndTheTheme() {
        let argv = SessionAgent.renderEditorArguments(
            target: TestHost.target, path: "\(TestHost.homeRoot)/notes.md", appearance: .dark,
            controlPath: "/tmp/cm")

        XCTAssertEqual(argv.last, "dark")
        guard let verbIndex = argv.firstIndex(of: "--render-editor") else {
            return XCTFail("no --render-editor in \(argv)")
        }
        XCTAssertEqual(argv[verbIndex + 1], "'\(TestHost.homeRoot)/notes.md'")
        XCTAssertEqual(argv[argv.count - 2], "--theme")
        XCTAssertTrue(argv.contains("session-view"))
    }

    func testRenderEditorSharesTheRenderControlMaster() {
        let argv = SessionAgent.renderEditorArguments(
            target: TestHost.target, path: "\(TestHost.homeRoot)/notes.md", appearance: .light,
            controlPath: "/tmp/cm")

        // The `-render` suffix is what keeps page renders off the terminal's
        // connection, so compression cannot leak onto interactive keystrokes.
        XCTAssertTrue(argv.contains("ControlPath=/tmp/cm-render"))
        XCTAssertTrue(argv.contains("-C"))
    }

    func testRenderEditorQuotesAPathWithASpace() {
        let argv = SessionAgent.renderEditorArguments(
            target: TestHost.target, path: "\(TestHost.homeRoot)/my notes.md", appearance: .light,
            controlPath: "/tmp/cm")
        let verbIndex = argv.firstIndex(of: "--render-editor")!
        XCTAssertEqual(argv[verbIndex + 1], "'\(TestHost.homeRoot)/my notes.md'")
    }

    // MARK: - The write back

    func testWriteBackNamesTheContainedWriteVerbAndOnlyTheTarget() {
        let argv = WorkingCopyStore.writeFileArguments(
            target: TestHost.target,
            path: "\(TestHost.homeRoot)/notes.md",
            controlPath: "/tmp/cm")

        XCTAssertEqual(argv.suffix(3),
                       ["session-agent", "write-file", "'\(TestHost.homeRoot)/notes.md'"])
    }

    func testWriteBackComposesNoRemoteShellLine() {
        let argv = WorkingCopyStore.writeFileArguments(
            target: TestHost.target,
            path: "\(TestHost.homeRoot)/Convivy/deck/notes.md")

        // The staging path Deck used to derive from the target's parent
        // directory is gone: `write-file` stages inside a directory it has
        // already opened one component at a time, so a symlinked parent
        // cannot redirect the write. Deck naming a second path again — or a
        // `&&` sequencing two commands — would put that derivation back.
        let joined = argv.joined(separator: " ")
        XCTAssertFalse(joined.contains("&&"))
        XCTAssertFalse(joined.contains("mv "))
        XCTAssertFalse(joined.contains("cat >"))
        XCTAssertFalse(joined.contains(".deck-save"))
    }

    func testWriteBackNeverNamesTheTargetAsAShellRedirect() {
        let argv = WorkingCopyStore.writeFileArguments(
            target: TestHost.target,
            path: "\(TestHost.homeRoot)/notes.md")

        // The document arrives on stdin. A redirect anywhere in argv would
        // mean the remote shell, not the verb, is opening the file — which is
        // the truncate-then-fail failure the staging dance existed to avoid
        // and the containment bypass it did not avoid.
        XCTAssertFalse(argv.contains(where: { $0.contains(">") }))
    }

    func testWriteBackQuotesAPathContainingASingleQuote() {
        let argv = WorkingCopyStore.writeFileArguments(
            target: TestHost.target,
            path: "\(TestHost.homeRoot)/operator's notes.md")

        XCTAssertEqual(argv.last!, "'\(TestHost.homeRoot)/operator'\\''s notes.md'")
    }

    // MARK: - The editor page on disk

    func testEditorPageIsWrittenWhereTheServerWillServeIt() async throws {
        let remotePath = "\(TestHost.homeRoot)/Convivy/deck-editor-test-\(UUID().uuidString).md"
        let pageURL = try WorkingCopyStore.writeEditorPage("<!doctype html>ok",
                                                           forAbsolutePath: remotePath)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: pageURL.deletingLastPathComponent())
        }

        XCTAssertEqual(pageURL.lastPathComponent, WorkingCopyStore.editorPageName)
        XCTAssertEqual(try String(contentsOf: pageURL, encoding: .utf8), "<!doctype html>ok")

        // The real server roots itself at the same base directory, so a page
        // written here must produce a loopback URL rather than nil.
        let server = WorkingCopyServer()
        try await server.start()
        addTeardownBlock { server.stop() }
        let url = server.url(for: pageURL)
        XCTAssertNotNil(url, "the editor page fell outside the served root")
        XCTAssertEqual(url?.host, "127.0.0.1")
        XCTAssertTrue(url?.query?.contains("t=") ?? false, "no capability token in \(url as Any)")

        // AND IT IS ACTUALLY FETCHED, not merely addressable. The working-copy
        // directory nests one level per path component now, so the request
        // carries a multi-segment path through the server's percent-decoding
        // and root-confinement check. Asserting the URL could be BUILT would
        // not have caught a server that then refused to serve it.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let (data, response) = try await URLSession(configuration: config).data(from: url!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "<!doctype html>ok")
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
                       "text/html; charset=utf-8")
    }

    func testRewritingTheEditorPageReplacesRatherThanAccumulates() throws {
        let remotePath = "\(TestHost.homeRoot)/Convivy/deck-editor-test-\(UUID().uuidString).md"
        _ = try WorkingCopyStore.writeEditorPage("first", forAbsolutePath: remotePath)
        let second = try WorkingCopyStore.writeEditorPage("second", forAbsolutePath: remotePath)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }

        // Asserts about editor PAGES rather than the whole listing: the
        // directory legitimately holds siblings the page generator does not own
        // — the fetched copy, a draft, the source marker — and pinning an exact
        // listing made this test fail on an unrelated addition. What it exists
        // to prove is that re-rendering replaces the page rather than
        // accumulating stale ones the server would still serve.
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: second.deletingLastPathComponent().path)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".html") },
                       [WorkingCopyStore.editorPageName])
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
    }

    // MARK: - What the page may say

    func testDecodeAcceptsASave() {
        // No `roundTrip` key at all — the shape every save has until
        // `session_view.py` ships `issue_01M3P0A0GSS8MNTPXEV3JBB0JZ` — decodes
        // to `.absent`, not ok.
        XCTAssertEqual(EditorMessage.decode(["action": "save", "source": "# Hi"]),
                       .save(source: "# Hi", roundTrip: .absent))
    }

    func testDecodeAcceptsAnEmptySave() {
        // An empty document is a legitimate save — deleting every block. The
        // ceiling is the only size rule; a lower bound here would refuse a real
        // edit. What made an empty save dangerous in knowledge #170 was that it
        // happened SILENTLY on an untouched document, which is the page's bug
        // and not a shape Swift can distinguish.
        XCTAssertEqual(EditorMessage.decode(["action": "save", "source": ""]),
                       .save(source: "", roundTrip: .absent))
    }

    // MARK: - The round-trip verdict

    func testDecodeReadsAnOkRoundTrip() {
        XCTAssertEqual(
            EditorMessage.decode(["action": "save", "source": "# Hi",
                                   "roundTrip": ["ok": true, "failures": []]]),
            .save(source: "# Hi", roundTrip: EditorRoundTrip(ok: true, failures: [])))
    }

    func testDecodeReadsAFailingRoundTripAndItsFailures() {
        XCTAssertEqual(
            EditorMessage.decode(["action": "save", "source": "# Hi",
                                   "roundTrip": ["ok": false, "failures": ["dropped a table"]]]),
            .save(source: "# Hi",
                  roundTrip: EditorRoundTrip(ok: false, failures: ["dropped a table"])))
    }

    func testDecodeReadsAFailureObjectLeniently() {
        // The upstream shape for one failure is not pinned by the contract
        // yet — a plain string today, plausibly a richer object once
        // `saveChecked()` ships. Either decodes to something a person can
        // read, rather than the whole `save` being refused.
        let decoded = EditorMessage.decode([
            "action": "save", "source": "# Hi",
            "roundTrip": ["ok": false, "failures": [["message": "dropped a code span"]]],
        ])
        guard case .save(_, let roundTrip) = decoded else {
            return XCTFail("expected a .save, got \(String(describing: decoded))")
        }
        XCTAssertEqual(roundTrip.failures, ["dropped a code span"])
    }

    func testDecodeTreatsAMissingRoundTripAsAbsent() {
        XCTAssertEqual(
            EditorMessage.decode(["action": "save", "source": "# Hi"]),
            .save(source: "# Hi", roundTrip: .absent))
    }

    func testDecodeTreatsAMalformedRoundTripAsAbsent() {
        // `roundTrip` present but not a dictionary, and `ok` present but not a
        // bool, are both malformed shapes — decoding leniently means the save
        // itself still goes through, with the verdict read as not-ok rather
        // than the whole message refused.
        XCTAssertEqual(
            EditorMessage.decode(["action": "save", "source": "# Hi", "roundTrip": "yes"]),
            .save(source: "# Hi", roundTrip: .absent))
        XCTAssertEqual(
            EditorMessage.decode(["action": "save", "source": "# Hi",
                                   "roundTrip": ["ok": "yes"]]),
            .save(source: "# Hi", roundTrip: .absent))
    }

    func testDecodeAcceptsDirty() {
        XCTAssertEqual(EditorMessage.decode(["action": "dirty"]), .dirty)
    }

    func testDecodeRejectsASaveWithNoSource() {
        XCTAssertNil(EditorMessage.decode(["action": "save"]))
    }

    func testDecodeRejectsASaveWhoseSourceIsNotAString() {
        XCTAssertNil(EditorMessage.decode(["action": "save", "source": 42]))
    }

    func testDecodeRejectsAnUnknownAction() {
        XCTAssertNil(EditorMessage.decode(["action": "delete", "path": "/etc/passwd"]))
    }

    func testDecodeRejectsABodyThatIsNotADictionary() {
        XCTAssertNil(EditorMessage.decode("save"))
        XCTAssertNil(EditorMessage.decode([1, 2, 3]))
    }

    func testDecodeRejectsASourceOverTheCeiling() {
        let tooBig = String(repeating: "x", count: EditorMessage.maximumSourceBytes + 1)
        XCTAssertNil(EditorMessage.decode(["action": "save", "source": tooBig]))
    }

    func testDecodeMeasuresTheCeilingInBytesNotCharacters() {
        // A multi-byte character must count for what it costs. Measuring in
        // `count` would let a document four times the ceiling through.
        let justOver = String(repeating: "é", count: EditorMessage.maximumSourceBytes / 2 + 1)
        XCTAssertNil(EditorMessage.decode(["action": "save", "source": justOver]))
    }

    // MARK: - Whether a save signs and sends

    /// `EditorRoundTrip.gate` is what `EditorModel.receive` switches on before
    /// anything that needs Touch ID or a real `kb apply` call runs, so these
    /// pin the same four cases the field asked for without any of that
    /// machinery — the same seam `EditorPageBridge.policy` uses for the
    /// navigation decision.
    func testAMessageWithNoRoundTripNeverSigns() {
        guard case .save(_, let roundTrip)? =
                EditorMessage.decode(["action": "save", "source": "# Hi"]) else {
            return XCTFail("expected a .save")
        }
        XCTAssertEqual(roundTrip.gate, .unverified(failures: []))
    }

    func testOkFalseWithFailuresNeverSignsAndSurfacesThem() {
        XCTAssertEqual(EditorRoundTrip(ok: false, failures: ["dropped a table"]).gate,
                       .unverified(failures: ["dropped a table"]))
    }

    func testOkTrueSignsAndSends() {
        XCTAssertEqual(EditorRoundTrip(ok: true, failures: []).gate, .signAndSend)
    }

    func testAMalformedRoundTripRefuses() {
        // `ok` present but not a bool decodes to `.absent`, which — same as a
        // missing field — never signs.
        guard case .save(_, let roundTrip)? =
                EditorMessage.decode(["action": "save", "source": "# Hi",
                                       "roundTrip": ["ok": "yes"]]) else {
            return XCTFail("expected a .save")
        }
        XCTAssertEqual(roundTrip.gate, .unverified(failures: []))
    }

    // MARK: - The status a person sees

    func testUnverifiedStatusNeverReadsSaved() {
        XCTAssertFalse(EditorPane.unverifiedExplanation(failures: []).contains("Saved"))
        XCTAssertFalse(EditorPane.unverifiedExplanation(failures: ["x"]).contains("Saved"))
    }

    func testAnExpiredCertificateStatusReadsAsAFailureNamingTheDate() {
        let status = EditorModel.Status.certificateOutsideValidity(
            .expired(notAfter: ISO8601DateFormatter().date(from: "2027-01-03T03:24:32Z")!))

        XCTAssertTrue(status.isFailure, "an expired certificate must draw as a failure")
        XCTAssertEqual(status.label,
                       "Not sent to the knowledge base — your signing certificate expired on 3 Jan 2027. "
                       + "Import a renewed one in Settings › Signing.")
    }

    func testANotYetValidCertificateStatusReadsAsAFailureNamingTheStart() {
        let status = EditorModel.Status.certificateOutsideValidity(
            .notYetValid(notBefore: ISO8601DateFormatter().date(from: "2026-10-05T03:24:32Z")!))

        XCTAssertTrue(status.isFailure, "a not-yet-valid certificate must draw as a failure")
        XCTAssertEqual(status.label,
                       "Not sent to the knowledge base — your signing certificate is not valid until 5 Oct 2026. "
                       + "Import a certificate that is valid today in Settings › Signing.")
    }

    func testAnExpiredCertificateBannerKeepsTheInstructionInFull() {
        // The header label truncates on a narrow pane; the banner is the one
        // place the instruction is guaranteed to appear whole.
        let text = EditorPane.certificateOutsideValidityBanner(
            .expired(notAfter: ISO8601DateFormatter().date(from: "2027-01-03T03:24:32Z")!))

        XCTAssertEqual(text,
                       "This save was not sent to the knowledge base, because your signing certificate "
                       + "expired on 3 Jan 2027. Import a renewed one in Settings › Signing. "
                       + "Your draft is kept on this Mac; nothing there has changed.")
    }

    func testUnverifiedStatusListsFailuresWhenPresent() {
        let text = EditorPane.unverifiedExplanation(failures: ["dropped a table", "unbalanced backtick"])
        XCTAssertTrue(text.contains("could not be verified as faithful"))
        XCTAssertTrue(text.contains("dropped a table"))
        XCTAssertTrue(text.contains("unbalanced backtick"))
    }

    // MARK: - What the page may load

    func testLoopbackOnOurPortIsAllowed() {
        XCTAssertEqual(
            EditorPageBridge.policy(for: URL(string: "http://127.0.0.1:4242/editor.html?t=x"),
                                       isLinkActivated: false, port: 4242, hosts: testHosts),
            .allow)
    }

    func testLoopbackOnAnotherPortIsRefused() {
        // Another local process's server is not ours, and a page that reached it
        // would be talking to something Deck did not start.
        XCTAssertEqual(
            EditorPageBridge.policy(for: URL(string: "http://127.0.0.1:9999/x"),
                                       isLinkActivated: false, port: 4242, hosts: testHosts),
            .cancel)
    }

    func testAForeignHostIsRefusedEvenWhenItIsNotALinkClick() {
        // This is the exfiltration channel the CSP cannot close: a script-driven
        // navigation carrying the capability token in the referrer or the URL.
        XCTAssertEqual(
            EditorPageBridge.policy(for: URL(string: "https://evil.example/steal?t=abc"),
                                       isLinkActivated: false, port: 4242, hosts: testHosts),
            .cancel)
    }

    func testAWebLinkTheReaderClickedGoesToTheBrowser() {
        let url = URL(string: "https://example.com/docs")!
        XCTAssertEqual(
            EditorPageBridge.policy(for: url, isLinkActivated: true, port: 4242, hosts: testHosts),
            .external(url))
    }

    func testAFileURLIsRefusedEvenAsALinkClick() {
        // `ExternalLink`'s allowlist would drop this too, but the policy refuses
        // it outright so the pane does not depend on a check two layers away.
        let url = URL(string: "file://\(TestHost.homeRoot)/.ssh/id_ed25519")!
        XCTAssertEqual(
            EditorPageBridge.policy(for: url, isLinkActivated: true, port: 4242, hosts: testHosts),
            .cancel)
        XCTAssertFalse(ExternalLink.allowedSchemes.contains("file"))
    }

    func testAnAppDeepLinkIsRefusedEvenAsALinkClick() {
        XCTAssertEqual(
            EditorPageBridge.policy(for: URL(string: "obsidian://open?vault=x"),
                                    isLinkActivated: true, port: 4242, hosts: testHosts),
            .cancel)
    }

    func testADeckOpenLinkRoutesBackIntoDeck() {
        let url = URL(string: "deck-open:?origin=kb&ref=deck%2Fspecs%2Fsession-pane")!
        XCTAssertEqual(
            EditorPageBridge.policy(for: url, isLinkActivated: true, port: 4242, hosts: testHosts),
            .openRef(.kb(id: "deck/specs/session-pane")))
    }

    func testAMalformedDeckOpenLinkIsRefusedRatherThanGuessed() {
        let url = URL(string: "deck-open:?origin=path&ref=%2Fetc%2Fpasswd")!
        XCTAssertEqual(
            EditorPageBridge.policy(for: url, isLinkActivated: true, port: 4242, hosts: testHosts),
            .cancel)
    }

    func testNoNavigationIsAllowedBeforeTheServerHasAPort() {
        // Port 0 means the listener has not come up. Allowing a match against it
        // would let `http://127.0.0.1` with no port through.
        XCTAssertEqual(
            EditorPageBridge.policy(for: URL(string: "http://127.0.0.1/editor.html"),
                                       isLinkActivated: false, port: 0, hosts: testHosts),
            .cancel)
    }

    func testANilURLIsRefused() {
        XCTAssertEqual(
            EditorPageBridge.policy(for: nil, isLinkActivated: true, port: 4242, hosts: testHosts),
            .cancel)
    }

    // MARK: - Which file a message belongs to

    private func page(_ path: String, target: SSHTarget = TestHost.target) -> LoadedEditorPage {
        LoadedEditorPage(
            url: URL(string: "http://127.0.0.1:4242/path/\(path)/editor.html?t=x")!,
            ref: .path(absolutePath: "\(TestHost.homeRoot)/\(path).md"),
            target: target)
    }

    /// The same document on two hosts shares one working-copy URL and one ref,
    /// because `WorkingCopyStore` keys its directory on the ref alone. Only the
    /// host tells them apart — so without it in the page, switching hosts
    /// issues no load, the view keeps the first host's page, and a save from it
    /// is attributed to the host the reader has already left.
    func testAPageFromADifferentHostIsReloaded() {
        let first = page("a")
        let second = page("a", target: TestHost.secondaryTarget)
        XCTAssertEqual(LoadedEditorPage.toLoad(current: first, wanted: second), second)
    }

    func testAViewHoldingThePageDoesNotReloadIt() {
        let held = page("a")
        XCTAssertNil(LoadedEditorPage.toLoad(current: held, wanted: held))
    }

    func testAViewHoldingNothingLoads() {
        XCTAssertEqual(LoadedEditorPage.toLoad(current: nil, wanted: page("a")), page("a"))
    }

    func testTwoRemotePathsNeverShareAWorkingCopyDirectory() throws {
        // The collision that was there: replacing '/' with '-' mapped both of
        // these to one directory, so one overwrote the other's copy and the
        // reader got the wrong file's contents under this file's name. With
        // the editor, a save then writes those contents to this path.
        XCTAssertNotEqual(
            try WorkingCopyStore.pathComponents(forAbsolutePath: "\(TestHost.homeRoot)/a/b.md"),
            try WorkingCopyStore.pathComponents(forAbsolutePath: "\(TestHost.homeRoot)/a-b.md"))
    }

    func testTheDirectoryMappingIsInjectiveOverSeparatorAmbiguity() throws {
        // Every way a '-' and a '/' can be swapped for one another. The last
        // pair is the one that killed the first attempt at a fix: escaping '-'
        // as '--' and then '/' as '-' sent BOTH of them to 'x---y', because the
        // escape character and the separator were the same character and a run
        // of three splits two ways.
        let paths = [
            "\(TestHost.homeRoot)/a/b.md",
            "\(TestHost.homeRoot)/a-b.md",
            "\(TestHost.homeRoot)/a/b/c.md",
            "\(TestHost.homeRoot)/a-b-c.md",
            "\(TestHost.homeRoot)/a/b-c.md",
            "\(TestHost.homeRoot)/a-b/c.md",
            "\(TestHost.homeRoot)/x--y.md",
            "\(TestHost.homeRoot)/x/-y.md",
            "\(TestHost.homeRoot)/x-/y.md",
            "\(TestHost.homeRoot)/trailing-",
        ]
        let mapped = try paths.map { try WorkingCopyStore.pathComponents(forAbsolutePath: $0) }
        XCTAssertEqual(Set(mapped.map { $0.joined(separator: "\u{0}") }).count,
                       paths.count, "colliding directories among \(mapped)")
    }

    func testTheDirectoryMirrorsThePathOneComponentAtATime() throws {
        XCTAssertEqual(
            try WorkingCopyStore.pathComponents(forAbsolutePath: "\(TestHost.homeRoot)/a/b.md"),
            ["Users", TestHost.user, "a", "b.md"])
    }

    func testAPathThatCouldClimbOutOfTheRootIsRefused() throws {
        // Not reachable through the app — validatePath standardises first — but
        // this builds a directory Deck writes into, and appendingPathComponent
        // would honour a "..".
        XCTAssertThrowsError(
            try WorkingCopyStore.pathComponents(forAbsolutePath: "\(TestHost.homeRoot)/../../etc/x.md"))
        XCTAssertThrowsError(
            try WorkingCopyStore.pathComponents(forAbsolutePath: "\(TestHost.homeRoot)/./x.md"))
        XCTAssertThrowsError(try WorkingCopyStore.pathComponents(forAbsolutePath: "/"))
    }

    func testACollidingURLIsStillReloadedWhenTheRefDiffers() {
        // Defence in depth behind the injective slug: even handed two pages
        // that somehow share a URL, a different ref must still force a load.
        // Without this, the view keeps the first file and a save from it
        // carries the first file's ref while the header names the second.
        let first = page("a")
        let second = LoadedEditorPage(url: first.url,
                                      ref: .path(absolutePath: "\(TestHost.homeRoot)/other.md"),
                                      target: TestHost.target)
        XCTAssertEqual(LoadedEditorPage.toLoad(current: first, wanted: second), second)
    }

    func testTheRefMovesWithTheURLAndNeverSeparately() {
        // The failure this rules out: the URL updated and the ref did not, so a
        // save from the page now showing gets addressed to the file that was
        // there before. Whenever a load happens, both fields come from the same
        // value — there is no assignment that moves one alone.
        let next = LoadedEditorPage.toLoad(current: page("a"), wanted: page("b"))
        XCTAssertEqual(next, page("b"))
        XCTAssertEqual(next?.ref, .path(absolutePath: "\(TestHost.homeRoot)/b.md"))
    }

    // MARK: - Appearance

    func testThemeScriptStampsTheResolvedAppearance() {
        XCTAssertEqual(EditorPageBridge.themeScript(for: .dark),
                       "document.documentElement.setAttribute('data-theme','dark')")
        XCTAssertEqual(EditorPageBridge.themeScript(for: .light),
                       "document.documentElement.setAttribute('data-theme','light')")
    }

    func testTheDirtyScriptListensOnTheContractedMountPoint() {
        // `#editor-root` is the id the generated page mounts on, pinned by the
        // editor-page contract. If it moves, this listener silently stops
        // firing and unsaved work stops being reported.
        XCTAssertTrue(EditorPageBridge.dirtyScript.contains("getElementById('editor-root')"))
        XCTAssertTrue(EditorPageBridge.dirtyScript.contains("messageHandlers.deckEditor"))
        XCTAssertTrue(EditorPageBridge.dirtyScript.contains("action: 'dirty'"))
    }

    // MARK: - Eligibility

    func testLocalMarkdownIsEditable() {
        XCTAssertTrue(EditorPane.canEdit(.path(absolutePath: "\(TestHost.homeRoot)/notes.md")))
        XCTAssertTrue(EditorPane.canEdit(.path(absolutePath: "\(TestHost.homeRoot)/NOTES.MD")))
    }

    func testNonMarkdownIsNotEditable() {
        XCTAssertFalse(EditorPane.canEdit(.path(absolutePath: "\(TestHost.homeRoot)/a.swift")))
        XCTAssertFalse(EditorPane.canEdit(.path(absolutePath: "\(TestHost.homeRoot)/a.pdf")))
        XCTAssertFalse(EditorPane.canEdit(.path(absolutePath: "\(TestHost.homeRoot)/README")))
    }

    func testAKBDocumentIsEditable() {
        // Phase 4 landed this. A KB document is checked out, edited, and
        // returned as a pull request — which is the discipline
        // platform/decisions/0020 settles on, not a Deck-specific route.
        // This test previously asserted the opposite and had to be rewritten
        // rather than deleted: the phase boundary it encoded moved.
        XCTAssertTrue(EditorPane.canEdit(.kb(id: "deck/specs/session-pane")))
    }
}

/// The KB viewer path, which had three defects phase 4 walked past.
final class KBViewerWorkingCopyTests: XCTestCase {

    func testTwoDocumentIdsNeverShareAWorkingCopyDirectory() throws {
        // Flattening '/' to '-' sent these to one directory, so the second
        // document opened overwrote the first's working copy and the reader saw
        // the wrong document's contents. A doc id is [a-z0-9-] in three
        // segments — exactly the alphabet where a hyphen and a separator are
        // interchangeable — so this was MORE reachable than the path-branch
        // collision #74 fixed, not less.
        XCTAssertNotEqual(
            try WorkingCopyStore.pathComponents(forAbsolutePath: "a-b/c/d"),
            try WorkingCopyStore.pathComponents(forAbsolutePath: "a/b-c/d"))
    }

    func testAKBWorkingCopyNestsOneDirectoryPerSegment() throws {
        let id = "deck/specs/probe-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = try WorkingCopyStore.directory(forKBId: id)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(dir.path.contains("/kb/deck/specs/"))
    }

    func testAKBIdCarryingDotDotIsRefused() {
        // validateKBId admits no dots, so this is unreachable through the app.
        // The guard is shared with the path branch rather than skipped on the
        // argument that this input is narrower — that argument is exactly what
        // left the collision above in place after #74.
        XCTAssertThrowsError(try WorkingCopyStore.directory(forKBId: "a/../../etc"))
    }

    func testTheViewerReadPathTakesNoLeaseToRelease() {
        // The viewer used to fetch through `agentctl kb checkout`, which took
        // a four-hour write lease as a side effect and left a detached `kb
        // release` racing to drop it (deck/decisions/0002). The Library's
        // reference route is a read with nothing to release, so nothing here
        // should mention checkout, release, or a lease at all.
        let command = WorkingCopyStore.libraryDocumentRemoteCommand(kbId: "deck/specs/session-pane")
        XCTAssertFalse(command.contains("checkout"))
        XCTAssertFalse(command.contains("release"))
        XCTAssertFalse(command.contains("agentctl"))
    }
}
