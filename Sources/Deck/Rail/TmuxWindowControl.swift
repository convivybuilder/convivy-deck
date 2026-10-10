import Foundation

/// Direct tmux control for a window leaf: `select-window` and `move-window`,
/// run as plain ssh commands rather than through `session-agent` — there is
/// no such verb for either, because these are tmux mechanics, the same tier
/// `sshArguments` in `SSHTarget.swift` operates at, not session state. See
/// `deck/specs/multiple-sessions-per-project` §"Windows created by hand".
enum TmuxWindowControl {
    enum ControlError: Error, Equatable {
        case invalidWindowNumber(Int)
    }

    /// tmux windows are 1-based and no real session runs into the hundreds
    /// of them; this is defence in depth for a number that lands in ssh
    /// argv, the same reasoning every other validated field here gets.
    static func validateWindowNumber(_ n: Int) throws -> Int {
        guard n > 0, n <= 999 else { throw ControlError.invalidWindowNumber(n) }
        return n
    }

    /// argv for `tmux select-window -t <session>:<n>`.
    ///
    /// SAFE BECAUSE `-D` IS ALWAYS ON. Every Deck attach carries `-D`
    /// (`sshArguments`), which guarantees at most one client per session, so
    /// moving that session's current window cannot resize or disturb
    /// another client — the design doc's own reasoning for why this leaf
    /// gesture is safe to send blind.
    ///
    /// `target.user`/`.host` are re-validated here even though every real
    /// caller already sourced them from an already-validated `HostEntry` —
    /// the same "validate again where argv is built" defence in depth
    /// `sshArguments` and every `SessionAgent` argv builder apply to their
    /// own `target`. `target:` was hardcoded to `.mini` here until phase 6b
    /// threaded a config-resolved target through, which is what makes this
    /// gate load-bearing rather than moot.
    static func selectWindowArguments(
        target: SSHTarget,
        session: String,
        window: Int,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        let name = try validateTmuxSessionName(session)
        let n = try validateWindowNumber(window)
        return withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            "tmux", "select-window", "-t", "\(name):\(n)",
        ], home: home)
    }

    /// argv for `tmux move-window -s <session>:<n> -t <newName>:`, promoting
    /// a hand-made window to its own sibling session. The trailing colon on
    /// `-t` is tmux's own syntax for "a new session by this name, seeded
    /// from this window" — verified on the mini with an isolated socket, per
    /// the spec's tmux experiments.
    static func moveWindowArguments(
        target: SSHTarget,
        session: String,
        window: Int,
        newSessionName: String,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        let name = try validateTmuxSessionName(session)
        let n = try validateWindowNumber(window)
        let newName = try validateTmuxSessionName(newSessionName)
        return withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            "tmux", "move-window", "-s", "\(name):\(n)", "-t", "\(newName):",
        ], home: home)
    }

    /// Selects window `n` in `session` on the mini. Fire-and-forget from the
    /// caller's side: Deck's own selection already moved, and this is only
    /// telling tmux to follow, per the design's "Deck's selection and
    /// tmux's current window stay decoupled" — a failure here leaves the
    /// terminal pane attached but pointed at whichever window tmux was
    /// already on, which the next poll's own drawing will still reflect
    /// correctly.
    @discardableResult
    static func selectWindow(target: SSHTarget, session: String, window: Int) throws -> Data {
        try SessionAgent.run(selectWindowArguments(target: target, session: session, window: window))
    }

    /// Moves window `n` out of `session` into a brand-new session named
    /// `newSessionName`, promoting it to a full sibling.
    @discardableResult
    static func moveWindow(target: SSHTarget, session: String, window: Int,
                           newSessionName: String) throws -> Data {
        try SessionAgent.run(
            moveWindowArguments(target: target, session: session, window: window,
                                newSessionName: newSessionName))
    }
}
