import XCTest
@testable import Deck

/// Tests for the KB seam: what Deck asks the knowledge base for, and how it
/// reads the answer.
///
/// The interesting failures here are all silent ones. A submit that omits the
/// base sha still opens a pull request and still looks correct; it just stops
/// detecting that somebody else moved the document. So most of these assert
/// something is PRESENT rather than that an operation succeeded.
final class KnowledgeBaseTests: XCTestCase {

    private let doc = KnowledgeBase.CheckedOutDocument(
        id: "deck/specs/session-pane",
        content: "---\nid: deck/specs/session-pane\n---\n\n# T\n",
        contentSha: "3acf9780aa451c2f0d0e",
        sourceRef: "projects/deck/specs/session-pane.md", target: TestHost.target)

    // MARK: - The sha is kept, even though nothing consumes it yet

    func testTheCheckedOutShaIsCarriedOnTheDocument() {
        // The return verb does not exist, so nothing sends this anywhere. It is
        // held rather than dropped because re-deriving it when the Library
        // lands would mean a second read of the document, and a second read can
        // disagree with the first — which is the whole reason checkout returns
        // content and sha together.
        XCTAssertEqual(doc.contentSha, "3acf9780aa451c2f0d0e")
        let mirror = Mirror(reflecting: doc)
        XCTAssertTrue(mirror.children.contains { $0.label == "contentSha" })
    }

    // MARK: - What a reader is told

    func testTheExplanationSaysWhereTheEditDidNotGo() {
        // "Saved" alone reads as "saved to the knowledge base", which is the one
        // thing that did not happen. The sentence has to name the absence.
        let text = KnowledgeBase.notReturnedExplanation.lowercased()
        XCTAssertTrue(text.contains("this mac only"))
        XCTAssertTrue(text.contains("cannot be checked back in"))
        XCTAssertTrue(text.contains("nothing on the knowledge base has changed"))
    }

    // MARK: - argv shape

    func testCheckoutNamesTheDocumentAndTakesALease() {
        let argv = KnowledgeBase.checkoutArguments(target: TestHost.target, id: doc.id, controlPath: "/tmp/cm")
        XCTAssertEqual(argv[argv.count - 4], "checkout")
        XCTAssertEqual(argv[argv.count - 3], "'deck/specs/session-pane'")
        XCTAssertEqual(argv[argv.count - 2], "--note")
    }

    func testReleaseNamesTheDocument() {
        let argv = KnowledgeBase.releaseArguments(target: TestHost.target, id: doc.id, controlPath: "/tmp/cm")
        XCTAssertEqual(argv.suffix(3), ["kb", "release", "'deck/specs/session-pane'"])
    }

    // MARK: - content_sha's shape is checked before it becomes baseSha

    /// A 64-lowercase-hex `content_sha` is the contract's shape
    /// (`platform/contracts/library-protocol` §2.2's `--base-sha`). Checked
    /// here rather than assumed: `checkout` used to cast it straight out of
    /// JSON with no format check, and `applyArguments` then interpolated it
    /// into ssh argv — quoted now, but a value that cannot even be a sha
    /// should never reach that argv at all. Found by `deck-security-reviewer`
    /// on #286.
    private let validCheckoutJSON = Data("""
    {"content":"# T\\n","content_sha":"3acf9780aa451c2f0d0e3acf9780aa451c2f0d0e3acf9780aa451c2f0d0e1234",
     "source_ref":"projects/deck/specs/session-pane.md"}
    """.utf8)

    func testParseCheckoutResponseAcceptsA64LowercaseHexSha() throws {
        let document = try KnowledgeBase.parseCheckoutResponse(
            validCheckoutJSON, id: "deck/specs/session-pane", target: TestHost.target)
        XCTAssertEqual(document.contentSha, "3acf9780aa451c2f0d0e3acf9780aa451c2f0d0e3acf9780aa451c2f0d0e1234")
        XCTAssertEqual(document.contentSha.count, 64)
    }

