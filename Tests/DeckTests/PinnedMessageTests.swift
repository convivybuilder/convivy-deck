import XCTest
@testable import Deck

// MARK: - Hysteresis state machine

/// `ConversationScrollState.applyPinCheck` decides when the pinned-last-message
/// bar shows and hides, at both thresholds and across the gap between them —
/// the same split `applyScrollCheck` uses for the "New output" pill, so this
/// runs against plain numbers rather than a live WKWebView.
///
/// THE TWO THRESHOLDS, restated from the source doc: `pinShowThreshold` (0) is
/// the boundary itself — the target's bottom edge at or above the container's
/// top edge counts as fully past. `pinHideClearanceLines` (1) is a SEPARATE,
/// larger threshold — hiding needs the row back by more than one full line
/// height, not merely back past zero — so a scroll tick that straddles the
/// boundary cannot flicker the bar on and off. Testing both, and the gap
/// between them, is what holds that gap fixed rather than letting it collapse
/// back to a single threshold under a future edit.
@MainActor
final class PinnedMessageHysteresisTests: XCTestCase {

    private func candidate(key: String = "a.0", text: String = "hello",
                           edgeOffset: Double, lineHeight: Double = 20) -> ConversationWebView.PinCandidate {
        ConversationWebView.PinCandidate(key: key, text: text, edgeOffset: edgeOffset, lineHeight: lineHeight)
    }

    // MARK: No candidate

    func testNoCandidateClearsThePin() {
        let state = ConversationScrollState()
        state.applyPinCheck(candidate(edgeOffset: -10))
        XCTAssertNotNil(state.pinnedMessage, "precondition: something is showing")

        state.applyPinCheck(nil)
        XCTAssertNil(state.pinnedMessage, "no .turn.you row on the page at all clears the bar")
    }

    // MARK: The show threshold

    func testAtTheShowThreshold_shows() {
        // edgeOffset == 0: the bottom edge exactly at the container's top —
        // the boundary is inclusive on the show side.
        let state = ConversationScrollState()
        state.applyPinCheck(candidate(edgeOffset: 0))
        XCTAssertEqual(state.pinnedMessage?.key, "a.0")
    }

    func testFullyPastTheShowThreshold_shows() {
        let state = ConversationScrollState()
        state.applyPinCheck(candidate(edgeOffset: -50))
        XCTAssertEqual(state.pinnedMessage?.key, "a.0")
    }

    func testJustShortOfTheShowThreshold_doesNotShow() {
        // edgeOffset > 0: the bottom edge is still below the container's top,
        // so some part of the row remains on screen — not fully past yet.
        let state = ConversationScrollState()
        state.applyPinCheck(candidate(edgeOffset: 0.5))
        XCTAssertNil(state.pinnedMessage, "a row not yet fully past the edge must not raise the bar")
    }

    // MARK: The hide threshold — a gap, not the same line as the show threshold

    func testOnceShown_stayingJustPastTheShowThresholdKeepsItUp() {
        let state = ConversationScrollState()
        state.applyPinCheck(candidate(edgeOffset: -10))
        XCTAssertNotNil(state.pinnedMessage)

        // Back to just past zero — inside the hysteresis gap, well short of a
        // full line height. Must still be showing: this is the exact case
        // that would flicker without a gap.
        state.applyPinCheck(candidate(edgeOffset: 0.5, lineHeight: 20))
        XCTAssertNotNil(state.pinnedMessage, "clearing the show threshold alone must not hide the bar")
    }

    func testOnceShown_exactlyOneLineHeightClear_staysShown() {
        // "more than one line height" is the spoken threshold, so exactly one
        // line height of clearance is still inside the shown band.
        let state = ConversationScrollState()
        state.applyPinCheck(candidate(edgeOffset: -10, lineHeight: 20))
        state.applyPinCheck(candidate(edgeOffset: 20, lineHeight: 20))
        XCTAssertNotNil(state.pinnedMessage, "exactly one line height of clearance is not yet MORE than one")
    }

