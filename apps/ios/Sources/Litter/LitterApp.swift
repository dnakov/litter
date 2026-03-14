import SwiftUI
import Combine
import Inject
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    private var pendingPushToken: Data?
    weak var serverManager: ServerManager? {
        didSet {
            if let token = pendingPushToken {
                serverManager?.devicePushToken = token
                pendingPushToken = nil
            }
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        NSLog("[push] device token received (%d bytes): %@", deviceToken.count, hex)
        if let sm = serverManager {
            sm.devicePushToken = deviceToken
        } else {
            pendingPushToken = deviceToken
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("[push] registration failed: %@", error.localizedDescription)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NSLog("[push] background push received")
        guard let sm = serverManager else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await sm.handleBackgroundPush()
            completionHandler(.newData)
        }
    }
}

@main
struct LitterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var serverManager = ServerManager()
    @StateObject private var themeManager = ThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serverManager)
                .environmentObject(themeManager)
                .task {
                    appDelegate.serverManager = serverManager
                    await serverManager.reconnectAll()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                serverManager.appDidEnterBackground()
            case .active:
                serverManager.appDidBecomeActive()
            default:
                break
            }
        }
    }
}

struct ContentView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var appState = AppState()
    @State private var sidebarDragOffset: CGFloat = 0
    @State private var isEdgeOpeningSidebar = false
    @State private var keyboardHeight: CGFloat = 0

    private let sidebarAnimation = Animation.spring(response: 0.3, dampingFraction: 0.86)

    private var sidebarRevealProgress: CGFloat {
        guard appState.sidebarOpen else { return 0 }
        return min(1, max(0, 1 + (sidebarDragOffset / SidebarOverlay.sidebarWidth)))
    }

    var body: some View {
        GeometryReader { geometry in
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()

            mainContent(topInset: geometry.safeAreaInsets.top, bottomInset: keyboardHeight > 0 ? 0 : geometry.safeAreaInsets.bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .overlay {
                    if appState.showModelSelector {
                        Color.black.opacity(0.01)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    appState.showModelSelector = false
                                }
                            }
                    }
                }
                .overlay(alignment: .top) {
                    if serverManager.activeThreadKey != nil {
                        HeaderView(topInset: geometry.safeAreaInsets.top)
                    }
                }
            .id(themeManager.themeVersion)
            .allowsHitTesting(!appState.sidebarOpen)
            .simultaneousGesture(edgeOpenGesture)

            SidebarOverlay(dragOffset: $sidebarDragOffset, topInset: geometry.safeAreaInsets.top)

            if let approval = serverManager.activePendingApproval {
                ApprovalPromptView(approval: approval) { decision in
                    serverManager.respondToPendingApproval(requestId: approval.requestId, decision: decision)
                }
            }
        }
        .ignoresSafeArea(.container)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = frame.height
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .environmentObject(appState)
        .onAppear {
            let forceDiscoveryForUITest =
                ProcessInfo.processInfo.environment["CODEXIOS_UI_TEST_FORCE_DISCOVERY"] == "1"
            if forceDiscoveryForUITest {
                appState.showServerPicker = true
            }
        }
        .onChange(of: appState.sidebarOpen) { _, isOpen in
            if !isOpen { sidebarDragOffset = 0 }
        }
        .enableInjection()
        .sheet(isPresented: $appState.showServerPicker) {
            NavigationStack {
                DiscoveryView(onServerSelected: { server in
                    appState.showServerPicker = false
                    appState.sidebarOpen = true
                })
                .environmentObject(serverManager)
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $appState.showSettings) {
            SettingsView()
                .environmentObject(serverManager)
                .environmentObject(appState)
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

    private func mainContent(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        Group {
            if serverManager.activeThreadKey != nil {
                ConversationView(topInset: topInset, bottomInset: bottomInset)
            } else {
                HomeNavigationView()
                    .environmentObject(serverManager)
                    .environmentObject(appState)
            }
        }
    }
}

private struct HomeNavigationView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var showSessions = false

    var body: some View {
        NavigationStack {
            DiscoveryView(onServerSelected: { _ in
                showSessions = true
            })
            .environmentObject(serverManager)
            .navigationDestination(isPresented: $showSessions) {
                SessionSidebarView()
                    .navigationTitle("Sessions")
                    .navigationBarTitleDisplayMode(.inline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            }
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

    private var requesterLabel: String? {
        let nickname = approval.requesterAgentNickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let role = approval.requesterAgentRole?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !nickname.isEmpty && !role.isEmpty {
            return "\(nickname) [\(role)]"
        }
        if !nickname.isEmpty {
            return nickname
        }
        if !role.isEmpty {
            return "[\(role)]"
        }
        return nil
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(LitterFont.styled(.headline))
                    .foregroundColor(LitterTheme.textPrimary)

                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .font(LitterFont.styled(.footnote))
                        .foregroundColor(LitterTheme.textSecondary)
                }

                if let requesterLabel {
                    Text("Requester: \(requesterLabel)")
                        .font(LitterFont.styled(.caption))
                        .foregroundColor(LitterTheme.textMuted)
                }

                if let command = approval.command, !command.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command")
                            .font(LitterFont.styled(.caption))
                            .foregroundColor(LitterTheme.textMuted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(command)
                                .font(LitterFont.styled(.footnote))
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
                        .font(LitterFont.styled(.caption))
                        .foregroundColor(LitterTheme.textMuted)
                }

                if let grantRoot = approval.grantRoot, !grantRoot.isEmpty {
                    Text("Grant Root: \(grantRoot)")
                        .font(LitterFont.styled(.caption))
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
                .font(LitterFont.styled(.callout))
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
                    .font(LitterFont.styled(.body))
                    .foregroundColor(LitterTheme.textMuted)
            }
        }
    }
}
