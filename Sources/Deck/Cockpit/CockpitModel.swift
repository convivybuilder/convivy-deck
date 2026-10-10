import Foundation

/// Drives the cockpit column's two Library reads: the Course and the
/// corrections queue. One instance per `ContentView`, tracking whichever
/// project the current selection resolves to.
///
/// FETCHES ON PROJECT CHANGE AND ON A SLOW TIMER, NOTHING MORE — the Course
/// changes on the order of hours (`deck/bead/deck`), and the rail already
/// polls every ~4s and the session pane every 2s, so a third fast poller
/// would buy nothing and cost an ssh round trip nobody asked for.
@MainActor
final class CockpitModel: ObservableObject {
    @Published private(set) var course: LibraryClient.Course?
    @Published private(set) var courseError: String?
    @Published private(set) var queue: LibraryClient.CorrectionsQueue?
    @Published private(set) var queueError: String?
    @Published private(set) var isLoading = false

    /// The proposals region: the open epics whose maturity is `proposed`,
    /// filtered client-side from the same unfiltered epics read the rail's
    /// bead-progress meter makes (`LibraryClient.proposedEpics(from:)`).
    /// Fetched alongside the Course and queue in `fetch`, cleared alongside
    /// them in `refresh`, and re-fetched immediately after a successful
    /// approval rather than waiting on the slow timer, so the row leaves the
    /// pane on the click and not ten minutes later.
    @Published private(set) var proposedEpics: [LibraryClient.Epic] = []
    @Published private(set) var proposedEpicsError: String?

    /// Every item of the current product's, any state and any type — the
    /// chip join's own source (`CockpitView.pullRequestWorkItemChips`,
    /// issue_01M3WPNJ1ESJVCVJ85FVNQHNKC), fetched alongside the Course and
    /// queue in `fetch` rather than resolved from whatever epics happen to
    /// be expanded this session. **Cleared to `[]` on a failed fetch, unlike
    /// `course`/`queue`, which keep showing their last good read** — a chip
    /// costs nothing when absent, so the join degrading to "no chips" is the
    /// per-field behaviour the item's own spec asks for, not a step down from
    /// what those two panels do for a real failure.
    @Published private(set) var allWorkItems: [LibraryClient.WorkItemRecord] = []
    /// The epic whose Approve is in flight, if any. Disables every row's
    /// button while one write is out, so two clicks cannot race one another.
    @Published private(set) var approvingEpicID: String?
    /// Why the last Approve did not land, kept with the epic it was for so the
    /// view can say it under that row. Cleared at the start of the next attempt.
    @Published private(set) var approvalRefusal: ApprovalRefusal?

    /// Whether a Course reorder write is out. Blocks a second drop until the
    /// first has settled, so no move is ever computed from a picture the
    /// previous one has already made stale.
    @Published private(set) var isReorderingCourse = false
    /// Why the last move did not land, in words for the Course panel; cleared
    /// at the start of the next attempt.
    @Published private(set) var courseReorderRefusal: String?

    struct ApprovalRefusal: Equatable {
        let epicID: String
        let message: String
    }

    /// A Course entry's own detail (`deck/bead/deck` §"The work") needs no
    /// fetch — `GET /courses/{id}` already resolved it. Its child work items
    /// are a second call, so expansion is tracked separately: which rows are
    /// open, and each open row's children, fetched once and cached.
    @Published private(set) var expandedEntries: Set<String> = []
    @Published private(set) var childrenByEntry: [String: ChildrenState] = [:]

    /// Whether the corrections queue is showing everything it fetched or only
    /// its top few (`CockpitView.queueRowLimit`). The rest were unreachable
    /// before this existed: the panel sliced them off and named no way to see
    /// them, so a queue of twelve looked like a queue of five.
    ///
    /// **`CockpitView`'s slice is over items ALREADY FETCHED, so expanding
    /// costs no round trip** — `GET /items?product=&state=open` returns the
    /// page whole and the panel was drawing five of it. Kept on the model
    /// rather than as view `@State` for the reason `expandedEntries` is: the
    /// slow-timer refresh replaces `queue` underneath the view, and a reader's
    /// expansion must survive that.
    ///
    /// `private(set)` behind `toggleQueueExpansion`, matching every other
    /// piece of mutable state on this model rather than being the one a view
    /// may assign to directly (`deck-reviewer`, PR #137). There is no side
    /// effect to own here today; the consistency is the point, so a later
    /// invariant has somewhere to live.
    @Published private(set) var isQueueExpanded = false

