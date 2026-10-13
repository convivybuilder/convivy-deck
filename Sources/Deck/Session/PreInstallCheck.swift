import Foundation

/// What the pre-install check found on a host (E22, CQ·159). Only `.ready`
/// lets the install start; every other reading is shown to the person as
/// what is missing and what they do about it.
enum PreInstallReading: Equatable, Sendable {
    case ready
    case claudeNotInstalled
    /// Carries what `claude` printed, which is the person's best clue —
    /// "Not logged in · Please run /login", or an expired-session message.
    case claudeSignedOut(String)
    case desktopLoggedOut
    /// The check itself failed (ssh, a timeout): no evidence either way,
    /// so the install does not start.
    case couldNotCheck(String)

    var allowsInstall: Bool { self == .ready }

    /// One sentence saying what is missing and what the person does.
    func explanation(hostName: String) -> String {
        switch self {
        case .ready:
            return "\(hostName) is ready for the install."
        case .claudeNotInstalled:
            return "Claude Code is not installed on \(hostName). Install it there and sign in, then try again."
        case .claudeSignedOut(let text):
            let said = text.isEmpty ? "" : " It said: \(text)"
            return "Claude Code on \(hostName) is not signed in. Run claude there and sign in, then try again.\(said)"
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
            "claude", "-p", "ok", "--max-turns", "1", "--model", "haiku",
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
