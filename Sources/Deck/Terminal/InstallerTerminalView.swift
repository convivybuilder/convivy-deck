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

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        theme.palette(for: appearance).apply(to: view)
        view.font = typography.resolvedFont
        view.lineSpacing = typography.clampedLineSpacing
        view.startProcess(executable: "/usr/bin/ssh", args: arguments, execName: "ssh")
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        theme.palette(for: appearance).apply(to: nsView)
    }

    /// Closing the sheet mid-install ends the ssh process rather than
    /// leaving it running with nobody watching.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.finished = true
        if nsView.process.running { nsView.terminate() }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
        private let onExit: (Int32?) -> Void
        var finished = false

        init(onExit: @escaping (Int32?) -> Void) { self.onExit = onExit }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            guard !finished else { return }
            finished = true
            onExit(exitCode)
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
