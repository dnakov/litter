import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Central Theme

enum LitterTheme {
    static let accent       = Color(hex: "#B0B0B0")
    static let textPrimary  = Color.white
    static let textSecondary = Color(hex: "#888888")
    static let textMuted    = Color(hex: "#555555")
    static let textBody     = Color(hex: "#E0E0E0")
    static let textSystem   = Color(hex: "#C6D0CA")
    static let surface      = Color(hex: "#1A1A1A")
    static let surfaceLight = Color(hex: "#2A2A2A")
    static let border       = Color(hex: "#333333")

    static let gradientColors: [Color] = [
        Color(hex: "#0A0A0A"),
        Color(hex: "#0F0F0F"),
        Color(hex: "#080808")
    ]

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

func serverIconName(for source: ServerSource) -> String {
    switch source {
    case .local: return "iphone"
    case .bonjour: return "desktopcomputer"
    case .ssh: return "terminal"
    case .tailscale: return "network"
    case .manual: return "server.rack"
    }
}

func relativeDate(_ timestamp: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

// MARK: - Glass Effect Availability Wrappers

struct GlassRectModifier: ViewModifier {
    let cornerRadius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            content.overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke((tint ?? LitterTheme.surfaceLight).opacity(0.4), lineWidth: 1)
            )
        }
    }
}

struct GlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(LitterTheme.surfaceLight)
                .clipShape(Capsule())
        }
    }
}

struct GlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .circle)
        } else {
            content
                .background(LitterTheme.surfaceLight)
                .clipShape(Circle())
        }
    }
}
