import SwiftUI
import WebKit

// MARK: - Scroll state bridge

/// Mediates scroll state between the WKWebView and the native chrome that
/// wraps it.
///
/// `SessionPaneView` owns one as a `@StateObject` and passes it to
/// `ConversationWebView`, which wires its `webView` property in `makeNSView`.
/// The native chrome observes `hasNewOutput` to show the jump affordance when
/// the reader is scrolled up and new turns have arrived.
///
/// The jump affordance calls `scrollToBottom()`, which sets the `.turns`
/// element's scrollTop to 0 — the column-reverse container's "at bottom"
/// position — via host-evaluated JavaScript.
@MainActor
final class ConversationScrollState: ObservableObject {
    /// New turns arrived while the reader is scrolled up.
    @Published private(set) var hasNewOutput = false
    /// The live WKWebView. Set by `ConversationWebView.makeNSView`, cleared
    /// when the view is deallocated.
    weak var webView: WKWebView?

    func markNewOutput() { hasNewOutput = true }
    func clearNewOutput() { hasNewOutput = false }

    func scrollToBottom() {
        // scrollTop = 0 is the column-reverse container's "at bottom": the
        // flex flow starts at the newest turn, so 0 is the natural start.
        let js = "(function(){var t=document.querySelector('.turns');if(t)t.scrollTop=0;})()"
        webView?.evaluateJavaScript(js, completionHandler: nil)
        hasNewOutput = false
    }

    /// Poll-tick entry point: reads scrollTop and delegates to `applyScrollCheck`.
    ///
    /// Called every ~2 s by `SessionPaneView` via the model's `pollCount`.
    /// Returns immediately when `hasNewOutput` is already false, so the JS
    /// evaluation only fires when the pill is actually showing.
    func checkAndClearIfAtBottom() {
        guard hasNewOutput else { return }
        let js = "(function(){var t=document.querySelector('.turns');return t?t.scrollTop:0;})()"
        webView?.evaluateJavaScript(js) { [weak self] result, _ in
            MainActor.assumeIsolated {
                let raw = (result as? Double) ?? ((result as? Int).map(Double.init) ?? 0)
                self?.applyScrollCheck(scrollTop: raw)
            }
        }
    }

    /// Clears `hasNewOutput` when the reader is at the bottom.
    ///
    /// Split from `checkAndClearIfAtBottom` so the state-machine transitions
    /// are testable without a live WKWebView.
    func applyScrollCheck(scrollTop: Double) {
        guard hasNewOutput, ConversationWebView.isAtBottom(scrollTop: scrollTop) else { return }
        hasNewOutput = false
    }

    // MARK: - Pinned last message

    /// The reader's own newest message, shown when it has scrolled off the top
    /// of the conversation. `text` is the FULL body text, uncut — the bar
    /// truncates it for display (`SessionPaneView.pinnedPreview`) but the
    /// accessibility label wants the whole thing, so both are derived from this
    /// one untruncated value rather than the bar caching only what it draws.
    struct PinnedMessage: Equatable {
        let key: String
        let text: String
    }

    /// Shown when the reader's own last message is pinned above the top edge,
    /// nil otherwise. Set only by `applyPinCheck`.
    @Published private(set) var pinnedMessage: PinnedMessage?

    /// Appear once the target's bottom edge is AT OR ABOVE the container's top
    /// edge — fully past, never merely touching it. `edgeOffset` is
    /// `rowRect.bottom - turnsRect.top`, so zero is the boundary itself and a
    /// negative value means the row's bottom has crossed above it.
    static let pinShowThreshold: Double = 0

    /// Hide only once the row has cleared the boundary by more than one line
    /// height, in LINES rather than a fixed pixel count, because the pixel
    /// value moves with the text-scale preference and a fixed number would be
    /// wrong at the extremes. A gap of zero (hide at the same line the show
    /// threshold uses) would flicker the bar at every sub-pixel scroll tick
    /// that straddles the boundary — the same flicker `atBottomTolerance`
    /// exists to absorb on the other pill, but here the fix is a real
    /// hysteresis band rather than a tolerance, because "just past the edge"
    /// is a state the reader should keep seeing, not round away.
    static let pinHideClearanceLines: Double = 1

    /// Applies the hysteresis for one poll tick's reading.
    ///
    /// `candidate` is the reader's current newest non-held `you` turn, freshly
    /// looked up — WHICH message this is can change any time they send a new
    /// one, so a changed key is treated as a different message needing its own
    /// fresh show/hide decision, never as a continuation of the outgoing one's
    /// state. `nil` means no such turn exists (a fresh conversation, or the
    /// `.turns` element itself absent) and always clears the bar.
    ///
    /// Split from `checkPinnedMessage` so the transitions are testable without
    /// a live WKWebView, matching `applyScrollCheck`.
    func applyPinCheck(_ candidate: ConversationWebView.PinCandidate?) {
        guard let candidate else {
            pinnedMessage = nil
            return
        }
        if let current = pinnedMessage, current.key == candidate.key {
            // Already showing this exact message: keep it up unless it has
            // cleared the boundary by the full hysteresis gap. Floored at 1pt
            // so a zero or unreadable computed line-height still yields a real
            // gap rather than collapsing the hysteresis back to the show
            // threshold.
            let clearance = max(candidate.lineHeight, 1) * ConversationScrollState.pinHideClearanceLines
            if candidate.edgeOffset > clearance {
                pinnedMessage = nil
            }
            return
        }
        // A different message than whatever was last tracked (including
        // "nothing was showing"): show only if it is already fully past the
        // top edge. A message merely approaching the edge does not raise the
        // bar early — hysteresis only holds a state open, it never widens
        // when to enter one.
        pinnedMessage = candidate.edgeOffset <= ConversationScrollState.pinShowThreshold
            ? PinnedMessage(key: candidate.key, text: candidate.text)
            : nil
    }

    /// Poll-tick entry point: finds the reader's newest non-held `you` turn and
    /// measures it against the container's top edge.
    ///
    /// Unlike `checkAndClearIfAtBottom`, this runs on every tick unconditionally
    /// rather than short-circuiting when nothing is currently shown — which
    /// message counts as "the reader's last" can change the moment they send a
    /// new one, independent of whatever the bar was doing before this tick.
    func checkPinnedMessage() {
        webView?.evaluateJavaScript(ConversationWebView.pinCheckScript) { [weak self] result, _ in
            MainActor.assumeIsolated {
                self?.applyPinCheck(ConversationWebView.parsePinCandidate(result))
            }
        }
    }

