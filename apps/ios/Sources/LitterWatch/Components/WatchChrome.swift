import SwiftUI

/// Ginger eyebrow heading — small uppercased mono text.
struct WatchEyebrow: View {
    let text: String
    var color: Color = WatchTheme.ginger
    var size: CGFloat = 11

    var body: some View {
        Text(text.uppercased())
            .font(WatchTheme.mono(size, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(color)
    }
}

/// Pulsing dot used to signal activity.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 6
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.9), radius: pulse ? 5 : 2)
            .scaleEffect(pulse ? 1.15 : 1)
            .animation(
                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}

/// Centered empty-state card. Used when the watch has no data for a
/// surface yet — either no pending approval, no running task, etc.
struct WatchEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String?

    init(icon: String, title: String, subtitle: String? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(WatchTheme.dim)
            Text(title)
                .font(WatchTheme.mono(12, weight: .bold))
                .foregroundStyle(WatchTheme.text)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(WatchTheme.mono(10))
                    .foregroundStyle(WatchTheme.dim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
    }
}
