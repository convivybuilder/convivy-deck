import Foundation

/// One row's presentation — a pure function of `PRLadder.Position`, kept
/// separate from `PRLadder` itself: that file derives the position from the
/// Library's records, this file decides how the cockpit panel draws it. The
/// same split `CockpitView.RowTreatment` keeps from `LibraryClient.CourseEntry`.
///
/// `issue_01M1372GNR81ZV7K1DXHAD10R0`'s specification is what this maps to:
/// "in CI" and "failed CI" must draw differently, so must "in second review"
/// and "ready to merge", and anything waiting on the operator must draw differently
/// from anything waiting on a machine.
enum PRLadderRow {

    /// The one visual weight a row's label carries beyond its plain text —
    /// `.caution` and `.failure` both mean "a person should look", drawn at
    /// two different inks so a reviewer's request and a broken build don't
    /// read as the same event; `.invitation` is the one ink that means
    /// "waiting on the operator", never reused for anything a machine is still doing.
    enum Severity: Equatable {
        case neutral
        case caution
        case failure
        case invitation
    }

    /// Everything one row draws from its derived position: the word,
    /// whether the row is a closed/terminal one (struck through, muted),
    /// and the ink weight.
    struct Presentation: Equatable {
        let label: String
        let isTerminal: Bool
        let severity: Severity
    }

    static func present(_ position: PRLadder.Position) -> Presentation {
        switch position {
        case .draft:
            return Presentation(label: "Draft", isTerminal: false, severity: .neutral)
        case .inReview:
            return Presentation(label: "In review", isTerminal: false, severity: .neutral)
        case .changesRequested:
            return Presentation(label: "Changes requested", isTerminal: false, severity: .caution)
        case .inSecondReview:
            return Presentation(label: "In second review", isTerminal: false, severity: .neutral)
        case .inCI:
            return Presentation(label: "In CI", isTerminal: false, severity: .neutral)
        case .failedCI:
            return Presentation(label: "CI failed", isTerminal: false, severity: .failure)
        case .readyToMerge:
            return Presentation(label: "Ready to merge", isTerminal: false, severity: .invitation)
        case .closed(.closed):
            return Presentation(label: "Closed", isTerminal: true, severity: .neutral)
        case .closed(.merged):
            return Presentation(label: "Merged", isTerminal: true, severity: .neutral)
        case .stateUnknown(let reason):
            return Presentation(
                label: "State unknown — \(unknownReasonText(reason))",
                isTerminal: false, severity: .neutral)
        }
    }

    /// The named reason a `stateUnknown` row draws — never a bare "state
    /// unknown" with nothing to say why, per the epic's own rule ("a PR the
    /// Bosun holds no record of draws as 'state unknown' and is never
    /// dropped" — the reason is the other half of that promise).
    static func unknownReasonText(_ reason: PRLadder.UnknownReason) -> String {
        switch reason {
        case .noPRRecord:
            return "no record of this PR"
        case .missingState:
            return "its record has no state"
        case .missingHeadSha:
            return "its record has no head commit"
        case .unrecognizedState(let raw):
            return raw.isEmpty ? "its record reported no state" : "its record reported \"\(raw)\""
        case .noCISource(let detail):
            return detail
        }
    }

    /// "1 stale review" / "3 stale reviews", or `nil` for a row with none —
    /// the label `staleReviewCount` draws as, pulled out so
    /// `PRLadderPanelTests` can pin the plural without a view.
    static func staleReviewsLabel(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 stale review" : "\(count) stale reviews"
    }

    /// The stoplight category a position's dot draws in. The operator's own revised
    /// mapping (2026-09-16, in session, after seeing the first cut): CI and
    /// review are no longer one "in flight" amber — a broken build (`failedCI`,
    /// red) must draw differently from a build still running (`inCI`, brown)
    /// and from a human still reading (`inReview`, amber), and a closed-not-merged
    /// PR takes the shell's own text ink rather than red, since red is now
    /// spoken for by CI failure. `draftOrUnknown` is still grey, GitHub's own
    /// draft-PR colour, reused for `stateUnknown` since neither has a verdict to
    /// report. `ThemeRecipe.prDotInk` is what turns this into an actual colour
    /// for the shell's current appearance; this mapping stays pure so it is
    /// testable without a view.
    enum DotColor: Hashable {
        case merged
        case ready
        case closed
        case failedCI
        case inCI
        case inReview
        case draftOrUnknown
    }

    static func dotColor(_ position: PRLadder.Position) -> DotColor {
        switch position {
        case .draft, .stateUnknown:
            return .draftOrUnknown
        case .inReview, .changesRequested, .inSecondReview:
            return .inReview
        case .inCI:
            return .inCI
        case .failedCI:
            return .failedCI
        case .readyToMerge:
            return .ready
        case .closed(.closed):
            return .closed
        case .closed(.merged):
            return .merged
        }
    }

    /// GitHub's own host — the one literal this function allows, kept as a
    /// named constant so a later GitHub Enterprise host is a one-line change
    /// rather than a search-and-replace across call sites
    /// (`deck/specs/running-deck-as-someone-else`).
    private static let githubHost = "github.com"

    /// The PR's page on GitHub, or `nil` when `repo` won't validate as an
    /// `owner/name` pair — a row whose repo fails that check draws no link
    /// rather than a link built from a guessed URL, the same per-field
    /// degrade posture an unparseable record gets elsewhere.
    /// `LibraryClient.validateRepoIdentity` is the same owner/name split and
    /// charset check `PRLadder.fetchLadder` already runs on this same field.
    ///
    /// This is the placeholder `issue_01M2P4JJFW5CE8FT0ZTASR6KN5` describes
    /// for the merge affordance (`issue_01M0NWWHCPYNBYS297SEPRKRD5`, blocked
    /// on the Individuator and the `merge` verb) — one pure function so that
    /// replacement is a small change rather than an unpicking.
    static func githubURL(repo: String, number: Int) -> URL? {
        guard let identity = LibraryClient.validateRepoIdentity(repo) else { return nil }
        return URL(string: "https://\(githubHost)/\(identity.owner)/\(identity.repoName)/pull/\(number)")
    }

    /// The compact repo mark a row draws beside `#N` once its crew follows
    /// more than one repo (`issue_01M2P5JHM1G8XCMKM4HEHVJB2P`) — the bare
    /// repo name, not the full `owner/name` identity. Horizontal space is
    /// the scarce resource on this row (a stoplight dot, `#N`, and
    /// eventually a work-item key chip — `issue_01M2P5D0D4EQEQX7BSRNFT5QGJ`
    /// — already share it), and a crew's several repos share one owner far
    /// more often than they collide on repo name alone. `nil` when `repo`
    /// won't validate, same as `githubURL`.
    static func repoMark(_ repo: String) -> String? {
        LibraryClient.validateRepoIdentity(repo)?.repoName
    }
}
