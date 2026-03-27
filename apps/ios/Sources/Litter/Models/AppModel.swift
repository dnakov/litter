import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    /// Pre-built Rust objects initialized off the main thread to avoid
    /// priority inversion (tokio runtime init blocks at default QoS).
    private struct RustBridges: @unchecked Sendable {
        let store: AppStore
        let rpc: AppServerRpc
        let discovery: DiscoveryBridge
        let serverBridge: ServerBridge
        let ssh: SshBridge
    }

    /// Kick off Rust bridge construction on a background thread.
    /// Call from `AppDelegate.didFinishLaunching` before SwiftUI touches `shared`.
    nonisolated static func prewarmRustBridges() {
        _ = _prewarmResult
    }

    private nonisolated static let _prewarmResult: RustBridges = {
        RustBridges(
            store: AppStore(),
            rpc: AppServerRpc(),
            discovery: DiscoveryBridge(),
            serverBridge: ServerBridge(),
            ssh: SshBridge()
        )
    }()

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
        store: AppStore? = nil,
        rpc: AppServerRpc? = nil,
        discovery: DiscoveryBridge? = nil,
        serverBridge: ServerBridge? = nil,
        ssh: SshBridge? = nil
    ) {
        let bridges = Self._prewarmResult
        self.store = store ?? bridges.store
        self.rpc = rpc ?? bridges.rpc
        self.discovery = discovery ?? bridges.discovery
        self.serverBridge = serverBridge ?? bridges.serverBridge
        self.ssh = ssh ?? bridges.ssh
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
                    let update = try await subscription.nextUpdate()
                    await self.handleStoreUpdate(update)
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

    func restartLocalServer() async throws {
        let currentLocal = snapshot?.servers.first(where: \.isLocal)
        let serverId = currentLocal?.serverId ?? "local"
        let displayName = currentLocal?.displayName ?? "This Device"
        serverBridge.disconnectServer(serverId: serverId)
        _ = try await serverBridge.connectLocalServer(
            serverId: serverId,
            displayName: displayName,
            host: "127.0.0.1",
            port: 0
        )
        await restoreStoredLocalChatGPTAuth(serverId: serverId)
        await refreshSnapshot()
    }

    func restoreStoredLocalChatGPTAuth(serverId: String) async {
        guard let tokens = (try? ChatGPTOAuthTokenStore.shared.load()) ?? nil else {
            return
        }

        do {
            _ = try await rpc.loginAccount(
                serverId: serverId,
                params: .chatgptAuthTokens(
                    accessToken: tokens.accessToken,
                    chatgptAccountId: tokens.accountID,
                    chatgptPlanType: tokens.planType
                )
            )
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

    private func handleStoreUpdate(_ update: AppStoreUpdateRecord) async {
        switch update {
        case .threadChanged(let key):
            await refreshThreadSnapshot(key: key)
        case .threadRemoved(let key):
            removeThreadSnapshot(for: key)
        case .activeThreadChanged(let key):
            updateActiveThread(key)
            if let key, snapshot?.threadSnapshot(for: key) == nil {
                await refreshThreadSnapshot(key: key)
            }
        case .pendingApprovalsChanged:
            await refreshSnapshot()
        case .pendingUserInputsChanged:
            await refreshSnapshot()
        case .serverChanged:
            await refreshSnapshot()
        case .serverRemoved:
            await refreshSnapshot()
        case .fullResync:
            await refreshSnapshot()
        case .voiceSessionChanged:
            await refreshSnapshot()
        case .realtimeTranscriptUpdated:
            break
        case .realtimeHandoffRequested:
            break
        case .realtimeSpeechStarted:
            break
        case .realtimeStarted:
            await refreshSnapshot()
        case .realtimeOutputAudioDelta:
            break
        case .realtimeError:
            await refreshSnapshot()
        case .realtimeClosed:
            await refreshSnapshot()
        }
    }

    private func refreshThreadSnapshot(key: ThreadKey) async {
        guard snapshot != nil else {
            await refreshSnapshot()
            return
        }

        do {
            guard let threadSnapshot = try await store.threadSnapshot(key: key) else {
                removeThreadSnapshot(for: key)
                return
            }
            applyThreadSnapshot(threadSnapshot)
        } catch {
            lastError = error.localizedDescription
            await refreshSnapshot()
        }
    }

    private func applyThreadSnapshot(_ thread: AppThreadSnapshot) {
        guard var snapshot else {
            applySnapshot(nil)
            return
        }

        if let index = snapshot.threads.firstIndex(where: { $0.key == thread.key }) {
            snapshot.threads[index] = thread
        } else {
            snapshot.threads.append(thread)
        }
        self.snapshot = snapshot
        lastError = nil
    }

    private func removeThreadSnapshot(for key: ThreadKey) {
        guard var snapshot else { return }
        snapshot.threads.removeAll { $0.key == key }
        if snapshot.activeThread == key {
            snapshot.activeThread = nil
        }
        self.snapshot = snapshot
    }

    private func updateActiveThread(_ key: ThreadKey?) {
        guard var snapshot else { return }
        snapshot.activeThread = key
        self.snapshot = snapshot
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
        guard server.account != nil else { return }
        do {
            _ = try await rpc.getAccountRateLimits(serverId: serverId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startTurn(key: ThreadKey, payload: AppComposerPayload) async throws {
        do {
            try await store.startTurn(
                key: key,
                params: payload.turnStartParams(threadId: key.threadId)
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func ensureThreadLoaded(
        key: ThreadKey,
        maxAttempts: Int = 5
    ) async -> ThreadKey? {
        if snapshot?.threadSnapshot(for: key) != nil {
            return key
        }

        var currentKey = key
        for attempt in 0..<maxAttempts {
            var readSucceeded = false
            do {
                let response = try await rpc.threadRead(
                    serverId: currentKey.serverId,
                    params: ThreadReadParams(
                        threadId: currentKey.threadId,
                        includeTurns: true
                    )
                )
                currentKey = ThreadKey(serverId: currentKey.serverId, threadId: response.thread.id)
                store.setActiveThread(key: currentKey)
                readSucceeded = true
            } catch {
                lastError = error.localizedDescription
            }

            await refreshSnapshot()
            if snapshot?.threadSnapshot(for: currentKey) != nil {
                return currentKey
            }

            if !readSucceeded {
                do {
                    _ = try await rpc.threadList(
                        serverId: currentKey.serverId,
                        params: ThreadListParams(
                            cursor: nil,
                            limit: nil,
                            sortKey: nil,
                            modelProviders: nil,
                            sourceKinds: nil,
                            archived: nil,
                            cwd: nil,
                            searchTerm: nil
                        )
                    )
                } catch {
                    lastError = error.localizedDescription
                }

                await refreshSnapshot()
                if snapshot?.threadSnapshot(for: currentKey) != nil {
                    return currentKey
                }
            }

            if attempt + 1 < maxAttempts {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        if let activeKey = snapshot?.activeThread,
           activeKey.serverId == currentKey.serverId,
           snapshot?.threadSnapshot(for: activeKey) != nil {
            return activeKey
        }

        return nil
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
