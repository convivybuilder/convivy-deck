import Foundation

/// Deck's client for the Library reads that back the cockpit column: a
/// project's Course (with its epics resolved) and its corrections queue.
///
/// FOLLOWS `WorkingCopyStore`'s STOPGAP-TRANSPORT DISCIPLINE EXACTLY, for the
/// same reasons that file's header documents at length: curl over the
/// existing ssh ControlMaster (there is no direct URLSession path to the
/// mini anywhere in this codebase — the loopback port these requests hit is
/// loopback ON THE MINI, not on the laptop), `Library-Protocol: 1` required,
/// and the bearer token read into curl's config over stdin so it never
/// reaches curl's argv (and therefore `ps`) on the mini. This file adds no
/// new transport of its own; it reuses `WorkingCopyStore.libraryBaseURLExpression`
/// and `.libraryTokenFile` rather than re-deriving them, so the two clients
/// cannot drift on where the Library is or which credential reaches it.
///
/// **The three response shapes below were confirmed against the running
/// Library** (`curl` from this checkout, 2026-08-24) rather than guessed from
/// the contract prose alone — `platform/contracts/library-protocol` describes
/// the routes but not their exact JSON keys. `GET /courses?product=X` answers
/// `{"courses": [...], "count", "total", "offset", "truncated"}`;
/// `GET /courses/{id}` answers the same course with `entries` (an ordered
/// array of item ids) alongside `items` (the resolved objects, observed in
/// the same order as `entries` but not assumed to stay that way — see
/// `decodeCourse`); `GET /items?product=X&state=open` answers
/// `{"items": [...], "count", "total", "offset", "truncated"}`. Every decode
/// below degrades per field regardless, per Deck's standing contract
/// discipline, so a drift in a field this file does not read costs nothing.
enum LibraryClient {

    /// A terminal work-item outcome, shared by `CourseEntry.isCompleted` and
    /// `ChildItem.isCompleted` so an epic and a child under it read "passed"
    /// against the same vocabulary rather than two independently-chosen
    /// lists that could drift apart. `ITEM_RESOLUTIONS` is `{fixed, wontfix,
    /// duplicate, redirected}` (`library/store.py:552`); `redirected` was
    /// missing here, so a redirected item drew as still ahead rather than
    /// passed.
    static let terminalWorkStates: Set<String> = ["fixed", "wontfix", "duplicate", "redirected"]

    /// The word a claim's holder is described with, wherever one is
    /// rendered — shared by `claimStatusLine` and `claimMetaFragment` so the
    /// design choice below is made once, in one place, rather than risking
    /// the two render sites drifting on wording independently.
    ///
    /// **Reads "last held by" rather than "unclaimed" once a claim has
    /// lapsed — a deliberate choice, not the only one available.** The
    /// Library treats `claim_expired: true` as free to take (`issue_get`'s
    /// docstring), so reading a lapsed claim as simply unclaimed would be
    /// the more honest of the two options: it says exactly what an operator
    /// can do with the row. This file keeps the holder's name instead,
    /// because that name is itself informative — it is what let this bug's
    /// filer notice convivy-deck's own crew-stats epic was sitting on a
    /// claim from a session that had ended days earlier, rather than merely
    /// "free". Flip this one line to change the wording everywhere it draws.
    private static func claimVerb(expired: Bool) -> String {
        expired ? "last held by" : "claimed by"
    }

    /// `CockpitView`'s epic-detail line: `"Claimed by: agent-x"` for a live
    /// claim, `"Last held by: agent-x"` once `claim_expired` marks it
    /// lapsed. Pure and independent of any view, so the wording is testable
    /// from `LibraryClientTests` even though nothing in `DeckTests`
    /// instantiates `CockpitView` itself.
    static func claimStatusLine(claimedBy: String, expired: Bool) -> String {
        let verb = claimVerb(expired: expired)
        return "\(verb.prefix(1).uppercased())\(verb.dropFirst()): \(claimedBy)"
    }

    /// `ItemDetailPane`'s meta line: `"claimed by agent-x"` for a live claim,
    /// `"last held by agent-x"` once lapsed — lowercase, since it joins the
    /// rest of that line (`type · state · severity`) mid-sentence rather
    /// than standing as its own labeled row the way `claimStatusLine` does.
    /// Same word choice as `claimStatusLine`, via the shared `claimVerb`.
    static func claimMetaFragment(claimedBy: String, expired: Bool) -> String {
        "\(claimVerb(expired: expired)) \(claimedBy)"
    }

    enum FetchError: Error, Equatable {
        /// The response did not have the shape a 200 from this route should.
        case unexpectedResponse(String)
        /// The Library answered with a non-200 status.
        case libraryRefused(status: Int, body: String)
        /// A product name or Library id failed `validateLibraryProduct`/
        /// `validateLibraryId` before it could reach argv.
        case invalidInput(String)
        /// `acting_human` failed `validateActingHuman` before `approveEpic`
        /// built a request — carries the operator-facing reason directly,
        /// since there is no id or JSON body here to derive one from.
        case invalidActingHuman(String)
        /// A model or reason failed `itemModelBody`'s bounds before a request
        /// was built; carries the operator-facing reason.
        case invalidModelChoice(String)
    }

    // MARK: - Model

    struct Course: Equatable {
        let id: String
        let product: String?
        let title: String?
        /// In Course order (`entries`), not response order — see `decodeCourse`.
        ///
        /// **THESE ARE THE RENDERED ROWS, AND NOT NECESSARILY THE WHOLE
        /// COURSE.** `decodeCourse` drops any served id with no resolved item.
        /// Never build a write from this array; `servedEntryIds` is the one.
        let entries: [CourseEntry]
        /// The Library's own `version` for this Course, the token
        /// `PUT /courses/{id}/order` checks against. `nil` when the response
        /// carried none, which disables reordering rather than guessing one.
        let version: Int?
        /// `GET /courses/{id}`'s `entries`, verbatim: every id the Library
        /// holds in this Course's order, in order, resolved or not.
        ///
        /// **THE ONLY SAFE BASE FOR A REORDER.** The order route replaces the
        /// whole array, so a write built from `entries` above would delete
        /// every id `decodeCourse` dropped, with no error and nothing to undo
        /// it. `reorderedEntryIds` moves within this array instead.
        let servedEntryIds: [String]

        /// Explicit so the two fields added for reordering can default, which
        /// keeps every call site that predates them compiling. An omitted
        /// `servedEntryIds` reads as exactly the rendered rows, the right
        /// answer for a Course in which nothing was dropped.
        init(id: String, product: String?, title: String?, entries: [CourseEntry],
             version: Int? = nil, servedEntryIds: [String]? = nil) {
            self.id = id
            self.product = product
            self.title = title
            self.entries = entries
            self.version = version
            self.servedEntryIds = servedEntryIds ?? entries.map(\.id)
        }

        /// This Course drawn in `servedIds`' order: the rendered rows sorted
        /// by their position there, `version` untouched. It is the optimistic
        /// picture shown while a reorder is in flight; the write's own
        /// outcome then replaces it with the Library's truth.
        func reordered(toServed servedIds: [String]) -> Course {
            let position = Dictionary(servedIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let sorted = entries.enumerated().sorted {
                (position[$0.element.id] ?? Int.max, $0.offset) < (position[$1.element.id] ?? Int.max, $1.offset)
            }.map(\.element)
            return Course(id: id, product: product, title: title, entries: sorted,
                          version: version, servedEntryIds: servedIds)
        }
    }

    /// One entry in a work item's `prerequisites` array
    /// (`platform/decisions/0074-a-work-item-names-its-prerequisites-and-a-blocked-item-is-not-claimable`,
    /// entry shape settled on `issue_01M27E11MEH73Y66K7EEKPMAHN` comment
    /// 2261, which supersedes the issue body's "The field, as requested"
    /// section). Decoded once here and shared by `CourseEntry`, `ChildItem`,
    /// and `QueueItem` so the three surfaces that draw a "Needs first:"
    /// line cannot draw the three shapes three different ways.
    enum PrerequisiteEntry: Equatable {
        /// `{item, state, title}` — the reader can see the blocking item.
        /// `state` decides `CockpitView`'s strikethrough, via the same
        /// `LibraryClient.terminalWorkStates` every other row reads.
        case item(id: String, title: String, state: String?)
        /// `{item, missing: true}`, with no `state` or `title` — the same
        /// shape `GET /courses/{id}` gives an entry its reader cannot see.
        /// Comment 2261: "draw it as a blocker that can't be opened, and
        /// never drop it."
        case missingItem(id: String)
        /// `{text, met, judged_by, judged_at}` — a testable condition
        /// rather than another item.
        case text(text: String, met: Bool, judgedBy: String?, judgedAt: String?)
    }

    /// Decodes one item's `prerequisites` array, degrading per entry: a
    /// dict matching none of the three known shapes is dropped, never the
    /// whole row — the same "field costs itself" discipline every decoder
    /// in this file follows. An absent or non-array `prerequisites` decodes
    /// to `[]`.
    static func decodePrerequisites(_ raw: Any?) -> [PrerequisiteEntry] {
        guard let entries = raw as? [[String: Any]] else { return [] }
        return entries.compactMap { entry -> PrerequisiteEntry? in
            if let text = entry["text"] as? String {
                return .text(text: text, met: (entry["met"] as? Bool) ?? false,
                             judgedBy: entry["judged_by"] as? String,
                             judgedAt: entry["judged_at"] as? String)
            }
            guard let id = entry["item"] as? String else { return nil }
            if (entry["missing"] as? Bool) == true {
                return .missingItem(id: id)
            }
            guard let title = entry["title"] as? String else { return nil }
            return .item(id: id, title: title, state: entry["state"] as? String)
        }
    }

    struct CourseEntry: Equatable {
        let id: String
        let title: String
        /// The route label — what a waypoint says when the whole Course is
        /// drawn as a ribbon and a full title would not fit.
        ///
        /// **THE LIBRARY DOES NOT SERVE THIS FIELD YET**, so it is `nil` on
        /// every response today and `ribbonLabel` falls back to a condensed
        /// title. Decoded now rather than later so the ribbon improves the
        /// day the field lands, with no Deck release in the path — the same
        /// posture every other optional field in this file takes, applied to
        /// one that does not exist rather than to one that might go away.
        let shortDescription: String?
        let type: String?
        let state: String?
        let maturity: String?
        let resolution: String?
        /// The six fields below all arrive on the same `GET /courses/{id}`
        /// response that resolves `type`/`state`/`maturity`/`resolution` —
        /// the epic's own detail needs no second request.
        let body: String?
        let specification: String?
        let definitionOfDone: String?
        let severity: String?
        let needs: [String]
        let claimedBy: String?
        /// Whether `claimedBy`'s hold has lapsed — `GET /courses/{id}`'s own
        /// `claim_expired`. **Absent or explicit `null` decodes to `false`,
        /// not `true`**: those two shapes are what every response predating
        /// this field, and every response for an item nobody has claimed,
        /// look like, and reading either as "expired" would draw a claim
        /// nobody made as one that lapsed. Only a response that says so
        /// explicitly reads as expired — see `decodeCourse`.
        let claimExpired: Bool
        /// What this item is waiting on before it can be claimed —
        /// `platform/decisions/0074`. `GET /courses/{id}` carries this on
        /// every item; degrades to `[]` like every other optional here.
        let prerequisites: [PrerequisiteEntry]
        /// Computed by the Library at read time from `prerequisites`, and
        /// read here rather than recomputed from them — ADR-0074: "so Deck
        /// and the claimable query cannot disagree." Absent decodes to
        /// `false`, the same posture as every other bool field in this file.
        let blocked: Bool
        /// The stable key a PR row's chip carries — `"E9·4"` for a work item
        /// under an epic, `"E16"` for an epic with no child under it, `nil`
        /// when this Course predates the field or the Library never assigned
        /// one. Never the Course POSITION, which moves on every
        /// `course_set_order` — see issue_01M2P5D0D4EQEQX7BSRNFT5QGJ.
        let key: String?
        /// The pull request this item is waiting on, as the Library sends
        /// it — a STRING (`"297"`), never a number, confirmed against the
        /// running Library 2026-10-01. `nil` on every one of these three
        /// together exactly when there is no PR.
        let pr: String?
        let prURL: String?
        /// `"owner/repo"`, e.g. `"convivy/convivy-deck"` — the other half of
        /// `pr` that `PRLadder.LadderResult.identityKey` keys a row on.
        let prRepo: String?

        /// Explicit rather than the synthesized memberwise init, so the
        /// widened fields can default to absent/empty — a `let` with an
        /// inline default is excluded from the synthesized init entirely,
        /// which would silently drop every existing call site (including
        /// every test in `LibraryClientTests`) that predates them.
        init(id: String, title: String, shortDescription: String? = nil,
             type: String? = nil, state: String? = nil,
             maturity: String? = nil, resolution: String? = nil, body: String? = nil,
             specification: String? = nil, definitionOfDone: String? = nil, severity: String? = nil,
             needs: [String] = [], claimedBy: String? = nil, claimExpired: Bool = false,
             prerequisites: [PrerequisiteEntry] = [], blocked: Bool = false,
             key: String? = nil, pr: String? = nil, prURL: String? = nil, prRepo: String? = nil) {
            self.id = id
            self.title = title
            self.shortDescription = shortDescription
            self.type = type
            self.state = state
            self.maturity = maturity
            self.resolution = resolution
            self.body = body
            self.specification = specification
            self.definitionOfDone = definitionOfDone
            self.severity = severity
            self.needs = needs
            self.claimedBy = claimedBy
            self.claimExpired = claimExpired
            self.prerequisites = prerequisites
            self.blocked = blocked
            self.key = key
            self.pr = pr
            self.prURL = prURL
            self.prRepo = prRepo
        }

        /// `pr` parsed to an `Int`, or `nil` when it is absent or not a
        /// whole number — the form every row draws (`"PR #297"`), computed
        /// once here rather than at each of the several call sites that need
        /// it.
        var prNumber: Int? { pr.flatMap(Int.init) }

        /// A terminal outcome (library-protocol §6: `resolve` records
        /// `fixed`/`wontfix`/`duplicate`/`redirected`) draws as passed
        /// rather than ahead.
        var isCompleted: Bool {
            resolution != nil || LibraryClient.terminalWorkStates.contains(state ?? "")
        }

        /// Neither untouched (`open`, nobody has claimed it yet) nor closed —
        /// the one epic whose interior the cockpit expands inline, per
        /// `deck/bead/deck` §"The work": "the state of items in any epic
        /// that is not fully unstarted or closed."
        var isInProgress: Bool {
            guard let state, !isCompleted else { return false }
            return state != "open"
        }
    }

