import SwiftUI

/// Every typographic surface Deck draws, each sized independently.
///
/// WHY FOUR AND NOT ONE. There was one preference — the terminal's — and the
/// session pane's text scale was DERIVED from it as a ratio, so moving the
/// terminal moved the conversation and neither could be set alone. Everything
/// else (vitals, live bar, rail rows, composer) was hardcoded at ~30 call sites
/// between 9 and 13pt, reachable only by editing Swift. The operator: "the settings box
/// has a terminal font size which also changes the session font size, and a line
/// spacing which only changes terminal."
///
/// THE LADDER, AND WHY THE TERMINAL IS NOT ON IT. Frame 11, composer 13, session
/// prose ~16: a step of roughly 1.2, so each surface is one perceptible notch
/// from its neighbour and the hierarchy reads without anyone naming it. The
/// terminal stands apart at 11.5 because that number is CELL PHYSICS rather than
/// taste — see `TerminalTypography.default`, where 11.5 is the largest Monaco
/// size landing on the 7.0pt cell that matches iTerm's columns. Deriving the
/// composer or the chrome from it would import a SwiftTerm rounding workaround
/// into surfaces that have no cells.
struct DeckTypography: Equatable {
    /// The terminal canvas: font family, point size, line spacing.
    var terminal: TerminalTypography

    /// The conversation, rendered by `session-view` in a web pane.
    var session: SessionTypography

    /// The message box you type into.
    var composer: ComposerTypography

    /// The chrome around both panes — vitals, live bar, rail rows, buttons.
    var frame: FrameTypography

    static let `default` = DeckTypography(
        terminal: .default, session: .default, composer: .default, frame: .default)
}

/// The conversation pane's typography.
///
/// A PERCENT AND A RATIO, NOT POINTS, because that is what the renderer takes
/// and what it means. `session-view --scale` sets `:root { font-size: N% }`, and
/// the page's prose, collapsed summaries and tool output are each a different
/// multiple of that root — so a single point value would be a lie about which
/// of them it named. The settings slider shows the effective prose size beside
/// the percentage, which is the honest way to make a percent legible.
struct SessionTypography: Equatable {
    /// Multiplier on the page's root font size, 1.0 being what ships.
    var scale: Double

    /// Leading for running prose only, passed as `--line-height`. Separate from
    /// `scale` because code and prose want different leading: scale moves the
    /// whole document, this opens the paragraphs.
    var lineHeight: Double

    /// The shipped rendering, ratified as an independent default rather than
    /// inherited from the terminal's size.
    static let `default` = SessionTypography(scale: 1.0, lineHeight: 1.65)

    /// `session-view`'s own bounds, mirrored so a value it would refuse is never
    /// sent — a refused flag leaves the page at a size nobody asked for, with
    /// nothing to say why.
    static let minimumScale = 0.5
    static let maximumScale = 3.0
    /// Narrower than the scale's range, and for a reason worth stating: below
    /// ~1.2 descenders collide with the next line's ascenders, and past ~2.4 a
    /// paragraph stops reading as one block.
    static let minimumLineHeight = 1.2
    static let maximumLineHeight = 2.4

    var clampedScale: Double {
        DeckTypography.clamp(scale, Self.minimumScale, Self.maximumScale,
                             fallback: Self.default.scale)
    }

    var clampedLineHeight: Double {
        DeckTypography.clamp(lineHeight, Self.minimumLineHeight, Self.maximumLineHeight,
                             fallback: Self.default.lineHeight)
    }

    /// The prose size a reader actually gets, for the settings caption. The page
    /// ships at a 15px root and prose at 1.05rem of it, so this is what the
    /// percentage means in the only units anyone can picture.
    var effectiveProsePixels: Double { 15 * 1.05 * clampedScale }
}

/// The message box.
struct ComposerTypography: Equatable {
    var fontSize: CGFloat

    /// 13pt is `NSFont.systemFontSize`, macOS's body size. You compose
    /// multi-line prose here, so it earns body size — one notch above the
    /// chrome, one below the pane that will display what you wrote. It was 12,
    /// which put it level with chrome that is only glanced at.
    static let `default` = ComposerTypography(fontSize: 13)

    static let minimumFontSize: CGFloat = 10
    static let maximumFontSize: CGFloat = 20

    var clampedFontSize: CGFloat {
        CGFloat(DeckTypography.clamp(Double(fontSize), Double(Self.minimumFontSize),
                                     Double(Self.maximumFontSize),
                                     fallback: Double(Self.default.fontSize)))
    }
}

