import CryptoKit
import Foundation

/// Deck's theme catalog, encoded as the Library's `PUT /themes/palette` body
/// — CQ·211, so Orient can draw a project's site in that project's own Deck
/// colour.
///
/// THE SHAPE IS THE LIBRARY'S, NOT A GUESS: `{catalog, themes}`, `themes`
/// keyed by exactly the ten `ThemeCatalog.all` names, each `{light, dark}`,
/// each of those exactly `{accent, on_accent, wash, on_wash}` — confirmed
/// against the deployed route (library#380 at 89a101f82, comment 7443 on
/// issue_01M7G7W6JJ7XHSD5ACZ32X2A09). Any other key at any level is a 400.
enum ThemeLibraryPalette {
    /// The label this catalog is sent under. Deck ships exactly one
    /// catalog, so this is a fixed string rather than anything computed.
    static let catalogLabel = "deck-catalog-1"

    /// `{name: {light: {...}, dark: {...}}}` for every theme in
    /// `ThemeCatalog.all` — `ThemeCatalog.graphite` is deliberately excluded,
    /// the same way it is excluded from `all` itself: it is the laptop's own
    /// unthemed shell, not one of the ten crew colours the Library's catalog
    /// names.
    static func themes() -> [String: Any] {
        var out: [String: Any] = [:]
        for theme in ThemeCatalog.all {
            out[theme.name] = [
                "light": appearance(theme.light, .light),
                "dark": appearance(theme.dark, .dark),
            ]
        }
        return out
    }

    /// One `{accent, on_accent, wash, on_wash}` entry.
    ///
    /// `accent` AND `on_accent` ARE A PAIR: section 6.10 defines `on_accent`
    /// as "the text drawn on" the accent, so the two must be legible
    /// together. Deck's only filled accent surface is the composer's Send
    /// slab: white text on `ThemeRecipe.accentFillInk`, which is solved to
    /// text contrast against white from the theme's hue. That pair is what
    /// this sends, so Orient draws an accent fill exactly as Deck does. The
    /// raw `cursor` swatch is solved against the theme's canvas, not against
    /// any text, so it has no text colour of its own to send.
    /// `accentFillInk` reads only the hue, so light and dark carry the same
    /// pair.
    ///
    /// `wash` IS `SessionPaneView.frameTintRGB` — the session pane's own
    /// frame-strip tint, the one tinted background this app already draws
    /// per accent and per appearance, rather than a second formula invented
    /// for this route. `on_wash` is `ThemeRecipe.primaryTextInk`, the ink
    /// `ColumnBand.neutralInk` already draws text in on that exact kind of
    /// surface (a frame tint under Builder Default) — `solveLightness`
    /// underneath it picks the correct walk direction for either appearance,
    /// so the same call serves both.
    private static func appearance(_ palette: TerminalPalette, _ appearance: Appearance) -> [String: String] {
        let accent = palette.cursor
        let wash = SessionPaneView.frameTintRGB(canvas: accent.hexString, appearance: appearance) ?? accent
        return [
            "accent": ThemeRecipe.accentFillInk(accent: accent).hexString,
            "on_accent": "#ffffff",
            "wash": wash.hexString,
            "on_wash": ThemeRecipe.primaryTextInk(on: wash).hexString,
        ]
    }

    /// SHA-256 hex of `themes` serialised with sorted keys and no
    /// whitespace — the Library's own digest formula (comment 7443).
    ///
    /// DECK CANNOT READ THE LIBRARY'S STORED DIGEST BACK: `GET
    /// /themes/palette` is gated on `registry.read`, which Deck's credential
    /// does not hold. So `ThemePublisher` computes this locally instead of
    /// the digest-gate the issue body originally described, and resends the
    /// palette only when ITS OWN reading of this changes — which, since
    /// `themes()` is a pure function of the compiled-in catalog, is never,
    /// short of a future catalog change. `JSONSerialization` without
    /// `.prettyPrinted` already omits whitespace; `.sortedKeys` is what
    /// makes the bytes independent of `themes()`'s own dictionary-iteration
    /// order.
    static func digest(_ themes: [String: Any]) -> String {
        let canonical = (try? JSONSerialization.data(withJSONObject: themes, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}
