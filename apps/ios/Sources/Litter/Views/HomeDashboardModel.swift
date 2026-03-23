import Foundation
import Observation

@MainActor
@Observable
final class HomeDashboardModel {
    private struct Snapshot {
        let connectedServers: [HomeDashboardServer]
        let recentSessions: [HomeDashboardRecentSession]
    }

    private(set) var connectedServers: [HomeDashboardServer] = []
    private(set) var recentSessions: [HomeDashboardRecentSession] = []

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private(set) var rebuildCount = 0
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var observationGeneration = 0

    func bind(appModel: AppModel) {
        self.appModel = appModel
        guard isActive else { return }
        refreshState()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        refreshState()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        observationGeneration &+= 1
    }

    private func refreshState() {
        guard isActive, let appModel else {
            connectedServers = []
            recentSessions = []
            return
        }

        observationGeneration &+= 1
        let generation = observationGeneration
        let snapshot = withObservationTracking {
            let appSnapshot = appModel.snapshot
            let nextConnectedServers = HomeDashboardSupport.sortedConnectedServers(
                from: appSnapshot?.servers ?? [],
                activeServerId: appSnapshot?.activeThread?.serverId
            )
            let nextRecentSessions = HomeDashboardSupport.recentConnectedSessions(
                from: appSnapshot?.sessionSummaries ?? [],
                serversById: Dictionary(uniqueKeysWithValues: nextConnectedServers.map { ($0.id, $0) })
            )
            return Snapshot(
                connectedServers: nextConnectedServers,
                recentSessions: nextRecentSessions
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.observationGeneration == generation else { return }
                self.refreshState()
            }
        }

        rebuildCount += 1
        connectedServers = snapshot.connectedServers
        recentSessions = snapshot.recentSessions
    }
}
