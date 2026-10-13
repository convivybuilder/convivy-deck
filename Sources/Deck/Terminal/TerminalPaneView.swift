// The terminal half of stage 2 (fork 1/2/3): a native SwiftTerm view spawning
// a child process — `ssh` attaching to a tmux session on the mini, or a local
// login shell. For the remote case tmux is the persistence plumbing, so this
// view is disposable and can die and reattach without losing anything the
// fleet-side session held. A local pane has no such backing and is gone when
// it closes, which is the honest behaviour for a scratch terminal.
import AppKit
import SwiftTerm
import SwiftUI

struct TerminalPaneView: NSViewRepresentable {
    let target: TerminalTarget
    let theme: TerminalTheme
    /// Passed in, never read from the environment here. The shell is the single
    /// appearance authority (CLAUDE.md): it resolves the appearance once and
    /// stamps it into every surface in the same frame, so a pane cannot decide
    /// for itself and drift out of step with the rail beside it.
    let appearance: Appearance
    let typography: TerminalTypography
    /// Resolves the directory a fresh local-shell process should launch in.
    /// Called once at connect time — including a clean-exit auto-restart —
    /// never polled and never cached past that call, so whatever it returns
    /// is only ever as stale as the moment the process is about to spawn.
    /// Ignored for any non-local target: an ssh target's directory is decided
    /// on the far side, not here.
    var localStartingDirectory: () -> String = { TerminalLaunch.localWorkingDirectory }
    /// Reports where the local shell was sitting, read from the kernel in the
    /// last moment before its process is killed. That timing is the whole
    /// design: once the child is gone its cwd is unreadable, so a pane that
    /// waited for `processTerminated` would have nothing left to ask.
    /// Ignored for any non-local target — an ssh target's pid is Deck's own
    /// `ssh` process, and its cwd is wherever Deck launched from rather than
    /// anywhere the user has been.
    var onLocalShellDirectory: (String) -> Void = { _ in }
    let onPhaseChange: (ConnectionStateMachine.Phase) -> Void
    /// Wired to the live view once it connects and detached on teardown —
    /// see `Coordinator.connect`/`tearDown`. nil for a pane the find bar (a
    /// separate feature) has not been given a controller for.
    var searchController: TerminalSearchController? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            target: target,
            localStartingDirectory: localStartingDirectory,
            onLocalShellDirectory: onLocalShellDirectory,
            onPhaseChange: onPhaseChange,
            searchController: searchController)
    }

    func makeNSView(context: Context) -> SSHStderrWatchingTerminalView {
        let view = SSHStderrWatchingTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        theme.palette(for: appearance).apply(to: view)
        applyTypography(to: view)
        context.coordinator.connect(view)
        return view
    }

    /// Re-applied on every update so a system appearance change repaints the
    /// live pane. The pane is not recreated for a theme change — only for a
    /// session change, via `.id(selection)` in ContentView — so without this
    /// a light-to-dark switch would leave the running terminal on the old
    /// palette until the next reconnect.
    func updateNSView(_ nsView: SSHStderrWatchingTerminalView, context: Context) {
        theme.palette(for: appearance).apply(to: nsView)
        applyTypography(to: nsView)
    }

    /// Order matters. Setting `font` rebuilds the FontSet and recomputes cell
    /// dimensions; setting `lineSpacing` also recomputes them. Applying the
    /// font first means the spacing pass sees the final metrics, so the grid
    /// is sized once against the values that will actually be drawn.
    private func applyTypography(to view: LocalProcessTerminalView) {
        let font = typography.resolvedFont
        if view.font != font { view.font = font }
        if view.lineSpacing != typography.clampedLineSpacing {
            view.lineSpacing = typography.clampedLineSpacing
        }
    }

    /// Called when SwiftUI drops this view — a session switch on the rail
    /// (via `.id(selection)` in ContentView) or the pane leaving the
    /// hierarchy entirely. `LocalProcess.deinit` closes its I/O descriptors
    /// but deliberately does not send SIGTERM to the child, so without this
    /// every session switch would leak an orphaned `ssh` process still
    /// holding a live PTY into the mini's tmux session.
    static func dismantleNSView(_ nsView: SSHStderrWatchingTerminalView, coordinator: Coordinator) {
        coordinator.tearDown(nsView)
    }

    /// Owns the reconnect state machine and the retry timer. SwiftTerm only
    /// tells us a process died (`processTerminated`), never that ssh finished
    /// its handshake, so "connected" is an assumption made shortly after
    /// launch and revoked if the process dies before that grace period ends.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
        private let target: TerminalTarget
        private let localStartingDirectory: () -> String
        private let onLocalShellDirectory: (String) -> Void
        private let onPhaseChange: (ConnectionStateMachine.Phase) -> Void
        private let searchController: TerminalSearchController?
        private let stateMachine = ConnectionStateMachine()
        /// Bounds how many consecutive OpenSSH multiplexing-client refusals
        /// (`SSHStderrClassifier`) this pane will erase and retry silently —
        /// see `processTerminated`. Unbounded absorption would make a
        /// genuinely wedged ControlMaster look like a hang instead of a
        /// reported failure.
        ///
        /// DORMANT SINCE CQ·165: a pane's own ssh process connects with
        /// `ControlPath=none`, so it never runs the mux client this classifies
        /// — `classification()` reads `.other` unconditionally, and this never
        /// absorbs. Left in place rather than torn out, since an idle policy
        /// costs nothing and `processTerminated` still needs a classification
        /// to decide whether to clear the screen before the reconnect veil.
        private var absorptionPolicy = MuxRefusalAbsorptionPolicy()
        private weak var view: SSHStderrWatchingTerminalView?
        private var retryWorkItem: DispatchWorkItem?
        private var connectedAssumptionWorkItem: DispatchWorkItem?
        private var isTornDown = false
        private var terminationObserver: (any NSObjectProtocol)?
        /// When the current child process was launched, used to tell a shell
        /// the user exited from one that died on startup.
        private var launchedAt: Date?

        /// A local shell that exits cleanly *this* fast did not have a user in
        /// it — a stray `exit` in a profile, say. Restarting such a shell
        /// immediately is an unbounded tight loop, so anything under this
        /// threshold takes the backoff path instead.
        private static let minimumHealthyLocalRun: TimeInterval = 1.0

        init(
            target: TerminalTarget,
            localStartingDirectory: @escaping () -> String,
            onLocalShellDirectory: @escaping (String) -> Void,
            onPhaseChange: @escaping (ConnectionStateMachine.Phase) -> Void,
            searchController: TerminalSearchController? = nil
        ) {
            self.target = target
            self.localStartingDirectory = localStartingDirectory
            self.onLocalShellDirectory = onLocalShellDirectory
            self.onPhaseChange = onPhaseChange
            self.searchController = searchController
            super.init()
            // Closing the split calls `dismantleNSView`; quitting the app does
            // not reliably, and SwiftUI makes no promise that it will. Without
            // this observer the remembered directory would survive a toggle but
            // silently reset to home across a relaunch, which is the case a
            // user is most likely to notice.
            if case .localShell = target {
                terminationObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.rememberLocalShellDirectory() }
                }
            }
        }


        func connect(_ view: SSHStderrWatchingTerminalView) {
            guard !isTornDown else { return }
            self.view = view
            // Rebound on every connect, including a reconnect after a
            // dropped ssh session — the NSView instance persists across
            // those (only the child process is replaced), so this is
            // idempotent, but it keeps the controller pointed at whichever
            // view is actually live rather than assuming makeNSView's first
            // call is the only one that matters.
            searchController?.view = view
            retryWorkItem?.cancel()
            connectedAssumptionWorkItem?.cancel()
            onPhaseChange(.connecting)
            // A stale classification from the attempt that just ended must
            // never be read as this new one's — see `processTerminated`.
            view.beginWatchingNewAttempt()

            let executable: String
            let args: [String]
            do {
                (executable, args) = try TerminalLaunch.executableAndArguments(for: target)
            } catch {
                scheduleRetry(after: stateMachine.connectionLost())
                return
            }

            // NO GATE WAIT HERE (CQ·165). A pane's ssh process opens its own
            // connection (`ControlPath=none` in `sshArguments`/
            // `BuilderServerInstall.arguments`) rather than riding the shared
            // ControlMaster `SSHConnectionGate` bounds, so it is no longer one
            // of the sessions sshd's `MaxSessions` caps on that socket, and has
            // nothing to queue for.
            startProcess(executable: executable, args: args, view: view)
        }

        /// Actually launches the pane's process.
        private func startProcess(executable: String, args: [String], view: SSHStderrWatchingTerminalView) {
            // `currentDirectory` matters only for the local shell — an ssh
            // target's directory is decided on the far side. Passing nil for
            // those leaves SwiftTerm's inherited behaviour untouched.
            //
            // Resolved fresh on every connect, including the restart after
            // a clean `exit`, rather than once and reused. Nothing here
            // polls or holds a snapshot: the directory is asked for at the
            // moment a process is about to spawn, and at no other time.
            view.startProcess(
                executable: executable, args: args,
                execName: (executable as NSString).lastPathComponent,
                currentDirectory: target == .localShell
                    ? localStartingDirectory() : nil)

            let assumeConnected = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.absorptionPolicy.succeeded()
                self.onPhaseChange(self.stateMachine.connectSucceeded())
            }
            launchedAt = Date()
            connectedAssumptionWorkItem = assumeConnected
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: assumeConnected)
        }

        /// A remote session and a local shell exit for different reasons, and
        /// treating them the same is wrong in a way the user feels immediately.
        ///
        /// ssh exits because the network dropped or the host slept — never
        /// because the user asked — so backoff and a "reconnecting" veil are
        /// right. A local shell exits because the user typed `exit`, and
        /// answering that with "Reconnecting (attempt 3) — retrying in 8s" is
        /// both wrong and slow: the delay compounds across repeated exits
        /// within one pane visit.
        ///
        /// So a clean local exit restarts at once, with no veil and no attempt
        /// counter. A *non-zero* local exit still backs off, because a shell
        /// that crashes on launch would otherwise spin as fast as the machine
        /// allows.
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard !isTornDown else { return }
            connectedAssumptionWorkItem?.cancel()

            // Nothing is remembered here, and that is a limit worth naming: by
            // the time this fires the child is already reaped, so its cwd is
            // unreadable. A shell the user `exit`s out of therefore restarts in
            // the last directory that WAS captured — at the previous teardown —
            // rather than wherever it had been `cd`'d to just now.
            //
            // The elapsed-time guard is what keeps the immediate restart from
            // becoming a busy loop: a profile containing `exit` would otherwise
            // spawn, exit 0, and respawn as fast as the machine allows.
            if case .localShell = target, exitCode == 0, ranLongEnoughToBeDeliberate() {
                guard let view else { return }
                connect(view)
                return
            }

            // The child's own stderr — the exact text of a failure like
            // OpenSSH's multiplexing-client refusal — is already painted
            // into the terminal by the time this fires: `dataReceived` runs
            // as the bytes arrive, before the process is reaped and this is
            // called. Absorbing that one narrow, retryable condition means
            // erasing it right here, before the reconnect veil goes up, so
            // the next attempt starts on a clean screen instead of dimly
            // showing the last attempt's error text underneath the veil.
            // Bounded by `absorptionPolicy` — a real failure, or a refusal
            // that keeps recurring, is left on screen and reported exactly
            // as it always was.
            let classification = view?.classification() ?? .other
            if absorptionPolicy.shouldAbsorb(classification: classification) {
                view?.terminal.resetToInitialState()
            }

            scheduleRetry(after: stateMachine.connectionLost())
        }

        /// Idempotent: SwiftUI's dismantle call and `terminate()`'s own
        /// `processTerminated` callback can both reach here.
        func tearDown(_ view: LocalProcessTerminalView) {
            guard !isTornDown else { return }
            isTornDown = true
            retryWorkItem?.cancel()
            connectedAssumptionWorkItem?.cancel()
            // BEFORE `terminate()`, which is the only ordering that works: the
            // cwd is a property of a living process, and one line later there
            // is nothing left to read it from.
            rememberLocalShellDirectory()
            // Explicit rather than left to the weak reference's deallocation
            // timing. This is the pane leaving Terminal View — a session
            // switch or "Back to Session View" both dismantle through here —
            // and a highlight left in a surface nobody is looking at is the
            // exact failure the epic names.
            searchController?.clear()
            searchController?.view = nil
            // Dropped here rather than in `deinit`, which cannot touch
            // MainActor state. Teardown is also the honest moment: the pane is
            // gone, so a quit arriving later has nothing left to capture.
            if let terminationObserver {
                NotificationCenter.default.removeObserver(terminationObserver)
                self.terminationObserver = nil
            }
            view.terminate()
        }

        /// Captures where the local shell is sitting, so the next one opens
        /// there instead of back in home.
        ///
        /// Silent when there is nothing to capture — a non-local target, no
        /// live child, or a kernel read that failed because the process exited
        /// on its own a moment ago. A miss costs the user a `cd`; reporting a
        /// directory that is not where they were would cost them more.
        private func rememberLocalShellDirectory() {
            guard case .localShell = target, let view, view.process.running else { return }
            guard let directory = ProcessCwd.currentDirectory(ofProcess: view.process.shellPid)
            else { return }
            onLocalShellDirectory(directory)
        }

        private func ranLongEnoughToBeDeliberate() -> Bool {
            guard let launchedAt else { return false }
            return Date().timeIntervalSince(launchedAt) >= Self.minimumHealthyLocalRun
        }

        private func scheduleRetry(after phase: ConnectionStateMachine.Phase) {
            onPhaseChange(phase)
            guard case .reconnecting(_, let delay) = phase else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self, let view = self.view else { return }
                self.connect(view)
            }
            retryWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
