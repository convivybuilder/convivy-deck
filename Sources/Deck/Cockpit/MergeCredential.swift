import Foundation
import Security

/// Which credential a merge or close call actually used — carried on
/// `MergeRefusal.unauthorizedCredential` so its line names what GitHub
/// rejected, never a bare "the credential".
enum CredentialIdentity: Equatable {
    /// A logged-in `gh` account whose own token was used, named by login.
    case account(login: String)
    /// The pasted Keychain token, used because `gh` listed no account, or
    /// because no listed account was usable: each one either had a token
    /// that could not push to this repository (`couldNotPush`) or had no
    /// token `gh` would hand over (`unreadable`). Both lists keep
    /// active-account-first order.
    case pastedToken(couldNotPush: [String], unreadable: [String])

    /// What a refusal line names for this credential.
    var label: String {
        switch self {
        case .account(let login):
            return login
        case .pastedToken:
            return "the saved token"
        }
    }

    /// One sentence saying why Deck fell back to the saved token, or `nil`
    /// when there is nothing to explain: an account was used, or `gh`
    /// listed no account at all. An account whose token could not be read
    /// is never described as unable to push, since Deck never asked GitHub
    /// about it.
    var fallbackReason: String? {
        guard case .pastedToken(let couldNotPush, let unreadable) = self else { return nil }
        var reasons: [String] = []
        if !couldNotPush.isEmpty {
            reasons.append("\(Self.list(couldNotPush)) can't push here")
        }
        if !unreadable.isEmpty {
            reasons.append("gh couldn't read a token for \(Self.list(unreadable))")
        }
        guard !reasons.isEmpty else { return nil }
        return "Deck used it because \(reasons.joined(separator: " and "))."
    }

    private static func list(_ logins: [String]) -> String {
        switch logins.count {
        case 0: return ""
        case 1: return logins[0]
        case 2: return "\(logins[0]) and \(logins[1])"
        default: return logins.dropLast().joined(separator: ", ") + ", and \(logins.last!)"
        }
    }
}

/// The token a merge or close call sends, paired with which credential it
/// came from — `MergeCredentialSource.resolve`'s own result.
struct MergeCredentialChoice: Equatable {
    let token: String
    let identity: CredentialIdentity
}

/// One `github.com` account `gh auth status` lists, in the order it was
/// read — `MergeCredentialSource.resolve` asks the active one first only
/// because `GHAuthStatus.listAccounts` already sorts that way.
struct GHAccount: Equatable {
    let login: String
    let active: Bool
}

/// The merge/close press's own credential: a logged-in `gh` account that can
/// push to the repository being merged, read fresh at each press and kept
/// nowhere, falling back to a pasted token kept in the login Keychain
/// (`deck/decisions/0003-under-deterministic-deck-merges-with-the-operators-own-credential`).
///
/// **NEVER CALLED UNTIL `ServedSessionsCheck.evaluate` HAS ALREADY ANSWERED
/// `nil` FOR THIS PRESS.** 0003's own ordering — "Deck never reads the gh
/// login on such a machine, because the check runs before the read" — is
/// enforced by `MergePressModel.press`'s call order, not by anything in this
/// file; this file only reads a credential when asked to.
enum MergeCredentialSource {
    /// Asks each logged-in `gh` account, active first, whether it can push
    /// to `repo`, and uses the first that can. Falls back to the pasted
    /// token when `gh` lists no account or none of them can push, and to
    /// `nil` when that pasted token also doesn't exist — the press then
    /// refuses with no GitHub call made at all. Never runs `gh auth
    /// switch`: the accounts are read and discarded within this one call,
    /// so no other `gh` caller on the machine sees its active account
    /// change. Every read is injected so a test never shells out, touches
    /// the real Keychain, or reaches GitHub.
    static func resolve(
        repo: String,
        listAccounts: () -> [GHAccount] = { GHAuthStatus.listAccounts() },
        readAccountToken: (String) -> String? = { GHAuthToken.read(user: $0) },
        canPush: (String, String) -> Bool = { token, repo in GitHubMergeClient.canPush(repo: repo, token: token) },
        readPastedToken: () -> String? = { MergeTokenKeychain.shared.read() }
    ) -> MergeCredentialChoice? {
        var couldNotPush: [String] = []
        var unreadable: [String] = []
        var firstReadable: MergeCredentialChoice?
        for account in listAccounts() {
            guard let token = readAccountToken(account.login) else {
                unreadable.append(account.login)
                continue
            }
            let choice = MergeCredentialChoice(token: token, identity: .account(login: account.login))
            if canPush(token, repo) {
                return choice
            }
            couldNotPush.append(account.login)
            if firstReadable == nil { firstReadable = choice }
        }
        if let pasted = readPastedToken() {
            return MergeCredentialChoice(
                token: pasted, identity: .pastedToken(couldNotPush: couldNotPush, unreadable: unreadable))
        }
        // No account passed the push check and nothing is pasted. Send the
        // first readable account anyway, so GitHub's own refusal (a dead
        // token's 401, a missing grant's 404) reaches the row with that
        // login named, instead of "no credential found", which would hide
        // the cause.
        return firstReadable
    }
}

