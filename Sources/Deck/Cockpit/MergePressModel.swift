import Foundation

/// One row's own state through a merge or close press. `idle` is "nothing
/// pressed yet"; the two `confirming` states are the one-click confirmation
/// the item asks for ("a press is one human click on a confirmation that
/// names the pull request and its short head"); `working` is the in-flight
/// state a repeated press during it is dropped against (see
/// `MergePressModel.press`); the rest are where a press can land.
enum MergePressState: Equatable {
    case idle
    case confirmingMerge
    case confirmingClose
    case working
    /// Neither `gh` nor a pasted token produced a credential — refused
    /// before any GitHub call was made, the same "no call, no copy" posture
    /// a served-sessions refusal takes.
    case noCredential
    case refused(MergeRefusal)
    /// GitHub merged it; this is what the Keel's `/merge-reports` answered.
    case reported(MergeReportOutcome)
    /// GitHub closed it without merging.
    case closed
}

/// Drives one cockpit's worth of merge/close presses, one `MergePressState`
/// per pull request (keyed by `PRLadder.LadderResult.identityKey`) — the
/// business logic behind the row-level affordance
/// `issue_01M1HQMDZ8TG2KVK7JG6P7YK7T` builds, with every external effect an
/// injected, `@Sendable` seam so a test never shells out to `gh`, touches the
/// real Keychain, calls `api.github.com`, or opens a real ssh forward — the
/// same seam shape `PRLadderModel.fetchLadder` already uses for its own
/// off-main-actor call.
///
/// **ORDER IS THE WHOLE POINT OF `attempt(...)` BELOW.** 0003's "the check
/// runs before the read": the served-sessions check runs first, with no
/// credential read at all when it refuses; only once it answers clear is
/// `readCredential` called; only once a merge is reported as `.merged` is
/// `reportMerge` called, and it is never called on a refusal. No path here
/// retries a refused or working press — `press(key:...)` drops a second
/// press on a key already `working`, and nothing in this file loops or
/// re-presses on its own.
@MainActor
final class MergePressModel: ObservableObject {
    @Published private(set) var states: [String: MergePressState] = [:]

    /// Rows whose cockpit close the capture has since caught up with: once
    /// a captured row reads closed, or a newer capture lands, the captured
    /// position is the authority again, so a pull request reopened on
    /// GitHub draws open on its next capture instead of closed forever.
    /// Not `@Published`: `drawnPosition(for:)` records it while drawing.
    private var closeSuperseded: Set<String> = []

    /// The captured row's `updatedAt` when its close was pressed. A capture
    /// whose `updatedAt` differs is newer than the press.
    private var closePressedOver: [String: String?] = [:]

    /// The configured Hosts list the served-sessions check reads — set by
    /// whoever owns this model (`ContentView`'s own Settings › Hosts table),
    /// never derived here. Setting it refreshes `servedSessionsReason` for
    /// DISPLAY (see that property's own doc); it plays no part in what a
    /// press actually checks, which always reads `hosts` fresh.
    var hosts: [HostEntry] = [] {
        didSet { refreshServedSessionsReason() }
    }

    /// The served-sessions reason for DISPLAY, cached rather than
    /// recomputed on every render: the real check resolves each configured
    /// host and can block on DNS, so it runs off the main actor. `nil` until
    /// `hosts` is set at least once, which is exactly the state every
    /// EXISTING `CockpitView` render test leaves a default-constructed
    /// `MergePressModel()` in: those tests never touch `hosts`, so they
    /// never run the real check and never depend on what is actually on the
    /// machine running the test.
    @Published private(set) var servedSessionsReason: MergeRefusal.ServesSessionsReason?

    /// Whether a pasted token is in the store, which decides whether a
    /// served-sessions refusal offers to remove one (0003).
    @Published private(set) var pastedTokenStored = false

    /// The latest display refresh, so a test can await its result.
    private(set) var servedSessionsRefresh: Task<Void, Never>?

    private func refreshServedSessionsReason() {
        servedSessionsRefresh?.cancel()
        let hosts = self.hosts
        let evaluateServedSessions = self.evaluateServedSessions
        let tokenStore = self.tokenStore
        servedSessionsRefresh = Task { [weak self] in
            let (reason, stored) = await Task.detached {
                (evaluateServedSessions(hosts), tokenStore.exists())
            }.value
            guard !Task.isCancelled, let self else { return }
            self.servedSessionsReason = reason
            self.pastedTokenStored = stored
        }
    }

    var tokenStore: any MergeTokenStore = MergeTokenKeychain.shared

