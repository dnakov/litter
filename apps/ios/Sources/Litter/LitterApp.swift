import SwiftUI
import UIKit
import UserNotifications
import os

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var pendingPushToken: Data?
    private var pendingNotificationThreadKey: ThreadKey?
    private var splashWindow: UIWindow?
    private var minTimeElapsed = false
    private var contentReady = false
    private var splashDismissed = false

    weak var appRuntime: AppRuntimeController? {
        didSet {
            if let token = pendingPushToken {
                LLog.info("push", "delivering pending device token to runtime")
                appRuntime?.setDevicePushToken(token)
                pendingPushToken = nil
            }
            if let key = pendingNotificationThreadKey {
                LLog.info(
                    "push",
                    "delivering pending notification thread open to runtime",
                    fields: ["serverId": key.serverId, "threadId": key.threadId]
                )
                pendingNotificationThreadKey = nil
                openThreadFromNotification(key)
            }
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        codex_ios_system_init()
        LLog.bootstrap()
        LLog.info("lifecycle", "application did finish launching")
        OpenAIApiKeyStore.shared.applyToEnvironment()
        // Pre-initialize Rust bridges (tokio runtime) on a background thread
        // before SwiftUI accesses AppModel.shared, avoiding a priority inversion
        // where the main thread blocks on lower-QoS tokio worker init.
        DispatchQueue.global(qos: .userInitiated).async {
            AppModel.prewarmRustBridges()
        }
        application.registerForRemoteNotifications()
        UNUserNotificationCenter.current().delegate = self
        OrientationResponder.shared.start()
        showSplashWindow()
        scheduleKeyboardWarmup()
        // Start pushing state to the paired Apple Watch, gated behind the
        // experimental feature flag. Flip the `appleWatch` feature in
        // Settings → Experimental Features to enable. No-op when disabled.
        DispatchQueue.main.async {
            if ExperimentalFeatures.shared.isEnabled(.appleWatch) {
                WatchCompanionBridge.shared.start()
            }
        }
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
        LLog.info(
            "push",
            "background push received",
            fields: [
                "applicationState": application.applicationState.debugName
            ],
            payloadJson: notificationPayloadJson(userInfo)
        )
        if application.applicationState == .active {
            LLog.info("push", "skipping background push handler because app is already active")
            completionHandler(.noData)
            return
        }
        guard let appRuntime else {
            LLog.warn("push", "background push received before runtime was ready")
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await appRuntime.handleBackgroundPush()
            LLog.info("push", "background push handling completed", fields: ["result": "newData"])
            completionHandler(.newData)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        LLog.info(
            "push",
            "user opened notification",
            payloadJson: notificationPayloadJson(response.notification.request.content.userInfo)
        )
        if let key = AppLifecycleController.notificationThreadKey(
            from: response.notification.request.content.userInfo
        ) {
            openThreadFromNotification(key)
        }
        completionHandler()
    }

    private func openThreadFromNotification(_ key: ThreadKey) {
        LLog.info(
            "push",
            "open thread from notification",
            fields: ["serverId": key.serverId, "threadId": key.threadId]
        )
        if appRuntime == nil {
            pendingNotificationThreadKey = key
            return
        }

        Task { @MainActor [weak self] in
            guard let self, let appRuntime = self.appRuntime else { return }
            await appRuntime.openThreadFromNotification(key: key)
        }
    }

    private func notificationPayloadJson(_ userInfo: [AnyHashable: Any]) -> String? {
        guard !userInfo.isEmpty else { return nil }
        let payload = Dictionary(uniqueKeysWithValues: userInfo.map { key, value in
            (String(describing: key), String(describing: value))
        })
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
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
                    appRuntime.appDidBecomeActive()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            LLog.info("lifecycle", "scenePhase changed", fields: ["phase": newPhase.debugName])
            switch newPhase {
            case .background:
                appRuntime.appDidEnterBackground()
            case .inactive:
                appRuntime.appDidBecomeInactive()
            case .active:
                appRuntime.appDidBecomeActive()
            default:
                break
            }
        }
    }
}

