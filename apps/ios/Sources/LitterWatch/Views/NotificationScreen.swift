import SwiftUI
import UserNotifications

/// 6 · Notification long-look. Driven by the real push payload the phone
/// sent. watchOS passes us `UNNotification.request.content`; we pull title,
/// subtitle, body out of that.
struct NotificationScreen: View {
    let notification: UNNotification?

    init(notification: UNNotification? = nil) {
        self.notification = notification
    }

    var body: some View {
        let content = notification?.request.content

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(WatchTheme.ginger)
                        .frame(width: 18, height: 18)
                    Text("L")
                        .font(WatchTheme.mono(10, weight: .bold))
                        .foregroundStyle(Color(hex: 0x0C0B0A))
                }
                Text("litter")
                    .font(WatchTheme.mono(10))
                    .foregroundStyle(WatchTheme.dim)
                Spacer(minLength: 0)
            }

            Text(content?.title ?? "codex update")
                .font(WatchTheme.mono(14, weight: .bold))
                .foregroundStyle(WatchTheme.text)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = content?.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(WatchTheme.mono(11))
                    .foregroundStyle(WatchTheme.gingerLight)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(content?.body ?? "")
                .font(WatchTheme.mono(11))
                .foregroundStyle(WatchTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .containerBackground(WatchTheme.bg.gradient, for: .navigation)
    }
}

#if DEBUG
#Preview {
    NotificationScreen()
}
#endif
