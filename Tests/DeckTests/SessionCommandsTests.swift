import XCTest
@testable import Deck

/// `SessionCommands.decode` and the sentences the menu says when it has
/// nothing to list.
///
/// The decoder is where a wrong reply becomes a wrong menu, and this menu's
/// whole purpose is telling the reader whether a command is really there — so
/// the cases that matter are the malformed ones, not the happy path.
final class SessionCommandsTests: XCTestCase {

    private func decode(_ json: String) -> SessionCommands? {
        SessionCommands.decode(Data(json.utf8))
    }

    // MARK: - The shape the mini sends

    func testDecodesAnEntryWithEveryField() throws {
        let out = try XCTUnwrap(decode("""
        {"cwd": "/repo", "sources": [{"scope": "project", "path": "/repo/.claude", "exists": true}],
         "commands": [{"name": "handoff-leave", "kind": "skill", "scope": "project",
                       "description": "write a handoff", "path": "/x/SKILL.md"}]}
        """))
        XCTAssertEqual(out.cwd, "/repo")
        XCTAssertEqual(out.sources, [.init(scope: .project, path: "/repo/.claude", exists: true)])
        let entry = try XCTUnwrap(out.entries.first)
        XCTAssertEqual(entry.name, "handoff-leave")
        XCTAssertEqual(entry.kind, .skill)
        XCTAssertEqual(entry.scope, .project)
        XCTAssertEqual(entry.description, "write a handoff")
        XCTAssertNil(entry.declaredName)
    }

    /// The invocation as typed, which is the only string in the menu that has
    /// to be exactly right.
    func testTheSlashIsTheNameAsItWouldBeTyped() {
        let entry = SessionCommands.Entry(name: "kb:audit", kind: .command, scope: .project,
                                          description: nil, declaredName: nil)
        XCTAssertEqual(entry.slash, "/kb:audit")
    }

    func testCarriesAFrontmatterNameThatDisagreesWithItsDirectory() throws {
        let out = try XCTUnwrap(decode("""
        {"cwd": null, "sources": [],
         "commands": [{"name": "on-disk", "kind": "skill", "scope": "user",
                       "declared_name": "in-frontmatter"}]}
        """))
        XCTAssertEqual(out.entries.first?.name, "on-disk")
        XCTAssertEqual(out.entries.first?.declaredName, "in-frontmatter")
    }

    // MARK: - A reply that is not what it should be

    func testNotAJSONObjectDecodesToNil() {
        XCTAssertNil(decode("not json"))
        XCTAssertNil(decode("[]"))
        XCTAssertNil(decode(""))
    }

    /// NIL AND EMPTY ARE DIFFERENT and the model turns the first into an error
    /// rather than an empty menu — a menu showing nothing because the reply was
    /// unreadable is the exact confusion this feature removes.
    func testAnObjectWithNoCommandsKeyIsEmptyNotNil() throws {
        let out = try XCTUnwrap(decode("{\"cwd\": \"/repo\"}"))
        XCTAssertTrue(out.entries.isEmpty)
    }

    /// An entry Deck cannot name is dropped rather than defaulted. Inventing a
    /// name would print an invocation that does nothing, which is worse than
    /// omitting it.
    func testEntriesWithoutAUsableNameOrKindAreDropped() throws {
        let out = try XCTUnwrap(decode("""
        {"commands": [{"kind": "skill", "scope": "user"},
                      {"name": "", "kind": "skill", "scope": "user"},
                      {"name": "unknown-kind", "kind": "plugin", "scope": "user"},
                      {"name": "unknown-scope", "kind": "skill", "scope": "global"},
                      {"name": "good", "kind": "skill", "scope": "user"}]}
        """))
        XCTAssertEqual(out.entries.map(\.name), ["good"])
    }

    func testASourceMissingItsPathIsDropped() throws {
        let out = try XCTUnwrap(decode("""
        {"sources": [{"scope": "user"}, {"scope": "user", "path": "/h/.claude", "exists": true}]}
        """))
        XCTAssertEqual(out.sources.count, 1)
    }

    /// The mini sorts project-first and Deck preserves it. Re-sorting here
    /// would put two orderings in play that could disagree.
    func testTheOrderTheMiniSentIsKept() throws {
        let out = try XCTUnwrap(decode("""
        {"commands": [{"name": "zzz", "kind": "skill", "scope": "project"},
                      {"name": "aaa", "kind": "command", "scope": "user"}]}
        """))
        XCTAssertEqual(out.entries.map(\.name), ["zzz", "aaa"])
    }

    // MARK: - What the menu says when there is nothing to list

