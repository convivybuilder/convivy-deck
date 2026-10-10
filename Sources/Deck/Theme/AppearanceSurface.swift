import SwiftUI

/// The surfaces the shell resolves an appearance for.
///
/// The shell decides each surface's appearance in one place
/// (`ThemeConfiguration.appearance(for:systemIsDark:)`) and hands it down,
/// the same way a single window-wide value was handed down before. Under
/// `.builderDefault`, status surfaces draw dark and work surfaces draw light,
/// the way Slack's sidebar sits beside its message pane. The cockpit is a work
/// surface there: it draws light on the frame tint of the selected session's
/// composer, and the green frame around it comes from the status side.
enum AppearanceSurface: Equatable, CaseIterable {
    /// The session list, the selected crew's bead pane and the theme menu.
    case rail
    /// The pane for a selected row whose host resolves to nothing, which has no
    /// session to draw a conversation for.
    case start
    /// The right column's cockpit, including the service crew panel. Under
    /// Builder Default it draws on the selected session's frame tint, not the
    /// status ground.
    case cockpit
    /// A run's detail, opened from the cockpit.
    case run
    /// The header above the main pane and the right column: the Session/Terminal
    /// and the Cockpit/Shell pills.
    case chrome
    /// The Course strip along the foot of the session pane.
    case strip
    /// The session conversation, its composer and its status bar, and the
    /// stopped-session panes (Start, a missing working directory) that stand in
    /// for it. Those draw on the same canvas the conversation does.
    case conversation
    /// The Terminal View, the Shell and the Local Terminal.
    case terminal
    /// The file viewer, the editor, a correction item and review records.
    case document
    /// The Slate sheet of asks and notes.
    case slate
}

extension ThemeConfiguration {
    /// The appearance `surface` draws in.
    ///
    /// `system`, `light` and `dark` answer the same for every surface, so the
    /// window looks as it always has under them. `builderDefault` answers by
    /// surface and never reads `systemIsDark`, since its answer must not change
    /// when the system switches.
    func appearance(for surface: AppearanceSurface, systemIsDark: Bool) -> Appearance {
        switch appearancePreference {
        case .system: return systemIsDark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        case .builderDefault:
            switch surface {
            case .rail, .start, .run, .chrome, .strip: return .dark
            case .cockpit, .conversation, .terminal, .document, .slate: return .light
            }
        }
    }

    /// The appearance to pin `surface`'s subtree to, or `nil` to leave it on
    /// the window's own colour scheme.
    ///
    /// `light`, `dark` and `builderDefault` pin every surface, so native chrome
    /// draws in the appearance the shell resolved for it whatever the system
    /// scheme is. `system` pins nothing: its native chrome follows the system.
    /// The resolved value here never reads `systemIsDark`, because the three
    /// pinning presets answer the same whichever way the system is set.
    func pinnedAppearance(for surface: AppearanceSurface) -> Appearance? {
        guard appearancePreference != .system else { return nil }
        return appearance(for: surface, systemIsDark: false)
    }

    /// What a pinned subtree draws with: its colour scheme, and the ground its
    /// fill and inks solve against.
    ///
    /// The ground is `StatusGround.ground` only for a dark pin under
    /// `builderDefault`, which is exactly the status surfaces. Every other pin
    /// draws on the window background colour resolved in the pinned scheme, so
    /// a pinned Light on a dark Mac draws a light ground. `system` pins nothing
    /// and returns `nil`.
    func pinnedSurface(for surface: AppearanceSurface) -> PinnedSurface? {
        guard let appearance = pinnedAppearance(for: surface) else { return nil }
        let usesStatusGround = appearancePreference == .builderDefault && appearance == .dark
        return PinnedSurface(appearance: appearance,
                             ground: usesStatusGround ? StatusGround.ground : nil)
    }

    /// The appearance of a window with no pane of its own, such as Settings: the
    /// chrome's appearance, so it draws the way the header above the main pane
    /// does. Under `builderDefault` that is dark whatever the system says.
    func windowAppearance(systemIsDark: Bool) -> Appearance {
        appearance(for: .chrome, systemIsDark: systemIsDark)
    }

    /// The pin for the dividers between the native panes: the rail's trailing
    /// edge, the header's underline, and the divider before the right column.
    ///
    /// Each divider sits outside the panes it separates, so under a pinned scheme
    /// its own scheme and the window's system ground would otherwise show through.
    /// `light` and `dark` pin every divider to the chrome's appearance, the same pin
    /// the header draws. `builderDefault` and `system` return `nil` and leave the
    /// dividers on the system scheme, as they were drawn before this pin existed.
    var pinnedDividerSurface: PinnedSurface? {
        switch appearancePreference {
        case .light, .dark: return pinnedSurface(for: .chrome)
        case .system, .builderDefault: return nil
        }
    }
}

/// A pinned subtree's colour scheme and ground, as the shell resolved them.
struct PinnedSurface: Equatable {
    let appearance: Appearance
    /// The Builder Default ground for a status pane, or `nil` when the subtree
    /// draws on the system's own ground.
    let ground: RGB?
}

extension ColumnOccupant {
    /// The surface a right-column occupant draws as.
    var appearanceSurface: AppearanceSurface {
        switch self {
        case .cockpit: return .cockpit
        case .remoteShell, .localTerminal: return .terminal
        case .viewer, .editor, .item, .reviewRecords: return .document
        case .run: return .run
        case .slate: return .slate
        }
    }
}

extension View {
    /// Pins this subtree to `pinned`'s colour scheme and ground, or leaves it
    /// alone when `pinned` is `nil`.
    ///
    /// SwiftUI resolves system colours such as `controlBackgroundColor` and
    /// `.secondary` against the colour scheme in the environment, so writing
    /// `\.colorScheme` here is what lets a dark rail draw dark beside a light
    /// pane. The modifier writes the scheme and never reads it, so the shell
    /// still decides. The background fill makes sure a surface paints its own
    /// ground rather than showing the window's system colour behind it.
    ///
    /// The same write carries `pinned.ground` as `\.statusGround`, so the views
    /// under a status pane fill and solve their inks against the Builder
    /// Default ground without each one reading the preference.
    @ViewBuilder
    func surfaceAppearance(_ pinned: PinnedSurface?) -> some View {
        if let pinned {
            let scheme: ColorScheme = pinned.appearance == .dark ? .dark : .light
            self
                .environment(\.colorScheme, scheme)
                .environment(\.statusGround, pinned.ground)
                .background {
                    Rectangle()
                        .fill(pinned.ground.map(Color.init) ?? Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, scheme)
                }
        } else {
            self
        }
    }
}
