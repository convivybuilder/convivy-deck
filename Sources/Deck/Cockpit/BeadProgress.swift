import Foundation

/// The rail's bead-progress pane draws a title, a thin meter, and the
/// fraction as text (`deck/bead/deck` §1) — this is the number behind the
/// meter. The operator's formula, 2026-08-26:
///
/// **Numerator:** epics closed since the plan's last major revision.
/// **Denominator:** epics that revision listed, plus epics added since.
///
/// Kept apart from `LibraryClient`, which only fetches and decodes — this is
/// the arithmetic, pure and static so it is testable with no ssh round trip
/// (Deck has no view-level test target, `deck/bead/deck` §6.5).
enum BeadProgress {
    struct Result: Equatable {
        let closed: Int
        let total: Int

        /// 0 when `total` is 0 — a bead with no epics draws an empty meter
        /// rather than trapping on the divide.
        var fraction: Double {
            guard total > 0 else { return 0 }
            return Double(closed) / Double(total)
        }

        /// "3 of 12 epics" — the fraction as text, the operator's example verbatim.
        var fractionLabel: String { "\(closed) of \(total) epics" }
    }

    /// A terminal outcome under ANY resolution — `fixed`, `wontfix`,
    /// `duplicate`, `redirected` — settles the plan's line on that epic, so
    /// every one of them counts as closed (decision 2: "any resolution
    /// counts as closed"). `resolution != nil` alone already covers every
    /// named case; `state` is checked too only as the fallback
    /// `LibraryClient.CourseEntry.isCompleted` takes for the same wire
    /// shape, for an item whose resolution field went missing but whose
    /// state still says it settled.
    private static func isResolved(_ epic: LibraryClient.Epic) -> Bool {
        epic.resolution != nil || terminalStates.contains(epic.state ?? "")
    }
    private static let terminalStates: Set<String> = ["fixed", "wontfix", "duplicate", "redirected"]

    /// `epics`, scored against `revision` — the bead document's own
    /// `last_reviewed`, or nil when the document carried none.
    ///
    /// Returns nil when `revision` is missing OR present but unparseable —
    /// decision 3, never invent a denominator: the pane draws the title and
    /// no meter in either case, so both collapse to the same one guard here
    /// rather than needing two call sites to agree on the fallback.
    static func compute(epics: [LibraryClient.Epic], revision: String?) -> Result? {
        guard let revision, let revisionInstant = parseRevisionDate(revision) else { return nil }

        var total = 0
        var closed = 0
        for epic in epics {
            let resolved = isResolved(epic)
            let createdAt = epic.createdAt.flatMap(parseTimestamp)
            let resolvedAt = epic.resolvedAt.flatMap(parseTimestamp)

            // An epic whose own `created_at` is missing or unparseable
            // defaults to "created since the revision" — the same posture
            // as the top-level guard above, applied per epic: a data gap
            // adds the epic to the plan's current work rather than
            // silently dropping it from the count.
            let createdBeforeRevision = createdAt.map { $0 < revisionInstant } ?? false
            let resolvedBeforeRevision = resolved && (resolvedAt.map { $0 < revisionInstant } ?? false)

            // Denominator: every epic EXCEPT one both created and closed
            // before the revision — settled work the plan already
            // accounted for the last time it was reviewed.
            if !(createdBeforeRevision && resolvedBeforeRevision) {
                total += 1
            }

            // Numerator: resolved on or after the revision day. Decision 1:
            // `revisionInstant` is 00:00:00 UTC that day, so an epic
            // resolved any time that same day still reads as closed since.
            if resolved, let resolvedAt, resolvedAt >= revisionInstant {
                closed += 1
            }
        }
        return Result(closed: closed, total: total)
    }

    /// `last_reviewed` is a DATE, `"2026-08-24"`, never a timestamp —
    /// parsed as 00:00:00 UTC that day (decision 1). Strict: a string that
    /// is not exactly `yyyy-MM-dd`, or whose digits do not name a real
    /// calendar day, returns nil rather than a formatter's best guess.
    ///
    /// **ROUND-TRIPPED RATHER THAN TRUSTING `isLenient = false` ALONE** —
    /// `DateFormatter` still accepted `"2026/08/24"` against a `yyyy-MM-dd`
    /// pattern despite that setting, reading the slashes as if they were
    /// the literal hyphens. Re-formatting the parsed date and comparing it
    /// back against the input catches that regardless of what the
    /// formatter itself considers strict.
    static func parseRevisionDate(_ revision: String) -> Date? {
        guard revision.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        guard let date = formatter.date(from: revision),
              formatter.string(from: date) == revision else { return nil }
        return date
    }

    /// An epic's `created_at`/`resolved_at` — ISO 8601 with a `Z` offset,
    /// confirmed against the running Library on a `CorrectionDetail`'s own
    /// `created_at` (`LibraryClientTests`, `"2026-08-08T22:31:14Z"`), the
    /// same shape `/items` serves everywhere else.
    private static func parseTimestamp(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }
}
