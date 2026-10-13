import Foundation

/// Deck's client for `session-agent` on the mini.
///
/// WHY THE WORK IS OVER THERE. The process tree, the run dirs and the hook logs
/// are all on the mini, so Deck would be reaching across ssh for every one of
/// them anyway. Keeping the state machine and the tmux mechanics on that side
/// also keeps a second implementation of them out of Swift, where it could not
/// be tested in this suite and would drift from the one that is.
///
/// So this type is argv and JSON. It builds a command, runs it over the ssh
/// ControlMaster the terminal panes already share, and decodes one object.
enum SessionAgent {
    /// The remote command name. Installed by `agent-platform/install.sh`, which
    /// symlinks it onto the PATH; a machine that has not re-run the installer
    /// reports the failure through `AgentError.notInstalled` rather than a bare
    /// non-zero exit.
    static let remoteCommand = "session-agent"

    /// `CustomStringConvertible` and `LocalizedError` both forward to
    /// `description`, so every call site that interpolates the error —
    /// `"\(error)"`, `error.localizedDescription`, an alert's message — reads
    /// the same plain sentence. Without this, Swift's synthesized
    /// description for `.failed(text)` prints `failed("text")`, quote marks
    /// and all, which is what a failed crew create was showing on the rail.
    enum AgentError: Error, Equatable, CustomStringConvertible, LocalizedError {
        case invalidSessionName(String)
        case notInstalled
        case failed(String)

        var description: String {
            switch self {
            case .invalidSessionName(let name):
                return "\"\(name)\" is not a usable session name."
            case .notInstalled:
                return "session-agent is not installed. Run the installer and try again."
            case .failed(let message):
                return message
            }
        }

        var errorDescription: String? { description }
    }