    var evaluateServedSessions: @Sendable ([HostEntry]) -> MergeRefusal.ServesSessionsReason? = { hosts in
        ServedSessionsCheck.evaluate(hosts: hosts)
    }
    var readCredential: @Sendable (String) -> MergeCredentialChoice? = {
        repo in MergeCredentialSource.resolve(repo: repo)
    }
    var performMerge:
        @Sendable (String, Int, String, MergeCredentialChoice) throws -> GitHubMergeClient.MergeAttemptOutcome = {
        repo, number, expectedHeadSha, credential in
        try GitHubMergeClient.merge(
            repo: repo, number: number, expectedHeadSha: expectedHeadSha, credential: credential)
    }
    var performClose: @Sendable (String, Int, MergeCredentialChoice) throws -> MergeRefusal? = {
        repo, number, credential in
        try GitHubMergeClient.close(repo: repo, number: number, credential: credential)
    }
    /// No usable default: a real caller always sets this to a
    /// `MergeReportClient.liveTransport`-backed closure once it knows which
    /// host's forwarding socket to reach. The placeholder below never runs
    /// in production — only a merge success reaches it, and every
    /// production call site sets this first.
    var reportMerge: @Sendable (String, Int, String) -> MergeReportOutcome = { _, _, _ in
        .reportFailed(reason: "no report transport configured")
    }
    /// Called when a press changes what the ladder should show: a moved head
    /// (0003: "Deck... draws the pull request again at its new head"), a
    /// merge, or a close. It is the caller's cue to refetch; this file never
    /// refetches anything itself. NOT `@Sendable`: `press(key:kind:)` calls
    /// this back on the main actor, after `await`ing the detached attempt,
    /// never from inside it.
    var onLadderChanged: (() -> Void)?

    /// Keys with an attempt currently running — what makes a second press
    /// on the same row, while the first is still in flight, a no-op rather
    /// than a second GitHub call.
    private var working: Set<String> = []

    func state(for row: PRLadder.LadderResult) -> MergePressState {
        states[row.identityKey] ?? .idle
    }

    /// The position a row draws (`issue_01M747MYS6TYG6ZHQ2WZ3R2RAN`). A
    /// merge GitHub confirmed draws merged from then on, since a merge
    /// cannot be undone. A close GitHub confirmed draws closed only until
    /// the capture catches up: a captured row reading closed, or any capture
    /// newer than the one the close was pressed over, hands the row back to
    /// the captured position, so a reopen draws open again.
    func drawnPosition(for row: PRLadder.LadderResult) -> PRLadder.Position {
        PRLadderRow.effectivePosition(row.position, pressState: displayState(for: row))
    }

    /// The press state the row's buttons draw from: `state(for:)`, except
    /// that a close the capture has caught up with reads `.idle`, so a
    /// reopened pull request offers its Merge and Close buttons again.
    func displayState(for row: PRLadder.LadderResult) -> MergePressState {
        let pressState = state(for: row)
        guard case .closed = pressState else { return pressState }
        let key = row.identityKey
        if case .closed = row.position {
            closeSuperseded.insert(key)
        } else if let pressedOver = closePressedOver[key], let current = row.updatedAt,
                  current != pressedOver {
            closeSuperseded.insert(key)
        }
        return closeSuperseded.contains(key) ? .idle : pressState
    }

    func beginMergeConfirmation(for row: PRLadder.LadderResult) {
        states[row.identityKey] = .confirmingMerge
    }

    func beginCloseConfirmation(for row: PRLadder.LadderResult) {
        states[row.identityKey] = .confirmingClose
    }

    func cancel(for row: PRLadder.LadderResult) {
        states[row.identityKey] = .idle
    }

    /// Saves a pasted token to the login Keychain only after the same
    /// served-sessions check a press runs (0003), then returns this row to
    /// `.idle`, so a fresh press (never a retry of the refused one) can
    /// pick it up through `readCredential`'s own fallback. On a refusal
    /// nothing is stored and the row draws the refusal.
    func savePastedToken(_ token: String, for row: PRLadder.LadderResult) async {
        let key = row.identityKey
        guard !working.contains(key) else { return }
        working.insert(key)
        states[key] = .working
        let evaluateServedSessions = self.evaluateServedSessions
        let hosts = self.hosts
        let tokenStore = self.tokenStore
        let (refusal, stored) = await Task.detached { () -> (MergeRefusal.ServesSessionsReason?, Bool) in
            if let reason = evaluateServedSessions(hosts) {
                return (reason, tokenStore.exists())
            }
            tokenStore.save(token)
            return (nil, tokenStore.exists())
        }.value
        working.remove(key)
        pastedTokenStored = stored
        states[key] = refusal.map { .refused(.servesSessions($0)) } ?? .idle
    }

