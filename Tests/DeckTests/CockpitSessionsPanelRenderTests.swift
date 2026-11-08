import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What the Sessions panel (CQ-169, deck/bead/deck §1's "what each session
/// is working on") DRAWS: a session's display name and its working-on
/// line, through the same `WorkingStrip.presentation` precedence the status
/// bar uses — `WorkingStripTests` already pins that precedence itself, so
/// what is worth proving here is only that this view draws the case it
/// resolves to, including the two that must never be lost: a stale line
/// (CQ-167) and a session whose state could not be read
/// (`.claude/CLAUDE.md`'s INFERRED/state-unknown rule).
///
/// Renders via `NSHostingView` + `cacheDisplay`, never `ImageRenderer`,
/// which draws `ScrollView` contents blank — `CockpitRevealRenderTests`' own
/// choice — and compares inked-pixel counts the way `SlatePaneRenderTests`
/// does, since nothing here has a stable accessibility tree to query.
@MainActor
final class CockpitSessionsPanelRenderTests: XCTestCase {

    private func workingOn(text: String = "chasing the pagination bug",
                            age: Double? = nil, stale: Bool? = nil,
                            since: Double? = nil) -> SessionState.WorkingOn {
        SessionState.WorkingOn(text: text, age: age, stale: stale, since: since)
    }

    private func dispatch(text: String = "rebase PR #318",
                           derivedFrom: String = SessionState.WorkingOnDerived.dispatchTaskSource,
                           age: Double? = nil, since: Double? = nil) -> SessionState.WorkingOnDerived {
        SessionState.WorkingOnDerived(text: text, derivedFrom: derivedFrom, age: age, since: since)
    }

    private func state(workingOn: SessionState.WorkingOn? = nil,
                        workingOnDerived: SessionState.WorkingOnDerived? = nil,
                        clients: SessionState.Clients? = nil) -> SessionState {
        SessionState(session: "s", phase: .working, alive: true,
                     workingOn: workingOn, workingOnDerived: workingOnDerived, clients: clients)
    }

    private func row(_ name: String, state: SessionState?) -> CockpitView.SessionRow {
        CockpitView.SessionRow(ref: SessionRef(host: nil, name: name), displayName: name, state: state)
    }

    /// Fresh, unmistaken for stale, with nothing to fall back to.
    private var freshRow: CockpitView.SessionRow {
        row("deck-coder", state: state(workingOn: workingOn(stale: false, since: 120)))
    }

    /// Stale, with no dispatch record to replace it — must still draw, with
    /// its age (CQ-167's own rule, restated by the contract's `working_on`
    /// section: a stale line is never silently dropped).
    private var staleRow: CockpitView.SessionRow {
        row("deck-reviewer", state: state(workingOn: workingOn(age: 10_800, stale: true)))
    }

    /// No authored line at all: the dispatch fallback is all there is,
    /// labelled "Last dispatch:" so it is never mistaken for the co's own
    /// words.
    private var dispatchFallbackRow: CockpitView.SessionRow {
        row("deck-security-reviewer", state: state(workingOnDerived: dispatch(age: 300, since: 600)))
    }

    /// A `UserPromptSubmit` record — the operator's ruling, 2026-10-20, is
    /// that the session window already shows the operator's own latest
    /// message, so this is never drawn here either.
    private var promptDerivedRow: CockpitView.SessionRow {
        row("deck-security-reviewer",
            state: state(workingOnDerived: dispatch(derivedFrom: "UserPromptSubmit")))
    }

    /// No entry in `railState.states` at all: the state could not be read.
    private var unreadableRow: CockpitView.SessionRow {
        row("deck-orphan", state: nil)
    }

    /// One tmux client, named.
    private var namedClientRow: CockpitView.SessionRow {
        row("deck-coder", state: state(clients: .attached([
            .init(pid: 1, via: .local, label: "Deck on orchard"),
        ])))
    }

    /// Two tmux clients, both named — the case the row must summarise
    /// rather than wrap onto a second line.
    private var twoClientsRow: CockpitView.SessionRow {
        row("deck-coder", state: state(clients: .attached([
            .init(pid: 1, via: .local, label: "Deck on orchard"),
            .init(pid: 2, via: .ssh, label: "SSH from harbor"),
        ])))
    }

    /// tmux answered and nobody is attached by tmux — must draw its own
    /// neutral wording, never "nobody is watching" (Remote Control viewers
    /// are invisible to this field either way).
    private var emptyClientsRow: CockpitView.SessionRow {
        row("deck-coder", state: state(clients: .attached([])))
    }

    /// The read failed — a different answer from `[]`, and must draw
    /// differently from it.
    private var unknownClientsRow: CockpitView.SessionRow {
        row("deck-coder", state: state(clients: .unknown))
    }

    /// No `clients` field at all — a mini that predates it.
    private var noClientsFieldRow: CockpitView.SessionRow {
        row("deck-coder", state: state())
    }

    private func mount(
        _ sessions: [CockpitView.SessionRow], width: CGFloat, appearance: Appearance
    ) async throws -> (window: NSWindow, host: NSView) {
        let view = CockpitView(
            model: CockpitModel(), unresolvedReason: nil, sessions: sessions,
            appearance: appearance, onSelectCorrection: { _ in },
            panelIDs: [CockpitView.sessionsPanelID]
        )
        .background(appearance == .dark ? Color(white: 0.145) : Color(white: 0.98))
        .environmentObject(ThemeStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-\(UUID().uuidString).json")))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 420))
        host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        return (window, host)
    }

    private func render(
        _ sessions: [CockpitView.SessionRow], width: CGFloat, appearance: Appearance
    ) async throws -> NSBitmapImageRep {
        let (window, host) = try await mount(sessions, width: width, appearance: appearance)
        defer { window.orderOut(nil) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Whether `c` differs from the render's own corner (the solid backdrop
    /// `mount` paints) by more than a hair — `SlatePaneRenderTests`' own
    /// measure.
    private func isInk(_ c: NSColor, against backdrop: NSColor) -> Bool {
        let delta = abs(c.redComponent - backdrop.redComponent)
            + abs(c.greenComponent - backdrop.greenComponent)
            + abs(c.blueComponent - backdrop.blueComponent)
        return delta > 0.05
    }

    private func inkedPixelCount(_ rep: NSBitmapImageRep) -> Int {
        guard let backdrop = rep.colorAt(x: 0, y: rep.pixelsHigh - 1) else { return 0 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if isInk(c, against: backdrop) { count += 1 }
            }
        }
        return count
    }

    // MARK: - Draws at both widths, both appearances

    /// The item's own instruction: render at 320pt and 280pt, light and
    /// dark, with fixtures covering fresh, stale, dispatch-fallback and
    /// unreadable sessions, before committing.
    func testFixtureRowsDrawNonBlankAtBothWidthsAndAppearances() async throws {
        let rows = [freshRow, staleRow, dispatchFallbackRow, unreadableRow]
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let rep = try await render(rows, width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(rep), 0,
                                     "the Sessions panel drew nothing at \(width)pt, \(appearance)")
            }
        }
    }

    // MARK: - Each case draws something of its own

    /// A fresh line draws its own text — more ink than the same session
    /// with nothing recorded.
    func testAFreshLineDrawsSomethingOfItsOwn() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let withLine = try await render([freshRow], width: width, appearance: appearance)
                let nameOnly = try await render(
                    [row("deck-coder", state: state())], width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(withLine), inkedPixelCount(nameOnly),
                                     "a fresh working-on line drew nothing at \(width)pt, \(appearance)")
            }
        }
    }

    /// The never-dropped case: a stale line still draws, with its age —
    /// never fewer pixels than the same session with nothing recorded at
    /// all, which is what dropping it silently would look like.
    func testAStaleLineIsNeverDroppedAndDrawsMoreThanNoRecording() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let stale = try await render([staleRow], width: width, appearance: appearance)
                let nothing = try await render(
                    [row("deck-reviewer", state: state())], width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(stale), inkedPixelCount(nothing),
                                     "a stale working-on line drew nothing at \(width)pt, \(appearance)")
            }
        }
    }

    /// The dispatch fallback ("Last dispatch:", the task, its age) draws
    /// something of its own.
    func testTheDispatchFallbackDrawsSomethingOfItsOwn() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let withDispatch = try await render([dispatchFallbackRow], width: width, appearance: appearance)
                let nothing = try await render(
                    [row("deck-security-reviewer", state: state())], width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(withDispatch), inkedPixelCount(nothing),
                                     "the dispatch fallback drew nothing at \(width)pt, \(appearance)")
            }
        }
    }

    /// Now-must-fail companion to the two tests above: a dispatch record
    /// whose own `derivedFrom` this view does not recognise is treated like
    /// `UserPromptSubmit` and must NOT draw — proving the comparison above
    /// is actually sensitive to the fallback drawing, not to the row
    /// existing at all.
    func testAnUnrecognisedDerivedFromDrawsNothing() async throws {
        let unrecognised = row("deck-security-reviewer",
                               state: state(workingOnDerived: dispatch(derivedFrom: "some-future-source")))
        let nothing = row("deck-security-reviewer", state: state())
        let withUnrecognised = try await render([unrecognised], width: 320, appearance: .light)
        let withNothing = try await render([nothing], width: 320, appearance: .light)
        XCTAssertEqual(inkedPixelCount(withUnrecognised), inkedPixelCount(withNothing),
                       "an unrecognised derivedFrom value drew a line it should not have")
    }

    /// The operator's ruling, 2026-10-20: a `UserPromptSubmit` record is
    /// never drawn, so this row must read identically to the same session
    /// with no derived record at all.
    func testAPromptDerivedRecordDrawsNoWorkingOnLine() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let withPrompt = try await render([promptDerivedRow], width: width, appearance: appearance)
                let withNone = try await render(
                    [row("deck-security-reviewer", state: state())], width: width, appearance: appearance)
                XCTAssertEqual(inkedPixelCount(withPrompt), inkedPixelCount(withNone),
                               "a UserPromptSubmit record drew something at \(width)pt, \(appearance)")
            }
        }
    }

    /// The never-missing case: a session whose state could not be read
    /// still draws a row, marked "State unknown.", rather than disappearing
    /// or reading the same as a session that was read and had nothing to
    /// say.
    func testAnUnreadableSessionStillDrawsARowMarkedStateUnknown() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let unreadable = try await render([unreadableRow], width: width, appearance: appearance)
                let readableButBlank = try await render(
                    [row("deck-orphan", state: state())], width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(unreadable), inkedPixelCount(readableButBlank),
                                     "an unreadable session's row drew nothing of its own at "
                                     + "\(width)pt, \(appearance)")
            }
        }
    }

    /// No sessions for the project is a real, worded answer, not a blank
    /// panel body.
    func testNoSessionsDrawsItsOwnSentence() async throws {
        let empty = try await render([], width: 320, appearance: .light)
        XCTAssertGreaterThan(inkedPixelCount(empty), 0, "an empty Sessions panel drew nothing at all")
    }

    // MARK: - CQ-172: who is in each session

    /// A named client draws a line of its own, at both widths and
    /// appearances — this is the first time this contract surface is
    /// consumed, covering the `clients` list-with-a-label case.
    func testANamedClientDrawsSomethingOfItsOwn() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let withClient = try await render([namedClientRow], width: width, appearance: appearance)
                let withNone = try await render([noClientsFieldRow], width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(withClient), inkedPixelCount(withNone),
                                     "a named client drew nothing at \(width)pt, \(appearance)")
            }
        }
    }

    /// A second client draws more, not a wrapped second line — the row
    /// stays inside its existing height budget by summarising instead.
    func testTwoClientsDrawMoreThanOneRatherThanWrapping() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let withOne = try await render([namedClientRow], width: width, appearance: appearance)
                let withTwo = try await render([twoClientsRow], width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(withTwo), inkedPixelCount(withOne),
                                     "a second client drew nothing at \(width)pt, \(appearance)")
            }
        }
    }

    /// `[]` (tmux answered, nobody attached) still draws its own line —
    /// never the blank a dropped field would leave.
    func testEmptyAttachedListDrawsItsOwnLineRatherThanNothing() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let empty = try await render([emptyClientsRow], width: width, appearance: appearance)
                let absent = try await render([noClientsFieldRow], width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(empty), inkedPixelCount(absent),
                                     "an empty clients list drew nothing at \(width)pt, \(appearance)")
            }
        }
    }

    /// `null` (the read failed) must draw differently from `[]` (tmux
    /// answered, nobody attached) — the contract's own distinction between
    /// "could not tell" and "positively zero," and the one this view must
    /// not collapse.
    func testNullClientsDrawsDifferentlyFromEmptyAttached() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let unknown = try await render([unknownClientsRow], width: width, appearance: appearance)
                let empty = try await render([emptyClientsRow], width: width, appearance: appearance)
                XCTAssertNotEqual(inkedPixelCount(unknown), inkedPixelCount(empty),
                                  "null and [] clients drew identically at \(width)pt, \(appearance) — "
                                  + "they are different answers and must say different things")
            }
        }
    }

    /// `null` also draws something of its own, rather than nothing — the
    /// same never-dropped rule every other unreadable field in this panel
    /// follows.
    func testNullClientsStillDrawsSomethingOfItsOwn() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let unknown = try await render([unknownClientsRow], width: width, appearance: appearance)
                let absent = try await render([noClientsFieldRow], width: width, appearance: appearance)
                XCTAssertGreaterThan(inkedPixelCount(unknown), inkedPixelCount(absent),
                                     "null clients drew nothing at \(width)pt, \(appearance)")
            }
        }
    }
}
