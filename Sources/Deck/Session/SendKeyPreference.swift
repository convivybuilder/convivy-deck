import Foundation

/// Which keystroke sends a message, and which one inserts a newline.
///
/// This is a preference rather than a decision because the two populations
/// genuinely disagree. Chat clients send on Return, and a user coming from
/// Slack or iMessage will send half a sentence into a live agent session before
/// learning otherwise. Terminal and editor users expect Return to be a newline
/// and reach for a modifier to submit, and for them the chat idiom destroys
/// multi-line input. Neither is a default the other can live with.
enum SendKeyPreference: String, CaseIterable, Equatable {
    /// Return sends; Shift-Return inserts a newline. The chat idiom.
    case returnKey
    /// Command-Return sends; Return inserts a newline. The editor idiom, and
    /// what Deck shipped with.
    case commandReturn

    /// The chat idiom, because the pane is a conversation. The composer is a
    /// message box next to a Send button, and its neighbours in that role all
    /// send on Return.
    static let `default` = SendKeyPreference.returnKey

    /// Names the whole binding rather than the send key alone. "Return" as a
    /// label leaves the reader to guess what happened to the newline, which is
    /// the question a person picking between these is actually asking.
    var label: String {
        switch self {
        case .returnKey: return "Return sends, Shift-Return for a new line"
        case .commandReturn: return "Command-Return sends, Return for a new line"
        }
    }

    /// Whether a bare Return should send under this preference.
    var sendsOnBareReturn: Bool { self == .returnKey }
}
