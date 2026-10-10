import Foundation

/// A hand-made tmux window (`ctrl-A c`), drawn as a terminal-only leaf under
/// the session that owns it — `deck/specs/multiple-sessions-per-project`
/// §"Windows created by hand". This type owns the leaf's synthetic row
/// identity and the pure rule for how many leaves a window count produces;
/// nothing here touches ssh or a view.
enum WindowLeaf {
    /// The rail's selection/tag for one session's extra window — tmux's own
    /// `session:window` addressing. `validateTmuxSessionName` rejects `:`
    /// (see `SSHTarget.swift`'s allowed charset), so this can never collide
    /// with a real tmux session name already validated elsewhere.
    static func id(session: String, window: Int) -> String {
        "\(session):\(window)"
    }

    /// Parses a leaf id back into its owning session and window number, or
    /// nil for anything else — in particular for a real session name, which
    /// by construction never contains a colon. Splits on the LAST colon so a
    /// session name that somehow carried one (it cannot, per the validator,
    /// but this function must not assume its input was validated) still
    /// yields a sane parse.
    static func parse(_ id: String) -> (session: String, window: Int)? {
        guard let colon = id.lastIndex(of: ":") else { return nil }
        let session = String(id[..<colon])
        let windowText = id[id.index(after: colon)...]
        guard !session.isEmpty, let window = Int(windowText), window > 0 else { return nil }
        return (session, window)
    }

    /// The window numbers a session's leaves should draw for, given its
    /// reported window count. `nil` (unknown) means no leaves — never
    /// assume there is a second window. `0` or `1` also mean no leaves:
    /// there is nothing beyond the session's own first window, and this
    /// must never produce a negative range.
    static func numbers(forWindowCount windows: Int?) -> [Int] {
        guard let windows, windows > 1 else { return [] }
        return Array(2...windows)
    }

    /// The `SessionRef` form of `id(session:window:)` — the rail's
    /// selection is now `(host, name)`, so a leaf's tag has to carry its
    /// owning session's host too, per
    /// `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// hosts": "`WindowLeaf`, whose `"<session>:<n>"` parse now sits under a
    /// host." `host` passes straight through unchanged — a leaf's window
    /// lives in the same tmux server as the session that owns it — and only
    /// the name half gets the `:<n>` suffix, via the existing string helper.
    static func ref(session: SessionRef, window: Int) -> SessionRef {
        SessionRef(host: session.host, name: WindowLeaf.id(session: session.name, window: window))
    }

    /// The `SessionRef` form of `parse(_:)`, splitting only the name half
    /// and carrying `host` through unchanged.
    static func parse(_ ref: SessionRef) -> (session: SessionRef, window: Int)? {
        guard let parsed = WindowLeaf.parse(ref.name) else { return nil }
        return (SessionRef(host: ref.host, name: parsed.session), parsed.window)
    }
}