    /// Whether the Pull Requests panel's closed tier is showing every row
    /// in `PRLadder.closedWithinDays`'s window or only its top
    /// `PRLadder.recentClosedLimit` — `isQueueExpanded`'s own pattern,
    /// kept on the model for the same reason: the slow-timer refresh
    /// replaces `pullRequests` underneath the view, and a reader's
    /// expansion must survive that.
    @Published private(set) var isPullRequestsExpanded = false

    /// The child item a click on an issue id in the session pane asked the
    /// cockpit to point at, set by `reveal`. `CockpitView.childItemRow` reads
    /// it and fills the matching row with the tint the proposal card uses
    /// (`accentColor` at 8%), the cockpit's one existing highlight, and
    /// `CockpitView` scrolls that row into view. `nil` when nothing is being
    /// pointed at.
    ///
    /// Lives until the reader collapses that epic, the next `reveal` replaces
    /// it, or the cockpit follows a different project. No timer: a highlight
    /// that fades on its own is a second piece of visual vocabulary, and one
    /// that survives a stray refresh is what lets a reader find the row after
    /// looking away.
    @Published private(set) var highlightedItemID: String?

    /// Counts `reveal` successes. The view scrolls once per count, so a second
    /// click on an id that is already highlighted still brings its row back on
    /// screen, and a manual refresh (which empties and refills the children
    /// under an unchanged highlight) does not pull the reader back to it.
    @Published private(set) var revealCount = 0
    private var highlightedEpicID: String?

    /// The id a PR row's chip asked the Course or queue to scroll to
    /// (`revealFromPullRequestChip`) — an epic's own id for an `E` key, a
    /// correction's own id for a `CQ` key. `CockpitView.pullRequestWorkItemChips`
    /// already resolves which one a chip is from data this model already
    /// holds, so unlike `reveal(itemID:)` there is no parent to look up here.
    @Published private(set) var chipScrollID: String?
    /// Counts a chip scroll the same way `revealCount` counts a reveal, so a
    /// second click on the same chip still re-centers its row.
    @Published private(set) var chipScrollCount = 0

    enum ChildrenState: Equatable {
        case loading
        case loaded([LibraryClient.ChildItem])
        case failed(String)
    }

    /// Reads one item's product and parent — `GET /items/{id}`, the one
    /// route that answers both for an id Deck has not already listed. A
    /// stored closure for the reason `fetchChildItems` is: a test substitutes
    /// a fake, and can tell a fetch from a cache hit without an ssh round trip.
    var fetchItemPlacement: @Sendable (SSHTarget, String) throws -> LibraryClient.CorrectionDetail = { target, id in
        try LibraryClient.fetchCorrection(target: target, id: id)
    }

    /// The Course and queue reads `fetch` runs, stored for the reason
    /// `fetchChildItems` is. `reveal` decides from what these returned, and a
    /// test cannot seed `course` or `queue` any other way.
    var fetchCourse: @Sendable (SSHTarget, String) throws -> LibraryClient.Course? = { target, product in
        try LibraryClient.fetchCourse(target: target, product: product)
    }
    var fetchQueue: @Sendable (SSHTarget, String) throws -> LibraryClient.CorrectionsQueue = { target, product in
        try LibraryClient.fetchCorrectionsQueue(target: target, product: product)
    }
    /// The unfiltered epics read the Proposals region filters, and the write
    /// its Approve button makes. Stored closures for the same reason as the
    /// two above: a test substitutes a fake and never reaches ssh.
    var fetchEpics: @Sendable (SSHTarget, String) throws -> [LibraryClient.Epic] = { target, product in
        try LibraryClient.fetchEpics(target: target, product: product)
    }
    /// The chip join's own read, stored for the same reason as the three
    /// above: a test substitutes a fake and never reaches ssh.
    var fetchAllItems: @Sendable (SSHTarget, String) throws -> [LibraryClient.WorkItemRecord] = { target, product in
        try LibraryClient.fetchAllItems(target: target, product: product)
    }
    var approveEpic: @Sendable (SSHTarget, String, String) throws -> Void = { target, itemId, actingHuman in
        try LibraryClient.approveEpic(target: target, itemId: itemId, actingHuman: actingHuman)
    }

    /// The write a Course drop makes: `(target, courseId, version, entries)`.
    /// A stored closure for the reason `approveEpic` is.
    var reorderCourse: @Sendable (SSHTarget, String, Int, [String]) throws -> Void = { target, courseId, version, entries in
        try LibraryClient.reorderCourse(target: target, courseId: courseId, version: version, entries: entries)
    }