    func testParseCheckoutResponseRefusesAShaThatIsTooShort() {
        let json = Data("""
        {"content":"# T\\n","content_sha":"3acf9780aa451c2f0d0e",
         "source_ref":"projects/deck/specs/session-pane.md"}
        """.utf8)
        XCTAssertThrowsError(
            try KnowledgeBase.parseCheckoutResponse(json, id: "deck/specs/session-pane", target: TestHost.target)
        ) { error in
            guard case KnowledgeBase.KBError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }

    func testParseCheckoutResponseRefusesAShaCarryingAShellMetacharacter() {
        // The exact failure mode the review named: an untrusted or corrupted
        // content_sha carrying a shell metacharacter must never reach
        // applyArguments at all, not merely be quoted once it gets there.
        let json = Data("""
        {"content":"# T\\n","content_sha":"abc; rm -rf ~ #aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         "source_ref":"projects/deck/specs/session-pane.md"}
        """.utf8)
        XCTAssertThrowsError(
            try KnowledgeBase.parseCheckoutResponse(json, id: "deck/specs/session-pane", target: TestHost.target))
    }

    func testParseCheckoutResponseRefusesUppercaseHex() {
        let json = Data("""
        {"content":"# T\\n","content_sha":"3ACF9780AA451C2F0D0E3ACF9780AA451C2F0D0E3ACF9780AA451C2F0D0E123",
         "source_ref":"projects/deck/specs/session-pane.md"}
        """.utf8)
        XCTAssertThrowsError(
            try KnowledgeBase.parseCheckoutResponse(json, id: "deck/specs/session-pane", target: TestHost.target))
    }

    func testIsValidContentShaAcceptsExactly64LowercaseHexCharacters() {
        XCTAssertTrue(KnowledgeBase.isValidContentSha(String(repeating: "a", count: 64)))
        XCTAssertFalse(KnowledgeBase.isValidContentSha(String(repeating: "a", count: 63)))
        XCTAssertFalse(KnowledgeBase.isValidContentSha(String(repeating: "a", count: 65)))
        XCTAssertFalse(KnowledgeBase.isValidContentSha(""))
    }

}

/// The KB working-copy directory, which had the path branch's collision.
final class KBWorkingCopyTests: XCTestCase {

    func testTwoDocumentIdsNeverShareAWorkingCopyDirectory() throws {
        // A doc id is [a-z0-9-] in three segments, which is exactly the
        // alphabet where a hyphen and a separator are interchangeable — so
        // flattening '/' to '-' collided here for the same reason it did on the
        // path branch, and the narrower input made it MORE reachable, not less.
        XCTAssertNotEqual(
            try WorkingCopyStore.pathComponents(forAbsolutePath: "a-b/c/d"),
            try WorkingCopyStore.pathComponents(forAbsolutePath: "a/b-c/d"))
    }

    func testAKBEditorPageIsWrittenUnderItsOwnNestedDirectory() throws {
        let id = "deck/specs/probe-\(UUID().uuidString.prefix(8).lowercased())"
        let pageURL = try WorkingCopyStore.writeEditorPage("<!doctype html>ok", forKBId: id)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: pageURL.deletingLastPathComponent())
        }
        XCTAssertEqual(pageURL.lastPathComponent, WorkingCopyStore.editorPageName)
        // One directory per segment, under the kb root rather than the path one.
        XCTAssertTrue(pageURL.path.contains("/kb/deck/specs/"))
    }

    func testAKBIdCarryingDotDotIsRefused() throws {
        // validateKBId admits no dots, so this is unreachable through the app.
        // The guard is shared with the path branch rather than skipped on the
        // argument that this input is narrower — that argument is what let the
        // first collision survive.
        XCTAssertThrowsError(try WorkingCopyStore.directory(forKBId: "a/../../etc"))
    }
}

