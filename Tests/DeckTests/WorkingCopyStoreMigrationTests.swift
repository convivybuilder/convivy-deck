import XCTest
@testable import Deck

/// `deck/specs/running-deck-as-someone-else` §"The defaults name Convivy":
/// `WorkingCopyStore` no longer nests under `Convivy` in Application Support,
/// and existing working copies at the old path are migrated forward rather
/// than stranded — a KB document's `.draft.md` is the sole copy of an edit
/// nobody has submitted anywhere yet (`KnowledgeBase.saveLocally`), so
/// starting clean at the new path would silently lose it.
///
/// Every test drives real temp directories through `FileManager.default`
/// rather than `WorkingCopyStore.baseDirectory` itself — evaluating that
/// static touches the real Application Support directory (and, via
/// migration, any real working copies sitting under it) as a side effect,
/// which a test must never do.
final class WorkingCopyStoreMigrationTests: XCTestCase {
    private func tempRoot() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-workingcopy-migration-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - The path itself

    func testCurrentBaseDirectoryDropsTheConvivyComponent() {
        let support = URL(fileURLWithPath: "/tmp/some-app-support")
        let current = WorkingCopyStore.currentBaseDirectory(applicationSupport: support)
        XCTAssertEqual(current.path, "/tmp/some-app-support/Deck/working-copies")
    }

    func testLegacyBaseDirectoryIsTheOldConvivyNestedPath() {
        let support = URL(fileURLWithPath: "/tmp/some-app-support")
        let legacy = WorkingCopyStore.legacyBaseDirectory(applicationSupport: support)
        XCTAssertEqual(legacy.path, "/tmp/some-app-support/Convivy/Deck/working-copies")
    }

    // MARK: - Migration