    struct CorrectionsQueue: Equatable {
        /// The merged set from every state in `queueStates`, however many
        /// pages each took.
        ///
        /// **IN THE LIBRARY'S OWN ARRIVAL ORDER — `fetchCorrectionsQueue`
        /// no longer sorts it.** Ordering it is `orderedQueueItems`'s job
        /// now, called once by whoever is about to draw the queue
        /// (`CockpitView.visibleQueueItems`), over this whole array, before
        /// any row cap — see that function's doc for why a caller changing
        /// the sort order needs no second fetch, and `queueRowLimit`'s own
        /// doc for why capping first would be wrong. `decodeCorrectionsQueue`,
        /// the single-page entry point `LibraryClientTests` drives directly,
        /// is the one exception: it still returns this field pre-sorted by
        /// `sortedQueueItems` (area order), because that is what its own
        /// tests, predating the sort control, assert against.
        let items: [QueueItem]
        /// `items.count` — what this fetch actually holds, after every drop
        /// it applies and every page it merged. Not any one page's envelope
        /// `total`, which counts what the Library returned on that call
        /// rather than what this panel shows; see `decodeCorrectionsQueue`
        /// and `fetchCorrectionsQueue`.
        let total: Int
        /// Whether this queue is known incomplete — `true` only when a state
        /// was still paged past `LibraryClient.itemsMaxPages` with the
        /// Library still answering `truncated: true`, meaning `items` (and
        /// therefore `total`) fall short of what the Library actually holds.
        /// `false` is the overwhelming common case: `fetchCorrectionsQueue`
        /// keeps paging a state until the Library itself says there is no
        /// more, so `total` is normally the true full count, not a guess at
        /// it. The panel must say so explicitly rather than presenting a
        /// short list as the whole queue — see `CockpitView.queueExpander`.
        let truncated: Bool
        /// Item id → its parent epic's id, for every item the queue read
        /// returned and `decodeQueueItemsPage` dropped because it has a parent.
        ///
        /// **`QueueItem` DOES NOT CARRY `parentId`, DELIBERATELY.** The queue is
        /// "not an epic and no parent epic", so by construction no `QueueItem`
        /// has one and the field would be nil on every row. The Library does
        /// return `parent_id` on this read; the rows that carry it are exactly
        /// the ones dropped from `items`, and this map keeps what the drop
        /// used to discard. It answers "which epic is this item under" for
        /// every unresolved child in the project (`queueStates`: `pr-open`,
        /// `open`, `claimed`) with no extra request, which is what
        /// `CockpitModel.reveal` reads before it falls back to a fetch.
        /// A resolved child is absent here, because the queue never asks for
        /// terminal states.
        let childParents: [String: String]
        /// The ids of this product's corrections queues, from
        /// `GET /corrections-queues?product=`. Empty against a Library that
        /// predates the route, where every correction's parent is null.
        ///
        /// **A PARENT IN THIS SET IS A CORRECTION'S HOME, NOT AN EPIC.** The
        /// Library's one-home plan (library/specs/one-home-per-work-item)
        /// stores the queue id as `parent_id` for every work item outside an
        /// epic. `decodeQueueItemsPage` keeps such an item in `items`, and
        /// `CockpitView.pullRequestWorkItemChips` draws its chip as the
        /// correction's own. A queue is recognised by this lookup only; the
        /// plan rules out reading the `cq_` prefix.
        var correctionsQueueIds: Set<String> = []
    }

    struct QueueItem: Equatable {
        let id: String
        let title: String
        let type: String?
        let severity: String?
        /// The Library's own state word, kept so the row can mark a
        /// `pr-open` item and the queue can sort it to the top. `nil` when a
        /// record omitted it, which draws as an ordinary row rather than
        /// guessing.
        let state: String?
        /// Who holds this item's claim — present only for a `state: claimed`
        /// row, since `.prOpen` and `.open` items are by definition
        /// unclaimed. Absent means not claimed, the same discipline
        /// `CourseEntry.claimExpired`'s doc describes.
        let claimedBy: String?
        /// Whether `claimedBy`'s hold has lapsed. Same absent/null-means-
        /// `false` discipline as `CourseEntry.claimExpired` — a lapsed claim
        /// is what makes a `claimed` row a free item that still reads as
        /// taken, which is the whole reason this queue draws the state at
        /// all (`.claimed` in `queueStates`).
        let claimExpired: Bool

        /// The area this item was filed under — `sortedQueueItems` groups
        /// the queue by this field, first element only, before ordering
        /// within a group by `isAwaitingPR`/`severity`. Empty for an item
        /// that carries none, the same absent-costs-nothing discipline as
        /// every other field here, and for a record from a Library that
        /// predates the field.
        let topics: [String]
        /// Same field, same degrade-per-item discipline as
        /// `CourseEntry.prerequisites` — see that field's doc.
        let prerequisites: [PrerequisiteEntry]
        /// Same field, computed by the Library and never recomputed here —
        /// see `CourseEntry.blocked`'s doc.
        let blocked: Bool
        /// The stable key a PR row's chip carries, `"CQ·63"` for a
        /// correction — see `CourseEntry.key`'s doc for the full vocabulary
        /// and why it is never the Course position.
        let key: String?
        /// Same three fields, same degrade discipline, as `CourseEntry.pr`/
        /// `.prURL`/`.prRepo`.
        let pr: String?
        let prURL: String?
        let prRepo: String?

        /// Whether this item is waiting on a pull request rather than on
        /// somebody starting it — the highest-priority thing in the queue,
        /// because the work is done and a person is the remaining step.
        var isAwaitingPR: Bool { state == "pr-open" }

        /// `pr` parsed to an `Int` — see `CourseEntry.prNumber`'s doc.
        var prNumber: Int? { pr.flatMap(Int.init) }

        /// Written out rather than left to the synthesized memberwise
        /// init, because a `let` property's default value is dropped from
        /// that synthesis entirely rather than becoming an overridable
        /// default parameter (confirmed against Swift 6.3 — `var` gets the
        /// override, `let` does not). `topics` defaults to `[]` so
        /// `CockpitViewTests`'s pre-existing `QueueItem(...)` call, which
        /// predates this field, keeps compiling unchanged.
        init(id: String, title: String, type: String? = nil, severity: String? = nil,
             state: String? = nil, claimedBy: String? = nil, claimExpired: Bool = false,
             topics: [String] = [], prerequisites: [PrerequisiteEntry] = [], blocked: Bool = false,
             key: String? = nil, pr: String? = nil, prURL: String? = nil, prRepo: String? = nil) {
            self.id = id
            self.title = title
            self.type = type
            self.severity = severity
            self.state = state
            self.claimedBy = claimedBy
            self.claimExpired = claimExpired
            self.topics = topics
            self.prerequisites = prerequisites
            self.blocked = blocked
            self.key = key
            self.pr = pr
            self.prURL = prURL
            self.prRepo = prRepo
        }
    }

    /// Lower sorts first. `critical` and `high` outrank `medium` and `low`;
    /// `nil` or an unrecognised word ranks last rather than crashing or
    /// getting dropped, the same per-field degrade discipline as everywhere
    /// else in this file — a severity word this client has never seen is not
    /// a reason to hide the row, only a reason not to claim it is urgent.
    ///
    /// **`critical` NEVER REACHES A REAL ROW** (steward, 2026-09-16,
    /// issue_01M2P9ZPBA5114PE875BHHT8NR): the Library's own
    /// `store.ITEM_SEVERITIES` is `{"high", "medium", "low"}`, and both
    /// write paths refuse anything else, so no queue item can ever carry
    /// it. Kept anyway rather than trimmed to match — it costs nothing and
    /// serves another surface — but it is not exercised by live data, and
    /// the vocabulary this ordering has to agree with Orient's `_SEVERITY_RANK`
    /// on is the three real words plus "unset" (a missing or unrecognised
    /// value), not four ranked words.
    private static let severityOrder: [String: Int] = [
        "critical": 0, "high": 1, "medium": 2, "low": 3,
    ]

    private static func severityRank(_ severity: String?) -> Int {
        guard let severity else { return severityOrder.count }
        return severityOrder[severity] ?? severityOrder.count
    }

    /// The corrections queue's three orderings — `orderedQueueItems`'s
    /// `order:` parameter, and `ThemeConfiguration.queueSortOrder`'s
    /// persisted choice. `.severity` is the default (the operator, 2026-09-16, in the
    /// steward session: "yeah let's just do severity sort for now").
    enum QueueSortOrder: String, CaseIterable, Equatable, Codable {
        case severity
        case area
        case arrival

        static let `default`: QueueSortOrder = .severity

        /// The label `CockpitView`'s sort control shows — centralised here
        /// for the same reason `claimVerb` centralises its own wording: one
        /// choice of words, not several call sites that could drift.
        var displayName: String {
            switch self {
            case .severity: return "Severity"
            case .area: return "Area"
            case .arrival: return "Arrival"
            }
        }
    }

    /// One work item filed under an epic — `GET /items?parent_id={epic id}`.
    /// The fleet has filed none of these yet (measured 2026-08-25: 0 of 50
    /// items across five products carry a `parent_id`), so an empty result
    /// is the expected steady state, not a sign the fetch went wrong.
    struct ChildItem: Equatable {
        let id: String
        let title: String
        let type: String?
        let state: String?

        /// The epic this item is filed under, carried so the DECODER can check
        /// the server filtered the way it was asked to — see
        /// `decodeChildItems`. Optional because the field degrades like every
        /// other one here; an item that does not carry it cannot be confirmed
        /// as this epic's child and is dropped rather than shown.
        let parentId: String?
        /// Same field, same degrade-per-item discipline as
        /// `CourseEntry.prerequisites` — see that field's doc. `GET
        /// /items?parent_id=` returns it on every item.
        let prerequisites: [PrerequisiteEntry]
        /// Same field, computed by the Library and never recomputed here —
        /// see `CourseEntry.blocked`'s doc.
        let blocked: Bool
        /// The stable key a PR row's chip carries, `"E9·4"` for a work item
        /// filed under this child's own epic — see `CourseEntry.key`'s doc.
        let key: String?
        /// Same three fields, same degrade discipline, as `CourseEntry.pr`/
        /// `.prURL`/`.prRepo`.
        let pr: String?
        let prURL: String?
        let prRepo: String?

        /// `pr` parsed to an `Int` — see `CourseEntry.prNumber`'s doc.
        var prNumber: Int? { pr.flatMap(Int.init) }

        /// Explicit rather than the synthesized memberwise init, so
        /// `prerequisites` and `blocked` default to absent and every
        /// existing call site (including `LibraryClientTests`) that
        /// predates them keeps compiling.
        init(id: String, title: String, type: String? = nil, state: String? = nil,
             parentId: String? = nil,
             prerequisites: [PrerequisiteEntry] = [], blocked: Bool = false,
             key: String? = nil, pr: String? = nil, prURL: String? = nil, prRepo: String? = nil) {
            self.id = id
            self.title = title
            self.type = type
            self.state = state
            self.parentId = parentId
            self.prerequisites = prerequisites
            self.blocked = blocked
            self.key = key
            self.pr = pr
            self.prURL = prURL
            self.prRepo = prRepo
        }

        /// Same terminal-state vocabulary `CourseEntry.isCompleted` reads —
        /// "passed" is meant to look the same one level down as it does on
        /// the Course itself. `ChildItem` carries no `resolution` field (the
        /// Course response resolves that for an epic; `GET /items?parent_id=`
        /// does not), so `state` alone decides it.
        var isCompleted: Bool {
            LibraryClient.terminalWorkStates.contains(state ?? "")
        }
    }

    /// One item whose `found_during` names a given epic — `GET
    /// /items?found_during={epic_id}`, confirmed by the Library on 2026-09-24
    /// (comment thread on issue_01M3BFMY1SWA4M4H6M1JHZZRTE): every state, no
    /// `state=` filter, so the open/closed split happens client-side
    /// (`isCompleted`, `openFoundDuringItems`) — the same split `ChildItem`
    /// makes for `parent_id`.
    struct FoundDuringItem: Equatable, Identifiable {
        let id: String
        let title: String
        let state: String?

        /// Same terminal-state vocabulary as `ChildItem.isCompleted` — see
        /// that property's doc.
        var isCompleted: Bool {
            LibraryClient.terminalWorkStates.contains(state ?? "")
        }
    }

    /// The open items found during an epic — every entry `isCompleted`
    /// excludes, the filter `ItemDetailPane`'s epic section draws from. Pure
    /// so it is testable without a view.
    static func openFoundDuringItems(_ items: [FoundDuringItem]) -> [FoundDuringItem] {
        items.filter { !$0.isCompleted }
    }

    /// One row of `GET /items?product=X&limit=200` with no `state` filter —
    /// every item of every state and type, fetched for
    /// `CockpitView.pullRequestWorkItemChips`'s own join
    /// (issue_01M3WPNJ1ESJVCVJ85FVNQHNKC). Unlike `ChildItem`, nothing here
    /// filters on `parentId`: the chip join reads it directly to tell a
    /// filed item from a top-level one.
    struct WorkItemRecord: Equatable {
        let id: String
        let title: String
        /// `"epic"` for an epic, so the join can route a parent-less item's
        /// own chip to the Course rather than the corrections queue — see
        /// `CockpitView.pullRequestWorkItemChips`.
        let type: String?
        let parentId: String?
        /// The stable key a PR row's chip carries — see `CourseEntry.key`'s
        /// doc for the full vocabulary.
        let key: String?
        /// Same three fields, same degrade discipline, as `CourseEntry.pr`/
        /// `.prURL`/`.prRepo`.
        let pr: String?
        let prURL: String?
        let prRepo: String?

        init(id: String, title: String, type: String? = nil, parentId: String? = nil,
             key: String? = nil, pr: String? = nil, prURL: String? = nil, prRepo: String? = nil) {
            self.id = id
            self.title = title
            self.type = type
            self.parentId = parentId
            self.key = key
            self.pr = pr
            self.prURL = prURL
            self.prRepo = prRepo
        }
    }

    /// One comment on a correction's thread — `GET /items/{id}`'s `comments[]`,
    /// confirmed against the running Library 2026-08-25 (`actor`, `kind`,
    /// `body`, `run_id`, `at`, plus the row `id`).
    /// Every field degrades independently, same discipline as everywhere else
    /// in this file — a malformed comment draws as a blank line rather than
    /// dropping the whole thread.
    struct CorrectionComment: Equatable {
        let id: Int?
        let actor: String?
        let kind: String?
        let body: String?
        let at: String?
    }

    /// An item's `model_choice` (`platform/contracts/library-protocol` §6.2),
    /// as `GET /items/{id}` returns it.
    ///
    /// **WHAT IT ATTESTS.** `setByClient` comes from the credential that
    /// called the reserved route, so the Library guarantees it. `actingHuman`
    /// is the string that client reported, stored and never verified, so
    /// nothing here or in `modelChoiceLines` may call it verified.
    ///
    /// Every field degrades alone. `decodeModelChoice` keeps a non-empty
    /// record that lacks `model` (the Bosun refuses to dispatch on one, so it
    /// is a state worth drawing) and marks it `isMalformed`.
    struct ModelChoice: Equatable {
        var model: String?
        var reason: String?
        var setByClient: String?
        var actingHuman: String?
        var setAt: String?

        var isMalformed: Bool { (model ?? "").isEmpty }
    }

