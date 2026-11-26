import Foundation

/// Deck's report to the Bosun after GitHub answers that a pull request
/// merged — `agent-platform/lib/agent-platform/bosun_merge_reconcile.py`'s
/// `POST /merge-reports` (E5·2), reached over the Individuator's forwarding
/// socket exactly as `/sessions`/`/authorize` are, never over the server or
/// with any credential of Deck's own:
///
/// > The report carries no credential and nothing in it is trusted: it
/// > names a repository, a pull request number and a merge commit, and
/// > this module's whole job is to confirm that claim against GitHub
/// > itself before acting on it.
///
/// Deck's own half carries no credential either — the Individuator's own
/// machine certificate is what the Bosun's mTLS listener sees, never
/// anything Deck read from `gh` or the Keychain, and nothing in this file
/// touches either.
enum MergeReportOutcome: Equatable {
    /// `ok: true`, reason `reconciled` or `already_fixed` — both read as
    /// "the work item is closed" from Deck's side: `process_merge_report`'s
    /// own doc calls both "done" states.
    case closed
    /// `ok: false`, reason `held` — another holder's lease is in the way;
    /// `bosun_merge_reconcile`'s own retry sweep is what clears this later,
    /// never a retry from Deck.
    case waitingOnLeaseHolder
    /// Any other answer, including a transport failure that never reached
    /// the Bosun at all. The merge itself already happened on GitHub either
    /// way — this outcome is about the REPORT, not the merge.
    case reportFailed(reason: String)
}

enum MergeReportClient {
    /// The Individuator's forwarding socket, where the Bosun's
    /// `/merge-reports` route is reached — observed from
    /// `agent-platform/lib/agent-platform/forwarding_transport.py`'s own
    /// `DEFAULT_SOCKET_PATH`, which names the same `individuator-daemon`
    /// directory `install-individuator` creates for the daemon's sockets.
    /// Deck has no access to `IndividuatorPaths` itself (a Swift type in
    /// agent-platform's own `individuator/` package, outside this repo), so
    /// this is Deck's own mirror of that one path, not a shared constant.
    static let forwardingSocketPath = "/var/db/individuator-daemon/forward.sock"

    /// Builds the report body `bosun_merge_reconcile.validate_report`
    /// expects: `repo`, `pr` as a NUMBER STRING, and `merge_commit_sha` —
    /// exactly the three keys it requires and no others.
    static func reportBody(repo: String, number: Int, mergeCommitSha: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "repo": repo, "pr": String(number), "merge_commit_sha": mergeCommitSha,
        ])
    }

    /// Sends one report and parses the Bosun's answer into a
    /// `MergeReportOutcome` — never throws; a transport failure or a body
    /// this cannot parse both become `.reportFailed`, since the merge
    /// already happened on GitHub and a report Deck cannot complete must
    /// never read as though it did.
    ///
    /// `transport` is the one seam: given the request body, returns an HTTP
    /// status and response body, or throws. The production default opens a
    /// `KeelForward` to `target`'s own forwarding socket, dials it with
    /// `KeelConnection.forwardedPort`, and sends the request with
    /// `KeelHTTPExchange` — the same pieces `KeelClient` is built from,
    /// reused directly rather than through `KeelClient`'s own envelope
    /// decoding, since `/merge-reports` answers a plain JSON object, not a
    /// `KeelEnvelope`.
    static func send(
        repo: String, number: Int, mergeCommitSha: String,
        transport: (Data) throws -> (status: Int, body: Data)
    ) -> MergeReportOutcome {
        do {
            let body = try reportBody(repo: repo, number: number, mergeCommitSha: mergeCommitSha)
            let (_, responseBody) = try transport(body)
            return outcome(from: responseBody)
        } catch {
            return .reportFailed(reason: "\(error)")
        }
    }

    /// The production transport: one forward, one connection, one request —
    /// `KeelHTTPExchange`'s own "one request per connection" rule, closed
    /// (and the forward stopped) before this returns either way.
    static func liveTransport(
        target: SSHTarget, remoteSocketPath: String = forwardingSocketPath, timeout: TimeInterval = 20
    ) -> (Data) throws -> (status: Int, body: Data) {
        { body in
            let forward = try KeelForward.start(target: target, remoteSocketPath: remoteSocketPath)
            defer { forward.stop() }
            let fd = try KeelSocket.connect(.forwardedPort(forward.localPort), timeout: timeout)
            let response = try KeelHTTPExchange.exchange(
                fd: fd, method: "POST", host: "localhost", path: "/merge-reports",
                headers: ["Content-Type": "application/json"], body: body, timeout: timeout)
            return (response.status, response.body)
        }
    }

    /// `_do_merge_report`'s own response shape: `{"ok": bool, "reason":
    /// str, ...}` — read for `ok`/`reason` alone; every other field
    /// (`item_id`, `lease`, the mismatch detail) is for a log, not for this
    /// three-way draw.
    static func outcome(from body: Data) -> MergeReportOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let ok = json["ok"] as? Bool
        else {
            return .reportFailed(reason: "the Bosun's response did not carry a usable ok/reason")
        }
        let reason = json["reason"] as? String ?? "(no reason given)"
        if ok {
            return .closed
        }
        if reason == "held" {
            return .waitingOnLeaseHolder
        }
        return .reportFailed(reason: reason)
    }
}
