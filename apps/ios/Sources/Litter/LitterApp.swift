import SwiftUI
import Inject
import UIKit
import os


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
        scheduleKeyboardWarmup()
        return true
    }

    private func scheduleKeyboardWarmup() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.keyWindow ?? scene.windows.first else {
                // Window not ready yet, retry
                self.scheduleKeyboardWarmup()
                return
            }
            let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            window.addSubview(field)
            field.becomeFirstResponder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                field.resignFirstResponder()
                field.removeFromSuperview()
            }
        }
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
    @State private var serverManager = ServerManager()
    @State private var themeManager = ThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(serverManager)
                .environment(themeManager)
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
    @Environment(ServerManager.self) private var serverManager
    @Environment(ThemeManager.self) private var themeManager
    @State private var appState = AppState()
    @State private var stableSafeAreaInsets = StableSafeAreaInsets()
    @State private var conversationWarmup = ConversationWarmupCoordinator()
    @State private var composerBottomInset: CGFloat = 0

    var body: some View {
        @Bindable var bindableAppState = appState

        GeometryReader { geometry in
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()

                HomeNavigationView(
                    topInset: geometry.safeAreaInsets.top,
                    bottomInset: composerBottomInset
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .id(themeManager.themeVersion)

                if let approval = serverManager.activePendingApproval {
                    ApprovalPromptView(approval: approval) { decision in
                        serverManager.respondToPendingApproval(requestId: approval.requestId, decision: decision)
                    } onViewThread: { threadKey in
                        appState.pendingThreadNavigation = threadKey
                    }
                }

                if let warmupID = conversationWarmup.activeWarmupID {
                    ConversationWarmupView(warmupID: warmupID) {
                        conversationWarmup.finishWarmup()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .ignoresSafeArea(.container)
            .task {
                if composerBottomInset <= 0, geometry.safeAreaInsets.bottom > 0 {
                    composerBottomInset = geometry.safeAreaInsets.bottom
                }
                stableSafeAreaInsets.start(
                    fallback: max(composerBottomInset, geometry.safeAreaInsets.bottom)
                )
            }
            .onChange(of: stableSafeAreaInsets.bottomInset) { (_: CGFloat, nextInset: CGFloat) in
                guard nextInset > 0 else { return }
                composerBottomInset = nextInset
            }
        }
        .environment(appState)
        .environment(conversationWarmup)
        .onAppear {
            let forceDiscoveryForUITest =
                ProcessInfo.processInfo.environment["CODEXIOS_UI_TEST_FORCE_DISCOVERY"] == "1"
            if forceDiscoveryForUITest {
                appState.showServerPicker = true
            }
        }
        .onChange(of: serverManager.activeThreadKey) { _, _ in
            appState.selectedModel = ""
            appState.reasoningEffort = ""
            appState.showModelSelector = false
        }
        .enableInjection()
        .sheet(isPresented: $bindableAppState.showServerPicker) {
            NavigationStack {
                DiscoveryView(onServerSelected: { _ in
                    appState.showServerPicker = false
                })
            }
            .environment(serverManager)
            .environment(appState)
        }
        .sheet(isPresented: $bindableAppState.showSettings) {
            SettingsView()
                .environment(serverManager)
        }
    }

}

private let homeNavigationSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "HomeNavigation"
)

private let conversationRouteSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "ConversationRoute"
)