    /// No legacy directory at all — the common case for a fresh install —
    /// migrates nothing and must not fabricate the destination.
    func testNoLegacyDirectoryMigratesNothing() {
        let root = tempRoot()
        let legacy = root.appendingPathComponent("legacy")
        let current = root.appendingPathComponent("current")

        let count = WorkingCopyStore.migrateLegacyWorkingCopies(from: legacy, to: current)

        XCTAssertEqual(count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    }

    /// A file nested several directories deep (the shape `directory(forKBId:)`
    /// and `directory(forAbsolutePath:)` actually produce) moves to the same
    /// relative position under the new root.
    func testANestedFileMovesToTheSameRelativePosition() throws {
        let root = tempRoot()
        let legacy = root.appendingPathComponent("legacy")
        let current = root.appendingPathComponent("current")
        let nested = legacy.appendingPathComponent("kb/deck/specs")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "draft content".write(to: nested.appendingPathComponent("session-pane.draft.md"),
                                  atomically: true, encoding: .utf8)

        let count = WorkingCopyStore.migrateLegacyWorkingCopies(from: legacy, to: current)

        XCTAssertEqual(count, 1)
        let migrated = current.appendingPathComponent("kb/deck/specs/session-pane.draft.md")
        XCTAssertEqual(try String(contentsOf: migrated, encoding: .utf8), "draft content")
    }

    /// THE CASE THE MIGRATION MUST NEVER GET WRONG: a file already present at
    /// the destination is not overwritten by whatever the legacy side holds,
    /// and the legacy copy is left in place rather than deleted out from under
    /// a mismatched pair.
    func testAFileAtBothPathsKeepsTheDestinationAndLeavesTheSourceAlone() throws {
        let root = tempRoot()
        let legacy = root.appendingPathComponent("legacy/kb/doc")
        let current = root.appendingPathComponent("current/kb/doc")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try "old draft".write(to: legacy.appendingPathComponent("doc.draft.md"),
                              atomically: true, encoding: .utf8)
        try "already-open draft".write(to: current.appendingPathComponent("doc.draft.md"),
                                       atomically: true, encoding: .utf8)

        let count = WorkingCopyStore.migrateLegacyWorkingCopies(
            from: root.appendingPathComponent("legacy"), to: root.appendingPathComponent("current"))

        XCTAssertEqual(count, 0, "the colliding file must not count as migrated")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("doc.draft.md"),
                                  encoding: .utf8), "already-open draft",
                       "the destination file must win")
        XCTAssertEqual(try String(contentsOf: legacy.appendingPathComponent("doc.draft.md"),
                                  encoding: .utf8), "old draft",
                       "the source file must survive untouched rather than being deleted")
    }

    /// A directory holding one colliding file and one clean file: the clean
    /// file still migrates even though its sibling did not.
    func testACollisionInOneFileDoesNotBlockASiblingFromMigrating() throws {
        let root = tempRoot()
        let legacyDir = root.appendingPathComponent("legacy/kb/doc")
        let currentDir = root.appendingPathComponent("current/kb/doc")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentDir, withIntermediateDirectories: true)
        try "old".write(to: legacyDir.appendingPathComponent("collide.md"),
                        atomically: true, encoding: .utf8)
        try "new".write(to: currentDir.appendingPathComponent("collide.md"),
                        atomically: true, encoding: .utf8)
        try "clean".write(to: legacyDir.appendingPathComponent("editor.html"),
                          atomically: true, encoding: .utf8)

        let count = WorkingCopyStore.migrateLegacyWorkingCopies(
            from: root.appendingPathComponent("legacy"), to: root.appendingPathComponent("current"))

        XCTAssertEqual(count, 1)
        XCTAssertEqual(try String(contentsOf: currentDir.appendingPathComponent("editor.html"),
                                  encoding: .utf8), "clean")
        XCTAssertEqual(try String(contentsOf: currentDir.appendingPathComponent("collide.md"),
                                  encoding: .utf8), "new", "the destination file must still win")
    }

    /// A fully-migrated legacy tree is pruned away rather than left behind as
    /// permanent clutter.
    func testAFullyMigratedLegacyTreeIsPruned() throws {
        let root = tempRoot()
        let legacy = root.appendingPathComponent("legacy")
        let current = root.appendingPathComponent("current")
        let nested = legacy.appendingPathComponent("path/Users/" + "operator" + "/notes")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "hello".write(to: nested.appendingPathComponent("todo.md"), atomically: true, encoding: .utf8)

        _ = WorkingCopyStore.migrateLegacyWorkingCopies(from: legacy, to: current)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "an emptied legacy tree must not linger")
    }

    /// A legacy tree left with a collision survivor is NOT pruned — deleting
    /// it would destroy the very file the collision guard just protected.
    func testALegacyTreeWithASurvivingCollisionIsNotPruned() throws {
        let root = tempRoot()
        let legacy = root.appendingPathComponent("legacy/kb/doc")
        let current = root.appendingPathComponent("current/kb/doc")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try "old draft".write(to: legacy.appendingPathComponent("doc.draft.md"),
                              atomically: true, encoding: .utf8)
        try "already-open draft".write(to: current.appendingPathComponent("doc.draft.md"),
                                       atomically: true, encoding: .utf8)

        _ = WorkingCopyStore.migrateLegacyWorkingCopies(
            from: root.appendingPathComponent("legacy"), to: root.appendingPathComponent("current"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("doc.draft.md").path),
                      "the surviving file, and the directory holding it, must remain")
    }

    /// Running the migration twice (a second launch after the first already
    /// migrated everything) is a cheap no-op, not a re-scan that finds
    /// anything to move.
    func testRunningTwiceMigratesNothingTheSecondTime() throws {
        let root = tempRoot()
        let legacy = root.appendingPathComponent("legacy")
        let current = root.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "hello".write(to: legacy.appendingPathComponent("todo.md"), atomically: true, encoding: .utf8)

        let first = WorkingCopyStore.migrateLegacyWorkingCopies(from: legacy, to: current)
        let second = WorkingCopyStore.migrateLegacyWorkingCopies(from: legacy, to: current)

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0, "the legacy tree was pruned after the first run — nothing is left to find")
    }
}