    /// The full detail behind one corrections-queue row — `GET /items/{id}`.
    /// **Carries the full body AND the comment thread** (library-protocol
    /// §3.1); the list route the queue panel uses deliberately does not, which
    /// is why this pane needs its own fetch rather than reading `QueueItem`.
    /// Confirmed against the running Library 2026-08-25 (see the probe
    /// comment left on `issue_01KZHR0X9ZHGVXESA1E08AEE6J`, convivy-deck's own
    /// queue). Every field but `id` degrades independently.
    struct CorrectionDetail: Equatable {
        let id: String
        let title: String?
        /// The product this item is filed against.
        ///
        /// **Load-bearing rather than decorative.** An item reaches this pane
        /// two ways now: from the cockpit's own corrections queue, where the
        /// product is the selected crew's and the reader already knows it; or
        /// from a `deck-open:?origin=item` link, which can carry an item from
        /// ANY product the token can see. In the second case the product is
        /// the fact that makes the item legible at all (the operator, 2026-08-26:
        /// "along with info like whose project its filed against").
        let product: String?
        let body: String?
        let type: String?
        let state: String?
        let severity: String?
        /// Who the item is waiting on — `"agent"` or `"operator"` in
        /// practice — a string field on the wire, not the array `needs`
        /// takes on a Course entry's approval-gate list.
        let needs: String?
        let resolution: String?
        let outcomeNote: String?
        let claimedBy: String?
        /// Same field, same absent/null-means-not-expired discipline as
        /// `CourseEntry.claimExpired` — see that field's doc.
        let claimExpired: Bool
        let createdAt: String?
        let parentId: String?
        /// The epic whose work turned this item up — distinct from `parentId`,
        /// which files an item INTO the plan under an epic. `found_during`
        /// instead names the epic a cleanup crew will revisit this item
        /// under once that epic closes (the steward's epic
        /// issue_01M3BFKEZD4WA70EWAK5TPZMMC). Confirmed served on `GET
        /// /items/{id}` by the Library, 2026-09-24 (comment thread on
        /// issue_01M3BFMY1SWA4M4H6M1JHZZRTE): `null` when unset, which
        /// degrades to `nil` here like every other optional field. Does not
        /// affect `decodeQueueItemsPage`'s corrections-lane rule, which reads
        /// only `type` and `parentId`.
        let foundDuring: String?
        /// An epic's specification and definition of done, both Markdown, the
        /// latter a bullet list. Confirmed on the wire 2026-09-21 by calling
        /// `GET /items/issue_01M32CC86M0NX5YNG2FX0TK4GW`: both are root keys.
        /// Absent or null on every correction and most work items, which the
        /// pane draws as no heading at all.
        let specification: String?
        let definitionOfDone: String?
        /// The operator's model choice, or `nil` for none.
        let modelChoice: ModelChoice?
        let comments: [CorrectionComment]

        /// Explicit rather than the synthesized memberwise init, for the same
        /// reason `CourseEntry`'s is: a `let` with an inline default is
        /// EXCLUDED from a synthesized init entirely rather than merely
        /// defaulted (confirmed against the compiler — a caller cannot pass a
        /// value for such a property at all), which would leave
        /// `decodeCorrectionDetail` no way to ever set `claimExpired` to
        /// `true`. Defaulting it here instead keeps every existing call site
        /// (including `ItemDetailPaneTests`'s) compiling unchanged while
        /// still letting the decoder pass a real value.
        init(id: String, title: String? = nil, product: String? = nil, body: String? = nil,
             type: String? = nil, state: String? = nil, severity: String? = nil, needs: String? = nil,
             resolution: String? = nil, outcomeNote: String? = nil, claimedBy: String? = nil,
             claimExpired: Bool = false, createdAt: String? = nil, parentId: String? = nil,
             foundDuring: String? = nil,
             specification: String? = nil, definitionOfDone: String? = nil,
             modelChoice: ModelChoice? = nil,
             comments: [CorrectionComment] = []) {
            self.id = id
            self.title = title
            self.product = product
            self.body = body
            self.type = type
            self.state = state
            self.severity = severity
            self.needs = needs
            self.resolution = resolution
            self.outcomeNote = outcomeNote
            self.claimedBy = claimedBy
            self.claimExpired = claimExpired
            self.createdAt = createdAt
            self.parentId = parentId
            self.foundDuring = foundDuring
            self.specification = specification
            self.definitionOfDone = definitionOfDone
            self.modelChoice = modelChoice
            self.comments = comments
        }
    }

    /// One epic from `GET /items?product=X&type=epic` — every epic of every
    /// state, not only the open ones `itemsRemoteCommand` filters to. The
    /// rail's bead-progress pane (`BeadProgress.compute`) needs a closed
    /// epic's `resolvedAt` and every epic's `createdAt` to score them
    /// against the bead's last revision, neither of which `CourseEntry`
    /// carries — that decoder resolves a Course's live entries only, via a
    /// different route (`GET /courses/{id}`), and was never asked to keep
    /// dates.
    ///
    /// `title`, `maturity` and `specification` are what the Proposals region
    /// reads (`proposedEpics(from:)`). All three degrade to `nil` like every
    /// other field here.
    struct Epic: Equatable, Identifiable {
        let id: String
        let state: String?
        let resolution: String?
        let createdAt: String?
        let resolvedAt: String?
        let title: String?
        let maturity: String?
        let specification: String?

        /// Written out for the reason `QueueItem.init` is: a synthesized
        /// memberwise init would make `title`, `maturity` and `specification`
        /// required arguments, and the bead-progress tests build epics with
        /// none of them.
        init(id: String, state: String?, resolution: String?, createdAt: String?,
             resolvedAt: String?, title: String? = nil, maturity: String? = nil,
             specification: String? = nil) {
            self.id = id
            self.state = state
            self.resolution = resolution
            self.createdAt = createdAt
            self.resolvedAt = resolvedAt
            self.title = title
            self.maturity = maturity
            self.specification = specification
        }

        /// A terminal outcome under any resolution, the same vocabulary
        /// `CourseEntry.isCompleted` reads. `resolution != nil` covers every
        /// named outcome; `state` is the fallback for an item whose
        /// resolution field went missing but whose state still says it
        /// settled.
        var isResolved: Bool {
            resolution != nil || LibraryClient.terminalWorkStates.contains(state ?? "")
        }
    }

    /// The Library's `ITEM_MATURITIES` words this file names
    /// (`store.py`: `proposed`, `approved`, `built`, `superseded`).
    static let proposedMaturity = "proposed"
    static let approvedMaturity = "approved"

