import XCTest
@testable import Deck

/// Deck's half of the session pane: the argv it sends and the state it decodes.
///
/// The mini's half is tested in agent-platform. What is testable here is the
/// seam — that a session name cannot become something else on the way to a
/// remote shell, that a message never becomes an argument, and that a state Deck
/// cannot parse degrades to `unknown` rather than to a confident wrong answer.
final class SessionAgentTests: XCTestCase {

    // MARK: - argv

    func testStateArgumentsCarryTheControlMasterAndTheSession() throws {
        let args = try SessionAgent.stateArguments(target: TestHost.target, session: "hollis")
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertEqual(args.suffix(2), ["state", "hollis"])
    }

    /// A caller that names a host is addressed there — pinned for
    /// `stateArguments` and `statesArguments`, representative of every verb
    /// `target:` was threaded through in phase 6a.
    func testAnExplicitTargetAddressesThatHost() throws {
        let target = SSHTarget(user: "operator", host: "10.0.0.5")
        let single = try SessionAgent.stateArguments(target: target, session: "hollis")
        XCTAssertTrue(single.contains("operator@10.0.0.5"))

        let batched = try SessionAgent.statesArguments(target: target, sessions: ["hollis"])
        XCTAssertTrue(batched.contains("operator@10.0.0.5"))
    }

    /// Every remaining argv builder that takes a `target`, checked the same
    /// way `stateArguments`/`statesArguments` are above. `startArguments` and
    /// `stopArguments` once silently dropped `target` on the way to the shared
    /// `arguments(...)` helper — the two verbs that create and kill a session
    /// — and nothing in the suite would have caught it, because this
    /// assertion did not exist for them. Written for every builder rather
    /// than just those two, since that is exactly the gap that let it ship.
    func testExplicitTargetsReachEveryRemainingArgvBuilder() throws {
        let target = SSHTarget(user: "operator", host: "10.0.0.5")
        let addressed = "operator@10.0.0.5"

        let sessions = try SessionAgent.sessionsArguments(target: target)
        XCTAssertTrue(sessions.contains(addressed))

        let crewsRoot = try SessionAgent.crewsRootArguments(target: target)
        XCTAssertTrue(crewsRoot.contains(addressed))

        let send = try SessionAgent.sendArguments(target: target, session: "hollis")
        XCTAssertTrue(send.contains(addressed))

        let choose = try SessionAgent.chooseArguments(target: target, session: "hollis", choice: 1)
        XCTAssertTrue(choose.contains(addressed))

        let submit = try SessionAgent.submitArguments(target: target, session: "hollis")
        XCTAssertTrue(submit.contains(addressed))

        let interrupt = try SessionAgent.interruptArguments(target: target, session: "hollis")
        XCTAssertTrue(interrupt.contains(addressed))

        let unqueue = try SessionAgent.unqueueArguments(target: target, session: "hollis")
        XCTAssertTrue(unqueue.contains(addressed))

        let type = try SessionAgent.typeArguments(target: target, session: "hollis")
        XCTAssertTrue(type.contains(addressed))

        let focus = try SessionAgent.focusFreeTextArguments(target: target, session: "hollis")
        XCTAssertTrue(focus.contains(addressed))

        let key = try SessionAgent.keyArguments(target: target, session: "hollis", key: "Escape")
        XCTAssertTrue(key.contains(addressed))

        let render = try SessionAgent.renderArguments(target: target, session: "hollis", appearance: .dark)
        XCTAssertTrue(render.contains(addressed))

        let delta = try SessionAgent.deltaArguments(
           target: target, session: "hollis", cursor: 0, appearance: .dark)
        XCTAssertTrue(delta.contains(addressed))

        let start = try SessionAgent.startArguments(target: target, session: "hollis")
        XCTAssertTrue(start.contains(addressed))

        let stop = try SessionAgent.stopArguments(target: target, session: "hollis", kill: true)
        XCTAssertTrue(stop.contains(addressed))
    }

    /// `crews-root` is the ONE builder that bounds the TCP connect, and the
    /// reason is when it runs. Every other verb polls a host the rail already
    /// reached, so it rides a warm ControlMaster; this one fires the moment a
    /// host is ADDED, against a box nobody has proved is reachable. Without
    /// it an offline host waits on the OS connect timeout — `ServerAlive*`
    /// bounds a stall AFTER the handshake and says nothing about the connect.
    func testCrewsRootBoundsTheConnectUnlikeTheOtherBuilders() throws {
        let target = SSHTarget(user: "operator", host: "mini.local")

        let crewsRoot = try SessionAgent.crewsRootArguments(target: target)
        XCTAssertTrue(crewsRoot.contains("ConnectTimeout=8"))

        XCTAssertFalse(try SessionAgent.sessionsArguments(target: target)
            .contains { $0.hasPrefix("ConnectTimeout") },
            "the polling builders ride a warm ControlMaster and must not change")
    }

    /// `crews-root` takes no session name, the same shape `sessions` takes:
    /// it answers about the whole host rather than one name. Pinned
    /// separately from `testExplicitTargetsReachEveryRemainingArgvBuilder`
    /// because that test only checks the target reaches argv, not that the
    /// verb carries nothing else.
    func testCrewsRootArgumentsCarryNoSessionName() throws {
        let args = try SessionAgent.crewsRootArguments(target: TestHost.target)
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertEqual(args.last, "crews-root")
    }

    func testFollowIsOptIn() throws {
        XCTAssertFalse(try SessionAgent.stateArguments(target: TestHost.target, session: "deck").contains("--follow"))
        XCTAssertTrue(try SessionAgent.stateArguments(target: TestHost.target, session: "deck", follow: true)
            .contains("--follow"))
    }

