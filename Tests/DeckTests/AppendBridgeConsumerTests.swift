import XCTest
import WebKit
@testable import Deck

// MARK: - Which rows are safe to apply

/// A delta row's key is checked against `rowKeyPattern` before it is ever
/// used, exactly as `sanitize(openKeys:)` checks a key on the restore path —
/// the same reasoning `platform/contracts/session-page-markup` gives applies
/// here: the key returns inside a script the host evaluates.
final class DeltaRowValidationTests: XCTestCase {

    private func row(_ key: String) -> SessionAgent.DeltaRow {
        SessionAgent.DeltaRow(key: key, html: "<div class=turn data-k=\"\(key)\">x</div>")
    }

    func testAUuidKeyedRowIsKept() {
        let rows = [row("a8896700-58ca-4c84-be20-13b40bc5e7aa.0")]
        XCTAssertEqual(ConversationWebView.validateRows(rows), rows)
    }

    func testAHashAndADisambiguatedKeyAreKept() {
        let rows = [row("h6dc66093f97f561c"), row("a-1.0~2")]
        XCTAssertEqual(ConversationWebView.validateRows(rows), rows)
    }

    func testARowCarryingAQuoteInItsKeyIsDropped() {
        XCTAssertEqual(ConversationWebView.validateRows([row("a\",alert(1),\"b")]), [])
    }

    func testKeysCarryingScriptPunctuationAreDropped() {
        let hostile = ["a'b", "a\\b", "a<b", "a b", "a\nb", "</script>"].map(row)
        XCTAssertEqual(ConversationWebView.validateRows(hostile), [])
    }

    func testAnOverlongKeyIsDropped() {
        XCTAssertEqual(ConversationWebView.validateRows([row(String(repeating: "a", count: 121))]), [])
    }

    func testALegalKeyAtTheLengthBoundIsKept() {
        let rows = [row(String(repeating: "a", count: 120))]
        XCTAssertEqual(ConversationWebView.validateRows(rows), rows)
    }

    func testOneBadKeyDoesNotDiscardTheGoodRowsAroundIt() {
        // Degrade per row, the same way the restore path degrades per key: one
        // unreadable row must not drop the rest of the batch.
        let rows = [row("a.0"), row("bad\"key"), row("b.1")]
        XCTAssertEqual(ConversationWebView.validateRows(rows), [row("a.0"), row("b.1")])
    }

    func testAnEmptyListStaysEmpty() {
        XCTAssertEqual(ConversationWebView.validateRows([]), [])
    }
}

// MARK: - The cursor, as pure functions

/// `SessionPaneModel`'s cursor advances only once `ConversationWebView`
/// confirms a delta applied — never when the batch is merely fetched.
///
/// `@MainActor` because `SessionPaneModel` is: the same pattern
/// `NewOutputPillTests` uses for `ConversationScrollState`.
@MainActor
final class DeltaCursorTests: XCTestCase {

    func testCursorAdvancesToTheAppliedLines() {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        XCTAssertNil(model.cursor)
        model.deltaApplied(cursor: 412)
        XCTAssertEqual(model.cursor, 412)
    }

    func testCursorAdvancesAgainOnASubsequentApply() {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        model.deltaApplied(cursor: 10)
        model.deltaApplied(cursor: 55)
        XCTAssertEqual(model.cursor, 55)
    }

    /// `deltaFailed` also kicks a full-render fallback `Task`, which is
    /// fire-and-forget here and never awaited — the assertion below only
    /// depends on the synchronous state change, which happens before that
    /// `Task`'s body ever runs. The session name is one that cannot exist, so
    /// the background fallback is inert even if it does run.
    func testAFailedApplyDropsTheCursorRatherThanKeepingAStaleOne() {
        let model = SessionPaneModel(session: "test-append-bridge-no-such-session", target: TestHost.target)
        model.deltaApplied(cursor: 200)
        XCTAssertEqual(model.cursor, 200)
        model.deltaFailed()
        XCTAssertNil(model.cursor, "a failed apply must not leave a cursor the page cannot back up")
    }
}

// MARK: - applyDeltaOutcome: the decision, driven with a synthetic outcome

/// `SessionPaneModel.applyDeltaOutcome` is the part `applyDelta` and
/// `establishCursorIfNeeded` share after their own ssh round trip — split out
/// exactly so these can drive it with a synthetic `DeltaOutcome` instead of
/// racing a real one. `@MainActor` for the reason `DeltaCursorTests` is.
@MainActor
final class DeltaOutcomeApplicationTests: XCTestCase {

    private func row(_ key: String = "a.0") -> SessionAgent.DeltaRow {
        SessionAgent.DeltaRow(key: key, html: "<div class=turn data-k=\"\(key)\">x</div>")
    }

