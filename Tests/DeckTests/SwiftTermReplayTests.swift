import XCTest
import SwiftTerm
@testable import Deck

/// A `TerminalDelegate` that does nothing except record the two signals
/// these tests need (buffer activation, clipboard writes) — a stand-in for
/// the real app's `LocalProcessTerminalView`, which none of this needs
/// since it operates purely on `Terminal`'s parser and buffer.
final class RecordingTerminalDelegate: TerminalDelegate {
    private(set) var bufferActivationCount = 0
    private(set) var clipboardCopies: [Data] = []

    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
    func sizeChanged(source: Terminal) {}
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) {}
    func bufferActivated(source: Terminal) { bufferActivationCount += 1 }
    func synchronizedOutputChanged(source: Terminal, active: Bool) {}
    func bell(source: Terminal) {}
    func selectionChanged(source: Terminal) {}
    func isProcessTrusted(source: Terminal) -> Bool { true }
    func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { nil }
    func mouseModeChanged(source: Terminal) {}
    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {}
    func hostCurrentDirectoryUpdated(source: Terminal) {}
    func hostCurrentDocumentUpdated(source: Terminal) {}
    func colorChanged(source: Terminal, idx: Int?) {}
    func setForegroundColor(source: Terminal, color: SwiftTerm.Color) {}
    func setBackgroundColor(source: Terminal, color: SwiftTerm.Color) {}
    func setCursorColor(source: Terminal, color: SwiftTerm.Color?) {}
    func getColors(source: Terminal) -> (foreground: SwiftTerm.Color, background: SwiftTerm.Color) {
        (SwiftTerm.Color(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF), SwiftTerm.Color(red: 0, green: 0, blue: 0))
    }
    func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
    func clipboardCopy(source: Terminal, content: Data) { clipboardCopies.append(content) }
    func clipboardRead(source: Terminal) -> Data? { nil }
    func notify(source: Terminal, title: String, body: String) {}
    func progressReport(source: Terminal, report: Terminal.ProgressReport) {}
    func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {}
    func createImage(source: Terminal, data: Data, width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool) {}
}

enum FixtureLoader {
    /// Loads a captured `.bytes` fixture (see `Fixtures/README.md` for how
    /// each one was recorded) from the test bundle's resources.
    static func load(_ name: String) -> [UInt8] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "bytes", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else {
            XCTFail("missing fixture: \(name).bytes")
            return []
        }
        return [UInt8](data)
    }

    /// Splits a byte stream right after the first occurrence of `marker`,
    /// so a test can assert mid-stream state (mode enabled) as well as
    /// final state (mode disabled) from one real capture.
    static func splitAfterFirstOccurrence(of marker: [UInt8], in bytes: [UInt8]) -> (head: [UInt8], tail: [UInt8])? {
        guard !marker.isEmpty, bytes.count >= marker.count else { return nil }
        for start in 0...(bytes.count - marker.count) {
            if Array(bytes[start..<(start + marker.count)]) == marker {
                let splitPoint = start + marker.count
                return (Array(bytes[0..<splitPoint]), Array(bytes[splitPoint...]))
            }
        }
        return nil
    }
}

