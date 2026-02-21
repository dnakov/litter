import SwiftUI
import Inject

@main
struct LitterApp: App {
    @StateObject private var serverManager = ServerManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverManager)
                .preferredColorScheme(.dark)
                .task { await serverManager.reconnectAll() }
        }
    }
}

struct ContentView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @StateObject private var appState = AppState()
    @State private var showAccount = false

    private var activeAuthStatus: AuthStatus {
        serverManager.activeConnection?.authStatus ?? .unknown
    }

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                HeaderView()
                Divider().background(Color(hex: "#1E1E1E"))
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            SidebarOverlay()
        }
        .environmentObject(appState)
        .onAppear {
            if !serverManager.hasAnyConnection {
                appState.showServerPicker = true
            }
        }
        .onChange(of: activeAuthStatus) { _, newStatus in
            if case .notLoggedIn = newStatus {
                showAccount = true
            }
        }
        .sheet(isPresented: $showAccount) {
            AccountView().environmentObject(serverManager)
        }
        .enableInjection()
        .sheet(isPresented: $appState.showServerPicker) {
            NavigationStack {
                DiscoveryView(onServerSelected: { server in
                    appState.showServerPicker = false
                    appState.sidebarOpen = true
                })
                .environmentObject(serverManager)
            }
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if serverManager.activeThreadKey != nil {
            ConversationView()
        } else {
            EmptyStateView()
        }
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            VStack(spacing: 24) {
                BrandLogo(size: 132)
                Text("AI coding agent on iOS")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(LitterTheme.textMuted)
            }
        }
    }
}