    func testOnceShown_pastOneLineHeightClear_hides() {
        let state = ConversationScrollState()
        state.applyPinCheck(candidate(edgeOffset: -10, lineHeight: 20))
        state.applyPinCheck(candidate(edgeOffset: 20.1, lineHeight: 20))
        XCTAssertNil(state.pinnedMessage, "more than one line height of clearance hides the bar")
    }

    func testOnceShown_wayPastClearance_hides() {
        let state = ConversationScrollState()
        state.applyPinCheck(candidate(edgeOffset: -10, lineHeight: 20))
        state.applyPinCheck(candidate(edgeOffset: 500, lineHeight: 20))
        XCTAssertNil(state.pinnedMessage)
    }

    /// A zero or unreadable computed line-height must not collapse the
    /// hysteresis gap back to zero — `applyPinCheck` floors it at 1pt.
    func testZeroLineHeightStillLeavesARealGap() {
        let state = ConversationScrollState()
        state.applyPinCheck(candidate(edgeOffset: -10, lineHeight: 0))
        // 0.5pt of clearance against a floored 1pt gap: still inside it.
        state.applyPinCheck(candidate(edgeOffset: 0.5, lineHeight: 0))
        XCTAssertNotNil(state.pinnedMessage, "a floored gap still absorbs a sub-pixel reading")

        state.applyPinCheck(candidate(edgeOffset: 1.5, lineHeight: 0))
        XCTAssertNil(state.pinnedMessage, "past the floored 1pt gap, it hides")
    }

    // MARK: A different message resets the decision

    func testADifferentKeyIsJudgedFreshRatherThanInheritingTheOldHysteresis() {
        let state = ConversationScrollState()
        state.applyPinCheck(candidate(key: "a.0", edgeOffset: -10, lineHeight: 20))
        XCTAssertEqual(state.pinnedMessage?.key, "a.0")

        // A new message the reader just sent, sitting near the bottom (not
        // past the show threshold): must NOT inherit "a.0"'s shown state.
        state.applyPinCheck(candidate(key: "b.0", edgeOffset: 5, lineHeight: 20))
        XCTAssertNil(state.pinnedMessage, "a fresh message near the bottom is judged on its own geometry")
    }

    func testADifferentKeyThatIsAlreadyPastTheEdgeShowsImmediately() {
        let state = ConversationScrollState()
        state.applyPinCheck(candidate(key: "a.0", edgeOffset: -10, lineHeight: 20))
        state.applyPinCheck(candidate(key: "b.0", edgeOffset: -30, lineHeight: 20))
        XCTAssertEqual(state.pinnedMessage?.key, "b.0")
    }

    // MARK: Text carried through

    func testShowingCarriesTheCandidatesFullText() {
        let state = ConversationScrollState()
        state.applyPinCheck(candidate(text: "the full message text", edgeOffset: -10))
        XCTAssertEqual(state.pinnedMessage?.text, "the full message text")
    }
}

// MARK: - Truncation and the accessibility label

/// `SessionPaneView.pinnedPreview` and `.pinnedAccessibilityLabel` are pure
/// functions of a string, tested independently of any hosted view — the
/// property under test (does the preview visibly mark a cut, does the label
/// carry everything the preview dropped) is provable without a layout pass.
final class PinnedMessagePreviewTests: XCTestCase {

    func testShortTextIsUnchanged() {
        XCTAssertEqual(SessionPaneView.pinnedPreview("fix the bug"), "fix the bug")
    }

    func testLongTextIsCutWithAVisibleEllipsis() {
        let long = String(repeating: "a", count: SessionPaneView.pinnedPreviewMaxLength + 50)
        let preview = SessionPaneView.pinnedPreview(long)
        XCTAssertTrue(preview.hasSuffix("…"), "a cut preview must carry a visible mark that it was cut")
        XCTAssertEqual(preview.count, SessionPaneView.pinnedPreviewMaxLength + 1,
            "cut to the bound plus the ellipsis character")
    }