    /// The name lands in a command that ssh joins and a remote shell splits, so
    /// it goes through the same gate the terminal argv uses.
    func testAnInvalidSessionNameNeverReachesArgv() {
        for bad in ["steward; rm -rf ~", "$(whoami)", "a b", "", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try SessionAgent.stateArguments(target: TestHost.target, session: bad))
            XCTAssertThrowsError(try SessionAgent.sendArguments(target: TestHost.target, session: bad))
            XCTAssertThrowsError(try SessionAgent.chooseArguments(target: TestHost.target, session: bad, choice: 1))
            XCTAssertThrowsError(try SessionAgent.interruptArguments(target: TestHost.target, session: bad))
            XCTAssertThrowsError(try SessionAgent.focusFreeTextArguments(target: TestHost.target, session: bad))
            XCTAssertThrowsError(try SessionAgent.renderArguments(target: TestHost.target, session: bad, appearance: .dark))
        }
    }

    /// A host `user`/`address` from a hand-edited `theme.json`'s `hosts`
    /// table reaches the same destination token a session name does. This
    /// gate is what makes the guarantee hold regardless of who built the
    /// `SSHTarget` — `parseHosts` also drops a row shaped like this before it
    /// ever reaches the table, but the argv gate is the one that cannot be
    /// bypassed by a target built some other way.
    func testAnInjectionShapedTargetNeverReachesArgv() {
        let badUser = SSHTarget(user: "-oProxyCommand=touch /tmp/pwned;", host: "10.0.0.5")
        let badHost = SSHTarget(user: "operator", host: "-oProxyCommand=touch /tmp/pwned;")
        for target in [badUser, badHost] {
            XCTAssertThrowsError(try SessionAgent.stateArguments(target: target, session: "deck"))
            XCTAssertThrowsError(try SessionAgent.statesArguments(target: target, sessions: ["deck"]))
            XCTAssertThrowsError(try SessionAgent.sessionsArguments(target: target))
            XCTAssertThrowsError(try SessionAgent.crewsRootArguments(target: target))
            XCTAssertThrowsError(
                try SessionAgent.renderArguments(target: target, session: "deck", appearance: .dark))
            XCTAssertThrowsError(try SessionAgent.startArguments(target: target, session: "deck"))
            XCTAssertThrowsError(
                try SessionAgent.stopArguments(target: target, session: "deck", kill: false))
        }
    }

    // MARK: - AgentError description

    /// `.failed(text)` must render as `text` alone, not `failed("text")` —
    /// Swift's synthesized description quotes and wraps the associated
    /// value, which is what leaked into a failed crew create's alert:
    /// `Could not create test: failed("session-agent: --create-dir path
    /// must be under /Users/<account>/Convivy: /Users/<account>/test")`.
    func testFailedDescriptionIsTheBareMessage() {
        let error: Error = SessionAgent.AgentError.failed("path must be under \(TestHost.homeRoot)/Convivy")
        XCTAssertEqual("\(error)", "path must be under \(TestHost.homeRoot)/Convivy")
        XCTAssertEqual(error.localizedDescription, "path must be under \(TestHost.homeRoot)/Convivy")
    }

    func testNotInstalledDescriptionIsAPlainSentence() {
        let error: Error = SessionAgent.AgentError.notInstalled
        let description = "\(error)"
        XCTAssertFalse(description.contains("notInstalled"),
                       "must not be the synthesized case name, got: \(description)")
        XCTAssertTrue(description.contains("session-agent"))
    }

    func testInvalidSessionNameDescriptionIsAPlainSentence() {
        let error: Error = SessionAgent.AgentError.invalidSessionName("bad name")
        let description = "\(error)"
        XCTAssertFalse(description.contains("invalidSessionName"),
                       "must not be the synthesized case name, got: \(description)")
        XCTAssertTrue(description.contains("bad name"))
    }

    /// A message travels on stdin. On argv it would be visible in the remote
    /// process table, and it would have to survive ssh's joining intact.
    func testSendPutsTheMessageOnStdinNotArgv() throws {
        let args = try SessionAgent.sendArguments(target: TestHost.target, session: "deck")
        XCTAssertEqual(args.suffix(3), ["deck", "--text", "-"])
    }

    func testChoosePutsTheDigitAfterTheName() throws {
        let args = try SessionAgent.chooseArguments(target: TestHost.target, session: "deck", choice: 3)
        XCTAssertEqual(args.suffix(3), ["choose", "deck", "3"])
    }

    func testAChoiceOutsideTheMenuIsRefused() {
        for bad in [0, 10, -1] {
            XCTAssertThrowsError(try SessionAgent.chooseArguments(target: TestHost.target, session: "deck", choice: bad))
        }
    }

    /// The walk takes a session and nothing else. It carries no row number on
    /// purpose: the mini finds the row by reading the pane, because the option list
    /// wraps and a row Deck computed would be a row nobody verified.
    func testFocusFreeTextCarriesOnlyTheSession() throws {
        let args = try SessionAgent.focusFreeTextArguments(target: TestHost.target, session: "deck")
        XCTAssertEqual(args.suffix(2), ["focus-free-text", "deck"])
    }

    // MARK: - Slate

    func testSlateArgumentsCarryTheSessionAndNoAllFlag() throws {
        let args = try SessionAgent.slateArguments(target: TestHost.target, session: "deck")
        XCTAssertEqual(args.suffix(2), ["slate", "deck"])
        XCTAssertFalse(args.contains("--all"),
                       "the sheet draws the server's default view, not the --all one")
    }

    /// `slate-edit <name> <id> --text -`: the id follows the name, and the
    /// text is never on argv.
    func testSlateEditArgumentsPutTheIdAfterTheNameAndTheTextOnStdin() throws {
        let args = try SessionAgent.slateEditArguments(target: TestHost.target, session: "deck", id: "a-7f3k2q")
        XCTAssertEqual(args.suffix(4), ["deck", "a-7f3k2q", "--text", "-"])
    }

    func testSlateSendArgumentsPutTheIdAfterTheName() throws {
        let args = try SessionAgent.slateSendArguments(target: TestHost.target, session: "deck", id: "a-7f3k2q")
        XCTAssertEqual(args.suffix(3), ["slate-send", "deck", "a-7f3k2q"])
    }

    /// `slate-note <name> --text -`: no id to carry — this is the one Slate
    /// write that creates a card rather than acting on one — and the text is
    /// never on argv.
    func testSlateNoteArgumentsCarryNoIdAndPutTheTextOnStdin() throws {
        let args = try SessionAgent.slateNoteArguments(target: TestHost.target, session: "deck")
        XCTAssertEqual(args.suffix(4), ["slate-note", "deck", "--text", "-"])
    }

    func testSlateDeleteArgumentsPutTheIdAfterTheName() throws {
        let args = try SessionAgent.slateDeleteArguments(target: TestHost.target, session: "deck", id: "n-9d1x4m")
        XCTAssertEqual(args.suffix(3), ["slate-delete", "deck", "n-9d1x4m"])
    }

    func testAnInvalidSessionNameNeverReachesSlateArgv() {
        for bad in ["deck; rm -rf ~", "$(whoami)", "a b"] {
            XCTAssertThrowsError(try SessionAgent.slateArguments(target: TestHost.target, session: bad))
            XCTAssertThrowsError(
                try SessionAgent.slateEditArguments(target: TestHost.target, session: bad, id: "a-1"))
            XCTAssertThrowsError(
                try SessionAgent.slateSendArguments(target: TestHost.target, session: bad, id: "a-1"))
            XCTAssertThrowsError(try SessionAgent.slateNoteArguments(target: TestHost.target, session: bad))
            XCTAssertThrowsError(
                try SessionAgent.slateDeleteArguments(target: TestHost.target, session: bad, id: "n-1"))
        }
    }

    /// SECURITY, THE SECOND GUARD: `SlateCard.decode` already demotes a
    /// hostile id to `.unknown` before it ever reaches Deck's UI, but
    /// `slateEditArguments`/`slateSendArguments`/`slateDeleteArguments` must
    /// refuse to build argv for one too, in case a future caller passes an
    /// id straight through without going via `decode` first — ssh re-splits
    /// trailing argv in the remote shell, so a crafted id on the command
    /// line is remote command execution. Raised in review for the first two
    /// verbs; `slateDeleteArguments` carries the same guard from its own
    /// construction, the lesson from that review applied to a new verb.
    func testAnInvalidCardIdNeverReachesSlateArgv() {
        for bad in ["a-1; rm -rf ~", "$(whoami)", "a 1"] {
            XCTAssertThrowsError(
                try SessionAgent.slateEditArguments(target: TestHost.target, session: "deck", id: bad))
            XCTAssertThrowsError(
                try SessionAgent.slateSendArguments(target: TestHost.target, session: "deck", id: bad))
            XCTAssertThrowsError(
                try SessionAgent.slateDeleteArguments(target: TestHost.target, session: "deck", id: bad))
        }
    }

    /// Rendering is a DIFFERENT command. Sending `--theme` to `session-agent`
    /// would reach a parser that has never heard of it.
    func testRenderUsesTheRendererNotTheDriver() throws {
        let args = try SessionAgent.renderArguments(target: TestHost.target, session: "deck", appearance: .dark)
        XCTAssertTrue(args.contains("session-view"))
        XCTAssertFalse(args.contains("session-agent"))
        XCTAssertEqual(args.suffix(4), ["--render-tmux", "deck", "--theme", "dark"])
    }

    /// The shell resolves the appearance and the page is told. A page left to
    /// follow the OS would go light beside a dark rail the moment Deck is pinned.
    func testTheResolvedAppearanceIsPassedToTheRenderer() throws {
        XCTAssertEqual(
            try SessionAgent.renderArguments(target: TestHost.target, session: "deck", appearance: .light).last, "light")
        XCTAssertEqual(
            try SessionAgent.renderArguments(target: TestHost.target, session: "deck", appearance: .dark).last, "dark")
    }

    func testRenderFileUsesTheRendererNotTheDriver() {
        let args = SessionAgent.renderFileArguments(
           target: TestHost.target, path: "\(TestHost.homeRoot)/Convivy/file.md", appearance: .dark)
        XCTAssertTrue(args.contains("session-view"))
        XCTAssertFalse(args.contains("session-agent"))
    }

    /// The path is the last meaningful element, shell-quoted, followed by --theme.
    func testRenderFileTrailingShape() {
        let args = SessionAgent.renderFileArguments(
           target: TestHost.target, path: "\(TestHost.homeRoot)/Convivy/file.md",
            appearance: .dark,
            controlPath: "/tmp/cm-%C"
        )
        XCTAssertEqual(args.suffix(4),
                       ["--render-file", "'\(TestHost.homeRoot)/Convivy/file.md'", "--theme", "dark"])
    }

    /// A space in the path must be protected so the remote shell does not split it.
    func testRenderFileShellQuotesPathWithSpace() {
        let args = SessionAgent.renderFileArguments(
           target: TestHost.target, path: "\(TestHost.homeRoot)/My Docs/file.md",
            appearance: .light,
            controlPath: "/tmp/cm-%C"
        )
        XCTAssertEqual(args.suffix(4),
                       ["--render-file", "'\(TestHost.homeRoot)/My Docs/file.md'", "--theme", "light"])
    }

    /// An embedded single quote in the path uses the POSIX `'\''` escape sequence.
    func testRenderFileShellQuotesEmbeddedSingleQuote() {
        let args = SessionAgent.renderFileArguments(
           target: TestHost.target, path: "\(TestHost.homeRoot)/Operator's Work/file.md",
            appearance: .light,
            controlPath: "/tmp/cm-%C"
        )
        XCTAssertTrue(args.contains("'\(TestHost.homeRoot)/Operator'\\''s Work/file.md'"))
    }

    /// File renders use the same separate render ControlMaster as session renders,
    /// so they multiplex onto the compressed channel without interfering with the
    /// terminal master.
    func testRenderFileUsesTheSeparateRenderControlMaster() {
        let args = SessionAgent.renderFileArguments(
           target: TestHost.target, path: "\(TestHost.homeRoot)/file.md",
            appearance: .light,
            controlPath: "/tmp/deck-cm-%C"
        )
        XCTAssertTrue(args.contains("ControlPath=/tmp/deck-cm-%C-render"))
    }

    func testRenderFilePassesResolvedTheme() {
        XCTAssertTrue(
            SessionAgent.renderFileArguments(
               target: TestHost.target, path: "\(TestHost.homeRoot)/f.md", appearance: .dark).contains("dark"))
        XCTAssertTrue(
            SessionAgent.renderFileArguments(
               target: TestHost.target, path: "\(TestHost.homeRoot)/f.md", appearance: .light).contains("light"))
    }

    func testRenderFileUsesCompression() {
        let args = SessionAgent.renderFileArguments(
           target: TestHost.target, path: "\(TestHost.homeRoot)/file.md", appearance: .light)
        XCTAssertTrue(args.contains("-C"), "file renders use the compressed render master")
    }

    // MARK: - renderKBArguments

    func testRenderKBUsesTheRendererNotTheDriver() {
        let args = SessionAgent.renderKBArguments(
           target: TestHost.target, docId: "deck/specs/session-pane", appearance: .dark)
        XCTAssertTrue(args.contains("session-view"))
        XCTAssertFalse(args.contains("session-agent"))
    }

    /// The doc-id is the last meaningful element before --theme, and it must
    /// be shell-quoted so the remote shell sees it as one token.
    func testRenderKBTrailingShape() {
        let args = SessionAgent.renderKBArguments(
           target: TestHost.target, docId: "deck/specs/session-pane",
            appearance: .dark,
            controlPath: "/tmp/cm-%C"
        )
        XCTAssertEqual(args.suffix(4),
                       ["--render-kb", "'deck/specs/session-pane'", "--theme", "dark"])
    }

    /// The doc-id is constrained to [a-z0-9-/] by validateKBId — a charset
    /// with no shell metacharacter — but is POSIX-single-quoted anyway.
    /// A charset assumption is a weaker guarantee than quoting.
    func testRenderKBShellQuotesTheDocId() {
        let args = SessionAgent.renderKBArguments(
           target: TestHost.target, docId: "deck/specs/session-pane", appearance: .light,
            controlPath: "/tmp/cm-%C")
        XCTAssertTrue(args.contains("'deck/specs/session-pane'"),
                      "the doc-id must be POSIX-single-quoted on the argv")
    }

    /// KB renders use the same separate render ControlMaster as file and
    /// session renders, so they multiplex onto the compressed channel without
    /// interfering with the terminal master.
    func testRenderKBUsesTheSeparateRenderControlMaster() {
        let args = SessionAgent.renderKBArguments(
           target: TestHost.target, docId: "deck/specs/session-pane",
            appearance: .light,
            controlPath: "/tmp/deck-cm-%C"
        )
        XCTAssertTrue(args.contains("ControlPath=/tmp/deck-cm-%C-render"))
    }

    func testRenderKBPassesResolvedTheme() {
        XCTAssertTrue(
            SessionAgent.renderKBArguments(
               target: TestHost.target, docId: "deck/specs/session-pane", appearance: .dark).contains("dark"))
        XCTAssertTrue(
            SessionAgent.renderKBArguments(
               target: TestHost.target, docId: "deck/specs/session-pane", appearance: .light).contains("light"))
    }

    func testRenderKBUsesCompression() {
        let args = SessionAgent.renderKBArguments(
           target: TestHost.target, docId: "deck/specs/session-pane", appearance: .light)
        XCTAssertTrue(args.contains("-C"), "KB renders use the compressed render master")
    }

    // MARK: - Delta argv

    /// Built the way `renderArguments` is, with `--delta-since` appended —
    /// the append bridge's rows have to match what the same renderer already
    /// put on the page.
    func testDeltaUsesTheRendererNotTheDriver() throws {
        let args = try SessionAgent.deltaArguments(target: TestHost.target, session: "deck", cursor: 0, appearance: .dark)
        XCTAssertTrue(args.contains("session-view"))
        XCTAssertFalse(args.contains("session-agent"))
        XCTAssertEqual(args.suffix(6), ["--render-tmux", "deck", "--theme", "dark", "--delta-since", "0"])
    }

    func testDeltaCarriesTheGivenCursor() throws {
        let args = try SessionAgent.deltaArguments(target: TestHost.target, session: "deck", cursor: 412, appearance: .light)
        XCTAssertEqual(args.suffix(2), ["--delta-since", "412"])
    }

    /// The name lands in the same ssh argv every other verb's does.
    func testAnInvalidSessionNameNeverReachesDeltaArgv() {
        for bad in ["steward; rm -rf ~", "$(whoami)", "a b", ""] {
            XCTAssertThrowsError(
                try SessionAgent.deltaArguments(target: TestHost.target, session: bad, cursor: 0, appearance: .dark))
        }
    }

    // MARK: - Decoding

    private func decode(_ json: String, session: String = "deck") -> SessionState {
        SessionState.decode(Data(json.utf8), fallbackSession: session)
    }

    func testDecodesEachPhase() {
        for (raw, expected) in [("idle", SessionState.Phase.idle), ("working", .working),
                                ("waiting", .waiting), ("blocked", .blocked), ("ended", .ended)] {
            XCTAssertEqual(decode(#"{"state":"\#(raw)"}"#).phase, expected)
        }
    }

    /// A phase Deck has never heard of is `unknown`, not a crash and not a
    /// guess. The mini's vocabulary can grow, and the pane's answer to not
    /// knowing is to offer the terminal.
    func testAnUnrecognisedPhaseIsUnknown() {
        XCTAssertEqual(decode(#"{"state":"reticulating"}"#).phase, .unknown)
        XCTAssertEqual(decode(#"{}"#).phase, .unknown)
    }

    func testUnparseableOutputIsUnknownRatherThanFatal() {
        let state = decode("not json at all")
        XCTAssertEqual(state.phase, .unknown)
        XCTAssertEqual(state.session, "deck", "the session it was asked about survives")
        XCTAssertFalse(state.alive)
        XCTAssertNotNil(state.reason)
    }

    /// A state carrying a field Deck predates must still parse. The mini adds
    /// fields as this design grows, and a client that refused one would go blind
    /// on the next platform release.
    func testAnUnknownFieldIsIgnored() {
        let state = decode(#"{"state":"idle","some_future_field":{"a":1}}"#)
        XCTAssertEqual(state.phase, .idle)
    }

    // MARK: - working_on

    func testDecodesAWellFormedWorkingOnBlock() {
        let state = decode("""
            {"state":"working","working_on":{"text":"chasing the pagination bug",
             "age":30,"stale":false,"since":600}}
            """)
        XCTAssertEqual(state.workingOn?.text, "chasing the pagination bug")
        XCTAssertEqual(state.workingOn?.age, 30)
        XCTAssertEqual(state.workingOn?.stale, false)
        XCTAssertEqual(state.workingOn?.since, 600)
    }

    /// The field the whole batch was seeded with on the mini — every session
    /// carries the key. Still, a state that predates it, or a reading from a
    /// mini that could not assemble one, must decode rather than throw.
    func testAStateWithNoWorkingOnKeyStillDecodes() {
        let state = decode(#"{"state":"idle"}"#)
        XCTAssertNil(state.workingOn)
    }

    /// A document shaped wrong for `working_on` costs that one field, never
    /// the state read — the contract's degrade-per-field rule.
    func testAMalformedWorkingOnCostsTheFieldNotTheState() {
        for json in [
            #"{"state":"working","working_on":"not an object"}"#,
            #"{"state":"working","working_on":{"text":42}}"#,
            #"{"state":"working","working_on":{"age":30}}"#,
        ] {
            let state = decode(json)
            XCTAssertEqual(state.phase, .working, json)
            XCTAssertNil(state.workingOn, json)
        }
    }

    /// The producer's all-null shape for "nothing recorded" — the key is
    /// present but every field is null. Decodes to nil, same as an absent
    /// `text`, so the strip draws nothing rather than an empty line.
    func testAllNullWorkingOnFieldsDecodeToNothingRecorded() {
        let state = decode("""
            {"state":"idle","working_on":{"text":null,"age":null,
             "stale":null,"since":null}}
            """)
        XCTAssertNil(state.workingOn)
    }

    /// `since` absent must never be filled in from `age` — an older writer's
    /// recording carries no start time, and inventing one from the last
    /// write would report hours-old work as seconds old.
    func testSinceNullDoesNotFallBackToAge() {
        let state = decode("""
            {"state":"working","working_on":{"text":"reading the contract doc",
             "age":45,"stale":false}}
            """)
        XCTAssertEqual(state.workingOn?.age, 45)
        XCTAssertNil(state.workingOn?.since)
    }

    // MARK: - ctx_pct and rollover (the rail's context meter)

    /// The brief `states` shape agent-platform#560 serves, captured from the
    /// mini on 2026-09-13: `ctx_pct` and `rollover` at the top level, with no
    /// vitals block.
    func testDecodesTheBriefContextAndRolloverShape() {
        let state = decode("""
            {"state":"working","ctx_pct":39,"rollover":{"calls_seeking":0,"cap":null,
             "policy":{"floor_pct":null,"mode":"observe","seek_call_cap":null,"seek_pct":70},
             "reason":null,"since":1789325852.5,"state":"none","vetoed_until":null}}
            """)
        XCTAssertEqual(state.contextPercent, 39)
        XCTAssertEqual(state.rollover?.state, .ok)
        XCTAssertEqual(state.rollover?.callsSeeking, 0)
        XCTAssertNil(state.rollover?.cap)
        XCTAssertEqual(state.rollover?.since, 1789325852.5)
        XCTAssertEqual(state.rollover?.policy?.seekPercent, 70)
        XCTAssertNil(state.rollover?.policy?.floorPercent)
        XCTAssertEqual(state.rollover?.policy?.mode, "observe")
    }

    /// The open pane's full read carries the number only inside `vitals` on an
    /// older mini; the meter reads it from there rather than going blank.
    func testContextPercentFallsBackToVitals() {
        let state = decode(#"{"state":"idle","vitals":{"ctx_pct":48.1}}"#)
        XCTAssertEqual(state.contextPercent, 48.1)
    }

    /// When both are present, the top-level reading wins, since that is the
    /// one the rail's poll carries.
    func testTopLevelContextPercentWinsOverVitals() {
        let state = decode(#"{"state":"idle","ctx_pct":52,"vitals":{"ctx_pct":48}}"#)
        XCTAssertEqual(state.contextPercent, 52)
    }

    func testAStateWithNoRolloverKeyDecodesToNil() {
        let state = decode(#"{"state":"idle"}"#)
        XCTAssertNil(state.rollover)
        XCTAssertNil(state.contextPercent)
    }

    /// Each wire value of the closed set maps to its case, and anything else
    /// is kept as `.unrecognized` rather than rounded to a known state.
    func testRolloverStatesMapTheClosedSet() {
        let cases: [(String, SessionState.Rollover.State)] = [
            ("none", .ok), ("seeking", .seeking), ("roll_now", .rollNow),
            ("rolling", .rolling), ("vetoed", .vetoed), ("parked", .parked),
            ("draining", .unrecognized("draining")),
        ]
        for (wire, expected) in cases {
            let state = decode(#"{"state":"idle","rollover":{"state":"\#(wire)"}}"#)
            XCTAssertEqual(state.rollover?.state, expected, wire)
        }
    }

    func testDecodesAVetoAndASuccessorWindow() {
        let vetoed = decode(#"{"state":"idle","rollover":{"state":"vetoed","vetoed_until":"floor_pct"}}"#)
        XCTAssertEqual(vetoed.rollover?.vetoedUntil, "floor_pct")
        let rolling = decode(#"{"state":"working","rollover":{"state":"rolling","successor_window":2}}"#)
        XCTAssertEqual(rolling.rollover?.successorWindow, 2)
    }

    /// A `rollover` shaped wrong costs that field, never the state read, and a
    /// non-numeric `ctx_pct` costs only the meter.
    func testAMalformedRolloverOrContextCostsOnlyThatField() {
        for json in [
            #"{"state":"working","rollover":"seeking"}"#,
            #"{"state":"working","rollover":{"calls_seeking":3}}"#,
            #"{"state":"working","ctx_pct":"39"}"#,
        ] {
            let state = decode(json)
            XCTAssertEqual(state.phase, .working, json)
            XCTAssertNil(state.rollover, json)
            XCTAssertNil(state.contextPercent, json)
        }
    }

    // MARK: - Gates

    func testDecodesAnAskingClassGateWithItsOptions() {
        let state = decode("""
            {"state":"blocked","gate":{"kind":"question","tool":"AskUserQuestion",
             "questions":[{"question":"Which?","header":"Pick",
              "options":[{"label":"Red","description":"the warm one"},{"label":"Blue"}]}]}}
            """)
        XCTAssertEqual(state.phase, .blocked)
        let gate = state.gate
        XCTAssertEqual(gate?.kind, .question)
        XCTAssertEqual(gate?.questions.first?.header, "Pick")
        XCTAssertEqual(gate?.questions.first?.options.map(\.label), ["Red", "Blue"])
        XCTAssertEqual(gate?.questions.first?.options.first?.detail, "the warm one")
    }

    /// The two gate classes do not share a payload shape upstream. The mini
    /// normalises them; this pins that Deck reads the normalised form rather
    /// than expecting an asking-class payload from a permission-class gate.
    func testDecodesAPermissionClassGate() {
        let state = decode("""
            {"state":"blocked","gate":{"kind":"permission","tool":"Bash",
             "detail":{"command":"sw_vers"},"suggestions":[{"type":"addRules"}]}}
            """)
        XCTAssertEqual(state.gate?.kind, .permission)
        XCTAssertEqual(state.gate?.tool, "Bash")
        XCTAssertTrue(state.gate?.hasSuggestions ?? false)
        XCTAssertTrue(state.gate?.questions.isEmpty ?? false)
    }

    /// Blocked with no renderable gate is a real answer — "stopped for you, and
    /// I cannot show you what it wants" — and the pane offers the terminal for
    /// it rather than drawing an empty dialog.
    func testBlockedWithoutAGateStaysBlocked() {
        let state = decode(#"{"state":"blocked","gate":null}"#)
        XCTAssertEqual(state.phase, .blocked)
        XCTAssertNil(state.gate)
    }

    func testAMalformedGateDoesNotTakeTheStateWithIt() {
        XCTAssertEqual(decode(#"{"state":"blocked","gate":"nonsense"}"#).phase, .blocked)
        XCTAssertNil(decode(#"{"state":"blocked","gate":{"kind":"???"}}"#).gate)
    }

    // MARK: - What the pane does with a phase

    /// Blocked takes an answer rather than a message, and an ended session takes
    /// nothing. Letting a message be typed into either would send it somewhere
    /// it cannot land.
    func testOnlyLiveStatesAcceptATypedMessage() {
        XCTAssertTrue(SessionState.Phase.idle.acceptsMessage)
        XCTAssertTrue(SessionState.Phase.working.acceptsMessage)
        XCTAssertTrue(SessionState.Phase.waiting.acceptsMessage)
        XCTAssertFalse(SessionState.Phase.blocked.acceptsMessage)
        XCTAssertFalse(SessionState.Phase.ended.acceptsMessage)
        XCTAssertFalse(SessionState.Phase.unknown.acceptsMessage)
    }

    func testEveryPhaseHasWordsForTheUser() {
        for phase in [SessionState.Phase.idle, .working, .waiting, .blocked, .ended, .unknown] {
            XCTAssertFalse(phase.label.isEmpty)
            XCTAssertFalse(phase.label == phase.rawValue, "\(phase) shows a state name, not words")
        }
    }

    // MARK: - held

    /// The four payload shapes the contract distinguishes. Absent and `null`
    /// must decode to different answers — "not read" and "read and could not
    /// tell" are different facts a reader acts on differently.
    func testAnAbsentHeldKeyIsNotRead() {
        XCTAssertNil(decode(#"{"state":"working"}"#).held)
    }

    func testANullHeldIsUnknown() {
        XCTAssertEqual(decode(#"{"state":"working","held":null}"#).held, .unknown)
    }

    func testAnEmptyMessagesListIsAPositiveZero() {
        XCTAssertEqual(
            decode(#"{"state":"working","held":{"messages":[]}}"#).held, .count(0))
    }

    func testMessagesDecodeToTheirCount() {
        XCTAssertEqual(
            decode(#"{"state":"working","held":{"messages":["a","b","c"]}}"#).held,
            .count(3))
    }

    /// A `held` present but not shaped like the contract's object — carrying
    /// no `messages` array at all — is "looked and could not tell", the same
    /// answer a `null` gets, rather than a decode failure that takes the rest
    /// of the state with it.
    func testAHeldOfTheWrongShapeIsUnknown() {
        XCTAssertEqual(decode(#"{"state":"working","held":"nonsense"}"#).held, .unknown)
        XCTAssertEqual(decode(#"{"state":"working","held":{}}"#).held, .unknown)
    }

    /// THE PRIVACY CONSTRAINT, ASSERTED POSITIVELY. `held.messages` is text
    /// the reader typed that the agent has not read yet, and Deck has no
    /// reason to hold it at rest — so the decoded state must not carry the
    /// string anywhere, not just in the field this test happens to check. A
    /// later refactor that "helpfully" threads the strings into `HeldCount`
    /// (or anywhere else reachable from `SessionState`) must fail this test:
    /// the search below walks the WHOLE decoded value with `Mirror`, not one
    /// named property.
    func testTheDecodedStateNeverCarriesTheMessageText() {
        let needle = "a message the mini must never hand back except through unqueue"
        let state = decode(#"""
            {"state":"working","held":{"messages":["\#(needle)"]}}
            """#)
        XCTAssertEqual(state.held, .count(1), "the count still has to decode")
        XCTAssertFalse(Self.anyString(in: state, contains: needle),
                       "the message text reached SessionState, which must never hold it")
    }

    /// Walks a value's stored properties recursively, looking for `needle` in
    /// any `String` it finds — through optionals, arrays, and nested structs
    /// alike, so this stays correct however `SessionState` reshapes itself.
    private static func anyString(in value: Any, contains needle: String) -> Bool {
        if let s = value as? String { return s.contains(needle) }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let unwrapped = mirror.children.first?.value else { return false }
            return anyString(in: unwrapped, contains: needle)
        }
        for child in mirror.children {
            if anyString(in: child.value, contains: needle) { return true }
        }
        return false
    }
}

/// `session-view --delta-since` answers in a JSON envelope, never plain HTML.
/// These pin the decode under every shape it could take, including the ones a
/// future producer field or a transport hiccup could send — each degrades to
/// `.unavailable` on its own, per
/// `deck/specs/session-pane-incremental-rendering`.
final class SessionAgentDeltaDecodingTests: XCTestCase {

    private func decode(_ json: String) -> SessionAgent.DeltaOutcome {
        SessionAgent.decodeDelta(Data(json.utf8))
    }

    func testAWellFormedEnvelopeDecodes() {
        let outcome = decode("""
            {"lines": 412, "full": false,
             "rows": [{"key": "a.0", "html": "<div class=turn data-k=a.0>hi</div>"}]}
            """)
        XCTAssertEqual(outcome, .rows(lines: 412, rows: [
            SessionAgent.DeltaRow(key: "a.0", html: "<div class=turn data-k=a.0>hi</div>"),
        ], removed: []))
    }

    func testRowOrderIsPreserved() {
        let outcome = decode("""
            {"lines": 3, "full": false,
             "rows": [{"key": "a.0", "html": "1"}, {"key": "b.0", "html": "2"}]}
            """)
        guard case .rows(_, let rows, _) = outcome else { return XCTFail("expected .rows") }
        XCTAssertEqual(rows.map(\.key), ["a.0", "b.0"])
    }

    func testAnEmptyRowsArrayIsAValidDelta() {
        // A poll can find something worth re-checking (phase, gate) with no
        // new transcript lines. The cursor still moves.
        XCTAssertEqual(decode(#"{"lines": 5, "full": false, "rows": []}"#),
                       .rows(lines: 5, rows: [], removed: []))
    }

    func testFullTrueCarriesAWholePage() {
        XCTAssertEqual(decode(#"{"full": true, "page": "<html>whole page</html>"}"#),
                       .full(page: "<html>whole page</html>"))
    }

    func testFullTrueWithNoPageIsUnavailable() {
        XCTAssertEqual(decode(#"{"full": true}"#), .unavailable)
    }

    func testFullTrueWithAnEmptyPageIsUnavailable() {
        XCTAssertEqual(decode(#"{"full": true, "page": ""}"#), .unavailable)
    }

    func testNotJSONAtAllIsUnavailable() {
        XCTAssertEqual(decode("not json"), .unavailable)
    }

    func testAJSONArrayRatherThanAnObjectIsUnavailable() {
        XCTAssertEqual(decode("[1,2,3]"), .unavailable)
    }

    func testAMissingLinesIsUnavailable() {
        XCTAssertEqual(decode(#"{"full": false, "rows": []}"#), .unavailable)
    }

    func testANegativeLinesIsUnavailable() {
        XCTAssertEqual(decode(#"{"lines": -1, "full": false, "rows": []}"#), .unavailable)
    }

    func testANonIntegerLinesIsUnavailable() {
        XCTAssertEqual(decode(#"{"lines": "412", "full": false, "rows": []}"#), .unavailable)
    }

    func testAMissingRowsIsUnavailable() {
        XCTAssertEqual(decode(#"{"lines": 5, "full": false}"#), .unavailable)
    }

    func testRowsAsSomethingOtherThanAnArrayIsUnavailable() {
        XCTAssertEqual(decode(#"{"lines": 5, "full": false, "rows": "nope"}"#), .unavailable)
    }

    func testARowMissingItsKeyMakesTheWholeBatchUnavailable() {
        // Not just that one row dropped: skipping it would still advance the
        // cursor past content that was never rendered, and no later delta
        // would ever re-offer it.
        XCTAssertEqual(
            decode(#"{"lines": 5, "full": false, "rows": [{"html": "hi"}]}"#), .unavailable)
    }

    func testARowMissingItsHtmlMakesTheWholeBatchUnavailable() {
        XCTAssertEqual(
            decode(#"{"lines": 5, "full": false, "rows": [{"key": "a.0"}]}"#), .unavailable)
    }

    func testARowWithAnEmptyKeyMakesTheWholeBatchUnavailable() {
        XCTAssertEqual(
            decode(#"{"lines": 5, "full": false, "rows": [{"key": "", "html": "hi"}]}"#),
            .unavailable)
    }

    func testARowThatIsNotAnObjectMakesTheWholeBatchUnavailable() {
        XCTAssertEqual(decode(#"{"lines": 5, "full": false, "rows": ["nope"]}"#), .unavailable)
    }

    func testAnUnknownFieldIsIgnored() {
        // The producer can grow fields; a client that refused an unknown one
        // would go blind on the next agent-platform release.
        XCTAssertEqual(
            decode(#"{"lines": 1, "full": false, "rows": [], "future_field": {"a": 1}}"#),
            .rows(lines: 1, rows: [], removed: []))
    }

    func testEmptyDataIsUnavailable() {
        XCTAssertEqual(SessionAgent.decodeDelta(Data()), .unavailable)
    }

    // MARK: - Removal keys

    /// The prerequisite for held-message rows: a delta can withdraw a row it
    /// previously sent, alongside the ordinary `rows` it is adding or
    /// replacing.
    func testARemovedListIsDecoded() {
        XCTAssertEqual(
            decode(#"{"lines": 5, "full": false, "rows": [], "removed": ["a.0", "b.1"]}"#),
            .rows(lines: 5, rows: [], removed: ["a.0", "b.1"]))
    }

    /// An absent `removed` field behaves exactly as it did before this field
    /// existed — the whole point of a no-op default.
    func testAnAbsentRemovedFieldIsAnEmptyList() {
        XCTAssertEqual(
            decode(#"{"lines": 5, "full": false, "rows": []}"#),
            .rows(lines: 5, rows: [], removed: []))
    }

    /// `removed` degrades PER ENTRY rather than poisoning the whole batch —
    /// unlike a malformed row, a malformed removal key costs nothing but a
    /// beat: the row it named simply stays on the page.
    func testANonStringEntryInRemovedIsDroppedWithoutInvalidatingTheBatch() {
        XCTAssertEqual(
            decode(#"{"lines": 5, "full": false, "rows": [], "removed": ["a.0", 3, "b.1"]}"#),
            .rows(lines: 5, rows: [], removed: ["a.0", "b.1"]))
    }

    /// `removed` carrying something other than an array is the same as it
    /// being absent, not a decode failure — the rest of the envelope is
    /// still trustworthy.
    func testARemovedFieldThatIsNotAnArrayIsTreatedAsEmpty() {
        XCTAssertEqual(
            decode(#"{"lines": 5, "full": false, "rows": [], "removed": "a.0"}"#),
            .rows(lines: 5, rows: [], removed: []))
    }

    // MARK: - `newest`, the held row's position

    /// The mini marks a held row `newest` so the page can put it back at the
    /// bottom rather than replacing it where it sits.
    func testANewestRowIsDecodedAsSuch() {
        XCTAssertEqual(
            decode(#"{"lines": 5, "full": false, "rows": [{"key": "~held.0.ab", "html": "<div/>", "newest": true}]}"#),
            .rows(lines: 5, rows: [
                SessionAgent.DeltaRow(key: "~held.0.ab", html: "<div/>", newest: true),
            ], removed: []))
    }

    /// An absent `newest` is false, which is what makes an older mini — one
    /// that never sends the field — behave exactly as it does today.
    func testAnAbsentNewestFieldIsFalse() {
        XCTAssertEqual(
            decode(#"{"lines": 5, "full": false, "rows": [{"key": "a.0", "html": "<div/>"}]}"#),
            .rows(lines: 5, rows: [SessionAgent.DeltaRow(key: "a.0", html: "<div/>")],
                  removed: []))
    }

    /// `newest` degrades on its own, like `removed` and unlike `key`/`html`.
    /// A malformed value costs a held row its position for one poll; it does
    /// not justify discarding rows the cursor would then advance past.
    func testANonBooleanNewestIsFalseRatherThanADecodeFailure() {
        XCTAssertEqual(
            decode(#"{"lines": 5, "full": false, "rows": [{"key": "a.0", "html": "<div/>", "newest": "yes"}]}"#),
            .rows(lines: 5, rows: [SessionAgent.DeltaRow(key: "a.0", html: "<div/>")],
                  removed: []))
    }
}

/// `session-agent rollover`'s argv and its `{outcome, reason, rollover}`
/// answer, pinned without an ssh round trip.
final class SessionAgentRolloverTests: XCTestCase {

    private func decode(_ json: String) -> SessionAgent.RolloverOutcome {
        SessionAgent.decodeRolloverOutcome(Data(json.utf8))
    }

    /// The CLI is `session-agent rollover <name> <action>`: the action is a
    /// second positional after the name, so it must be the last argument.
    func testArgvPutsTheActionAfterTheSessionName() throws {
        let target = SSHTarget(user: "operator", host: "10.0.0.5")
        for action in SessionAgent.RolloverAction.allCases {
            let argv = try SessionAgent.rolloverArguments(target: target, session: "hollis", action: action)
            XCTAssertTrue(argv.contains("operator@10.0.0.5"), action.rawValue)
            XCTAssertEqual(Array(argv.suffix(3)), ["rollover", "hollis", action.rawValue])
        }
    }

    func testAnInvalidSessionNameNeverReachesArgv() {
        let target = SSHTarget(user: "operator", host: "10.0.0.5")
        XCTAssertThrowsError(try SessionAgent.rolloverArguments(target: target, session: "a;b", action: .force))
    }

    func testArmedCarriesTheRolloverStateAfterwards() {
        XCTAssertEqual(
            decode(#"{"outcome":"armed","reason":null,"rollover":{"state":"vetoed","vetoed_until":"floor_pct"}}"#),
            .armed(SessionState.Rollover(state: .vetoed, vetoedUntil: "floor_pct")))
    }

    func testSentDecodes() {
        XCTAssertEqual(
            decode(#"{"outcome":"sent","reason":null,"rollover":{"state":"roll_now"}}"#),
            .sent(SessionState.Rollover(state: .rollNow)))
    }

    /// A refusal is a normal answer, carried at exit 0 with the mini's reason.
    func testRefusedCarriesTheMinisReason() {
        XCTAssertEqual(
            decode(#"{"outcome":"refused","reason":"the composer holds a draft","rollover":{"state":"none"}}"#),
            .refused("the composer holds a draft"))
    }

    /// On a write, an answer Deck cannot read means it cannot say whether the
    /// override took effect, so none of these reads as success.
    func testAnUnreadableAnswerIsMalformed() {
        for json in ["", "not json", #"{"reason":null}"#, #"{"outcome":"queued"}"#] {
            XCTAssertEqual(decode(json), .malformed, json)
        }
    }
}

/// `session-agent unqueue`'s JSON envelope: success carrying the pulled
/// messages, each of the four refusal shapes, and malformed output. A PURE
/// FUNCTION OF THE BYTES, the same split `SessionAgentDeltaDecodingTests`
/// uses, so every shape is pinned without an ssh round trip. See
/// `platform/contracts/session-agent-api`'s `unqueue` paragraphs.
final class SessionAgentUnqueueDecodingTests: XCTestCase {

    private func decode(_ json: String) -> SessionAgent.UnqueueOutcome {
        SessionAgent.decodeUnqueue(Data(json.utf8))
    }

    func testSuccessWithMessagesDecodesInOrder() {
        XCTAssertEqual(
            decode(#"{"ok": true, "messages": ["first", "second"]}"#),
            .messages(["first", "second"]))
    }

    /// A real positive answer, not a partial one — the queue had already
    /// drained, and there is nothing to rewrite.
    func testSuccessWithAnEmptyListIsMessagesNotMalformed() {
        XCTAssertEqual(decode(#"{"ok": true, "messages": []}"#), .messages([]))
    }

    /// All four refusals share one shape on the wire (`{"ok": false, "error":
    /// …}`); which of the four it is lives in the string, which Deck surfaces
    /// verbatim through `lastError` rather than re-deriving.
    func testEachRefusalDecodesItsReason() {
        for reason in [
            "the composer is not observably empty",
            "could not read the transcript back",
            "the pane is unexplained",
            "a picker took the box during the recall",
        ] {
            XCTAssertEqual(
                decode(#"{"ok": false, "error": "\#(reason)"}"#), .refused(reason))
        }
    }

    func testARefusalWithNoErrorStringStillDecodesAsRefused() {
        guard case .refused = decode(#"{"ok": false}"#) else {
            return XCTFail("an ok:false with no error string is still a refusal")
        }
    }

    func testNotJSONAtAllIsMalformed() {
        XCTAssertEqual(decode("not json"), .malformed)
    }

    func testMissingOkIsMalformed() {
        XCTAssertEqual(decode(#"{"messages": ["a"]}"#), .malformed)
    }

    func testOkTrueWithNoMessagesArrayIsMalformed() {
        XCTAssertEqual(decode(#"{"ok": true}"#), .malformed)
    }

    /// A non-string entry invalidates the whole batch, unlike a delta row's
    /// `removed` list — this is the one moment this text exists in Deck, so
    /// silently dropping an entry would lose a message rather than merely
    /// mis-render one.
    func testANonStringMessageInvalidatesTheWholeBatch() {
        XCTAssertEqual(decode(#"{"ok": true, "messages": ["fine", 7]}"#), .malformed)
    }

    func testEmptyDataIsMalformed() {
        XCTAssertEqual(SessionAgent.decodeUnqueue(Data()), .malformed)
    }
}

/// `SessionAgent.decodeSlateWrite` — what `slate-edit` and `slate-send`
/// answer. Shapes pinned against macstudio's live `session-agent` (agent-platform#752):
/// see this item's PR body for exactly what was run.
final class SessionAgentSlateWriteDecodingTests: XCTestCase {

    private func decode(_ json: String) -> SessionAgent.SlateWriteOutcome {
        SessionAgent.decodeSlateWrite(Data(json.utf8))
    }

    func testSuccessDecodesTheReturnedCard() {
        let outcome = decode("""
            {"ok": true, "card": {"id": "a-dd5np4", "kind": "ask", "state": "answered",
             "question": "q", "answer_draft": "d", "answer": "d"}}
            """)
        guard case .card(.ask(let ask)) = outcome else {
            return XCTFail("expected a decoded ask card, got \(outcome)")
        }
        XCTAssertEqual(ask.id, "a-dd5np4")
        XCTAssertEqual(ask.state, .answered)
        XCTAssertEqual(ask.answer, "d")
    }

    /// Both refusals this item's own live run produced: a missing claude
    /// process (`slate-send`), and deleting the wrong kind (`slate-delete`,
    /// carried here since the shape is shared across every write verb).
    func testEachRefusalDecodesItsReason() {
        for reason in [
            "no claude process found in any pane of 'slate-probe-cq119'",
            "a-dd5np4 is an ask, not a note",
        ] {
            XCTAssertEqual(decode(#"{"ok": false, "error": "\#(reason)"}"#), .refused(reason))
        }
    }

    func testARefusalWithNoErrorStringStillDecodesAsRefused() {
        guard case .refused = decode(#"{"ok": false}"#) else {
            return XCTFail("an ok:false with no error string is still a refusal")
        }
    }

    func testNotJSONAtAllIsMalformed() {
        XCTAssertEqual(decode("not json"), .malformed)
    }

    func testOkTrueWithNoCardIsMalformed() {
        XCTAssertEqual(decode(#"{"ok": true}"#), .malformed)
    }
}

/// `SessionAgent.decodeSlateDelete` — what `slate-delete` answers. Shapes
/// pinned live against a throwaway tmux session (this item's PR body):
/// `{"id": "...", "ok": true}` on success, `{"error": "...", "ok": false}`
/// on a refusal — the same reason given live for deleting an ask ("a-dd5np4
/// is an ask, not a note") and for a card already gone ("no card '...'").
final class SessionAgentSlateDeleteDecodingTests: XCTestCase {

    private func decode(_ json: String) -> SessionAgent.SlateDeleteOutcome {
        SessionAgent.decodeSlateDelete(Data(json.utf8))
    }

    func testSuccessDecodesTheDeletedId() {
        XCTAssertEqual(decode(#"{"id": "n-es1i3q", "ok": true}"#), .deleted(id: "n-es1i3q"))
    }

    func testEachRefusalDecodesItsReason() {
        for reason in ["a-dd5np4 is an ask, not a note", "no card 'n-es1i3q'"] {
            XCTAssertEqual(decode(#"{"error": "\#(reason)", "ok": false}"#), .refused(reason))
        }
    }

    func testARefusalWithNoErrorStringStillDecodesAsRefused() {
        guard case .refused = decode(#"{"ok": false}"#) else {
            return XCTFail("an ok:false with no error string is still a refusal")
        }
    }

    func testNotJSONAtAllIsMalformed() {
        XCTAssertEqual(decode("not json"), .malformed)
    }

    func testOkTrueWithNoIdIsMalformed() {
        XCTAssertEqual(decode(#"{"ok": true}"#), .malformed)
    }
}

/// `SessionAgent.decodeCrewsRoot` — the `{"root": ...}` envelope
/// `crews-root` answers with. A PURE FUNCTION OF THE BYTES, the same split
/// `SessionAgentUnqueueDecodingTests` uses, so every shape is pinned
/// without an ssh round trip. See `platform/contracts/session-agent-api`'s
/// `crews-root` section.
final class SessionAgentCrewsRootDecodingTests: XCTestCase {
    private func decode(_ json: String) -> String? {
        SessionAgent.decodeCrewsRoot(Data(json.utf8))
    }

    func testWellFormedBodyDecodesTheRootUnresolved() {
        // UNRESOLVED, deliberately: `~` is not expanded here — see
        // `SessionAgent.decodeCrewsRoot`'s own doc for why.
        XCTAssertEqual(decode(#"{"root": "~/work"}"#), "~/work")
        XCTAssertEqual(decode(#"{"root": "\#(TestHost.secondaryHomeRoot)/crews"}"#),
                       "\(TestHost.secondaryHomeRoot)/crews")
    }

    func testNotJSONAtAllIsNil() {
        XCTAssertNil(decode("not json"))
    }

    func testMissingRootKeyIsNil() {
        XCTAssertNil(decode("{}"))
    }

    func testARootThatIsNotAStringIsNil() {
        XCTAssertNil(decode(#"{"root": 7}"#))
    }

    func testAnEmptyRootStringIsNil() {
        XCTAssertNil(decode(#"{"root": ""}"#))
    }

    func testEmptyDataIsNil() {
        XCTAssertNil(SessionAgent.decodeCrewsRoot(Data()))
    }
}

/// Decoding output captured from the live fleet, rather than from a fixture I
/// wrote to match my own decoder. A hand-made sample proves the decoder agrees
/// with itself; this proves it agrees with the mini.
final class SessionAgentLiveShapeTests: XCTestCase {
    func testDecodesRealOutputFromTheMini() throws {
        // Captured 2026-07-23 from `session-agent state hollis`.
        let live = """
            {"alive": true, "cwd": "\(TestHost.homeRoot)/Convivy/hollis", "gate": null,
             "gate_ts": null, "last_event": "Notification", "last_event_age": 4038.2,
             "pane": "%154", "pid": 4738, "progressing": false, "reason": null,
             "session": "hollis", "session_id": "6283a4ed-cde7-42e2-86db-5581fd2d4e73",
             "state": "waiting", "transcript_age": 4004.1, "unparsed_records": 0}
            """
        let state = SessionState.decode(Data(live.utf8), fallbackSession: "fallback")
        XCTAssertEqual(state.session, "hollis")
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertTrue(state.alive)
        XCTAssertNil(state.gate)
        XCTAssertEqual(state.lastEvent, "Notification")
        // Fields Deck does not model — cwd, pid, progressing, transcript_age —
        // must not prevent the ones it does from decoding.
        XCTAssertNotEqual(state.phase, .unknown)
    }
}

/// The web pane's posture, which this PR sets for every later pane.
final class ConversationWebViewSecurityTests: XCTestCase {

    /// A link in transcript text is attacker-influenceable, and NSWorkspace
    /// dispatches whatever scheme it is given to whichever app claims it.
    func testOnlyWebAndMailSchemesAreHandedToTheSystem() {
        for good in ["https://example.com", "http://example.com", "mailto:a@b.c"] {
            XCTAssertTrue(ExternalLink.allowedSchemes.contains(URL(string: good)!.scheme!))
        }
        // file:// reveals local files; ssh:// can open a connection dialog to an
        // attacker's host; app deep links can drive an installed app whose
        // handler acts without confirming.
        for bad in ["file:///etc/passwd", "ssh://attacker.example",
                    "obsidian://x", "x-callback-url://y", "javascript:alert(1)"] {
            let scheme = URL(string: bad)?.scheme?.lowercased() ?? ""
            XCTAssertFalse(ExternalLink.allowedSchemes.contains(scheme), "\(bad) must not open")
        }
    }

    func testASchemelessOrUnopenableURLIsRefusedRatherThanGuessed() {
        XCTAssertFalse(ExternalLink.open(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(ExternalLink.open(URL(string: "ssh://host")!))
    }

    /// The navigation delegate does NOT see subresource fetches, so this rule is
    /// the only thing stopping an injected `<img src=https://attacker/>` firing
    /// an outbound GET from the laptop. Reading the nil baseURL origin as a
    /// network block was the original mistake here.
    func testTheNetworkBlockRuleMatchesEverything() throws {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(NetworkBlock.rules.utf8)) as? [[String: Any]]
        let rule = try XCTUnwrap(parsed?.first)
        XCTAssertEqual((rule["trigger"] as? [String: Any])?["url-filter"] as? String, ".*")
        XCTAssertEqual((rule["action"] as? [String: Any])?["type"] as? String, "block")
    }
}
