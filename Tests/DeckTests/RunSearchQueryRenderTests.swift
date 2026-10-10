import AppKit
import SwiftUI
import XCTest
@testable import Deck

/// Whether a search query draws literally in the "Searches it has made" row.
/// The row builds its text from an interpolated string, which SwiftUI may read
/// as a Markdown literal. Each query is drawn both ways and the PNGs compared:
/// the same bytes mean the interpolated text is not styled.
@MainActor
final class RunSearchQueryRenderTests: XCTestCase {
    /// The row's query text, built the way `RunDetailPane.searchRow` builds it.
    private func rowText(_ query: String) -> some View {
        Text("\u{201C}\(query)\u{201D}")
    }

    private func verbatimText(_ query: String) -> some View {
        Text(verbatim: "\u{201C}\(query)\u{201D}")
    }

    /// `view` at the row's font, hosted in an `NSHostingView` and drawn to PNG.
    private func png<V: View>(_ view: V) throws -> Data {
        let framed = view.font(.body).frame(width: 400, alignment: .leading).padding(4)
        let host = NSHostingView(rootView: framed)
        host.frame = NSRect(x: 0, y: 0, width: 408, height: 40)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// The controls: a Markdown literal with no interpolation is styled, so a
    /// PNG that differs from its verbatim twin proves this harness can see
    /// Markdown styling at all, for both bold and a link.
    func testControlAMarkdownLiteralDrawsDifferentlyFromItsVerbatimTwin() throws {
        XCTAssertNotEqual(try png(Text("**bold**")), try png(Text(verbatim: "**bold**")))
        XCTAssertNotEqual(try png(Text("[x](https://example.com)")),
                          try png(Text(verbatim: "[x](https://example.com)")))
    }

    func testAnInterpolatedMarkdownLinkQueryDrawsLiterally() throws {
        let query = "[x](https://example.com)"
        XCTAssertEqual(try png(rowText(query)), try png(verbatimText(query)),
                       "the row's text for this query must match its verbatim draw")
    }

    func testAnInterpolatedBoldQueryDrawsLiterally() throws {
        let query = "**bold**"
        XCTAssertEqual(try png(rowText(query)), try png(verbatimText(query)),
                       "the row's text for this query must match its verbatim draw")
    }
}
