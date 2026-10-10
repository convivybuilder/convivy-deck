import SwiftUI

/// The one mark a session gets: its identity and its state, on the same object.
///
/// WHY THERE IS ONLY ONE. Every earlier design put state in a second mark
/// trailing the row while identity led it, and the operator's verdict on the last of them
/// was "there's just too much clutter and it doesn't mean anything". Two marks
/// per row is two things to read where the row has one thing to say — and the
/// trailing one was always the weaker of the pair, being small, monochrome, and
/// far from the name it described.
///
/// So the dot that was already there does the work. Colour is the session's own
/// accent, the same colour its canvas and terminal use, so a row stays
/// recognisable at a glance. Shape says what the session is doing. Motion says
/// whether it is still happening.
///
/// THE ONE EXCEPTION IS `.needsYou`, which drops the accent for the attention
/// ink. Shape alone is a weak signal at eight points across fifteen rows, and
/// this is the state the rail exists to be scanned for. Exactly one dot in the
/// rail is not somebody's identity, and it is the one you are looking for.
struct SessionDotView: View {
    let mark: SessionState.Mark
    /// The session's own colour. Every shape but `.needsYou` draws in it,
    /// after `ThemeRecipe.dotInk` walks its lightness far enough from `surface`
    /// for the shape to be readable — a no-op for accents that already clear.
    let accent: RGB
    /// What the dot is drawn over. Both inks are solved against it: the
    /// attention ink for `.needsYou`, and the session's own accent for
    /// everything else.
    let surface: RGB
    /// Diameter of the circle. Every other shape is sized to match it optically,
    /// which is not the same as sizing it identically — see `squareSide`.
    let size: CGFloat
    /// A stopped session keeps its identity and drops its liveness: whatever it
    /// was doing, it is not doing it now.
    var isDimmed: Bool = false

    /// With motion reduced, `.busy` and `.listening` stop moving and are told
    /// apart by shape alone — a notched disc against a whole one. That is why
    /// the notch is a shape difference rather than only a spinner's tail.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var spinning = false
    @State private var pulsing = false

    /// A square at the circle's diameter reads noticeably larger than the
    /// circle, because it fills its bounding box and the circle does not. Pulled
    /// in so the settled rail does not look heavier than the busy one.
    private var squareSide: CGFloat { size * 0.86 }

    /// The summons, sized past the rest rather than level with it.
    ///
    /// THE TRIANGLE IS THE FAINTEST SHAPE IN THE SET AT EQUAL SIZE, which is
    /// arithmetic rather than taste: inscribed in a box it holds 2r² of ink
    /// against a circle's πr², about 64%. At 1.05 it was the quietest mark in
    /// the rail while being the one the rail is scanned for. At 1.35 it carries
    /// roughly a sixth MORE ink than the circle, which is the right side of
    /// level for the only state that is asking for something.
    private var triangleSide: CGFloat { size * 1.35 }

    /// The accent, made legible against whatever this dot is drawn on.
    private var ink: RGB { ThemeRecipe.dotInk(accent: accent, on: surface) }

    /// The second end of the `.listening` pulse — see `ThemeRecipe.pulseDotInk`.
    private var pulseInk: RGB { ThemeRecipe.pulseDotInk(accent: accent, on: surface) }

    var body: some View {
        Group {
            switch mark {
            case .needsYou(let gateAge):
                // The arrow points at the move you make, and it is drawn past
                // the size of everything else — see `triangleSide`. On the rail
                // it is no longer carrying the summons alone: `RailRow` draws a
                // bar down the leading edge for the same state, because a mark
                // this size cannot both say WHAT a row is and say LOOK HERE
                // among a dozen competitors at the same x.
                RightTriangle()
                    .fill(Color(ThemeRecipe.attentionInk(
                        on: surface,
                        staleness: ThemeRecipe.staleness(gateAge: gateAge))))
                    .frame(width: triangleSide, height: triangleSide)

            case .busy:
                // The Convivy mark itself, turning. The operator: "it looks like the
                // Convivy C. If it's not exactly the Convivy C, let's make it
                // so." It now is, to the degree and the ratio.
                ConvivyC()
                    .fill(Color(ink))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(reduceMotion ? nil
                               : .linear(duration: 1.4).repeatForever(autoreverses: false),
                               value: spinning)
                    // BOTH HALVES. The `@State` outlives the branch — the switch
                    // is inside one view's body — so leaving `.busy` and coming
                    // back finds `spinning` already true, `onAppear` sets
                    // true→true, the animation's `value:` sees no change, and
                    // the disc returns frozen at whatever angle it stopped on.
                    // This bug shipped twice in the view this replaces.
                    .onAppear { spinning = true }
                    .onDisappear { spinning = false }

            case .listening:
                // Pulses between two SOLVED inks, not one ink faded by opacity
                // — an alpha blend toward `surface` has no contrast floor at
                // all, which is what let the second phase drop to ~1.4:1 while
                // this shape carries state in its motion, not just its colour.
                // See `ThemeRecipe.pulseDotInk` for how the two ends are chosen
                // — it brightens rather than dims, on every theme.
                Circle()
                    .fill(Color(pulsing ? pulseInk : ink))
                    .frame(width: size, height: size)
                    .animation(reduceMotion ? nil
                               : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                               value: pulsing)
                    // Both halves, for the reason spelled out on `.busy` above.
                    // Gated on `reduceMotion` here (unlike `.busy`'s spin, which
                    // is harmless at any fixed angle): with motion off there is
                    // no animation to carry `pulsing` back to `false`, so an
                    // unconditional `true` would leave the second phase showing
                    // permanently instead of the resting `ink`.
                    .onAppear { if !reduceMotion { pulsing = true } }
                    .onDisappear { pulsing = false }

            case .ready:
                // At rest. A square has corners where every other shape here is
                // round or pointed, which is what makes a settled rail read as
                // settled without drawing anything extra.
                RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .fill(Color(ink))
                    .frame(width: squareSide, height: squareSide)

            case .unreadable:
                // Hollow, because a filled shape would assert something. The
                // pane's answer to this state is to offer the raw terminal.
                Circle()
                    .strokeBorder(Color(ink), lineWidth: max(1, size * 0.18))
                    .frame(width: size, height: size)

            case .unpolled:
                // The rail before its first reading: alive-looking, claiming
                // nothing. A row that started as a square would say "done" about
                // a session that might be mid-turn.
                Circle()
                    .fill(Color(ink))
                    .frame(width: size, height: size)
            }
        }
        // Sized to the LARGEST shape, which is the triangle, so a row's text
        // never shifts when its state changes. Without this the name jogs left
        // and right as sessions work — and the jog would be widest on exactly
        // the transition into the state you are trying to read.
        .frame(width: triangleSide, height: triangleSide)
        // Dimmed, not hidden: a stopped session keeps its identity colour so the
        // row is still recognisable, just plainly off.
        .opacity(isDimmed ? 0.3 : 1)
        .accessibilityLabel(Text(mark.accessibilityLabel))
    }
}