    /// THE HAZARD THE PLAN NAMES. A truncation that happens to land after a
    /// complete-reading clause is the dangerous case — this pins a truncation
    /// at least happens (the string is shorter than the source) and that the
    /// visible mark survives collapsing, rather than asserting on this exact
    /// sentence's cut point, which is incidental to where the bound falls.
    func testATruncatedInstructionIsNotMistakeableForACompleteOne() {
        let full = "don't ship the migration " + String(repeating: "x", count: 200) + " without the backfill"
        let preview = SessionPaneView.pinnedPreview(full)
        XCTAssertLessThan(preview.count, full.count, "the preview is shorter than what was actually sent")
        XCTAssertTrue(preview.hasSuffix("…"), "the cut is marked, so it cannot read as the complete instruction")
    }

    // MARK: - Displayed text must agree with sent text
    //
    // The ellipsis tests above hold one half of that property. These hold the
    // other, found in security review of #88: a bidi override reaches the same
    // end as a bad truncation without cutting anything, because `Text` and the
    // accessibility label both implement the Unicode bidi algorithm.

    func testABidiOverrideCannotReorderWhatTheBarShows() {
        // U+202E flips the run that follows it, so a reader would see the
        // reversed text rather than what was sent — with nothing truncated.
        let sent = "deploy to staging \u{202E}gnitset retfa"
        let preview = SessionPaneView.pinnedPreview(sent)
        XCTAssertFalse(preview.unicodeScalars.contains { $0 == "\u{202E}" },
                       "the override is dropped rather than rendered")
        XCTAssertTrue(preview.hasPrefix("deploy to staging "),
                      "the text either side of it survives unchanged")
    }

