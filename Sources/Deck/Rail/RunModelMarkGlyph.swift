import SwiftUI

/// The small trailing glyph a session row draws when one of its live runs is
/// not on its roster model, sized and weighted like `ContextMeterGlyph`.
///
/// TWO GLYPHS AND TWO INKS, because the two cases say different things.
/// An override is a choice someone made, so it draws in the quiet secondary
/// ink, a knob that was turned. A fail-over is nobody's choice and may be
/// worth a look, so it draws in the same warning ink the pane's caution badge
/// uses, solved against the row's backing surface so the shell's appearance,
/// not the system's, decides how it reads in light and dark.
struct RunModelMarkGlyph: View {
    let mark: RunModelMark
    let surface: RGB

    static func symbolName(for kind: RunModelMarkKind) -> String {
        switch kind {
        case .override: return "slider.horizontal.3"
        case .failover: return "arrow.uturn.right.circle"
        }
    }

    var body: some View {
        let image = Image(systemName: RunModelMarkGlyph.symbolName(for: mark.kind))
            .font(.system(size: 9, weight: .semibold))
        Group {
            switch mark.kind {
            case .override: image.foregroundStyle(.secondary)
            case .failover: image.foregroundStyle(Color(ThemeRecipe.warningInk(on: surface)))
            }
        }
        // No `.help` here: the row's own tooltip carries `mark.help`
        // (`RailRow.rowHelp`), because an inner `.help` never showed.
    }
}
