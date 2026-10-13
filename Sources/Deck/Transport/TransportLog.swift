import Foundation

/// Appends one line per ssh transport event to `transport.log`, rotated at
/// about 1 MB with one previous file kept — issue_01M4RZFFK250HBM735QSMP1GR0.
/// Deck had no record at all of a transport failure before this: stdin,
/// stdout and stderr on the app bundle's own process are all `/dev/null`, so
/// a connection failure could only be reconstructed after the fact from
/// unrelated processes' start times.
///
/// EVERY LINE IS DIAGNOSTIC METADATA, NEVER CONTENT. A caller passes an
/// event kind, a host label, an exit status, a duration, or ssh's own
/// stderr — never a command, a message a person typed, or a credential.
/// There is no method on this type that takes free text wide enough to
/// carry one by accident; each call site below builds its event string from
/// named, narrow fields.
///
/// INJECTABLE SO A TEST NEVER TOUCHES THE REAL APPLICATION SUPPORT
/// DIRECTORY: every call site below takes a `TransportLog` with `.shared`
/// as its default, and a test constructs its own against a temp directory.
///
/// A WRITE NEVER BLOCKS THE TRANSPORT PATH ON ANYTHING BUT A LOCAL FILE
/// WRITE, AND NEVER THROWS OR CRASHES IT. Every filesystem call here is
/// `try?`; a directory that cannot be created or a file that cannot be
/// opened just means this one line is lost, never that the ssh call that
/// triggered it fails or waits on this.
/// `@unchecked Sendable`: `lock` is the actual synchronization, held across
/// every read and write below, the same discipline `SSHProcessRunner`'s own
/// `StderrWatch` follows for the same reason — callers reach `.shared` from
/// several threads/tasks at once.
final class TransportLog: @unchecked Sendable {
    static let shared = TransportLog()

    /// ~1 MB. Approximate on purpose: rotation checks the file's size
    /// before the line that would cross the cap is appended, so the kept
    /// file is never more than one line past it, and never exactly it.
    static let rotationSizeBytes = 1_000_000

    static let defaultDirectory: URL = {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Deck", isDirectory: true)
    }()

    private let fileURL: URL
    private let previousFileURL: URL
    private let maxBytes: Int
    /// Serializes every read-size/rotate/write sequence below. Transport
    /// events arrive from several threads at once — `SessionAgent.run`'s
    /// background queue, `SessionPaneModel`'s detached liveness checks, a
    /// render's own ssh call — and two writers racing past the size check
    /// without this could both decide to rotate, or neither could, at the
    /// same instant.
    private let lock = NSLock()

    init(directory: URL = TransportLog.defaultDirectory, maxBytes: Int = TransportLog.rotationSizeBytes) {
        self.fileURL = directory.appendingPathComponent("transport.log")
        self.previousFileURL = directory.appendingPathComponent("transport.log.1")
        self.maxBytes = maxBytes
    }

    /// `user@host` — the one label every call site already has in hand,
    /// either as an `SSHTarget` or as the destination token already sitting
    /// in an argv array it built. Not `HostDisplay.label`, which resolves a
    /// probed hostname and a config name for a person to read on the rail;
    /// this label only needs to tell two hosts' lines apart in a log file,
    /// and resolving the richer one would mean a transport call that is
    /// already failing also pays for a probe.
    static func hostLabel(target: SSHTarget) -> String {
        "\(target.user)@\(target.host)"
    }

    /// The same label, pulled back out of an argv array that never carried
    /// an `SSHTarget` to begin with — `SessionAgent.run` sees only the argv
    /// its callers already built. Every destination token this codebase
    /// builds is `"\(user)@\(host)"` with no `@` anywhere else in the
    /// array (`ControlPath`'s `%C` token, flag names and values alike all
    /// exclude it), so the first element containing one is that token.
    static func hostLabel(fromArgv argv: [String]) -> String {
        argv.first(where: { $0.contains("@") }) ?? "unknown"
    }

    /// Wraps `text` in quotes with every embedded quote, backslash and
    /// newline escaped, so ssh's own multi-line stderr still lands as one
    /// log line — "one line per transport event" is the whole point of
    /// the format `append` pins.
    static func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    /// Appends one line: a UTC timestamp, `host`, and `event`, space
    /// separated. Rotates first when the pending write would cross
    /// `maxBytes`.
    func append(host: String, event: String) {
        guard let data = "\(TransportLog.timestamp()) \(host) \(event)\n".data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded(beforeAppending: data.count)
        appendLocked(data)
    }

    private func rotateIfNeeded(beforeAppending additionalBytes: Int) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let currentSize = attributes?[.size] as? Int,
              currentSize + additionalBytes > maxBytes
        else { return }
        try? FileManager.default.removeItem(at: previousFileURL)
        try? FileManager.default.moveItem(at: fileURL, to: previousFileURL)
    }

    private func appendLocked(_ data: Data) {
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            try? data.write(to: fileURL)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// `yyyy-MM-ddTHH:mm:ssZ`, UTC. A plain `DateFormatter` rather than
    /// `ISO8601DateFormatter`'s shared-instance caveats — built fresh per
    /// call, under `append`'s own lock, which is the only place this runs.
    private static func timestamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
