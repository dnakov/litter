import Foundation
import Observation

@MainActor
@Observable
final class SessionsModel {
    struct ThreadEphemeralState: Equatable {
        let hasTurnActive: Bool
        let updatedAt: Date
    }

    private struct Snapshot {
        let derivedData: SessionsDerivedData
        let connectedServerOptions: [DirectoryPickerServerOption]
        let ephemeralStateByThreadKey: [ThreadKey: ThreadEphemeralState]
        let frozenMostRecentThreadOrder: [ThreadKey]?
    }

    private(set) var derivedData: SessionsDerivedData = .empty
    private(set) var connectedServerOptions: [DirectoryPickerServerOption] = []
    private(set) var ephemeralStateByThreadKey: [ThreadKey: ThreadEphemeralState] = [:]
    let localNicknames = LocalSessionNicknames()
    let localLastMessages = LocalSessionLastMessage()

    @ObservationIgnored private weak var serverManager: ServerManager?
    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var searchQuery = ""
    @ObservationIgnored private var hasInitializedState = false
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var frozenMostRecentThreadOrder: [ThreadKey]?

    func bind(serverManager: ServerManager, appState: AppState) {
        let needsRebind = self.serverManager !== serverManager || self.appState !== appState

        self.serverManager = serverManager
        self.appState = appState

        guard needsRebind || !hasInitializedState else { return }
        hasInitializedState = true
        refreshState()
    }

    func updateSearchQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != searchQuery else { return }
        searchQuery = trimmed
        refreshState()
    }

    private func refreshState() {
        guard let serverManager, let appState else {
            derivedData = .empty
            connectedServerOptions = []
            ephemeralStateByThreadKey = [:]
            frozenMostRecentThreadOrder = nil
            return
        }

        let previousDisplayedOrder = derivedData.allThreadKeys
        let currentSearchQuery = searchQuery

        observationGeneration &+= 1
        let generation = observationGeneration
        var pendingCacheUpdates: [(ThreadKey, String)] = []
        let snapshot = withObservationTracking {
            let selectedServerFilterId = appState.sessionsSelectedServerFilterId
            let showOnlyForks = appState.sessionsShowOnlyForks
            let workspaceSortMode = WorkspaceSortMode(rawValue: appState.sessionsWorkspaceSortModeRaw) ?? .mostRecent

            let nextConnectedServerOptions = serverManager.connections.values
                .filter(\.isConnected)
                .sorted {
                    $0.server.name.localizedCaseInsensitiveCompare($1.server.name) == .orderedAscending
                }
                .map {
                    DirectoryPickerServerOption(
                        id: $0.id,
                        name: $0.server.name,
                        sourceLabel: $0.server.source.rawString
                    )
                }

            let nextEphemeralStateByThreadKey = serverManager.threads.reduce(into: [ThreadKey: ThreadEphemeralState]()) { partialResult, entry in
                partialResult[entry.key] = ThreadEphemeralState(
                    hasTurnActive: entry.value.hasTurnActive,
                    updatedAt: entry.value.updatedAt
                )
                // Collect cache updates — applied after withObservationTracking to avoid
                // SessionsModel inadvertently observing localLastMessages.messages
                if !entry.value.hasTurnActive,
                   let lastText = entry.value.items
                    .last(where: { $0.isAssistantItem && !($0.assistantText ?? "").isEmpty })?
                    .assistantText {
                    pendingCacheUpdates.append((entry.key, lastText))
                }
            }

            let nextFrozenMostRecentThreadOrder = resolvedFrozenMostRecentThreadOrder(
                serverManager: serverManager,
                workspaceSortMode: workspaceSortMode,
                previousDisplayedOrder: previousDisplayedOrder
            )

            let nicknameLookup = { [localNicknames] (key: ThreadKey) -> String? in
                localNicknames.nickname(for: key)
            }
            let nextDerivedData = SessionsDerivation.build(
                serverManager: serverManager,
                selectedServerFilterId: selectedServerFilterId,
                showOnlyForks: showOnlyForks,
                workspaceSortMode: workspaceSortMode,
                searchQuery: currentSearchQuery,
                frozenMostRecentOrder: nextFrozenMostRecentThreadOrder,
                nicknameLookup: nicknameLookup
            )

            return Snapshot(
                derivedData: nextDerivedData,
                connectedServerOptions: nextConnectedServerOptions,
                ephemeralStateByThreadKey: nextEphemeralStateByThreadKey,
                frozenMostRecentThreadOrder: nextFrozenMostRecentThreadOrder
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.refreshState()
            }
        }

        frozenMostRecentThreadOrder = snapshot.frozenMostRecentThreadOrder
        connectedServerOptions = snapshot.connectedServerOptions
        ephemeralStateByThreadKey = snapshot.ephemeralStateByThreadKey
        derivedData = snapshot.derivedData

        // Apply last-message cache updates outside withObservationTracking so
        // SessionsModel does not observe localLastMessages and trigger a spurious
        // extra refreshState() on every write
        for (key, text) in pendingCacheUpdates {
            localLastMessages.update(text, for: key)
        }
    }

    private func resolvedFrozenMostRecentThreadOrder(
        serverManager: ServerManager,
        workspaceSortMode: WorkspaceSortMode,
        previousDisplayedOrder: [ThreadKey]
    ) -> [ThreadKey]? {
        guard workspaceSortMode == .mostRecent else {
            return nil
        }

        let hasActiveThread = serverManager.threads.values.contains(where: \.hasTurnActive)
        guard hasActiveThread else {
            return nil
        }

        if let frozenMostRecentThreadOrder {
            return frozenMostRecentThreadOrder
        }

        if !previousDisplayedOrder.isEmpty {
            return previousDisplayedOrder
        }

        return serverManager.threads.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.key)
    }
}
