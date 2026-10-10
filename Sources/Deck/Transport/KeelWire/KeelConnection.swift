import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Where one Keel HTTP exchange connects.
///
/// `.unixSocket` dials a unix-domain socket path directly — the shape a
/// caller colocated with the socket would use, and the one Deck's own tests
/// use to exercise `KeelHTTPExchange` live against `run-register-api`'s
/// socket with no ssh hop in the way. `.forwardedPort` dials a local TCP
/// port a `KeelForward` has already bound to a remote unix socket — the
/// production shape, since Deck normally runs on the laptop, remote from
/// wherever the Keel's socket actually lives.
///
/// `URLSession` HAS NO PUBLIC WAY TO DIAL A UNIX-DOMAIN SOCKET ON MACOS —
/// checked, not assumed: neither `URLSessionConfiguration` nor any other
/// public Foundation entry point exposes one. That rules out "`URLSession`
/// for the forwarded-port production path, something else for the
/// direct-socket path Deck's tests use live": doing that would mean the
/// exact HTTP framing and decoding this stack ships to production never
/// gets a live exercise at all, since the live-reachable path in this
/// sandbox is the direct socket, not a working ssh hop (see
/// `KeelForwardTests`' own header for why). A hand-rolled HTTP/1.1 exchange
/// that runs identically over an AF_UNIX fd and an AF_INET fd
/// (`KeelHTTPExchange`) is what lets the SAME code both paths call get a
/// real, live check today.
enum KeelConnection: Equatable {
    case unixSocket(path: String)
    case forwardedPort(UInt16)
}

enum KeelSocketError: Error, Equatable, CustomStringConvertible {
    case couldNotCreateSocket(String)
    case couldNotConnect(String)
    case timedOut(String)
    case pathTooLong(String)

    var description: String {
        switch self {
        case .couldNotCreateSocket(let message),
             .couldNotConnect(let message),
             .timedOut(let message),
             .pathTooLong(let message):
            return message
        }
    }
}

/// Dials a `KeelConnection` and hands back a connected, blocking file
/// descriptor — blocking, because only the `connect()` step itself needs
/// the non-blocking-plus-`poll()` treatment below; `KeelHTTPExchange` bounds
/// its own reads and writes with `SO_RCVTIMEO`/`SO_SNDTIMEO` on the fd this
/// returns rather than depending on the socket's mode.
enum KeelSocket {
    static func connect(_ connection: KeelConnection, timeout: TimeInterval) throws -> Int32 {
        switch connection {
        case .unixSocket(let path):
            return try connectUnix(path: path, timeout: timeout)
        case .forwardedPort(let port):
            return try connectTCP(port: port, timeout: timeout)
        }
    }

    private static func connectUnix(path: String, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw KeelSocketError.couldNotCreateSocket("socket(AF_UNIX) failed: \(errnoText())")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(fd)
            throw KeelSocketError.pathTooLong("unix socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let buffer = raw.bindMemory(to: Int8.self)
            for (index, byte) in pathBytes.enumerated() { buffer[index] = Int8(bitPattern: byte) }
            buffer[pathBytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return try finishConnecting(fd: fd, timeout: timeout) { rawFd in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(rawFd, sa, size)
                }
            }
        }
    }

    private static func connectTCP(port: UInt16, timeout: TimeInterval) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw KeelSocketError.couldNotCreateSocket("socket(AF_INET) failed: \(errnoText())")
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        return try finishConnecting(fd: fd, timeout: timeout) { rawFd in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(rawFd, sa, size)
                }
            }
        }
    }

    /// The one thing shared between the AF_UNIX and AF_INET paths, and the
    /// whole reason this file exists rather than a bare blocking
    /// `connect()`: a socket with nothing listening on the far end — an
    /// absent forward, a forward that died, a Individuator that is down —
    /// must fail as a transport error rather than hang the caller, which is
    /// exactly the failure `platform/contracts/deck-keel-wire` names as this
    /// build's most common one.
    ///
    /// NON-BLOCKING CONNECT PLUS `poll()`, NOT A WATCHDOG THREAD.
    /// `SSHProcessRunner` bounds a `Process` with a background-thread
    /// watchdog because `Process` offers no other hook to bound it with; a
    /// raw socket's own `O_NONBLOCK` plus `poll()` is the POSIX-native way
    /// to bound `connect()` and needs no extra thread. The fd is returned in
    /// its original (blocking) mode — `O_NONBLOCK` is cleared again before
    /// this returns — so a caller doing ordinary blocking reads/writes
    /// afterward gets what it expects.
    private static func finishConnecting(
        fd: Int32, timeout: TimeInterval, connectCall: (Int32) -> Int32
    ) throws -> Int32 {
        let originalFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        let result = connectCall(fd)
        if result == 0 {
            _ = fcntl(fd, F_SETFL, originalFlags)
            return fd
        }
        guard errno == EINPROGRESS else {
            let message = errnoText()
            Darwin.close(fd)
            throw KeelSocketError.couldNotConnect("connect() failed: \(message)")
        }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let millis = Int32(max(0, timeout) * 1000)
        let pollResult = poll(&pfd, 1, millis)
        guard pollResult > 0 else {
            Darwin.close(fd)
            throw KeelSocketError.timedOut("connect() did not complete within \(timeout)s")
        }
        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
        guard soError == 0 else {
            Darwin.close(fd)
            throw KeelSocketError.couldNotConnect("connect() failed: \(String(cString: strerror(soError)))")
        }
        _ = fcntl(fd, F_SETFL, originalFlags)
        return fd
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
