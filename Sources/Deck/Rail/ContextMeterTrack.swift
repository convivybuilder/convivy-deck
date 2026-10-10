import SwiftUI

/// The context meter's hairline, drawn along the bottom of a rail row — see
/// `ContextMeter` for what decides its fill and ink.
///
/// A LINE, NOT A BAR, AND UNLABELLED, because the row already says two things
/// (who the session is, in the dot's hue, and what it is doing, in the dot's
/// shape) and the operator ruled a second mark on the row out as clutter. The
/// exact number lives in the row's hover text.
///
/// ONE POINT, SQUARE-ENDED. It shipped at two points with rounded ends (four
/// device pixels on Retina), and the operator's verdict on the running app
/// was that it read "like a progress bar" where the design meant "a laser".
/// One point (#228) halved that, but a ZStack sizing bug then drew #228's line
/// at three points, which the operator saw as the same progress bar and asked
/// to go to the thinnest line the display can draw: one device pixel, half a
/// point on Retina. That overshot; the operator's verdict once the sizing bug was fixed and the
/// device-pixel line was actually on screen was that one point, back where
/// #228 left it, reads right. A point is an integral number of device pixels
/// at scale 1, 2 and 3 (one, two and three), so the line still draws crisp
/// rather than blurred across a pixel boundary.
///
/// THE AMBER IS `ThemeRecipe.attentionInk`, the same contrast-solved ink the
/// needs-you bar uses, so "look at this one" is one colour across the rail
/// and holds its contrast on a selected row's accent wash. It carries a faint
/// glow, which is what keeps a one-pixel line findable as a signal rather than
/// only as a reading.
struct ContextMeterTrack: View {
    let meter: ContextMeter
    /// What the row is drawn over, from `RailRow.markBacking`.
    let surface: RGB

    /// One point, at every scale.
    static let thickness: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    private var pulses: Bool { meter.ink == .attentionPulsing && !reduceMotion }
    private var isAttention: Bool { meter.ink != .neutral }

    private var ink: Color {
        switch meter.ink {
        case .neutral: return Color.primary.opacity(0.40)
        case .attention, .attentionPulsing: return Color(ThemeRecipe.attentionInk(on: surface))
        }
    }

    var body: some View {
        if let fill = meter.fill {
            let thickness = ContextMeterTrack.thickness
            GeometryReader { geo in
                // EVERY LINE CARRIES ITS OWN HEIGHT. Left flexible, the two
                // rectangles took the ZStack's height, which the taller tick
                // below sets, so a line meant to be one point drew at the
                // tick's three (and the first version's two-point line at four).
                // Measured in a rendered row, 2026-09-13: six device pixels
                // where two were intended. That is what read as a progress bar.
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.08))
                        .frame(height: thickness)
                    Rectangle().fill(ink)
                        .frame(width: geo.size.width * fill, height: thickness)
                        .shadow(color: isAttention ? ink.opacity(0.7) : .clear, radius: 1.5)
                        .opacity(dimmed ? 0.45 : 1)
                    // The seek threshold, so a grey row shows how close it is.
                    Rectangle().fill(Color.primary.opacity(0.30))
                        .frame(width: 1, height: 3)
                        .offset(x: geo.size.width * meter.threshold)
                }
            }
            .frame(height: ContextMeterTrack.thickness)
            .accessibilityHidden(true)
            // Restarted whenever `pulses` flips, so a row that moves into
            // roll_now while on screen starts pulsing, and one that leaves it
            // settles back to solid.
            .task(id: pulses) {
                dimmed = false
                guard pulses else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
        }
    }
}

/// A row's rollover section of its right-click menu: the meter's reading as a
/// label, then each override the state offers. Draws nothing for a row with no
/// meter and no overrides, so a stopped or agent-less row's menu is unchanged.
struct RolloverMenuItems: View {
    let meter: ContextMeter?
    let actions: [SessionAgent.RolloverAction]
    let onRollover: ((SessionAgent.RolloverAction) -> Void)?

    var body: some View {
        if let meter {
            Text(meter.help)
        }
        if let onRollover {
            ForEach(actions, id: \.self) { action in
                Button(ContextMeter.menuTitle(action, state: meter?.rolloverState)) { onRollover(action) }
            }
        }
        if meter != nil || (onRollover != nil && !actions.isEmpty) {
            Divider()
        }
    }
}

/// The small trailing glyph a rollover state adds to a row: roll-over for
/// `roll_now`, a labelled roll-over for `rolling`, and a veto sign for
/// `vetoed`. Nothing for the other states, whose track says enough.
struct ContextMeterGlyph: View {
    let glyph: ContextMeter.Glyph
    let surface: RGB

    var body: some View {
        let attention = Color(ThemeRecipe.attentionInk(on: surface))
        switch glyph {
        case .none:
            EmptyView()
        case .rollNow:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(attention)
        case .rolling:
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                Text("rolling").frameFont(.label)
            }
            .foregroundStyle(attention)
        case .vetoed:
            Image(systemName: "nosign")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}