    /// Scrolls to the pinned message — navigation only, per the spec: the
    /// message already exists fully rendered in the transcript, so this finds
    /// that element and brings it into view rather than drawing a second copy
    /// of it. Clears the bar immediately, the same way `scrollToBottom` clears
    /// `hasNewOutput` on click rather than waiting for the next poll tick; the
    /// next tick's fresh geometry reading is what would clear it anyway, once
    /// the target is back on screen.
    func scrollToPinnedMessage() {
        guard let key = pinnedMessage?.key, let webView else { return }
        pinnedMessage = nil
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                ConversationWebView.scrollToElementBody,
                arguments: ["key": key],
                in: nil,
                contentWorld: .page)
        }
    }

    // MARK: - Search

    /// The find bar's backend for this pane. It drives `WKWebView.find`
    /// (highlighting and traversal) and separately counts matches, since
    /// `find` reports only whether one call landed on a match — never how
    /// many exist. See `deck/specs/session-pane-incremental-rendering`: the
    /// document this searches holds the WHOLE transcript, not a tail (verified
    /// against a 3,898-line live session on the mini, `session-view
    /// --render-tmux`, PR body has the numbers), so a search here answering
    /// "no matches" is answering about everything, not a window of it.
    ///
    /// Reuses this type's own `webView` rather than adding a second path to
    /// it — the find bar (a separate surface, issue_01M1S525RMHB9ENTG8DKM24VS6)
    /// drives conversation search through here exactly as the chrome already
    /// drives scroll-to-bottom and the pinned-message bar through it.

    /// The active search term, or nil when nothing is being searched.
    /// `SessionPaneView` wires nothing to this today — it is the narrow API
    /// the find bar item is told to drive, not a control of its own.
    @Published private(set) var searchTerm: String?

    /// 1-based position of the current match within `searchTotal`, or 0 when
    /// there is no current match — no term set, or the last count found
    /// nothing.
    ///
    /// UNLIKE SwiftTerm's `searchMatchSummary`, THIS IS NOT READ BACK FROM
    /// THE ENGINE. `WKWebView.find` reports only `matchFound`, never which
    /// occurrence it landed on, so Deck tracks its own counter: seeded at 1
    /// by `search(_:)` when at least one match exists, then stepped and
    /// wrapped by `findNext`/`findPrevious`. It is only as right as the
    /// assumption that `find` steps through occurrences in the same order
    /// this counts them — true for plain case-insensitive substring matches
    /// in one text run, which is what `.turns`' rendered prose is.
    @Published private(set) var searchIndex = 0

    /// How many matches `search(_:)` counted the last time it ran, capped at
    /// `ConversationWebView.searchMatchCap`. See `searchCapped`.
    @Published private(set) var searchTotal = 0

    /// Whether `searchTotal` hit the cap rather than being the exact count —
    /// the same "capped, and say so" idea the terminal side's
    /// `searchMatchSummary` limit uses. A consumer showing "N of M" should
    /// render M as "cap+" when this is true, not a bare number that reads as
    /// exact when it is not.
    @Published private(set) var searchCapped = false

    /// "3 of 17", "No results", or "1 of 1000+" once `total` hits the cap —
    /// the same shape `TerminalSearchController.label` uses, so the find
    /// bar's count reads identically whichever backend is live. A pure
    /// function, tested directly without a live `WKWebView`, matching that
    /// type's own split between the label mapping and the instance state
    /// that feeds it.
    nonisolated static func label(index: Int, total: Int, capped: Bool) -> String {
        guard total > 0 else { return "No results" }
        let totalLabel = capped ? "\(total)+" : "\(total)"
        return "\(index) of \(totalLabel)"
    }

    /// This instance's own `label(index:total:capped:)` — a plain computed
    /// property, not `@Published`, so it stays correct automatically
    /// whenever any of the three backing fields changes.
    var resultsLabel: String {
        ConversationScrollState.label(index: searchIndex, total: searchTotal, capped: searchCapped)
    }

    /// Starts (or restarts) a search for `term` and moves to its first match.
    /// An empty term clears rather than searching for nothing — the find bar
    /// treats an emptied field as "stop searching."
    func search(_ term: String) {
        guard !term.isEmpty else { clearSearch(); return }
        searchTerm = term
        recount(term, thenSelectFirst: true)
    }

    /// Moves to the next match, wrapping the last back to the first. A no-op
    /// with nothing to move through: no active term, or the count found
    /// zero matches.
    func findNext() {
        guard let term = searchTerm, searchTotal > 0 else { return }
        searchIndex = ConversationScrollState.nextSearchIndex(current: searchIndex, total: searchTotal)
        runFind(term, backwards: false)
    }

    /// The mirror of `findNext`: wraps the first match back to the last.
    func findPrevious() {
        guard let term = searchTerm, searchTotal > 0 else { return }
        searchIndex = ConversationScrollState.previousSearchIndex(current: searchIndex, total: searchTotal)
        runFind(term, backwards: true)
    }

    /// Ends the search: no term, no count, and the native highlight
    /// withdrawn. Called by the find bar when its field empties or the
    /// reader switches away from the conversation surface — a highlight left
    /// up in a pane nobody is looking at is the failure mode this pairs with
    /// on the terminal side.
    ///
    /// `find("")` IS THE CLEAR CALL. WKWebView has no separate "clear
    /// highlight" entry point; an empty search string is WebKit's own way to
    /// withdraw one. `ConversationSearchCapabilityTests` confirms this
    /// empirically against a live WKWebView rather than trusting it as a
    /// documented guarantee, the same discipline `EvaluateJSCapabilityTests`
    /// applies to `evaluateJavaScript`.
    func clearSearch() {
        searchTerm = nil
        searchIndex = 0
        searchTotal = 0
        searchCapped = false
        webView?.find("", configuration: WKFindConfiguration()) { _ in }
    }

    /// Called after the document changes underneath an active search — a
    /// full reload (`Coordinator.webView(_:didFinish:)`) or a landed delta
    /// batch (`ConversationWebView.applyPendingDelta`), the only two places
    /// that mutate `.turns`. A no-op when no search is running.
    ///
    /// THE COUNT IS RECOMPUTED AND THE POSITION RESETS TO THE FIRST MATCH,
    /// RATHER THAN TRYING TO CARRY `searchIndex` FORWARD. There is no
    /// reliable way to say "the match that was 3rd is now which one" across
    /// an arbitrary insert/replace/removal batch or a wholesale reload —
    /// unlike a transcript row's `data-k`, a match has no identity of its
    /// own to look up again. Silently keeping a stale "3 of 17" against a
    /// document that no longer has 17 would be the wrong kind of wrong for a
    /// pane whose whole job is showing what is actually there; resetting is
    /// the honest alternative the issue calls out as the other defensible
    /// choice.
    func documentDidChange() {
        guard let term = searchTerm else { return }
        recount(term, thenSelectFirst: true)
    }

    /// Where `findNext` moves the counter to, wrapping the last match back to
    /// the first. A pure function of the current index and the total, so the
    /// wrap arithmetic is testable without a live WKWebView — the same split
    /// `ConversationWebView.isAtBottom` and `SessionPaneModel.shouldRender`
    /// use elsewhere on this pane.
    nonisolated static func nextSearchIndex(current: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return current >= total ? 1 : current + 1
    }

    /// The mirror of `nextSearchIndex`, wrapping the first match back to the
    /// last.
    nonisolated static func previousSearchIndex(current: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return current <= 1 ? total : current - 1
    }

    /// Drives `WKWebView.find` for one step: case-insensitive and always
    /// wrapping, since `searchIndex`'s own wrap-around already models "past
    /// the last match is the first" and the two must agree.
    private func runFind(_ term: String, backwards: Bool) {
        let config = WKFindConfiguration()
        config.caseSensitive = false
        config.backwards = backwards
        config.wraps = true
        webView?.find(term, configuration: config) { _ in }
    }

    /// Counts `term`'s matches against the live document and publishes the
    /// result, optionally landing on the first one.
    ///
    /// GATED ON THE TERM STILL BEING THE ACTIVE ONE WHEN THE ROUND TRIP
    /// RETURNS — the same discipline `applyDeltaOutcome`'s generation check
    /// uses: a newer `search(_:)` call or a `clearSearch()` may have run
    /// while this was in flight, and its answer belongs to a question that
    /// is no longer being asked.
    private func recount(_ term: String, thenSelectFirst selectFirst: Bool) {
        guard let webView else { return }
        let cap = ConversationWebView.searchMatchCap
        Task { @MainActor [weak self] in
            let value = try? await webView.callAsyncJavaScript(
                ConversationWebView.searchCountBody,
                arguments: ["term": term, "cap": cap],
                in: nil,
                contentWorld: .page)
            guard let self, self.searchTerm == term else { return }
            let (total, capped) = ConversationWebView.parseSearchCount(value)
            self.searchTotal = total
            self.searchCapped = capped
            self.searchIndex = total > 0 ? 1 : 0
            if selectFirst, total > 0 {
                self.runFind(term, backwards: false)
            }
        }
    }
}