    /// THE FIX FOR THE PROBE'S BIAS. `establishCursorIfNeeded` used to keep
    /// only the row count and throw the rows themselves away; on a
    /// transcript that only grows, that count is always at least as high as
    /// what the page already holds, so the cursor could land ahead of the
    /// page with nothing left to re-offer the gap. Publishing the rows
    /// instead — the same as an ordinary delta — makes the cursor and the
    /// page agree by construction: the rows land idempotently on the page's
    /// existing `data-k` keys, and `deltaApplied` is still the only place
    /// the cursor itself advances.
    func testAProbeOutcomePublishesItsRowsRatherThanDiscardingThem() async {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        let rows = [row("a.0"), row("a.1")]
        let accepted = await model.applyDeltaOutcome(
            .rows(lines: 50, rows: rows, removed: []), fetchedAtGeneration: 0,
            isProbe: true, appearance: .dark)

        XCTAssertTrue(accepted)
        XCTAssertNil(model.cursor, "the probe must publish rows for the view to apply, not set the cursor directly")
        XCTAssertEqual(model.pendingDelta?.rows, rows)
        XCTAssertEqual(model.pendingDelta?.cursor, 50)
    }

    /// `removed` is carried through to `pendingDelta` the same way `rows`
    /// is — this is the whole reason the field exists on `PendingDelta` at
    /// all, so `ConversationWebView` has something to apply.
    func testARemovedListIsCarriedThroughToThePendingDelta() async {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        let accepted = await model.applyDeltaOutcome(
            .rows(lines: 50, rows: [], removed: ["a.0", "b.1"]), fetchedAtGeneration: 0,
            isProbe: false, appearance: .dark)

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.pendingDelta?.removed, ["a.0", "b.1"])
    }

    /// THE RE-CHECK AFTER THE AWAIT. The probe's first guard — `cursor ==
    /// nil` before it ever asks the mini — cannot see something that
    /// happens while its own ssh round trip is in flight: a full page's own
    /// meta, or a second probe, learning the cursor first. Without a second
    /// check here, this outcome would land anyway and clobber whichever one
    /// got there first.
    func testAProbeOutcomeIsRefusedWhenSomethingElseSetTheCursorWhileItWasInFlight() async {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        model.deltaApplied(cursor: 99)
        let accepted = await model.applyDeltaOutcome(
            .rows(lines: 5, rows: [row()], removed: []), fetchedAtGeneration: 0,
            isProbe: true, appearance: .dark)

        XCTAssertFalse(accepted, "a probe must not clobber a cursor learned while its fetch was in flight")
        XCTAssertEqual(model.cursor, 99)
        XCTAssertNil(model.pendingDelta)
    }

    /// The re-check above is the probe's own extra caution — an ordinary
    /// delta is only ever fetched once a cursor is already known, so
    /// `isProbe: false` must not require `cursor == nil`.
    func testAnOrdinaryDeltaOutcomeIsNotSubjectToTheProbesCursorGuard() async {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        model.deltaApplied(cursor: 40)
        let accepted = await model.applyDeltaOutcome(
            .rows(lines: 55, rows: [row()], removed: []), fetchedAtGeneration: 0,
            isProbe: false, appearance: .dark)

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.pendingDelta?.cursor, 55)
    }

    /// THE APPEARANCE-CHANGE RACE. A re-render started while this outcome's
    /// fetch was in flight repaints the page under a new theme; this batch
    /// was rendered for the OLD one. Applying it now would splice
    /// stale-theme rows onto the fresh page — they match by `data-k` and
    /// land as a silent replace, behind the new cursor, so nothing would
    /// ever re-offer them. `reRender` bumps `renderGeneration` before
    /// its own await completes, so a fetch captured at generation 0 is
    /// stale the moment a render has happened since.
    func testADeltaOutcomeFetchedUnderAnOlderGenerationIsRefusedAfterAReRenderBumpsIt() async {
        let model = SessionPaneModel(session: "test-append-bridge-no-such-session", target: TestHost.target)
        await model.reRender(appearance: .dark)

        let accepted = await model.applyDeltaOutcome(
            .rows(lines: 50, rows: [row()], removed: []), fetchedAtGeneration: 0,
            isProbe: false, appearance: .dark)

        XCTAssertFalse(accepted, "a delta fetched under a superseded render generation must be refused")
        XCTAssertNil(model.pendingDelta)
    }

    /// The same fetch, against the generation still current, is accepted —
    /// the guard above is about staleness, not about refusing everything.
    func testADeltaOutcomeFetchedUnderTheCurrentGenerationIsAccepted() async {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        let accepted = await model.applyDeltaOutcome(
            .rows(lines: 50, rows: [row()], removed: []), fetchedAtGeneration: 0,
            isProbe: false, appearance: .dark)

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.pendingDelta?.cursor, 50)
    }

    /// THE `.unavailable`/`nil` BRANCH NOW MATCHES `.full`. Both trigger a
    /// fresh `reRender`, and `cursorRead(fromMeta:)` only adopts that fresh
    /// page's own count when `cursor == nil` — so leaving a stale cursor in
    /// place here, unlike the `.full` case, would have stopped the new page
    /// from ever re-syncing off its own meta.
    func testAnUnavailableOutcomeClearsTheCursorBeforeReRenderingSoTheFreshPageCanReSync() async {
        let model = SessionPaneModel(session: "test-append-bridge-no-such-session", target: TestHost.target)
        model.deltaApplied(cursor: 30)

        _ = await model.applyDeltaOutcome(nil, fetchedAtGeneration: 0, isProbe: false, appearance: .dark)

        XCTAssertNil(model.cursor, "an unavailable/nil outcome must clear the cursor the same way .full does")
    }

    /// The probe takes no such fallback: it is already running against a
    /// page that was just rendered, so re-rendering again from here would
    /// just re-trigger the render that spawned it. The cursor is already
    /// nil going in — see `establishCursorIfNeeded`'s own guard — so there
    /// is nothing for this outcome to clear either.
    func testAnUnavailableProbeOutcomeDoesNothingRatherThanChasingWithAnotherRender() async {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        let accepted = await model.applyDeltaOutcome(nil, fetchedAtGeneration: 0, isProbe: true, appearance: .dark)

        XCTAssertTrue(accepted)
        XCTAssertNil(model.cursor)
        XCTAssertNil(model.pendingDelta)
    }

    /// THE HELD ROW'S DISAPPEARANCE, REPRODUCED WITHOUT SSH.
    /// `issue_01M3NWD9SFBS9DT434MVM0D663`: a message queued then absorbed in
    /// quick succession fires two delta fetches before either is confirmed
    /// drawn (see `nextFetchCursor`'s doc for why the second is scoped from
    /// the first's own returned cursor rather than the last drawn one).
    /// Fetch 1 answers while the message is still held — a row for it,
    /// `newest: true`. Fetch 2, scoped from fetch 1's own cursor, answers
    /// after it resolves — no held row, and its withdrawal in `removed`,
    /// exactly what a live mini answered when asked the same way. Before
    /// this fix, the second `applyDeltaOutcome` call REPLACED `pendingDelta`
    /// outright, so the held row's insert was thrown away before the view
    /// ever drew it and the withdrawal had nothing left to withdraw.
    func testAHeldRowFromAnUnconfirmedFetchIsWithdrawnRatherThanDrawnBeforeEitherIsDrawn() async {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        let heldRow = SessionAgent.DeltaRow(
            key: "~held.0.fc0afe2a33cc5086",
            html: "<div class=\"turn you held\" data-k=\"~held.0.fc0afe2a33cc5086\">queued</div>",
            newest: true)

        // Fetch 1: the message is still held when the mini answers.
        let accepted1 = await model.applyDeltaOutcome(
            .rows(lines: 80, rows: [row("a.0"), heldRow], removed: []),
            fetchedAtGeneration: 0, isProbe: false, appearance: .dark)
        XCTAssertTrue(accepted1)
        XCTAssertEqual(model.pendingDelta?.rows, [row("a.0"), heldRow],
                       "fetch 1 alone must publish the held row")

        // `model.cursor` is still nil here — nothing has confirmed fetch 1
        // drawn — so a second, real dispatch would have used
        // `nextFetchCursor(cursor: 68, pendingDelta: model.pendingDelta)`,
        // i.e. 80 (fetch 1's own answer), never 68 again. Fetch 2, scoped
        // that way, is exactly what a live mini answered: no held row, and
        // its withdrawal.
        let accepted2 = await model.applyDeltaOutcome(
            .rows(lines: 89, rows: [row("b.0")], removed: ["~held.0.fc0afe2a33cc5086"]),
            fetchedAtGeneration: 0, isProbe: false, appearance: .dark)
        XCTAssertTrue(accepted2)

        // `mergedRows` drops fetch 1's held row from `rows` because fetch 2's
        // `removed` names it — the view would only insert it and take it
        // straight back out again, and a row that never lands avoids that
        // churn while landing at the identical final DOM state. `removed`
        // still carries the key, so a mini-side render that HAD already
        // drawn it (this pane's own earlier confirmed batch, not this test)
        // still gets told to take it down.
        XCTAssertEqual(model.pendingDelta?.rows, [row("a.0"), row("b.0")],
                       "a key fetch 2 withdraws must not still be offered as a row to draw")
        XCTAssertEqual(model.pendingDelta?.removed, ["~held.0.fc0afe2a33cc5086"],
                       "fetch 2's withdrawal must still reach the batch that will actually draw the page")
        XCTAssertEqual(model.pendingDelta?.cursor, 89)
    }

    /// THE ROUND-2 REGRESSION: `render_delta` (the mini's own endpoint)
    /// resends the CURRENT held set in full on every call, so two fetches
    /// landing while the same message is still held — no `removed` between
    /// them — carry the identical row. Before `mergedRows`, plain
    /// concatenation put that key in the merged batch twice, and
    /// `ConversationWebView.applyDeltaBody`'s pre-loop DOM snapshot read the
    /// second occurrence as unseen and inserted a second node for one key
    /// (round 2 review, `deck-reviewer`). Drives the full production path —
    /// `applyDeltaOutcome` for both fetches, then the merged batch through a
    /// live `WKWebView` — so a regression here shows up as a real duplicate
    /// node, not just a duplicate array entry.
    func testTwoFetchesResendingTheSameHeldRowLandAsOneDOMNode() async throws {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        let heldRow = SessionAgent.DeltaRow(
            key: "~held.0.fc0afe2a33cc5086",
            html: "<div class=\"turn you held\" data-k=\"~held.0.fc0afe2a33cc5086\">queued</div>",
            newest: true)

        _ = await model.applyDeltaOutcome(
            .rows(lines: 80, rows: [row("a.0"), heldRow], removed: []),
            fetchedAtGeneration: 0, isProbe: false, appearance: .dark)
        // Fetch 2 lands while the message is STILL held — the mini resends
        // the identical row, unchanged, alongside whatever else moved.
        _ = await model.applyDeltaOutcome(
            .rows(lines: 85, rows: [row("b.0"), heldRow], removed: []),
            fetchedAtGeneration: 0, isProbe: false, appearance: .dark)

        let delta = try XCTUnwrap(model.pendingDelta)
        XCTAssertEqual(delta.rows.filter { $0.key == heldRow.key }.count, 1,
                       "the merged batch must carry the held row once, not twice")

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: config)
        let helper = LoadHelper()
        webView.navigationDelegate = helper
        webView.loadHTMLString("<html><body><div class=\"turns\"></div></body></html>", baseURL: nil)
        await helper.waitForLoad()

        let coordinator = ConversationWebView.Coordinator(html: "", onDeckOpen: nil, hosts: [])
        let applied = Expectation()
        coordinator.onDeltaApplied = { _ in applied.fulfill() }
        coordinator.onDeltaFailed = { XCTFail("a legal merged batch must not fall back") }
        ConversationWebView.applyPendingDelta(delta, view: webView, coordinator: coordinator)
        await applied.wait()

        let count = try await webView.callAsyncJavaScript(
            "return document.querySelectorAll('.turns [data-k=\"\(heldRow.key)\"]').length",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(count as? Int, 1, "the held row must land as one DOM node, not two")
        _ = helper
    }

    /// The merge is scoped to an UNCONFIRMED batch only. Once `cursor` has
    /// caught up to what `pendingDelta` already claimed drawn, a fresh
    /// fetch's rows are the whole story again — nothing earlier is still
    /// waiting to be lost, so replacing (not appending forever) is correct.
    func testASecondFetchReplacesRatherThanMergesOnceTheFirstIsConfirmedDrawn() async {
        let model = SessionPaneModel(session: "test-append-bridge", target: TestHost.target)
        _ = await model.applyDeltaOutcome(
            .rows(lines: 80, rows: [row("a.0")], removed: []),
            fetchedAtGeneration: 0, isProbe: false, appearance: .dark)
        model.deltaApplied(cursor: 80)

        _ = await model.applyDeltaOutcome(
            .rows(lines: 89, rows: [row("b.0")], removed: []),
            fetchedAtGeneration: 0, isProbe: false, appearance: .dark)

        XCTAssertEqual(model.pendingDelta?.rows, [row("b.0")],
                       "a fetch confirmed drawn must not keep being re-sent on every later batch")
    }
}

