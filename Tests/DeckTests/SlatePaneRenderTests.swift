import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// What `SlatePane` DRAWS (issue_01M3WPYD8M0P8PD20Y3ZBNGBWG), not merely what
/// `Slate.decode`/`SlateModel` compute — those are `SlateTests`'/
/// `SlateModelTests`' own job. The item's own instruction is to render with
/// `NSHostingView` + `cacheDisplay` at 320pt and 280pt in both appearances
/// before committing, the same thing `PullRequestsExpanderRenderTests` and
/// `PullRequestWorkItemChipRenderTests` already do for their own panes.
///
/// Renders via `NSHostingView` + `cacheDisplay`, never `ImageRenderer`, which
/// draws `ScrollView` contents blank — `CockpitRevealRenderTests`' own choice.
@MainActor
final class SlatePaneRenderTests: XCTestCase {
    private let testTarget = SSHTarget(user: "operator", host: "macstudio")

    private func askOpenWithTrickyText() -> SlateCard {
        .ask(SlateCard.Ask(
            id: "a-quotes", state: .open,
            question: #"Ship the copy with "straight quotes", a `backtick`, and a literal $PATH?"# + "\n"
                + "Second line, after a real newline.",
            answerDraft: nil, answer: nil))
    }

    private func askAnswered() -> SlateCard {
        .ask(SlateCard.Ask(
            id: "a-answered", state: .answered, question: "Short question, already answered.",
            answerDraft: "the operator's answer", answer: "the operator's answer"))
    }

    private func unknownCard() -> SlateCard {
        .unknown(id: "a-unknown")
    }

    private func noteDraftWithTrickyText() -> SlateCard {
        .note(SlateCard.Note(
            id: "n-quotes", state: .draft,
            text: #"Draft holding "straight quotes", a `backtick`, and a literal $PATH,"# + "\n"
                + "plus a second line after a real newline."))
    }

    private func fixtureCards() -> [SlateCard] {
        [askOpenWithTrickyText(), askAnswered(), noteDraftWithTrickyText(), unknownCard()]
    }

    /// A model pre-seeded with `cards` via `fetchSlate`, already `refresh()`ed
    /// so `slate` is populated before the first frame — `SlatePane`'s own
    /// `.task(id:)` calls `start(session:target:)` again on mount, but with
    /// the same (session, target) that is a no-op (`SlateModel.start`'s own
    /// guard), so the seeded state survives.
    private func model(cards: [SlateCard]) async -> SlateModel {
        let model = SlateModel()
        model.fetchSlate = { _, session in Slate(session: session, cards: cards) }
        model.start(session: "deck-coder", target: testTarget)
        await model.refresh()
        return model
    }

