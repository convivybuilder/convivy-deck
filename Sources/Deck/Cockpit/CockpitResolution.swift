import Foundation

/// What the cockpit and the bead link resolve to, once the owning crew and the
/// host are known.
///
/// FILE-SCOPE AND PURE, NOT METHODS ON THE VIEW, and this file exists because
/// of a bug that hid in the difference. The bead action resolved its host
/// through the COCKPIT's resolution, which requires `crew.project` — so a crew
/// carrying a bead and no project got a permanently disabled button, and its
/// tooltip told the operator to set a project, which would not have helped.
/// The two fields are orthogonal by design, and nothing a test could reach
/// said so, because all four answers were `private` methods on `ContentView`.
///
/// It is the shape `convivy-deck#131` landed three untested fixes in, and the
/// answer `ColumnOccupant`'s toggles already took. Found by `deck-reviewer`
/// on #133.
///
/// **The crew lookup deliberately stays on the view.** `ContentView.owningCrew`
/// reads `childParentByRef` and `discoveredParentByRef`, which are derived
/// view state rather than configuration, so extracting it would mean faking
/// the lookup rather than testing it. These take the crew a caller already
/// resolved, which is the part that was actually getting the decisions wrong.
enum CockpitResolution {

    /// The bead doc id for a crew, or nil.
    ///
    /// PICKED, NOT DERIVED — see `Crew.bead`. A crew's id, display name and
    /// Library product are three naming spaces a bead's doc id does not
    /// reliably agree with (`convivy-deck` → `deck/bead/deck`, `bosun` →
    /// `agent-platform/bead/agent-platform`), so nothing here guesses one from
    /// another and an unset field means no link rather than a wrong one.
    static func beadId(for crew: Crew?) -> String? {
        guard let bead = crew?.bead, !bead.isEmpty else { return nil }
        return bead
    }

    /// Whether the bead link can open, and if not, why — as ONE value.
    ///
    /// A SUM TYPE SO THE BUTTON AND ITS TOOLTIP CANNOT DISAGREE. They drifted
    /// twice. First the tooltip named a Library project, which the bead action
    /// does not need, so it was wrong for every crew that had a project and no
    /// bead. Then the fix computed a correct reason, threaded it into the view,
    /// and never read it — the button's enabled state was right while its
    /// tooltip stayed the old wrong string, and a pure-function test could not
    /// see it because the two were computed independently and only agreed by
    /// being written to agree.
    ///
    /// One value removes the agreement problem rather than documenting it: a
    /// caller cannot render an enabled button with a reason, or a disabled one
    /// without, because neither state is representable. Found by
    /// `deck-reviewer` on #133, twice.
    ///
    /// **Gated on the bead and the host, never on `crew.project`.** A crew may
    /// carry a bead and no project, or a project and no bead; they are set
    /// independently and answer different questions.
    enum BeadAvailability: Equatable {
        case available(beadId: String, target: SSHTarget)
        case unavailable(reason: String)

        /// The tooltip, for either state — so one call answers both.
        var help: String {
            switch self {
            case .available: return "Open this project's bead"
            case .unavailable(let reason): return reason
            }
        }

        var openable: (beadId: String, target: SSHTarget)? {
            switch self {
            case .available(let beadId, let target): return (beadId, target)
            case .unavailable: return nil
            }
        }
    }

    static func beadAvailability(hasSelection: Bool, crew: Crew?,
                                 target: SSHTarget?) -> BeadAvailability {
        guard hasSelection else {
            return .unavailable(reason: "Select a session to open its project's bead.")
        }
        guard let crew else {
            return .unavailable(reason: "This session has no crew, so it has no bead.")
        }
        guard let bead = beadId(for: crew) else {
            return .unavailable(
                reason: "\(crew.displayName) names no bead. Choose one in Settings › Sessions.")
        }
        guard let target else {
            return .unavailable(reason: "\(crew.displayName)'s host is not configured.")
        }
        return .available(beadId: bead, target: target)
    }

