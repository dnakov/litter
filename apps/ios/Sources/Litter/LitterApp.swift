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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()
    @State private var showAccount = false
    @State private var sidebarDragOffset: CGFloat = 0
    @State private var isEdgeOpeningSidebar = false

    private let sidebarAnimation = Animation.spring(response: 0.3, dampingFraction: 0.86)

    private var activeAuthStatus: AuthStatus {
        serverManager.activeConnection?.authStatus ?? .unknown
    }

    private var sidebarRevealProgress: CGFloat {
        guard appState.sidebarOpen else { return 0 }
        return min(1, max(0, 1 + (sidebarDragOffset / SidebarOverlay.sidebarWidth)))
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
            .offset(x: sidebarRevealProgress * 284)
            .scaleEffect(1 - (0.04 * sidebarRevealProgress), anchor: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 20 * sidebarRevealProgress, style: .continuous))
            .shadow(color: .black.opacity(0.22 * sidebarRevealProgress), radius: 26, x: 8, y: 0)
            .allowsHitTesting(sidebarRevealProgress < 0.01)
            .animation(sidebarAnimation, value: appState.sidebarOpen)
            .animation(sidebarAnimation, value: sidebarDragOffset)
            .simultaneousGesture(edgeOpenGesture)

            SidebarOverlay(dragOffset: $sidebarDragOffset)

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
            Task { await serverManager.handleAppLifecycleChange(isForeground: true) }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { @MainActor in
                switch phase {
                case .active:
                    await serverManager.handleAppLifecycleChange(isForeground: true)
                case .background:
                    await serverManager.handleAppLifecycleChange(isForeground: false)
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
        .onChange(of: appState.sidebarOpen) { _, isOpen in
            if !isOpen { sidebarDragOffset = 0 }
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

    private var edgeOpenGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard !appState.sidebarOpen || isEdgeOpeningSidebar else { return }

                if !isEdgeOpeningSidebar {
                    let startsAtEdge = value.startLocation.x <= 24
                    let horizontalIntent = abs(value.translation.width) > abs(value.translation.height)
                    guard startsAtEdge, horizontalIntent, value.translation.width > 0 else { return }
                    isEdgeOpeningSidebar = true
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        appState.sidebarOpen = true
                        sidebarDragOffset = -SidebarOverlay.sidebarWidth
                    }
                }

                let translationX = max(0, value.translation.width)
                sidebarDragOffset = min(
                    0,
                    max(-SidebarOverlay.sidebarWidth, -SidebarOverlay.sidebarWidth + translationX)
                )
            }
            .onEnded { value in
                guard isEdgeOpeningSidebar else { return }
                isEdgeOpeningSidebar = false

                let projectedOpenDistance = max(value.translation.width, value.predictedEndTranslation.width)
                let shouldOpen = projectedOpenDistance > SidebarOverlay.sidebarWidth * 0.35
                withAnimation(sidebarAnimation) {
                    appState.sidebarOpen = shouldOpen
                    sidebarDragOffset = 0
                }
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
                    .font(LitterFont.monospaced(.headline))
                    .foregroundColor(LitterTheme.textPrimary)

                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .font(LitterFont.monospaced(.footnote))
                        .foregroundColor(LitterTheme.textSecondary)
                }

                if let command = approval.command, !command.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command")
                            .font(LitterFont.monospaced(.caption))
                            .foregroundColor(LitterTheme.textMuted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(command)
                                .font(LitterFont.monospaced(.footnote))
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
                        .font(LitterFont.monospaced(.caption))
                        .foregroundColor(LitterTheme.textMuted)
                }

                if let grantRoot = approval.grantRoot, !grantRoot.isEmpty {
                    Text("Grant Root: \(grantRoot)")
                        .font(LitterFont.monospaced(.caption))
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
                .font(LitterFont.monospaced(.callout))
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
                    .font(LitterFont.monospaced(.body))
                    .foregroundColor(LitterTheme.textMuted)
            }
        }
    }
}
