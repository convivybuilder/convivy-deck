import Foundation

/// Reads back the two Info.plist keys `Scripts/write-bundle-metadata.sh`
/// stamps into every bundle: `CFBundleShortVersionString` (the marketing
/// version, from the repo's `VERSION` file) and `CFBundleVersion` (the
/// commit count, monotonic within a branch). Settings shows both, because
/// the build number is what tells two builds of the same marketing version
/// apart — the whole reason it's stamped.
///
/// Takes the source dictionary as a parameter rather than reaching for
/// `Bundle.main` internally, so a test can drive every combination of
/// present/missing keys without a real bundle anywhere near it.
enum AppVersionInfo {
    /// `swift test` runs the bare executable, never a `.app` bundle, so
    /// `Bundle.main.infoDictionary` has neither key on every test run — not
    /// a hypothetical edge case but the path this suite always takes. That
    /// case must not crash, must not invent a version number, and must not
    /// render as blank text that reads like a UI bug; it renders as an
    /// explicit "unknown" so the wording is pinned rather than left to drift.
    static func displayString(from info: [String: Any]) -> String {
        let version = (info["CFBundleShortVersionString"] as? String).flatMap(nonEmpty)
        let build = (info["CFBundleVersion"] as? String).flatMap(nonEmpty)

        switch (version, build) {
        case let (version?, build?):
            return "Version \(version) (\(build))"
        case let (version?, nil):
            return "Version \(version) (build unknown)"
        case let (nil, build?):
            return "Version unknown (\(build))"
        case (nil, nil):
            return "Version unknown (build unknown)"
        }
    }

    static func displayString(from bundle: Bundle) -> String {
        displayString(from: bundle.infoDictionary ?? [:])
    }

    private static func nonEmpty(_ string: String) -> String? {
        string.isEmpty ? nil : string
    }
}
