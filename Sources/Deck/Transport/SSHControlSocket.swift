import Foundation

/// What `ssh -O check` established about an existing control socket,
/// reduced to the one decision a caller needs: is it safe to delete the
/// socket file and retry through a fresh master.
enum SSHControlSocketCheck: Equatable {
    /// A master answered and reported itself running. The socket must not be
    /// touched — deleting a live master's socket file out from under it
    /// would take a working ControlMaster down for every other pane sharing
    /// it, not just the one that happened to check.
    case confirmedAlive
    /// The check failed FAST with ssh's own words for "nothing usable is
    /// listening here" — no process, the wrong kind of file at the path, or
    /// a socket nobody is bound to any more. Safe to delete: ssh has already
    /// said, authoritatively and quickly, that nothing is behind this path.
    ///
    /// Measured, not assumed: reproduced by hand for the PR this shipped in.
    /// `ControlMaster=auto` already recovers from most of this family on its
    /// own — a missing file, a plain non-socket file, and a socket file with
    /// no listener all let a normal connection through in well under a
    /// tenth of a second, the last of those via ssh's own logged "Stale
    /// control socket ... unlinking". This case exists for the caller that
    /// asked `-O check` directly rather than routing through a full connect.
    case confirmedDead
    /// The check could not complete within its own bound. See `classify`'s
    /// doc for why this counts as confirmation rather than a shrug.
    case unresponsive

    /// PURE classification of one `-O check` outcome, so the decision is
    /// pinned by a test with no ssh round trip — the same discipline
    /// `HostTestOutcome.classify` and `SSHStderrClassifier.classify` follow
    /// for ssh's own wording elsewhere.
    ///
    /// `timedOut` FOLDS INTO `.unresponsive`, NOT `.confirmedAlive`, and
    /// that is the one call here that is not obvious. A `-O check` that
    /// cannot even complete is not an ambiguous reading to be cautious
    /// about — it is the exact symptom the caller already observed on the
    /// connection this check exists to explain. Reproduced by hand: an
    /// AF_UNIX socket that accepts a connection and never answers hangs
    /// `-O check` for exactly as long as it hangs a real connection
    /// attempt, zero output either way, because the mux hello exchange
    /// itself never gets a reply — `-O check` has no ssh-side bound of its
    /// own any more than a real connection does. Reading a timeout here as
    /// "leave the socket alone" would mean the one failure this mechanism
    /// exists for — a wedged master — never clears.
    static func classify(exitCode: Int32, stderr: String, timedOut: Bool) -> SSHControlSocketCheck {
        guard !timedOut else { return .unresponsive }
        guard exitCode != 0 else { return .confirmedAlive }
        let lower = stderr.lowercased()
        let deadPhrases = [
            "no such file or directory",
            "connection refused",
            "operation on non-socket",
        ]
        return deadPhrases.contains(where: lower.contains) ? .confirmedDead : .unresponsive
    }

    /// Whether this outcome justifies deleting the socket file and retrying
    /// once — see `SessionAgent.run`. Only a master that answered and
    /// claimed to be alive holds the file in place; both terminal readings
    /// that follow from a check that could not confirm a live master count.
    var warrantsClearing: Bool {
        switch self {
        case .confirmedAlive: return false
        case .confirmedDead, .unresponsive: return true
        }
    }
}

/// Checks and clears a possibly-wedged control socket — the recovery path
/// `SessionAgent.run` takes after a transport failure, never on a healthy
/// connection (see its own doc for why speculative clearing is not this).
enum SSHControlSocket {
    /// How long `check` and the config-resolution step in `clear` are each
    /// allowed before counting as unresponsive. Short, because both are
    /// meant to be local-only operations — a normal `-O check` against a
    /// live, responsive master returns in single-digit milliseconds, per
    /// this PR's own measurements — so anything that runs this long is
    /// already the failure `SSHControlSocketCheck.unresponsive` names.
    static let checkTimeout: TimeInterval = 5

    static func check(target: SSHTarget, controlPath: String) -> SSHControlSocketCheck {
        guard let argv = try? sshControlSocketCheckArguments(target: target, controlPath: controlPath),
              let outcome = try? SSHProcessRunner.run(argv, timeout: checkTimeout)
        else { return .unresponsive }
        return SSHControlSocketCheck.classify(
            exitCode: outcome.terminationStatus, stderr: outcome.stderr, timedOut: outcome.timedOut)
    }

    /// Deletes the concrete socket file `controlPath` (a template that may
    /// still carry ssh's own `%C` token) resolves to, so the next connection
    /// attempt finds nothing there and `ControlMaster=auto` opens a fresh
    /// master instead of repeating whatever `check` just found. Resolves
    /// through `ssh -G`, a purely local config dump with no network
    /// involved, rather than reimplementing ssh's own `%C` hash in Swift —
    /// see `resolvedControlPath(fromConfigOutput:)`.
    ///
    /// Silent on failure. A file another recovery attempt already removed,
    /// or one `ssh -G` could not resolve, leaves the caller no worse off
    /// than surfacing the original transport error would have — deleting
    /// nothing is always a safe outcome here, since a caller only reaches
    /// this after `check` has already said the socket is not a live
    /// master's.
    static func clear(target: SSHTarget, controlPath: String) {
        guard let argv = try? sshResolvedConfigArguments(target: target, controlPath: controlPath),
              let outcome = try? SSHProcessRunner.run(argv, timeout: checkTimeout),
              outcome.terminationStatus == 0,
              let resolved = resolvedControlPath(fromConfigOutput: outcome.stdout)
        else { return }
        try? FileManager.default.removeItem(atPath: resolved)
    }

    /// Pulls `controlpath`'s resolved value back out of `ssh -G`'s output —
    /// PURE, so the parsing is pinned by a test without an ssh round trip.
    /// `ssh -G` prints one `key value` pair per line, token-expanded, which
    /// is what turns the `%C` in `defaultControlPath()`'s template into the
    /// literal filename ssh itself would open.
    static func resolvedControlPath(fromConfigOutput data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0] == "controlpath" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty || value == "none" ? nil : value
        }
        return nil
    }
}