// MARK: - nextFetchCursor: which cursor the NEXT delta fetch is scoped from

/// `SessionPaneModel.nextFetchCursor` is the pure decision `applyStateTransition`
/// uses to choose `--delta-since`'s value — split out the same way
/// `shouldRender` and `backgroundActive` are, so the choice is testable
/// without a pane or an ssh round trip.
@MainActor
final class NextFetchCursorTests: XCTestCase {

    private func row(_ key: String = "a.0") -> SessionAgent.DeltaRow {
        SessionAgent.DeltaRow(key: key, html: "<div class=turn data-k=\"\(key)\">x</div>")
    }

    func testWithNoPendingDeltaTheConfirmedCursorIsUsed() {
        XCTAssertEqual(SessionPaneModel.nextFetchCursor(cursor: 68, pendingDelta: nil), 68)
    }

    /// THE CASE THIS EXISTS FOR. A fetch already sitting in `pendingDelta`,
    /// unconfirmed, answered from a NARROWER window than the confirmed
    /// cursor would give — asking again from the confirmed cursor would
    /// re-open a window a held row's withdrawal cannot be seen from (see
    /// `applyDeltaOutcome`'s merge doc).
    func testWithAnUnconfirmedPendingDeltaItsOwnCursorIsUsedInstead() {
        let pending = SessionPaneModel.PendingDelta(
            generation: 1, cursor: 80, rows: [row()], removed: [])
        XCTAssertEqual(SessionPaneModel.nextFetchCursor(cursor: 68, pendingDelta: pending), 80)
    }
}