    /// Mounts `SlatePane` alone in a live window, given time for layout to
    /// settle — `PullRequestWorkItemChipRenderTests`' own harness, including
    /// its explicit backdrop (`SlatePane` paints no window chrome of its own
    /// in this harness, and reads no explicit appearance, so without a
    /// backdrop there is no real surface for "dark text" or "light text" to
    /// clear against on either appearance). The caller owns the window and
    /// must `orderOut` it.
    ///
    /// `layoutWidth` lays the pane out wider than the host. The inner frame
    /// sets that width, and the outer frame holds the host at `width`, so the
    /// hosting view cannot grow to fit the pane. Without the outer frame the
    /// host resizes to 400pt and the control's overflow disappears. Only the
    /// control test passes `layoutWidth`.
    private func mount(
        _ model: SlateModel, width: CGFloat, appearance: Appearance, expanded: Set<String> = [],
        layoutWidth: CGFloat? = nil
    ) async throws -> (window: NSWindow, host: NSView) {
        let view = SlatePane(
            session: "deck-coder", target: testTarget, onClose: {},
            // The canvas is the backdrop, so the ink this file counts is text
            // alone. A canvas that differed from the backdrop would read as ink.
            canvas: appearance == .dark ? RGB(red: 0.145, green: 0.145, blue: 0.145)
                : RGB(red: 0.98, green: 0.98, blue: 0.98),
            bandColours: .neutral(appearance), place: "deck-coder on macstudio",
            model: model, initiallyExpanded: expanded
        )
        .frame(width: layoutWidth ?? width, alignment: .leading)
        .frame(width: width, alignment: .leading)
        .clipped()
        .background(appearance == .dark ? Color(white: 0.145) : Color(white: 0.98))
        let host = NSHostingView(rootView: view)
        // Tall enough for the whole fixture: a card below the fold draws no ink here.
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 640))
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
        _ model: SlateModel, width: CGFloat, appearance: Appearance, expanded: Set<String> = []
    ) async throws -> NSBitmapImageRep {
        let (window, host) = try await mount(model, width: width, appearance: appearance, expanded: expanded)
        defer { window.orderOut(nil) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// A left click at `point` in `host`'s own flipped coordinates, delivered
    /// to the host's window the way the window server would deliver it. The
    /// accessibility tree is not an option here: SwiftUI builds none of it
    /// without an assistive-technology client, so the tests find targets by
    /// position instead.
    private func click(_ host: NSView, at point: NSPoint) throws {
        let window = try XCTUnwrap(host.window)
        let location = host.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    /// The rendered pixels of `host` as they stand now.
    private func snapshot(_ host: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Records every write `SlateModel` would send over ssh, so a click test
    /// can see what the button did without touching a host.
    private final class WriteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String] = []
        func record(_ call: String) { lock.lock(); sent.append(call); lock.unlock() }
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return sent }
    }

    /// A model whose writes return their cards and record the call, never ssh.
    private func recordingModel(cards: [SlateCard], recorder: WriteRecorder) async -> SlateModel {
        let model = await self.model(cards: cards)
        model.writeEdit = { _, _, id, _ in
            recorder.record("edit \(id)")
            return .card(cards.first { $0.id == id } ?? .unknown(id: id))
        }
        model.writeSend = { _, _, id, _ in
            recorder.record("send \(id)")
            return .card(cards.first { $0.id == id } ?? .unknown(id: id))
        }
        model.writeCreateNote = { _, _, _ in
            recorder.record("create-note")
            return .malformed
        }
        return model
    }

    /// Whether `c` differs from the render's own corner (the solid backdrop
    /// `render` paints) by more than a hair — `PullRequestWorkItemChipRenderTests`'
    /// own measure.
    private func isInk(_ c: NSColor, against backdrop: NSColor) -> Bool {
        let delta = abs(c.redComponent - backdrop.redComponent)
            + abs(c.greenComponent - backdrop.greenComponent)
            + abs(c.blueComponent - backdrop.blueComponent)
        return delta > 0.05
    }

    private func inkedPixelCount(_ rep: NSBitmapImageRep) -> Int {
        // The bottom-left pixel is the sheet's canvas. The top-left is the
        // header band now, which would count every canvas pixel as ink.
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

    /// Every enabled, focusable control in `host`, as frames in `host`'s own
    /// coordinates: Send, Send Again, Delete, New Note, the close button and
    /// each ask's disclosure triangle. SwiftUI on macOS hosts each one in a
    /// `KeyViewProxy` view, and that view carries no title or accessibility
    /// label, so the walk finds controls by class and not by name. A disabled
    /// button is not focusable, so it drops out of the walk.
    private func controlFrames(in host: NSView) -> [NSRect] {
        var frames: [NSRect] = []
        func walk(_ view: NSView) {
            if String(describing: type(of: view)).hasSuffix("KeyViewProxy") {
                frames.append(host.convert(view.bounds, from: view))
            }
            view.subviews.forEach(walk)
        }
        walk(host)
        return frames
    }

    /// Ink in the rows where `frame` sits, from just left of the control to the
    /// rep's trailing edge. The band follows the control, so the TextEditor
    /// stroke above a Send row never counts, and a control laid out past the
    /// host's trailing edge leaves the band empty.
    private func inkedPixelCount(_ rep: NSBitmapImageRep, inBandOf frame: NSRect, in host: NSView) -> Int {
        // The bottom-left pixel is the sheet's canvas. The top-left is the
        // header band now, which would count every canvas pixel as ink.
        guard let backdrop = rep.colorAt(x: 0, y: rep.pixelsHigh - 1) else { return 0 }
        let scaleX = CGFloat(rep.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / host.bounds.height
        let visualTop = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
        let x0 = Int(max(0, frame.minX - 4) * scaleX)
        let x1 = rep.pixelsWide
        let y0 = Int(max(0, visualTop - 2) * scaleY)
        let y1 = min(rep.pixelsHigh, Int((visualTop + frame.height + 2) * scaleY))
        guard x0 < x1, y0 < y1 else { return 0 }
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if isInk(c, against: backdrop) { count += 1 }
            }
        }
        return count
    }

    /// Asserts `host` holds exactly `expectedCount` controls, every one inside
    /// the frame, each drawing ink where it sits. A control pushed past the
    /// trailing edge fails both checks: its right edge leaves the frame, and
    /// its band is empty. The count proves the walk found the controls, so an
    /// empty walk cannot pass.
    private func assertControlsInsideFrame(
        _ host: NSView, _ rep: NSBitmapImageRep, expectedCount: Int, context: String
    ) {
        let frames = controlFrames(in: host)
        XCTAssertEqual(frames.count, expectedCount,
                       "found \(frames.count) controls, expected \(expectedCount) — \(context)")
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX,
                                     "a control extends past the frame — \(context)")
            XCTAssertGreaterThan(inkedPixelCount(rep, inBandOf: frame, in: host), 0,
                                 "no ink where a control sits — \(context)")
        }
    }

    /// The lowest bottom edge among `host`'s controls. A card's controls sit
    /// below its id line, so this moves down when the id line grows. `host`
    /// is flipped, so a larger `y` is lower on screen.
    private func lowestControlBottom(in host: NSView) -> CGFloat? {
        controlFrames(in: host).map(\.maxY).max()
    }

    /// Writes a PNG for a look, the same opt-in `DECK_SNAPSHOT_DIR` pattern
    /// `PullRequestsExpanderRenderTests`/`StewardBoardQueueRenderTests` use.
    private func writeSnapshot(_ rep: NSBitmapImageRep, name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["DECK_SNAPSHOT_DIR"] else { return }
        if let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// The three fixture cards — an open ask whose question holds quotes,
    /// `$`, a backtick, and a real newline; an answered ask; and an unknown
    /// card — draw real, non-blank content at both widths the item names and
    /// in both appearances, with both ask cards expanded (the shape that
    /// nests the `TextEditor` and the Send button `DisclosureGroup` only
    /// draws when open).
    func testFixtureCardsDrawNonBlankAtBothWidthsAndAppearances() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let populated = try await render(
                    await model(cards: fixtureCards()), width: width, appearance: appearance,
                    expanded: ["a-quotes", "a-answered"])
                try writeSnapshot(populated, name: "slate-fixture-\(Int(width))-\(appearance)")
                XCTAssertGreaterThan(inkedPixelCount(populated), 0,
                                     "the fixture cards drew nothing at \(width)pt, \(appearance)")
            }
        }
    }

    /// The fixture cards draw strictly more ink than an empty Slate ("No
    /// open asks.") — confirms the cards themselves are responsible for the
    /// ink above, not some constant chrome (the header, the divider) that
    /// would draw the same either way.
    func testFixtureCardsDrawMoreInkThanAnEmptySlate() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let populated = try await render(
                    await model(cards: fixtureCards()), width: width, appearance: appearance,
                    expanded: ["a-quotes", "a-answered"])
                let empty = try await render(await model(cards: []), width: width, appearance: appearance)
                XCTAssertGreaterThan(
                    inkedPixelCount(populated), inkedPixelCount(empty),
                    "the fixture cards drew no extra ink over an empty Slate at \(width)pt, \(appearance)")
            }
        }
    }

    /// The unknown card's own row (an icon plus "Card a-unknown: state
    /// unknown") draws something — dropped silently would be the one
    /// outcome the item's own "never dropped" rule forbids.
    func testTheUnknownCardDrawsSomethingOfItsOwn() async throws {
        let withUnknown = try await render(
            await model(cards: fixtureCards()), width: 320, appearance: .light,
            expanded: ["a-quotes", "a-answered"])
        let withoutUnknown = try await render(
            await model(cards: [askOpenWithTrickyText(), askAnswered()]), width: 320, appearance: .light,
            expanded: ["a-quotes", "a-answered"])
        XCTAssertGreaterThan(inkedPixelCount(withUnknown), inkedPixelCount(withoutUnknown),
                             "the unknown card drew nothing of its own")
    }

    /// The note card (its text, Delete and Send) draws ink of its own, not
    /// just the chrome that would draw either way — same proof-of-ink shape
    /// `testTheUnknownCardDrawsSomethingOfItsOwn` uses for the unknown row.
    func testTheNoteCardDrawsSomethingOfItsOwn() async throws {
        let withNote = try await render(
            await model(cards: fixtureCards()), width: 320, appearance: .light,
            expanded: ["a-quotes", "a-answered"])
        let withoutNote = try await render(
            await model(cards: [askOpenWithTrickyText(), askAnswered(), unknownCard()]),
            width: 320, appearance: .light, expanded: ["a-quotes", "a-answered"])
        XCTAssertGreaterThan(inkedPixelCount(withNote), inkedPixelCount(withoutNote),
                             "the note card drew nothing of its own")
    }

    /// The note card's own Delete/Send row must stay inside the frame at the
    /// 280pt floor, the same risk `testExpandedAskCardsKeepTheirSendButtonWithinTheFrameAtBothWidths`
    /// checks for an ask's `HStack(Spacer(), Button)` — note cards are never
    /// collapsed, so no `expanded` set is needed to reach this row.
    func testTheNoteCardKeepsItsSendButtonWithinTheFrameAtBothWidths() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let (window, host) = try await mount(
                    await model(cards: [noteDraftWithTrickyText()]), width: width, appearance: appearance)
                defer { window.orderOut(nil) }
                assertControlsInsideFrame(
                    host, try snapshot(host), expectedCount: 4,
                    context: "note at \(width)pt, \(appearance)")
            }
        }
    }

    /// An expanded ask card's Send/Send Again button must stay inside the
    /// frame at the 280pt floor, not get pushed past the trailing edge — the
    /// review finding's own named risk for this exact `HStack(Spacer(),
    /// Button)` shape. Checked at both widths and appearances, across every
    /// control in the fixture, which includes "Send Again" and the note's
    /// "Send".
    func testExpandedAskCardsKeepTheirSendButtonWithinTheFrameAtBothWidths() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let (window, host) = try await mount(
                    await model(cards: fixtureCards()), width: width, appearance: appearance,
                    expanded: ["a-quotes", "a-answered"])
                defer { window.orderOut(nil) }
                // Seven, not eight: the first ask's Send is disabled (no answer
                // draft), so it is not focusable and the walk does not see it.
                assertControlsInsideFrame(
                    host, try snapshot(host), expectedCount: 7,
                    context: "fixture at \(width)pt, \(appearance)")
            }
        }
    }

    /// The control for `assertSendButtonsInsideFrame`. The same expanded ask
    /// laid out 80pt wider than its 320pt host puts Send past the trailing
    /// edge, and the check must fail there. Without this, a check that passes
    /// everywhere would pass the two tests above too.
    func testTheSendCheckFailsWhenSendIsPushedPastTheFrame() async throws {
        let (window, host) = try await mount(
            await model(cards: [askAnswered()]), width: 320, appearance: .light,
            expanded: ["a-answered"], layoutWidth: 400)
        defer { window.orderOut(nil) }
        let rep = try snapshot(host)
        XCTAssertEqual(controlFrames(in: host).count, 4,
                       "the control must find its controls, or it proves nothing")
        XCTExpectFailure("controls laid out past a 320pt frame must fail the check") {
            assertControlsInsideFrame(host, rep, expectedCount: 4, context: "control")
        }
    }

    /// An open ask whose only text is its id and a fixed question, so two
    /// cards that differ only in id differ only in the id line.
    private func openAsk(id: String) -> SlateCard {
        .ask(SlateCard.Ask(id: id, state: .open, question: "Same question on both sides.",
                           answerDraft: nil, answer: nil))
    }

    private func draftNote(id: String) -> SlateCard {
        .note(SlateCard.Note(id: id, state: .draft, text: "Same text on both sides."))
    }

    /// Every card draws its id line above its controls. A short id and a
    /// 60-character one differ only in that line, so the long one inks more.
    /// The long id wraps, and the wrap pushes the card's controls down, so
    /// the lowest control moves lower. An id line placed below the card's
    /// content would leave those controls where they were, and a dropped id
    /// line would leave the ink count unchanged. Each case fails one check.
    func testEveryCardDrawsItsIDLine() async throws {
        let longID = "a-" + String(repeating: "q", count: 58)
        let longNoteID = "n-" + String(repeating: "q", count: 58)
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let (shortAskWindow, shortAskHost) = try await mount(
                    await model(cards: [openAsk(id: "a-1")]), width: width, appearance: appearance)
                defer { shortAskWindow.orderOut(nil) }
                let shortAsk = try snapshot(shortAskHost)
                let (longAskWindow, longAskHost) = try await mount(
                    await model(cards: [openAsk(id: longID)]), width: width, appearance: appearance)
                defer { longAskWindow.orderOut(nil) }
                let longAsk = try snapshot(longAskHost)
                XCTAssertGreaterThan(inkedPixelCount(longAsk), inkedPixelCount(shortAsk),
                                     "an ask's id line drew nothing at \(width)pt, \(appearance)")
                let shortAskBottom = try XCTUnwrap(lowestControlBottom(in: shortAskHost))
                let longAskBottom = try XCTUnwrap(lowestControlBottom(in: longAskHost))
                XCTAssertGreaterThan(longAskBottom, shortAskBottom,
                                     "an ask's controls did not move down when its id wrapped at \(width)pt, \(appearance) — the id line is not above them")

                let (shortNoteWindow, shortNoteHost) = try await mount(
                    await model(cards: [draftNote(id: "n-1")]), width: width, appearance: appearance)
                defer { shortNoteWindow.orderOut(nil) }
                let shortNote = try snapshot(shortNoteHost)
                let (longNoteWindow, longNoteHost) = try await mount(
                    await model(cards: [draftNote(id: longNoteID)]), width: width, appearance: appearance)
                defer { longNoteWindow.orderOut(nil) }
                let longNote = try snapshot(longNoteHost)
                XCTAssertGreaterThan(inkedPixelCount(longNote), inkedPixelCount(shortNote),
                                     "a note's id line drew nothing at \(width)pt, \(appearance)")
                let shortNoteBottom = try XCTUnwrap(lowestControlBottom(in: shortNoteHost))
                let longNoteBottom = try XCTUnwrap(lowestControlBottom(in: longNoteHost))
                XCTAssertGreaterThan(longNoteBottom, shortNoteBottom,
                                     "a note's controls did not move down when its id wrapped at \(width)pt, \(appearance) — the id line is not above them")
            }
        }
    }

    /// A long id — 80 characters, well past what a card's row holds — wraps
    /// inside the frame, and the answered card's Send Again stays inside it.
    func testALongIDWrapsAndKeepsSendWithinTheFrameAtBothWidths() async throws {
        let longID = "a-" + String(repeating: "x", count: 78)
        let card = SlateCard.ask(SlateCard.Ask(
            id: longID, state: .answered, question: "A question on a card with a long id.",
            answerDraft: "answer", answer: "answer"))
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let (window, host) = try await mount(
                    await model(cards: [card]), width: width, appearance: appearance, expanded: [longID])
                defer { window.orderOut(nil) }
                let rep = try snapshot(host)
                try writeSnapshot(rep, name: "slate-long-id-\(Int(width))-\(appearance)")
                assertControlsInsideFrame(
                    host, rep, expectedCount: 4,
                    context: "long id at \(width)pt, \(appearance) — the id or Send Again may have pushed past the frame")
            }
        }
    }

    /// Sweeps `host` bottom-up along its trailing edge, clicking, until `call`
    /// is recorded. Bottom-up reaches a Send button before a card's label row,
    /// whose click would collapse the card.
    private func clickTrailingEdgeUntil(
        _ call: String, in host: NSView, width: CGFloat, recorder: WriteRecorder
    ) async throws {
        for y in stride(from: CGFloat(600), through: 0, by: -6) {
            try click(host, at: NSPoint(x: width - 30, y: y))
            try await Task.sleep(nanoseconds: 80_000_000)
            if recorder.calls.contains(call) { return }
        }
    }

    /// Send Again and the note's Send still write once the sheet is
    /// selectable, at both widths and appearances; a disabled Send still
    /// writes nothing; New Note opens a draft row without writing.
    func testSendAndNewNoteStillAct() async throws {
        let cards: [(call: String, card: SlateCard)] = [
            ("send a-answered", askAnswered()),
            ("send n-quotes", noteDraftWithTrickyText()),
        ]
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                for (call, card) in cards {
                    let recorder = WriteRecorder()
                    let (window, host) = try await mount(
                        await recordingModel(cards: [card], recorder: recorder), width: width,
                        appearance: appearance, expanded: ["a-answered"])
                    defer { window.orderOut(nil) }
                    try await clickTrailingEdgeUntil(call, in: host, width: width, recorder: recorder)
                    XCTAssertTrue(recorder.calls.contains(call),
                                  "\(call) did not write through at \(width)pt, \(appearance); calls: \(recorder.calls)")
                }
            }
        }

        let recorder = WriteRecorder()
        let (disabledWindow, disabledHost) = try await mount(
            await recordingModel(cards: [openAsk(id: "a-open")], recorder: recorder), width: 320, appearance: .light,
            expanded: ["a-open"])
        defer { disabledWindow.orderOut(nil) }
        for y in stride(from: CGFloat(600), through: 0, by: -6) {
            try click(disabledHost, at: NSPoint(x: 290, y: y))
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        XCTAssertFalse(recorder.calls.contains { $0.hasPrefix("send a-open") },
                       "a disabled Send wrote through; calls: \(recorder.calls)")

        // New Note opens a draft row and writes nothing: the host refuses an
        // empty note, so the first write waits for the operator's text.
        let noteModel = await recordingModel(cards: [], recorder: recorder)
        let (headerWindow, headerHost) = try await mount(noteModel, width: 320, appearance: .light)
        defer { headerWindow.orderOut(nil) }
        try await openDraftWithNewNote(headerHost, noteModel)
        XCTAssertEqual(noteModel.localNoteIDs.count, 1,
                       "New Note did not open a draft row; calls: \(recorder.calls)")
        XCTAssertFalse(recorder.calls.contains("create-note"),
                       "New Note wrote to the host before any text; calls: \(recorder.calls)")
    }

    /// Clicks across the header's New Note button until a draft row opens. The
    /// sweep finds the button by position, since the accessibility tree is
    /// empty here (see `click`).
    private func openDraftWithNewNote(_ host: NSView, _ model: SlateModel) async throws {
        search: for x in stride(from: CGFloat(180), through: 280, by: 8) {
            for y in stride(from: CGFloat(8), through: 32, by: 8) {
                try click(host, at: NSPoint(x: x, y: y))
                try await Task.sleep(nanoseconds: 150_000_000)
                if !model.localNoteIDs.isEmpty { break search }
            }
        }
    }

    /// A host that holds the notes its creates made, and a gate that holds a
    /// create until `open()`, so a test can draw the draft before the host has
    /// its note. A create records its note before it answers, and the reads
    /// return what the host holds, the way the real Slate does. A read that
    /// omitted the note would make `SlateModel` retire the draft as gone.
    /// The create runs on a detached task, so `wait` blocks only that task's
    /// thread, and the timeout keeps a failing test from hanging the run.
    private final class GatedNoteHost: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var cards: [SlateCard] = []
        var held: [SlateCard] { lock.lock(); defer { lock.unlock() }; return cards }
        func hold() { _ = semaphore.wait(timeout: .now() + 10) }
        func open() { semaphore.signal() }
        func record(_ card: SlateCard) { lock.lock(); cards.append(card); lock.unlock() }
    }

    /// A draft row draws its host id once its create lands, on the same
    /// mounted sheet with no reopen. The row is opened by New Note and typed
    /// into through the editor's own binding, `SlateModel.editNote`. The create
    /// is held until the "before" frame is drawn, so the two frames differ only
    /// by what the create changed: the id line and the controls it pushes down.
    /// The model assertion alone cannot see a view that ignores `draftHostIDs`.
    func testADraftDrawsItsHostIDOnceTheCreateLands() async throws {
        for width: CGFloat in [320, 280] {
            for appearance: Appearance in [.light, .dark] {
                let notes = GatedNoteHost()
                let model = await self.model(cards: [])
                model.fetchSlate = { _, session in Slate(session: session, cards: notes.held) }
                model.writeCreateNote = { _, _, text in
                    notes.hold()
                    let note = SlateCard.Note(id: "n-1", state: .draft, text: text)
                    notes.record(.note(note))
                    return .card(.note(note))
                }
                let (window, host) = try await mount(model, width: width, appearance: appearance)
                defer { window.orderOut(nil) }
                try await openDraftWithNewNote(host, model)
                let key = try XCTUnwrap(model.localNoteIDs.first, "New Note opened no draft row at \(width)pt, \(appearance)")
                model.editNote(id: key, text: "Typed before the create lands.")
                try await Task.sleep(nanoseconds: 200_000_000)
                // The key view loop is built at mount, so a control drawn after
                // it has no proxy for `controlFrames` to find until it is rebuilt.
                window.recalculateKeyViewLoop()
                let before = try snapshot(host)
                let beforeBottom = try XCTUnwrap(lowestControlBottom(in: host))
                XCTAssertNil(model.draftHostIDs[key], "no id is drawn before the host holds the note")

                notes.open()
                let deadline = Date().addingTimeInterval(5)
                while model.draftHostIDs[key] == nil, Date() < deadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                XCTAssertEqual(model.draftHostIDs[key], "n-1",
                               "the create did not land at \(width)pt, \(appearance); sendErrors: \(model.sendErrors)")
                try await Task.sleep(nanoseconds: 300_000_000)
                host.layoutSubtreeIfNeeded()
                window.recalculateKeyViewLoop()
                let after = try snapshot(host)
                let afterBottom = try XCTUnwrap(lowestControlBottom(in: host))

                XCTAssertGreaterThan(inkedPixelCount(after), inkedPixelCount(before),
                                     "the draft drew no id line once its create landed at \(width)pt, \(appearance)")
                XCTAssertGreaterThan(afterBottom, beforeBottom,
                                     "the draft's controls did not move down for its id line at \(width)pt, \(appearance)")
            }
        }
    }
}
