import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import Deck

/// `LibraryClient`'s pure pieces: the argv/remote-command builders (shape,
/// the protocol header, the token never in argv), and the decoders against
/// well-formed and malformed bodies. The Library itself is tested in the
/// Library's own repository; what is testable here is Deck's half of the
/// seam, the same split `SessionAgentTests` documents for `session-agent`.
final class LibraryClientTests: XCTestCase {
    // MARK: - The queue holds two states, and pr-open leads

    /// **THE COMMA FORM IS A TRAP AND THIS LOCKS THE SHAPE THAT ISN'T.**
    /// Measured against the running Library on 2026-09-04, `state=open,pr-open`
    /// returns HTTP 200 with zero items while each single value returns rows.
    /// A caller that joined them would draw an empty queue and see a success
    /// code, so the command must carry exactly one state.
    func testItemsCommandCarriesExactlyOneState() {
        for state in LibraryClient.queueStates {
            let command = LibraryClient.itemsRemoteCommand(product: "vivy", state: state)
            XCTAssertTrue(command.contains("state=\(state.rawValue)"),
                          "missing state=\(state.rawValue)")
            XCTAssertFalse(command.contains(","), "a comma in the state filter returns nothing")
        }
    }

    /// `pr-open` is fetched and appended first, so finished work waiting on a
    /// person sits above work nobody has started. `.claimed` joined `.open`
    /// and `.prOpen` for `issue_01M1Y7AKMRQ4S7K9CX5R99ZMPQ` — a claim expires
    /// without the Library ever moving the item out of `state: claimed`, so
    /// leaving it out of this list left a lapsed claim invisible everywhere.
    func testQueueStatesIsPROpenOpenClaimedInThatOrder() {
        XCTAssertEqual(LibraryClient.queueStates, [.prOpen, .open, .claimed])
    }

