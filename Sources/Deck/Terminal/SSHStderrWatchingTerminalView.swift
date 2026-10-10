import AppKit
import SwiftTerm

/// Watches the raw bytes SwiftTerm feeds to the terminal for OpenSSH's
/// multiplexing-client refusal (`SSHStderrClassifier`) — the only hook
/// available onto a child process's stderr, since `ssh` interleaves it with
/// stdout on the shared PTY and `LocalProcess` never separates the two.
/// `dataReceived` is `open` on `LocalProcessTerminalView` for exactly this
/// kind of extension.
final class SSHStderrWatchingTerminalView: LocalProcessTerminalView {
    /// Bytes received since `beginWatchingNewAttempt()`, capped so a chatty
    /// or binary stream — a full-screen tmux redraw, say — cannot grow this
    /// unbounded. The refusal ssh prints is one short line, so a few KB is
    /// generous.
    private var recentOutput: [UInt8] = []
    private let recentOutputCap = 4096

    /// Called at the start of every connect attempt, so a stale
    /// classification from a previous attempt can never leak into this one's.
    func beginWatchingNewAttempt() {
        recentOutput.removeAll(keepingCapacity: true)
    }

    /// What the bytes received since the last `beginWatchingNewAttempt()`
    /// classify as.
    func classification() -> SSHStderrClassification {
        SSHStderrClassifier.classify(String(decoding: recentOutput, as: UTF8.self))
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        recentOutput.append(contentsOf: slice)
        if recentOutput.count > recentOutputCap {
            recentOutput.removeFirst(recentOutput.count - recentOutputCap)
        }
        super.dataReceived(slice: slice)
    }
}
