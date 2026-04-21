import SwiftUI
import WatchKit
import UserNotifications

/// Root @main for the Litter Watch app. Vertically paginated TabView
/// makes the three hero surfaces reachable via crown/swipe.
@main
struct LitterWatchApp: App {
    @StateObject private var store = WatchAppStore.shared

    init() {
        WatchSessionBridge.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(WatchTheme.ginger)
        }

        WKNotificationScene(
            controller: LitterNotificationController.self,
            category: "litter.task.complete"
        )
    }
}

/// The three-page hero loop: glance → dictate → approve.
///
/// A single root `NavigationStack` wraps the `TabView` so pushed
/// destinations (task detail, transcript, approval) replace the whole
/// pager and the native horizontal edge-swipe-back gesture works.
/// Nesting `NavigationStack` per tab page fought with the vertical
/// page tab view and broke back navigation.
struct WatchRootView: View {
    @State private var tab: RootTab = .home

    var body: some View {
        NavigationStack {
            TabView(selection: $tab) {
                HomeScreen().tag(RootTab.home)
                VoiceScreen().tag(RootTab.voice)
                ApprovalScreen().tag(RootTab.approval)
            }
            .tabViewStyle(.verticalPage)
        }
    }
}

enum RootTab: Hashable {
    case home, voice, approval
}

final class LitterNotificationController: WKUserNotificationHostingController<NotificationScreen> {
    private var currentNotification: UNNotification?

    override var body: NotificationScreen {
        NotificationScreen(notification: currentNotification)
    }

    override func didReceive(_ notification: UNNotification) {
        currentNotification = notification
    }
}
