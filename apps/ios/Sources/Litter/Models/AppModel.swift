import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    struct ComposerPrefillRequest: Identifiable, Equatable {
        let id = UUID()
        let threadKey: ThreadKey
        let text: String
    }

    let store: AppStore
    let rpc: AppServerRpc
    let discovery: DiscoveryBridge
    let serverBridge: ServerBridge
    let ssh: SshBridge

    private(set) var snapshot: AppSnapshotRecord?
    private(set) var lastError: String?
    private(set) var composerPrefillRequest: ComposerPrefillRequest?

    @ObservationIgnored private var subscription: AppStoreSubscription?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var loadingModelServerIds: Set<String> = []

    init(
        store: AppStore = AppStore(),
        rpc: AppServerRpc = AppServerRpc(),
        discovery: DiscoveryBridge = DiscoveryBridge(),
        serverBridge: ServerBridge = ServerBridge(),
        ssh: SshBridge = SshBridge()
    ) {
        self.store = store
        self.rpc = rpc
        self.discovery = discovery
        self.serverBridge = serverBridge
        self.ssh = ssh
    }

    deinit {
        updateTask?.cancel()
    }

    func start() {
        guard updateTask == nil else { return }
        subscription = store.subscribeUpdates()
        updateTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshSnapshot()
            guard let subscription = self.subscription else { return }
            while !Task.isCancelled {
                do {
                    _ = try await subscription.nextUpdate()
                    await self.refreshSnapshot()
                } catch {
                    if Task.isCancelled { break }
                    self.lastError = error.localizedDescription
                    break
                }
            }
        }
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        subscription = nil
    }

    func refreshSnapshot() async {
        do {
            applySnapshot(try await store.snapshot())
        } catch {
            lastError = error.localizedDescription
        }
    }

    func applySnapshot(_ snapshot: AppSnapshotRecord?) {
        self.snapshot = snapshot
        if snapshot != nil {
            lastError = nil
        }
    }

    func queueComposerPrefill(threadKey: ThreadKey, text: String) {
        composerPrefillRequest = ComposerPrefillRequest(threadKey: threadKey, text: text)
    }

    func clearComposerPrefill(id: UUID) {
        guard composerPrefillRequest?.id == id else { return }
        composerPrefillRequest = nil
    }

    func availableModels(for serverId: String) -> [Model] {
        snapshot?.serverSnapshot(for: serverId)?.availableModels ?? []
    }

    func rateLimits(for serverId: String) -> RateLimitSnapshot? {
        snapshot?.serverSnapshot(for: serverId)?.rateLimits
    }

    func loadConversationMetadataIfNeeded(serverId: String) async {
        await loadAvailableModelsIfNeeded(serverId: serverId)
        await loadRateLimitsIfNeeded(serverId: serverId)
    }

    func loadAvailableModelsIfNeeded(serverId: String) async {
        guard let server = snapshot?.serverSnapshot(for: serverId), server.isConnected else { return }
        guard server.availableModels == nil else { return }
        guard !loadingModelServerIds.contains(serverId) else { return }
        loadingModelServerIds.insert(serverId)
        defer { loadingModelServerIds.remove(serverId) }
        do {
            _ = try await rpc.modelList(
                serverId: serverId,
                params: ModelListParams(cursor: nil, limit: nil, includeHidden: false)
            )
            await refreshSnapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadRateLimitsIfNeeded(serverId: String) async {
        guard let server = snapshot?.serverSnapshot(for: serverId), server.isConnected else { return }
        guard server.rateLimits == nil else { return }
        do {
            _ = try await rpc.getAccountRateLimits(serverId: serverId)
        } catch {
            lastError = error.localizedDescription
        }
    }
}

extension AppSnapshotRecord {
    func threadSnapshot(for key: ThreadKey) -> AppThreadSnapshot? {
        threads.first { $0.key == key }
    }

    func serverSnapshot(for serverId: String) -> AppServerSnapshot? {
        servers.first { $0.serverId == serverId }
    }

    func sessionSummary(for key: ThreadKey) -> AppSessionSummary? {
        sessionSummaries.first { $0.key == key }
    }

    func resolvedThreadKey(for receiverId: String, serverId: String) -> ThreadKey? {
        guard let normalized = AgentLabelFormatter.sanitized(receiverId) else { return nil }
        if let summary = sessionSummaries.first(where: {
            $0.key.serverId == serverId && $0.key.threadId == normalized
        }) {
            return summary.key
        }
        return ThreadKey(serverId: serverId, threadId: normalized)
    }

    func resolvedAgentTargetLabel(for target: String, serverId: String) -> String? {
        if AgentLabelFormatter.looksLikeDisplayLabel(target) {
            return AgentLabelFormatter.sanitized(target)
        }
        guard let normalized = AgentLabelFormatter.sanitized(target) else { return nil }
        if let summary = sessionSummaries.first(where: {
            $0.key.serverId == serverId && $0.key.threadId == normalized
        }) {
            return summary.agentDisplayLabel ?? AgentLabelFormatter.sanitized(target)
        }
        return nil
    }
}
