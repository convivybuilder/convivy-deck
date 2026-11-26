import SwiftUI

/// One refusal line, in the pull request ladder row's own idiom
/// (`CockpitView.pullRequestRow`): a leading glyph, baseline-aligned with
/// the first line of text, then the message. The glyph carries the cause —
/// `MergeRefusal.glyphName` — so the row tells its six-plus-one causes apart
/// by shape as well as by ink, never by colour alone.
///
/// A standalone view rather than a `CockpitView` method, since
/// `issue_01M1372GW0EHM5BYKHAD5ZZ1D9` builds only the line itself; the
/// later item that presses merge (E11·3) mounts this wherever its result
/// needs to draw.
struct MergeRefusalRow: View {
    let refusal: MergeRefusal
    let appearance: Appearance

    /// The same "no canvas" fallback `CockpitView.indexSurface` uses — this
    /// row has no session canvas or accent of its own either.
    private var surface: RGB {
        CockpitView.resolvedIndexSurface(appearance: appearance)
    }

    private var ink: AnyShapeStyle {
        switch refusal.severity {
        case .neutral:
            return CockpitView.secondaryInkStyle(on: surface)
        case .caution:
            return AnyShapeStyle(Color(ThemeRecipe.warningInk(on: surface)))
        case .failure:
            return AnyShapeStyle(Color(ThemeRecipe.errorInk(on: surface)))
        case .invitation:
            return AnyShapeStyle(Color(ThemeRecipe.attentionTextInk(on: surface)))
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Same 14pt leading column `pullRequestRow`'s stoplight dot
            // draws in, so a refusal line reads as the same shape of row.
            Image(systemName: refusal.glyphName)
                .frameFont(.icon)
                .foregroundStyle(ink)
                .frame(width: 14, alignment: .center)
            Text(refusal.message)
                .frameFont(.body)
                .foregroundStyle(ink)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(refusal.message)
    }
}
