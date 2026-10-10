import Foundation

/// What a session can be told to do by name — the slash commands and skills
/// Claude Code loaded for it, as `session-agent commands` reports them.
///
/// WHY DECK SHOWS THIS AT ALL. The composer takes a slash command, and until
/// this there was no way to know whether one had loaded except to type it and
/// watch. A command that is not there looks exactly like one that is, right up
/// to the moment it does nothing.
struct SessionCommands: Equatable {

    /// One invocable name.
    struct Entry: Equatable, Identifiable {
        enum Kind: String, Equatable {
            case command
            case skill
        }

        enum Scope: String, Equatable {
            /// From the project the session is working in.
            case project
            /// From `~/.claude`, so present in every session regardless of project.
            case user
        }

        let name: String
        let kind: Kind
        let scope: Scope
        let description: String?

        /// Set only when a skill's frontmatter `name` disagrees with the
        /// directory it lives in. The directory is what gets invoked, so that
        /// is what `name` holds; this is the other one, worth showing because
        /// a reader hunting a command by its declared name would not find it.
        let declaredName: String?

        /// The invocation as it would be typed.
        var slash: String { "/\(name)" }

        var id: String { "\(scope.rawValue):\(kind.rawValue):\(name)" }
    }

    /// Where the mini looked, and whether that directory was there. Reported so
    /// the pane can tell "this project defines no commands" from "this session
    /// has no project directory to define them in" — different answers to
    /// someone hunting a command that is not appearing.
    struct Source: Equatable {
        let scope: Entry.Scope
        let path: String
        let exists: Bool
    }

    let cwd: String?
    let sources: [Source]
    let entries: [Entry]

    /// PROJECT FIRST, AND THE MINI ALREADY SORTED IT. Re-sorting here would put
    /// two orderings in play that could disagree, so this preserves what it was
    /// given and the platform's test pins that order.
    static func decode(_ data: Data) -> SessionCommands? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let sources = (root["sources"] as? [[String: Any]] ?? []).compactMap { raw -> Source? in
            guard let scope = (raw["scope"] as? String).flatMap(Entry.Scope.init(rawValue:)),
                  let path = raw["path"] as? String else { return nil }
            return Source(scope: scope, path: path, exists: raw["exists"] as? Bool ?? false)
        }
        // A ROW WITH NO NAME OR AN UNKNOWN KIND IS DROPPED, not defaulted. This
        // is a menu of things to type: an entry whose name Deck had to invent
        // would print an invocation that does nothing, which is the exact
        // failure the feature exists to remove.
        let entries = (root["commands"] as? [[String: Any]] ?? []).compactMap { raw -> Entry? in
            guard let name = raw["name"] as? String, !name.isEmpty,
                  let kind = (raw["kind"] as? String).flatMap(Entry.Kind.init(rawValue:)),
                  let scope = (raw["scope"] as? String).flatMap(Entry.Scope.init(rawValue:))
            else { return nil }
            return Entry(name: name, kind: kind, scope: scope,
                         description: raw["description"] as? String,
                         declaredName: raw["declared_name"] as? String)
        }
        return SessionCommands(cwd: root["cwd"] as? String, sources: sources, entries: entries)
    }

    /// What the menu says when it has nothing to list, which is not always the
    /// same sentence. An empty list with a project directory that exists is a
    /// fact about the project; an empty list with no such directory is a fact
    /// about the session, and telling a reader the first when the second is
    /// true sends them looking in the wrong place.
    var emptyExplanation: String? {
        guard entries.isEmpty else { return nil }
        let project = sources.first { $0.scope == .project }
        if project == nil {
            return "This session has no working directory, so only machine-wide commands apply — and there are none."
        }
        if project?.exists == false {
            return "No .claude directory in this session's project, and no machine-wide commands."
        }
        return "No commands or skills on disk for this session."
    }
}