// MARK: - Web view

/// Deck's first web pane: the rendered conversation, and nothing else.
///
/// THE BOUNDARY RULE, APPLIED. Chrome is native and document-shaped surfaces are
/// web. This view is only the document — the input box, the state, the gate
/// buttons and the interrupt are native SwiftUI wrapped around it. That split is
/// why this can stay as locked down as it is.
///
/// WHY IT IS LOCKED DOWN. The page is rendered by our own code, but it EMBEDS
/// transcript text — tool output, file contents, pages a session fetched — which
/// is arbitrary and attacker-influenceable. The renderer escapes it, and escaping
/// is exactly the thing that has bugs; that module has already had one.
///
/// THREE SEPARATE MECHANISMS, because they stop different things and confusing
/// them is how a pane ends up less protected than its comments claim:
///
///   * `allowsContentJavaScript = false` stops script executing, and no message
///     handler is registered, so there is no bridge to Swift even if it did.
///   * The **content rule list** blocks network loads. This is the one that stops
///     a passive `<img src="https://attacker/beacon">`, and nothing else here
///     does. The navigation delegate does NOT: it sees navigation actions —
///     clicks, form submits, frame loads — and never sees a subresource fetch.
///     Without this rule an injected image would fire an outbound GET from the
///     laptop, reachable to the local network, which is SSRF rather than nothing.
///   * The **navigation delegate** keeps a click from replacing the document,
///     and sends real links to the browser instead.
///
/// `loadHTMLString(_:baseURL: nil)` gives the document an opaque origin, which
/// stops same-origin access to `file://` and CORS-gated XHR. It is NOT a network
/// block, and reading it as one was the original error here.
///
/// Host-evaluated JavaScript (`evaluateJavaScript`) carries the reader's state
/// across a reload: the `.turns` element's scrollTop, and the keys of the rows
/// they had expanded, read before the load and put back after. This is a
/// DIFFERENT path from page-origin script, which `allowsContentJavaScript =
/// false` stops. `EvaluateJSCapabilityTests` confirms empirically that the two
/// are independent before the code relies on it.
///
/// Both handles are agent-platform's to keep stable, and
/// `platform/contracts/session-page-markup` is where that agreement is written
/// down. Renaming `.turns` or `data-k` on the producing side breaks a feature
/// here with no error on either side, which is why the contract exists.
///
/// This is the pattern every later web pane inherits, so it starts closed and a
/// pane that genuinely needs a capability opts into it explicitly — including,
/// if one ever legitimately loads an asset, relaxing this rule list on purpose.
struct ConversationWebView: NSViewRepresentable {
    /// The rendered page, appearance already stamped into it.
    ///
    /// This view takes no `appearance` of its own, deliberately. The shell
    /// resolves it once and `SessionPaneModel` passes it to the renderer, which
    /// writes `data-theme` into the document — so by the time it arrives here
    /// the decision is made. A field on this type would imply a second place
    /// appearance is decided, which is exactly what the authority rule forbids.
    let html: String

    /// Scroll state shared with the native chrome. The chrome observes
    /// `scrollState.hasNewOutput` to show a "jump to new output" affordance
    /// when the reader is scrolled up and new content has arrived.
    let scrollState: ConversationScrollState

    /// Rows to splice into the live document instead of a full reload, or nil
    /// when nothing is pending. `SessionPaneModel.PendingDelta.generation`
    /// tells a new batch from one already applied, the same way `html`
    /// equality tells a new page from the one already loaded.
    let pendingDelta: SessionPaneModel.PendingDelta?

    /// Called with the delta's cursor once every row in it has been applied
    /// without error. The model advances its cursor only here — never when
    /// the batch is merely fetched — so a failed apply cannot leave the
    /// cursor claiming content that never reached the page.
    var onDeltaApplied: ((Int) -> Void)?

    /// Called when applying the delta could not be trusted to have left the
    /// page consistent: a JS error, or a document with no `.turns` to insert
    /// into. The model responds by falling back to a full reload, which is
    /// always correct.
    var onDeltaFailed: (() -> Void)?

    /// Called once a full page has finished loading, with the delta cursor
    /// read off its `transcript-lines` meta — or nil when the meta was
    /// absent, unparseable, or negative. `SessionPaneModel.cursorRead(fromMeta:)`
    /// is the only production caller: it adopts the value when present, and
    /// falls back to the `establishCursorIfNeeded` probe when not.
    var onCursorRead: ((Int?) -> Void)?

    /// Called when a `deck-open:` link is clicked in the conversation.
    ///
    /// The scheme is an internal command: it is never passed to NSWorkspace,
    /// never added to `ExternalLink.allowedSchemes`, and the navigation is
    /// always cancelled. `DeckOpenRef.validate` runs first; a rejected ref
    /// results in a log line and nothing else, so the callback is only called
    /// with a validated origin.
    var onDeckOpen: ((DeckOpenRef.Origin) -> Void)?

    /// Every configured host, so a `deck-open:` link the reader clicks
    /// validates against the roots they derive rather than a compiled one —
    /// see `DeckOpenRef.allowedPathRoots(hosts:)`.
    let hosts: [HostEntry]

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")

        // Wire the scroll state so the native chrome can call scrollToBottom().
        scrollState.webView = view

