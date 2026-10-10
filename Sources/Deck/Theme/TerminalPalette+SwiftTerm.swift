import AppKit
import SwiftTerm

extension RGB {
    /// SwiftTerm's `Color` carries 16-bit components, not 8-bit. Scaling by
    /// 65535 rather than 255 matters: multiplying by 255 would land every color
    /// in the darkest 0.4% of the range and render the whole palette black.
    var swiftTermColor: SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16((red * 65535).rounded()),
            green: UInt16((green * 65535).rounded()),
            blue: UInt16((blue * 65535).rounded())
        )
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

extension TerminalPalette {
    /// Applies the whole palette to a live terminal view.
    ///
    /// `installColors` is documented to silently do nothing unless handed
    /// exactly 16 entries, so a palette that lost one would fail invisibly,
    /// leaving SwiftTerm's stock dark-background ANSI colors on a light page.
    /// `TerminalPalette` guarantees the count by construction and
    /// `ThemeContrastTests` asserts it.
    @MainActor
    func apply(to view: TerminalView) {
        view.installColors(ansi.map(\.swiftTermColor))
        view.nativeBackgroundColor = background.nsColor
        view.nativeForegroundColor = foreground.nsColor
        view.caretColor = cursor.nsColor
        view.selectedTextBackgroundColor = selection.nsColor
        // Not optional. SwiftTerm replaces a character's own foreground with
        // this whenever it is selected (AppleTerminalView.swift:1141), and its
        // Mac default is NSColor.black (MacTerminalView.swift:836) — so a dark
        // theme without this draws black text on a dark selection, around 2:1.
        // Setting the palette's own foreground is what
        // ThemeContrastTests.testSelectedTextIsReadable asserts.
        view.selectedTextForegroundColor = foreground.nsColor
    }
}
