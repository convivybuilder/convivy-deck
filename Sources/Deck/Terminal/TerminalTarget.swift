import Foundation

/// What a terminal pane connects to.
///
/// Deck exists to reach the fleet, so a remote tmux session is the common case.
/// But once Deck is the window you live in, not having a local shell means
/// leaving it to do anything on your own machine — which is how this got added:
/// "I've lost my ability to quickly summon a terminal on my laptop."
enum TerminalTarget: Equatable {
    /// A tmux session on the mini, over ssh. tmux is the persistence layer, so
    /// the pane is disposable and can reattach without losing fleet-side state.
    ///
    /// The working directory is used only when Deck has to create the
    /// session: the same session started from two different directories is
    /// still one session, so a config edit to it must not tear down and
    /// respawn a live pane.
    ///
    /// `target` resolves the crew's host (`HostResolution`), and is required
    /// rather than defaulted — there is no implied host left to fall back to.
    ///
    /// SWIFTUI IDENTITY FOR A PANE ON THIS TARGET NEVER COMES FROM THIS
    /// TYPE. Every real call site tags its view with the owning
    /// `SessionRef` explicitly (`.id(selection)`,
    /// `.id("pane-\(selection.stringForm)")`) — `TerminalTarget` used to
    /// carry its own `id`/`themeKey`, computed from the bare `name` here,
    /// and nothing read either for this case. Once more than one host
    /// exists a bare name is not a safe identity on its own — two crews
    /// sharing a name on different hosts would collide — so the computed
    /// properties were removed rather than left as a trap for the next
    /// reader to reach for. See
    /// `deck/specs/multiple-sessions-per-project` §"Crews on different
    /// hosts".
    case remoteSession(name: String, workingDirectory: String?, target: SSHTarget)

    /// A login shell on this machine. No tmux, so nothing survives the pane
    /// closing — deliberate: a local terminal for quick work is not a session
    /// to be preserved, and silently persisting one would be surprising.
    case localShell

    /// The scratch shell beside the conversation: its own tmux session on the
    /// mini, one per fleet session, in that session's working directory.
    ///
    /// TMUX, AND THE REASON IS A BUG THIS FIXED. It used to be a bare login
    /// shell whose `id` was its DIRECTORY, so changing the selected session
    /// changed the id, SwiftUI tore the pane down, and teardown killed the ssh
    /// process — taking whatever was running in it. The operator: "if you have a shell
    /// open beside a co, and then you change co sessions, it kills the shell
    /// session." A shell that dies when you glance at another session cannot be
    /// trusted with a long command, which is most of what a shell is for.
    ///
    /// Keyed on the SESSION owning it — a caller tags the view with the
    /// owning `SessionRef`, the way every real call site does (see
    /// `remoteSession`'s doc) — rather than the directory, so the pane
    /// still swaps when you switch — you want the shell for what you are
    /// looking at — while the tmux session underneath survives, and
    /// switching back reattaches to the same scrollback with the same
    /// command still running. It survives a Deck restart for the same
    /// reason the agent panes do.
    ///
    /// The directory is honoured when the session is created and ignored
    /// when attaching, so a changed cwd does not respawn a shell you are
    /// working in. Nothing here injects a `cd` into a live shell.
    ///
    /// One session per rail row, which is what bounds these: the name is derived
    /// from the fleet session, so a rail of fifteen can produce at most fifteen.
    /// There is nothing to reap.
    ///
    /// `target` follows the fleet session's own resolved host, the same
    /// reasoning `remoteSession.target` documents.
    case remoteShell(session: String, workingDirectory: String?, target: SSHTarget)
}

/// Resolves the executable and argv for a target.
///
/// Local shell resolution prefers `$SHELL`, because a user who has chosen a
/// shell has done so deliberately and Deck should not second-guess it. The
/// fallback chain exists because `$SHELL` can be absent or unusable in a GUI
/// app's environment: an app launched from Finder inherits launchd's
/// environment, not a login shell's.
enum TerminalLaunch {
    static let fallbackShell = "/bin/zsh"

    static func executableAndArguments(
        for target: TerminalTarget,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (executable: String, arguments: [String]) {
        switch target {
        case .remoteSession(let name, let workingDirectory, let sshTarget):
            return (
                "/usr/bin/ssh",
                try sshArguments(target: sshTarget, tmuxSession: name, workingDirectory: workingDirectory)
            )

        case .remoteShell(let session, let workingDirectory, let sshTarget):
            // The same attach the agent panes use, against a session named for
            // this one. `new-session -A` creates it the first time and reattaches
            // afterwards, which is the whole persistence story — no separate
            // create step, and no way for Deck to be holding the only handle on
            // the shell's process.
            return (
                "/usr/bin/ssh",
                try sshArguments(target: sshTarget, tmuxSession: scratchShellSessionName(for: session),
                                 workingDirectory: workingDirectory)
            )

        case .localShell:
            // `-l` so the shell sources the user's profile. Without it a pane
            // launched from Finder has none of the PATH, aliases, or functions
            // the same shell would have in Terminal.app, which makes it look
            // broken rather than merely different.
            return (resolvedShell(environment: environment), ["-l"])
        }
    }

    /// `$SHELL` is used only when it names an executable regular file. A stale
    /// or bogus value would otherwise fail at spawn time with no useful signal.
    static func resolvedShell(environment: [String: String]) -> String {
        if let shell = environment["SHELL"], isRunnable(shell) {
            return shell
        }
        return isRunnable(fallbackShell) ? fallbackShell : "/bin/sh"
    }

    /// Where a locally-spawned shell starts.
    ///
    /// THE HOME DIRECTORY, EXPLICITLY, because a GUI app has no useful working
    /// directory to inherit. Launched from the Dock, Deck's own cwd is `/`, so
    /// the local shell opened at the top level of the machine — a prompt in a
    /// directory nobody keeps anything in, one `cd` away from being useful every
    /// single time. Reported by the operator.
    ///
    /// Only the local shell needs this: a remote target's directory is decided
    /// on the far side by tmux or by the login shell's own default.
    static var localWorkingDirectory: String { NSHomeDirectory() }

    /// Where a local shell should start, given the directory the last one was
    /// sitting in when it was closed.
    ///
    /// The remembered path is RE-CHECKED rather than trusted. It was true when
    /// captured, and the gap to here is unbounded — a Deck restart, a branch
    /// deleted, an unmounted volume — so a path that is no longer a directory
    /// falls back to home instead of failing at spawn time with nothing on
    /// screen to explain it.
    ///
    /// Home is the fallback for every such case, deliberately undifferentiated:
    /// no directory remembered yet, one that has since gone, or one that was
    /// never a directory. All three mean the same thing here — there is nowhere
    /// better than home to start.
    static func localStartingDirectory(
        remembered: String?,
        directoryExists: (String) -> Bool = directoryIsReachable
    ) -> String {
        guard let remembered, directoryExists(remembered) else { return localWorkingDirectory }
        return remembered
    }

    /// A path is only worth launching in if it is still a directory. A shell
    /// that `cd`'d somewhere since deleted would otherwise hand a new process
    /// a path that fails at spawn time.
    static func directoryIsReachable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// `isExecutableFile` alone is not enough: the execute bit on a *directory*
    /// means traversable, so it answers true for `/tmp`. Spawning that would
    /// fail at exec time with nothing useful surfaced, so the directory check
    /// is what makes this a real guard rather than a decorative one.
    private static func isRunnable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
