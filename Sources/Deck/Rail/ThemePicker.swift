import SwiftUI

/// The context menu behind a right-click on a rail row.
///
/// This exists so a config file is never the interface. Hand-editing JSON to
/// change a terminal color is a workaround, not a feature; the file stays as
/// the persistence layer and the escape hatch, and this is how a user actually
/// picks.
struct ThemePicker: View {
    /// The theme in effect now, so the menu can mark it. Includes the hashed
    /// default, which is why this is passed in rather than read from the
    /// config — a session the user has never touched still shows its current
    /// color as checked.
    let currentThemeName: String
    let appearance: Appearance
    let onPick: (String) -> Void
    let onResetToDefault: () -> Void

    var body: some View {
        ForEach(ThemeCatalog.all, id: \.name) { theme in
            Button {
                onPick(theme.name)
            } label: {
                // A swatch of the appearance actually on screen, so the menu
                // shows what picking it will look like rather than an
                // appearance the user is not in.
                Label {
                    Text(theme.name.capitalized
                        + (theme.name == currentThemeName ? " ✓" : ""))
                } icon: {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(Color(theme.palette(for: appearance).cursor))
                }
            }
        }

        Divider()

        Button("Reset to Default", action: onResetToDefault)
    }
}