/// Runs `gh auth token` as a local subprocess — never over ssh, since this
/// reads the credential of the machine Deck itself runs on. The same
/// resolved-executable-path and bounded-subprocess shape
/// `TailnetDiscovery.resolvedExecutablePath`/`.run` already use for
/// `tailscale`, reused here for the identical reason: a GUI app's `$PATH`
/// does not reliably carry `/usr/local/bin` or `/opt/homebrew/bin`.
enum GHAuthToken {
    static let candidateExecutablePaths = [
        "/usr/local/bin/gh",
        "/opt/homebrew/bin/gh",
        "/usr/bin/gh",
    ]

    static func resolvedExecutablePath(
        candidates: [String] = candidateExecutablePaths,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        candidates.first(where: isExecutable)
    }

    /// `gh auth token --user <login>`'s stdout, trimmed — the per-account
    /// read `MergeCredentialSource.resolve` uses to read a logged-in
    /// account's token without switching it active (`gh auth switch` would,
    /// and is never called here). `nil` when `gh` is missing, has no token
    /// for that login, or exits non-zero for any other reason; 0003 treats
    /// all of those as one condition that falls through to the next account.
    static func read(user login: String, timeout: TimeInterval = 5) -> String? {
        readTrimmed(arguments: ["auth", "token", "--user", login], timeout: timeout)
    }

    private static func readTrimmed(arguments: [String], timeout: TimeInterval) -> String? {
        guard let executablePath = resolvedExecutablePath() else { return nil }
        guard let data = try? GHSubprocess.run(executablePath: executablePath, arguments: arguments, timeout: timeout)
        else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty ?? true) ? nil : token
    }
}

/// `gh auth status --json hosts`'s logged-in `github.com` accounts, active
/// one first — `MergeCredentialSource.resolve`'s own "active account first"
/// ordering (deck/decisions/0003) depends on this sort, not on whatever
/// order `gh` itself happened to print them in.
enum GHAuthStatus {
    static func listAccounts(timeout: TimeInterval = 5) -> [GHAccount] {
        guard let executablePath = GHAuthToken.resolvedExecutablePath() else { return [] }
        guard let data = try? GHSubprocess.run(
            executablePath: executablePath, arguments: ["auth", "status", "--json", "hosts"], timeout: timeout)
        else { return [] }
        return parse(data)
    }

    /// `{"hosts":{"github.com":[{"login":..,"active":bool,"state":..}]}}`,
    /// observed on the laptop's gh 2.89 — an unparseable body or a missing
    /// `github.com` entry answers no accounts, the same "falls through to
    /// the pasted token" condition `GHAuthToken.read` answering `nil` does.
    static func parse(_ data: Data) -> [GHAccount] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hosts = json["hosts"] as? [String: Any],
              let entries = hosts["github.com"] as? [[String: Any]]
        else { return [] }
        let accounts = entries.compactMap { entry -> GHAccount? in
            guard let login = entry["login"] as? String else { return nil }
            return GHAccount(login: login, active: (entry["active"] as? Bool) ?? false)
        }
        return accounts.filter(\.active) + accounts.filter { !$0.active }
    }
}

/// The bounded local subprocess `GHAuthToken` and `GHAuthStatus` both run —
/// never over ssh, since this reads the credential of the machine Deck
/// itself runs on. The same resolved-executable-path and bounded-subprocess
/// shape `TailnetDiscovery.resolvedExecutablePath`/`.run` already use for
/// `tailscale`, reused here for the identical reason: a GUI app's `$PATH`
/// does not reliably carry `/usr/local/bin` or `/opt/homebrew/bin`.
private enum GHSubprocess {
    static func run(executablePath: String, arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0, process.terminationReason != .uncaughtSignal else {
            throw CocoaError(.fileReadUnknown)
        }
        return data
    }
}

/// A pasted-token store, so `MergeCredentialSource` and the served-sessions
/// refusal path (which offers to remove a stored token) can both be tested
/// against an in-memory fake that never touches the real login Keychain.
protocol MergeTokenStore: Sendable {
    func read() -> String?
    func save(_ token: String)
    func remove()
    /// Whether a token is stored, answered without returning it.
    func exists() -> Bool
}

/// The real store: one generic-password item in the login Keychain, scoped
/// by a fixed service name — never a file, an environment variable, or
/// anything that would outlive the Keychain's own access control.
final class MergeTokenKeychain: MergeTokenStore, @unchecked Sendable {
    static let shared = MergeTokenKeychain()

    /// Fixed rather than per-host: 0003's pasted token is a property of the
    /// MACHINE Deck runs on ("kept in that machine's login Keychain"), not
    /// of any one crew or host entry, so one item is all this ever needs.
    private let service = "com.convivy.deck.merge-pasted-token"
    private let account = "deck-merge-token"

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var attributes = query()
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) {
        let data = Data(token.utf8)
        var attributes = query()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    func remove() {
        SecItemDelete(query() as CFDictionary)
    }

    /// Asks for attributes only, so the secret never leaves the Keychain to
    /// draw an offer to remove it.
    func exists() -> Bool {
        var attributes = query()
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess
    }
}
