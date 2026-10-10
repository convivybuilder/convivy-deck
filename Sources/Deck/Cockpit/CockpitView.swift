import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The right-hand column's default occupant: the Course, the current epic's
/// interior, and the corrections queue for whichever project the selected
/// crew names.
///
/// NATIVE, NOT A WEB PANE — the boundary call CLAUDE.md asks a crossing to
/// name. The cockpit is a scannable list a reader acts on, the same shape as
/// the rail rather than a document; it needs no script, no generated markup,
/// and nothing here benefits from a second theming path when SwiftUI's own
/// `colorScheme` environment already resolves the shell's appearance for a
/// native view for free. Building a WKWebView pane here would mean inventing
/// a THIRD ad hoc theming mechanism (`deck/bead/deck` §3 already counts two)
/// for a surface that does not need one.
///
/// Every panel degrades independently and never disappears silently: a
/// failed fetch shows what it could not reach rather than an empty rectangle
/// (CLAUDE.md, "a failed Library call is not an error to shout about").
struct CockpitView: View {
    @ObservedObject var model: CockpitModel
    /// Why the cockpit has nothing to follow — no crew selected, or the
    /// selected crew names no Library project — or `nil` when it does.
    let unresolvedReason: String?
    /// The selected crew's dispatched runs, straight off `railState.states`
    /// — the same session payload `WorkingStrip` already reads for
    /// `workingOn`, so this panel costs no poller of its own
    /// (`CockpitModel`'s own doc: "a third fast poller would buy nothing").
    ///
    /// THREE STATES, NOT TWO. `nil` is a mini that predates `agent_runs` —
    /// "this mini doesn't report agent runs yet" — and is not the same
    /// answer as `[]`, "no agents in flight." Collapsing them would draw an
    /// old mini's silence as an honest empty crew.
    var agentRuns: [SessionState.AgentRun]? = nil
    /// Whether `agentRuns` lists every repo's runs rather than just the
    /// selected crew's own — true only for the steward. Read straight off
    /// the same `SessionState` `agentRuns` came from
    /// (`SessionState.agentsAreFleetWide`), so the two never disagree about
    /// which run list this is. Drives the Dispatched panel's title; see
    /// `dispatchedPanelTitle`.
    var agentsAreFleetWide: Bool = false
    /// The shell's resolved appearance — needed here only to solve the
    /// panel index's queue count against the right surface
    /// (`indexSurface`), the same reason `SessionPaneView` and `RailRow`
    /// take it rather than reading `@Environment(\.colorScheme)`: nothing
    /// sets `preferredColorScheme`, so the environment reports the SYSTEM
    /// appearance even when Deck's own config has pinned the other one.
    let appearance: Appearance
    /// The Builder Default ground the Cockpit is drawn on, set by the shell's pin.
    @Environment(\.statusGround) private var statusGround
    /// The cockpit's secondary text and its tertiary marks, solved against the
    /// ground the cockpit is drawn on. Nil ground keeps the system styles.
    private var secondaryInk: AnyShapeStyle { CockpitView.secondaryInkStyle(on: statusGround) }
    private var tertiaryInk: AnyShapeStyle { CockpitView.tertiaryInkStyle(on: statusGround) }
    /// The selected crew's own hue — the same expression `ContentView`
    /// passes `SessionPaneView` and the rail's own dot, so an in-progress
    /// mark drawn in this panel is provably the same colour as everywhere
    /// else that crew's accent appears. `nil` when there is no session
    /// selected, the same "no theme resolved" case `SessionPaneView.accent`
    /// answers with `neutralAccent`.
    var accent: RGB? = nil
    /// Opens `ItemDetailPane` in the right column for one Library item id.
    /// A corrections-queue row's tap calls it, and so does the `Open` control
    /// (`ItemOpenButton`) on every Course epic row, child work-item row,
    /// queue row and proposal row. `ContentView` owns `columnOccupant`, so this view only
    /// names the id and lets the caller decide what that means.
    let onSelectCorrection: (String) -> Void
    /// Opens (or, on the open run, closes) the run pane for a Dispatched row.
    /// nil draws the rows inert.
    var onSelectRun: ((String) -> Void)? = nil
    /// The run id whose pane is open, so its row draws selected.
    var openRunId: String? = nil
    /// The header's title: "Cockpit" for a project crew, "Board" for the
    /// steward's board.
    var title: String = "Cockpit"
    /// The header's place line, the selected crew's project. nil draws the
    /// band without one, which is what a crew with no project shows.
    var placeLine: String? = nil
    /// Which panels draw, top to bottom. A project crew's cockpit draws all
    /// of `panelOrder`; the steward's board draws `boardPanelIDs`. The panel
    /// index lists exactly these, so it never names a panel that isn't there.
    var panelIDs: [String] = CockpitView.panelOrder
    /// Why the Course panel alone has nothing to draw while the rest of the
    /// view does. The steward's board passes the course cockpit's own
    /// "names no Library project" reason here, so a board whose crew has no
    /// project still shows Dispatched and Working documents, and its Course
    /// panel says why it is empty rather than drawing an empty Course.
    var courseUnresolvedReason: String? = nil
    /// Why the Proposals panel alone has nothing to draw while the rest of
    /// the view does — the same reason `courseUnresolvedReason` carries, and
    /// for the same cause: `CockpitModel.refresh` clears `proposedEpics` to
    /// `[]` right alongside `course` when no project resolves, so without
    /// this the board would draw "No epics awaiting approval," a claim it
    /// never checked.
    var proposalsUnresolvedReason: String? = nil
    /// The Working documents panel's rows and what a click opens. Drawn only
    /// when `panelIDs` names `documentsPanelID`.
    var documents: DocumentsPanel? = nil

    /// The Checkout panel's reading and what a click opens. Drawn only when
    /// `panelIDs` names `checkoutPanelID`.
    var checkoutDocuments: CheckoutDocumentsPanel? = nil
    /// The Pull Requests panel's reading, off `PRLadderModel`. Drawn only
    /// when `panelIDs` names `pullRequestsPanelID`. `nil` before the model
    /// has ever fetched (no crew resolved) — the same "nothing asked yet"
    /// posture `checkoutDocuments`'s own `nil` takes.
    var pullRequests: PullRequestsPanel? = nil
    /// Why the Pull Requests panel has nothing to follow — no crew
    /// selected, or the selected crew names no repository — or `nil` when
    /// it does. Checked FIRST in `pullRequestsContent`, the same priority
    /// `courseUnresolvedReason` takes in `coursePanel`: with nothing
    /// resolved, `pullRequests` has been cleared (`PRLadderModel.refresh`),
    /// and this reason is the only honest thing the panel can say.
    var pullRequestsUnresolvedReason: String? = nil
    /// Opens the reviews pane for one Pull Requests panel row — a row's
    /// tap, away from the `#N` text's own tap (which opens the PR on
    /// GitHub). `nil` draws the rows with no row-level tap at all, the same
    /// "inert without a handler" posture `onSelectRun` takes.
    var onSelectPullRequest: ((PRLadder.LadderResult) -> Void)? = nil
    /// Run alongside `model.manualRefresh()` by the header's refresh, so one
    /// control re-reads every panel, including those fed by another model.
    var onRefresh: (() -> Void)? = nil

    /// `PRLadderModel`'s per-repo cached readings, read-only here — this
    /// view draws them and reaches into neither `PRLadderModel` nor
    /// `PRLadder` for anything else beyond the pure merge helpers
    /// (`PRLadder.mergeReadings`/`orderedForDisplay`).
    /// `issue_01M1372GNR81ZV7K1DXHAD10R0`'s own boundary: the derivation
    /// lives in `PRLadder`, this file draws it. Plural because a crew now
    /// follows several repos (`issue_01M2P5JHM1G8XCMKM4HEHVJB2P`); a crew
    /// following one still builds a one-element `readings`.
    struct PullRequestsPanel {
        let readings: [RepoReading]
        /// How many of the crew's own repos exceeded
        /// `CockpitResolution.maxFollowedRepos` and so were never fetched —
        /// `0` when the cap was never reached. Surfaced as a note rather
        /// than a silently shorter panel.
        var droppedByCap: Int = 0

        /// One followed repo's own current reading — the same fields
        /// `PRLadderModel.CachedReading` carries, paired with the repo
        /// identity so a merged, multi-repo panel can say which repo a row,
        /// a failure, or a still-loading state belongs to.
        struct RepoReading: Equatable {
            let owner: String
            let repoName: String
            let result: PRLadder.FetchResult?
            let fetchError: String?
            let isLoading: Bool
            /// When `result` was last set by a successful fetch — straight
            /// off `PRLadderModel.CachedReading.fetchedAt`, the same clock
            /// the model already keeps per repo
            /// (`issue_01M2P60KDY9KPXWMZ4C6G1CJ52` point 5). `nil` before
            /// this repo has ever been fetched successfully — a real
            /// state, not a missing measurement. A failed refresh on rows
            /// already held leaves this dating those surviving rows rather
            /// than clearing it (`issue_01M2PMHZVF1WN0VSJRHZHD2PD6`).
            var fetchedAt: Date? = nil
        }

        /// Single-repo convenience — every crew following exactly one repo
        /// (still the common case) builds the panel this way, and most of
        /// this file's own tests predate the multi-repo epic and construct
        /// it this way too. `owner`/`repoName` default to an empty string:
        /// a single-reading panel never draws a repo mark
        /// (`CockpitView.showsRepoMark`'s own `readings.count > 1` gate), so
        /// nothing reads them.
        init(result: PRLadder.FetchResult?, fetchError: String?, isLoading: Bool, fetchedAt: Date? = nil,
             owner: String = "", repoName: String = "") {
            self.readings = [RepoReading(owner: owner, repoName: repoName, result: result,
                                          fetchError: fetchError, isLoading: isLoading, fetchedAt: fetchedAt)]
            self.droppedByCap = 0
        }

        init(readings: [RepoReading], droppedByCap: Int = 0) {
            self.readings = readings
            self.droppedByCap = droppedByCap
        }
    }

    /// Whether a followed repo's own mark should draw beside `#N` — once a
    /// crew follows more than one repo, `#238` alone no longer identifies
    /// which repo a row belongs to. `false` for the common single-repo
    /// case, which spends this row's scarce width on nothing extra.
    nonisolated static func showsRepoMark(_ panel: PullRequestsPanel?) -> Bool {
        (panel?.readings.count ?? 0) > 1
    }

    /// Every followed repo's rows and failures, folded into one —
    /// `PRLadder.mergeReadings` over the panel's own readings. A pure
    /// function of the panel so `pullRequestsCount`/`pullRequestsTotalCount`/
    /// `pullRequestsAreTruncated`/`pullRequestsContent` all agree on the
    /// same merge rather than each re-deriving it.
    nonisolated static func mergedLadder(_ panel: PullRequestsPanel?) -> PRLadder.MergedLadder {
        PRLadder.mergeReadings((panel?.readings ?? []).map {
            PRLadder.RepoReading(owner: $0.owner, repoName: $0.repoName, result: $0.result, fetchError: $0.fetchError)
        })
    }

    /// Whether any reading in `panel` has ever produced a real `.ladder`
    /// result — the "a real measurement exists" gate `pullRequestsCount`/
    /// `pullRequestsTotalCount` need: a panel where every repo is still
    /// loading, degraded, or erroring outright has no real count to report,
    /// even though `mergedLadder`'s own `results` would just be empty (which
    /// is indistinguishable from "loaded, and genuinely zero rows").
    private static func hasAnyLadderReading(_ panel: PullRequestsPanel?) -> Bool {
        (panel?.readings ?? []).contains {
            if case .ladder = $0.result { return true }
            return false
        }
    }

    struct CheckoutDocumentsPanel {
        let state: CheckoutDocumentsModel.State
        /// Takes a KB id. `ContentView.openCheckoutDocument` holds it to
        /// `DeckOpenRef.validateKBId` before opening.
        let onOpen: (String) -> Void
    }

    struct DocumentsPanel {
        /// Already resolved to absolute paths — see
        /// `RestStateResolution.documentPaths(for:)`.
        let paths: [String]
        /// Routes a row through `ContentView.openRestStateDocument`, which
        /// holds it to the `deck-open:` containment boundary.
        let onOpen: (String) -> Void
    }

    /// Whether the Course's collapsed LEADING run of closed epics is showing
    /// in full. View-level, in-memory state — not persisted, and not
    /// `model.expandedEntries`, which is the unrelated per-epic detail
    /// expansion (`coursePartition`'s own doc explains the collapse itself).
    @State private var isCourseHeadExpanded = false
    /// Same, for the collapsed TRAILING run of unstarted epics.
    @State private var isCourseTailExpanded = false

    /// Which Course entry's row the pointer is over, gating that row's
    /// hover-revealed copy icon — right-click alone (`.contextMenu` below)
    /// is only findable by someone who already suspects it is there, so
    /// this gives the same "Copy title" a second, discoverable path
    /// (the operator, 2026-09-02). One `@State` for the whole list rather than one
    /// per row: at most one row is under the pointer at a time.
    @State private var hoveredCourseEntryID: String?
    /// The Course row being dragged and the row the pointer is over, so the
    /// landing line can be drawn where the drop will actually put the epic.
    /// `draggedCourseEntryID` is set when a drag starts and is not cleared by
    /// a cancelled drag; it is only read while `courseDropTargetID` is set,
    /// and every new drag overwrites it first.
    @State private var draggedCourseEntryID: String?
    @State private var courseDropTargetID: String?
    /// Same, for the corrections-queue row.
    @State private var hoveredQueueItemID: String?

    /// Reaches `ThemeConfiguration.queueSortOrder` — the corrections
    /// queue's persisted sort choice — and the mutator that saves a new
    /// one. `DeckApp` injects the same `ThemeStore` instance every view in
    /// the app draws from, so this needs no explicit parameter the way
    /// `model` and `accent` are threaded from `ContentView`.
    @EnvironmentObject private var themeStore: ThemeStore
    /// Same, for a child item's row inside an expanded epic. The
    /// `.contextMenu` there was the only copy affordance and the operator
    /// reached for it without finding it (issue_01M2787H072R4FFX4DBHVHX1VY) — this closes
    /// the same gap `hoveredCourseEntryID` and `hoveredQueueItemID` already
    /// closed for their row types.
    @State private var hoveredChildItemID: String?
    /// The proposal row under the pointer, so its `Open` control reveals the
    /// way the Course and queue rows' do.
    @State private var hoveredProposalEpicID: String?
    /// The `model.revealCount` this view last scrolled for, so one reveal
    /// scrolls once however many times the target's row appears and
    /// disappears under it (see `revealScrollTarget`).
    @State private var scrolledRevealCount = 0
    /// The `model.chipScrollCount` this view last scrolled for — the same
    /// "count, not id" guard `scrolledRevealCount` keeps, so a second click
    /// on an already-scrolled-to chip still re-centers its row.
    @State private var scrolledChipCount = 0

    /// Which top-level panels (`panelOrder`'s ids) are collapsed to just
    /// their header. View-level, in-memory state, deliberately not
    /// persisted (issue_01M1CCYWG8409VA4PT4W1QBB5D) — and a DIFFERENT axis
    /// from `isCourseHeadExpanded`/`isCourseTailExpanded`, which collapse
    /// runs of rows *inside* the Course panel. Both coexist: collapsing the
    /// whole Course panel here hides its head/tail affordances along with
    /// everything else; neither state reads the other.
    @State private var collapsedPanelIDs: Set<String> = []

    /// A reader's expand or collapse of one Checkout kind group, keyed by
    /// kind. A kind with no entry follows `Group.isExpandedByDefault`.
    /// In-memory, like `collapsedPanelIDs`, and kept across crew switches so
    /// a reader who opened Decisions finds it open on the next crew too.
    @State private var checkoutGroupExpansion: [String: Bool] = [:]

    /// Each rendered panel's frame in the `scrollCoordinateSpaceName` space,
    /// as last reported by `panelSection`'s background `GeometryReader` via
    /// `PanelFramePreferenceKey`. Drives the panel index's "here" entry
    /// (`topmostVisiblePanelID`) — a function of this, not a fixed list, so
    /// a panel this pass never had to know about (a future documents-in-hand
    /// or PRs-open panel) is placed correctly the moment it registers a
    /// frame through the same mechanism.
    @State private var panelFrames: [String: CGRect] = [:]

    /// The `ScrollView`'s own visible height, in the same units
    /// `panelFrames` reports in — `topmostVisiblePanelID`'s other half of
    /// "does this panel intersect the viewport." Measured off the
    /// `ScrollView` itself via `ScrollViewportHeightPreferenceKey` rather
    /// than taken from a `GeometryReader` wrapping the whole view, because
    /// the header now sits outside the `ScrollView` (see `body`) and no
    /// longer shares its height.
    @State private var scrollViewportHeight: CGFloat = 0

    /// The coordinate space `panelSection` measures frames in and the
    /// `ScrollView` publishes — named rather than `.global` so a panel's
    /// reported `minY` is already relative to the SCROLLING CONTAINER's own
    /// bounds (the viewport), not the whole window.
    private static let scrollCoordinateSpaceName = "cockpitScroll"

    static let dispatchedPanelID = "dispatched"
    private static let proposalsPanelID = "proposals"
    static let coursePanelID = "course"
    static let correctionsQueuePanelID = "correctionsQueue"
    /// The documents the selected session's checkout brought.
    static let checkoutPanelID = "checkout"
    /// The crew's own working documents — the steward's board only.
    static let documentsPanelID = "documents"
    /// Every pull request for the crew's project repo, with its ladder
    /// position (`issue_01M1372GNR81ZV7K1DXHAD10R0`).
    static let pullRequestsPanelID = "pullRequests"

    /// The steward's board: the fleet's dispatched runs, the product's
    /// proposed epics, the crew's Course, its corrections queue, and its
    /// working documents (issue_01M2GAFYACF3MZCF89F0HVZ5CP). The queue joined
    /// on the operator's decision of 2026-09-24: "yes to the steward having a
    /// corrections queue — now that it has a course it needs one". That
    /// replaced the earlier reading that the queue is a project crew's own
    /// work surface. Proposals sits directly above the Course it feeds and
    /// the queue directly below it, the same positions `panelOrder` gives
    /// them. The Course and the queue draw through this view's own
    /// `coursePanel` and `correctionsQueueContent`, so the board and the
    /// cockpit can never draw either two different ways.
    static let boardPanelIDs = [
        dispatchedPanelID, proposalsPanelID, coursePanelID, correctionsQueuePanelID, documentsPanelID,
    ]

    /// Top-to-bottom visual order — what the panel index lists in and what
    /// `topmostVisiblePanelID` walks. Not `private`: `CockpitViewTests`
    /// references it directly rather than re-typing the panel ids, the
    /// same way it reuses `rowTreatment` and `coursePartition` rather than
    /// reimplementing their logic.
    static let panelOrder = [
        dispatchedPanelID, proposalsPanelID, coursePanelID, correctionsQueuePanelID,
        pullRequestsPanelID, checkoutPanelID,
    ]

