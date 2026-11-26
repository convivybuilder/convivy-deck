import Foundation

/// The direct GitHub call a merge or close press makes with the operator's
/// own credential
/// (`deck/decisions/0003-under-deterministic-deck-merges-with-the-operators-own-credential`:
/// "Deck merges a pull request by calling GitHub's merge directly... The
/// merge request and the credential never pass through the server or the
/// Keel").
///
/// `perform` is the one seam: a transport closure that sends an already-built
/// `URLRequest` and returns its status and body, never thrown as a test
/// double that reaches `api.github.com`. The production default is a plain
/// synchronous `URLSession` call — no mutual TLS, no local socket, since this
/// is an ordinary HTTPS call to GitHub's own API.
enum GitHubMergeClient {
    static let apiBase = "https://api.github.com"

    enum TransportError: Error, CustomStringConvertible {
        case invalidRepo(String)
        case transport(String)

        var description: String {
            switch self {
            case .invalidRepo(let repo): return "\(repo) is not a usable owner/repo pair"
            case .transport(let message): return message
            }
        }
    }

    /// One HTTP exchange against GitHub's API, performed synchronously —
    /// the same blocking-`URLSession` shape `LibraryMutualTLSClient.perform`
    /// already uses, with no client identity and no custom trust evaluator,
    /// since this is a plain HTTPS call to GitHub's own public API.
    static func perform(_ request: URLRequest, timeout: TimeInterval = 20) throws -> (status: Int, body: Data) {
        var request = request
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(Int, Data), Error> = .failure(
            TransportError.transport("the request never completed"))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(TransportError.transport(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = .failure(TransportError.transport("the response carried no HTTP status"))
                return
            }
            result = .success((http.statusCode, data ?? Data()))
        }
        task.resume()
        semaphore.wait()
        let (status, body) = try result.get()
        return (status, body)
    }

    private static func pullURL(repo: String, number: Int) throws -> URL {
        guard let identity = LibraryClient.validateRepoIdentity(repo) else {
            throw TransportError.invalidRepo(repo)
        }
        guard let url = URL(string: "\(apiBase)/repos/\(identity.owner)/\(identity.repoName)/pulls/\(number)")
        else { throw TransportError.invalidRepo(repo) }
        return url
    }

    private static func authorizedRequest(url: URL, method: String, token: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Deck", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// `merge`'s own answer: GitHub reported the merge, carrying the merge
    /// commit it made (`merge_commit_sha` on Deck's own `POST
    /// /merge-reports` report, read off GitHub's `sha` field here), or a
    /// classified refusal.
    enum MergeAttemptOutcome: Equatable {
        case merged(mergeCommitSha: String)
        case refused(MergeRefusal)
    }

    /// `PUT /repos/{owner}/{repo}/pulls/{number}/merge`, sending the row's
    /// own head as the expected one — 0003's "Deck merges at the head the
    /// operator read... GitHub refuses the merge if the head has moved."
    /// Any refusal is classified by `MergeRefusal.classify`, reused rather
    /// than re-derived, and carries `credential.identity` so an
    /// unauthorized refusal names what Deck used.
    static func merge(
        repo: String, number: Int, expectedHeadSha: String, credential: MergeCredentialChoice,
        perform: (URLRequest) throws -> (status: Int, body: Data) = { try perform($0) }
    ) throws -> MergeAttemptOutcome {
        let url = try pullURL(repo: repo, number: number).appendingPathComponent("merge")
        let body = try JSONSerialization.data(withJSONObject: ["sha": expectedHeadSha])
        let request = authorizedRequest(url: url, method: "PUT", token: credential.token, body: body)
        let (status, responseBody) = try perform(request)
        if let refusal = MergeRefusal.classify(status: status, body: responseBody, credential: credential.identity) {
            return .refused(refusal)
        }
        guard let json = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let mergeCommitSha = json["sha"] as? String
        else {
            return .refused(.unrecognised(
                status: status, message: "GitHub reported the merge but named no merge commit"))
        }
        return .merged(mergeCommitSha: mergeCommitSha)
    }

    /// `PATCH /repos/{owner}/{repo}/pulls/{number}` with `state: closed` —
    /// the close-without-merging affordance, through the same credential
    /// path as `merge` and classified the same way: `nil` means GitHub
    /// closed it.
    static func close(
        repo: String, number: Int, credential: MergeCredentialChoice,
        perform: (URLRequest) throws -> (status: Int, body: Data) = { try perform($0) }
    ) throws -> MergeRefusal? {
        let url = try pullURL(repo: repo, number: number)
        let body = try JSONSerialization.data(withJSONObject: ["state": "closed"])
        let request = authorizedRequest(url: url, method: "PATCH", token: credential.token, body: body)
        let (status, responseBody) = try perform(request)
        if status == 200 { return nil }
        return MergeRefusal.classify(status: status, body: responseBody, credential: credential.identity)
            ?? .unrecognised(status: status, message: String(data: responseBody, encoding: .utf8) ?? "(binary)")
    }

    /// `GET /repos/{owner}/{repo}` with `token`, answering whether
    /// `permissions.push` reads `true` — the per-account check
    /// `MergeCredentialSource.resolve` runs before trusting an account to
    /// merge. Never throws: an invalid repo, a transport failure, or an
    /// unparseable body all answer `false`, since 0003's own fallthrough
    /// ("falls back to the pasted token when... none can push") treats
    /// every one of those the same as a push check that failed.
    static func canPush(
        repo: String, token: String,
        perform: (URLRequest) throws -> (status: Int, body: Data) = { try perform($0) }
    ) -> Bool {
        guard let identity = LibraryClient.validateRepoIdentity(repo),
              let url = URL(string: "\(apiBase)/repos/\(identity.owner)/\(identity.repoName)")
        else { return false }
        let request = authorizedRequest(url: url, method: "GET", token: token, body: nil)
        guard let (status, body) = try? perform(request), status == 200,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let permissions = json["permissions"] as? [String: Any]
        else { return false }
        return (permissions["push"] as? Bool) == true
    }
}