    /// Three different facts, three different sentences. Telling a reader "this
    /// project defines none" when the truth is "this session has no project"
    /// sends them looking in the wrong place.
    func testAnEmptyListWithAProjectDirectoryBlamesNeitherSide() throws {
        let out = try XCTUnwrap(decode("""
        {"cwd": "/repo", "sources": [{"scope": "project", "path": "/repo/.claude", "exists": true}],
         "commands": []}
        """))
        XCTAssertEqual(out.emptyExplanation, "No commands or skills on disk for this session.")
    }

    func testAnEmptyListWithNoProjectClaudeDirectorySaysSo() throws {
        let out = try XCTUnwrap(decode("""
        {"cwd": "/repo", "sources": [{"scope": "project", "path": "/repo/.claude", "exists": false}],
         "commands": []}
        """))
        XCTAssertEqual(out.emptyExplanation,
                       "No .claude directory in this session's project, and no machine-wide commands.")
    }

    func testAnEmptyListWithNoProjectAtAllSaysThat() throws {
        let out = try XCTUnwrap(decode("""
        {"cwd": null, "sources": [{"scope": "user", "path": "/h/.claude", "exists": true}],
         "commands": []}
        """))
        XCTAssertEqual(
            out.emptyExplanation,
            "This session has no working directory, so only machine-wide commands apply — and there are none.")
    }

    func testANonEmptyListHasNoExplanationToGive() throws {
        let out = try XCTUnwrap(decode("""
        {"commands": [{"name": "x", "kind": "skill", "scope": "user"}]}
        """))
        XCTAssertNil(out.emptyExplanation)
    }
}

/// Putting a picked command into the composer.
@MainActor
final class InsertCommandTests: XCTestCase {

    private func model() -> SessionPaneModel {
        SessionPaneModel(session: "deck", target: TestHost.target)
    }

    func testAnEmptyComposerTakesTheCommandAndASpace() {
        let m = model()
        m.insertCommand("/handoff-leave")
        XCTAssertEqual(m.draft, "/handoff-leave ")
    }

    /// A composer with text in it is a message being written, and replacing it
    /// would lose work — so this appends.
    func testTextAlreadyThereIsKept() {
        let m = model()
        m.draft = "please run"
        m.insertCommand("/write-better")
        XCTAssertEqual(m.draft, "please run /write-better ")
    }

    func testATrailingSpaceIsNotDoubled() {
        let m = model()
        m.draft = "please run "
        m.insertCommand("/write-better")
        XCTAssertEqual(m.draft, "please run /write-better ")
    }

    func testAfterANewlineNoSpaceIsAdded() {
        let m = model()
        m.draft = "first line\n"
        m.insertCommand("/x")
        XCTAssertEqual(m.draft, "first line\n/x ")
    }
}

/// The one thing about the menu a unit test can reach.
///
/// `Menu` has no "opened" callback, and an `.onTapGesture` wrapped around one
/// never fires: the control's own AppKit tracking session consumes the event
/// before an outer gesture gets a turn. A first version loaded through exactly
/// that, so the menu opened, looked right, and permanently showed its
/// not-yet-read placeholder — the feature appearing to work while never
/// loading. deck-reviewer found it by sending a synthetic mouseDown/mouseUp
/// pair; `swift test` could not, and still cannot, because this package has no
/// UI test target.
///
/// These guard the shape of the fix at the only level available. They are a
/// backstop, not coverage.
final class CommandsMenuWiringTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Deck/Session/\(name)"),
                          encoding: .utf8)
    }

    /// A gesture on the menu cannot be what loads it.
    func testTheMenuDoesNotLoadThroughAnOuterTapGesture() throws {
        let view = try source("SessionPaneView.swift")
        XCTAssertFalse(view.contains(".onTapGesture(perform: onOpen)"),
                       "a tap gesture on a Menu never fires — the control eats the event")
    }

    /// So the pane starts the read itself, once, and the menu's own Reload —
    /// a Button, whose action does fire — is how it gets read again.
    func testThePaneStartsTheReadItself() throws {
        let model = try source("SessionPaneModel.swift")
        guard let start = model.range(of: "func start(appearance:"),
              let nextFunc = model.range(of: "\n    // MARK: - Reading", range: start.upperBound..<model.endIndex)
        else { return XCTFail("could not isolate start() — update this guard") }
        XCTAssertTrue(model[start.upperBound..<nextFunc.lowerBound].contains("loadCommands()"),
                      "the pane must start the read; nothing else can")
    }

    func testTheMenuOffersAReload() throws {
        XCTAssertTrue(try source("SessionPaneView.swift").contains("Button(\"Reload\", action: onOpen)"),
                      "a file added since the session started needs a way in")
    }
}
