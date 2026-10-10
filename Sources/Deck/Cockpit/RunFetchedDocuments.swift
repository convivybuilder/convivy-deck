import Foundation

/// The documents a dispatched run has fetched so far, in fetch order, and the
/// searches it has made, read from the register's `/runs/<run_id>/docs_fetched`
/// route. The platform derives both from the run's own `tool_calls.jsonl`
/// (agent-platform `lib/agent-platform/fetched_documents.py`), so they update
/// while the run is still going. Each document entry is one `kb_get`,
/// `kb_checkout` or `signal_get` that returned a document. Each search entry is
/// one `kb_search` or `signal_search` call that did not error.
///
/// A SEARCH IS NOT A FETCH. Searches arrive under their own `searches` key and
/// draw in their own section, never among the documents. The key's shape is
/// the Bosun's (item issue_01M46AHNZDE99ZXR4B4S6TDTRG, not yet live at the time
/// of writing). A register that does not send the key leaves `searches` nil,
/// and the pane draws no searches section for that answer.
///
/// THE LIST IS THE REGISTER'S ANSWER. Deck does not re-derive it from the
/// tool-call log.
///
/// THE READ REACHES DECK THROUGH THE RUN REGISTER, like `RunGivenDocuments`,
/// so the private-crew gate applies to it too.
enum RunFetchedDocuments: Equatable {
    case listed(Listing)
    case unavailable(Reason)

    struct Listing: Equatable {
        var documents: [Document]
        /// Document rows the register sent that could not be read. Each one is
        /// counted and noted in the pane, and the other rows still draw.
        var unreadableDocuments: Int = 0
        /// The searches in call order, or nil when the answer carries no
        /// `searches` key (or the key is not an array). Nil means the pane
        /// does not show searches. It never means "no searches were made".
        var searches: [Search]? = nil
        /// Search rows the register sent that could not be read. Each one is
        /// counted and noted in the pane, and the other rows still draw.
        var unreadableSearches: Int = 0
    }

    struct Document: Equatable, Identifiable {
        /// The place in fetch order. A run can fetch one document twice, so the
        /// place is the identity.
        let position: Int
        /// The id the run passed to the tool: a knowledge-document id for a
        /// `knowledge` entry, an Archives signal id for a `signal` entry.
        let documentId: String
        /// `knowledge` for a KB document, `signal` for an Archives record.
        let kind: String
        /// The tool call's timestamp, as the platform wrote it, or nil.
        let fetchedAt: String?

        var id: Int { position }

        /// The id, when `DeckOpenRef.validateKBId` accepts it. Only a KB
        /// document opens: Deck has no open path for an Archives record, so a
        /// `signal` entry is never openable.
        var openableId: String? {
            kind == "knowledge" ? DeckOpenRef.validateKBId(documentId) : nil
        }

        /// The row's label: a KB document's last id segment, or the whole id
        /// for an Archives record.
        var label: String {
            guard kind == "knowledge" else { return documentId }
            return String(documentId.split(separator: "/").last ?? Substring(documentId))
        }

        /// The fetch time, drawn in the reader's zone and locale. Nil when the
        /// entry carries no parseable timestamp.
        func fetchedLabel(now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
            RunFetchedDocuments.timeLabel(fetchedAt, now: now, timeZone: timeZone, locale: locale)
        }
    }

    /// One search the run made. Its query is not a document id and is never
    /// opened.
    struct Search: Equatable, Identifiable {
        /// The place in the register's `searches` list, which is call order.
        let position: Int
        /// `kb_search` or `signal_search`.
        let tool: String
        /// The query the run passed, cleaned by `displayableQuery` for display.
        /// The producer bounds its length already.
        let query: String
        /// The call's timestamp, as the platform wrote it, or nil.
        let searchedAt: String?

        var id: Int { position }

        /// The row's kind: a KB search or an Archives search.
        var kindLabel: String {
            tool == "signal_search" ? "Archives search" : "Knowledge search"
        }

        /// The search time, drawn in the reader's zone and locale. Nil when the
        /// entry carries no parseable timestamp.
        func searchedLabel(now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
            RunFetchedDocuments.timeLabel(searchedAt, now: now, timeZone: timeZone, locale: locale)
        }
    }

    enum Reason: Equatable {
        /// The register does not know this run.
        case unknownRun
        /// A private crew's run, which the register withholds.
        case withheld

        /// The sentence the pane shows in place of a list.
        var explanation: String {
            switch self {
            case .unknownRun:
                return "The run register does not know this run, so the documents it has fetched cannot be read."
            case .withheld:
                return "The documents this run has fetched are withheld for a private crew."
            }
        }
    }

    /// The `tool` values the register sends under `searches`.
    static let searchTools: Set<String> = ["kb_search", "signal_search"]