/// The stdin render verb, which is how a KB document reaches the editor.
final class RenderEditorFromStdinTests: XCTestCase {

    func testTheDocIdIsPassedAsTheName() {
        let argv = SessionAgent.renderEditorFromStdinArguments(
            target: TestHost.target, name: "deck/specs/session-pane", appearance: .dark, controlPath: "/tmp/cm")
        let flag = argv.firstIndex(of: "--name")!
        XCTAssertEqual(argv[flag + 1], "'deck/specs/session-pane'")
        XCTAssertEqual(argv[argv.count - 2], "--theme")
        XCTAssertEqual(argv.last, "dark")
    }

    func testTheDocumentIsNotOnArgv() {
        // '-' tells session-view to read the document from stdin. A document on
        // argv would be visible in the remote process table.
        let argv = SessionAgent.renderEditorFromStdinArguments(
            target: TestHost.target, name: "a/b/c", appearance: .light)
        let verb = argv.firstIndex(of: "--render-editor")!
        XCTAssertEqual(argv[verb + 1], "-")
    }

    func testItSharesTheRenderControlMaster() {
        let argv = SessionAgent.renderEditorFromStdinArguments(
            target: TestHost.target, name: "a/b/c", appearance: .light, controlPath: "/tmp/cm")
        XCTAssertTrue(argv.contains("ControlPath=/tmp/cm-render"))
    }
}

/// The stdin render verb `ItemDetailPane` uses to render a composed
/// Markdown document that has no path on the mini.
final class RenderFileFromStdinTests: XCTestCase {

    func testTheNameIsPassedQuoted() {
        let argv = SessionAgent.renderFileFromStdinArguments(
            target: TestHost.target, name: "issue_01ABC", appearance: .dark, controlPath: "/tmp/cm")
        let flag = argv.firstIndex(of: "--name")!
        XCTAssertEqual(argv[flag + 1], "'issue_01ABC'")
        XCTAssertEqual(argv[argv.count - 2], "--theme")
        XCTAssertEqual(argv.last, "dark")
    }

    func testTheDocumentIsNotOnArgv() {
        // '-' tells session-view to read the document from stdin, the same
        // reason `renderEditorFromStdinArguments` reads its document that way:
        // a document on argv would be visible in the remote process table.
        let argv = SessionAgent.renderFileFromStdinArguments(
            target: TestHost.target, name: "a", appearance: .light)
        let verb = argv.firstIndex(of: "--render-file")!
        XCTAssertEqual(argv[verb + 1], "-")
    }

    func testItSharesTheRenderControlMaster() {
        let argv = SessionAgent.renderFileFromStdinArguments(
            target: TestHost.target, name: "a", appearance: .light, controlPath: "/tmp/cm")
        XCTAssertTrue(argv.contains("ControlPath=/tmp/cm-render"))
    }
}

/// The ordering that decides whether a lease can leak.
///
/// The defect this pins had no test that could fail, because the leak lived in
/// the ORDER of two statements inside one closure rather than in either of
/// them. What is testable is the shape the fix relies on: checkout returns a
/// document, and nothing about rendering it is part of obtaining it.
final class KBLeaseTrackingTests: XCTestCase {

    func testCheckoutIsSeparableFromRenderingWhatItReturned() {
        // `checkout` yields the document on its own. The editor records it
        // before attempting the render, so a render failure cannot leave a
        // lease taken and untracked — which is exactly what happened when both
        // steps shared one detached closure and the assignment sat after the
        // throwing call.
        let doc = KnowledgeBase.CheckedOutDocument(
            id: "deck/specs/session-pane", content: "# T\n", contentSha: "abc123",
            sourceRef: "projects/deck/specs/session-pane.md", target: TestHost.target)
        XCTAssertEqual(doc.id, "deck/specs/session-pane")
        XCTAssertFalse(doc.content.isEmpty)
        XCTAssertFalse(doc.contentSha.isEmpty)
    }