// MARK: - An all-invalid batch must fall back rather than advance

/// `ConversationWebView.applyPendingDelta` drops a row that fails the key
/// allowlist and keeps the rest of the batch — `DeltaRowValidationTests`
/// covers that degrade-per-row behaviour via `validateRows`. This covers the
/// batch-level decision one layer up: when EVERY row in a batch fails,
/// nothing is left to draw, and that case must route to the same
/// full-reload fallback every other failure on this path uses, not advance
/// the cursor past content that was never applied.
@MainActor
final class AllInvalidBatchRoutesToFallbackTests: XCTestCase {

    private func freshView() -> WKWebView {
        WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    func testABatchWhoseEveryRowFailsTheAllowlistRoutesToTheFallbackRatherThanAdvancing() {
        let coordinator = ConversationWebView.Coordinator(html: "", onDeckOpen: nil, hosts: [])
        var applied: Int?
        var failed = false
        coordinator.onDeltaApplied = { applied = $0 }
        coordinator.onDeltaFailed = { failed = true }

        let delta = SessionPaneModel.PendingDelta(
            generation: 1, cursor: 99,
            rows: [SessionAgent.DeltaRow(key: "bad\"key", html: "<div>x</div>")], removed: [])
        ConversationWebView.applyPendingDelta(delta, view: freshView(), coordinator: coordinator)

        XCTAssertTrue(failed, "content that failed validation must fall back, not advance silently past it")
        XCTAssertNil(applied)
    }

    /// The contrast case: a batch that legitimately carries no rows and no
    /// removals at all (the cursor moved with nothing new to draw) is not a
    /// failure — nothing was dropped, so nothing needs recovering, and this
    /// must still advance.
    func testAGenuinelyEmptyBatchStillAdvancesTheCursor() {
        let coordinator = ConversationWebView.Coordinator(html: "", onDeckOpen: nil, hosts: [])
        var applied: Int?
        coordinator.onDeltaApplied = { applied = $0 }
        coordinator.onDeltaFailed = { XCTFail("an empty batch carries nothing dropped — it must not fall back") }

        let delta = SessionPaneModel.PendingDelta(generation: 1, cursor: 99, rows: [], removed: [])
        ConversationWebView.applyPendingDelta(delta, view: freshView(), coordinator: coordinator)

        XCTAssertEqual(applied, 99)
    }

    /// A batch with no rows but a real removal must NOT take the
    /// genuinely-empty fast path above — that would advance the cursor
    /// without ever telling the page to drop the row. Driven against a
    /// loaded page carrying the row named, so success is checked the strong
    /// way: the row is actually gone, not merely that some callback fired.
    func testARemovalOnlyBatchIsAppliedRatherThanTakingTheEmptyBatchFastPath() async throws {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: config)
        let helper = LoadHelper()
        webView.navigationDelegate = helper
        webView.loadHTMLString("""
            <html><body><div class="turns">
            <div class="turn" data-k="a.0">first</div>
            <div class="turn" data-k="a.1">second</div>
            </div></body></html>
            """, baseURL: nil)
        await helper.waitForLoad()

        let coordinator = ConversationWebView.Coordinator(html: "", onDeckOpen: nil, hosts: [])
        let applied = Expectation()
        var appliedCursor: Int?
        coordinator.onDeltaApplied = { appliedCursor = $0; applied.fulfill() }
        coordinator.onDeltaFailed = { XCTFail("a removal targeting a row on the page must succeed") }

        let delta = SessionPaneModel.PendingDelta(generation: 1, cursor: 99, rows: [], removed: ["a.1"])
        ConversationWebView.applyPendingDelta(delta, view: webView, coordinator: coordinator)
        await applied.wait()

        XCTAssertEqual(appliedCursor, 99, "a batch that only removes rows still advances the cursor")
        let count = try await webView.callAsyncJavaScript(
            "return document.querySelectorAll('.turns [data-k]').length",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(count as? Int, 1, "the removed row is gone; the other row survives")
        _ = helper
    }
}

/// A minimal async signal, since `applyPendingDelta`'s real-apply path
/// resolves inside a detached `Task` that this test has no other handle on.
@MainActor
private final class Expectation {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fulfilled = false

