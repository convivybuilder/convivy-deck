import XCTest
import SwiftUI
import AppKit
@testable import Deck

/// The drag handle between the conversation and the right-hand column,
/// measured with an `NSHostingView` the way `SettingsLayoutTests` and
/// `PickerTests` already do — headless, no window server, runs over ssh.
///
/// THE FAULT. `Divider()` draws its thin axis VERTICALLY only when it sits
/// directly inside an `HStack` — SwiftUI reads that from the enclosing
/// stack, not from any frame placed around it. Hosted in a `ZStack`, it drew
/// HORIZONTALLY: one point tall, centred in whatever the `ZStack` collapsed
/// to, regardless of the `.frame(width:)` beside it (that modifier
/// constrains only the horizontal axis). The result was a 14×1 dash
/// centred between the two panes, which the pointer essentially never
/// lands on — killing the hover cursor and the drag gesture together.
/// `05e4395` widened `hitWidth` 8 → 14, the wrong axis, which is why the
/// symptom survived that fix.
///
/// THIS TEST MUST FAIL AGAINST THE OLD BODY. Verified by hand before this
/// landed: reverting `ResizableDivider.body` to
/// `ZStack { Divider() }.frame(width: ResizableDivider.hitWidth)` fails
/// `testTheHitStripFillsTheRowsHeight` below (it measures ~1pt instead of
/// the row's height).
final class ResizableDividerLayoutTests: XCTestCase {

    /// Captures a `GeometryReader`'s measured size into a reference type, so
    /// the value survives past the `View`'s own value-type lifetime and can
    /// be read back after `layoutSubtreeIfNeeded()` forces SwiftUI to lay
    /// out and dispatch `onAppear`.
    private final class SizeBox {
        var size: CGSize = .zero
    }

    /// Hosts `ResizableDivider` as the middle child of a three-way `HStack`
    /// pinned to `rowHeight` — the same shape `ContentView.columnDivider` is
    /// actually placed in: a fixed-height row alongside sibling panes that
    /// take `maxHeight: .infinity`. A `GeometryReader` behind the divider
    /// reports what it was actually given.
    @MainActor
    private func measuredHitStripSize(rowHeight: CGFloat = 600) -> CGSize {
        let box = SizeBox()
        let probe = HStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            ResizableDivider(width: .constant(320), onCommit: {})
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear { box.size = geo.size }
                    }
                )
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 800, height: rowHeight)

        let host = NSHostingView(rootView: probe)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: rowHeight)
        host.layoutSubtreeIfNeeded()
        return box.size
    }

    /// THE MEASUREMENT ITSELF. The strip's width still has to stay at
    /// `hitWidth` — this is not a "grow without bound" fix — but its height
    /// must track the row's, not collapse to the divider's own 1pt line
    /// thickness.
    @MainActor
    func testTheHitStripFillsTheRowsHeight() {
        let rowHeight: CGFloat = 600
        let size = measuredHitStripSize(rowHeight: rowHeight)

        XCTAssertEqual(size.width, ResizableDivider.hitWidth, accuracy: 0.5,
                       "the strip's width drifted off hitWidth: \(size)")
        XCTAssertGreaterThan(
            size.height, rowHeight - 1,
            "the hit strip is \(size.height)pt tall in a \(rowHeight)pt row — "
            + "a hairline the pointer can essentially never land on")
    }

    /// The same shape at a second row height, so the pass above cannot be an
    /// accident of one particular number.
    @MainActor
    func testTheHitStripTracksADifferentRowHeightToo() {
        let rowHeight: CGFloat = 340
        let size = measuredHitStripSize(rowHeight: rowHeight)

        XCTAssertGreaterThan(
            size.height, rowHeight - 1,
            "the hit strip is \(size.height)pt tall in a \(rowHeight)pt row")
    }
}
