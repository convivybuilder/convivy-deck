import Foundation

/// Fetches files from the mini and writes working copies into Application Support.
///
/// THE KB CHECKOUT ON DISK IS NEVER WRITTEN TO. The copy under Application
/// Support is Deck's own working area, distinct from
/// `~/Convivy/knowledge/`. A document that arrived through MCP goes back
/// through MCP (phase 4).
///
/// **The KB read path takes no lease, and does not carry `content_sha`.**
/// `fetch(target:kbId:)` reads `GET /reference/documents/{doc_id}` on the
/// Library (`deck/decisions/0002`), which is a read with nothing to release —
/// see that function's doc for why, and for the one field this move drops.
/// The editor's own checkout, in `KnowledgeBase.swift`, is unrelated: it takes
/// its own lease through `agentctl kb checkout` because it means to write, and
/// carries the sha phase 4's `kb_propose` will need from that call, not from
/// this one.
enum WorkingCopyStore {

    enum FetchError: Error {
        case unexpectedResponse(String)
        /// A path with no usable components, or one carrying `.` or `..`.
        case unusablePath(String)
        /// Two different remote sources resolved to one local directory.
        case workingCopyCollision(existing: String, incoming: String)
        /// The Library has no document at this id, or none this identity may
        /// see — its 404 conflates the two on purpose (contract §8), so this
        /// does too.
        case documentNotFound(String)
        /// The Library refused the request for some other reason: 401, 403,
        /// 409, 422, or a 5xx. Carries the status and body as given rather
        /// than a name from ADR-0002's future error-kind taxonomy, which this
        /// stopgap transport does not speak — see `fetch(target:kbId:)`.
        case libraryRefused(status: Int, body: String)
    }

    /// The file recording which remote source a working-copy directory holds.
    static let sourceMarkerName = ".deck-source"

    /// Claims a working-copy directory for one remote source, or refuses it.
    ///
    /// INJECTIVE IN SWIFT IS NOT INJECTIVE ON DISK, and that gap is the whole
    /// reason this exists. The directory tree mirrors the remote path or doc id
    /// one component at a time, which cannot collide as a mapping — but APFS is
    /// case-insensitive and folds NFC/NFD, so two distinct sources can still
    /// land in one directory once the filesystem has its say. Recorded as
    /// `sig_01KZ98FJB40Z7KPF1XDTSHAQZM`.
    ///
    /// It is unreachable today for one reason only: the mini and the laptop run
    /// the same case-insensitive filesystem, so a source that could produce two
    /// colliding names cannot exist over there either. **That is a property of
    /// the storage, not of this code**, and it changes without anything here
    /// changing — a case-sensitive volume, or a Linux host serving paths to
    /// Deck, and the collision returns in its original form. Nothing in Deck's
    /// suite would catch it, because the mapping would still be injective and
    /// every test would still pass.
    ///
    /// So the directory records what it holds, and a second source claiming it
    /// is refused rather than served. That turns a silent wrong-document — the
    /// exact failure #74 and #76 each fixed once — into an error naming both
    /// sources.
    private static func claim(_ dir: URL, forSource source: String) throws {
        let marker = dir.appendingPathComponent(sourceMarkerName)
        if let existing = try? String(contentsOf: marker, encoding: .utf8),
           existing != source {
            throw FetchError.workingCopyCollision(existing: existing, incoming: source)
        }
        try? source.write(to: marker, atomically: true, encoding: .utf8)
    }

