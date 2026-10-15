import Foundation
import Security

/// What a mutual-TLS Library request can fail with, distinct from
/// `LibraryClient.FetchError` because this file never decodes a response —
/// it hands back a status and a body for the SAME decoders every existing
/// path already has, and throws only for a failure those decoders never see
/// a shape for at all: the handshake or the trust check never got that far.
///
/// **NEVER CAUGHT AND RETRIED ON THE EXISTING PATH.** CQ·162's done
/// conditions are explicit that a handshake, trust or 401 failure surfaces
/// as itself — `LibraryTransportDispatch` has no `catch` around the
/// mutual-TLS branch that falls through to the ssh/curl branch, and no test
/// in this change may add one.
enum LibraryMutualTLSError: Error, Equatable, CustomStringConvertible {
    /// No client identity was offered when the Library's listener asked for
    /// one — reachable only if a caller reaches this type with no identity
    /// at all, since `LibraryTransportSelector` never chooses `.mutualTLS`
    /// without one.
    case noClientIdentity
    case handshakeFailed(String)
    case trustRefused(String)
    case transportFailed(String)
    case unexpectedResponse(String)
    /// 401 from the binding gate: the Bearer token is not bound to this
    /// machine. Binding it is an operator step on the Library's host.
    case credentialNotBound(String)
    /// 401 "no resolvable identity": the certificate chained, but it is not
    /// one active registered machine with clientAuth.
    case machineNotRegistered(String)
    /// A 401 whose body names neither reason above.
    case unauthorized(String)

    var description: String {
        switch self {
        case .noClientIdentity: return "no client identity was available for this host"
        case .handshakeFailed(let why): return "the TLS handshake failed: \(why)"
        case .trustRefused(let why): return "the Library's certificate was refused: \(why)"
        case .transportFailed(let why): return "the request could not be sent: \(why)"
        case .unexpectedResponse(let why): return "the response did not have a usable status: \(why)"
        case .credentialNotBound(let why):
            return "the Library refused the credential: it is not bound to this machine (\(why))"
        case .machineNotRegistered(let why):
            return "the Library refused this machine: its certificate is not an active registered machine (\(why))"
        case .unauthorized(let why): return "the Library refused the request (401): \(why)"
        }
    }
}

/// Answers both halves of a mutual-TLS handshake for one `URLSession`:
/// `NSURLAuthenticationMethodServerTrust` by anchoring to exactly the given
/// root(s) (`LibraryServerTrustEvaluator`, never the system's default trust
/// store), and `NSURLAuthenticationMethodClientCertificate` by presenting the
/// given identity. Holds no state of its own beyond what it was built with,
/// so one instance is good for exactly one host's forward.
/// `@unchecked Sendable`: `identity` and `anchors` are both `let`, set once
/// at init and never mutated, which is all `URLSession`'s own delegate
/// queue needs from this type.
final class LibraryMutualTLSSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let identity: SecIdentity
    private let anchors: [SecCertificate]

    init(identity: SecIdentity, anchors: [SecCertificate]) {
        self.identity = identity
        self.anchors = anchors
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            switch LibraryServerTrustEvaluator.evaluate(trust, anchors: anchors) {
            case .trusted:
                completionHandler(.useCredential, URLCredential(trust: trust))
            case .refused:
                // THE REASON IS NOT CARRIED PAST THIS POINT ON PURPOSE. A
                // `URLSession` challenge has nowhere to attach it; the
                // caller learns a handshake failed from the transport error
                // `URLSession`'s own completion handler reports a moment
                // later (`NSURLErrorServerCertificateUntrusted` or similar),
                // which `LibraryMutualTLSClient.classify(_:)` turns into
                // `.trustRefused`.
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            let credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
            completionHandler(.useCredential, credential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// One mutual-TLS Library request, synchronous like every other transport
/// call in this codebase (`SessionAgent.run`, `WorkingCopyStore.fetch`) so
/// `LibraryTransportDispatch` can sit beside them with no new concurrency
/// model for callers to adopt.
enum LibraryMutualTLSClient {
    /// `baseURL` is the forward's own `https://localhost:<local port>` —
    /// never the Library's remote address, since the forward is what makes
    /// that loopback port answer at all. Blocks the calling thread; callers
    /// already run off the main actor the same way every `SessionAgent.run`
    /// caller in `LibraryClient` does.
    static func perform(
        method: String, baseURL: URL, path: String, headers: [String: String],
        body: Data?, identity: SecIdentity, anchors: [SecCertificate],
        timeout: TimeInterval = 30
    ) throws -> (status: Int, body: Data) {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw LibraryMutualTLSError.transportFailed("\(path) is not a usable path against \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = body
        request.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        configuration.timeoutIntervalForRequest = timeout
        let delegate = LibraryMutualTLSSessionDelegate(identity: identity, anchors: anchors)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        // `nonisolated(unsafe)`: the semaphore wait below is the actual
        // synchronization — this thread never reads `result` until the
        // completion handler has signalled, so the two never touch it at
        // once despite the compiler being unable to see that through a
        // semaphore.
        nonisolated(unsafe) var result: Result<(Int, Data), Error> = .failure(
            LibraryMutualTLSError.transportFailed("the request never completed"))
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(classify(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = .failure(LibraryMutualTLSError.unexpectedResponse("\(String(describing: response))"))
                return
            }
            result = .success((http.statusCode, data ?? Data()))
        }
        task.resume()
        semaphore.wait()
        let (status, responseBody) = try result.get()
        return (status, responseBody)
    }

    /// Turns `URLSession`'s own transport error into one of this file's own
    /// kinds, so `LibraryTransportDispatch` never has to inspect an
    /// `NSError` domain itself. `NSURLErrorServerCertificateUntrusted` and
    /// its siblings are what a refused `SecTrust` surfaces as once
    /// `URLSession` reports the handshake's outcome — the delegate itself
    /// never gets to say why, per its own doc comment above.
    private static func classify(_ error: Error) -> LibraryMutualTLSError {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return .transportFailed(nsError.localizedDescription)
        }
        switch nsError.code {
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            return .trustRefused(nsError.localizedDescription)
        case NSURLErrorSecureConnectionFailed:
            return .handshakeFailed(nsError.localizedDescription)
        default:
            return .transportFailed(nsError.localizedDescription)
        }
    }
}
