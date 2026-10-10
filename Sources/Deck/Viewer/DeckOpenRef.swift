import Foundation

/// The reference encoded in a `deck-open:` URL.
///
/// `deck-open:?origin=kb&ref=deck%2Fspecs%2Fsession-pane` routes a KB doc.
/// `deck-open:?origin=path&ref=%2FUsers%2Foperator%2FConvivy%2Ffile.md` routes
/// an absolute path on the mini. `deck-open:?origin=item&ref=issue_01M0Y7PW…`
/// routes a Library item — a work item id `session_view.py`'s renderer is
/// expected to emit inline the way it already emits `kb`/`path` links, once
/// that renderer's own change lands (out of scope here; this side only has to
/// parse the format before anything emits it, so a later renderer never hands
/// Deck a ref it cannot open).
///
/// The URL scheme is an internal command — it is never passed to NSWorkspace or
/// added to `ExternalLink.allowedSchemes`. `ConversationWebView`'s navigation
/// delegate intercepts it in-process and cancels the navigation.
///
/// Parsing and validation are `nonisolated static` so they are testable without
/// WebKit or a window, matching the convention in `SessionPaneModel` and
/// `SessionAgent`.
enum DeckOpenRef {

    enum Origin: Hashable, Sendable {
        case kb(id: String)
        case path(absolutePath: String)
        /// A Library work item (`issue_…`, `course_…`) opened in the item
        /// detail pane, on whichever product it is filed against — see
        /// `ItemDetailPane`.
        case item(id: String)
    }

    /// Roots a `path` ref must fall under after normalisation, derived from
    /// the account name of every configured host plus the local scratchpad.
    ///
    /// EACH CONFIGURED HOST CONTRIBUTES ITS OWN `/Users/<account>/`, rather
    /// than one compiled-in operator's home directory — see
    /// `deck/specs/running-deck-as-someone-else`. An empty `hosts` table
    /// (Settings › Hosts' own empty state on an unconfigured install)
    /// therefore contributes NO `/Users/` root at all, and a `path` ref
    /// refuses outright: the same "unresolved resolves to nothing" posture
    /// #119 gave `SSHTarget.mini` rather than falling back to a compiled
    /// identity. This can only ever NARROW what a compiled operator home
    /// admitted, never widen it — a configured host's account can only add
    /// another sibling of that same shape under `/Users/`.
    ///
    /// `entry.user` is re-validated with `validateHostUser` here rather than
    /// trusted as already-clean. `ThemeConfiguration.parseHosts` and
    /// `HostFormValidation` both gate it before a `HostEntry` normally
    /// reaches `hosts`, but this is the security boundary itself, so it does
    /// not take that on faith — the same "the gate that makes it true
    /// regardless of who built it" discipline `SessionAgent.arguments`
    /// applies to `SSHTarget`. A `user` that fails validation (a `/`, a
    /// leading `-`, anything outside the charset) contributes no root rather
    /// than a malformed one.
    ///
    /// Every entry is absolute and ends with `/` so the prefix check never
    /// matches a sibling account whose name is a longer extension of this
    /// one's (e.g. `operatorExtra` beside `operator`).
    /// `testAllAllowedRootsAreAbsoluteAndEndWithSlash` asserts the format
    /// invariant on the full list.
    ///
    /// LIMITATION, NOTED RATHER THAN SOLVED: a Linux host's home is
    /// `/home/<account>/`, not `/Users/`. Deck's remote is a Mac today (tmux
    /// + session-agent), so this does not widen to admit both shapes — a
    /// Linux host would need its own derivation, not a guess bolted on here.
    nonisolated static func allowedPathRoots(hosts: [HostEntry]) -> [String] {
        // Claude Code writes session scratchpads to /private/tmp/claude-<uid>/.
        // That directory is 0700 owned by the running user; sticky /private/tmp
        // stops any other local user replacing it. getuid() always succeeds, so
        // this derivation is correct as long as the laptop and mini share a uid
        // (both run as the operator account, uid 501, today). If they diverge, scratchpad links
        // silently fail; validatePath logs specifically when it detects that case.
        //
        // Both spellings are listed because `validatePath` is lexical only
        // (see its doc comment): `NSString.standardizingPath`'s
        // `/private/tmp` -> `/tmp` collapse fires only when the exact
        // candidate path currently exists on the laptop — measured directly,
        // an existing file under `/private/tmp/claude-<uid>/...` collapses to
        // `/tmp/claude-<uid>/...` while a path with nothing behind it keeps
        // the `/private/tmp` spelling. Whether a given scratchpad candidate
        // exists on the laptop is unrelated to whether it exists on the mini
        // (the host that actually opens it), so a lexical check has to
        // accept both spellings rather than depend on local existence to
        // pick the right one.
        let uid = getuid()
        let hostRoots = hosts.compactMap { host -> String? in
            (try? validateHostUser(host.user)).map { "/Users/\($0)/" }
        }
        return hostRoots + [
            "/private/tmp/claude-\(uid)/",
            "/tmp/claude-\(uid)/",
        ]
    }

