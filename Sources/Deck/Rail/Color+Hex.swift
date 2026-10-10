import SwiftUI

extension Color {
    /// Falls back to a loud, obviously-wrong color instead of black or clear
    /// so a bad hex string is visible in the UI immediately, not silently
    /// swallowed. Retained for hex strings arriving from user config; the
    /// crew catalog no longer carries any.
    init(hex: String) {
        guard let rgb = parseHexColor(hex) else {
            self = .pink
            return
        }
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    init(_ rgb: RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