    /// ssh argv for one verb.
    ///
    /// The session name is validated with the same rule the terminal argv uses,
    /// because it lands in the same place: `ssh` joins its trailing arguments
    /// and the remote shell splits them again.
    ///
    /// A MESSAGE IS NEVER AN ARGUMENT. It goes on stdin (`--text -`), which
    /// keeps it out of the remote process table and out of argv entirely. The
    /// mini side stages it through `tmux load-buffer -` for the same reason.
    ///
    /// `target.user`/`target.host` are validated here too, alongside the
    /// session name — a hosts-table entry from a hand-edited `theme.json`
    /// reaches this same destination token, and `parseHosts` dropping a bad
    /// row keeps most of them out, but this is the gate that makes it true
    /// regardless of who built the `SSHTarget`.
    static func arguments(
        target: SSHTarget,
        session: String,
        verb: [String],
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        let name = try validateTmuxSessionName(session)
        return withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            remoteCommand,
        ] + verb + [name], home: home)
    }

    /// argv for the verbs that take the session name last, and for `send`, whose
    /// text arrives on stdin.
    static func stateArguments(
        target: SSHTarget, session: String, follow: Bool = false
    ) throws -> [String] {
        var argv = try arguments(target: target, session: session, verb: ["state"])
        if follow { argv.append("--follow") }
        return argv
    }

    /// argv for `session-agent states name…`, the rail's batched read.
    ///
    /// One command carrying every rail name, so the rail costs ONE ssh round trip
    /// per poll rather than one per row — the whole reason to batch. Each name is
    /// validated the same way a single verb's is, because they all land in the
    /// same trailing argv the remote shell re-splits.
    static func statesArguments(
        target: SSHTarget,
        sessions: [String],
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        let names = try sessions.map(validateTmuxSessionName)
        return withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            remoteCommand, "states",
        ] + names, home: home)
    }

    /// argv for `session-agent sessions` — every non-scratch tmux session on
    /// the host, for grouping under a crew (`SessionGrouping`). Takes NO
    /// session-name argv at all, per the contract: it lists across the whole
    /// host rather than answering about one name, which is the point of it.
    ///
    /// Same ControlMaster options as `statesArguments`, so the rail's
    /// discovery poll multiplexes onto the connection its states poll
    /// already opened rather than negotiating a second one.
    static func sessionsArguments(
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
            remoteCommand, "sessions",
        ], home: home)
    }

    /// Runs `session-agent sessions` and decodes it. Throws only on a
    /// transport-level failure (an unreachable mini, or the remote command
    /// not installed) — `DiscoveredSession.decode` is a total function that
    /// never throws on the bytes themselves, so a malformed body reads as an
    /// empty list rather than propagating here. See `RailStateModel.refresh`
    /// for how a caller tells "the call failed, leave the last good set
    /// standing" apart from "the call succeeded and genuinely found nothing."
    static func discoveredSessions(target: SSHTarget) throws -> [DiscoveredSession] {
        DiscoveredSession.decode(
            try run(sessionsArguments(target: target),
                    staleSocketRecovery: (target: target, controlPath: defaultControlPath())),
            host: target)
    }

    /// argv for `session-agent crews` — the crew specs the steward's
    /// `new-crew`/`new-subcrew` skills wrote to `crews.d/` on the host,
    /// served as one envelope. Takes NO session-name argv, the same shape
    /// `sessionsArguments` takes: it answers about the whole host rather
    /// than one crew.
    ///
    /// Same ControlMaster options as `sessionsArguments`, so this rides the
    /// rail's already-warm connection rather than negotiating a second one
    /// — see `platform/contracts/session-agent-api`'s `crews` section.
    static func crewsArguments(
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
            remoteCommand, "crews",
        ], home: home)
    }

    /// Runs `session-agent crews` and decodes it. Throws only on a
    /// transport-level failure — `ServedCrew.decode` is a total function
    /// that never throws on the bytes themselves, so a malformed body reads
    /// as an empty list rather than propagating here, the same split
    /// `discoveredSessions` follows.
    static func servedCrews(target: SSHTarget) throws -> [ServedCrew] {
        ServedCrew.decode(
            try run(crewsArguments(target: target),
                    staleSocketRecovery: (target: target, controlPath: defaultControlPath())),
            host: target)
    }

    /// argv for `session-agent crews-root` — no session name, the same
    /// shape `sessionsArguments` takes: it answers about the whole host
    /// rather than one session, so there is no name to put on argv.
    ///
    /// See `platform/contracts/session-agent-api`'s `crews-root` section:
    /// the verb reports the root a `--create-dir` call may create under —
    /// the host's own configured `CREWS_ROOT`, or its floor's own default
    /// when nothing overrides it — so Deck can stop compiling `~/Convivy`
    /// in and ask instead. See `deck/specs/running-deck-as-someone-else`.
    static func crewsRootArguments(
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
            // THE ONE BUILDER THAT BOUNDS THE CONNECT, and the reason is
            // when it runs rather than what it asks for. Every other verb
            // here polls a host the rail already reached, so it rides a
            // warm ControlMaster; this one fires the moment a host is ADDED,
            // which is the first connection to a box nobody has proved is
            // reachable. `ServerAlive*` above bounds a connection that
            // stalls AFTER the handshake and says nothing about the TCP
            // connect, so an offline box, a wrong address, or a silent drop
            // would wait on the OS default — uncontrolled, and long. Settings
            // stays responsive either way (the row appears immediately; only
            // the steward offer waits), so this bounds the wait rather than
            // hiding it.
            "-o", "ConnectTimeout=8",
            "\(user)@\(host)",
            remoteCommand, "crews-root",
        ], home: home)
    }

    /// Decodes `session-agent crews-root`'s `{"root": ...}` envelope. A
    /// PURE FUNCTION OF THE BYTES, so every malformed shape can be pinned
    /// by a test without an ssh round trip — the same split `decodeDelta`
    /// and `decodeUnqueue` use.
    ///
    /// THE STRING IS RETURNED EXACTLY AS THE HOST REPORTED IT — unresolved,
    /// per the contract, byte-identical to what `--create-dir`'s own
    /// refusal quotes. Resolving, normalising or expanding it here would
    /// break that agreement on a symlinked or otherwise non-literal root.
    static func decodeCrewsRoot(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let root = obj as? [String: Any],
              let value = root["root"] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Runs `crews-root` and decodes it. Throws on a transport-level
    /// failure or a malformed body, same as every other verb — the caller
    /// deciding to treat that as "no root available" (rather than
    /// surfacing it) is `HostsSettingsView.addHost`'s job, not this one's.
    static func crewsRoot(target: SSHTarget) throws -> String {
        guard let value = decodeCrewsRoot(try run(crewsRootArguments(target: target))) else {
            throw AgentError.failed("the host did not report a crews root")
        }
        return value
    }

    static func sendArguments(target: SSHTarget, session: String) throws -> [String] {
        try arguments(target: target, session: session, verb: ["send"]) + ["--text", "-"]
    }

    static func chooseArguments(target: SSHTarget, session: String, choice: Int,
                                gateId: String? = nil,
                                questionIndex: Int? = nil) throws -> [String] {
        guard (1...9).contains(choice) else {
            throw AgentError.failed("choice must be 1-9, got \(choice)")
        }
        // `choose <name> <n>`: the name precedes the digit, so the shared
        // builder's trailing-name shape does not fit and the argv is assembled
        // here rather than bent to it.
        var argv = try arguments(target: target, session: session, verb: ["choose"])
        argv.append(String(choice))
        appendExpectations(&argv, gateId: gateId, questionIndex: questionIndex)
        return argv
    }

    /// argv for `session-agent submit`, which closes a multiselect question.
    ///
    /// A SECOND VERB RATHER THAN A FLAG ON `choose`, because they are different
    /// acts: `choose` ticks a box and `submit` sends the answer. Folding them
    /// together would mean every tick carried a "and finish now" argument that
    /// is wrong for all but the last one.
    static func submitArguments(target: SSHTarget, session: String,
                                gateId: String? = nil,
                                questionIndex: Int? = nil) throws -> [String] {
        var argv = try arguments(target: target, session: session, verb: ["submit"])
        appendExpectations(&argv, gateId: gateId, questionIndex: questionIndex)
        return argv
    }

    static func interruptArguments(target: SSHTarget, session: String) throws -> [String] {
        try arguments(target: target, session: session, verb: ["interrupt"])
    }

    /// argv for `session-agent unqueue`, which answers Claude Code's own
    /// "Press up to edit queued messages" — see `unqueue`'s own doc for why
    /// Deck never presses `Up` directly.
    static func unqueueArguments(target: SSHTarget, session: String) throws -> [String] {
        try arguments(target: target, session: session, verb: ["unqueue"])
    }

    /// argv for `session-agent type`, which puts text into a live picker.
    ///
    /// NOT `send`, AND THE DIFFERENCE IS THE WHOLE REASON THIS VERB EXISTS.
    /// `send` does clear → paste → Enter and the mini refuses it outright while a
    /// session is blocked, because a picker eats the paste as filter-box typing and
    /// the trailing Enter takes whichever row is highlighted. That is what
    /// convivy-deck #54 kept hitting. `type` pastes with no Enter and is allowed
    /// only while blocked — the exact inverse gate, for the one case where pasting
    /// without submitting is what you want.
    ///
    /// The text goes over stdin rather than argv, as `send`'s does: an argument is
    /// visible in the process table, and an answer is the user's words.
    static func typeArguments(target: SSHTarget, session: String,
                              gateId: String? = nil,
                              questionIndex: Int? = nil) throws -> [String] {
        var argv = try arguments(target: target, session: session, verb: ["type"])
        appendExpectations(&argv, gateId: gateId, questionIndex: questionIndex)
        return argv + ["--text", "-"]
    }

    /// argv for `session-agent focus-free-text`, which walks a MULTISELECT
    /// question's highlight onto its free-text row so `type` has somewhere to land.
    ///
    /// NOT NEEDED ON A SINGLE-SELECT, where `choose <row>` focuses the field with
    /// one digit. On a multiselect that same digit TICKS the row instead, the
    /// highlight does not move, and the paste that follows is swallowed — the
    /// sequence Deck shipped against both kinds and withdrew in #60.
    ///
    /// THE WALK IS THE MINI'S, and it has to be: it reads the pane between arrows
    /// to find the row, because the option list wraps and no counted walk is safe.
    /// Deck could not do it from here without a second implementation of the
    /// picker reader in Swift.
    static func focusFreeTextArguments(target: SSHTarget, session: String,
                                       gateId: String? = nil,
                                       questionIndex: Int? = nil) throws -> [String] {
        var argv = try arguments(target: target, session: session, verb: ["focus-free-text"])
        appendExpectations(&argv, gateId: gateId, questionIndex: questionIndex)
        return argv
    }

    /// argv for `session-agent key`, one named key from the mini's allowlist.
    ///
    /// The allowlist is the mini's and is deliberately narrow — it has no `C-c`
    /// entry, because two in succession exit Claude Code. Deck names the key it
    /// wants and the mini decides whether that is a key at all.
    static func keyArguments(target: SSHTarget, session: String, key: String) throws -> [String] {
        var argv = try arguments(target: target, session: session, verb: ["key"])
        argv.append(key)
        return argv
    }

    /// The renderer is a DIFFERENT command. `session-view` produces the page;
    /// `session-agent` drives the session. They are separate on the mini because
    /// the renderer predates the driver by days and is useful on its own, and
    /// conflating them here would send a `--theme` flag to a parser that has
    /// never heard of it.
    static let renderCommand = "session-view"

    /// The range `session-view` accepts. Mirrored rather than assumed: a value
    /// it would refuse is not worth sending, and a Deck that sent one would show
    /// an unchanged page with no hint why.
    static let minimumScale = 0.5
    static let maximumScale = 3.0

    /// A CSS hex colour, and only that.
    ///
    /// The value is interpolated into a `<style>` block on the far side, so the
    /// mini validates it too. Validating here as well is the same reasoning the
    /// session name gets: this lands in ssh argv, which the remote shell splits
    /// again, and a caller should not be able to smuggle a second argument
    /// through a colour.
    /// `\z`, NOT `$`. NSRegularExpression is ICU, where `$` matches at the end
    /// of input OR just before a final newline — so `"#aabbcc\n"` satisfies a
    /// `$`-anchored pattern. Measured, not assumed. Nothing in the current path
    /// produces a trailing newline, which is precisely what would have kept this
    /// quiet. `\z` is the absolute end with no exception. Caught by
    /// deck-reviewer.
    static let hexColour = try! NSRegularExpression(
        pattern: "^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\\z")

    static func validateHexColour(_ value: String) -> String? {
        let range = NSRange(value.startIndex..., in: value)
        return hexColour.firstMatch(in: value, range: range) != nil ? value : nil
    }

    /// A gate id, and only that.
    ///
    /// The id goes into ssh argv as `--expect-gate <id>`, so the same reasoning
    /// as the session name and the hex colour applies: only characters that are
    /// safe without quoting. Gate ids are tool-use ids from the Anthropic hook
    /// stream (`toolu_<base58>`), so alphanumeric, underscores and hyphens cover
    /// every real value. Anything else is dropped and the flag is omitted, which
    /// is the permissive degradation §5.5 describes.
    static let gateIdPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]+\\z")

    static func validateGateId(_ value: String) -> String? {
        let range = NSRange(value.startIndex..., in: value)
        return gateIdPattern.firstMatch(in: value, range: range) != nil ? value : nil
    }

    /// A Slate card id, and only that.
    ///
    /// The card is co-written to a board file Deck only reads (`Slate.swift`'s
    /// own doc), and the id lands in ssh argv as a trailing positional
    /// argument (`slate-edit <name> <id>`, `slate-send <name> <id>`) — the
    /// same destination the session name and the gate id reach, so the same
    /// reasoning applies: only characters safe without quoting cross into
    /// argv. Real ids seen live against `session-agent slate` (`a-dd5np4`,
    /// `a-7f3k2q`) are alphanumeric with a hyphen, so the gate id's own
    /// allowlist already covers them. Raised in review.
    static func validateCardId(_ value: String) -> String? {
        validateGateId(value)
    }

    /// Appends `--expect-gate` and `--expect-question` to `argv` when present.
    ///
    /// Each flag is independent: a gate with no folded id still carries a
    /// question index, and an unrecognised version drops the rendered block
    /// entirely, leaving the question index nil while a gate id may still be
    /// known. Omitting each flag when its value is nil is the permissive
    /// degradation §5.5 describes.
    private static func appendExpectations(_ argv: inout [String],
                                           gateId: String?,
                                           questionIndex: Int?) {
        if let id = gateId.flatMap({ validateGateId($0) }) {
            argv += ["--expect-gate", id]
        }
        if let n = questionIndex {
            argv += ["--expect-question", String(n)]
        }
    }

    static func renderArguments(
        target: SSHTarget,
        session: String,
        appearance: Appearance,
        background: String? = nil,
        scale: Double? = nil,
        lineHeight: Double? = nil,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        let name = try validateTmuxSessionName(session)
        var argv = withDeckIdentity([
            // COMPRESSION, AND ITS OWN TRANSPORT — the second half is what makes
            // the first half work. A render is the whole conversation as HTML and
            // grows with the session: a day-old one measured 958 KB, shipped
            // again on every poll that finds the transcript moved. That is the
            // lag the operator described. It compresses to 24%, measured.
            //
            // BUT ssh negotiates compression ONCE, when the ControlMaster is
            // established, and every channel over that master inherits it. On
            // the shared path this flag would have done nothing in the common
            // case (the terminal opens the master first, so the render joins as
            // a slave and `-C` is ignored) and the wrong thing in the rare one
            // (render opens first, so interactive keystrokes get compressed too
            // — the opposite of the intent). Caught in review; I had reasoned
            // about the flag and not about where it is negotiated.
            //
            // So renders get their own master. They still multiplex with each
            // other, which is what matters when a working session re-renders
            // every couple of seconds, and the terminal's transport is left
            // exactly as it was.
            "-C",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)-render",
            // The same keepalives every other verb carries. Usually the master
            // is already open from the preceding state poll, but a render that
            // opens it first would otherwise hold a connection with no keepalive
            // and wedge on a roaming link.
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            renderCommand, "--render-tmux", name,
            // The shell resolved this; the page is told rather than left to
            // follow the OS and disagree with the rail beside it.
            "--theme", appearance == .dark ? "dark" : "light",
        ], home: home)
        // The canvas the shell painted beside this pane. Only Deck knows it —
        // it is per-session and remappable — so the renderer is told rather than
        // left to guess a colour that would disagree with the terminal.
        // Dropped rather than sent if it is not a hex colour, since a page with
        // the shipped background is a smaller failure than an argument the
        // remote shell might read as something else.
        if let background, let safe = validateHexColour(background) {
            // QUOTED, AND THAT IS THE WHOLE POINT. ssh joins its trailing
            // arguments with spaces and hands the string to the REMOTE SHELL,
            // where a bare `#` begins a comment — so `--background #2b1d12`
            // arrived as `--background` with its value eaten, session-view
            // exited 2, and the pane sat on "Loading the conversation…" forever.
            //
            // Both security reviews checked this value for INJECTION, whether it
            // could break out. Nobody checked the opposite: that the shell would
            // swallow it. The allowlist makes the single quotes safe — a hex
            // colour cannot contain one — which is what lets quoting be the fix
            // rather than the start of an escaping problem.
            argv += ["--background", "'\(safe)'"]
        }
        // The pane's text size, as a multiplier. Sent only when it differs from
        // the shipped size, so an untouched Deck asks for nothing and the page
        // renders exactly as it always has. The mini bounds it too; a value
        // outside the range is dropped here rather than argued about there.
        if let scale, scale.isFinite, scale != 1,
           scale >= SessionAgent.minimumScale, scale <= SessionAgent.maximumScale {
            argv += ["--scale", String(format: "%.3f", scale)]
        }
        // The prose's leading, on the same terms and for the same reason: sent
        // only when it differs from the shipped 1.65, so an untouched Deck asks
        // for nothing.
        //
        // THAT SILENCE IS ALSO THE COMPATIBILITY STORY. `--line-height` arrived
        // in agent-platform#246; a mini without it rejects the unknown flag and
        // the render fails outright rather than degrading. Not sending the
        // default means only a user who has actually moved the slider can meet
        // that, and the fix for them is installing the mini side.
        if let lineHeight, lineHeight.isFinite, lineHeight != SessionTypography.default.lineHeight,
           lineHeight >= SessionTypography.minimumLineHeight,
           lineHeight <= SessionTypography.maximumLineHeight {
            argv += ["--line-height", String(format: "%.2f", lineHeight)]
        }
        return argv
    }

    /// One row of a delta envelope: a key found in the page's `data-k`, and the
    /// markup to place there. Order matters — `DeltaOutcome.rows` carries them
    /// in transcript order, oldest first, and the consumer applies them in
    /// that order.
    struct DeltaRow: Equatable {
        let key: String
        let html: String
        /// "Place this at the newest end, wherever it currently sits."
        ///
        /// Set by the mini on a held row — a queued message the agent has not
        /// read yet — and on nothing else. Every other row's position is fixed
        /// by its line in the transcript, so replacing it where it already sits
        /// is correct. A held row is not in the transcript at all and belongs
        /// below all of it, because it is the thing that has not happened yet.
        ///
        /// DEFAULTS FALSE WHEN THE FIELD IS ABSENT, which is the whole
        /// compatibility story: a mini that predates the flag sends no `newest`
        /// on any row and gets exactly today's behaviour.
        let newest: Bool

        init(key: String, html: String, newest: Bool = false) {
            self.key = key
            self.html = html
            self.newest = newest
        }
    }

    /// What `session-view --delta-since` answered, decoded from its JSON
    /// envelope. See `deck/specs/session-pane-incremental-rendering`.
    enum DeltaOutcome: Equatable {
        /// `lines` is the new cursor to send on the next call. `rows` is in
        /// transcript order, oldest first; each is either a row already on
        /// the page (replace in place) or a new one (insert). `removed` is
        /// the keys of rows to drop from the page entirely — the mini's way
        /// of withdrawing a row it previously sent, e.g. a queued message
        /// the agent has since read. Empty on every delta the mini does not
        /// implement removal on, which is the whole no-op story: an absent
        /// or empty list behaves exactly as before it existed.
        case rows(lines: Int, rows: [DeltaRow], removed: [String])
        /// The mini could not honestly produce a delta and sent a whole page
        /// instead — no cursor was sent, the cursor is past the end of the
        /// transcript (a rotated or truncated file), or the build does not
        /// implement `--delta-since`. The consumer treats this exactly as an
        /// ordinary render.
        case full(page: String)
        /// The envelope did not decode into either known shape. Every field
        /// degrades on its own; this is the case once none of them could be
        /// trusted. It means "no delta available", never a crash or a
        /// partial apply.
        case unavailable
    }

    /// argv for `session-view --render-tmux <name> --delta-since <cursor>`.
    ///
    /// Built the way `renderArguments` is — same ControlMaster, same
    /// compression, same theme/canvas/scale/lineHeight — because a delta row
    /// is markup from the same renderer and has to match what is already on
    /// the page. `--delta-since` is the only thing added.
    static func deltaArguments(
        target: SSHTarget,
        session: String,
        cursor: Int,
        appearance: Appearance,
        background: String? = nil,
        scale: Double? = nil,
        lineHeight: Double? = nil,
        controlPath: String = defaultControlPath()
    ) throws -> [String] {
        var argv = try renderArguments(
            target: target, session: session, appearance: appearance,
            background: background, scale: scale, lineHeight: lineHeight,
            controlPath: controlPath)
        argv += ["--delta-since", String(cursor)]
        return argv
    }

    /// Decodes the JSON envelope `session-view --delta-since` returns.
    ///
    /// A PURE FUNCTION OF THE BYTES, so every malformed shape can be pinned by
    /// a test without an ssh round trip — the same split `decodeStates` uses.
    static func decodeDelta(_ data: Data) -> DeltaOutcome {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let root = obj as? [String: Any] else {
            return .unavailable
        }
        if root["full"] as? Bool == true {
            guard let page = root["page"] as? String, !page.isEmpty else { return .unavailable }
            return .full(page: page)
        }
        guard let lines = root["lines"] as? Int, lines >= 0 else { return .unavailable }
        guard let rawRows = root["rows"] as? [Any] else { return .unavailable }
        var rows: [DeltaRow] = []
        rows.reserveCapacity(rawRows.count)
        for item in rawRows {
            guard let dict = item as? [String: Any],
                  let key = dict["key"] as? String, !key.isEmpty,
                  let html = dict["html"] as? String else {
                // ONE MALFORMED ROW MEANS THE WHOLE BATCH IS UNTRUSTED, not
                // just that row. Skipping only the bad one would still
                // advance the cursor past content that was never rendered —
                // a row that no later delta would ever re-offer, since
                // `--delta-since` only sends what came after the cursor.
                return .unavailable
            }
            // `newest` is read leniently, unlike `key` and `html` above. A
            // malformed one costs a held row its position for a poll, not a
            // silently skipped row the cursor advances past, so the strict
            // whole-batch rejection those two need would be out of proportion
            // here — the same reasoning `decodeRemovedKeys` gives.
            rows.append(DeltaRow(key: key, html: html,
                                 newest: dict["newest"] as? Bool ?? false))
        }
        return .rows(lines: lines, rows: rows, removed: decodeRemovedKeys(root["removed"]))
    }

    /// The removal keys carried by a delta envelope, or an empty list.
    ///
    /// LENIENT ON PURPOSE, UNLIKE `rows` ABOVE. A malformed row invalidates
    /// the whole batch because skipping it would still advance the cursor
    /// past content that no later delta would ever re-offer. A malformed or
    /// unrecognised removal key has no such one-shot window — the row it
    /// named just stays on the page a beat longer, which is the same
    /// "client and mini need not agree perfectly" degradation the apply side
    /// already gives a removal that matches nothing. So a field that is
    /// absent or not an array is simply empty, and a non-string entry is
    /// dropped rather than poisoning the rest.
    private static func decodeRemovedKeys(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    /// Fetches and decodes one delta. A non-zero exit or an unreachable mini
    /// throws, exactly as `render` does; the caller falls back to a full
    /// render on either that or `.unavailable`.
    static func delta(target: SSHTarget, session: String, cursor: Int, appearance: Appearance,
                      background: String? = nil, scale: Double? = nil,
                      lineHeight: Double? = nil) throws -> DeltaOutcome {
        let data = try run(deltaArguments(
            target: target, session: session, cursor: cursor, appearance: appearance,
            background: background, scale: scale, lineHeight: lineHeight))
        return decodeDelta(data)
    }

    /// What `session-agent unqueue` answered, decoded from its JSON envelope.
    ///
    /// See `deck/specs/session-pane-input-channel`'s M1-M5 and
    /// `platform/contracts/session-agent-api`'s `unqueue` paragraphs for why
    /// the verb runs its own read-verify-act sequence on the mini rather than
    /// Deck pressing `Up` directly: every discriminator between a real pop
    /// and a stray history recall lives on that side of the ssh hop.
    enum UnqueueOutcome: Equatable {
        /// `ok: true`. The messages actually pulled off the queue, oldest
        /// first — AUTHORITATIVE, because they are what left the queue at
        /// the moment it left, not a guess reconstructed from a poll taken
        /// before or after. An empty list is a real positive answer: the
        /// queue had already drained, naturally or via a history recall this
        /// verb undid, and there is nothing to rewrite.
        case messages([String])
        /// `ok: false`. One of the four refusals: the box was not observably
        /// empty, the transcript could not be read back afterward, the pane
        /// is unexplained, or a picker took the box mid-recall. The string
        /// is the mini's own words.
        case refused(String)
        /// The envelope did not decode into either known shape — empty
        /// output, not JSON, an object missing `ok`, or `ok: true` with no
        /// usable `messages` array. Unlike `decodeDelta`'s rows this is not a
        /// partial-batch question: `unqueue`'s answer is small enough that
        /// any missing piece means the whole call cannot be trusted.
        case malformed
    }

    /// A PURE FUNCTION OF THE BYTES, so every shape — success, each refusal,
    /// and malformed output — can be pinned by a test without an ssh round
    /// trip, the same split `decodeDelta` uses.
    static func decodeUnqueue(_ data: Data) -> UnqueueOutcome {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let root = obj as? [String: Any],
              let ok = root["ok"] as? Bool else {
            return .malformed
        }
        guard ok else {
            return .refused(root["error"] as? String
                            ?? "the session refused to rewind the queue")
        }
        guard let raw = root["messages"] as? [Any] else { return .malformed }
        let messages = raw.compactMap { $0 as? String }
        // A NON-STRING ENTRY INVALIDATES THE WHOLE BATCH, unlike
        // `decodeRemovedKeys`'s leniency. This is the one and only moment
        // this text exists in Deck; silently dropping an entry would lose a
        // message the user typed rather than merely mis-render one.
        guard messages.count == raw.count else { return .malformed }
        return .messages(messages)
    }

    /// Runs `unqueue` and decodes its outcome. Reads stdout REGARDLESS OF
    /// EXIT STATUS — see `run`'s `throwOnNonZeroExit` doc — because a
    /// refusal is a normal answer carried on stdout at exit 1, not a
    /// transport failure. A genuinely missing remote command or an
    /// unreachable mini still throws, same as every other verb.
    static func unqueue(target: SSHTarget, session: String) throws -> UnqueueOutcome {
        let data = try run(unqueueArguments(target: target, session: session), throwOnNonZeroExit: false)
        return decodeUnqueue(data)
    }

    /// The operator's overrides on a session's rollover
    /// (`platform/decisions/0069-a-co-session-rolls-itself-over-before-it-runs-out-of-context`).
    /// The Bosun decides that a session must roll; these are how a person
    /// overrides that decision from the rail.
    enum RolloverAction: String, CaseIterable {
        /// Stop a pending rollover. Holds until the session crosses its next
        /// limit (the operator's ruling (d)).
        case veto
        /// Roll over now, without waiting for a good moment.
        case force
        /// Start looking for a good moment now, at any context level.
        case seek
        /// Drop the override and return the session to the policy.
        case clear
    }

    /// What `session-agent rollover` answered.
    enum RolloverOutcome: Equatable {
        /// `force` sent `/rollover` to an idle session. Carries the session's
        /// rollover state as it read afterwards.
        case sent(SessionState.Rollover?)
        /// The override is written. It takes effect on the session's own next
        /// hook firing, or at once for a `veto`, `seek` or `clear`.
        case armed(SessionState.Rollover?)
        /// The Bosun declined: the session could not be resolved, or a `force`
        /// would have landed on a composer draft or a held message. The string
        /// is the mini's own words.
        case refused(String)
        /// No `outcome` Deck knows. On a write, that means Deck cannot say
        /// whether the override took effect, so it is never read as success.
        case malformed
    }

    /// argv for `session-agent rollover <name> <action>`. The action comes
    /// AFTER the name, the reverse of most verbs here: `arguments` appends the
    /// name to the verb, and the CLI takes the action as a second positional.
    static func rolloverArguments(target: SSHTarget, session: String,
                                  action: RolloverAction) throws -> [String] {
        try arguments(target: target, session: session, verb: ["rollover"]) + [action.rawValue]
    }

    /// A PURE FUNCTION OF THE BYTES, like `decodeUnqueue`. The verb answers
    /// `{outcome, reason, rollover}` and exits 0 even when it refuses, so the
    /// outcome is read from the body and never from the exit status.
    static func decodeRolloverOutcome(_ data: Data) -> RolloverOutcome {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let outcome = root["outcome"] as? String else {
            return .malformed
        }
        let state = SessionState.decodeRollover(root["rollover"])
        switch outcome {
        case "sent": return .sent(state)
        case "armed": return .armed(state)
        case "refused": return .refused(root["reason"] as? String ?? "the session declined the rollover change")
        default: return .malformed
        }
    }

    /// Runs `rollover` and decodes its outcome. A mini that predates the verb
    /// fails argparse at a non-zero exit, which throws like any other missing
    /// remote command rather than reading as a refusal.
    static func rollover(target: SSHTarget, session: String,
                         action: RolloverAction) throws -> RolloverOutcome {
        decodeRolloverOutcome(try run(rolloverArguments(target: target, session: session, action: action)))
    }

    /// The rollover policy limits Deck may set. `mode` is deliberately absent:
    /// whether the machine acts on the policy is the platform's switch, not
    /// the operator's (see `RolloverPolicySection`).
    enum RolloverPolicyField: String, CaseIterable {
        case seekPercent = "seek_pct"
        case floorPercent = "floor_pct"
        case seekCallCap = "seek_call_cap"
    }

    /// One `--set`: a field and its new value, `nil` to unset it.
    struct RolloverPolicyUpdate: Equatable {
        var field: RolloverPolicyField
        var value: Double?
    }

    /// What `session-agent rollover-policy` answered.
    enum RolloverPolicyOutcome: Equatable {
        /// The policy now on disk: after the edit, or as read.
        case policy(SessionState.Rollover.Policy)
        /// The machine refused the edit and wrote nothing. The string is its
        /// own words, which name its keys.
        case refused(String)
        /// Neither shape. An older `session-agent` without the verb lands
        /// here, since argparse's refusal leaves stdout empty.
        case malformed
    }

    /// argv for `session-agent rollover-policy [--set key=value ...]`. No
    /// session name: the policy belongs to the machine. Each value is a number
    /// Deck formatted, never text a person typed.
    static func rolloverPolicyArguments(target: SSHTarget, updates: [RolloverPolicyUpdate],
                                        controlPath: String = defaultControlPath(),
                                        home: String = NSHomeDirectory()) throws -> [String] {
        let user = try validateHostUser(target.user)
        let host = try validateHostAddress(target.host)
        return withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)",
            remoteCommand, "rollover-policy",
        ] + updates.flatMap { ["--set", policyArgument($0)] }, home: home)
    }

    /// `seek_pct=65`, `floor_pct=87.5`, `seek_call_cap=null`. A whole number
    /// is written without a fractional part, so an integer cap stays one.
    static func policyArgument(_ update: RolloverPolicyUpdate) -> String {
        guard let value = update.value, value.isFinite else { return "\(update.field.rawValue)=null" }
        if value == value.rounded(), abs(value) < 1e15 { return "\(update.field.rawValue)=\(Int(value))" }
        return "\(update.field.rawValue)=\(value)"
    }

    /// A PURE FUNCTION OF THE BYTES. A success prints the policy object; a
    /// refusal prints `{"ok": false, "error": …}`.
    static func decodeRolloverPolicy(_ data: Data) -> RolloverPolicyOutcome {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .malformed
        }
        if let ok = root["ok"] as? Bool, !ok {
            return .refused(root["error"] as? String ?? "the machine refused the policy change")
        }
        guard root["seek_pct"] != nil || root["mode"] != nil,
              let policy = SessionState.decodeRolloverPolicy(root) else { return .malformed }
        return .policy(policy)
    }

    /// Reads, or edits and reads back, a machine's rollover policy. Reads
    /// stdout regardless of exit status, like `unqueue`: a refusal is a
    /// normal answer at exit 1.
    static func rolloverPolicy(target: SSHTarget, updates: [RolloverPolicyUpdate] = []) throws -> RolloverPolicyOutcome {
        decodeRolloverPolicy(try run(rolloverPolicyArguments(target: target, updates: updates),
                                     throwOnNonZeroExit: false))
    }

    /// Wraps a string in POSIX single quotes for the remote shell.
    ///
    /// ssh joins its trailing argv items with spaces before the remote shell sees
    /// them, so a path with spaces becomes multiple tokens unless quoted. Each
    /// embedded `'` is escaped as `'\''`: close the single-quoted string, emit a
    /// backslash-escaped single quote, then reopen.
    ///
    /// Used for both file paths and KB doc-ids. KB ids are constrained to
    /// `[a-z0-9-/]` by `validateKBId` — a charset with no shell metacharacter —
    /// but are quoted anyway: a charset assumption is a weaker guarantee than
    /// quoting, and the space-in-path lesson from `renderFileArguments` applies
    /// uniformly rather than only where the risk is already visible.
    static func shellQuotePath(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// argv for `session-view --render-file <path>`.
    ///
    /// Uses the same render ControlMaster (the `-render` suffix) and compression
    /// as `renderArguments`, so file and session renders multiplex together rather
    /// than each opening their own connection to the mini.
    ///
    /// The path is POSIX-single-quoted because ssh joins its trailing arguments
    /// with spaces before the remote shell sees them — a bare path containing a
    /// space would be split into multiple tokens. The path arrives already
    /// validated by `DeckOpenRef.validatePath`, which rejects control characters
    /// but allows spaces and punctuation. A `'` in the path is escaped as `'\''`.
    static func renderFileArguments(
        target: SSHTarget,
        path: String,
        appearance: Appearance,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-C",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)-render",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            renderCommand, "--render-file", shellQuotePath(path),
            "--theme", appearance == .dark ? "dark" : "light",
        ], home: home)
    }

    /// Renders a file on the mini with `session-view --render-file` and returns
    /// the complete self-contained HTML page.
    ///
    /// A non-zero exit propagates as `AgentError.failed` and surfaces as the
    /// viewer's existing error state.
    static func renderFile(target: SSHTarget, path: String, appearance: Appearance) throws -> String {
        let data = try run(renderFileArguments(target: target, path: path, appearance: appearance))
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw AgentError.failed("the file renderer returned nothing")
        }
        return text
    }

    /// argv for `session-view --render-kb <doc-id>`.
    ///
    /// Uses the same render ControlMaster (the `-render` suffix) and compression
    /// as `renderArguments` and `renderFileArguments`, so KB, file, and session
    /// renders all multiplex together on the compressed channel.
    ///
    /// The doc-id is POSIX-single-quoted even though `DeckOpenRef.validateKBId`
    /// already constrains it to `[a-z0-9-/]`, which contains no shell
    /// metacharacter. A charset assumption is a weaker guarantee than quoting —
    /// `renderFileArguments` learned that lesson with spaces — so the policy
    /// applies uniformly.
    static func renderKBArguments(
        target: SSHTarget,
        docId: String,
        appearance: Appearance,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-C",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)-render",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            renderCommand, "--render-kb", shellQuotePath(docId),
            "--theme", appearance == .dark ? "dark" : "light",
        ], home: home)
    }

    /// Renders a KB document on the mini with `session-view --render-kb` and
    /// returns the complete self-contained HTML page.
    ///
    /// A non-zero exit propagates as `AgentError.failed` and surfaces as the
    /// viewer's existing error state. The mini side is the authoritative source
    /// for the document; a missing doc-id exits non-zero per the contract.
    static func renderKB(target: SSHTarget, docId: String, appearance: Appearance) throws -> String {
        let data = try run(renderKBArguments(target: target, docId: docId, appearance: appearance))
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw AgentError.failed("the KB renderer returned nothing")
        }
        return text
    }

    /// argv for `session-view --render-editor <path>`.
    ///
    /// Uses the same render ControlMaster and compression as the other two
    /// render verbs, so an editor page multiplexes with the session and file
    /// renders rather than opening its own connection.
    ///
    /// The page this returns runs script, which the viewer's pages do not. That
    /// difference lives entirely on the Deck side: `--render-editor` reads the
    /// file, inlines it, and never invokes Node, so the remote call is no more
    /// privileged than `--render-file`.
    static func renderEditorArguments(
        target: SSHTarget,
        path: String,
        appearance: Appearance,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-C",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)-render",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            renderCommand, "--render-editor", shellQuotePath(path),
            "--theme", appearance == .dark ? "dark" : "light",
        ], home: home)
    }

    /// Renders a file on the mini with `session-view --render-editor` and
    /// returns the complete self-contained editor page.
    ///
    /// A non-zero exit propagates as `AgentError.failed` and surfaces as the
    /// editor pane's error state.
    static func renderEditor(target: SSHTarget, path: String, appearance: Appearance) throws -> String {
        let data = try run(renderEditorArguments(target: target, path: path, appearance: appearance))
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw AgentError.failed("the editor renderer returned nothing")
        }
        return text
    }

    /// argv for `session-view --render-editor -`, with the document on stdin.
    ///
    /// A KB DOCUMENT HAS NO PATH ON THE MINI, which is the whole reason this
    /// exists. It reaches Deck through `agentctl kb checkout`, which returns
    /// content and the sha to submit against and writes nothing to disk.
    /// Piping those same bytes back is what keeps the page and the precondition
    /// pointed at one version; asking the mini to re-read the document would be
    /// a second read, and a second read can return something else.
    ///
    /// `--name` carries the doc id, since there is no filename to take a
    /// heading from.
    static func renderEditorFromStdinArguments(
        target: SSHTarget,
        name: String,
        appearance: Appearance,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-C",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)-render",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            renderCommand, "--render-editor", "-",
            "--name", shellQuotePath(name),
            "--theme", appearance == .dark ? "dark" : "light",
        ], home: home)
    }

    /// Renders `content` as an editor page, naming it `name`.
    static func renderEditor(target: SSHTarget, content: String, name: String,
                             appearance: Appearance) throws -> String {
        let data = try run(
            renderEditorFromStdinArguments(target: target, name: name, appearance: appearance),
            stdin: content,
            classifyMissingCommand: false)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw AgentError.failed("the editor renderer returned nothing")
        }
        return text
    }

    /// argv for `session-view --render-file -`, with the document on stdin.
    ///
    /// THE SAME STDIN SHAPE AS `renderEditorFromStdinArguments`, and for the
    /// same reason: the caller (`ItemDetailPane`) already has the
    /// document's bytes in hand from a Library fetch, so piping them in here
    /// avoids a second remote read `--render-file <path>` would require and
    /// this content has no path on the mini to read from anyway.
    ///
    /// `--name` is what `session-view` titles the page with, and it is
    /// shell-adjacent the same way a KB doc id is on `--render-editor -`:
    /// `shellQuotePath` wraps it rather than trusting its charset, because
    /// a Library-supplied title must never reach argv unquoted.
    static func renderFileFromStdinArguments(
        target: SSHTarget,
        name: String,
        appearance: Appearance,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-C",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)-render",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            renderCommand, "--render-file", "-",
            "--name", shellQuotePath(name),
            "--theme", appearance == .dark ? "dark" : "light",
        ], home: home)
    }

    /// Renders `content` as a Markdown document with `session-view
    /// --render-file -`, naming it `name`, and returns the complete
    /// self-contained HTML page.
    ///
    /// `classifyMissingCommand: false`, matching `renderEditor(content:...)`:
    /// the bridge that renders Markdown execs Node, and a Node binary that
    /// vanished between `_find_node`'s stat and the exec raises an OSError
    /// whose text also reads "No such file" — reading that as `notInstalled`
    /// would send the caller to reinstall `session-agent` over a failure it
    /// has nothing to do with.
    static func renderFile(target: SSHTarget, content: String, name: String,
                          appearance: Appearance) throws -> String {
        let data = try run(
            renderFileFromStdinArguments(target: target, name: name, appearance: appearance),
            stdin: content,
            classifyMissingCommand: false)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw AgentError.failed("the file renderer returned nothing")
        }
        return text
    }

    /// argv for `session-agent start`.
    ///
    /// The directory and the command are the catalog's, and both are validated
    /// on the mini as well. Deck checks them anyway for the reason it validates
    /// a session name: these land in ssh argv, which the remote shell splits
    /// again, so a bad row should fail here rather than become a second
    /// argument over there.
    static func startArguments(
        target: SSHTarget,
        session: String,
        directory: String? = nil,
        hasCommand: Bool = false,
        createDirectory: Bool = false,
        controlPath: String = defaultControlPath()
    ) throws -> [String] {
        var argv = try arguments(target: target, session: session, verb: ["start"],
                                 controlPath: controlPath)
        // The directory is safe on argv: `validateWorkingDirectory` rejects
        // spaces and every shell metacharacter, so ssh's join-and-resplit leaves
        // it one token.
        if let directory { argv += ["--dir", try validateWorkingDirectory(directory)] }
        // `--create-dir` is NOT a parameter of `start(session:directory:command:)`
        // below — only `createCrew` can pass `createDirectory: true` here, so
        // a rail-row Start (which calls `start`) has no way to create a
        // directory even by a typo in config. See
        // `deck/specs/multiple-sessions-per-project` §"'+ New' and its inverse".
        if createDirectory { argv.append("--create-dir") }
        // THE COMMAND IS NEVER ON ARGV. ssh joins its trailing arguments with
        // spaces and the remote shell splits them again, so `co -r` would arrive
        // as two tokens and `co; curl evil` would run its second clause in the
        // ssh control shell. `--command -` reads it from stdin instead, the same
        // channel `send` uses for a message and for the same reason. Both
        // reviewers caught this; the first version put the command on argv and
        // claimed it survived, which it does not.
        if hasCommand { argv += ["--command", "-"] }
        return argv
    }

    /// argv for `session-agent stop`.
    ///
    /// `kill` is separated from the gentle stop on this side too, so a caller
    /// cannot destroy a session by passing the wrong default.
    static func stopArguments(
        target: SSHTarget,
        session: String,
        kill: Bool,
        controlPath: String = defaultControlPath()
    ) throws -> [String] {
        var argv = try arguments(target: target, session: session, verb: ["stop"],
                                 controlPath: controlPath)
        if kill { argv.append("--kill") }
        return argv
    }

    @discardableResult
    static func start(target: SSHTarget, session: String, directory: String? = nil,
                      command: String? = nil) throws -> Data {
        // Validated here as defence in depth — the mini validates too — and to
        // give a bad catalog row a failure at the call rather than a silent
        // mangle. A `nil` command means the mini's default, so nothing is sent
        // on stdin and the verb is argv-only.
        var stdin: String?
        if let command {
            guard let safe = ThemeConfiguration.validatedCommand(command) else {
                throw AgentError.failed("not a usable launch command: \(command)")
            }
            stdin = safe
        }
        return try run(
            startArguments(target: target, session: session, directory: directory,
                           hasCommand: stdin != nil),
            stdin: stdin)
    }

    /// The steward bootstrap's ONLY entry point (`StewardCrew.create`) — Deck
    /// has no other control that makes a crew; see
    /// `deck/specs/multiple-sessions-per-project` §"'+ New' and its inverse".
    /// The one place `--create-dir` can reach argv: `directory` is required
    /// rather than optional, unlike `start`, because the steward always has
    /// one (derived from `crewsRoot`), and there is no case here that should
    /// fall back to the mini's default working directory.
    ///
    /// Creating and adopting are the same call — the caller does not, and
    /// cannot, know whether `directory` already exists on the mini, so it
    /// never branches on it. The mini's `--create-dir` decides that.
    @discardableResult
    static func createCrew(target: SSHTarget, session: String, directory: String,
                              command: String? = nil) throws -> Data {
        var stdin: String?
        if let command {
            guard let safe = ThemeConfiguration.validatedCommand(command) else {
                throw AgentError.failed("not a usable launch command: \(command)")
            }
            stdin = safe
        }
        return try run(
            startArguments(target: target, session: session, directory: directory,
                           hasCommand: stdin != nil, createDirectory: true),
            stdin: stdin)
    }

    /// Whether a failed start is the one case not worth showing the user.
    ///
    /// The benign case is a session already up with an agent in it: the rail's
    /// poll was a beat stale, selecting it did the right thing, and an alert
    /// would be noise.
    ///
    /// A PURE FUNCTION SO IT CAN BE TESTED, and it earned that. The check used
    /// to live inline in the view, where nothing exercised it, and it matched
    /// `already exists` — which the mini also returned for a session whose agent
    /// had exited. Those rows greyed, offered a Start, and had every attempt
    /// discarded here in silence. An untested predicate deciding what a user is
    /// allowed to hear is how that lasted.
    static func isBenignStartFailure(_ message: String) -> Bool {
        message.contains("already has an agent")
    }

    @discardableResult
    static func stop(target: SSHTarget, session: String, kill: Bool) throws -> Data {
        try run(stopArguments(target: target, session: session, kill: kill))
    }

    static func render(target: SSHTarget, session: String, appearance: Appearance,
                       background: String? = nil,
                       scale: Double? = nil,
                       lineHeight: Double? = nil) throws -> String {
        let data = try run(renderArguments(target: target, session: session, appearance: appearance,
                                           background: background, scale: scale,
                                           lineHeight: lineHeight))
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw AgentError.failed("the renderer returned nothing")
        }
        return text
    }

    /// Runs one verb and returns its stdout.
    ///
    /// `stdin` is written and the pipe closed before the output is read, so a
    /// message larger than a pipe buffer cannot deadlock the two ends against
    /// each other.
    ///
    /// `classifyMissingCommand` decides whether "No such file" on stderr is read
    /// as a missing remote command. It is right for every verb that names one
    /// and wrong for a remote shell line that touches a path: a write to a
    /// deleted directory reports "No such file" too, and reading that as
    /// `notInstalled` sends the reader off to run the installer over a failure
    /// the installer has nothing to do with. A caller whose command handles
    /// paths passes `false` and gets the remote's own words.
    ///
    /// `throwOnNonZeroExit` is false for two callers, `unqueue` and
    /// `rolloverPolicy`. Each verb's REFUSAL is a normal, expected outcome carried as a valid JSON
    /// body on stdout at exit 1 (`{"ok": false, "error": …}`), per the
    /// contract — not a transport failure, so throwing here on that exit
    /// code would discard the very envelope the caller needs to decode.
    /// `classifyMissingCommand` still applies first: a genuinely missing
    /// remote command carries no JSON body at all, and that failure is real.
    ///
    /// BOUNDED, WHERE IT USED TO WAIT FOREVER. `SSHProcessRunner.run` is what
    /// turns a wedged ControlMaster into a thrown error instead of a hang —
    /// see its doc for the case reproduced. `staleSocketRecovery`, when a
    /// caller supplies it, adds one more step after a transport-shaped
    /// failure (a timeout, or ssh's own exit 255): ask the control socket
    /// whether it is still a live master and, if it plainly is not, clear it
    /// and retry once — see `SSHControlSocket`. Left `nil` by every caller
    /// except `state`, `states`, and `discoveredSessions`, the three verbs
    /// behind the panes this exists for; every other verb still gets the
    /// timeout, just not the extra round trip, since a one-off action (send
    /// a key, stop a session) has nothing to gain from retrying against a
    /// socket that was just confirmed dead moments before the user acts again.
    @discardableResult
    static func run(_ argv: [String], stdin: String? = nil,
                    classifyMissingCommand: Bool = true,
                    throwOnNonZeroExit: Bool = true,
                    timeout: TimeInterval = defaultTimeout,
                    staleSocketRecovery: (target: SSHTarget, controlPath: String)? = nil,
                    transportLog: TransportLog = .shared) throws -> Data {
        let started = Date()
        // `runQueued` holds this call to `SSHConnectionGate`'s own cap on
        // sessions through one ControlMaster, queueing it FIFO behind
        // whatever else is already using that master and requeuing it
        // in-place on a master-full refusal — see its own doc. By the time
        // an outcome reaches here, ssh's own refusal wording has already
        // been retried past, which is also why the transport-failure check
        // below excludes it explicitly rather than relying on that alone.
        let outcome = try SSHProcessRunner.runQueued(argv, stdin: stdin, timeout: timeout)
        // ssh's own documented convention: 255 is the client's own transport
        // failure, distinct from a remote command's forwarded exit status.
        // Only that shape, or our own watchdog firing, is worth spending a
        // second ssh round trip on `-O check` to explain — a session the
        // mini genuinely has no record of already reached the remote side,
        // and `-O check` would only cost time confirming what the exit code
        // already answered.
        //
        // A MASTER-FULL REFUSAL IS EXCLUDED HERE EVEN THOUGH `runQueued`
        // ALREADY HANDLES IT, deliberately: `-O check`-and-clear must never
        // run against a refusal this call never actually diagnosed as dead
        // — a live master that is merely full looks nothing like the
        // wedged-socket case this recovery exists for, and clearing its
        // file out from under every other pane sharing it would be exactly
        // the hazard `SSHControlSocket`'s own doc warns against.
        let isTransportFailure = SSHStderrClassifier.classify(outcome.stderr) != .transientMuxRefusal
            && (outcome.timedOut || outcome.terminationStatus == 255)
        if isTransportFailure {
            // THE HOST LABEL COMES FROM `argv` ITSELF, NOT FROM
            // `staleSocketRecovery`, which most callers leave `nil` — see
            // `TransportLog.hostLabel(fromArgv:)`. A transport failure is
            // worth a log line on every verb, not only the three that opt
            // into recovery.
            let host = TransportLog.hostLabel(fromArgv: argv)
            transportLog.append(
                host: host,
                event: "transport-failure timed_out=\(outcome.timedOut) exit=\(outcome.terminationStatus) "
                    + "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(started)))s "
                    + "stderr=\(TransportLog.quoted(outcome.stderr))")
            if let staleSocketRecovery {
                let check = SSHControlSocket.check(
                    target: staleSocketRecovery.target, controlPath: staleSocketRecovery.controlPath,
                    transportLog: transportLog)
                if check.warrantsClearing {
                    SSHControlSocket.clear(
                        target: staleSocketRecovery.target, controlPath: staleSocketRecovery.controlPath,
                        transportLog: transportLog)
                    let retried = try SSHProcessRunner.runQueued(argv, stdin: stdin, timeout: timeout)
                    transportLog.append(
                        host: host,
                        event: "retry timed_out=\(retried.timedOut) exit=\(retried.terminationStatus)")
                    return try decoded(retried, classifyMissingCommand: classifyMissingCommand,
                                       throwOnNonZeroExit: throwOnNonZeroExit, timeout: timeout)
                }
            }
        }
        return try decoded(outcome, classifyMissingCommand: classifyMissingCommand,
                           throwOnNonZeroExit: throwOnNonZeroExit, timeout: timeout)
    }

    /// How long `run` waits for ssh to exit before treating it as wedged and
    /// killing it — generous next to every real answer this codebase
    /// measures in milliseconds to low single-digit seconds, but bounded,
    /// which is the entire point: see `SSHProcessRunner.run`.
    static let defaultTimeout: TimeInterval = 20

    /// Turns one `SSHProcessRunner` outcome into `run`'s historical
    /// contract — the decode/throw logic every caller already depended on,
    /// reading from a struct instead of three loose locals.
    private static func decoded(_ outcome: SSHProcessOutcome, classifyMissingCommand: Bool,
                                throwOnNonZeroExit: Bool, timeout: TimeInterval) throws -> Data {
        guard outcome.terminationStatus == 0 else {
            if outcome.timedOut {
                throw AgentError.failed(
                    "ssh did not respond within \(Int(timeout))s — the connection may be wedged")
            }
            // A missing command is its own answer: the fix is running the
            // installer, not debugging a session. Anything else carries the
            // remote's own words, which name which of the three failures it was.
            if classifyMissingCommand,
               outcome.stderr.contains("command not found") || outcome.stderr.contains("No such file") {
                throw AgentError.notInstalled
            }
            guard throwOnNonZeroExit else { return outcome.stdout }
            throw AgentError.failed(outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return outcome.stdout
    }

    static func state(target: SSHTarget, session: String) throws -> SessionState {
        SessionState.decode(
            try run(stateArguments(target: target, session: session),
                    staleSocketRecovery: (target: target, controlPath: defaultControlPath())),
            fallbackSession: session)
    }

    /// Decodes one line of `session-agent state --follow` output, or nil when
    /// the line is not a JSON object at all.
    ///
    /// NIL IS A TRANSPORT GLITCH, NOT A READING. The mini's own honest
    /// "could not tell" already arrives as valid JSON — `{"state": "unknown",
    /// ...}` — and decodes through `SessionState.decode` like any other line,
    /// same as a one-shot `state` call. What this guards against is
    /// upstream of that: a blank keep-alive, a line split wrong by a buffer
    /// boundary, anything that is not a JSON object at all. Returning nil for
    /// that lets the caller skip one line and keep reading rather than
    /// publishing a bogus `.unknown` state over whatever the pane last knew.
    static func decodeFollowLine(_ line: String, fallbackSession: String) -> SessionState? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return SessionState.decode(data, fallbackSession: fallbackSession)
    }

    /// The slash commands and skills the named session can invoke.
    ///
    /// One ssh round trip, made on demand rather than polled: this changes only
    /// when a file appears on the mini, and a menu nobody has opened is not
    /// worth a recurring cost. Returns nil when the output is not a JSON object
    /// at all — the same transport-glitch guard `decodeFollowLine` makes, and
    /// for the same reason: a menu that invents entries is worse than one that
    /// says it could not read them.
    static func commands(target: SSHTarget, session: String) throws -> SessionCommands? {
        SessionCommands.decode(try run(arguments(target: target, session: session, verb: ["commands"])))
    }

    /// The knowledge documents the named session's checkout brought, or the
    /// reason the host names instead. One on-demand round trip, like
    /// `commands`. The verb exits 0 for every answer, so a reply that is not
    /// one of its two shapes is the failure, not the exit status.
    static func documents(target: SSHTarget, session: String) throws -> CheckoutDocuments {
        let data = try run(arguments(target: target, session: session, verb: ["documents"]),
                           staleSocketRecovery: (target: target, controlPath: defaultControlPath()))
        guard let decoded = CheckoutDocuments.decode(data) else {
            throw AgentError.failed("the host's reply was neither a document list nor a named reason")
        }
        return decoded
    }

    /// A brief state for each named session, keyed by name.
    ///
    /// An empty request is answered without touching ssh — the rail with no rows
    /// asks for nothing. A name the mini could not read still comes back, decoded
    /// to `unknown`, because `session_states` gives every name an entry; the rail
    /// greys such a row rather than dropping it.
    static func states(target: SSHTarget, sessions: [String]) throws -> [String: SessionState] {
        guard !sessions.isEmpty else { return [:] }
        return try decodeStates(run(
            statesArguments(target: target, sessions: sessions),
            staleSocketRecovery: (target: target, controlPath: defaultControlPath())))
    }

    /// Decodes the `{name: state}` object `session-agent states` emits. Split
    /// from the ssh call so the shape can be tested without a round trip; each
    /// value goes through the same per-session decoder a single `state` uses, so
    /// the two paths cannot drift.
    static func decodeStates(_ data: Data) throws -> [String: SessionState] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.failed("the batched states were not an object")
        }
        var out: [String: SessionState] = [:]
        for (name, value) in root {
            guard let sub = try? JSONSerialization.data(withJSONObject: value) else { continue }
            out[name] = SessionState.decode(sub, fallbackSession: name)
        }
        return out
    }

    static func send(target: SSHTarget, session: String, text: String) throws {
        try run(sendArguments(target: target, session: session), stdin: text)
    }

    static func choose(target: SSHTarget, session: String, choice: Int,
                       gateId: String? = nil, questionIndex: Int? = nil) throws {
        try run(chooseArguments(target: target, session: session, choice: choice,
                                gateId: gateId, questionIndex: questionIndex))
    }

    static func submit(target: SSHTarget, session: String,
                       gateId: String? = nil, questionIndex: Int? = nil) throws {
        try run(submitArguments(target: target, session: session,
                                gateId: gateId, questionIndex: questionIndex))
    }

    static func interrupt(target: SSHTarget, session: String) throws {
        try run(interruptArguments(target: target, session: session))
    }

    static func type(target: SSHTarget, session: String, text: String,
                     gateId: String? = nil, questionIndex: Int? = nil) throws {
        try run(typeArguments(target: target, session: session,
                              gateId: gateId, questionIndex: questionIndex),
                stdin: text)
    }

    static func key(target: SSHTarget, session: String, key: String) throws {
        try run(keyArguments(target: target, session: session, key: key))
    }

    static func focusFreeText(target: SSHTarget, session: String,
                              gateId: String? = nil, questionIndex: Int? = nil) throws {
        try run(focusFreeTextArguments(target: target, session: session,
                                       gateId: gateId, questionIndex: questionIndex))
    }

    // MARK: - Slate

    /// argv for `session-agent slate <name>`. Never sends `--all`: the Slate
    /// sheet draws the server's own default view, where a resolved ask
    /// leaves the list the moment `co-ask resolve` runs — see
    /// issue_01M3WPYD8M0P8PD20Y3ZBNGBWG's "If the answer settles the ask...
    /// the card leaves the sheet."
    static func slateArguments(
        target: SSHTarget, session: String, controlPath: String = defaultControlPath()
    ) throws -> [String] {
        try arguments(target: target, session: session, verb: ["slate"], controlPath: controlPath)
    }

    /// Runs `slate` and decodes it. `nil` only when the envelope itself could
    /// not be read — see `Slate.decode`'s doc; a transport-level failure (an
    /// unreachable host, or a `session-agent` that predates the verb) still
    /// throws, same as `state`.
    static func slate(target: SSHTarget, session: String) throws -> Slate? {
        Slate.decode(
            try run(slateArguments(target: target, session: session),
                    staleSocketRecovery: (target: target, controlPath: defaultControlPath())),
            fallbackSession: session)
    }

    /// argv for `session-agent slate-edit <name> <id> --text -`. The id
    /// follows the name the shared `arguments(...)` builder already
    /// appended, the same "action after the name" shape `rolloverArguments`
    /// uses, and the text is never on argv — only ever on stdin.
    ///
    /// `id` is validated here too, THE SECOND GUARD: `SlateCard.decode`
    /// already demotes a card whose id fails `validateCardId` to
    /// `.unknown`, so no path through the UI can reach this with a bad id,
    /// but a caller that builds argv directly (a test, or future code)
    /// should not be able to smuggle one through either. Raised in review.
    static func slateEditArguments(
        target: SSHTarget, session: String, id: String, controlPath: String = defaultControlPath()
    ) throws -> [String] {
        guard let id = validateCardId(id) else {
            throw AgentError.failed("slate-edit: invalid card id")
        }
        return try arguments(target: target, session: session, verb: ["slate-edit"], controlPath: controlPath)
            + [id, "--text", "-"]
    }

    /// argv for `session-agent slate-send <name> <id>`, with `--sig <value>` when
    /// `sig` is given. Same second guard as `slateEditArguments`, applied to the
    /// signature too. Only a host that lists `slate-sig-v1` gets `sig`.
    static func slateSendArguments(
        target: SSHTarget, session: String, id: String, sig: String? = nil,
        controlPath: String = defaultControlPath()
    ) throws -> [String] {
        guard let id = validateCardId(id) else {
            throw AgentError.failed("slate-send: invalid card id")
        }
        var argv = try arguments(target: target, session: session, verb: ["slate-send"], controlPath: controlPath) + [id]
        if let sig {
            guard SlateAnswerSignature.isWellFormed(sig) else {
                throw AgentError.failed("slate-send: malformed signature")
            }
            argv += ["--sig", sig]
        }
        return argv
    }

    /// What `slate-edit` and `slate-send` answer — the same three-way split
    /// `decodeRolloverPolicy` makes, read from the body rather than the exit
    /// status, since a refusal is a normal answer carried on stdout at exit 1
    /// (`{"ok": false, "error": ...}`), confirmed live against macstudio's
    /// `session-agent` (see this item's PR body).
    enum SlateWriteOutcome: Equatable {
        case card(SlateCard)
        case refused(String)
        /// Neither shape — empty output, not JSON, or `ok: true` with no
        /// `card`.
        case malformed
    }

    /// A PURE FUNCTION OF THE BYTES, like `decodeRolloverPolicy`, so every
    /// shape — a card, each refusal, and malformed output — can be pinned by
    /// a test without an ssh round trip.
    static func decodeSlateWrite(_ data: Data) -> SlateWriteOutcome {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .malformed
        }
        if let ok = root["ok"] as? Bool, !ok {
            return .refused(root["error"] as? String ?? "the Slate refused the change")
        }
        guard let card = root["card"] else { return .malformed }
        return .card(SlateCard.decode(card))
    }

    /// Runs `slate-edit` and decodes its outcome. Reads stdout regardless of
    /// exit status, like `unqueue` and `rolloverPolicy`: a refusal (a sent
    /// note, a resolved ask) is a normal answer at exit 1, not a transport
    /// failure.
    static func slateEdit(target: SSHTarget, session: String, id: String, text: String) throws -> SlateWriteOutcome {
        decodeSlateWrite(try run(
            slateEditArguments(target: target, session: session, id: id),
            stdin: text, throwOnNonZeroExit: false))
    }

    /// Runs `slate-send` and decodes its outcome, same exit-status handling
    /// as `slateEdit`. `sig` is passed through as `--sig` when present.
    static func slateSend(target: SSHTarget, session: String, id: String, sig: String? = nil) throws -> SlateWriteOutcome {
        decodeSlateWrite(try run(
            slateSendArguments(target: target, session: session, id: id, sig: sig),
            throwOnNonZeroExit: false))
    }

    /// argv for `session-agent slate-note <name> --text -`. No id: this
    /// creates a new draft, the one Slate write that has nothing yet to
    /// validate. The text never touches argv, same discipline as
    /// `slateEditArguments`.
    static func slateNoteArguments(
        target: SSHTarget, session: String, controlPath: String = defaultControlPath()
    ) throws -> [String] {
        try arguments(target: target, session: session, verb: ["slate-note"], controlPath: controlPath)
            + ["--text", "-"]
    }

    /// Runs `slate-note` and decodes its outcome, same exit-status handling
    /// as `slateEdit`. Shape pinned live against a throwaway tmux session
    /// (this item's PR body).
    static func slateNote(target: SSHTarget, session: String, text: String) throws -> SlateWriteOutcome {
        decodeSlateWrite(try run(
            slateNoteArguments(target: target, session: session),
            stdin: text, throwOnNonZeroExit: false))
    }

    /// argv for `session-agent slate-delete <name> <id>`. THE FIRST GUARD
    /// here too, same reasoning as `slateEditArguments`/`slateSendArguments`:
    /// a caller that builds argv directly must not be able to smuggle an
    /// unsafe id through, even though `SlateCard.decode` already keeps one
    /// out of the UI.
    static func slateDeleteArguments(
        target: SSHTarget, session: String, id: String, controlPath: String = defaultControlPath()
    ) throws -> [String] {
        guard let id = validateCardId(id) else {
            throw AgentError.failed("slate-delete: invalid card id")
        }
        return try arguments(target: target, session: session, verb: ["slate-delete"], controlPath: controlPath)
            + [id]
    }

    /// What `slate-delete` answers: `{"ok": true, "id": "..."}` on success,
    /// or the same refusal/malformed shapes `SlateWriteOutcome` uses — a
    /// sent note or anything that isn't a draft note refuses the same way,
    /// confirmed live.
    enum SlateDeleteOutcome: Equatable {
        case deleted(id: String)
        case refused(String)
        /// Neither shape — empty output, not JSON, or `ok: true` with no
        /// `id`.
        case malformed
    }

    /// A PURE FUNCTION OF THE BYTES, like `decodeSlateWrite`.
    static func decodeSlateDelete(_ data: Data) -> SlateDeleteOutcome {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .malformed
        }
        if let ok = root["ok"] as? Bool, !ok {
            return .refused(root["error"] as? String ?? "the Slate refused the delete")
        }
        guard let id = root["id"] as? String else { return .malformed }
        return .deleted(id: id)
    }

    /// Runs `slate-delete` and decodes its outcome, same exit-status
    /// handling as `slateEdit`.
    static func slateDelete(target: SSHTarget, session: String, id: String) throws -> SlateDeleteOutcome {
        decodeSlateDelete(try run(
            slateDeleteArguments(target: target, session: session, id: id),
            throwOnNonZeroExit: false))
    }
}