    /// The Library product the cockpit follows, with its host.
    static func projectAndTarget(for crew: Crew?, target: SSHTarget?)
    -> (project: String, target: SSHTarget)? {
        guard let project = crew?.project, !project.isEmpty, let target else { return nil }
        return (project, target)
    }

    /// One followed repo, validated — `LibraryClient.validateRepoIdentity`'s
    /// own return shape, named here so `prLadderRepos`' callers don't each
    /// spell out the tuple.
    struct ResolvedRepo: Equatable {
        let owner: String
        let repoName: String
        var identity: String { "\(owner)/\(repoName)" }
    }

    /// `prLadderRepos`' full answer: the repos the panel will actually
    /// fetch, plus how many more the crew named beyond `maxFollowedRepos`.
    struct ResolvedRepos: Equatable {
        let repos: [ResolvedRepo]
        /// How many valid, deduplicated repos the crew named beyond
        /// `maxFollowedRepos` — `0` when the cap was never reached. A
        /// panel surfaces this as a note rather than silently drawing a
        /// shorter list than the crew configured.
        let droppedByCap: Int
    }

    /// How many of a crew's followed repos the Pull Requests panel will
    /// actually fetch. Bounds the per-refresh Library fetch fan-out this
    /// panel issues: `PRLadderModel` fetches once per repo, and repeats
    /// every `PRLadderModel.refreshInterval` (900s) via the background
    /// sweep besides — an unbounded served `repos` array becomes an
    /// unbounded, standing fetch load, one crew's spec away from hammering
    /// the Library on a timer. The busiest real crew measured for
    /// `issue_01M2P5JHM1G8XCMKM4HEHVJB2P` (Constance) follows four repos;
    /// this caps at 8, generous headroom for real growth while still
    /// bounding a malformed or runaway served spec to a fixed, small
    /// fan-out rather than an unbounded one.
    static let maxFollowedRepos = 8

    /// `PRLadder.fetchLadder`'s `(owner, repoName)` for every repo the
    /// crew follows, read from `Crew.repos` — empty on the same
    /// "unresolved resolves to nothing rather than guessing" terms
    /// `projectAndTarget` is.
    ///
    /// **NO CREW→REPO GUESS IS MADE HERE.** An earlier version of the
    /// single-repo predecessor to this function hardcoded `convivy` as the
    /// owner and reused `project` as the repo name, on the observation that
    /// every repo this build had seen shared that shape. It was wrong for
    /// the Keel crew, whose project is `bosun` and whose repo is
    /// `convivy/agent-platform` — no `convivy/bosun` exists, so the guess
    /// drew a silently empty panel — and it was never going to be right
    /// once Deck shipped to anyone running it outside Convivy. See
    /// `Crew.repos`'s doc.
    ///
    /// **Each entry is validated independently** (`LibraryClient.validateRepoIdentity`)
    /// — an entry that fails costs only itself, the same "field costs
    /// itself" discipline `ThemeConfiguration.parseRepos` and (as of this
    /// function) `ServedCrew.resolvedRepos` already apply at decode time.
    /// This is a second, redundant validation of already-validated data for
    /// a locally-configured or hand-edited crew, and the FIRST validation a
    /// served crew's singular `repo` ever receives — that field has been
    /// unvalidated since `#238` introduced it, harmlessly while only
    /// `repos.first` was ever read; this function is what starts actually
    /// querying every entry, so it is where that gap had to close.
    ///
    /// **Duplicates collapse to their first occurrence**, preserving
    /// configured order — a crew that lists the same repo twice fetches
    /// and shows it once, the same as a crew that only ever named it once.
    /// Compared as the exact, case-preserved `owner/repoName` string
    /// `validateRepoIdentity` returns, matching how `PRLadder.repoConsistency`
    /// already keys a repo by plain string equality elsewhere in this
    /// derivation.
    static func prLadderRepos(for crew: Crew?) -> ResolvedRepos {
        guard let crew else { return ResolvedRepos(repos: [], droppedByCap: 0) }
        var seen = Set<String>()
        var validated: [ResolvedRepo] = []
        for raw in crew.repos {
            guard let identity = LibraryClient.validateRepoIdentity(raw) else { continue }
            let resolved = ResolvedRepo(owner: identity.owner, repoName: identity.repoName)
            guard seen.insert(resolved.identity).inserted else { continue }
            validated.append(resolved)
        }
        let dropped = max(0, validated.count - maxFollowedRepos)
        return ResolvedRepos(repos: Array(validated.prefix(maxFollowedRepos)), droppedByCap: dropped)
    }

