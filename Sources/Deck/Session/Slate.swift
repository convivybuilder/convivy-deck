import Foundation

/// One crew's Slate: the asks a co has posted for the operator and the notes
/// the operator is holding to send, as `session-agent slate <name>` answers
/// it (CQ-358, agent-platform#752). See
/// issue_01M3WPJC2790N8JM8MGR7BQ5RJ's specification and
/// `platform/decisions/0091`.
///
/// Keyed by tmux session name on the crew's own host — nothing here is
/// fleet-wide, the way `SessionState` is scoped to one session.
struct Slate: Equatable {
    var session: String
    var cards: [SlateCard]
    /// The `capabilities` the host's session-agent lists. Empty when the envelope
    /// has none, which is how a host older than the capability reads.
    var capabilities: [String] = []
}

/// One card on a Slate. `.unknown` is not a failure to hide: the item's own
/// wording is "an unreadable card shows as state unknown and is never
/// dropped", so every element `session-agent` sends becomes exactly one
/// `SlateCard`, this case included, rather than vanishing from the list.
enum SlateCard: Equatable {
    case ask(Ask)
    case note(Note)
    /// A card whose `kind` was absent or unrecognised, or whose `kind` was
    /// `ask`/`note` but was missing the one field that kind cannot be shown
    /// without (`id`, or `question`/`text`). `id` is carried through when the
    /// raw entry had one, so a reader can still tell which card this was.
    case unknown(id: String?)

    /// A question or decision the co needs from the operator.
    struct Ask: Equatable {
        /// A closed set, agreed with the Bosun (epic comment 4593): anything
        /// else decodes to `.unrecognized` rather than a guess at the
        /// nearest known state.
        enum State: Equatable {
            case open, answered, resolved
            case unrecognized(String)

            init(wire: String) {
                switch wire {
                case "open": self = .open
                case "answered": self = .answered
                case "resolved": self = .resolved
                default: self = .unrecognized(wire)
                }
            }
        }

        var id: String
        var state: State
        /// Exactly what the co wrote. Rendered as a plain `Text(String)` —
        /// no Markdown, no `AttributedString` — so quotes, `$`, backticks
        /// and a newline all draw byte for byte.
        var question: String
        /// The operator's unsent answer, saved through `slate-edit` as it is
        /// typed. `nil` when nothing has been drafted yet.
        var answerDraft: String?
        /// The last answer actually delivered, or `nil` before the first
        /// send.
        var answer: String?
    }

    /// The operator's own card: a note held for a break point.
    struct Note: Equatable {
        enum State: Equatable {
            case draft, sent
            case unrecognized(String)

            init(wire: String) {
                switch wire {
                case "draft": self = .draft
                case "sent": self = .sent
                default: self = .unrecognized(wire)
                }
            }
        }

        var id: String
        var state: State
        var text: String
    }

    /// The id to key a write or a UI row on, or `nil` for an `.unknown` card
    /// that carried none.
    var id: String? {
        switch self {
        case .ask(let ask): return ask.id
        case .note(let note): return note.id
        case .unknown(let id): return id
        }
    }
}

extension Slate {
    /// Decodes `session-agent slate`'s `{"ok": true, "session": ..., "cards": [...]}`.
    ///
    /// `nil` ONLY WHEN THE ENVELOPE ITSELF COULD NOT BE READ AT ALL — not JSON,
    /// or not an object. That is the caller's own "state unknown": unlike
    /// `SessionState.decode`, which always has a fallback session name to
    /// hang an `.unknown` phase on, there is no card list to show in that
    /// case, so there is nothing a `Slate` value would add.
    static func decode(_ data: Data, fallbackSession: String) -> Slate? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let rawCards = root["cards"] as? [Any] ?? []
        return Slate(session: root["session"] as? String ?? fallbackSession,
                     cards: rawCards.map(SlateCard.decode),
                     capabilities: root["capabilities"] as? [String] ?? [])
    }
}

extension SlateCard {
    /// Decodes one card. Every element of the wire's `cards` array becomes
    /// exactly one `SlateCard` — `.unknown` included — so a malformed entry
    /// demotes itself rather than disappearing ahead of whatever card
    /// followed it on the wire.
    static func decode(_ raw: Any) -> SlateCard {
        guard let dict = raw as? [String: Any] else { return .unknown(id: nil) }
        // THE FIRST GUARD: the board file is co-written, and this id reaches
        // ssh argv verbatim in `slateEditArguments`/`slateSendArguments` —
        // `SessionAgent.validateCardId`'s own doc on why only a safe
        // character set may cross into it. An id that fails demotes the
        // whole card to `.unknown` rather than carrying the raw value
        // forward, the same degrade a missing `question`/`text` already
        // gets. Raised in review.
        let id = (dict["id"] as? String).flatMap(SessionAgent.validateCardId)
        switch dict["kind"] as? String {
        case "ask":
            guard let id, let question = dict["question"] as? String else { return .unknown(id: id) }
            return .ask(Ask(
                id: id,
                state: Ask.State(wire: dict["state"] as? String ?? ""),
                question: question,
                answerDraft: dict["answer_draft"] as? String,
                answer: dict["answer"] as? String))
        case "note":
            guard let id, let text = dict["text"] as? String else { return .unknown(id: id) }
            return .note(Note(
                id: id,
                state: Note.State(wire: dict["state"] as? String ?? ""),
                text: text))
        default:
            return .unknown(id: id)
        }
    }
}