    /// The row's mark is driven off the decoded state, so a record that
    /// omitted it draws as an ordinary row rather than as a guess.
    func testAwaitingPRReadsTheDecodedState() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i1","title":"one","state":"pr-open"},
                  {"id":"i2","title":"two","state":"open"},
                  {"id":"i3","title":"three"}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.count, 3)
        XCTAssertTrue(queue.items[0].isAwaitingPR)
        XCTAssertFalse(queue.items[1].isAwaitingPR)
        XCTAssertFalse(queue.items[2].isAwaitingPR, "a missing state is not a pr-open row")
    }

    /// **THE DEFECT THIS ISSUE FIXES.** `severity` was decoded and never read
    /// for ordering, so a `high` item sat wherever the Library's newest-first
    /// order happened to put it — sixth, on 2026-09-04, behind an "N more"
    /// expander. Given `low`, `high`, `medium` in that arrival order, the
    /// decoded queue must read `high`, `medium`, `low`.
    func testSeverityOrdersItemsWithinAStateGroup() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i-low","title":"low one","state":"open","severity":"low"},
                  {"id":"i-high","title":"high one","state":"open","severity":"high"},
                  {"id":"i-medium","title":"medium one","state":"open","severity":"medium"}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.map(\.id), ["i-high", "i-medium", "i-low"])
    }

    /// A `pr-open` item still leads even a `high`-severity `open` item —
    /// `LibraryClient.queueStates`' state grouping is the product's own call and severity
    /// orders only within it, never across it.
    func testPROpenLeadsEvenAHighSeverityOpenItem() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i-open-high","title":"high, open","state":"open","severity":"high"},
                  {"id":"i-pr","title":"pr-open, no severity","state":"pr-open"}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.map(\.id), ["i-pr", "i-open-high"])
    }

    /// **THE DEFECT `issue_01M1Y7AKMRQ4S7K9CX5R99ZMPQ` FIXES.** A `claimed`
    /// page — the one `.claimed` in `queueStates` now asks the Library for —
    /// decodes both a live and a lapsed claim, and each carries the fields
    /// `CockpitView.correctionsQueueContent` needs to draw them differently:
    /// the live one's holder, the lapsed one's `claimExpired` flag.
    func testClaimedItemsDecodeBothLiveAndExpired() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i-live","title":"live claim","state":"claimed",
                   "claimed_by":"agent-x","claim_expired":false},
                  {"id":"i-expired","title":"expired claim","state":"claimed",
                   "claimed_by":"agent-y","claim_expired":true}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.count, 2)
        let live = try XCTUnwrap(queue.items.first { $0.id == "i-live" })
        XCTAssertEqual(live.claimedBy, "agent-x")
        XCTAssertFalse(live.claimExpired)
        let expired = try XCTUnwrap(queue.items.first { $0.id == "i-expired" })
        XCTAssertEqual(expired.claimedBy, "agent-y")
        XCTAssertTrue(expired.claimExpired)
    }

    /// A `claimed` item with no `claimed_by`/`claim_expired` on the wire
    /// decodes as not claimed — the same absent-means-`false`,
    /// absent-means-`nil` discipline as every other claim field in this
    /// file. Neither `state == "claimed"` alone nor a missing holder should
    /// crash or fabricate a name.
    func testClaimedFieldsDegradeWhenAbsent() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i1","title":"one","state":"claimed"}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertNil(queue.items.first?.claimedBy)
        XCTAssertFalse(queue.items.first?.claimExpired ?? true)
    }

    /// A `claimed` item sorts exactly where an `open` one with the same
    /// severity would — no third tier ahead of or behind `open`, live or
    /// lapsed.
    func testClaimedItemSortsWithOpenNotAsAThirdTier() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i-claimed-high","title":"claimed high","state":"claimed",
                   "severity":"high","claimed_by":"agent-x","claim_expired":false},
                  {"id":"i-open-low","title":"open low","state":"open","severity":"low"},
                  {"id":"i-pr","title":"pr open","state":"pr-open"}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.map(\.id), ["i-pr", "i-claimed-high", "i-open-low"])
    }

    /// A missing or unrecognised severity word sorts after every known one —
    /// degrading the row to "not claimed urgent" rather than dropping it or
    /// crashing on a word this client has never seen.
    func testMissingOrUnknownSeveritySortsLast() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i-none","title":"no severity","state":"open"},
                  {"id":"i-weird","title":"unrecognised word","state":"open","severity":"urgent-ish"},
                  {"id":"i-high","title":"high one","state":"open","severity":"high"}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.first?.id, "i-high")
        XCTAssertEqual(Set(queue.items.dropFirst().map(\.id)), Set(["i-none", "i-weird"]))
    }

    /// Two items tied on both state and severity keep the order they arrived
    /// in — the Library's own newest-first — rather than the sort scrambling
    /// ties. This is what would break silently if the severity sort were
    /// swapped for an unstable one.
    func testEqualSeverityItemsKeepArrivalOrder() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i-newer","title":"newer","state":"open","severity":"high"},
                  {"id":"i-older","title":"older","state":"open","severity":"high"}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.map(\.id), ["i-newer", "i-older"])
    }

    // MARK: - Topic grouping (issue_01M2298XAXW03K3GAF2FJ144J6)

    /// The field the Library returns on every item, decoded rather than
    /// dropped — the whole reason `QueueItem` had no way to group before
    /// this.
    func testQueueItemDecodesTopics() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i1","title":"one","state":"open","topics":["lock","stale-claims"]}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.first?.topics, ["lock", "stale-claims"])
    }

    /// A record carrying no `topics` key — an older Library, or a genuinely
    /// untriaged item — decodes to an empty array rather than throwing or
    /// crashing, the same absent-costs-nothing discipline as `severity` and
    /// every other optional field this decoder reads.
    func testQueueItemDefaultsTopicsToEmptyArrayWhenAbsent() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i1","title":"one","state":"open"}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.first?.topics, [])
    }

    /// `GET /items?product=&state=` carries `prerequisites` and `blocked`
    /// on every item, same as the Course and child-item routes.
    func testQueueItemDecodesPrerequisitesAndBlocked() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i1","title":"one","state":"open","blocked":true,
                   "prerequisites":[{"text":"a condition","met":false}]}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        let item = try XCTUnwrap(queue.items.first)
        XCTAssertTrue(item.blocked)
        XCTAssertEqual(item.prerequisites, [.text(text: "a condition", met: false, judgedBy: nil, judgedAt: nil)])
    }

    /// A record predating these fields still decodes.
    func testQueueItemWithNoPrerequisitesOrBlockedStillDecodes() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i1","title":"one","state":"open"}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        let item = try XCTUnwrap(queue.items.first)
        XCTAssertEqual(item.prerequisites, [])
        XCTAssertFalse(item.blocked)
    }

    /// `GET /items?product=&state=` carries `key`, `pr`, `pr_url` and
    /// `pr_repo` on every item (Library, commit ea76e7d, verified
    /// 2026-10-01) — `pr` is a STRING, never a number, so `prNumber` is what
    /// parses it.
    func testQueueItemDecodesTheKeyAndPRFields() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i1","title":"one","state":"pr-open","key":"CQ·63",
                   "pr":"297","pr_url":"https://github.com/convivy/convivy-deck/pull/297",
                   "pr_repo":"convivy/convivy-deck"}]}
        """#)
        let item = try XCTUnwrap(LibraryClient.decodeCorrectionsQueue(raw).items.first)
        XCTAssertEqual(item.key, "CQ·63")
        XCTAssertEqual(item.pr, "297")
        XCTAssertEqual(item.prNumber, 297)
        XCTAssertEqual(item.prURL, "https://github.com/convivy/convivy-deck/pull/297")
        XCTAssertEqual(item.prRepo, "convivy/convivy-deck")
    }

    /// A record carrying none of the four — predates the fields, or
    /// genuinely has no PR — degrades to `nil` on every one, per field,
    /// rather than throwing or guessing.
    func testQueueItemWithNoKeyOrPRFieldsStillDecodes() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i1","title":"one","state":"open"}]}
        """#)
        let item = try XCTUnwrap(LibraryClient.decodeCorrectionsQueue(raw).items.first)
        XCTAssertNil(item.key)
        XCTAssertNil(item.pr)
        XCTAssertNil(item.prNumber)
        XCTAssertNil(item.prURL)
        XCTAssertNil(item.prRepo)
    }

    /// `pr` sent as something other than a decimal string (malformed, or a
    /// future Library sending a bare number some other way) parses to `nil`
    /// rather than crashing or guessing a number out of it.
    func testQueueItemPRNumberIsNilWhenPRIsNotADecimalString() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i1","title":"one","state":"open","pr":"not-a-number"}]}
        """#)
        let item = try XCTUnwrap(LibraryClient.decodeCorrectionsQueue(raw).items.first)
        XCTAssertEqual(item.pr, "not-a-number")
        XCTAssertNil(item.prNumber)
    }

    /// **THE DEFECT THIS ISSUE FIXES.** Before topic grouping, sorting on
    /// `(isAwaitingPR, severity)` alone put every `pr-open` item ahead of
    /// every `open` item regardless of topic, so a topic's own two items
    /// landed on opposite ends of the list — `lock-pr`'s neighbour was
    /// `automation-pr`, not `lock-open`. Grouping must put both `lock` items
    /// together, with `lock-pr` still leading `lock-open` inside that group.
    func testTopicGroupsTheQueueWithAwaitingPRStillOrderingWithinIt() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"automation-pr","title":"automation pr","state":"pr-open","topics":["automation"]},
                  {"id":"lock-open","title":"lock open","state":"open","topics":["lock"]},
                  {"id":"lock-pr","title":"lock pr","state":"pr-open","topics":["lock"]}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        // "automation" sorts before "lock" alphabetically, so its one item
        // leads; the two "lock" items follow together, pr-open first within
        // that group rather than at the very top of the whole list.
        XCTAssertEqual(queue.items.map(\.id), ["automation-pr", "lock-pr", "lock-open"])
    }

    /// Two topics both sort ahead of severity — a `high`-severity item in
    /// one topic must not jump ahead of a `low`-severity item filed under an
    /// alphabetically earlier topic.
    func testTopicsSortAlphabeticallyAheadOfSeverity() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"b-low","title":"b low","state":"open","severity":"low","topics":["b-topic"]},
                  {"id":"a-high","title":"a high","state":"open","severity":"high","topics":["a-topic"]}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.map(\.id), ["a-high", "b-low"])
    }

    /// An item with no topic is not dropped and does not fold into a false
    /// "" group ahead of real topics — it sorts after every named topic, so
    /// the reader finds the deliberately-grouped work first and the leftover
    /// bucket at the bottom rather than scattered through the middle.
    func testItemsWithNoTopicSortAfterEveryNamedTopic() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"no-topic","title":"untriaged","state":"open","severity":"high"},
                  {"id":"z-topic-item","title":"z topic","state":"open","severity":"low","topics":["z-topic"]}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.map(\.id), ["z-topic-item", "no-topic"],
                       "a high-severity no-topic item must still sort after a low-severity named-topic one")
    }

    /// An item naming several topics groups under the first — the array
    /// exists because the field does, but grouping draws the row once, not
    /// once per topic it carries.
    func testAnItemWithSeveralTopicsGroupsUnderTheFirst() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"multi","title":"multi-topic","state":"open","topics":["a-topic","z-topic"]},
                  {"id":"z-solo","title":"z solo","state":"open","topics":["z-topic"]}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.map(\.id), ["multi", "z-solo"],
                       "grouped under \"a-topic\" (its first entry), ahead of the \"z-topic\"-only item")
    }

    /// `sort=topic` reaches the wire on every items request — Deck's own
    /// sort still has to group across pages and states (see
    /// `fetchCorrectionsQueue`'s doc), but requesting it server-side keeps a
    /// topic's rows from being scattered across a page boundary in the
    /// first place.
    func testItemsRemoteCommandRequestsSortByTopic() {
        let command = LibraryClient.itemsRemoteCommand(product: "convivy-deck", state: .open)
        XCTAssertTrue(command.contains("sort=topic"))
    }

    // MARK: - Input validation

    func testValidProductNamesAreAccepted() {
        XCTAssertEqual(LibraryClient.validateLibraryProduct("convivy-deck"), "convivy-deck")
        XCTAssertEqual(LibraryClient.validateLibraryProduct("bosun"), "bosun")
    }

    func testProductNamesWithShellCharactersAreRejected() {
        XCTAssertNil(LibraryClient.validateLibraryProduct(""))
        XCTAssertNil(LibraryClient.validateLibraryProduct("convivy deck"))
        XCTAssertNil(LibraryClient.validateLibraryProduct("$(rm -rf ~)"))
        XCTAssertNil(LibraryClient.validateLibraryProduct("a\"; curl evil.example --"))
        XCTAssertNil(LibraryClient.validateLibraryProduct("a/b"))
        XCTAssertNil(LibraryClient.validateLibraryProduct(String(repeating: "a", count: 65)))
    }

    func testValidLibraryIdsAreAccepted() {
        XCTAssertEqual(LibraryClient.validateLibraryId("course_01M0D6NN1FRHP5Y0Q994DJ6NJ2"),
                       "course_01M0D6NN1FRHP5Y0Q994DJ6NJ2")
    }

    func testLibraryIdsWithShellCharactersAreRejected() {
        XCTAssertNil(LibraryClient.validateLibraryId(""))
        XCTAssertNil(LibraryClient.validateLibraryId("course_01`whoami`"))
        XCTAssertNil(LibraryClient.validateLibraryId("../../etc/passwd"))
    }

    // MARK: - Remote commands

    func testEveryRemoteCommandCarriesTheProtocolHeader() {
        XCTAssertTrue(LibraryClient.coursesListRemoteCommand(product: "convivy-deck")
            .contains("Library-Protocol: 1"))
        XCTAssertTrue(LibraryClient.courseRemoteCommand(courseId: "course_01ABC")
            .contains("Library-Protocol: 1"))
        XCTAssertTrue(LibraryClient.itemsRemoteCommand(product: "convivy-deck", state: .open)
            .contains("Library-Protocol: 1"))
        XCTAssertTrue(LibraryClient.beadsListRemoteCommand()
            .contains("Library-Protocol: 1"))
    }

    func testBeadsListRemoteCommandFiltersByKind() {
        XCTAssertTrue(LibraryClient.beadsListRemoteCommand().contains("/reference/documents?kind=bead"))
    }

    /// The token is read into curl's config over stdin — `--config -` — and
    /// never appears as a `-H "Authorization: ..."` argument, the same
    /// discipline `WorkingCopyStore.libraryDocumentRemoteCommand` documents
    /// at length. Pinned here so a future edit that "simplifies" this back
    /// to a `-H` argument fails a test rather than shipping a token visible
    /// to every account on the mini via `ps`.
    func testTheTokenNeverReachesTheCommandAsAHeaderArgument() {
        let command = LibraryClient.itemsRemoteCommand(product: "convivy-deck", state: .open)
        XCTAssertTrue(command.contains("--config -"))
        XCTAssertFalse(command.contains("-H \"Authorization"))
        XCTAssertFalse(command.contains("-H 'Authorization"))
    }

    func testItemsRemoteCommandFiltersByProductAndOpenState() {
        let command = LibraryClient.itemsRemoteCommand(product: "convivy-deck", state: .open)
        XCTAssertTrue(command.contains("/items?product=convivy-deck&state=open"))
    }

    /// No `state=` parameter — `BeadProgress.compute`'s denominator needs
    /// every epic, resolved or not.
    func testEpicsRemoteCommandFiltersByProductAndTypeWithNoStateParameter() {
        let command = LibraryClient.epicsRemoteCommand(product: "convivy-deck")
        XCTAssertTrue(command.contains("/items?product=convivy-deck&type=epic"))
        XCTAssertFalse(command.contains("state="))
    }

    /// No `state=` parameter and no `type=` parameter — the chip join's own
    /// read needs every item of every state and type
    /// (issue_01M3WPNJ1ESJVCVJ85FVNQHNKC).
    func testAllItemsRemoteCommandFiltersByProductWithNoStateOrTypeParameter() {
        let command = LibraryClient.allItemsRemoteCommand(product: "convivy-deck")
        XCTAssertTrue(command.contains("/items?product=convivy-deck&limit=200"))
        XCTAssertFalse(command.contains("state="))
        XCTAssertFalse(command.contains("type="))
    }

    func testCoursesListRemoteCommandFiltersByProduct() {
        let command = LibraryClient.coursesListRemoteCommand(product: "convivy-deck")
        XCTAssertTrue(command.contains("/courses?product=convivy-deck"))
    }

    func testCourseRemoteCommandAddressesTheGivenId() {
        let command = LibraryClient.courseRemoteCommand(courseId: "course_01ABC")
        XCTAssertTrue(command.contains("/courses/course_01ABC"))
    }

    // MARK: - argv

    func testEveryArgvBuilderCarriesTheControlMasterAndAddressesTheTarget() {
        let target = SSHTarget(user: "operator", host: "10.0.0.5")
        let courses = LibraryClient.coursesListArguments(target: target, product: "convivy-deck")
        let course = LibraryClient.courseArguments(target: target, courseId: "course_01ABC")
        let items = LibraryClient.itemsArguments(target: target, product: "convivy-deck", state: .open)
        let beads = LibraryClient.beadsListArguments(target: target)
        for args in [courses, course, items, beads] {
            XCTAssertTrue(args.contains("ControlMaster=auto"))
            XCTAssertTrue(args.contains("operator@10.0.0.5"))
        }
    }

    /// The token file's path is read on the MINI, inside the remote command
    /// string — it never becomes its own argv element the way a `-H` value
    /// would. This asserts the stronger, argv-level version of
    /// `testTheTokenNeverReachesTheCommandAsAHeaderArgument`: no element of
    /// the argv array Deck hands to `Process` is an `Authorization` header.
    func testNoArgvElementCarriesAnAuthorizationHeader() {
        let args = LibraryClient.itemsArguments(target: TestHost.target, product: "convivy-deck", state: .open)
        XCTAssertFalse(args.contains { $0.hasPrefix("Authorization") || $0.contains("-H \"Authorization") })
    }

    // MARK: - Decode: courses list

    func testDecodesCoursesListIds() throws {
        let raw = curlResponse(status: 200, body: """
        {"courses":[{"id":"course_01ABC","product":"convivy-deck"}],"count":1,"total":1,"offset":0,"truncated":false}
        """)
        XCTAssertEqual(try LibraryClient.decodeCoursesList(raw), ["course_01ABC"])
    }

    func testDecodesAnEmptyCoursesListToNoIds() throws {
        let raw = curlResponse(status: 200, body: """
        {"courses":[],"count":0,"total":0,"offset":0,"truncated":false}
        """)
        XCTAssertEqual(try LibraryClient.decodeCoursesList(raw), [])
    }

    func testCoursesListRefusalThrowsLibraryRefused() {
        let raw = curlResponse(status: 403, body: #"{"error":"forbidden","hint":"no capability"}"#)
        XCTAssertThrowsError(try LibraryClient.decodeCoursesList(raw)) { error in
            guard case LibraryClient.FetchError.libraryRefused(let status, _) = error else {
                return XCTFail("expected .libraryRefused, got \(error)")
            }
            XCTAssertEqual(status, 403)
        }
    }

    func testUnparseableCoursesListBodyThrowsUnexpectedResponse() {
        let raw = curlResponse(status: 200, body: "not json")
        XCTAssertThrowsError(try LibraryClient.decodeCoursesList(raw)) { error in
            guard case LibraryClient.FetchError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }

    // MARK: - Decode: course

    /// The shape confirmed against the running Library: `entries` is an
    /// ordered array of ids, `items` the resolved objects. `entries` is the
    /// order authority per `decodeCourse`'s doc — asserted here by giving
    /// `items` a DIFFERENT order than `entries` and checking the result
    /// follows `entries`.
    func testDecodesACourseInEntriesOrderRegardlessOfItemsOrder() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","product":"convivy-deck","title":"The Course",
         "entries":["issue_A","issue_B"],
         "items":[
           {"id":"issue_B","title":"Second on the route","type":"epic","state":"open"},
           {"id":"issue_A","title":"First on the route","type":"epic","state":"fixed","resolution":"fixed"}
         ]}
        """)
        let course = try LibraryClient.decodeCourse(raw)
        XCTAssertEqual(course.id, "course_01ABC")
        XCTAssertEqual(course.product, "convivy-deck")
        XCTAssertEqual(course.entries.map(\.id), ["issue_A", "issue_B"])
        XCTAssertEqual(course.entries.first?.title, "First on the route")
    }

    /// An entry with no matching resolved item is dropped, not fatal —
    /// per-field degrade at the entry level.
    func testACourseEntryWithNoResolvedItemIsDropped() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","entries":["issue_A","issue_MISSING"],
         "items":[{"id":"issue_A","title":"Only this one resolved"}]}
        """)
        let course = try LibraryClient.decodeCourse(raw)
        XCTAssertEqual(course.entries.map(\.id), ["issue_A"])
    }

    /// A duplicate id in `items` must not crash the decoder —
    /// `Dictionary(uniqueKeysWithValues:)` would trap on this input, which is
    /// exactly why `decodeCourse` builds the lookup table by hand.
    func testDuplicateIdsInItemsDoNotCrashTheDecoder() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","entries":["issue_A"],
         "items":[{"id":"issue_A","title":"First"},{"id":"issue_A","title":"Second wins"}]}
        """)
        let course = try LibraryClient.decodeCourse(raw)
        XCTAssertEqual(course.entries.first?.title, "Second wins")
    }

    func testAnEmptyCourseDecodesToNoEntries() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01EMPTY","product":"convivy-deck","title":"Nothing yet","entries":[],"items":[]}
        """)
        let course = try LibraryClient.decodeCourse(raw)
        XCTAssertEqual(course.id, "course_01EMPTY")
        XCTAssertTrue(course.entries.isEmpty)
    }

    func testACourseWithNoIdThrowsUnexpectedResponse() {
        let raw = curlResponse(status: 200, body: #"{"product":"convivy-deck","entries":[],"items":[]}"#)
        XCTAssertThrowsError(try LibraryClient.decodeCourse(raw)) { error in
            guard case LibraryClient.FetchError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }

    /// The five fields the cockpit's epic detail draws — `body`,
    /// `specification`, `definition_of_done`, `severity`, `needs`,
    /// `claimed_by` — all arrive on the same `GET /courses/{id}` response
    /// already decoded for `type`/`state`; this is what confirms the widened
    /// struct actually reads them rather than silently discarding them.
    /// `claim_expired: true` is included here too, pinning that a lapsed
    /// claim decodes as lapsed — see `LibraryClient.CourseEntry.claimExpired`'s
    /// doc for why the absent/null cases (below) matter just as much.
    func testACourseEntryDecodesTheWidenedFields() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","entries":["issue_A"],
         "items":[{"id":"issue_A","title":"An epic","body":"Full write-up",
                   "specification":"Do the thing","definition_of_done":"Tests pass",
                   "severity":"high","needs":["issue_B","issue_C"],"claimed_by":"agent-x",
                   "claim_expired":true}]}
        """)
        let entry = try XCTUnwrap(LibraryClient.decodeCourse(raw).entries.first)
        XCTAssertEqual(entry.body, "Full write-up")
        XCTAssertEqual(entry.specification, "Do the thing")
        XCTAssertEqual(entry.definitionOfDone, "Tests pass")
        XCTAssertEqual(entry.severity, "high")
        XCTAssertEqual(entry.needs, ["issue_B", "issue_C"])
        XCTAssertEqual(entry.claimedBy, "agent-x")
        XCTAssertTrue(entry.claimExpired)
    }

    /// A response predating these fields (or an item missing them) still
    /// decodes — per-field degrade, the same discipline every other decoder
    /// in this file follows. An absent `claim_expired` decodes to `false`,
    /// not `true` — the item carries no `claimed_by` here either, and a
    /// never-claimed item must never read as one whose claim lapsed.
    func testACourseEntryWithNoWidenedFieldsStillDecodes() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","entries":["issue_A"],
         "items":[{"id":"issue_A","title":"An epic"}]}
        """)
        let entry = try XCTUnwrap(LibraryClient.decodeCourse(raw).entries.first)
        XCTAssertNil(entry.body)
        XCTAssertNil(entry.specification)
        XCTAssertNil(entry.definitionOfDone)
        XCTAssertNil(entry.severity)
        XCTAssertEqual(entry.needs, [])
        XCTAssertNil(entry.claimedBy)
        XCTAssertFalse(entry.claimExpired)
    }

    /// `claim_expired: false` decodes as live — the mirror of the `true`
    /// case pinned above, on an item that DOES carry a holder.
    func testACourseEntryWithAClaimExpiredFalseDecodesAsLive() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","entries":["issue_A"],
         "items":[{"id":"issue_A","title":"An epic","claimed_by":"agent-x","claim_expired":false}]}
        """)
        let entry = try XCTUnwrap(LibraryClient.decodeCourse(raw).entries.first)
        XCTAssertFalse(entry.claimExpired)
    }

    /// An explicit JSON `null` for `claim_expired` decodes to `false`, the
    /// same as an absent key — `item["claim_expired"] as? Bool` returns `nil`
    /// for `NSNull` exactly as it does for a missing key, so both shapes take
    /// the same `?? false` fallback. Getting this inverted (null reading as
    /// `true`) would make every live claim in a response that carries the key
    /// explicitly draw as lapsed, which looks like a working fix while being
    /// the same defect in the other direction.
    func testACourseEntryWithAnExplicitNullClaimExpiredDecodesAsLive() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","entries":["issue_A"],
         "items":[{"id":"issue_A","title":"An epic","claimed_by":"agent-x","claim_expired":null}]}
        """)
        let entry = try XCTUnwrap(LibraryClient.decodeCourse(raw).entries.first)
        XCTAssertFalse(entry.claimExpired)
    }

    /// `GET /courses/{id}` carries `key`, `pr`, `pr_url` and `pr_repo` on
    /// every epic (Library, commit ea76e7d, verified 2026-10-01) — the same
    /// four fields the corrections queue and the child-item route carry.
    func testACourseEntryDecodesTheKeyAndPRFields() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","entries":["issue_A"],
         "items":[{"id":"issue_A","title":"An epic","key":"E16",
                   "pr":"297","pr_url":"https://github.com/convivy/convivy-deck/pull/297",
                   "pr_repo":"convivy/convivy-deck"}]}
        """)
        let entry = try XCTUnwrap(LibraryClient.decodeCourse(raw).entries.first)
        XCTAssertEqual(entry.key, "E16")
        XCTAssertEqual(entry.pr, "297")
        XCTAssertEqual(entry.prNumber, 297)
        XCTAssertEqual(entry.prURL, "https://github.com/convivy/convivy-deck/pull/297")
        XCTAssertEqual(entry.prRepo, "convivy/convivy-deck")
    }

    /// An entry carrying none of the four degrades to `nil` on every one,
    /// per field — a response predating the fields, or a genuinely open
    /// epic with no PR against it.
    func testACourseEntryWithNoKeyOrPRFieldsStillDecodes() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","entries":["issue_A"],
         "items":[{"id":"issue_A","title":"An epic"}]}
        """)
        let entry = try XCTUnwrap(LibraryClient.decodeCourse(raw).entries.first)
        XCTAssertNil(entry.key)
        XCTAssertNil(entry.pr)
        XCTAssertNil(entry.prNumber)
        XCTAssertNil(entry.prURL)
        XCTAssertNil(entry.prRepo)
    }

    /// The Library retired `parked` (library#110) but still serves
    /// `park_reason`, `unpark_condition` and `parked_at` on the items that
    /// were once parked, as history. An entry carrying them decodes on its
    /// current state, and Deck reads the history fields into nothing.
    func testACourseEntryWithParkHistoryDecodesOnItsCurrentState() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","entries":["issue_A"],
         "items":[{"id":"issue_A","title":"An epic","state":"claimed",
                   "park_reason":"waiting on a design call",
                   "unpark_condition":"the operator picks a palette",
                   "parked_at":"2026-08-27T10:00:00Z"}]}
        """)
        let entry = try XCTUnwrap(LibraryClient.decodeCourse(raw).entries.first)
        XCTAssertEqual(entry.state, "claimed")
        XCTAssertEqual(entry.title, "An epic")
    }

    // MARK: - Decode: prerequisites and blocked (ADR-0074, comment 2261)

    /// The three entry shapes comment 2261 on `issue_01M27E11MEH73Y66K7EEKPMAHN`
    /// settled, decoded directly rather than through a full course response —
    /// `decodePrerequisites` is what `decodeCourse`, `decodeChildItems`, and
    /// `decodeQueueItemsPage` all call, so pinning it here covers all three.
    func testDecodePrerequisitesReadsAReadableItemEntry() {
        let entries = LibraryClient.decodePrerequisites(
            [["item": "issue_BLOCKER", "state": "open", "title": "The blocking item"]])
        XCTAssertEqual(entries, [.item(id: "issue_BLOCKER", title: "The blocking item", state: "open")])
    }

    /// `{item, missing: true}` — the same shape `GET /courses/{id}` gives an
    /// entry the reader cannot see. Comment 2261: never dropped.
    func testDecodePrerequisitesReadsAMissingItemEntry() {
        let entries = LibraryClient.decodePrerequisites(
            [["item": "issue_HIDDEN", "missing": true]])
        XCTAssertEqual(entries, [.missingItem(id: "issue_HIDDEN")])
    }

    /// `{text, met, judged_by, judged_at}` — a testable condition rather
    /// than another item.
    func testDecodePrerequisitesReadsATextEntry() {
        let entries = LibraryClient.decodePrerequisites(
            [["text": "the design review happens", "met": true,
              "judged_by": "agent-x", "judged_at": "2026-09-10T10:00:00Z"]])
        XCTAssertEqual(entries, [.text(text: "the design review happens", met: true,
                                       judgedBy: "agent-x", judgedAt: "2026-09-10T10:00:00Z")])
    }

    /// A text entry with no `met`/`judged_by`/`judged_at` still decodes —
    /// `met` defaults to `false`, the same absent-costs-nothing discipline
    /// every other bool in this file follows.
    func testDecodePrerequisitesReadsAnUnmetTextEntryWithNoJudgment() {
        let entries = LibraryClient.decodePrerequisites([["text": "a condition"]])
        XCTAssertEqual(entries, [.text(text: "a condition", met: false, judgedBy: nil, judgedAt: nil)])
    }

    /// An entry matching none of the three known shapes — here, an `item`
    /// entry with no `title` and no `missing` flag — is dropped without
    /// dropping its siblings, the same "field costs itself" discipline the
    /// rest of this file follows for a single malformed record.
    func testDecodePrerequisitesDropsAnUnparseableEntryWithoutDroppingItsSiblings() {
        let entries = LibraryClient.decodePrerequisites(
            [["item": "issue_NO_TITLE"],
             ["item": "issue_GOOD", "state": "open", "title": "Fine"]])
        XCTAssertEqual(entries, [.item(id: "issue_GOOD", title: "Fine", state: "open")])
    }

    /// An absent or non-array `prerequisites` decodes to `[]` rather than
    /// throwing.
    func testDecodePrerequisitesDecodesAbsentToEmptyArray() {
        XCTAssertEqual(LibraryClient.decodePrerequisites(nil), [])
        XCTAssertEqual(LibraryClient.decodePrerequisites("not an array"), [])
    }

    /// `GET /courses/{id}` carries `prerequisites` and `blocked` on every
    /// item — this pins that `decodeCourse` actually reads both rather than
    /// silently discarding them, the same round-trip
    /// `testACourseEntryDecodesTheWidenedFields` pins for the older fields.
    func testACourseEntryDecodesPrerequisitesAndBlocked() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","entries":["issue_A"],
         "items":[{"id":"issue_A","title":"An epic","blocked":true,
                   "prerequisites":[{"item":"issue_B","state":"open","title":"Blocker"}]}]}
        """)
        let entry = try XCTUnwrap(LibraryClient.decodeCourse(raw).entries.first)
        XCTAssertTrue(entry.blocked)
        XCTAssertEqual(entry.prerequisites, [.item(id: "issue_B", title: "Blocker", state: "open")])
    }

    /// A response predating these fields still decodes — `prerequisites`
    /// degrades to `[]`, `blocked` to `false`.
    func testACourseEntryWithNoPrerequisitesOrBlockedStillDecodes() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","entries":["issue_A"],
         "items":[{"id":"issue_A","title":"Not blocked"}]}
        """)
        let entry = try XCTUnwrap(LibraryClient.decodeCourse(raw).entries.first)
        XCTAssertEqual(entry.prerequisites, [])
        XCTAssertFalse(entry.blocked)
    }

    func testACourseWithAMalformedTitleStillDecodesEveryOtherField() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"course_01ABC","product":"convivy-deck","title":42,"entries":[],"items":[]}
        """)
        let course = try LibraryClient.decodeCourse(raw)
        XCTAssertEqual(course.id, "course_01ABC")
        XCTAssertNil(course.title)
    }

    // MARK: - Decode: corrections queue

    func testDecodesTheCorrectionsQueueWithTotal() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A","title":"A bug","type":"bug","severity":"low"}],
         "count":1,"total":1,"offset":0,"truncated":false}
        """)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.total, 1)
        XCTAssertEqual(queue.items.map(\.id), ["issue_A"])
        XCTAssertEqual(queue.items.first?.severity, "low")
    }

    /// `total` ignores the envelope even when the response is complete (30
    /// items returned, envelope `total` also 30): 10 of the 30 are epics, so
    /// `queue.total` must read 20, the survivor count, not 30.
    func testCompleteResponseSubtractsDroppedItemsFromEnvelopeTotal() throws {
        let epics = (0..<10).map { "{\"id\":\"epic_\($0)\",\"title\":\"Epic \($0)\",\"type\":\"epic\"}" }
        let tasks = (0..<20).map { "{\"id\":\"issue_\($0)\",\"title\":\"Task \($0)\",\"type\":\"task\"}" }
        let raw = queueResponse((epics + tasks).joined(separator: ","), total: 30)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.count, 20)
        XCTAssertEqual(queue.total, 20)
    }

    /// A truncated response (bosun: 169 open items, the Library returns a
    /// 50-item page) makes the same point more sharply: the envelope's
    /// `total` (20 here) has no relationship to what actually reached this
    /// page (5 items, 3 surviving). `queue.total` must still read 3.
    func testTruncatedResponseReportsSurvivingItemCountNotEnvelopeArithmetic() throws {
        let raw = queueResponse("""
        {"id":"issue_1","title":"An epic","type":"epic"},
        {"id":"issue_2","title":"Another epic","type":"epic"},
        {"id":"issue_3","title":"A task","type":"task"},
        {"id":"issue_4","title":"Another task","type":"task"},
        {"id":"issue_5","title":"A third task","type":"task"}
        """, total: 20)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.count, 3)
        XCTAssertEqual(queue.total, 3)
    }

    /// The envelope's `total` says 2; only one item survives the decode's
    /// `id`/`title` guard. `queue.total` must follow the survivor, not the
    /// envelope — a third drop path the badge arithmetic once missed
    /// entirely, because neither `droppedEpics` nor `droppedParented` ever
    /// counted it.
    func testAQueueItemMissingATitleIsDropped() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A"},{"id":"issue_B","title":"Has a title"}],"total":2}
        """)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.map(\.id), ["issue_B"])
        XCTAssertEqual(queue.total, 1)
    }

    func testAMissingTotalDegradesToZeroRatherThanThrowing() throws {
        let raw = curlResponse(status: 200, body: #"{"items":[]}"#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.total, 0)
        XCTAssertEqual(queue.items, [])
    }

    func testCorrectionsQueueRefusalThrowsLibraryRefused() {
        let raw = curlResponse(status: 401, body: #"{"error":"no resolvable identity"}"#)
        XCTAssertThrowsError(try LibraryClient.decodeCorrectionsQueue(raw)) { error in
            guard case LibraryClient.FetchError.libraryRefused(let status, _) = error else {
                return XCTFail("expected .libraryRefused, got \(error)")
            }
            XCTAssertEqual(status, 401)
        }
    }

    func testUnparseableCurlOutputThrowsUnexpectedResponse() {
        // No trailing status line at all — not curl's `-w '\n%{http_code}'` shape.
        let raw = Data("garbage with no status line".utf8)
        XCTAssertThrowsError(try LibraryClient.decodeCorrectionsQueue(raw)) { error in
            guard case LibraryClient.FetchError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }

    // MARK: - Decode: beads list

    func testDecodesBeadsListIdsAndProducts() throws {
        let raw = curlResponse(status: 200, body: """
        {"documents":[{"id":"deck/bead/deck","product":"convivy-deck"},
                       {"id":"agent-platform/bead/agent-platform","product":"bosun"}],
         "count":2,"total":2,"offset":0,"truncated":false}
        """)
        let beads = try LibraryClient.decodeBeadsList(raw)
        XCTAssertEqual(beads.map(\.id), ["deck/bead/deck", "agent-platform/bead/agent-platform"])
        XCTAssertEqual(beads.map(\.product), ["convivy-deck", "bosun"])
    }

    func testDecodesAnEmptyBeadsListToNoDocuments() throws {
        let raw = curlResponse(status: 200, body: #"{"documents":[],"count":0,"total":0}"#)
        XCTAssertEqual(try LibraryClient.decodeBeadsList(raw), [])
    }

    /// A document missing `product` still decodes — degrade per field, not
    /// per document.
    func testABeadDocumentWithNoProductStillDecodesItsId() throws {
        let raw = curlResponse(status: 200, body: #"{"documents":[{"id":"library/bead/library"}]}"#)
        let beads = try LibraryClient.decodeBeadsList(raw)
        XCTAssertEqual(beads, [LibraryClient.BeadDocument(id: "library/bead/library", product: nil)])
    }

    /// A document missing `id` is dropped, not fatal — the same per-document
    /// degrade `decodeCorrectionsQueue`'s `QueueItem` gets.
    func testABeadDocumentWithNoIdIsDropped() throws {
        let raw = curlResponse(status: 200, body: """
        {"documents":[{"product":"convivy-deck"},{"id":"library/bead/library","product":"library"}]}
        """)
        let beads = try LibraryClient.decodeBeadsList(raw)
        XCTAssertEqual(beads.map(\.id), ["library/bead/library"])
    }

    func testBeadsListRefusalThrowsLibraryRefused() {
        let raw = curlResponse(status: 403, body: #"{"error":"forbidden"}"#)
        XCTAssertThrowsError(try LibraryClient.decodeBeadsList(raw)) { error in
            guard case LibraryClient.FetchError.libraryRefused(let status, _) = error else {
                return XCTFail("expected .libraryRefused, got \(error)")
            }
            XCTAssertEqual(status, 403)
        }
    }

    func testUnparseableBeadsListBodyThrowsUnexpectedResponse() {
        let raw = curlResponse(status: 200, body: "not json")
        XCTAssertThrowsError(try LibraryClient.decodeBeadsList(raw)) { error in
            guard case LibraryClient.FetchError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }

    /// A body with no `documents` key at all — malformed shape, not merely
    /// an empty list — throws rather than silently reading as `[]`.
    func testABodyWithNoDocumentsKeyThrowsUnexpectedResponse() {
        let raw = curlResponse(status: 200, body: #"{"count":0}"#)
        XCTAssertThrowsError(try LibraryClient.decodeBeadsList(raw)) { error in
            guard case LibraryClient.FetchError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }

    // MARK: - Decode: child items

    func testChildItemsRemoteCommandFiltersByParentId() {
        let command = LibraryClient.childItemsRemoteCommand(parentId: "issue_01ABC")
        XCTAssertTrue(command.contains("/items?parent_id=issue_01ABC"))
        XCTAssertTrue(command.contains("Library-Protocol: 1"))
    }

    func testChildItemsArgumentsCarryTheControlMasterAndAddressTheTarget() {
        let args = LibraryClient.childItemsArguments(target: TestHost.target, parentId: "issue_01ABC")
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertFalse(args.contains { $0.hasPrefix("Authorization") || $0.contains("-H \"Authorization") })
    }

    /// `fetchChildItems` is the only caller of the remote-command/argv
    /// builders above, and it refuses a parent id that fails
    /// `validateLibraryId` before it reaches curl — the same discipline
    /// `fetchCourse` applies to a course id read back from the Library.
    func testFetchChildItemsRefusesAnInvalidParentId() {
        XCTAssertThrowsError(
            try LibraryClient.fetchChildItems(target: TestHost.target, parentId: "issue_01`whoami`")
        ) { error in
            guard case LibraryClient.FetchError.invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        }
    }

    func testDecodesChildItems() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A","title":"A filed item","type":"bug","state":"open",
                   "parent_id":"issue_EPIC"}],
         "count":1,"total":1,"offset":0,"truncated":false}
        """)
        let items = try LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC")
        XCTAssertEqual(items, [LibraryClient.ChildItem(id: "issue_A", title: "A filed item",
                                                        type: "bug", state: "open",
                                                        parentId: "issue_EPIC")])
    }

    /// A child carrying park history decodes the same as
    /// `testACourseEntryWithParkHistoryDecodesOnItsCurrentState`: its
    /// current state parses, and the history fields read into nothing.
    func testDecodesAChildItemWithParkHistory() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A","title":"A child","type":"task","state":"open",
                   "parent_id":"issue_EPIC","park_reason":"blocked on another crew",
                   "unpark_condition":"the auth PR merges","parked_at":"2026-08-27T10:00:00Z"}]}
        """)
        let item = try XCTUnwrap(LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC").first)
        XCTAssertEqual(item.state, "open")
        XCTAssertEqual(item.title, "A child")
    }

    /// `GET /items?parent_id=` carries `prerequisites` and `blocked` on
    /// every item, same as `GET /courses/{id}`.
    func testDecodesChildItemsPrerequisitesAndBlocked() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A","title":"A blocked child","parent_id":"issue_EPIC",
                   "blocked":true,
                   "prerequisites":[{"item":"issue_B","missing":true}]}]}
        """)
        let item = try XCTUnwrap(LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC").first)
        XCTAssertTrue(item.blocked)
        XCTAssertEqual(item.prerequisites, [.missingItem(id: "issue_B")])
    }

    /// A response predating these fields still decodes.
    func testDecodesChildItemsWithNoPrerequisitesOrBlockedStillDecodes() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A","title":"Not blocked","parent_id":"issue_EPIC"}]}
        """)
        let item = try XCTUnwrap(LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC").first)
        XCTAssertEqual(item.prerequisites, [])
        XCTAssertFalse(item.blocked)
    }

    /// `GET /items?parent_id=` carries `key`, `pr`, `pr_url` and `pr_repo` on
    /// every item, same as the Course and corrections-queue routes.
    func testDecodesChildItemsTheKeyAndPRFields() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A","title":"A filed item","parent_id":"issue_EPIC",
                   "key":"E9·4","pr":"297",
                   "pr_url":"https://github.com/convivy/convivy-deck/pull/297",
                   "pr_repo":"convivy/convivy-deck"}]}
        """)
        let item = try XCTUnwrap(LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC").first)
        XCTAssertEqual(item.key, "E9·4")
        XCTAssertEqual(item.pr, "297")
        XCTAssertEqual(item.prNumber, 297)
        XCTAssertEqual(item.prURL, "https://github.com/convivy/convivy-deck/pull/297")
        XCTAssertEqual(item.prRepo, "convivy/convivy-deck")
    }

    /// An item carrying none of the four degrades to `nil` on every one.
    func testDecodesChildItemsWithNoKeyOrPRFieldsStillDecodes() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A","title":"Not filed against a PR","parent_id":"issue_EPIC"}]}
        """)
        let item = try XCTUnwrap(LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC").first)
        XCTAssertNil(item.key)
        XCTAssertNil(item.pr)
        XCTAssertNil(item.prNumber)
        XCTAssertNil(item.prURL)
        XCTAssertNil(item.prRepo)
    }

    /// The fleet-wide steady state today: no epic has any children yet
    /// (measured 2026-08-25, 0 of 50 items across five products carry a
    /// `parent_id`). An empty `items` array must decode to an empty list,
    /// not throw — this is the case the cockpit's "no work items filed"
    /// empty state depends on.
    func testAnAbsentItemsKeyDecodesToAnEmptyListRatherThanThrowing() throws {
        let raw = curlResponse(status: 200, body: #"{"count":0,"total":0}"#)
        XCTAssertEqual(try LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC"), [])
    }

    func testAChildItemMissingATitleIsDropped() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A","parent_id":"issue_EPIC"},
                  {"id":"issue_B","title":"Has a title","parent_id":"issue_EPIC"}]}
        """)
        let items = try LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC")
        XCTAssertEqual(items.map(\.id), ["issue_B"])
    }

    /// A malformed body (not even a JSON object) throws — a per-field
    /// decode has nothing to degrade when there is no object to read a
    /// field from. This is the failure `childItemsSection`'s `.failed` case
    /// draws, distinct from the merely-empty case above.
    func testUnparseableChildItemsBodyThrowsUnexpectedResponse() {
        let raw = curlResponse(status: 200, body: "not json")
        XCTAssertThrowsError(try LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC")) { error in
            guard case LibraryClient.FetchError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }

    /// THE CHECK THAT MAKES THIS CLIENT CORRECT WITHOUT TRUSTING THE SERVER.
    /// `GET /items?parent_id=` is honoured today — measured 2026-08-25: 15
    /// items unfiltered, 0 with a nonexistent parent, and 15 again with an
    /// unknown parameter, so the filter is applied rather than ignored. If
    /// that ever stopped being true the response would carry every item in
    /// the product, and without this the cockpit would render them under
    /// EVERY epic as a plausible non-empty list. Found by `deck-reviewer` on
    /// #136.
    func testAnItemFiledUnderADifferentEpicIsDropped() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_MINE","title":"Mine","parent_id":"issue_EPIC"},
                  {"id":"issue_THEIRS","title":"Someone else's","parent_id":"issue_OTHER"}]}
        """)
        let items = try LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC")
        XCTAssertEqual(items.map(\.id), ["issue_MINE"])
    }

    /// The whole-response case the finding actually described: a route that
    /// stopped filtering hands back items carrying other parents, or none at
    /// all. Both are dropped, so the expansion is empty rather than wrong.
    func testAnUnfilteredResponseDecodesToNothingRatherThanEverything() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_1","title":"One","parent_id":"issue_OTHER"},
                  {"id":"issue_2","title":"Two"},
                  {"id":"issue_3","title":"Three","parent_id":"issue_ANOTHER"}]}
        """)
        XCTAssertEqual(try LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC"), [])
    }

    /// An item carrying no `parent_id` cannot be confirmed as this epic's, so
    /// it is dropped rather than shown — the same posture as a missing title.
    func testAnItemWithNoParentIdIsDropped() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A","title":"No parent recorded"}]}
        """)
        XCTAssertEqual(try LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC"), [])
    }

    func testChildItemsRefusalThrowsLibraryRefused() {
        let raw = curlResponse(status: 404, body: #"{"error":"no such item"}"#)
        XCTAssertThrowsError(try LibraryClient.decodeChildItems(raw, expectedParentId: "issue_EPIC")) { error in
            guard case LibraryClient.FetchError.libraryRefused(let status, _) = error else {
                return XCTFail("expected .libraryRefused, got \(error)")
            }
            XCTAssertEqual(status, 404)
        }
    }

    // MARK: - ChildItem state logic

    /// A `fixed` child reads passed, the same vocabulary
    /// `testATerminalResolutionIsCompleted` exercises for a Course entry —
    /// `ChildItem` carries no `resolution` field of its own, so `state`
    /// alone must decide it.
    func testAFixedChildIsCompleted() {
        let item = LibraryClient.ChildItem(
            id: "issue_A", title: "Wire the transport", type: "task", state: "fixed", parentId: "issue_EPIC")
        XCTAssertTrue(item.isCompleted)
    }

    func testAnOpenChildIsNotCompleted() {
        let item = LibraryClient.ChildItem(
            id: "issue_B", title: "Draw the cockpit", type: "task", state: "open", parentId: "issue_EPIC")
        XCTAssertFalse(item.isCompleted)
    }

    func testAChildWithNoStateIsNotCompleted() {
        let item = LibraryClient.ChildItem(
            id: "issue_C", title: "No state recorded", type: nil, state: nil, parentId: "issue_EPIC")
        XCTAssertFalse(item.isCompleted)
    }

    /// `ITEM_RESOLUTIONS` is `{fixed, wontfix, duplicate, redirected}`
    /// (`library/store.py:552`) — `redirected` was missing from
    /// `terminalWorkStates`, so a redirected child never drew as passed.
    /// Live instance: `issue_01M0NWWSDM1EVSSX9WVM694T38`.
    func testARedirectedChildIsCompleted() {
        let item = LibraryClient.ChildItem(
            id: "issue_D", title: "Filed against the wrong repo", type: "task",
            state: "redirected", parentId: "issue_EPIC")
        XCTAssertTrue(item.isCompleted)
    }

    // MARK: - Decode: found-during items

    func testFoundDuringItemsRemoteCommandFiltersByFoundDuring() {
        let command = LibraryClient.foundDuringItemsRemoteCommand(epicId: "issue_01EPIC")
        XCTAssertTrue(command.contains("/items?found_during=issue_01EPIC"))
        XCTAssertTrue(command.contains("Library-Protocol: 1"))
    }

    func testFoundDuringItemsArgumentsCarryTheControlMasterAndAddressTheTarget() {
        let args = LibraryClient.foundDuringItemsArguments(target: TestHost.target, epicId: "issue_01EPIC")
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertFalse(args.contains { $0.hasPrefix("Authorization") || $0.contains("-H \"Authorization") })
    }

    /// `fetchFoundDuringItems` refuses an epic id that fails
    /// `validateLibraryId` before it reaches curl — the same discipline
    /// `fetchChildItems` applies to a parent id read back from the Library.
    func testFetchFoundDuringItemsRefusesAnInvalidEpicId() {
        XCTAssertThrowsError(
            try LibraryClient.fetchFoundDuringItems(target: TestHost.target, epicId: "issue_01`whoami`")
        ) { error in
            guard case LibraryClient.FetchError.invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        }
    }

    func testDecodesFoundDuringItems() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A","title":"Found along the way","type":"bug","state":"open",
                   "found_during":"issue_EPIC"}]}
        """)
        let items = try LibraryClient.decodeFoundDuringItems(raw, expectedFoundDuring: "issue_EPIC")
        XCTAssertEqual(items, [LibraryClient.FoundDuringItem(id: "issue_A", title: "Found along the way",
                                                              state: "open")])
    }

    func testAFoundDuringItemMissingATitleIsDropped() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A","found_during":"issue_EPIC"},
                  {"id":"issue_B","title":"Has a title","found_during":"issue_EPIC"}]}
        """)
        let items = try LibraryClient.decodeFoundDuringItems(raw, expectedFoundDuring: "issue_EPIC")
        XCTAssertEqual(items.map(\.id), ["issue_B"])
    }

    /// The same independence-from-the-server check `decodeChildItems` makes
    /// for `parent_id`: an item naming a DIFFERENT epic is dropped rather
    /// than shown under this one.
    func testAFoundDuringItemNamingADifferentEpicIsDropped() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_MINE","title":"Mine","found_during":"issue_EPIC"},
                  {"id":"issue_THEIRS","title":"Someone else's","found_during":"issue_OTHER"}]}
        """)
        let items = try LibraryClient.decodeFoundDuringItems(raw, expectedFoundDuring: "issue_EPIC")
        XCTAssertEqual(items.map(\.id), ["issue_MINE"])
    }

    /// An item carrying no `found_during` cannot be confirmed as this
    /// epic's, so it is dropped rather than shown.
    func testAnItemWithNoFoundDuringIsDropped() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_A","title":"No found_during recorded"}]}
        """)
        XCTAssertEqual(try LibraryClient.decodeFoundDuringItems(raw, expectedFoundDuring: "issue_EPIC"), [])
    }

    /// A missing `items` key degrades to an empty list rather than
    /// throwing — an epic with nothing found during it is the expected
    /// steady state, not a malformed response.
    func testAnAbsentItemsKeyDecodesToAnEmptyFoundDuringList() throws {
        let raw = curlResponse(status: 200, body: #"{"count":0,"total":0}"#)
        XCTAssertEqual(try LibraryClient.decodeFoundDuringItems(raw, expectedFoundDuring: "issue_EPIC"), [])
    }

    func testUnparseableFoundDuringItemsBodyThrowsUnexpectedResponse() {
        let raw = curlResponse(status: 200, body: "not json")
        XCTAssertThrowsError(
            try LibraryClient.decodeFoundDuringItems(raw, expectedFoundDuring: "issue_EPIC")
        ) { error in
            guard case LibraryClient.FetchError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }

    func testFoundDuringItemsRefusalThrowsLibraryRefused() {
        let raw = curlResponse(status: 404, body: #"{"error":"no such item"}"#)
        XCTAssertThrowsError(
            try LibraryClient.decodeFoundDuringItems(raw, expectedFoundDuring: "issue_EPIC")
        ) { error in
            guard case LibraryClient.FetchError.libraryRefused(let status, _) = error else {
                return XCTFail("expected .libraryRefused, got \(error)")
            }
            XCTAssertEqual(status, 404)
        }
    }

    // MARK: - FoundDuringItem state logic, and the open-items filter

    func testAFixedFoundDuringItemIsCompleted() {
        let item = LibraryClient.FoundDuringItem(id: "issue_A", title: "Done now", state: "fixed")
        XCTAssertTrue(item.isCompleted)
    }

    func testAnOpenFoundDuringItemIsNotCompleted() {
        let item = LibraryClient.FoundDuringItem(id: "issue_B", title: "Still open", state: "open")
        XCTAssertFalse(item.isCompleted)
    }

    /// `ItemDetailPane`'s epic section lists only the open ones — a resolved
    /// item found during the epic is excluded, not shown struck through.
    func testOpenFoundDuringItemsFiltersOutCompletedOnes() {
        let items = [
            LibraryClient.FoundDuringItem(id: "issue_A", title: "Open", state: "open"),
            LibraryClient.FoundDuringItem(id: "issue_B", title: "Fixed", state: "fixed"),
            LibraryClient.FoundDuringItem(id: "issue_C", title: "No state", state: nil),
        ]
        XCTAssertEqual(LibraryClient.openFoundDuringItems(items).map(\.id), ["issue_A", "issue_C"])
    }

    // MARK: - CourseEntry state logic

    func testATerminalResolutionIsCompleted() {
        let entry = LibraryClient.CourseEntry(
            id: "x", title: "t", type: "epic", state: "fixed", maturity: nil, resolution: "fixed")
        XCTAssertTrue(entry.isCompleted)
        XCTAssertFalse(entry.isInProgress)
    }

    /// The live instance A1 names: a `redirected` epic reads passed rather
    /// than ahead.
    func testARedirectedEntryIsCompleted() {
        let entry = LibraryClient.CourseEntry(
            id: "issue_01M0NWWSDM1EVSSX9WVM694T38", title: "t", type: "epic",
            state: "redirected", maturity: nil, resolution: "redirected")
        XCTAssertTrue(entry.isCompleted)
        XCTAssertFalse(entry.isInProgress)
    }

    func testAnOpenUnclaimedEntryIsNeitherCompletedNorInProgress() {
        let entry = LibraryClient.CourseEntry(
            id: "x", title: "t", type: "epic", state: "open", maturity: nil, resolution: nil)
        XCTAssertFalse(entry.isCompleted)
        XCTAssertFalse(entry.isInProgress)
    }

    func testAClaimedEntryIsInProgress() {
        let entry = LibraryClient.CourseEntry(
            id: "x", title: "t", type: "epic", state: "claimed", maturity: nil, resolution: nil)
        XCTAssertFalse(entry.isCompleted)
        XCTAssertTrue(entry.isInProgress)
    }

    func testAnEntryWithNoStateIsNeitherCompletedNorInProgress() {
        let entry = LibraryClient.CourseEntry(
            id: "x", title: "t", type: nil, state: nil, maturity: nil, resolution: nil)
        XCTAssertFalse(entry.isCompleted)
        XCTAssertFalse(entry.isInProgress)
    }

    // MARK: - Claim status wording

    /// `CockpitView`'s epic-detail line, pinned here since nothing in
    /// `DeckTests` instantiates that view — a live claim reads exactly as it
    /// did before this fix.
    func testClaimStatusLineForALiveClaim() {
        XCTAssertEqual(
            LibraryClient.claimStatusLine(claimedBy: "agent-x", expired: false), "Claimed by: agent-x")
    }

    /// The design choice this fix makes: an expired claim names who last
    /// held it rather than reading as simply unclaimed.
    func testClaimStatusLineForAnExpiredClaim() {
        XCTAssertEqual(
            LibraryClient.claimStatusLine(claimedBy: "agent-x", expired: true), "Last held by: agent-x")
    }

    /// `ItemDetailPane`'s meta-line fragment — same word choice, lowercase.
    func testClaimMetaFragmentForALiveClaim() {
        XCTAssertEqual(
            LibraryClient.claimMetaFragment(claimedBy: "agent-x", expired: false), "claimed by agent-x")
    }

    func testClaimMetaFragmentForAnExpiredClaim() {
        XCTAssertEqual(
            LibraryClient.claimMetaFragment(claimedBy: "agent-x", expired: true), "last held by agent-x")
    }

    // MARK: - Decode: correction detail

    /// The shape confirmed against the running Library 2026-08-25 (the probe
    /// comment left on `issue_01KZHR0X9ZHGVXESA1E08AEE6J`, convivy-deck's own
    /// queue) — every field the detail pane draws, plus a comment. No
    /// `claim_expired` key here, pinning that an item carrying a holder but
    /// predating this field still reads as live — see
    /// `LibraryClient.CorrectionDetail.claimExpired`'s doc.
    func testDecodesACorrectionDetailWithComments() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"issue_01ABC","title":"A bug","body":"Full write-up","type":"bug",
         "state":"open","severity":"low","needs":"agent","resolution":null,
         "outcome_note":null,"claimed_by":"agent-x","created_at":"2026-08-08T22:31:14Z",
         "parent_id":null,
         "comments":[{"id":858,"actor":"agent-platform","kind":"note",
                      "body":"a probe comment","run_id":null,"at":"2026-08-26T01:00:28Z"}]}
        """)
        let detail = try LibraryClient.decodeCorrectionDetail(raw)
        XCTAssertEqual(detail.id, "issue_01ABC")
        XCTAssertEqual(detail.title, "A bug")
        XCTAssertEqual(detail.body, "Full write-up")
        XCTAssertEqual(detail.severity, "low")
        XCTAssertEqual(detail.needs, "agent")
        XCTAssertEqual(detail.claimedBy, "agent-x")
        XCTAssertFalse(detail.claimExpired)
        XCTAssertEqual(detail.comments.count, 1)
        XCTAssertEqual(detail.comments.first?.id, 858)
        XCTAssertEqual(detail.comments.first?.actor, "agent-platform")
        XCTAssertEqual(detail.comments.first?.body, "a probe comment")
    }

    /// `claim_expired: true` decodes as expired — the corrections-queue
    /// detail pane's own version of the `CourseEntry` case pinned above.
    func testACorrectionDetailWithClaimExpiredTrueDecodesAsExpired() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"issue_01ABC","title":"A bug","claimed_by":"agent-x","claim_expired":true}
        """)
        let detail = try LibraryClient.decodeCorrectionDetail(raw)
        XCTAssertTrue(detail.claimExpired)
    }

    /// `claim_expired: false` decodes as live.
    func testACorrectionDetailWithClaimExpiredFalseDecodesAsLive() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"issue_01ABC","title":"A bug","claimed_by":"agent-x","claim_expired":false}
        """)
        let detail = try LibraryClient.decodeCorrectionDetail(raw)
        XCTAssertFalse(detail.claimExpired)
    }

    /// An explicit JSON `null` decodes as live, same as an absent key —
    /// see `LibraryClient.CourseEntry`'s equivalent test for why this
    /// direction of the mistake is the dangerous one to leave unpinned.
    func testACorrectionDetailWithAnExplicitNullClaimExpiredDecodesAsLive() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"issue_01ABC","title":"A bug","claimed_by":"agent-x","claim_expired":null}
        """)
        let detail = try LibraryClient.decodeCorrectionDetail(raw)
        XCTAssertFalse(detail.claimExpired)
    }

    /// **`product` is what makes a cross-product item legible**, and it is the
    /// field a `deck-open:?origin=item` link depends on: an item reached that
    /// way can belong to any product the token can see, so the pane has to say
    /// which. It degrades independently like every other optional field here.
    func testTheDetailDecodesTheProduct() throws {
        let raw = Data("""
        {"id":"issue_01ABC","title":"T","product":"library","body":"b"}
        200
        """.replacingOccurrences(of: "\n        ", with: "\n").utf8)
        let detail = try LibraryClient.decodeCorrectionDetail(raw)
        XCTAssertEqual(detail.product, "library")
    }

    /// A response carrying no `product` still decodes — the field costs itself
    /// and nothing else, the same posture the rest of this decoder takes.
    func testAMissingProductDegradesToNil() throws {
        let raw = Data("""
        {"id":"issue_01ABC","title":"T","body":"b"}
        200
        """.replacingOccurrences(of: "\n        ", with: "\n").utf8)
        let detail = try LibraryClient.decodeCorrectionDetail(raw)
        XCTAssertNil(detail.product)
    }

    /// `found_during` names the epic whose work turned this item up —
    /// confirmed served on `GET /items/{id}` by the Library, 2026-09-24.
    func testTheDetailDecodesFoundDuring() throws {
        let raw = curlResponse(status: 200, body: #"{"id":"issue_01ABC","found_during":"issue_EPIC"}"#)
        let detail = try LibraryClient.decodeCorrectionDetail(raw)
        XCTAssertEqual(detail.foundDuring, "issue_EPIC")
    }

    /// A response carrying no `found_during` at all degrades to `nil`.
    func testAMissingFoundDuringDegradesToNil() throws {
        let raw = curlResponse(status: 200, body: #"{"id":"issue_01ABC"}"#)
        let detail = try LibraryClient.decodeCorrectionDetail(raw)
        XCTAssertNil(detail.foundDuring)
    }

    /// An explicit JSON `null` — "`null` when unset", per the Library's own
    /// description of the field — decodes the same as an absent key.
    func testAnExplicitNullFoundDuringDegradesToNil() throws {
        let raw = curlResponse(status: 200, body: #"{"id":"issue_01ABC","found_during":null}"#)
        let detail = try LibraryClient.decodeCorrectionDetail(raw)
        XCTAssertNil(detail.foundDuring)
    }

    /// An epic's two Markdown fields are root keys of `GET /items/{id}`,
    /// verified 2026-09-21 by calling the endpoint for an approved epic.
    func testDecodesAnEpicsSpecificationAndDefinitionOfDone() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"id":"issue_01ABC","title":"An epic","type":"epic",
         "specification":"## Why\nBecause.","definition_of_done":"- one\n- two"}
        """#)
        let detail = try LibraryClient.decodeCorrectionDetail(raw)
        XCTAssertEqual(detail.specification, "## Why\nBecause.")
        XCTAssertEqual(detail.definitionOfDone, "- one\n- two")
    }

    /// A correction carries neither key, and a null is the same as absent.
    func testAnItemWithoutTheEpicFieldsDecodesThemAsNil() throws {
        for body in [#"{"id":"issue_01ABC"}"#,
                     #"{"id":"issue_01ABC","specification":null,"definition_of_done":null}"#] {
            let detail = try LibraryClient.decodeCorrectionDetail(curlResponse(status: 200, body: body))
            XCTAssertNil(detail.specification)
            XCTAssertNil(detail.definitionOfDone)
        }
    }

    func testACorrectionDetailWithNoCommentsDecodesToAnEmptyThread() throws {
        let raw = curlResponse(status: 200, body: #"{"id":"issue_01ABC","title":"A bug"}"#)
        let detail = try LibraryClient.decodeCorrectionDetail(raw)
        XCTAssertEqual(detail.comments, [])
    }

    /// A comment missing its body still decodes — per-field degrade, the
    /// same discipline every other decoder in this file follows.
    func testACommentMissingItsBodyStillDecodesTheRestOfTheThread() throws {
        let raw = curlResponse(status: 200, body: """
        {"id":"issue_01ABC","comments":[{"id":1,"actor":"x","kind":"note"}]}
        """)
        let detail = try LibraryClient.decodeCorrectionDetail(raw)
        XCTAssertEqual(detail.comments.first?.actor, "x")
        XCTAssertNil(detail.comments.first?.body)
    }

    func testACorrectionDetailWithNoIdThrowsUnexpectedResponse() {
        let raw = curlResponse(status: 200, body: #"{"title":"A bug"}"#)
        XCTAssertThrowsError(try LibraryClient.decodeCorrectionDetail(raw)) { error in
            guard case LibraryClient.FetchError.unexpectedResponse = error else {
                return XCTFail("expected .unexpectedResponse, got \(error)")
            }
        }
    }

    func testCorrectionDetailRefusalThrowsLibraryRefused() {
        let raw = curlResponse(status: 404, body: #"{"error":"no such item"}"#)
        XCTAssertThrowsError(try LibraryClient.decodeCorrectionDetail(raw)) { error in
            guard case LibraryClient.FetchError.libraryRefused(let status, _) = error else {
                return XCTFail("expected .libraryRefused, got \(error)")
            }
            XCTAssertEqual(status, 404)
        }
    }

    func testItemRemoteCommandAddressesTheGivenId() {
        let command = LibraryClient.itemRemoteCommand(itemId: "issue_01ABC")
        XCTAssertTrue(command.contains("/items/issue_01ABC"))
        XCTAssertTrue(command.contains("Library-Protocol: 1"))
    }

    func testFetchCorrectionRefusesAnInvalidId() {
        XCTAssertThrowsError(
            try LibraryClient.fetchCorrection(target: TestHost.target, id: "issue_01`whoami`")
        ) { error in
            guard case LibraryClient.FetchError.invalidInput = error else {
                return XCTFail("expected .invalidInput, got \(error)")
            }
        }
    }

    // MARK: - Write: shell-injection round trip
    //
    // These execute the ACTUAL remote command string through a real shell —
    // `/bin/bash`, the same interpreter ssh hands the command to on the mini
    // — with a tiny local TCP listener standing in for the Library, so the
    // assertion is against bytes that genuinely crossed a shell rather than
    // a hand-simplified stand-in. `LauncherTests`/`ProcessCwdTests` already
    // run real `/bin/bash`/`/bin/sh` processes from this test target for the
    // same reason: a string-level assertion cannot prove a shell didn't
    // expand something a byte-level one can.

    /// Runs `command` through `/bin/bash -c`, with the real process stdin
    /// carrying `body`'s JSON encoding (exactly what `SessionAgent.run(_:stdin:)`
    /// would send) and a raw TCP listener in place of the Library, then
    /// JSON-decodes the request the listener captured and asserts `field`
    /// decodes back to exactly `expectedValue` — a substring check on the raw
    /// bytes would conflate JSON's own escaping (`"` → `\"`, `\` → `\\`) with
    /// shell mangling, so decoding is what actually proves the shell left the
    /// text alone. `${LIBRARY_BASE_URL:-...}` is set to the listener's own
    /// address so the command's own curl call reaches it.
    private func assertPOSTBodySurvivesRoundTrip(
        command: String, body: [String: Any], field: String, expectedValue: String,
        expectedRequestLine: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let request = try captureRequest(command: command, body: body, file: file, line: line)
        if let expectedRequestLine {
            XCTAssertEqual(request.requestLine, expectedRequestLine,
                           "the request line the listener saw", file: file, line: line)
        }
        XCTAssertEqual(request.body[field] as? String, expectedValue,
                       "the dangerous field did not survive the shell round trip unmangled",
                       file: file, line: line)
    }

    /// The request the listener captured, with the body already JSON-decoded.
    /// Shared by the assertion above and by tests whose body is not a single
    /// string field.
    private func captureRequest(
        command: String, body: [String: Any],
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (requestLine: String?, body: [String: Any]) {
        let listener = try RawCapturingHTTPListener()
        defer { listener.close() }

        let payload = try JSONSerialization.data(withJSONObject: body)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["LIBRARY_BASE_URL"] = "http://127.0.0.1:\(listener.port)"
        process.environment = env

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let captured = ThreadSafeBox<String>(value: "")
        let acceptThread = Thread {
            captured.value = listener.acceptOnceAndCaptureBody()
        }
        acceptThread.start()

        try process.run()
        stdinPipe.fileHandleForWriting.write(payload)
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        acceptThread.cancel()
        // Bounded wait for the accept thread to finish capturing — the
        // listener closes its accepted socket as soon as it has read a full
        // request, so this is milliseconds in practice.
        let deadline = Date().addingTimeInterval(5)
        while !captured.isSet && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        guard let bodyRange = captured.value.range(of: "\r\n\r\n") else {
            XCTFail("no request reached the listener; got:\n\(captured.value)", file: file, line: line)
            return (nil, [:])
        }
        let jsonText = String(captured.value[bodyRange.upperBound...])
        guard let jsonData = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            XCTFail("captured body did not decode as JSON:\n\(jsonText)", file: file, line: line)
            return (nil, [:])
        }
        return (captured.value.components(separatedBy: "\r\n").first, object)
    }

    // MARK: - Test helper

    /// Builds the byte shape curl's `-w '\n%{http_code}'` produces, so the
    /// decoders here exercise the exact split `WorkingCopyStore.splitCurlStatusResponse`
    /// performs rather than a hand-simplified stand-in.
    private func curlResponse(status: Int, body: String) -> Data {
        Data("\(body)\n\(status)".utf8)
    }

    // MARK: - The corrections queue is the interrupt lane, not the plan

    private func queueResponse(_ itemsJSON: String, total: Int) -> Data {
        Data("{\"items\":[\(itemsJSON)],\"total\":\(total)}\n200".utf8)
    }

    /// **An epic is the plan, not an interrupt.** `GET /items?product=&state=open`
    /// returns every open item of every type, so the Course's own epics were
    /// drawn a second time in the corrections queue — one item in two panels,
    /// which reads to an operator as a duplicate filing.
    func testEpicsAreDroppedFromTheCorrectionsQueue() throws {
        let raw = queueResponse("""
        {"id":"issue_1","title":"A bug","type":"bug"},
        {"id":"issue_2","title":"An epic","type":"epic"},
        {"id":"issue_3","title":"A task","type":"task"}
        """, total: 3)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.map(\.id), ["issue_1", "issue_3"])
    }

    /// The count heads the panel, so it must count what the panel SHOWS.
    /// Reporting the envelope's total would head a two-row queue with "3".
    func testTheQueueTotalExcludesTheDroppedEpics() throws {
        let raw = queueResponse("""
        {"id":"issue_1","title":"A bug","type":"bug"},
        {"id":"issue_2","title":"An epic","type":"epic"},
        {"id":"issue_3","title":"A task","type":"task"}
        """, total: 3)
        XCTAssertEqual(try LibraryClient.decodeCorrectionsQueue(raw).total, 2)
    }

    /// An item carrying no `type` is kept. The filter drops what it can prove
    /// is an epic rather than everything it cannot classify — the same
    /// "a field costs itself" posture the rest of this decoder takes, and the
    /// safe direction: showing an extra row beats hiding a real correction.
    func testAnItemWithNoTypeIsKept() throws {
        let raw = queueResponse("""
        {"id":"issue_1","title":"No type at all"}
        """, total: 1)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.map(\.id), ["issue_1"])
        XCTAssertEqual(queue.total, 1)
    }

    /// The subtraction never goes negative, however the envelope and the page
    /// disagree — a truncated response can report a total smaller than what
    /// this page dropped.
    func testTheTotalNeverGoesNegative() throws {
        let raw = queueResponse("""
        {"id":"issue_1","title":"An epic","type":"epic"},
        {"id":"issue_2","title":"Another","type":"epic"}
        """, total: 0)
        XCTAssertEqual(try LibraryClient.decodeCorrectionsQueue(raw).total, 0)
    }

    /// convivy-orient/issue_build.py:128 defines queue membership as
    /// "not an epic AND has no parent epic" — an item filed under an epic is
    /// in the plan, not an interrupt, the same reasoning that drops the epic
    /// itself. Covers all three parent shapes the Library can hand back: a
    /// real parent (dropped), an explicit `null` (kept), and the key missing
    /// entirely (kept) — a missing or null key must not be read as "has a
    /// parent" the way a naive truthiness check would invert it.
    func testItemsWithAParentEpicAreDroppedFromTheCorrectionsQueue() throws {
        let raw = queueResponse("""
        {"id":"issue_1","title":"An epic's child","type":"task","parent_id":"epic_9"},
        {"id":"issue_2","title":"Explicitly parentless","type":"task","parent_id":null},
        {"id":"issue_3","title":"No parent_id key at all","type":"task"}
        """, total: 3)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.map(\.id), ["issue_2", "issue_3"])
        XCTAssertEqual(queue.total, 2)
    }

    /// `found_during` names the epic whose work turned an item up — distinct
    /// from `parentId`, which files an item INTO the plan. The corrections
    /// lane's rule reads only `type` and `parentId`, so an item carrying
    /// `found_during` and no `parentId` is still a correction and still
    /// lands in the queue (CQ·107's own degrade requirement: "the corrections
    /// lane is unchanged").
    func testAFoundDuringItemWithNoParentStillLandsInTheCorrectionsQueue() throws {
        let raw = queueResponse("""
        {"id":"issue_1","title":"Found during cleanup","type":"task","found_during":"issue_EPIC"}
        """, total: 1)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.items.map(\.id), ["issue_1"])
        XCTAssertEqual(queue.total, 1)
    }

    /// The rows the drop above discards are the only place the queue read
    /// says which epic an unresolved child is under, and `CockpitModel.reveal`
    /// reads them from here instead of fetching. Pinned in both directions: a
    /// parented item is recorded, and a parentless one, an empty parent and an
    /// epic are not.
    func testTheQueueKeepsTheParentOfEveryItemItDrops() throws {
        let raw = queueResponse("""
        {"id":"issue_1","title":"An epic's child","type":"task","parent_id":"epic_9"},
        {"id":"issue_2","title":"Explicitly parentless","type":"task","parent_id":null},
        {"id":"issue_3","title":"No parent_id key at all","type":"task"},
        {"id":"issue_4","title":"Empty parent","type":"task","parent_id":""},
        {"id":"epic_9","title":"The epic","type":"epic"}
        """, total: 5)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw)
        XCTAssertEqual(queue.childParents, ["issue_1": "epic_9"])
        XCTAssertEqual(queue.items.map(\.id), ["issue_2", "issue_3", "issue_4"],
                       "keeping the parent must not put the child back in the queue")
    }

    /// Two pages of one state merge their maps, so a child on page two is
    /// found as readily as one on page one.
    func testPagedQueueMergesParentsAcrossPages() throws {
        let pages = [
            Data((#"{"items":[{"id":"issue_1","title":"a","parent_id":"epic_1"}],"truncated":true}"# + "\n200").utf8),
            Data((#"{"items":[{"id":"issue_2","title":"b","parent_id":"epic_2"}],"truncated":false}"# + "\n200").utf8),
        ]
        let result = try LibraryClient.pagedQueue { offset in offset == 0 ? pages[0] : pages[1] }
        XCTAssertEqual(result.childParents, ["issue_1": "epic_1", "issue_2": "epic_2"])
        XCTAssertFalse(result.truncated)
    }

    // MARK: - A corrections queue as a parent (issue_01M4J5T82F8GRQWYRZ71JE7CV7)

    /// After the Library's one-home switch, a correction's `parent_id` names
    /// its product's corrections queue. Such an item stays in the queue, a
    /// null-parent item stays too, and only an epic parent takes one out.
    func testDecodeCorrectionsQueueKeepsAnItemWhoseParentIsACorrectionsQueue() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[
          {"id":"issue_queued","title":"in the queue row","parent_id":"queue_A"},
          {"id":"issue_null","title":"null parent","parent_id":null},
          {"id":"issue_kid","title":"under an epic","parent_id":"epic_9"}
        ]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw, correctionsQueueIds: ["queue_A"])
        XCTAssertEqual(Set(queue.items.map(\.id)), ["issue_queued", "issue_null"])
        XCTAssertEqual(queue.childParents, ["issue_kid": "epic_9"])
        XCTAssertEqual(queue.correctionsQueueIds, ["queue_A"])
    }

    /// The queue is recognised by the lookup, never by the id's shape: an
    /// id that looks like a queue but is not in the lookup is an epic parent.
    func testDecodeCorrectionsQueueDoesNotReadTheQueuePrefix() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"issue_1","title":"a","parent_id":"cq_01UNLISTED"}]}
        """#)
        let queue = try LibraryClient.decodeCorrectionsQueue(raw, correctionsQueueIds: ["cq_01LISTED"])
        XCTAssertEqual(queue.items, [])
        XCTAssertEqual(queue.childParents, ["issue_1": "cq_01UNLISTED"])
    }

    func testPagedQueueKeepsQueueParentedItemsOnEveryPage() throws {
        let pages = [
            Data((#"{"items":[{"id":"issue_1","title":"a","parent_id":"queue_A"}],"truncated":true}"# + "\n200").utf8),
            Data((#"{"items":[{"id":"issue_2","title":"b","parent_id":"queue_A"}],"truncated":false}"# + "\n200").utf8),
        ]
        let result = try LibraryClient.pagedQueue(correctionsQueueIds: ["queue_A"]) { offset in
            offset == 0 ? pages[0] : pages[1]
        }
        XCTAssertEqual(result.items.map(\.id), ["issue_1", "issue_2"])
        XCTAssertEqual(result.childParents, [:])
    }

    func testCorrectionsQueuesRemoteCommandAsksForTheProductsQueues() {
        XCTAssertTrue(LibraryClient.correctionsQueuesRemoteCommand(product: "convivy-deck")
            .contains("/corrections-queues?product=convivy-deck\""))
    }

    func testDecodeCorrectionsQueueIdsReadsEveryId() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"corrections_queues":[{"id":"queue_A","product":"convivy-deck","created_at":"2026-10-09T00:00:00Z"},{"product":"no id"}],"count":2}
        """#)
        XCTAssertEqual(try LibraryClient.decodeCorrectionsQueueIds(raw), ["queue_A"])
    }

    /// A product with no queue yet gets a 200 with an empty list once the
    /// route exists (the Library's confirmed shape, relayed by the steward
    /// 2026-10-09). That is no queues, not the error state.
    func testDecodeCorrectionsQueueIdsReadsAnEmptyListAsNoQueues() throws {
        let raw = curlResponse(status: 200, body: #"{"corrections_queues":[],"count":0}"#)
        XCTAssertEqual(try LibraryClient.decodeCorrectionsQueueIds(raw), [])
    }

    /// A Library from before the route answers 404; every correction's
    /// parent is still null there, so no queues loses nothing.
    func testDecodeCorrectionsQueueIdsReadsA404AsNoQueues() throws {
        let raw = curlResponse(status: 404, body: #"{"detail":"Not Found"}"#)
        XCTAssertEqual(try LibraryClient.decodeCorrectionsQueueIds(raw), [])
    }

    /// Any other failure must fail the queue fetch: an empty set would drop
    /// every queue-parented correction and draw an empty panel as the truth.
    func testDecodeCorrectionsQueueIdsThrowsOnAnyOtherFailure() {
        XCTAssertThrowsError(try LibraryClient.decodeCorrectionsQueueIds(
            curlResponse(status: 500, body: "boom")))
        XCTAssertThrowsError(try LibraryClient.decodeCorrectionsQueueIds(
            curlResponse(status: 200, body: #"{"queues":[{"id":"queue_A"}]}"#)),
            "a 200 without corrections_queues is a shape Deck does not know, not an empty list")
    }

    // MARK: - The queue's own `truncated` flag

    func testDecodeCorrectionsQueueSurfacesTheEnvelopesTruncatedFlag() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i1","title":"one","state":"open"}],"truncated":true}
        """#)
        XCTAssertTrue(try LibraryClient.decodeCorrectionsQueue(raw).truncated)
    }

    /// A response predating this field, or one from a product whose one page
    /// held everything, must not read as truncated merely because the key is
    /// absent — the same absent-means-false discipline `CourseEntry.claimExpired`
    /// documents for its own field.
    func testDecodeCorrectionsQueueDefaultsTruncatedToFalseWhenAbsent() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i1","title":"one","state":"open"}]}
        """#)
        XCTAssertFalse(try LibraryClient.decodeCorrectionsQueue(raw).truncated)
    }

    // MARK: - Paging past the Library's 50-item default (issue_01M1STN4AB0JQ7YJ1ETJTBR370)

    func testItemsRemoteCommandCarriesLimitAndOffset() {
        let command = LibraryClient.itemsRemoteCommand(product: "convivy-deck", state: .open, limit: 200, offset: 400)
        XCTAssertTrue(command.contains("limit=200"))
        XCTAssertTrue(command.contains("offset=400"))
    }

    /// The defaults exist so every pre-existing call in this file (and the
    /// argv builders below it) keeps compiling unchanged, but they must still
    /// be a real limit and a real offset, not an empty filter that falls back
    /// to the Library's own 50-item default the way no `limit=` at all would.
    func testItemsRemoteCommandDefaultsToThePageLimitAndZeroOffset() {
        let command = LibraryClient.itemsRemoteCommand(product: "convivy-deck", state: .open)
        XCTAssertTrue(command.contains("limit=\(LibraryClient.itemsPageLimit)"))
        XCTAssertTrue(command.contains("offset=0"))
    }

    /// **THE DEFECT THIS ISSUE FIXES.** Before `pagedQueueItems` existed, a
    /// state's items came from exactly one call, so a `truncated: true` first
    /// page was never followed up — measured against the running Library,
    /// `vivy`'s `state=open` answered 50 of 176 with `truncated: true` and
    /// nothing asked for the rest. Here the fake remote-command layer (the
    /// `fetchPage` closure) hands back a truncated first page and a complete
    /// second page; the queue this produces must hold the union of both.
    func testPagedQueueItemsUnionsATruncatedFirstPageWithItsFollowUp() throws {
        var offsetsAsked: [Int] = []
        let firstPage = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i1","title":"one","state":"open"},
                  {"id":"i2","title":"two","state":"open"}],"truncated":true}
        """#)
        let secondPage = curlResponse(status: 200, body: #"""
        {"items":[{"id":"i3","title":"three","state":"open"}],"truncated":false}
        """#)
        let (items, truncated) = try LibraryClient.pagedQueueItems { offset in
            offsetsAsked.append(offset)
            return offsetsAsked.count == 1 ? firstPage : secondPage
        }
        XCTAssertEqual(Set(items.map(\.id)), Set(["i1", "i2", "i3"]))
        XCTAssertFalse(truncated)
        XCTAssertEqual(offsetsAsked, [0, 2],
                       "the second page must start after the first page's own item count")
    }

    /// **THE SAFETY VALVE, NOT THE COMMON CASE.** A server that never stops
    /// saying `truncated: true` must not spin `pagedQueueItems` forever — it
    /// gives up after `itemsMaxPages` and reports the result `truncated`,
    /// which is what tells the panel to say some rows are missing
    /// (`CockpitView.queueTruncatedNotice`) rather than silently presenting a
    /// partial list as the whole queue.
    func testPagedQueueItemsSurfacesTruncationWhenTheServerNeverStops() throws {
        var calls = 0
        let (items, truncated) = try LibraryClient.pagedQueueItems { _ in
            calls += 1
            return self.curlResponse(status: 200, body: """
            {"items":[{"id":"i\(calls)","title":"item \(calls)","state":"open"}],"truncated":true}
            """)
        }
        XCTAssertEqual(calls, LibraryClient.itemsMaxPages)
        XCTAssertEqual(items.count, LibraryClient.itemsMaxPages)
        XCTAssertTrue(truncated)
    }

    /// An empty page ends the loop even while `truncated: true` — advancing
    /// `offset` by zero would otherwise spin without making progress, and an
    /// empty page can never mean "there is more" in any useful sense.
    func testPagedQueueItemsStopsOnAnEmptyPageEvenIfTruncated() throws {
        let raw = curlResponse(status: 200, body: #"{"items":[],"truncated":true}"#)
        let (items, truncated) = try LibraryClient.pagedQueueItems { _ in raw }
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(truncated)
    }

    // MARK: - Decode: epics

    func testDecodesEpicsWithTheirDates() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"epic_1","state":"fixed","resolution":"fixed",
                    "created_at":"2026-08-01T00:00:00Z","resolved_at":"2026-08-25T00:00:00Z"}]}
        """)
        let epics = try LibraryClient.decodeEpics(raw)
        XCTAssertEqual(epics, [
            LibraryClient.Epic(id: "epic_1", state: "fixed", resolution: "fixed",
                               createdAt: "2026-08-01T00:00:00Z", resolvedAt: "2026-08-25T00:00:00Z"),
        ])
    }

    /// Mirrors `decodeChildItems`'s leniency: an absent `items` key degrades
    /// to an empty list rather than throwing.
    func testAMissingItemsKeyDecodesToNoEpics() throws {
        let raw = curlResponse(status: 200, body: "{}")
        XCTAssertEqual(try LibraryClient.decodeEpics(raw), [])
    }

    /// A field costs itself — an epic with no dates is still decoded, so
    /// `BeadProgress.compute` can apply its own missing-date defaults rather
    /// than the epic vanishing before it gets there.
    func testAnEpicWithNoDatesIsStillDecoded() throws {
        let raw = curlResponse(status: 200, body: #"{"items":[{"id":"epic_1","state":"open"}]}"#)
        let epics = try LibraryClient.decodeEpics(raw)
        XCTAssertEqual(epics, [LibraryClient.Epic(id: "epic_1", state: "open", resolution: nil,
                                                   createdAt: nil, resolvedAt: nil)])
    }

    func testAnEpicWithNoIdIsDropped() throws {
        let raw = curlResponse(status: 200, body: #"{"items":[{"state":"open"}]}"#)
        XCTAssertEqual(try LibraryClient.decodeEpics(raw), [])
    }

    /// The Proposals region reads all three, so they must survive the
    /// decode; an epic that carries none still decodes, with all `nil`.
    func testDecodesAnEpicsTitleMaturityAndSpecification() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"epic_1","state":"open","title":"Ship the widget","maturity":"proposed",
                    "specification":"Do the thing"},
                  {"id":"epic_2","state":"open"}]}
        """)
        let epics = try LibraryClient.decodeEpics(raw)
        XCTAssertEqual(epics.map(\.title), ["Ship the widget", nil])
        XCTAssertEqual(epics.map(\.maturity), ["proposed", nil])
        XCTAssertEqual(epics.map(\.specification), ["Do the thing", nil])
    }

    // MARK: - Decode: work item records (the chip join's own read)

    func testDecodesWorkItemRecordsWithEveryField() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"id":"issue_KID","title":"A filed item","type":"bug","parent_id":"issue_EPIC",
                    "key":"E9·4","pr":"298","pr_url":"https://example.invalid/298",
                    "pr_repo":"convivy/convivy-deck"}]}
        """)
        let items = try LibraryClient.decodeWorkItemRecords(raw)
        XCTAssertEqual(items, [
            LibraryClient.WorkItemRecord(id: "issue_KID", title: "A filed item", type: "bug",
                                         parentId: "issue_EPIC", key: "E9·4", pr: "298",
                                         prURL: "https://example.invalid/298", prRepo: "convivy/convivy-deck"),
        ])
    }

    /// Mirrors `decodeEpics`'s leniency: an absent `items` key degrades to an
    /// empty list rather than throwing.
    func testAMissingItemsKeyDecodesToNoWorkItemRecords() throws {
        let raw = curlResponse(status: 200, body: "{}")
        XCTAssertEqual(try LibraryClient.decodeWorkItemRecords(raw), [])
    }

    /// A field costs itself — an item carrying none of the optional fields
    /// still decodes, with `parentId` absent (a top-level item) and no
    /// identity to join on.
    func testAWorkItemRecordWithNoOptionalFieldsIsStillDecoded() throws {
        let raw = curlResponse(status: 200, body: #"{"items":[{"id":"issue_1","title":"Bare item"}]}"#)
        XCTAssertEqual(try LibraryClient.decodeWorkItemRecords(raw),
                       [LibraryClient.WorkItemRecord(id: "issue_1", title: "Bare item")])
    }

    func testAWorkItemRecordMissingIdOrTitleIsDropped() throws {
        let raw = curlResponse(status: 200, body: """
        {"items":[{"title":"No id"},{"id":"issue_1"}]}
        """)
        XCTAssertEqual(try LibraryClient.decodeWorkItemRecords(raw), [])
    }

    // MARK: - Proposals: the filter

    private func epic(_ id: String, maturity: String?, state: String? = "open",
                      resolution: String? = nil, specification: String? = nil) -> LibraryClient.Epic {
        LibraryClient.Epic(id: id, state: state, resolution: resolution, createdAt: nil,
                           resolvedAt: nil, title: "Epic \(id)", maturity: maturity,
                           specification: specification)
    }

    /// A proposed epic appears; an approved, built, superseded or unset (with
    /// no specification) one does not.
    func testOnlyAnOpenProposedEpicIsAProposal() {
        let epics = [
            epic("proposed", maturity: "proposed"),
            epic("approved", maturity: "approved"),
            epic("built", maturity: "built"),
            epic("superseded", maturity: "superseded"),
            epic("unset", maturity: nil),
        ]
        XCTAssertEqual(LibraryClient.proposedEpics(from: epics).map(\.id), ["proposed"])
    }

    /// The Library answers 409 to a correction on a terminal item, so an
    /// Approve on a resolved epic could only fail. It must not draw.
    func testAResolvedEpicIsNotAProposalEvenIfItsMaturityReadsProposed() {
        let epics = [
            epic("done", maturity: "proposed", state: "fixed", resolution: "fixed"),
            epic("dropped", maturity: "proposed", state: "wontfix"),
            epic("live", maturity: "proposed", state: "claimed"),
        ]
        XCTAssertEqual(LibraryClient.proposedEpics(from: epics).map(\.id), ["live"])
    }

    /// Mirrors Orient's `put_forward()` (convivy-orient, `issue_build.py`):
    /// `POST /items` has never accepted `maturity`, so every epic the
    /// Library creates starts with none. An unset maturity plus a written
    /// specification is a real proposal nobody has stamped yet, not an epic
    /// nobody has assessed.
    func testAnUnsetMaturityWithASpecificationIsAProposal() {
        let epics = [epic("a", maturity: nil, specification: "Do the thing")]
        XCTAssertEqual(LibraryClient.proposedEpics(from: epics).map(\.id), ["a"])
    }

    /// `maturity` trims to empty exactly like `nil` does, since Orient's rule
    /// operates on the trimmed string in both places.
    func testABlankMaturityWithASpecificationIsAProposal() {
        let epics = [epic("a", maturity: "  ", specification: "Do the thing")]
        XCTAssertEqual(LibraryClient.proposedEpics(from: epics).map(\.id), ["a"])
    }

    /// A whitespace-only specification trims to empty, so an unset-maturity
    /// epic with one is still not a proposal.
    func testUnsetMaturityWithAWhitespaceOnlySpecificationIsNotAProposal() {
        let epics = [epic("a", maturity: nil, specification: "   \n  ")]
        XCTAssertTrue(LibraryClient.proposedEpics(from: epics).isEmpty)
    }

    /// A specification does not override an explicit non-`proposed`
    /// maturity — only an unset one falls back to it.
    func testApprovedMaturityWithASpecificationIsNotAProposal() {
        let epics = [epic("a", maturity: "approved", specification: "Do the thing")]
        XCTAssertTrue(LibraryClient.proposedEpics(from: epics).isEmpty)
    }

    /// The resolved guard applies to the specification branch the same way
    /// it applies to the `proposed`-maturity branch.
    func testAResolvedEpicWithAnUnsetMaturityAndASpecificationIsNotAProposal() {
        let epics = [epic("a", maturity: nil, state: "fixed", resolution: "fixed",
                          specification: "Do the thing")]
        XCTAssertTrue(LibraryClient.proposedEpics(from: epics).isEmpty)
    }

    // MARK: - Approving an epic: the write's command shape

    /// The guard the write must pass: the protocol header and the JSON content
    /// type are present, the token reaches curl through its config on stdin,
    /// and no `-H Authorization` puts it in argv where `ps` on the mini would
    /// show it.
    func testTheApproveWriteCommandCarriesTheProtocolHeaderAndNeverArgvsTheToken() {
        let command = LibraryClient.itemApproveRemoteCommand(itemId: "issue_01ABC")
        XCTAssertTrue(command.contains("Library-Protocol: 1"))
        XCTAssertTrue(command.contains("Content-Type: application/json"))
        XCTAssertTrue(command.contains("--config -"))
        XCTAssertTrue(command.contains("-X POST"))
        XCTAssertFalse(command.contains("-H \"Authorization"))
        XCTAssertFalse(command.contains("-H 'Authorization"))
    }

    /// `/approve` and not `/correct`: `/correct` now refuses `maturity` by
    /// name and points here (`platform/decisions/0087`), and no other route
    /// holds an epic for this write the way `/approve` does.
    func testTheApproveWriteAddressesTheApproveRouteOfTheNamedItem() {
        let command = LibraryClient.itemApproveRemoteCommand(itemId: "issue_01ABC")
        XCTAssertTrue(command.contains("/items/issue_01ABC/approve\""))
        XCTAssertFalse(command.contains("/correct"))
        XCTAssertFalse(command.contains("/revision"))
    }

    /// **THE CREDENTIAL BOUNDARY, MEASURED ON THE COMMAND STRING.** The
    /// approve write must read `deck-library-token`, never the shared
    /// `agent-platform-token` (kind `agent`, cannot hold `epic.approve`) and
    /// never `library-client-token` (the same-directory trap — resolves
    /// `approved_client` too, but as actor `orient`; see
    /// `WorkingCopyStore.libraryApprovalTokenFile`'s doc). Every other write
    /// and every read in this file keeps reading the shared file.
    func testTheApproveWriteReadsTheApprovalCredentialAndNoOther() {
        let command = LibraryClient.itemApproveRemoteCommand(itemId: "issue_01ABC")
        XCTAssertTrue(command.contains("cat ~/.orient-control/deck-library-token"), command)
        XCTAssertFalse(command.contains("agent-platform-token"), command)
        XCTAssertFalse(command.contains("library-client-token"), command)
    }

    func testEveryOtherWriteAndReadStillReadsTheSharedCredential() {
        XCTAssertTrue(LibraryClient.courseOrderRemoteCommand(courseId: "course_1")
            .contains("agent-platform-token"))
        XCTAssertTrue(LibraryClient.itemRemoteCommand(itemId: "issue_1")
            .contains("agent-platform-token"))
        XCTAssertTrue(LibraryClient.coursesListRemoteCommand(product: "p")
            .contains("agent-platform-token"))
    }

    /// The body travels as process stdin and never enters the command string.
    func testTheApproveWriteCommandNamesNoBodyContent() {
        let command = LibraryClient.itemApproveRemoteCommand(itemId: "issue_01ABC")
        XCTAssertTrue(command.contains(#"data-binary = "@-""#))
        XCTAssertFalse(command.contains("maturity"))
        XCTAssertFalse(command.contains("acting_human"))
    }

    /// The whole payload is two keys. `owner` would name a checkout Deck does
    /// not take; sending it is a claim Deck cannot back.
    func testTheApproveBodyIsExactlyMaturityAndActingHuman() {
        let body = LibraryClient.approveEpicBody(actingHuman: "deck:operator@example.com")
        XCTAssertEqual(Set(body.keys), ["maturity", "acting_human"])
        XCTAssertEqual(body["maturity"] as? String, "approved")
        XCTAssertEqual(body["acting_human"] as? String, "deck:operator@example.com")
    }

    func testTheApproveArgumentsCarryTheControlMasterAndAddressTheTarget() throws {
        let target = SSHTarget(user: "operator", host: "10.0.0.5")
        let args = try LibraryClient.approveEpicArguments(target: target, itemId: "issue_01ABC")
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("operator@10.0.0.5"))
        XCTAssertTrue(try XCTUnwrap(args.last).contains("/items/issue_01ABC/approve"))
    }

    /// An id that fails validation throws before any command string exists, so
    /// a hostile id read back from the Library's JSON cannot reach the mini's
    /// shell. `approveEpic` builds its argv through this, so it inherits the
    /// refusal.
    func testTheApproveArgumentsRefuseAnIdThatCouldInjectIntoTheCommand() {
        for hostile in ["issue_01`whoami`", "a b", "x$(id)", "../approve", "", "a;b"] {
            XCTAssertThrowsError(try LibraryClient.approveEpicArguments(
                target: TestHost.target, itemId: hostile), "\(hostile) was accepted") { error in
                guard case LibraryClient.FetchError.invalidInput = error else {
                    return XCTFail("expected invalidInput for \(hostile), got \(error)")
                }
            }
        }
        XCTAssertThrowsError(try LibraryClient.approveEpic(target: TestHost.target, itemId: "a b", actingHuman: "operator"))
    }

    /// A real bash runs the real command against a listener standing in for
    /// the Library, so the request that arrives is the one the mini would
    /// send — and carries `acting_human` unmangled, the field this write
    /// gained over the old `/correct` body.
    func testTheApproveBodyArrivesAtTheListenerIntact() throws {
        try assertPOSTBodySurvivesRoundTrip(
            command: LibraryClient.itemApproveRemoteCommand(itemId: "issue_01ABC"),
            body: LibraryClient.approveEpicBody(actingHuman: "deck:operator@example.com"),
            field: "acting_human", expectedValue: "deck:operator@example.com",
            expectedRequestLine: "POST /items/issue_01ABC/approve HTTP/1.1")
    }

    /// `acting_human` is operator-adjacent text reaching the same shell-safe
    /// channel `LibraryClient.swift`'s "SHELL-SAFE POST BODIES" comment
    /// describes — this is the hostile-content half of that guarantee,
    /// proven against a real shell rather than asserted from the comment.
    func testAHostileActingHumanSurvivesTheShellRoundTripUnmangled() throws {
        let hostile = #"`whoami` $(id) "quoted" 'quoted' \backslash"#
        let request = try captureRequest(
            command: LibraryClient.itemApproveRemoteCommand(itemId: "issue_01ABC"),
            body: LibraryClient.approveEpicBody(actingHuman: hostile))
        XCTAssertEqual(request.body["acting_human"] as? String, hostile)
    }

    // MARK: - Approving an epic: `acting_human`'s local bound

    /// Mirrors the Library's own `identity.attested_human`: trimmed,
    /// non-empty, no longer than `MAX_ACTOR` (200, `store.py:474`,
    /// confirmed against the deployed Library 2026-09-22).
    func testValidateActingHumanTrimsAndAccepts() throws {
        XCTAssertEqual(try LibraryClient.validateActingHuman("  deck:operator@example.com  "), "deck:operator@example.com")
    }

    /// The case that must fail: nothing to attest to.
    func testValidateActingHumanRefusesEmptyOrWhitespaceOnly() {
        for empty in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(try LibraryClient.validateActingHuman(empty), "\"\(empty)\" should not validate") { error in
                guard case LibraryClient.FetchError.invalidActingHuman(let reason) = error else {
                    return XCTFail("expected invalidActingHuman, got \(error)")
                }
                XCTAssertFalse(reason.isEmpty)
            }
        }
    }

    /// The other case that must fail: over the Library's own bound, refused
    /// locally in words that name the actual count and the actual limit
    /// rather than a generic "invalid input".
    func testValidateActingHumanRefusesOverTheLibrarysBound() throws {
        let tooLong = String(repeating: "a", count: LibraryClient.maxActingHumanLength + 1)
        XCTAssertThrowsError(try LibraryClient.validateActingHuman(tooLong)) { error in
            guard case LibraryClient.FetchError.invalidActingHuman(let reason) = error else {
                return XCTFail("expected invalidActingHuman, got \(error)")
            }
            XCTAssertTrue(reason.contains("\(tooLong.count)"), reason)
            XCTAssertTrue(reason.contains("\(LibraryClient.maxActingHumanLength)"), reason)
        }
        XCTAssertNoThrow(try LibraryClient.validateActingHuman(
            String(repeating: "a", count: LibraryClient.maxActingHumanLength)),
            "exactly at the bound should validate")
    }

    /// `approveEpic` refuses locally before building any request — a degenerate
    /// `actingHuman` never reaches curl, and the target need not even resolve.
    func testApproveEpicRefusesADegenerateActingHumanLocally() {
        for degenerate in ["", "   "] {
            XCTAssertThrowsError(try LibraryClient.approveEpic(
                target: TestHost.unreachableTarget, itemId: "issue_01ABC", actingHuman: degenerate)) { error in
                guard case LibraryClient.FetchError.invalidActingHuman = error else {
                    return XCTFail("expected invalidActingHuman for \"\(degenerate)\", got \(error)")
                }
            }
        }
        let tooLong = String(repeating: "a", count: LibraryClient.maxActingHumanLength + 1)
        XCTAssertThrowsError(try LibraryClient.approveEpic(
            target: TestHost.unreachableTarget, itemId: "issue_01ABC", actingHuman: tooLong)) { error in
            guard case LibraryClient.FetchError.invalidActingHuman = error else {
                return XCTFail("expected invalidActingHuman, got \(error)")
            }
        }
    }

    /// The local refusal renders in words an operator can act on, the same
    /// row-level shape every other refusal takes (`approvalRefusalMessage`).
    func testADegenerateActingHumanRefusalReadsAsWordsAnOperatorCanAct() {
        let message = LibraryClient.approvalRefusalMessage(
            LibraryClient.FetchError.invalidActingHuman("Deck has no operator name to send with this approval."))
        XCTAssertEqual(message, "Deck has no operator name to send with this approval.")
    }

    // MARK: - Approving an epic: the actor assertion

    /// **THE CHECK THAT CAN TELL `deck-library-token` FROM `library-client-token`.**
    /// Both resolve `approved_client` with the identical capability set,
    /// including `epic.approve`, so a capability check cannot distinguish
    /// them — only the answering `actor` can, and only a call that actually
    /// reaches the Library can read it. Decode-only, against a canned
    /// response shaped exactly like the running Library's (confirmed on the
    /// wire 2026-09-22: `{"actor","kind","products","capabilities"}`).
    func testDecodeWhoamiReadsTheActor() throws {
        let raw = curlResponse(status: 200, body: #"""
        {"actor":"deck","kind":"approved_client","products":["*"],"capabilities":["epic.approve","course.write"]}
        """#)
        let whoami = try LibraryClient.decodeWhoami(raw)
        XCTAssertEqual(whoami.actor, "deck")
        XCTAssertEqual(whoami.kind, "approved_client")
        XCTAssertEqual(Set(whoami.capabilities), ["epic.approve", "course.write"])
    }

    func testWhoamiCommandReadsTheApprovalCredential() {
        let command = LibraryClient.whoamiRemoteCommand()
        XCTAssertTrue(command.contains("/whoami\""))
        XCTAssertTrue(command.contains("cat ~/.orient-control/deck-library-token"), command)
        XCTAssertFalse(command.contains("agent-platform-token"), command)
        XCTAssertFalse(command.contains("library-client-token"), command)
    }

    /// **THE LIVE CHECK THE EPIC'S DONE-WHEN NAMES**: "add a test that calls
    /// GET /whoami with whatever WorkingCopyStore hands the Library client
    /// and checks it answers deck, not merely that the call returns 200."
    /// `decodeWhoami`'s canned-response test above cannot catch the actual
    /// trap — the wrong SECRET sitting at the right PATH — because nothing
    /// about a wrong-but-present file makes decoding fail; only a call that
    /// genuinely reaches the Library and reads back `actor` can. Runs the
    /// real `whoamiRemoteCommand()` through `/bin/bash` with no
    /// `LIBRARY_BASE_URL` override, so it falls through to the Library this
    /// machine actually runs (`WorkingCopyStore.libraryBaseURLExpression`'s
    /// own default) and reads the real
    /// `~/.orient-control/deck-library-token` — confirmed by hand before
    /// this test existed (`curl` against the running Library, 2026-09-22):
    /// `deck-library-token` answers `actor: "deck"`, `library-client-token`
    /// answers `actor: "orient"`, same capabilities on both.
    func testLiveApprovalCredentialResolvesAsDeckNotOrient() throws {
        try requireLiveApprovalToken()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", LibraryClient.whoamiRemoteCommand()]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let raw = stdout.fileHandleForReading.readDataToEndOfFile()
        let whoami = try LibraryClient.decodeWhoami(raw)
        XCTAssertEqual(whoami.actor, "deck",
                       "the approval credential resolved as \(whoami.actor ?? "nil"), not deck — "
                       + "check ~/.orient-control/deck-library-token on this machine")
    }

    /// Skips only when this machine has no approval token provisioned at
    /// all — the same "skip rather than fail the whole suite on a missing
    /// live dependency" shape `KeelHTTPExchangeTests.requireLiveSocket`
    /// takes for the `run-register-api` socket.
    private func requireLiveApprovalToken(file: StaticString = #filePath, line: UInt = #line) throws {
        let path = (WorkingCopyStore.libraryApprovalTokenFile as NSString).expandingTildeInPath
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: path),
            "no \(WorkingCopyStore.libraryApprovalTokenFile) on this machine — this live check only "
            + "runs where Deck's own approval credential is provisioned",
            file: file, line: line)
    }

    // MARK: - Reordering the Course

    private func courseBody(entries: String, items: String, extra: String = #""version":7,"#) -> Data {
        curlResponse(status: 200, body: #"{"id":"course_1","product":"p","title":"T",\#(extra)"entries":[\#(entries)],"items":[\#(items)]}"#)
    }

    /// `version` is what the order route checks, so it must be read.
    func testACourseDecodesItsVersion() throws {
        let course = try LibraryClient.decodeCourse(courseBody(
            entries: #""a""#, items: #"{"id":"a","title":"A"}"#))
        XCTAssertEqual(course.version, 7)
    }

    /// No version, a boolean, or a fraction leaves the Course unwritable
    /// rather than guessing one. A JSON `true` is an `NSNumber` and would
    /// otherwise read as 1, which passes against a fresh Course.
    func testAMissingOrNonIntegerVersionDecodesToNil() throws {
        let items = #"{"id":"a","title":"A"}"#
        for extra in ["", #""version":true,"#, #""version":"7","#, #""version":7.5,"#, #""version":null,"#] {
            let course = try LibraryClient.decodeCourse(courseBody(entries: #""a""#, items: items, extra: extra))
            XCTAssertNil(course.version, "\(extra) should not decode as a version")
        }
    }

    /// **THE HAZARD.** The rendered rows drop an id with no resolved item;
    /// the served array must keep it, in the Library's own order.
    func testTheServedEntryIdsKeepAnIdThatResolvesToNoItem() throws {
        let course = try LibraryClient.decodeCourse(courseBody(
            entries: #""a","ghost","b""#,
            items: #"{"id":"a","title":"A"},{"id":"b","title":"B"}"#))
        XCTAssertEqual(course.entries.map(\.id), ["a", "b"], "the ghost is not drawn")
        XCTAssertEqual(course.servedEntryIds, ["a", "ghost", "b"], "but it is still in the Course")
    }

    func testMovingDownLandsAfterTheTargetAndMovingUpLandsBefore() {
        let served = ["a", "b", "c", "d"]
        XCTAssertEqual(LibraryClient.reorderedEntryIds(served, moving: "a", onto: "c"), ["b", "c", "a", "d"])
        XCTAssertEqual(LibraryClient.reorderedEntryIds(served, moving: "d", onto: "b"), ["a", "d", "b", "c"])
        XCTAssertEqual(LibraryClient.reorderedEntryIds(served, moving: "b", onto: "c"), ["a", "c", "b", "d"])
    }

    /// The case that must now fail: nothing to write when nothing moves or an
    /// id is not in the Course, so no PUT can carry a guess.
    func testAMoveThatChangesNothingOrNamesAStrangerProducesNoOrder() {
        let served = ["a", "b"]
        XCTAssertNil(LibraryClient.reorderedEntryIds(served, moving: "a", onto: "a"))
        XCTAssertNil(LibraryClient.reorderedEntryIds(served, moving: "x", onto: "a"))
        XCTAssertNil(LibraryClient.reorderedEntryIds(served, moving: "a", onto: "x"))
        XCTAssertNil(LibraryClient.reorderedEntryIds([], moving: "a", onto: "b"))
    }

    /// The outgoing array for a Course with an unresolved id, built the way
    /// the model builds it (decode, then move within the served array). The
    /// ghost stays, next to the neighbour it sat beside.
    func testAReorderOfACourseWithAnUnresolvedEntryKeepsItInTheOutgoingArray() throws {
        let course = try LibraryClient.decodeCourse(courseBody(
            entries: #""a","ghost","b","c""#,
            items: #"{"id":"a","title":"A"},{"id":"b","title":"B"},{"id":"c","title":"C"}"#))
        let down = try XCTUnwrap(LibraryClient.reorderedEntryIds(course.servedEntryIds, moving: "a", onto: "b"))
        XCTAssertEqual(down, ["ghost", "b", "a", "c"])
        let up = try XCTUnwrap(LibraryClient.reorderedEntryIds(course.servedEntryIds, moving: "c", onto: "a"))
        XCTAssertEqual(up, ["c", "a", "ghost", "b"])
        for order in [down, up] {
            XCTAssertEqual(Set(order), Set(course.servedEntryIds), "no id gained or lost")
        }
    }

    func testTheOptimisticPictureFollowsTheServedOrderAndKeepsTheVersion() throws {
        let course = try LibraryClient.decodeCourse(courseBody(
            entries: #""a","ghost","b""#,
            items: #"{"id":"a","title":"A"},{"id":"b","title":"B"}"#))
        let moved = course.reordered(toServed: ["ghost", "b", "a"])
        XCTAssertEqual(moved.entries.map(\.id), ["b", "a"])
        XCTAssertEqual(moved.servedEntryIds, ["ghost", "b", "a"])
        XCTAssertEqual(moved.version, 7)
    }

    func testTheOrderWriteIsAPutWithTheProtocolHeaderAndNeverArgvsTheToken() {
        let command = LibraryClient.courseOrderRemoteCommand(courseId: "course_1")
        XCTAssertTrue(command.contains("-X PUT"))
        XCTAssertFalse(command.contains("-X POST"))
        XCTAssertTrue(command.contains("/courses/course_1/order\""))
        XCTAssertTrue(command.contains("Library-Protocol: 1"))
        XCTAssertTrue(command.contains("--config -"))
        XCTAssertTrue(command.contains(#"data-binary = "@-""#))
        XCTAssertFalse(command.contains("-H \"Authorization"))
        XCTAssertFalse(command.contains("-H 'Authorization"))
    }

    /// The POST builders still say POST after the shared builder gained a verb.
    func testTheApproveWriteIsStillAPost() {
        XCTAssertTrue(LibraryClient.itemApproveRemoteCommand(itemId: "issue_1").contains("-X POST"))
        XCTAssertFalse(LibraryClient.itemApproveRemoteCommand(itemId: "issue_1").contains("-X PUT"))
    }

    func testTheOrderArgumentsRefuseACourseIdThatCouldInjectIntoTheCommand() throws {
        for hostile in ["course_1`whoami`", "a b", "x$(id)", "../order", "", "a;b"] {
            XCTAssertThrowsError(try LibraryClient.reorderCourseArguments(
                target: TestHost.target, courseId: hostile), "\(hostile) was accepted") { error in
                guard case LibraryClient.FetchError.invalidInput = error else {
                    return XCTFail("expected invalidInput for \(hostile), got \(error)")
                }
            }
        }
        let args = try LibraryClient.reorderCourseArguments(target: TestHost.target, courseId: "course_1")
        XCTAssertTrue(try XCTUnwrap(args.last).contains("/courses/course_1/order"))
        XCTAssertThrowsError(try LibraryClient.reorderCourse(
            target: TestHost.target, courseId: "a b", version: 1, entries: []))
    }

    /// A real bash runs the real command against a listener standing in for
    /// the Library: the request is a PUT to the order route carrying the
    /// version and the full array, ghost included.
    func testTheOrderBodyArrivesAtTheListenerAsAPutWithVersionAndEveryId() throws {
        let request = try captureRequest(
            command: LibraryClient.courseOrderRemoteCommand(courseId: "course_1"),
            body: LibraryClient.courseOrderBody(version: 7, entries: ["ghost", "b", "a"]))
        XCTAssertEqual(request.requestLine, "PUT /courses/course_1/order HTTP/1.1")
        XCTAssertEqual(request.body["version"] as? Int, 7)
        XCTAssertEqual(request.body["entries"] as? [String], ["ghost", "b", "a"])
        XCTAssertEqual(Set(request.body.keys), ["version", "entries"])
    }

    // MARK: - Reordering the Course: refusals

    private let staleBody = """
    {"error":"version mismatch: this Course changed since you read it","your_version":7,"current_version":8,"current_entries":["b","a"],"hint":"rebase your change onto current_entries and retry"}
    """

    /// Only a 409 carrying `current_version` is "someone else reordered it".
    /// A superseded Course is also a 409 and must not be told that story.
    func testOnlyAVersionMismatchReadsAsStale() {
        XCTAssertTrue(LibraryClient.isStaleVersionRefusal(refusal(409, staleBody)))
        XCTAssertFalse(LibraryClient.isStaleVersionRefusal(refusal(
            409, #"{"error":"this Course is superseded and is kept as a record; it cannot be changed"}"#)))
        XCTAssertFalse(LibraryClient.isStaleVersionRefusal(refusal(400, staleBody)))
        XCTAssertFalse(LibraryClient.isStaleVersionRefusal(refusal(409, "<html>")))
        XCTAssertFalse(LibraryClient.isStaleVersionRefusal(LibraryClient.FetchError.unexpectedResponse("x")))
    }

    func testAStaleRefusalSaysTheMoveWasNotAppliedAndDoesNotOfferToRetry() {
        let message = LibraryClient.reorderRefusalMessage(refusal(409, staleBody))
        XCTAssertTrue(message.contains("Someone else reordered the Course"))
        XCTAssertTrue(message.contains("your move was not applied"))
        XCTAssertFalse(message.lowercased().contains("retry"))
    }

    func testAnUnknownEpicRefusalNamesTheIdsTheLibraryNamed() {
        let message = LibraryClient.reorderRefusalMessage(refusal(400, """
        {"error":"no such work item, or none this identity may see","unknown":["issue_ghost"]}
        """))
        XCTAssertEqual(message, "no such work item, or none this identity may see (issue_ghost)")
    }

    func testASupersededCourseRefusalPassesTheLibrarysWordsThrough() {
        let message = LibraryClient.reorderRefusalMessage(refusal(
            409, #"{"error":"this Course is superseded and is kept as a record; it cannot be changed"}"#))
        XCTAssertEqual(message, "this Course is superseded and is kept as a record; it cannot be changed")
    }

    // MARK: - Approving an epic: what the button says when the write is refused

    private func refusal(_ status: Int, _ json: String) -> Error {
        LibraryClient.FetchError.libraryRefused(status: status, body: json)
    }

    private var arizona: TimeZone { TimeZone(secondsFromGMT: -7 * 3600)! }
    private var posix: Locale { Locale(identifier: "en_US_POSIX") }
    /// 2026-09-20T18:00:00Z, which is 11:00 in `arizona`.
    private var now: Date { Date(timeIntervalSince1970: 1_789_927_200) }

    private func heldMessage(expiresAt: String) -> String {
        LibraryClient.approvalRefusalMessage(
            refusal(409, """
            {"error":"issue_01ABC is held by co-convivy-deck-pickup, not deck; a correction waits for the holder",
             "reason":"held",
             "lease":{"holder":"co-convivy-deck-pickup","expires_at":"\(expiresAt)","dead":false}}
            """),
            now: now, timeZone: arizona, locale: posix)
    }

    /// The point of the button's refusal: it names who holds the epic and
    /// until when, in the operator's own clock.
    func testAHeldEpicSaysWhoHoldsItAndUntilWhen() {
        let message = heldMessage(expiresAt: "2026-09-20T22:41:38Z")
        XCTAssertTrue(message.contains("co-convivy-deck-pickup"), message)
        XCTAssertTrue(message.contains("3:41"), message)
        XCTAssertFalse(message.contains("Sep"), "an expiry later today carries no date: \(message)")
    }

    func testAnExpiryOnAnotherDayCarriesTheDate() {
        let message = heldMessage(expiresAt: "2026-09-21T22:41:38Z")
        XCTAssertTrue(message.contains("Sep 21"), message)
    }

    /// A fractional-seconds instant still parses; an unparseable one falls
    /// back to the raw text and keeps the holder's name.
    func testAnExpiryTheClientCannotParseStillNamesTheHolder() {
        XCTAssertTrue(heldMessage(expiresAt: "2026-09-20T22:41:38.123456Z").contains("3:41"))
        let message = heldMessage(expiresAt: "tomorrow-ish")
        XCTAssertTrue(message.contains("co-convivy-deck-pickup"), message)
        XCTAssertTrue(message.contains("tomorrow-ish"), message)
    }

    /// A hold outside this identity's scope carries no lease, so there is
    /// nobody to name; the Library's own words stand.
    func testAHeldRefusalWithNoLeaseFallsBackToTheLibrarysText() {
        let message = LibraryClient.approvalRefusalMessage(refusal(409, """
        {"error":"issue_01ABC is held by another session, and that lease is outside this identity's scope","reason":"held"}
        """))
        XCTAssertEqual(message, "issue_01ABC is held by another session, and that lease is outside this identity's scope")
    }

    /// An epic with no specification or definition of done cannot be approved
    /// (`_spec_gaps`); that is a 400 whose text tells the operator why.
    func testAnEpicMissingItsSpecificationSaysSo() {
        let message = LibraryClient.approvalRefusalMessage(refusal(400, """
        {"error":"an epic cannot be approved while it has no specification or definition_of_done"}
        """))
        XCTAssertEqual(message, "an epic cannot be approved while it has no specification or definition_of_done")
    }

    /// A credential missing `epic.approve` or `course.write` — `refusals.forbidden`'s
    /// shape, a 403 naming the capability rather than the resource. Distinct
    /// from every 409 above: no lease, no holder, just a capability the
    /// credential does not have.
    func testAMissingCapabilityNamesIt() {
        let message = LibraryClient.approvalRefusalMessage(refusal(403, """
        {"error":"this identity lacks 'epic.approve'"}
        """))
        XCTAssertEqual(message, "this identity lacks 'epic.approve'")
    }

    /// A product with no live Course refuses the approval — `_do_approve`'s
    /// `reason: "no_live_course"`, a 409 that is NOT the `held` shape and so
    /// must not be read as one (no lease, no holder to report).
    func testANoLiveCourseRefusalNamesTheProduct() {
        let message = LibraryClient.approvalRefusalMessage(refusal(409, """
        {"error":"convivy-deck has no live Course, so issue_01ABC cannot be approved: approving an epic puts it on the Course",
         "reason":"no_live_course"}
        """))
        XCTAssertTrue(message.contains("no live Course"), message)
        XCTAssertFalse(message.contains("Held by"), "no_live_course must not read as a held lease: \(message)")
    }

    /// `acting_human` missing or blank — `identity.attested_human`'s 403,
    /// reachable if `approveEpic`'s own local check were ever bypassed
    /// (a stale build, a future direct caller). The row must still say
    /// something an operator can act on rather than a raw Library string
    /// about a field Deck itself is supposed to have filled in.
    func testAMissingActingHumanFromTheLibraryItselfStillSaysSomething() {
        let message = LibraryClient.approvalRefusalMessage(refusal(403, """
        {"error":"acting_human is required"}
        """))
        XCTAssertEqual(message, "acting_human is required")
    }

    func testARefusalWithNoReadableBodyStillSaysSomething() {
        let message = LibraryClient.approvalRefusalMessage(refusal(502, "<html>bad gateway</html>"))
        XCTAssertTrue(message.contains("502"), message)
        XCTAssertTrue(message.contains("bad gateway"), message)
    }

    func testATransportFailureIsNotSwallowed() {
        let message = LibraryClient.approvalRefusalMessage(LibraryClient.FetchError.unexpectedResponse("ssh: timed out"))
        XCTAssertTrue(message.contains("ssh: timed out"), message)
    }

}

// MARK: - Shell-injection round-trip test infrastructure

/// Cross-thread capture of one value, for handing a result from the accept
/// thread in `assertPOSTBodySurvivesRoundTrip` back to the test's own thread.
/// A lock rather than an actor: the accept thread is a plain `Thread`
/// blocking on a synchronous BSD `accept()`/`read()`, which cannot await.
private final class ThreadSafeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    private var _isSet = false

    init(value: T) { _value = value }

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue; _isSet = true } }
    }

    var isSet: Bool { lock.withLock { _isSet } }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock(); defer { unlock() }
        return body()
    }
}

/// A one-shot raw TCP listener standing in for the Library in the
/// shell-injection round-trip tests — bound to an ephemeral loopback port,
/// the same BSD-socket pattern `WorkingCopyServerTests` already uses to
/// probe the real loopback server. It does not parse HTTP beyond finding
/// the header/body boundary and respecting `Content-Length`: the point is
/// capturing exactly the bytes that reached it, not being a real server.
private final class RawCapturingHTTPListener {
    let port: UInt16
    private let listenSocket: Int32

    init() throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw NSError(domain: "RawCapturingHTTPListener", code: 1)
        }
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(sock)
            throw NSError(domain: "RawCapturingHTTPListener", code: 2)
        }
        listen(sock, 1)

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getsockname(sock, sa, &len)
            }
        }
        listenSocket = sock
        port = CFSwapInt16BigToHost(bound.sin_port)
    }

    /// Blocks until one connection arrives, reads the request until the
    /// header/body boundary plus the declared `Content-Length`, replies with
    /// a minimal 200, and returns everything received (headers and body) as
    /// a string for the caller to search.
    func acceptOnceAndCaptureBody() -> String {
        let clientSocket = accept(listenSocket, nil, nil)
        guard clientSocket >= 0 else { return "" }
        defer { Darwin.close(clientSocket) }

        var buffer = [UInt8](repeating: 0, count: 65536)
        var all = Data()
        while true {
            let n = read(clientSocket, &buffer, buffer.count)
            if n <= 0 { break }
            all.append(contentsOf: buffer[0..<n])
            guard let headerEnd = all.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let headerText = String(data: all[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let bodySoFar = all[headerEnd.upperBound...]
            let expected = headerText
                .split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { $0.split(separator: ":").last }
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            if bodySoFar.count >= expected {
                break
            }
        }
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        _ = response.withCString { write(clientSocket, $0, strlen($0)) }
        return String(data: all, encoding: .utf8) ?? String(decoding: all, as: UTF8.self)
    }

    func close() {
        Darwin.close(listenSocket)
    }
}
