import Darwin
import Foundation

/// Reads a held save's draft through one file descriptor. The bytes that are
/// hashed and signed are the bytes of the file whose location and identity were
/// checked, so a path swapped after the check cannot change what is signed.
enum HeldDraftFile {
    /// Why a draft was not read. Each case keeps its reason on the held save.
    enum Failure: Error, Equatable {
        /// The draft's containing directory resolves outside the working copy.
        case outsideWorkingCopy
        /// The leaf is a symbolic link, a directory or another non-regular file.
        case notRegularFile
        /// The file has another hard link, so it may be shared with a file elsewhere.
        case linkedFromAnotherPath
        /// The file could not be opened, read or decoded as UTF-8.
        case unreadable(String)
    }

    /// Returns the draft's text. The containing directory is opened first and
    /// its real path must sit inside `workingCopy`. The leaf is then opened with
    /// `O_NOFOLLOW` relative to that directory, and the descriptor must be a
    /// regular file with one hard link whose device and inode match the leaf
    /// as it was just before the open.
    static func readDraft(at draftPath: String, inside workingCopy: URL) throws -> String {
        let url = URL(fileURLWithPath: draftPath)
        let leaf = url.lastPathComponent
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path

        let directory = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unreadable(String(cString: strerror(errno))) }
        defer { close(directory) }

        guard let root = realPath(ofDirectory: workingCopy.path) else {
            throw Failure.unreadable("the working copy could not be opened")
        }
        guard let real = realPath(of: directory), isInside(real, root) else {
            throw Failure.outsideWorkingCopy
        }

        var before = stat()
        guard fstatat(directory, leaf, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Failure.unreadable(String(cString: strerror(errno)))
        }
        guard before.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile }

        // O_NONBLOCK: a FIFO swapped into the leaf after the fstatat check above
        // would otherwise block this open until a writer appears. The fstat below
        // still refuses a FIFO once the open returns; this flag only keeps that
        // refusal from hanging. It has no effect on reads of a regular file.
        let file = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            // A symlink that replaced the leaf after the check fails with ELOOP.
            if errno == ELOOP { throw Failure.notRegularFile }
            throw Failure.unreadable(String(cString: strerror(errno)))
        }
        defer { close(file) }

        var opened = stat()
        guard fstat(file, &opened) == 0 else {
            throw Failure.unreadable(String(cString: strerror(errno)))
        }
        guard opened.st_mode & S_IFMT == S_IFREG,
              opened.st_dev == before.st_dev, opened.st_ino == before.st_ino else {
            throw Failure.notRegularFile
        }
        guard opened.st_nlink == 1 else { throw Failure.linkedFromAnotherPath }

        let data = try readAll(file)
        guard let content = String(data: data, encoding: .utf8) else {
            throw Failure.unreadable("the file is not valid UTF-8")
        }
        return content
    }

    /// The reason a refused send keeps on the list.
    static func reason(for failure: Failure, documentId: String, draftPath: String) -> String {
        switch failure {
        case .outsideWorkingCopy:
            return "the saved draft is outside the working copy for \(documentId), so nothing was sent."
        case .notRegularFile:
            return "the saved draft at \(draftPath) is not a regular file, so nothing was sent."
        case .linkedFromAnotherPath:
            return "the saved draft at \(draftPath) has another hard link, so nothing was sent."
        case .unreadable(let why):
            return "the local draft at \(draftPath) could not be read: \(why)"
        }
    }

    /// The real path of an open directory, as the kernel resolves it.
    private static func realPath(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let status = buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        guard status == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Whether `path` is `directory` or sits under it. Both are real paths from `F_GETPATH`,
    /// so `/private/var` and `/var` agree.
    private static func isInside(_ path: String, _ directory: String) -> Bool {
        path == directory || path.hasPrefix(directory + "/")
    }

    /// The real path of the directory at `path`, opened and then read the same way.
    private static func realPath(ofDirectory path: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        return realPath(of: descriptor)
    }

    private static func readAll(_ file: Int32) throws -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.unreadable(String(cString: strerror(errno)))
            }
            data.append(chunk, count: count)
        }
    }
}
