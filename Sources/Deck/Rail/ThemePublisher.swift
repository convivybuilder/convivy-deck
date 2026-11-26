import Foundation

/// Publishes Deck's theme catalog and each project's resolved theme to the
/// Library, so Orient can draw a project's site in that project's own Deck
/// colour — CQ·211.
///
/// ASSUMES ONE LIBRARY. Convivy runs a single Library instance, reached over
/// ssh to whichever host it is dialled through — `WorkingCopyStore
/// .libraryBaseURLExpression`'s own `127.0.0.1:8100` is loopback ON THAT
/// HOST, not a fleet-wide address. `lastSentDigest`/`lastSentProjectThemes`
/// below are tracked for this whole launch, not per host, so on a
/// multi-host rail only the first host `RailStateModel.refresh()` hears
/// from each tick attempts the write — correct for the one-Library
/// deployment this ships to, and costs nothing on the common single-host
/// one.
///
/// ONE INSTANCE PER APP RUN (`shared`). What makes a refusal never loop is
/// tracking what this launch has already ATTEMPTED — sent, whether or not
/// the Library accepted it — rather than what it has confirmed landed: an
/// attempted value is not attempted again until it changes. See
/// `publishSync`.
final class ThemePublisher: @unchecked Sendable {
    static let shared = ThemePublisher()

    /// Guards every mutable property below — this type is called from
    /// `RailStateModel`'s per-host poll tasks, which run concurrently with
    /// each other, the same reason `TransportLog` and
    /// `LibraryHostConnectionPool` take a lock of their own.
    private let lock = NSLock()
    private var lastSentDigest: String?
    private var lastSentProjectThemes: [String: ProjectThemeResolution.Resolved] = [:]
    private var loggedCauses: Set<String> = []

    /// The write seam — a test substitutes a fake so nothing here reaches a
    /// real ssh process, the same discipline `RailStateModel.fetchStates`
    /// and friends already follow.
    var putPalette: (SSHTarget, String, [String: Any]) throws -> Void = { target, catalog, themes in
        try LibraryClient.putThemePalette(target: target, catalog: catalog, themes: themes)
    }
    var putProjectTheme: (SSHTarget, String, String, String) throws -> Void = { target, slug, theme, source in
        try LibraryClient.putProjectTheme(target: target, slug: slug, theme: theme, source: source)
    }

    /// `.shared` in production; a test substitutes its own so a run never
    /// touches Application Support.
    var transportLog: TransportLog = .shared

    /// Fire-and-forget, off the main actor — `RailStateModel.refresh()`'s
    /// per-host loop is the only production caller, right after it merges
    /// that host's served crews. Never blocks the rail: the writes below
    /// run inside the detached task, never on the caller's own thread.
    func publish(target: SSHTarget, servedCrews crews: [ServedCrew]) {
        Task.detached { [self] in
            self.publishSync(target: target, servedCrews: crews)
        }
    }

    /// The synchronous form `publish` wraps — a test calls this directly so
    /// the dedup and logging behaviour is deterministic with no `Task` to
    /// await.
    func publishSync(target: SSHTarget, servedCrews crews: [ServedCrew]) {
        publishPaletteIfChanged(target: target)
        publishProjectThemesIfChanged(target: target, crews: crews)
    }

    private func publishPaletteIfChanged(target: SSHTarget) {
        let themes = ThemeLibraryPalette.themes()
        let digest = ThemeLibraryPalette.digest(themes)
        lock.lock()
        let alreadyAttempted = lastSentDigest == digest
        lock.unlock()
        guard !alreadyAttempted else { return }

        do {
            try putPalette(target, ThemeLibraryPalette.catalogLabel, themes)
            lock.lock(); lastSentDigest = digest; lock.unlock()
        } catch LibraryClient.FetchError.libraryRefused(let status, _) {
            // A refusal is still a settled answer about THIS digest — mark
            // it attempted so the same bytes are never retried, per the
            // issue body's "doesn't retry in a loop". The catalog is a pure
            // function of compiled-in constants, so the digest can only
            // change across a build, which is exactly when retrying again
            // makes sense.
            lock.lock(); lastSentDigest = digest; lock.unlock()
            logRefusalOnce(cause: "theme-palette-refused status=\(status)", target: target)
        } catch {
            // A transport failure (host unreachable, no Library listening)
            // says nothing about this digest — NOT marked attempted, so the
            // next served-crews poll tries again. The host being briefly
            // unreachable is not the Library refusing.
        }
    }

    private func publishProjectThemesIfChanged(target: SSHTarget, crews: [ServedCrew]) {
        for resolved in ProjectThemeResolution.resolved(from: crews) {
            lock.lock()
            let unchanged = lastSentProjectThemes[resolved.slug] == resolved
            lock.unlock()
            guard !unchanged else { continue }

            do {
                try putProjectTheme(target, resolved.slug, resolved.theme, resolved.source)
                lock.lock(); lastSentProjectThemes[resolved.slug] = resolved; lock.unlock()
            } catch LibraryClient.FetchError.libraryRefused(let status, _) {
                // Same "a refusal is a settled answer about this value"
                // reasoning as the palette's — a 400 here means not
                // published, never proof the slug does not exist (comment
                // 7441), so there is nothing further to learn by resending
                // the identical theme/source pair.
                lock.lock(); lastSentProjectThemes[resolved.slug] = resolved; lock.unlock()
                logRefusalOnce(cause: "theme-project-refused status=\(status) project=\(resolved.slug)", target: target)
            } catch {
                // Transport failure — same no-mark, retry-next-tick posture
                // as the palette's.
            }
        }
    }

    /// `TransportLog` carries no content, only diagnostic metadata (see its
    /// own doc), and `cause` here is built entirely from a status code and
    /// a project slug Deck itself resolved — never a Library response body.
    private func logRefusalOnce(cause: String, target: SSHTarget) {
        lock.lock()
        let alreadyLogged = loggedCauses.contains(cause)
        if !alreadyLogged { loggedCauses.insert(cause) }
        lock.unlock()
        guard !alreadyLogged else { return }
        transportLog.append(host: TransportLog.hostLabel(target: target), event: cause)
    }
}
