import SwiftUI

/// 浅色主题
enum Theme {
    static let bg = Color(hex: 0xF4F6F9)
    static let card = Color.white
    static let line = Color(hex: 0xE3E7EE)
    static let text = Color(hex: 0x111827)
    static let sub = Color(hex: 0x5B6577)
    static let dim = Color(hex: 0x98A2B3)
    static let accent = Color(hex: 0x0E9F6E)
    static let blue = Color(hex: 0x2563EB)
    static let orange = Color(hex: 0xE8830C)
    static let red = Color(hex: 0xE11D48)
    static let green = Color(hex: 0x0E9F6E)
    static let fill = Color(hex: 0xF0F3F7)
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
            .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
    }
}

struct TagView: View {
    var text: String
    var color: Color = Theme.accent
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

struct SectionTitle: View {
    var text: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let i = icon {
                Image(systemName: i).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.accent)
            }
            Text(text).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.text)
            Spacer()
        }
    }
}


struct PresetItem: Identifiable {
    var id: String
    var label: String
    var value: String
}


extension Notification.Name {
    static let rcForeground = Notification.Name("rc.foreground")
}
