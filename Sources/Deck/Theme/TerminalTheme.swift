import Foundation

/// One appearance of one theme: everything the terminal canvas needs to draw.
///
/// `ansi` is always 16 entries, in the standard order (0-7 normal, 8-15
/// bright), because that is the order SwiftTerm's `installColors` expects.
struct TerminalPalette: Equatable {
    let background: RGB
    let foreground: RGB
    let cursor: RGB
    let selection: RGB
    let ansi: [RGB]
}

/// A named theme carrying both appearances. The shell picks between them; a
/// palette never decides for itself, which is the native half of CLAUDE.md's
/// single-appearance-authority rule.
struct TerminalTheme: Equatable {
    let name: String
    let light: TerminalPalette
    let dark: TerminalPalette

    func palette(for appearance: Appearance) -> TerminalPalette {
        switch appearance {
        case .light: return light
        case .dark: return dark
        }
    }
}

enum Appearance: Equatable {
    case light
    case dark
}
