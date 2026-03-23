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

    func handleSnapshot(_ snapshot: AppSnapshotRecord?) {
        liveActivities.sync(snapshot)
    }

    func appDidEnterBackground() {
        guard let appModel else { return }
        lifecycle.appDidEnterBackground(
            snapshot: appModel.snapshot,
            hasActiveVoiceSession: voiceRuntime?.activeVoiceSession != nil,
            liveActivities: liveActivities
        )
    }

    func appDidBecomeActive() {
        guard let appModel else { return }
        lifecycle.appDidBecomeActive(
            appModel: appModel,
            hasActiveVoiceSession: voiceRuntime?.activeVoiceSession != nil,
            liveActivities: liveActivities
        )
    }

    func handleBackgroundPush() async {
        guard let appModel else { return }
        await lifecycle.handleBackgroundPush(
            appModel: appModel,
            liveActivities: liveActivities
        )
    }
}
