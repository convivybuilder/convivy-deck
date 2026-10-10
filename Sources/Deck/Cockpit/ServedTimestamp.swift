import Foundation

/// The one place that parses a timestamp the Library or the mini served as
/// ISO 8601 and draws it in the reader's own zone and locale — a clock
/// reading, `08:12`, when it falls on the same day as `now`, the date too,
/// `Sep 29 08:12`, otherwise. `CockpitView.agentRunStartClockLabel`,
/// `LibraryClient.expiryText`, `ItemDetailPane`'s comment timestamps,
/// `CockpitView.needsFirstPlainText`'s `judged_at` and
/// `CockpitView.agentRunCostHelpLines`'s `written_at` all draw through here,
/// so the today/earlier-day rule and the ISO parse live in exactly one
/// place.
enum ServedTimestamp {

    /// Accepts both shapes the Library's wire has used: with fractional
    /// seconds and without. `nil` when neither parses, which every caller
    /// here treats as "draw the raw string unchanged" rather than a crash or
    /// a dropped field.
    nonisolated static func parse(_ iso: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: iso) ?? fractional.date(from: iso)
    }

    /// `instant` in `timeZone`/`locale`, following the today/earlier-day
    /// rule. `templateSuffix` extends the day/no-day template pair
    /// (`"jmm"`/`"MMMd jmm"`) with anything a caller wants appended, such as
    /// `expiryText`'s zone abbreviation (`" z"`).
    nonisolated static func label(
        for instant: Date, now: Date, timeZone: TimeZone, locale: Locale, templateSuffix: String = ""
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        let template = (calendar.isDate(instant, inSameDayAs: now) ? "jmm" : "MMMd jmm") + templateSuffix
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: instant)
    }

    /// A served ISO 8601 string, parsed and drawn per `label(for:now:timeZone:locale:)`,
    /// or `iso` unchanged when it does not parse — so format drift on the
    /// producer's side costs only the pretty time, never the field itself.
    nonisolated static func localLabel(
        _ iso: String, now: Date, timeZone: TimeZone = .current, locale: Locale = .current
    ) -> String {
        guard let instant = parse(iso) else { return iso }
        return label(for: instant, now: now, timeZone: timeZone, locale: locale)
    }
}
