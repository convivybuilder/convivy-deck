import Foundation

/// The `NOTICE` and `LICENSE` files `Scripts/make-app.sh` copies into a bundle's
/// `Contents/Resources`, read back so Settings can show them.
///
/// WHY THIS EXISTS. Apache-2.0 section 4(d) asks that the NOTICE content appear
/// "wherever such third-party notices normally appear". On a Mac application that
/// is somewhere a person can read it, and a file inside the bundle is not that
/// for anyone who has not gone looking with Show Package Contents.
///
/// READ FROM THE BUNDLE, never from a repository path. The person this serves is
/// running a shipped bundle with no checkout, where a source path would resolve
/// on a developer's machine and nowhere else.
///
/// The text is reproduced as the files hold it. Nothing here summarises or
/// rewords either file, because a paraphrase of the licence is worse than no
/// text at all.
struct LicenceNotice: Equatable {
    /// The full text of `NOTICE`, or `nil` when the bundle has no readable copy.
    let notice: String?
    /// The full text of `LICENSE`, or `nil` when the bundle has no readable copy.
    let license: String?

    /// The bundle's own copy, read once. A bundle's resources do not change under
    /// a running process, and `SettingsView.body` re-runs on every slider tick.
    static let bundled = LicenceNotice.load(from: Bundle.main)

    static let noticeFileName = "NOTICE"
    static let licenseFileName = "LICENSE"

    /// What Settings says when the bundle carries neither file. A bundle built
    /// before the files were shipped, and the bare executable `swift test` runs,
    /// both land here, so the wording is pinned rather than left as an empty view.
    static let unavailableMessage =
        "This build of Deck does not include its licence files."

    /// What the full-text sheet says in place of a file that is missing while its
    /// sibling is present.
    static func missingFileMessage(_ fileName: String) -> String {
        "This build of Deck does not include \(fileName)."
    }

    /// True when neither file could be read, which is the case the caller
    /// draws `unavailableMessage` for.
    var isEmpty: Bool { notice == nil && license == nil }

    /// One shipped file as the full-text sheet lays it out. `text` is `nil` for a
    /// file the bundle lacks, and the sheet says so under its name.
    struct File: Equatable {
        let name: String
        let text: String?
    }

    /// `NOTICE` then `LICENSE`, in the order the sheet reads them: the short
    /// attribution first, the long text after it.
    var files: [File] {
        [File(name: Self.noticeFileName, text: notice),
         File(name: Self.licenseFileName, text: license)]
    }

    /// What the General tab draws under the version line.
    enum Presentation: Equatable {
        /// Neither file is in the bundle; say so.
        case unavailable
        /// At least one file is. `headline` is `nil` when only `LICENSE` is, and
        /// the button that opens the sheet is offered either way.
        case available(headline: String?)
    }

    var presentation: Presentation {
        isEmpty ? .unavailable : .available(headline: headline)
    }

    /// The leading lines of `NOTICE` up to its first blank line: the product name
    /// and copyright line, in the file's own words. Short enough to sit under the
    /// version line, and a verbatim excerpt rather than a rewrite. `nil` when
    /// `NOTICE` is missing.
    var headline: String? {
        guard let notice else { return nil }
        let lines = notice.trimmingCharacters(in: .newlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
        let block = lines.prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return block.isEmpty ? nil : block.joined(separator: "\n")
    }

    /// Reads both files from `resourceURL`. A file that is absent, unreadable,
    /// not UTF-8, or holds only whitespace reads as `nil`; none of those may
    /// crash or draw a blank view.
    static func load(from resourceURL: URL?) -> LicenceNotice {
        LicenceNotice(notice: read(noticeFileName, in: resourceURL),
                      license: read(licenseFileName, in: resourceURL))
    }

    static func load(from bundle: Bundle) -> LicenceNotice {
        load(from: bundle.resourceURL)
    }

    private static func read(_ name: String, in directory: URL?) -> String? {
        guard let directory,
              let text = try? String(contentsOf: directory.appendingPathComponent(name),
                                     encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }
}