    /// Characters accepted in a validated path.
    ///
    /// `WorkingCopyStore.readFileArguments` shell-quotes the path before placing it
    /// on ssh argv, so the only characters that must be rejected are control
    /// characters and newlines: they are never legitimate in a user-visible
    /// path and they corrupt log lines. A denylist of control characters is
    /// strictly stronger than the old allowlist, because it does not depend on
    /// having enumerated every dangerous character correctly.
    private static let safePathCharacters = CharacterSet.controlCharacters.inverted

    private static let kbIdPattern = try! NSRegularExpression(
        pattern: "^[a-z0-9-]+/[a-z0-9-]+/[a-z0-9-]+\\z")

    /// Characters accepted in a validated item id, mirroring
    /// `LibraryClient.validateLibraryId`'s charset (alphanumerics, dot,
    /// underscore, hyphen) rather than calling it.
    ///
    /// `LibraryClient` lives in `Cockpit`, and `Cockpit` already depends on
    /// `Viewer` (`ItemDetailPane` renders through `FileViewerPane`), so
    /// reaching from here into `LibraryClient` would point this file's
    /// dependency arrow back the other way and leave the two folders
    /// depending on each other. Duplicating the charset keeps the direction
    /// one-way, at the cost of two places that must agree — `DeckOpenRefTests`
    /// pins the two against each other so a change to one without the other
    /// fails a test rather than drifting silently, the same trade the KB id
    /// pattern above already makes.
    ///
    /// **`LibraryClient.validateLibraryId` is authoritative.** A future
    /// change to the Library's own id charset changes that function first;
    /// this one follows.
    private static let allowedItemIdCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Matches `/private/tmp/claude-<digits>/` with any uid (capture group 1 = uid).
    private static let scratchpadPattern = try! NSRegularExpression(
        pattern: "^/private/tmp/claude-(\\d+)/")

    // MARK: - Validation

    /// Parses a `deck-open:` URL and returns its validated origin, or nil.
    ///
    /// Returns nil on any malformed or rejected input. The caller logs and
    /// continues; this function never throws or raises.
    ///
    /// `hosts` is the caller's current `ThemeConfiguration.hosts` — a `path`
    /// ref is validated against the roots those hosts derive
    /// (`allowedPathRoots(hosts:)`), never a compiled default.
    nonisolated static func validate(_ url: URL, hosts: [HostEntry]) -> Origin? {
        guard url.scheme?.lowercased() == "deck-open" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        var params: [String: String] = [:]
        for item in items {
            if let value = item.value { params[item.name] = value }
        }
        guard let origin = params["origin"], let ref = params["ref"] else { return nil }
        switch origin {
        case "kb":   return validateKBId(ref).map { .kb(id: $0) }
        case "item": return validateItemId(ref).map { .item(id: $0) }
        case "path": return validatePath(ref, allowedRoots: allowedPathRoots(hosts: hosts))
                .map { .path(absolutePath: $0) }
        default:     return nil
        }
    }

    /// Accepts exactly three slash-separated segments of `[a-z0-9-]`.
    ///
    /// The pattern is `^[a-z0-9-]+/[a-z0-9-]+/[a-z0-9-]+$` as specified. A KB
    /// id only ever contains lowercase alphanumeric and hyphens, so any id that
    /// matches is also safe on ssh argv without quoting.
    nonisolated static func validateKBId(_ id: String) -> String? {
        let range = NSRange(id.startIndex..., in: id)
        return kbIdPattern.firstMatch(in: id, range: range) != nil ? id : nil
    }

    /// Accepts a non-empty id of at most 128 characters, all drawn from
    /// `allowedItemIdCharacters` — see that constant's doc for why this
    /// mirrors `LibraryClient.validateLibraryId` rather than calling it.
    nonisolated static func validateItemId(_ id: String) -> String? {
        guard !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy(allowedItemIdCharacters.contains) else { return nil }
        return id
    }

    // MARK: - Download

    /// The filename to suggest when saving a working copy to disk.
    ///
    /// For a `path` ref this is the basename. For a `kb` ref it is the doc
    /// id's last slash-separated segment plus `.md`, because KB docs have no
    /// local filename.
    ///
    /// The empty and all-separator fallbacks are NOT reachable through the app:
    /// `validateKBId` requires three non-empty segments and `validatePath` an
    /// allowed root, so a degenerate ref never gets this far. They stay because
    /// this is a plain static anyone can call, and the tests pin them so the
    /// contract holds if a future caller arrives without that validation — but
    /// nobody should read those tests as describing a live path.
    nonisolated static func suggestedFilename(for origin: Origin) -> String {
        switch origin {
        case .path(let absolutePath):
            let name = (absolutePath as NSString).lastPathComponent
            return name.isEmpty || name == "/" ? "file" : name
        case .kb(let id):
            let last = id.split(separator: "/").last.map(String.init) ?? ""
            return last.isEmpty ? "document.md" : "\(last).md"
        case .item(let id):
            // NOT REACHABLE THROUGH THE APP: an `.item` ref opens
            // `ColumnOccupant.item` directly (`ContentView.openViewer`
            // intercepts it before it ever becomes a `.viewer` ref), so it
            // never reaches the save panel this filename is for. Handled
            // anyway because `Origin` is one type across three cases and a
            // pure function over it has to answer for all of them.
            return "\(id).md"
        }
    }

