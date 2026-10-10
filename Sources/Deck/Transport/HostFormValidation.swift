import Foundation

/// Pure validation for the Hosts tab's add/edit sheet. The part of a form
/// flow that can be silently wrong (a duplicate name that would vanish on the
/// next load, per `ThemeConfiguration.parseHosts`'s own drop-the-later-row
/// rule) belongs in a type a test can drive without a sheet anywhere near
/// it.
enum HostFormValidation {
    enum FieldError: Error, Equatable {
        case emptyName
        case invalidName
        case duplicateName
        case invalidUser
        case invalidAddress
        case invalidCrewsRoot
        case invalidRunbookLink
    }

    /// Validates a sheet's raw fields into a `HostEntry`, refusing a name
    /// collision here rather than letting it reach `parseHosts`'s silent
    /// drop — see `deck/specs/multiple-sessions-per-project` §"Crews on
    /// different hosts": `HostResolution`'s uniqueness guarantee is what
    /// keeps an "OTHER SESSIONS" row's reverse lookup and a Stop button's
    /// forward one in agreement, so a duplicate name is refused rather than
    /// silently dropped.
    ///
    /// `excludingName` is the entry's own current name while editing, so
    /// saving a host without renaming it never collides with itself.
    static func makeEntry(
        name: String, user: String, address: String, crewsRoot: String,
        runbookLink: String = "",
        existingHosts: [HostEntry], excludingName: String? = nil
    ) throws -> HostEntry {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { throw FieldError.emptyName }
        guard let validName = try? validateHostName(trimmedName) else {
            throw FieldError.invalidName
        }
        guard !existingHosts.contains(where: { $0.name == validName && $0.name != excludingName })
        else { throw FieldError.duplicateName }

        guard let validUser = try? validateHostUser(user.trimmingCharacters(in: .whitespaces)) else {
            throw FieldError.invalidUser
        }
        guard let validAddress = try? validateHostAddress(address.trimmingCharacters(in: .whitespaces)) else {
            throw FieldError.invalidAddress
        }

        let trimmedRoot = crewsRoot.trimmingCharacters(in: .whitespaces)
        var validRoot: String?
        if !trimmedRoot.isEmpty {
            guard let root = try? validateWorkingDirectory(trimmedRoot) else {
                throw FieldError.invalidCrewsRoot
            }
            validRoot = root
        }

        let trimmedRunbookLink = runbookLink.trimmingCharacters(in: .whitespaces)
        var validRunbookLink: String?
        if !trimmedRunbookLink.isEmpty {
            guard let link = RunbookLink.parse(trimmedRunbookLink) else {
                throw FieldError.invalidRunbookLink
            }
            validRunbookLink = link.stored
        }

        return HostEntry(
            name: validName, user: validUser, address: validAddress, crewsRoot: validRoot,
            runbookLink: validRunbookLink)
    }

    /// The message shown under the form on a validation failure — a pure
    /// mapping so the wording is pinned by a test.
    nonisolated static func errorMessage(_ error: Error) -> String {
        switch error as? FieldError {
        case .emptyName:
            return "Type a name for the host."
        case .invalidName:
            return "That name isn\u{2019}t usable \u{2014} letters, digits, "
                + "\u{2018}.\u{2019}, \u{2018}_\u{2019} and \u{2018}-\u{2019} only."
        case .duplicateName:
            return "That name is already taken by another host."
        case .invalidUser:
            return "That user isn\u{2019}t usable."
        case .invalidAddress:
            return "That address isn\u{2019}t usable."
        case .invalidCrewsRoot:
            return "That folder doesn\u{2019}t look right \u{2014} an absolute path or "
                + "one starting with ~/, no spaces."
        case .invalidRunbookLink:
            return "That runbook link doesn\u{2019}t look right \u{2014} an https:// URL, "
                + "or a KB id."
        case nil:
            return "Could not save that host."
        }
    }
}
