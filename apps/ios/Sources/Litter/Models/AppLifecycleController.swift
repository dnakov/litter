import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor
final class AppLifecycleController {
    static let notificationServerIdKey = "litter.notification.serverId"
    static let notificationThreadIdKey = "litter.notification.threadId"

    struct BackgroundTurnReconciliation {
        let remainingKeys: Set<ThreadKey>
        let activeThreads: [AppThreadSnapshot]
        let completedNotificationThread: AppThreadSnapshot?
    }

    private let pushProxy = PushProxyClient()
    private var pushProxyRegistrationId: String?
    private var devicePushToken: Data?
    private var backgroundedTurnKeys: Set<ThreadKey> = []
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var bgWakeCount: Int = 0
    private var notificationPermissionRequested = false
    private var hasRecoveredCurrentForegroundSession = false
    private var hasEnteredBackgroundSinceLaunch = false
    private var foregroundRecoveryTask: Task<Void, Never>?
    private var foregroundRecoveryID: UUID?

    func setDevicePushToken(_ token: Data) {
        devicePushToken = token
    }

    func reconnectSavedServers(appModel: AppModel) async {
        let plans = SavedServerStore.rememberedServers().compactMap {
            reconnectPlan(for: $0, appModel: appModel)
        }

        let tasks = plans.map { plan in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runReconnectPlan(plan, appModel: appModel)
            }
        }

        for task in tasks {
            await task.value
        }