    private static let panelTitles: [String: String] = [
        dispatchedPanelID: "Dispatched",
        proposalsPanelID: "Proposals",
        coursePanelID: "Course",
        correctionsQueuePanelID: "Corrections Queue",
        documentsPanelID: "Working documents",
        checkoutPanelID: "Checkout documents",
        pullRequestsPanelID: "Pull Requests",
    ]

    /// "Dispatched" or "Dispatched (fleet)" — `SessionState.fleetWideSuffix`
    /// is the same constant `SessionPaneView`'s `agentsLabel` appends for the
    /// same fact, so the session pane and this panel can't drift apart on how
    /// to say "this list is the whole fleet's."
    private var dispatchedPanelTitle: String {
        (Self.panelTitles[Self.dispatchedPanelID] ?? "Dispatched")
            + (agentsAreFleetWide ? SessionState.fleetWideSuffix : "")
    }

    /// `panelTitles[id]`, except the Dispatched panel — the one title that
    /// varies per instance — routes through `dispatchedPanelTitle` instead
    /// of the static table.
    private func panelTitle(for id: String) -> String {
        id == Self.dispatchedPanelID ? dispatchedPanelTitle : (Self.panelTitles[id] ?? id)
    }

    /// The panel index's own, shorter label for an entry — `02-cockpit.html`
    /// draws "Queue" in the index and keeps "Corrections queue" for the
    /// aria-label only, and "Checkout" stands in for "Checkout documents" the
    /// same way. At the 328pt column the spec is drawn at, the full
    /// `panelTitle` eats room the four-entry layout was designed around;
    /// `panelSection`'s own header keeps the full name, since that header
    /// has no such neighbours to crowd. `panelTitle(for:)` still supplies
    /// the entry's accessibility label (`panelIndexEntry`), so VoiceOver
    /// hears the same full name the panel header itself carries.
    private func indexEntryLabel(for id: String) -> String {
        switch id {
        case Self.correctionsQueuePanelID: return "Queue"
        case Self.checkoutPanelID: return "Checkout"
        case Self.pullRequestsPanelID: return "PRs"
        default: return panelTitle(for: id)
        }
    }