    func testEveryBidiControlGoes() {
        // The embeddings, the overrides, the isolates and the directional
        // marks — the set that can reorder what a reader sees.
        for scalar in ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                       "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
                       "\u{200E}", "\u{200F}", "\u{061C}"] {
            XCTAssertEqual(SessionPaneView.pinnedPreview("before\(scalar)after"),
                           "beforeafter",
                           "a control that reorders the run after it is dropped")
        }
    }

    func testTheJoinerStaysBecauseEmojiAreBuiltFromIt() {
        // U+200D is the same general category as the overrides above, which is
        // why the first version of this guard dropped it and broke every ZWJ
        // sequence. It reorders nothing, so it is content rather than hazard.
        let joined = "before\u{200D}after"
        XCTAssertEqual(SessionPaneView.pinnedPreview(joined), joined)
    }

    func testTheAccessibilityLabelIsHeldToTheSameStandard() {
        // VoiceOver gets the FULL text, so it is the one place a reordering
        // would go unnoticed by a sighted reader checking the capsule.
        let label = SessionPaneView.pinnedAccessibilityLabel("ship it \u{202E}ton od")
        XCTAssertFalse(label.unicodeScalars.contains { $0 == "\u{202E}" })
        XCTAssertTrue(label.hasSuffix("ship it ton od"))
    }

    /// Every cluster of the stripped input maps to exactly one cluster of the
    /// output — itself, or one replacement character. Five rounds of security
    /// review each defeated a per-cluster transform by finding a boundary the
    /// reader re-segmented differently; this is the property that makes that
    /// class impossible rather than the next patch in it.
    private func assertOneClusterOut(_ input: String, _ what: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let bidiStripped = String(String.UnicodeScalarView(
            input.unicodeScalars.filter { !SessionPaneView.bidiControls.contains($0) }))
        XCTAssertEqual(SessionPaneView.displayable(input).count, bidiStripped.count,
                       "\(what): the output must re-segment to what was intended",
                       file: file, line: line)
    }

    func testTheClusterInvariantHoldsForEveryDefeatSoFar() {
        let marks20 = String(repeating: "\u{0301}", count: 20)
        // Round 5: two clusters each capped to a bare regional indicator
        // re-paired into 🇦🇨, a flag present nowhere in the message.
        assertOneClusterOut("\u{1F1E6}" + marks20 + "\u{1F1E8}" + marks20, "regional indicators")
        // Round 4: stripping the separators let the survivors coalesce.
        assertOneClusterOut(String(repeating: "\u{202E}" + String(repeating: "\u{0301}", count: 15),
                                   count: 250), "coalescence")
        // Round 3: a joiner reset the per-base counter without ending the cluster.
        assertOneClusterOut("a" + String(repeating: String(repeating: "\u{0301}", count: 4)
                                         + "\u{200D}", count: 800), "joiner interleave")
        // Round 2: one base plus 3,999 marks is one cluster, never truncated.
        assertOneClusterOut("a" + String(repeating: "\u{0301}", count: 3999), "zalgo")
    }

    func testTheInvariantAlsoHoldsForContentThatMustSurvive() {
        for (text, what) in [("👨‍👩‍👧‍👦", "family"), ("👩‍❤️‍💋‍👨", "kiss"),
                             ("🏴󠁧󠁢󠁳󠁣󠁴󠁿", "tag flag"), ("🇬🇧", "real flag"),
                             ("ที่", "thai"), ("क्षि", "devanagari"),
                             ("ship the migration without the backfill", "ordinary")] {
            assertOneClusterOut(text, what)
        }
    }

    func testAnOverCapClusterBecomesAVisibleReplacement() {
        // Dropping it silently would be the truncation hazard one level down:
        // the reader cannot tell something was removed.
        let zalgo = "a" + String(repeating: "\u{0301}", count: 3999)
        XCTAssertEqual(SessionPaneView.pinnedPreview(zalgo), "\u{FFFD}")
    }

    func testARegionalIndicatorPairIsNeverManufactured() {
        let marks20 = String(repeating: "\u{0301}", count: 20)
        let payload = "\u{1F1E6}" + marks20 + "\u{1F1E8}" + marks20
        let preview = SessionPaneView.pinnedPreview(payload)
        XCTAssertFalse(preview.unicodeScalars.contains { (0x1F1E6...0x1F1FF).contains($0.value) },
                       "no bare regional indicator survives to pair with its neighbour")
    }

    func testOrdinaryTextIsUntouched() {
        // The first version of this test used only single-scalar emoji, which is
        // why it did not catch that dropping category Cf destroys ZWJ sequences:
        // a family became four separate people and a pride flag became a white
        // flag beside a rainbow. Emoji built from joiners are the case that
        // matters here, so they lead.
        for text in ["👨‍👩‍👧‍👦 family", "👩‍💻 dev", "🏳️‍🌈 flag", "👩‍❤️‍💋‍👨 kiss",
                     "🏴󠁧󠁢󠁳󠁣󠁴󠁿 scotland", "👋🏽 wave",
                     "ship it 🚀", "café", "日本語のメッセージ", "e\u{301}"] {
            XCTAssertEqual(SessionPaneView.pinnedPreview(text), text,
                           "legitimate content is not the thing being guarded against")
        }
    }

    func testWhitespaceIsCollapsedBeforeCounting() {
        let messy = "line one\n\n\n   line two\twith a tab"
        XCTAssertEqual(SessionPaneView.pinnedPreview(messy), "line one line two with a tab")
    }

    func testAccessibilityLabelCarriesTheFullTextEvenWhenThePreviewIsCut() {
        let long = String(repeating: "word ", count: 200) + "the last word"
        let preview = SessionPaneView.pinnedPreview(long)
        let label = SessionPaneView.pinnedAccessibilityLabel(long)

        XCTAssertTrue(preview.hasSuffix("…"), "precondition: the preview actually truncated")
        XCTAssertTrue(label.contains("the last word"),
            "the accessibility label reaches the end of the message the visible preview cut off")
        XCTAssertFalse(label.hasSuffix("…"),
            "the label is the whole message, not a second truncation of it")
    }

    func testAccessibilityLabelCollapsesWhitespaceLikeThePreviewDoes() {
        let messy = "line one\n\n\n   line two"
        XCTAssertTrue(SessionPaneView.pinnedAccessibilityLabel(messy).contains("line one line two"))
    }
}