    func testReleaseIsAddressedByIdAlone() {
        // Releasing needs only what checkout already returned, so the editor can
        // drop a lease it took even if everything after the checkout failed.
        let argv = KnowledgeBase.releaseArguments(target: TestHost.target, id: "deck/specs/session-pane",
                                                  controlPath: "/tmp/cm")
        XCTAssertEqual(argv.suffix(3), ["kb", "release", "'deck/specs/session-pane'"])
    }
}

/// The working copy telling the truth about what it holds.
final class WorkingCopyTruthfulnessTests: XCTestCase {

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DeckTruth-\(UUID().uuidString)")
    }

    func testADraftDoesNotOverwriteTheFetchedCopy() throws {
        // The defect: both writers used one filename, so saving an edit replaced
        // the copy the read-only viewer reads. Pressing Done then showed the
        // reader their own draft as the document, with no banner — the surface
        // that explains the difference is the one they just left.
        let id = "deck/specs/probe-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = try WorkingCopyStore.directory(forKBId: id)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let fetched = dir.appendingPathComponent("\(id.split(separator: "/").last!).md")
        try "CANONICAL".write(to: fetched, atomically: true, encoding: .utf8)

        let doc = KnowledgeBase.CheckedOutDocument(
            id: id, content: "CANONICAL", contentSha: "s",
            sourceRef: "projects/\(id).md", target: TestHost.target)
        let draft = try KnowledgeBase.saveLocally(document: doc, content: "MY EDIT")

        XCTAssertNotEqual(draft, fetched)
        XCTAssertEqual(try String(contentsOf: fetched, encoding: .utf8), "CANONICAL")
        XCTAssertEqual(try String(contentsOf: draft, encoding: .utf8), "MY EDIT")
        XCTAssertTrue(draft.lastPathComponent.hasSuffix(KnowledgeBase.draftSuffix))
    }

    func testTheExplanationPromisesOnlyWhatSurvives() {
        // It used to say "your working copy is safe", which returning to the
        // viewer made false — the fetched copy is refreshed there. The draft is
        // what survives, so the draft is what it names.
        let text = KnowledgeBase.notReturnedExplanation
        XCTAssertFalse(text.lowercased().contains("working copy is safe"))
        XCTAssertTrue(text.lowercased().contains("draft"))
        XCTAssertTrue(text.lowercased().contains("nothing on the knowledge base has changed"))
    }

    func testASecondSourceClaimingOneDirectoryIsRefused() throws {
        // Injective in Swift is not injective on disk: APFS folds case and
        // NFC/NFD, so two distinct sources can still land in one directory once
        // the filesystem has its say. Unreachable while both machines run the
        // same case-insensitive filesystem — which is a property of the storage
        // rather than of this code, and changes without this code changing.
        let id = "deck/specs/probe-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = try WorkingCopyStore.directory(forKBId: id)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // Re-claiming for the SAME source is how every ordinary reopen works.
        XCTAssertNoThrow(try WorkingCopyStore.directory(forKBId: id))

        // A different source pointed at the same directory is refused rather
        // than served, which is the silent wrong-document turned into an error.
        let marker = dir.appendingPathComponent(WorkingCopyStore.sourceMarkerName)
        try "kb:some/other/document".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkingCopyStore.directory(forKBId: id)) { error in
            guard case WorkingCopyStore.FetchError.workingCopyCollision = error else {
                return XCTFail("expected a collision, got \(error)")
            }
        }
    }

    func testAPathAndAKBDocumentCannotClaimEachOthersDirectory() throws {
        // The two roots are separate, but the marker records which kind of
        // source a directory holds so the guard does not depend on that.
        let id = "deck/specs/probe-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = try WorkingCopyStore.directory(forKBId: id)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent(WorkingCopyStore.sourceMarkerName)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "kb:\(id)")
    }
}