/// The Convivy mark: a disc with a 90° wedge opening to the right and a small
/// hole at its centre.
///
/// MEASURED FROM THE BRAND MARK, NOT APPROXIMATED. The operator, on the working dot:
/// "the notched disk works, it looks like the Convivy C. If it's not exactly
/// the Convivy C, let's make it so." It was not — it was a thick stroked arc,
/// which is a ring with a gap rather than a disc with a wedge, and it had no
/// centre hole at all.
///
/// The numbers come from `convivy-orient/assets/source-mark.png`, sampled by
/// ray: the golden region is absent over an 89° span centred on the +x axis,
/// which is a 90° wedge, and absent within the innermost 19.4% of the radius in
/// every direction, which is the hole. Both are recorded here rather than in a
/// comment elsewhere, because a shape that drifts from the brand is the failure
/// this exists to prevent.
///
/// SPINNING IS WHY THE MARK FITS THIS STATE AT ALL. A circle rotating is
/// indistinguishable from a circle at rest, so the working dot has to carry an
/// asymmetry — and the C's wedge is exactly that, already, by design.
struct ConvivyC: Shape {
    /// The centre hole, as a fraction of the outer radius.
    static let innerRatio: CGFloat = 0.194
    /// Half the wedge's opening. The wedge is centred on the +x axis, so the
    /// body of the mark spans the remaining 270°.
    static let halfWedgeDegrees: CGFloat = 45

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * ConvivyC.innerRatio
        let half = Angle.degrees(ConvivyC.halfWedgeDegrees)
        let start = Angle.degrees(360 - ConvivyC.halfWedgeDegrees)

        var path = Path()
        // Outer edge, the long way round from one lip of the wedge to the other.
        path.addArc(center: centre, radius: outer,
                    startAngle: half, endAngle: start, clockwise: false)
        // Back along the hole, so the enclosed region is the body of the mark
        // and the hole stays empty.
        path.addArc(center: centre, radius: inner,
                    startAngle: start, endAngle: half, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// A catalog row's mark: not running, not yet adopted into a live session —
/// `design/redesign/03-rail.html`'s `m-start`, a hollow square at full ink.
///
/// HOLLOW, NOT DIMMED. A dimmed `.ready` square is what a STOPPED crew draws
/// (`SessionDotView`'s `isDimmed`, 30% opacity, identity hue kept) — the same
/// shape and the same opacity in a different section, which is exactly the
/// pair the dot rail collapses into one indistinguishable glyph. A hollow
/// square reads as "not yet" where a dimmed one reads as "was", and it draws
/// in a neutral ink rather than the row's hue: this row has never run, so
/// there is no identity colour to keep.
///
/// Sized by the same formulas `SessionDotView` uses for its own `.ready` and
/// `.unreadable` shapes, so a catalog row's mark sits at the same optical
/// weight as a live one beside it.
struct CatalogStartMark: View {
    private let size: CGFloat = 10
    private var squareSide: CGFloat { size * 0.86 }
    private var triangleSide: CGFloat { size * 1.35 }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
            .strokeBorder(Color.secondary, lineWidth: max(1, size * 0.18))
            .frame(width: squareSide, height: squareSide)
            // Sized to match `SessionDotView`'s own outer frame, so a
            // catalog row's text starts at the same x as a live row's.
            .frame(width: triangleSide, height: triangleSide)
            .accessibilityLabel(Text("not running; activate to start"))
    }
}

/// A right-pointing triangle, inscribed in its frame.
///
/// Hand-drawn rather than `Image(systemName: "play.fill")`, because an SF Symbol
/// is sized to a text baseline and this sits in a row of geometric shapes: the
/// symbol's optical weight against a plain `Circle` is exactly the mismatch that
/// made the old `?` badge read smaller than the bubble beside it.
struct RightTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension SessionState.Mark {
    /// What the dot says, for a reader who is not looking at it.
    ///
    /// Spelled out rather than left to a shape name, which carries nothing on
    /// its own — "triangle" is not what the row means.
    var accessibilityLabel: String {
        switch self {
        case .needsYou: return "needs an answer"
        case .busy: return "working"
        case .listening: return "agents running"
        case .ready: return "ready"
        case .unreadable: return "state unknown"
        case .unpolled: return "checking"
        }
    }
}
