import SwiftUI

extension AppServerHealth {
    var displayLabel: String {
        switch self {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting…"
        case .unresponsive:
            return "Unresponsive"
        case .disconnected:
            return "Disconnected"
        case .unknown:
            return "Unknown"
        }
    }

    var accentColor: Color {
        switch self {
        case .connected:
            return LitterTheme.accent
        case .connecting, .unresponsive:
            return .orange
        case .disconnected, .unknown:
            return LitterTheme.textSecondary
        }
    }
}
