import XCTest
@testable import Deck

/// `ThemeLibraryPalette` — the `PUT /themes/palette` encoder and digest
/// formula, CQ·211.
final class ThemeLibraryPaletteTests: XCTestCase {
    private func isLowercaseHex(_ value: String) -> Bool {
        guard value.hasPrefix("#"), value.count == 7 else { return false }
        return value.dropFirst().allSatisfy { "0123456789abcdef".contains($0) }
    }

    func testThemesHasExactlyTheTenCatalogNames() {
        let themes = ThemeLibraryPalette.themes()
        XCTAssertEqual(Set(themes.keys), Set(ThemeCatalog.all.map(\.name)))
        XCTAssertEqual(themes.count, 10)
    }

    /// `ThemeCatalog.graphite` — the laptop's own unthemed shell — is not one
    /// of the ten and must never show up in the published catalog.
    func testGraphiteIsNotPublished() {
        XCTAssertNil(ThemeLibraryPalette.themes()[ThemeCatalog.graphite.name])
    }

    /// Every theme's every appearance carries exactly the four required keys,
    /// each a lower-case `#rrggbb` — the shape and the hex-encoding rule
    /// `PUT /themes/palette` refuses anything else against (comment 7443 on
    /// issue_01M7G7W6JJ7XHSD5ACZ32X2A09).
    func testEveryThemeHasExactlyLightAndDarkEachWithFourLowerCaseHexValues() throws {
        let themes = ThemeLibraryPalette.themes()
        for theme in ThemeCatalog.all {
            let entry = try XCTUnwrap(themes[theme.name] as? [String: Any], theme.name)
            XCTAssertEqual(Set(entry.keys), ["light", "dark"], theme.name)
            for appearanceKey in ["light", "dark"] {
                let appearance = try XCTUnwrap(entry[appearanceKey] as? [String: String],
                                               "\(theme.name) \(appearanceKey)")
                XCTAssertEqual(Set(appearance.keys), ["accent", "on_accent", "wash", "on_wash"],
                              "\(theme.name) \(appearanceKey)")
                for (key, value) in appearance {
                    XCTAssertTrue(isLowercaseHex(value), "\(theme.name) \(appearanceKey) \(key) = \(value)")
                }
            }
        }
    }

    /// No stray mixed-case survives a real recipe's output either — pinned
    /// against one real theme's one real swatch, not only the format check
    /// above, so a future change to `RGB.hexString` that started
    /// upper-casing would fail here too.
    func testOneRealThemesAccentIsLowerCase() throws {
        let gold = try XCTUnwrap(ThemeCatalog.named("gold"))
        let accent = gold.light.cursor.hexString
        XCTAssertEqual(accent, accent.lowercased())
        XCTAssertTrue(isLowercaseHex(accent))
    }

    /// Section 6.10 defines `on_accent` as the text drawn on `accent` and
    /// `on_wash` as the ink drawn on `wash`, so each pair must be legible.
    /// Fails if `accent` reverts to the canvas-solved `cursor`, or if
    /// `on_accent` becomes a second accent rather than a text colour.
    func testEveryPairIsLegibleAtTextContrast() throws {
        let themes = try XCTUnwrap(ThemeLibraryPalette.themes() as? [String: [String: [String: String]]])
        for (name, modes) in themes {
            for (mode, colors) in modes {
                for (fill, ink) in [("accent", "on_accent"), ("wash", "on_wash")] {
                    let f = try XCTUnwrap(colors[fill].flatMap { parseHexColor(String($0.dropFirst())) })
                    let i = try XCTUnwrap(colors[ink].flatMap { parseHexColor(String($0.dropFirst())) })
                    XCTAssertGreaterThanOrEqual(i.contrastRatio(against: f), ThemeRecipe.minimumTextContrast,
                                                "\(name) \(mode): \(ink) on \(fill) is not legible")
                }
            }
        }
    }

    /// SHA-256 of `themes` as sorted-key, no-whitespace JSON — the Library's
    /// own formula (comment 7443). The expected hex below is independently
    /// computed: `printf '%s' '<the exact JSON string>' | shasum -a 256`.
    func testDigestMatchesTheLibrarysFormulaOnAFixedVector() {
        let themes: [String: Any] = [
            "ember": [
                "dark": ["accent": "#112233", "on_accent": "#445566", "on_wash": "#aabbcc", "wash": "#778899"],
                "light": ["accent": "#112233", "on_accent": "#445566", "on_wash": "#aabbcc", "wash": "#778899"],
            ],
        ]
        XCTAssertEqual(ThemeLibraryPalette.digest(themes),
                       "90d7bccdefb2c4a9e3183cf344d8922fda9fe87e9c8f43c4224873e4500dcb79")
    }

    /// `digest` depends only on the bytes, not on dictionary-iteration
    /// order: the Swift literal above and a differently-ordered construction
    /// of the identical content must agree.
    func testDigestIsIndependentOfInsertionOrder() {
        var themes: [String: Any] = [:]
        themes["ember"] = [
            "light": ["accent": "#112233", "on_accent": "#445566", "on_wash": "#aabbcc", "wash": "#778899"],
            "dark": ["wash": "#778899", "on_wash": "#aabbcc", "accent": "#112233", "on_accent": "#445566"],
        ]
        XCTAssertEqual(ThemeLibraryPalette.digest(themes),
                       "90d7bccdefb2c4a9e3183cf344d8922fda9fe87e9c8f43c4224873e4500dcb79")
    }

    /// `digest` is a pure function of its argument: calling it twice on the
    /// real catalog agrees with itself, which is what lets `ThemePublisher`
    /// treat an unchanged digest as "nothing to resend."
    func testDigestIsStableAcrossCalls() {
        let themes = ThemeLibraryPalette.themes()
        XCTAssertEqual(ThemeLibraryPalette.digest(themes), ThemeLibraryPalette.digest(themes))
    }

    func testCatalogLabelIsNamedAndWithinTheLibrarysBound() {
        XCTAssertFalse(ThemeLibraryPalette.catalogLabel.isEmpty)
        XCTAssertLessThanOrEqual(ThemeLibraryPalette.catalogLabel.count, 64)
    }
}
