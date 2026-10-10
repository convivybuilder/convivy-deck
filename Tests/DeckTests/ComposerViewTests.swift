import XCTest
import SwiftUI
import AppKit
@testable import Deck

/// `ComposerView`'s state decisions — which label and style the primary slot
/// takes, whether the held-queue chip appears and what it reads, and whether
/// Interrupt draws at all — pulled into pure `nonisolated` functions the way
/// `CockpitView.rowTreatment` and `coursePartition` already are, so the
/// input-pane redesign's per-state rules (`design/input-pane-mock.html`,
/// Option A, second pass) are testable without a keystroke or a rendered
/// frame.
///
/// WHAT THIS FILE DOES NOT PROVE. Option A's headline promise is that the
/// primary slot's right edge never moves as the bar's contents change — a
/// pixel position in rendered SwiftUI output. No XCTest in this repo can pin
/// that (there is no XCUITest target, and `NSHostingView.fittingSize` reports
/// an aggregate, not a subview's frame origin); it needs a human looking at
/// the app. Named here rather than implied by a green suite, the same lesson
/// convivy-deck#153 was reverted for on 2026-08-31.
final class ComposerViewTests: XCTestCase {

    // MARK: - Primary slot style

    /// The epic's first pass claimed Send and Interrupt were "already
    /// mutually exclusive in the model — Send is disabled exactly while the
    /// session is working". `SessionAgentTests` already pins the fact that
    /// falsifies that: `Phase.working.acceptsMessage` is `true`, so `canSend`
    /// can be `true` while a turn runs — typing a message and hitting Send
    /// mid-turn is how a message gets queued. The revision's fix is that the
    /// primary slot no longer takes `isWorking` as an input at all: its style
    /// depends only on `canSend`, whatever the working phase is doing.
    func testPrimaryStyleDependsOnlyOnCanSend() {
        XCTAssertEqual(ComposerView.primaryStyle(canSend: true), .actionable)
        XCTAssertEqual(ComposerView.primaryStyle(canSend: false), .disabled)
    }

    // MARK: - Primary slot label

    func testPrimaryLabelEmptyBoxReturnKeyPreference() {
        XCTAssertEqual(
            ComposerView.primaryLabel(isRewrite: false, sendKey: .returnKey),
            "Send ↩")
    }

    func testPrimaryLabelTypedTextCommandReturnPreference() {
        XCTAssertEqual(
            ComposerView.primaryLabel(isRewrite: false, sendKey: .commandReturn),
            "Send ⌘↩")
    }

    func testPrimaryLabelQueuePulledBackReturnKeyPreference() {
        XCTAssertEqual(
            ComposerView.primaryLabel(isRewrite: true, sendKey: .returnKey),
            "Replace ↩")
    }

    func testPrimaryLabelQueuePulledBackCommandReturnPreference() {
        XCTAssertEqual(
            ComposerView.primaryLabel(isRewrite: true, sendKey: .commandReturn),
            "Replace ⌘↩")
    }

    // MARK: - Primary slot accessibility label

    func testPrimaryAccessibilityLabelSend() {
        XCTAssertEqual(ComposerView.primaryAccessibilityLabel(isRewrite: false), "Send message")
    }

    func testPrimaryAccessibilityLabelReplace() {
        XCTAssertEqual(ComposerView.primaryAccessibilityLabel(isRewrite: true),
                       "Replace held messages")
    }

    // MARK: - Interrupt is its own control

    /// The state the first pass never drew: a turn is running and there is
    /// sendable text. The primary slot still reads Send and is actionable —
    /// it never reads "Interrupt" and never disables — while Interrupt is a
    /// distinct label with its own accessibility string. Two different
    /// strings is what "two distinct controls" reduces to at the level this
    /// file can test; see the file-level doc comment for what it cannot.
    func testWorkingWithTextTypedKeepsSendAndInterruptDistinct() {
        XCTAssertEqual(ComposerView.primaryStyle(canSend: true), .actionable)
        XCTAssertEqual(ComposerView.primaryLabel(isRewrite: false, sendKey: .returnKey), "Send ↩")
        XCTAssertNotEqual(ComposerView.primaryAccessibilityLabel(isRewrite: false),
                          ComposerView.interruptAccessibilityLabel)
    }

