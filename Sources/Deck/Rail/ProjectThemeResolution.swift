import Foundation

/// Which served crew speaks for a project's theme, and what that crew's
/// theme resolves to — CQ·211, the project-theme half of
/// `ThemePublisher.publish`.
enum ProjectThemeResolution {
    /// One project's resolved theme, ready for `PUT /projects/{slug}/theme`.
    struct Resolved: Equatable {
        let slug: String
        let theme: String
        let source: String
    }

    /// One served crew per project, out of `crews` — the crew whose served
    /// spec names that project.
    ///
    /// `crews` MUST ALREADY BE NARROWED TO THE ONE HOST `ThemePublisher` is
    /// about to write to. This makes no host comparison of its own — see
    /// `ThemePublisher.publish`'s doc for why.
    ///
    /// ON A TIE, THE CREW WHOSE ID EQUALS THE SLUG WINS; OTHERWISE THE FIRST
    /// BY SORTED ID (comment 7443 on issue_01M7G7W6JJ7XHSD5ACZ32X2A09). A
    /// project with only one served crew never reaches the tiebreak at all.
    static func resolved(from crews: [ServedCrew]) -> [Resolved] {
        var byProject: [String: [ServedCrew]] = [:]
        for crew in crews {
            let slug = (crew.project ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty else { continue }
            byProject[slug, default: []].append(crew)
        }
        // Sorted so the result (and therefore the order `ThemePublisher`
        // sends in) does not depend on `crews`' own incoming order, which a
        // dictionary-backed merge like `RailStateModel.servedCrews` does not
        // promise to hold stable.
        return byProject.keys.sorted().map { slug in
            let candidates = byProject[slug]!
            let primary = candidates.first(where: { $0.crewId == slug })
                ?? candidates.sorted(by: { $0.crewId < $1.crewId })[0]
            let (theme, source) = resolvedTheme(for: primary)
            return Resolved(slug: slug, theme: theme, source: source)
        }
    }

    /// `crew.theme` when the served spec set one, with source `"crews-d"`;
    /// otherwise `ThemeCatalog.defaultTheme(forSession:)`'s hashed name,
    /// with source `"hash"`.
    ///
    /// READS `ServedCrew.theme` DIRECTLY RATHER THAN THROUGH
    /// `ThemeConfiguration.theme(forSession:)` — that function also mixes in
    /// an explicit pick from the laptop's own `theme.json`, which this must
    /// never do (the issue body: "never the laptop's theme.json pick"; a
    /// published theme is this crew's identity for every Deck install
    /// talking to the same Library, not this one laptop's personal
    /// override). `ServedCrew.theme` is already validated against
    /// `ThemeCatalog.named` at decode time, so a non-nil value here always
    /// names a real catalog theme.
    static func resolvedTheme(for crew: ServedCrew) -> (theme: String, source: String) {
        if let theme = crew.theme {
            return (theme, "crews-d")
        }
        return (ThemeCatalog.defaultTheme(forSession: crew.crewId).name, "hash")
    }
}