    /// Why the cockpit cannot draw, in words for the operator, or nil when it can.
    static func unresolvedReason(hasSelection: Bool, crew: Crew?, target: SSHTarget?) -> String? {
        guard hasSelection else { return "Select a session to see its project's cockpit." }
        guard let crew else { return "This session has no crew, so it has no project to follow." }
        guard let project = crew.project, !project.isEmpty else {
            return "\(crew.displayName) names no Library project. Set one in "
                + "Settings › Sessions to see its cockpit."
        }
        _ = project
        guard target != nil else { return "\(crew.displayName)'s host is not configured." }
        return nil
    }

    /// Why the Pull Requests panel has nothing to follow, in words for the
    /// operator, or nil when it does — `unresolvedReason`'s own shape, but
    /// gated on `crew.repos` rather than `crew.project`. The two are set
    /// independently (see `Crew.repos`'s doc, and `BeadAvailability`'s own
    /// doc for the bug this same split already fixed once for project/bead),
    /// so a crew naming a project and no repo must say so rather than the
    /// panel drawing an empty list with no reason.
    static func prLadderUnresolvedReason(hasSelection: Bool, crew: Crew?, target: SSHTarget?) -> String? {
        guard hasSelection else { return "Select a session to see its pull requests." }
        guard let crew else { return "This session has no crew, so it has no repository to follow." }
        guard !prLadderRepos(for: crew).repos.isEmpty else {
            return "\(crew.displayName) names no repository. Set one in "
                + "Settings › Sessions to see its pull requests."
        }
        guard target != nil else { return "\(crew.displayName)'s host is not configured." }
        return nil
    }

    /// Why the right column has nothing to draw for a `.board` or
    /// `.service` crew (`RestStateResolution.Shape`) — the same
    /// session-level checks `unresolvedReason` starts with (a selection, a
    /// crew, a configured host), with NO project requirement, because a
    /// crew shaped this way follows no Course by design and has no project
    /// to be missing.
    ///
    /// **THE BUG THIS REPLACES.** Before `RestStateResolution` existed,
    /// every crew — the steward included — drew through `unresolvedReason`,
    /// so a steward naming no Library project (every steward, since it has
    /// none to name) got told `"<name> names no Library project. Set one in
    /// Settings › Sessions"`, which would not have helped, and
    /// `CockpitView.body` used that one string to replace ALL FOUR panels —
    /// including Dispatched, which the steward's session payload already
    /// serves fleet-wide (`agents_fleet_wide`) and which the panel already
    /// titles "Dispatched (fleet)". `ContentView.columnBody(for: .cockpit)`
    /// must call THIS for a `.board`/`.service` crew and `unresolvedReason`
    /// only for `.course` — never the reverse — or the fix lands here and
    /// nowhere the running view can reach it.
    static func restStateUnresolvedReason(hasSelection: Bool, crew: Crew?, target: SSHTarget?) -> String? {
        guard hasSelection else { return "Select a session to see it." }
        guard let crew else { return "This session has no crew." }
        guard target != nil else { return "\(crew.displayName)'s host is not configured." }
        return nil
    }

    /// Why the bead link cannot open, in words for the operator, or nil when it
    /// can.
    ///
    /// SEPARATE FROM `unresolvedReason` BECAUSE THE PRECONDITIONS DIFFER. The
    /// single tooltip this replaces named the project for both, which was
    /// accurate only by accident and actively wrong whenever a crew had a
    /// project and no bead — the likelier miss, since the bead is the field
    /// the picker was added for.
    static func beadUnavailableReason(hasSelection: Bool, crew: Crew?, target: SSHTarget?) -> String? {
        switch beadAvailability(hasSelection: hasSelection, crew: crew, target: target) {
        case .available: return nil
        case .unavailable(let reason): return reason
        }
    }
}
