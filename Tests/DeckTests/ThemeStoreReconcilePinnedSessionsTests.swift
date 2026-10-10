import XCTest
@testable import Deck

/// `ThemeStore.reconcilePinnedSessions` — the per-crew, per-host driver
/// around `PinnedSessionReconcile`'s pure rule: resolves each crew's host,
/// filters the discovered set down to it, applies the rule, and commits
/// exactly once when anything actually changed. See
/// `PinnedSessionReconcileTests` for the rule itself.
final class ThemeStoreReconcilePinnedSessionsTests: XCTestCase {
    private let mini = TestHost.target
    private let hosts = [HostEntry(name: "mini", user: TestHost.user, address: TestHost.address)]

    private func url() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-reconcilepinned-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("theme.json")
    }

    private func discovered(_ name: String, sessionId: String? = nil) -> DiscoveredSession {
        DiscoveredSession(name: name, host: mini, sessionId: sessionId)
    }

    // MARK: - A rename persists, and reports where to move keyed state

    @MainActor
    func testARenameUpdatesTheSavedPinAndReportsTheOldAndNewName() throws {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask", host: "mini"))
        store.addPinnedSession(
            PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$19"),
            toCrew: SessionRef(host: "mini", name: "ask"))

        let renames = store.reconcilePinnedSessions(
            discovered: [discovered("ask--research-v2", sessionId: "$19")],
            hosts: hosts, defaultHost: nil)

        XCTAssertEqual(renames, [.init(crewHost: "mini", from: "ask--research", to: "ask--research-v2")])
        let ask = try XCTUnwrap((store.configuration.railSessions ?? []).first { $0.id == "ask" })
        XCTAssertEqual(ask.sessions, [
            PinnedSession(name: "ask--research-v2", displayName: "Research", sessionId: "$19"),
        ])
    }

    /// A rename survives a reload from disk — this is the actual
    /// persistence guarantee, not merely the in-memory value.
    @MainActor
    func testARenamePersistsAcrossAReload() throws {
        let fileURL = url()
        let store = ThemeStore(fileURL: fileURL)
        store.addCrew(Crew(id: "ask", displayName: "Ask", host: "mini"))
        store.addPinnedSession(
            PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$19"),
            toCrew: SessionRef(host: "mini", name: "ask"))

        store.reconcilePinnedSessions(
            discovered: [discovered("ask--research-v2", sessionId: "$19")],
            hosts: hosts, defaultHost: nil)

        let reloaded = ThemeConfiguration.load(from: fileURL)
        let ask = try XCTUnwrap(reloaded.railSessions?.first { $0.id == "ask" })
        XCTAssertEqual(ask.sessions.map(\.name), ["ask--research-v2"])
        XCTAssertEqual(ask.sessions.first?.sessionId, "$19")
    }

    /// The per-session theme (`ThemeConfiguration.sessions`, what
    /// `theme(forSession:)` reads) moves onto the new name in the SAME
    /// commit — a color the user picked for the old name must not read as
    /// freshly hashed the moment the pin follows a rename.
    @MainActor
    func testTheChildsPerSessionThemeMovesToTheNewNameInTheSameCommit() throws {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask", host: "mini"))
        store.addPinnedSession(
            PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$19"),
            toCrew: SessionRef(host: "mini", name: "ask"))
        store.setTheme("azure", forSession: SessionRef(host: "mini", name: "ask--research"))

        store.reconcilePinnedSessions(
            discovered: [discovered("ask--research-v2", sessionId: "$19")],
            hosts: hosts, defaultHost: nil)

        XCTAssertNil(store.configuration.sessions[SessionRef(host: "mini", name: "ask--research")])
        XCTAssertEqual(store.configuration.sessions[SessionRef(host: "mini", name: "ask--research-v2")], "azure")
    }

    // MARK: - No id yet: rule (b) records one, with no rename to report

    @MainActor
    func testAPinWithNoIdRecordsTheLiveIdAndReportsNoRename() throws {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask", host: "mini"))
        store.addPinnedSession(PinnedSession(name: "ask--research", displayName: "Research"), toCrew: SessionRef(host: "mini", name: "ask"))

        let renames = store.reconcilePinnedSessions(
            discovered: [discovered("ask--research", sessionId: "$19")],
            hosts: hosts, defaultHost: nil)

        XCTAssertEqual(renames, [])
        let ask = try XCTUnwrap((store.configuration.railSessions ?? []).first { $0.id == "ask" })
        XCTAssertEqual(ask.sessions.first?.sessionId, "$19")
    }

    // MARK: - No write when nothing changed

    /// A pin that already matches its live session exactly (name and id
    /// both agree) must not trigger a save — the property that lets this
    /// run every poll tick with no per-tick write.
    @MainActor
    func testAnAlreadyReconciledPinWritesNothingToDisk() throws {
        let fileURL = url()
        let store = ThemeStore(fileURL: fileURL)
        store.addCrew(Crew(id: "ask", displayName: "Ask", host: "mini"))
        store.addPinnedSession(
            PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$19"),
            toCrew: SessionRef(host: "mini", name: "ask"))
        // `save(to:)` writes `.atomic`ally — write-to-temp then rename-over —
        // which always assigns the destination a NEW inode, whatever the
        // written bytes turn out to be. Comparing the inode number is what
        // catches "committed anyway, but happened to write identical
        // bytes," which a byte or value comparison alone could not.
        let inodeBefore = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.systemFileNumber] as? Int

        let renames = store.reconcilePinnedSessions(
            discovered: [discovered("ask--research", sessionId: "$19")],
            hosts: hosts, defaultHost: nil)

        XCTAssertEqual(renames, [])
        let inodeAfter = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.systemFileNumber] as? Int
        XCTAssertEqual(inodeBefore, inodeAfter,
                       "nothing changed, so the file must not have been rewritten")
    }

    /// The purest form: a crew with no pins at all, and no discovered
    /// sessions either, is a complete no-op.
    @MainActor
    func testACrewWithNoPinsIsANoOp() {
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask", host: "mini"))
        let before = store.configuration

        let renames = store.reconcilePinnedSessions(discovered: [], hosts: hosts, defaultHost: nil)

        XCTAssertEqual(renames, [])
        XCTAssertEqual(store.configuration, before)
    }

    // MARK: - Host scoping

    /// A session discovered on a DIFFERENT host must never reconcile a
    /// crew's pin, even when its name and id happen to match — the same
    /// host boundary `SessionGrouping`/`hasTmuxSession` already enforce.
    @MainActor
    func testASameNameSameIdSessionOnADifferentHostIsIgnored() throws {
        let otherHost = SSHTarget(user: "operator", host: "10.0.0.9")
        let store = ThemeStore(fileURL: url())
        store.addCrew(Crew(id: "ask", displayName: "Ask", host: "mini"))
        store.addPinnedSession(
            PinnedSession(name: "ask--research", displayName: "Research", sessionId: "$19"),
            toCrew: SessionRef(host: "mini", name: "ask"))

        let renames = store.reconcilePinnedSessions(
            discovered: [DiscoveredSession(name: "ask--research-v2", host: otherHost, sessionId: "$19")],
            hosts: hosts, defaultHost: nil)

        XCTAssertEqual(renames, [])
        let ask = try XCTUnwrap((store.configuration.railSessions ?? []).first { $0.id == "ask" })
        XCTAssertEqual(ask.sessions.first?.name, "ask--research", "the stale pin is left exactly as it was")
    }
}
