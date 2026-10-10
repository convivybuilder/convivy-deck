import SwiftUI

/// A child session, drawn indented under its crew — a pinned sibling
/// (Phase 1) or a discovered one found on the mini outside Deck (Phase 2;
/// see `SessionGrouping`). Shares `RailRow`'s dot, ink-solving, and selection
/// wash — the row-level identity language is one thing regardless of how the
/// child got here — but carries no disclosure of its own: a child cannot
/// have children in this phase (design §D nesting is explicitly out of
/// scope here).
///
/// TAKES A BARE NAME AND DISPLAY NAME, not a `PinnedSession`, so one view
/// serves both a pinned child (whose display name is whatever the
/// new-subcrew skill or a hand edit to `theme.json` gave it) and a
/// discovered one (which has no display name of its own — its tmux name is
/// drawn as-is).
struct RailChildRow: View {
    let name: String
    let displayName: String
    let isSelected: Bool
    let accent: RGB
    let appearance: Appearance
    /// The Builder Default ground this row is drawn on, set by the shell's pin.
    @Environment(\.statusGround) private var statusGround
    let mark: SessionState.Mark
    let isStopped: Bool
    let themeMenu: () -> AnyView
    /// True for a discovered session the mini has confirmed has no agent —
    /// `SessionSurface.choose(...) == .terminalOnly` — and also true for a
    /// PINNED child whose tmux session is gone entirely
    /// (`PinnedRowLiveness.stale`). Draws the same `⊞` treatment
    /// `WindowLeafRow` uses for a hand-made window instead of the ordinary
    /// dot: a dimmed "stopped" dot would say this row can be started from
    /// here, which is false for a session Deck did not create, and would
    /// read as an ordinary quiet session for a stale pin whose attach
    /// actually creates a fresh one.
    var isTerminalOnly: Bool = false
    /// True only for an "OTHER SESSIONS" row — a discovered session no crew
    /// owns yet. A terminal-only row like this one previews the hue it
    /// would take on adoption, drawn at 30% opacity, rather than the
    /// achromatic glyph a terminal-only CHILD of a known crew keeps: that
    /// child already belongs to a crew and already draws that crew's hue
    /// everywhere else, so there is nothing left to preview.
    /// `ContentView.themeForSession` already hashes a bare name to a
    /// catalog theme, so the hue this draws exists before anyone adopts the
    /// row — see `design/redesign/03-rail.html`'s `.mark.term.would`. A
    /// deliberate change from the achromatic `⊞` this row drew before,
    /// accepted in review on that condition.
    var previewsAdoptionHue: Bool = false
    /// True when this is the last row in its crew's own child list — see
    /// `RailChildSpine`. Ignored when `indent` is 0 (an "OTHER SESSIONS"
    /// row has no parent to hang a spine from).
    var isLast: Bool = false
    /// "Stop", offered only when non-nil — an "OTHER SESSIONS" row and an
    /// ordinary discovered child under its crew both need it
    /// (`deck/specs/multiple-sessions-per-project` §"The model"): either can
    /// be agent-less and resolve to `.terminalOnly`, which has no Stop
    /// control in the pane itself. A pinned child usually never passes this
    /// (its pane carries its own Stop while it has an agent) — the one
    /// exception is `PinnedRowLiveness.needsRowStop`: a session adopted
    /// while agent-less keeps the tmux session it had, and its pane still
    /// offers no Stop, so the row stays its only way out. Reachable two
    /// ways: the context menu (shipped in #106) and, when non-nil, a
    /// hover-only trailing button — a discovered row has no right-click
    /// habit behind it the way a crew row's theme picker gives one, so the
    /// context menu alone left the operator unable to find a way to end
    /// `comptroller`. The context-menu item stays; this adds a second,
    /// discoverable path rather than replacing the first.
    var onStop: (() -> Void)? = nil
    /// "Remove from Deck…", offered only when non-nil — a PINNED child's
    /// own way out, mirroring `RailRow.onRemove` one level down (the
    /// operator's call: "same wording, same ordering, same destructive roles as
    /// `RailRow`'s"). The shell owns the confirm (including the conditional
    /// "Remove and Stop") and the `ThemeStore.removePinnedSession` call, the
    /// same division `onRemove` already follows at the crew level. Nil for
    /// a discovered child (nothing pinned to remove) and for an "OTHER
    /// SESSIONS" row (no crew row to remove it from).
    var onRemove: (() -> Void)? = nil
    /// "Adopt into ▸"'s targets — every crew on this discovered session's
    /// own host (`SessionGrouping.adoptionTargets`), resolved by the shell.
    /// Only ever non-empty for an "OTHER SESSIONS" row; empty omits the
    /// item, matching `RailRow`'s "Nest under ▸".
    var adoptionTargets: [Crew] = []
    /// A crew was chosen from "Adopt into ▸". The shell owns the
    /// `ThemeStore.addPinnedSession` call — the same division every other
    /// destructive-or-structural action here already follows. Nil wherever
    /// `adoptionTargets` is empty.
    var onAdopt: ((Crew) -> Void)? = nil
    /// "Promote to Crew…" was chosen — this row's inverse of adoption, only
    /// ever offered on an "OTHER SESSIONS" row (`RailView.otherSessionRow`).
    /// The shell owns the derivation (`SessionPromotion`), the confirm, and
    /// the `ThemeStore.addCrew` call — the same division every other
    /// structural action here already follows. Nil for a pinned or
    /// discovered child, which already has a crew.
    var onPromote: (() -> Void)? = nil