    func fulfill() {
        fulfilled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if fulfilled { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

// MARK: - A held row's first appearance, through the production apply path

/// `issue_01M3NWD9SFBS9DT434MVM0D663`: a queued message the agent has not
/// read yet stopped showing in the session pane. Drives
/// `ConversationWebView.applyPendingDelta` — the real production function,
/// not `ApplyDeltaBodyTests`' local `apply()` helper, which omits `newest`
/// from its payload and so cannot exercise this — against a page shaped like
/// a real render that has nothing held yet, with a batch shaped like
/// `session-view --delta-since`'s own envelope for a fresh enqueue: one row,
/// `newest: true`, never seen before.
@MainActor
final class HeldRowFirstAppearanceTests: XCTestCase {

    func testAFreshHeldRowAppearsAtTheNewestEnd() async throws {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: config)
        let helper = LoadHelper()
        webView.navigationDelegate = helper
        webView.loadHTMLString("""
            <html><body><div class="turns">
            <div class="turn" data-k="a.0">first</div>
            </div></body></html>
            """, baseURL: nil)
        await helper.waitForLoad()

        let coordinator = ConversationWebView.Coordinator(html: "", onDeckOpen: nil, hosts: [])
        let applied = Expectation()
        var appliedCursor: Int?
        coordinator.onDeltaApplied = { appliedCursor = $0; applied.fulfill() }
        coordinator.onDeltaFailed = { XCTFail("a fresh held row is a legal batch and must not fall back") }

        let delta = SessionPaneModel.PendingDelta(
            generation: 1, cursor: 7,
            rows: [SessionAgent.DeltaRow(
                key: "~held.0.6e1e43d204a079b2",
                html: "<div class=\"turn you held\" data-k=\"~held.0.6e1e43d204a079b2\">you (queued)</div>",
                newest: true)],
            removed: [])
        ConversationWebView.applyPendingDelta(delta, view: webView, coordinator: coordinator)
        await applied.wait()

        XCTAssertEqual(appliedCursor, 7)
        let keys = try await webView.callAsyncJavaScript(
            """
            return Array.from(document.querySelectorAll('.turns [data-k]'))
                .map(function(e){return e.getAttribute('data-k');});
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(keys as? [String], ["~held.0.6e1e43d204a079b2", "a.0"],
                       "the held row lands at the newest end, ahead of the existing turn")
        _ = helper
    }
}

// MARK: - Applying a delta batch: empirical, against a real WKWebView

/// `AppendBridgeCapabilityTests` proved the bound-argument mechanism works
/// for one row. These drive `ConversationWebView.applyDeltaBody` — the actual
/// production script — end to end against markup shaped like a real page,
/// covering the replace-vs-insert decision the bridge exists to make.
@MainActor
final class ApplyDeltaBodyTests: XCTestCase {

    private static let page = """
        <html><body><div class="turns">
        <div class="turn" data-k="a.0">first</div>
        <details data-k="a.1"><summary>Bash(ls)</summary><pre>out</pre></details>
        </div></body></html>
        """

    /// WKWebView holds its navigation delegate weakly, so the helper is
    /// returned alongside the view and retained for the test's lifetime — the
    /// same pattern `AppendBridgeCapabilityTests.loadedWebView` uses.
    private func loadedWebView(_ html: String) async -> (WKWebView, LoadHelper) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            configuration: config)
        let helper = LoadHelper()
        webView.navigationDelegate = helper
        webView.loadHTMLString(html, baseURL: nil)
        await helper.waitForLoad()
        return (webView, helper)
    }

    private func apply(_ rows: [SessionAgent.DeltaRow], removed: [String] = [],
                       to webView: WKWebView) async throws -> [String: Any] {
        // `newest` rides along here, matching the production payload
        // (`ConversationWebView.applyPendingDelta`'s `payload`) exactly — the
        // reposition branch below only takes effect when it is present.
        let payload = rows.map { ["key": $0.key, "html": $0.html, "newest": $0.newest] as [String: Any] }
        let value = try await webView.callAsyncJavaScript(
            ConversationWebView.applyDeltaBody,
            // `tolerance` is bound alongside `rows` because the script reads it
            // to decide whether to hold a scrolled-up reader's position. It is
            // not optional: an unbound identifier in the function body fails the
            // whole call, which is how these five tests caught its addition —
            // `removed` earns the same discipline now it exists too.
            arguments: ["rows": payload,
                        "removed": removed,
                        "tolerance": ConversationWebView.atBottomTolerance],
            in: nil,
            contentWorld: .page)
        return try XCTUnwrap(value as? [String: Any])
    }

    /// A row whose key is already on the page is replaced in place — the
    /// count does not grow, and the new content lands where the old row was.
    func testAKnownKeyReplacesTheExistingRow() async throws {
        let (webView, helper) = await loadedWebView(Self.page)
        let dict = try await apply(
            [SessionAgent.DeltaRow(key: "a.0", html: "<div class=\"turn\" data-k=\"a.0\">first, now with a reply</div>")],
            to: webView)

        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["inserted"] as? Bool, false, "a replace is not an insert")

        let count = try await webView.callAsyncJavaScript(
            "return document.querySelectorAll('.turns [data-k]').length",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(count as? Int, 2, "replacing must not change the row count")

        let text = try await webView.callAsyncJavaScript(
            "return document.querySelector('.turns [data-k=\"a.0\"]').textContent",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(text as? String, "first, now with a reply")
        _ = helper
    }

    /// A `newest` row already on the page is moved to the newest end rather
    /// than replaced in place — the shipped defect
    /// `deck/specs/session-pane-incremental-rendering` describes: a held row
    /// replaced where it sat stayed there while every new transcript row
    /// inserted ahead of it, so a long turn carried it off the top of the
    /// viewport. The row count must not grow, since this is a reposition of
    /// the one row already present, not an insert of a second.
    func testANewestRowAlreadyOnThePageIsRepositionedNotReplaced() async throws {
        let (webView, helper) = await loadedWebView("""
            <html><body><div class="turns">
            <div class="turn you held" data-k="~held.0.aa">you (queued)</div>
            <div class="turn" data-k="a.0">first</div>
            </div></body></html>
            """)
        let dict = try await apply(
            [SessionAgent.DeltaRow(key: "~held.0.aa",
                html: "<div class=\"turn you held\" data-k=\"~held.0.aa\">you (queued)</div>",
                newest: true)],
            to: webView)

        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["inserted"] as? Bool, false,
                       "a held row returning to a position it already held is not new output")

        let keys = try await webView.callAsyncJavaScript(
            """
            return Array.from(document.querySelectorAll('.turns [data-k]'))
                .map(function(e){return e.getAttribute('data-k');});
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(keys as? [String], ["~held.0.aa", "a.0"],
                       "the held row stays at the newest end rather than growing a duplicate")
        _ = helper
    }

    /// A REPEATED KEY WITHIN ONE BATCH must not duplicate the DOM node.
    /// `SessionPaneModel.mergedRows` is what keeps this out of a real batch,
    /// but `applyDeltaBody` used to look up a replace/reposition target
    /// against a DOM snapshot taken once before its loop, so a second
    /// occurrence of a key this same call already placed read as unseen and
    /// inserted again. Re-querying the live DOM every iteration (this
    /// change) closes that independently of the merge — the row lands once
    /// no matter which layer a repeat slips past.
    func testARepeatedKeyWithinOneBatchLandsAsOneNode() async throws {
        let (webView, helper) = await loadedWebView("""
            <html><body><div class="turns">
            <div class="turn" data-k="a.0">first</div>
            </div></body></html>
            """)
        let dict = try await apply([
            SessionAgent.DeltaRow(key: "~held.0.aa",
                html: "<div class=\"turn you held\" data-k=\"~held.0.aa\">you (queued)</div>", newest: true),
            SessionAgent.DeltaRow(key: "~held.0.aa",
                html: "<div class=\"turn you held\" data-k=\"~held.0.aa\">you (queued)</div>", newest: true),
        ], to: webView)

        XCTAssertEqual(dict["ok"] as? Bool, true)

        let count = try await webView.callAsyncJavaScript(
            "return document.querySelectorAll('.turns [data-k=\"~held.0.aa\"]').length",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(count as? Int, 1, "a key repeated within one batch must still land as one node")
        _ = helper
    }

    /// A row whose key is not on the page is inserted at the DOM start —
    /// `.turns` is column-reverse, so the DOM start is the visual bottom,
    /// which is where a brand new turn belongs.
    func testAnUnknownKeyIsInsertedAtTheDomStart() async throws {
        let (webView, helper) = await loadedWebView(Self.page)
        let dict = try await apply(
            [SessionAgent.DeltaRow(key: "b.0", html: "<div class=\"turn\" data-k=\"b.0\">second</div>")],
            to: webView)

        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["inserted"] as? Bool, true)

        let firstKey = try await webView.callAsyncJavaScript(
            "return document.querySelector('.turns [data-k]').getAttribute('data-k')",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(firstKey as? String, "b.0", "the newest row is the DOM's first child")

        let count = try await webView.callAsyncJavaScript(
            "return document.querySelectorAll('.turns [data-k]').length",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(count as? Int, 3)
        _ = helper
    }

    /// A batch can carry both kinds of row at once — a tool call's result
    /// folding into it (a replace) alongside the model's next turn (an
    /// insert) — and each is applied in order, correctly, in the one call.
    func testAMixedBatchReplacesAndInsertsInOneCall() async throws {
        let (webView, helper) = await loadedWebView(Self.page)
        let dict = try await apply([
            SessionAgent.DeltaRow(key: "a.1",
                html: "<details data-k=\"a.1\" open><summary>Bash(ls)</summary><pre>out\nmore</pre></details>"),
            SessionAgent.DeltaRow(key: "b.0", html: "<div class=\"turn\" data-k=\"b.0\">new</div>"),
        ], to: webView)

        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["inserted"] as? Bool, true, "one insert in the batch is enough to report it")

        let count = try await webView.callAsyncJavaScript(
            "return document.querySelectorAll('.turns [data-k]').length",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(count as? Int, 3, "one row replaced, one inserted — net one new row")
        _ = helper
    }

    /// A batch that only replaces existing rows — a tool result folding into
    /// its call, with no new turn — reports no insert. This is what the pill
    /// logic gates on: replacing content already on screen is not new output.
    func testAPureReplaceBatchReportsNoInsert() async throws {
        let (webView, helper) = await loadedWebView(Self.page)
        let dict = try await apply(
            [SessionAgent.DeltaRow(key: "a.1",
                html: "<details data-k=\"a.1\" open><summary>Bash(ls)</summary><pre>done</pre></details>")],
            to: webView)
        XCTAssertEqual(dict["inserted"] as? Bool, false)
        _ = helper
    }

    /// A document with no `.turns` — the placeholder page, or one that failed
    /// to load as expected — reports failure rather than doing something
    /// undefined. The caller treats this as needing the full-reload fallback.
    func testNoTurnsElementReportsFailureRatherThanSilentlyDoingNothing() async throws {
        let (webView, helper) = await loadedWebView("<html><body><p>loading…</p></body></html>")
        let dict = try await apply(
            [SessionAgent.DeltaRow(key: "a.0", html: "<div class=\"turn\" data-k=\"a.0\">x</div>")],
            to: webView)
        XCTAssertEqual(dict["ok"] as? Bool, false)
        _ = helper
    }

    /// The bound-argument property `AppendBridgeCapabilityTests` establishes
    /// for a single row also holds when a row is used to REPLACE rather than
    /// insert: hostile characters survive the crossing into the page.
    func testAHostileFragmentSurvivesAReplace() async throws {
        let (webView, helper) = await loadedWebView(Self.page)
        let hostile = "<div class=\"turn\" data-k=\"a.0\">quote \" apos ' backslash \\ close </script> and a backtick `</div>"
        _ = try await apply([SessionAgent.DeltaRow(key: "a.0", html: hostile)], to: webView)

        let text = try await webView.callAsyncJavaScript(
            "return document.querySelector('.turns [data-k=\"a.0\"]').textContent",
            arguments: [:], in: nil, contentWorld: .page)
        let rendered = text as? String ?? ""
        XCTAssertTrue(rendered.contains("quote \""))
        XCTAssertTrue(rendered.contains("apos '"))
        XCTAssertTrue(rendered.contains("backslash \\"))
        XCTAssertTrue(rendered.contains("`"))
        _ = helper
    }

    // MARK: - Removal

    /// A row named in `removed` is taken off the page. It is not new
    /// content, so it must not report an insert either — this is the same
    /// gate `testAPureReplaceBatchReportsNoInsert` checks for a replace.
    func testARemovedKeyIsTakenOffThePage() async throws {
        let (webView, helper) = await loadedWebView(Self.page)
        let dict = try await apply([], removed: ["a.1"], to: webView)

        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["inserted"] as? Bool, false, "a removal is not new output")

        let count = try await webView.callAsyncJavaScript(
            "return document.querySelectorAll('.turns [data-k]').length",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(count as? Int, 1, "the removed row is gone; the other row survives")

        let remainingKey = try await webView.callAsyncJavaScript(
            "return document.querySelector('.turns [data-k]').getAttribute('data-k')",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(remainingKey as? String, "a.0")
        _ = helper
    }

    /// A key that names nothing on the page is not an error — the row may
    /// already be gone, and the client and mini need not agree perfectly.
    func testRemovingAKeyThatIsNotPresentIsNotAnError() async throws {
        let (webView, helper) = await loadedWebView(Self.page)
        let dict = try await apply([], removed: ["not-on-the-page.0"], to: webView)

        XCTAssertEqual(dict["ok"] as? Bool, true)
        let count = try await webView.callAsyncJavaScript(
            "return document.querySelectorAll('.turns [data-k]').length",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(count as? Int, 2, "nothing on the page matched, so nothing changed")
        _ = helper
    }

    /// A batch can carry a row to place AND a row to withdraw at once — the
    /// held-row use case, where a new turn arrives the same beat an earlier
    /// held one is read. Both apply in the one call, and the insert (not the
    /// removal) is what the reported `inserted` flag reflects.
    func testABatchCarryingBothRowsAndRemovalsAppliesBoth() async throws {
        let (webView, helper) = await loadedWebView(Self.page)
        let dict = try await apply(
            [SessionAgent.DeltaRow(key: "b.0", html: "<div class=\"turn\" data-k=\"b.0\">new</div>")],
            removed: ["a.1"], to: webView)

        XCTAssertEqual(dict["ok"] as? Bool, true)
        XCTAssertEqual(dict["inserted"] as? Bool, true)

        let keys = try await webView.callAsyncJavaScript(
            """
            return Array.from(document.querySelectorAll('.turns [data-k]'))
                .map(function(e){return e.getAttribute('data-k');});
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(keys as? [String], ["b.0", "a.0"], "the removed row is gone, the new one is at the DOM start")
        _ = helper
    }
}

// MARK: - Helper

/// Resumes once the in-memory page has loaded, so a script runs against a
/// document that exists. WKWebView holds its delegate weakly, so the caller
/// retains this through the async wait, the same pattern
/// `AppendBridgeCapabilityTests` uses.
@MainActor
private final class LoadHelper: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var loaded = false

    func waitForLoad() async {
        if loaded { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        continuation?.resume()
        continuation = nil
    }
}
