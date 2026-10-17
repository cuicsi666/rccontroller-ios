import SwiftUI

enum Theme {
    static let bg = Color(hex: 0x0B0F14)
    static let card = Color(hex: 0x161C24)
    static let line = Color(hex: 0x232B36)
    static let text = Color(hex: 0xE8EEF6)
    static let sub = Color(hex: 0x9AA7B8)
    static let dim = Color(hex: 0x6B7787)
    static let accent = Color(hex: 0x2BE0A8)
    static let blue = Color(hex: 0x4DA3FF)
    static let orange = Color(hex: 0xFFA94D)
    static let red = Color(hex: 0xFF5D5D)
    static let green = Color(hex: 0x2BE0A8)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

struct Card<Content: View>: View {
    var content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
    }
}

struct TagView: View {
    var text: String
    var color: Color = Theme.accent
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}
