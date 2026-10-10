import XCTest
@testable import Deck

/// `ItemDetailPane`'s pure HTML generation and `DeckOperator`'s label
/// derivation — the pieces testable without a running WKWebView.
final class ItemDetailPaneTests: XCTestCase {

    /// A fixed nonce for every test that doesn't care about the fold marker
    /// itself, so `markdown(for:)` stays a one-argument call at most sites —
    /// only the tests exercising the fold need a real, tracked nonce.
    private let testNonce = "TEST-NONCE"

    private func markdown(for detail: LibraryClient.CorrectionDetail) -> String {
        ItemDetailPane.markdown(for: detail, nonce: testNonce)
    }

    // MARK: - HTML generation

    private func detail(
        body: String? = "plain body", title: String? = "A title",
        product: String? = "convivy-deck",
        specification: String? = nil, definitionOfDone: String? = nil,
        comments: [LibraryClient.CorrectionComment] = []
    ) -> LibraryClient.CorrectionDetail {
        LibraryClient.CorrectionDetail(
            id: "issue_01ABC", title: title, product: product,
            body: body, type: "bug", state: "open",
            severity: "low", needs: "agent", resolution: nil, outcomeNote: nil,
            claimedBy: nil, createdAt: nil, parentId: nil,
            specification: specification, definitionOfDone: definitionOfDone, comments: comments)
    }

    /// The body is text anyone who can file into a visible product controls
    /// — CLAUDE.md's escaping requirement for exactly this reason. A script
    /// tag in the body must render as inert text, never as markup the page
    /// executes (`allowsContentJavaScript = false` is the other half of that
    /// defense; this is the half that keeps the markup itself inert too).
    func testTheBodyIsHTMLEscaped() {
        let html = ItemDetailPane.page(
            for: detail(body: "<script>alert(1)</script> & \"quoted\""), appearance: .light)
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
        XCTAssertTrue(html.contains("&quot;quoted&quot;"))
    }

    /// A comment's body is the same kind of operator-controlled text as the
    /// item body, and gets the same escaping.
    func testACommentBodyIsHTMLEscaped() {
        let html = ItemDetailPane.page(
            for: detail(comments: [
                LibraryClient.CorrectionComment(
                    id: 1, actor: "<b>actor</b>", kind: "note",
                    body: "<img src=x onerror=alert(1)>", at: "2026-08-25T00:00:00Z"),
            ]),
            appearance: .light)
        XCTAssertFalse(html.contains("<img src=x onerror"))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        XCTAssertFalse(html.contains("<b>actor</b>"))
    }

    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    private let posix = Locale(identifier: "en_US_POSIX")
    /// 2026-09-16T06:30:00Z, which is 2026-09-16 12:00 in `kolkata`.
    private let now = Date(timeIntervalSince1970: 1_789_540_200)

    /// A comment's `at` draws in the reader's own zone, not the raw UTC
    /// instant the Library served — same day as `now` carries a clock
    /// reading alone; escaped exactly as the raw field was.
    func testCommentAtDrawsInTheReadersZoneInHTML() {
        let html = ItemDetailPane.page(
            for: detail(comments: [
                LibraryClient.CorrectionComment(
                    id: 1, actor: "operator", kind: "note", body: "looks fine", at: "2026-09-16T04:23:33Z"),
            ]),
            appearance: .light, now: now, timeZone: kolkata, locale: posix)
        XCTAssertTrue(html.contains("9:53\u{202F}AM"), html)
        XCTAssertFalse(html.contains("2026-09-16T04:23:33Z"))
    }

    /// An `at` on an earlier local day than `now` carries the date too.
    func testCommentAtOnAnEarlierDayCarriesTheDateInHTML() {
        let html = ItemDetailPane.page(
            for: detail(comments: [
                LibraryClient.CorrectionComment(
                    id: 1, actor: "operator", kind: "note", body: "looks fine", at: "2026-09-14T20:00:00Z"),
            ]),
            appearance: .light, now: now, timeZone: kolkata, locale: posix)
        XCTAssertTrue(html.contains("Sep 15 at 1:30\u{202F}AM"), html)
    }

    /// An `at` the client cannot parse draws unchanged.
    func testCommentAtUnparseableDrawsTheRawStringInHTML() {
        let html = ItemDetailPane.page(
            for: detail(comments: [
                LibraryClient.CorrectionComment(
                    id: 1, actor: "operator", kind: "note", body: "looks fine", at: "not-a-date"),
            ]),
            appearance: .light, now: now, timeZone: kolkata, locale: posix)
        XCTAssertTrue(html.contains("not-a-date"), html)
    }

