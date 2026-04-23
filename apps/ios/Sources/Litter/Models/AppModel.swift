import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {
    private struct PendingThreadStateEvent: Sendable {
        let state: AppThreadStateRecord
        let sessionSummary: AppSessionSummary
        let agentDirectoryVersion: UInt64
    }

    private struct PendingCommandRowMutation: Sendable {
        let key: ThreadKey
        let itemId: String
        var upsertItem: HydratedConversationItem?
    }

    private static let liveItemMutationCoalescingNanoseconds: UInt64 = 120_000_000 // ~8fps commands
    private static let liveThreadStateCoalescingNanoseconds: UInt64 = 150_000_000  // ~6fps metadata


    /// Pre-built Rust objects initialized off the main thread to avoid
    /// priority inversion (tokio runtime init blocks at default QoS).
    private struct RustBridges: @unchecked Sendable {
        let store: AppStore
        let client: AppClient
        let discovery: DiscoveryBridge
        let serverBridge: ServerBridge
        let ssh: SshBridge
        let reconnectController: ReconnectController
    }

    /// Kick off Rust bridge construction on a background thread.
    /// Call from `AppDelegate.didFinishLaunching` before SwiftUI touches `shared`.
    nonisolated static func prewarmRustBridges() {
        _ = _prewarmResult
    }

    private nonisolated static let _prewarmResult: RustBridges = {
        let rc = ReconnectController()
        rc.setCredentialProvider(provider: SwiftSshCredentialProvider())
        rc.setIpcSocketPathOverride(path: ExperimentalFeatures.shared.ipcSocketPathOverride())
        return RustBridges(
            store: AppStore(),
            client: AppClient(),
            discovery: DiscoveryBridge(),
            serverBridge: ServerBridge(),
            ssh: SshBridge(),
            reconnectController: rc
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
    let reconnectController: ReconnectController

    private(set) var snapshot: AppSnapshotRecord? {
        didSet {
            guard oldValue != snapshot else { return }
            snapshotRevision &+= 1
        }
    }
    private(set) var snapshotRevision: UInt64 = 0
    private(set) var lastError: String?
    private(set) var composerPrefillRequest: ComposerPrefillRequest?

    @ObservationIgnored private var subscription: AppStoreSubscription?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var loadingModelServerIds: Set<String> = []
    @ObservationIgnored private var loadingRateLimitServerIds: Set<String> = []
    @ObservationIgnored private var recentConversationMetadataLoads: [String: Date] = [:]
    @ObservationIgnored private var pendingThreadRefreshKeys: Set<ThreadKey> = []
    @ObservationIgnored private var pendingThreadRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingActiveThreadHydrationKey: ThreadKey?
    @ObservationIgnored private var pendingActiveThreadHydrationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSnapshotRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingThreadStateEvents: [ThreadKey: PendingThreadStateEvent] = [:]
    @ObservationIgnored private var pendingThreadStateTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCommandRowMutations: [String: PendingCommandRowMutation] = [:]
    @ObservationIgnored private var pendingCommandRowMutationTask: Task<Void, Never>?
    @ObservationIgnored private var cachedThreadSnapshots: [ThreadKey: AppThreadSnapshot] = [:]

    init(
        store: AppStore? = nil,
        client: AppClient? = nil,
        discovery: DiscoveryBridge? = nil,
        serverBridge: ServerBridge? = nil,
        ssh: SshBridge? = nil,
        reconnectController: ReconnectController? = nil
    ) {
        let bridges = Self._prewarmResult
        self.store = store ?? bridges.store
        self.client = client ?? bridges.client
        self.discovery = discovery ?? bridges.discovery
        self.serverBridge = serverBridge ?? bridges.serverBridge
        self.ssh = ssh ?? bridges.ssh
        self.reconnectController = reconnectController ?? bridges.reconnectController
    }

    deinit {
        updateTask?.cancel()
        pendingThreadRefreshTask?.cancel()
        pendingActiveThreadHydrationTask?.cancel()
        pendingSnapshotRefreshTask?.cancel()
        pendingThreadStateTask?.cancel()
        pendingCommandRowMutationTask?.cancel()
    }

    func start() {
        guard updateTask == nil else { return }
        let subscription = store.subscribeUpdates()
        self.subscription = subscription
        updateTask = Task.detached(priority: .userInitiated) { [weak self, subscription] in
            guard let self else { return }
            await self.refreshSnapshot()
            while !Task.isCancelled {
                do {
                    let update = try await subscription.nextUpdate()
                    await self.handleStoreUpdate(update)
                } catch {
                    if Task.isCancelled { break }
                    await self.recordStoreSubscriptionError(error)
                    break
                }
            }
        }
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        pendingThreadRefreshTask?.cancel()
        pendingThreadRefreshTask = nil
        pendingThreadRefreshKeys.removeAll()
        pendingActiveThreadHydrationTask?.cancel()
        pendingActiveThreadHydrationTask = nil
        pendingActiveThreadHydrationKey = nil
        pendingSnapshotRefreshTask?.cancel()
        pendingSnapshotRefreshTask = nil
        pendingThreadStateTask?.cancel()
        pendingThreadStateTask = nil
        pendingThreadStateEvents.removeAll()
        pendingCommandRowMutationTask?.cancel()
        pendingCommandRowMutationTask = nil
        pendingCommandRowMutations.removeAll()
        subscription = nil
    }

    func refreshSnapshot() async {
        pendingSnapshotRefreshTask?.cancel()
        pendingSnapshotRefreshTask = nil
        await performSnapshotRefresh()
    }

    private func performSnapshotRefresh() async {
        do {
            applySnapshot(try await store.snapshot())
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func recordStoreSubscriptionError(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func scheduleSnapshotRefreshDebounced() {
        guard pendingSnapshotRefreshTask == nil else { return }
        pendingSnapshotRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 75_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.pendingSnapshotRefreshTask = nil
            await self.performSnapshotRefresh()
        }
    }

    func activateThread(_ key: ThreadKey?) {
        restoreCachedThreadSnapshotIfNeeded(for: key)
        updateActiveThread(key)
        store.setActiveThread(key: key)
        scheduleDeferredActiveThreadHydrationIfNeeded(for: key)
    }

    func resumeThread(
        key: ThreadKey,
        launchConfig: AppThreadLaunchConfig,
        cwdOverride: String?
    ) async throws -> ThreadKey {
        let trimmedCwdOverride = cwdOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiresResumeOverrides = requiresResumeOverrides(
            for: key,
            launchConfig: launchConfig,
            cwdOverride: trimmedCwdOverride
        )
        let requiresDistinctCwdOverride = requiresResumeCwdOverride(
            for: key,
            cwdOverride: trimmedCwdOverride
        )

        if requiresResumeOverrides {
            return try await client.resumeThread(
                serverId: key.serverId,
                params: launchConfig.threadResumeRequest(
                    threadId: key.threadId,
                    cwdOverride: requiresDistinctCwdOverride ? trimmedCwdOverride : nil
                )
            )
        }

        // No overrides — let Rust decide whether to use IPC passively or do a thread/read RPC.
        try await store.externalResumeThread(key: key, hostId: nil)
        return key
    }

    func reloadThread(
        key: ThreadKey,
        launchConfig: AppThreadLaunchConfig,
        cwdOverride: String?
    ) async throws -> ThreadKey {
        let trimmedCwdOverride = cwdOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiresResumeOverrides = requiresResumeOverrides(
            for: key,
            launchConfig: launchConfig,
            cwdOverride: trimmedCwdOverride
        )
        let requiresDistinctCwdOverride = requiresResumeCwdOverride(
            for: key,
            cwdOverride: trimmedCwdOverride
        )

        if requiresResumeOverrides {
            return try await client.resumeThread(
                serverId: key.serverId,
                params: launchConfig.threadResumeRequest(
                    threadId: key.threadId,
                    cwdOverride: requiresDistinctCwdOverride ? trimmedCwdOverride : nil
                )
            )
        }

        // No overrides — let Rust decide whether to use IPC passively or do a thread/read RPC.
        try await store.externalResumeThread(key: key, hostId: nil)
        return key
    }

    private func requiresResumeCwdOverride(
        for key: ThreadKey,
        cwdOverride: String?
    ) -> Bool {
        guard let normalizedOverride = cwdOverride, !normalizedOverride.isEmpty else {
            return false
        }

        let existingCwd =
            threadSnapshot(for: key)?.info.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? snapshot?.sessionSummary(for: key)?.cwd.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let existingCwd, !existingCwd.isEmpty else {
            return true
        }
        return existingCwd != normalizedOverride
    }

    private func requiresResumeOverrides(
        for key: ThreadKey,
        launchConfig: AppThreadLaunchConfig,
        cwdOverride: String?
    ) -> Bool {
        if !(launchConfig.developerInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return true
        }
        if !launchConfig.persistExtendedHistory {
            return true
        }
        if requiresResumeCwdOverride(for: key, cwdOverride: cwdOverride) {
            return true
        }

        guard let existingThread = threadSnapshot(for: key) else {
            let existingModel = snapshot?.sessionSummary(for: key)?.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedModel = launchConfig.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let requestedModel, !requestedModel.isEmpty, requestedModel != existingModel {
                return true
            }
            return launchConfig.approvalPolicy != nil
                || launchConfig.sandbox != nil
        }

        let requestedModel = launchConfig.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingModel = (existingThread.model ?? existingThread.info.model)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedModel, !requestedModel.isEmpty, requestedModel != existingModel {
            return true
        }
        if let requestedApproval = launchConfig.approvalPolicy,
           requestedApproval != existingThread.effectiveApprovalPolicy {
            return true
        }
        if let requestedSandbox = launchConfig.sandbox,
           requestedSandbox != existingThread.effectiveSandboxPolicy?.launchOverrideMode {
            return true
        }
        return false
    }

    func resolvedLocalServerDisplayName() -> String {
        let connectedLocalName = snapshot?.servers
            .first(where: \.isLocal)
            .flatMap { $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let connectedLocalName, !connectedLocalName.isEmpty, connectedLocalName != "This Device" {
            return connectedLocalName
        }

        let savedLocalName = SavedServerStore.load()
            .first(where: { $0.id == "local" || $0.source == .local })
            .flatMap { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let savedLocalName, !savedLocalName.isEmpty, savedLocalName != "This Device" {
            return savedLocalName
        }

        return UIDevice.current.name
    }

    func restartLocalServer() async throws {
        let currentLocal = snapshot?.servers.first(where: \.isLocal)
        let serverId = currentLocal?.serverId ?? "local"
        let displayName = resolvedLocalServerDisplayName()
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
        let normalizedSnapshot = snapshot.map(normalizingLocalServerDisplayNames)
        let mergedSnapshot = normalizedSnapshot.map(mergingCachedThreadSnapshots)
        self.snapshot = mergedSnapshot
        if let mergedSnapshot {
            persistWakeMACs(from: mergedSnapshot.servers)
            mergedSnapshot.threads.forEach(cacheThreadSnapshot)
            lastError = nil
        }
    }

    private func persistWakeMACs(from servers: [AppServerSnapshot]) {
        for server in servers {
            SavedServerStore.updateWakeMAC(
                serverId: server.serverId,
                host: server.host,
                wakeMAC: server.wakeMac
            )
        }
    }

    private func normalizingLocalServerDisplayNames(_ snapshot: AppSnapshotRecord) -> AppSnapshotRecord {
        var snapshot = snapshot
        let fallbackName = UIDevice.current.name
        for index in snapshot.servers.indices {
            guard snapshot.servers[index].isLocal else { continue }
            let displayName = snapshot.servers[index].displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if displayName.isEmpty || displayName == "This Device" {
                snapshot.servers[index].displayName = fallbackName
            }
        }
        return snapshot
    }

    private func handleStoreUpdate(_ update: AppStoreUpdateRecord) async {
        switch update {
        case .threadUpserted(let thread, let sessionSummary, let agentDirectoryVersion):
            applyThreadUpsert(
                thread,
                sessionSummary: sessionSummary,
                agentDirectoryVersion: agentDirectoryVersion
            )
        case .threadMetadataChanged(let state, let sessionSummary, let agentDirectoryVersion):
            if shouldBatchLiveThreadStateUpdate(for: state.key) {
                enqueueThreadStateUpdate(
                    state,
                    sessionSummary: sessionSummary,
                    agentDirectoryVersion: agentDirectoryVersion
                )
            } else {
                applyThreadStateUpdated(
                    state,
                    sessionSummary: sessionSummary,
                    agentDirectoryVersion: agentDirectoryVersion
                )
            }
        case .threadItemChanged(let key, let item, let sessionSummary):
            let isBatched = shouldBatchCommandRowMutation(for: key, item: item)
            if isBatched {
                enqueueCommandRowUpsert(key: key, item: item)
            } else if !applyThreadItemUpsert(key: key, item: item) {
                scheduleThreadSnapshotRefresh(for: key)
            }
            // Reducer piggybacks the refreshed per-thread summary on every
            // item change, so the home dashboard's session-summary driven
            // fields (stats, last tool label, etc.) stay in sync with the
            // stream without waiting for a full snapshot rebuild.
            applySessionSummary(sessionSummary)
        case .threadStreamingDelta(let key, let itemId, let kind, let text):
            if kind == .assistantText {
                StreamingRendererCoordinator.shared.appendDelta(text, for: itemId)
            } else {
                scheduleThreadSnapshotRefresh(for: key)
            }
        case .threadRemoved(let key, let agentDirectoryVersion):
            removeThreadSnapshot(for: key, agentDirectoryVersion: agentDirectoryVersion)
        case .activeThreadChanged(let key):
            updateActiveThread(key)
            if let key, threadSnapshot(for: key) == nil {
                await refreshThreadSnapshot(key: key)
            }
            scheduleDeferredActiveThreadHydrationIfNeeded(for: key)
        case .pendingApprovalsChanged:
            await refreshSnapshot()
        case .pendingUserInputsChanged:
            await refreshSnapshot()
        case .serverChanged:
            scheduleSnapshotRefreshDebounced()
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
                if cachedThreadSnapshots[key] == nil {
                    removeThreadSnapshot(for: key, clearCache: false)
                }
                return
            }
            applyThreadSnapshot(threadSnapshot)
        } catch {
            lastError = error.localizedDescription
            await refreshSnapshot()
        }
    }

    private func scheduleThreadSnapshotRefresh(for key: ThreadKey) {
        pendingThreadRefreshKeys.insert(key)
        guard pendingThreadRefreshTask == nil else { return }
        pendingThreadRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self else { return }
            let keys = self.pendingThreadRefreshKeys
            self.pendingThreadRefreshKeys.removeAll()
            self.pendingThreadRefreshTask = nil
            for key in keys {
                await self.refreshThreadSnapshot(key: key)
            }
        }
    }

    private func shouldBatchLiveThreadStateUpdate(for key: ThreadKey) -> Bool {
        guard let thread = threadSnapshot(for: key) ?? cachedThreadSnapshots[key] else {
            return false
        }
        return thread.activeTurnId != nil || thread.info.status == .active
    }

    private func shouldBatchLiveCommandMutation(for key: ThreadKey) -> Bool {
        shouldBatchLiveThreadStateUpdate(for: key)
    }

    private func shouldBatchCommandRowMutation(
        for key: ThreadKey,
        item: HydratedConversationItem
    ) -> Bool {
        guard shouldBatchLiveCommandMutation(for: key) else { return false }
        return shouldBatchLiveNonAssistantItem(item)
    }

    private func shouldBatchLiveNonAssistantItem(_ item: HydratedConversationItem) -> Bool {
        switch item.content {
        case .assistant, .user:
            return false
        default:
            return true
        }
    }

    private func enqueueThreadStateUpdate(
        _ state: AppThreadStateRecord,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: UInt64
    ) {
        pendingThreadStateEvents[state.key] = PendingThreadStateEvent(
            state: state,
            sessionSummary: sessionSummary,
            agentDirectoryVersion: agentDirectoryVersion
        )

        guard pendingThreadStateTask == nil else { return }
        pendingThreadStateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.liveThreadStateCoalescingNanoseconds)
            guard let self else { return }
            await self.flushPendingThreadStateUpdates()
        }
    }

    private func flushPendingThreadStateUpdates() async {
        let events = pendingThreadStateEvents.values
        pendingThreadStateEvents.removeAll()
        pendingThreadStateTask = nil
        guard !events.isEmpty else { return }

        let relatedMutationKeys = Set(events.map(\.state.key))
        let relatedMutations = drainPendingCommandRowMutations(for: relatedMutationKeys)
        if !relatedMutations.isEmpty {
            let refreshKeys = applyCombinedLiveMutationBatch(
                Array(events),
                mutations: relatedMutations
            )
            for key in refreshKeys {
                await refreshThreadSnapshot(key: key)
            }
            return
        }

        for event in events {
            applyThreadStateUpdated(
                event.state,
                sessionSummary: event.sessionSummary,
                agentDirectoryVersion: event.agentDirectoryVersion
            )
        }
    }

    private func commandRowMutationKey(key: ThreadKey, itemId: String) -> String {
        "\(key.serverId)::\(key.threadId)::\(itemId)"
    }

    private func enqueueCommandRowUpsert(
        key: ThreadKey,
        item: HydratedConversationItem
    ) {
        let mutationKey = commandRowMutationKey(key: key, itemId: item.id)
        var mutation = pendingCommandRowMutations[mutationKey]
            ?? PendingCommandRowMutation(key: key, itemId: item.id)
        mutation.upsertItem = item
        pendingCommandRowMutations[mutationKey] = mutation
        schedulePendingCommandRowMutationsFlush()
    }

    private func schedulePendingCommandRowMutationsFlush() {
        guard pendingCommandRowMutationTask == nil else { return }
        pendingCommandRowMutationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.liveItemMutationCoalescingNanoseconds)
            guard let self else { return }
            await self.flushPendingCommandRowMutations()
        }
    }

    private func flushPendingCommandRowMutations() async {
        let mutations = Array(pendingCommandRowMutations.values)
        pendingCommandRowMutations.removeAll()
        pendingCommandRowMutationTask = nil
        guard !mutations.isEmpty else { return }

        let relatedStateKeys = Set(mutations.map(\.key))
        let relatedStateEvents = drainPendingThreadStateEvents(for: relatedStateKeys)
        if !relatedStateEvents.isEmpty {
            let refreshKeys = applyCombinedLiveMutationBatch(
                relatedStateEvents,
                mutations: mutations
            )
            for key in refreshKeys {
                await refreshThreadSnapshot(key: key)
            }
            return
        }

        let refreshKeys = applyCommandRowMutationBatch(mutations)
        for key in refreshKeys {
            await refreshThreadSnapshot(key: key)
        }
    }

    private func applyCommandRowMutationBatch(
        _ mutations: [PendingCommandRowMutation]
    ) -> Set<ThreadKey> {
        guard var snapshot else {
            return Set(mutations.map(\.key))
        }

        var mutated = false
        var touchedThreadIndexes: Set<Int> = []
        let refreshKeys = applyCommandRowMutationBatch(
            mutations,
            to: &snapshot,
            touchedThreadIndexes: &touchedThreadIndexes,
            mutated: &mutated
        )

        if mutated {
            self.snapshot = snapshot
            for threadIndex in touchedThreadIndexes {
                cacheThreadSnapshot(snapshot.threads[threadIndex])
            }
            lastError = nil
        }

        return refreshKeys
    }

    private func drainPendingThreadStateEvents(
        for keys: Set<ThreadKey>
    ) -> [PendingThreadStateEvent] {
        guard !keys.isEmpty else { return [] }
        let drained = pendingThreadStateEvents
            .filter { keys.contains($0.key) }
            .map(\.value)
        for key in keys {
            pendingThreadStateEvents.removeValue(forKey: key)
        }
        if pendingThreadStateEvents.isEmpty {
            pendingThreadStateTask?.cancel()
            pendingThreadStateTask = nil
        }
        return drained
    }

    private func drainPendingCommandRowMutations(
        for keys: Set<ThreadKey>
    ) -> [PendingCommandRowMutation] {
        guard !keys.isEmpty else { return [] }
        let drained = pendingCommandRowMutations
            .values
            .filter { keys.contains($0.key) }
        pendingCommandRowMutations = pendingCommandRowMutations.filter { _, value in
            !keys.contains(value.key)
        }
        if pendingCommandRowMutations.isEmpty {
            pendingCommandRowMutationTask?.cancel()
            pendingCommandRowMutationTask = nil
        }
        return Array(drained)
    }

    private func applyCombinedLiveMutationBatch(
        _ stateEvents: [PendingThreadStateEvent],
        mutations: [PendingCommandRowMutation]
    ) -> Set<ThreadKey> {
        guard var snapshot else {
            return Set(stateEvents.map(\.state.key)).union(mutations.map(\.key))
        }

        var mutated = false
        var refreshKeys: Set<ThreadKey> = []
        var touchedThreadIndexes: Set<Int> = []

        for event in stateEvents {
            if applyThreadStateUpdated(
                to: &snapshot,
                state: event.state,
                sessionSummary: event.sessionSummary,
                agentDirectoryVersion: event.agentDirectoryVersion
            ) {
                mutated = true
                if let threadIndex = snapshot.threads.firstIndex(where: { $0.key == event.state.key }) {
                    touchedThreadIndexes.insert(threadIndex)
                }
            }
        }

        let commandRefreshKeys = applyCommandRowMutationBatch(
            mutations,
            to: &snapshot,
            touchedThreadIndexes: &touchedThreadIndexes,
            mutated: &mutated
        )
        refreshKeys.formUnion(commandRefreshKeys)

        if mutated {
            self.snapshot = snapshot
            for threadIndex in touchedThreadIndexes {
                cacheThreadSnapshot(snapshot.threads[threadIndex])
            }
            lastError = nil
        }

        return refreshKeys
    }

    @discardableResult
    private func applyThreadStateUpdated(
        to snapshot: inout AppSnapshotRecord,
        state: AppThreadStateRecord,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: UInt64
    ) -> Bool {
        guard let threadIndex = snapshot.threads.firstIndex(where: { $0.key == state.key }) else {
            return false
        }

        var thread = snapshot.threads[threadIndex]
        let shouldPreserveLiveTimestamps = Self.isLiveThreadState(
            existing: thread,
            incoming: state
        )
        let isVisibleActiveLiveThread = shouldPreserveLiveTimestamps && snapshot.activeThread == state.key
        var effectiveInfo = state.info
        if shouldPreserveLiveTimestamps {
            effectiveInfo.updatedAt = thread.info.updatedAt
        }
        thread.info = effectiveInfo
        thread.collaborationMode = state.collaborationMode
        thread.model = state.model
        thread.reasoningEffort = state.reasoningEffort
        thread.effectiveApprovalPolicy = state.effectiveApprovalPolicy
        thread.effectiveSandboxPolicy = state.effectiveSandboxPolicy
        thread.queuedFollowUps = state.queuedFollowUps
        thread.activeTurnId = state.activeTurnId
        thread.activePlanProgress = state.activePlanProgress
        thread.pendingPlanImplementationPrompt = state.pendingPlanImplementationPrompt
        thread.contextTokensUsed = state.contextTokensUsed
        thread.modelContextWindow = state.modelContextWindow
        thread.rateLimits = state.rateLimits
        thread.realtimeSessionId = state.realtimeSessionId
        let threadChanged = snapshot.threads[threadIndex] != thread
        snapshot.threads[threadIndex] = thread

        let sessionSummaryChanged: Bool
        if let index = snapshot.sessionSummaries.firstIndex(where: { $0.key == sessionSummary.key }) {
            let existingSummary = snapshot.sessionSummaries[index]
            var effectiveSessionSummary = sessionSummary
            if shouldPreserveLiveTimestamps {
                effectiveSessionSummary.updatedAt = existingSummary.updatedAt
            }
            sessionSummaryChanged = existingSummary != effectiveSessionSummary
            snapshot.sessionSummaries[index] = effectiveSessionSummary
        } else {
            sessionSummaryChanged = true
            snapshot.sessionSummaries.append(sessionSummary)
        }
        if sessionSummaryChanged {
            snapshot.sessionSummaries.sort(by: Self.sessionSummarySort(lhs:rhs:))
        }
        let agentDirectoryChanged = snapshot.agentDirectoryVersion != agentDirectoryVersion
        if isVisibleActiveLiveThread && !threadChanged && !agentDirectoryChanged {
            return false
        }
        snapshot.agentDirectoryVersion = agentDirectoryVersion
        return threadChanged || sessionSummaryChanged || agentDirectoryChanged
    }

    private func applyCommandRowMutationBatch(
        _ mutations: [PendingCommandRowMutation],
        to snapshot: inout AppSnapshotRecord,
        touchedThreadIndexes: inout Set<Int>,
        mutated: inout Bool
    ) -> Set<ThreadKey> {
        var refreshKeys: Set<ThreadKey> = []

        for mutation in mutations {
            guard let threadIndex = snapshot.threads.firstIndex(where: { $0.key == mutation.key }) else {
                refreshKeys.insert(mutation.key)
                continue
            }

            guard let item = mutation.upsertItem else { continue }
            var thread = snapshot.threads[threadIndex]

            if let itemIndex = thread.hydratedConversationItems.firstIndex(where: { $0.id == item.id }) {
                guard thread.hydratedConversationItems[itemIndex] != item else { continue }
                thread.hydratedConversationItems[itemIndex] = item
            } else {
                let insertionIndex = Self.insertionIndex(for: item, in: thread.hydratedConversationItems)
                thread.hydratedConversationItems.insert(item, at: insertionIndex)
            }

            snapshot.threads[threadIndex] = thread
            touchedThreadIndexes.insert(threadIndex)
            mutated = true
        }

        return refreshKeys
    }

    private func scheduleDeferredActiveThreadHydrationIfNeeded(for key: ThreadKey?) {
        guard let key else {
            pendingActiveThreadHydrationTask?.cancel()
            pendingActiveThreadHydrationTask = nil
            pendingActiveThreadHydrationKey = nil
            return
        }

        guard let thread = threadSnapshot(for: key),
              shouldAttemptDeferredHydration(for: thread) else {
            if pendingActiveThreadHydrationKey == key {
                pendingActiveThreadHydrationTask?.cancel()
                pendingActiveThreadHydrationTask = nil
                pendingActiveThreadHydrationKey = nil
            }
            return
        }

        guard pendingActiveThreadHydrationKey != key || pendingActiveThreadHydrationTask == nil else {
            return
        }

        pendingActiveThreadHydrationTask?.cancel()
        pendingActiveThreadHydrationKey = key
        pendingActiveThreadHydrationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            await self.hydrateActiveThreadIfNeeded(key: key)
        }
    }

    private func hydrateActiveThreadIfNeeded(key: ThreadKey) async {
        defer {
            if pendingActiveThreadHydrationKey == key {
                pendingActiveThreadHydrationTask = nil
                pendingActiveThreadHydrationKey = nil
            }
        }

        guard snapshot?.activeThread == key,
              let thread = threadSnapshot(for: key),
              shouldAttemptDeferredHydration(for: thread) else {
            return
        }

        do {
            let nextKey = try await client.readThread(
                serverId: key.serverId,
                params: AppReadThreadRequest(
                    threadId: key.threadId,
                    includeTurns: true
                )
            )
            if let threadSnapshot = try await store.threadSnapshot(key: nextKey) {
                applyThreadSnapshot(threadSnapshot)
            } else {
                await refreshThreadSnapshot(key: nextKey)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func shouldAttemptDeferredHydration(for thread: AppThreadSnapshot) -> Bool {
        guard thread.hydratedConversationItems.isEmpty else { return false }
        let preview = thread.info.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = thread.info.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !preview.isEmpty || !title.isEmpty || thread.hasActiveTurn
    }

    func renameThread(serverId: String, threadId: String, title rawTitle: String) async throws {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let key = ThreadKey(serverId: serverId, threadId: threadId)

        _ = try await client.renameThread(
            serverId: serverId,
            params: AppRenameThreadRequest(threadId: threadId, name: title)
        )
        applyLocalThreadTitle(title, for: key)
        await refreshSnapshot()
        applyLocalThreadTitle(title, for: key)
    }

    private func applyLocalThreadTitle(_ title: String, for key: ThreadKey) {
        guard var snapshot else { return }
        guard snapshot.applyLocalThreadTitle(title, for: key) else { return }
        self.snapshot = snapshot
        if let thread = snapshot.threadSnapshot(for: key) {
            cacheThreadSnapshot(thread)
        }
        lastError = nil
    }

    private func applyThreadSnapshot(_ thread: AppThreadSnapshot) {
        let thread = mergedThreadSnapshotPreservingHydratedItems(thread)
        guard var snapshot else {
            cacheThreadSnapshot(thread)
            applySnapshot(nil)
            return
        }

        if let index = snapshot.threads.firstIndex(where: { $0.key == thread.key }) {
            snapshot.threads[index] = thread
        } else {
            snapshot.threads.append(thread)
        }
        self.snapshot = snapshot
        cacheThreadSnapshot(thread)
        lastError = nil
    }

    private func applyThreadUpsert(
        _ thread: AppThreadSnapshot,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: UInt64
    ) {
        var thread = mergedThreadSnapshotPreservingHydratedItems(thread)
        guard var snapshot else { return }

        if let index = snapshot.threads.firstIndex(where: { $0.key == thread.key }) {
            let oldThread = snapshot.threads[index]
            if oldThread.activeTurnId != nil {
                Self.preserveStreamingText(from: oldThread, into: &thread)
            }
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
        cacheThreadSnapshot(thread)
        lastError = nil
    }

    private func applyThreadStateUpdated(
        _ state: AppThreadStateRecord,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: UInt64
    ) {
        guard var snapshot else { return }
        guard applyThreadStateUpdated(
            to: &snapshot,
            state: state,
            sessionSummary: sessionSummary,
            agentDirectoryVersion: agentDirectoryVersion
        ) else {
            return
        }
        self.snapshot = snapshot
        if let thread = snapshot.threadSnapshot(for: state.key) {
            cacheThreadSnapshot(thread)
        }
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
            guard thread.hydratedConversationItems[itemIndex] != item else { return true }
            thread.hydratedConversationItems[itemIndex] = item
        } else {
            let insertionIndex = Self.insertionIndex(for: item, in: thread.hydratedConversationItems)
            thread.hydratedConversationItems.insert(item, at: insertionIndex)
        }

        snapshot.threads[threadIndex] = thread
        self.snapshot = snapshot
        cacheThreadSnapshot(thread)
        lastError = nil
        return true
    }

    /// Patch the matching `AppSessionSummary` in `snapshot.sessionSummaries`
    /// when the reducer hands us a freshly-derived one (via `threadItemChanged`,
    /// which now carries it as a field). Ensures home-list fields like
    /// `lastResponsePreview`, `lastToolLabel`, and `stats` track streaming
    /// items without needing a full snapshot rebuild.
    private func applySessionSummary(_ summary: AppSessionSummary) {
        guard var snapshot else { return }
        if let idx = snapshot.sessionSummaries.firstIndex(where: { $0.key == summary.key }) {
            snapshot.sessionSummaries[idx] = summary
        } else {
            snapshot.sessionSummaries.append(summary)
        }
        self.snapshot = snapshot
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
        guard snapshot.threads[threadIndex].hydratedConversationItems[itemIndex] != item else {
            return true
        }
        snapshot.threads[threadIndex].hydratedConversationItems[itemIndex] = item
        self.snapshot = snapshot
        cacheThreadSnapshot(snapshot.threads[threadIndex])
        lastError = nil
        return true
    }

    private func removeThreadSnapshot(
        for key: ThreadKey,
        agentDirectoryVersion: UInt64? = nil,
        clearCache: Bool = true
    ) {
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
        if clearCache {
            cachedThreadSnapshots.removeValue(forKey: key)
        }
    }

    private func updateActiveThread(_ key: ThreadKey?) {
        guard var snapshot else { return }
        snapshot.activeThread = key
        self.snapshot = snapshot
    }

    private static func preserveStreamingText(
        from oldThread: AppThreadSnapshot,
        into newThread: inout AppThreadSnapshot
    ) {
        let oldItemsById = Dictionary(
            oldThread.hydratedConversationItems.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        for (newIndex, newItem) in newThread.hydratedConversationItems.enumerated() {
            guard let oldItem = oldItemsById[newItem.id] else {
                continue
            }
            if let preserved = preservedStreamingContent(old: oldItem.content, new: newItem.content) {
                newThread.hydratedConversationItems[newIndex].content = preserved
            }
        }
    }

    private static func preservedStreamingContent(
        old: HydratedConversationItemContent,
        new: HydratedConversationItemContent
    ) -> HydratedConversationItemContent? {
        switch (old, new) {
        case (.assistant(let oldData), .assistant(var newData))
            where oldData.text.count > newData.text.count && oldData.text.hasPrefix(newData.text):
            newData.text = oldData.text
            return .assistant(newData)
        case (.reasoning(let oldData), .reasoning(var newData))
            where oldData.content.count > newData.content.count:
            let shared = zip(oldData.content, newData.content)
            if shared.allSatisfy({ old, new in old.hasPrefix(new) }) {
                newData.content = oldData.content
                return .reasoning(newData)
            }
            return nil
        case (.proposedPlan(let oldData), .proposedPlan(var newData))
            where oldData.content.count > newData.content.count && oldData.content.hasPrefix(newData.content):
            newData.content = oldData.content
            return .proposedPlan(newData)
        default:
            return nil
        }
    }

    private static func isLiveThreadState(
        existing: AppThreadSnapshot,
        incoming: AppThreadStateRecord
    ) -> Bool {
        if existing.activeTurnId != nil || incoming.activeTurnId != nil {
            return true
        }
        return existing.info.status == .active || incoming.info.status == .active
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

    private static func insertionIndex(
        for item: HydratedConversationItem,
        turnIndex: Int,
        turnItemIndex: Int,
        in items: [HydratedConversationItem]
    ) -> Int {
        let sameTurnIndices = items.enumerated().compactMap { index, existing in
            existing.sourceTurnIndex.map(Int.init) == turnIndex ? index : nil
        }

        if let start = sameTurnIndices.first {
            return min(start + turnItemIndex, start + sameTurnIndices.count)
        }

        if let nextTurnIndex = items.firstIndex(where: {
            guard let sourceTurnIndex = $0.sourceTurnIndex.map(Int.init) else { return false }
            return sourceTurnIndex > turnIndex
        }) {
            return nextTurnIndex
        }

        return item.sourceTurnIndex != nil ? items.count : insertionIndex(for: item, in: items)
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
        if hasFreshConversationMetadata(for: serverId) {
            return
        }
        await loadAvailableModelsIfNeeded(serverId: serverId)
        await loadRateLimitsIfNeeded(serverId: serverId)
        recentConversationMetadataLoads[serverId] = Date()
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
        guard !loadingRateLimitServerIds.contains(serverId) else { return }
        loadingRateLimitServerIds.insert(serverId)
        defer { loadingRateLimitServerIds.remove(serverId) }
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
        let canResumeViaIpc = snapshot?.serverSnapshot(for: key.serverId)?.canResumeViaIpc == true

        if let existing = threadSnapshot(for: key) {
            appState.hydratePermissions(from: existing)
            if !hasAuthoritativePermissions(existing), !canResumeViaIpc {
                scheduleBackgroundThreadPermissionHydration(for: key, appState: appState)
            }
            return key
        }

        if snapshot?.sessionSummary(for: key) != nil {
            if !canResumeViaIpc {
                scheduleBackgroundThreadPermissionHydration(for: key, appState: appState)
            } else {
                LLog.info(
                    "transport",
                    "hydrateThreadPermissions skipping background thread/read for IPC-resumable thread",
                    fields: ["serverId": key.serverId, "threadId": key.threadId]
                )
            }
            return key
        }

        if canResumeViaIpc {
            return key
        }

        do {
            let nextKey = try await client.readThread(
                serverId: key.serverId,
                params: AppReadThreadRequest(
                    threadId: key.threadId,
                    includeTurns: false
                )
            )
            if let threadSnapshot = try await store.threadSnapshot(key: nextKey) {
                applyThreadSnapshot(threadSnapshot)
                appState.hydratePermissions(from: threadSnapshot)
            } else {
                await refreshSnapshot()
                appState.hydratePermissions(from: snapshot?.threadSnapshot(for: nextKey))
            }
            return nextKey
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func scheduleBackgroundThreadPermissionHydration(
        for key: ThreadKey,
        appState: AppState
    ) {
        Task { [weak self] in
            guard let self else { return }
            if self.snapshot?.serverSnapshot(for: key.serverId)?.canResumeViaIpc == true {
                LLog.info(
                    "transport",
                    "scheduleBackgroundThreadPermissionHydration skipping thread/read for IPC-resumable thread",
                    fields: ["serverId": key.serverId, "threadId": key.threadId]
                )
                return
            }
            do {
                let nextKey = try await client.readThread(
                    serverId: key.serverId,
                    params: AppReadThreadRequest(
                        threadId: key.threadId,
                        includeTurns: false
                    )
                )
                if let threadSnapshot = try await store.threadSnapshot(key: nextKey) {
                    applyThreadSnapshot(threadSnapshot)
                    appState.hydratePermissions(from: threadSnapshot)
                } else {
                    await refreshSnapshot()
                    appState.hydratePermissions(from: snapshot?.threadSnapshot(for: nextKey))
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func ensureThreadLoaded(
        key: ThreadKey,
        maxAttempts: Int = 5
    ) async -> ThreadKey? {
        if threadSnapshot(for: key) != nil {
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
            if threadSnapshot(for: currentKey) != nil {
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
                if threadSnapshot(for: currentKey) != nil {
                    return currentKey
                }
            }

            if attempt + 1 < maxAttempts {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        if let activeKey = snapshot?.activeThread,
           activeKey.serverId == currentKey.serverId,
           threadSnapshot(for: activeKey) != nil {
            return activeKey
        }

        return nil
    }

    func threadSnapshot(for key: ThreadKey) -> AppThreadSnapshot? {
        snapshot?.threadSnapshot(for: key) ?? cachedThreadSnapshots[key]
    }

    private func hasAuthoritativePermissions(_ thread: AppThreadSnapshot) -> Bool {
        threadPermissionsAreAuthoritative(
            approvalPolicy: thread.effectiveApprovalPolicy,
            sandboxPolicy: thread.effectiveSandboxPolicy
        )
    }

    private func hasFreshConversationMetadata(for serverId: String) -> Bool {
        guard let server = snapshot?.serverSnapshot(for: serverId) else { return false }
        let hasModels = server.availableModels != nil
        let hasRateLimits = server.account == nil || server.rateLimits != nil
        if hasModels && hasRateLimits {
            return true
        }

        guard let lastLoad = recentConversationMetadataLoads[serverId] else { return false }
        return Date().timeIntervalSince(lastLoad) < 10
    }

    private func restoreCachedThreadSnapshotIfNeeded(for key: ThreadKey?) {
        guard let key,
              snapshot?.threadSnapshot(for: key) == nil,
              let cached = cachedThreadSnapshots[key] else {
            return
        }
        applyThreadSnapshot(cached)
    }

    private func cacheThreadSnapshot(_ thread: AppThreadSnapshot) {
        cachedThreadSnapshots[thread.key] = thread
    }

    private func mergedThreadSnapshotPreservingHydratedItems(_ thread: AppThreadSnapshot) -> AppThreadSnapshot {
        guard let cached = cachedThreadSnapshots[thread.key],
              !cached.hydratedConversationItems.isEmpty else {
            return thread
        }

        if thread.hydratedConversationItems.count < cached.hydratedConversationItems.count {
            LLog.warn("streaming", "threadUpsert arrived with fewer items than cached", fields: [
                "threadId": thread.key.threadId,
                "incoming": thread.hydratedConversationItems.count,
                "cached": cached.hydratedConversationItems.count,
                "status": String(describing: thread.info.status)
            ])
        }

        // Incoming has no items → use cached items entirely.
        if thread.hydratedConversationItems.isEmpty {
            var merged = thread
            merged.hydratedConversationItems = cached.hydratedConversationItems
            return merged
        }

        return thread
    }

    private func mergingCachedThreadSnapshots(_ snapshot: AppSnapshotRecord) -> AppSnapshotRecord {
        var snapshot = snapshot

        for index in snapshot.threads.indices {
            let thread = snapshot.threads[index]
            snapshot.threads[index] = mergedThreadSnapshotPreservingHydratedItems(thread)
        }

        for (key, cached) in cachedThreadSnapshots {
            guard snapshot.threads.contains(where: { $0.key == key }) == false else { continue }
            guard snapshot.activeThread == key ||
                  snapshot.sessionSummaries.contains(where: { $0.key == key }) else {
                continue
            }
            snapshot.threads.append(cached)
        }

        return snapshot
    }
}

extension AppSnapshotRecord {
    func threadSnapshot(for key: ThreadKey) -> AppThreadSnapshot? {
        if let idx = threads.firstIndex(where: { $0.key == key }) {
            return threads[idx]
        }
        return nil
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