private extension UIApplication.State {
    var debugName: String {
        switch self {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
}

private extension ScenePhase {
    var debugName: String {
        switch self {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
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
                .environment(appState)
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
    @State private var showProjectPicker = false
    @State private var openingRecentSessionKey: ThreadKey?
    @State private var isStartingNewSession = false
    @State private var isStartingVoice = false
    @State private var actionErrorMessage: String?
    @State private var homeInputMode: HomeInputMode = .collapsed
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
        case replayRecording(URL)
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
                    homeDashboard
                } else {
                    LitterTheme.backgroundGradient.ignoresSafeArea()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isHomeRouteActive,
                   experimentalFeatures.isEnabled(.realtimeVoice),
                   homeInputMode == .collapsed {
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
                        bottomInset: bottomInset,
                        onResumeSessions: { showSessions(for: $0) },
                        onOpenConversation: { replaceTopConversation(with: $0) },
                        onInfo: { navigationPath.append(.conversationInfo(threadKey)) }
                    )
                case let .replayRecording(recordingUrl):
                    ReplayDestinationScreen(
                        recordingUrl: recordingUrl,
                        bottomInset: bottomInset
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
                        createAndSelectProject(serverId: serverId, cwd: cwd)
                    },
                    onDismissRequested: {
                        directoryPickerSheet = nil
                    }
                )
            }
        }
        .sheet(isPresented: $showProjectPicker) {
            ProjectPickerSheet(
                projects: homeDashboardModel.projects,
                serverNamesById: Dictionary(uniqueKeysWithValues: homeDashboardModel.connectedServers.map { ($0.id, $0.displayName) }),
                onSelect: { project in
                    homeDashboardModel.selectedServerId = project.serverId
                    homeDashboardModel.selectedProject = project
                },
                onCreateNew: {
                    showProjectPicker = false
                    let defaultServerId = homeDashboardModel.selectedServerId ?? defaultNewSessionServerId()
                    if let defaultServerId {
                        directoryPickerSheet = SessionLaunchSupport.DirectoryPickerSheetModel(selectedServerId: defaultServerId)
                    } else {
                        appState.showServerPicker = true
                    }
                }
            )
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

    private func createAndSelectProject(serverId: String, cwd: String) {
        homeDashboardModel.selectFreshProject(serverId: serverId, cwd: cwd)
        RecentDirectoryStore.shared.record(path: cwd, for: serverId)
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
        HomeVoiceOrbButton(
            session: voiceRuntime.activeVoiceSession,
            isAvailable: true,
            isStarting: isStartingVoice,
            action: startHomeVoiceSession
        )
        // Match the bottom inset used by `HomeBottomBar` inside
        // `HomeDashboardView.bottomChrome` so the mic button sits on the
        // same horizontal line as the `+` and search pills on the right.
        .padding(.leading, 14)
        .padding(.bottom, 4)
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
                let voicePermissions = await voicePermissionConfig()
                try await voiceRuntime.startPinnedLocalVoiceCall(
                    cwd: preferredVoiceWorkingDirectory(),
                    model: selectedModel,
                    approvalPolicy: voicePermissions.approvalPolicy,
                    sandboxMode: voicePermissions.sandboxMode
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
            let resumeKey = await appModel.hydrateThreadPermissions(for: thread.key, appState: appState)
                ?? thread.key
            let nextKey = try await appModel.resumeThread(
                key: resumeKey,
                launchConfig: launchConfig(for: resumeKey),
                cwdOverride: thread.cwd
            )
            appModel.activateThread(nextKey)
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
                params: launchConfig().threadStartRequest(
                    cwd: cwd,
                    dynamicTools: ExperimentalFeatures.shared.isEnabled(.generativeUI)
                        ? generativeUiDynamicToolSpecs() : nil
                )
            )
            startedKey = key
            RecentDirectoryStore.shared.record(path: cwd, for: serverId)
            homeDashboardModel.pinThread(key)
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

    private func launchConfig(for threadKey: ThreadKey? = nil) -> AppThreadLaunchConfig {
        let selectedModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppThreadLaunchConfig(
            model: selectedModel.isEmpty ? nil : selectedModel,
            approvalPolicy: appState.launchApprovalPolicy(for: threadKey),
            sandbox: appState.launchSandboxMode(for: threadKey),
            developerInstructions: nil,
            persistExtendedHistory: true
        )
    }

    private func voicePermissionConfig() async -> (
        approvalPolicy: AppAskForApproval?,
        sandboxMode: AppSandboxMode?
    ) {
        let storedThreadId = UserDefaults.standard.string(forKey: VoiceRuntimeController.persistedLocalVoiceThreadIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let threadKey = storedThreadId.flatMap { threadId -> ThreadKey? in
            guard !threadId.isEmpty else { return nil }
            return ThreadKey(serverId: VoiceRuntimeController.localServerID, threadId: threadId)
        }
        let resolvedThreadKey: ThreadKey?
        if let threadKey {
            resolvedThreadKey = await appModel.hydrateThreadPermissions(for: threadKey, appState: appState)
                ?? threadKey
        } else {
            resolvedThreadKey = nil
        }
        return (
            approvalPolicy: appState.launchApprovalPolicy(for: resolvedThreadKey),
            sandboxMode: appState.launchSandboxMode(for: resolvedThreadKey)
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

    private var homeDashboard: some View {
        HomeDashboardView(
            recentSessions: homeDashboardModel.recentSessions,
            allSessions: homeDashboardModel.allSessions,
            pinnedThreadKeys: homeDashboardModel.pinnedKeys,
            connectedServers: homeDashboardModel.connectedServers,
            projects: homeDashboardModel.projects,
            selectedServerId: homeDashboardModel.selectedServerId,
            selectedProject: homeDashboardModel.selectedProject,
            openingRecentSessionKey: openingRecentSessionKey,
            onOpenRecentSession: openRecentSession,
            onSelectServer: handleSelectServer,
            onAddServer: { appState.showServerPicker = true },
            onOpenProjectPicker: { showProjectPicker = true },
            onThreadCreated: { key in homeDashboardModel.pinThread(key) },
            onShowSettings: { appState.showSettings = true },
            onPinThread: pinThread,
            onUnpinThread: unpinThread,
            onHideThread: hideThread,
            onHydrateThread: hydrateThread,
            onDeleteThread: deleteThread,
            onReconnectServer: reconnectServer,
            onDisconnectServer: disconnectServer,
            onRenameServer: renameServer,
            onOpenRecording: { url in
                navigationPath.append(.replayRecording(url))
            },
            onSendReply: sendQuickReply,
            onCancelThread: cancelThread,
            onInputModeChange: { mode in
                homeInputMode = mode
            },
            onLoadAllThreads: loadAllThreads
        )
    }

    private func handleSelectServer(_ server: HomeDashboardServer) {
        if homeDashboardModel.selectedServerId == server.id {
            homeDashboardModel.clearScope()
        } else {
            homeDashboardModel.selectedServerId = server.id
        }
    }

    private func pinThread(_ key: ThreadKey) {
        homeDashboardModel.pinThread(key)
    }

    private func unpinThread(_ key: ThreadKey) {
        homeDashboardModel.unpinThread(key)
    }

    private func hideThread(_ key: ThreadKey) {
        homeDashboardModel.hideThread(key)
    }

    private func hydrateThread(_ key: ThreadKey) async {
        // Resume rather than just read: `external_resume_thread` loads the
        // thread's items AND attaches a server-side conversation listener
        // for this connection, so we get live `TurnStarted` / `ItemStarted`
        // / `MessageDelta` / `TurnCompleted` events. Without it the server
        // would only push `ThreadStatusChanged` — the active-turn dot would
        // flip but the streaming bubble, tool log, and session-summary
        // updates would stay frozen until the user opened the thread.
        //
        // For the home list the listener cost is still low enough, and
        // resuming preemptively avoids the "first half-second of a stream
        // is missed while we set up a subscription" latency window that an
        // active-only subscription strategy would have. `externalResume`
        // short-circuits to a no-op when IPC is live and the thread's
        // items are already populated, so warm/IPC paths are cheap.
        try? await appModel.store.externalResumeThread(key: key, hostId: nil)
        await appModel.refreshSnapshot()
    }

    private func deleteThread(_ key: ThreadKey) async {
        _ = try? await appModel.client.archiveThread(
            serverId: key.serverId,
            params: AppArchiveThreadRequest(threadId: key.threadId)
        )
        await appModel.refreshSnapshot()
    }

    @MainActor
    private func cancelThread(_ threadKey: ThreadKey) async {
        // Look up the thread's active turn id — interrupt requires both.
        guard let thread = appModel.snapshot?.threadSnapshot(for: threadKey),
              let turnId = thread.activeTurnId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !turnId.isEmpty else {
            return
        }
        do {
            _ = try await appModel.client.interruptTurn(
                serverId: threadKey.serverId,
                params: AppInterruptTurnRequest(
                    threadId: threadKey.threadId,
                    turnId: turnId
                )
            )
            await appModel.refreshSnapshot()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func sendQuickReply(_ threadKey: ThreadKey, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The server needs the thread resumed before `startTurn` can find
        // it — same path `openRecentSession` takes. On a cold launch the
        // thread is in hydrated snapshot state but not yet registered with
        // the upstream session, so a quick-reply without resume would fail
        // with "thread cannot be found".
        let resumeKey = await appModel.hydrateThreadPermissions(for: threadKey, appState: appState)
            ?? threadKey
        let activeKey: ThreadKey
        do {
            activeKey = try await appModel.resumeThread(
                key: resumeKey,
                launchConfig: launchConfig(for: resumeKey),
                cwdOverride: nil
            )
        } catch {
            actionErrorMessage = error.localizedDescription
            return
        }
        let payload = AppComposerPayload(
            text: trimmed,
            additionalInputs: [],
            approvalPolicy: appState.launchApprovalPolicy(for: activeKey),
            sandboxPolicy: appState.turnSandboxPolicy(for: activeKey),
            model: nil,
            effort: nil,
            serviceTier: nil
        )
        do {
            try await appModel.startTurn(key: activeKey, payload: payload)
            await appModel.refreshSnapshot()
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func reconnectServer(_ server: HomeDashboardServer) {
        Task {
            await AppRuntimeController.shared.reconnectServer(serverId: server.id)
        }
    }

    private func disconnectServer(_ serverId: String) {
        SavedServerStore.remove(serverId: serverId)
        Task { await SshSessionStore.shared.close(serverId: serverId, ssh: appModel.ssh) }
        appModel.serverBridge.disconnectServer(serverId: serverId)
    }

    private func renameServer(_ serverId: String, newName: String) {
        SavedServerStore.rename(serverId: serverId, newName: newName)
        appModel.reconnectController.syncSavedServers(
            servers: SavedServerStore.reconnectRecords(
                localDisplayName: appModel.resolvedLocalServerDisplayName()
            )
        )
        appModel.store.renameServer(serverId: serverId, displayName: newName)
    }

    @Sendable
    private func loadAllThreads() async {
        await withTaskGroup(of: Void.self) { group in
            for server in homeDashboardModel.connectedServers {
                let serverId = server.id
                group.addTask {
                    _ = try? await appModel.client.listThreads(
                        serverId: serverId,
                        params: AppListThreadsRequest(
                            cursor: nil,
                            limit: nil,
                            archived: nil,
                            cwd: nil,
                            searchTerm: nil
                        )
                    )
                }
            }
        }
        await appModel.refreshSnapshot()
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
    let bottomInset: CGFloat
    let onResumeSessions: (String) -> Void
    let onOpenConversation: (ThreadKey) -> Void
    var onInfo: (() -> Void)?

    private var conversationThread: AppThreadSnapshot? {
        appModel.threadSnapshot(for: threadKey)
    }

    private var resolvedThreadKey: ThreadKey {
        conversationThread?.key ?? threadKey
    }

    private var pendingUserInputsForThread: [PendingUserInputRequest] {
        guard let snapshot = appModel.snapshot else { return [] }
        let key = resolvedThreadKey
        return snapshot.pendingUserInputs.filter {
            $0.serverId == key.serverId && $0.threadId == key.threadId
        }
    }

    private var relevantServerSnapshot: AppServerSnapshot? {
        appModel.snapshot?.serverSnapshot(for: resolvedThreadKey.serverId)
    }

    private func bindScreenModel(for thread: AppThreadSnapshot) {
        screenModel.bind(
            thread: thread,
            appModel: appModel,
            agentDirectoryVersion: appModel.snapshot?.agentDirectoryVersion ?? 0
        )
    }

    private var navigationTitle: String {
        conversationThread?.displayTitle ?? "Conversation"
    }

    var body: some View {
        Group {
            if let conversationThread {
                ConversationView(
                    thread: conversationThread,
                    activeThreadKey: resolvedThreadKey,
                    transcript: screenModel.transcript,
                    followScrollToken: screenModel.followScrollToken,
                    pinnedContextItems: screenModel.pinnedContextItems,
                    composer: screenModel.composer,
                    topInset: 0,
                    bottomInset: bottomInset,
                    onOpenConversation: onOpenConversation,
                    onResumeSessions: onResumeSessions
                )
                .onAppear {
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: conversationThread) { _, updatedThread in
                    bindScreenModel(for: updatedThread)
                }
                .onChange(of: appModel.snapshotRevision) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: pendingUserInputsForThread) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: relevantServerSnapshot) { _, _ in
                    bindScreenModel(for: conversationThread)
                }
                .onChange(of: appModel.composerPrefillRequest) { _, _ in
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
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let conversationThread {
                ToolbarItem(placement: .principal) {
                    HeaderView(thread: conversationThread)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ConversationToolbarControls(
                        thread: conversationThread,
                        control: .reload
                    )
                }
                if onInfo != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        ConversationToolbarControls(
                            thread: conversationThread,
                            control: .info,
                            onInfo: onInfo
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
        .task(id: threadKey) {
            os_signpost(
                .event,
                log: conversationRouteSignpostLog,
                name: "ThreadOpenStarted",
                "server=%{public}@ thread=%{public}@",
                threadKey.serverId,
                threadKey.threadId
            )
            appModel.activateThread(threadKey)
            if appModel.threadSnapshot(for: threadKey) == nil {
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

private struct ReplayDestinationScreen: View {
    @Environment(AppModel.self) private var appModel
    let recordingUrl: URL
    let bottomInset: CGFloat
    @State private var screenModel = ConversationScreenModel()
    @State private var replayThreadKey: ThreadKey?
    @State private var recorder = MessageRecorder.shared

    private var conversationThread: AppThreadSnapshot? {
        guard let key = replayThreadKey else { return nil }
        return appModel.threadSnapshot(for: key)
    }

    var body: some View {
        Group {
            if let thread = conversationThread, let key = replayThreadKey {
                ConversationView(
                    thread: thread,
                    activeThreadKey: key,
                    transcript: screenModel.transcript,
                    followScrollToken: screenModel.followScrollToken,
                    pinnedContextItems: screenModel.pinnedContextItems,
                    composer: screenModel.composer,
                    topInset: 0,
                    bottomInset: bottomInset,
                    onOpenConversation: nil,
                    onResumeSessions: { _ in }
                )
                .onAppear { bindScreenModel(for: thread) }
                .onChange(of: thread) { _, t in bindScreenModel(for: t) }
                .onChange(of: appModel.snapshotRevision) { _, _ in
                    if let t = conversationThread { bindScreenModel(for: t) }
                }
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView()
                        .tint(LitterTheme.accent)
                    Text(recorder.isReplaying ? "Replaying..." : "Starting replay...")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            }
        }
        .navigationTitle("Replay")
        .navigationBarTitleDisplayMode(.inline)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
        .task {
            let targetKey: ThreadKey
            if let server = appModel.snapshot?.servers.first {
                targetKey = ThreadKey(serverId: server.serverId, threadId: UUID().uuidString)
            } else {
                targetKey = ThreadKey(serverId: "replay", threadId: UUID().uuidString)
            }
            replayThreadKey = targetKey
            appModel.activateThread(targetKey)
            recorder.startReplay(url: recordingUrl, store: appModel.store, targetKey: targetKey)
        }
        .onDisappear {
            recorder.stopReplay()
        }
    }

    private func bindScreenModel(for thread: AppThreadSnapshot) {
        screenModel.bind(
            thread: thread,
            appModel: appModel,
            agentDirectoryVersion: appModel.snapshot?.agentDirectoryVersion ?? 0
        )
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