/// The chrome, as ONE number from which every role derives.
///
/// One stored value rather than seven, because a user adjusting "the frame"
/// means all of it and would not thank anyone for seven sliders that must be
/// kept in step. The roles are fixed offsets from the base, so the hierarchy
/// between a rail row's name and the caption under the send button survives any
/// size the user picks.
struct FrameTypography: Equatable {
    var baseSize: CGFloat

    /// 11 was already the de-facto value at roughly twenty of the thirty
    /// hardcoded call sites — it was right. The work is making the other ten
    /// derive from it rather than each having been chosen alone.
    static let `default` = FrameTypography(baseSize: 11)

    static let minimumBaseSize: CGFloat = 10
    static let maximumBaseSize: CGFloat = 14

    var clampedBaseSize: CGFloat {
        CGFloat(DeckTypography.clamp(Double(baseSize), Double(Self.minimumBaseSize),
                                     Double(Self.maximumBaseSize),
                                     fallback: Double(Self.default.baseSize)))
    }

    /// What a piece of chrome is for, which decides its size and weight.
    ///
    /// Named by ROLE rather than by size so a call site says why it is that big.
    /// `.font(.system(size: 11))` repeated thirty times records a number; a role
    /// records a decision, and a reader can tell whether a new label belongs
    /// beside the vitals or beside the rail's section headers.
    enum Role {
        /// Rail row names, the start-session title, the empty-state line.
        case primary
        /// A gate's question, the blocked banner, the rail's "New" field.
        case emphasis
        /// Vitals, status text, buttons, gate option details. The base size.
        case body
        /// The phase label. Body size at medium weight, so "Working" reads as
        /// the live thing on the row without being larger than its neighbours.
        case live
        /// Section headers: "START", a gate's header. Uppercase and tracked,
        /// which rhymes deliberately with the renderer's own `.who` treatment
        /// across the native/web boundary.
        case label
        /// The send hint, the stale-reading marker.
        ///
        /// This is the floor. It was 9pt at two call sites, below the 10pt macOS
        /// treats as the minimum for text — small enough that the one line
        /// telling a new user which key sends was the least legible thing on
        /// screen.
        case caption
        /// An SF Symbol set beside `body` text. Smaller on purpose: a glyph at
        /// the same point size as its label reads as larger, so this is an
        /// optical correction rather than a hierarchy step, and it is the one
        /// role allowed below the text floor.
        case icon

        fileprivate var offset: CGFloat {
            switch self {
            case .primary: return 2
            case .emphasis: return 1
            case .body, .live: return 0
            case .label, .caption: return -1
            case .icon: return -2
            }
        }

        var weight: Font.Weight {
            switch self {
            case .live: return .medium
            case .label: return .semibold
            default: return .regular
            }
        }
    }

    func size(_ role: Role) -> CGFloat {
        max(clampedBaseSize + role.offset, 8)
    }
}

extension DeckTypography {
    /// NaN-safe clamp, shared by every surface.
    ///
    /// `min(max(nan, lo), hi)` returns **nan** — every comparison against NaN is
    /// false, so the value passes straight through a naive clamp. That matters
    /// more than it looks: a NaN font size propagates into layout arithmetic and
    /// converting a NaN Double to Int traps. The rule this file follows is that
    /// a value nobody can compare is not a lenient value, it is no value, and it
    /// falls back rather than passing through.
    static func clamp(_ value: Double, _ low: Double, _ high: Double,
                      fallback: Double) -> Double {
        guard value.isFinite else { return value.isNaN ? fallback : min(max(value, low), high) }
        return min(max(value, low), high)
    }
}

// MARK: - Applying a frame role

private struct FrameTypographyKey: EnvironmentKey {
    static let defaultValue = FrameTypography.default
}

extension EnvironmentValues {
    /// The chrome's typography, injected once at the shell so every view down
    /// the tree resolves the same base — the appearance-authority rule applied
    /// to type: one owner, stamped in the same frame, rather than each surface
    /// reading the store and possibly disagreeing.
    var frameTypography: FrameTypography {
        get { self[FrameTypographyKey.self] }
        set { self[FrameTypographyKey.self] = newValue }
    }
}

private struct FrameFont: ViewModifier {
    @Environment(\.frameTypography) private var typography
    let role: FrameTypography.Role

    func body(content: Content) -> some View {
        content.font(.system(size: typography.size(role), weight: role.weight))
    }
}

extension View {
    /// Size this text by what it is FOR, not by a number.
    ///
    /// `.font(.system(size: 11))` repeated across thirty call sites recorded a
    /// number and no reason, so a new label had nothing to be consistent with
    /// and the sizes drifted between 9 and 13 with no rule anyone could state.
    /// A role records the decision instead, and moving the frame's base moves
    /// every one of them together.
    func frameFont(_ role: FrameTypography.Role) -> some View {
        modifier(FrameFont(role: role))
    }
}
