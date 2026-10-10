import XCTest
import SwiftUI
@testable import Deck

/// The working dot is the Convivy mark, and this pins it to the mark rather than
/// to whatever a `Path` happened to produce.
///
/// WHY THIS IS ASSERTED ON GEOMETRY AND NOT READ OFF A COMMENT. SwiftUI's
/// `addArc(clockwise:)` runs in a y-down space, so which way an arc sweeps is
/// easy to reason about wrongly and impossible to see in a diff — get it
/// backwards and the shape becomes a 90° pie slice instead of a 270° C, which
/// still compiles, still spins, and still looks deliberate.
///
/// The numbers are measured from `convivy-orient/assets/source-mark.png`: the
/// golden region is absent across an 89° span centred on +x, and absent inside
/// the innermost 19.4% of the radius.
final class ConvivyCTests: XCTestCase {

    private let box = CGRect(x: 0, y: 0, width: 100, height: 100)
    private lazy var path = ConvivyC().path(in: box)

    /// A point at `radius` (as a fraction of the outer radius) and `degrees`,
    /// in the same y-down space the shape is drawn in.
    private func point(_ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: 50 + radius * 50 * cos(a), y: 50 + radius * 50 * sin(a))
    }

    func testTheBodySpansTwoHundredAndSeventyDegrees() {
        // Every direction except the wedge is solid at mid-radius. This is the
        // assertion that fails if the arc sweeps the short way: a pie slice
        // would fill the wedge and empty everything else.
        for degrees in stride(from: 50.0, through: 310.0, by: 10.0) {
            XCTAssertTrue(path.contains(point(0.6, degrees)),
                          "the mark is hollow at \(degrees)°, which is its body")
        }
    }

    func testTheWedgeOpensToTheRight() {
        // ±45° about the +x axis, which is where the C's mouth is. Sampled
        // inside the lips rather than on them, since a boundary hit is a
        // rasteriser's business rather than the shape's.
        for degrees in stride(from: -40.0, through: 40.0, by: 10.0) {
            XCTAssertFalse(path.contains(point(0.6, degrees)),
                           "the wedge is filled at \(degrees)°")
        }
    }

    func testTheCentreHoleIsOpen() {
        // The hole is a full circle, not just the wedge's rounded apex — so it
        // has to be empty in the directions where the body is solid.
        for degrees in stride(from: 0.0, to: 360.0, by: 30.0) {
            XCTAssertFalse(path.contains(point(0.10, degrees)),
                           "the centre hole is filled at \(degrees)°")
        }
        // And solid again just outside it, in a direction the wedge does not
        // reach. Without this the test would pass on a shape with no hole at
        // all, or one with a hole swallowing half the mark.
        XCTAssertTrue(path.contains(point(0.30, 180)))
    }

    func testTheMarkIsInscribedInItsFrame() {
        // It has to sit in the same box as the circle and the square it stands
        // beside, or the rail's shapes read at different weights.
        XCTAssertTrue(path.contains(point(0.95, 180)), "the mark stops short of its frame")
        XCTAssertFalse(path.contains(point(1.05, 180)), "the mark overflows its frame")
    }

    func testTheProportionsAreTheBrandsRatherThanRoundNumbers() {
        // Pinned so a later "tidy-up" to 0.2 and 40° has to argue with the
        // measurement rather than slide past review as a rounding.
        XCTAssertEqual(ConvivyC.innerRatio, 0.194, accuracy: 0.001)
        XCTAssertEqual(ConvivyC.halfWedgeDegrees, 45, accuracy: 0.001)
    }
}
