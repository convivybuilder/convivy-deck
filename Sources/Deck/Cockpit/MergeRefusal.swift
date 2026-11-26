import Foundation

/// Why a merge press did not merge the pull request —
/// `issue_01M1372GW0EHM5BYKHAD5ZZ1D9`, under the direct-merge epic
/// (`issue_01M0NWWHCPYNBYS297SEPRKRD5`). Six named causes, plus a seventh for
/// anything this classifier does not recognise. This file classifies and
/// presents the cause; it makes no merge call, reads no credential, and
/// holds no network code. The merge call belongs to the merge button,
/// `issue_01M1HQMDZ8TG2KVK7JG6P7YK7T`
/// (deck/decisions/0003-under-deterministic-deck-merges-with-the-operators-own-credential).
enum MergeRefusal: Equatable {
    /// The head Deck sent as the pull request's expected head has moved
    /// since it was last read — GitHub's `PUT .../merge` answers 409.
    case movedHead
    /// GitHub will not merge the pull request as it stands — 405, "Pull
    /// Request is not mergeable."
    case conflict
    /// A branch protection rule or repository ruleset is blocking the
    /// merge, and no required status check names itself as the reason.
    case protectedBranch
    /// A required status check is failing, or still expected, at head.
    case redRequiredCheck
    /// The credential GitHub read for this merge is not authorized to make
    /// it — 401, 403, or a 404 GitHub answers when it hides a private
    /// repository from a credential without access to it. Carries which
    /// credential Deck used and GitHub's own status and message, so the
    /// line never drops them.
    case unauthorizedCredential(CredentialIdentity, status: Int, githubMessage: String?)
    /// Deck's own serves-no-sessions check refused the press before any
    /// call to GitHub was made.
    case servesSessions(ServesSessionsReason)
    /// A response this classifier does not recognise — GitHub's own status
    /// and message, carried verbatim, so nothing is ever drawn as a bare
    /// generic failure without GitHub's own words.
    case unrecognised(status: Int, message: String)

    /// Which of Deck's two "this machine serves sessions" findings refused
    /// the press
    /// (deck/decisions/0003-under-deterministic-deck-merges-with-the-operators-own-credential):
    /// a configured host resolving to this machine, or a Builder install
    /// found on it. Carried so a caller that logs or files an issue about a
    /// wrong finding can say which one fired, even though the two read the
    /// same sentence to the operator (`message` below).
    enum ServesSessionsReason: Equatable {
        case configuredHostResolvesHere
        case builderInstalledHere
    }
}

extension MergeRefusal {

    // MARK: - Classifying a GitHub merge response

    /// `PUT /repos/{owner}/{repo}/pulls/{n}/merge`'s answer, classified, or
    /// `nil` on a 200 whose body reports `"merged": true`.
    ///
    /// **GitHub publishes no error codes for these refusals.** Every match
    /// below is against the `message` string GitHub's merge endpoint is
    /// observed to send today, the same "observed, not owned" posture this
    /// codebase already takes with Claude Code's own wire formats. A
    /// `message` this function has not seen, on a status it has not seen
    /// paired with a recognised message, degrades to `.unrecognised` —
    /// NEVER to a named cause it did not actually match. A wrongly named
    /// cause would tell the operator the wrong thing to do next; a named
    /// "GitHub refused the merge and said X" never does.
    ///
    /// 401, 403, and 404 are read as `.unauthorizedCredential`
    /// unconditionally — GitHub answers 404 for a private repository a
    /// credential cannot see at all, so no message match is possible or
    /// needed there. `credential` is carried straight onto the refusal,
    /// never matched against; GitHub's own message is decoded when the
    /// body is JSON and `nil` otherwise, so a non-JSON body still names
    /// `credential` even though it names no GitHub message.
    static func classify(status: Int, body: Data, credential: CredentialIdentity) -> MergeRefusal? {
        if status == 200, mergedTrue(body) {
            return nil
        }
        if status == 401 || status == 403 || status == 404 {
            return .unauthorizedCredential(credential, status: status, githubMessage: decodeMessage(body))
        }
        guard let message = decodeMessage(body) else {
            return .unrecognised(status: status, message: rawBodyText(body))
        }
        switch status {
        case 409:
            return message.lowercased().contains("head branch was modified")
                ? .movedHead : .unrecognised(status: status, message: message)
        case 405:
            return classify405(message: message)
        default:
            return .unrecognised(status: status, message: message)
        }
    }

