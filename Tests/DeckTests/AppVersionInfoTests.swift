import XCTest
@testable import Deck

/// `AppVersionInfo` reads `CFBundleShortVersionString` and `CFBundleVersion`
/// back from an injected dictionary rather than `Bundle.main`, so the missing-
/// key path — the one `swift test` actually takes, since the suite runs the
/// bare executable and never a `.app` bundle — is directly reachable here
/// rather than only exercisable by launching a real bundle.
final class AppVersionInfoTests: XCTestCase {
    func testBothKeysPresent() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "412",
        ]
        XCTAssertEqual(AppVersionInfo.displayString(from: info), "Version 0.1.0 (412)")
    }

    func testBothKeysMissing() {
        XCTAssertEqual(AppVersionInfo.displayString(from: [:]), "Version unknown (build unknown)")
    }

    func testBuildNumberMissing() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0"]
        XCTAssertEqual(AppVersionInfo.displayString(from: info), "Version 0.1.0 (build unknown)")
    }

    func testMarketingVersionMissing() {
        let info: [String: Any] = ["CFBundleVersion": "412"]
        XCTAssertEqual(AppVersionInfo.displayString(from: info), "Version unknown (412)")
    }

    func testEmptyStringValuesAreTreatedAsMissing() {
        let info: [String: Any] = ["CFBundleShortVersionString": "", "CFBundleVersion": ""]
        XCTAssertEqual(AppVersionInfo.displayString(from: info), "Version unknown (build unknown)")
    }
}
