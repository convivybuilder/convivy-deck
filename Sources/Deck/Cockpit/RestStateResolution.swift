import Foundation

/// What the right column's REST STATE draws for the selected crew — the
/// `.cockpit` occupant's own per-crew branch, alongside `CockpitResolution`'s
/// per-crew bead/project answers. FILE-SCOPE AND PURE, the same discipline
/// `CockpitResolution` documents at its own declaration: a caller passes in
/// the crew it already resolved, and this makes the "which panels draw"
/// decision testable without a view.
///
/// See the steward-board proposal (`agent-runs/2026-09-09/run-83743d3c/
/// proposal.md`, approved by the operator the same day) for the reasoning this
/// mirrors in full: the column's rest state stays ONE thing — "what this
/// crew's work looks like" — and what that resolves to becomes a property
/// of the crew rather than a new `ColumnOccupant` case. `ContentView`'s
/// `columnBody(for: .cockpit)` is where the resolution actually reaches the
/// running view; see that call site for how each shape's panel is chosen.
enum RestStateResolution {

    /// The three things the `.cockpit` occupant's rest state can draw.
    enum Shape: Equatable {
        /// Today's `CockpitView`, unchanged — a crew that names (or
        /// defaults to naming) a Library project.
        case course
        /// The steward's fleet-wide board: `CockpitView` drawing
        /// `CockpitView.boardPanelIDs` (Dispatched, Proposals, Course,
        /// Corrections Queue, Working documents).
        case board
        /// The minimal service panel — a crew that follows no Course by
        /// design (ask, cfo, ea).
        case service
    }

    /// `crew.shape` decoded into a `Shape`, with the steward's by-id
    /// default folded in.
    ///
    /// **`nil` (no selection, or a crew with no `shape` field) is `.course`
    /// UNLESS the crew is the steward** (`crew.id == StewardCrew.id`),
    /// which defaults to `.board` — the same by-id detection
    /// `StewardCrew.shouldCreate` and friends already use, since a crew is
    /// a directory with a role framing in it rather than a typed record
    /// Deck could ask "are you the steward" some other way.
    ///
    /// **AN UNRECOGNIZED STRING DEGRADES THE SAME WAY A MISSING ONE DOES**,
    /// not to a fixed fallback — the "field costs itself" discipline
    /// `ServedCrew.decode` and `ThemeConfiguration.parseRail` already apply
    /// to `project`/`bead`: a crew whose `shape` field failed to parse is
    /// exactly as unresolved as one that never set it, so both fall through
    /// to the same by-id check rather than one being punished harder than
    /// the other for the accident of having tried and failed.
    nonisolated static func shape(for crew: Crew?) -> Shape {
        guard let crew else { return .course }
        switch crew.shape {
        case "course": return .course
        case "board": return .board
        case "service": return .service
        default:
            return crew.id == StewardCrew.id ? .board : .course
        }
    }

    /// The Working documents panel's rows for `.board` — the crew's own
    /// `documents`, resolved against `workingDirectory` into absolute
    /// paths, or the role file (`StewardCrew.roleFilename`) when the crew
    /// named none. Deck ships no filename knowledge beyond that one
    /// default; a crew that wants its charter or backlog listed here names
    /// them itself.
    ///
    /// **Empty when there is no `workingDirectory` to resolve against.**
    /// A relative document name with nothing to join it to is not a path
    /// `DeckOpenRef.Origin.path` could open, so this never invents one —
    /// the same "unresolved resolves to nothing rather than guessing"
    /// posture `Crew.host`/`Crew.project` already take.
    nonisolated static func documentPaths(for crew: Crew?) -> [String] {
        guard let crew, let directory = crew.workingDirectory, !directory.isEmpty else { return [] }
        let names = crew.documents.isEmpty ? [StewardCrew.roleFilename] : crew.documents
        return names.map { name in
            name.hasPrefix("/") ? name : "\(directory)/\(name)"
        }
    }
}
