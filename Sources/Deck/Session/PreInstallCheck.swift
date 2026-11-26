import Foundation

/// One step of the setup pane's composed remote command (E22, CQ·200).
/// `PreInstallReading.setupSteps` picks which steps a host needs; a step
/// here is the exact command text that runs, with nothing of Deck's own.
enum SetupStep: Equatable, Sendable {
    case installClaudeCode
    case signIntoClaudeCode
    case installBuilderServer

    var command: String {
        switch self {
        case .installClaudeCode:
            return "curl -fsSL https://claude.ai/install.sh | bash"
        case .signIntoClaudeCode:
            return "claude auth login"
        case .installBuilderServer:
            return BuilderServerInstall.command
        }
    }
}

/// What the pre-install check found on a host (E22, CQ·159). `setupSteps`
/// decides what the setup pane runs; `.desktopLoggedOut` and
/// `.couldNotCheck` start nothing and are shown to the person as what is
/// missing and what they do about it.
enum PreInstallReading: Equatable, Sendable {
    case ready
    case claudeNotInstalled
    /// Carries what `claude` printed, which is the person's best clue —
    /// "Not logged in · Please run /login", or an expired-session message.
    case claudeSignedOut(String)
    case desktopLoggedOut
    /// The check itself failed (ssh, a timeout): no evidence either way,
    /// so setup does not start.
    case couldNotCheck(String)

    /// The steps the setup pane runs, in order, skipping what this reading
    /// says the host already has. Empty for the two readings that start
    /// nothing.
    var setupSteps: [SetupStep] {
        switch self {
        case .ready:
            return [.installBuilderServer]
        case .claudeSignedOut:
            return [.signIntoClaudeCode, .installBuilderServer]
        case .claudeNotInstalled:
            return [.installClaudeCode, .signIntoClaudeCode, .installBuilderServer]
        case .desktopLoggedOut, .couldNotCheck:
            return []
        }
    }

    var allowsSetup: Bool { !setupSteps.isEmpty }

    /// One sentence saying what blocked the check and what the person does,
    /// for a reading that starts nothing. `nil` for a reading that starts a
    /// setup step instead — the pane installs Claude Code and signs it in
    /// itself, so the person is never told to do either by hand.
    func explanation(hostName: String) -> String? {
        switch self {
        case .ready, .claudeNotInstalled, .claudeSignedOut:
            return nil
        case .desktopLoggedOut:
            return "Nobody is logged in at \(hostName)\u{2019}s desktop. Log in to this account at the Mac\u{2019}s "
                + "own screen, then try again."
        case .couldNotCheck(let text):
            return "Deck could not check \(hostName): \(text)"
        }
    }
}

/// Runs the pre-install check over the host's existing ssh connection.
///
/// THE SIGN-IN HALF IS A REAL MODEL REQUEST, `claude -p ok --max-turns 1`,
/// as Shipwright specified (E22's thread, 2026-10-11): `claude auth status`
/// reads only that a credential file is present and reports a dead token
/// as logged in, so it cannot be the gate. It costs one small request, and
/// runs only when the person clicks to install.
///
/// THE DESKTOP HALF REUSES `DesktopSessionProbe`. Only its positive
/// `.loggedOut` blocks: a Linux host has no `launchctl`, which that probe
/// already reads as `.unknown`, and that is how "does not apply on Linux"
/// falls out with no OS detection of Deck's own.
enum PreInstallCheck {
    /// Long enough for one model round trip from the host; a hung `claude`
    /// still ends as `.couldNotCheck`.
    static let timeout: TimeInterval = 60

    /// The remote command, run through the user's LOGIN shell. ssh runs a
    /// command in a non-login shell, and Claude Code's Linux installer puts
    /// `claude` in `~/.local/bin`, which a stock Debian account adds to PATH
    /// only in `.profile`. Run bare, `claude` was not found on such a host
    /// and the check reported it not installed (live install check 2,
    /// 2026-10-20).
    ///
    /// `~/.local/bin` GOES ON PATH HERE TOO, the same as in the setup chain
    /// (`BuilderServerInstall.chain`), because on a Mac a login shell does
    /// not have it. Measured on a clone of a fresh macOS 26.6.2 account,
    /// 2026-11-06: Anthropic's installer succeeded and printed a note that
    /// the folder is not on PATH, it wrote no shell profile, and this check
    /// exited 127. A retry would then install Claude Code again on every
    /// attempt, where E22 says a retry skips the steps already done. Keeping
    /// `claude` on the PATH of later crew sessions is Builder's installer's
    /// job, which the setup runs after this check.
    /// `$SHELL` is expanded by the remote shell; the text is fixed.
    static let claudeCommand =
        #"exec "$SHELL" -lc 'export PATH="$HOME/.local/bin:$PATH"; claude -p ok --max-turns 1 --model haiku'"#

    static func claudeArguments(
        target: SSHTarget,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        return withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            claudeCommand,
        ], home: home)
    }

    /// Classifies the `claude -p` run. Exit 0 is signed in. 127 or "command
    /// not found" is not installed. 255 is ssh's own transport failure, and
    /// a watchdog kill is a timeout: neither says anything about the
    /// sign-in. Any other exit is not signed in, with what it printed.
    static func classifyClaude(exitStatus: Int32, errorText: String, timedOut: Bool) -> PreInstallReading {
        let text = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut {
            return .couldNotCheck("claude did not answer within \(Int(timeout))s")
        }
        if exitStatus == 0 {
            return .ready
        }
        if exitStatus == 127 || text.contains("command not found") {
            return .claudeNotInstalled
        }
        if exitStatus == 255 {
            return .couldNotCheck(text.isEmpty ? "ssh failed" : text)
        }
        return .claudeSignedOut(text)
    }

    /// A logged-out desktop is reported first: on a Mac it is also why
    /// `claude` cannot read its Keychain login, so it is the thing to fix.
    static func combine(desktop: DesktopSessionReading, claude: PreInstallReading) -> PreInstallReading {
        desktop == .loggedOut ? .desktopLoggedOut : claude
    }

    static func run(target: SSHTarget) -> PreInstallReading {
        let desktop = DesktopSessionProbe.probe(target: target)
        if desktop == .loggedOut {
            return .desktopLoggedOut
        }
        do {
            let outcome = try SSHProcessRunner.runQueued(try claudeArguments(target: target), timeout: timeout)
            return combine(
                desktop: desktop,
                claude: classifyClaude(
                    exitStatus: outcome.terminationStatus, errorText: outcome.stderr, timedOut: outcome.timedOut))
        } catch {
            return .couldNotCheck("\(error)")
        }
    }
}
