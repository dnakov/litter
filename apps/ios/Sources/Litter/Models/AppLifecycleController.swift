import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor
final class AppLifecycleController {
    private let pushProxy = PushProxyClient()
    private var pushProxyRegistrationId: String?
    private var devicePushToken: Data?
    private var backgroundedTurnKeys: Set<ThreadKey> = []
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var bgWakeCount: Int = 0
    private var notificationPermissionRequested = false

    func setDevicePushToken(_ token: Data) {
        devicePushToken = token
    }

    func reconnectSavedServers(appModel: AppModel) async {
        for savedServer in SavedServerStore.load() {
            let server = savedServer.toDiscoveredServer()
            if appModel.snapshot?.serverSnapshot(for: server.id)?.isConnected == true {
                continue
            }

            do {
                if savedServer.preferredConnectionMode == .ssh {
                    guard let credential = try SSHCredentialStore.shared.load(
                        host: server.hostname,
                        port: Int(server.resolvedSSHPort)
                    ) else {
                        continue
                    }
                    try await reconnectSSHServer(
                        appModel: appModel,
                        serverId: server.id,
                        displayName: server.name,
                        host: server.hostname,
                        port: server.resolvedSSHPort,
                        credentials: credential.toConnectionCredential()
                    )
                } else if let target = server.connectionTarget {
                    switch target {
                    case .local:
                        _ = try await appModel.serverBridge.connectLocalServer(
                            serverId: server.id,
                            displayName: server.name,
                            host: "127.0.0.1",
                            port: 0
                        )
                        await appModel.restoreStoredLocalChatGPTAuth(serverId: server.id)
                    case .remote(let host, let port):
                        _ = try await appModel.serverBridge.connectRemoteServer(
                            serverId: server.id,
                            displayName: server.name,
                            host: host,
                            port: port
                        )
                    case .remoteURL(let url):
                        _ = try await appModel.serverBridge.connectRemoteUrlServer(
                            serverId: server.id,
                            displayName: server.name,
                            websocketUrl: url.absoluteString
                        )
                    case .sshThenRemote(let host, let credentials):
                        try await reconnectSSHServer(
                            appModel: appModel,
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
                    try await reconnectSSHServer(
                        appModel: appModel,
                        serverId: server.id,
                        displayName: server.name,
                        host: server.hostname,
                        port: server.resolvedSSHPort,
                        credentials: credential.toConnectionCredential()
                    )
                }
            } catch {}
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
            _ = try await appModel.ssh.sshConnectRemoteServer(
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
            _ = try await appModel.ssh.sshConnectRemoteServer(
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
        guard !hasActiveVoiceSession else { return }
        let activeThreads = snapshot?.threads.filter(\.hasActiveTurn) ?? []
        guard !activeThreads.isEmpty else { return }

        backgroundedTurnKeys = Set(activeThreads.map(\.key))
        bgWakeCount = 0
        liveActivities.startIfNeeded(for: activeThreads)
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
        backgroundedTurnKeys.removeAll()

        Task {
            await reconnectSavedServers(appModel: appModel)
            await refreshTrackedThreads(appModel: appModel, keys: appModel.snapshot?.threads.compactMap {
                $0.hasActiveTurn ? $0.key : nil
            } ?? [])
            await appModel.refreshSnapshot()
            await MainActor.run {
                liveActivities.sync(appModel.snapshot)
            }
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
        for key in keys {
            guard let thread = snapshot.threadSnapshot(for: key) else { continue }
            if thread.hasActiveTurn {
                liveActivities.updateBackgroundWake(for: thread, pushCount: bgWakeCount)
            } else {
                backgroundedTurnKeys.remove(key)
                liveActivities.end(key: key, phase: .completed, snapshot: snapshot)
                postLocalNotificationIfNeeded(
                    model: thread.resolvedModel,
                    threadPreview: thread.resolvedPreview
                )
            }
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
                approvalPolicy: nil,
                sandbox: nil,
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

    private func postLocalNotificationIfNeeded(model: String, threadPreview: String?) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Turn completed"
        var bodyParts: [String] = []
        if let preview = threadPreview, !preview.isEmpty { bodyParts.append(preview) }
        if !model.isEmpty { bodyParts.append(model) }
        content.body = bodyParts.joined(separator: " - ")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