    /// True while the pointer is over this row — the gate on the hover
    /// button below. Introduced here rather than reused from elsewhere: the
    /// rail has no existing hover-affordance idiom to match, so this is the
    /// minimal one.
    @State private var isHovering = false
    /// How far this row indents beyond its own leading padding. Defaults to
    /// `RailChildRow.indent`, a crew's child; an "OTHER SESSIONS" row passes
    /// 0, since it draws at the rail's top level rather than under a crew.
    var indent: CGFloat = RailChildRow.indent
    /// True in the 44pt dot rail — see `RailRow.isCollapsed`'s doc, which
    /// this mirrors. The spine and its tick are UNCHANGED: `railChildSpine`
    /// draws under a fixed row height regardless of what the row itself
    /// shows, which is exactly why a child reads as a child at 44pt with no
    /// separate narrow geometry to keep in sync.
    var isCollapsed: Bool = false
    /// See `RailRow.meter`.
    var meter: ContextMeter? = nil
    /// See `RailRow.rolloverActions`.
    var rolloverActions: [SessionAgent.RolloverAction] = []
    /// See `RailRow.onRollover`.
    var onRollover: ((SessionAgent.RolloverAction) -> Void)? = nil
    /// See `RailRow.runModelMark`.
    var runModelMark: RunModelMark? = nil

    /// The terminal-only glyph's ink, or nil to draw the achromatic
    /// `.secondary` treatment unchanged. A pure function so the "which rows
    /// preview a hue" rule is pinned by a test rather than left to the
    /// view's `if`.
    nonisolated static func terminalGlyphInk(previewsAdoptionHue: Bool, accent: RGB) -> RGB? {
        previewsAdoptionHue ? accent : nil
    }

    /// How far a child indents under its crew's dot. Applied as leading
    /// padding on top of the row's own horizontal padding, so the child's dot
    /// sits to the right of the parent's rather than at the rail's shared
    /// identity column (design §E's mocks: `    ● research`).
    static let indent: CGFloat = 20

    private var backing: RGB {
        RailRow.markBacking(appearance: appearance, isSelected: isSelected, accent: accent,
                            ground: statusGround)
    }

    var body: some View {
        HStack(spacing: 8) {
            if isTerminalOnly {
                let previewInk = RailChildRow.terminalGlyphInk(
                    previewsAdoptionHue: previewsAdoptionHue, accent: accent)
                Text("⊞")
                    .frameFont(.primary)
                    .foregroundStyle(previewInk.map { AnyShapeStyle(Color($0).opacity(0.3)) }
                                     ?? AnyShapeStyle(.secondary))
                    .frame(width: 10)
            } else {
                SessionDotView(mark: mark, accent: accent, surface: backing,
                               size: 10, isDimmed: isStopped)
            }
            if !isCollapsed {
                Text(displayName)
                    .frameFont(.primary)
                    .foregroundStyle(isStopped || isTerminalOnly ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let runModelMark {
                    RunModelMarkGlyph(mark: runModelMark, surface: backing)
                }
                if let meter, meter.glyph != .none {
                    ContextMeterGlyph(glyph: meter.glyph, surface: backing)
                }
                // HOVER ONLY, never permanently visible — the rail is 200px and
                // these rows are transient, so a standing button on every row
                // would be clutter most of the time it is on screen.
                if let onStop, isHovering {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }
            }
        }
        .padding(.leading, isCollapsed ? 0 : RailRow.leadingPadding + indent)
        .padding(.trailing, isCollapsed ? 0 : 12)
        .frame(maxWidth: isCollapsed ? .infinity : nil)
        .frame(height: RailRow.rowHeight)
        .help(RailRow.rowHelp(isCollapsed: isCollapsed, name: displayName,
                              meterHelp: meter?.help, markHelp: runModelMark?.help))
        // See `RailRow`'s track overlay.
        .overlay(alignment: .bottomLeading) {
            if let meter, !isCollapsed {
                ContextMeterTrack(meter: meter, surface: backing)
                    .padding(.leading, RailRow.leadingPadding + indent + 18)
                    .padding(.trailing, 12)
                    .padding(.bottom, 2)
            }
        }
        .background(isSelected ? Color(accent).opacity(0.15) : Color.clear)
        .railChildSpine(indent: indent, isLast: isLast)
        .onHover { isHovering = $0 }
        // Drawn at the CHILD's own leading edge, indent included — "expanded,
        // the bar draws on the child's own row" (design §"Attention"). The
        // parent's row is what carries the folded case, via
        // `RailRow.effectiveSummonsSource`.
        .overlay(alignment: .leading) {
            if let ink = RailRow.summonsInk(mark: mark, isStopped: isStopped, on: backing)
                ?? (meter?.summons == true && !isStopped ? ThemeRecipe.attentionInk(on: backing) : nil) {
                Rectangle()
                    .fill(Color(ink))
                    .frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            RolloverMenuItems(meter: meter, actions: rolloverActions, onRollover: onRollover)
            themeMenu()
            if let onAdopt, !adoptionTargets.isEmpty {
                Divider()
                Menu("Adopt into") {
                    ForEach(adoptionTargets) { crew in
                        Button(crew.displayName) { onAdopt(crew) }
                    }
                }
            }
            if let onPromote {
                Divider()
                Button("Promote to Crew…", action: onPromote)
            }
            if let onStop {
                Divider()
                Button("Stop", role: .destructive, action: onStop)
            }
            if let onRemove {
                Divider()
                Button("Remove from Deck…", role: .destructive, action: onRemove)
            }
        }
    }
}