    /// The old merged slot "looked fine" here because the mock never drew a
    /// working turn with anything typed — an empty box during a working turn
    /// was the only working state anyone had seen. The primary is correctly
    /// disabled regardless; Interrupt's accessibility label is still its own
    /// string, unaffected by `canSend`.
    func testWorkingWithEmptyBoxDisablesPrimaryButInterruptStandsApart() {
        XCTAssertEqual(ComposerView.primaryStyle(canSend: false), .disabled)
        XCTAssertNotEqual(ComposerView.primaryAccessibilityLabel(isRewrite: false),
                          ComposerView.interruptAccessibilityLabel)
    }

    func testInterruptAccessibilityLabel() {
        XCTAssertEqual(ComposerView.interruptAccessibilityLabel, "Interrupt the running turn")
    }

    // MARK: - The held-queue chip

    /// Two waiting, new text typed — the chip names the up-arrow gesture
    /// that pulls them back, singular held message reads without an "s".
    func testRewriteChipTextBeforePullBack() {
        XCTAssertEqual(ComposerView.rewriteChipText(heldCount: 2, isRewrite: false), "↑ 2 held")
        XCTAssertEqual(ComposerView.rewriteChipText(heldCount: 1, isRewrite: false), "↑ 1 held")
    }

    /// Queue pulled back — the chip announces the mode, agreeing with the
    /// primary slot's own "Replace" so the rename reads deliberate.
    func testRewriteChipTextAfterPullBack() {
        XCTAssertEqual(ComposerView.rewriteChipText(heldCount: 2, isRewrite: true), "editing 2 held")
    }

    func testRewriteChipAccessibilityLabelPluralizes() {
        XCTAssertEqual(ComposerView.rewriteChipAccessibilityLabel(heldCount: 2),
                       "2 messages held — pull back to edit")
        XCTAssertEqual(ComposerView.rewriteChipAccessibilityLabel(heldCount: 1),
                       "1 message held — pull back to edit")
    }

    // MARK: - The caption's remaining half

    func testNewlineHintReturnKeyPreference() {
        XCTAssertEqual(ComposerView.newlineHint(.returnKey), "⇧↩ new line")
    }

    func testNewlineHintCommandReturnPreference() {
        XCTAssertEqual(ComposerView.newlineHint(.commandReturn), "↩ new line")
    }

    // MARK: - Hosting smoke test

    /// `ComposerView` is not `private`, matching `PaneStatusBar`, so this can
    /// host it directly. This proves every state DRAWS — it crashes on a
    /// force-unwrap or an unsatisfiable constraint the way a live session
    /// never would, so this is worth having — but it is a smoke test, not a
    /// layout assertion; see the file-level doc comment for what it does not
    /// cover.
    @MainActor
    private func host(isWorking: Bool, isRewrite: Bool, heldCount: SessionState.HeldCount?,
                      text: String = "") -> NSHostingView<some View> {
        let view = ComposerView(
            text: .constant(text),
            enabled: true,
            sendKey: .returnKey,
            tint: nil,
            errorInk: .red,
            progressFillInk: .blue,
            onSend: {},
            isWorking: isWorking,
            onInterrupt: {},
            heldCount: heldCount,
            onRewrite: {},
            isRewrite: isRewrite,
            commands: nil,
            commandsError: nil,
            loadingCommands: false,
            onOpenCommands: {},
            onPickCommand: { _ in },
            typography: .default
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    func testEveryMockStateHostsWithoutCrashing() {
        XCTAssertGreaterThan(host(isWorking: false, isRewrite: false, heldCount: nil).fittingSize.width, 0,
                             "empty box")
        XCTAssertGreaterThan(
            host(isWorking: false, isRewrite: false, heldCount: nil, text: "Ship it").fittingSize.width, 0,
            "typed text")
        XCTAssertGreaterThan(host(isWorking: true, isRewrite: false, heldCount: nil).fittingSize.width, 0,
                             "working, empty box — Interrupt is the only actionable control")
        XCTAssertGreaterThan(
            host(isWorking: true, isRewrite: false, heldCount: nil, text: "reply while it thinks")
                .fittingSize.width, 0,
            "working, text typed — the state the first pass never drew: Send and Interrupt both present")
        XCTAssertGreaterThan(
            host(isWorking: false, isRewrite: false, heldCount: .count(2), text: "new text").fittingSize.width, 0,
            "held, new text typed")
        XCTAssertGreaterThan(
            host(isWorking: false, isRewrite: true, heldCount: .count(2), text: "pulled back").fittingSize.width, 0,
            "queue pulled back")
        XCTAssertGreaterThan(
            host(isWorking: true, isRewrite: false, heldCount: .count(2), text: "everything at once")
                .fittingSize.width, 0,
            "working, held, and typed at once — the bar's fullest frame")
    }
}
