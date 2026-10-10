import XCTest
@testable import Deck

/// `SessionDraftStore` on its own: the plain dictionary semantics
/// `ContentView` and `SessionPaneModel` both build on.
@MainActor
final class SessionDraftStoreTests: XCTestCase {

    func testAnUnwrittenSessionReadsEmpty() {
        let store = SessionDraftStore()
        XCTAssertEqual(store.draft(for: SessionRef(host: nil, name: "deck")), "")
    }

    func testAWriteIsReadBackByTheSameKey() {
        let store = SessionDraftStore()
        let ref = SessionRef(host: nil, name: "deck")
        store.setDraft("still typing this", for: ref)
        XCTAssertEqual(store.draft(for: ref), "still typing this")
    }

    /// The whole reason `SessionRef`, not the bare tmux name, is the key —
    /// two crews on different hosts can share a session name, and their
    /// drafts must not collide.
    func testTwoHostsSharingATmuxNameKeepSeparateDrafts() {
        let store = SessionDraftStore()
        let mini = SessionRef(host: "mini", name: "deck")
        let laptop = SessionRef(host: "laptop", name: "deck")
        store.setDraft("for the mini", for: mini)
        store.setDraft("for the laptop", for: laptop)
        XCTAssertEqual(store.draft(for: mini), "for the mini")
        XCTAssertEqual(store.draft(for: laptop), "for the laptop")
    }

    func testPruneDropsWhatIsNoLongerInTheRoster() {
        let store = SessionDraftStore()
        let kept = SessionRef(host: nil, name: "kept")
        let dropped = SessionRef(host: nil, name: "dropped")
        store.setDraft("keep me", for: kept)
        store.setDraft("drop me", for: dropped)
        store.prune(keeping: [kept])
        XCTAssertEqual(store.draft(for: kept), "keep me")
        XCTAssertEqual(store.draft(for: dropped), "", "pruned entries read back empty, same as never written")
    }

    func testPruneKeepingEverythingChangesNothing() {
        let store = SessionDraftStore()
        let a = SessionRef(host: nil, name: "a")
        let b = SessionRef(host: nil, name: "b")
        store.setDraft("a's text", for: a)
        store.setDraft("b's text", for: b)
        store.prune(keeping: [a, b])
        XCTAssertEqual(store.draft(for: a), "a's text")
        XCTAssertEqual(store.draft(for: b), "b's text")
    }
}

/// `SessionPaneModel`'s wiring to `SessionDraftStore` — the reachable level
/// for an XCTest per the issue this fixes: it can pin that the model reads
/// and writes external storage that survives ITS OWN teardown, which is the
/// property a `.id()`-driven session switch depends on. It cannot pin
/// whether the storage `ContentView` hands a real pane is live at that
/// scope — see `deck/bead` history on convivy-deck#153 for why that gap
/// needs exercising in the running app instead.
@MainActor
final class SessionPaneModelDraftStorageTests: XCTestCase {

    /// Simulates exactly what `.id("pane-...")` does: the old model is
    /// discarded and a fresh one is built for the same session, over the
    /// same store. If the fresh model's initial `draft` were seeded from
    /// anywhere other than live, shared storage, this would read back empty
    /// the way the original bug did.
    func testADraftWrittenByOneModelIsSeenByAFreshModelForTheSameSession() {
        let store = SessionDraftStore()
        let key = SessionRef(host: nil, name: "deck")

        let before = SessionPaneModel(session: "deck", target: TestHost.target,
                                      draftStore: store, draftKey: key)
        before.draft = "half-written prompt"

        // `before` goes out of scope here — the pane's `.id()` teardown.
        let after = SessionPaneModel(session: "deck", target: TestHost.target,
                                     draftStore: store, draftKey: key)
        XCTAssertEqual(after.draft, "half-written prompt")
    }

    /// A different session's storage must not leak in — the same isolation
    /// `testTwoHostsSharingATmuxNameKeepSeparateDrafts` proves at the store
    /// level, proven here through the model's own initializer.
    func testASecondSessionsModelStartsEmptyEvenWithAnotherSessionsDraftPresent() {
        let store = SessionDraftStore()
        let deck = SessionRef(host: nil, name: "deck")
        let vivy = SessionRef(host: nil, name: "vivy")

        let deckModel = SessionPaneModel(session: "deck", target: TestHost.target,
                                         draftStore: store, draftKey: deck)
        deckModel.draft = "for deck"

        let vivyModel = SessionPaneModel(session: "vivy", target: TestHost.target,
                                         draftStore: store, draftKey: vivy)
        XCTAssertEqual(vivyModel.draft, "")
    }

    /// THE ACCEPTANCE TEST: `send()` must actually empty the box, in the
    /// store as well as on the model — this is exactly what broke in #153,
    /// where the write went through but a later read came back stale.
    func testSendClearsTheDraftInBothTheModelAndTheStoreItWritesThrough() {
        let store = SessionDraftStore()
        let key = SessionRef(host: nil, name: "deck")
        let model = SessionPaneModel(session: "deck", target: TestHost.target,
                                     draftStore: store, draftKey: key)
        model.draft = "send this"
        model.send()
        XCTAssertEqual(model.draft, "", "send() clears the composer synchronously, before its ssh round trip")
        XCTAssertEqual(store.draft(for: key), "", "the clear must reach the storage a rebuilt model would read")
    }
}
