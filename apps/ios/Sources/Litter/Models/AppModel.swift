import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    /// Pre-built Rust objects initialized off the main thread to avoid
    /// priority inversion (tokio runtime init blocks at default QoS).
    private struct RustBridges: @unchecked Sendable {
        let store: AppStore
        let client: AppClient
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
            client: AppClient(),
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
    let client: AppClient
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
        client: AppClient? = nil,
        discovery: DiscoveryBridge? = nil,
        serverBridge: ServerBridge? = nil,
        ssh: SshBridge? = nil
    ) {
        let bridges = Self._prewarmResult
        self.store = store ?? bridges.store
        self.client = client ?? bridges.client
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
            _ = try await client.loginAccount(
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
        case .threadUpserted(let thread, let sessionSummary, let agentDirectoryVersion):
            applyThreadUpsert(
                thread,
                sessionSummary: sessionSummary,
                agentDirectoryVersion: agentDirectoryVersion
            )
        case .threadStateUpdated(let state, let sessionSummary, let agentDirectoryVersion):
            applyThreadStateUpdated(
                state,
                sessionSummary: sessionSummary,
                agentDirectoryVersion: agentDirectoryVersion
            )
        case .threadItemUpserted(let key, let item):
            if !applyThreadItemUpsert(key: key, item: item) {
                await refreshThreadSnapshot(key: key)
            }
        case .threadCommandExecutionUpdated(
            let key,
            let itemId,
            let status,
            let exitCode,
            let durationMs,
            let processId
        ):
            if !applyThreadCommandExecutionUpdated(
                key: key,
                itemId: itemId,
                status: status,
                exitCode: exitCode,
                durationMs: durationMs,
                processId: processId
            ) {
                await refreshThreadSnapshot(key: key)
            }
        case .threadStreamingDelta(let key, let itemId, let kind, let text):
            if !applyThreadStreamingDelta(key: key, itemId: itemId, kind: kind, text: text) {
                await refreshThreadSnapshot(key: key)
            }
        case .threadRemoved(let key, let agentDirectoryVersion):
            removeThreadSnapshot(for: key, agentDirectoryVersion: agentDirectoryVersion)
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

    private func applyThreadUpsert(
        _ thread: AppThreadSnapshot,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: UInt64
    ) {
        guard var snapshot else { return }

        if let index = snapshot.threads.firstIndex(where: { $0.key == thread.key }) {
            snapshot.threads[index] = thread
        } else {
            snapshot.threads.append(thread)
        }

        if let index = snapshot.sessionSummaries.firstIndex(where: { $0.key == sessionSummary.key }) {
            snapshot.sessionSummaries[index] = sessionSummary
        } else {
            snapshot.sessionSummaries.append(sessionSummary)
        }
        snapshot.sessionSummaries.sort(by: Self.sessionSummarySort(lhs:rhs:))
        snapshot.agentDirectoryVersion = agentDirectoryVersion
        self.snapshot = snapshot
        lastError = nil
    }

    private func applyThreadStateUpdated(
        _ state: AppThreadStateRecord,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: UInt64
    ) {
        guard var snapshot else { return }
        guard let threadIndex = snapshot.threads.firstIndex(where: { $0.key == state.key }) else {
            return
        }

        var thread = snapshot.threads[threadIndex]
        thread.info = state.info
        thread.model = state.model
        thread.reasoningEffort = state.reasoningEffort
        thread.effectiveApprovalPolicy = state.effectiveApprovalPolicy
        thread.effectiveSandboxPolicy = state.effectiveSandboxPolicy
        thread.activeTurnId = state.activeTurnId
        thread.contextTokensUsed = state.contextTokensUsed
        thread.modelContextWindow = state.modelContextWindow
        thread.rateLimits = state.rateLimits
        thread.realtimeSessionId = state.realtimeSessionId
        snapshot.threads[threadIndex] = thread

        if let index = snapshot.sessionSummaries.firstIndex(where: { $0.key == sessionSummary.key }) {
            snapshot.sessionSummaries[index] = sessionSummary
        } else {
            snapshot.sessionSummaries.append(sessionSummary)
        }
        snapshot.sessionSummaries.sort(by: Self.sessionSummarySort(lhs:rhs:))
        snapshot.agentDirectoryVersion = agentDirectoryVersion
        self.snapshot = snapshot
        lastError = nil
    }

    private func applyThreadItemUpsert(
        key: ThreadKey,
        item: HydratedConversationItem
    ) -> Bool {
        guard var snapshot else { return false }
        guard let threadIndex = snapshot.threads.firstIndex(where: { $0.key == key }) else {
            return false
        }

        var thread = snapshot.threads[threadIndex]
        if let itemIndex = thread.hydratedConversationItems.firstIndex(where: { $0.id == item.id }) {
            thread.hydratedConversationItems[itemIndex] = item
        } else {
            let insertionIndex = Self.insertionIndex(for: item, in: thread.hydratedConversationItems)
            thread.hydratedConversationItems.insert(item, at: insertionIndex)
        }
        snapshot.threads[threadIndex] = thread
        self.snapshot = snapshot
        lastError = nil
        return true
    }

    private func applyThreadCommandExecutionUpdated(
        key: ThreadKey,
        itemId: String,
        status: AppOperationStatus,
        exitCode: Int32?,
        durationMs: Int64?,
        processId: String?
    ) -> Bool {
        guard var snapshot else { return false }
        guard let threadIndex = snapshot.threads.firstIndex(where: { $0.key == key }) else {
            return false
        }
        guard let itemIndex = snapshot.threads[threadIndex].hydratedConversationItems.firstIndex(where: { $0.id == itemId }) else {
            return false
        }

        var item = snapshot.threads[threadIndex].hydratedConversationItems[itemIndex]
        guard case .commandExecution(var data) = item.content else {
            return false
        }
        data.status = status
        data.exitCode = exitCode
        data.durationMs = durationMs
        data.processId = processId
        item.content = .commandExecution(data)
        snapshot.threads[threadIndex].hydratedConversationItems[itemIndex] = item
        self.snapshot = snapshot
        lastError = nil
        return true
    }

    private func applyThreadStreamingDelta(
        key: ThreadKey,
        itemId: String,
        kind: ThreadStreamingDeltaKind,
        text: String
    ) -> Bool {
        guard var snapshot else { return false }
        guard let threadIndex = snapshot.threads.firstIndex(where: { $0.key == key }) else {
            return false
        }
        guard let itemIndex = snapshot.threads[threadIndex].hydratedConversationItems.firstIndex(where: { $0.id == itemId }) else {
            return false
        }

        var item = snapshot.threads[threadIndex].hydratedConversationItems[itemIndex]
        guard let updatedContent = Self.applyingStreamingDelta(kind: kind, text: text, to: item.content) else {
            return false
        }
        item.content = updatedContent
        snapshot.threads[threadIndex].hydratedConversationItems[itemIndex] = item
        self.snapshot = snapshot
        lastError = nil
        return true
    }

    private func removeThreadSnapshot(for key: ThreadKey, agentDirectoryVersion: UInt64? = nil) {
        guard var snapshot else { return }
        snapshot.threads.removeAll { $0.key == key }
        snapshot.sessionSummaries.removeAll { $0.key == key }
        if snapshot.activeThread == key {
            snapshot.activeThread = nil
        }
        if let agentDirectoryVersion {
            snapshot.agentDirectoryVersion = agentDirectoryVersion
        }
        self.snapshot = snapshot
    }

    private func updateActiveThread(_ key: ThreadKey?) {
        guard var snapshot else { return }
        snapshot.activeThread = key
        self.snapshot = snapshot
    }

    private static func applyingStreamingDelta(
        kind: ThreadStreamingDeltaKind,
        text: String,
        to content: HydratedConversationItemContent
    ) -> HydratedConversationItemContent? {
        switch (kind, content) {
        case (.assistantText, .assistant(var data)):
            data.text += text
            return .assistant(data)
        case (.reasoningText, .reasoning(var data)):
            if data.content.isEmpty {
                data.content.append(text)
            } else {
                data.content[data.content.count - 1] += text
            }
            return .reasoning(data)
        case (.planText, .proposedPlan(var data)):
            data.content += text
            return .proposedPlan(data)
        case (.commandOutput, .commandExecution(var data)):
            data.output = (data.output ?? "") + text
            return .commandExecution(data)
        case (.mcpProgress, .mcpToolCall(var data)):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                data.progressMessages.append(text)
            }
            return .mcpToolCall(data)
        default:
            return nil
        }
    }

    private static func sessionSummarySort(lhs: AppSessionSummary, rhs: AppSessionSummary) -> Bool {
        let lhsUpdatedAt = lhs.updatedAt ?? Int64.min
        let rhsUpdatedAt = rhs.updatedAt ?? Int64.min
        if lhsUpdatedAt != rhsUpdatedAt {
            return lhsUpdatedAt > rhsUpdatedAt
        }
        if lhs.key.serverId != rhs.key.serverId {
            return lhs.key.serverId < rhs.key.serverId
        }
        return lhs.key.threadId < rhs.key.threadId
    }

    private static func insertionIndex(
        for item: HydratedConversationItem,
        in items: [HydratedConversationItem]
    ) -> Int {
        guard let targetTurnIndex = item.sourceTurnIndex.map(Int.init) else {
            return items.count
        }
        if let lastSameTurnIndex = items.lastIndex(where: { $0.sourceTurnIndex.map(Int.init) == targetTurnIndex }) {
            return lastSameTurnIndex + 1
        }
        if let nextTurnIndex = items.firstIndex(where: {
            guard let sourceTurnIndex = $0.sourceTurnIndex.map(Int.init) else { return false }
            return sourceTurnIndex > targetTurnIndex
        }) {
            return nextTurnIndex
        }
        return items.count
    }

    func queueComposerPrefill(threadKey: ThreadKey, text: String) {
        composerPrefillRequest = ComposerPrefillRequest(threadKey: threadKey, text: text)
    }

    func clearComposerPrefill(id: UUID) {
        guard composerPrefillRequest?.id == id else { return }
        composerPrefillRequest = nil
    }

    func availableModels(for serverId: String) -> [ModelInfo] {
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
            _ = try await client.refreshModels(
                serverId: serverId,
                params: AppRefreshModelsRequest(cursor: nil, limit: nil, includeHidden: false)
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
            _ = try await client.refreshRateLimits(serverId: serverId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startTurn(key: ThreadKey, payload: AppComposerPayload) async throws {
        do {
            try await store.startTurn(
                key: key,
                params: payload.turnStartRequest(threadId: key.threadId)
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func hydrateThreadPermissions(for key: ThreadKey, appState: AppState) async -> ThreadKey? {
        if let existing = snapshot?.threadSnapshot(for: key), hasAuthoritativePermissions(existing) {
            appState.hydratePermissions(from: existing)
            return key
        }

        do {
            let nextKey = try await client.readThread(
                serverId: key.serverId,
                params: AppReadThreadRequest(
                    threadId: key.threadId,
                    includeTurns: true
                )
            )
            await refreshSnapshot()
            appState.hydratePermissions(from: snapshot?.threadSnapshot(for: nextKey))
            return nextKey
        } catch {
            lastError = error.localizedDescription
            return nil
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
                let nextKey = try await client.readThread(
                    serverId: currentKey.serverId,
                    params: AppReadThreadRequest(
                        threadId: currentKey.threadId,
                        includeTurns: true
                    )
                )
                currentKey = nextKey
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
                    _ = try await client.listThreads(
                        serverId: currentKey.serverId,
                        params: AppListThreadsRequest(
                            cursor: nil,
                            limit: nil,
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

    private func hasAuthoritativePermissions(_ thread: AppThreadSnapshot) -> Bool {
        thread.effectiveApprovalPolicy != nil || thread.effectiveSandboxPolicy != nil
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