        // Compiled asynchronously, and the page is not loaded until it is
        // attached — otherwise the very first document would render before the
        // block took effect, which is the one render most likely to carry
        // whatever an attacker planted.
        NetworkBlock.attach(to: view) { [html] in
            view.loadHTMLString(IssueIdLinkifier.linkify(html), baseURL: nil)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onDeckOpen = onDeckOpen
        context.coordinator.hosts = hosts
        context.coordinator.scrollState = scrollState
        context.coordinator.onDeltaApplied = onDeltaApplied
        context.coordinator.onDeltaFailed = onDeltaFailed
        context.coordinator.onCursorRead = onCursorRead

        // HTML equality check: skip when nothing changed. Setting `lastLoaded`
        // before the async read ensures rapid successive calls don't each start
        // their own load — only the last one proceeds (the guard below rejects
        // any that were superseded).
        if context.coordinator.lastLoaded != html {
            context.coordinator.lastLoaded = html

            let coordinator = context.coordinator
            let targetHTML = html
            let state = scrollState

            // Read BEFORE loading the new document, because the load replaces
            // it and nothing in it survives. Two things are read: the reader's
            // scroll position, and the keys of the rows they have expanded.
            //
            // The `.turns` element is the scroller (not the body) in the
            // column-reverse layout; scrollTop = 0 is "at the bottom" (newest
            // content), higher values mean the reader has scrolled up into
            // history.
            view.evaluateJavaScript(ConversationWebView.readScript) { result, _ in
                // Guard: another update may have superseded this one while the
                // read was in flight. If so, the newer update owns the load.
                guard coordinator.lastLoaded == targetHTML else { return }

                // evaluateJavaScript completion fires on the main thread;
                // MainActor.assumeIsolated asserts that to access @MainActor
                // state.
                MainActor.assumeIsolated {
                    let (raw, heightBefore, openKeys) =
                        ConversationWebView.parseReadResult(result)
                    let atBottom = ConversationWebView.isAtBottom(scrollTop: raw)
                    coordinator.savedScrollTop = atBottom ? nil : raw
                    // Kept beside the offset because the offset is meaningless
                    // without it: the replacement document is normally taller,
                    // and `restoreScript` spends this to say by how much.
                    coordinator.savedScrollHeight = atBottom ? nil : heightBefore
                    // Open rows are saved whatever the scroll position. A
                    // reader at the bottom watching a tool call unfold is the
                    // case this defect hurt most, and it is the one an
                    // at-bottom early return would have missed.
                    coordinator.savedOpenKeys = openKeys
                    // Reader was already at the bottom when output arrived:
                    // clear the pill immediately. Reader was scrolled up:
                    // raise it.
                    if atBottom { state.clearNewOutput() } else { state.markNewOutput() }
                    view.loadHTMLString(IssueIdLinkifier.linkify(targetHTML), baseURL: nil)
                }
            }
            // A full reload is about to replace the document outright, so any
            // delta batch still pending belongs to the page being discarded.
            // `pendingDelta` itself may still ask for the same generation once
            // the new page has loaded and re-established a cursor — this only
            // stops this pass from applying it against a document that is
            // about to disappear.
            return
        }

        // No reload in flight: apply any new delta batch in place instead.
        if let delta = pendingDelta,
           context.coordinator.lastAppliedDeltaGeneration != delta.generation {
            context.coordinator.lastAppliedDeltaGeneration = delta.generation
            ConversationWebView.applyPendingDelta(delta, view: view, coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(html: html, onDeckOpen: onDeckOpen, hosts: hosts)
    }

    // MARK: - At-bottom predicate

    /// Whether the reader is at the bottom — the newest turn — within the
    /// given pixel tolerance.
    ///
    /// In the column-reverse scroller, scrollTop = 0 is the "at bottom"
    /// position: the flex flow starts at the newest turn, so a fresh document
    /// naturally begins there. Higher scrollTop values mean the reader has
    /// scrolled up toward older turns.
    ///
    /// The 5 px tolerance absorbs sub-pixel fractional offsets (common on
    /// high-DPI displays) and the one-pixel nudge some trackpad drivers
    /// produce at the end of a momentum scroll. `nonisolated` for the same
    /// reason as `shouldRender` and `backgroundActive`: a pure function of
    /// two numbers that reaches no actor state.
    /// MEASURED, NOT REASONED, AND THE PREVIOUS VERSION WAS WRONG. This read
    /// `scrollTop <= tolerance`, on the belief that a column-reverse container
    /// scrolls from 0 at the bottom UP through positive values. WebKit does the
    /// opposite: 0 is the bottom and history is NEGATIVE. Probed against a real
    /// rendered conversation page on 2026-08-08 — at rest `scrollTop` is 0,
    /// assigning `+60` clamps back to 0, assigning `-60` sticks.
    ///
    /// So every reachable value satisfied `<= tolerance` and this returned true
    /// unconditionally. Two shipped features were dead as a result: the
    /// jump-to-new-output pill could never rise, since it is cleared whenever
    /// the reader reads as at-bottom, and #71's scroll restoration always stored
    /// `nil` and put nothing back.
    ///
    /// The magnitude is what the question actually asks — how far from the
    /// newest turn, in either direction — so a sign convention cannot invert it
    /// again.
    nonisolated static func isAtBottom(scrollTop: Double,
                                       tolerance: Double = atBottomTolerance) -> Bool {
        abs(scrollTop) <= tolerance
    }

    /// The one definition of "close enough to the bottom to count as at it".
    ///
    /// Named rather than left as a literal default because `applyDeltaBody`
    /// needs the SAME number: the script decides whether to compensate the
    /// reader's scroll position for content added below them, and this
    /// predicate decides whether the jump-to-new-output pill should rise.
    /// Two literals would let those drift into disagreeing about where the
    /// bottom is, which reads as the pill appearing for a reader who is
    /// already there.
    nonisolated static let atBottomTolerance: Double = 5

    // MARK: - Open-row preservation

    /// What a row key may contain, and the reason this is a regex rather than
    /// an escape.
    ///
    /// A key arrives from `data-k` in a page built from the transcript, which
    /// is a file Deck does not write and tool output flows through. It then
    /// goes back out inside JavaScript the host evaluates against the page. So
    /// the key is checked against the shape agent-platform promises rather than
    /// escaped on the way out: a key that does not match is dropped, and its
    /// row simply does not reopen.
    ///
    /// The shape is `platform/contracts/session-page-markup`: a record uuid and
    /// a block index, a `h`-prefixed content hash, either optionally carrying a
    /// `~n` disambiguator.
    nonisolated static let rowKeyPattern = "^[A-Za-z0-9._~-]{1,120}$"

    /// How many open rows are carried across a reload.
    ///
    /// A bound, because the key list is interpolated into a script and the
    /// reader's open rows are unbounded in principle. 500 is far above what a
    /// person opens by hand and far below what would make the script large.
    nonisolated static let maxRestoredRows = 500

    /// The keys worth putting back, from whatever the page returned.
    ///
    /// Drops anything off-shape, de-duplicates, and truncates to the bound.
    /// `nonisolated` for the same reason as `isAtBottom`: a pure function that
    /// reaches no actor state.
    nonisolated static func sanitize(openKeys: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for key in openKeys {
            guard key.range(of: rowKeyPattern, options: .regularExpression) != nil else { continue }
            guard seen.insert(key).inserted else { continue }
            out.append(key)
            if out.count == maxRestoredRows { break }
        }
        return out
    }

    /// The script that reads what must survive the reload: the scroll position
    /// and the keys of every open row.
    ///
    /// One read rather than two, so both halves describe the same instant.
    /// `scrollHeight` travels with the other two because the document about to
    /// replace this one is usually TALLER, and the reader has to be put back
    /// relative to the bottom rather than at a raw pixel offset. See
    /// `restoreScript`, which spends it.
    nonisolated static let readScript = """
        (function(){var t=document.querySelector('.turns');\
        var d=document.querySelectorAll('details[open][data-k]');var o=[];\
        for(var i=0;i<d.length;i++){o.push(d[i].getAttribute('data-k'));}\
        return {scrollTop:t?t.scrollTop:0,scrollHeight:t?t.scrollHeight:0,open:o};})()
        """

    /// Splits `readScript`'s result into the two things it carries.
    ///
    /// Every field degrades on its own: a result that is not a dictionary, a
    /// missing scrollTop, an `open` that is not an array of strings all yield
    /// the same thing a fresh page would. This runs against a page built from a
    /// transcript, so a shape it does not expect is a case to survive.
    nonisolated static func parseReadResult(_ result: Any?)
        -> (scrollTop: Double, scrollHeight: Double, openKeys: [String]) {
        guard let dict = result as? [String: Any] else { return (0, 0, []) }
        let raw = dict["scrollTop"]
        let scrollTop = (raw as? Double) ?? ((raw as? Int).map(Double.init) ?? 0)
        let rawHeight = dict["scrollHeight"]
        let scrollHeight = (rawHeight as? Double) ?? ((rawHeight as? Int).map(Double.init) ?? 0)
        let keys = (dict["open"] as? [Any])?.compactMap { $0 as? String } ?? []
        return (scrollTop, scrollHeight, sanitize(openKeys: keys))
    }

    // MARK: - Pinned last message

    /// The bound the pin-check script slices `textContent` to before handing
    /// it back over the bridge.
    ///
    /// This is a payload-size guard, not the visible truncation — that one is
    /// `SessionPaneView.pinnedPreview`, which cuts to a single line's worth of
    /// characters and runs on whatever this bound lets through. The plan's own
    /// measurement found a 192,068-character queued message in the corpus, and
    /// polling that whole string across the bridge every ~2s for a bar that
    /// shows one truncated line would be pure waste. 4000 characters is far
    /// past anything a person types by hand — the pathological case is
    /// dispatch-prompt text, not prose — so this bound is never visible in
    /// practice; `pinnedPreview`'s much shorter cut is what a reader sees.
    nonisolated static let pinCandidateTextBridgeBound = 4_000

    /// What one poll tick reads off the page for the pinned-message bar,
    /// before `ConversationScrollState.applyPinCheck` turns it into a decision.
    nonisolated struct PinCandidate {
        let key: String
        let text: String
        /// `rowRect.bottom - turnsRect.top`. Zero is the container's top edge;
        /// negative means the row's bottom has crossed above it.
        let edgeOffset: Double
        /// The row's own computed `.body` line height in CSS px, read off the
        /// live page rather than reproduced from the text-scale preference —
        /// the typography spike (input-robustness plan, Slice C) measured that
        /// reproducing WebKit's line-height model natively does not match it at
        /// any of three scales tested, so the hysteresis gap is measured
        /// off the real box model instead of a second hand-rederived one.
        let lineHeight: Double
    }

    /// Finds the reader's newest non-held `you` turn and measures it against
    /// `.turns`, the scroller — never against the document, which can be
    /// taller than the visible pane.
    ///
    /// `:not(.held)` excludes a queued message not yet read (Input-robustness
    /// Slice D): the reader has not lost track of something they typed forty
    /// seconds ago and can already see below the composer, so a held row is
    /// not what this bar exists to help them find back.
    ///
    /// The FIRST element in DOM order is wanted, not the last: `.turns` is
    /// `column-reverse` and its rows are emitted reversed
    /// (`platform/contracts/session-page-markup`), so the DOM's first child is
    /// the newest turn and `querySelector` already returns document order.
    nonisolated static let pinCheckScript = """
        (function(){\
        var t=document.querySelector('.turns');\
        if(!t){return null;}\
        var row=t.querySelector('.turn.you:not(.held)');\
        if(!row){return null;}\
        var key=row.getAttribute('data-k');\
        if(!key){return null;}\
        var turnsRect=t.getBoundingClientRect();\
        var rowRect=row.getBoundingClientRect();\
        var body=row.querySelector('.body');\
        var lh=body?parseFloat(getComputedStyle(body).lineHeight):NaN;\
        if(!isFinite(lh)){lh=0;}\
        var raw=(body?body.textContent:row.textContent)||'';\
        var text=raw.length>\(pinCandidateTextBridgeBound)?raw.slice(0,\(pinCandidateTextBridgeBound)):raw;\
        return {key:key,text:text,edgeOffset:rowRect.bottom-turnsRect.top,lineHeight:lh};\
        })()
        """

    /// Parses `pinCheckScript`'s result. Every field degrades to "no
    /// candidate" together — this runs against a page built from a transcript,
    /// so a shape it does not expect (a `null` result, a missing key, a
    /// non-numeric measurement) is a case to survive rather than crash on,
    /// the same posture `parseReadResult` takes.
    nonisolated static func parsePinCandidate(_ result: Any?) -> PinCandidate? {
        guard let dict = result as? [String: Any],
              let key = dict["key"] as? String, !key.isEmpty,
              let text = dict["text"] as? String else { return nil }
        let edgeRaw = dict["edgeOffset"]
        let edgeOffset = (edgeRaw as? Double) ?? ((edgeRaw as? Int).map(Double.init) ?? 0)
        let lhRaw = dict["lineHeight"]
        let lineHeight = (lhRaw as? Double) ?? ((lhRaw as? Int).map(Double.init) ?? 0)
        return PinCandidate(key: key, text: text, edgeOffset: edgeOffset, lineHeight: lineHeight)
    }

    /// Scrolls a row identified by `data-k` into view. The key arrives as a
    /// BOUND ARGUMENT via `callAsyncJavaScript` — see `scrollToPinnedMessage`
    /// — and even so this finds the row by COMPARING `data-k` in a loop rather
    /// than building a CSS attribute selector from it, matching
    /// `applyDeltaBody` and `restoreScript`: a selector built from a key is the
    /// one place a malformed key could reach further than the row it names,
    /// and `platform/contracts/session-page-markup` names this as load-bearing
    /// security rather than a style preference either script happens to share.
    ///
    /// `scrollIntoView` rather than hand-computed `scrollTop` arithmetic: it
    /// already accounts for `column-reverse`, so this needs no sign convention
    /// of its own to get backwards.
    nonisolated static let scrollToElementBody = """
        var t = document.querySelector('.turns');
        if (!t) { return {ok:false}; }
        var rows = t.querySelectorAll('[data-k]');
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].getAttribute('data-k') === key) {
                rows[i].scrollIntoView({block: 'center'});
                return {ok:true};
            }
        }
        return {ok:false};
        """

    // MARK: - Search

    /// How many matches `searchCountBody` counts before giving up and
    /// reporting a capped total — the same cap and the same "some number,
    /// then a plus" idea SwiftTerm's `searchMatchSummary(limit:)` uses on the
    /// terminal side, matched rather than independently chosen so the two
    /// surfaces do not disagree about what "capped" means.
    nonisolated static let searchMatchCap = 1000

    /// Counts occurrences of `term` in `.turns`' rendered text,
    /// case-insensitive, stopping at `cap`.
    ///
    /// BOTH ARGUMENTS ARE BOUND, never interpolated, matching every other
    /// value that crosses this bridge — see `applyDeltaBody` and
    /// `AppendBridgeCapabilityTests` for why. A search term is person-typed
    /// rather than transcript content, but it still returns inside a script
    /// the host evaluates, and the discipline does not get to depend on how
    /// trusted the source looks.
    ///
    /// Counts against `textContent` — a plain case-folded substring count
    /// over the same text a reader sees — rather than deferring to
    /// `window.find` or a DOM `Range` walk. It can disagree with WebKit's own
    /// `find` on exotic Unicode case-folding, or on a match split across two
    /// text nodes by an inline tag; the renderer's markup does not do the
    /// latter today. Said here rather than left to be discovered: this is a
    /// practical count, not a value guaranteed identical to `find`'s own
    /// idea of a match.
    nonisolated static let searchCountBody = """
        var t = document.querySelector('.turns');
        if (!t) { return {total: 0, capped: false}; }
        var haystack = (t.textContent || '').toLowerCase();
        var needle = String(term || '').toLowerCase();
        if (needle.length === 0) { return {total: 0, capped: false}; }
        var count = 0, idx = 0;
        while (count <= cap) {
            var found = haystack.indexOf(needle, idx);
            if (found === -1) { break; }
            count += 1;
            idx = found + needle.length;
        }
        return {total: Math.min(count, cap), capped: count > cap};
        """

    /// Parses `searchCountBody`'s result. Degrades to "no matches" on any
    /// shape this does not expect — a non-dictionary result, a missing or
    /// non-numeric `total` — the same posture `parseReadResult` and
    /// `parsePinCandidate` take against a page whose content Deck does not
    /// control.
    nonisolated static func parseSearchCount(_ result: Any?) -> (total: Int, capped: Bool) {
        guard let dict = result as? [String: Any] else { return (0, false) }
        let rawTotal = dict["total"]
        let total = (rawTotal as? Int) ?? ((rawTotal as? Double).map(Int.init) ?? 0)
        return (max(0, total), dict["capped"] as? Bool ?? false)
    }

    // MARK: - Delta cursor from the page's own meta

    /// The script that reads the delta cursor off the page that just
    /// loaded: the `transcript-lines` meta's `content`, or `null` when the
    /// meta is absent.
    ///
    /// Host-evaluated, the same path `readScript` and `restoreScript`
    /// already use — see the type doc for why that is independent of
    /// `allowsContentJavaScript = false`. agent-platform #379 puts this meta
    /// right after the charset meta, on both the full render and the
    /// `full:true` fallback page, and even on an empty conversation, where
    /// there is no `.turns` to query — so this script never depends on that
    /// element existing.
    nonisolated static let readCursorScript = """
        (function(){var m=document.querySelector('meta[name="transcript-lines"]');\
        return m?m.getAttribute('content'):null;})()
        """

    /// Parses `readCursorScript`'s result into a cursor, or nil.
    ///
    /// DEFENSIVE BY DESIGN, because a wrong cursor is the dangerous failure
    /// here — not a missing one. Too high a cursor and the next
    /// `--delta-since` silently skips rows, so the pane just quietly lacks a
    /// turn with no error anywhere. A missing meta, a non-integer, and a
    /// negative value are all treated the same: nil, meaning "no cursor",
    /// which routes the caller to the `establishCursorIfNeeded` probe
    /// instead of trusting a guess.
    nonisolated static func parseCursor(fromMetaContent result: Any?) -> Int? {
        guard let text = result as? String, let value = Int(text), value >= 0 else { return nil }
        return value
    }

    /// The script that puts both back, in that order.
    ///
    /// **Rows first, scroll second.** Opening a row changes the height above
    /// the reader, so a scrollTop applied before the rows would land somewhere
    /// else once they expanded.
    ///
    /// The keys are compared in JavaScript rather than built into a selector.
    /// A selector would concatenate a key into a query string, which is the one
    /// place a malformed key could reach further than the row it names; a
    /// comparison cannot. `sanitize` has already dropped anything outside the
    /// key charset, so the array literal below holds only characters that need
    /// no escaping — the two together are why this is safe rather than either
    /// one alone.
    /// **The saved offset is corrected for growth, and without that it is wrong
    /// exactly when it is used.** The one path that reliably reaches a reload is
    /// `deltaFailed()` → `reRender()`, which fires precisely because there WAS
    /// new content that could not be applied incrementally — so the replacement
    /// document is taller than the one measured, and reapplying the raw offset
    /// lands the reader off by the difference. Same drift, same cause, and the
    /// same signature as the delta-apply bug this pairs with: `deck-reviewer`
    /// reproduced it at 50 px on a one-row growth while reviewing #83.
    ///
    /// `heightBefore` is compared AFTER the rows are reopened, which is why the
    /// growth is measured there rather than at the top of the script: reopening
    /// a row changes the height too, and only the content that actually arrived
    /// should move the reader.
    nonisolated static func restoreScript(openKeys: [String], scrollTop: Double?,
                                          heightBefore: Double? = nil) -> String {
        var body = ""
        if !openKeys.isEmpty {
            let list = openKeys.map { "\"\($0)\"" }.joined(separator: ",")
            body += "var k=[\(list)];var d=document.querySelectorAll('details[data-k]');"
            body += "for(var i=0;i<d.length;i++){"
            body += "if(k.indexOf(d[i].getAttribute('data-k'))>=0){d[i].open=true;}}"
        }
        // `isFinite` because an infinite or NaN scrollTop would interpolate as
        // `inf`/`nan` and make the whole script a syntax error, taking the row
        // restoration above down with it. The same guard covers `heightBefore`,
        // which is interpolated the same way.
        if let scrollTop, scrollTop.isFinite {
            body += "var t=document.querySelector('.turns');if(t){"
            if let heightBefore, heightBefore.isFinite, heightBefore > 0 {
                // History is negative, so holding position against content added
                // at the bottom means moving further from zero — the same
                // correction, and the same sign, as `applyDeltaBody`.
                body += "var g=t.scrollHeight-\(heightBefore);"
                body += "t.scrollTop=\(scrollTop)-(g>0?g:0);"
            } else {
                body += "t.scrollTop=\(scrollTop);"
            }
            body += "}"
        }
        return body.isEmpty ? "" : "(function(){\(body)})()"
    }

    // MARK: - Delta application

    /// The script `applyPendingDelta` runs, taking the validated rows as a
    /// BOUND ARGUMENT — never interpolated. See `AppendBridgeCapabilityTests`
    /// for why `callAsyncJavaScript` makes that the same escaping surface as
    /// the full page rather than a second one.
    ///
    /// A row is found by `data-k` and REPLACED IN PLACE when the document
    /// already holds it; otherwise it is INSERTED. The keys are compared
    /// rather than built into a selector, for the reason
    /// `OpenRowRestoreScriptTests` gives for the restore script: a selector
    /// built from a key is the one place a malformed key could reach further
    /// than the row it names, and a comparison cannot.
    ///
    /// `afterbegin`, NOT `beforeend`: `.turns` is `column-reverse` and its
    /// rows are emitted reversed, so the DOM start is the visual bottom, and
    /// an inserted row — always the newest, since the transcript is
    /// append-only and a delta is in order — belongs there.
    ///
    /// A key listed in `removed` — also a BOUND ARGUMENT — is found the same
    /// comparison way and taken off the page entirely, after every row has
    /// been placed. A withdrawn row is how the mini takes back something it
    /// already sent, e.g. a queued message the agent has since read; it is
    /// never new content, so it does not set `inserted`.
    ///
    /// Returns `{ok:false}` when there is no `.turns` to insert into, which
    /// the caller treats as a failure needing the full-reload fallback rather
    /// than as nothing to do — a document with no `.turns` is not a document
    /// this bridge can leave consistent. On success it also reports whether
    /// any row was actually INSERTED (as opposed to only replaced or
    /// removed), because only an insert is new content the reader has not
    /// seen — a reply that only replaced existing rows (a tool result
    /// folding into its call) or only removed one must not raise the
    /// jump-to-new-output pill.
    ///
    /// **Scroll compensation is ANCHOR-based, not a signed height delta.** An
    /// earlier version compensated with a single `scrollHeight` delta,
    /// reasoning that every change landed at the DOM start (the visual
    /// bottom, where an insert always lands) and so always fell between that
    /// edge and the reader. That reasoning does not hold for `removed`: a
    /// withdrawn row can be anywhere on the page, including on the far side
    /// of the reader from that edge, where the correct compensation is zero
    /// — `deck-reviewer` reproduced the resulting jump against a live
    /// WKWebView while reviewing this PR. An anchor sidesteps the geometry
    /// question entirely: before anything is applied, remember one row the
    /// reader can currently see and its position on screen; after every
    /// insert, replace and removal in the batch has landed, find that same
    /// row again and put it back exactly there. A row this batch never
    /// touched, however far away the change was, measures zero shift and
    /// gets zero correction; a row that did shift gets exactly its own
    /// shift. The same code path covers all three operations, with no case
    /// analysis of where in the document the change fell.
    nonisolated static let applyDeltaBody = """
        var turns = document.querySelector('.turns');
        if (!turns) { return {ok:false}; }
        // MEASURED BEFORE ANYTHING IS APPLIED, because both values are about
        // to change and the reader has to be put back where they were.
        var wasScrolledUp = Math.abs(turns.scrollTop) > tolerance;
        var heightBefore = turns.scrollHeight;

        // THE ANCHOR: a row the reader can currently see, picked before any
        // insert, replace or removal runs. Its own on-screen position is
        // what the compensation below restores, and restoring one row's
        // position restores every row's position, since scrolling the
        // container moves all of them together. A row already in `removed`
        // is skipped — it will not exist to re-measure afterward.
        //
        // A reader AT THE BOTTOM (`wasScrolledUp` false) gets no anchor and
        // so no compensation: staying pinned to the newest turn is what they
        // want, and correcting their position would scroll them off it.
        var removedSet = {};
        for (var rk = 0; rk < removed.length; rk++) { removedSet[removed[rk]] = true; }
        var anchorKey = null;
        var anchorTopBefore = 0;
        if (wasScrolledUp) {
            var turnsRect = turns.getBoundingClientRect();
            var candidates = turns.querySelectorAll('[data-k]');
            for (var c = 0; c < candidates.length; c++) {
                var candidateKey = candidates[c].getAttribute('data-k');
                if (removedSet[candidateKey]) { continue; }
                var candidateRect = candidates[c].getBoundingClientRect();
                if (candidateRect.bottom > turnsRect.top && candidateRect.top < turnsRect.bottom) {
                    anchorKey = candidateKey;
                    anchorTopBefore = candidateRect.top;
                    break;
                }
            }
        }

        var inserted = false;
        for (var i = 0; i < rows.length; i++) {
            var row = rows[i];
            // RE-QUERIED FRESH EVERY ITERATION, never a snapshot taken once
            // before this loop — the same reason the removal loop below does
            // this: `mergedRows` (SessionPaneModel.swift) already keeps a
            // repeated key to one entry, but this has to hold even if a batch
            // arrives with the same key twice, since a snapshot taken before
            // the loop cannot see a row this same batch already inserted or
            // replaced, and reading it as unseen a second time would insert a
            // second DOM node for one key.
            var existing = turns.querySelectorAll('[data-k]');
            var target = null;
            for (var j = 0; j < existing.length; j++) {
                if (existing[j].getAttribute('data-k') === row.key) { target = existing[j]; break; }
            }
            if (target && !row.newest) {
                target.outerHTML = row.html;
            } else {
                // A `newest` row already on the page is REMOVED AND RE-INSERTED
                // rather than replaced where it sits. It is a held row — a
                // queued message the agent has not read — and it is the one row
                // whose position the transcript does not fix, so it has to be
                // put back at the newest end on every batch.
                //
                // Replacing it in place was the bug: new transcript rows insert
                // here, at the newest end, so each one slid in underneath the
                // held message and left it one position further up. A single
                // long assistant turn then carried it off the top of the
                // viewport and it read as gone.
                //
                // `inserted` is NOT raised for a re-position — the pill means
                // "there is new output below you", and a held message the
                // reader has already seen moving back to the bottom is not new
                // output. A first insert of that row (no `target`) is.
                if (target) { target.remove(); } else { inserted = true; }
                turns.insertAdjacentHTML('afterbegin', row.html);
            }
        }
        // REMOVAL: a row the mini has withdrawn — e.g. a queued message the
        // agent has since read — leaves the page entirely. `inserted` is left
        // untouched here on purpose: a removal is not new output, and must
        // not raise the jump-to-new-output pill.
        //
        // Looked up by comparing `data-k` in JavaScript, never by building a
        // CSS selector from the key, for the same reason a replace target is
        // found this way above: a selector built from a key is the one place
        // a malformed key could reach further than the row it names, and a
        // comparison cannot. Re-queried fresh each time rather than reusing
        // `existing`, so a key can name a row this same batch just inserted
        // or replaced. A key matching nothing is not an error — the row may
        // already be gone, and the client and mini need not agree perfectly.
        for (var r = 0; r < removed.length; r++) {
            var live = turns.querySelectorAll('[data-k]');
            for (var k = 0; k < live.length; k++) {
                if (live[k].getAttribute('data-k') === removed[r]) { live[k].remove(); break; }
            }
        }
        // THE COMPENSATION: put the anchor back exactly where it was. Every
        // row in `.turns` moves together when the container scrolls, so
        // restoring one row's on-screen position restores all of them —
        // including a row this batch never touched, which measures no shift
        // here and gets none. This is what makes the same code correct for
        // an insert (always at the DOM start), a replace (in place, anywhere
        // on the page) and a removal (also anywhere on the page, unlike an
        // insert): none of them needed the reader's position reasoned about
        // relative to where the change fell, only measured directly.
        //
        // Re-queried by `data-k`, never reusing the node captured above: a
        // replace swaps in a new element for the same key via `outerHTML`,
        // so the original reference may already be detached from the page.
        if (anchorKey !== null) {
            var afterRows = turns.querySelectorAll('[data-k]');
            for (var m = 0; m < afterRows.length; m++) {
                if (afterRows[m].getAttribute('data-k') === anchorKey) {
                    var anchorTopAfter = afterRows[m].getBoundingClientRect().top;
                    turns.scrollTop = turns.scrollTop + (anchorTopAfter - anchorTopBefore);
                    break;
                }
            }
        }
        var grew = turns.scrollHeight - heightBefore;
        return {ok:true, inserted:inserted, scrollTop:turns.scrollTop, grew:grew};
        """

    /// The rows worth sending to the page, from whatever a delta carried.
    ///
    /// Validated against `rowKeyPattern` rather than escaped, exactly as
    /// `sanitize(openKeys:)` validates a key on the restore path — the same
    /// reasoning `platform/contracts/session-page-markup` gives applies here:
    /// the key returns inside a script the host evaluates. A row whose key
    /// fails the allowlist is dropped rather than applied; the rest of the
    /// batch still lands.
    nonisolated static func validateRows(_ rows: [SessionAgent.DeltaRow]) -> [SessionAgent.DeltaRow] {
        rows.filter { $0.key.range(of: rowKeyPattern, options: .regularExpression) != nil }
    }

    /// The removal keys worth sending to the page, from whatever a delta
    /// carried. Checked against the same `rowKeyPattern` `validateRows`
    /// checks a row's key against, and for the same reason: it returns
    /// inside a script the host evaluates.
    ///
    /// UNLIKE `validateRows`, A KEY THAT FAILS HERE IS JUST DROPPED — no
    /// batch-level failure follows it. A row that fails validation is
    /// content that would never be drawn and never re-offered, which is
    /// what makes an all-invalid row batch a failure worth a full reload
    /// over. A removal key that fails validation costs nothing but a beat:
    /// the row it named stays on the page, exactly as if the mini had not
    /// asked to remove it at all.
    nonisolated static func validateRemovedKeys(_ keys: [String]) -> [String] {
        keys.filter { $0.range(of: rowKeyPattern, options: .regularExpression) != nil }
    }

    /// Applies one delta batch to the live document, asynchronously —
    /// `updateNSView` must return before this finishes, so the result reaches
    /// the model through `coordinator`'s callbacks rather than being awaited
    /// here.
    ///
    /// Not `private`, unlike the rest of this application path, so a test can
    /// drive it directly against a `Coordinator` with the callbacks wired to
    /// captured state — the routing below has no WKWebView-dependent
    /// behaviour of its own to require one.
    static func applyPendingDelta(_ delta: SessionPaneModel.PendingDelta,
                                  view: WKWebView, coordinator: Coordinator) {
        let validRows = ConversationWebView.validateRows(delta.rows)
        let validRemoved = ConversationWebView.validateRemovedKeys(delta.removed)

        if !delta.rows.isEmpty && validRows.isEmpty {
            // Every row's key failed the allowlist. Content genuinely
            // existed here, so advancing the cursor with nothing drawn would
            // drop it for good — `--delta-since` never re-offers what is
            // already behind the cursor. Routed to the SAME full-reload
            // fallback every other failure on this path uses, so the worst
            // case stays what `platform/contracts/session-page-markup`
            // promises: today's behaviour, not silent loss. Any removals
            // riding along in the same batch are moot — a reload applies
            // them too, since it replaces the document outright.
            coordinator.onDeltaFailed?()
            return
        }
        guard !validRows.isEmpty || !validRemoved.isEmpty else {
            // A genuinely empty batch: the cursor moved with nothing new to
            // draw and nothing to withdraw. Nothing was dropped, so nothing
            // needs recovering.
            coordinator.onDeltaApplied?(delta.cursor)
            return
        }
        let payload = validRows.map {
            ["key": $0.key, "html": IssueIdLinkifier.linkify($0.html), "newest": $0.newest] as [String: Any]
        }
        Task { @MainActor in
            do {
                let value = try await view.callAsyncJavaScript(
                    ConversationWebView.applyDeltaBody,
                    // `tolerance` is bound rather than interpolated, for the
                    // reason every value on this path is: nothing is spliced
                    // into the script source. It carries `isAtBottom`'s own
                    // constant so the script and the predicate cannot drift
                    // to different ideas of "at the bottom".
                    arguments: ["rows": payload,
                                "removed": validRemoved,
                                "tolerance": ConversationWebView.atBottomTolerance],
                    in: nil,
                    contentWorld: .page)
                guard let dict = value as? [String: Any], dict["ok"] as? Bool == true else {
                    coordinator.onDeltaFailed?()
                    return
                }
                // Only an INSERT is content the reader has not seen — a batch
                // that only replaced rows already on the page (a tool result
                // folding into its call) must not raise the pill.
                if dict["inserted"] as? Bool == true {
                    let raw = dict["scrollTop"]
                    let scrollTop = (raw as? Double) ?? ((raw as? Int).map(Double.init) ?? 0)
                    if ConversationWebView.isAtBottom(scrollTop: scrollTop) {
                        coordinator.scrollState?.clearNewOutput()
                    } else {
                        coordinator.scrollState?.markNewOutput()
                    }
                }
                // The document just changed under whatever search is running
                // — a replace, insert or removal can each move where a term
                // appears. See `ConversationScrollState.documentDidChange`
                // for why the count is recomputed and the position resets
                // rather than trying to carry it forward.
                coordinator.scrollState?.documentDidChange()
                coordinator.onDeltaApplied?(delta.cursor)
            } catch {
                coordinator.onDeltaFailed?()
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoaded: String
        var onDeckOpen: ((DeckOpenRef.Origin) -> Void)?
        var hosts: [HostEntry]
        /// Scroll state shared with the chrome. Set in `updateNSView` so the
        /// coordinator always holds the current instance.
        var scrollState: ConversationScrollState?
        /// The scroll position to restore after the next reload, or nil when
        /// the reader was at the bottom and no restoration is needed.
        var savedScrollTop: Double?
        /// How tall the document was when `savedScrollTop` was measured, or nil
        /// alongside it. `restoreScript` compares this against the replacement
        /// document's height to correct the offset for content that arrived in
        /// between — which is the normal case, since the reload is usually
        /// triggered BY that content.
        var savedScrollHeight: Double?
        /// The keys of the rows the reader had expanded before the next
        /// reload. Empty when nothing was open, or on the first load.
        var savedOpenKeys: [String] = []
        /// The generation of the last delta batch applied, so a batch is
        /// never sent to the page twice. -1 so generation 0 would still be
        /// treated as new — `SessionPaneModel.deltaGeneration` in fact starts
        /// at 1, but nothing here depends on that.
        var lastAppliedDeltaGeneration = -1
        var onDeltaApplied: ((Int) -> Void)?
        var onDeltaFailed: (() -> Void)?
        /// Called once the page that just finished loading has been asked
        /// for its delta cursor. See `readCursorScript` and
        /// `SessionPaneModel.cursorRead(fromMeta:)`.
        var onCursorRead: ((Int?) -> Void)?

        init(html: String, onDeckOpen: ((DeckOpenRef.Origin) -> Void)?, hosts: [HostEntry]) {
            self.lastLoaded = html
            self.onDeckOpen = onDeckOpen
            self.hosts = hosts
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let scrollTop = savedScrollTop
            let heightBefore = savedScrollHeight
            let openKeys = savedOpenKeys
            savedScrollTop = nil
            savedScrollHeight = nil
            savedOpenKeys = []
            // Restore position and open rows immediately after the load so the
            // reader lands back where they were reading, still looking at
            // whatever they had expanded. Restoration via evaluateJavaScript
            // fires on the main thread and WebKit typically batches paints, so
            // the jump is minimised — but not fully eliminated: a brief flash
            // of the bottom position, and of the rows closed, is possible
            // before the script runs. The full solution (injecting state before
            // first paint) requires WKUserScript, which needs its own empirical
            // test under allowsContentJavaScript = false; that is out of scope
            // for this fix.
            let js = ConversationWebView.restoreScript(openKeys: openKeys,
                                                       scrollTop: scrollTop,
                                                       heightBefore: heightBefore)
            if !js.isEmpty {
                webView.evaluateJavaScript(js, completionHandler: nil)
            }

            // The whole document just got replaced — every full reload,
            // cosmetic re-renders included, so an active search is
            // re-counted against the page that is now actually on screen.
            // See `ConversationScrollState.documentDidChange`.
            scrollState?.documentDidChange()

            // Read the delta cursor off this page — see `readCursorScript`.
            // This fires after every full-page load, cosmetic re-renders
            // included; `SessionPaneModel.cursorRead(fromMeta:)` is the one
            // that decides whether the value matters.
            webView.evaluateJavaScript(ConversationWebView.readCursorScript) { [weak self] result, _ in
                MainActor.assumeIsolated {
                    self?.onCursorRead?(ConversationWebView.parseCursor(fromMetaContent: result))
                }
            }
        }

        /// Only the initial in-memory load is allowed. A link in transcript text
        /// opens in the user's browser instead of navigating the pane, so no
        /// remote page can occupy this view.
        ///
        /// The `@MainActor` on the closure is load-bearing, not decoration.
        /// Without it this only NEARLY matches the protocol requirement, so
        /// WebKit never calls it — the compiler says so in a warning, and the
        /// cost is silent: links would navigate the pane, with the code that
        /// forbids it sitting right here looking correct.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                // `deck-open:` is an internal command. It is never passed to
                // NSWorkspace and never added to ExternalLink.allowedSchemes.
                // The navigation is cancelled in every outcome.
                if url.scheme?.lowercased() == "deck-open" {
                    if let origin = DeckOpenRef.validate(url, hosts: hosts) {
                        onDeckOpen?(origin)
                    } else {
                        print("[Deck] deck-open: rejected ref: \(url)")
                    }
                    decisionHandler(.cancel)
                    return
                }
                ExternalLink.open(url)
                decisionHandler(.cancel)
                return
            }
            let isInMemory = navigationAction.request.url.map {
                $0.scheme == "about" || $0.absoluteString.isEmpty
            } ?? true
            decisionHandler(isInMemory ? .allow : .cancel)
        }
    }
}

// MARK: - External links

/// Handing a URL to the system, but only a scheme worth handing over.
enum ExternalLink {
    /// `NSWorkspace.open` dispatches to whatever app claims the scheme, and a
    /// link here comes from transcript text an attacker may have influenced. So
    /// the schemes are an allowlist rather than a blocklist.
    ///
    /// What the allowlist excludes, and why each matters: `file://` opens local
    /// files in whatever app claims their type; `ssh://` can open a connection
    /// dialog to an attacker's host; app deep links (`obsidian://`,
    /// `x-callback-url://`) can drive an installed app whose handler acts
    /// without confirming. Clicking a link in your agent's own conversation is
    /// the designed interaction here, so the bar is lower than for a link found
    /// somewhere untrusted.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}

// MARK: - Network block

/// Blocks every network load in a web view.
///
/// The page is self-contained — inline CSS, no assets — so nothing legitimate is
/// blocked, and anything that tries to fetch is by definition something the
/// renderer did not intend to be there.
enum NetworkBlock {
    static let identifier = "deck-conversation-block-all"

    /// One rule, matching everything, blocking it.
    static let rules = """
        [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}}]
        """

    /// Compiles and attaches, then calls `then`.
    ///
    /// FAILS OPEN, DELIBERATELY, AND THAT IS A JUDGEMENT WORTH SEEING. If the
    /// rule list cannot be compiled the page is still loaded, because a Deck
    /// that shows nothing is a Deck nobody uses, and the primary protections
    /// (no JavaScript, no bridge) do not depend on this. This rule is the third
    /// layer, guarding a passive fetch that only matters given an escaping bug
    /// upstream. Turning that residual risk into a blank pane would be the worse
    /// trade — but it is a trade, not an oversight.
    static func attach(to view: WKWebView, then: @escaping @MainActor () -> Void) {
        guard let store = WKContentRuleListStore.default() else {
            Task { @MainActor in then() }
            return
        }
        store.compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: rules
        ) { list, _ in
            Task { @MainActor in
                if let list { view.configuration.userContentController.add(list) }
                then()
            }
        }
    }
}
