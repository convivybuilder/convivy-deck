import SwiftUI

/// The crew rail row's count of asks waiting on the operator —
/// issue_01M3WPYSH0S1FZVZ6P3YMNJGXW, Deck's slice of the Slate epic
/// (issue_01M3WPJC2790N8JM8MGR7BQ5RJ). Pure logic, split from
/// `SlateBadgeGlyph`'s drawing the same way `RailRow.summonsInk` is split
/// from the row, so the rule is testable without a view.
enum SlateBadge {
    /// Whether the row draws anything at all. A `.count` draws only above
    /// zero — the item's own wording, "when it is above zero" — but
    /// `.unknown` always draws, whatever `asks_open` carried alongside
    /// `slate_error`: a zero the mini could not vouch for must read as doubt,
    /// never as the calm a hidden badge would claim.
    static func isVisible(_ asksOpen: SessionState.AsksOpen?) -> Bool {
        switch asksOpen {
        case nil: return false
        case .unknown: return true
        case .count(let n): return n > 0
        }
    }

    /// The glyph's own text — a bare digit for a count, `?` for a reading
    /// the mini could not establish.
    static func label(for asksOpen: SessionState.AsksOpen) -> String {
        switch asksOpen {
        case .unknown: return "?"
        case .count(let n): return "\(n)"
        }
    }

    /// What VoiceOver says for the row — the item's own "the row's
    /// accessibility label names the count."
    static func accessibilityLabel(for asksOpen: SessionState.AsksOpen) -> String {
        switch asksOpen {
        case .unknown: return "Slate state unknown"
        case .count(let n): return n == 1 ? "1 ask waiting on you" : "\(n) asks waiting on you"
        }
    }

    /// A folded group's own badge: the sum of its members' — E24's "the
    /// summed badge beside it." `nil` members (never polled) are skipped
    /// rather than zeroed, the same degrade every other per-session reading
    /// here gets; `nil` overall means no member has anything to show, which
    /// draws no badge at all, matching a single row with nothing to show.
    /// ANY member reading `.unknown` makes the sum `.unknown` too — a doubt
    /// about even one member's count is a doubt about the group's total,
    /// the same reason `.unknown` always draws on a single row regardless
    /// of what else is known.
    static func summed(_ members: [SessionState.AsksOpen?]) -> SessionState.AsksOpen? {
        var total = 0
        var sawUnknown = false
        var sawAny = false
        for member in members {
            guard let member else { continue }
            sawAny = true
            switch member {
            case .unknown: sawUnknown = true
            case .count(let n): total += n
            }
        }
        guard sawAny else { return nil }
        return sawUnknown ? .unknown : .count(total)
    }
}

/// The badge's drawing — sized and weighted like `RunModelMarkGlyph`, the
/// rail's other small trailing mark.
///
/// TWO INKS FOR THE SAME REASON `RunModelMarkGlyph` HAS TWO: a count is a
/// summons, so it draws in the same text-weight attention ink the rail's
/// other "needs you" badges use; `.unknown` is a caution rather than a
/// summons — nothing is confirmed waiting, only unreadable — so it draws in
/// the quieter warning ink instead.
struct SlateBadgeGlyph: View {
    let asksOpen: SessionState.AsksOpen
    /// What the badge is drawn over — see `RailRow.backing`'s own doc for why
    /// an ink is always solved against its real surface rather than assumed.
    let surface: RGB

    /// A pure function, so the ink choice is testable without a view —
    /// `RunModelMarkGlyph`'s own `symbolName(for:)` is the same split.
    static func ink(for asksOpen: SessionState.AsksOpen, on surface: RGB) -> RGB {
        switch asksOpen {
        case .unknown: return ThemeRecipe.warningInk(on: surface)
        case .count: return ThemeRecipe.attentionTextInk(on: surface)
        }
    }

    /// The group heading's own ink for its summed total — CQ·192: a
    /// `.count` draws in `ThemeRecipe.groupAskTotalInk` rather than `ink`'s
    /// own `attentionTextInk`, so the heading's total reads as a different
    /// kind of number from a member row's own count beside it. `.unknown`
    /// stays `warningInk`, the same doubt a single row reads with.
    static func groupTotalInk(for asksOpen: SessionState.AsksOpen, on surface: RGB) -> RGB {
        switch asksOpen {
        case .unknown: return ThemeRecipe.warningInk(on: surface)
        case .count: return ThemeRecipe.groupAskTotalInk(on: surface)
        }
    }

    var body: some View {
        Text(SlateBadge.label(for: asksOpen))
            .frameFont(.label)
            .fontWeight(.semibold)
            .foregroundStyle(Color(SlateBadgeGlyph.ink(for: asksOpen, on: surface)))
            // The row's own tooltip and accessibility label carry the full
            // sentence — see `RailRow.body`'s `.help`/`.accessibilityLabel` —
            // the same reason `RunModelMarkGlyph` sets neither on itself.
    }
}
