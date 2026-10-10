import XCTest
@testable import Deck

/// `ScreenSharingLink.url(forAddress:)` — the `vnc://` URL behind a logged-out
/// alert's Open Screen Sharing button (CQ·140).
final class ScreenSharingLinkTests: XCTestCase {
    func testAHostnameFormsAVNCURLWithTheHostnameAsItsHost() {
        let tailnetHost = "macmini.example.com"
        let url = ScreenSharingLink.url(forAddress: tailnetHost)

        XCTAssertEqual(url?.scheme, "vnc")
        XCTAssertEqual(url?.host, tailnetHost)
        XCTAssertEqual(url?.absoluteString, "vnc://\(tailnetHost)")
    }

    func testAnIPAddressFormsAVNCURLWithTheAddressAsItsHost() {
        let url = ScreenSharingLink.url(forAddress: "10.0.0.9")

        XCTAssertEqual(url?.scheme, "vnc")
        XCTAssertEqual(url?.host, "10.0.0.9")
        XCTAssertEqual(url?.absoluteString, "vnc://10.0.0.9")
    }

    /// A leading `-` reads as an option flag, the same refusal `validateHostAddress`
    /// makes for the ssh destination. Forming a URL from it would hand Screen
    /// Sharing a host that is really a flag.
    func testAnAddressWithALeadingDashFormsNoURL() {
        XCTAssertNil(ScreenSharingLink.url(forAddress: "-oProxyCommand=x"))
    }

    func testAnEmptyAddressFormsNoURL() {
        XCTAssertNil(ScreenSharingLink.url(forAddress: ""))
    }

    /// A space is outside the address charset, so no `vnc` host can carry it.
    func testAnAddressWithASpaceFormsNoURL() {
        XCTAssertNil(ScreenSharingLink.url(forAddress: "macmini tail"))
    }
}
