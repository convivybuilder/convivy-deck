import Darwin
import Foundation

/// Reads a process's current working directory straight from the kernel.
///
/// This exists because Deck has no other reliable way to learn where a local
/// shell is sitting. OSC 7 (SwiftTerm's `hostCurrentDirectoryUpdate`) only
/// fires from `/etc/zshrc_Apple_Terminal`, gated on `TERM_PROGRAM=Apple_Terminal`
/// — most users' dotfiles never emit it, so it is not a general answer.
/// `proc_pidinfo(PROC_PIDVNODEPATHINFO)` works for any process this user owns,
/// tracks a live `cd` with no cooperation from the shell, and needs nothing
/// from SwiftTerm beyond the pid it already exposes publicly as
/// `LocalProcessTerminalView.process.shellPid`.
///
/// Local only: this reads a process on this machine. A remote target's pid
/// (an `ssh` process) has no bearing on any directory the user thinks of as
/// "where the shell is" — its cwd is wherever Deck itself launched from.
enum ProcessCwd {
    static func currentDirectory(ofProcess pid: pid_t) -> String? {
        // pid 0 is not a real process to query — `proc_pidinfo` accepts it as
        // a sentinel for "the calling task" on some calls, which is not what
        // a caller here means by pid 0, so refuse it before the kernel call
        // rather than trust whatever comes back.
        guard pid > 0 else { return nil }

        var info = proc_vnodepathinfo()
        let expectedSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let bytesWritten = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, pointer, expectedSize)
        }

        // `proc_pidinfo` returns the byte count it actually wrote, or a
        // non-positive value on failure (pid gone, permission denied, no such
        // info type). Anything short of the full struct means the buffer was
        // never fully populated, so trusting `pvi_cdir` past this point would
        // be reading uninitialized memory as a path.
        guard bytesWritten == expectedSize else { return nil }

        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }
}
