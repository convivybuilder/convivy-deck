import Foundation

/// Derives a sibling session's tmux name from a crew id and a user-typed
/// short label — the naming rule `design-multiple-sessions.md` §A specifies:
/// `<crew-id>--<slug>`, double-dash, because a single dash already occurs
/// inside fleet names (`sous-chef`) and `--` cannot collide with one.
///
/// PURE, DELIBERATELY. This is the part of "move a window to its own
/// session" (`ContentView.moveWindowToOwnSession`, its one remaining caller)
/// that can be silently wrong — a slug that collapses two different labels
/// to the same name, or a derived name that slips past
/// `validateTmuxSessionName` — so it is exercised by tests without a tmux
/// session or an ssh round trip anywhere near it.
enum SiblingSessionName {
    enum DerivationError: Error, Equatable {
        /// The label held nothing `slugify` could keep — all punctuation, all
        /// whitespace, or empty outright.
        case emptyLabel
        /// The derived name failed `validateTmuxSessionName` — in practice
        /// this means it ran past the 64-character budget, since `slugify`
        /// never emits a character the validator would reject.
        case invalidName(String)
        /// The derived name matches a session already on the rail.
        case collision(String)
    }

    /// `existingNames` is every session name already in play — other pinned
    /// children, every crew id, and catalog entries — so a derived name
    /// cannot shadow any of them. The caller assembles that set; this
    /// function only judges the one name it derives.
    static func derive(crewId: String, label: String,
                       existingNames: Set<String>) throws -> String {
        let slug = slugify(label)
        guard !slug.isEmpty else { throw DerivationError.emptyLabel }
        let candidate = "\(crewId)--\(slug)"
        guard let name = try? validateTmuxSessionName(candidate) else {
            throw DerivationError.invalidName(candidate)
        }
        guard !existingNames.contains(name) else {
            throw DerivationError.collision(name)
        }
        // A name that passes the check above can still collide once
        // `scratchShellSessionName` truncates it for its own 53-character
        // budget — the risk this PR introduces, since a rail-only session
        // name never ran past 15 characters. Two names that agree on their
        // first 53 characters would otherwise attach the same scratch shell,
        // and `-D` would detach whichever session opened its shell first.
        guard !scratchShellCollides(name, with: existingNames) else {
            throw DerivationError.collision(name)
        }
        return name
    }

    /// Lowercases, keeps letters and digits, and collapses every run of
    /// anything else to a single `-` — so "Tax 2025" and "tax—2025!!" both
    /// become `tax-2025`, and a run of separators never leaves a doubled or
    /// trailing dash for `derive` to trip over. Leading/trailing separators
    /// are dropped outright rather than turned into a dash nobody typed.
    static func slugify(_ label: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        var result = ""
        var pendingDash = false
        for scalar in label.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                if pendingDash && !result.isEmpty { result += "-" }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else if !result.isEmpty {
                pendingDash = true
            }
        }
        return result
    }
}