private struct HomeNavigationView: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(AppState.self) private var appState
    @Environment(ConversationWarmupCoordinator.self) private var conversationWarmup
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @State private var homeDashboardModel = HomeDashboardModel()
    @State private var navigationPath: [HomeNavigationRoute] = []
    @State private var directoryPickerSheet: SessionLaunchSupport.DirectoryPickerSheetModel?
    @State private var openingRecentSessionKey: ThreadKey?
    @State private var isStartingNewSession = false
    @State private var actionErrorMessage: String?
    @State private var hasSeededInitialConversationRoute = false
    let topInset: CGFloat
    let bottomInset: CGFloat

    private enum HomeNavigationRoute: Hashable {
        case sessions(serverId: String, title: String)
        case conversation(ThreadKey)
    }

    private var connectedServerOptions: [DirectoryPickerServerOption] {
        homeDashboardModel.connectedServers.map { connection in
            DirectoryPickerServerOption(
                id: connection.id,
                name: connection.server.name,
                sourceLabel: connection.server.source.rawString
            )
        }
    }

    private var isHomeRouteActive: Bool {
        navigationPath.isEmpty
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if isHomeRouteActive {
                    HomeDashboardView(
                        recentSessions: homeDashboardModel.recentSessions,
                        connectedServers: homeDashboardModel.connectedServers,
                        openingRecentSessionKey: openingRecentSessionKey,
                        isStartingNewSession: isStartingNewSession,
                        onOpenRecentSession: openRecentSession,
                        onOpenServerSessions: openServerSessions,
                        onNewSession: handleNewSessionTap,
                        onConnectServer: { appState.showServerPicker = true },
                        onShowSettings: { appState.showSettings = true },
                        onDeleteThread: { key in
                            try? await serverManager.archiveThread(key)
                        },
                        onDisconnectServer: { serverId in
                            serverManager.removeServer(id: serverId)
                        }
                    )
                } else {
                    LitterTheme.backgroundGradient.ignoresSafeArea()
                }
            }
            .navigationDestination(for: HomeNavigationRoute.self) { route in
                switch route {
                case let .sessions(serverId, title):
                    SessionsScreen(
                        onOpenConversation: { key in
                            openConversation(key)
                        }
                    )
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                        .onAppear {
                            appState.sessionsSelectedServerFilterId = serverId
                            appState.sessionsShowOnlyForks = false
                        }
                case let .conversation(threadKey):
                    ConversationDestinationScreen(
                        threadKey: threadKey,
                        topInset: topInset,
                        bottomInset: bottomInset,
                        onBack: popCurrentRoute,
                        onResumeSessions: { showSessions(for: $0) },
                        onOpenConversation: { replaceTopConversation(with: $0) }
                    )
                }
            }
        }
        .task {
            homeDashboardModel.bind(serverManager: serverManager)
            updateHomeDashboardActivity()
            seedInitialConversationIfNeeded(activeKey: serverManager.activeThreadKey)
        }
        .onChange(of: serverManager.activeThreadKey) { _, newKey in
            seedInitialConversationIfNeeded(activeKey: newKey)
        }
        .onChange(of: navigationPath.count) { _, _ in
            updateHomeDashboardActivity()
        }
        .onChange(of: appState.pendingThreadNavigation) { _, newKey in
            if let newKey {
                appState.pendingThreadNavigation = nil
                replaceTopConversation(with: newKey)
            }
        }
        .sheet(item: $directoryPickerSheet) { _ in
            NavigationStack {
                DirectoryPickerView(
                    servers: connectedServerOptions,
                    selectedServerId: Binding(
                        get: { directoryPickerSheet?.selectedServerId ?? defaultNewSessionServerId() ?? "" },
                        set: { nextServerId in
                            guard var sheet = directoryPickerSheet else { return }
                            sheet.selectedServerId = nextServerId
                            directoryPickerSheet = sheet
                        }
                    ),
                    onServerChanged: { nextServerId in
                        guard var sheet = directoryPickerSheet else { return }
                        sheet.selectedServerId = nextServerId
                        directoryPickerSheet = sheet
                    },
                    onDirectorySelected: { serverId, cwd in
                        directoryPickerSheet = nil
                        Task { await startNewSession(serverId: serverId, cwd: cwd) }
                    },
                    onDismissRequested: {
                        directoryPickerSheet = nil
                    }
                )
            }
            .environment(serverManager)
        }
        .alert("Home Action Failed", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { if !$0 { actionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { actionErrorMessage = nil }
        } message: {
            Text(actionErrorMessage ?? "Unknown error")
        }
    }

    private func defaultNewSessionServerId(preferredServerId: String? = nil) -> String? {
        SessionLaunchSupport.defaultConnectedServerId(
            connectedServerIds: connectedServerOptions.map(\.id),
            activeThreadKey: serverManager.activeThreadKey,
            preferredServerId: preferredServerId
        )
    }

    private func handleNewSessionTap() {
        if let defaultServerId = defaultNewSessionServerId(preferredServerId: appState.sessionsSelectedServerFilterId) {
            // For local on-device server, skip directory picker and use /home/codex.
            if let conn = serverManager.connections[defaultServerId], conn.target == .local {
                let cwd = codex_ios_default_cwd() as String? ?? NSHomeDirectory()
                Task { await startNewSession(serverId: defaultServerId, cwd: cwd) }
                return
            }
            directoryPickerSheet = SessionLaunchSupport.DirectoryPickerSheetModel(selectedServerId: defaultServerId)
        } else {
            appState.showServerPicker = true
        }
    }

    private func openServerSessions(_ connection: ServerConnection) {
        appState.sessionsSelectedServerFilterId = connection.id
        appState.sessionsShowOnlyForks = false
        hasSeededInitialConversationRoute = true
        navigationPath.append(.sessions(serverId: connection.id, title: connection.server.name))
    }

    private func openRecentSession(_ thread: ThreadState) async {
        guard openingRecentSessionKey == nil else { return }
        openingRecentSessionKey = thread.key
        actionErrorMessage = nil
        defer { openingRecentSessionKey = nil }

        await conversationWarmup.prewarmIfNeeded()
        workDir = thread.cwd
        appState.currentCwd = thread.cwd
        let opened = await serverManager.viewThread(
            thread.key,
            approvalPolicy: appState.approvalPolicy,
            sandboxMode: appState.sandboxMode
        )
        guard opened else {
            if let selectedThread = serverManager.threads[thread.key],
               case .error(let message) = selectedThread.status {
                actionErrorMessage = message
            } else {
                actionErrorMessage = "Failed to open conversation."
            }
            return
        }
        openConversation(thread.key)
    }

    private func startNewSession(serverId: String, cwd: String) async {
        guard !isStartingNewSession else { return }
        let signpostID = OSSignpostID(log: homeNavigationSignpostLog)
        os_signpost(
            .begin,
            log: homeNavigationSignpostLog,
            name: "StartNewSession",
            signpostID: signpostID,
            "server=%{public}@ cwd=%{public}@",
            serverId,
            cwd
        )
        isStartingNewSession = true
        defer {
            isStartingNewSession = false
            os_signpost(.end, log: homeNavigationSignpostLog, name: "StartNewSession", signpostID: signpostID)
        }
        actionErrorMessage = nil
        await conversationWarmup.prewarmIfNeeded()
        workDir = cwd
        appState.currentCwd = cwd
        let model = appState.selectedModel.isEmpty ? nil : appState.selectedModel
        let startedKey = try? await serverManager.startThread(
            serverId: serverId,
            cwd: cwd,
            model: model,
            approvalPolicy: appState.approvalPolicy,
            sandboxMode: appState.sandboxMode
        )

        guard let startedKey else {
            actionErrorMessage = "Failed to start a new session."
            return
        }

        _ = RecentDirectoryStore.shared.record(path: cwd, for: serverId)
        openConversation(startedKey)
    }

    private func seedInitialConversationIfNeeded(activeKey: ThreadKey?) {
        guard !hasSeededInitialConversationRoute,
              navigationPath.isEmpty,
              let activeKey else { return }

        hasSeededInitialConversationRoute = true
        Task {
            await conversationWarmup.prewarmIfNeeded()
            navigationPath = [.conversation(activeKey)]
        }
    }

    private func openConversation(_ key: ThreadKey) {
        hasSeededInitialConversationRoute = true
        appState.showModelSelector = false
        guard navigationPath.last != .conversation(key) else { return }
        navigationPath.append(.conversation(key))
    }

    private func replaceTopConversation(with key: ThreadKey) {
        hasSeededInitialConversationRoute = true
        if case .conversation = navigationPath.last {
            navigationPath.removeLast()
        }
        openConversation(key)
    }

    private func popCurrentRoute() {
        guard !navigationPath.isEmpty else { return }
        appState.showModelSelector = false
        navigationPath.removeLast()
    }

    private func updateHomeDashboardActivity() {
        if isHomeRouteActive {
            homeDashboardModel.activate()
        } else {
            homeDashboardModel.deactivate()
        }
    }

    private func showSessions(for serverId: String) {
        appState.sessionsSelectedServerFilterId = serverId
        appState.sessionsShowOnlyForks = false
        appState.showModelSelector = false
        hasSeededInitialConversationRoute = true

        if let existingIndex = navigationPath.lastIndex(where: { route in
            guard case let .sessions(id, _) = route else { return false }
            return id == serverId
        }) {
            navigationPath = Array(navigationPath.prefix(through: existingIndex))
            return
        }

        if case .conversation = navigationPath.last {
            navigationPath.removeLast()
        }
        navigationPath.append(.sessions(serverId: serverId, title: serverTitle(for: serverId)))
    }

    private func serverTitle(for serverId: String) -> String {
        if let connection = serverManager.connections[serverId] {
            return connection.server.name
        }
        if let connection = homeDashboardModel.connectedServers.first(where: { $0.id == serverId }) {
            return connection.server.name
        }
        if let thread = serverManager.threads.values.first(where: { $0.serverId == serverId }) {
            return thread.serverName
        }
        return "Sessions"
    }
}