    /// The epics the Proposals region draws. A filter over the epics
    /// `fetchEpics` already returns, so no route asks the Library for it
    /// (`/items` has no `maturity` parameter). Mirrors Orient's own
    /// `put_forward()` (convivy-orient, `issue_build.py`) exactly, so the two
    /// surfaces that offer an epic for Approve agree on which ones qualify:
    /// an epic is a proposal when its trimmed `maturity` reads `proposed`, or
    /// when `maturity` is empty (after trimming) and `specification` is
    /// non-empty (after trimming). The second branch exists because
    /// `POST /items` has never accepted a `maturity` field, so every epic the
    /// Library creates starts with none — an unset maturity is not "nobody
    /// has assessed this," it is the Library's universal default, and a
    /// written specification is what distinguishes a real proposal from a
    /// stub.
    ///
    /// **A resolved epic never draws even when it would otherwise qualify.**
    /// The Library refuses a correction on a terminal item with a 409, so an
    /// Approve on one could only fail.
    static func proposedEpics(from epics: [Epic]) -> [Epic] {
        epics.filter { epic in
            guard !epic.isResolved else { return false }
            let maturity = (epic.maturity ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if maturity == proposedMaturity { return true }
            let specification = (epic.specification ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return maturity.isEmpty && !specification.isEmpty
        }
    }

    /// One bead doc from `GET /reference/documents?kind=bead` — the listing
    /// `SessionsSettingsView`'s bead picker reads so a crew's bead is picked
    /// rather than guessed from its `project` (the two are different naming
    /// spaces; see `ContentView.selectedCrewBeadId`). `product` is the
    /// Library product the bead belongs to, degraded independently the same
    /// way every other optional field in this file is — a listing row with
    /// no resolvable product still shows its id.
    struct BeadDocument: Identifiable, Equatable {
        let id: String
        let product: String?
    }

    // MARK: - Input validation

    /// The charset every Library-bound identifier in this file is restricted
    /// to before it reaches a remote curl command. `Crew.project` is a
    /// Deck-config-sourced string (the same trust level as `Crew.host`) and a
    /// Course/item id comes back from the Library's own JSON — both reach a
    /// query string embedded UNQUOTED inside a double-quoted URL the same way
    /// `WorkingCopyStore.libraryDocumentRemoteCommand`'s `kbId` does.
    /// Restricting the charset up front removes injection as a possibility
    /// rather than relying on quoting it correctly — see that function's doc
    /// for why single-quoting is not available here (the whole command is one
    /// double-quoted string so `${LIBRARY_BASE_URL:-…}` still expands).
    private static let allowedIdentifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// A Library product name (`convivy-deck`, `bosun`, …) — `Crew.project`.
    static func validateLibraryProduct(_ name: String) -> String? {
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy(allowedIdentifierCharacters.contains) else { return nil }
        return name
    }

    /// A Library id (`course_...`, `issue_...`), read back from the
    /// Library's own JSON rather than typed by an operator — validated
    /// anyway, since it is about to reach the same unquoted URL a
    /// config-sourced string does, and a response is not a trusted input
    /// merely because it came from the service Deck is about to re-query.
    static func validateLibraryId(_ id: String) -> String? {
        guard !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy(allowedIdentifierCharacters.contains) else { return nil }
        return id
    }

    /// One segment of a GitHub `owner/repo` pair (`convivy`, `convivy-deck`) —
    /// the same charset and length rule as `validateLibraryProduct`, reused
    /// rather than duplicated since a repo segment is exactly as
    /// identifier-shaped. `PRLadder`'s remote commands compose the `owner/repo`
    /// and `github:owner/repo` strings from two separately-validated segments
    /// rather than validating a single slash-bearing string, so this charset
    /// stays the one every other Library-bound identifier in this file uses.
    static func validateRepoSegment(_ segment: String) -> String? {
        validateLibraryProduct(segment)
    }

    /// A whole `owner/repo` identity (`Crew.repo`'s own stored shape),
    /// split into the two segments `PRLadder.fetchLadder` wants — `nil`
    /// unless the string is exactly two non-empty segments and both clear
    /// `validateRepoSegment`. A third slash, a leading/trailing one, or
    /// either segment failing the charset all refuse the whole identity
    /// rather than guessing which half was meant.
    static func validateRepoIdentity(_ identity: String) -> (owner: String, repoName: String)? {
        let segments = identity.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2,
              let owner = validateRepoSegment(String(segments[0])),
              let repoName = validateRepoSegment(String(segments[1])) else { return nil }
        return (owner, repoName)
    }

    // MARK: - Remote commands

    /// The curl template every Library GET in this file shares — protocol
    /// header, no `-f` (a 4xx/5xx is the Library answering, not a transport
    /// failure, and the caller needs the status to tell those apart), and the
    /// bearer token read from stdin rather than argv. Mirrors
    /// `WorkingCopyStore.libraryDocumentRemoteCommand` exactly; see that
    /// function's doc for why each piece is shaped the way it is.
    ///
    /// `tokenFile` defaults to `WorkingCopyStore.libraryTokenFile`; the one
    /// caller that reads a different credential (`whoamiRemoteCommand`, the
    /// approval-credential actor check) passes
    /// `WorkingCopyStore.libraryApprovalTokenFile` explicitly.
    private static func remoteGETCommand(path: String, tokenFile: String = WorkingCopyStore.libraryTokenFile) -> String {
        "curl -sS -w '\\n%{http_code}' " +
        "-H 'Library-Protocol: 1' " +
        "--config - " +
        "\"\(WorkingCopyStore.libraryBaseURLExpression)\(path)\" " +
        "<<EOF\n" +
        "header = \"Authorization: Bearer $(cat \(tokenFile) 2>/dev/null)\"\n" +
        "EOF"
    }

    /// `product` reaches this unvalidated at the call site's discretion — every
    /// caller in this file validates first via `validateLibraryProduct`, so
    /// this stays a pure string composer or its result reaches curl unsafely.
    static func coursesListRemoteCommand(product: String) -> String {
        remoteGETCommand(path: "/courses?product=\(product)")
    }

    static func courseRemoteCommand(courseId: String) -> String {
        remoteGETCommand(path: "/courses/\(courseId)")
    }

    /// **ONE STATE PER CALL, AND `state=open,pr-open` IS A TRAP.** Measured
    /// against the running Library on 2026-09-04: the comma form returns
    /// **HTTP 200 with an empty `items` array**, not an error — so a caller
    /// that checks the status code sees success and draws an empty queue.
    /// `state=open` returned 50 and `state=pr-open` returned 7 in the same
    /// minute, so both single values are honoured and only the join is not.
    ///
    /// Dropping `state=` entirely is not the way round it either: that
    /// response is capped at 50 items and includes `fixed` and `wontfix`, so
    /// on a busy product the closed items push the open ones off the page.
    ///
    /// So the queue issues one call per state and merges
    /// (`fetchCorrectionsQueue`).
    ///
    /// **`limit`/`offset` EXIST BECAUSE THE LIBRARY'S DEFAULT PAGE IS 50, AND
    /// THIS ROUTE NEVER SAID SO** (`issue_01M1STN4AB0JQ7YJ1ETJTBR370`). Before
    /// this, the queue asked for neither and silently took the Library's
    /// default page, so a product past 50 open items in one state showed a
    /// subset with nothing indicating the rest — measured against the
    /// running Library: `vivy`'s `state=open` answered 50 of 176 with
    /// `truncated: true`, and the queue never looked. `fetchCorrectionsQueue`
    /// pages while the envelope keeps saying `truncated: true`, so `limit`
    /// only bounds one call's size, never the queue's total.
    ///
    /// **A TYPE RATHER THAN A VALIDATED STRING** (`deck-security-reviewer`,
    /// PR #178). `product` reaches this URL through
    /// `validateLibraryProduct`, and `validateLibraryId`'s own doc states the
    /// standard: a value is gated "since it is about to reach the same
    /// unquoted URL a config-sourced string does". `state` arrived as a bare
    /// `String` with neither a gate nor a reason, safe only because today's
    /// one caller passes constants — which is exactly the assumption a future
    /// caller passing a variable breaks silently.
    ///
    /// An enum's `rawValue` cannot carry a shell metacharacter or a `&`, so
    /// there is no validation call left to forget. `limit`/`offset` are
    /// `Int`, so neither can carry one either.
    ///
    /// **`sort=topic` IS PASSED EVEN THOUGH IT CANNOT ORDER THE QUEUE ON ITS
    /// OWN** (`issue_01M2298XAXW03K3GAF2FJ144J6`). `fetchCorrectionsQueue`
    /// fetches several pages across three states and merges them, so the
    /// only sort that can be correct — for area order — is `sortedQueueItems`
    /// (via `orderedQueueItems`) running once over that whole merged set — a
    /// server-side sort governs one state's one page and cannot see the
    /// other two states or the other pages. It is
    /// requested anyway so a topic's items land in adjacent pages rather
    /// than being scattered across the fetch by the Library's default
    /// (newest-first) order: if paging ever stops short of a full state
    /// (`pagedQueueItems` gives up at `itemsMaxPages`), what gets cut is
    /// whole topics not yet reached, not a topic sliced in half across the
    /// boundary.
    static func itemsRemoteCommand(
        product: String, state: QueueState, limit: Int = itemsPageLimit, offset: Int = 0
    ) -> String {
        remoteGETCommand(path: "/items?product=\(product)&state=\(state.rawValue)&limit=\(limit)&offset=\(offset)&sort=topic")
    }

    /// `product`'s corrections queues — see `CorrectionsQueue.correctionsQueueIds`.
    /// `product` is validated by the caller, as for `itemsRemoteCommand`.
    static func correctionsQueuesRemoteCommand(product: String) -> String {
        remoteGETCommand(path: "/corrections-queues?product=\(product)")
    }

    /// The page size every corrections-queue request asks for. Large enough
    /// that a normal product's queue completes in one page per state —
    /// measured against the running Library: `vivy`'s 176 open items came
    /// back whole, `truncated: false`, at `limit=200` — while
    /// `fetchCorrectionsQueue` still pages past it via `offset` for whatever
    /// product eventually exceeds it, rather than this number being load-
    /// bearing for correctness.
    static let itemsPageLimit = 200

    /// How many pages `fetchCorrectionsQueue` asks for, per state, before
    /// giving up and reporting the queue `truncated` rather than looping
    /// forever against a server that never stops saying `truncated: true`.
    /// `itemsPageLimit * itemsMaxPages` is 5,000 items in one state — far
    /// past anything a real product has filed as of this write.
    static let itemsMaxPages = 25

    /// The states the corrections queue draws, in the order it draws them.
    ///
    /// **THE QUEUE MEANS "NOT FINISHED", NOT "NOT STARTED"** (the operator,
    /// 2026-09-04). It asked the Library for `state=open` alone, so an item
    /// moving to `pr-open` vanished from the panel at the moment it became
    /// the thing most likely to need a person — its PR is open and waiting on
    /// a merge. The operator hit this with a cancelled-reservation bug that
    /// disappeared when its coder linked a PR, and nothing in the panel said
    /// anything had been filtered.
    ///
    /// **`.claimed` joined for the same reason `.prOpen` did**
    /// (`issue_01M1Y7AKMRQ4S7K9CX5R99ZMPQ`): a claim expires without the
    /// Library ever changing the item's `state`, so a claimed item whose
    /// worker died sat in `claimed` invisibly — not in this queue (wrong
    /// state) and not under an epic (no parent). Measured against the
    /// running Library: eleven standalone claimed items across four
    /// products, ten of them with a lapsed claim and free to take, none of
    /// them drawn anywhere. `.claimed` rows sort with `.open`'s, not as a
    /// third tier — see `sortedQueueItems`.
    static let queueStates: [QueueState] = [.prOpen, .open, .claimed]

    /// The item states the corrections queue may ask the Library for. Closed
    /// as a type so no other value can reach the URL — see
    /// `itemsRemoteCommand`.
    enum QueueState: String {
        case prOpen = "pr-open"
        case open
        case claimed
    }

    /// **NO `state=` PARAMETER**, unlike `itemsRemoteCommand` — the
    /// denominator in `BeadProgress.compute` needs every epic ever filed,
    /// resolved or not, so omitting the filter (rather than passing
    /// `state=` empty, which the Library's handler might read as "match
    /// nothing") is what makes the server return all of them. `product`
    /// reaches this unvalidated at the call site's discretion, same as
    /// `itemsRemoteCommand` — `fetchEpics` is the only caller and validates
    /// first via `validateLibraryProduct`.
    static func epicsRemoteCommand(product: String) -> String {
        remoteGETCommand(path: "/items?product=\(product)&type=epic")
    }

    /// **NO `state=` PARAMETER, SAME REASON AS `epicsRemoteCommand`** — every
    /// item of every state and type, for `CockpitView.pullRequestWorkItemChips`'s
    /// own join (issue_01M3WPNJ1ESJVCVJ85FVNQHNKC). `limit=200` is the
    /// Library's own page cap (§3 of the contract: a larger value is clamped,
    /// not refused), and this route is deliberately ONE CALL, never paged the
    /// way `fetchCorrectionsQueue` pages — a chip is a nice-to-have that
    /// degrades to absent, not a count a panel must get exactly right, so a
    /// product past 200 items loses chips for whichever rows the Library's
    /// own ordering pushes past the page rather than costing a second round
    /// trip. `product` reaches this unvalidated at the call site's
    /// discretion, same as `epicsRemoteCommand` — `fetchAllItems` is the only
    /// caller and validates first via `validateLibraryProduct`.
    static func allItemsRemoteCommand(product: String, limit: Int = itemsPageLimit) -> String {
        remoteGETCommand(path: "/items?product=\(product)&limit=\(limit)")
    }

    /// `GET /signals/pr-state?repo=owner/repo&closed_within_days=N`, paged —
    /// the latest `pr_state` row per pull request, which the Library
    /// computes so no client has to collapse the raw one-row-per-transition
    /// signals itself. Requires `Library-Protocol` like every other read
    /// here; `remoteGETCommand` sends it.
    ///
    /// `closedWithinDays` bounds CLOSED and MERGED PRs only; every PR whose
    /// latest state is `OPEN` is returned at any age. `repo` is applied by
    /// the Library before it ranks each PR's rows, and `PRLadder.fetchLadder`
    /// still checks every page against it (see `PRLadder.repoConsistency`).
    /// `owner`/`repoName` and the integers reach this unvalidated at the
    /// call site's discretion, same as every other builder here —
    /// `PRLadder.fetchLadder` is the only caller and validates first via
    /// `validateRepoSegment`.
    static func latestPRStatesRemoteCommand(
        owner: String, repoName: String, closedWithinDays: Int, limit: Int, offset: Int
    ) -> String {
        remoteGETCommand(
            path: "/signals/pr-state?repo=\(owner)/\(repoName)&closed_within_days=\(closedWithinDays)" +
                  "&limit=\(limit)&offset=\(offset)")
    }

    /// `GET /review-records?repo_identity=github:owner/repo`, paged, and
    /// narrowed to one pull request when `pr` is given. Unlike
    /// `/signals`' `repo=`, this route's `repo_identity` really is applied
    /// server-side (`app.py`'s `list_review_records` builds
    /// `WHERE repo_identity = ?` from it), so no client-side consistency
    /// check is needed the way `PRLadder.repoConsistency` runs for pr-state
    /// rows; the same is true of `pr`, which the route applies as a further
    /// `AND pr = ?` on the same query (`list_review_records`'s own
    /// `pr_raw` handling). `owner`/`repoName` reach this unvalidated at the
    /// call site's discretion, same as `latestPRStatesRemoteCommand` —
    /// `PRLadder.fetchLadder` (no `pr`) and `ReviewRecordsFetch.fetch` (with
    /// `pr`) are the only callers and both validate first via
    /// `validateRepoSegment`.
    static func reviewRecordsRemoteCommand(
        owner: String, repoName: String, pr: Int? = nil, limit: Int, offset: Int
    ) -> String {
        let prClause = pr.map { "&pr=\($0)" } ?? ""
        return remoteGETCommand(
            path: "/review-records?repo_identity=github:\(owner)/\(repoName)\(prClause)&limit=\(limit)&offset=\(offset)")
    }

    /// `parentId` reaches this unvalidated at the call site's discretion,
    /// same as `courseRemoteCommand`'s `courseId` — `fetchChildItems` is the
    /// only caller and validates first via `validateLibraryId`.
    static func childItemsRemoteCommand(parentId: String) -> String {
        remoteGETCommand(path: "/items?parent_id=\(parentId)")
    }

    /// `epicId` reaches this unvalidated at the call site's discretion, same
    /// as `childItemsRemoteCommand`'s `parentId` — `fetchFoundDuringItems` is
    /// the only caller and validates first via `validateLibraryId`.
    static func foundDuringItemsRemoteCommand(epicId: String) -> String {
        remoteGETCommand(path: "/items?found_during=\(epicId)")
    }

    /// `itemId` reaches this unvalidated at the call site's discretion, same
    /// as every other per-route builder in this section — `fetchCorrection`
    /// is the only caller and validates first via `validateLibraryId`.
    static func itemRemoteCommand(itemId: String) -> String {
        remoteGETCommand(path: "/items/\(itemId)")
    }

    /// `GET /whoami`, read under `WorkingCopyStore.libraryApprovalTokenFile`
    /// rather than the shared `libraryTokenFile` — the one call whose whole
    /// point is to say which credential is actually on disk. See that
    /// constant's doc for the same-directory trap this exists to catch.
    static func whoamiRemoteCommand() -> String {
        remoteGETCommand(path: "/whoami", tokenFile: WorkingCopyStore.libraryApprovalTokenFile)
    }

    /// `POST /items/{id}/approve` — the write `approveEpic` sends, under the
    /// approval credential (`WorkingCopyStore.libraryApprovalTokenFile`), not
    /// the shared one every read and `reorderCourse` still use. `itemId`
    /// reaches this unvalidated at the call site's discretion, same as every
    /// other per-route builder in this section; `approveEpicArguments` is the
    /// only caller and validates first via `validateLibraryId`.
    static func itemApproveRemoteCommand(itemId: String) -> String {
        remoteWriteCommand(method: "POST", path: "/items/\(itemId)/approve",
                           tokenFile: WorkingCopyStore.libraryApprovalTokenFile)
    }

    /// `POST /items/{id}/model` — the write `setItemModel` sends, under Deck's
    /// own credential (`libraryApprovalTokenFile`, the one that resolves as
    /// actor `deck`), exactly as Approve does. `itemId` reaches this
    /// unvalidated; `itemModelArguments` is the only caller and validates
    /// first via `validateLibraryId`.
    static func itemModelRemoteCommand(itemId: String) -> String {
        remoteWriteCommand(method: "POST", path: "/items/\(itemId)/model",
                           tokenFile: WorkingCopyStore.libraryApprovalTokenFile)
    }

    /// `PUT /courses/{id}/order` — the write `reorderCourse` sends.
    /// `courseId` reaches this unvalidated at the call site's discretion,
    /// same as every other per-route builder in this section;
    /// `reorderCourseArguments` is the only caller and validates first via
    /// `validateLibraryId`.
    static func courseOrderRemoteCommand(courseId: String) -> String {
        remotePUTCommand(path: "/courses/\(courseId)/order")
    }

    /// No caller-supplied input reaches this path, unlike every other
    /// command in this file — `kind=bead` is a fixed filter, not a value
    /// this file composes from `Crew.project` or a picked doc id.
    static func beadsListRemoteCommand() -> String {
        remoteGETCommand(path: "/reference/documents?kind=bead")
    }

    // MARK: - argv

    private static func arguments(
        target: SSHTarget, remoteCommand: String, controlPath: String,
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            remoteCommand,
        ], home: home)
    }

    static func coursesListArguments(
        target: SSHTarget, product: String, controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target, remoteCommand: coursesListRemoteCommand(product: product),
                 controlPath: controlPath)
    }

