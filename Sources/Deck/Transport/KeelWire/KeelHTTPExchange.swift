import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A minimal HTTP/1.1 client that speaks over an already-connected POSIX
/// socket file descriptor — see `KeelConnection`'s doc for why this exists
/// instead of `URLSession`.
///
/// ONE REQUEST PER CONNECTION, matching the wire contract's own transport
/// line ("one request per operation"): every request this file sends
/// carries `Connection: close`, `exchange` always closes `fd` before
/// returning, and nothing here pools or reuses a connection. A caller
/// wanting a second call dials again.
enum KeelHTTPExchange {
    struct Response: Equatable {
        let status: Int
        let body: Data
    }

    /// Sends one request over `fd` and reads back the response, or throws
    /// `KeelSocketError` — never lets a read or a write block past
    /// `timeout`. Returns the raw status and body; nothing here decides
    /// whether the body is a usable Keel envelope. `KeelClient` is what
    /// turns a thrown `KeelSocketError` into `KeelError.transport` — this
    /// type stays agnostic of that vocabulary so its own tests can assert
    /// on the raw failure.
    static func exchange(
        fd: Int32, method: String, host: String, path: String,
        headers: [String: String], body: Data?, timeout: TimeInterval
    ) throws -> Response {
        defer { Darwin.close(fd) }
        try setTimeout(fd: fd, option: SO_SNDTIMEO, seconds: timeout)
        try setTimeout(fd: fd, option: SO_RCVTIMEO, seconds: timeout)
        try writeAll(fd: fd, data: requestBytes(
            method: method, host: host, path: path, headers: headers, body: body))
        let raw = try readAllUntilClosed(fd: fd)
        return try parse(raw)
    }

    /// Builds the raw request bytes — split out from `exchange` so the
    /// request SHAPE (header order, `Connection: close`, `Content-Length`
    /// only when there is a body) is directly testable without a socket.
    ///
    /// HEADERS ARE EMITTED IN SORTED KEY ORDER, deliberately: `headers` is a
    /// `[String: String]`, whose iteration order Swift does not guarantee,
    /// and a test asserting on the exact request bytes needs a
    /// deterministic order to assert against.
    static func requestBytes(
        method: String, host: String, path: String, headers: [String: String], body: Data?
    ) -> Data {
        var allHeaders = headers
        allHeaders["Host"] = host
        allHeaders["Connection"] = "close"
        if let body { allHeaders["Content-Length"] = String(body.count) }
        var text = "\(method) \(path) HTTP/1.1\r\n"
        for key in allHeaders.keys.sorted() {
            text += "\(key): \(allHeaders[key]!)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        if let body { data.append(body) }
        return data
    }

    private static func setTimeout(fd: Int32, option: Int32, seconds: TimeInterval) throws {
        let bounded = max(0, seconds)
        var tv = timeval(
            tv_sec: Int(bounded),
            tv_usec: Int32((bounded - Double(Int(bounded))) * 1_000_000))
        let result = setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard result == 0 else {
            throw KeelSocketError.couldNotConnect("setsockopt failed: \(String(cString: strerror(errno)))")
        }
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                guard n > 0 else {
                    throw KeelSocketError.couldNotConnect(
                        "write() failed or timed out: \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
    }

    /// Reads until the peer closes the connection. Safe because every
    /// request this file sends carries `Connection: close` — measured
    /// against the live `run-register-api` socket, which answers HTTP/1.0 and
    /// closes unconditionally regardless. `parse` still honours
    /// `Content-Length` when the response declares one rather than
    /// depending solely on this, so a future keep-alive-capable server does
    /// not silently hand back a body truncated before its declared length.
    ///
    /// NOT `private` — `KeelHTTPExchangeTests` calls this directly to
    /// exercise the errno mapping below against a real (if synthetic) fd,
    /// the same reason `requestBytes`/`parse` are non-private in this file.
    ///
    /// `EAGAIN`/`EWOULDBLOCK` IS THE ONLY ERRNO A GENUINE READ TIMEOUT
    /// PRODUCES — that's what `SO_RCVTIMEO` (set on `fd` by `exchange` before
    /// this runs) turns an expired blocking read into. Every other negative
    /// `read()` — `ECONNRESET`, `EBADF`, and the rest — is a distinct failure
    /// this used to mislabel `.timedOut` regardless, with "... failed or
    /// timed out" baked into the message even when the errno was neither.
    /// `strerror(errno)` still carries the real cause into the message
    /// either way, mirroring `writeAll`'s own message shape above — but only
    /// the timeout errnos get the `.timedOut` case and the word "timed out".
    static func readAllUntilClosed(fd: Int32) throws -> Data {
        var all = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 {
                let code = errno
                let detail = String(cString: strerror(code))
                if code == EAGAIN || code == EWOULDBLOCK {
                    throw KeelSocketError.timedOut("read() timed out: \(detail)")
                }
                throw KeelSocketError.couldNotConnect("read() failed: \(detail)")
            }
            if n == 0 { break }
            all.append(contentsOf: buffer[0..<n])
        }
        return all
    }

    /// Splits raw response bytes into a status line and a body — PURE, so
    /// every shape (a `Content-Length` body, a body with no declared
    /// length, a header block with no terminator at all) is testable
    /// without a socket.
    static func parse(_ raw: Data) throws -> Response {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw KeelSocketError.couldNotConnect("no complete HTTP header block arrived")
        }
        let headerText = String(data: raw[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw KeelSocketError.couldNotConnect("empty HTTP response")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw KeelSocketError.couldNotConnect("could not parse an HTTP status line: \(statusLine)")
        }
        let bodyBytes = raw[headerEnd.upperBound...]
        let contentLength = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { $0.split(separator: ":").last }
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let body = contentLength.map { Data(bodyBytes.prefix($0)) } ?? Data(bodyBytes)
        return Response(status: status, body: body)
    }
}
