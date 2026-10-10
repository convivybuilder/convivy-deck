import Foundation

/// The themes Deck ships with, spread evenly enough around the hue wheel that
/// adjacent sessions in the rail stay tellable apart.
///
/// Names are colors, deliberately, never crews. A theme table keyed to
/// Convivy's own session names would be unreadable and uneditable for anyone
/// else running Deck; the crew-to-theme mapping belongs in user config
/// (`ThemeConfiguration`), where a user names their own sessions.
enum ThemeCatalog {
    static let all: [TerminalTheme] = [
        ThemeRecipe.theme(named: "ember", hue: 29),
        ThemeRecipe.theme(named: "amber", hue: 68),
        ThemeRecipe.theme(named: "gold", hue: 95),
        ThemeRecipe.theme(named: "sage", hue: 145),
        ThemeRecipe.theme(named: "teal", hue: 178),
        ThemeRecipe.theme(named: "cyan", hue: 205),
        ThemeRecipe.theme(named: "azure", hue: 240),
        ThemeRecipe.theme(named: "indigo", hue: 275),
        ThemeRecipe.theme(named: "violet", hue: 305),
        ThemeRecipe.theme(named: "rose", hue: 350),
    ]

    /// The laptop's own theme: the shipped recipe at zero chroma, so Local reads
    /// as the machine it runs on rather than as a crew. It sits OUTSIDE `all`
    /// on purpose. `defaultTheme(forSession:)` indexes `all` by hash, so adding
    /// it there would move the colour of every unthemed session. `named(_:)`
    /// therefore cannot find it, and `ThemeConfiguration.theme(forSession:)`
    /// resolves it for `SessionRef.localShell` alone.
    static let graphite = ThemeRecipe.theme(named: "graphite", hue: 0, chroma: 0)

    static func named(_ name: String) -> TerminalTheme? {
        all.first { $0.name == name }
    }

    /// The theme a session gets when the user has not named one.
    ///
    /// Deterministic on the session name, so a session keeps its color across
    /// relaunches, across machines, and — unlike assigning by rail position —
    /// across adding or removing other sessions. A color that moves is not an
    /// identity cue, which is the only reason to have one.
    static func defaultTheme(forSession session: String) -> TerminalTheme {
        all[Int(stableHash(session) % UInt64(all.count))]
    }

    /// FNV-1a.
    ///
    /// Swift's own `hashValue` is seeded randomly per process, so it would give
    /// every session a different color on every launch — stable within a run
    /// and useless across them. This has to be a hash whose output is fixed by
    /// the input alone, and `ThemeCatalogTests` pins specific values so a
    /// future "cleanup" to the built-in hasher fails loudly.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
