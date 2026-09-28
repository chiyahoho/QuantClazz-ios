import SwiftUI

enum ForumTheme {
    static let accent = Color(hex: 0x1878F3)
    static let navy = Color(hex: 0x073763)
    static let text = Color(hex: 0x252B36)
    static let secondary = Color(hex: 0x8590A6)
    static let background = Color(hex: 0xF4F5F6)
    static let surface = Color.white
    static let separator = Color(hex: 0xEBEEF2)
    static let paleBlue = Color(hex: 0xEEF5FF)
}
private extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}