    static func courseArguments(
        target: SSHTarget, courseId: String, controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target, remoteCommand: courseRemoteCommand(courseId: courseId),
                 controlPath: controlPath)
    }

    static func itemsArguments(
        target: SSHTarget, product: String, state: QueueState,
        limit: Int = itemsPageLimit, offset: Int = 0,
        controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target,
                 remoteCommand: itemsRemoteCommand(product: product, state: state, limit: limit, offset: offset),
                 controlPath: controlPath)
    }

    static func correctionsQueuesArguments(
        target: SSHTarget, product: String, controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target, remoteCommand: correctionsQueuesRemoteCommand(product: product),
                 controlPath: controlPath)
    }

    static func beadsListArguments(
        target: SSHTarget, controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target, remoteCommand: beadsListRemoteCommand(), controlPath: controlPath)
    }

    static func epicsArguments(
        target: SSHTarget, product: String, controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target, remoteCommand: epicsRemoteCommand(product: product), controlPath: controlPath)
    }

    static func allItemsArguments(
        target: SSHTarget, product: String, limit: Int = itemsPageLimit,
        controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target, remoteCommand: allItemsRemoteCommand(product: product, limit: limit),
                 controlPath: controlPath)
    }

    static func childItemsArguments(
        target: SSHTarget, parentId: String, controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target, remoteCommand: childItemsRemoteCommand(parentId: parentId),
                 controlPath: controlPath)
    }

    static func foundDuringItemsArguments(
        target: SSHTarget, epicId: String, controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target, remoteCommand: foundDuringItemsRemoteCommand(epicId: epicId),
                 controlPath: controlPath)
    }

    static func latestPRStatesArguments(
        target: SSHTarget, owner: String, repoName: String, closedWithinDays: Int, limit: Int, offset: Int,
        controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target,
                 remoteCommand: latestPRStatesRemoteCommand(
                     owner: owner, repoName: repoName, closedWithinDays: closedWithinDays,
                     limit: limit, offset: offset),
                 controlPath: controlPath)
    }

    static func reviewRecordsArguments(
        target: SSHTarget, owner: String, repoName: String, pr: Int? = nil, limit: Int, offset: Int,
        controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target,
                 remoteCommand: reviewRecordsRemoteCommand(
                     owner: owner, repoName: repoName, pr: pr, limit: limit, offset: offset),
                 controlPath: controlPath)
    }

    static func itemArguments(
        target: SSHTarget, itemId: String, controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target, remoteCommand: itemRemoteCommand(itemId: itemId),
                 controlPath: controlPath)
    }

    static func whoamiArguments(
        target: SSHTarget, controlPath: String = defaultControlPath()
    ) -> [String] {
        arguments(target: target, remoteCommand: whoamiRemoteCommand(), controlPath: controlPath)
    }

    // MARK: - Remote commands: writes (library-protocol §4–§6)
    //
    // SHELL-SAFE POST BODIES — THE PROBLEM THE GET COMMANDS ABOVE DO NOT HAVE.
    //
    // Every GET command in this file is safe to embed unquoted inside a
    // double-quoted remote command line because every value that reaches it —
    // `product`, a Library id — is charset-validated by `validateLibraryProduct`/
    // `validateLibraryId` first (see those functions' docs). A POST body is
    // different in kind when it carries OPERATOR-TYPED FREE TEXT: a backtick
    // or `$(...)` in that text would execute ON THE MINI, AS THE OPERATOR, the moment it
    // reached the same unquoted-heredoc shape `remoteGETCommand` uses — the
    // heredoc there is deliberately unquoted (`<<EOF`, not `<<'EOF'`) so
    // `${LIBRARY_BASE_URL:-…}` and `$(cat …)` still expand, and that same
    // unquoting would expand an operator's `$(rm -rf ~)` identically.
    // Charset-validating free text the way an id is validated is not an
    // option, since the point of free text is that it says something.
    // `approveEpic`'s body now carries one such field, `acting_human`
    // (`DeckOperator.label()`, built from the macOS session's own username
    // and hostname rather than typed by anyone, but reaching this channel
    // under the identical threat model — neither is charset-restricted, and
    // a mischievous account name is exactly the case this channel exists
    // for); `reorderCourse` still sends only a version and Library ids. Both
    // use this channel so a future write with real operator-typed text
    // inherits the same safety rather than reaching for a heredoc.
    //
    // THE FIX: OPERATOR TEXT NEVER TOUCHES A SHELL STRING AT ALL. It travels
    // as the actual process stdin `SessionAgent.run(_:stdin:)` writes and ssh
    // forwards to the remote command's stdin unchanged — the same channel
    // `WorkingCopyStore.writeBack` already uses for a document's bytes, for
    // the identical reason (`writeBack`'s doc comment). Bash never parses
    // process stdin the way it parses a heredoc; a pipe is read as raw bytes.
    //
    // But the Authorization header still has to come from SOMEWHERE off argv
    // (the existing "token never in argv, never on `ps`" discipline —
    // `libraryDocumentRemoteCommand`'s doc — applies here exactly as it does
    // to every GET), and `--config -` is how the GET commands get it there.
    // curl can only read ONE stdin, so config-over-stdin and body-over-stdin
    // look mutually exclusive at first — and they are not, because curl's own
    // config-file grammar has a directive for exactly this: `data-binary =
    // "@-"` tells curl "read the request body from stdin", evaluated as the
    // NEXT thing on the same stream once the preceding config directives (the
    // `header = "..."` line) have been read. Verified empirically against the
    // curl actually deployed here (8.7.1, 2026-08-25): a stream carrying
    // `header = "X-Test: hello"` then `data-binary = "@-"` then raw bytes
    // containing a literal backtick, `$HOME` and `$(id)` delivered every one
    // of those bytes to the server unmangled — curl treats everything after
    // the `data-binary` directive as opaque body content, not as more config
    // to parse.
    //
    // So the remote command is a three-stage local pipe, entirely on the
    // mini's shell, before curl ever runs:
    //
    //   { printf 'header = "Authorization: Bearer %s"\n' "$(cat TOKENFILE)";
    //     printf 'data-binary = "@-"\n';
    //     cat; } | curl ... --config - ...
    //
    // The first `printf` is the ONLY line bash expands (the fixed, non-operator
    // token-file path), exactly mirroring `libraryDocumentRemoteCommand`'s
    // header line. The second `printf` is a fixed literal. `cat`, with no
    // arguments, copies the RUNNING SHELL'S OWN STDIN — the operator's JSON,
    // arriving over the ssh-forwarded pipe — straight through, byte for byte,
    // with no parsing of any kind. curl then reads that whole assembled stream
    // as its config: header directive, data-binary directive, then the literal
    // body.
    //
    // This satisfies every invariant at once: no operator text reaches argv
    // (it is never a command-line argument to anything); no operator text is
    // shell-expanded (`cat` does not parse); the bearer token still never
    // reaches argv (unchanged from the GET path); and nothing is written to a
    // temp file (three processes and two pipes, no disk). Round-tripped
    // through `` ` ``, `$(id)`, `$HOME`, a newline, a single quote, a double
    // quote and a backslash in `LibraryClientTests`.
    private static func remotePOSTCommand(path: String) -> String {
        remoteWriteCommand(method: "POST", path: path)
    }

    /// The same three-stage pipe for a PUT (`PUT /courses/{id}/order`, Deck's
    /// first). Only the verb differs, so this shares `remoteWriteCommand`
    /// with `remotePOSTCommand` rather than becoming a second shape.
    private static func remotePUTCommand(path: String) -> String {
        remoteWriteCommand(method: "PUT", path: path)
    }

    /// `method` is one of a few fixed literals from the callers above and
    /// never operator text, so it can sit in the command string like `path`.
    /// `tokenFile` defaults to `WorkingCopyStore.libraryTokenFile`, the same
    /// default `remoteGETCommand` takes and for the same reason —
    /// `itemApproveRemoteCommand` is the one write that passes
    /// `WorkingCopyStore.libraryApprovalTokenFile` explicitly.
    private static func remoteWriteCommand(
        method: String, path: String, tokenFile: String = WorkingCopyStore.libraryTokenFile
    ) -> String {
        "{ printf 'header = \"Authorization: Bearer %s\"\\n' " +
        "\"$(cat \(tokenFile) 2>/dev/null)\"; " +
        "printf 'data-binary = \"@-\"\\n'; cat; } | " +
        "curl -sS -w '\\n%{http_code}' " +
        "-H 'Library-Protocol: 1' " +
        "-H 'Content-Type: application/json' " +
        "--config - -X \(method) " +
        "\"\(WorkingCopyStore.libraryBaseURLExpression)\(path)\""
    }

    // MARK: - Decode

    /// The ids of every live Course matching a product filter — in practice
    /// zero or one, since a product holds at most one live Course
    /// (library-protocol §6.1), enforced by the Library's own unique index
    /// rather than by anything this client checks.
    static func decodeCoursesList(_ raw: Data) throws -> [String] {
        let body = try refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let courses = root["courses"] as? [[String: Any]] else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        return courses.compactMap { $0["id"] as? String }
    }

    /// A resolved Course, or throws when the payload has no usable `id` at
    /// all (a Course with no identity is not one worth showing a panel for).
    /// Every other field degrades independently.
    ///
    /// **`entries` IS THE ORDER AUTHORITY, `items` IS THE LOOKUP TABLE.** The
    /// Library returns `items` in the same order as `entries` today, but nothing
    /// in the contract promises that, and a client that trusted response order
    /// would silently draw the wrong route the day it changed. So `items` is
    /// indexed into a dictionary first — LAST WRITE WINS on a duplicate id
    /// rather than crashing, since `Dictionary(uniqueKeysWithValues:)` would
    /// trap on exactly the malformed input this decoder exists to survive —
    /// and `entries` is walked in its own order to build the result, dropping
    /// any id with no matching resolved item.
    static func decodeCourse(_ raw: Data) throws -> Course {
        let body = try refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = root["id"] as? String else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        let entryIds = (root["entries"] as? [String]) ?? []
        var itemsById: [String: [String: Any]] = [:]
        for item in (root["items"] as? [[String: Any]]) ?? [] {
            guard let itemId = item["id"] as? String else { continue }
            itemsById[itemId] = item
        }
        let entries = entryIds.compactMap { entryId -> CourseEntry? in
            guard let item = itemsById[entryId], let title = item["title"] as? String else { return nil }
            return CourseEntry(
                id: entryId, title: title,
                shortDescription: item["short_description"] as? String,
                type: item["type"] as? String,
                state: item["state"] as? String,
                maturity: item["maturity"] as? String,
                resolution: item["resolution"] as? String,
                body: item["body"] as? String,
                specification: item["specification"] as? String,
                definitionOfDone: item["definition_of_done"] as? String,
                severity: item["severity"] as? String,
                needs: (item["needs"] as? [String]) ?? [],
                claimedBy: item["claimed_by"] as? String,
                claimExpired: (item["claim_expired"] as? Bool) ?? false,
                prerequisites: decodePrerequisites(item["prerequisites"]),
                blocked: (item["blocked"] as? Bool) ?? false,
                key: item["key"] as? String, pr: item["pr"] as? String,
                prURL: item["pr_url"] as? String, prRepo: item["pr_repo"] as? String)
        }
        return Course(id: id, product: root["product"] as? String,
                     title: root["title"] as? String, entries: entries,
                     version: decodeVersion(root["version"]), servedEntryIds: entryIds)
    }

    /// The Course's `version`, or `nil` unless it is a real integer. A JSON
    /// boolean arrives as an `NSNumber` too, and `true` would otherwise read
    /// as version 1; the Library refuses a boolean version for the same
    /// reason, so Deck does not manufacture one.
    private static func decodeVersion(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }

    /// One page of `GET /items?product=&state=&limit=&offset=`, filtered but
    /// UNSORTED, plus the envelope's own `truncated` — split out of
    /// `decodeCorrectionsQueue` so `pagedQueueItems` can merge several pages
    /// of one state before sorting once over the whole set (see that
    /// function's doc for why sorting per page would be wrong). Items degrade
    /// independently: one missing a field is dropped rather than throwing, so
    /// an older or malformed server shows a short panel rather than no panel.
    private static func decodeQueueItemsPage(
        _ raw: Data, correctionsQueueIds: Set<String> = []
    ) throws -> (items: [QueueItem], childParents: [String: String], serverItemCount: Int, truncated: Bool) {
        let body = try refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        let rawItems = (root["items"] as? [[String: Any]]) ?? []
        var childParents: [String: String] = [:]
        let items = rawItems.compactMap { item -> QueueItem? in
            guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
            // AN EPIC IS THE PLAN, NOT AN INTERRUPT. `GET /items?product=&state=open`
            // returns every open item of every type, so before this the Course's own
            // epics were drawn a second time in the corrections queue — one item in
            // two panels, which reads as a duplicate filing (the operator, 2026-08-26, on
            // meeting the checkout-document-list epic in both).
            //
            // Dropped HERE rather than by asking the Library for `type=`, because
            // that filter takes ONE type and this needs "everything except epic" —
            // four queries where the response already carries what is needed.
            if (item["type"] as? String) == "epic" {
                return nil
            }
            // convivy-orient/issue_build.py:128 defines queue membership as
            // "not an epic AND has no parent epic" — this decoder only had the
            // first half. That was not wrong when it was written: measured
            // 2026-08-25, 0 of 50 items across five products carried a
            // `parent_id`, so the second half would have been dead code. The
            // fleet's first child items were filed 2026-08-28. The filter did
            // not become wrong; the data changed under it. A non-null
            // `parent_id` means this item is in the plan under its epic, not
            // an interrupt, so it is dropped here too. A missing or null key
            // means no parent — a queue member, kept.
            //
            // A parent naming one of the product's corrections queues is a
            // queue member too: that is how the Library stores a correction
            // once its one-home switch lands (`CorrectionsQueue.correctionsQueueIds`).
            if let parentId = item["parent_id"] as? String, !parentId.isEmpty,
               !correctionsQueueIds.contains(parentId) {
                childParents[id] = parentId
                return nil
            }
            return QueueItem(id: id, title: title,
                             type: item["type"] as? String, severity: item["severity"] as? String,
                             state: item["state"] as? String,
                             claimedBy: item["claimed_by"] as? String,
                             claimExpired: (item["claim_expired"] as? Bool) ?? false,
                             topics: (item["topics"] as? [String]) ?? [],
                             prerequisites: decodePrerequisites(item["prerequisites"]),
                             blocked: (item["blocked"] as? Bool) ?? false,
                             key: item["key"] as? String, pr: item["pr"] as? String,
                             prURL: item["pr_url"] as? String, prRepo: item["pr_repo"] as? String)
        }
        let truncated = (root["truncated"] as? Bool) ?? false
        return (items, childParents, rawItems.count, truncated)
    }

    /// The stable sort every corrections-queue page (or merged set of pages)
    /// is put in before it reaches a panel.
    ///
    /// **TOPIC GROUPS THE QUEUE; AWAITING-PR AND SEVERITY STILL ORDER WITHIN
    /// A GROUP, NOT ACROSS ALL OF THEM** (`issue_01M2298XAXW03K3GAF2FJ144J6`).
    /// Before this, the sort was `(isAwaitingPR, severity)` alone, so related
    /// work — every lock item, every automation item — sat scattered through
    /// one flat list. Grouping sits above that ordering rather than
    /// replacing it: a `pr-open` item still leads its own topic's items, and
    /// a `high`-severity item still leads the `open` and `claimed` ones
    /// beside it, so the urgency signal a reader relied on before survives
    /// inside the group it now also gets.
    ///
    /// **Named topics sort ascending by name, ahead of a single "no topic"
    /// group that always sorts last.** This matches the order the Library's
    /// own `sort=topic` produces server-side (`itemsRemoteCommand`), so the
    /// two agree on where one group ends and the next begins rather than the
    /// client silently redrawing a boundary the server already drew. An item
    /// with no topic is not dropped or folded into a false group — it is
    /// nearly always a Library record older than the field, and it must
    /// still show up somewhere the badge count and the row count agree on.
    ///
    /// **An item naming several topics groups under the first.** `topics` is
    /// an array because the field is, but grouping is one choice per row —
    /// showing the same item twice, once per topic, would read as two
    /// corrections rather than one. Verified 2026-09-08: 145 of 145 open
    /// `vivy` items carried exactly one, so this is today's universal case,
    /// not a corner this sort quietly gets wrong.
    ///
    /// **Called ONCE over the whole queue — every state, every page —
    /// never once per page or per state.** An item on page 2 of `open` must
    /// be compared against every item of `pr-open` and `claimed` too, or a
    /// `lock` item from one state could land outside the `lock` group formed
    /// by the others. `fetchCorrectionsQueue` merges every state's pages
    /// first and sorts exactly once over the total, for the same reason
    /// `testSeverityOrdersItemsWithinAStateGroup` pinned single-pass sorting
    /// before topic existed.
    ///
    /// Swift's `sorted(by:)` is a stable sort, so two items ranking equal on
    /// every key above keep the order they arrived in — the Library's own
    /// newest-first — rather than this sort scrambling ties.
    ///
    /// **A `claimed` item sorts exactly as an `open` one, no third tier.**
    /// `isAwaitingPR` is `false` for any state but `pr-open`, so a claimed
    /// item — live or lapsed — falls straight into the severity comparison
    /// alongside `open` items without this function needing a case for it.
    /// Someone is on a live claim, so it is not the interrupt a bare `open`
    /// row is; a lapsed one is exactly that interrupt again. Neither earns
    /// its own tier — the row itself carries the distinction (see
    /// `CockpitView.correctionsQueueContent`), not its position.
    private static func sortedQueueItems(_ items: [QueueItem]) -> [QueueItem] {
        items.sorted { lhs, rhs in
            if let topicResult = topicPrecedes(lhs, rhs) { return topicResult }
            if lhs.isAwaitingPR != rhs.isAwaitingPR {
                return lhs.isAwaitingPR
            }
            return severityRank(lhs.severity) < severityRank(rhs.severity)
        }
    }

    /// Named topics sort ascending by name, ahead of the single "no topic"
    /// group, which always sorts last — the comparator `sortedQueueItems`
    /// (topic as the PRIMARY key) and `severityOrderedQueueItems` (topic as
    /// the TIE-BREAK after severity and `isAwaitingPR`) both defer to, so
    /// area mode and severity mode cannot silently disagree on where one
    /// topic group ends and the next begins.
    ///
    /// Returns `nil` when the two items are in the same group (both named
    /// the same topic, or both carry none), so a caller's stable sort falls
    /// through to whatever key comes next.
    private static func topicPrecedes(_ lhs: QueueItem, _ rhs: QueueItem) -> Bool? {
        let lhsTopic = lhs.topics.first
        let rhsTopic = rhs.topics.first
        guard lhsTopic != rhsTopic else { return nil }
        switch (lhsTopic, rhsTopic) {
        case let (lhsName?, rhsName?): return lhsName < rhsName
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return nil
        }
    }

    /// **SEVERITY MODE'S OWN KEY ORDER** (steward, 2026-09-16,
    /// issue_01M2P9ZPBA5114PE875BHHT8NR, ruling the issue body left open):
    /// severity first (worst first), `isAwaitingPR` second so a pr-open item
    /// still leads its own severity band the way it leads its own topic
    /// group under `sortedQueueItems`, `topicPrecedes` third. Two items tied
    /// on all three keep the order they arrived in — the same
    /// `sorted(by:)` stability `sortedQueueItems` relies on — which is what
    /// keeps a row from jumping on every refresh; see `orderedQueueItems`'s
    /// doc for why that guarantee depends on this running over the
    /// UNTOUCHED merged set, not an already-reordered one.
    private static func severityOrderedQueueItems(_ items: [QueueItem]) -> [QueueItem] {
        items.sorted { lhs, rhs in
            let lhsRank = severityRank(lhs.severity)
            let rhsRank = severityRank(rhs.severity)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.isAwaitingPR != rhs.isAwaitingPR { return lhs.isAwaitingPR }
            return topicPrecedes(lhs, rhs) ?? false
        }
    }

    /// The corrections queue in whichever of the three orders `order`
    /// names. The entry point every reader of the queue calls, over the
    /// FULL merged set (`CorrectionsQueue.items`, which `fetchCorrectionsQueue`
    /// leaves in the Library's own arrival order — see that function's doc)
    /// and BEFORE `CockpitView.queueRowLimit` slices it, never after:
    /// capping first and ordering the capped slice shows whichever five
    /// items arrived first rather than the five worst, the exact mistake
    /// Orient measured on its own page (issue_01M2P9ZPBA5114PE875BHHT8NR) —
    /// 22 of Bosun's 47 high-severity items shown, 25 hidden. Deck's cap of
    /// 5 makes the same mistake worse, not better.
    ///
    /// - `.area`: `sortedQueueItems` exactly as it has always run — topic
    ///   first, `isAwaitingPR` second, severity third. **This is what the
    ///   queue already drew before this control existed** — kept as its own
    ///   named choice rather than folded into `.arrival`: an earlier
    ///   reading of this issue treated "filed order" and "area" as two
    ///   options, and they were the same option under two names, since
    ///   nothing about today's behaviour reads the Library's raw arrival
    ///   order at all.
    /// - `.severity`: `severityOrderedQueueItems` — severity first
    ///   (worst first), `isAwaitingPR` second, area third.
    /// - `.arrival`: `items`, untouched. **`isAwaitingPR` is not
    ///   re-applied here** — arrival means exactly what the Library
    ///   returned, and re-ranking it would make this a fourth computed
    ///   order rather than the one raw one.
    ///
    /// Called ONCE per render over the whole set, the same "never per page,
    /// never per state" discipline `sortedQueueItems` always documented —
    /// unchanged by moving the call site from `fetchCorrectionsQueue` to
    /// this function's own callers, since a caller can now change the
    /// order on the same fetched set with no second round trip.
    static func orderedQueueItems(_ items: [QueueItem], order: QueueSortOrder) -> [QueueItem] {
        switch order {
        case .area: return sortedQueueItems(items)
        case .severity: return severityOrderedQueueItems(items)
        case .arrival: return items
        }
    }

    /// One page of the corrections queue, decoded and area-sorted (via
    /// `sortedQueueItems`) — the entry point `LibraryClientTests` drives
    /// directly against a single canned response, and pre-dating the sort
    /// control, its own suite asserts that pre-sorted order. Production
    /// never calls this: `fetchCorrectionsQueue` needs several pages of one
    /// state MERGED before anything is sorted (see that function's doc), so
    /// it calls `decodeQueueItemsPage` directly and leaves the result for
    /// `orderedQueueItems` to sort downstream, in whichever order a reader
    /// has chosen. `total` is `items.count` — what this call actually produced — and
    /// `truncated` is this one response's own envelope flag, so a caller that
    /// decodes a single page directly (as every test here does) still learns
    /// when that page was not the whole story.
    static func decodeCorrectionsQueue(
        _ raw: Data, correctionsQueueIds: Set<String> = []
    ) throws -> CorrectionsQueue {
        let page = try decodeQueueItemsPage(raw, correctionsQueueIds: correctionsQueueIds)
        let sortedItems = sortedQueueItems(page.items)
        return CorrectionsQueue(items: sortedItems, total: sortedItems.count, truncated: page.truncated,
                                childParents: page.childParents, correctionsQueueIds: correctionsQueueIds)
    }

    /// `GET /corrections-queues?product=`'s ids, for `fetchCorrectionsQueue`.
    ///
    /// **A 404 READS AS NO QUEUES.** It is what a Library answers before the
    /// one-home plan's first PR adds the route, and in that state every
    /// correction's parent is still null, so an empty set loses nothing.
    ///
    /// **ANY OTHER FAILURE THROWS, AND SO DOES A 200 WITHOUT A
    /// `corrections_queues` ARRAY.** Once the Library stores queue ids as
    /// parents, guessing an empty set would drop every correction from the
    /// panel and present the result as an empty queue. Throwing fails the
    /// whole queue fetch instead, which the cockpit draws as "Could not reach
    /// the queue" with the error beside it. An entry without a string `id`
    /// is skipped, the per-item degrade every decoder here follows.
    static func decodeCorrectionsQueueIds(_ raw: Data) throws -> Set<String> {
        if let (status, _) = WorkingCopyStore.splitCurlStatusResponse(raw), status == 404 {
            return []
        }
        let body = try refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let queues = root["corrections_queues"] as? [[String: Any]] else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        return Set(queues.compactMap { $0["id"] as? String })
    }

    /// Pages one state to completion — see `itemsRemoteCommand`'s doc for why
    /// a state can span several `limit`/`offset` calls. `fetchPage(offset)`
    /// performs one HTTP round trip for the page starting at `offset` and is
    /// INJECTED so this paging logic is testable against canned response
    /// bytes rather than a real ssh target — every other fetch verb in this
    /// file reaches `SessionAgent.run` directly, which the test suite has no
    /// way to stand up.
    ///
    /// Keeps asking for another page exactly while the envelope's own
    /// `truncated` says there is more, advancing `offset` by that page's own
    /// item count (not `itemsPageLimit`, in case the Library ever answers
    /// short) — and gives up after `itemsMaxPages`, returning `truncated:
    /// true` in that case rather than looping forever against a server that
    /// never stops asking. An empty page ends the loop too, since advancing
    /// by zero would otherwise spin without making progress.
    ///
    /// Returns items UNSORTED — `fetchCorrectionsQueue` merges every state's
    /// pages and leaves the total unsorted too, for `orderedQueueItems` to
    /// order downstream; see that function's doc for why sorting here, page
    /// by page, would be wrong regardless of which order is eventually
    /// applied.
    static func pagedQueueItems(fetchPage: (_ offset: Int) throws -> Data) throws -> (items: [QueueItem], truncated: Bool) {
        let paged = try pagedQueue(fetchPage: fetchPage)
        return (paged.items, paged.truncated)
    }

    /// `pagedQueueItems` plus the parent of every item the decoder dropped for
    /// having one — see `CorrectionsQueue.childParents`. Kept as a second
    /// function so the two-value shape `pagedQueueItems`'s callers destructure
    /// does not change.
    static func pagedQueue(
        correctionsQueueIds: Set<String> = [],
        fetchPage: (_ offset: Int) throws -> Data
    ) throws -> (items: [QueueItem], childParents: [String: String], truncated: Bool) {
        var merged: [QueueItem] = []
        var childParents: [String: String] = [:]
        var offset = 0
        for _ in 0..<itemsMaxPages {
            let raw = try fetchPage(offset)
            let page = try decodeQueueItemsPage(raw, correctionsQueueIds: correctionsQueueIds)
            merged += page.items
            childParents.merge(page.childParents) { _, new in new }
            guard page.truncated, page.serverItemCount > 0 else {
                return (merged, childParents, false)
            }
            offset += page.serverItemCount
        }
        return (merged, childParents, true)
    }

    /// The work items filed under one epic. Mirrors `decodeCorrectionsQueue`'s
    /// leniency rather than `decodeBeadsList`'s strictness: a missing or
    /// absent `items` key degrades to an empty list rather than throwing,
    /// because an epic with no children is the expected steady state (see
    /// `ChildItem`'s doc) and must read the same as "asked, got zero" rather
    /// than as a malformed response. A body that is not a JSON object at all
    /// still throws — that is a transport-level surprise, not a content one.
    /// `expectedParentId` IS CHECKED HERE RATHER THAN TRUSTED FROM THE QUERY,
    /// and that is the point of taking it.
    ///
    /// `GET /items?parent_id=` is honoured by the Library today — measured
    /// 2026-08-25, where an unfiltered query returned 15 items, the same query
    /// with `parent_id` set to a nonexistent id returned 0, and a control query
    /// carrying an unknown parameter returned 15 again, so the service is
    /// applying this filter specifically rather than ignoring what it does not
    /// recognise.
    ///
    /// **The check exists anyway, because the failure mode without it is silent
    /// and wrong rather than empty.** A route that stopped honouring the filter
    /// would hand back every item in the product, and this view would render
    /// them under EVERY epic's expansion as a plausible non-empty list — no
    /// error, no empty state, nothing to catch it. Found by `deck-reviewer` on
    /// #136. `platform/contracts/library-protocol` documents `GET /items` and
    /// names no query filters for it, so nothing but this function makes the
    /// client's correctness independent of the server's behaviour.
    ///
    /// An item whose `parent_id` is absent or does not match is dropped, the
    /// same "field costs itself" posture the rest of this file takes: the
    /// expansion shows fewer rows rather than wrong ones.
    static func decodeChildItems(_ raw: Data, expectedParentId: String) throws -> [ChildItem] {
        let body = try refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        let items = (root["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item -> ChildItem? in
            guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
            let parentId = item["parent_id"] as? String
            guard parentId == expectedParentId else { return nil }
            return ChildItem(id: id, title: title,
                             type: item["type"] as? String, state: item["state"] as? String,
                             parentId: parentId,
                             prerequisites: decodePrerequisites(item["prerequisites"]),
                             blocked: (item["blocked"] as? Bool) ?? false,
                             key: item["key"] as? String, pr: item["pr"] as? String,
                             prURL: item["pr_url"] as? String, prRepo: item["pr_repo"] as? String)
        }
    }

    /// The items whose `found_during` names one epic. Same defensive posture
    /// as `decodeChildItems` — see that function's doc for why the decoder
    /// re-checks the field the query already filtered on rather than trusting
    /// the server did: a route that silently stopped honouring `found_during`
    /// would otherwise hand back every item in the product, and this decoder
    /// would show them all under every epic's section as a plausible,
    /// non-empty, wrong list.
    ///
    /// An item whose `found_during` is absent or does not match is dropped —
    /// the same "field costs itself" posture the rest of this file takes.
    static func decodeFoundDuringItems(_ raw: Data, expectedFoundDuring: String) throws -> [FoundDuringItem] {
        let body = try refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        let items = (root["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item -> FoundDuringItem? in
            guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
            guard (item["found_during"] as? String) == expectedFoundDuring else { return nil }
            return FoundDuringItem(id: id, title: title, state: item["state"] as? String)
        }
    }

    /// Every epic of every state — `GET /items?product=X&type=epic`, no
    /// `state=` filter (see `epicsRemoteCommand`). Same envelope as
    /// `decodeCorrectionsQueue`/`decodeChildItems` (`{"items": [...]}`), and
    /// the same leniency: an absent `items` key degrades to an empty list
    /// rather than throwing. An item missing `id` is dropped; every other
    /// field, including the two dates `BeadProgress.compute` reads, degrades
    /// independently.
    static func decodeEpics(_ raw: Data) throws -> [Epic] {
        let body = try refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        let items = (root["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item -> Epic? in
            guard let id = item["id"] as? String else { return nil }
            return Epic(id: id,
                        state: item["state"] as? String,
                        resolution: item["resolution"] as? String,
                        createdAt: item["created_at"] as? String,
                        resolvedAt: item["resolved_at"] as? String,
                        title: item["title"] as? String,
                        maturity: item["maturity"] as? String,
                        specification: item["specification"] as? String)
        }
    }

    /// Every item of `product`'s, any state and any type — `GET
    /// /items?product=X&limit=200`, no `state=` filter, by analogy with
    /// `decodeEpics` (see `allItemsRemoteCommand`). Same envelope
    /// (`{"items": [...]}`) and the same leniency: an absent `items` key
    /// degrades to an empty list rather than throwing, and an item missing
    /// `id` or `title` is dropped; every other field degrades independently.
    static func decodeWorkItemRecords(_ raw: Data) throws -> [WorkItemRecord] {
        let body = try refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        let items = (root["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item -> WorkItemRecord? in
            guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
            return WorkItemRecord(
                id: id, title: title, type: item["type"] as? String,
                parentId: item["parent_id"] as? String,
                key: item["key"] as? String, pr: item["pr"] as? String,
                prURL: item["pr_url"] as? String, prRepo: item["pr_repo"] as? String)
        }
    }

    /// Every bead doc in the Reference Room, by analogy with
    /// `decodeCoursesList`/`decodeCorrectionsQueue`'s envelope shape
    /// (`{"documents": [...], "count", "total", "offset", "truncated"}`) —
    /// the same paginated-list envelope every other listing route in this
    /// file answers with. A document missing `id` is dropped; `product`
    /// degrades to `nil` independently.
    static func decodeBeadsList(_ raw: Data) throws -> [BeadDocument] {
        let body = try refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let documents = root["documents"] as? [[String: Any]] else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        return documents.compactMap { doc -> BeadDocument? in
            guard let id = doc["id"] as? String else { return nil }
            return BeadDocument(id: id, product: doc["product"] as? String)
        }
    }

    /// `GET /whoami`'s answer — confirmed on the wire against the running
    /// Library, 2026-09-22: `{"actor","kind","products","capabilities"}`,
    /// every field a root key. `products`/most of `capabilities` are unused
    /// here; `capabilities` is kept for the same reason `Epic.title` is kept
    /// unread by some callers — it costs nothing and the actor-assertion test
    /// below wants it available.
    struct WhoamiResponse: Equatable {
        let actor: String?
        let kind: String?
        let capabilities: [String]
    }

    /// Throws only when the body is not the JSON object every 200 from this
    /// route is; every field then degrades independently, the same
    /// discipline as every other decoder in this file.
    static func decodeWhoami(_ raw: Data) throws -> WhoamiResponse {
        let body = try refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        return WhoamiResponse(actor: root["actor"] as? String, kind: root["kind"] as? String,
                              capabilities: (root["capabilities"] as? [String]) ?? [])
    }

    /// Splits a curl response and refuses anything but 200, shared by every
    /// decoder above. Pure — same split `WorkingCopyStore.fetch` uses.
    ///
    /// **Internal rather than `private`** so `PRLadder.swift`'s own decoders
    /// (`/signals/pr-state`, `/review-records`) can reuse the exact same
    /// refusal semantics instead of a second copy drifting from this one.
    ///
    /// The write path uses it too: every write in this file answers 200, so
    /// anything else is a refusal carrying the Library's own error body. §8's
    /// refusals name what failed, and that text is the caller's cue to surface
    /// rather than a generic failure.
    static func refusedOr200Body(_ raw: Data) throws -> Data {
        guard let (status, body) = WorkingCopyStore.splitCurlStatusResponse(raw) else {
            throw FetchError.unexpectedResponse(String(data: raw, encoding: .utf8) ?? "(binary)")
        }
        guard status == 200 else {
            throw FetchError.libraryRefused(status: status, body: String(data: body, encoding: .utf8) ?? "(binary)")
        }
        return body
    }

    /// A correction's full detail — `GET /items/{id}`. Throws only when the
    /// payload carries no usable `id`; every other field, including each
    /// entry of `comments`, degrades independently, the same discipline
    /// `decodeCourse` and `decodeCorrectionsQueue` follow.
    static func decodeCorrectionDetail(_ raw: Data) throws -> CorrectionDetail {
        let body = try refusedOr200Body(raw)
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = root["id"] as? String else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        let comments = ((root["comments"] as? [[String: Any]]) ?? []).map { comment -> CorrectionComment in
            CorrectionComment(
                id: (comment["id"] as? NSNumber)?.intValue,
                actor: comment["actor"] as? String,
                kind: comment["kind"] as? String,
                body: comment["body"] as? String,
                at: comment["at"] as? String)
        }
        return CorrectionDetail(
            id: id,
            title: root["title"] as? String,
            product: root["product"] as? String,
            body: root["body"] as? String,
            type: root["type"] as? String,
            state: root["state"] as? String,
            severity: root["severity"] as? String,
            needs: root["needs"] as? String,
            resolution: root["resolution"] as? String,
            outcomeNote: root["outcome_note"] as? String,
            claimedBy: root["claimed_by"] as? String,
            claimExpired: (root["claim_expired"] as? Bool) ?? false,
            createdAt: root["created_at"] as? String,
            parentId: root["parent_id"] as? String,
            foundDuring: root["found_during"] as? String,
            specification: root["specification"] as? String,
            definitionOfDone: root["definition_of_done"] as? String,
            modelChoice: decodeModelChoice(root["model_choice"]),
            comments: comments)
    }

    /// `model_choice`: `null`, `{}`, `""` and an absent key mean no choice,
    /// the same reading the Bosun gives them
    /// (`platform/contracts/work-item-model-override`, "Parsing what comes
    /// back"). Anything else is a choice. The Bosun refuses to dispatch on
    /// any other shape, so a non-empty object lacking fields, and a value
    /// that is not an object at all, both decode as a choice with those
    /// fields missing, which `isMalformed` marks, rather than "No model set".
    static func decodeModelChoice(_ raw: Any?) -> ModelChoice? {
        if raw == nil || raw is NSNull { return nil }
        if let text = raw as? String, text.isEmpty { return nil }
        guard let object = raw as? [String: Any] else { return ModelChoice() }
        if object.isEmpty { return nil }
        return ModelChoice(
            model: object["model"] as? String, reason: object["reason"] as? String,
            setByClient: object["set_by_client"] as? String,
            actingHuman: object["acting_human"] as? String, setAt: object["set_at"] as? String)
    }

    // MARK: - Fetch

    /// Resolves `product`'s one live Course, fully resolved, or `nil` when
    /// the product has none. Two round trips — list, then fetch by id —
    /// because only `GET /courses/{id}` resolves entries; the list route
    /// does not carry them (§3). Synchronous and blocking, like every
    /// `SessionAgent`/`WorkingCopyStore` verb; callers run this off the main
    /// actor (`Task.detached`), the same discipline `ContentView` already
    /// applies to `WorkingCopyStore.fetch`.
    static func fetchCourse(target: SSHTarget, product: String) throws -> Course? {
        guard let safeProduct = validateLibraryProduct(product) else {
            throw FetchError.invalidInput(product)
        }
        let listRaw = try SessionAgent.run(
            coursesListArguments(target: target, product: safeProduct), classifyMissingCommand: false)
        guard let courseId = try decodeCoursesList(listRaw).first else { return nil }
        guard let safeCourseId = validateLibraryId(courseId) else {
            throw FetchError.invalidInput(courseId)
        }
        let courseRaw = try SessionAgent.run(
            courseArguments(target: target, courseId: safeCourseId), classifyMissingCommand: false)
        return try decodeCourse(courseRaw)
    }

    /// The corrections queue for `product` — every `open`, `pr-open`, and
    /// `claimed` item, however many pages the Library needs to hand them all
    /// over. Synchronous and blocking, like `fetchCourse` — see that
    /// function's doc.
    ///
    /// **ONE STATE'S WORTH OF PAGES PER STATE IN `queueStates`.** The
    /// Library honours a single `state=` and silently returns an empty list
    /// for the comma-joined form — see `itemsRemoteCommand`, which records
    /// the measurement. So `pr-open`, `open`, and `claimed` are each fetched
    /// separately and merged before anything is sorted.
    ///
    /// **`claimed` is here because a fetched state can hide its own
    /// staleness.** A claim expires without the Library ever moving the item
    /// out of `state: claimed` — `issue_get`'s own doc: `claim_expired: true`
    /// means free to take, not "somebody has this." Before `.claimed` joined
    /// `queueStates`, a claimed item left this queue the moment it was
    /// claimed and only returned if its state later changed, so an item
    /// whose worker died sat invisible in both this queue (wrong state) and
    /// under an epic (no parent) — see `CockpitView.correctionsQueueContent`
    /// for how a claimed row still marks a lapsed claim rather than reading
    /// as merely taken.
    ///
    /// **EACH STATE IS PAGED TO COMPLETION VIA `pagedQueueItems`, NOT ONE
    /// CALL** (`issue_01M1STN4AB0JQ7YJ1ETJTBR370`). Before this, the queue
    /// took whatever the Library's default page handed back — 50 items — and
    /// never looked at the envelope's own `truncated` flag, so a product past
    /// 50 open items in one state showed a silent subset. Measured against
    /// the running Library: `vivy`'s `state=open` answered 50 of 176 with
    /// `truncated: true`. Paging is preferred over asking for one very large
    /// `limit` and hoping, because paging is correct at any queue size;
    /// `pagedQueueItems` still bounds itself at `itemsMaxPages` and reports
    /// `truncated: true` on `CorrectionsQueue` if even that runs out, so the
    /// panel says so rather than presenting a partial queue as the whole one
    /// (`CockpitView.queueTruncatedNotice`).
    ///
    /// **MERGED ACROSS EVERY STATE'S PAGES, BUT NO LONGER SORTED HERE**
    /// (`issue_01M2P9ZPBA5114PE875BHHT8NR`). Until the corrections queue
    /// offered a sort choice, this function called `sortedQueueItems` on
    /// the merged total once every page of every state was in hand — see
    /// `sortedQueueItems`'s own doc for why sorting has to happen once,
    /// over the whole set, never per page or per state, a constraint that
    /// still holds and is now enforced by `orderedQueueItems` instead:
    /// `CorrectionsQueue.items` below carries the merged set in the
    /// Library's own arrival order, and whichever order a reader has
    /// chosen is applied once, downstream, over that same whole set,
    /// before any row cap (`CockpitView.visibleQueueItems`). Sorting here
    /// would mean a changed sort choice needing a second Library round
    /// trip for data already in hand.
    ///
    /// **A FAILING CALL FAILS THE WHOLE FETCH rather than half-filling the
    /// panel.** A queue quietly missing its `pr-open` rows is the defect this
    /// change exists to fix, and it would be indistinguishable from a queue
    /// that genuinely has none.
    static func fetchCorrectionsQueue(target: SSHTarget, product: String) throws -> CorrectionsQueue {
        guard let safeProduct = validateLibraryProduct(product) else {
            throw FetchError.invalidInput(product)
        }
        let queueIds = try decodeCorrectionsQueueIds(SessionAgent.run(
            correctionsQueuesArguments(target: target, product: safeProduct), classifyMissingCommand: false))
        var merged: [QueueItem] = []
        var childParents: [String: String] = [:]
        var queueTruncated = false
        for state in queueStates {
            let (items, parents, truncated) = try pagedQueue(correctionsQueueIds: queueIds) { offset in
                try SessionAgent.run(
                    itemsArguments(target: target, product: safeProduct, state: state,
                                  limit: itemsPageLimit, offset: offset),
                    classifyMissingCommand: false)
            }
            merged += items
            childParents.merge(parents) { _, new in new }
            queueTruncated = queueTruncated || truncated
        }
        return CorrectionsQueue(items: merged, total: merged.count, truncated: queueTruncated,
                                childParents: childParents, correctionsQueueIds: queueIds)
    }

    /// Every bead doc in the Reference Room, for `SessionsSettingsView`'s
    /// picker. Synchronous and blocking, like `fetchCourse` — see that
    /// function's doc; callers run this off the main actor.
    static func fetchBeadsList(target: SSHTarget) throws -> [BeadDocument] {
        let raw = try SessionAgent.run(beadsListArguments(target: target), classifyMissingCommand: false)
        return try decodeBeadsList(raw)
    }

    /// Every epic of `product`'s, for `BeadProgress.compute` — see `Epic`'s
    /// doc for why this is a separate route from `fetchCourse`. Synchronous
    /// and blocking, like `fetchCourse`; callers run this off the main
    /// actor.
    ///
    /// **`product` IS `Crew.project`, AND THE BEAD DOCUMENT'S OWN `project`
    /// FIELD IS THE WRONG ONE — do not "fix" this to use it.** The PR that
    /// added this left the question open, having been unable to confirm what
    /// `GET /reference/documents/{id}` serves. It does serve `project`
    /// (`library/reference.py`'s `doc_dict`), and that is exactly the trap: a
    /// KB document's `project` is its KNOWLEDGE-REPO project, not a Library
    /// product. Deck's own bead carries `project: deck` while its Library
    /// product is `convivy-deck`, so querying items for `deck` would match no
    /// product at all and the meter would read zero of zero forever.
    ///
    /// This is the same three-naming-spaces hazard `CockpitResolution.beadId`
    /// documents for the doc id itself — `convivy-deck` → `deck/bead/deck`,
    /// `bosun` → `agent-platform/bead/agent-platform`. The names do not agree
    /// and nothing derives one from another.
    static func fetchEpics(target: SSHTarget, product: String) throws -> [Epic] {
        guard let safeProduct = validateLibraryProduct(product) else {
            throw FetchError.invalidInput(product)
        }
        let raw = try SessionAgent.run(
            epicsArguments(target: target, product: safeProduct), classifyMissingCommand: false)
        return try decodeEpics(raw)
    }

    /// Every item of `product`'s, any state and any type, for
    /// `CockpitView.pullRequestWorkItemChips`'s own join — one call, not
    /// paged like `fetchCorrectionsQueue` (see `allItemsRemoteCommand`).
    /// Synchronous and blocking, like `fetchCourse`; callers run this off the
    /// main actor.
    static func fetchAllItems(target: SSHTarget, product: String) throws -> [WorkItemRecord] {
        guard let safeProduct = validateLibraryProduct(product) else {
            throw FetchError.invalidInput(product)
        }
        let raw = try SessionAgent.run(
            allItemsArguments(target: target, product: safeProduct), classifyMissingCommand: false)
        return try decodeWorkItemRecords(raw)
    }

    /// The work items filed under one epic, fetched on the cockpit's first
    /// expand of that epic's row — see `CockpitModel.toggleExpansion`.
    /// Synchronous and blocking, like `fetchCourse` — see that function's
    /// doc; callers run this off the main actor. `parentId` is a Course
    /// entry's own id, read back from the Library's prior `GET /courses/{id}`
    /// response, so it is validated exactly as `fetchCourse` validates a
    /// course id read back the same way — see `validateLibraryId`'s doc.
    static func fetchChildItems(target: SSHTarget, parentId: String) throws -> [ChildItem] {
        guard let safeParentId = validateLibraryId(parentId) else {
            throw FetchError.invalidInput(parentId)
        }
        let raw = try SessionAgent.run(
            childItemsArguments(target: target, parentId: safeParentId), classifyMissingCommand: false)
        return try decodeChildItems(raw, expectedParentId: safeParentId)
    }

    /// The items found during one epic, fetched on the item detail pane's
    /// load when the opened item is itself an epic — see `ItemDetailPane`'s
    /// doc. Synchronous and blocking, like `fetchChildItems`; callers run
    /// this off the main actor. `epicId` is the pane's own loaded item id,
    /// validated the same way `fetchChildItems` validates a parent id.
    static func fetchFoundDuringItems(target: SSHTarget, epicId: String) throws -> [FoundDuringItem] {
        guard let safeEpicId = validateLibraryId(epicId) else {
            throw FetchError.invalidInput(epicId)
        }
        let raw = try SessionAgent.run(
            foundDuringItemsArguments(target: target, epicId: safeEpicId), classifyMissingCommand: false)
        return try decodeFoundDuringItems(raw, expectedFoundDuring: safeEpicId)
    }

    /// The full detail behind one corrections-queue row, for the detail pane
    /// — see `CorrectionDetail`'s doc. Synchronous and blocking, like
    /// `fetchCourse`; callers run this off the main actor. `id` is read back
    /// from the queue's own prior `GET /items` response, validated the same
    /// way `fetchChildItems` validates a parent id read back the same way.
    static func fetchCorrection(target: SSHTarget, id: String) throws -> CorrectionDetail {
        guard let safeId = validateLibraryId(id) else {
            throw FetchError.invalidInput(id)
        }
        let raw = try SessionAgent.run(
            itemArguments(target: target, itemId: safeId), classifyMissingCommand: false)
        return try decodeCorrectionDetail(raw)
    }

    // MARK: - Write

    /// Runs one Library POST — `argv` from one of the `*Arguments` builders
    /// above, `body` serialised to JSON and sent over the process's own
    /// stdin (see `remotePOSTCommand`'s doc for why) — and returns the
    /// decoded response object, or throws. Shared by every write verb below.
    private static func postJSON(argv: [String], body: [String: Any]) throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let payloadString = String(data: payload, encoding: .utf8) ?? "{}"
        let raw = try SessionAgent.run(argv, stdin: payloadString, classifyMissingCommand: false)
        let responseBody = try refusedOr200Body(raw)
        guard let object = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] else {
            throw FetchError.unexpectedResponse(String(data: responseBody, encoding: .utf8) ?? "(binary)")
        }
        return object
    }

    // MARK: - Write: approving a proposed epic

    /// The Library's own bound on `acting_human` — `store.MAX_ACTOR`,
    /// confirmed 200 against the deployed Library's source (`store.py:474`,
    /// 2026-09-22). Checked here so an over-length value refuses locally,
    /// before it reaches curl, rather than reaching the Library for the
    /// identical 403.
    static let maxActingHumanLength = 200

    /// `acting_human`, trimmed and bound-checked the same way the Library's
    /// own `identity.attested_human` checks it: non-empty after trimming,
    /// and no longer than `maxActingHumanLength`. Returns the trimmed value,
    /// or throws `FetchError.invalidActingHuman` with a
    /// words-an-operator-can-read reason — never a generic "invalid input",
    /// since there is no id or JSON here to point at instead.
    static func validateActingHuman(_ value: String, for action: String = "approval") throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FetchError.invalidActingHuman("Deck has no operator name to send with this \(action).")
        }
        guard trimmed.count <= maxActingHumanLength else {
            throw FetchError.invalidActingHuman(
                "Deck's operator name is \(trimmed.count) characters, over the Library's "
                + "\(maxActingHumanLength)-character limit.")
        }
        return trimmed
    }

    /// The body `approveEpic` sends, and the whole of what it sends but for
    /// `acting_human`.
    ///
    /// **A bare `{maturity, acting_human}` write approves a proposed epic;
    /// nothing else has to travel with it.** Read against the Library's
    /// `_approval_invariant` and `_do_approve` (`app.py`):
    ///
    /// - The demotion that forces `approved` back to `proposed` fires through
    ///   `_revokes_approval`, whose first line returns false unless the item's
    ///   CURRENT maturity is `approved`. A proposed epic carries no approval to
    ///   revoke, so resending `approved` here is not the "keeping `approved`
    ///   across a revoking change" case that comment names.
    /// - The only gate this write meets is the one every epic approval meets:
    ///   the stored `specification` and `definition_of_done` must both be
    ///   non-empty (`_spec_gaps`), or the route answers 400. That refusal is
    ///   the Library telling the operator the epic is not ready, so Deck
    ///   surfaces its text and does not try to satisfy it. An epic refused
    ///   this way is not editable from Deck — it is approved as it stands or
    ///   not at all, so nothing in Deck offers to edit its specification.
    /// - `owner` is not sent. With no live lease on the epic the route holds it
    ///   for this one write (`_hold_for_write`), so Deck takes no checkout and
    ///   leaves no lease behind.
    static func approveEpicBody(actingHuman: String) -> [String: Any] {
        ["maturity": approvedMaturity, "acting_human": actingHuman]
    }

    /// `approveEpic`'s argv, validated first: an id that fails
    /// `validateLibraryId` throws here and reaches no command string. Split
    /// out so a test can prove that without an ssh target. `acting_human`
    /// travels in the body, not argv, so it needs no such gate here —
    /// `approveEpic` validates it separately, via `validateActingHuman`.
    static func approveEpicArguments(
        target: SSHTarget, itemId: String, controlPath: String = defaultControlPath()
    ) throws -> [String] {
        guard let safeId = validateLibraryId(itemId) else {
            throw FetchError.invalidInput(itemId)
        }
        return arguments(target: target, remoteCommand: itemApproveRemoteCommand(itemId: safeId),
                         controlPath: controlPath)
    }

    /// Promotes one epic from `proposed` to `approved` and places it on its
    /// product's live Course, with no agent involved — `POST
    /// /items/{id}/approve`, under the approval credential
    /// (`WorkingCopyStore.libraryApprovalTokenFile`). Synchronous and
    /// blocking, like every fetch here; callers run it off the main actor.
    ///
    /// `actingHuman` is checked locally first (`validateActingHuman`) and
    /// throws `FetchError.invalidActingHuman` with an operator-facing reason
    /// rather than reaching the Library for a 403 it could have caught
    /// itself. Past that, a refusal throws `FetchError.libraryRefused`,
    /// which `approvalRefusalMessage` turns into words for the operator: a
    /// 409 while another session holds the epic or the product has no live
    /// Course, a 400 while the epic lacks a specification or definition of
    /// done, a 403 while the credential lacks `epic.approve` or
    /// `course.write`.
    static func approveEpic(target: SSHTarget, itemId: String, actingHuman: String) throws {
        let argv = try approveEpicArguments(target: target, itemId: itemId)
        let trimmed = try validateActingHuman(actingHuman)
        _ = try postJSON(argv: argv, body: approveEpicBody(actingHuman: trimmed))
    }

    /// What the Approve button says when the write did not land. The Library's
    /// refusals name what failed (§8), so this passes that text through, and
    /// for a 409 `reason: "held"` it names the holder and the expiry from the
    /// lease the refusal carries, since "held by someone" leaves the operator
    /// nothing to act on.
    ///
    /// `now`, `timeZone` and `locale` are parameters so a test can pin the
    /// clock; the expiry shows a date only when it is not today.
    static func approvalRefusalMessage(
        _ error: Error, retry: String = "Approve", now: Date = Date(), timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        switch error {
        case FetchError.libraryRefused(let status, let body):
            let object = (body.data(using: .utf8))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if status == 409, object?["reason"] as? String == "held" {
                let lease = object?["lease"] as? [String: Any]
                if let holder = lease?["holder"] as? String {
                    let until = (lease?["expires_at"] as? String).map {
                        " until " + expiryText($0, now: now, timeZone: timeZone, locale: locale)
                    } ?? ""
                    return "Held by \(holder)\(until). \(retry) again once they release it."
                }
            }
            if let message = object?["error"] as? String { return message }
            return "The Library refused (\(status)): \(body)"
        case FetchError.invalidInput(let value):
            return "That id is not usable: \(value)"
        case FetchError.invalidActingHuman(let reason), FetchError.invalidModelChoice(let reason):
            return reason
        default:
            return "\(error)"
        }
    }

    // MARK: - Write: an item's model choice

    /// The Library's bounds on the model and reason of `POST /items/{id}/model`
    /// (`library-protocol` §6.2): 64 and 300 characters after trimming.
    static let maxModelLength = 64
    static let maxModelReasonLength = 300

    /// The body `setItemModel` sends. `model` nil clears the choice and is
    /// sent as an explicit JSON null, because an absent `model` is a 400. A
    /// blank reason is omitted, since the Library stores it as absent anyway.
    /// `owner` is never sent: with no live lease the route holds the item for
    /// this one write, so Deck takes no checkout, as with Approve.
    ///
    /// Bounds are checked here so an over-length value refuses locally with
    /// words instead of reaching the Library for the same 400.
    static func itemModelBody(model: String?, reason: String?, actingHuman: String) throws -> [String: Any] {
        var body: [String: Any] = ["acting_human": actingHuman]
        if let model {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw FetchError.invalidModelChoice("Name a model to set, or use Clear to remove the choice.")
            }
            guard trimmed.count <= maxModelLength else {
                throw FetchError.invalidModelChoice(
                    "The model name is \(trimmed.count) characters, over the Library's \(maxModelLength)-character limit.")
            }
            body["model"] = trimmed
        } else {
            body["model"] = NSNull()
        }
        if let reason {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= maxModelReasonLength else {
                throw FetchError.invalidModelChoice(
                    "The reason is \(trimmed.count) characters, over the Library's \(maxModelReasonLength)-character limit.")
            }
            if !trimmed.isEmpty { body["reason"] = trimmed }
        }
        return body
    }

    /// `setItemModel`'s argv, validated first: an id that fails
    /// `validateLibraryId` throws here and reaches no command string.
    static func itemModelArguments(
        target: SSHTarget, itemId: String, controlPath: String = defaultControlPath()
    ) throws -> [String] {
        guard let safeId = validateLibraryId(itemId) else {
            throw FetchError.invalidInput(itemId)
        }
        return arguments(target: target, remoteCommand: itemModelRemoteCommand(itemId: safeId),
                         controlPath: controlPath)
    }

    /// Sets, or with `model` nil clears, the model on one work item. Whether
    /// the change is permitted is the Library's decision (the item.model
    /// capability, terminal states, leases); Deck sends the request and
    /// shows the answer. Nothing here dispatches anything or touches a run
    /// already dispatched. Synchronous and blocking; callers run it off the
    /// main actor. A refusal throws `FetchError.libraryRefused`, which
    /// `modelChoiceRefusalMessage` turns into words.
    static func setItemModel(
        target: SSHTarget, itemId: String, model: String?, reason: String?, actingHuman: String
    ) throws {
        let argv = try itemModelArguments(target: target, itemId: itemId)
        let trimmed = try validateActingHuman(actingHuman, for: "change")
        let body = try itemModelBody(model: model, reason: reason, actingHuman: trimmed)
        _ = try postJSON(argv: argv, body: body)
    }

    /// What the model control says when the write did not land: the
    /// Library's own text, and for a held item the holder and expiry.
    static func modelChoiceRefusalMessage(_ error: Error) -> String {
        approvalRefusalMessage(error, retry: "Try")
    }

    /// Whether the Item pane offers the model control. The Library refuses a
    /// change to a terminal item with a 409, so the control is absent there;
    /// it is also absent when the state is unknown, since Deck cannot tell.
    static func canSetModel(state: String?) -> Bool {
        guard let state else { return false }
        return !terminalWorkStates.contains(state)
    }

    /// The lines the pane draws for a choice, in the Library's own terms:
    /// the client is attested by its credential, the person is what that
    /// client reported.
    static func modelChoiceLines(_ choice: ModelChoice) -> [String] {
        var lines: [String] = []
        if let model = choice.model, !model.isEmpty {
            lines.append("Model: \(model)")
        } else {
            lines.append("Model: not readable from the Library's record")
        }
        if let reason = choice.reason, !reason.isEmpty { lines.append("Reason: \(reason)") }
        if let client = choice.setByClient {
            lines.append("Set through the \(client) client, as the Library attests from its credential")
        }
        if let person = choice.actingHuman, !person.isEmpty {
            lines.append("Named person: \(person), as that client reported; the Library has not verified it")
        }
        if let at = choice.setAt { lines.append("Set at: \(at)") }
        return lines
    }

    // MARK: - Write: reordering the Course

    /// The Course's order with `moving` placed where `target` sits: dropped
    /// below its old position it lands AFTER `target`, dropped above it lands
    /// BEFORE, the same rule as SwiftUI's own `move(fromOffsets:toOffset:)`.
    /// `nil` when the move changes nothing, or when either id is not in
    /// `served`, so a caller has no write to make.
    ///
    /// **`served` MUST BE `Course.servedEntryIds`, NEVER THE RENDERED ROWS.**
    /// The order route replaces the whole array, and `decodeCourse` drops any
    /// id with no resolved item. A move computed over the rendered rows would
    /// send an array without those ids and delete them from the Course
    /// permanently, with no error. Moving inside the served array leaves each
    /// unrendered id exactly where the Library had it relative to its
    /// neighbours.
    static func reorderedEntryIds(_ served: [String], moving: String, onto target: String) -> [String]? {
        guard moving != target,
              let from = served.firstIndex(of: moving),
              let to = served.firstIndex(of: target) else { return nil }
        var moved = served
        moved.remove(at: from)
        moved.insert(moving, at: to)
        return moved
    }

    /// The whole body `reorderCourse` sends. `version` is the one the
    /// operator's screen was drawn from, so a Course changed since is refused
    /// rather than overwritten (the route's own description: "the only route
    /// in the Library with real concurrency semantics").
    static func courseOrderBody(version: Int, entries: [String]) -> [String: Any] {
        ["version": version, "entries": entries]
    }

    /// `reorderCourse`'s argv, validated first: a Course id that fails
    /// `validateLibraryId` throws here and reaches no command string. The
    /// entry ids travel in the stdin body and never in the command, so they
    /// need no such gate.
    static func reorderCourseArguments(
        target: SSHTarget, courseId: String, controlPath: String = defaultControlPath()
    ) throws -> [String] {
        guard let safeId = validateLibraryId(courseId) else {
            throw FetchError.invalidInput(courseId)
        }
        return arguments(target: target, remoteCommand: courseOrderRemoteCommand(courseId: safeId),
                         controlPath: controlPath)
    }

    /// Replaces one Course's order. Synchronous and blocking, like every
    /// write here; callers run it off the main actor. `entries` is the full
    /// array, built by `reorderedEntryIds`. A refusal throws
    /// `FetchError.libraryRefused`, which `reorderRefusalMessage` turns into
    /// words.
    static func reorderCourse(
        target: SSHTarget, courseId: String, version: Int, entries: [String]
    ) throws {
        let argv = try reorderCourseArguments(target: target, courseId: courseId)
        _ = try postJSON(argv: argv, body: courseOrderBody(version: version, entries: entries))
    }

    /// Whether a refusal is the Library saying the Course moved since it was
    /// read: a 409 carrying `current_version`. A superseded Course is also a
    /// 409 (`this Course is superseded ...`) but carries no `current_version`,
    /// and telling the operator someone reordered it would be false, so the
    /// two are told apart by that field.
    ///
    /// Read from the Library's source (`app.py`'s `_do_set_course_order`)
    /// and its live openapi; the route's `200`/`422` there are FastAPI
    /// boilerplate, since the handler reads the body itself and answers 400,
    /// 409 or 503 by hand.
    static func isStaleVersionRefusal(_ error: Error) -> Bool {
        guard case FetchError.libraryRefused(let status, let body) = error, status == 409,
              let object = body.data(using: .utf8)
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
            return false
        }
        return object["current_version"] is NSNumber
    }

    /// What the Course panel says when a move did not land. A stale version
    /// says so plainly and does not offer to redo the move: Deck refuses and
    /// shows the Library's order rather than rebasing the operator's move onto
    /// it, because a silent rebase can land an epic somewhere the operator did
    /// not intend while they believe they placed it.
    ///
    /// Every other refusal passes the Library's own text through
    /// (`approvalRefusalMessage`'s shape), plus the ids it names. That is how
    /// the operator learns of an epic the Library will not accept in a
    /// reorder, such as an id Deck cannot resolve to an item.
    static func reorderRefusalMessage(_ error: Error) -> String {
        if isStaleVersionRefusal(error) {
            return "Someone else reordered the Course, so your move was not applied. "
                + "The order shown is now the Library's."
        }
        var message = approvalRefusalMessage(error)
        if case FetchError.libraryRefused(_, let body) = error,
           let object = body.data(using: .utf8)
               .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
            let named = ["unknown", "not_epics", "wrong_product", "duplicates"]
                .compactMap { object[$0] as? [String] }
                .flatMap { $0 }
            if !named.isEmpty { message += " (" + named.joined(separator: ", ") + ")" }
        }
        return message
    }

    /// An ISO-8601 instant as the operator's clock reads it, or the raw string
    /// when it does not parse, so a format drift on the Library's side costs
    /// the pretty time and never the holder's name.
    private static func expiryText(_ iso: String, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        guard let instant = ServedTimestamp.parse(iso) else { return iso }
        return ServedTimestamp.label(for: instant, now: now, timeZone: timeZone, locale: locale, templateSuffix: " z")
    }
}
