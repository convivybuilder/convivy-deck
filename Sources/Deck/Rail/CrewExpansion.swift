import Foundation

/// Which crew rows the rail has left expanded, and how that survives a
/// relaunch — the state behind `RailView`'s `deck.expandedProjectIds`
/// `@AppStorage` string.
///
/// A TYPE RATHER THAN TWO LINES IN THE VIEW, because the keying is the part
/// that can be wrong. A crew is identified by its host and its name, so
/// macstudio's `steward` and macmini's `steward` have to open and close
/// independently; keyed by bare id, as this was, they shared one disclosure
/// and neither could be collapsed alone. That is a claim a unit test can
/// hold, which it cannot while the set lives inside a `View`.
///
/// STORED AS ONE COMMA-JOINED STRING, still, and still `@AppStorage` rather
/// than `theme.json`: this is the rail remembering what a user left open, not
/// a setting anyone hand-edits. Each entry is a `SessionRef.stringForm`
/// (`"macstudio|steward"`), and `,` cannot appear in one — `validateHostName` and
/// `validateTmuxSessionName` both refuse it — so the join is unambiguous for
/// every ref Deck writes.
struct CrewExpansion: Equatable {
    /// The `@AppStorage` key `RailView` keeps this under, named once so
    /// `ThemeStore.updateHost` rewrites the same value the rail reads.
    static let storageKey = "deck.expandedProjectIds"

    private var keys: Set<String>

    /// A key written before the host half existed is a bare crew id, and it
    /// matches that name ON ANY HOST rather than nothing at all: a user who
    /// upgrades should find the rows they left open still open. The first
    /// toggle of such a row rewrites it in the host-qualified form, because
    /// `toggle` only ever inserts and removes `stringForm` keys.
    ///
    /// A bare key therefore opens BOTH crews of that name on an install that
    /// already had two, which is the one case this read cannot resolve: the
    /// old state held one entry for both rows, so there is no second answer
    /// to recover. It costs one click on whichever row the user wanted shut.
    init(raw: String) {
        keys = Set(raw.split(separator: ",").map(String.init))
    }

    /// The string form for `@AppStorage`. Sorted, so an unrelated redraw
    /// cannot rewrite the value with the same entries in a new order.
    var raw: String { keys.sorted().joined(separator: ",") }

    func isExpanded(_ crew: SessionRef) -> Bool {
        keys.contains(crew.stringForm) || keys.contains(crew.name)
    }

    /// Nothing auto-expands from a poll (design §E) — the disclosure's own
    /// `onToggle` is the only caller, and it fires only from a click on the
    /// chevron.
    ///
    /// Collapsing drops the bare legacy key alongside the qualified one, or a
    /// row read as expanded through that key could never be closed.
    mutating func toggle(_ crew: SessionRef) {
        if isExpanded(crew) {
            keys.remove(crew.stringForm)
            keys.remove(crew.name)
        } else {
            keys.insert(crew.stringForm)
        }
    }

    /// Moves every entry naming `oldHost` to `newHost`, for a host rename.
    /// Without it an expanded row on the renamed host keeps a key naming a
    /// host that no longer exists, matches neither its new `stringForm` nor
    /// its bare name, and draws collapsed after the rename. A bare legacy key
    /// names no host and is left as it is.
    mutating func renameHost(_ oldHost: String, to newHost: String) {
        keys = Set(keys.map { key in
            guard let ref = SessionRef.parse(stringForm: key),
                  ref.host == oldHost else { return key }
            return SessionRef(host: newHost, name: ref.name).stringForm
        })
    }
}
