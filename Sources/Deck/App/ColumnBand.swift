import SwiftUI

/// The colours one right-column band draws. The shell's appearance is the only
/// input, so a band never decides light or dark for itself.
struct ColumnBandColours: Equatable {
    /// The band's fill.
    let surface: RGB
    /// The icon's ink, and the rule's ink when `hasRule` is set.
    let ink: RGB
    /// The place line's ink, solved to 4.5:1 against `surface`.
    let placeInk: RGB
    /// Whether a 2pt rule in `ink` closes the band. False draws the plain
    /// separator instead, which is the neutral form.
    let hasRule: Bool

    /// The neutral band: the window background, primary ink, a plain separator.
    /// The Cockpit draws it, and so does the Shell when no session is selected.
    ///
    /// Under a pin with a `ground`, the band draws on it with the primary ink
    /// solved for that ground: `StatusGround.primaryInk` on the dark status
    /// ground, and a dark ink on the light frame tint the cockpit draws on under
    /// Builder Default. Every other band keeps the system's window background and
    /// label colour.
    static func neutral(_ appearance: Appearance, ground: RGB? = nil) -> ColumnBandColours {
        let surface = ground ?? systemRGB(.windowBackgroundColor, appearance)
        return ColumnBandColours(
            surface: surface,
            ink: neutralInk(appearance, ground: ground),
            placeInk: ThemeRecipe.placeLineInk(on: surface),
            hasRule: false)
    }

    private static func neutralInk(_ appearance: Appearance, ground: RGB?) -> RGB {
        guard let ground else { return systemRGB(.labelColor, appearance) }
        return appearance == .dark ? StatusGround.primaryInk : ThemeRecipe.primaryTextInk(on: ground)
    }

    /// A crew's identity band. The surface is the frame tint of the session's
    /// canvas, which is the same surface the session pane's own status bar
    /// draws on, so the band reads as part of that pane. The icon and rule take
    /// the accent, solved against that surface.
    static func identity(canvas: RGB, accent: RGB, _ appearance: Appearance) -> ColumnBandColours {
        let surface = SessionPaneView.frameTintRGB(canvas: canvas.hexString, appearance: appearance) ?? canvas
        return ColumnBandColours(
            surface: surface,
            ink: ThemeRecipe.dotInk(accent: accent, on: surface),
            placeInk: ThemeRecipe.placeLineInk(on: surface),
            hasRule: true)
    }

    /// The system colour as a plain RGB under `appearance`, so the place line's
    /// ink can be solved against it. The band fills itself with the same value.
    static func systemRGB(_ color: NSColor, _ appearance: Appearance) -> RGB {
        var resolved = RGB(red: 0, green: 0, blue: 0)
        let name: NSAppearance.Name = appearance == .dark ? .darkAqua : .aqua
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            if let rgb = color.usingColorSpace(.sRGB) {
                resolved = RGB(red: Double(rgb.redComponent),
                               green: Double(rgb.greenComponent),
                               blue: Double(rgb.blueComponent))
            }
        }
        return resolved
    }
}

/// The header every right-column tab draws: an icon, a title, a place line and
/// the tab's own trailing controls, with a rule that names the tab's identity.
///
/// The title never truncates and keeps the most room. The place line takes the
/// rest and truncates in the middle, with the whole text in `.help`. A crew's
/// place line is a host, so the end of it is what a reader needs.
struct ColumnBand<Trailing: View>: View {
    let title: String
    let icon: String
    let place: String?
    let colours: ColumnBandColours
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(colours.ink))
                    .frame(width: 18)
                Text(title)
                    .frameFont(.emphasis).fontWeight(.semibold)
                    .fixedSize()
                    .layoutPriority(2)
                if let place {
                    Text(place)
                        .frameFont(.label)
                        .foregroundStyle(Color(colours.placeInk))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(place)
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) { trailing }
                    .fixedSize()
                    .layoutPriority(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(colours.surface))
            if colours.hasRule {
                Rectangle().fill(Color(colours.ink)).frame(height: 2)
            } else {
                Divider()
            }
        }
    }
}
