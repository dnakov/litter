import SwiftUI
import UIKit

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
    static let accentStrong = Color(hex: "#00FF9C")
    static let textPrimary  = Color.white
    static let textSecondary = Color(hex: "#888888")
    static let textMuted    = Color(hex: "#555555")
    static let textBody     = Color(hex: "#E0E0E0")
    static let textSystem   = Color(hex: "#C6D0CA")
    static let surface      = Color(hex: "#1A1A1A")
    static let surfaceLight = Color(hex: "#2A2A2A")
    static let border       = Color(hex: "#333333")
    static let separator    = Color(hex: "#1E1E1E")
    static let danger       = Color(hex: "#FF5555")
    static let success      = Color(hex: "#6EA676")
    static let warning      = Color(hex: "#E2A644")
    static let overlayScrim = Color.black.opacity(0.5)

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

enum LitterFont {
    private static let berkeleyRegular = "BerkeleyMono-Regular"
    private static let berkeleyBold = "BerkeleyMono-Bold"

    static var markdownFontName: String {
        preferredFontName(weight: .regular) ?? "SFMono-Regular"
    }

    static func monospaced(
        _ style: Font.TextStyle,
        weight: Font.Weight = .regular,
        scale: CGFloat = 1.0
    ) -> Font {
        let pointSize = UIFont.preferredFont(forTextStyle: style.uiTextStyle).pointSize * scale
        return monospaced(size: pointSize, weight: weight, relativeTo: style)
    }

    static func monospaced(size: CGFloat, weight: Font.Weight = .regular, scale: CGFloat = 1.0) -> Font {
        monospaced(size: size * scale, weight: weight, relativeTo: nil)
    }

    private static func monospaced(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle?) -> Font {
        if let fontName = preferredFontName(weight: weight) {
            if let style {
                return .custom(fontName, size: size, relativeTo: style)
            }
            return .custom(fontName, size: size)
        }
        if let style {
            return .system(style, design: .monospaced, weight: weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    private static func preferredFontName(weight: Font.Weight) -> String? {
        let preferred = isBold(weight: weight) ? berkeleyBold : berkeleyRegular
        if UIFont(name: preferred, size: 12) != nil {
            return preferred
        }
        if UIFont(name: berkeleyRegular, size: 12) != nil {
            return berkeleyRegular
        }
        return nil
    }

    private static func isBold(weight: Font.Weight) -> Bool {
        switch weight {
        case .semibold, .bold, .heavy, .black:
            return true
        default:
            return false
        }
    }
}

private extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        @unknown default: return .body
        }
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
