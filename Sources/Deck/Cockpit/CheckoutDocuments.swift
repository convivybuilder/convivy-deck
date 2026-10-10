import Foundation

/// What `session-agent documents <session>` answered: the knowledge documents
/// a session's checkout brought, or the named reason it cannot say.
///
/// THE LIST IS A RECORD OF THE CHECKOUT, NOT A RECOMPUTED PLAN. The mini reads
/// `.claude/.profile-documents.json`, which `knowledge-ctx use` writes when it
/// individuates the profile (agent-platform#577), so the answer describes what
/// the session loaded even after its profile or the corpus has moved on. Deck
/// never reads a profile YAML or a `.claude/` directory itself.
enum CheckoutDocuments: Equatable {
    case listed(profile: String?, documents: [Document])
    case unavailable(Reason)

    struct Document: Equatable, Hashable, Identifiable {
        /// The three-segment KB id (`project/kind-dir/slug`). Not validated
        /// here: every open goes through `DeckOpenRef.validateKBId` at the
        /// click, the same gate a `deck-open:` link passes, so a malformed id
        /// stays visible and refuses to open rather than vanishing.
        let id: String
        /// The document's frontmatter kind, or "" when the mini sent none.
        let kind: String

        /// The row's label — the id's last segment, since the verb carries
        /// no title and the kind is already the group heading.
        var slug: String { id.split(separator: "/").last.map(String.init) ?? id }
    }

    /// The four answers the mini names in place of a list. An empty list
    /// would say the checkout brought nothing, which none of these mean.
    enum Reason: Equatable {
        /// The session's working directory could not be resolved — a
        /// session with no running Claude answers this too, not only a
        /// missing one.
        case noSuchSession
        case notIndividuated
        /// The checkout was individuated before the record existed. Common
        /// right after the verb shipped: every live session answers this until
        /// its next restart re-individuates it.
        case noDocumentRecord
        case unreadableRecord
        /// A reason this build does not know, kept verbatim so the panel can
        /// still say what the mini said.
        case other(String)

        init(wire: String) {
            switch wire {
            case "no_such_session": self = .noSuchSession
            case "not_materialized": self = .notIndividuated  // wire key, renamed only when its producer renames it
            case "no_document_record": self = .noDocumentRecord
            case "unreadable_record": self = .unreadableRecord
            default: self = .other(wire)
            }
        }

        var explanation: String {
            switch self {
            case .noSuchSession:
                return "The host could not find this session's working directory, so there is no checkout to read."
            case .notIndividuated:
                return "This session started without loading a knowledge profile, so its checkout brought no documents."
            case .noDocumentRecord:
                return "This session loaded its profile before its documents were recorded. They will be listed after the session's next restart."
            case .unreadableRecord:
                return "This session's record of its documents could not be read."
            case .other(let wire):
                return "The host could not list this session's documents (\(wire))."
            }
        }
    }

    /// Decodes the verb's one JSON object, or nil when the reply is not an
    /// object carrying either `documents` or `reason`. The verb always exits
    /// 0, so this — not the exit status — is where an answer is told from a
    /// refusal.
    ///
    /// AN ENTRY WITH NO ID IS DROPPED; one with no kind is kept under "".
    /// A row with nothing to open is not a document, while a document whose
    /// kind is missing is still one the checkout brought, and it collapses
    /// with the other kinds Deck does not recognise.
    static func decode(_ data: Data) -> CheckoutDocuments? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let raw = root["documents"] as? [[String: Any]] {
            let documents = raw.compactMap { entry -> Document? in
                guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
                return Document(id: id, kind: entry["kind"] as? String ?? "")
            }
            return .listed(profile: root["profile"] as? String, documents: documents)
        }
        if let reason = root["reason"] as? String {
            return .unavailable(Reason(wire: reason))
        }
        return nil
    }

    // MARK: - Grouping

    /// One kind's documents, in the order the mini sent them (sorted by id).
    struct Group: Equatable, Identifiable {
        let kind: String
        let documents: [Document]

        var id: String { kind }
        var title: String { CheckoutDocuments.groupTitle(kind: kind) }
        /// The kinds that orient a reader open by default; every other kind
        /// starts collapsed under its count. A checkout brings well over a
        /// hundred documents, most of them decisions (the operator, 2026-09-14).
        var isExpandedByDefault: Bool { CheckoutDocuments.expandedKinds.contains(kind) }
    }

    /// Listed in full by default, in this order, ahead of everything else.
    static let expandedKinds = ["bead", "overview", "architecture"]
    /// Collapsed by default, in this order, after the expanded kinds.
    static let collapsedKinds = ["decision", "reference", "runbook", "skill", "agent"]

    /// Groups documents by kind: the expanded kinds first, then the known
    /// collapsed kinds, then any kind Deck does not recognise, alphabetically.
    /// Empty groups are omitted.
    static func groups(_ documents: [Document]) -> [Group] {
        var byKind: [String: [Document]] = [:]
        for document in documents {
            byKind[document.kind, default: []].append(document)
        }
        let known = expandedKinds + collapsedKinds
        let unknown = byKind.keys.filter { !known.contains($0) }.sorted()
        return (known + unknown).compactMap { kind in
            byKind[kind].map { Group(kind: kind, documents: $0) }
        }
    }

    static func groupTitle(kind: String) -> String {
        switch kind {
        case "bead": return "Bead"
        case "overview": return "Overviews"
        case "architecture": return "Architecture"
        case "decision": return "Decisions"
        case "reference": return "Reference"
        case "runbook": return "Runbooks"
        case "skill": return "Skills"
        case "agent": return "Agents"
        case "": return "Other"
        default: return kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }
}
