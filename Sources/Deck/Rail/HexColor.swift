import Foundation

struct RGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double
}

/// Parses `#RRGGBB` (leading `#` optional, case-insensitive) into normalized
/// 0...1 components. Returns nil for anything else instead of guessing — a
/// bad hex in the crew catalog should be visibly wrong, not silently
/// blended into the nearest valid color.
func parseHexColor(_ hex: String) -> RGB? {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
    let red = Double((value >> 16) & 0xFF) / 255
    let green = Double((value >> 8) & 0xFF) / 255
    let blue = Double(value & 0xFF) / 255
    return RGB(red: red, green: green, blue: blue)
}