    /// Copies `source` onto `destination`, leaving `destination` untouched if
    /// the write cannot complete.
    ///
    /// Removing the existing file and copying over the gap loses the file the
    /// reader chose to replace when the copy then fails — a full disk or an
    /// ejected volume and the original is gone with nothing in its place. The
    /// save panel's "replace?" prompt is consent to overwrite, not consent to
    /// lose both.
    ///
    /// So the bytes are staged beside the destination and swapped in.
    /// `replaceItemAt` leaves the original in place if the swap does not
    /// complete, and staging in the destination's own directory keeps the swap
    /// on one volume, where it is atomic.
    ///
    /// `nonisolated static` so the write is testable without a window or a save
    /// panel, matching the seam convention `validate` and `SessionAgent` use.
    nonisolated static func saveCopy(of source: URL, to destination: URL) throws {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".deck-save-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: staged)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch {
            // `replaceItemAt` consumes the staged file on success, so there is
            // only something to clean up on the failure path.
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    // MARK: - Path validation

    /// Accepts absolute paths that, after normalisation, fall under an allowed
    /// root and contain only ssh-safe characters.
    ///
    /// `validatePath` never touches the filesystem beyond what
    /// `NSString.standardizingPath` itself does internally to resolve
    /// `.`/`..` and macOS's `/private/tmp` <-> `/tmp` alias. It does not
    /// `lstat` or resolve symlinks, and that is deliberate: this check runs
    /// on the laptop, while every consumer of its result —
    /// `WorkingCopyStore.fetch`, `SessionAgent.renderFile`,
    /// `WorkingCopyStore.writeBack` — opens the validated path over ssh on a
    /// separate host, the mini. A symlink that exists only on the laptop's
    /// filesystem is never what gets opened, so resolving it here would
    /// protect nothing; it would only give this function more ways to be
    /// wrong about a filesystem it is not the one reading. An earlier
    /// version of this function resolved symlinks on both the candidate and
    /// each allowed root to close that gap, and in doing so handed the
    /// containment boundary itself to a symlink a session could plant —
    /// replace an allowed root's own directory with a symlink to `/`, and
    /// the resolved root became `/`, which every absolute path has as a
    /// prefix. `testReplacingADirectoryWithASymlinkDoesNotChangeItsStandardizedPath`
    /// pins the property that makes that impossible now: `standardizingPath`
    /// does not follow a directory-level symlink the way
    /// `resolvingSymlinksInPath` does. Containment against a symlink has to
    /// be enforced on the host that opens the file, not here.
    ///
    /// The one filesystem-dependent behaviour that remains is
    /// `standardizingPath`'s `/private/tmp` <-> `/tmp` collapse, and it is
    /// existence-gated on the laptop: a candidate that exists locally
    /// collapses to the `/tmp` spelling, one that doesn't keeps
    /// `/private/tmp`. Whether a scratchpad candidate happens to exist on
    /// the laptop says nothing about whether it exists on the mini, so this
    /// function does not treat local nonexistence as rejection — a
    /// candidate under an allowed scratchpad root that isn't on the laptop
    /// is accepted, because it may well be real on the mini, which is the
    /// only host that matters. `allowedRoots` lists both scratchpad
    /// spellings so whichever one a candidate happens to arrive in still
    /// matches — see `allowedPathRoots(hosts:)`, which derives it.
    nonisolated static func validatePath(_ path: String, allowedRoots: [String]) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let normalised = (path as NSString).standardizingPath
        guard allowedRoots.contains(where: { normalised.hasPrefix($0) }) else {
            // If the rejected path looks like a scratchpad under a different uid,
            // say so explicitly. The real reason this is acceptable for the
            // single-user threat model is that validatePath never touches the
            // filesystem beyond standardizingPath's own internal resolution —
            // the cat call on the mini will fail when no file exists there.
            // What is NOT acceptable is silent failure when laptop and mini diverge.
            let range = NSRange(normalised.startIndex..., in: normalised)
            if let m = scratchpadPattern.firstMatch(in: normalised, range: range) {
                let uidRange = Range(m.range(at: 1), in: normalised)!
                let embeddedUid = normalised[uidRange]
                if embeddedUid != "\(getuid())" {
                    print("[Deck] validatePath: scratchpad uid mismatch — " +
                          "path uid \(embeddedUid), laptop uid \(getuid()); " +
                          "laptop and host may have diverged")
                }
            }
            return nil
        }
        guard normalised.unicodeScalars.allSatisfy(safePathCharacters.contains) else {
            return nil
        }
        return normalised
    }
}
