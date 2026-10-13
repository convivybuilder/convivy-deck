import Foundation

/// What kind of thing an ssh child process just said on stderr.
///
/// NARROW ON PURPOSE. `.transientMuxRefusal` covers OpenSSH's own two-part
/// wording for ONE condition — the ControlMaster's channel count is
/// momentarily full — not two different ones: every `session-agent` call
/// rides one ControlMaster (`defaultControlPath`), and the host's sshd caps
/// how many session channels it will open on that one connection
/// (`MaxSessions`). When the cap is momentarily full, the client refuses a
/// new channel with a message carrying `mux_client_request_session`, and
/// `ControlMaster=auto` then logs "disabling multiplexing" as it falls back
/// to a full direct connection — the slow path CQ·164 closes (that fallback
/// alone measured 26.4s). Either phrase means the same thing: the socket is
/// alive and reachable, the host and the credentials are fine, and the
/// failure clears itself the moment another caller's channel frees up. That
/// is what makes it retryable by construction rather than a real failure.
///
/// A TERMINAL PANE'S OWN ssh PROCESS CANNOT PRODUCE EITHER PHRASE (CQ·165).
/// A pane connects with `ControlPath=none` precisely so a stalled pane
/// terminal cannot block the shared master's `write()` and freeze every
/// other caller riding it — which also means a pane's ssh never runs the
/// mux client this classification exists to read, since there is no shared
/// socket for it to request a channel on. `TerminalPaneView.Coordinator`
/// still classifies its child's stderr through `SSHStderrClassifier`, but
/// `.transientMuxRefusal` now reads `.other` there unconditionally.
///
/// Everything else — host unreachable, a rejected key, a tmux session that no
/// longer exists — is `.other`, and every caller of `classify` shows it to the
/// user promptly, unchanged, once it is called at all.
///
/// THAT LAST CLAUSE IS LOAD-BEARING, AND ITS ABSENCE WAS THE BUG. `classify`
/// only runs once an ssh child process has produced something to classify —
/// exited (`TerminalPaneView.Coordinator.processTerminated`) or answered
/// (`SessionPaneModel.refreshState`'s catch). A process that neither exits
/// nor answers, because it is blocked inside ssh's own multiplexing
/// handshake against a ControlMaster that stopped responding, produces
/// nothing to classify and no call to `classify` at all — this is exactly
/// what happened on 2026-08-17: an ssh child hung for minutes with no
/// stderr, no exit, and therefore no classification, `.other` or otherwise.
/// `.other`'s promise held for every outcome ssh actually reported; the
/// outage was a process that never reported one. `SSHProcessRunner` closes
/// that gap for the one-shot verbs behind the session pane and the rail
/// (`SessionAgent.run`'s `timeout`, since 2026-08-17) by bounding the child
/// process itself, so a hang becomes a reported failure instead of silence.
/// The interactive terminal pane's long-lived ssh process is NOT bounded the
/// same way — a live PTY session is legitimately silent for stretches no
/// fixed timeout could tell apart from a hang — so it can still go this
/// quiet; see the PR body this comment was corrected in for what is and is
/// not covered.
enum SSHStderrClassification: Equatable {
    case transientMuxRefusal
    case other
}

enum SSHStderrClassifier {
    /// The token OpenSSH's multiplexing client prints for this refusal, and
    /// only for this refusal — distinct from every other ssh failure message,
    /// which is what makes matching on it narrow rather than swallowing ssh
    /// stderr wholesale.
    private static let muxRefusalToken = "mux_client_request_session"

    /// `ControlMaster=auto`'s own wording the instant it abandons the
    /// multiplexing attempt and starts a full direct connection in its
    /// place — CQ·164's own incident log shows it immediately following
    /// `muxRefusalToken` in the same stderr, and it is the one piece of
    /// stderr that marks the exact moment a caller must stop waiting on
    /// this attempt: everything after it is the slow fallback connection,
    /// not the mux refusal that caused it.
    private static let multiplexingFallbackToken = "disabling multiplexing"

    static func classify(_ text: String) -> SSHStderrClassification {
        text.contains(muxRefusalToken) || text.contains(multiplexingFallbackToken)
            ? .transientMuxRefusal : .other
    }
}
