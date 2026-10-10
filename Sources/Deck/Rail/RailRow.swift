import SwiftUI

/// One rail row, decorated with what its session is doing.
///
/// ONE MARK, ANSWERING BOTH QUESTIONS. The leading dot is the session's identity
/// — its theme accent, the same colour its canvas and terminal use — and it is
/// also the session's state, in its shape and its motion. The row carried a
/// second, trailing mark for state until 2026-07-26, and the operator's verdict on it was
/// "there's just too much clutter and it doesn't mean anything": two marks per
/// row is two things to read where the row has one thing to say.
///
/// A session with no live agent — stopped, killed, or never started — reads as
/// off: the name greys and the identity dot dims. That is the state the operator asked to
/// be legible, "turning the rail entry gray," and the Start affordance for it
/// lives in the pane, not here.
struct RailRow: View {
    let crew: Crew
    let isSelected: Bool
    /// The same theme the terminal canvas uses for this session, so the dot
    /// beside a name and the canvas it opens are provably the same colour.
    let accent: RGB
    /// Resolved by the shell and handed down, per the appearance-authority rule.
    let appearance: Appearance
    /// The Builder Default ground this row is drawn on, set by the shell's pin.
    @Environment(\.statusGround) private var statusGround
    /// What this session's state draws, resolved by the shell.
    ///
    /// A MARK RATHER THAN A PHASE, because the mark is no longer a function of
    /// the phase alone: a co at its prompt draws a square or a pulsing circle
    /// depending on whether dispatched agents are alive behind it, and the row
    /// has no business knowing about `active.json`. An unpolled session resolves
    /// to `.unpolled`, which claims nothing rather than asserting `.ready`.
    let mark: SessionState.Mark
    /// Whether the mini has told us this session has no agent. Greys the row.
    /// Distinct from "not yet polled": an unpolled row is drawn live-looking
    /// rather than greyed, so the rail does not flash grey on every launch.
    let isStopped: Bool
    let themeMenu: () -> AnyView
    /// Non-nil only for a crew row that has pinned sibling sessions — see
    /// `Disclosure`. A row with no children draws no chevron at all.
    var disclosure: Disclosure? = nil
    /// A collapsed parent's summons source: the mark of whichever pinned
    /// child needs an answer, or nil when none does or the row is expanded.
    /// Combined with the row's own `mark` in `effectiveSummonsSource` so "a
    /// folded crew cannot hide a summons" (design §E) without the dot
    /// itself claiming the parent's own conversation needs a reply.
    var childSummonsMark: SessionState.Mark? = nil
    /// "Rename…", offered only on a crew row. Changes `displayName` only —
    /// never the crew `id`, which is the tmux session name every
    /// `SessionRef` and argv builder keys on. See
    /// `ThemeStore.renameCrew`'s doc comment for why "rename" reads as
    /// renaming the crew when it actually only relabels the row.
    var onRename: (() -> Void)? = nil
    /// "Remove from Deck…", offered only on a crew row — see
    /// `deck/specs/multiple-sessions-per-project` §"Remove". Nil on a child
    /// row, which has no config row of its own to remove.
    var onRemove: (() -> Void)? = nil
    /// How far this row indents beyond its own leading padding — 0 for a
    /// top-level crew, `RailChildRow.indent` for a nested one (design
    /// §"The rail": a nested crew draws "at the child indent"). Mirrors
    /// `RailChildRow.indent`, since a nested crew is still a full crew row.
    var indent: CGFloat = 0
    /// "Nest under ▸"'s targets — `RailNesting.eligibleParents`, resolved
    /// by the shell. Empty means the menu item is omitted rather than shown
    /// disabled.
    var eligibleParents: [Crew] = []
    /// "Nest under <parent>" or "Move to Top Level" was chosen — carries
    /// the new `parent` value, nil for "Move to Top Level". The shell owns
    /// the config write, the same division every other destructive or
    /// structural action here already follows.
    var onSetParent: ((String?) -> Void)? = nil
    /// "user@machine" for this crew's resolved host — `HostDisplay.crewLabel`,
    /// resolved by the shell. Nil unless this row's name is drawn by more
    /// than one entry on the rail right now, so an ordinary install with no
    /// name collision draws nothing extra here. Drawn beside the name AND
    /// repeated in the context menu — see `body`.
    var hostLabel: String? = nil
    /// Two conditions share this one slot, resolved by the shell and never
    /// both non-nil for the same crew: either this crew's `host` names
    /// something the table no longer has
    /// (`HostDisplay.unresolvedHostWarning`; see
    /// `deck/specs/multiple-sessions-per-project` §"Warn when a crew's host
    /// names nothing" — the fallback stays exactly as it is, this only adds
    /// visibility), or the host resolves fine but its most recent poll
    /// could not reach it at all (`HostDisplay.unreachableWarning`; see
    /// `issue_01M23WC488NVYT6T5MDZN37ZBR`).
    var hostWarning: String? = nil
    /// True in the 44pt dot rail — `design/redesign/04-narrow.html`: "names
    /// go, marks stay." Drops the name, the disclosure control, and the
    /// host-warning glyph, none of which fit in 44pt; the mark, the
    /// selection wash, and the summons bar are unchanged, since those are
    /// exactly what the dot rail exists to keep legible. The name moves to
    /// `.help()` instead of disappearing outright — `RailView`'s doc on
    /// `suppressesNumberShortcuts` notes a collapsed "OTHER SESSIONS" or
    /// "START" row has no Cmd-1…9 shortcut either, so hover is its only way
    /// to learn what it is.
    var isCollapsed: Bool = false
    /// The context meter's reading for this session, or nil to draw none —
    /// see `ContextMeter`. Resolved by the shell, like `mark`.
    var meter: ContextMeter? = nil
    /// The rollover overrides this row's menu offers (`ContextMeter.actions`).
    var rolloverActions: [SessionAgent.RolloverAction] = []
    /// An override was chosen. The shell owns the confirm for `force` and the
    /// `session-agent rollover` call, the same division `onRemove` follows.
    var onRollover: ((SessionAgent.RolloverAction) -> Void)? = nil
    /// Set when one of this session's live runs is off its roster model, from
    /// the run register — see `RunModelMark`. Nil draws nothing, which is also
    /// what a register that cannot be read leaves.
    var runModelMark: RunModelMark? = nil
    /// This crew's Slate badge reading — `nil` before the first poll or on a
    /// mini that predates the field; see `SlateBadge.isVisible` for when that
    /// actually draws something. CREW ROWS ONLY: a pinned or discovered child
    /// shares its crew's tmux session and so its crew's own Slate, which is
    /// why `RailChildRow` carries no such field at all — see
    /// issue_01M3WPYSH0S1FZVZ6P3YMNJGXW.
    var asksOpen: SessionState.AsksOpen? = nil
    /// The badge was clicked. The shell owns opening the cockpit on this
    /// crew's Slate — the same division every other click-through here
    /// follows. Nil draws the badge with no click target, which `isCollapsed`
    /// already keeps it out of entirely.
    var onOpenSlate: (() -> Void)? = nil