    /// Reports one panel's frame, in `scrollCoordinateSpaceName`, up to the
    /// `ScrollView` that measures visibility against its own viewport.
    /// `Color.clear` in a `.background` is the usual SwiftUI shape for
    /// this — invisible, sized to exactly match the panel it is attached
    /// to, and its `GeometryReader` never affects layout since a
    /// `.background` takes its parent's size rather than proposing one.
    private struct PanelFramePreferenceKey: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    /// Reports the `ScrollView`'s own size up to `scrollViewportHeight` —
    /// same `Color.clear` + `GeometryReader` shape as `PanelFramePreferenceKey`,
    /// scoped to the `ScrollView`'s `.background` so what it measures is the
    /// viewport, not the whole pane.
    private struct ScrollViewportHeightPreferenceKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    /// **The header sits OUTSIDE the `ScrollView`, a sibling above it, not
    /// its first item.** An earlier version put it inside, which is exactly
    /// what let it scroll off the top along with everything else and undid
    /// the point of an "always-present" panel index — a reader down at the
    /// corrections queue had no on-screen way back to Dispatched, the same
    /// complaint this view exists to fix. This mirrors the spec's own markup
    /// (`design/redesign/02-cockpit.html`, `deck.css`'s
    /// `.cockpit { grid-template-rows: auto 1fr }`): a fixed `.head` row
    /// carrying the title and the index, and a separate, scrolling `.scroll`
    /// row underneath it — `Divider()` standing in for the `.head`'s own
    /// `border-bottom`.
    var body: some View {
        ScrollViewReader { scrollProxy in
            VStack(alignment: .leading, spacing: 0) {
                header(scrollProxy: scrollProxy)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if let unresolvedReason {
                            unresolvedState(unresolvedReason)
                        } else {
                            // DISPATCHED FIRST in both `panelOrder` and
                            // `boardPanelIDs` — the Course below it has no
                            // fixed height and grows with the epic list, so
                            // anything placed after it can be pushed off the
                            // bottom of the pane. Crew stats is the panel an
                            // operator most needs plainly visible, so it sits
                            // above that pressure instead of below it
                            // (issue_01M1CCYWG8409VA4PT4W1QBB5D).
                            ForEach(Array(panelIDs.enumerated()), id: \.element) { index, id in
                                if index > 0 { Divider().padding(.vertical, 4) }
                                panel(for: id)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // CONTAINER-LEVEL, NOT PER-`Text(` — `.textSelection`
                    // is inherited by descendants, so one modifier here
                    // reaches every static line in the four panels
                    // (issue_01M1HQXGN5QVYGQ6FAPX4KHS67: an operator
                    // wanting to copy an epic title or a claimed-by name
                    // out of the cockpit had no way to). It does NOT reach
                    // a `Button` label — SwiftUI suppresses selection
                    // inside a control's own label so the control stays a
                    // control — so the panel-header/rail/collapse buttons
                    // need no opt-out.
                    //
                    // `courseEntryRow` and the corrections-queue row are
                    // plain `HStack`s carrying `.onTapGesture`, not
                    // controls, so inherited selection is not suppressed
                    // the way it is inside a `Button` label — CONFIRMED in
                    // the running app (issue_01M1JK7QRCWVS5CV3KT4ET1TDV):
                    // clicking an epic row's title selected text instead of
                    // expanding the row, while the bubble and the chevron
                    // either side of it still expanded and collapsed as
                    // normal. Both rows opt back out below
                    // (`.textSelection(.disabled)`) and each carries a
                    // `.contextMenu` "Copy title" instead, since a
                    // right-click doesn't compete with the tap the way
                    // drag-select does — the whole row stays clickable and
                    // the title stays reachable, at the cost of copying
                    // only the whole title rather than a selected part of
                    // it.
                    .textSelection(.enabled)
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollViewportHeightPreferenceKey.self, value: geo.size.height)
                    }
                )
                .coordinateSpace(name: Self.scrollCoordinateSpaceName)
                // Preference diffing is Equatable-keyed ([String: CGRect] is
                // Equatable since CGRect is), so this callback — and the
                // @State write and the redraw it triggers — fires only when
                // a reported frame actually changed, not on every poll tick
                // that leaves layout untouched. See the PR body for the
                // full per-update cost accounting.
                .onPreferenceChange(PanelFramePreferenceKey.self) { panelFrames = $0 }
                .onPreferenceChange(ScrollViewportHeightPreferenceKey.self) { scrollViewportHeight = $0 }
                // `onAppear` covers a reveal that presented the cockpit
                // (the column was showing another occupant, so this view
                // was not mounted when the highlight was set); `onChange`
                // covers one that arrived while it was, and the moment the
                // epic's children finish loading.
                .onAppear { scrollToRevealedItem(scrollProxy) }
                .onChange(of: revealScrollTarget) { scrollToRevealedItem(scrollProxy) }
                .onChange(of: chipScrollTarget) { scrollToChipTarget(scrollProxy) }
            }
        }
    }

    /// A PR chip's click and which click asked for it — `RevealScrollTarget`'s
    /// own shape, for the reason that one gives: `onChange` fires on a new
    /// click, or once the id first exists (the queue just expanded to show
    /// it), and on nothing else.
    struct ChipScrollTarget: Equatable {
        let itemID: String
        let count: Int
    }

    private var chipScrollTarget: ChipScrollTarget? {
        guard let id = model.chipScrollID else { return nil }
        return ChipScrollTarget(itemID: id, count: model.chipScrollCount)
    }

    /// Scrolls a PR chip's target to the middle of the pane, once per click —
    /// `scrollToRevealedItem`'s own shape. The hop to the next main-queue
    /// turn is what lets `model.isQueueExpanded` flipping to `true` (inside
    /// `revealFromPullRequestChip`) lay out the newly-shown rows before
    /// `scrollTo` looks for one of them.
    private func scrollToChipTarget(_ scrollProxy: ScrollViewProxy) {
        guard let target = chipScrollTarget, target.count != scrolledChipCount else { return }
        scrolledChipCount = target.count
        DispatchQueue.main.async {
            withAnimation { scrollProxy.scrollTo(target.itemID, anchor: .center) }
        }
    }

    /// A reveal's row and which reveal asked for it. Equatable so `onChange`
    /// fires on a new reveal, or when the row first exists, and on nothing else.
    struct RevealScrollTarget: Equatable {
        let itemID: String
        let revealCount: Int
    }

    /// The highlighted item, once its row exists to scroll to. `reveal` can
    /// return before the epic's children have loaded, and `scrollTo` on an id
    /// nothing draws does nothing, so this stays `nil` until `children` holds
    /// the item.
    static func revealScrollTarget(
        highlightedItemID: String?, revealCount: Int,
        children: [String: CockpitModel.ChildrenState]
    ) -> RevealScrollTarget? {
        guard let itemID = highlightedItemID else { return nil }
        let isLoaded = children.values.contains { state in
            if case .loaded(let items) = state { return items.contains { $0.id == itemID } }
            return false
        }
        return isLoaded ? RevealScrollTarget(itemID: itemID, revealCount: revealCount) : nil
    }

    private var revealScrollTarget: RevealScrollTarget? {
        CockpitView.revealScrollTarget(
            highlightedItemID: model.highlightedItemID, revealCount: model.revealCount,
            children: model.childrenByEntry)
    }

    /// Scrolls the revealed row to the middle of the pane, once per reveal.
    /// The hop to the next main-queue turn is what lets the row exist in the
    /// layout by the time `scrollTo` looks for it: this is called from the
    /// update that inserts it.
    private func scrollToRevealedItem(_ scrollProxy: ScrollViewProxy) {
        guard let target = revealScrollTarget, target.revealCount != scrolledRevealCount else { return }
        scrolledRevealCount = target.revealCount
        DispatchQueue.main.async {
            withAnimation { scrollProxy.scrollTo(target.itemID, anchor: .center) }
        }
    }

    /// One panel by id — the single place an id becomes a section, so
    /// `panelIDs` alone decides which panels draw and in what order.
    @ViewBuilder
    private func panel(for id: String) -> some View {
        switch id {
        case Self.dispatchedPanelID:
            panelSection(id: id, title: dispatchedPanelTitle,
                         trailing: { crewStatsTrailing }, content: { crewStatsContent })
        case Self.proposalsPanelID:
            panelSection(id: id, title: "Proposals",
                         trailing: { EmptyView() }, content: { proposalsContent })
        case Self.coursePanelID:
            panelSection(id: id, title: "Course",
                         trailing: { EmptyView() }, content: { coursePanel })
        case Self.correctionsQueuePanelID:
            panelSection(id: id, title: "Corrections Queue",
                         trailing: { correctionsQueueTrailing }, content: { correctionsQueueContent })
        case Self.pullRequestsPanelID:
            panelSection(id: id, title: panelTitle(for: id),
                         trailing: { pullRequestsStalenessTrailing }, content: { pullRequestsContent })
        case Self.documentsPanelID:
            panelSection(id: id, title: panelTitle(for: id),
                         trailing: { EmptyView() }, content: { documentsContent })
        case Self.checkoutPanelID:
            panelSection(id: id, title: panelTitle(for: id),
                         trailing: { EmptyView() }, content: { checkoutContent })
        default:
            EmptyView()
        }
    }

    // MARK: - Working documents

    /// The crew's own working documents, each opening in the viewer. Moved
    /// here from the steward board's former view, unchanged, when the board
    /// became this view with `boardPanelIDs`.
    @ViewBuilder
    private var documentsContent: some View {
        let paths = documents?.paths ?? []
        if paths.isEmpty {
            Text("This crew names no documents and has no working directory to find its role file in.")
                .frameFont(.label).foregroundStyle(secondaryInk)
        } else {
            ForEach(paths, id: \.self) { path in
                documentRow(path)
            }
        }
    }

    /// One document — the same clickable-row shape `courseEntryRow` and the
    /// corrections-queue row use: the whole row is the tap target, and the
    /// full path is a tooltip for a name that alone doesn't say which crew's
    /// directory it's in.
    private func documentRow(_ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .frameFont(.icon)
                .foregroundStyle(secondaryInk)
                .frame(width: 14, alignment: .center)
            Text((path as NSString).lastPathComponent)
                .frameFont(.label)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { documents?.onOpen(path) }
        .help(path)
        // Opts out of the container's `.textSelection(.enabled)` for the
        // same reason `courseEntryRow` does: the row's own text is the tap
        // target, so selection would compete with the click.
        .textSelection(.disabled)
    }

    // MARK: - Checkout documents

    /// How many documents the checkout brought, or nil when there is no list
    /// to count — loading, a named reason, or a failure all draw "—" in the
    /// index rather than a zero that would say the checkout was empty.
    nonisolated static func checkoutDocumentCount(_ state: CheckoutDocumentsModel.State?) -> Int? {
        guard case .loaded(.listed(_, let documents)) = state else { return nil }
        return documents.count
    }

    /// How many of the panel's merged rows are `.readyToMerge` — the number
    /// that asks for a decision, not how many rows the panel draws (which
    /// the reader can already see by looking at the list below it). A
    /// `readyToMerge` row is always open, so `orderedForDisplay`'s
    /// recent-closed cut can never drop one; filtering the raw `results`
    /// is equivalent to filtering the displayed rows. `nil` when no repo
    /// has ever produced a real result — every repo still loading, wholly
    /// degraded, or erroring outright — since none of those is a real
    /// count; once at least one repo HAS produced rows, the count is real
    /// even if another of the crew's repos is still failing
    /// (`issue_01M2P5JHM1G8XCMKM4HEHVJB2P`'s "degrade that repo's rows,
    /// not the whole panel").
    nonisolated static func pullRequestsCount(_ panel: PullRequestsPanel?) -> Int? {
        guard hasAnyLadderReading(panel) else { return nil }
        return mergedLadder(panel).results.filter { $0.position == .readyToMerge }.count
    }

    /// How many rows the panel draws in total, after `orderedForDisplay`'s
    /// recent-closed cut (or all of them, once `expanded`) — `panelIndexCount`
    /// pairs this with `pullRequestsCount` so the index reads "0/8", not a
    /// bare "0" that looks the same as "no pull requests at all" beside eight
    /// open rows (rendered both ways to check; the bare form was the one that
    /// read wrong). `nil` under the same condition `pullRequestsCount` returns
    /// `nil` for.
    nonisolated static func pullRequestsTotalCount(_ panel: PullRequestsPanel?, expanded: Bool = false) -> Int? {
        guard hasAnyLadderReading(panel) else { return nil }
        return PRLadder.orderedForDisplay(mergedLadder(panel).results, expanded: expanded).count
    }

    /// Whether the Pull Requests panel should show its truncation notice —
    /// true when ANY followed repo's `PRLadder.fetchLadder` reported one of
    /// its two paged reads gave up before the Library stopped saying there
    /// was more (`PRLadder.FetchResult.ladder`'s own doc). `false`
    /// when no repo has a `.ladder` result at all — `.degraded` or a bare
    /// fetch error already says the panel could not be trusted for a
    /// different, already-surfaced reason.
    nonisolated static func pullRequestsAreTruncated(_ panel: PullRequestsPanel?) -> Bool {
        mergedLadder(panel).truncated
    }

    /// Every state but a non-empty list is one sentence. A named reason
    /// shows in words and is never an empty list, which would say the
    /// checkout brought nothing (issue_01M0Y6VZJA6Z2S45C9WX4EK0YQ).
    @ViewBuilder
    private var checkoutContent: some View {
        switch checkoutDocuments?.state ?? .idle {
        case .idle:
            checkoutSentence("No session selected.")
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                checkoutSentence("Reading this session's checkout…")
            }
        case .failed(let sentence):
            checkoutSentence(sentence)
        case .loaded(.unavailable(let reason)):
            checkoutSentence(reason.explanation)
        case .loaded(.listed(let profile, let documents)):
            if documents.isEmpty {
                checkoutSentence("This session's checkout brought no documents.")
            } else {
                if let profile {
                    Text("Profile \(profile)")
                        .frameFont(.label).foregroundStyle(secondaryInk)
                }
                ForEach(CheckoutDocuments.groups(documents)) { group in
                    checkoutGroup(group)
                }
            }
        }
    }

    private func checkoutSentence(_ text: String) -> some View {
        Text(text).frameFont(.label).foregroundStyle(secondaryInk)
    }

    /// One kind: a header carrying its count that expands or collapses the
    /// group, and the group's rows while expanded.
    @ViewBuilder
    private func checkoutGroup(_ group: CheckoutDocuments.Group) -> some View {
        let isExpanded = checkoutGroupExpansion[group.kind] ?? group.isExpandedByDefault
        Button {
            checkoutGroupExpansion[group.kind] = !isExpanded
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(tertiaryInk)
                    .frame(width: 10)
                Text(group.title).frameFont(.label).fontWeight(.semibold)
                Text("\(group.documents.count)")
                    .frameFont(.label).foregroundStyle(secondaryInk).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(group.title), \(group.documents.count), \(isExpanded ? "expanded" : "collapsed"). "
            + "Activate to \(isExpanded ? "collapse" : "expand") it.")
        if isExpanded {
            ForEach(group.documents) { document in
                checkoutRow(document)
            }
            .padding(.leading, 14)
        }
    }

    /// One document, in `documentRow`'s shape: the whole row is the tap
    /// target, and the full KB id is the tooltip.
    private func checkoutRow(_ document: CheckoutDocuments.Document) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .frameFont(.icon)
                .foregroundStyle(secondaryInk)
                .frame(width: 14, alignment: .center)
            Text(document.slug)
                .frameFont(.label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture { checkoutDocuments?.onOpen(document.id) }
        .help(document.id)
        .textSelection(.disabled)
    }

    /// How old a reading has to be before it is worth a caveat — pegged to
    /// `PRLadderModel.refreshInterval` (900s), not to seconds: the model
    /// resweeps every cached repo on that cadence, so a row still younger
    /// than it is already as fresh as this session's own polling gets, and
    /// the upstream capture (`agent-platform/bin/pr-state-capture`'s own
    /// 900s launchd tick) means it is already as fresh as the *data* gets
    /// either way. A reading still older than this missed its own resweep —
    /// the case actually worth flagging.
    static let stalenessThreshold = TimeInterval(PRLadderModel.refreshInterval.components.seconds)

    /// The Pull Requests header's staleness note, or `nil` when the reading
    /// needs no caveat. Two facts, either or both shown:
    ///
    /// - **age**, once `fetchedAt` is at least `stalenessThreshold` old —
    ///   younger than that draws nothing, since flagging every reading
    ///   would turn the one signal worth noticing into wallpaper
    ///   (`issue_01M2P60KDY9KPXWMZ4C6G1CJ52` point 5's own "infer it" concern).
    /// - **refreshing**, whenever `isLoading` is true, whatever the age —
    ///   a fetch in flight is worth saying the instant it starts, since it's
    ///   the answer to "is this about to change," and it says so for as
    ///   long as it's true and no longer, so it never becomes furniture.
    ///
    /// `fetchedAt: nil` (never yet fetched successfully) draws no age —
    /// there is no second clock to invent one from, so a not-yet-known age
    /// says nothing rather than a guess (the fetch-error panel state
    /// already says why via `unreachableLine`, before this is ever
    /// reached). A refresh failure on rows already held leaves `fetchedAt`
    /// dating those surviving rows, so this keeps reporting their real age
    /// while `pullRequestsContent` separately says the latest refresh
    /// failed (`issue_01M2PMHZVF1WN0VSJRHZHD2PD6`).
    nonisolated static func pullRequestsStalenessText(
        fetchedAt: Date?, isLoading: Bool, now: Date
    ) -> String? {
        let ageText = fetchedAt.flatMap { fetched -> String? in
            let age = now.timeIntervalSince(fetched)
            guard age >= stalenessThreshold else { return nil }
            return ageDescription(age)
        }
        switch (ageText, isLoading) {
        case (nil, false): return nil
        case (nil, true): return "refreshing…"
        case (let text?, false): return text
        case (let text?, true): return "\(text) · refreshing"
        }
    }

    /// `stalenessThreshold`-or-older durations, in the coarsest unit that
    /// still reads as one number — minutes below an hour, then hours (plus
    /// a remainder in minutes), then whole days past that. No reading has
    /// been observed old enough to need the day form, but an operator
    /// stepping away for a weekend shouldn't get an hour count in the
    /// thousands.
    private static func ageDescription(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m old" }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h old" : "\(hours)h \(remainder)m old"
        }
        return "\(hours / 24)d old"
    }

    /// The oldest `fetchedAt` among a panel's readings that have ever
    /// fetched successfully — the panel is only as fresh as its
    /// least-fresh followed repo. `nil` when no repo has ever fetched
    /// successfully, the same "no second clock to invent an age from"
    /// posture the single-repo predecessor of this took.
    nonisolated static func oldestFetchedAt(_ panel: PullRequestsPanel?) -> Date? {
        (panel?.readings ?? []).compactMap(\.fetchedAt).min()
    }

    /// Whether any followed repo is presently mid-fetch — worth saying the
    /// instant any one of them starts, the same reasoning
    /// `pullRequestsStalenessText`'s own doc gives for a single repo.
    nonisolated static func anyReadingIsLoading(_ panel: PullRequestsPanel?) -> Bool {
        (panel?.readings ?? []).contains(where: \.isLoading)
    }

    /// The Pull Requests panel header's trailing accessory — the staleness
    /// note, drawn beside the title rather than above the rows, so an old
    /// reading costs no extra line and never pushes the rows or the panels
    /// below them (the epic's own "keep it cheap" constraint).
    @ViewBuilder
    private var pullRequestsStalenessTrailing: some View {
        if let text = CockpitView.pullRequestsStalenessText(
            fetchedAt: CockpitView.oldestFetchedAt(pullRequests),
            isLoading: CockpitView.anyReadingIsLoading(pullRequests), now: Date()
        ) {
            Text(text)
                .frameFont(.caption)
                .foregroundStyle(secondaryInk)
                .lineLimit(1)
        }
    }

    // MARK: - Pull Requests
    //
    // NO MERGE OR CLOSE AFFORDANCE ANYWHERE IN THIS SECTION, per the epic's
    // own "not in this epic" boundary — that stays true. The one exception is
    // the `#N` number, which opens the PR's GitHub page
    // (`PRLadderRow.githubURL`, issue_01M2P4JJFW5CE8FT0ZTASR6KN5) as the
    // explicitly temporary placeholder for the merge affordance the epic
    // still blocks. The rest of the row opens the reviews pane
    // (`onSelectPullRequest`, issue_01M3830X3DXRZDJFB8657YRCMK) on a tap of
    // its own, the same nested tap-within-tap shape `courseEntryRow` and the
    // corrections-queue row already use for their own click targets, and the
    // whole row opts out of `.textSelection(.enabled)` (see `body`) for the
    // same reason those two do.

    /// A named unresolved reason, real rows (with a per-repo failure note
    /// alongside for any followed repo whose own latest fetch could not be
    /// trusted), or "nothing fetched yet" — the same split `coursePanel`
    /// draws, except rows now outrank a repo's own failure: a repo that
    /// still has rows from its last success shows them plus the failure
    /// note, rather than the error alone hiding data the operator already
    /// had (`issue_01M2PMHZVF1WN0VSJRHZHD2PD6`), and now generalized so ONE
    /// followed repo's failure degrades only that repo's rows rather than
    /// blanking the whole panel (`issue_01M2P5JHM1G8XCMKM4HEHVJB2P`).
    @ViewBuilder
    private var pullRequestsContent: some View {
        if let pullRequestsUnresolvedReason {
            Text(pullRequestsUnresolvedReason).frameFont(.label).foregroundStyle(secondaryInk)
        } else if let panel = pullRequests, !panel.readings.isEmpty {
            let merged = CockpitView.mergedLadder(panel)
            let rows = PRLadder.orderedForDisplay(merged.results, expanded: model.isPullRequestsExpanded)
            let showsRepoMark = CockpitView.showsRepoMark(panel)
            if rows.isEmpty, merged.failures.isEmpty, !CockpitView.anyReadingIsLoading(panel) {
                Text(panel.readings.count > 1 ? "No pull requests for these repos." : "No pull requests for this repo.")
                    .frameFont(.label).foregroundStyle(secondaryInk)
            } else if rows.isEmpty, merged.failures.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading pull requests…").frameFont(.label).foregroundStyle(secondaryInk)
                }
            } else {
                let chips = pullRequestWorkItemChipsByIdentity
                ForEach(rows, id: \.identityKey) { row in
                    pullRequestRow(row, showsRepoMark: showsRepoMark, chip: chips[row.identityKey])
                }
                pullRequestsExpander(merged.results)
            }
            if merged.truncated {
                pullRequestsTruncatedNotice
            }
            ForEach(merged.failures, id: \.self) { failure in
                unreachableLine(
                    showsRepoMark ? "\(failure.owner)/\(failure.repoName) could not be read" : "Could not reach pull requests",
                    detail: failure.reason)
            }
            if panel.droppedByCap > 0 {
                repoCapNotice(droppedCount: panel.droppedByCap)
            }
        } else {
            Text("No pull requests read yet.")
                .frameFont(.label).foregroundStyle(secondaryInk)
        }
    }

    /// The way to the closed rows `orderedForDisplay`'s collapsed default
    /// hides, and the way back — `queueExpander`'s own pattern: says how many
    /// are hidden rather than a bare "show more", draws nothing once there's
    /// nothing to reveal (`PRLadder.hiddenClosedCount` is `0`), and reads its
    /// expanded state off the model so a slow-timer refresh underneath it
    /// doesn't collapse it back.
    @ViewBuilder
    private func pullRequestsExpander(_ results: [PRLadder.LadderResult]) -> some View {
        let hidden = PRLadder.hiddenClosedCount(results)
        if hidden > 0 {
            Button {
                model.togglePullRequestsExpansion()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.isPullRequestsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                    Text(model.isPullRequestsExpanded ? "Show fewer" : "\(hidden) more")
                        .frameFont(.label)
                }
                .foregroundStyle(secondaryInk)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    /// Shown once a crew names more repos than `CockpitResolution.maxFollowedRepos`
    /// — the cap's own "degrade visibly rather than silently" requirement:
    /// the panel draws the repos it DID fetch with no indication otherwise
    /// that any were left out.
    private func repoCapNotice(droppedCount: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .frameFont(.icon)
            Text(droppedCount == 1
                 ? "This crew names 1 more repo than the Pull Requests panel follows at once."
                 : "This crew names \(droppedCount) more repos than the Pull Requests panel follows at once.")
                .frameFont(.label)
        }
        .foregroundStyle(Color(ThemeRecipe.attentionTextInk(on: indexSurface)))
        .padding(.top, 4)
    }

    /// Shown when `PRLadder.fetchLadder` gave up paging one of its two reads
    /// still mid-truncation — the same explicit "some rows are missing"
    /// posture `queueTruncatedNotice` takes for the corrections queue,
    /// rather than the panel quietly presenting a short read as the whole
    /// ladder.
    ///
    /// **The copy describes the effect the review-records read can still
    /// have, because that is the read that can still trip.** The Library now
    /// serves one row per pull request (`GET /signals/pr-state`), so the
    /// state read would need 5,000 open or recently closed PRs in a single
    /// repo to hit the page budget. A truncated review-records read sheds the
    /// OLDEST records, and a shown PR then loses whichever review sat among
    /// them: a blocking `REQUEST_CHANGES` that vanished lets the PR read
    /// further along the ladder than it is (see `fetchLadder`'s own doc). The
    /// flag does not say which read gave up, and the copy says nothing about
    /// a missing row, since the only way to lose one is the state read.
    private var pullRequestsTruncatedNotice: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .frameFont(.icon)
            Text(
                "The Library holds more than this panel could page in — " +
                "a pull request may be drawn without a review that would change its position.")
                .frameFont(.label)
        }
        .foregroundStyle(Color(ThemeRecipe.attentionTextInk(on: indexSurface)))
        .padding(.top, 4)
    }

    /// A PR row's stable-key chip (issue_01M2P5D0D4EQEQX7BSRNFT5QGJ) —
    /// resolved client-side, never fetched for: the join is over whatever the
    /// cockpit already holds, so a row with no matching work item draws no
    /// chip, same as any other field in this file that costs nothing when
    /// absent.
    struct PullRequestWorkItemChip: Equatable {
        /// `"E9·4"`, `"E16"`, or `"CQ·63"` — drawn verbatim before `#N`.
        let key: String
        /// What `.help` says: the epic's own title for an `E` key (whether
        /// the chip's item IS the epic or is filed under it), the
        /// correction's own title for a `CQ` key, which has no epic.
        let tooltip: String
        /// The id a click scrolls to — an epic's id for an `E` key, the
        /// correction's own id for a `CQ` key.
        let scrollTargetID: String
        /// `true` routes the click through `CockpitModel.revealFromPullRequestChip`
        /// at the Course; `false` routes it at the corrections queue.
        let isEpic: Bool
    }

    /// `"owner/repo#123"` from a Library record's own `(prRepo, pr)` pair, or
    /// `nil` when either half is missing or `pr` is not a whole number —
    /// exactly the shape `PRLadder.LadderResult.identityKey` builds from a
    /// ladder row's `(repo, number)`, so the two sides of the join agree on
    /// one key without either knowing about the other's type.
    private static func prWorkItemIdentity(repo: String?, pr: String?) -> String? {
        guard let repo, !repo.isEmpty, let pr, let number = Int(pr) else { return nil }
        return "\(repo)#\(number)"
    }

    /// Joins `CockpitModel.allWorkItems` — its own unfiltered,
    /// every-state-and-type `GET /items?product=X&limit=200` read
    /// (issue_01M3WPNJ1ESJVCVJ85FVNQHNKC) — against
    /// `PRLadder.LadderResult.identityKey`, so `pullRequestRow` can look its
    /// own row straight up with no second pass over either side. **This
    /// replaced a join over whatever the cockpit happened to already hold in
    /// memory** (Course entries, the children of expanded epics, the
    /// corrections queue), which drew no chip for an item under an
    /// unexpanded epic and none at all for a resolved item, since a resolved
    /// correction leaves the queue and a resolved child is never fetched.
    ///
    /// An item with a `parentId` names a filed item: the chip is keyed and
    /// tooltipped for its PARENT epic — hover and click both point at the
    /// epic, not at the child carrying the PR — and the parent's title comes
    /// from this same response when the parent is in it (epics are items
    /// too), falling back to `course`'s own copy and then to the item's own
    /// title when neither has it. An item with no `parentId` is either an
    /// epic itself (`type == "epic"`, chip routes to the Course) or a
    /// parent-less correction (chip routes to the queue); either way the
    /// chip names and tooltips the item's own title. A `parentId` in
    /// `correctionsQueueIds` names the product's corrections queue rather
    /// than an epic, so that item draws as a parent-less correction
    /// (`LibraryClient.CorrectionsQueue.correctionsQueueIds`).
    ///
    /// `course` is read only for that title fallback, not for identity — the
    /// join's one source of truth for which rows exist and what they carry
    /// is `allItems`. A PR with no matching item is simply absent from the
    /// result. The click itself still degrades on its own:
    /// `CockpitModel.revealFromPullRequestChip` no-ops when its target is not
    /// actually on the Course or in the queue (a resolved epic, a resolved
    /// correction), so the chip and tooltip draw regardless and only the
    /// click goes nowhere — exactly what the item's own spec asks for.
    ///
    /// A pure function of already-decoded state, the same discipline
    /// `coursePartition` and `rowTreatment` follow — testable without a view.
    nonisolated static func pullRequestWorkItemChips(
        allItems: [LibraryClient.WorkItemRecord],
        course: LibraryClient.Course?,
        correctionsQueueIds: Set<String> = []
    ) -> [String: PullRequestWorkItemChip] {
        var titleByID: [String: String] = [:]
        for item in allItems where titleByID[item.id] == nil {
            titleByID[item.id] = item.title
        }
        for entry in course?.entries ?? [] where titleByID[entry.id] == nil {
            titleByID[entry.id] = entry.title
        }
        var chips: [String: PullRequestWorkItemChip] = [:]
        for item in allItems {
            guard let key = item.key,
                  let identity = prWorkItemIdentity(repo: item.prRepo, pr: item.pr) else { continue }
            if let parentId = item.parentId, !correctionsQueueIds.contains(parentId) {
                chips[identity] = PullRequestWorkItemChip(
                    key: key, tooltip: titleByID[parentId] ?? item.title, scrollTargetID: parentId, isEpic: true)
            } else {
                chips[identity] = PullRequestWorkItemChip(
                    key: key, tooltip: item.title, scrollTargetID: item.id, isEpic: item.type == "epic")
            }
        }
        return chips
    }

    /// `pullRequestWorkItemChips`, read off this view's own model state —
    /// recomputed each render the same way `pullRequestsContent`'s own
    /// `mergedLadder` is, over data already in memory rather than a fetch.
    private var pullRequestWorkItemChipsByIdentity: [String: PullRequestWorkItemChip] {
        CockpitView.pullRequestWorkItemChips(allItems: model.allWorkItems, course: model.course,
                                             correctionsQueueIds: model.queue?.correctionsQueueIds ?? [])
    }

    /// One pull request: number, title, author, and its ladder position —
    /// the exact four fields the specification names. A stale review count
    /// (`reviewed_ref != head`) draws alongside the position rather than
    /// replacing it, since a stale review is additional context on top of
    /// whatever the position already says, not a fifth position of its own.
    ///
    /// **`showsRepoMark`** draws the repo's bare name (`PRLadderRow.repoMark`)
    /// right before `#N` once the crew follows more than one repo — `#238`
    /// alone stops identifying a PR the moment two repos are both in play
    /// (`issue_01M2P5JHM1G8XCMKM4HEHVJB2P`). `false` for the common
    /// single-repo case draws exactly the row this replaces.
    ///
    /// **`chip`** is the work item this PR belongs to, if
    /// `pullRequestWorkItemChipsByIdentity` could place one — drawn before
    /// `#N` per the item's own approved design, `nil` drawing exactly the
    /// row that predates this feature.
    private func pullRequestRow(
        _ row: PRLadder.LadderResult, showsRepoMark: Bool, chip: PullRequestWorkItemChip?
    ) -> some View {
        let presentation = PRLadderRow.present(row.position)
        let dotColor = PRLadderRow.dotColor(row.position)
        let githubURL = PRLadderRow.githubURL(repo: row.repo, number: row.number)
        let repoMark = showsRepoMark ? PRLadderRow.repoMark(row.repo) : nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The same leading column `courseEntryRow`'s glyph draws in —
                // 14pt-wide, `.icon`-sized, baseline-aligned with the row's
                // first line — so a PR row and a Course row read as the same
                // shape of line, one a stoplight and the other a phase glyph.
                Image(systemName: "circle.fill")
                    .frameFont(.icon)
                    .foregroundStyle(Color(ThemeRecipe.prDotInk(dotColor, appearance: appearance,
                                                                    on: indexSurface)))
                    .frame(width: 14, alignment: .center)
                    .help(presentation.label)
                if let chip {
                    Text(chip.key)
                        .frameFont(.caption)
                        .foregroundStyle(Color(ThemeRecipe.workItemChipInk(on: indexSurface)))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color(ThemeRecipe.workItemChipInk(on: indexSurface)).opacity(0.4))
                        )
                        .help(chip.tooltip)
                        .onTapGesture {
                            model.revealFromPullRequestChip(itemID: chip.scrollTargetID, isEpic: chip.isEpic)
                        }
                        .textSelection(.disabled)
                }
                if let repoMark {
                    Text(repoMark)
                        .frameFont(.caption)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(1)
                        .help(row.repo)
                }
                Group {
                    if let githubURL {
                        Text("#\(row.number)")
                            .underline()
                            .onTapGesture { NSWorkspace.shared.open(githubURL) }
                            .help("Open #\(row.number) on GitHub")
                            .textSelection(.disabled)
                    } else {
                        Text("#\(row.number)")
                    }
                }
                .frameFont(.label).foregroundStyle(secondaryInk).monospacedDigit()
                Text(row.title ?? "(untitled)")
                    .frameFont(.body)
                    .strikethrough(presentation.isTerminal)
                    .foregroundStyle(presentation.isTerminal ? secondaryInk : AnyShapeStyle(.primary))
                    .lineLimit(2)
                    .help(CockpitView.libraryTooltip(row.title ?? "(untitled)"))
            }
            HStack(spacing: 6) {
                if let author = row.author {
                    Text(author).frameFont(.caption).foregroundStyle(secondaryInk)
                }
                Text(presentation.label)
                    .frameFont(.caption)
                    .fontWeight(presentation.severity == .neutral ? .regular : .semibold)
                    .foregroundStyle(pullRequestSeverityInk(presentation.severity))
                if let staleLabel = PRLadderRow.staleReviewsLabel(row.staleReviewCount) {
                    Text(staleLabel).frameFont(.caption).foregroundStyle(secondaryInk).italic()
                }
            }
            // Indented under the title, past the dot column and its
            // spacing (14 + 6 = 20) — the same "aligns under the title"
            // shape `epicDetail` gives the Course's own expansion.
            .padding(.leading, 20)
        }
        .contentShape(Rectangle())
        // The same nested-gesture shape `courseEntryRow`'s tap/`Button` split
        // already relies on: the `#N` text's own `.onTapGesture` above sits
        // deeper in the tree and wins a tap on itself, so this row-level
        // gesture only ever fires for a tap elsewhere on the row.
        .onTapGesture { onSelectPullRequest?(row) }
        // Opts out of the container-level `.textSelection(.enabled)` — see
        // this section's own header comment.
        .textSelection(.disabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CockpitView.pullRequestRowAccessibilityLabel(row, repoMark: repoMark, chip: chip))
    }

    /// `pullRequestRow`'s own accessibility label, pulled into a plain
    /// function so the type-checker isn't asked to solve string
    /// concatenation inside a view-modifier chain in one pass — the
    /// compiler could not resolve it inline once the repo-mark clause was
    /// added.
    ///
    /// **Names the position, same as before `chip` existed, and now also
    /// the work item** — the item's own constraint: "keep the row
    /// accessibility label naming the position, and add the work item key
    /// to it."
    private static func pullRequestRowAccessibilityLabel(
        _ row: PRLadder.LadderResult, repoMark: String?, chip: PullRequestWorkItemChip?
    ) -> String {
        let presentation = PRLadderRow.present(row.position)
        var parts: [String] = []
        if let repoMark { parts.append(repoMark) }
        parts.append("PR #\(row.number), \(row.title ?? "untitled")")
        if let author = row.author { parts.append("by \(author)") }
        parts.append(presentation.label)
        if let staleLabel = PRLadderRow.staleReviewsLabel(row.staleReviewCount) { parts.append(staleLabel) }
        if let chip { parts.append("work item \(chip.key)") }
        return parts.joined(separator: ", ")
    }

    /// `PRLadderRow.Severity` → ink, on the surface every other degrade or
    /// attention mark in this file is solved against. `.invitation` reuses
    /// `attentionTextInk` — the same ink the blocked lock icon and the
    /// queue's `HIGH` chip already use for "this needs the operator", so "ready to
    /// merge" reads as the same category of summons rather than inventing a
    /// fourth ink for one more "needs a person" case.
    private func pullRequestSeverityInk(_ severity: PRLadderRow.Severity) -> AnyShapeStyle {
        switch severity {
        case .neutral: return secondaryInk
        case .caution: return AnyShapeStyle(Color(ThemeRecipe.warningInk(on: indexSurface)))
        case .failure: return AnyShapeStyle(Color(ThemeRecipe.errorInk(on: indexSurface)))
        case .invitation: return AnyShapeStyle(Color(ThemeRecipe.attentionTextInk(on: indexSurface)))
        }
    }

    // MARK: - Panel collapse, frame tracking, and the panel index

    /// One top-level panel: a header carrying the collapse affordance and
    /// an optional trailing accessory (a count, a compose button), and its
    /// content — hidden entirely while collapsed, exactly the "just the
    /// header" shape the epic asks for. Every panel in the column goes
    /// through this one wrapper, which is what makes the panel index and the
    /// collapse affordance uniform across panels that otherwise have
    /// nothing in common (a list, an error line, a form trigger).
    ///
    /// **The frame report sits on the whole section, header included** —
    /// collapsing shrinks what `panelSection` reports, so a panel's
    /// neighbours below it naturally slide up in the next geometry pass
    /// with no extra wiring: `topmostVisiblePanelID` re-reads `panelFrames`
    /// from a `PreferenceKey`, not a snapshot taken once.
    @ViewBuilder
    private func panelSection<Trailing: View, Content: View>(
        id: String,
        title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsedPanelIDs.contains(id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    if isCollapsed {
                        collapsedPanelIDs.remove(id)
                    } else {
                        collapsedPanelIDs.insert(id)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(tertiaryInk)
                            .frame(width: 10)
                        Text(title).frameFont(.body).fontWeight(.semibold)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(title), \(isCollapsed ? "collapsed" : "expanded"). Activate to "
                    + "\(isCollapsed ? "expand" : "collapse") \(title)."
                )
                Spacer()
                trailing()
            }
            if !isCollapsed {
                content()
            }
        }
        .id(id)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PanelFramePreferenceKey.self,
                    value: [id: geo.frame(in: .named(Self.scrollCoordinateSpaceName))]
                )
            }
        )
    }

    /// The always-present panel index (issue_01M1QYBWFCH9XTTF4RY4J4EZ81,
    /// `design/redesign/02-cockpit.html`): one entry per `panelOrder` id,
    /// each carrying a count, replacing the old off-screen rail that
    /// appeared only once a panel had scrolled below the fold. **This
    /// reverses that rail's recorded absent-unless-needed choice
    /// (`deck/bead/deck`'s "furniture, not an alert") — the spec's own
    /// call, made because a count is information rather than furniture,
    /// and not re-litigated here.**
    ///
    /// **Gated on `unresolvedReason == nil`.** No panel renders while a
    /// crew is unresolved, so `panelFrames` — a `@State` that outlives that
    /// transition — could otherwise hold stale frames from before the
    /// crew was deselected and draw entries with no matching `.id` for
    /// `scrollProxy.scrollTo` to find.
    @ViewBuilder
    private func panelIndex(scrollProxy: ScrollViewProxy) -> some View {
        if unresolvedReason == nil {
            let hereID = CockpitView.topmostVisiblePanelID(
                order: panelIDs, frames: panelFrames, viewportHeight: scrollViewportHeight
            )
            PanelIndexFlowLayout {
                ForEach(panelIDs, id: \.self) { id in
                    panelIndexEntry(id: id, isHere: id == hereID, scrollProxy: scrollProxy)
                }
            }
        }
    }

    /// One index entry: the panel's title and count, underlined while it is
    /// `isHere`, struck while collapsed. Activating a collapsed entry both
    /// expands it and scrolls to it — the index and `collapsedPanelIDs`
    /// never draw a panel two different ways at once.
    private func panelIndexEntry(id: String, isHere: Bool, scrollProxy: ScrollViewProxy) -> some View {
        let isCollapsed = collapsedPanelIDs.contains(id)
        let accessibilityTitle = panelTitle(for: id)
        let count = CockpitView.panelIndexCount(
            id: id, agentRuns: agentRuns,
            proposalCount: proposalsUnresolvedReason == nil ? model.proposedEpics.count : nil,
            courseEntries: courseUnresolvedReason == nil ? model.course?.entries : nil,
            queueTotal: model.queue?.total, documentCount: documents?.paths.count,
            checkoutDocumentCount: Self.checkoutDocumentCount(checkoutDocuments?.state),
            pullRequestCount: Self.pullRequestsCount(pullRequests),
            pullRequestTotalCount: Self.pullRequestsTotalCount(pullRequests, expanded: model.isPullRequestsExpanded)
        )
        return Button {
            if isCollapsed {
                collapsedPanelIDs.remove(id)
            }
            withAnimation { scrollProxy.scrollTo(id, anchor: .top) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(indexEntryLabel(for: id)).fontWeight(.semibold).strikethrough(isCollapsed)
                Group {
                    if let count {
                        Text(count).foregroundStyle(indexCountInk(id: id, isCollapsed: isCollapsed))
                    } else {
                        Text("—").foregroundStyle(isCollapsed ? secondaryInk : AnyShapeStyle(.primary))
                    }
                }
                .monospacedDigit()
                // `.index a .n` is regular weight in the spec; only the name
                // (`.index a b`) is bold. `frameFont(.label)` below sets the
                // row to `.semibold`, so the count needs its own override —
                // except the queue's, whose `.n.hot` rule carries semibold
                // as part of its attention-hue badge (`indexCountWeight`).
                .fontWeight(CockpitView.indexCountWeight(id: id))
            }
            .frameFont(.label)
            .foregroundStyle(isCollapsed ? secondaryInk : AnyShapeStyle(.primary))
            .padding(.bottom, 3)
            .overlay(alignment: .bottom) {
                if isHere {
                    Rectangle().fill(.primary).frame(height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            CockpitView.panelIndexAccessibilityLabel(title: accessibilityTitle, count: count))
    }

    /// The surface the panel index text is drawn on — no session canvas or
    /// accent applies here, so this is the same "no canvas" fallback
    /// `SessionPaneView.inkSurface` uses for the shell's own window
    /// background: an approximation, not a read of the real window colour,
    /// which is what every other ink in this vocabulary already accepts
    /// (`ThemeRecipe.attentionInk`'s `on surface:` contract is a legibility
    /// floor, not a colour match).
    private var indexSurface: RGB {
        CockpitView.resolvedIndexSurface(appearance: appearance, ground: statusGround)
    }

    /// `indexSurface`'s own computation, pulled out `static` so
    /// `ServiceCrewPanel` can draw an in-progress mark against the same
    /// approximation this file uses for a session with no theme resolved —
    /// see `indexSurface`'s own doc for why an approximation is the right
    /// answer here, not a window-colour read.
    nonisolated static func resolvedIndexSurface(appearance: Appearance, ground: RGB? = nil) -> RGB {
        ground ?? (appearance == .dark
            ? RGB(red: 0.12, green: 0.12, blue: 0.13)
            : RGB(red: 0.98, green: 0.98, blue: 0.98))
    }

    /// `accent`, or the same neutral `SessionPaneView`'s own live bar draws
    /// when a session has no theme resolved yet — so an in-progress mark
    /// here never has to special-case the unresolved crew.
    private var resolvedAccent: RGB { accent ?? SessionPaneView.neutralAccent(appearance) }

    /// The queue's count draws in the attention hue — `deck.css`'s
    /// `.n.hot` rule, called out in the spec as half the justification for
    /// showing a count at all: "the queue's 23 in the summons hue is the
    /// interrupt lane's badge." Every other entry's count keeps the
    /// title's own ink, collapsed or not — the CSS rule this mirrors
    /// targets only the bold title (`a.collapsed b`), never the count, so
    /// a collapsed queue entry keeps its hot count too.
    private func indexCountInk(id: String, isCollapsed: Bool) -> AnyShapeStyle {
        guard id == Self.correctionsQueuePanelID else {
            return isCollapsed ? secondaryInk : AnyShapeStyle(.primary)
        }
        return AnyShapeStyle(Color(ThemeRecipe.attentionInk(on: indexSurface)))
    }

    /// `deck.css`'s `.n.hot` rule carries both the attention hue (above) and
    /// `font-weight: 600` — the weight is part of the same badge treatment,
    /// not a second decision, so it follows `indexCountInk`'s own test
    /// rather than adding a new one.
    nonisolated static func indexCountWeight(id: String) -> Font.Weight {
        id == correctionsQueuePanelID ? .semibold : .regular
    }

    /// Which panel is "here" — the top-most panel whose measured frame
    /// intersects the viewport, in `order`. `nil` before any frame has been
    /// measured, the same honest "haven't measured it" answer
    /// `offScreenPanelIDs` used to give the old rail — no entry underlines
    /// rather than one underlining a guess.
    ///
    /// A collapsed panel's shrunken frame can still be "here": collapsing
    /// is not scrolling away from it, and the index says as much by
    /// striking the title rather than by refusing to name it current.
    ///
    /// A PURE FUNCTION over already-measured geometry, the same discipline
    /// `coursePartition` and `rowTreatment` already follow — testable
    /// without a view, which matters here because ContentView-level view
    /// wiring is not reachable from XCTest in this repo (convivy-deck#153).
    nonisolated static func topmostVisiblePanelID(
        order: [String],
        frames: [String: CGRect],
        viewportHeight: CGFloat
    ) -> String? {
        order
            .compactMap { id in frames[id].map { (id: id, frame: $0) } }
            .filter { $0.frame.maxY > 0 && $0.frame.minY < viewportHeight }
            .min { $0.frame.minY < $1.frame.minY }
            .map(\.id)
    }

    /// The number an index entry carries, or `nil` when the panel has
    /// nothing counted yet — no course loaded, no queue reading, a mini
    /// that predates `agent_runs` (the same three-state tri-state
    /// `agentRuns` documents at its declaration), or a Proposals panel
    /// with no project resolved (`proposalCount` is `nil` there for the
    /// same reason `courseEntries` is). `nil` means "no measurement";
    /// `panelIndexEntry` is what turns that into the "—" glyph on screen
    /// rather than a misleading zero.
    ///
    /// **Course counts settled epics over the total** — `.done` or
    /// `.closedNotDone` by `rowTreatment`, the same vocabulary
    /// `courseEntryRow` draws, so the index can never disagree with the
    /// panel about which epics are behind the reader.
    ///
    /// **Pull Requests counts ready-to-merge over the total**, the same
    /// "settled/total" shape Course uses just above, and for the same
    /// reason: a bare ready count reads as "how many PRs exist" when it is
    /// actually "how many need a decision", and the two agree only by
    /// coincidence. `nil` when the total is `0` too — a loaded, genuinely
    /// empty panel draws no count, the same choice Course makes for a
    /// loaded, empty Course just below.
    nonisolated static func panelIndexCount(
        id: String,
        agentRuns: [SessionState.AgentRun]?,
        proposalCount: Int?,
        courseEntries: [LibraryClient.CourseEntry]?,
        queueTotal: Int?,
        documentCount: Int? = nil,
        checkoutDocumentCount: Int? = nil,
        pullRequestCount: Int? = nil,
        pullRequestTotalCount: Int? = nil
    ) -> String? {
        switch id {
        case checkoutPanelID:
            return checkoutDocumentCount.map { "\($0)" }
        case documentsPanelID:
            return documentCount.map { "\($0)" }
        case pullRequestsPanelID:
            guard let pullRequestCount, let pullRequestTotalCount, pullRequestTotalCount > 0 else {
                return nil
            }
            return "\(pullRequestCount)/\(pullRequestTotalCount)"
        case dispatchedPanelID:
            return agentRuns.map { "\($0.count)" }
        case proposalsPanelID:
            return proposalCount.map { "\($0)" }
        case coursePanelID:
            guard let courseEntries, !courseEntries.isEmpty else { return nil }
            let settled = courseEntries.filter {
                let treatment = rowTreatment(state: $0.state, resolution: $0.resolution)
                return treatment == .done || treatment == .closedNotDone
            }.count
            return "\(settled)/\(courseEntries.count)"
        case correctionsQueuePanelID:
            return queueTotal.map { "\($0)" }
        default:
            return nil
        }
    }

    /// VoiceOver's label for one index entry — the title, its count if any,
    /// then the same "activate to scroll" instruction every other
    /// scroll-to-panel control in this file gives. A `nil` count draws as
    /// the "—" glyph on screen, but VoiceOver says "no count" rather than
    /// announcing a punctuation mark.
    nonisolated static func panelIndexAccessibilityLabel(title: String, count: String?) -> String {
        let named = count.map { "\(title), \($0)" } ?? "\(title), no count"
        return "\(named). Activate to scroll to it."
    }

    /// The band is neutral: the Cockpit is the laptop's view of a crew, not
    /// a session's, so it takes no crew colour. The panel index sits under it
    /// and stays on screen while the panels scroll.
    private func header(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnBand(title: title, icon: "square.grid.2x2.fill", place: placeLine,
                       colours: .neutral(appearance, ground: statusGround)) {
                if model.isLoading {
                    ProgressView().controlSize(.mini)
                }
                // The manual escape hatch for the slow timer
                // (`CockpitModel.refreshInterval`, 600s) and for `toggleExpansion`'s
                // cache, neither of which an operator can otherwise force —
                // issue_01M1HVTD8QXXZF9ADZGRWRFEYW: an epic closed and two items
                // filed through the ops plane stayed invisible with no recourse
                // but switching crews and back. Cmd-R is unclaimed elsewhere in
                // Sources/Deck (checked before picking it) and is the platform's
                // own refresh convention.
                Button {
                    onRefresh?()
                    Task { await model.manualRefresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isLoading)
                .help("Refresh the cockpit")
            }
            panelIndex(scrollProxy: scrollProxy)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            Divider()
        }
    }

    private func unresolvedState(_ reason: String) -> some View {
        Text(reason)
            .frameFont(.label)
            .foregroundStyle(secondaryInk)
    }

    // MARK: - Proposals
    //
    // ITS OWN REGION, NOT PART OF THE COURSE. A proposal is an epic whose
    // `maturity` is `proposed`: nobody has agreed it should happen yet, and
    // rendering it inline among Course entries would make an untouched epic
    // and a merely-proposed one look the same. The tinted background on each
    // row (`proposalRow`) is a secondary cue; the placement above the Course,
    // in its own titled block, is the primary one.
    //
    // ONE PRIMARY CONTROL, AND NO DECLINE. Approve writes `maturity: approved`
    // and the row leaves on the refetch, with nothing to confirm. A proposed
    // epic appears nowhere else in Deck (the Course carries approved epics and
    // the corrections queue drops epics), so the row also carries the same
    // `Open` control its neighbours have, and an operator who wants the text
    // opens the epic in the Item pane. The text is never rendered in this
    // region.

    /// The id the row's `Open` control hands to `onSelectCorrection`. It is
    /// the epic's own id, the same one `CockpitModel.approve` writes, so a row
    /// cannot open one epic and approve another.
    static func proposalOpenTarget(_ epic: LibraryClient.Epic) -> String { epic.id }

    @ViewBuilder
    private var proposalsContent: some View {
        // Checked FIRST, the same priority `courseUnresolvedReason` takes in
        // `coursePanel`: with no project resolved, `model.proposedEpics` has
        // been cleared to `[]`, and this reason is the only honest thing the
        // panel can say.
        if let proposalsUnresolvedReason {
            Text(proposalsUnresolvedReason)
                .frameFont(.label).foregroundStyle(secondaryInk)
        } else if let proposedEpicsError = model.proposedEpicsError {
            unreachableLine("Could not reach proposals", detail: proposedEpicsError)
        } else if model.proposedEpics.isEmpty {
            Text("No epics awaiting approval.")
                .frameFont(.label).foregroundStyle(secondaryInk)
        } else {
            ForEach(model.proposedEpics) { epic in
                proposalRow(epic)
            }
        }
    }

    private func proposalRow(_ epic: LibraryClient.Epic) -> some View {
        let title = (epic.title ?? "").isEmpty ? "(untitled epic)" : epic.title ?? ""
        let showsOpen = hoveredProposalEpicID == epic.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(title)
                    .frameFont(.label)
                    .fontWeight(.medium)
                Spacer(minLength: 0)
                // Reserved rather than conditional, as on the Course and queue
                // rows (see `ItemOpenButton`); it is beside the title so that
                // Approve stays the one prominent control.
                ItemOpenButton(isRevealed: showsOpen) {
                    onSelectCorrection(CockpitView.proposalOpenTarget(epic))
                }
            }
            HStack(spacing: 8) {
                Button("Approve") {
                    Task { await model.approve(epic) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.approvingEpicID != nil)
                .accessibilityLabel("Approve \(title)")
                if model.approvingEpicID == epic.id { ProgressView().controlSize(.mini) }
            }
            if let refusal = model.approvalRefusal, refusal.epicID == epic.id {
                Text(refusal.message)
                    .frameFont(.label)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
        .onHover { isHovering in
            if isHovering {
                hoveredProposalEpicID = epic.id
            } else if hoveredProposalEpicID == epic.id {
                hoveredProposalEpicID = nil
            }
        }
        .contextMenu {
            Button(ItemOpenButton.menuTitle) {
                onSelectCorrection(CockpitView.proposalOpenTarget(epic))
            }
        }
    }

    // MARK: - Course

    @ViewBuilder
    private var coursePanel: some View {
        Group {
            // Checked FIRST: with no project resolved, `model` has been
            // cleared (`CockpitModel.refresh`), and this reason is the only
            // honest thing the panel can say.
            if let courseUnresolvedReason {
                Text(courseUnresolvedReason)
                    .frameFont(.label).foregroundStyle(secondaryInk)
            } else if let courseError = model.courseError {
                unreachableLine("Could not reach the Course", detail: courseError)
            } else if let course = model.course {
                if course.entries.isEmpty {
                    Text("Nothing on the Course yet.")
                        .frameFont(.label).foregroundStyle(secondaryInk)
                } else {
                    courseEntryList(course.entries)
                }
                // The same words-in-red shape the proposals row uses for a
                // refused Approve. Shown beside the rows it concerns, so a
                // move that did not land never passes without a word.
                if let refusal = model.courseReorderRefusal {
                    Text(refusal)
                        .frameFont(.label)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !model.isLoading {
                Text("No Course found for this project.")
                    .frameFont(.label).foregroundStyle(secondaryInk)
            }
        }
    }

    /// The Course's rows, with `coursePartition`'s two collapses applied —
    /// a leading run of closed epics behind an up-arrow affordance, a
    /// trailing run of unstarted epics behind a count. Each hidden run
    /// expands in place, independently, into the same row rendering the
    /// always-visible middle uses.
    @ViewBuilder
    private func courseEntryList(_ entries: [LibraryClient.CourseEntry]) -> some View {
        let partition = CockpitView.coursePartition(entries)
        if !partition.hiddenHead.isEmpty {
            if isCourseHeadExpanded {
                ForEach(partition.hiddenHead, id: \.id) { entry in courseEntryBlock(entry) }
            } else {
                courseCollapseAffordance(
                    count: partition.hiddenHead.count,
                    label: "\(partition.hiddenHead.count) more closed epics",
                    accessibilityLabel: "\(partition.hiddenHead.count) more closed epics hidden. "
                        + "Activate to show them.",
                    systemImage: "chevron.up"
                ) { isCourseHeadExpanded = true }
            }
        }
        ForEach(partition.visible, id: \.id) { entry in courseEntryBlock(entry) }
        if !partition.hiddenTail.isEmpty {
            if isCourseTailExpanded {
                ForEach(partition.hiddenTail, id: \.id) { entry in courseEntryBlock(entry) }
            } else {
                courseCollapseAffordance(
                    count: partition.hiddenTail.count,
                    label: "\(partition.hiddenTail.count) more",
                    accessibilityLabel: "\(partition.hiddenTail.count) more upcoming epics hidden. "
                        + "Activate to show them.",
                    systemImage: "chevron.down"
                ) { isCourseTailExpanded = true }
            }
        }
    }

    private func courseEntryBlock(_ entry: LibraryClient.CourseEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            courseEntryRow(entry)
                .overlay(alignment: courseDropEdge(for: entry) == .above ? .top : .bottom) {
                    if courseDropEdge(for: entry) != nil {
                        Capsule()
                            .fill(dropLineInk)
                            .frame(height: 2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .draggable(startCourseDrag(entry)) {
                    Text(entry.title).frameFont(.body).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                }
                .dropDestination(for: CourseEntryDrag.self) { items, _ in
                    draggedCourseEntryID = nil
                    courseDropTargetID = nil
                    guard let dropped = items.first else { return false }
                    Task { await model.moveCourseEntry(dropped.courseEntryID, onto: entry.id) }
                    return true
                } isTargeted: { isTargeted in
                    if isTargeted {
                        courseDropTargetID = entry.id
                    } else if courseDropTargetID == entry.id {
                        courseDropTargetID = nil
                    }
                }
            if model.expandedEntries.contains(entry.id) {
                epicDetail(entry)
            }
        }
    }

    /// Runs when a drag begins (SwiftUI evaluates a `draggable` payload then),
    /// which is the one moment the dragged row is known.
    private func startCourseDrag(_ entry: LibraryClient.CourseEntry) -> CourseEntryDrag {
        draggedCourseEntryID = entry.id
        return CourseEntryDrag(courseEntryID: entry.id)
    }

    /// The edge of this row the landing line is drawn on, or `nil` when the
    /// pointer is not over it with a drag in flight. Nothing draws while a
    /// write is out, because `moveCourseEntry` would ignore a drop then.
    private func courseDropEdge(for entry: LibraryClient.CourseEntry) -> CourseDropEdge? {
        guard !model.isReorderingCourse,
              courseDropTargetID == entry.id, let dragged = draggedCourseEntryID,
              let course = model.course else { return nil }
        return CockpitView.courseDropEdge(
            entryIDs: course.entries.map(\.id), dragging: dragged, over: entry.id)
    }

    /// The crew's own mark ink, contrast-checked against the panel surface by
    /// `ThemeRecipe`, which is the ink an in-progress row's glyph draws in.
    private var dropLineInk: AnyShapeStyle {
        guard let mark = ThemeRecipe.progressMarkInk(accent: resolvedAccent, on: indexSurface) else {
            return AnyShapeStyle(.primary)
        }
        return AnyShapeStyle(Color(mark))
    }

    /// Which edge of `over` a dragged row lands on. The rule is
    /// `LibraryClient.reorderedEntryIds`': dragged from above, it lands after
    /// the row it is dropped on, so the line is drawn below; dragged from
    /// below, above. `nil` for a drop on itself or on a row not in the list,
    /// where nothing would move and no line should promise it.
    ///
    /// Compared over the rendered rows, which keep the served order among
    /// themselves, so it agrees with the write built over the served array.
    nonisolated static func courseDropEdge(
        entryIDs: [String], dragging: String, over target: String
    ) -> CourseDropEdge? {
        guard dragging != target,
              let from = entryIDs.firstIndex(of: dragging),
              let to = entryIDs.firstIndex(of: target) else { return nil }
        return from < to ? .below : .above
    }

    private func courseCollapseAffordance(
        count: Int, label: String, accessibilityLabel: String, systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 8))
                Text(label).frameFont(.label)
            }
            .foregroundStyle(secondaryInk)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// A completed entry draws passed rather than ahead — struck through,
    /// dimmed, a filled check — so the route reads differently once you can
    /// see what was just passed (`deck/bead/deck` §1). Clicking any row
    /// (completed or not — a reader looking at what was just passed wants
    /// the same detail as one still ahead) toggles its expansion.
    private func courseEntryRow(_ entry: LibraryClient.CourseEntry) -> some View {
        let treatment = CockpitView.rowTreatment(state: entry.state, resolution: entry.resolution)
        let progress = CockpitView.childProgress(model.childrenByEntry[entry.id])
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: treatment.glyphName)
                .frameFont(.icon)
                .foregroundStyle(glyphInk(treatment))
                .frame(width: 14, alignment: .center)
            Text(entry.title)
                .frameFont(.body)
                .strikethrough(treatment.strikethrough)
                .foregroundStyle(CockpitView.titleInk(treatment, ground: statusGround))
                .lineLimit(2)
                // The clamp's escape hatch, the same one `clampedCaption`
                // gives the lines inside the expansion and `childItemRow`
                // gives a child's title. This row was left out of PR #171
                // because it was not part of that diff, and the operator found the
                // gap by hovering a long epic title and getting nothing.
                .help(CockpitView.libraryTooltip(entry.title))
            Spacer(minLength: 0)
            if let progress {
                Text("\(progress.done)/\(progress.total)")
                    .frameFont(.caption)
                    .foregroundStyle(secondaryInk)
                    .monospacedDigit()
                    .fixedSize()
            }
            // Drawn from the Library's own computed `blocked` field ONLY —
            // never recomputed here from `entry.prerequisites` — so Deck and
            // the Library's claimable query cannot disagree (ADR-0074).
            if entry.blocked {
                Image(systemName: "lock.fill")
                    .frameFont(.icon)
                    .foregroundStyle(Color(ThemeRecipe.attentionTextInk(on: indexSurface)))
                    .help("Blocked — waiting on its prerequisites")
                    .accessibilityLabel("blocked")
            }
            // **RESERVED, NOT CONDITIONAL** (the operator, 2026-09-04, in the running
            // app): "when the copy icon appears, it causes multi-line rows to
            // re-render and shift because it takes up space that was text."
            //
            // The first version borrowed `RailChildRow`'s conditional
            // inclusion and claimed the `Spacer` absorbed the width. **THE
            // PRECEDENT DOES NOT TRANSFER, AND THE REASON IS THE LINE LIMIT.**
            // `RailChildRow` draws its title at `.lineLimit(1)`, which cannot
            // reflow — the row is one line whatever the width. This title
            // clamps to TWO lines and wraps, so once the `Spacer` is at zero
            // on a long title, the icon's width comes out of the text and the
            // wrap point moves as the pointer arrives. `deck-reviewer` called
            // this on PR #170 as reasoned-not-observed; it was right.
            //
            // The button is therefore always laid out and only its VISIBILITY
            // changes, so both states lay out identically by construction
            // rather than by a width constant that could drift from the icon's
            // own `.frameFont(.icon)` metrics. Hit testing and the
            // accessibility tree follow the opacity, so an invisible control
            // is neither clickable nor announced — the properties conditional
            // inclusion gave for free.
            //
            // In its own `Button` so its click doesn't fall through to the
            // row's `.onTapGesture` — a `Button`'s own label is also exempt
            // from the container's inherited `.textSelection`, same as the
            // chevron and header buttons.
            let showsCopy = hoveredCourseEntryID == entry.id
            // The epic row's tap is spent on expansion, the more frequent
            // action, so this is the only route from an epic to its own
            // record. Reserved and revealed exactly as the copy icon below.
            ItemOpenButton(isRevealed: showsCopy) { onSelectCorrection(entry.id) }
            Button {
                CockpitView.copyTitleToPasteboard(entry.title)
            } label: {
                Image(systemName: "doc.on.doc")
                    .frameFont(.icon)
                    .foregroundStyle(secondaryInk)
            }
            .buttonStyle(.plain)
            .help("Copy title")
            .opacity(showsCopy ? 1 : 0)
            .allowsHitTesting(showsCopy)
            .accessibilityHidden(!showsCopy)
            Image(systemName: model.expandedEntries.contains(entry.id) ? "chevron.down" : "chevron.right")
                .frameFont(.icon)
                .foregroundStyle(tertiaryInk)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggleExpansion(for: entry.id) }
        .onHover { isHovering in
            if isHovering {
                hoveredCourseEntryID = entry.id
            } else if hoveredCourseEntryID == entry.id {
                hoveredCourseEntryID = nil
            }
        }
        // Opts out of the container-level `.textSelection(.enabled)` — see
        // that modifier's comment. The title is the obvious click target,
        // so it must take the tap; Copy title below is how it stays
        // reachable for copying.
        .textSelection(.disabled)
        .contextMenu {
            Button(ItemOpenButton.menuTitle) { onSelectCorrection(entry.id) }
            Button("Copy title") {
                CockpitView.copyTitleToPasteboard(entry.title)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CockpitView.accessibilityLabel(
            title: entry.title, treatment: treatment,
            progress: progress.map { (done: $0.done, total: $0.total) },
            blocked: entry.blocked))
    }

    /// The one write both the hover icon and the context-menu item make —
    /// shared so the two "Copy title" paths cannot drift.
    static func copyTitleToPasteboard(_ title: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
    }

    /// Which of the five visual treatments a row draws — **the organizing
    /// idea of this pass**: three ink levels carry the state (secondary, the
    /// crew's own hue, the attention ink), glyph SHAPE carries identity, so
    /// nothing rests on colour alone. Pulled out as a pure enum + function,
    /// the testable core the state table maps onto, the same discipline
    /// `childProgress` and `showsTypeChips` already follow.
    enum RowTreatment: Equatable {
        /// `open` — accent used to mean "not finished", which was most of
        /// every list, so it meant nothing. Secondary glyph, primary title.
        case ahead
        /// Non-open, non-terminal — includes `pr-open`, whose own honesty
        /// lives in `.help` rather than a distinct glyph.
        case inProgress
        /// `fixed`.
        case done
        /// `wontfix`/`duplicate`/`redirected` — deliberately ONE mark: at a
        /// glance the question is "is this still ahead of me", and all
        /// three answer no.
        case closedNotDone

        var glyphName: String {
            switch self {
            case .ahead: return "circle"
            case .inProgress: return "circle.lefthalf.filled"
            case .done: return "checkmark.circle.fill"
            case .closedNotDone: return "minus.circle.fill"
            }
        }

        var strikethrough: Bool {
            switch self {
            case .done, .closedNotDone: return true
            default: return false
            }
        }

        /// The word VoiceOver leads each row with — strikethrough and glyph
        /// fill are both invisible to it.
        var accessibilityPrefix: String {
            switch self {
            case .ahead: return "ahead"
            case .inProgress: return "in progress"
            case .done: return "done"
            case .closedNotDone: return "closed without change"
            }
        }
    }

    /// The state table, as a pure function of `state` and `resolution` —
    /// shared by an epic's own row (`CourseEntry`) and a child row
    /// (`ChildItem`, whose `resolution` is always `nil`; `state` alone
    /// decides it, the same asymmetry `ChildItem.isCompleted` already
    /// documents).
    nonisolated static func rowTreatment(state: String?, resolution: String?) -> RowTreatment {
        let terminal = resolution ?? (LibraryClient.terminalWorkStates.contains(state ?? "") ? state : nil)
        if let terminal {
            return terminal == "fixed" ? .done : .closedNotDone
        }
        return (state == nil || state == "open") ? .ahead : .inProgress
    }

    /// The three runs `coursePanel` draws: a leading run of closed epics
    /// collapsed behind an up-arrow affordance, a trailing run of unstarted
    /// epics collapsed behind a count, and everything in between shown
    /// plainly. Both are contiguous slices of `entries` in the original
    /// order, so `hiddenHead + visible + hiddenTail` reconstructs `entries`
    /// exactly.
    struct CoursePartition: Equatable {
        let hiddenHead: [LibraryClient.CourseEntry]
        let visible: [LibraryClient.CourseEntry]
        let hiddenTail: [LibraryClient.CourseEntry]
    }

    /// Two independent collapse rules over `rowTreatment`'s own vocabulary,
    /// each anchored to one end of the Course and each stopping the moment
    /// it meets a treatment the rule does not cover — a run, not a filter,
    /// so an unstarted epic beyond an in-progress one never collapses
    /// alongside the trailing run just because it shares a treatment with
    /// it.
    ///
    /// **Head** — `.done`/`.closedNotDone` only, kept to 2 once the leading
    /// run exceeds that. **Tail** — `.ahead` only, kept to 2 once the
    /// trailing run exceeds that. `.inProgress` never collapses at either
    /// end (the spec's "MUST STAY" column) — it simply ends whichever run
    /// it interrupts.
    ///
    /// The two runs cannot overlap: a head run is entirely
    /// `.done`/`.closedNotDone` entries and a tail run is entirely `.ahead`
    /// entries, and no entry carries both treatments at once, so whenever
    /// both runs are non-empty the head run necessarily ends at or before
    /// the tail run begins.
    ///
    /// A PURE FUNCTION over already-decoded entries, the same discipline
    /// `rowTreatment` and `childProgress` already follow — testable without
    /// a view, and what `courseEntryList` renders is exactly this partition.
    nonisolated static func coursePartition(
        _ entries: [LibraryClient.CourseEntry]
    ) -> CoursePartition {
        let treatments = entries.map { rowTreatment(state: $0.state, resolution: $0.resolution) }

        var headRunEnd = 0
        while headRunEnd < treatments.count,
              treatments[headRunEnd] == .done || treatments[headRunEnd] == .closedNotDone {
            headRunEnd += 1
        }
        let hiddenHeadCount = headRunEnd > 2 ? headRunEnd - 2 : 0

        var tailRunStart = treatments.count
        while tailRunStart > 0, treatments[tailRunStart - 1] == .ahead {
            tailRunStart -= 1
        }
        let tailRunLength = treatments.count - tailRunStart
        let hiddenTailCount = tailRunLength > 2 ? tailRunLength - 2 : 0
        let hiddenTailStart = treatments.count - hiddenTailCount

        return CoursePartition(
            hiddenHead: Array(entries[0..<hiddenHeadCount]),
            visible: Array(entries[hiddenHeadCount..<hiddenTailStart]),
            hiddenTail: Array(entries[hiddenTailStart...])
        )
    }

    /// Not `static`, unlike its neighbours here — it needs `resolvedAccent`
    /// and `indexSurface`, which is exactly `indexCountInk`'s own reason for
    /// being an instance method. The state table it draws from stays the
    /// pure static `rowTreatment`.
    private func glyphInk(_ treatment: RowTreatment) -> AnyShapeStyle {
        CockpitView.glyphInk(treatment: treatment, accent: resolvedAccent, appearance: appearance,
                                  ground: statusGround)
    }

    /// `glyphInk(_:)`'s own logic, `static` and given the accent and
    /// appearance explicitly rather than read off `self` — the shape
    /// `ServiceCrewPanel`'s Dispatched panel calls this through, so a
    /// service crew's in-progress glyph is provably the same colour
    /// computation as the project cockpit's, not a second implementation
    /// that could drift from it.
    nonisolated static func glyphInk(
        treatment: RowTreatment, accent: RGB, appearance: Appearance, ground: RGB? = nil
    ) -> AnyShapeStyle {
        let surface = resolvedIndexSurface(appearance: appearance, ground: ground)
        switch treatment {
        case .ahead, .done, .closedNotDone: return secondaryInkStyle(on: ground)
        case .inProgress:
            guard let mark = ThemeRecipe.progressMarkInk(accent: accent, on: surface) else {
                return AnyShapeStyle(.primary)
            }
            return AnyShapeStyle(Color(mark))
        }
    }

    /// The secondary text ink on the cockpit's ground: the system's secondary
    /// style with no ground, and the Deck-solved ink under Builder Default.
    /// Every secondary text and icon in the cockpit draws through this.
    static func secondaryInkStyle(on ground: RGB?) -> AnyShapeStyle {
        guard let ground else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(Color(ThemeRecipe.secondaryTextInk(on: ground)))
    }

    /// The tertiary ink for the disclosure chevrons: the non-text mark floor,
    /// solved against the same ground as `secondaryInkStyle(on:)`.
    static func tertiaryInkStyle(on ground: RGB?) -> AnyShapeStyle {
        guard let ground else { return AnyShapeStyle(.tertiary) }
        return AnyShapeStyle(Color(ThemeRecipe.neutralMarkInk(on: ground)))
    }

    /// The opacity of the child-row highlight: `Color.accentColor` at this alpha
    /// under a highlighted child row's contents. The chip's ink solves against it.
    static let childRowHighlightOpacity = 0.08

    /// The type chip's text ink. The chip draws its text on its `.quaternary`
    /// fill, and the fill sits on whatever is beneath it: the ground, or the
    /// highlight wash when the chip is in a highlighted child row. Under Builder
    /// Default the ink solves against the fill composited over that surface.
    /// Nil ground keeps the system secondary style.
    static func typeChipInkStyle(on ground: RGB?, highlighted: Bool) -> AnyShapeStyle {
        guard let ground else { return AnyShapeStyle(.secondary) }
        let beneath = highlighted ? highlightWashComposite(over: ground) : ground
        return AnyShapeStyle(Color(ThemeRecipe.secondaryTextInk(on: quaternaryComposite(over: beneath))))
    }

    /// The system's `.quaternary` fill composited over `ground`. The chip's fill
    /// is an alpha wash, so the surface its text sits on depends on what is beneath.
    static func quaternaryComposite(over ground: RGB) -> RGB {
        compositeFill(NSColor.quaternaryLabelColor, opacity: 1, over: ground)
    }

    /// The child-row highlight wash composited over `ground`: `Color.accentColor`
    /// at `childRowHighlightOpacity`.
    static func highlightWashComposite(over ground: RGB) -> RGB {
        compositeFill(NSColor.controlAccentColor, opacity: childRowHighlightOpacity, over: ground)
    }

    /// `fill`, scaled by `opacity` on top of its own alpha, composited over
    /// `ground` in the Aqua appearance the cockpit draws in.
    private static func compositeFill(_ fill: NSColor, opacity: Double, over ground: RGB) -> RGB {
        var composite = ground
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            guard let fill = fill.usingColorSpace(.sRGB) else { return }
            let alpha = Double(fill.alphaComponent) * opacity
            composite = RGB(red: Double(fill.redComponent) * alpha + ground.red * (1 - alpha),
                            green: Double(fill.greenComponent) * alpha + ground.green * (1 - alpha),
                            blue: Double(fill.blueComponent) * alpha + ground.blue * (1 - alpha))
        }
        return composite
    }

    private static func titleInk(_ treatment: RowTreatment, ground: RGB?) -> AnyShapeStyle {
        switch treatment {
        case .done, .closedNotDone: return secondaryInkStyle(on: ground)
        case .ahead, .inProgress: return AnyShapeStyle(.primary)
        }
    }

    /// The full VoiceOver label for a row — state prefix, title, and (an
    /// epic row only) the progress count, composed into one coherent
    /// sentence rather than left for VoiceOver to stitch together from
    /// separate elements. Pure and testable, the same reason `rowTreatment`
    /// is pulled out rather than inlined.
    nonisolated static func accessibilityLabel(
        title: String, treatment: RowTreatment,
        progress: (done: Int, total: Int)? = nil, blocked: Bool = false
    ) -> String {
        let prefix = treatment.accessibilityPrefix
        var label = "\(prefix), \(title)"
        if let progress {
            label += ", \(progress.done) of \(progress.total) settled"
        }
        if blocked {
            label += ", blocked"
        }
        return label
    }

    /// How far an epic's children have gotten, read off whatever
    /// `childrenByEntry` already holds rather than a fetch of its own — an
    /// unexpanded row's children were never asked for, and this must not be
    /// the thing that asks (`deck-coder`'s brief: "do not fetch children
    /// eagerly to populate it"). Mirrors `visibleQueueItems`'s discipline of
    /// slicing what is already in hand instead of reaching for more.
    ///
    /// `nil` for "never fetched", "still loading", "failed", and "fetched but
    /// empty" alike — none of those are a count worth drawing on the
    /// collapsed row, and the epic already says as much once expanded.
    ///
    /// A PURE FUNCTION, so the derivation is testable without a view — the
    /// same discipline `RailRow.summonsInk` follows for its own testable
    /// decision.
    nonisolated static func childProgress(
        _ state: CockpitModel.ChildrenState?
    ) -> (done: Int, total: Int)? {
        guard case .loaded(let items) = state, !items.isEmpty else { return nil }
        return (items.filter(\.isCompleted).count, items.count)
    }

    /// Whether an epic's children draw a type chip at all — **all rows or
    /// none**, decided once per epic rather than per row. Every item filed
    /// under today's epics happens to be `task`, so a chip on every row drew
    /// the same word column-down: the most salient mark on the block and the
    /// least informative. Suppressing per row instead would leave a chip-less
    /// row ambiguous between "no type" and "the default type", and the
    /// dominant type can shift mid-load, so a row's chip would flicker
    /// between snapshots. Deciding for the whole visible group avoids both.
    nonisolated static func showsTypeChips(_ items: [LibraryClient.ChildItem]) -> Bool {
        Set(items.compactMap { $0.type?.lowercased() }).count > 1
    }

    /// An expanded entry's own detail — the same `GET /courses/{id}` call
    /// already resolved, not a second request — followed by its child work
    /// items, which are (`childItemsSection`).
    ///
    /// **A hairline spine, not a bare indent.** At the rail's 280px width a
    /// leading `.padding` alone reads as noise rather than nesting — the
    /// child block sits close enough to the epic row's own leading edge that
    /// the eye has nothing to anchor the hierarchy to, especially once a
    /// title wraps to two lines. The rule is what a pure indent stops doing
    /// once that happens: it runs the block's full height, so the eye can
    /// follow it down past a wrap rather than losing the thread.
    private func epicDetail(_ entry: LibraryClient.CourseEntry) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 4) {
                epicInterior(entry)
                epicFields(entry)
                childItemsSection(entry)
                    .padding(.top, 4)
            }
            .padding(.leading, 10)
        }
    }

    private func epicInterior(_ entry: LibraryClient.CourseEntry) -> some View {
        HStack(spacing: 4) {
            Text(entry.state?.capitalized ?? "Open")
            if let type = entry.type { Text("· \(type)") }
            // The reverse of the PR row's own chip (issue_01M2P5D0D4EQEQX7BSRNFT5QGJ):
            // before this, `pr-open` said only that — a reader had to leave
            // the Course to learn which pull request. Shown for `pr-open`
            // specifically, the one state this entry's own doc already
            // calls out as needing the honesty `.help` gives it elsewhere.
            if entry.state == "pr-open", let number = entry.prNumber {
                Text("· PR #\(number)")
            }
        }
        // `.body`, matching `epicFields` below it — the spec draws `.state`,
        // `.cap` and `.meta` at the same tier, and PR #187 moved `epicFields`
        // there without this line, leaving a visible seam inside one block.
        .frameFont(.body)
        .foregroundStyle(secondaryInk)
    }

    /// The entry's own fields the Course response already carried —
    /// `definition_of_done`, `prerequisites`, `severity`, `claimed_by` —
    /// each degrading independently: a field this entry's JSON did not
    /// carry just does not draw a line, same discipline as every other
    /// decode in `LibraryClient`.
    ///
    /// **`specification` is no longer DRAWN here.** Three clamped lines of a
    /// ~300-word document was the tallest element in the expansion and
    /// answered no glance question — a specification is authored to be read
    /// whole, and the clamp made it smaller without making it scannable.
    /// `definitionOfDone` stays at 2 lines: that one IS the glance-sized
    /// fact about an epic.
    ///
    /// **`CourseEntry.specification` is still decoded**, and deliberately so —
    /// an earlier version of this comment said the field was "cut entirely",
    /// which was false and would have sent the next reader looking for a
    /// decode that is right there (`LibraryClient.swift`, the `specification`
    /// parameter and its `decodeCourse` line). Nothing in `Sources/` reads it
    /// today. It stays because removing it and putting it back are not the
    /// same size of change: drawing the specification again is one line here,
    /// while re-adding the field, its initializer parameter, its decode and
    /// its tests is four edits across two files (`LibraryClient.swift` holds
    /// the first three, `LibraryClientTests.swift` the fourth). The decode
    /// costs one optional cast per entry.
    @ViewBuilder
    private func epicFields(_ entry: LibraryClient.CourseEntry) -> some View {
        if let definitionOfDone = entry.definitionOfDone, !definitionOfDone.isEmpty {
            clampedCaption(
                Text("Done when: ").fontWeight(.semibold) + Text(definitionOfDone),
                full: "Done when: \(definitionOfDone)", role: .body)
        }
        if let needsFirst = CockpitView.needsFirstText(entry.prerequisites) {
            clampedCaption(
                Text("Needs first: ").fontWeight(.semibold) + needsFirst,
                full: "Needs first: \(CockpitView.needsFirstPlainText(entry.prerequisites))", role: .body)
        }
        if entry.severity != nil || entry.claimedBy != nil {
            HStack(spacing: 8) {
                if let severity = entry.severity { Text("Severity: \(severity)") }
                if let claimedBy = entry.claimedBy {
                    Text(LibraryClient.claimStatusLine(claimedBy: claimedBy, expired: entry.claimExpired))
                }
            }
            .frameFont(.body)
            .foregroundStyle(secondaryInk)
        }
    }

    /// The word this file draws for a prerequisite entry the reader cannot
    /// see — `{item, missing: true}`
    /// (`platform/decisions/0074-a-work-item-names-its-prerequisites-and-a-blocked-item-is-not-claimable`).
    /// Comment 2261 on `issue_01M27E11MEH73Y66K7EEKPMAHN` calls this "a
    /// blocker that can't be opened", so it draws as fixed text rather than
    /// a link — this file has nothing to open it with.
    static let missingPrerequisiteLabel = "an item you can't see"

    /// One prerequisite entry, rendered for the "Needs first:" caption — a
    /// readable item shows its title with its served state alongside
    /// (`"Design review signed off (open)"`) and strikes through once that
    /// state is terminal (the same `LibraryClient.terminalWorkStates`
    /// `rowTreatment` reads), a missing item draws the fixed label above,
    /// and a text entry strikes through once `met`. Pure, so
    /// `needsFirstText`'s join is testable without a view.
    nonisolated static func prerequisiteFragment(_ entry: LibraryClient.PrerequisiteEntry) -> Text {
        switch entry {
        case .item(_, let title, let state):
            let text = Text(state.map { "\(title) (\($0))" } ?? title)
            return LibraryClient.terminalWorkStates.contains(state ?? "") ? text.strikethrough() : text
        case .missingItem:
            return Text(missingPrerequisiteLabel)
        case .text(let text, let met, _, _):
            let rendered = Text(text)
            return met ? rendered.strikethrough() : rendered
        }
    }

    /// The "Needs first:" caption's body — every entry's fragment,
    /// comma-joined — or `nil` for an empty list, so a caller can skip
    /// drawing the line entirely rather than drawing an empty one.
    nonisolated static func needsFirstText(_ entries: [LibraryClient.PrerequisiteEntry]) -> Text? {
        guard let first = entries.first else { return nil }
        return entries.dropFirst().reduce(prerequisiteFragment(first)) { joined, entry in
            joined + Text(", ") + prerequisiteFragment(entry)
        }
    }

    /// The plain-string form of the same list, for `clampedCaption`'s
    /// `full` parameter — the tooltip and the "more" expansion both read a
    /// plain string, not the rich `Text` `needsFirstText` builds, which
    /// cannot be measured or bounded. A readable item carries its served
    /// state alongside its title, matching `prerequisiteFragment`. A text
    /// entry appends who judged it and when, since comment 2261 puts
    /// `judged_by`/`judged_at` in the tooltip and nowhere else. `judged_at`
    /// draws in the reader's own zone through `ServedTimestamp`, `now`
    /// defaulting fresh per call since this feeds a view body with no clock
    /// of its own to pass in (`LibraryClient.approvalRefusalMessage`'s
    /// pattern).
    nonisolated static func needsFirstPlainText(
        _ entries: [LibraryClient.PrerequisiteEntry],
        now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        entries.map { entry -> String in
            switch entry {
            case .item(_, let title, let state):
                return state.map { "\(title) (\($0))" } ?? title
            case .missingItem:
                return missingPrerequisiteLabel
            case .text(let text, let met, let judgedBy, let judgedAt):
                var meta: [String] = []
                if met { meta.append("met") }
                if let judgedBy, !judgedBy.isEmpty { meta.append("judged by \(judgedBy)") }
                if let judgedAt, !judgedAt.isEmpty {
                    meta.append(ServedTimestamp.localLabel(judgedAt, now: now, timeZone: timeZone, locale: locale))
                }
                return meta.isEmpty ? text : "\(text) (\(meta.joined(separator: ", ")))"
            }
        }.joined(separator: ", ")
    }

    /// One caption inside the expansion or on a row: an epic's `Done when:`
    /// and `Needs first:`, and the `Needs first:` line on child and
    /// corrections-queue rows.
    ///
    /// **The behaviour lives in `ClampedCaption`**, including why clamped and
    /// selectable together overdrew `Severity: medium` (PR #171) and why
    /// expanding is what makes the text selectable again. This is the seam
    /// that supplies the bounded tooltip, since `libraryTooltip` is where the
    /// sanitising and the bound live for every Library-served string this
    /// file hands to `.help`.
    private func clampedCaption(
        _ content: Text, full: String, role: FrameTypography.Role = .caption
    ) -> some View {
        ClampedCaption(content: content, full: full,
                       tooltip: CockpitView.libraryTooltip(full), role: role,
                       moreInk: moreLinkInk)
    }

    /// The "more" affordance's ink — `ThemeRecipe.progressTextInk`'s crew-hue
    /// text, or `.primary` where `progressCollidesWithSummons` says the crew's
    /// hue would read as a second summons. The same entry point and the same
    /// fallback `WaypointRibbon.currentTextStyle` uses for the current
    /// waypoint's label, so the two inks cannot drift apart.
    private var moreLinkInk: AnyShapeStyle {
        guard let text = ThemeRecipe.progressTextInk(accent: resolvedAccent, on: indexSurface) else {
            return AnyShapeStyle(.primary)
        }
        return AnyShapeStyle(Color(text))
    }

    /// Loading, empty, and error each draw differently — the empty case
    /// reads "no work items filed" rather than as a stuck fetch or a
    /// failure, since the whole fleet has filed none yet and that is
    /// expected, not broken (see `LibraryClient.ChildItem`'s doc).
    @ViewBuilder
    private func childItemsSection(_ entry: LibraryClient.CourseEntry) -> some View {
        switch model.childrenByEntry[entry.id] {
        case .none:
            EmptyView()
        case .loading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Loading work items…").frameFont(.caption).foregroundStyle(secondaryInk)
            }
        case .loaded(let items):
            if items.isEmpty {
                Text("No work items filed under this epic yet.")
                    .frameFont(.caption).foregroundStyle(secondaryInk)
            } else {
                let showType = CockpitView.showsTypeChips(items)
                ForEach(items, id: \.id) { item in
                    childItemRow(item, showType: showType)
                }
            }
        case .failed(let error):
            unreachableLine("Could not reach work items", detail: error)
        }
    }

    /// One work item under an expanded epic. `state` now speaks the exact
    /// state table `courseEntryRow` speaks for a Course entry — the same
    /// `RowTreatment`, so a child and its epic read the same vocabulary one
    /// level down rather than a second one invented here.
    ///
    /// **A two-column layout, not one `HStack` sizing the glyph implicitly.**
    /// The fixed-width leading column normalizes the differing glyph widths
    /// so every title's left edge lines up — not, as an earlier version of
    /// this comment claimed, to stop a wrapped second line drifting under
    /// the bullet, which an `HStack` whose second column is a `VStack` never
    /// does regardless of the glyph's width.
    ///
    /// **The type chip occupies the `VStack`'s second row, under the
    /// title.** `pr-open` carries no glyph of its own — it collapses into
    /// `.inProgress` — so its own honesty lives in `.help` too.
    ///
    /// `showType` is decided once per epic by `showsTypeChips`, all rows or
    /// none — never a per-row decision.
    private func childItemRow(_ item: LibraryClient.ChildItem, showType: Bool) -> some View {
        let treatment = CockpitView.rowTreatment(state: item.state, resolution: nil)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: treatment.glyphName)
                .frameFont(.icon)
                .foregroundStyle(glyphInk(treatment))
                .frame(width: 14, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .frameFont(.caption)
                    .strikethrough(treatment.strikethrough)
                    .foregroundStyle(CockpitView.titleInk(treatment, ground: statusGround))
                    .lineLimit(2)
                    // Clamped, so it opts out for the reason `clampedCaption`
                    // documents. Not routed through that helper, because a
                    // child title carries its own ink and strikethrough.
                    //
                    // **IT NEEDS ITS OWN `.help`, and pointing at the row's
                    // was wrong** (`deck-reviewer`, PR #171). The row's
                    // tooltip is `childHelpText`, which returns the raw
                    // state word and NEVER the title — so a clamped title
                    // had nothing carrying its overflow, while the bug this
                    // PR fixes at least drew the whole string, messily.
                    // Opting out without this would have removed the only
                    // way to read a long child title.
                    .textSelection(.disabled)
                    .help(CockpitView.childTitleHelpText(item))
                    // Copyable for the reason `clampedCaption` documents:
                    // this title lost selection in PR #171 and had no copy
                    // path afterwards. Raw title to the pasteboard, not the
                    // bounded tooltip string.
                    .contextMenu {
                        Button(ItemOpenButton.menuTitle) { onSelectCorrection(item.id) }
                        Button("Copy title") {
                            CockpitView.copyTitleToPasteboard(item.title)
                        }
                    }
                if showType, let type = item.type, !type.isEmpty {
                    Text(type.uppercased())
                        .frameFont(.caption)
                        .foregroundStyle(CockpitView.typeChipInkStyle(
                            on: statusGround, highlighted: model.highlightedItemID == item.id))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
                // A child carries no "Done when:" line, so this is the only
                // place its own prerequisites draw — independent of the
                // type slot above, since a row can be both blocked on an
                // unmet prerequisite and typed at once.
                if let needsFirst = CockpitView.needsFirstText(item.prerequisites) {
                    clampedCaption(
                        Text("Needs first: ").fontWeight(.semibold) + needsFirst,
                        full: "Needs first: \(CockpitView.needsFirstPlainText(item.prerequisites))")
                }
            }
            Spacer(minLength: 0)
            // Same posture as `courseEntryRow`'s lock icon — drawn from the
            // Library's own `blocked` field only. See that call site's
            // comment.
            if item.blocked {
                Image(systemName: "lock.fill")
                    .frameFont(.icon)
                    .foregroundStyle(Color(ThemeRecipe.attentionTextInk(on: indexSurface)))
                    .help("Blocked — waiting on its prerequisites")
                    .accessibilityLabel("blocked")
            }
            // The same hover-revealed "Copy title" `courseEntryRow` and the
            // corrections-queue row already carry, reserved rather than
            // conditional for the same reason theirs is (see
            // `courseEntryRow`'s comment above `showsCopy`): this title also
            // clamps and wraps, so a conditionally-included icon would move
            // the wrap point as the pointer arrived. The `.contextMenu`
            // below was, until now, the only way to reach this — right-click
            // alone is not an affordance a reader finds without already
            // knowing it's there (issue_01M2787H072R4FFX4DBHVHX1VY).
            let showsCopy = hoveredChildItemID == item.id
            // A child work item had no route to its own record at all: no
            // tap and no menu entry reached the Item pane.
            ItemOpenButton(isRevealed: showsCopy) { onSelectCorrection(item.id) }
            Button {
                CockpitView.copyTitleToPasteboard(item.title)
            } label: {
                Image(systemName: "doc.on.doc")
                    .frameFont(.icon)
                    .foregroundStyle(secondaryInk)
            }
            .buttonStyle(.plain)
            .help("Copy title")
            .opacity(showsCopy ? 1 : 0)
            .allowsHitTesting(showsCopy)
            .accessibilityHidden(!showsCopy)
        }
        .contentShape(Rectangle())
        // The row a click on an issue id in the conversation revealed
        // (`CockpitModel.highlightedItemID`): the proposal card's tint, the
        // cockpit's only highlight. It bleeds 4pt past the row rather than
        // padding it, so highlighting a row moves nothing.
        .background {
            if model.highlightedItemID == item.id {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(CockpitView.childRowHighlightOpacity))
                    .padding(-4)
            }
        }
        .id(item.id)
        .onHover { isHovering in
            if isHovering {
                hoveredChildItemID = item.id
            } else if hoveredChildItemID == item.id {
                hoveredChildItemID = nil
            }
        }
        .help(CockpitView.childHelpText(item) ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CockpitView.accessibilityLabel(
            title: item.title, treatment: treatment, blocked: item.blocked))
    }

    /// What hovering a child row's TITLE says: the title itself, which is the
    /// escape hatch for the `.lineLimit(2)` clamp, followed by whatever the
    /// row's own tooltip would have said.
    ///
    /// **It carries both rather than replacing one with the other.** A
    /// `.help` on the title wins over the row's for the title's own region,
    /// so a title tooltip saying only the title would silently cost a row
    /// its state exactly where a reader is most likely to hover.
    ///
    /// Both halves go through `libraryTooltip`; the join is not re-cut,
    /// because cutting the composed string is what would drop the state off
    /// the end of a long title. That is the shape `agentRunHelpText` already
    /// uses — bound each field, join the bounded ones.
    /// Pure, so it is testable without a view.
    nonisolated static func childTitleHelpText(_ item: LibraryClient.ChildItem) -> String {
        let title = CockpitView.libraryTooltip(item.title)
        guard let state = childHelpText(item), !state.isEmpty else {
            return title
        }
        return title.isEmpty ? state : "\(title) — \(state)"
    }

    /// What hovering a child row says — the raw state word, so `pr-open`
    /// (collapsed into `.inProgress` at a glance) still says exactly what it
    /// is on hover. Pure, so it is testable without a view.
    nonisolated static func childHelpText(_ item: LibraryClient.ChildItem) -> String? {
        item.state.map(CockpitView.libraryTooltip)
    }

    /// A claimed queue row's caption: `"claimed · agent-x"` for a live claim,
    /// `"claim expired"` once `claimExpired` marks it lapsed, `nil` when the
    /// item carries no `claimedBy` at all (an `open` or `pr-open` row, or a
    /// `claimed` one whose holder degraded away). Pure, so it is testable
    /// without a view, the same split `childHelpText` uses.
    ///
    /// **Says "claim expired" rather than naming the lapsed holder.** Unlike
    /// `LibraryClient.claimMetaFragment`'s "last held by agent-x" (the epic
    /// detail's own choice, made deliberately to keep the name informative —
    /// see that function's doc), this row's whole point is that the item is
    /// free again: the holder who no longer holds it is not the fact this
    /// row needs to carry.
    nonisolated static func queueClaimMetaText(_ item: LibraryClient.QueueItem) -> String? {
        guard let claimedBy = item.claimedBy else { return nil }
        return item.claimExpired ? "claim expired" : "claimed · \(claimedBy)"
    }

    // MARK: - Corrections queue

    @ViewBuilder
    private var correctionsQueueTrailing: some View {
        if let queue = model.queue {
            HStack(spacing: 4) {
                // `queue.truncated` is the escape hatch `LibraryClient.pagedQueueItems`
                // reports when even `itemsMaxPages` of paging left the Library still
                // saying `truncated: true` — the count beside it is real but short,
                // and this mark is what keeps that from reading as the whole queue.
                if queue.truncated {
                    Image(systemName: "exclamationmark.triangle")
                        .frameFont(.icon)
                        .foregroundStyle(Color(ThemeRecipe.attentionTextInk(on: indexSurface)))
                        .help("The Library reports more items than this panel could page in — the count and list below may be short.")
                        .accessibilityLabel("queue count may be incomplete")
                }
                queueSortMenu
                Text("\(queue.total)").frameFont(.label).foregroundStyle(secondaryInk)
            }
        }
    }

    /// The queue's sort control — `LibraryClient.QueueSortOrder`'s three
    /// orders, in a compact menu beside the header's own count rather than a
    /// full-width segmented control, matching `SessionPaneView`'s own
    /// trailing-icon `Menu` for the same reason: this header has no room to
    /// spare for a wider control, and the choice is made rarely, not on
    /// every glance at the panel. Persisted through `themeStore`, so it
    /// survives a refresh (`ThemeStore` is never reset by `CockpitModel`'s
    /// poll, unlike `model.isQueueExpanded`) and a relaunch (`theme.json`).
    private var queueSortMenu: some View {
        Menu {
            ForEach(LibraryClient.QueueSortOrder.allCases, id: \.self) { order in
                Button {
                    themeStore.setQueueSortOrder(order)
                } label: {
                    if order == themeStore.configuration.queueSortOrder {
                        Label(order.displayName, systemImage: "checkmark")
                    } else {
                        Text(order.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .frameFont(.icon)
                .foregroundStyle(secondaryInk)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort the queue: \(themeStore.configuration.queueSortOrder.displayName)")
        .accessibilityLabel("Sort order: \(themeStore.configuration.queueSortOrder.displayName)")
    }

    @ViewBuilder
    private var correctionsQueueContent: some View {
        if let queueError = model.queueError {
            unreachableLine("Could not reach the queue", detail: queueError)
        } else if let queue = model.queue {
            if queue.items.isEmpty {
                Text("Nothing in the queue.")
                    .frameFont(.label).foregroundStyle(secondaryInk)
            } else {
                ForEach(visibleQueueItems(queue), id: \.id) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // TWO GLYPHS, BECAUSE THE QUEUE NOW HOLDS TWO KINDS
                        // OF THING (the operator, 2026-09-04). `open` is an interrupt
                        // nobody has picked up; `pr-open` is finished work
                        // whose pull request is waiting on a person, and it
                        // sorts to the top for that reason
                        // (`LibraryClient.queueStates`). Drawing both as the
                        // same orange exclamation would say the queue is one
                        // list of undifferentiated problems, which is the
                        // reading that made a `pr-open` item's disappearance
                        // invisible in the first place.
                        //
                        // SHAPE CARRIES IT, NOT COLOUR ALONE — the same rule
                        // `rowTreatment` follows for the Course's own rows.
                        Image(systemName: item.isAwaitingPR
                              ? "arrow.triangle.pull" : "exclamationmark.circle")
                            .frameFont(.icon)
                            .foregroundStyle(item.isAwaitingPR
                                            ? glyphInk(.inProgress)
                                            : AnyShapeStyle(Color(ThemeRecipe.attentionTextInk(on: indexSurface))))
                            .frame(width: 14, alignment: .center)
                            .accessibilityLabel(item.isAwaitingPR
                                                ? "pull request open" : "needs attention")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).frameFont(.body).lineLimit(2)
                                // Same escape hatch as the epic row above.
                                // `deck-reviewer` scoped this out of PR #173 as
                                // pre-existing rather than a regression; it is
                                // closed here with its sibling.
                                .help(CockpitView.libraryTooltip(item.title))
                            // A `claimed` row is a free item that otherwise
                            // reads as taken — the whole reason `.claimed`
                            // joined `LibraryClient.queueStates`
                            // (`issue_01M1Y7AKMRQ4S7K9CX5R99ZMPQ`). Live and
                            // lapsed draw differently rather than both saying
                            // "claimed", since a lapsed claim is exactly the
                            // free-to-take interrupt an `open` row is.
                            if let claimText = CockpitView.queueClaimMetaText(item) {
                                Text(claimText)
                                    .frameFont(.caption)
                                    .foregroundStyle(item.claimExpired
                                                     ? AnyShapeStyle(Color(ThemeRecipe.attentionTextInk(on: indexSurface)))
                                                     : secondaryInk)
                            }
                            // The reverse of the PR row's own chip
                            // (issue_01M2P5D0D4EQEQX7BSRNFT5QGJ) — before
                            // this, a `pr-open` row said only that, and a
                            // reader had to leave the queue to learn which
                            // pull request it was.
                            if item.isAwaitingPR, let number = item.prNumber {
                                Text("PR #\(number)").frameFont(.caption).foregroundStyle(secondaryInk)
                            }
                            if let needsFirst = CockpitView.needsFirstText(item.prerequisites) {
                                clampedCaption(
                                    Text("Needs first: ").fontWeight(.semibold) + needsFirst,
                                    full: "Needs first: \(CockpitView.needsFirstPlainText(item.prerequisites))")
                            }
                        }
                        Spacer(minLength: 0)
                        // Same posture as `courseEntryRow`'s lock icon —
                        // drawn from the Library's own `blocked` field only.
                        // See that call site's comment.
                        if item.blocked {
                            Image(systemName: "lock.fill")
                                .frameFont(.icon)
                                .foregroundStyle(Color(ThemeRecipe.attentionTextInk(on: indexSurface)))
                                .help("Blocked — waiting on its prerequisites")
                                .accessibilityLabel("blocked")
                        }
                        // A `high` item earns the one mark this row can carry
                        // beyond its position — the row that sorted second
                        // instead of sixth still looks like every other row
                        // otherwise (`LibraryClient.decodeCorrectionsQueue`'s
                        // severity sort). Design spec: `02-cockpit.html`'s
                        // `.sev` chip. Shown for `high` only, not `medium` or
                        // `low` — the spec draws the chip on the one row that
                        // needs a person to notice it, not as a legend for
                        // every severity word the Library might send.
                        if item.severity == "high" {
                            Text("HIGH")
                                .frameFont(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color(ThemeRecipe.attentionTextInk(on: indexSurface)))
                                .accessibilityLabel("severity high")
                        }
                        // Reserved rather than conditional, for the reason
                        // `courseEntryRow` documents: this title also clamps
                        // to two lines, so an icon that appears on hover would
                        // take its width from the text and move the wrap.
                        let showsCopy = hoveredQueueItemID == item.id
                        // The row tap already opens the pane; this makes that
                        // route visible on hover, matching the epic and child
                        // rows. The tap itself is unchanged.
                        ItemOpenButton(isRevealed: showsCopy) { onSelectCorrection(item.id) }
                        Button {
                            CockpitView.copyTitleToPasteboard(item.title)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .frameFont(.icon)
                                .foregroundStyle(secondaryInk)
                        }
                        .buttonStyle(.plain)
                        .help("Copy title")
                        .opacity(showsCopy ? 1 : 0)
                        .allowsHitTesting(showsCopy)
                        .accessibilityHidden(!showsCopy)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectCorrection(item.id) }
                    .onHover { isHovering in
                        if isHovering {
                            hoveredQueueItemID = item.id
                        } else if hoveredQueueItemID == item.id {
                            hoveredQueueItemID = nil
                        }
                    }
                    // Opts out of the container-level
                    // `.textSelection(.enabled)` — see that modifier's
                    // comment on `courseEntryRow`'s same treatment.
                    .textSelection(.disabled)
                    .contextMenu {
                        Button(ItemOpenButton.menuTitle) { onSelectCorrection(item.id) }
                        Button("Copy title") {
                            CockpitView.copyTitleToPasteboard(item.title)
                        }
                    }
                }
                queueExpander(queue)
            }
            if queue.truncated {
                queueTruncatedNotice
            }
        } else if !model.isLoading {
            Text("No corrections queue reading yet.")
                .frameFont(.label).foregroundStyle(secondaryInk)
        }
    }

    /// Shown when `LibraryClient.pagedQueueItems` gave up on a state still
    /// mid-truncation after `LibraryClient.itemsMaxPages` — an explicit "some
    /// rows are missing" rather than the panel quietly presenting the pages
    /// it did get as the whole queue. Distinct from `queueExpander`, which
    /// only ever says how many of the rows ALREADY IN HAND are hidden behind
    /// the collapse; this says the Library itself has more than that.
    private var queueTruncatedNotice: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .frameFont(.icon)
            Text("The Library has more items than this panel could page in — some rows may be missing.")
                .frameFont(.label)
        }
        .foregroundStyle(Color(ThemeRecipe.attentionTextInk(on: indexSurface)))
        .padding(.top, 4)
    }

    /// The rows the panel draws: the top few by default, everything once the
    /// reader expands it — in whichever of `LibraryClient.QueueSortOrder`'s
    /// three orders `themeStore.configuration.queueSortOrder` names.
    ///
    /// **ORDERS THE FULL MERGED SET BEFORE SLICING IT, NEVER AFTER.**
    /// `queue.items` is `fetchCorrectionsQueue`'s whole result, every state's
    /// every page; `orderedQueueItems` runs once over that entire array, and
    /// only then is `queueRowLimit` applied to the result. Capping first and
    /// ordering the five-item slice would show whichever rows happened to
    /// arrive first rather than the actual worst five — the mistake Orient
    /// measured on its own page, where capping before sorting showed 22 of
    /// 47 high-severity items and hid 25 (issue_01M2P9ZPBA5114PE875BHHT8NR).
    private func visibleQueueItems(
        _ queue: LibraryClient.CorrectionsQueue
    ) -> [LibraryClient.QueueItem] {
        let ordered = LibraryClient.orderedQueueItems(queue.items, order: themeStore.configuration.queueSortOrder)
        return model.isQueueExpanded ? ordered : Array(ordered.prefix(CockpitView.queueRowLimit))
    }

    /// The way to the items the slice hides, and the way back.
    ///
    /// **It says how many are hidden rather than "show more"**, because the
    /// number is the fact a reader needs to decide whether to look: a queue of
    /// six and a queue of thirty drew identically before this, both as five
    /// rows with nothing announcing the rest.
    ///
    /// **Counts `items.count`, not `queue.total`, though the two are always
    /// equal today** — `LibraryClient.CorrectionsQueue.total` is defined as
    /// `items.count` (see that struct's doc), never a raw envelope figure, so
    /// there is no drift between them left to protect against. This still
    /// reads `items.count` directly rather than `queue.total` so the control
    /// stays correct by construction rather than by that definition holding:
    /// it can never promise rows the panel does not hold, whichever field a
    /// future change to `total` repoints. `queue.truncated` is the separate
    /// signal for the case this count cannot fix — the Library holding MORE
    /// than `items` does, after `LibraryClient.pagedQueueItems` gave up
    /// paging for one; that reads through `queueTruncatedNotice`, not here.
    @ViewBuilder
    private func queueExpander(_ queue: LibraryClient.CorrectionsQueue) -> some View {
        let hidden = queue.items.count - CockpitView.queueRowLimit
        if hidden > 0 {
            Button {
                model.toggleQueueExpansion()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.isQueueExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                    Text(model.isQueueExpanded ? "Show fewer" : "\(hidden) more")
                        .frameFont(.label)
                }
                .foregroundStyle(secondaryInk)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    /// The top few — the rest are behind `queueExpander`. `deck/bead/deck`
    /// §"The work" asks for "the top few items ... with a link to the whole
    /// queue"; expanding in place is that link, since the whole queue is
    /// already in hand (see `CockpitModel.isQueueExpanded`).
    static let queueRowLimit = 5

    // MARK: - Crew stats

    @ViewBuilder
    private var crewStatsTrailing: some View {
        if let agentRuns {
            Text("\(agentRuns.count)").frameFont(.label).foregroundStyle(secondaryInk)
        }
    }

    /// One line per agent in flight, whatever individuated it —
    /// `issue_01M0NWW3R742YGQZF9KBYHW8GQ`. **First in the column**: the
    /// Course below it has no bounded height and pushes everything after it
    /// off the bottom of the pane, so this is deliberately not the panel
    /// left down there (`issue_01M1CCYWG8409VA4PT4W1QBB5D`). Its rows still
    /// appear and vanish on their own between polls; that churn now pushes
    /// every other panel down rather than around, which is the trade this
    /// position makes.
    ///
    /// **"Dispatched" rather than "Crew"**, deliberately: the title states
    /// the boundary the standing footer then completes, rather than the
    /// footer reading like an apology bolted onto an unrelated header.
    @ViewBuilder
    private var crewStatsContent: some View {
        if let agentRuns {
            if agentRuns.isEmpty {
                Text("No agents in flight.")
                    .frameFont(.label).foregroundStyle(secondaryInk)
            } else {
                ForEach(CockpitView.sortedAgentRuns(agentRuns), id: \.id) { run in
                    agentRunRow(run)
                }
            }
        } else {
            Text("This host doesn't report agent runs yet.")
                .frameFont(.label).foregroundStyle(secondaryInk)
        }
        // ALWAYS DRAWN, including on an empty panel — that is exactly
        // where "no agents in flight" is only honest with the boundary
        // attached. Drawn always, it reads as furniture (a map's "not
        // for navigation") rather than an alert, which is the point:
        // the Task tool is expected to be retired, and until then this
        // says plainly what the panel does not cover (the operator).
        Text("Runs started through the Task tool aren't tracked here.")
            .frameFont(.caption).foregroundStyle(secondaryInk)
    }

    /// One dispatched run. Two lines on `childItemRow`'s own grammar: a
    /// fixed-width glyph column, then identity-plus-metadata over a quiet
    /// detail line. Every row here IS "work is moving here", which is what
    /// `RowTreatment.inProgress`'s accent glyph already means — there is no
    /// second treatment to choose between.
    private func agentRunRow(_ run: SessionState.AgentRun) -> some View {
        // `.help` sits on the leaf `Text` views a person actually hovers,
        // not on the row container: the container also carries
        // `runRowSelection`'s `.contentShape`/`.onTapGesture`/
        // `.textSelection(.disabled)` stack, and the one tooltip the operator
        // has seen work (the PR ladder's `#NNN` link) is a leaf `Text` with
        // `.help` attached directly, ahead of its own `.textSelection`.
        // The cause of the container-level failure is unconfirmed; this
        // copies the known-working shape rather than diagnosing it.
        let helpText = CockpitView.agentRunHelpText(run) ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: RowTreatment.inProgress.glyphName)
                .frameFont(.icon)
                .foregroundStyle(glyphInk(.inProgress))
                .frame(width: 12, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The name truncates before the metadata does — same
                    // trade `courseEntryRow` makes for its counts.
                    //
                    // SANITISED, because `run.agent` comes from `active.json`
                    // — machine-wide and attacker-influenced, the same trust
                    // level `SessionPaneView.displayable` already exists to
                    // handle for transcript text.
                    Text(CockpitView.sanitizedAgentField(run.agent))
                        .frameFont(.label)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .help(helpText)
                    Spacer(minLength: 0)
                    if let trailing = CockpitView.agentRunTrailingMetadata(run, now: Date()) {
                        Text(trailing)
                            .frameFont(.caption)
                            .foregroundStyle(secondaryInk)
                            .monospacedDigit()
                            .fixedSize()
                            .help(helpText)
                    }
                }
                // ABSENT, NOT "PRIVATE" OR "WITHHELD". A crew's dispatch
                // prompt is kept off the machine for a black-box crew
                // (ADR-0043), or when privacy could not be determined —
                // and Deck cannot tell those two apart from a task the
                // registry never carried in the first place. Claiming the
                // distinction would be inventing it, so the line is
                // simply not drawn.
                if let task = run.task {
                    Text(CockpitView.taskGloss(task))
                        .frameFont(.caption)
                        .foregroundStyle(secondaryInk)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(helpText)
                }
            }
        }
        .runRowSelection(runId: run.runId, openRunId: openRunId, onSelectRun: onSelectRun)
    }

    /// Whatever `agent_runs` gave us, in the order the panel draws it —
    /// ascending by `startedAt`, so the longest-running row sits at the top
    /// and a poll that changes nothing reorders nothing. A run with no
    /// `startedAt` sorts after every run that has one, rather than being
    /// mistaken for the oldest; `runId` breaks a tie, including the tie
    /// between two runs that both lack a start time.
    ///
    /// A PURE FUNCTION, so the ordering is testable without a view — the
    /// same discipline `rowTreatment`/`childProgress` already follow.
    nonisolated static func sortedAgentRuns(
        _ runs: [SessionState.AgentRun]
    ) -> [SessionState.AgentRun] {
        let sorted = runs.sorted { a, b in
            switch (a.startedAt, b.startedAt) {
            case let (sa?, sb?):
                if sa != sb { return sa < sb }
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            case (nil, nil):
                break
            }
            return (a.runId ?? "") < (b.runId ?? "")
        }
        // Stamp each element with its position in THIS sorted snapshot, so
        // `AgentRun.id`'s run_id-less fallback can fold it in and tell apart
        // two runs the mini reports as byte-identical (a private crew's
        // redaction — see `AgentRun.id`). The array `sorted` produces is
        // always a fresh copy, so this never mutates the caller's own
        // `agentRuns`.
        return sorted.enumerated().map { index, run in
            var stamped = run
            stamped.snapshotIndex = index
            return stamped
        }
    }

    /// The model half of the Dispatched line, "haiku 4.5 (typed override)":
    /// the glossed model plus how it was chosen when it was not the roster's
    /// pick. The run pane shows the same string.
    nonisolated static func agentRunModelLine(_ run: SessionState.AgentRun) -> String? {
        let qualifier = RunModelMark.dispatchedQualifier(for: run.modelSource, resolved: run.modelResolved)
        return run.model.map(modelGloss).map { gloss in
            qualifier.map { "\(gloss) (\($0))" } ?? gloss
        }
    }

    /// The line's trailing `"<model> · <clock time> · <runtime>"`, each part
    /// demoted alone when its field is missing, `nil` when all are. `now` is
    /// the reader's own clock, passed in rather than read here, so the
    /// derivation stays pure and testable — the call site supplies `Date()`
    /// fresh on every render, which is what makes the runtime advance
    /// without a timer: the panel simply redraws whenever the session
    /// payload it already reads arrives with a new poll. `timeZone` and
    /// `locale` default to the Mac's own, following
    /// `LibraryClient.approvalRefusalMessage`'s pattern for a pinnable clock.
    nonisolated static func agentRunTrailingMetadata(
        _ run: SessionState.AgentRun, now: Date, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String? {
        let modelPart = agentRunModelLine(run)
        let clockPart = run.startedAt.map {
            agentRunStartClockLabel($0, now: now, timeZone: timeZone, locale: locale)
        }
        let runtimePart = run.startedAt.map {
            WorkingStrip.durationLabel(now.timeIntervalSince1970 - $0)
        }
        let parts = [modelPart, clockPart, runtimePart, run.cost.map(agentRunCostLabel)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A run's start time as a clock reading in the reader's own zone and
    /// locale: `08:12` when it started today, `Sep 29 23:45` when it started
    /// on an earlier day than `now`. `now`, `timeZone` and `locale` are
    /// parameters so a test can pin the clock.
    nonisolated static func agentRunStartClockLabel(
        _ startedAt: Double, now: Date, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        ServedTimestamp.label(
            for: Date(timeIntervalSince1970: startedAt), now: now, timeZone: timeZone, locale: locale)
    }

    /// A run's start time as the full local date and time, `Sep 30, 08:12` —
    /// the run pane's `Started` fact and the tooltip's `Started:` line, both
    /// always dated since neither has a `now` to compare against for "today".
    nonisolated static func agentRunStartFullLabel(
        _ startedAt: Double, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd jmm")
        return formatter.string(from: Date(timeIntervalSince1970: startedAt))
    }

    /// One run's spend, marked when it is not exact: `$1.16` for metered
    /// spend, `≈$1.16` for a list-price reading or a source this build does
    /// not know.
    ///
    /// **THE MARKING IS NOT DECORATION.** The operator approved serving a list-price
    /// figure for subscription runs only on the condition that it never draws
    /// as though it were metered (2026-09-15), and `RunCost.Source` carries
    /// which it is so this cannot be lost. An unrecognised source draws
    /// approximate too: an unknown provenance is not a metered one.
    ///
    /// **NO PANEL TOTAL, and its absence is the other half of that
    /// condition.** A crew's runs can mix a metered figure and an estimated
    /// one, and adding them would produce a number that is neither. If a
    /// total is ever wanted here, it has to say what it is made of.
    nonisolated static func agentRunCostLabel(_ cost: SessionState.AgentRun.RunCost) -> String {
        let amount = String(format: "$%.2f", cost.usd)
        return cost.source.isExact ? amount : "≈\(amount)"
    }

    /// The tooltip's cost lines: the figure, what kind of figure it is, and
    /// when the mini wrote it — in the reader's own zone, through
    /// `ServedTimestamp`. A reader hovering is the reader asking whether to
    /// trust the number, so this is where the estimate says so in words
    /// rather than in one glyph.
    nonisolated static func agentRunCostHelpLines(
        _ cost: SessionState.AgentRun.RunCost,
        now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current
    ) -> [String] {
        let kind: String
        switch cost.source {
        case .metered: kind = "metered spend"
        case .estimate: kind = "list-price estimate, not the billed total"
        case .unrecognized(let wire):
            kind = "source not recognised (\(sanitizedAgentField(wire))), treated as approximate"
        }
        var lines = ["Cost: \(agentRunCostLabel(cost)) — \(kind)"]
        if let writtenAt = cost.writtenAt {
            let drawn = ServedTimestamp.localLabel(writtenAt, now: now, timeZone: timeZone, locale: locale)
            lines.append("Cost read: \(sanitizedAgentField(drawn))")
        }
        return lines
    }

    /// The full model id, `run_id`, `repo`, `started_at`, and the task head
    /// bounded to 500 characters — the escape hatch for everything the row
    /// itself condenses or omits. `nil` only when every one of those fields
    /// is missing, which the row's own glyph and (if present) agent name
    /// still draw something for.
    ///
    /// EVERY FIELD SANITISED AND BOUNDED, not only `task`. `model`, `run_id`
    /// and `repo` come from the same attacker-influenced `active.json` and
    /// a tooltip is where a long hostile string sits unnoticed longest —
    /// nobody reads it until they hover.
    ///
    /// `Started:` reads in the reader's own zone and locale, the same
    /// `agentRunStartFullLabel` the run pane's `Started` fact uses, rather
    /// than the UTC ISO 8601 instant it showed before this changed.
    nonisolated static func agentRunHelpText(
        _ run: SessionState.AgentRun, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String? {
        var lines: [String] = []
        if let model = run.model { lines.append("Model: \(CockpitView.sanitizedAgentField(model))") }
        if let chosen = RunModelMark.dispatchedHelpLine(for: run.modelSource) { lines.append(chosen) }
        if let runId = run.runId { lines.append("Run: \(CockpitView.sanitizedAgentField(runId))") }
        if let repo = run.repo { lines.append("Repo: \(CockpitView.sanitizedAgentField(repo))") }
        if let startedAt = run.startedAt {
            let started = agentRunStartFullLabel(startedAt, timeZone: timeZone, locale: locale)
            lines.append("Started: \(started)")
        }
        if let cost = run.cost {
            lines.append(contentsOf: agentRunCostHelpLines(cost, now: now, timeZone: timeZone, locale: locale))
        }
        if let task = run.task { lines.append(CockpitView.sanitizedAgentField(task)) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A Library-served string on its way into a `.help` tooltip: sanitised,
    /// then bounded to `WaypointRibbon.tooltipCharacterLimit`.
    ///
    /// **THE ORDER IS THE POINT, and `condense` ALONE IS NOT A BOUND.**
    /// `condense` counts Characters, and a single grapheme cluster can carry
    /// unboundedly many scalars — so a Character-count cap applied first
    /// bounds nothing. `SessionPaneView.displayable` caps every cluster at 16
    /// scalars, and only after that does counting Characters bound the total.
    /// This is the same ordering `sanitizedAgentField` documents below, whose
    /// comment records the attack defeating three rounds of review.
    ///
    /// **It exists because the bound had to live somewhere a caller could
    /// not forget, and one already had** (`deck-security-reviewer`, PR #171).
    /// The first version of this change put the bound inside
    /// `clampedCaption` and claimed no caller could forget it; `childHelpText`
    /// was building an unbounded `park_reason` tooltip one call site over,
    /// on the same row, from the same field the epic-level line bounds. A
    /// bound inside one helper is not a bound on the surface.
    ///
    /// So: every Library-served string this file hands to `.help` goes
    /// through here. AppKit sizes a tooltip window to whatever it is handed,
    /// and the Library bounds none of these fields at the write path.
    nonisolated static func libraryTooltip(_ value: String) -> String {
        WaypointRibbon.condense(SessionPaneView.displayable(value),
                                to: WaypointRibbon.tooltipCharacterLimit)
    }

    /// Sanitises a raw `AgentRun` field for display, and bounds it to 500
    /// characters — `task`'s existing ceiling, now shared by every field
    /// this row or its tooltip draws unglossed.
    ///
    /// `displayable()` FIRST, THEN THE CHARACTER-BASED CUT, in that order
    /// deliberately: `SessionPaneView.displayable` bounds every grapheme
    /// cluster to at most 16 scalars, so a `.prefix` counted in Characters
    /// afterward bounds total scalars too. Cutting first would not — a
    /// single pathological cluster passes any Character-count cap
    /// untouched, which is exactly the attack `SessionPaneView.displayable`'s
    /// doc comment records defeating three rounds of review before this one.
    /// NOT `private` — `ServiceCrewPanel`'s Dispatched panel draws the same
    /// `AgentRun` fields from the same attacker-influenced `active.json`
    /// source and must sanitise them identically, so this is shared rather
    /// than a second copy that could drift out of step with the bound
    /// `sanitizedAgentField`'s own doc records three rounds of review
    /// defeating an unbounded-cluster attack on.
    nonisolated static func sanitizedAgentField(_ value: String) -> String {
        String(SessionPaneView.displayable(value).prefix(500))
    }

    /// The most of a dispatch instruction the run pane draws. Real ones run
    /// 2,000 to 6,000 characters; this bound is for a hostile one.
    nonisolated static let instructionCharacterLimit = 50_000

    /// A run's full dispatch instruction, ready to draw in the run pane:
    /// `displayable` first and the Character cut after, for the reason
    /// `sanitizedAgentField` gives, but with `instructionCharacterLimit` in
    /// place of its 500. Where the cut bites, a closing line says so, so a
    /// truncated instruction never reads as a complete one.
    nonisolated static func sanitizedInstruction(_ value: String) -> String {
        let clean = SessionPaneView.displayable(value)
        guard clean.count > instructionCharacterLimit else { return clean }
        return String(clean.prefix(instructionCharacterLimit))
            + "\n\n[Cut here: the instruction is longer than \(instructionCharacterLimit) characters.]"
    }

    /// `run.agent`, sanitised the same way — no separate length cap, since
    /// the row already draws it at `.lineLimit(1)`.
    nonisolated static func sanitizedAgentField(_ value: String?) -> String {
        SessionPaneView.displayable(value ?? "")
    }

    /// Strips a leading `claude-` and a trailing version segment, so
    /// `claude-sonnet-5` draws `sonnet`. Anything not in the `claude-`
    /// shape draws as received, through `condense` — this never invents a
    /// gloss for a model id it does not recognise.
    ///
    /// SANITISED BEFORE `condense`, for the reason `sanitizedAgentField`
    /// documents: `condense`'s Character-based bound does not itself limit
    /// scalars, so an unsanitised model id could carry an oversized cluster
    /// straight through it to the `Text` this glosses for.
    nonisolated static func modelGloss(_ model: String) -> String {
        let sanitized = SessionPaneView.displayable(model)
        guard sanitized.hasPrefix("claude-") else { return WaypointRibbon.condense(sanitized) }
        var stripped = String(sanitized.dropFirst("claude-".count))
        if let range = stripped.range(of: #"-[0-9][0-9.]*$"#, options: .regularExpression) {
            stripped.removeSubrange(range)
        }
        return WaypointRibbon.condense(stripped)
    }

    /// Flattens a dispatch prompt — routinely 2,000-6,000 characters of
    /// structured markdown — into one glanceable line: the first ~500
    /// characters, markdown markers stripped from the start of each line,
    /// whitespace runs collapsed, then `WaypointRibbon.condense` to 90.
    ///
    /// **NEVER "select the first meaningful line" instead.** A prompt
    /// opening `## Task` glosses to "Task", not to an empty label, because
    /// flattening keeps the words the selective version would have thrown
    /// away along with the heading. Every heuristic for skipping a line is
    /// a heuristic that is wrong on some other prompt; this is
    /// deterministic and degrades to slightly noisy rather than to empty.
    ///
    /// Not hoisted out of `WaypointRibbon` — `condense` stays where it is
    /// and this calls it, since moving it would touch its own tests for no
    /// difference this pass draws.
    ///
    /// SANITISED BEFORE THE 500-CHARACTER HEAD, not after — `task` is
    /// attacker-influenced (`active.json` again), and `.prefix` here counts
    /// Characters, not scalars. `SessionPaneView.displayable` bounds every
    /// cluster to at most 16 scalars first, so the Character-counted cut
    /// that follows — here, and inside `WaypointRibbon.condense` — bounds
    /// total scalars too. See `sanitizedAgentField`.
    nonisolated static func taskGloss(_ task: String) -> String {
        let head = String(SessionPaneView.displayable(task).prefix(500))
        let flattened = head
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripLeadingMarkdownMarker(String($0)) }
            .joined(separator: " ")
        let collapsed = flattened
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // A task built entirely of markdown markers ("##\n##\n##") strips
        // every line to nothing, so the flattened join is empty though the
        // task itself was not. Falling back to the raw head — collapsed the
        // same way, markers left in — keeps the gloss non-empty rather than
        // contradicting its own documented invariant.
        guard !collapsed.isEmpty else {
            let rawCollapsed = head
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return WaypointRibbon.condense(rawCollapsed, to: 90)
        }
        return WaypointRibbon.condense(collapsed, to: 90)
    }

    /// One line of a markdown prompt, with a single leading `#`-heading,
    /// `-`/`*`/`>` bullet, or `1.`-style ordered marker (and the whitespace
    /// after it) removed. Only the leading marker — `taskGloss` collapses
    /// whatever markdown remains inside the line along with everything
    /// else once every line has been joined.
    nonisolated private static func stripLeadingMarkdownMarker(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(
            of: #"^(#{1,6}|[-*>]|[0-9]+\.)\s*"#, options: .regularExpression
        ) else { return trimmed }
        return String(trimmed[range.upperBound...])
    }

    private func unreachableLine(_ label: String, detail: String) -> some View {
        Text("\(label): \(detail)")
            .frameFont(.label)
            .foregroundStyle(secondaryInk)
            .lineLimit(2)
    }
}

/// The `Open` control on a Course epic row, a child work-item row, a
/// corrections-queue row and a proposal row. It routes the row's item id to the Item pane
/// through `CockpitView.onSelectCorrection` and does nothing else: no claim,
/// no write, no second pane.
///
/// **RESERVED, NOT CONDITIONAL**, for the reason `courseEntryRow` records
/// (the operator, 2026-09-04): an icon included only on hover takes its width out of a
/// title that clamps to two lines and wraps, so the wrap point moves as the
/// pointer arrives. The button is always laid out and only `isRevealed`
/// changes its opacity, hit testing and accessibility exposure, so both
/// states lay out identically by construction. The rows' context menus carry
/// the same action (`menuTitle`), which is the route for a reader who is not
/// using a pointer.
struct ItemOpenButton: View {
    let isRevealed: Bool
    let action: () -> Void
    @Environment(\.statusGround) private var statusGround

    static let helpText = "Open in the Item pane"
    static let menuTitle = "Open in Item pane"

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.right.square")
                .frameFont(.icon)
                .foregroundStyle(CockpitView.secondaryInkStyle(on: statusGround))
        }
        .buttonStyle(.plain)
        .help(Self.helpText)
        .opacity(isRevealed ? 1 : 0)
        .allowsHitTesting(isRevealed)
        .accessibilityHidden(!isRevealed)
        .accessibilityLabel("Open")
    }
}

/// The side of a Course row a drop lands on, and where its landing line draws.
enum CourseDropEdge: Equatable {
    case above, below
}

/// What a Course row carries while it is dragged: the epic's id, under a
/// payload type of Deck's own so text dragged in from elsewhere (an id
/// selected in a conversation, say) is not read as a reorder.
struct CourseEntryDrag: Codable, Transferable {
    let courseEntryID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
