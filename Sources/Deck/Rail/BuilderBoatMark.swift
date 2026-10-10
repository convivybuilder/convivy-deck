import AppKit
import SwiftUI

/// The boat from the convivybuilder GitHub organisation's avatar, which
/// Shipwright drew, shown in the blank band at the top of the rail under
/// Builder Default (`RailView.topInset`).
///
/// THE BOAT ALONE, ON THE RAIL'S OWN GROUND. Shipwright drew the avatar on
/// `#22382c`, which is `StatusGround.ground`, so the square adds nothing but a
/// possible faint edge where colour management moves it off the window's
/// ground. The asset below is the avatar's boat (source pixels x 73–404,
/// y 108–318 of 460) with that ground un-mixed to transparent, so the hull
/// stripe and the gap above the runner are holes. It is 88×56 pixels, four
/// times the 22×14pt the band draws it at.
///
/// EMBEDDED, NOT A RESOURCE. The `Deck` target declares no resources and
/// `make-app.sh` copies only the binary into the bundle, so a SwiftPM resource
/// bundle would be missing at runtime; the bytes live in the source instead.
struct BuilderBoatMark: View {
    static let size = CGSize(width: 22, height: 14)

    static let image: NSImage? = Data(base64Encoded: pngBase64, options: .ignoreUnknownCharacters)
        .flatMap(NSImage.init(data:))

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.size.width, height: Self.size.height)
        }
    }

    private static let pngBase64 = """
        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
        """
}
