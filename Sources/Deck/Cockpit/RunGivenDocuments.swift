import Foundation

/// The documents a dispatched run was given, read from the `docs_consulted.json`
/// record in its run directory. The record's `docs` array is written at
/// dispatch (agent-platform#740), so a run still going has its given set: one
/// row per agent file, skill, instruction block and profile document, each with
/// its id, kind and content hash (agent-platform `bin/agentctl`,
/// `_materialized_documents`).
///
/// THE LIST IS THE RECORD, NOT A RECOMPUTED PLAN. Deck never assembles the set
/// from a profile. It shows the `docs` the run's record holds, keeps every row
/// the record holds, and names the missing part when the record cannot answer.
///
/// THE RECORD REACHES DECK THROUGH THE RUN REGISTER, not by reading the run
/// directory over ssh: the register applies the same private-crew gate as
/// `/runs`, and a raw read would skip it.
enum RunGivenDocuments: Equatable {
    case listed(Listing)
    case unavailable(Reason)

    struct Listing: Equatable {
        /// Every row the record's `docs` holds, in the record's order. A row
        /// with no string id stays listed, with `openableId` nil.
        let documents: [Document]
        /// Agent and skill names the record's activation block names that no
        /// row carries. Empty when the list agrees with the activation block.
        let unmatchedNames: [String]
    }

    struct Document: Equatable, Identifiable {
        /// The row's place in `docs`. A kind and an id can both repeat across
        /// rows, so the place is the identity.
        let position: Int
        /// The id the record wrote, or nil when it wrote none.
        let recordId: String?
        /// The kind the record wrote, or "" when it wrote none.
        let kind: String
        /// The content hash the record wrote, or nil.
        let bodyHash: String?
        /// The scope an instruction block was composed at. Nil on other rows.
        let scope: String?

        var id: Int { position }

        /// The id, when `DeckOpenRef.validateKBId` accepts it: the gate a
        /// `deck-open:` link passes, so a row that fails stays listed and
        /// cannot open.
        var openableId: String? { recordId.flatMap(DeckOpenRef.validateKBId) }

        /// The row's label: the id's last segment, since the kind is the group
        /// heading. Nil when the record wrote no id.
        var slug: String? { recordId?.split(separator: "/").last.map(String.init) }
    }

    enum Reason: Equatable {
        /// The register answered `docs_consulted` null: the record is missing
        /// or unreadable for this run. The register does not say which, so
        /// Deck does not either.
        case noRecord
        /// The record exists but holds no `docs` list.
        case noDocumentList
        /// The record is not a JSON object.
        case unreadable
        /// A private crew's run, which the register withholds.
        case withheld
        /// The register does not know this run.
        case unknownRun

        /// The sentence the pane shows in place of a list.
        var explanation: String {
            switch self {
            case .noRecord:
                return "This run's record of the documents it was given is missing or unreadable."
            case .noDocumentList:
                return "This run's record has no list of the documents it was given, so none can be shown."
            case .unreadable:
                return "This run's record of the documents it was given could not be read."
            case .withheld:
                return "The documents this run was given are withheld for a private crew."
            case .unknownRun:
                return "The run register does not know this run, so its documents cannot be read."
            }
        }
    }

    // MARK: - Decode

    /// Decodes the register's answer to `/runs/<run_id>/docs_given`:
    /// `{"found": bool, "private": bool, "docs_consulted": object | null}`.
    /// Nil when the body is not that envelope, which the caller treats as a
    /// failed read. A `docs_consulted` that is absent or null is `.noRecord`;
    /// one that is present but not an object is `.unreadable`.
    static func decodeRegister(_ data: Data) -> RunGivenDocuments? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let found = root["found"] as? Bool else { return nil }
        guard found else { return .unavailable(.unknownRun) }
        if root["private"] as? Bool == true { return .unavailable(.withheld) }
        switch root["docs_consulted"] {
        case nil, is NSNull:
            return .unavailable(.noRecord)
        case let record as [String: Any]:
            return decodeRecord(record)
        default:
            return .unavailable(.unreadable)
        }
    }

    /// Decodes one run's `docs_consulted.json` object. Every row of `docs`
    /// survives: a row that is not an object becomes a row with no id and no
    /// kind, so the list never shows fewer rows than the record holds.
    ///
    /// The activation names are read from `individuated_at_activation`, and
    /// from `materialized_at_activation` only when that is absent. They are
    /// the cross-check that the list matches the record: an agent or skill
    /// the activation names and no row carries shows up in `unmatchedNames`.
    static func decodeRecord(_ record: [String: Any]) -> RunGivenDocuments {
        guard let rows = record["docs"] as? [Any] else { return .unavailable(.noDocumentList) }
        let documents = rows.enumerated().map { position, row -> Document in
            let entry = row as? [String: Any] ?? [:]
            let recordId = (entry["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Document(position: position, recordId: recordId,
                            kind: entry["kind"] as? String ?? "",
                            bodyHash: entry["body_sha256"] as? String,
                            scope: entry["scope"] as? String)
        }
        let activation = (record["individuated_at_activation"] as? [String: Any])
            ?? (record["materialized_at_activation"] as? [String: Any]) ?? [:]
        let agents = names(activation["agents"])
        let skills = names(activation["skills"])
        let unmatched = agents.filter { name in
            !documents.contains { $0.kind == "agent" && $0.slug == name }
        } + skills.filter { name in
            !documents.contains { $0.kind == "skill" && $0.slug == name }
        }
        return .listed(Listing(documents: documents, unmatchedNames: unmatched))
    }

    private static func names(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    // MARK: - Grouping

    /// One kind's rows, in the record's order.
    struct Group: Equatable, Identifiable {
        let kind: String
        let documents: [Document]

        var id: String { kind }
        /// The run pane's own title for a kind. `instruction-block` is named in
        /// full here; the Checkout panel's title for that kind stays as it was
        /// (`CheckoutDocuments.groupTitle` falls through to its default case).
        var title: String {
            kind == "instruction-block" ? "Instruction blocks" : CheckoutDocuments.groupTitle(kind: kind)
        }
    }

    /// Agents, then skills, then instruction blocks, then every other kind
    /// alphabetically. Empty groups are omitted.
    static func groups(_ documents: [Document]) -> [Group] {
        var byKind: [String: [Document]] = [:]
        for document in documents {
            byKind[document.kind, default: []].append(document)
        }
        let leading = ["agent", "skill", "instruction-block"]
        let rest = byKind.keys.filter { !leading.contains($0) }.sorted()
        return (leading + rest).compactMap { kind in
            byKind[kind].map { Group(kind: kind, documents: $0) }
        }
    }

    // MARK: - Fetch

    /// The `docs_given` read for one run, through `RunRegisterRead`.
    static func arguments(target: SSHTarget, runId: String,
                          controlPath: String = defaultControlPath(),
                          home: String = NSHomeDirectory()) throws -> [String] {
        try RunRegisterRead.arguments(target: target, runId: runId, route: "docs_given",
                                      controlPath: controlPath, home: home)
    }

    static func validateRunId(_ runId: String) throws -> String {
        try RunRegisterRead.validateRunId(runId)
    }

    static func fetch(target: SSHTarget, runId: String) throws -> RunGivenDocuments {
        let raw = try RunRegisterRead.run(target: target, runId: runId, route: "docs_given")
        guard let decoded = decodeRegister(raw) else {
            throw SessionAgent.AgentError.failed("the run register answered something other than a run's documents")
        }
        return decoded
    }
}
