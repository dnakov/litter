import SwiftUI
import UIKit
import os


class AppDelegate: NSObject, UIApplicationDelegate {
    private var pendingPushToken: Data?
    private var splashWindow: UIWindow?
    private var minTimeElapsed = false
    private var contentReady = false
    private var splashDismissed = false

    weak var appRuntime: AppRuntimeController? {
        didSet {
            if let token = pendingPushToken {
                appRuntime?.setDevicePushToken(token)
                pendingPushToken = nil
            }
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        codex_ios_system_init()
        LLog.bootstrap()
        OpenAIApiKeyStore.shared.applyToEnvironment()
        // Pre-initialize Rust bridges (tokio runtime) on a background thread
        // before SwiftUI accesses AppModel.shared, avoiding a priority inversion
        // where the main thread blocks on lower-QoS tokio worker init.
        DispatchQueue.global(qos: .userInitiated).async {
            AppModel.prewarmRustBridges()
        }
        application.registerForRemoteNotifications()
        showSplashWindow()
        scheduleKeyboardWarmup()
        return true
    }

    // MARK: - Splash window (sits above keyboard)

    private func showSplashWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
                self.showSplashWindow()
                return
            }
            let window = UIWindow(windowScene: scene)
            // Keyboard window is typically at level ~10000. Go above it.
            window.windowLevel = UIWindow.Level(rawValue: 10000002)
            let hosting = UIHostingController(rootView:
                AnimatedSplashView(appReady: true) {}
            )
            hosting.view.backgroundColor = .clear
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            self.splashWindow = window

            // Minimum display time
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.minTimeElapsed = true
                self.tryDismissSplash()
            }
            // Hard max
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.forceDismissSplash()
            }
        }
    }

    /// Called by ContentView when the main UI has appeared.
    func signalContentReady() {
        contentReady = true
        tryDismissSplash()
    }

    private func tryDismissSplash() {
        guard !splashDismissed, minTimeElapsed, contentReady else { return }
        dismissSplash()
    }

    private func forceDismissSplash() {
        guard !splashDismissed else { return }
        dismissSplash()
    }

    private func dismissSplash() {
        splashDismissed = true
        guard let window = splashWindow else { return }
        UIView.animate(withDuration: 0.35, animations: {
            window.alpha = 0
        }, completion: { _ in
            window.isHidden = true
            window.rootViewController = nil
            self.splashWindow = nil
        })
    }

    // MARK: - Keyboard warmup

    private func scheduleKeyboardWarmup() {
        // Load the real system keyboard while the splash window covers it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first(where: { $0 !== self.splashWindow }) else {
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
        LLog.info("push", "device token received", fields: ["bytes": deviceToken.count, "hex": hex])
        if let appRuntime {
            appRuntime.setDevicePushToken(deviceToken)
        } else {
            pendingPushToken = deviceToken
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        LLog.error("push", "registration failed", error: error)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        LLog.info("push", "background push received")
        guard let appRuntime else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await appRuntime.handleBackgroundPush()
            completionHandler(.newData)
        }
    }
}

