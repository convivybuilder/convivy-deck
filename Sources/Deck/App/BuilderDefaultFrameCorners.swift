import SwiftUI

/// The rounded interior corners of the Builder Default frame.
///
/// The green frame has four interior corners: where its rail, top bar and Course
/// strip meet the session pane and the cockpit column. Each pane's corner is
/// rounded by painting the ground into the corner, outside an arc. The pane is
/// not clipped, so a web pane or a terminal under it draws unchanged.
enum BuilderDefaultFrameCorners {
    /// The interior radius, in points. The window's outer corner radius is about
    /// 18pt on macOS 27, fitted from the window server's capture of a window's
    /// top-left corner (the edge pixels fit radii of 17 to 19). The interior
    /// radius is half of that.
    static let radius: CGFloat = 9
}

/// The ground in the corner of two frame elements, outside a quarter arc. It
/// is drawn in the top-leading orientation, and a modifier flips it into the
/// corner it sits in.
struct InteriorCornerFillet: Shape {
    /// Arc segments. Enough that the chord error is far under a point at `radius`.
    private static let segments = 16

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height)
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: r, y: 0))
        // The arc is centred on the far corner, (r, r). It runs from (r, 0)
        // round through (r - r/√2, r - r/√2) to (0, r).
        for step in 0...InteriorCornerFillet.segments {
            let angle = (.pi / 2) * (1 - CGFloat(step) / CGFloat(InteriorCornerFillet.segments))
            path.addLine(to: CGPoint(x: r - r * cos(angle), y: r - r * sin(angle)))
        }
        path.closeSubpath()
        return path
    }
}

extension View {
    /// Paints the frame's ground into one corner of this view, so the corner
    /// reads as rounded against the green. `corner` names the corner of this view
    /// that meets the frame. Off under every other preference.
    func builderFrameCorner(_ corner: Alignment, enabled: Bool) -> some View {
        overlay(alignment: corner) {
            if enabled {
                InteriorCornerFillet()
                    .fill(Color(StatusGround.ground))
                    .frame(width: BuilderDefaultFrameCorners.radius,
                           height: BuilderDefaultFrameCorners.radius)
                    .scaleEffect(x: corner.horizontal == .trailing ? -1 : 1,
                                 y: corner.vertical == .bottom ? -1 : 1)
                    .allowsHitTesting(false)
            }
        }
    }
}