    private static func classify405(message: String) -> MergeRefusal {
        let lower = message.lowercased()
        if lower.contains("not mergeable") || lower.contains("merge conflicts") {
            return .conflict
        }
        if lower.contains("required status check") {
            return .redRequiredCheck
        }
        if lower.contains("rule violation") || lower.contains("protected ref") || lower.contains("protected branch") {
            return .protectedBranch
        }
        return .unrecognised(status: 405, message: message)
    }

    private static func mergedTrue(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return (json["merged"] as? Bool) == true
    }

    private static func decodeMessage(_ body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json["message"] as? String
    }

    private static func rawBodyText(_ body: Data) -> String {
        String(data: body, encoding: .utf8) ?? "(binary)"
    }

    // MARK: - What a person reads

    /// One line, plain English: what happened, and what the person can do
    /// about it. Never names a host, a machine, or the operator — the
    /// item's own instruction, since this line is drawn for whoever is
    /// reading the pull request row, not for a log.
    var message: String {
        switch self {
        case .movedHead:
            return "This pull request changed since you read it. Deck has reloaded it at its new commit; " +
                "read the changes before you merge."
        case .conflict:
            return "GitHub can't merge this pull request as it stands. Resolve the conflict, then try again."
        case .protectedBranch:
            return "A branch protection rule is blocking this merge. Resolve it on GitHub, then try again."
        case .redRequiredCheck:
            return "A required check hasn't passed yet. Wait for it to finish, or fix it, then try again."
        case .unauthorizedCredential(let credential, let status, let githubMessage):
            let answer = githubMessage.map { "\(status): \($0)" } ?? "\(status)"
            let why = credential.fallbackReason.map { " \($0)" } ?? ""
            return "GitHub refused the merge for \(credential.label) (\(answer)).\(why) Sign in to gh with an " +
                "account that can merge here, then try again."
        case .servesSessions(.configuredHostResolvesHere):
            return "This machine also serves the fleet's sessions, so merging here isn't available. " +
                "Merge this pull request on github.com instead."
        case .servesSessions(.builderInstalledHere):
            return "This machine has a Builder install on it, so merging here isn't available. " +
                "Merge this pull request on github.com instead."
        case .unrecognised(let status, let message):
            return "GitHub refused the merge (\(status)): \(message)"
        }
    }

    // MARK: - How a row draws it

    /// The glyph a row draws beside `message` — a second channel from
    /// `severity`'s ink, so the row does not rely on colour alone to tell
    /// its six-plus-one causes apart. Every case gets its own SF Symbol.
    var glyphName: String {
        switch self {
        case .movedHead: return "arrow.triangle.2.circlepath"
        case .conflict: return "exclamationmark.triangle.fill"
        case .protectedBranch: return "lock.fill"
        case .redRequiredCheck: return "xmark.seal.fill"
        case .unauthorizedCredential: return "person.crop.circle.badge.xmark"
        case .servesSessions: return "arrow.up.forward.square"
        case .unrecognised: return "questionmark.circle.fill"
        }
    }

    /// The ink weight `message` draws at — `PRLadderRow.Severity`'s own
    /// vocabulary, reused rather than duplicated, since both are "how
    /// urgently should this line read."
    var severity: PRLadderRow.Severity {
        switch self {
        case .movedHead, .servesSessions:
            return .caution
        case .conflict, .protectedBranch, .redRequiredCheck, .unauthorizedCredential, .unrecognised:
            return .failure
        }
    }
}
