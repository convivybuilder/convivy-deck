import AppKit
import SwiftTerm
import SwiftUI

/// A terminal that runs one ssh command once and reports how it ended
/// (CQ·160). `TerminalPaneView` reconnects to a tmux session on every exit,
/// which is right for a crew and wrong for an installer: an install that
/// stops must stay stopped, with its output on screen.
struct InstallerTerminalView: NSViewRepresentable {
    let arguments: [String]
    let theme: TerminalTheme
    let appearance: Appearance
    let typography: TerminalTypography
    /// Called once, on the main actor, with ssh's exit status: the remote
    /// command's own, or 255 for ssh's transport failure. nil when the
    /// process ended without one.
    let onExit: (Int32?) -> Void
    /// The port Deck forwarded for Builder's GitHub App page (CQ·202), or
    /// nil when this pane forwards none. Only an Open line naming exactly
    /// this port is ever opened.
    var githubAppPort: UInt16? = nil
    /// Called at most once per pane, on the main actor, with the exact URL
    /// `create-github-app` printed. Defaults to the real browser; tests
    /// inject a recorder instead.
    var openBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }

    func makeCoordinator() -> Coordinator {
        Coordinator(onExit: onExit, githubAppPort: githubAppPort, openBrowser: openBrowser)
    }

    func makeNSView(context: Context) -> BuilderSetupTerminalView {
        let view = BuilderSetupTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        view.onBytesReceived = { [weak coordinator = context.coordinator] slice in
            coordinator?.dataReceived(slice)
        }
        theme.palette(for: appearance).apply(to: view)
        view.font = typography.resolvedFont
        view.lineSpacing = typography.clampedLineSpacing
        view.startProcess(executable: "/usr/bin/ssh", args: arguments, execName: "ssh")
        return view
    }

    func updateNSView(_ nsView: BuilderSetupTerminalView, context: Context) {
        theme.palette(for: appearance).apply(to: nsView)
    }

    /// Closing the sheet mid-install ends the ssh process rather than
    /// leaving it running with nobody watching.
    static func dismantleNSView(_ nsView: BuilderSetupTerminalView, coordinator: Coordinator) {
        coordinator.finished = true
        if nsView.process.running { nsView.terminate() }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
        private let onExit: (Int32?) -> Void
        private let expectedPort: UInt16?
        private let openBrowser: (URL) -> Void
        var finished = false

        /// Bytes received since this pane started, capped so a chatty or
        /// binary stream cannot grow this unbounded — the printed line is
        /// one short sentence, so a few KB is generous even split across
        /// many reads with ANSI escapes in between.
        private var recentOutput: [UInt8] = []
        private let recentOutputCap = 8192
        private var opened = false

        init(onExit: @escaping (Int32?) -> Void, githubAppPort: UInt16?, openBrowser: @escaping (URL) -> Void) {
            self.onExit = onExit
            self.expectedPort = githubAppPort
            self.openBrowser = openBrowser
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard !finished else { return }
            finished = true
            onExit(exitCode)
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        /// Watches for `create-github-app`'s one printed line and opens it
        /// in the browser, at most once per pane, and only when a port was
        /// actually forwarded for it. Exposed directly (rather than only
        /// through `BuilderSetupTerminalView`) so a test can feed bytes
        /// without standing up a real `LocalProcessTerminalView`.
        func dataReceived(_ slice: ArraySlice<UInt8>) {
            guard let expectedPort, !opened else { return }
            recentOutput.append(contentsOf: slice)
            if recentOutput.count > recentOutputCap {
                recentOutput.removeFirst(recentOutput.count - recentOutputCap)
            }
            guard let url = BuilderGitHubAppOpenLine.find(
                in: String(decoding: recentOutput, as: UTF8.self), expectedPort: expectedPort)
            else { return }
            opened = true
            openBrowser(url)
        }
    }
}

/// Feeds every byte SwiftTerm receives to `onBytesReceived`, the only hook
/// onto a child process's output (`dataReceived` is `open` on
/// `LocalProcessTerminalView` for exactly this — see
/// `SSHStderrWatchingTerminalView`'s doc for the same mechanism used for a
/// different watch). Adds no ssh connection of its own; this is the setup
/// pane's existing one.
final class BuilderSetupTerminalView: LocalProcessTerminalView {
    var onBytesReceived: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onBytesReceived?(slice)
        super.dataReceived(slice: slice)
    }
}
