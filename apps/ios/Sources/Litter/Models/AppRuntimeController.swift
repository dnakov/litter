import Foundation
import Observation

@MainActor
@Observable
final class AppRuntimeController {
    static let shared = AppRuntimeController()

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private weak var voiceRuntime: VoiceRuntimeController?
    @ObservationIgnored private let lifecycle = AppLifecycleController()
    @ObservationIgnored private let liveActivities = TurnLiveActivityController()
    @ObservationIgnored private var pendingLiveActivitySync = false
    @ObservationIgnored private var lastLiveActivitySyncTime: CFAbsoluteTime = 0

    func bind(appModel: AppModel, voiceRuntime: VoiceRuntimeController) {
        self.appModel = appModel
        self.voiceRuntime = voiceRuntime
        lifecycle.requestNotificationPermissionIfNeeded()
    }

    func setDevicePushToken(_ token: Data) {
        lifecycle.setDevicePushToken(token)
    }

    func reconnectSavedServers() async {
        guard let appModel else { return }
        await lifecycle.reconnectSavedServers(appModel: appModel)
    }

    func reconnectServer(serverId: String) async {
        guard let appModel else { return }
        await lifecycle.reconnectServer(serverId: serverId, appModel: appModel)
    }

    func restoreMissingLocalAuthStateIfNeeded() async {
        guard let appModel else { return }
        await appModel.restoreMissingLocalAuthStateIfNeeded()
    }

    func openThreadFromNotification(key: ThreadKey) async {
        guard let appModel else { return }
        LLog.info(
            "push",
            "runtime opening thread from notification",
            fields: ["serverId": key.serverId, "threadId": key.threadId]
        )
        lifecycle.markThreadOpenedFromNotification(key)
        appModel.activateThread(key)

        if let resolvedKey = await appModel.ensureThreadLoaded(key: key) {
            lifecycle.markThreadOpenedFromNotification(resolvedKey)
            LLog.info(
                "push",
                "notification thread resolved and activated",
                fields: ["serverId": resolvedKey.serverId, "threadId": resolvedKey.threadId]
            )
            appModel.activateThread(resolvedKey)
            await appModel.refreshThreadSnapshot(key: resolvedKey)
        } else {
            LLog.warn(
                "push",
                "notification thread could not be resolved",
                fields: ["serverId": key.serverId, "threadId": key.threadId]
            )
        }
    }

    func handleSnapshot(_ snapshot: AppSnapshotRecord?) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastLiveActivitySyncTime
        if elapsed >= 3.0 {
            lastLiveActivitySyncTime = now
            liveActivities.sync(snapshot)
        } else if !pendingLiveActivitySync {
            pendingLiveActivitySync = true
            let delay = 3.0 - elapsed
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.pendingLiveActivitySync = false
                self.lastLiveActivitySyncTime = CFAbsoluteTimeGetCurrent()
                self.liveActivities.sync(self.appModel?.snapshot)
            }
        }
    }

    func appDidEnterBackground() {
        guard let appModel else { return }
        appModel.reconnectController.onAppEnteredBackground()
        lifecycle.appDidEnterBackground(
            snapshot: appModel.snapshot,
            hasActiveVoiceSession: voiceRuntime?.activeVoiceSession != nil,
            liveActivities: liveActivities
        )
    }

    func appDidBecomeInactive() {
        guard let appModel else { return }
        appModel.reconnectController.onAppBecameInactive()
    }

    func appDidBecomeActive() {
        guard let appModel else { return }
        // Keep lifecycle state in sync even when foreground recovery exits early
        // for an already-running voice session.
        appModel.reconnectController.noteAppBecameActive()
        lifecycle.appDidBecomeActive(
            appModel: appModel,
            hasActiveVoiceSession: voiceRuntime?.activeVoiceSession != nil,
            liveActivities: liveActivities
        )
    }

    func handleBackgroundPush() async {
        guard let appModel else { return }
        LLog.info("push", "runtime handling background push")
        await lifecycle.handleBackgroundPush(
            appModel: appModel,
            liveActivities: liveActivities
        )
        LLog.info("push", "runtime finished background push")
    }
}
