import SwiftUI

/// Design tokens for the Litter Apple Watch experience.
///
/// Matches the Claude Design handoff: pure #000 OLED, ginger (#F59E0B) as the
/// only accent, green for success. Berkeley mono everywhere, never below 10pt.
enum WatchTheme {
    // MARK: - Palette
    static let bg            = Color.black
    static let surface       = Color(hex: 0x0E0E0E)
    static let surfaceDeep   = Color(hex: 0x0A0A0A)
    static let surfaceHi     = Color(hex: 0x1A1A1A)
    static let border        = Color(hex: 0x222222)
    static let borderHi      = Color(hex: 0x333333)

    static let ginger        = Color(hex: 0xF59E0B)
    static let gingerLight   = Color(hex: 0xFCD472)
    static let amber         = Color(hex: 0xD98A53)
    static let amberDeep     = Color(hex: 0xB06535)
    static let gingerTint    = Color(hex: 0xF59E0B).opacity(0.12)
    static let gingerStroke  = Color(hex: 0xF59E0B).opacity(0.35)

    static let text          = Color(hex: 0xFCFCFC)
    static let dim           = Color(hex: 0x8F8F8F)
    static let dimMore       = Color(hex: 0x555555)
    static let muted         = Color(hex: 0x6D6050)

    static let success       = Color(hex: 0x00FF9C)
    static let successSoft   = Color(hex: 0x85DF7B)
    static let danger        = Color(hex: 0xFF5555)
    static let userBubble    = Color(hex: 0x0169CC)
    static let onAccent      = Color(hex: 0x1F2937)

    // MARK: - Type
    private static let mono = "BerkeleyMono-Regular"
    private static let monoBold = "BerkeleyMono-Bold"

    /// Berkeley Mono is embedded in the parent iOS app. On watchOS falls back to
    /// the system monospaced design when that resource is unavailable.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = weight == .bold || weight == .heavy ? monoBold : mono
        return Font.custom(name, size: size).weight(weight)
    }

    // MARK: - Radii / spacing
    static let cardRadius: CGFloat  = 14
    static let pillRadius: CGFloat  = 999
    static let innerRadius: CGFloat = 10
}

// MARK: - Hex helper

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8)  & 0xFF) / 255
        let b = Double(hex         & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
