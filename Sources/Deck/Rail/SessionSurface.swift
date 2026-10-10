import Foundation

/// What a session's main surface should be — the rail's dot, and the pane
/// `ContentView.mainPane` draws — given whether Deck configured the row (a
/// crew or a pinned sibling) or merely discovered it (`session-agent
/// sessions` found it), and what the rail's last poll knows.
///
/// THE TEST IS WHETHER THERE IS AN AGENT, NOT WHO CREATED THE SESSION. A
/// discovered session with no agent gets no `StartSessionView`: Deck did
/// not create it, so it has no directory or command to launch one with, and
/// offering one turns a plain shell someone is using into an invitation to
/// clobber it. This is the same doctrine the `⊞` window leaves already
/// follow — the raw terminal is the honest surface for something
/// `claude_pane` cannot read. See
/// `deck/specs/multiple-sessions-per-project` §"Windows created by hand".
///
/// PURE, so the four cases the spec pins are testable with no poll and no
/// view: a stopped crew/pinned row, a discovered session with an agent, a
/// discovered session with no reading yet, and a discovered session
/// confirmed to have no agent.
enum SessionSurface: Equatable {
    /// No agent, and Deck knows how to start one — `StartSessionView`'s
    /// Start button. Only reachable when `isDiscovered` is false: a crew or
    /// a pinned child, which Deck configured itself and so has a directory
    /// and a command for.
    case start
    /// The conversation pane: the session has an agent, or nothing yet says
    /// it doesn't.
    case conversationPane
    /// The raw terminal, with no dot and no Start offer — a session Deck
    /// did not create, confirmed by the mini to have no agent.
    case terminalOnly
    /// A stopped crew or pinned child with no usable `workingDirectory` to
    /// start in — refused rather than started. `ContentView.start` only
    /// passes `-c <directory>` to tmux when a directory is present, so a
    /// directory-less Start creates the session wherever the ssh login lands
    /// (`$HOME`). That is self-reinforcing rather than merely untidy:
    /// `SessionGrouping`'s path rule can only claim a session inside a
    /// crew's own directory, and `$HOME` is outside every crew's, so the
    /// session that most needs grouping is created in the one place
    /// guaranteeing it never can be. See `issue_01M1KXWJDHMDATQM5K57FQ2PE7`.
    ///
    /// A directory that is present but invalid lands here too — see
    /// `isUsableDirectory(_:)`.
    case missingDirectory

    /// A crew's own row or one of its pinned children, confirmed by a poll
    /// to have no tmux session behind it at all — `PinnedRowLiveness.stale`.
    /// Attaching (the conversation pane) or opening the raw terminal both
    /// run `tmux new-session -A -D`, which CREATES a session under the old
    /// name rather than resuming anything, silently erasing the evidence
    /// that the row had gone stale. Refused rather than acted on, the same
    /// doctrine `.missingDirectory` follows: the row's only ways forward are
    /// an explicit Start (deliberately recreating it) or removing the pin.
    /// See `issue_01M1KXVY8MNNNG53NFBT8SY58Z`.
    case stale

    /// `isDiscovered` is true for a session that is not a crew id, a pinned
    /// child, or a catalog entry — the only rows Deck configures itself.
    /// `isStopped` and `hasReading` are `RailStateModel`'s own readings:
    /// `RailStateModel.isStopped(_:)` and `isAlive(_:) || isStopped(_:)`.
    /// `hasDirectory` defaults `true` so every discovered-session case above
    /// (which never reads it) and every existing configured-row case keep
    /// their prior answer unchanged; only a configured row that is both
    /// stopped and without a usable directory moves, from `.start` to
    /// `.missingDirectory`. Callers compute it with `isUsableDirectory(_:)`.
    ///
    /// `hasPolled` and `hasTmuxSession` default to `true`, so every existing
    /// call site — every test above, and every catalog-row caller that has
    /// no liveness reading of its own to pass — resolves exactly as before;
    /// they only move a result when a caller has a real reading and passes
    /// it explicitly. The `.stale` check defers to `PinnedRowLiveness.choose`
    /// rather than a second copy of its rule, so the two can never drift.
    static func choose(
        isDiscovered: Bool, isStopped: Bool, hasReading: Bool, hasDirectory: Bool = true,
        hasPolled: Bool = true, hasTmuxSession: Bool = true
    ) -> SessionSurface {
        guard isDiscovered else {
            if PinnedRowLiveness.choose(
                hasPolled: hasPolled, isStopped: isStopped, hasTmuxSession: hasTmuxSession
            ) == .stale {
                return .stale
            }
            guard isStopped else { return .conversationPane }
            return hasDirectory ? .start : .missingDirectory
        }
        guard isStopped, hasReading else { return .conversationPane }
        return .terminalOnly
    }

    /// Whether a configured row's `workingDirectory` is one Deck can start
    /// in: present, and accepted by `validateWorkingDirectory`, the check
    /// `SessionAgent.startArguments` applies before it runs anything. A folder
    /// the Settings field saved despite its warning (a relative path, a
    /// space, a `..`) makes that start throw, so it must gate to
    /// `.missingDirectory` rather than offer a Start that can only fail
    /// (`issue_01M1N7EXJ80BS3B0B8QB9MJRPJ`).
    static func isUsableDirectory(_ path: String?) -> Bool {
        guard let path else { return false }
        return (try? validateWorkingDirectory(path)) != nil
    }

    /// Whether `ContentView.mainPane` draws the live `SessionPaneView` for a
    /// session with this surface — the one predicate both `mainPane`'s own
    /// branch and the toolbar's overflow-menu gate read
    /// (`ContentView.sessionPaneIsShowing`), so the two conditions cannot
    /// drift the way a hand-copied second copy of this once did: during the
    /// launch-in-flight window (`ContentView.launching.insert` to
    /// `.remove`), `surface` still reads `.start` because the rail has not
    /// polled yet, but `mainPane` already falls through to
    /// `SessionPaneView` with `isLaunching: true` — hence the
    /// `isLaunching` override on the `.start` case below.
    func showsConversationPane(
        hasSessionPane: Bool, isShowingTerminal: Bool, hasHostTarget: Bool, isLaunching: Bool
    ) -> Bool {
        hasSessionPane
            && !isShowingTerminal
            && hasHostTarget
            && self != .missingDirectory
            && self != .terminalOnly
            && self != .stale
            && (self != .start || isLaunching)
    }
}