    /// Every row in the rail — a crew, a child, a window leaf, a catalog
    /// entry — draws at this height. `design/redesign/03-rail.html`: "216pt,
    /// 26pt rows, 13pt names." Fixed rather than derived from padding, so
    /// `RailChildSpine` can place its endpoints without measuring a row that
    /// has not laid out yet.
    static let rowHeight: CGFloat = 26

    /// The expanded row's leading padding, chosen so a crew's dot does not move
    /// when the rail expands or collapses. The plain `List` adds 10pt of its own
    /// on each side, so a collapsed row (44pt rail) centres its 10pt dot at
    /// x 22, and 10 + 7 puts the expanded dot at x 17–27, centred on the same
    /// x 22 (the operator, 2026-10-09: the dots should hold still for a cleaner
    /// transition). Child rows, window leaves, the meter and the child spine
    /// all start from this value, so their indents are unchanged relative to it.
    static let leadingPadding: CGFloat = 7

    /// Where the dot column's centre sits in the rail, in either state. The
    /// Builder ship mark in the band above centres on it.
    static let dotColumnCenterX: CGFloat = 22

    /// The row's one tooltip: the context meter's line, then the run-model
    /// mark's sentences when a mark is drawn.
    ///
    /// ONE `.help` FOR THE WHOLE ROW, NOT ONE ON THE GLYPH. The row sets
    /// `.help` on its full frame, and on macOS that outer tooltip is what a
    /// hover over the glyph shows. The operator hovered the first live override mark
    /// on 2026-09-24 and got "49% of context", never the mark's text, which
    /// was attached to `RunModelMarkGlyph` inside the row. So the mark's text
    /// rides in the row's own tooltip.
    nonisolated static func rowHelp(isCollapsed: Bool, name: String,
                                    meterHelp: String?, markHelp: String?) -> String {
        if isCollapsed { return name }
        return [meterHelp, markHelp]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// A collapsed crew row's disclosure control: the child count shown
    /// only while collapsed (an expanded row's children are already visible,
    /// so the count would be redundant), and the toggle itself.
    struct Disclosure {
        let childCount: Int
        let isExpanded: Bool
        let onToggle: () -> Void
    }

    /// What the mark is drawn over, which is what its ink must be solved
    /// against.
    ///
    /// A PURE FUNCTION, so a test can assert what the VIEW passes rather than
    /// only what the solver returns. The first version hardcoded the light
    /// surface in both appearances: the sweep test passed, because it solved
    /// each ink against the correct surface per appearance, while the view
    /// handed the solver a light surface in dark mode and drew ~2.7:1 on the
    /// rail. A test that exercises the machinery and not the call site is
    /// exactly the gap that shipped an unwired composer parameter one PR ago.
    ///
    /// TAKES THE SHELL'S RESOLVED APPEARANCE, not `@Environment(\.colorScheme)`.
    /// Nothing here sets `preferredColorScheme`, so the environment reports the
    /// SYSTEM appearance while Deck resolves its own from config — which can pin
    /// light or dark. Reading the environment would keep the same bug for anyone
    /// who has pinned an appearance the system disagrees with, and it would
    /// break the rule that the shell is the single appearance authority.
    ///
    /// `ground` is the Builder Default ground when the row is drawn on one. It
    /// replaces the hand-written approximation below, so the marks are solved
    /// against the colour that is actually drawn.
    nonisolated static func markBacking(appearance: Appearance,
                                        isSelected: Bool, accent: RGB,
                                        ground: RGB? = nil) -> RGB {
        let base = ground ?? (appearance == .dark
            ? RGB(red: 0.16, green: 0.16, blue: 0.17)
            : RGB(red: 0.92, green: 0.92, blue: 0.93))
        guard isSelected else { return base }
        // The selection wash is the session's own accent at 0.15, so a selected
        // row is the harder surface — an accent-coloured mark could vanish into
        // it, which is why this is the case the sweep has to cover.
        return RGB(red: base.red + (accent.red - base.red) * 0.15,
                   green: base.green + (accent.green - base.green) * 0.15,
                   blue: base.blue + (accent.blue - base.blue) * 0.15)
    }

    private var backing: RGB {
        RailRow.markBacking(appearance: appearance, isSelected: isSelected, accent: accent,
                            ground: statusGround)
    }

    /// The ink for the summons bar down the row's leading edge, or nil when the
    /// row is not asking for anything.
    ///
    /// WHY THE ROW CARRIES THIS AND NOT THE DOT. The operator, on the shipped triangle:
    /// "the only thing not quite right is that the triangle doesn't really call
    /// for attention." There is a mechanical reason. A triangle inscribed in a
    /// box holds about 64% of the ink of a circle in the same box — 2r² against
    /// πr² — so at equal size it is structurally the faintest shape in the set,
    /// and it is asking to be found among a dozen other coloured dots that are
    /// all competing at the same x position.
    ///
    /// A bar at the leading edge has no competition, because nothing else in the
    /// rail is drawn there. The division that follows is the point: the DOT says
    /// what a row is doing, the BAR says look at this one. Asking a ten-point
    /// mark to do both is what was failing.
    ///
    /// RAIL ONLY. The pane draws one session and has nothing to be found among,
    /// so the bar would be decoration there.
    ///
    /// A PURE FUNCTION, so the decision is testable without a view. It carries
    /// the staleness ramp too, which means the bar deepens as the gate ages on
    /// the same schedule the dot does rather than on a second one.
    nonisolated static func summonsInk(mark: SessionState.Mark,
                                       isStopped: Bool, on surface: RGB) -> RGB? {
        // A stopped session is not summoning anyone. Its dot dims for the same
        // reason, and a bar shouting on a row whose agent is gone would send the
        // reader somewhere there is nothing to answer.
        guard !isStopped, case .needsYou(let gateAge) = mark else { return nil }
        return ThemeRecipe.attentionInk(
            on: surface, staleness: ThemeRecipe.staleness(gateAge: gateAge))
    }

    /// Which mark should decide a row's summons bar: its own, when that is
    /// already asking for something, or — failing that — a collapsed
    /// crew's child's. This is the rule from design §"Attention": "a
    /// folded crew cannot hide a summons," and expanded the child gets its
    /// own row and its own bar instead (the caller simply passes nil for
    /// `collapsedChildNeedingAttention` on an expanded row).
    ///
    /// A PURE FUNCTION so the precedence — own state first — is pinned by a
    /// test rather than left to draw order in the view.
    nonisolated static func effectiveSummonsSource(
        own: SessionState.Mark, ownStopped: Bool,
        collapsedChildNeedingAttention: SessionState.Mark?
    ) -> (mark: SessionState.Mark, isStopped: Bool) {
        if !ownStopped, case .needsYou = own { return (own, false) }
        if let child = collapsedChildNeedingAttention { return (child, false) }
        return (own, ownStopped)
    }

    var body: some View {
        HStack(spacing: 8) {
            // TEN POINTS, UP FROM EIGHT. It carries two jobs now instead of one,
            // and the shapes that distinguish the states — a notch in a disc, a
            // square's corners — need the room to be read as shapes rather than
            // as slightly different blobs.
            SessionDotView(mark: mark, accent: accent, surface: backing,
                           size: 10, isDimmed: isStopped)
            if !isCollapsed {
                Text(crew.displayName)
                    .frameFont(.primary)
                    .foregroundStyle(isStopped ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                // Which box THIS ONE is — drawn only when another entry on
                // the rail shares this name, per `hostLabel`'s own doc.
                if let hostLabel {
                    Text(hostLabel)
                        .frameFont(.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // A stale `host` reference is worth flagging regardless of how
                // many hosts are configured — see `hostWarning`'s doc. `.help`
                // carries the reason on hover; the same text is repeated in the
                // context menu below for a reader who never hovers.
                if let hostWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help(hostWarning)
                }
                Spacer(minLength: 0)
                if let runModelMark {
                    RunModelMarkGlyph(mark: runModelMark, surface: backing)
                }
                if let meter, meter.glyph != .none {
                    ContextMeterGlyph(glyph: meter.glyph, surface: backing)
                }
                if let asksOpen, SlateBadge.isVisible(asksOpen) {
                    Button(action: { onOpenSlate?() }) {
                        SlateBadgeGlyph(asksOpen: asksOpen, surface: backing)
                    }
                    .buttonStyle(.plain)
                    .help(SlateBadge.accessibilityLabel(for: asksOpen))
                    .accessibilityLabel(SlateBadge.accessibilityLabel(for: asksOpen))
                }
                // TRAILING, NOT LEADING. Every identity dot sits at one x
                // position, and the summons bar owns the leading edge precisely
                // because nothing else in the rail is drawn there — a leading
                // chevron would either indent a parent's dot out of that shared
                // column or fight the bar for the same edge. The trailing edge
                // carries nothing today, so the chevron and count cost no
                // existing signal (design §E).
                if let disclosure {
                    Button(action: disclosure.onToggle) {
                        HStack(spacing: 3) {
                            if !disclosure.isExpanded {
                                Text("\(disclosure.childCount)")
                                    .frameFont(.label)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: disclosure.isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.leading, isCollapsed ? 0 : RailRow.leadingPadding + indent)
        .padding(.trailing, isCollapsed ? 0 : 12)
        .frame(maxWidth: isCollapsed ? .infinity : nil)
        .frame(height: RailRow.rowHeight)
        .help(RailRow.rowHelp(isCollapsed: isCollapsed, name: crew.displayName,
                              meterHelp: meter?.help, markHelp: runModelMark?.help))
        // The context meter, under the name and out of the dot's column. Not
        // drawn in the 44pt dot rail, which keeps only the mark and the bar.
        .overlay(alignment: .bottomLeading) {
            if let meter, !isCollapsed {
                ContextMeterTrack(meter: meter, surface: backing)
                    .padding(.leading, RailRow.leadingPadding + indent + 18)
                    .padding(.trailing, 12)
                    // Two points up, not three: at three a descender in the
                    // 13pt name ("shipwright") touched the track when rendered.
                    .padding(.bottom, 2)
            }
        }
        // THE ROW'S OWN ACCENT, not the system blue. Every other identity
        // signal in this app — the dot beside the name, the pane's frame tint,
        // the terminal canvas — draws from the session's theme, so a blue
        // selection wash beside a gold dot said the selection belonged to
        // something other than the session it selected.
        .background(isSelected ? Color(accent).opacity(0.15) : Color.clear)
        // FLUSH TO THE LEADING EDGE, FULL HEIGHT, and drawn over the selection
        // wash rather than under it. Those three together are what make it
        // findable: it is the only thing in the rail at that x, it is a tall
        // target rather than a ten-point one, and a selected row cannot mute it.
        .overlay(alignment: .leading) {
            let source = RailRow.effectiveSummonsSource(
                own: mark, ownStopped: isStopped,
                collapsedChildNeedingAttention: childSummonsMark)
            // A parked session (`ContextMeter.summons`) asks for a person the
            // same way a gate does, whichever of the four reasons parked it —
            // not only a failed successor spawn.
            if let ink = RailRow.summonsInk(mark: source.mark, isStopped: source.isStopped, on: backing)
                ?? (meter?.summons == true && !isStopped ? ThemeRecipe.attentionInk(on: backing) : nil) {
                Rectangle()
                    .fill(Color(ink))
                    .frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            // "Which box is this on" is always answerable without hunting
            // — see `deck/specs/multiple-sessions-per-project` §"Where it
            // is drawn". A plain `Text`, not a `Button`: this is a label,
            // not an action.
            if let hostLabel {
                Text(hostLabel)
                Divider()
            }
            if let hostWarning {
                Text(hostWarning)
                Divider()
            }
            RolloverMenuItems(meter: meter, actions: rolloverActions, onRollover: onRollover)
            themeMenu()
            if let onRename {
                Divider()
                Button("Rename…", action: onRename)
            }
            if let onSetParent, !eligibleParents.isEmpty || crew.parent != nil {
                Divider()
                if !eligibleParents.isEmpty {
                    Menu("Nest under") {
                        ForEach(eligibleParents) { parent in
                            Button(parent.displayName) { onSetParent(parent.id) }
                        }
                    }
                }
                if crew.parent != nil {
                    Button("Move to Top Level") { onSetParent(nil) }
                }
            }
            if let onRemove {
                Divider()
                Button("Remove from Deck…", role: .destructive, action: onRemove)
            }
        }
    }
}
