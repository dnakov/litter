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

            if let approval = serverManager.activePendingApproval {
                ApprovalPromptView(approval: approval) { decision in
                    serverManager.respondToPendingApproval(requestId: approval.requestId, decision: decision)
                }
            }
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

private struct ApprovalPromptView: View {
    let approval: ServerManager.PendingApproval
    let onDecision: (ServerManager.ApprovalDecision) -> Void

    private var title: String {
        switch approval.kind {
        case .commandExecution:
            return "Command Approval Required"
        case .fileChange:
            return "File Change Approval Required"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(.headline, design: .monospaced))
                    .foregroundColor(LitterTheme.textPrimary)

                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(LitterTheme.textSecondary)
                }

                if let command = approval.command, !command.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(LitterTheme.textMuted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(command)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(LitterTheme.textBody)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(LitterTheme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if let cwd = approval.cwd, !cwd.isEmpty {
                    Text("CWD: \(cwd)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(LitterTheme.textMuted)
                }

                if let grantRoot = approval.grantRoot, !grantRoot.isEmpty {
                    Text("Grant Root: \(grantRoot)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(LitterTheme.textMuted)
                }

                VStack(spacing: 8) {
                    Button("Allow Once") { onDecision(.accept) }
                        .buttonStyle(.borderedProminent)
                        .tint(LitterTheme.accent)
                        .frame(maxWidth: .infinity)

                    Button("Allow for Session") { onDecision(.acceptForSession) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                    HStack(spacing: 8) {
                        Button("Deny") { onDecision(.decline) }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)

                        Button("Abort") { onDecision(.cancel) }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                }
                .font(.system(.callout, design: .monospaced))
            }
            .padding(16)
            .modifier(GlassRectModifier(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(LitterTheme.border, lineWidth: 1)
            )
            .padding(.horizontal, 16)
        }
        .transition(.opacity)
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