@main
struct LitterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel.shared
    @State private var voiceRuntime = VoiceRuntimeController.shared
    @State private var appRuntime = AppRuntimeController.shared
    @State private var themeManager = ThemeManager.shared
    @State private var wallpaperManager = WallpaperManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(appRuntime)
                .environment(voiceRuntime)
                .environment(themeManager)
                .environment(wallpaperManager)
                .task {
                    appModel.start()
                    voiceRuntime.bind(appModel: appModel)
                    appRuntime.bind(appModel: appModel, voiceRuntime: voiceRuntime)
                    appDelegate.appRuntime = appRuntime
                    await appRuntime.reconnectSavedServers()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                appRuntime.appDidEnterBackground()
            case .active:
                appRuntime.appDidBecomeActive()
            default:
                break
            }
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppRuntimeController.self) private var appRuntime
    @Environment(ThemeManager.self) private var themeManager
    @State private var appState = AppState()
    @State private var stableSafeAreaInsets = StableSafeAreaInsets()
    @State private var conversationWarmup = ConversationWarmupCoordinator()
    @State private var composerBottomInset: CGFloat = 0
    @State private var splashDismissed = false
    @AppStorage("conversationTextSizeStep") private var textSizeStep = ConversationTextSize.large.rawValue

    private var textScale: CGFloat {
        ConversationTextSize.clamped(rawValue: textSizeStep).scale
    }

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
                .onAppear {
                    if !splashDismissed {
                        splashDismissed = true
                        (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
                    }
                }

                if let approval = appModel.snapshot?.pendingApprovals.first(where: {
                    $0.kind != .mcpElicitation
                }) {
                    ApprovalPromptView(approval: approval) { decision in
                        Task {
                            try? await appModel.store.respondToApproval(
                                requestId: approval.id,
                                decision: decision
                            )
                        }
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
        .environment(\.textScale, textScale)
        .onAppear {
            let forceDiscoveryForUITest =
                ProcessInfo.processInfo.environment["CODEXIOS_UI_TEST_FORCE_DISCOVERY"] == "1"
            if forceDiscoveryForUITest {
                appState.showServerPicker = true
            }
        }
        .onChange(of: appModel.snapshot?.activeThread) { _, _ in
            appState.selectedModel = ""
            appState.reasoningEffort = ""
            appState.showModelSelector = false
        }
        .onChange(of: appModel.snapshot) { _, nextSnapshot in
            appRuntime.handleSnapshot(nextSnapshot)
        }
        .sheet(isPresented: $bindableAppState.showServerPicker) {
            NavigationStack {
                DiscoveryView(onServerSelected: { _ in
                    appState.showServerPicker = false
                })
            }
            .environment(appState)
            .environment(\.textScale, textScale)
        }
        .sheet(isPresented: $bindableAppState.showSettings) {
            SettingsView()
                .environment(\.textScale, textScale)
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
    @Environment(AppModel.self) private var appModel
    @Environment(VoiceRuntimeController.self) private var voiceRuntime
    @Environment(AppState.self) private var appState
    @Environment(ConversationWarmupCoordinator.self) private var conversationWarmup
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @State private var experimentalFeatures = ExperimentalFeatures.shared
    @State private var homeDashboardModel = HomeDashboardModel()
    @State private var navigationPath: [HomeNavigationRoute] = []
    @State private var directoryPickerSheet: SessionLaunchSupport.DirectoryPickerSheetModel?
    @State private var openingRecentSessionKey: ThreadKey?
    @State private var isStartingNewSession = false
    @State private var isStartingVoice = false
    @State private var actionErrorMessage: String?
    @State private var hasSeededInitialConversationRoute = false
    @State private var pendingWallpaperConfig: WallpaperConfig?
    @State private var pendingWallpaperImage: UIImage?
    let topInset: CGFloat
    let bottomInset: CGFloat

    private enum HomeNavigationRoute: Hashable {
        case sessions(serverId: String, title: String)
        case conversation(ThreadKey)
        case realtimeVoice(ThreadKey)
        case conversationInfo(ThreadKey)
        case wallpaperSelection(ThreadKey)
        case wallpaperAdjust(ThreadKey)
        case serverInfo(serverId: String)
        case serverWallpaperSelection(serverId: String)
        case serverWallpaperAdjust(serverId: String)
    }

    private var connectedServerOptions: [DirectoryPickerServerOption] {
        homeDashboardModel.connectedServers.map { server in
            DirectoryPickerServerOption(
                id: server.id,
                name: server.displayName,
                sourceLabel: server.sourceLabel
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
                            _ = try? await appModel.client.archiveThread(
                                serverId: key.serverId,
                                params: AppArchiveThreadRequest(threadId: key.threadId)
                            )
                            await appModel.refreshSnapshot()
                        },
                        onDisconnectServer: { serverId in
                            SavedServerStore.remove(serverId: serverId)
                            Task { await SshSessionStore.shared.close(serverId: serverId, ssh: appModel.ssh) }
                            appModel.serverBridge.disconnectServer(serverId: serverId)
                        },
                        onRenameServer: { serverId, newName in
                            SavedServerStore.rename(serverId: serverId, newName: newName)
                        }
                    )
                } else {
                    LitterTheme.backgroundGradient.ignoresSafeArea()
                }
            }
            .overlay(alignment: .bottom) {
                if isHomeRouteActive, experimentalFeatures.isEnabled(.realtimeVoice) {
                    homeVoiceLauncher
                }
            }
            .navigationDestination(for: HomeNavigationRoute.self) { route in
                switch route {
                case let .sessions(serverId, title):
                    SessionsScreen(
                        onOpenConversation: { key in
                            openConversation(key)
                        },
                        onInfo: {
                            navigationPath.append(.serverInfo(serverId: serverId))
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
                        onOpenConversation: { replaceTopConversation(with: $0) },
                        onInfo: { navigationPath.append(.conversationInfo(threadKey)) }
                    )
                case let .realtimeVoice(threadKey):
                    RealtimeVoiceScreen(
                        threadKey: threadKey,
                        onEnd: {
                            popCurrentRoute()
                            Task { await voiceRuntime.stopActiveVoiceSession() }
                        },
                        onToggleSpeaker: {
                            Task { try? await voiceRuntime.toggleActiveVoiceSessionSpeaker() }
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                case let .conversationInfo(threadKey):
                    ConversationInfoView(
                        threadKey: threadKey,
                        serverId: nil,
                        onOpenWallpaper: { navigationPath.append(.wallpaperSelection(threadKey)) },
                        onOpenConversation: { replaceTopConversation(with: $0) }
                    )
                case let .wallpaperSelection(threadKey):
                    WallpaperSelectionView(
                        threadKey: threadKey,
                        onSelectWallpaper: { config, image in
                            pendingWallpaperConfig = config
                            pendingWallpaperImage = image
                            navigationPath.append(.wallpaperAdjust(threadKey))
                        },
                        onClose: {
                            // Pop back to conversation info
                            popToConversationInfo()
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                case let .wallpaperAdjust(threadKey):
                    WallpaperAdjustView(
                        threadKey: threadKey,
                        initialConfig: pendingWallpaperConfig ?? WallpaperConfig(),
                        customImage: pendingWallpaperImage,
                        onDone: {
                            // Pop back to conversation info
                            popToConversationInfo()
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                case let .serverInfo(serverId):
                    ConversationInfoView(
                        threadKey: nil,
                        serverId: serverId,
                        onOpenWallpaper: { navigationPath.append(.serverWallpaperSelection(serverId: serverId)) }
                    )
                case let .serverWallpaperSelection(serverId):
                    WallpaperSelectionView(
                        threadKey: nil,
                        serverId: serverId,
                        onSelectWallpaper: { config, image in
                            pendingWallpaperConfig = config
                            pendingWallpaperImage = image
                            navigationPath.append(.serverWallpaperAdjust(serverId: serverId))
                        },
                        onClose: {
                            popToServerInfo()
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                case let .serverWallpaperAdjust(serverId):
                    WallpaperAdjustView(
                        threadKey: nil,
                        serverId: serverId,
                        initialConfig: pendingWallpaperConfig ?? WallpaperConfig(),
                        customImage: pendingWallpaperImage,
                        onDone: {
                            popToServerInfo()
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                }
            }
        }
        .task {
            homeDashboardModel.bind(appModel: appModel)
            updateHomeDashboardActivity()
            seedInitialConversationIfNeeded(activeKey: appModel.snapshot?.activeThread)
        }
        .onChange(of: appModel.snapshot?.activeThread) { _, newKey in
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
            activeThreadKey: appModel.snapshot?.activeThread,
            preferredServerId: preferredServerId
        )
    }

    private func handleNewSessionTap() {
        if let defaultServerId = defaultNewSessionServerId(preferredServerId: appState.sessionsSelectedServerFilterId) {
            // For local on-device server, skip directory picker and use /home/codex.
            if let server = homeDashboardModel.connectedServers.first(where: { $0.id == defaultServerId }),
               server.isLocal {
                let cwd = codex_ios_default_cwd() as String? ?? NSHomeDirectory()
                Task { await startNewSession(serverId: defaultServerId, cwd: cwd) }
                return
            }
            directoryPickerSheet = SessionLaunchSupport.DirectoryPickerSheetModel(selectedServerId: defaultServerId)
        } else {
            appState.showServerPicker = true
        }
    }

    private var homeVoiceLauncher: some View {
        HStack {
            Spacer()
            HomeVoiceOrbButton(
                session: voiceRuntime.activeVoiceSession,
                isAvailable: true,
                isStarting: isStartingVoice,
                action: startHomeVoiceSession
            )
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, max(bottomInset - 12, 6))
    }

    private func startHomeVoiceSession() {
        guard !isStartingVoice else { return }
        isStartingVoice = true
        actionErrorMessage = nil

        Task {
            do {
                let selectedModel = normalizedSelectedModel()
                let selectedEffort = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                voiceRuntime.handoffModel = selectedModel
                voiceRuntime.handoffEffort = selectedEffort.isEmpty ? nil : selectedEffort
                voiceRuntime.handoffFastMode = false
                try await voiceRuntime.startPinnedLocalVoiceCall(
                    cwd: preferredVoiceWorkingDirectory(),
                    model: selectedModel,
                    approvalPolicy: appState.approvalPolicy,
                    sandboxMode: appState.sandboxMode
                )
                if let voiceKey = await MainActor.run(body: { voiceRuntime.activeVoiceSession?.threadKey }) {
                    await MainActor.run {
                        openRealtimeVoice(voiceKey)
                    }
                }
            } catch {
                await MainActor.run {
                    actionErrorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                isStartingVoice = false
            }
        }
    }

    private func normalizedSelectedModel() -> String? {
        let trimmed = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func preferredVoiceWorkingDirectory() -> String {
        let current = appState.currentCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            return current
        }

        let stored = UserDefaults.standard.string(forKey: "workDir")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty {
            return stored
        }

        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    }

    private func openServerSessions(_ server: HomeDashboardServer) {
        appState.sessionsSelectedServerFilterId = server.id
        appState.sessionsShowOnlyForks = false
        hasSeededInitialConversationRoute = true
        navigationPath.append(.sessions(serverId: server.id, title: server.displayName))
    }

    private func openRecentSession(_ thread: HomeDashboardRecentSession) async {
        guard openingRecentSessionKey == nil else { return }
        openingRecentSessionKey = thread.key
        actionErrorMessage = nil
        defer { openingRecentSessionKey = nil }

        await conversationWarmup.prewarmIfNeeded()
        workDir = thread.cwd
        appState.currentCwd = thread.cwd
        let openedKey: ThreadKey?
        do {
            let nextKey = try await appModel.client.resumeThread(
                serverId: thread.key.serverId,
                params: launchConfig().threadResumeRequest(
                    threadId: thread.key.threadId,
                    cwdOverride: thread.cwd
                )
            )
            appModel.store.setActiveThread(key: nextKey)
            await appModel.refreshSnapshot()
            openedKey = nextKey
        } catch {
            actionErrorMessage = error.localizedDescription
            openedKey = nil
        }
        guard let openedKey else {
            actionErrorMessage = actionErrorMessage ?? "Failed to open conversation."
            return
        }
        openConversation(openedKey)
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
        let startedKey: ThreadKey
        do {
            let key = try await appModel.client.startThread(
                serverId: serverId,
                params: launchConfig().threadStartRequest(cwd: cwd)
            )
            startedKey = key
            appModel.store.setActiveThread(key: startedKey)
            await appModel.refreshSnapshot()
        } catch {
            actionErrorMessage = error.localizedDescription
            return
        }

        guard let resolvedKey = await appModel.ensureThreadLoaded(key: startedKey)
            ?? appModel.snapshot?.threadSnapshot(for: startedKey)?.key else {
            actionErrorMessage = appModel.lastError ?? "Failed to load the new session."
            return
        }

        openConversation(resolvedKey)
    }

    private func seedInitialConversationIfNeeded(activeKey: ThreadKey?) {
        guard !hasSeededInitialConversationRoute,
              !isStartingVoice,
              navigationPath.isEmpty,
              let activeKey else { return }

        Task { @MainActor in
            await conversationWarmup.prewarmIfNeeded()
            guard !hasSeededInitialConversationRoute,
                  !isStartingVoice,
                  navigationPath.isEmpty,
                  appModel.snapshot?.activeThread == activeKey else {
                return
            }
            hasSeededInitialConversationRoute = true
            navigationPath = [.conversation(activeKey)]
        }
    }

    private func launchConfig() -> AppThreadLaunchConfig {
        let selectedModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppThreadLaunchConfig(
            model: selectedModel.isEmpty ? nil : selectedModel,
            approvalPolicy: AppAskForApproval(wireValue: appState.approvalPolicy),
            sandbox: AppSandboxMode(wireValue: appState.sandboxMode),
            developerInstructions: nil,
            persistExtendedHistory: true
        )
    }

    private func openConversation(_ key: ThreadKey) {
        hasSeededInitialConversationRoute = true
        appState.showModelSelector = false
        guard navigationPath.last != .conversation(key) else { return }
        navigationPath.append(.conversation(key))
    }

    private func openRealtimeVoice(_ key: ThreadKey) {
        hasSeededInitialConversationRoute = true
        appState.showModelSelector = false
        guard navigationPath.last != .realtimeVoice(key) else { return }
        navigationPath.append(.realtimeVoice(key))
    }

    private func popToConversationInfo() {
        // Pop wallpaper selection and/or adjust screens, back to conversation info
        while let last = navigationPath.last {
            if case .conversationInfo = last { break }
            navigationPath.removeLast()
        }
    }

    private func popToServerInfo() {
        while let last = navigationPath.last {
            if case .serverInfo = last { break }
            navigationPath.removeLast()
        }
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
        } else if case .realtimeVoice = navigationPath.last {
            navigationPath.removeLast()
        }
        navigationPath.append(.sessions(serverId: serverId, title: serverTitle(for: serverId)))
    }

    private func serverTitle(for serverId: String) -> String {
        if let server = homeDashboardModel.connectedServers.first(where: { $0.id == serverId }) {
            return server.displayName
        }
        if let thread = homeDashboardModel.recentSessions.first(where: { $0.serverId == serverId }) {
            return thread.serverDisplayName
        }
        return "Sessions"
    }
}

private struct ConversationDestinationScreen: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @State private var screenModel = ConversationScreenModel()
    let threadKey: ThreadKey
    let topInset: CGFloat
    let bottomInset: CGFloat
    let onBack: () -> Void
    let onResumeSessions: (String) -> Void
    let onOpenConversation: (ThreadKey) -> Void
    var onInfo: (() -> Void)?

    private var conversationThread: AppThreadSnapshot? {
        if let exact = appModel.snapshot?.threadSnapshot(for: threadKey) {
            return exact
        }
        guard let activeKey = appModel.snapshot?.activeThread,
              activeKey.serverId == threadKey.serverId else {
            return nil
        }
        return appModel.snapshot?.threadSnapshot(for: activeKey)
    }

    private var resolvedThreadKey: ThreadKey {
        conversationThread?.key ?? threadKey
    }

    private func bindScreenModel(for thread: AppThreadSnapshot) {
        screenModel.bind(
            thread: thread,
            appModel: appModel,
            agentDirectoryVersion: appModel.snapshot?.agentDirectoryVersion ?? 0
        )
    }

    var body: some View {
        Group {
            if let conversationThread {
                ZStack(alignment: .top) {
                    ConversationView(
                        thread: conversationThread,
                        activeThreadKey: resolvedThreadKey,
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
                        thread: conversationThread,
                        onBack: onBack,
                        onInfo: onInfo,
                        topInset: topInset
                    )
                    .zIndex(2)
                }
                .onAppear {
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: conversationThread) { _, updatedThread in
                    bindScreenModel(for: updatedThread)
                }
                .onChange(of: appModel.snapshot?.agentDirectoryVersion) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: appModel.snapshot) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView()
                        .tint(LitterTheme.accent)
                    Text("Loading thread...")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                .overlay(alignment: .topLeading) {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .litterFont(size: 14, weight: .semibold)
                            Text("Back")
                                .litterFont(.callout)
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
            appModel.store.setActiveThread(key: threadKey)
            if appModel.snapshot?.threadSnapshot(for: threadKey) == nil {
                _ = await appModel.ensureThreadLoaded(key: threadKey)
            }
            await appModel.loadConversationMetadataIfNeeded(serverId: threadKey.serverId)
            if let thread = conversationThread,
               let cwd = thread.info.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cwd.isEmpty {
                workDir = cwd
                appState.currentCwd = cwd
            }
        }
    }
}

private struct ApprovalPromptView: View {
    let approval: PendingApproval
    let onDecision: (ApprovalDecisionValue) -> Void
    var onViewThread: ((ThreadKey) -> Void)? = nil

    private var title: String {
        switch approval.kind {
        case .command:
            return "Command Approval Required"
        case .fileChange:
            return "File Change Approval Required"
        case .permissions:
            return "Permissions Approval Required"
        case .mcpElicitation:
            return "MCP Input Required"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .litterFont(.headline)
                    .foregroundColor(LitterTheme.textPrimary)

                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.textSecondary)
                }

                if let threadId = approval.threadId, onViewThread != nil {
                    HStack {
                        Button {
                            onViewThread?(ThreadKey(serverId: approval.serverId, threadId: threadId))
                        } label: {
                            HStack(spacing: 3) {
                                Text("View Thread")
                                    .litterFont(.caption, weight: .medium)
                                Image(systemName: "arrow.right")
                                    .litterFont(size: 9, weight: .semibold)
                            }
                            .foregroundColor(LitterTheme.accent)
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                }

                if let command = approval.command, !command.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command")
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textMuted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(command)
                                .litterFont(.footnote)
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
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textMuted)
                }

                if let grantRoot = approval.grantRoot, !grantRoot.isEmpty {
                    Text("Grant Root: \(grantRoot)")
                        .litterFont(.caption)
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
                .litterFont(.callout)
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
                    .litterFont(.body)
                    .foregroundColor(LitterTheme.textMuted)
            }
        }
    }
}