/// Fork 2's acceptance gate (proposal §"Fork 2 — Terminal rendering"): each
/// item in the fixture table gets a recorded-byte-diet replay through
/// SwiftTerm, with the resulting screen/mode state compared against what
/// the byte diet should produce. IME composition is deliberately not here —
/// see Fixtures/README.md for why.
final class SwiftTermReplayTests: XCTestCase {
    private func makeTerminal(delegate: RecordingTerminalDelegate) -> Terminal {
        Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24))
    }

    func testAltScreenSwitchingIsolatesContentAndFiresBufferActivated() {
        let delegate = RecordingTerminalDelegate()
        let terminal = makeTerminal(delegate: delegate)
        terminal.feed(byteArray: FixtureLoader.load("alt-screen"))

        XCTAssertEqual(delegate.bufferActivationCount, 2, "one activation entering the alt screen, one returning to normal")

        let visibleText = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
        XCTAssertTrue(visibleText.contains("after alt-screen"), "normal-buffer content written after returning should be visible")
        XCTAssertFalse(visibleText.contains("inside alt screen"), "content written while the alt buffer was active must not leak into the normal buffer's visible state")
    }

    func testBracketedPasteModeObservesBothOnAndOffDuringReplay() {
        // tmux manages bracketed paste itself around every prompt (disabling
        // while a command line is being typed, re-enabling once the prompt
        // redraws), on top of the two explicit toggles this fixture adds —
        // real capture noise the alt-screen/mouse-mode fixtures don't have.
        // So rather than assert a specific before/after transition, feed the
        // stream incrementally and confirm the parser actually tracks the
        // mode both ways somewhere in it, which is the acceptance concern
        // (claude's TUI uses this mode, and tracking it wrong either
        // direction would misinterpret ordinary input as a paste or vice
        // versa).
        let delegate = RecordingTerminalDelegate()
        let terminal = makeTerminal(delegate: delegate)
        let bytes = FixtureLoader.load("bracketed-paste")

        // `bracketedPasteMode` defaults to false, so "observed true" and
        // "observed false at some point" are each satisfiable for free —
        // false is true before a single byte is parsed. Tracking actual
        // false->true and true->false *transitions* instead requires the
        // parser to really flip the mode both ways; a "stuck in paste mode"
        // regression (never transitions back to false after the first
        // enable) would leave sawFalseToTrue satisfied but sawTrueToFalse
        // never set, and fail.
        var previous = terminal.bracketedPasteMode
        var sawFalseToTrue = false
        var sawTrueToFalse = false
        for byte in bytes {
            terminal.feed(byteArray: [byte])
            let current = terminal.bracketedPasteMode
            if !previous && current { sawFalseToTrue = true }
            if previous && !current { sawTrueToFalse = true }
            previous = current
        }

        XCTAssertTrue(sawFalseToTrue, "the mode never transitioned from off to on during replay")
        XCTAssertTrue(sawTrueToFalse, "the mode never transitioned from on to off during replay — a stuck-in-paste-mode regression would look like this")

        let visibleText = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
        XCTAssertTrue(visibleText.contains("pasted content"), "the wrapped paste content is still ordinary printable text")
    }

    func testOSC52ClipboardCopyDecodesBase64Content() {
        let delegate = RecordingTerminalDelegate()
        let terminal = makeTerminal(delegate: delegate)
        terminal.feed(byteArray: FixtureLoader.load("osc52-clipboard"))

        XCTAssertEqual(delegate.clipboardCopies.count, 1)
        let copied = delegate.clipboardCopies.first.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(copied, "deck clipboard test")
    }

    func testUnicodeWideCharactersOccupyTwoColumnsWithAPlaceholder() {
        let delegate = RecordingTerminalDelegate()
        let terminal = makeTerminal(delegate: delegate)
        terminal.feed(byteArray: FixtureLoader.load("unicode-width"))

        var wideCellCount = 0
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            for col in 0..<(terminal.cols - 1) {
                if line.getWidth(index: col) == 2 {
                    wideCellCount += 1
                    XCTAssertEqual(line.getWidth(index: col + 1), 0, "a wide cell at col \(col) on row \(row) must be followed by a zero-width placeholder")
                }
            }
        }
        // The fixture contains 你好世界 (4 wide characters) both as typed-command
        // echo and as the command's real stdout, so at least 4 should appear;
        // the exact count depends on line wrapping and isn't the point.
        XCTAssertGreaterThanOrEqual(wideCellCount, 4)

        let visibleText = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
        XCTAssertTrue(visibleText.contains("你"), "corroborates the wide-cell count actually came from the CJK text, not an unrelated artifact")
        XCTAssertTrue(visibleText.contains("plain ascii"), "narrow ASCII on the following line should be unaffected")
    }

    func testMouseTrackingModeTogglesOnThenOff() {
        let delegate = RecordingTerminalDelegate()
        let terminal = makeTerminal(delegate: delegate)
        let bytes = FixtureLoader.load("mouse-mode")

        guard let (head, tail) = FixtureLoader.splitAfterFirstOccurrence(of: Array("\u{1B}[?1006h".utf8), in: bytes) else {
            XCTFail("enable marker not found in fixture")
            return
        }
        terminal.feed(byteArray: head)
        XCTAssertNotEqual(terminal.mouseMode, .off, "SGR mouse tracking (1000+1006), the mode tmux itself uses, should be active")

        terminal.feed(byteArray: tail)
        XCTAssertEqual(terminal.mouseMode, .off, "both tracking modes were explicitly disabled by the end of the stream")
    }

    func testSustainedStreamingRedrawEndsInACoherentFinalFrame() {
        let delegate = RecordingTerminalDelegate()
        let terminal = makeTerminal(delegate: delegate)
        // 200 iterations of cursor-home + clear-line + a freshly numbered
        // line, approximating a TUI's repaint loop (claude's own redraw
        // shape) — the parser must land on the LAST frame, not some
        // torn mix of an earlier one, and must not have crashed or hung
        // on the volume.
        terminal.feed(byteArray: FixtureLoader.load("sustained-streaming"))

        let firstLine = terminal.getLine(row: 0)?.translateToString(trimRight: true) ?? ""
        XCTAssertTrue(firstLine.contains("line 200"), "the final redraw frame (iteration 200) must be what's on screen, not an earlier one")
        XCTAssertFalse(firstLine.contains("line 199"), "each redraw clears the line before rewriting it — no residual overlap from the prior frame")
    }
}