        await appModel.refreshSnapshot()
    }

    func reconnectServer(serverId: String, appModel: AppModel) async {
        let snapshotServer = appModel.snapshot?.serverSnapshot(for: serverId)
        if snapshotServer?.isLocal == true || serverId == "local" {
            try? await appModel.restartLocalServer()
            return
        }

        if let savedServer = SavedServerStore.load().first(where: { $0.id == serverId }),
           let plan = reconnectPlan(
            for: savedServer,
            appModel: appModel,
            skipIfAlreadyConnected: false
           ) {
            await SshSessionStore.shared.close(serverId: serverId, ssh: appModel.ssh)
            appModel.serverBridge.disconnectServer(serverId: serverId)
            await runReconnectPlan(plan, appModel: appModel)
            await appModel.refreshSnapshot()
            return
        }

        await SshSessionStore.shared.close(serverId: serverId, ssh: appModel.ssh)
        appModel.serverBridge.disconnectServer(serverId: serverId)
        if let snapshotServer {
            _ = try? await appModel.serverBridge.connectRemoteServer(
                serverId: snapshotServer.serverId,
                displayName: snapshotServer.displayName,
                host: snapshotServer.host,
                port: snapshotServer.port
            )
        }
        await appModel.refreshSnapshot()
    }

    private func reconnectSSHServer(
        appModel: AppModel,
        serverId: String,
        displayName: String,
        host: String,
        port: UInt16,
        credentials: SSHCredentials
    ) async throws {
        let authMethod: String = switch credentials {
        case .password:
            "password"
        case .key:
            "private_key"
        }
        LLog.trace(
            "lifecycle",
            "reconnecting saved SSH server",
            fields: [
                "serverId": serverId,
                "host": host,
                "sshPort": Int(port),
                "authMethod": authMethod
            ]
        )
        let ipcSocketPathOverride = ExperimentalFeatures.shared.ipcSocketPathOverride()
        switch credentials {
        case .password(let username, let password):
            _ = try await appModel.ssh.sshStartRemoteServerConnect(
                serverId: serverId,
                displayName: displayName,
                host: host,
                port: port,
                username: username,
                password: password,
                privateKeyPem: nil,
                passphrase: nil,
                acceptUnknownHost: true,
                workingDir: nil,
                ipcSocketPathOverride: ipcSocketPathOverride
            )
        case .key(let username, let privateKey, let passphrase):
            _ = try await appModel.ssh.sshStartRemoteServerConnect(
                serverId: serverId,
                displayName: displayName,
                host: host,
                port: port,
                username: username,
                password: nil,
                privateKeyPem: privateKey,
                passphrase: passphrase,
                acceptUnknownHost: true,
                workingDir: nil,
                ipcSocketPathOverride: ipcSocketPathOverride
            )
        }
    }

    func appDidEnterBackground(
        snapshot: AppSnapshotRecord?,
        hasActiveVoiceSession: Bool,
        liveActivities: TurnLiveActivityController
    ) {
        hasEnteredBackgroundSinceLaunch = true
        hasRecoveredCurrentForegroundSession = false
        foregroundRecoveryTask?.cancel()
        foregroundRecoveryTask = nil
        foregroundRecoveryID = nil
        guard !hasActiveVoiceSession else { return }
        let activeThreads = snapshot?.threadsWithTrackedTurns ?? []
        guard !activeThreads.isEmpty else { return }

        backgroundedTurnKeys = Set(activeThreads.map(\.key))
        bgWakeCount = 0
        liveActivities.sync(snapshot)
        registerPushProxy()

        let bgID = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard let self else { return }
            let expiredID = self.backgroundTaskID
            self.backgroundTaskID = .invalid
            UIApplication.shared.endBackgroundTask(expiredID)
        }
        backgroundTaskID = bgID
    }

    func appDidBecomeActive(
        appModel: AppModel,
        hasActiveVoiceSession: Bool,
        liveActivities: TurnLiveActivityController
    ) {
        deregisterPushProxy()
        endBackgroundTaskIfNeeded()
        guard !hasActiveVoiceSession else { return }
        guard !hasRecoveredCurrentForegroundSession else { return }
        hasRecoveredCurrentForegroundSession = true
        let needsInitialReconnect = !hasEnteredBackgroundSinceLaunch
        let preResumeActiveSSHServerIDs = Set((appModel.snapshot?.servers ?? [])
            .filter { !$0.isLocal && $0.health != .disconnected }
            .map(\.serverId))
        let currentSnapshot = appModel.snapshot
        let backgroundedKeys = backgroundedTurnKeys
        backgroundedTurnKeys.removeAll()
        var keysToRefresh = Set(currentSnapshot?.threads.compactMap { thread in
            currentSnapshot?.threadHasTrackedTurn(for: thread.key) == true ? thread.key : nil
        } ?? [])
        if let activeKey = currentSnapshot?.activeThread {
            keysToRefresh.insert(activeKey)
        }

        foregroundRecoveryTask?.cancel()
        let recoveryID = UUID()
        foregroundRecoveryID = recoveryID

        foregroundRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.foregroundRecoveryID == recoveryID {
                    self.foregroundRecoveryTask = nil
                    self.foregroundRecoveryID = nil
                }
            }

            await self.performForegroundRecovery(
                appModel: appModel,
                liveActivities: liveActivities,
                needsInitialReconnect: needsInitialReconnect,
                reconnectActiveServerIDs: preResumeActiveSSHServerIDs,
                backgroundedKeys: backgroundedKeys,
                keysToRefresh: keysToRefresh
            )
        }
    }

    func handleBackgroundPush(
        appModel: AppModel,
        liveActivities: TurnLiveActivityController
    ) async {
        bgWakeCount += 1
        let keys = backgroundedTurnKeys
        guard !keys.isEmpty else { return }

        await reconnectSavedServers(appModel: appModel)
        await refreshTrackedThreads(appModel: appModel, keys: Array(keys))
        await appModel.refreshSnapshot()

        guard let snapshot = appModel.snapshot else { return }
        let reconciliation = reconcileBackgroundedTurns(snapshot: snapshot, trackedKeys: keys)
        backgroundedTurnKeys = reconciliation.remainingKeys

        for thread in reconciliation.activeThreads {
            liveActivities.updateBackgroundWake(for: thread, pushCount: bgWakeCount)
        }

        if let thread = reconciliation.completedNotificationThread {
            liveActivities.endCurrent(phase: .completed, snapshot: snapshot)
            postLocalNotificationIfNeeded(
                model: thread.resolvedModel,
                threadPreview: thread.resolvedPreview,
                threadKey: thread.key
            )
        }

        if backgroundedTurnKeys.isEmpty {
            deregisterPushProxy()
        }
    }

    func requestNotificationPermissionIfNeeded() {
        guard !notificationPermissionRequested else { return }
        notificationPermissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func reconnectActiveSSHServers(
        appModel: AppModel,
        serverIDs: Set<String>
    ) async {
        guard !serverIDs.isEmpty else { return }

        let plans = SavedServerStore.rememberedServers().compactMap { savedServer -> SavedReconnectPlan? in
            guard savedServer.preferredConnectionMode == .ssh,
                  serverIDs.contains(savedServer.id) else {
                return nil
            }
            let server = savedServer.toDiscoveredServer()
            guard let credential = try? SSHCredentialStore.shared.load(
                host: server.hostname,
                port: Int(server.resolvedSSHPort)
            ) else {
                return nil
            }
            return .ssh(
                serverId: server.id,
                displayName: server.name,
                host: server.hostname,
                port: server.resolvedSSHPort,
                credentials: credential.toConnectionCredential()
            )
        }

        let tasks = plans.map { plan in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runReconnectPlan(plan, appModel: appModel)
            }
        }

        for task in tasks {
            await task.value
        }

        await appModel.refreshSnapshot()
    }

    func reconcileBackgroundedTurns(
        snapshot: AppSnapshotRecord,
        trackedKeys: Set<ThreadKey>
    ) -> BackgroundTurnReconciliation {
        var remainingKeys: Set<ThreadKey> = []
        var activeThreads: [AppThreadSnapshot] = []
        var completedThreads: [AppThreadSnapshot] = []

        for key in trackedKeys {
            guard let thread = snapshot.threadSnapshot(for: key) else {
                // Keep tracking until we can observe a definitive thread state again.
                remainingKeys.insert(key)
                continue
            }

            if snapshot.threadHasTrackedTurn(for: key) {
                remainingKeys.insert(key)
                activeThreads.append(thread)
            } else {
                completedThreads.append(thread)
            }
        }

        let completedNotificationThread: AppThreadSnapshot?
        if remainingKeys.isEmpty {
            completedNotificationThread = completedThreads.first(where: {
                $0.info.parentThreadId == nil
            }) ?? completedThreads.first
        } else {
            completedNotificationThread = nil
        }

        return BackgroundTurnReconciliation(
            remainingKeys: remainingKeys,
            activeThreads: activeThreads,
            completedNotificationThread: completedNotificationThread
        )
    }

    private func reconnectPlan(
        for savedServer: SavedServer,
        appModel: AppModel,
        skipIfAlreadyConnected: Bool = true
    ) -> SavedReconnectPlan? {
        let server = savedServer.toDiscoveredServer()
        if skipIfAlreadyConnected,
           let snapshot = appModel.snapshot?.serverSnapshot(for: server.id),
           snapshot.health != .disconnected {
            return nil
        }

        do {
            if savedServer.preferredConnectionMode == .ssh {
                guard let credential = try SSHCredentialStore.shared.load(
                    host: server.hostname,
                    port: Int(server.resolvedSSHPort)
                ) else {
                    return nil
                }
                return .ssh(
                    serverId: server.id,
                    displayName: server.name,
                    host: server.hostname,
                    port: server.resolvedSSHPort,
                    credentials: credential.toConnectionCredential()
                )
            } else if let target = server.connectionTarget {
                switch target {
                case .local:
                    return .local(
                        serverId: server.id,
                        displayName: server.name,
                        restoreLocalAuth: true
                    )
                case .remote(let host, let port):
                    return .remote(
                        serverId: server.id,
                        displayName: server.name,
                        host: host,
                        port: port
                    )
                case .remoteURL(let url):
                    return .remoteURL(
                        serverId: server.id,
                        displayName: server.name,
                        websocketUrl: url.absoluteString
                    )
                case .sshThenRemote(let host, let credentials):
                    return .ssh(
                        serverId: server.id,
                        displayName: server.name,
                        host: host,
                        port: server.resolvedSSHPort,
                        credentials: credentials
                    )
                }
            } else if savedServer.preferredConnectionMode == nil,
                      let credential = try SSHCredentialStore.shared.load(
                host: server.hostname,
                port: Int(server.resolvedSSHPort)
            ) {
                return .ssh(
                    serverId: server.id,
                    displayName: server.name,
                    host: server.hostname,
                    port: server.resolvedSSHPort,
                    credentials: credential.toConnectionCredential()
                )
            }
        } catch {
            return nil
        }

        return nil
    }

    private func runReconnectPlan(
        _ plan: SavedReconnectPlan,
        appModel: AppModel
    ) async {
        do {
            switch plan {
            case .ssh(let serverId, let displayName, let host, let port, let credentials):
                try await reconnectSSHServer(
                    appModel: appModel,
                    serverId: serverId,
                    displayName: displayName,
                    host: host,
                    port: port,
                    credentials: credentials
                )
            case .local(let serverId, let displayName, let restoreLocalAuth):
                _ = try await appModel.serverBridge.connectLocalServer(
                    serverId: serverId,
                    displayName: displayName,
                    host: "127.0.0.1",
                    port: 0
                )
                if restoreLocalAuth {
                    await appModel.restoreStoredLocalChatGPTAuth(serverId: serverId)
                }
            case .remote(let serverId, let displayName, let host, let port):
                _ = try await appModel.serverBridge.connectRemoteServer(
                    serverId: serverId,
                    displayName: displayName,
                    host: host,
                    port: port
                )
            case .remoteURL(let serverId, let displayName, let websocketUrl):
                _ = try await appModel.serverBridge.connectRemoteUrlServer(
                    serverId: serverId,
                    displayName: displayName,
                    websocketUrl: websocketUrl
                )
            }
        } catch {}
    }

    private enum SavedReconnectPlan {
        case ssh(
            serverId: String,
            displayName: String,
            host: String,
            port: UInt16,
            credentials: SSHCredentials
        )
        case local(
            serverId: String,
            displayName: String,
            restoreLocalAuth: Bool
        )
        case remote(
            serverId: String,
            displayName: String,
            host: String,
            port: UInt16
        )
        case remoteURL(
            serverId: String,
            displayName: String,
            websocketUrl: String
        )
    }

    private func performForegroundRecovery(
        appModel: AppModel,
        liveActivities: TurnLiveActivityController,
        needsInitialReconnect: Bool,
        reconnectActiveServerIDs: Set<String>,
        backgroundedKeys: Set<ThreadKey>,
        keysToRefresh: Set<ThreadKey>
    ) async {
        if needsInitialReconnect {
            await reconnectSavedServers(appModel: appModel)
            guard !Task.isCancelled else { return }
        }

        let serverIDsToReconnect: Set<String>
        if needsInitialReconnect {
            serverIDsToReconnect = reconnectActiveServerIDs
        } else {
            let focusedServerIDs = Set(backgroundedKeys.map(\.serverId))
                .union(keysToRefresh.map(\.serverId))
            serverIDsToReconnect = reconnectActiveServerIDs.intersection(focusedServerIDs)
        }

        if !serverIDsToReconnect.isEmpty {
            await reconnectActiveSSHServers(
                appModel: appModel,
                serverIDs: serverIDsToReconnect
            )
            guard !Task.isCancelled else { return }
        }

        if !keysToRefresh.isEmpty {
            await refreshTrackedThreads(appModel: appModel, keys: Array(keysToRefresh))
            guard !Task.isCancelled else { return }
        }

        await appModel.refreshSnapshot()
        liveActivities.sync(appModel.snapshot)
    }

    private func refreshTrackedThreads(appModel: AppModel, keys: [ThreadKey]) async {
        let serverIds = Set(keys.map(\.serverId))
        for serverId in serverIds {
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

        let snapshot = appModel.snapshot
        for key in keys {
            let existing = snapshot?.threadSnapshot(for: key)
            let cwd = existing?.info.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            let config = AppThreadLaunchConfig(
                model: existing?.resolvedModel,
                approvalPolicy: .never,
                sandbox: .dangerFullAccess,
                developerInstructions: nil,
                persistExtendedHistory: true
            )
            _ = try? await appModel.client.resumeThread(
                serverId: key.serverId,
                params: config.threadResumeRequest(
                    threadId: key.threadId,
                    cwdOverride: cwd?.isEmpty == false ? cwd : nil
                )
            )
        }
    }

    private func registerPushProxy() {
        guard let tokenData = devicePushToken else { return }
        guard pushProxyRegistrationId == nil else { return }
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        Task {
            do {
                let regId = try await pushProxy.register(pushToken: token, interval: 30, ttl: 7200)
                await MainActor.run {
                    self.pushProxyRegistrationId = regId
                }
            } catch {}
        }
    }

    private func deregisterPushProxy() {
        guard let regId = pushProxyRegistrationId else { return }
        pushProxyRegistrationId = nil
        Task {
            try? await pushProxy.deregister(registrationId: regId)
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    static func notificationThreadKey(from userInfo: [AnyHashable: Any]) -> ThreadKey? {
        guard let serverId = userInfo[notificationServerIdKey] as? String,
              let threadId = userInfo[notificationThreadIdKey] as? String else {
            return nil
        }

        let trimmedServerId = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServerId.isEmpty, !trimmedThreadId.isEmpty else { return nil }

        return ThreadKey(serverId: trimmedServerId, threadId: trimmedThreadId)
    }

    private func postLocalNotificationIfNeeded(
        model: String,
        threadPreview: String?,
        threadKey: ThreadKey
    ) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Turn completed"
        var bodyParts: [String] = []
        if let preview = threadPreview, !preview.isEmpty { bodyParts.append(preview) }
        if !model.isEmpty { bodyParts.append(model) }
        content.body = bodyParts.joined(separator: " - ")
        content.sound = .default
        content.userInfo = [
            Self.notificationServerIdKey: threadKey.serverId,
            Self.notificationThreadIdKey: threadKey.threadId
        ]
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
