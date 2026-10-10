import XCTest
@testable import Deck

final class ProcessCwdTests: XCTestCase {
    /// The simplest possible check: this test process's own pid must report
    /// the same directory `FileManager` already knows it is running in.
    func testOwnPidMatchesFileManagersCurrentDirectory() {
        let cwd = ProcessCwd.currentDirectory(ofProcess: getpid())
        XCTAssertEqual(cwd, FileManager.default.currentDirectoryPath)
    }

    /// A spawned child that changes directory before the process under test
    /// is queried — the case this exists for: reading where a *live* process
    /// is sitting right now, not where it started.
    func testFollowsASpawnedChildsWorkingDirectory() throws {
        // `/private/tmp` rather than `/tmp` (a symlink to it) so the value the
        // kernel hands back can be compared byte-for-byte with no symlink
        // resolution ambiguity on either side.
        let targetDirectory = "/private/tmp"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Prints its own cwd, then blocks. The parent waits on that line
        // before ever calling the helper, so there is no race between "the
        // child exists" and "the child has actually chdir'd" — Process sets
        // the child's directory before exec, and reading the printed line
        // back proves that took effect.
        process.arguments = ["-c", "pwd; exec sleep 30"]
        process.currentDirectoryURL = URL(fileURLWithPath: targetDirectory)
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }

        var collected = Data()
        while !collected.contains(UInt8(ascii: "\n")) {
            collected.append(stdout.fileHandleForReading.availableData)
        }
        let printedCwd = String(data: collected, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(printedCwd, targetDirectory, "the child never confirmed its own cwd")

        XCTAssertEqual(ProcessCwd.currentDirectory(ofProcess: process.processIdentifier), targetDirectory)
    }

    /// A pid nothing is running under must come back nil, not a stale or
    /// garbage path from an uninitialized buffer.
    func testReturnsNilForAPidThatDoesNotExist() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let exitedPid = process.processIdentifier

        XCTAssertNil(ProcessCwd.currentDirectory(ofProcess: exitedPid))
    }

    /// pid 0 is not a process this call means to query — `proc_pidinfo`
    /// treats 0 as a sentinel on some request types, so it must be refused
    /// before the kernel call rather than trusted if it happens to return
    /// something.
    func testReturnsNilForPidZero() {
        XCTAssertNil(ProcessCwd.currentDirectory(ofProcess: 0))
    }

    /// A negative pid is nonsensical and must not be handed to the kernel call.
    func testReturnsNilForANegativePid() {
        XCTAssertNil(ProcessCwd.currentDirectory(ofProcess: -1))
    }
}