    /// 0003's offer on a served-sessions refusal. `pastedTokenStored` is
    /// read back from the store, so a failed removal keeps the offer drawn.
    func removePastedToken() async {
        let tokenStore = self.tokenStore
        pastedTokenStored = await Task.detached {
            tokenStore.remove()
            return tokenStore.exists()
        }.value
    }

    /// The merge button's own confirmed press. `row.headSha` is the
    /// expected head sent to GitHub — a row with no known head (a draft, or
    /// a state-unknown row) offers nothing to confirm, so this is a no-op
    /// rather than a call made with a guessed head.
    func confirmMerge(for row: PRLadder.LadderResult) async {
        guard let headSha = row.headSha else { return }
        let repo = row.repo
        let number = row.number
        await press(key: row.identityKey, kind: .merge(expectedHeadSha: headSha, repo: repo, number: number))
    }

    func confirmClose(for row: PRLadder.LadderResult) async {
        closePressedOver[row.identityKey] = row.updatedAt
        await press(key: row.identityKey, kind: .close(repo: row.repo, number: row.number))
    }

    private enum PressKind {
        case merge(expectedHeadSha: String, repo: String, number: Int)
        case close(repo: String, number: Int)
    }

    /// Runs one attempt off the main actor and writes its result back —
    /// `AT MOST ONE PUT PER PRESS, AND NO RETRY`: a key already in
    /// `working` is dropped here, before anything is captured for the
    /// detached task, so a double-click or a second confirmation while the
    /// first is still running never reaches `performMerge`/`performClose` a
    /// second time.
    private func press(key: String, kind: PressKind) async {
        guard !working.contains(key) else { return }
        working.insert(key)
        states[key] = .working
        let evaluateServedSessions = self.evaluateServedSessions
        let hosts = self.hosts
        let readCredential = self.readCredential
        let performMerge = self.performMerge
        let performClose = self.performClose
        let reportMerge = self.reportMerge
        let result = await Task.detached {
            MergePressModel.attempt(
                kind: kind, hosts: hosts, evaluateServedSessions: evaluateServedSessions,
                readCredential: readCredential, performMerge: performMerge, performClose: performClose,
                reportMerge: reportMerge)
        }.value
        working.remove(key)
        closeSuperseded.remove(key)
        states[key] = result
        switch result {
        case .refused(.movedHead), .reported, .closed:
            onLadderChanged?()
        case .refused(.servesSessions):
            // The machine started serving sessions since the last display
            // refresh, so the row and its token offer need the new answer.
            refreshServedSessionsReason()
        default:
            break
        }
    }

    /// The whole attempt, off the main actor and touching no instance state
    /// — a free function in all but name, so nothing here can race
    /// `states`/`working` while it runs. See this type's own doc for the
    /// ordering this enforces.
    private nonisolated static func attempt(
        kind: PressKind,
        hosts: [HostEntry],
        evaluateServedSessions: @Sendable ([HostEntry]) -> MergeRefusal.ServesSessionsReason?,
        readCredential: @Sendable (String) -> MergeCredentialChoice?,
        performMerge: @Sendable (String, Int, String, MergeCredentialChoice) throws
            -> GitHubMergeClient.MergeAttemptOutcome,
        performClose: @Sendable (String, Int, MergeCredentialChoice) throws -> MergeRefusal?,
        reportMerge: @Sendable (String, Int, String) -> MergeReportOutcome
    ) -> MergePressState {
        if let reason = evaluateServedSessions(hosts) {
            return .refused(.servesSessions(reason))
        }
        let repo: String
        switch kind {
        case .merge(_, let r, _): repo = r
        case .close(let r, _): repo = r
        }
        guard let credential = readCredential(repo) else {
            return .noCredential
        }
        switch kind {
        case .merge(let expectedHeadSha, let repo, let number):
            let outcome: GitHubMergeClient.MergeAttemptOutcome
            do {
                outcome = try performMerge(repo, number, expectedHeadSha, credential)
            } catch {
                return .refused(.unrecognised(status: 0, message: "\(error)"))
            }
            switch outcome {
            case .refused(let refusal):
                return .refused(refusal)
            case .merged(let mergeCommitSha):
                return .reported(reportMerge(repo, number, mergeCommitSha))
            }
        case .close(let repo, let number):
            do {
                if let refusal = try performClose(repo, number, credential) {
                    return .refused(refusal)
                }
                return .closed
            } catch {
                return .refused(.unrecognised(status: 0, message: "\(error)"))
            }
        }
    }
}