    static let baseDirectory: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let legacy = legacyBaseDirectory(applicationSupport: support)
        let current = currentBaseDirectory(applicationSupport: support)
        migrateLegacyWorkingCopies(from: legacy, to: current)
        return current
    }()

    /// Today's working-copies root under a given Application Support
    /// directory. Split out from `baseDirectory` so the path itself — no
    /// `Convivy` component, per `deck/specs/running-deck-as-someone-else`
    /// §"The defaults name Convivy" — is checkable without evaluating the
    /// real static, which would touch the real Application Support directory
    /// (and, via migration, real working copies) as a side effect of the
    /// check.
    static func currentBaseDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Deck/working-copies", isDirectory: true)
    }

    /// Where working copies lived before this change. Kept as its own
    /// function, alongside `currentBaseDirectory`, for the same testability
    /// reason.
    static func legacyBaseDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Convivy/Deck/working-copies", isDirectory: true)
    }

    // MARK: - Migration

    /// Moves every file under a retired working-copies root into today's,
    /// without ever overwriting something already at the destination.
    /// Runs once, from `baseDirectory`'s lazy initializer, so app launch pays
    /// for it at most once per legacy file — a no-op every time after.
    ///
    /// A MIGRATION, NOT A DISPOSABLE-CACHE RESET, because not everything under
    /// here is disposable. A fetched read copy and a rendered `editor.html`
    /// are regenerated on next open and would cost nothing to strand — but a
    /// KB document's `.draft.md` (`KnowledgeBase.saveLocally`) is the ONLY
    /// copy of an edit Deck has not sent anywhere: phase 1 saves locally
    /// rather than submitting, because `kb_propose` doesn't exist yet
    /// (phase 4). Starting clean at the new path would silently lose a
    /// document someone edited and has not pushed, which is the outcome this
    /// spec calls out by name as the wrong one. Migrating the whole tree,
    /// rather than drafts alone, is simpler and no costlier — the tree is
    /// small, and telling a draft from a disposable copy would need its own
    /// logic for a distinction that does not save any work here.
    ///
    /// NEVER OVERWRITES. A destination file already present wins; the legacy
    /// copy is left exactly where it was rather than moved over it or
    /// deleted. Two working-copy directories are never expected to collide —
    /// this migration should only ever run once, into an otherwise-empty
    /// destination — but a reader who has already opened a document at the
    /// new path before this runs (a debug build, a manual copy) must not have
    /// that newer copy clobbered by an older one arriving late.
    ///
    /// Legacy directories left empty by the move are pruned, stopping at
    /// `legacy` itself — this never reaches for its parent
    /// (`Application Support/Convivy`), which may hold another product's data.
    @discardableResult
    static func migrateLegacyWorkingCopies(
        from legacy: URL, to current: URL, fileManager: FileManager = .default
    ) -> Int {
        guard fileManager.fileExists(atPath: legacy.path) else { return 0 }
        var migratedCount = 0
        migrateContents(from: legacy, to: current, fileManager: fileManager, migratedCount: &migratedCount)
        pruneIfEmpty(legacy, fileManager: fileManager)
        return migratedCount
    }

    private static func migrateContents(
        from legacy: URL, to current: URL, fileManager: FileManager, migratedCount: inout Int
    ) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: legacy, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries {
            let destination = current.appendingPathComponent(entry.lastPathComponent)
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                migrateContents(from: entry, to: destination, fileManager: fileManager,
                                migratedCount: &migratedCount)
                pruneIfEmpty(entry, fileManager: fileManager)
            } else if !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)
                if (try? fileManager.moveItem(at: entry, to: destination)) != nil {
                    migratedCount += 1
                }
            }
            // A destination file that already exists wins; `entry` is left
            // where it was rather than overwritten or deleted.
        }
    }

    /// Removes `directory` if the migration left it with nothing in it.
    /// Never climbs to a parent — see the caller's doc comment.
    private static func pruneIfEmpty(_ directory: URL, fileManager: FileManager) {
        guard let remaining = try? fileManager.contentsOfDirectory(atPath: directory.path),
              remaining.isEmpty else { return }
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Fetch

    /// Fetches a KB doc from the Library's `GET /reference/documents/{doc_id}`
    /// and writes a working copy. Returns the local URL of the written file.
    ///
    /// USED TO GO THROUGH `agentctl kb checkout`, WHICH TOOK A LEASE THIS
    /// READER NEVER WANTED (`deck/decisions/0002`, the issue this shipped
    /// under). That verb took a four-hour write lease as a side effect of
    /// returning content, and the viewer only reads, so every document opened
    /// here left a lease behind that a detached `kb release` then raced to
    /// drop. The Library's reference route is a read with nothing to
    /// release — no checkout, no detached cleanup, no race.
    ///
    /// **DROPS `content_sha`, AND THAT IS A REAL GAP, NAMED RATHER THAN
    /// PAPERED OVER.** `kb checkout`'s sha is `sha256` over the whole file
    /// FastAPI's `{doc_id:path}` route serves under `/reference/documents`
    /// returns a `body` field the Library's own indexer already split out of
    /// its source file's frontmatter — never the raw bytes `kb checkout`
    /// hashed, and not reconstructable to match it (frontmatter formatting
    /// isn't preserved on the way into the index). There is no equivalent
    /// field to carry forward. This was already a dead read in this specific
    /// function, though: the sha extracted here was validated and then never
    /// used — nothing downstream of `fetch(target:kbId:)` persisted or
    /// consumed it. The sha phase 4's `kb_propose` will need against a base
    /// comes from the editor's OWN checkout in `KnowledgeBase.swift`, an
    /// unrelated call this change does not touch.
    ///
    /// **THE TRANSPORT IS A NAMED STOPGAP, NOT ADR-0002's WIRE.** The decision
    /// specifies one unix socket per Keel endpoint, an `{ok, result}` /
    /// `{ok: false, error: {kind, message, detail}}` envelope, and a nine-kind
    /// error taxonomy — none of which exists yet, and none of which the
    /// running Library speaks today: measured against the live service, it
    /// answers over a loopback TCP port (`127.0.0.1:8100`, `LIBRARY_BASE_URL`
    /// in `convivy-orient/library_client.py`) with a plain JSON body and an
    /// HTTP status code per `platform/contracts/library-protocol` §8 — 400,
    /// 401, 403, 404, 409, 422. Building `FetchError` around the future
    /// taxonomy now would invent a client for a protocol nothing serves,
    /// which is the exact second-vocabulary failure the decision exists to
    /// prevent. So this reaches the loopback port the same way every other
    /// verb in this file reaches the mini — a command run over the existing
    /// ssh ControlMaster, its stdout parsed here — and reads today's actual
    /// status/body shape (`libraryDocumentRemoteCommand`,
    /// `splitCurlStatusResponse`). The seam for the real client is this
    /// function and `libraryDocumentArguments` beside it: when the typed wire
    /// exists, both are replaced wholesale rather than grown into it.
    ///
    /// **THE CREDENTIAL IS BORROWED, NOT MINTED FOR DECK.** No Library token
    /// is provisioned for Deck yet (Phase 5 mints per-client ones). Until
    /// then this sends the `agent-platform` bearer already used for other
    /// loopback-only reads on the mini — same token, same 0600 file,
    /// `agent-platform/lib/agent-platform/signal_client.py` is the precedent.
    /// The Library's audit trail records these reads as `agent-platform`
    /// rather than as Deck, which is the concrete cost of not building the
    /// real client here.
    ///
    /// **THAT TOKEN NEVER REACHES CURL'S ARGV ON THE MINI.**
    /// `libraryDocumentRemoteCommand` reads it into curl's config over stdin
    /// rather than a `-H` argument — see that function's doc for why the
    /// difference matters on a multi-tenant box where argv is world-readable
    /// through `ps`.
    static func fetch(target: SSHTarget, kbId: String) throws -> URL {
        let raw = try LibraryTransportDispatch.run(
            target: target, argv: libraryDocumentArguments(target: target, kbId: kbId))
        let content = try libraryDocumentContent(from: raw, kbId: kbId)

        let dir = try directory(forKBId: kbId)

        // Preserve the last segment as the filename (with .md) so the viewer
        // can use the extension for type detection.
        let filename = "\(String(kbId.split(separator: "/").last ?? "document")).md"
        let contentURL = dir.appendingPathComponent(filename)
        try content.write(to: contentURL, atomically: true, encoding: .utf8)
        return contentURL
    }

    /// Turns `libraryDocumentRemoteCommand`'s raw stdout into a document's
    /// body text, or the `FetchError` it means. Pure — split out of `fetch`
    /// so every failure mode is pinned by a test with no ssh round trip and
    /// no disk write.
    static func libraryDocumentContent(from raw: Data, kbId: String) throws -> String {
        guard let (status, body) = splitCurlStatusResponse(raw) else {
            throw FetchError.unexpectedResponse(String(data: raw, encoding: .utf8) ?? "(binary)")
        }
        guard status == 200 else {
            if status == 404 { throw FetchError.documentNotFound(kbId) }
            throw FetchError.libraryRefused(status: status,
                                            body: String(data: body, encoding: .utf8) ?? "(binary)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let content = root["body"] as? String else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        return content
    }

    /// The fields `BeadProgressModel` reads off a Reference Room document —
    /// same route, same response, as `fetch(target:kbId:)`, and the same
    /// "a field costs itself" posture: every field here is independently
    /// optional, degrading rather than failing the whole read.
    struct LibraryDocumentMetadata: Equatable {
        let title: String?
        let lastReviewed: String?
    }

    /// Reads a Reference Room document's metadata without writing a working
    /// copy — the rail's bead-progress pane needs `title`/`last_reviewed`,
    /// not the body, and has no working-copy directory of its own to write
    /// into.
    ///
    /// **A SECOND ROUND TRIP FROM `fetch(target:kbId:)`, not a shared one —
    /// deliberately.** The two serve different callers on different
    /// schedules: `fetch` runs once, on the reader's own click to open a
    /// bead in the viewer; this runs on `BeadProgressModel`'s slow timer,
    /// polling metadata whether or not anyone has opened the bead this
    /// launch. Sharing one cached response between them would mean the pane
    /// either forces a fetch on every launch before the reader has asked
    /// for anything, or the viewer opens a bead with metadata that is
    /// minutes stale — a stopgap transport's day, not a large cost, so this
    /// keeps the two reads independent rather than inventing a cache to
    /// dodge it.
    static func fetchDocumentMetadata(target: SSHTarget, kbId: String) throws -> LibraryDocumentMetadata {
        let raw = try LibraryTransportDispatch.run(
            target: target, argv: libraryDocumentArguments(target: target, kbId: kbId))
        return try libraryDocumentMetadata(from: raw, kbId: kbId)
    }

    /// Turns `libraryDocumentRemoteCommand`'s raw stdout into a document's
    /// metadata, or the `FetchError` it means — pure, mirroring
    /// `libraryDocumentContent`'s split for the same testability reason.
    static func libraryDocumentMetadata(from raw: Data, kbId: String) throws -> LibraryDocumentMetadata {
        guard let (status, body) = splitCurlStatusResponse(raw) else {
            throw FetchError.unexpectedResponse(String(data: raw, encoding: .utf8) ?? "(binary)")
        }
        guard status == 200 else {
            if status == 404 { throw FetchError.documentNotFound(kbId) }
            throw FetchError.libraryRefused(status: status,
                                            body: String(data: body, encoding: .utf8) ?? "(binary)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw FetchError.unexpectedResponse(String(data: body, encoding: .utf8) ?? "(binary)")
        }
        return LibraryDocumentMetadata(title: root["title"] as? String,
                                       lastReviewed: root["last_reviewed"] as? String)
    }

    /// The working-copy directory for a KB document, created if absent.
    ///
    /// NESTED PER SEGMENT, FOR THE REASON THE PATH ONE IS. This had the same
    /// collision the path branch had before #74: flattening `/` to `-` sent
    /// `a-b/c/d` and `a/b-c/d` to one directory, so two documents shared a
    /// working copy and whichever was opened second overwrote the first. A doc
    /// id is `[a-z0-9-]` in three segments, which is exactly the alphabet where
    /// a hyphen and a separator are interchangeable, so the narrower input made
    /// this MORE reachable than the path case rather than less.
    ///
    /// The `.` and `..` guard is shared with the path side rather than skipped
    /// on the argument that a validated doc id cannot contain them. That
    /// argument — this input is narrower, so the guard is unnecessary — is what
    /// left the collision here after #74 fixed the identical one next door.
    ///
    /// **The injectivity depends on `validateKBId` keeping ids lowercase.**
    /// APFS is case-insensitive, so `Deck/Specs/x` and `deck/specs/x` would
    /// land in one directory — two distinct ids, one working copy, which is the
    /// collision above wearing a different hat. `[a-z0-9-]` is what makes that
    /// unreachable, so widening the validator to admit uppercase is a change
    /// to THIS function's correctness even though it does not touch it. Named
    /// by `deck-reviewer`, who noted the code relied on it and said so nowhere.
    static func directory(forKBId kbId: String) throws -> URL {
        var dir = baseDirectory.appendingPathComponent("kb", isDirectory: true)
        for component in try pathComponents(forAbsolutePath: kbId) {
            dir = dir.appendingPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try claim(dir, forSource: "kb:\(kbId)")
        return dir
    }

    /// Fetches a file from the mini with `session-agent read-file` and writes a
    /// working copy.
    ///
    /// Returns the local URL of the written file. The original filename is
    /// preserved so the extension is available for type detection.
    ///
    /// The path is validated twice, in two different places, and only the
    /// second one is a boundary. `DeckOpenRef.validatePath` runs here on the
    /// laptop and is syntactic: it rejects a relative path, a `..`, a control
    /// character. `read-file` runs on the mini and resolves the path one
    /// component at a time as it opens it, refusing a symlink at any component,
    /// which is the check that has to happen where the file actually is. See
    /// `readFileArguments`.
    ///
    /// `classifyMissingCommand: false` for the reason `writeBack` passes it:
    /// this verb names a path, and a path that does not exist reports "No such
    /// file" too. Reading that as `notInstalled` would send someone who opened
    /// a deleted document off to run the installer.
    static func fetch(target: SSHTarget, absolutePath: String) throws -> URL {
        let data = try SessionAgent.run(readFileArguments(target: target, path: absolutePath),
                                        classifyMissingCommand: false)

        let filename = (absolutePath as NSString).lastPathComponent
        let dir = try directory(forAbsolutePath: absolutePath)
        let fileURL = dir.appendingPathComponent(filename)
        try data.write(to: fileURL)
        return fileURL
    }

    /// The path components a remote path's working-copy directory nests under.
    ///
    /// ONE PATH, ONE DIRECTORY, AND NO TWO PATHS SHARING ONE. Flattening the
    /// path into a single name is what broke that. Replacing `/` with `-` sent
    /// `$HOME/a/b.md` and `$HOME/a-b.md` to the same name,
    /// so two files shared a directory: whichever opened second overwrote the
    /// first's copy, and the reader got the other file's contents under this
    /// file's name. With the editor, a save then writes those contents to this
    /// path. Found by `deck-security-reviewer` on #74; the collision predates
    /// the editor and reached the read-only viewer through `fetch`.
    ///
    /// Escaping the hyphen before the replacement looks like the fix and is
    /// not. `-` as `--` leaves `x/-y` and `x-/y` both encoding to `x---y`,
    /// because the escape character and the separator are the same character
    /// and a run of three splits two ways. Caught by the injectivity test on
    /// the first version of this fix.
    ///
    /// So the path is not flattened at all: the directory tree mirrors it, one
    /// component per component. That is injective by construction rather than
    /// by an encoding argument, and it needs no decoder to read.
    ///
    /// `.` and `..` are refused rather than encoded. Every caller today passes
    /// a path `DeckOpenRef.validatePath` has already standardised, so neither
    /// can appear — but this builds a directory Deck then WRITES into, and a
    /// `..` reaching `appendingPathComponent` would climb out of the
    /// working-copy root. A guard costs one comparison.
    static func pathComponents(forAbsolutePath absolutePath: String) throws -> [String] {
        let components = absolutePath.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw FetchError.unusablePath(absolutePath)
        }
        return components
    }

    /// Writes a generated editor page for a KB document and returns its URL.
    @discardableResult
    static func writeEditorPage(_ html: String, forKBId kbId: String) throws -> URL {
        let pageURL = try directory(forKBId: kbId).appendingPathComponent(editorPageName)
        try html.write(to: pageURL, atomically: true, encoding: .utf8)
        return pageURL
    }

    /// The working-copy directory for a remote path, created if absent.
    ///
    /// Split out of `fetch` because the editor writes a generated page into the
    /// same directory without fetching the file: `--render-editor` inlines the
    /// source into the page on the mini, so a `cat` alongside it would be a
    /// second round trip for bytes Deck already has.
    static func directory(forAbsolutePath absolutePath: String) throws -> URL {
        var dir = baseDirectory.appendingPathComponent("path", isDirectory: true)
        for component in try pathComponents(forAbsolutePath: absolutePath) {
            dir = dir.appendingPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try claim(dir, forSource: "path:\(absolutePath)")
        return dir
    }

    /// The filename every generated editor page is written under.
    ///
    /// One name for all of them, because a working-copy directory holds exactly
    /// one remote file and re-rendering should replace the previous page rather
    /// than accumulate a directory of stale ones the server would still serve.
    static let editorPageName = "editor.html"

    /// Writes a generated editor page into the working-copy directory for
    /// `absolutePath` and returns its local URL.
    ///
    /// The loopback server serves it from there. Nothing else in Deck reads it.
    @discardableResult
    static func writeEditorPage(_ html: String, forAbsolutePath absolutePath: String) throws -> URL {
        let dir = try directory(forAbsolutePath: absolutePath)
        let pageURL = dir.appendingPathComponent(editorPageName)
        try html.write(to: pageURL, atomically: true, encoding: .utf8)
        return pageURL
    }

    // MARK: - Write back

    /// Writes `source` back to `path` on the mini with `session-agent
    /// write-file`, atomically.
    ///
    /// THE STAGE-AND-RENAME MOVED TO THE MINI, AND THAT IS THE POINT. Deck used
    /// to compose the write itself — `cat > <staged> && mv -f <staged> <path>`,
    /// with the staging path derived by taking the target's parent directory
    /// from the path STRING. The atomicity was real and is unchanged; the
    /// containment was not there at all. Deck's check ran on the laptop against
    /// a string, and both the staged open and the rename then happened on the
    /// mini against whatever that string resolved to there — so a symlinked
    /// PARENT directory under an allowed root redirected the write out of the
    /// root entirely, and Deck had no way to see it. `write-file` stages and
    /// renames inside a directory it has already opened one component at a
    /// time with `O_NOFOLLOW`, so the directory the bytes land in is the
    /// directory that was checked, with no window between the two.
    ///
    /// The document goes over stdin rather than argv for the reason every other
    /// body does: argv is visible in the remote process table, and this one is
    /// the user's document.
    ///
    /// `classifyMissingCommand: false` because this verb names a path rather
    /// than only a remote binary — a write into a directory that has been
    /// deleted reports "No such file" as well, and the installer has nothing to
    /// do with that. See `SessionAgent.run`.
    static func writeBack(target: SSHTarget, source: String, toAbsolutePath path: String) throws {
        try SessionAgent.run(
            writeFileArguments(target: target, path: path),
            stdin: source,
            classifyMissingCommand: false)
    }

    // MARK: - Library reference read (deck/decisions/0002, stopgap transport)

    /// The bearer credential Deck presents to the Library, read from disk on
    /// the MINI (never shipped in Deck's source or its binary, never crosses
    /// the network beyond loopback) — see `fetch(target:kbId:)`'s "CREDENTIAL
    /// IS BORROWED" note for why this is `agent-platform`'s and not Deck's own.
    static let libraryTokenFile = "~/.orient-control/agent-platform-token"

    /// The bearer credential Deck presents for the ONE write that needs a
    /// human-reserved capability: approving an epic (`epic.approve` plus
    /// `course.write`, `POST /items/{id}/approve`) — `libraryTokenFile` above
    /// resolves kind `agent` and cannot hold either, by design
    /// (`platform/decisions/0087`).
    ///
    /// **A SAME-DIRECTORY TRAP.** `~/.orient-control/library-client-token`
    /// sits beside this file, also resolves `approved_client` with the
    /// identical capability set — but as actor `orient`. Presenting it here
    /// would not refuse: the approval would succeed, silently and
    /// permanently attributed to the wrong client. Confirmed against the
    /// running Library, 2026-09-22: `deck-library-token` answers `GET
    /// /whoami` as `{"actor":"deck",...}`, `library-client-token` as
    /// `{"actor":"orient",...}`, both `"kind":"approved_client"`. Never
    /// widen this constant's use beyond the approval write — every other
    /// route keeps reading `libraryTokenFile`, unchanged by this file's
    /// addition.
    static let libraryApprovalTokenFile = "~/.orient-control/deck-library-token"

    /// The Library's own base-URL convention, resolved on the mini rather than
    /// hardcoded here: `LIBRARY_BASE_URL`, defaulting to the loopback port its
    /// existing clients default to (`convivy-orient/library_client.py`). A
    /// future redeploy that moves the port, or the Library's move to the Mac
    /// Studio the decision names, changes this on the mini and needs no Deck
    /// release to follow it.
    static let libraryBaseURLExpression = "${LIBRARY_BASE_URL:-http://127.0.0.1:8100}"

    /// The remote shell command that reads one Reference Room document.
    ///
    /// `-w '\n%{http_code}'` APPENDS THE STATUS AFTER A NEWLINE CURL ITSELF
    /// ADDS, rather than failing the transfer on a non-2xx (no `-f`) — a 404
    /// or a 403 is the Library answering, not ssh or curl failing, and this
    /// function's caller needs the status to tell those apart. See
    /// `splitCurlStatusResponse`.
    ///
    /// `kbId` IS EMBEDDED UNQUOTED INSIDE A DOUBLE-QUOTED URL, and that is
    /// safe rather than careless: `DeckOpenRef.validateKBId` already
    /// constrains it to `[a-z0-9-/]` before this is ever called, a charset
    /// containing none of `$` `` ` `` `"` `\` — the four characters double
    /// quotes do not neutralize. Single-quoting the way `shellQuotePath` does
    /// elsewhere is not available here: this whole command is one
    /// double-quoted string so `${LIBRARY_BASE_URL:-…}` still expands, and a
    /// single quote is a plain character rather than an escape once already
    /// inside double quotes.
    ///
    /// THE BEARER TOKEN IS READ INTO CURL'S CONFIG FILE OVER ITS OWN STDIN
    /// (`--config -`), NEVER AS A `-H` ARGUMENT. The header carrying it used
    /// to be built as `-H "Authorization: Bearer $(cat …)"` — the `$(…)`
    /// still ran on the mini, so the token was never in Deck's process or on
    /// the wire before it reached there, but the substitution's RESULT then
    /// became a literal element of curl's own argv on the mini, visible to
    /// every account on that box for the life of the request via `ps`. Same
    /// process-table exposure `writeBack`'s doc comment names for a document,
    /// and worse here because a credential is worth more to whoever reads it.
    /// `--config -` reads directives from stdin instead of argv, and the
    /// heredoc supplying that stdin is expanded by the REMOTE shell before
    /// curl ever sees it — the command substitution still runs on the mini,
    /// reading the same 0600 file, but its output now goes straight into a
    /// pipe curl reads from rather than becoming a token curl's own argv
    /// carries. Verified against the running Library on 2026-08-21: `ps`
    /// taken while a request was in flight showed curl's argv ending
    /// `--config - <url>`, no `Authorization` and no token anywhere in it.
    ///
    /// The heredoc's `EOF` marker is UNQUOTED (`<<EOF`, not `<<'EOF'`) on
    /// purpose — a quoted marker turns off exactly the expansion this needs,
    /// leaving curl to read the literal text `$(cat …)` as its header value
    /// instead of the token.
    static func libraryDocumentRemoteCommand(kbId: String) -> String {
        "curl -sS -w '\\n%{http_code}' " +
        "-H 'Library-Protocol: 1' " +
        "--config - " +
        "\"\(libraryBaseURLExpression)/reference/documents/\(kbId)\" " +
        "<<EOF\n" +
        "header = \"Authorization: Bearer $(cat \(libraryTokenFile) 2>/dev/null)\"\n" +
        "EOF"
    }

    /// ssh argv that runs `libraryDocumentRemoteCommand` on the mini.
    ///
    /// Uses the same ControlMaster socket every other verb uses, so this
    /// multiplexes onto an existing connection rather than opening a new one.
    static func libraryDocumentArguments(
        target: SSHTarget,
        kbId: String,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            libraryDocumentRemoteCommand(kbId: kbId),
        ], home: home)
    }

    /// Splits `curl -w '\n%{http_code}'` output into its HTTP status and body.
    ///
    /// SPLITS ON THE LAST NEWLINE, NOT THE FIRST. The status curl appends is
    /// the only thing guaranteed to follow the final `\n`; the body is JSON
    /// and — while the Library's own encoder does not pretty-print it — this
    /// function makes no assumption about that and must not break if it ever
    /// does. `nil` means the output does not have this shape at all (an empty
    /// response, or a transport-level failure that never reached curl's own
    /// write-out step), which is `fetch`'s cue to report the whole thing as
    /// unexpected rather than misreading part of it as a status code.
    static func splitCurlStatusResponse(_ data: Data) -> (status: Int, body: Data)? {
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return nil }
        let statusText = String(data: data[data.index(after: lastNewline)...], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let statusText, let status = Int(statusText) else { return nil }
        return (status, data[..<lastNewline])
    }

    // MARK: - argv

    /// ssh argv for `session-agent read-file <path>`.
    ///
    /// THIS REPLACED `cat <path>`, AND THE DIFFERENCE IS WHERE THE CHECK RUNS.
    /// `cat` opens whatever the path resolves to on the mini, and the only
    /// containment in front of it was `DeckOpenRef.validatePath` — a string
    /// check running on the laptop, on a path the mini resolves. A symlink
    /// under an allowed root on the mini, pointing anywhere, passed that check
    /// and was followed. `read-file` walks the path one component at a time
    /// with `O_NOFOLLOW`, refusing a symlink in the SAME syscall that would
    /// have descended through it, and admits a path only if it lands inside the
    /// invoking account's home or its Claude scratchpad. Deck's own check stays
    /// as a syntactic pre-filter; the mini is the boundary.
    ///
    /// The verb's stdout is raw bytes, not JSON, so this is a drop-in for what
    /// `cat` returned — a refusal goes to stderr and exits non-zero, and
    /// nothing reaches stdout either way.
    ///
    /// The path is single-quoted for the remote shell. ssh joins its trailing
    /// argv items with spaces before the remote shell sees them, so a bare path
    /// with spaces or punctuation would be re-split into multiple tokens.
    /// Single-quoting prevents that: any embedded `'` is escaped as `'\''`.
    static func readFileArguments(
        target: SSHTarget,
        path: String,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            SessionAgent.remoteCommand, "read-file", SessionAgent.shellQuotePath(path),
        ], home: home)
    }

    /// ssh argv for `session-agent write-file <path>`, content on stdin.
    ///
    /// ONE ARGV ITEM PER TOKEN, NOT ONE COMPOSED SHELL LINE. The write this
    /// replaced was a single string — `cat > <staged> && mv -f <staged>
    /// <path>` — because two commands had to be sequenced on the remote side.
    /// One verb needs no sequencing, so there is no shell line to compose and
    /// no second path for Deck to derive; `write-file` stages and renames
    /// inside the directory it already opened, and Deck names only the target.
    ///
    /// The path is single-quoted for the same reason `readFileArguments`
    /// quotes it: ssh re-joins these items with spaces and the remote shell
    /// splits the result again.
    static func writeFileArguments(
        target: SSHTarget,
        path: String,
        controlPath: String = defaultControlPath(),
        home: String = NSHomeDirectory()
    ) -> [String] {
        withDeckIdentity([
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "\(target.user)@\(target.host)",
            SessionAgent.remoteCommand, "write-file", SessionAgent.shellQuotePath(path),
        ], home: home)
    }
}
