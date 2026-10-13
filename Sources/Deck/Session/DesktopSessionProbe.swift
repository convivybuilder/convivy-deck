import Foundation

/// A host's reading of whether the ssh account has a desktop session —
/// CQ·124: macmini's services are per-user LaunchAgents, which run only while
/// that account is logged in at the console, and macOS logs in only one
/// account automatically on reboot.
///
/// POSITIVE EVIDENCE BOTH WAYS. `.loggedIn` and `.loggedOut` each come from
/// a specific, named shape of `launchctl print gui/$(id -u)`'s own answer —
/// see `DesktopSessionProbe.classify`. Anything else — an ssh failure, a
/// timeout, unexpected text — is `.unknown`, which never raises an alert
/// (`DesktopSessionTracker`).
enum DesktopSessionReading: Equatable, Sendable {
    case loggedIn
    case loggedOut
    case unknown
}

/// Runs and classifies the probe. See `deck/specs` (CQ·124's PR body) for
/// the real samples this was checked against: a logged-in account's
/// `launchctl print gui/$(id -u)` on macstudio exits 0. The logged-out shape
/// confirmed live is exit 125 with "Domain does not support specified
/// action", recorded by Shipwright on 2026-10-02 self-probing a logged-out
/// account (macmini, uid 504, no console session) — see `classify`. macOS's
/// own documented "Could not find domain for" text is kept as logged out
/// too, though still unseen from a self-probe on this fleet.
enum DesktopSessionProbe {
    /// Same ControlMaster options as `SessionAgent`'s verbs, so this rides
    /// the connection the rail's `states`/`sessions` calls already hold
    /// open, rather than negotiating a second one — the cadence this rides
    /// is `RailStateModel.refresh()`'s existing poll, not a new one.
    ///
    /// `$(id -u)` is sent LITERALLY, not expanded locally: ssh joins its
    /// trailing arguments with a space and hands the result to the remote
    /// shell, which is what expands it against the REMOTE account's own
    /// uid — the whole reason this command works unmodified against any
    /// configured host.
    static func arguments(
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
            "launchctl", "print", "gui/$(id -u)",
        ], home: home)
    }

    /// Classifies a failed probe's exit status and stderr text together.
    /// Per CQ·124: "An ssh failure, a timeout, or any other output is
    /// unknown, and unknown never notifies as logged out."
    ///
    /// Exit 125 with "Domain does not support specified action" is the
    /// shape Shipwright recorded live (2026-10-02, macmini, uid 504) from a
    /// self-probe of a logged-out account, and BOTH the status and the text
    /// are required: the text alone is also what a cross-user probe (asking
    /// for another account's domain while being someone else) answers, and
    /// Deck never probes as anyone but the target account itself, so that
    /// ambiguity doesn't reach production — see
    /// `testADifferentDomainErrorNowClassifiesAsLoggedOut`.
    ///
    /// "Could not find domain for" is macOS's own documented logged-out
    /// text, kept as logged out on its text alone — it has not yet turned
    /// up from a self-probe on this fleet, only recorded from Apple's docs.
    static func classify(exitStatus: Int32, errorText: String) -> DesktopSessionReading {
        let text = errorText.lowercased()
        if text.contains("could not find domain for") {
            return .loggedOut
        }
        if exitStatus == 125 && text.contains("domain does not support specified action") {
            return .loggedOut
        }
        return .unknown
    }

    /// Runs the probe off the current task and classifies the result.
    /// Never throws: every failure this can hit — a bad target, a
    /// transport failure, the remote command's own non-zero exit — is a
    /// `DesktopSessionReading` in its own right rather than an error the
    /// caller has to handle separately, which is what lets
    /// `RailStateModel.refresh()` use this exactly like its other
    /// non-throwing fetch seams.
    ///
    /// Goes to `SSHProcessRunner.runQueued` rather than `SessionAgent.run` —
    /// `classify` needs the remote exit status alongside stderr, and
    /// `SessionAgent.run` discards it into an `AgentError.failed(String)`.
    /// Queued rather than plain `run`, because the rail polls this beside
    /// `fetchStates` on the same ControlMaster, so it must count against
    /// `SSHConnectionGate`'s cap.
    static func probe(target: SSHTarget) -> DesktopSessionReading {
        do {
            let argv = try arguments(target: target)
            let outcome = try SSHProcessRunner.runQueued(argv, timeout: SessionAgent.defaultTimeout)
            if outcome.timedOut {
                return .unknown
            }
            if outcome.terminationStatus == 0 {
                return .loggedIn
            }
            return classify(exitStatus: outcome.terminationStatus, errorText: outcome.stderr)
        } catch {
            return .unknown
        }
    }
}

/// The last DEFINITE reading `DesktopSessionTracker` has settled on for a
/// host — never `.unknown`: an unknown reading holds whatever this already
/// was rather than becoming a third stored state. See
/// `DesktopSessionTracker.apply`.
enum DesktopSessionKnownState: Equatable, Sendable {
    case loggedIn
    case loggedOut
}

/// The one-alert-per-transition rule (CQ·124), as a pure function of
/// one reading and the last known definite state — so the rule is pinned by
/// a test without an ssh round trip, the same discipline `RailPoll` follows
/// for the rail's other merges.
enum DesktopSessionTracker {
    /// `lastKnown` is `nil` exactly once per host: before its first
    /// reading ever lands. CQ·124 treats that the same as a prior
    /// `.loggedIn` reading — "On a change from logged in (OR THE FIRST
    /// READING) to logged out" — so a host discovered already logged out
    /// raises its alert on its very first poll, rather than needing to be
    /// seen logged in first.
    static func apply(
        reading: DesktopSessionReading, lastKnown: DesktopSessionKnownState?
    ) -> (next: DesktopSessionKnownState?, notify: Bool) {
        switch reading {
        case .unknown:
            // "A run of unknown readings doesn't reset or trigger
            // anything" — the known state, and whether a future
            // logged-out reading would raise a new alert, both pass
            // through unchanged.
            return (lastKnown, false)
        case .loggedIn:
            return (.loggedIn, false)
        case .loggedOut:
            return (.loggedOut, lastKnown != .loggedOut)
        }
    }
}