    /// Fetches one Course entry's children. A stored `@Sendable` closure,
    /// not a direct `LibraryClient.fetchChildItems` call, so a test can
    /// substitute a fake and tell a genuine re-fetch apart from a cache hit
    /// with no real ssh round trip — the same seam `RailStateModel.fetchStates`
    /// exists for (that type's own doc: "so a test can substitute a fake
    /// that is slow or that fails without a real ssh round trip"). Defaults
    /// to the real call.
    var fetchChildItems: @Sendable (SSHTarget, String) throws -> [LibraryClient.ChildItem] = { target, parentId in
        try LibraryClient.fetchChildItems(target: target, parentId: parentId)
    }

    /// The `(target, product)` this model last fetched for, so `refresh`
    /// called again for the same pair (the slow timer tick, a redundant
    /// selection-change callback) is a no-op rather than a second round trip.
    private var lastFetched: Key?
    private var timerTask: Task<Void, Never>?

    private struct Key: Equatable {
        let host: SSHTarget
        let product: String
    }

    /// How often the slow timer re-fetches while the cockpit stays on the
    /// same project. Selection changes fetch immediately regardless of this.
    static let refreshInterval = Duration.seconds(600)

    init() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: CockpitModel.refreshInterval)
                guard !Task.isCancelled, let self, let key = self.lastFetched else { continue }
                await self.fetch(target: key.host, product: key.product)
            }
        }
    }

    deinit {
        timerTask?.cancel()
    }

    /// Draws `course` without a Library read. The render tests use it to put
    /// the Course strip on a hosted window, which has no target to fetch from.
    func seedCourse(_ course: LibraryClient.Course?) {
        self.course = course
    }

    /// Points the model at a new project (or clears it). A `nil` product or
    /// target clears whatever was showing rather than leaving a stale read
    /// on screen for a session the cockpit no longer follows.
    func refresh(target: SSHTarget?, product: String?) async {
        guard let target, let product, !product.isEmpty else {
            lastFetched = nil
            course = nil
            courseError = nil
            queue = nil
            queueError = nil
            isLoading = false
            expandedEntries = []
            childrenByEntry = [:]
            clearHighlight()
            isQueueExpanded = false
            isPullRequestsExpanded = false
            proposedEpics = []
            proposedEpicsError = nil
            allWorkItems = []
            approvalRefusal = nil
            courseReorderRefusal = nil
            return
        }
        let key = Key(host: target, product: product)
        guard key != lastFetched else { return }
        lastFetched = key
        expandedEntries = []
        childrenByEntry = [:]
        clearHighlight()
        isQueueExpanded = false
        isPullRequestsExpanded = false
        approvalRefusal = nil
        courseReorderRefusal = nil
        await fetch(target: target, product: product)
    }

    /// Shows the whole corrections queue, or falls back to its top few.
    func toggleQueueExpansion() {
        isQueueExpanded.toggle()
    }

    /// Shows every closed Pull Requests row in the fetched window, or falls
    /// back to the top `PRLadder.recentClosedLimit`.
    func togglePullRequestsExpansion() {
        isPullRequestsExpanded.toggle()
    }

    /// Opens or closes one Course entry's row. Opening it for the first time
    /// kicks off a `fetchChildItems` call; a later toggle on the same id
    /// reads `childrenByEntry`'s cached entry instead of re-fetching — the
    /// cockpit's own slow-timer refresh (`fetch`, above) never touches this
    /// cache, so a reader's open row stays open and its children stay put
    /// across a poll tick.
    func toggleExpansion(for entryId: String) {
        if expandedEntries.contains(entryId) {
            expandedEntries.remove(entryId)
            if highlightedEpicID == entryId { clearHighlight() }
            return
        }
        expandedEntries.insert(entryId)
        guard childrenByEntry[entryId] == nil, let key = lastFetched else { return }
        childrenByEntry[entryId] = .loading
        Task { [weak self] in
            guard let self else { return }
            self.childrenByEntry[entryId] = await self.fetchedChildrenState(for: entryId, key: key)
        }
    }

    // MARK: - Reveal

    /// What `reveal` did, so the caller can fall back to the Item pane on
    /// `.notInCockpit` and a click always lands somewhere visible.
    enum RevealOutcome: Equatable {
        /// The item's epic is open in the Course and the item is highlighted.
        case revealed
        /// The cockpit has nothing to expand for this item. Every one of these
        /// is ordinary rather than an error: the item belongs to another
        /// project, has no parent, sits under an epic that is not a Course
        /// entry, or its epic is folded into a collapsed run the view owns.
        case notInCockpit
    }

    /// Expands the epic an item is filed under and highlights the item inside
    /// it. Navigation only, nothing is written.
    ///
    /// **THE PARENT IS RESOLVED ON CLICK, NEVER ON RENDER.** A long
    /// conversation names dozens of ids and a lookup per id would be dozens of
    /// ssh round trips for links nobody clicks. The answer is read from what
    /// the cockpit already holds first, in order of cost: the Course (an epic
    /// itself has nothing above it), the queue (it lists no item with a
    /// parent), the children of epics already expanded, then the queue read's
    /// `childParents`. Only an id none of those knows costs a request, and that
    /// request (`fetchItemPlacement`) is also what tells us the item's
    /// product, the one fact Deck cannot get from the id alone.
    ///
    /// A failed request degrades to `.notInCockpit` rather than throwing: the
    /// Item pane the caller opens next shows the same failure in words.
    func reveal(itemID: String) async -> RevealOutcome {
        guard let key = lastFetched, let course else { return .notInCockpit }
        guard let epicID = await parentEpicID(of: itemID, key: key) else { return .notInCockpit }
        // The project can change while the request above is in flight; a
        // highlight for the old project's item would land on the new one's rows.
        guard lastFetched == key, course.entries.contains(where: { $0.id == epicID }) else {
            return .notInCockpit
        }
        // An epic inside a collapsed run has no row to expand. Whether the
        // reader has unfolded that run is view state, so it is treated as
        // hidden either way and the caller opens the Item pane.
        let partition = CockpitView.coursePartition(course.entries)
        guard !partition.hiddenHead.contains(where: { $0.id == epicID }),
              !partition.hiddenTail.contains(where: { $0.id == epicID }) else {
            return .notInCockpit
        }
        if !expandedEntries.contains(epicID) {
            toggleExpansion(for: epicID)
        }
        highlightedItemID = itemID
        highlightedEpicID = epicID
        revealCount += 1
        return .revealed
    }

    /// Scrolls the Course panel to an epic, or the corrections queue to a
    /// correction — a PR row's chip, already resolved to one or the other by
    /// `CockpitView.pullRequestWorkItemChips`'s own join. Expands the queue
    /// first when the target sits outside `CockpitView.queueRowLimit`'s
    /// default slice, since a row the panel is not drawing yet has nothing
    /// for `scrollTo` to find; an epic hidden behind the Course's own
    /// collapsed head or tail run is not similarly expanded, matching
    /// `reveal(itemID:)`'s own "hidden stays hidden" posture for that case.
    /// A no-op for an id neither `course` nor `queue` currently holds.
    func revealFromPullRequestChip(itemID: String, isEpic: Bool) {
        if isEpic {
            guard course?.entries.contains(where: { $0.id == itemID }) == true else { return }
        } else {
            guard queue?.items.contains(where: { $0.id == itemID }) == true else { return }
            if !isQueueExpanded { isQueueExpanded = true }
        }
        chipScrollCount += 1
        chipScrollID = itemID
    }

    private func parentEpicID(of itemID: String, key: Key) async -> String? {
        if course?.entries.contains(where: { $0.id == itemID }) == true { return nil }
        if queue?.items.contains(where: { $0.id == itemID }) == true { return nil }
        for (epicID, state) in childrenByEntry {
            if case .loaded(let items) = state, items.contains(where: { $0.id == itemID }) {
                return epicID
            }
        }
        if let parent = queue?.childParents[itemID] { return parent }
        let placementFetch = fetchItemPlacement
        guard let detail = try? await Task.detached(operation: {
            try placementFetch(key.host, itemID)
        }).value else { return nil }
        guard detail.product == key.product else { return nil }
        return detail.parentId
    }

    private func clearHighlight() {
        highlightedItemID = nil
        highlightedEpicID = nil
        chipScrollID = nil
    }

    private func fetchedChildrenState(for entryId: String, key: Key) async -> ChildrenState {
        let childrenFetch = fetchChildItems
        do {
            let items = try await Task.detached {
                try childrenFetch(key.host, entryId)
            }.value
            return .loaded(items)
        } catch {
            return .failed("\(error)")
        }
    }

    /// The operator-triggered refresh `CockpitView`'s control and keyboard
    /// shortcut call. Re-fetches the Course, the corrections queue and
    /// proposed epics the same way the slow timer does, but — unlike the timer —
    /// also clears `childrenByEntry` and re-fetches every row still in
    /// `expandedEntries`, so an epic left open does not go on showing what it
    /// showed ten minutes ago (issue_01M1HVTD8QXXZF9ADZGRWRFEYW).
    ///
    /// Reads `lastFetched` directly rather than going through `refresh`,
    /// whose `key != lastFetched` guard is exactly what makes THIS call a
    /// no-op on the current selection — that guard exists so a redundant
    /// same-selection call (the `.task(id:)` firing again, the timer tick)
    /// costs nothing, but the operator asking for a refresh on the selection
    /// already showing is the entire point, so it must not go through the
    /// same door.
    func manualRefresh() async {
        guard let key = lastFetched else { return }
        await fetch(target: key.host, product: key.product)
        let expanded = expandedEntries
        childrenByEntry = [:]
        guard !expanded.isEmpty else { return }
        for entryId in expanded {
            childrenByEntry[entryId] = .loading
        }
        await withTaskGroup(of: (String, ChildrenState).self) { group in
            for entryId in expanded {
                group.addTask { [weak self] in
                    let state = await self?.fetchedChildrenState(for: entryId, key: key)
                    return (entryId, state ?? .failed("cockpit deallocated"))
                }
            }
            for await (entryId, state) in group {
                childrenByEntry[entryId] = state
            }
        }
    }

    /// Not `private` — `CockpitModelTests` calls this directly to exercise
    /// exactly what the slow timer runs (`init`'s `timerTask`, above) without
    /// waiting on `refreshInterval`, since that call is the "timer path"
    /// `testFetchNeverTouchesTheChildrenCache` pins.
    func fetch(target: SSHTarget, product: String) async {
        isLoading = true
        let courseRead = fetchCourse
        let queueRead = fetchQueue
        async let courseResult: Result<LibraryClient.Course?, Error> = Task.detached {
            do { return .success(try courseRead(target, product)) }
            catch { return .failure(error) }
        }.value
        async let queueResult: Result<LibraryClient.CorrectionsQueue, Error> = Task.detached {
            do { return .success(try queueRead(target, product)) }
            catch { return .failure(error) }
        }.value
        let epicsRead = fetchEpics
        async let epicsResult: Result<[LibraryClient.Epic], Error> = Task.detached {
            do { return .success(try epicsRead(target, product)) }
            catch { return .failure(error) }
        }.value
        let allItemsRead = fetchAllItems
        async let allItemsResult: Result<[LibraryClient.WorkItemRecord], Error> = Task.detached {
            do { return .success(try allItemsRead(target, product)) }
            catch { return .failure(error) }
        }.value

        switch await courseResult {
        case .success(let fetchedCourse):
            course = fetchedCourse
            courseError = nil
        case .failure(let error):
            courseError = "\(error)"
        }
        switch await queueResult {
        case .success(let fetchedQueue):
            queue = fetchedQueue
            queueError = nil
        case .failure(let error):
            queueError = "\(error)"
        }
        switch await epicsResult {
        case .success(let fetchedEpics):
            proposedEpics = LibraryClient.proposedEpics(from: fetchedEpics)
            proposedEpicsError = nil
        case .failure(let error):
            proposedEpicsError = "\(error)"
        }
        switch await allItemsResult {
        case .success(let fetchedItems):
            allWorkItems = fetchedItems
        case .failure:
            // Per-field degrade: a failed chip-join read draws no chips
            // rather than failing the panel (the item's own spec) — unlike
            // `courseError`/`queueError`/`proposedEpicsError` above, nothing
            // surfaces this failure in words, because nothing here has a
            // place to say "chips could not be read" without a false alarm
            // on a panel most of whose rows draw fine with none.
            allWorkItems = []
        }
        isLoading = false
    }

    // MARK: - Reordering the Course

    /// Moves one Course epic to where `targetId` sits and writes the new order.
    ///
    /// **THE WRITE IS BUILT FROM `servedEntryIds`, THE LIBRARY'S OWN ARRAY,
    /// NEVER FROM THE RENDERED ROWS.** The route replaces the whole order and
    /// the rows omit any id with no resolved item; see
    /// `LibraryClient.reorderedEntryIds`.
    ///
    /// **A STALE VERSION IS REFUSED, NOT REBASED.** The Library answers 409
    /// with its current order when someone else reordered since this Course
    /// was read. Replaying the operator's move onto that order could put the
    /// epic somewhere they did not intend while they believed they had placed
    /// it. The Course is re-read, so the panel shows the Library's order, and
    /// `courseReorderRefusal` says the move was not applied.
    ///
    /// The rows move at once, before the write returns, and are put back on
    /// any refusal. A successful write is followed by a Course re-read, which
    /// also brings back the version the next move must send.
    func moveCourseEntry(_ entryId: String, onto targetId: String) async {
        guard let key = lastFetched, let before = course, !isReorderingCourse else { return }
        courseReorderRefusal = nil
        guard let ordered = LibraryClient.reorderedEntryIds(
            before.servedEntryIds, moving: entryId, onto: targetId) else { return }
        guard let version = before.version else {
            courseReorderRefusal = "The Library did not report this Course's version, so it cannot be reordered safely."
            return
        }
        isReorderingCourse = true
        course = before.reordered(toServed: ordered)
        let write = reorderCourse
        do {
            try await Task.detached { try write(key.host, before.id, version, ordered) }.value
            await refetchCourse(key: key)
        } catch {
            guard lastFetched == key else { isReorderingCourse = false; return }
            course = before
            courseReorderRefusal = LibraryClient.reorderRefusalMessage(error)
            if LibraryClient.isStaleVersionRefusal(error), await refetchCourse(key: key) == false {
                // The refusal text says the order shown is the Library's, which
                // holds only if the re-read landed. `courseError` carries why it
                // did not.
                courseReorderRefusal = "Someone else reordered the Course, so your move was not applied. "
                    + "The order shown could not be refreshed, so it may not match the Library."
            }
        }
        isReorderingCourse = false
    }

    /// Re-reads the Course alone, for `moveCourseEntry`: the queue and epics
    /// reads `fetch` also makes are not what a reorder changed. Returns
    /// `false` when the read failed, so the caller can stop claiming the
    /// panel shows what the Library holds.
    @discardableResult
    private func refetchCourse(key: Key) async -> Bool {
        let read = fetchCourse
        do {
            let fresh = try await Task.detached { try read(key.host, key.product) }.value
            guard lastFetched == key else { return true }
            course = fresh
            courseError = nil
            return true
        } catch {
            guard lastFetched == key else { return true }
            courseError = "\(error)"
            return false
        }
    }

    // MARK: - Proposals

    /// Promotes a proposed epic to `approved` and places it on the product's
    /// live Course, then re-fetches, so the row leaves the region on the
    /// click. No agent runs and no lease is taken:
    /// `LibraryClient.approveEpic` writes through the Library's `/approve`
    /// route under Deck's own approval credential, which holds the epic for
    /// the one write when nobody else does.
    ///
    /// `acting_human` is `DeckOperator.label()` — the macOS session Deck is
    /// running in, the same label `deck/decisions/0001` already treats as
    /// honest for an `owner` write. It is the one fact Deck can attest
    /// without verifying it, and `platform/decisions/0087` rules that
    /// sufficient: any action by a Deck user is treated as the operator's.
    ///
    /// When it does not land, `approvalRefusal` says why in the Library's own
    /// words. The common case is an agent holding the epic, and that message
    /// names the holder and the expiry; an Approve that did nothing and said
    /// nothing would be worse than one that says who has it.
    ///
    /// The row stays when the write succeeds but the re-fetch fails. A second
    /// click then repeats a write that changes nothing, which the Library
    /// answers 200.
    func approve(_ epic: LibraryClient.Epic) async {
        guard let key = lastFetched, approvingEpicID == nil else { return }
        approvingEpicID = epic.id
        approvalRefusal = nil
        let write = approveEpic
        let actingHuman = DeckOperator.label()
        do {
            try await Task.detached { try write(key.host, epic.id, actingHuman) }.value
            await refetchProposedEpics(key: key)
        } catch {
            approvalRefusal = ApprovalRefusal(
                epicID: epic.id, message: LibraryClient.approvalRefusalMessage(error))
        }
        approvingEpicID = nil
    }

    private func refetchProposedEpics(key: Key) async {
        let read = fetchEpics
        do {
            let epics = try await Task.detached { try read(key.host, key.product) }.value
            proposedEpics = LibraryClient.proposedEpics(from: epics)
            proposedEpicsError = nil
        } catch {
            proposedEpicsError = "\(error)"
        }
    }
}