    /// The shell is the single appearance authority — the pane stamps
    /// `data-theme` from the `Appearance` it is handed rather than reading
    /// `prefers-color-scheme`, so this pins that the value actually reaches
    /// the page.
    func testAppearanceStampsDataTheme() {
        XCTAssertTrue(ItemDetailPane.page(for: detail(), appearance: .light)
            .contains(#"data-theme="light""#))
        XCTAssertTrue(ItemDetailPane.page(for: detail(), appearance: .dark)
            .contains(#"data-theme="dark""#))
    }

    /// A missing title falls back to the id rather than an empty heading.
    func testAMissingTitleFallsBackToTheId() {
        let html = ItemDetailPane.page(for: detail(title: nil), appearance: .light)
        XCTAssertTrue(html.contains("issue_01ABC"))
    }

    /// No comments reads as an explicit empty state, not a blank section.
    func testNoCommentsShowsAnExplicitEmptyState() {
        let html = ItemDetailPane.page(for: detail(comments: []), appearance: .light)
        XCTAssertTrue(html.contains("No comments yet."))
    }

    // MARK: - Markdown composition

    /// The remote renderer produces the styled document; the source it
    /// renders from carries the same fields `page(for:)`'s fallback does.
    func testTheMarkdownDocumentCarriesTitleBodyAndMeta() {
        let md = markdown(for: detail(body: "plain body", title: "A title"))
        XCTAssertTrue(md.contains("# A title"))
        XCTAssertTrue(md.contains("plain body"))
        XCTAssertTrue(md.contains("bug"))
        XCTAssertTrue(md.contains("open"))
    }

    /// A missing title falls back to the id, same as the fallback page.
    func testAMissingTitleFallsBackToTheIdInMarkdown() {
        XCTAssertTrue(markdown(for: detail(title: nil)).contains("issue_01ABC"))
    }

    /// No comments reads as an explicit empty state in the composed document
    /// too, not a bare "## Comments" heading with nothing under it.
    func testNoCommentsShowsAnExplicitEmptyStateInMarkdown() {
        XCTAssertTrue(markdown(for: detail(comments: []))
            .contains("_No comments yet._"))
    }

    /// A comment's body appears in the composed document, under its own
    /// actor/kind/at line.
    func testACommentAppearsInTheMarkdownDocument() {
        let md = markdown(for: detail(comments: [
            LibraryClient.CorrectionComment(
                id: 1, actor: "operator", kind: "note", body: "looks fine", at: "2026-08-25T00:00:00Z"),
        ]))
        XCTAssertTrue(md.contains("operator"))
        XCTAssertTrue(md.contains("looks fine"))
    }

    /// A comment's `at` draws in the reader's own zone, not the raw UTC
    /// instant the Library served — same day as `now` carries a clock
    /// reading alone.
    func testCommentAtDrawsInTheReadersZoneInMarkdown() {
        let md = ItemDetailPane.markdown(
            for: detail(comments: [
                LibraryClient.CorrectionComment(
                    id: 1, actor: "operator", kind: "note", body: "looks fine", at: "2026-09-16T04:23:33Z"),
            ]), nonce: testNonce, now: now, timeZone: kolkata, locale: posix)
        XCTAssertTrue(md.contains("9:53\u{202F}AM"), md)
        XCTAssertFalse(md.contains("2026-09-16T04:23:33Z"))
    }

    /// An `at` on an earlier local day than `now` carries the date too.
    func testCommentAtOnAnEarlierDayCarriesTheDateInMarkdown() {
        let md = ItemDetailPane.markdown(
            for: detail(comments: [
                LibraryClient.CorrectionComment(
                    id: 1, actor: "operator", kind: "note", body: "looks fine", at: "2026-09-14T20:00:00Z"),
            ]), nonce: testNonce, now: now, timeZone: kolkata, locale: posix)
        XCTAssertTrue(md.contains("Sep 15 at 1:30\u{202F}AM"), md)
    }

    /// An `at` the client cannot parse draws unchanged.
    func testCommentAtUnparseableDrawsTheRawStringInMarkdown() {
        let md = ItemDetailPane.markdown(
            for: detail(comments: [
                LibraryClient.CorrectionComment(
                    id: 1, actor: "operator", kind: "note", body: "looks fine", at: "not-a-date"),
            ]), nonce: testNonce, now: now, timeZone: kolkata, locale: posix)
        XCTAssertTrue(md.contains("not-a-date"), md)
    }

    /// A newline in a single-line field (title, meta, a comment's actor)
    /// cannot open a new heading or paragraph mid-line — it collapses to a
    /// space instead. Exercised on the title, since it seeds the document's
    /// only "# " heading; a surviving newline there would let a second line
    /// of attacker-chosen text start its own top-level heading.
    func testANewlineInATitleCannotOpenASecondHeading() {
        let md = markdown(for: detail(title: "Real title\n# Injected heading"))
        XCTAssertEqual(md.components(separatedBy: "\n").filter { $0.hasPrefix("# ") }.count, 1)
    }

    /// A newline in a comment's actor cannot do the same to its meta line —
    /// the injected text survives (collapsed to a space, same as any other
    /// character in the actor field), but never as its own line, so it can
    /// never be read as a Markdown heading.
    func testANewlineInACommentActorCannotBreakItsMetaLine() {
        let md = markdown(for: detail(comments: [
            LibraryClient.CorrectionComment(
                id: 1, actor: "operator\n## Injected", kind: "note", body: "hi", at: "t"),
        ]))
        XCTAssertFalse(md.components(separatedBy: "\n").contains { $0.hasPrefix("## Injected") })
    }

    /// A body that opens a fenced code block and never closes it must not
    /// swallow the "## Comments" section composed after it — the failure
    /// mode this is written against is exactly that: without the fence
    /// balancer, "## Comments" and every comment would render as inert text
    /// inside the still-open fence rather than as their own section. The
    /// appended closer must match the opener's own character and length, or
    /// it does not actually close the fence.
    func testAnUnclosedFenceInTheBodyDoesNotSwallowComments() {
        let md = markdown(for: detail(
            body: "before\n```\nunterminated code",
            comments: [LibraryClient.CorrectionComment(id: 1, actor: "operator", kind: "note",
                                                        body: "after", at: "t")]))
        XCTAssertTrue(md.contains("unterminated code\n```\n"))
        XCTAssertTrue(md.contains("## Comments"))
    }

    /// A comment body with an unclosed fence gets the same treatment, so it
    /// cannot swallow whatever comment comes after it.
    func testAnUnclosedFenceInACommentDoesNotSwallowTheNextComment() {
        let md = markdown(for: detail(comments: [
            LibraryClient.CorrectionComment(id: 1, actor: "operator", kind: "note",
                                            body: "```\nunterminated", at: "t"),
            LibraryClient.CorrectionComment(id: 2, actor: "second-commenter", kind: "note",
                                            body: "second comment", at: "t"),
        ]))
        XCTAssertTrue(md.contains("second comment"))
        XCTAssertTrue(md.contains("second-commenter"))
    }

    /// An already-balanced fence (a normal fenced code block) is left
    /// untouched — the balancer only acts when a fence is still open at the
    /// end of the text.
    func testABalancedFenceInTheBodyIsUnchanged() {
        let body = "before\n```\ncode\n```\nafter"
        let md = markdown(for: detail(body: body))
        XCTAssertTrue(md.contains(body))
    }

    /// The dangerous direction a line-parity count gets wrong: a 4-backtick
    /// opener is not closed by a 3-backtick line, since CommonMark requires a
    /// closer at least as long as its opener. Counting fence-looking LINES
    /// (2 here) reads as even and leaves this untouched — the exact swallow
    /// this function exists to prevent, since the fence, and everything
    /// after it including "## Comments", stays open. Tracking fence PAIRS
    /// catches it: the fence is still open at the end, so a matching
    /// 4-backtick closer is appended.
    func testAFourBacktickFenceIsNotFalselyClosedByAShorterInnerLine() {
        let md = markdown(for: detail(
            body: "````\nunclosed forever\n```\nmore"))
        XCTAssertTrue(md.contains("more\n````\n"))
    }

    /// The other direction a line-parity count gets wrong: a 4-backtick fence
    /// genuinely closed, wrapping a literal 3-backtick line, reads as "3
    /// fence-looking lines, odd" and used to get a spurious closer appended —
    /// which itself opened a new, unpaired fence. Length-aware pairing
    /// recognizes the inner line as content, not a closer, and leaves an
    /// already-balanced fence alone.
    func testAClosedFourBacktickFenceWrappingAShorterInnerLineIsUnchanged() {
        let body = "````\n```\nouter content\n````"
        let md = markdown(for: detail(body: body))
        XCTAssertTrue(md.contains(body))
    }

    /// A tilde fence gets a tilde closer, never a backtick one — the two
    /// fence characters are distinct delimiters and don't close each other.
    func testAnUnclosedTildeFenceGetsATildeCloserNotABacktickOne() {
        let md = markdown(for: detail(body: "before\n~~~\nunterminated"))
        XCTAssertTrue(md.contains("unterminated\n~~~\n"))
    }

    /// A tilde line inside an open backtick fence is content, not a closer —
    /// mixing fence characters misfires the same way a too-short run does.
    func testATildeLineInsideAnOpenBacktickFenceDoesNotCloseIt() {
        let md = markdown(for: detail(body: "```\n~~~\nstill inside"))
        XCTAssertTrue(md.contains("still inside\n```\n"))
    }

    /// A fence-looking line indented 4+ spaces is CommonMark's indented code
    /// block, never a fence — it must not be mistaken for an opener or a
    /// closer.
    func testAFourSpaceIndentedFenceLookingLineIsNotAFence() {
        let body = "before\n    ```\nafter"
        let md = markdown(for: detail(body: body))
        XCTAssertTrue(md.contains(body))
    }

    // MARK: - Found during: the epic shown on an item

    /// The row's label resolves to the epic's title once the second fetch
    /// (`fetchDetail` reused against the `found_during` id) comes back.
    @MainActor
    func testFoundDuringTitleResolvesFromTheEpicsOwnDetail() async {
        let model = ItemDetailModel()
        model.fetchDetail = { _, id in
            id == "issue_EPIC"
                ? LibraryClient.CorrectionDetail(id: id, title: "The epic", type: "epic")
                : LibraryClient.CorrectionDetail(id: id, title: "A bug", foundDuring: "issue_EPIC")
        }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        await model.load(id: "issue_01ABC", target: TestHost.target, appearance: .light)
        await model.foundDuringTitleFetchTask?.value
        XCTAssertEqual(model.foundDuringTitle, "The epic")
    }

    /// "An id that doesn't resolve shows the id rather than nothing" — the
    /// model side of that: a failed second fetch leaves `foundDuringTitle`
    /// nil, which `ItemDetailPane.foundDuringSection` falls back to the raw
    /// id for.
    @MainActor
    func testFoundDuringTitleFallsBackToNilWhenTheEpicFetchFails() async {
        let model = ItemDetailModel()
        model.fetchDetail = { _, id in
            if id == "issue_EPIC" { throw LibraryClient.FetchError.libraryRefused(status: 404, body: "") }
            return LibraryClient.CorrectionDetail(id: id, title: "A bug", foundDuring: "issue_EPIC")
        }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        await model.load(id: "issue_01ABC", target: TestHost.target, appearance: .light)
        await model.foundDuringTitleFetchTask?.value
        XCTAssertNil(model.foundDuringTitle)
    }

    /// No `found_during` means no second fetch at all — the degrade rule:
    /// "a Library that doesn't serve the field shows nothing extra."
    @MainActor
    func testNoFoundDuringMeansNoTitleFetchRuns() async {
        let model = ItemDetailModel()
        model.fetchDetail = { _, id in
            if id == "issue_EPIC" { XCTFail("no found_during was set") }
            return LibraryClient.CorrectionDetail(id: id, title: "A bug")
        }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        await model.load(id: "issue_01ABC", target: TestHost.target, appearance: .light)
        XCTAssertNil(model.foundDuringTitleFetchTask)
        XCTAssertNil(model.foundDuringTitle)
    }

    // MARK: - Found during: the items shown on an epic

    @MainActor
    func testAnEpicLoadsTheItemsFoundDuringIt() async {
        let model = ItemDetailModel()
        model.fetchDetail = { _, id in LibraryClient.CorrectionDetail(id: id, title: "An epic", type: "epic") }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        model.fetchFoundDuringItems = { _, epicId in
            [LibraryClient.FoundDuringItem(id: "issue_A", title: "Found along the way", state: "open")]
        }
        await model.load(id: "issue_EPIC", target: TestHost.target, appearance: .light)
        await model.foundDuringItemsFetchTask?.value
        XCTAssertEqual(model.foundDuringItemsState,
                       .loaded([LibraryClient.FoundDuringItem(id: "issue_A", title: "Found along the way",
                                                               state: "open")]))
    }

    /// A non-epic item never runs this fetch at all.
    @MainActor
    func testANonEpicItemNeverFetchesFoundDuringItems() async {
        let model = ItemDetailModel()
        model.fetchDetail = { _, id in LibraryClient.CorrectionDetail(id: id, title: "A bug", type: "bug") }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        model.fetchFoundDuringItems = { _, _ in
            XCTFail("a non-epic item must not fetch found-during items")
            return []
        }
        await model.load(id: "issue_01ABC", target: TestHost.target, appearance: .light)
        XCTAssertNil(model.foundDuringItemsFetchTask)
        XCTAssertEqual(model.foundDuringItemsState, .none)
    }

    /// A failed fetch surfaces as `.failed`, the same unreachable-line
    /// treatment `CockpitView.childItemsSection` draws for its own list.
    @MainActor
    func testAFailedFoundDuringItemsFetchSurfacesAsFailed() async {
        let model = ItemDetailModel()
        model.fetchDetail = { _, id in LibraryClient.CorrectionDetail(id: id, title: "An epic", type: "epic") }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        model.fetchFoundDuringItems = { _, _ in
            throw LibraryClient.FetchError.libraryRefused(status: 500, body: #"{"error":"boom"}"#)
        }
        await model.load(id: "issue_EPIC", target: TestHost.target, appearance: .light)
        await model.foundDuringItemsFetchTask?.value
        guard case .failed = model.foundDuringItemsState else {
            return XCTFail("expected .failed, got \(model.foundDuringItemsState)")
        }
    }

    /// Opening another item (a `deck-open:` link, or the reused pane)
    /// drops the old item's found-during state rather than showing it under
    /// the new one for the instant before its own fetch resolves — same
    /// discipline as `testOpeningAnotherItemDropsTheDraftAndTheOldItem`.
    @MainActor
    func testOpeningAnotherItemDropsTheOldFoundDuringState() async {
        let model = ItemDetailModel()
        model.fetchDetail = { _, id in LibraryClient.CorrectionDetail(id: id, title: "A bug", foundDuring: "issue_EPIC") }
        model.renderDetail = { detail, _, _ in ItemDetailPane.page(for: detail, appearance: .light) }
        await model.load(id: "issue_01ABC", target: TestHost.target, appearance: .light)
        await model.foundDuringTitleFetchTask?.value

        model.fetchDetail = { _, id in LibraryClient.CorrectionDetail(id: id, title: "A different item") }
        await model.load(id: "issue_01XYZ", target: TestHost.target, appearance: .light)
        XCTAssertNil(model.foundDuringTitle)
    }

    // MARK: - DeckOperator

    func testLabelCombinesUserAndHost() {
        XCTAssertEqual(DeckOperator.label(userName: "operator", hostName: "example.com"),
                       "deck:operator@example.com")
    }

    /// Stable across calls with the same inputs — every write from this
    /// laptop needs to name the same holder.
    func testLabelIsStableForTheSameInputs() {
        XCTAssertEqual(DeckOperator.label(userName: "operator", hostName: "h"),
                       DeckOperator.label(userName: "operator", hostName: "h"))
    }

    // MARK: - An epic's specification and definition of done

    /// Specification, then definition of done, then the folded body, then
    /// the thread — an epic opens on the spec and the definition of done
    /// now, ahead of the body (the operator, 2026-09-22, quoted on `markdown(for:
    /// nonce:)`). The Course entry's own name for the definition of done is
    /// `Done when`.
    func testAnEpicDrawsSpecificationDoneWhenAndTheBackgroundedBodyInOrder() throws {
        let nonce = "epic-order-nonce"
        let md = ItemDetailPane.markdown(for: detail(
            body: "the body", specification: "the spec", definitionOfDone: "- first\n- second"),
            nonce: nonce)
        let spec = try XCTUnwrap(md.range(of: "## Specification\n\nthe spec")?.lowerBound)
        let done = try XCTUnwrap(md.range(of: "## Done when\n\n- first\n- second")?.lowerBound)
        let open = try XCTUnwrap(md.range(of: ItemDetailPane.backgroundOpenMarker(nonce))?.lowerBound)
        let body = try XCTUnwrap(md.range(of: "the body")?.lowerBound)
        let close = try XCTUnwrap(md.range(of: ItemDetailPane.backgroundCloseMarker(nonce))?.lowerBound)
        let comments = try XCTUnwrap(md.range(of: "## Comments")?.lowerBound)
        XCTAssertTrue(spec < done && done < open && open < body && body < close && close < comments)
    }

    /// Every correction and most work items: nothing new is drawn, no empty
    /// heading is left behind, and the body comes right after the meta line
    /// — same as before this change, since for these the body IS the
    /// content. An empty string reads the same as absent.
    func testAnItemWithNeitherFieldDrawsNoHeadingAndKeepsTheBodyRightAfterMeta() {
        for (spec, done) in [(nil, nil), ("", ""), (nil, ""), ("", nil)] as [(String?, String?)] {
            let md = markdown(for: detail(specification: spec, definitionOfDone: done))
            XCTAssertFalse(md.contains("Specification"), md)
            XCTAssertFalse(md.contains("Done when"), md)
            XCTAssertFalse(md.contains(ItemDetailPane.backgroundOpenMarker(testNonce)), md)
            XCTAssertFalse(md.contains(ItemDetailPane.backgroundCloseMarker(testNonce)), md)
            XCTAssertEqual(md, markdown(for: detail()))
            let sections = md.components(separatedBy: "\n\n")
            XCTAssertEqual(sections[2], "plain body", md)
            let html = ItemDetailPane.page(for: detail(specification: spec, definitionOfDone: done),
                                           appearance: .light)
            XCTAssertFalse(html.contains("Specification"), html)
            XCTAssertFalse(html.contains("Done when"), html)
            XCTAssertFalse(html.contains("<details"), html)
        }
    }

    /// An epic with an empty body has nothing to fold, so it draws its
    /// specification and definition of done but no Background marker or
    /// heading.
    func testAnEpicWithAnEmptyBodyDrawsNoBackground() {
        for body in [nil, ""] as [String?] {
            let md = ItemDetailPane.markdown(
                for: detail(body: body, specification: "the spec"), nonce: testNonce)
            XCTAssertTrue(md.contains("## Specification"), md)
            XCTAssertFalse(md.contains(ItemDetailPane.backgroundOpenMarker(testNonce)), md)
            XCTAssertFalse(md.contains(ItemDetailPane.backgroundCloseMarker(testNonce)), md)
            let html = ItemDetailPane.page(
                for: detail(body: body, specification: "the spec"), appearance: .light)
            XCTAssertFalse(html.contains("<details"), html)
        }
    }

    /// One present field draws its own heading and not the other's.
    func testAnItemWithOnlyOneFieldDrawsOnlyThatHeading() {
        let onlySpec = markdown(for: detail(specification: "the spec"))
        XCTAssertTrue(onlySpec.contains("## Specification"))
        XCTAssertFalse(onlySpec.contains("Done when"))
        let onlyDone = markdown(for: detail(definitionOfDone: "- x"))
        XCTAssertTrue(onlyDone.contains("## Done when"))
        XCTAssertFalse(onlyDone.contains("Specification"))
    }

    /// Same fence guard as the body: an unclosed fence in the specification
    /// cannot swallow the definition of done or the thread after it.
    func testAnUnclosedFenceInTheSpecificationDoesNotSwallowWhatFollows() throws {
        let md = markdown(for: detail(
            specification: "```\nnever closed", definitionOfDone: "- done"))
        let closer = try XCTUnwrap(md.range(of: "never closed\n```\n"))
        let done = try XCTUnwrap(md.range(of: "## Done when"))
        XCTAssertTrue(closer.upperBound <= done.lowerBound)
    }

    /// The fallback page shows both escaped, like the body, and puts the
    /// specification ahead of the folded body.
    func testTheFallbackPageEscapesAndLabelsBothFields() {
        let html = ItemDetailPane.page(for: detail(
            specification: "<script>alert(1)</script>", definitionOfDone: "- a & b"),
            appearance: .light)
        XCTAssertFalse(html.contains("<script>alert(1)"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)"))
        XCTAssertTrue(html.contains("<h3>Specification</h3>"))
        XCTAssertTrue(html.contains("<h3>Done when</h3>"))
        XCTAssertTrue(html.contains("- a &amp; b"))
    }

    /// `page(for:)` puts Specification before the `<details>` for an epic,
    /// and has no `<details>` at all for a plain item — the same shape the
    /// remote-render path produces through `foldBackground(html:nonce:)`.
    func testPagePutsSpecificationBeforeDetailsForAnEpicAndOmitsItForAPlainItem() throws {
        let epicHTML = ItemDetailPane.page(
            for: detail(body: "the body", specification: "the spec"), appearance: .light)
        let spec = try XCTUnwrap(epicHTML.range(of: "<h3>Specification</h3>")?.lowerBound)
        let details = try XCTUnwrap(epicHTML.range(of: "<details class=\"background\">")?.lowerBound)
        XCTAssertTrue(spec < details)
        XCTAssertTrue(epicHTML.contains("<summary>Background</summary>"))
        XCTAssertTrue(epicHTML.contains("the body"))

        let plainHTML = ItemDetailPane.page(for: detail(), appearance: .light)
        XCTAssertFalse(plainHTML.contains("<details"))
    }

    // MARK: - Folding the background disclosure after render

    /// The exact rendered form of a plain-text paragraph is `<p>…</p>` with
    /// no surrounding whitespace — confirmed 2026-09-22 by piping a marker
    /// paragraph through `session-view --render-file - --name probe.md` and
    /// reading the output. This pins that fact: when both markers appear
    /// exactly once, the substitution turns them into exactly one
    /// `<details>…</details>` around whatever rendered between them.
    func testTheSubstitutionProducesExactlyOneDetailsAroundTheBody() {
        let nonce = "fold-nonce"
        let open = ItemDetailPane.backgroundOpenMarker(nonce)
        let close = ItemDetailPane.backgroundCloseMarker(nonce)
        let rendered = "<p>before</p><p>\(open)</p><p>the body</p><p>\(close)</p><p>after</p>"

        let folded = ItemDetailPane.foldBackground(html: rendered, nonce: nonce)

        XCTAssertEqual(folded,
            "<p>before</p>" +
            "<details class=\"background\"><summary>Background</summary><p>the body</p></details>" +
            "<p>after</p>")
    }

    /// A body containing the literal marker text under a DIFFERENT nonce
    /// does not match this render's exact string, so it is left untouched —
    /// nothing in a Library-controlled body can forge this render's fold by
    /// guessing or reusing a nonce it never saw.
    func testAMarkerTextWithADifferentNonceIsNotSubstituted() {
        let open = ItemDetailPane.backgroundOpenMarker("attacker-guessed-nonce")
        let close = ItemDetailPane.backgroundCloseMarker("attacker-guessed-nonce")
        let rendered = "<p>before</p><p>\(open)</p><p>body text</p><p>\(close)</p><p>after</p>"

        let folded = ItemDetailPane.foldBackground(html: rendered, nonce: "the-real-nonce")

        XCTAssertEqual(folded, rendered)
        XCTAssertFalse(folded.contains("<details"))
    }

    /// A missing close marker (the open one rendered, the close one did
    /// not, for whatever reason) must not emit an opening `<details>` with
    /// no closer — it degrades to the body left unfolded, with no marker
    /// text surviving into what the reader sees.
    func testAMissingCloseMarkerDegradesToUnfoldedWithNoMarkerTextLeft() {
        let nonce = "missing-close-nonce"
        let open = ItemDetailPane.backgroundOpenMarker(nonce)
        let rendered = "<p>before</p><p>\(open)</p><p>body text</p><p>after</p>"

        let folded = ItemDetailPane.foldBackground(html: rendered, nonce: nonce)

        XCTAssertFalse(folded.contains("<details"))
        XCTAssertFalse(folded.contains("BACKGROUND-OPEN"))
        XCTAssertTrue(folded.contains("<p>body text</p>"))
    }

    /// The other missing-marker case: no open marker at all (a missing
    /// close is covered above) degrades the same way.
    func testAMissingOpenMarkerDegradesToUnfoldedWithNoMarkerTextLeft() {
        let nonce = "missing-open-nonce"
        let close = ItemDetailPane.backgroundCloseMarker(nonce)
        let rendered = "<p>before</p><p>body text</p><p>\(close)</p><p>after</p>"

        let folded = ItemDetailPane.foldBackground(html: rendered, nonce: nonce)

        XCTAssertFalse(folded.contains("<details"))
        XCTAssertFalse(folded.contains("BACKGROUND-CLOSE"))
        XCTAssertTrue(folded.contains("<p>body text</p>"))
    }
}