    // MARK: - Decode

    /// Decodes the register's answer to `/runs/<run_id>/docs_fetched`:
    /// `{"found": bool, "private": bool, "docs_fetched": [{id, kind, fetched_at}],
    /// "searches": [{tool, query, searched_at}]}`. Nil when the body is not that
    /// envelope, or `docs_fetched` is missing or not an array. The caller treats
    /// nil as a failed read, never as an empty list.
    ///
    /// An empty `docs_fetched` is `.listed` with no documents: the read
    /// succeeded and the run has fetched nothing yet. A document row that is not
    /// an object with a string `id` and `kind` counts toward
    /// `unreadableDocuments` and does not affect the other rows; the same holds
    /// for a search row that is not an object with a known `tool` and a string
    /// `query`, which counts toward `unreadableSearches`.
    static func decodeRegister(_ data: Data) -> RunFetchedDocuments? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let found = root["found"] as? Bool else { return nil }
        guard found else { return .unavailable(.unknownRun) }
        if root["private"] as? Bool == true { return .unavailable(.withheld) }
        guard let rows = root["docs_fetched"] as? [Any] else { return nil }
        var documents: [Document] = []
        var unreadable = 0
        for (position, row) in rows.enumerated() {
            guard let entry = row as? [String: Any],
                  let id = entry["id"] as? String,
                  let kind = entry["kind"] as? String else {
                unreadable += 1
                continue
            }
            let fetchedAt = entry["fetched_at"] as? String
            documents.append(Document(position: position, documentId: id, kind: kind, fetchedAt: fetchedAt))
        }
        let searches = decodeSearches(root["searches"])
        return .listed(Listing(documents: documents,
                               unreadableDocuments: unreadable,
                               searches: searches.rows,
                               unreadableSearches: searches.unreadable))
    }

    /// The `searches` key. A missing key, or a value that is not an array,
    /// leaves `rows` nil so the pane shows no searches. An array gives its
    /// readable rows and a count of the unreadable ones.
    private static func decodeSearches(_ value: Any?) -> (rows: [Search]?, unreadable: Int) {
        guard let raw = value as? [Any] else { return (nil, 0) }
        var rows: [Search] = []
        var unreadable = 0
        for (position, row) in raw.enumerated() {
            guard let entry = row as? [String: Any],
                  let tool = entry["tool"] as? String, searchTools.contains(tool),
                  let query = entry["query"] as? String else {
                unreadable += 1
                continue
            }
            rows.append(Search(position: position, tool: tool,
                               query: displayableQuery(query),
                               searchedAt: entry["searched_at"] as? String))
        }
        return (rows, unreadable)
    }

    /// A query as the pane draws it. `SessionPaneView.displayable` strips bidi
    /// controls and caps clusters, but it leaves C0 and C1 controls in place,
    /// so they are mapped here first. Each C0 control becomes its Control
    /// Pictures glyph (U+2400 block), DEL becomes U+2421, other C1 controls
    /// become U+FFFD, and tab and line breaks become spaces, which keeps the
    /// query on one line.
    static func displayableQuery(_ raw: String) -> String {
        let mapped = raw.unicodeScalars.map { scalar -> Unicode.Scalar in
            guard scalar.properties.generalCategory == .control else { return scalar }
            switch scalar.value {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D: return " "
            case 0x00...0x1F: return Unicode.Scalar(0x2400 + scalar.value) ?? "\u{FFFD}"
            case 0x7F: return "\u{2421}"
            default: return "\u{FFFD}"
            }
        }
        return SessionPaneView.displayable(String(String.UnicodeScalarView(mapped)))
    }

    /// A timestamp drawn for the reader, or nil when it does not parse.
    private static func timeLabel(_ raw: String?, now: Date, timeZone: TimeZone, locale: Locale) -> String? {
        guard let raw, let instant = ServedTimestamp.parse(raw) else { return nil }
        return ServedTimestamp.label(for: instant, now: now, timeZone: timeZone, locale: locale)
    }

    // MARK: - Fetch

    /// The `docs_fetched` read for one run, through `RunRegisterRead`.
    static func arguments(target: SSHTarget, runId: String,
                          controlPath: String = defaultControlPath(),
                          home: String = NSHomeDirectory()) throws -> [String] {
        try RunRegisterRead.arguments(target: target, runId: runId, route: "docs_fetched",
                                      controlPath: controlPath, home: home)
    }

    static func fetch(target: SSHTarget, runId: String) throws -> RunFetchedDocuments {
        let raw = try RunRegisterRead.run(target: target, runId: runId, route: "docs_fetched")
        guard let decoded = decodeRegister(raw) else {
            throw SessionAgent.AgentError.failed("the run register answered something other than a run's fetched documents")
        }
        return decoded
    }
}
