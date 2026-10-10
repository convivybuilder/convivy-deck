import XCTest
@testable import Deck

/// The context meter's line is one point — see `ContextMeterTrack`'s doc
/// comment for why that's thicker than the thinnest line the display can
/// draw.
final class ContextMeterTrackTests: XCTestCase {

    func testTheLineIsOnePoint() {
        XCTAssertEqual(ContextMeterTrack.thickness, 1)
    }
}