private struct ConversationDestinationScreen: View {
    @Environment(ServerManager.self) private var serverManager
    @Environment(AppState.self) private var appState
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @State private var screenModel = ConversationScreenModel()
    let threadKey: ThreadKey
    let topInset: CGFloat
    let bottomInset: CGFloat
    let onBack: () -> Void
    let onResumeSessions: (String) -> Void
    let onOpenConversation: (ThreadKey) -> Void

    private var conversationContext: (thread: ThreadState, connection: ServerConnection)? {
        guard let thread = serverManager.threads[threadKey],
              let connection = serverManager.connections[threadKey.serverId] else {
            return nil
        }
        return (thread, connection)
    }

    var body: some View {
        Group {
            if let conversationContext {
                ZStack(alignment: .top) {
                    ConversationView(
                        connection: conversationContext.connection,
                        activeThreadKey: threadKey,
                        serverManager: serverManager,
                        transcript: screenModel.transcript,
                        pinnedContextItems: screenModel.pinnedContextItems,
                        composer: screenModel.composer,
                        topInset: topInset,
                        bottomInset: bottomInset,
                        onOpenConversation: onOpenConversation,
                        onResumeSessions: onResumeSessions
                    )
                    if appState.showModelSelector {
                        Color.black.opacity(0.01)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    appState.showModelSelector = false
                                }
                            }
                            .zIndex(1)
                    }
                    HeaderView(
                        thread: conversationContext.thread,
                        connection: conversationContext.connection,
                        serverManager: serverManager,
                        onBack: onBack,
                        topInset: topInset
                    )
                    .zIndex(2)
                }
                .task(id: threadKey) {
                    screenModel.bind(
                        thread: conversationContext.thread,
                        connection: conversationContext.connection,
                        serverManager: serverManager
                    )
                }
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView()
                        .tint(LitterTheme.accent)
                    Text("Loading thread...")
                        .font(LitterFont.styled(.caption))
                        .foregroundColor(LitterTheme.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                .overlay(alignment: .topLeading) {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Back")
                                .font(LitterFont.styled(.callout))
                        }
                        .foregroundColor(LitterTheme.accent)
                        .padding(.horizontal, 16)
                        .padding(.top, topInset + 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .toolbar(.hidden, for: .navigationBar)
        .task(id: threadKey) {
            os_signpost(
                .event,
                log: conversationRouteSignpostLog,
                name: "ThreadOpenStarted",
                "server=%{public}@ thread=%{public}@",
                threadKey.serverId,
                threadKey.threadId
            )
            _ = await serverManager.prepareThreadForPresentation(
                threadKey,
                approvalPolicy: appState.approvalPolicy,
                sandboxMode: appState.sandboxMode
            )
            if let thread = serverManager.threads[threadKey], !thread.cwd.isEmpty {
                workDir = thread.cwd
                appState.currentCwd = thread.cwd
            }
        }
    }
}

private struct ApprovalPromptView: View {
    let approval: ServerManager.PendingApproval
    let onDecision: (ServerManager.ApprovalDecision) -> Void
    var onViewThread: ((ThreadKey) -> Void)? = nil

    private var title: String {
        switch approval.kind {
        case .commandExecution:
            return "Command Approval Required"
        case .fileChange:
            return "File Change Approval Required"
        }
    }

    private var requesterLabel: String? {
        AgentLabelFormatter.format(
            nickname: approval.requesterAgentNickname,
            role: approval.requesterAgentRole
        )
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
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(LitterTheme.success)
                            Text(requesterLabel)
                                .font(LitterFont.styled(.caption, weight: .medium))
                                .foregroundColor(LitterTheme.textPrimary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(LitterTheme.success.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        if let threadId = approval.threadId, onViewThread != nil {
                            Button {
                                onViewThread?(ThreadKey(serverId: approval.serverId, threadId: threadId))
                            } label: {
                                HStack(spacing: 3) {
                                    Text("View Thread")
                                        .font(LitterFont.styled(.caption, weight: .medium))
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .foregroundColor(LitterTheme.accent)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()
                    }
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
