package com.litter.android.state

import com.litter.android.core.bridge.UniffiInit
import com.litter.android.util.LLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicLong
import uniffi.codex_mobile_client.AppClient
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppSnapshotRecord
import uniffi.codex_mobile_client.AppStore
import uniffi.codex_mobile_client.AppStoreSubscription
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.ThreadStreamingDeltaKind
import uniffi.codex_mobile_client.AppStoreUpdateRecord
import uniffi.codex_mobile_client.DiscoveryBridge
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.HandoffManager
import uniffi.codex_mobile_client.MessageParser
import uniffi.codex_mobile_client.ReconnectController
import uniffi.codex_mobile_client.ServerBridge
import uniffi.codex_mobile_client.SshBridge
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.AppListThreadsRequest
import uniffi.codex_mobile_client.AppRefreshModelsRequest
import uniffi.codex_mobile_client.AppReadThreadRequest
import uniffi.codex_mobile_client.registerAndroidTools
import uniffi.codex_mobile_client.threadPermissionsAreAuthoritative

/**
 * Central app state singleton. Thin wrapper over Rust [AppStore] — all business
 * logic, reconciliation, and state management lives in Rust.
 *
 * Exposes a [snapshot] StateFlow that the UI observes. Updated automatically
 * via the Rust subscription stream.
 */
class AppModel private constructor(context: android.content.Context) {

    data class ComposerPrefillRequest(
        val requestId: Long,
        val threadKey: ThreadKey,
        val text: String,
    )

    companion object {
        private var _instance: AppModel? = null

        val shared: AppModel
            get() = _instance ?: throw IllegalStateException("AppModel not initialized — call init(context) first")

        fun init(context: android.content.Context): AppModel {
            if (_instance == null) {
                _instance = AppModel(context.applicationContext)
            }
            return _instance!!
        }
    }

    // --- Rust bridges (singletons behind the scenes) -------------------------

    val store: AppStore
    val client: AppClient
    val discovery: DiscoveryBridge
    val serverBridge: ServerBridge
    val ssh: SshBridge
    val sshSessionStore: SshSessionStore
    val parser: MessageParser
    val reconnectController: ReconnectController
    val launchState: AppLaunchState
    val appContext: android.content.Context = context
    init {
        UniffiInit.ensure(context)
        registerBundledCliTools(context)
        LLog.bootstrap(context)
        store = AppStore()
        client = AppClient()
        discovery = DiscoveryBridge()
        serverBridge = ServerBridge()
        ssh = SshBridge()
        sshSessionStore = SshSessionStore(ssh)
        parser = MessageParser()
        reconnectController = ReconnectController()
        reconnectController.setCredentialProvider(
            KotlinSshCredentialProvider(SshCredentialStore(context))
        )
        reconnectController.setIpcSocketPathOverride(
            com.litter.android.ui.ExperimentalFeatures.ipcSocketPathOverride()
        )
        launchState = AppLaunchState(context)
    }

    // --- Observable state ----------------------------------------------------

    private val _snapshot = MutableStateFlow<AppSnapshotRecord?>(null)
    val snapshot: StateFlow<AppSnapshotRecord?> = _snapshot.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()
    private val loadingModelServerIds = mutableSetOf<String>()
    private val loadingRateLimitServerIds = mutableSetOf<String>()
    private val recentConversationMetadataLoads = mutableMapOf<String, Long>()
    private val cachedThreadSnapshots = mutableMapOf<ThreadKey, AppThreadSnapshot>()
    private val sessionListMutex = Mutex()
    private var pendingActiveThreadHydrationKey: ThreadKey? = null
    private var pendingActiveThreadHydrationJob: Job? = null

    // --- Composer prefill queue (for edit message / slash commands) -----------

    private val nextComposerPrefillRequestId = AtomicLong(0)
    private val _composerPrefillRequest = MutableStateFlow<ComposerPrefillRequest?>(null)
    val composerPrefillRequest: StateFlow<ComposerPrefillRequest?> = _composerPrefillRequest.asStateFlow()

    fun queueComposerPrefill(threadKey: ThreadKey, text: String) {
        _composerPrefillRequest.value = ComposerPrefillRequest(
            requestId = nextComposerPrefillRequestId.incrementAndGet(),
            threadKey = threadKey,
            text = text,
        )
    }

    fun clearComposerPrefill(requestId: Long) {
        if (_composerPrefillRequest.value?.requestId == requestId) {
            _composerPrefillRequest.value = null
        }
    }

    // --- Subscription lifecycle ----------------------------------------------

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var subscriptionJob: Job? = null

    fun start() {
        if (subscriptionJob?.isActive == true) return
        subscriptionJob = scope.launch {
            try {
                val subscription: AppStoreSubscription = store.subscribeUpdates()
                refreshSnapshot()
                while (true) {
                    try {
                        val update: AppStoreUpdateRecord = subscription.nextUpdate()
                        handleUpdate(update)
                    } catch (e: Exception) {
                        LLog.e("AppModel", "AppStore subscription loop failed", e)
                        throw e
                    }
                }
            } catch (e: Exception) {
                LLog.e("AppModel", "AppModel.start() subscription failed", e)
                _lastError.value = e.message
            }
        }
    }

    fun stop() {
        subscriptionJob?.cancel()
        subscriptionJob = null
        pendingActiveThreadHydrationJob?.cancel()
        pendingActiveThreadHydrationJob = null
        pendingActiveThreadHydrationKey = null
    }

    // --- Snapshot refresh -----------------------------------------------------

    suspend fun refreshSnapshot() {
        try {
            val snap = store.snapshot()
            applySnapshot(snap)
            val serverSummary = snap.servers.joinToString(separator = " | ") { server ->
                "${server.serverId}:${server.displayName}:${server.host}:${server.port}:${server.health}"
            }
            LLog.d(
                "AppModel",
                "snapshot refreshed",
                fields = mapOf("servers" to snap.servers.size, "summary" to serverSummary),
            )
        } catch (e: Exception) {
            _lastError.value = e.message
        }
    }

    private fun applySnapshot(snapshot: AppSnapshotRecord?) {
        val merged = snapshot
            ?.let(::applySavedServerNames)
            ?.let(::mergeCachedThreadSnapshots)
        _snapshot.value = merged
        if (merged != null) {
            persistWakeMacs(merged)
            merged.threads.forEach(::cacheThreadSnapshot)
            _lastError.value = null
        }
    }

    private fun persistWakeMacs(snapshot: AppSnapshotRecord) {
        snapshot.servers.forEach { server ->
            SavedServerStore.updateWakeMac(
                context = appContext,
                serverId = server.serverId,
                host = server.host,
                wakeMac = server.wakeMac,
            )
        }
    }

    private fun loadSavedServerNames(): Map<String, String> =
        SavedServerStore.load(appContext)
            .mapNotNull { server ->
                val trimmed = server.name.trim()
                if (trimmed.isEmpty()) null else server.id to trimmed
            }
            .toMap()

    private fun applySavedServerNames(snapshot: AppSnapshotRecord): AppSnapshotRecord {
        val nameByServerId = loadSavedServerNames()
        if (nameByServerId.isEmpty()) return snapshot

        return snapshot.copy(
            servers = snapshot.servers.map { server ->
                val savedName = nameByServerId[server.serverId]
                if (savedName != null && savedName != server.displayName) {
                    server.copy(displayName = savedName)
                } else {
                    server
                }
            },
            sessionSummaries = snapshot.sessionSummaries.map { summary ->
                val savedName = nameByServerId[summary.key.serverId]
                if (savedName != null && savedName != summary.serverDisplayName) {
                    summary.copy(serverDisplayName = savedName)
                } else {
                    summary
                }
            },
        )
    }

    private fun applySavedServerName(summary: AppSessionSummary): AppSessionSummary {
        val savedName = loadSavedServerNames()[summary.key.serverId] ?: return summary
        return if (savedName != summary.serverDisplayName) {
            summary.copy(serverDisplayName = savedName)
        } else {
            summary
        }
    }

    /// Patch a single `AppSessionSummary` in the snapshot. Called whenever
    /// the reducer emits a per-item summary update on `threadItemChanged`,
    /// so home-list derived fields track streaming items without waiting
    /// for a full snapshot rebuild.
    private fun applySessionSummary(summary: AppSessionSummary) {
        val current = _snapshot.value ?: return
        val adjusted = applySavedServerName(summary)
        val existingIndex = current.sessionSummaries.indexOfFirst { it.key == adjusted.key }
        val updatedSummaries = current.sessionSummaries.toMutableList().apply {
            if (existingIndex >= 0) {
                this[existingIndex] = adjusted
            } else {
                add(adjusted)
            }
        }
        _snapshot.value = current.copy(sessionSummaries = updatedSummaries)
    }

    suspend fun restartLocalServer() {
        val currentLocal = snapshot.value?.servers?.firstOrNull { it.isLocal }
        val serverId = currentLocal?.serverId ?: "local"
        val displayName = currentLocal?.displayName ?: "This Device"
        runCatching { serverBridge.disconnectServer(serverId) }
        serverBridge.connectLocalServer(
            serverId = serverId,
            displayName = displayName,
            host = "127.0.0.1",
            port = 0u,
        )
        restoreStoredLocalChatGptAuth(serverId)
        try {
            refreshSessions(listOf(serverId))
        } catch (_: Exception) {
        }
        refreshSnapshot()
    }

    suspend fun refreshSessions(serverIds: Collection<String>? = null) {
        val targetServerIds = (serverIds?.toList() ?: snapshot.value?.servers
            ?.filter { it.isConnected }
            ?.map { it.serverId }
            .orEmpty())
            .distinct()

        if (targetServerIds.isEmpty()) {
            return
        }

        sessionListMutex.withLock {
            try {
                for (serverId in targetServerIds) {
                    client.listThreads(
                        serverId,
                        AppListThreadsRequest(
                            cursor = null,
                            limit = null,
                            archived = null,
                            cwd = null,
                            searchTerm = null,
                        ),
                    )
                }
                _lastError.value = null
            } catch (e: Exception) {
                _lastError.value = e.message
                throw e
            }
        }
    }

    suspend fun loadConversationMetadataIfNeeded(serverId: String) {
        if (hasFreshConversationMetadata(serverId)) return
        loadAvailableModelsIfNeeded(serverId)
        loadRateLimitsIfNeeded(serverId)
        recentConversationMetadataLoads[serverId] = System.currentTimeMillis()
    }

    suspend fun loadAvailableModelsIfNeeded(serverId: String) {
        val server = snapshot.value?.servers?.firstOrNull { it.serverId == serverId } ?: return
        if (!server.isConnected) return
        if (server.availableModels != null) return
        if (!loadingModelServerIds.add(serverId)) return
        try {
            client.refreshModels(
                serverId,
                AppRefreshModelsRequest(cursor = null, limit = null, includeHidden = false),
            )
            refreshSnapshot()
        } catch (e: Exception) {
            _lastError.value = e.message
        } finally {
            loadingModelServerIds.remove(serverId)
        }
    }

    suspend fun loadRateLimitsIfNeeded(serverId: String) {
        val server = snapshot.value?.servers?.firstOrNull { it.serverId == serverId } ?: return
        if (!server.isConnected) return
        if (server.account == null) return
        if (server.rateLimits != null) return
        if (!loadingRateLimitServerIds.add(serverId)) return
        try {
            client.refreshRateLimits(serverId)
            refreshSnapshot()
        } catch (e: Exception) {
            _lastError.value = e.message
        } finally {
            loadingRateLimitServerIds.remove(serverId)
        }
    }

    suspend fun restoreStoredLocalChatGptAuth(serverId: String) {
        val tokens = ChatGPTOAuthTokenStore(appContext).load() ?: return
        runCatching {
            client.loginAccount(
                serverId,
                uniffi.codex_mobile_client.AppLoginAccountRequest.ChatgptAuthTokens(
                    accessToken = tokens.accessToken,
                    chatgptAccountId = tokens.accountId,
                    chatgptPlanType = tokens.planType,
                ),
            )
        }.onFailure { error ->
            _lastError.value = error.message
        }
    }

    suspend fun hydrateThreadPermissions(key: ThreadKey): ThreadKey? {
        val existing = threadSnapshot(key)
        if (existing != null && hasAuthoritativePermissions(existing)) {
            launchState.syncFromThread(existing)
            return key
        }

        if (existing != null) {
            launchState.syncFromThread(existing)
            scheduleBackgroundThreadPermissionHydration(key)
            return key
        }

        if (snapshot.value?.sessionSummaries?.any { it.key == key } == true) {
            scheduleBackgroundThreadPermissionHydration(key)
            return key
        }

        return try {
            val nextKey = client.readThread(
                key.serverId,
                AppReadThreadRequest(
                    threadId = key.threadId,
                    includeTurns = false,
                ),
            )
            val threadSnapshot = store.threadSnapshot(nextKey)
            if (threadSnapshot != null) {
                applyThreadSnapshot(threadSnapshot)
                launchState.syncFromThread(threadSnapshot)
            } else {
                refreshSnapshot()
                launchState.syncFromThread(snapshot.value?.threads?.firstOrNull { it.key == nextKey })
            }
            nextKey
        } catch (e: Exception) {
            _lastError.value = e.message
            null
        }
    }

    fun activateThread(key: ThreadKey?) {
        restoreCachedThreadSnapshotIfNeeded(key)
        updateActiveThread(key)
        store.setActiveThread(key)
        scheduleDeferredActiveThreadHydrationIfNeeded(key)
    }

    suspend fun startTurn(
        key: ThreadKey,
        payload: AppComposerPayload,
    ) {
        try {
            store.startTurn(key, payload.toAppStartTurnRequest(key.threadId))
            _lastError.value = null
        } catch (e: Exception) {
            _lastError.value = e.message
            throw e
        }
    }

    suspend fun externalResumeThread(
        key: ThreadKey,
        hostId: String? = null,
    ) {
        try {
            store.externalResumeThread(key, hostId)
            _lastError.value = null
        } catch (e: Exception) {
            _lastError.value = e.message
            throw e
        }
    }

    suspend fun ensureThreadLoaded(
        key: ThreadKey,
        maxAttempts: Int = 5,
    ): ThreadKey? {
        if (threadSnapshot(key) != null) {
            return key
        }

        var currentKey = key
        repeat(maxAttempts) { attempt ->
            var readSucceeded = false
            try {
                val nextKey = client.readThread(
                    currentKey.serverId,
                    AppReadThreadRequest(
                        threadId = currentKey.threadId,
                        includeTurns = true,
                    ),
                )
                currentKey = nextKey
                store.setActiveThread(currentKey)
                readSucceeded = true
            } catch (e: Exception) {
                _lastError.value = e.message
            }

            refreshSnapshot()
            if (threadSnapshot(currentKey) != null) {
                return currentKey
            }

            if (!readSucceeded) {
                try {
                    client.listThreads(
                        currentKey.serverId,
                        AppListThreadsRequest(
                            cursor = null,
                            limit = null,
                            archived = null,
                            cwd = null,
                            searchTerm = null,
                        ),
                    )
                } catch (e: Exception) {
                    _lastError.value = e.message
                }

                refreshSnapshot()
                if (threadSnapshot(currentKey) != null) {
                    return currentKey
                }
            }

            if (attempt + 1 < maxAttempts) {
                delay(250)
            }
        }

        val activeKey = _snapshot.value?.activeThread
        if (activeKey != null &&
            activeKey.serverId == currentKey.serverId &&
            threadSnapshot(activeKey) != null
        ) {
            return activeKey
        }

        return null
    }

    // --- Internal event handling ----------------------------------------------

    private suspend fun handleUpdate(update: AppStoreUpdateRecord) {
        when (update) {
            is AppStoreUpdateRecord.ThreadUpserted ->
                applyThreadUpsert(update.thread, update.sessionSummary, update.agentDirectoryVersion)
            is AppStoreUpdateRecord.ThreadMetadataChanged ->
                applyThreadStateUpdated(update.state, update.sessionSummary, update.agentDirectoryVersion)
            is AppStoreUpdateRecord.ThreadItemChanged -> {
                if (!applyThreadItemChanged(update.key, update.item)) {
                    recoverThreadDeltaApplication(update.key)
                }
                // Reducer piggybacks the refreshed per-thread summary on
                // every item change; patch our local session-summary cache
                // so home-list derived fields (stats, last tool label, etc.)
                // stay in sync with streaming items without waiting for a
                // full snapshot rebuild.
                applySessionSummary(update.sessionSummary)
            }
            is AppStoreUpdateRecord.ThreadStreamingDelta -> {
                if (!applyThreadStreamingDelta(update.key, update.itemId, update.kind, update.text)) {
                    recoverThreadDeltaApplication(update.key)
                }
            }
            is AppStoreUpdateRecord.ThreadRemoved ->
                removeThreadSnapshot(update.key, update.agentDirectoryVersion)
            is AppStoreUpdateRecord.ActiveThreadChanged -> {
                updateActiveThread(update.key)
                if (update.key != null && threadSnapshot(update.key) == null) {
                    refreshThreadSnapshot(update.key)
                }
                scheduleDeferredActiveThreadHydrationIfNeeded(update.key)
            }
            is AppStoreUpdateRecord.PendingApprovalsChanged -> refreshSnapshot()
            is AppStoreUpdateRecord.PendingUserInputsChanged -> refreshSnapshot()
            is AppStoreUpdateRecord.ServerChanged -> refreshSnapshot()
            is AppStoreUpdateRecord.ServerRemoved -> refreshSnapshot()
            is AppStoreUpdateRecord.FullResync -> refreshSnapshot()
            is AppStoreUpdateRecord.VoiceSessionChanged -> refreshSnapshot()
            is AppStoreUpdateRecord.RealtimeTranscriptUpdated -> Unit
            is AppStoreUpdateRecord.RealtimeHandoffRequested -> Unit
            is AppStoreUpdateRecord.RealtimeSpeechStarted -> Unit
            is AppStoreUpdateRecord.RealtimeStarted -> refreshSnapshot()
            is AppStoreUpdateRecord.RealtimeOutputAudioDelta -> Unit
            is AppStoreUpdateRecord.RealtimeError -> refreshSnapshot()
            is AppStoreUpdateRecord.RealtimeClosed -> refreshSnapshot()
        }
    }

    private suspend fun recoverThreadDeltaApplication(key: ThreadKey) {
        val current = _snapshot.value
        val threadMissing = current?.threads?.any { it.key == key } != true
        val summaryMissing = current?.sessionSummaries?.any { it.key == key } != true
        if (threadMissing && summaryMissing) {
            refreshSnapshot()
        } else {
            refreshThreadSnapshot(key)
        }
    }

    private suspend fun refreshThreadSnapshot(key: ThreadKey) {
        if (_snapshot.value == null) {
            refreshSnapshot()
            return
        }

        try {
            val threadSnapshot = store.threadSnapshot(key)
            if (threadSnapshot == null) {
                if (cachedThreadSnapshots[key] == null) {
                    removeThreadSnapshot(key, clearCache = false)
                }
                return
            }
            applyThreadSnapshot(threadSnapshot)
        } catch (e: Exception) {
            _lastError.value = e.message
            refreshSnapshot()
        }
    }

    private fun scheduleBackgroundThreadPermissionHydration(key: ThreadKey) {
        scope.launch {
            try {
                val nextKey = client.readThread(
                    key.serverId,
                    AppReadThreadRequest(
                        threadId = key.threadId,
                        includeTurns = false,
                    ),
                )
                val threadSnapshot = store.threadSnapshot(nextKey)
                if (threadSnapshot != null) {
                    applyThreadSnapshot(threadSnapshot)
                    launchState.syncFromThread(threadSnapshot)
                } else {
                    refreshSnapshot()
                    launchState.syncFromThread(snapshot.value?.threads?.firstOrNull { it.key == nextKey })
                }
            } catch (e: Exception) {
                _lastError.value = e.message
            }
        }
    }

    private fun scheduleDeferredActiveThreadHydrationIfNeeded(key: ThreadKey?) {
        if (key == null) {
            pendingActiveThreadHydrationJob?.cancel()
            pendingActiveThreadHydrationJob = null
            pendingActiveThreadHydrationKey = null
            return
        }

        val thread = threadSnapshot(key)
        if (thread == null || !shouldAttemptDeferredHydration(thread)) {
            if (pendingActiveThreadHydrationKey == key) {
                pendingActiveThreadHydrationJob?.cancel()
                pendingActiveThreadHydrationJob = null
                pendingActiveThreadHydrationKey = null
            }
            return
        }

        if (pendingActiveThreadHydrationKey == key && pendingActiveThreadHydrationJob != null) {
            return
        }

        pendingActiveThreadHydrationJob?.cancel()
        pendingActiveThreadHydrationKey = key
        pendingActiveThreadHydrationJob = scope.launch {
            delay(300)
            hydrateActiveThreadIfNeeded(key)
        }
    }

    private suspend fun hydrateActiveThreadIfNeeded(key: ThreadKey) {
        try {
            val current = snapshot.value
            val thread = threadSnapshot(key)
            if (current?.activeThread != key || thread == null || !shouldAttemptDeferredHydration(thread)) {
                return
            }

            val nextKey = client.readThread(
                key.serverId,
                AppReadThreadRequest(
                    threadId = key.threadId,
                    includeTurns = true,
                ),
            )
            val threadSnapshot = store.threadSnapshot(nextKey)
            if (threadSnapshot != null) {
                applyThreadSnapshot(threadSnapshot)
            } else {
                refreshThreadSnapshot(nextKey)
            }
        } catch (e: Exception) {
            _lastError.value = e.message
        } finally {
            if (pendingActiveThreadHydrationKey == key) {
                pendingActiveThreadHydrationJob = null
                pendingActiveThreadHydrationKey = null
            }
        }
    }

    private fun shouldAttemptDeferredHydration(thread: AppThreadSnapshot): Boolean {
        if (thread.hydratedConversationItems.isNotEmpty()) return false
        val preview = thread.info.preview?.trim().orEmpty()
        val title = thread.info.title?.trim().orEmpty()
        return preview.isNotEmpty() || title.isNotEmpty() || thread.hasActiveTurn
    }

    private fun applyThreadSnapshot(thread: AppThreadSnapshot) {
        val mergedThread = mergedThreadSnapshotPreservingHydratedItems(thread)
        val current = _snapshot.value
        if (current == null) {
            cacheThreadSnapshot(mergedThread)
            return
        }
        val existingIndex = current.threads.indexOfFirst { it.key == thread.key }
        val updatedThreads = current.threads.toMutableList().apply {
            if (existingIndex >= 0) {
                this[existingIndex] = mergedThread
            } else {
                add(mergedThread)
            }
        }
        _snapshot.value = current.copy(threads = updatedThreads)
        cacheThreadSnapshot(mergedThread)
        _lastError.value = null
    }

    private fun applyThreadUpsert(
        thread: AppThreadSnapshot,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: ULong,
    ) {
        val mergedThread = mergedThreadSnapshotPreservingHydratedItems(thread)
        val current = _snapshot.value ?: return
        val existingThreadIndex = current.threads.indexOfFirst { it.key == thread.key }

        // Race condition guard: during active streaming, if the old thread has
        // longer assistant text that starts with the new text, preserve the old
        // (more complete) text to avoid flickering backwards.
        val finalThread = if (existingThreadIndex >= 0) {
            val oldThread = current.threads[existingThreadIndex]
            if (oldThread.hasActiveTurn) {
                preserveStreamingText(oldThread, mergedThread)
            } else {
                mergedThread
            }
        } else {
            mergedThread
        }

        val updatedThreads = current.threads.toMutableList().apply {
            if (existingThreadIndex >= 0) {
                this[existingThreadIndex] = finalThread
            } else {
                add(finalThread)
            }
        }

        val adjustedSummary = applySavedServerName(sessionSummary)
        val existingSummaryIndex = current.sessionSummaries.indexOfFirst { it.key == adjustedSummary.key }
        val updatedSummaries = current.sessionSummaries.toMutableList().apply {
            if (existingSummaryIndex >= 0) {
                this[existingSummaryIndex] = adjustedSummary
            } else {
                add(adjustedSummary)
            }
            sortWith(compareByDescending<AppSessionSummary> { it.updatedAt ?: Long.MIN_VALUE }
                .thenBy { it.key.serverId }
                .thenBy { it.key.threadId })
        }

        _snapshot.value = current.copy(
            threads = updatedThreads,
            sessionSummaries = updatedSummaries,
            agentDirectoryVersion = agentDirectoryVersion,
        )
        cacheThreadSnapshot(finalThread)
        _lastError.value = null
    }

    private fun preserveStreamingText(
        oldThread: AppThreadSnapshot,
        newThread: AppThreadSnapshot,
    ): AppThreadSnapshot {
        if (newThread.hydratedConversationItems.isEmpty()) return newThread
        val oldItemsById = oldThread.hydratedConversationItems.associateBy { it.id }
        var changed = false
        val mergedItems = newThread.hydratedConversationItems.map { newItem ->
            val oldItem = oldItemsById[newItem.id]
            if (oldItem != null) {
                val oldText = assistantText(oldItem.content)
                val newText = assistantText(newItem.content)
                if (oldText != null && newText != null &&
                    oldText.length > newText.length &&
                    oldText.startsWith(newText)
                ) {
                    changed = true
                    oldItem
                } else {
                    newItem
                }
            } else {
                newItem
            }
        }
        return if (changed) newThread.copy(hydratedConversationItems = mergedItems) else newThread
    }

    private fun assistantText(content: HydratedConversationItemContent): String? =
        when (content) {
            is HydratedConversationItemContent.Assistant -> content.v1.text
            else -> null
        }

    private fun applyThreadStateUpdated(
        state: uniffi.codex_mobile_client.AppThreadStateRecord,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: ULong,
    ) {
        val current = _snapshot.value ?: return
        val existingThreadIndex = current.threads.indexOfFirst { it.key == state.key }
        if (existingThreadIndex < 0) return

        val existingThread = current.threads[existingThreadIndex]
        val updatedThread = existingThread.copy(
            info = state.info,
            collaborationMode = state.collaborationMode,
            model = state.model,
            reasoningEffort = state.reasoningEffort,
            effectiveApprovalPolicy = state.effectiveApprovalPolicy,
            effectiveSandboxPolicy = state.effectiveSandboxPolicy,
            activeTurnId = state.activeTurnId,
            activePlanProgress = state.activePlanProgress,
            pendingPlanImplementationPrompt = state.pendingPlanImplementationPrompt,
            contextTokensUsed = state.contextTokensUsed,
            modelContextWindow = state.modelContextWindow,
            rateLimits = state.rateLimits,
            realtimeSessionId = state.realtimeSessionId,
        )
        val updatedThreads = current.threads.toMutableList().apply {
            this[existingThreadIndex] = updatedThread
        }

        val adjustedSummary = applySavedServerName(sessionSummary)
        val existingSummaryIndex = current.sessionSummaries.indexOfFirst { it.key == adjustedSummary.key }
        val updatedSummaries = current.sessionSummaries.toMutableList().apply {
            if (existingSummaryIndex >= 0) {
                this[existingSummaryIndex] = adjustedSummary
            } else {
                add(adjustedSummary)
            }
            sortWith(compareByDescending<AppSessionSummary> { it.updatedAt ?: Long.MIN_VALUE }
                .thenBy { it.key.serverId }
                .thenBy { it.key.threadId })
        }

        _snapshot.value = current.copy(
            threads = updatedThreads,
            sessionSummaries = updatedSummaries,
            agentDirectoryVersion = agentDirectoryVersion,
        )
        cacheThreadSnapshot(updatedThread)
        _lastError.value = null
    }

    private fun applyThreadItemChanged(
        key: ThreadKey,
        item: HydratedConversationItem,
    ): Boolean {
        val current = _snapshot.value ?: return false
        val threadIndex = current.threads.indexOfFirst { it.key == key }
        if (threadIndex < 0) return false

        val thread = current.threads[threadIndex]
        val updatedItems = thread.hydratedConversationItems.toMutableList()
        val existingItemIndex = updatedItems.indexOfFirst { it.id == item.id }
        if (existingItemIndex >= 0) {
            updatedItems[existingItemIndex] = item
        } else {
            val insertionIndex = insertionIndexForItem(updatedItems, item)
            updatedItems.add(insertionIndex, item)
        }
        applyThreadSnapshot(thread.copy(hydratedConversationItems = updatedItems))
        return true
    }

    private fun applyThreadStreamingDelta(
        key: ThreadKey,
        itemId: String,
        kind: ThreadStreamingDeltaKind,
        text: String,
    ): Boolean {
        val current = _snapshot.value ?: return false
        val threadIndex = current.threads.indexOfFirst { it.key == key }
        if (threadIndex < 0) return false

        val thread = current.threads[threadIndex]
        val itemIndex = thread.hydratedConversationItems.indexOfFirst { it.id == itemId }
        if (itemIndex < 0) return false

        val updatedContent = applyStreamingDelta(kind, text, thread.hydratedConversationItems[itemIndex].content)
            ?: return false
        val updatedItems = thread.hydratedConversationItems.toMutableList().apply {
            this[itemIndex] = this[itemIndex].copy(content = updatedContent)
        }
        applyThreadSnapshot(thread.copy(hydratedConversationItems = updatedItems))
        return true
    }

    private fun applyStreamingDelta(
        kind: ThreadStreamingDeltaKind,
        text: String,
        content: HydratedConversationItemContent,
    ): HydratedConversationItemContent? = when (kind) {
        ThreadStreamingDeltaKind.ASSISTANT_TEXT -> when (content) {
            is HydratedConversationItemContent.Assistant ->
                HydratedConversationItemContent.Assistant(content.v1.copy(text = content.v1.text + text))
            else -> null
        }
        ThreadStreamingDeltaKind.REASONING_TEXT -> when (content) {
            is HydratedConversationItemContent.Reasoning -> {
                val updatedContent = content.v1.content.toMutableList().apply {
                    if (isEmpty()) {
                        add(text)
                    } else {
                        this[lastIndex] = this[lastIndex] + text
                    }
                }
                HydratedConversationItemContent.Reasoning(content.v1.copy(content = updatedContent))
            }
            else -> null
        }
        ThreadStreamingDeltaKind.PLAN_TEXT -> when (content) {
            is HydratedConversationItemContent.ProposedPlan ->
                HydratedConversationItemContent.ProposedPlan(content.v1.copy(content = content.v1.content + text))
            else -> null
        }
        ThreadStreamingDeltaKind.COMMAND_OUTPUT -> when (content) {
            is HydratedConversationItemContent.CommandExecution ->
                HydratedConversationItemContent.CommandExecution(
                    content.v1.copy(output = (content.v1.output ?: "") + text)
                )
            else -> null
        }
        ThreadStreamingDeltaKind.MCP_PROGRESS -> when (content) {
            is HydratedConversationItemContent.McpToolCall -> {
                val updatedProgress = content.v1.progressMessages.toMutableList().apply {
                    if (text.isNotBlank()) {
                        add(text)
                    }
                }
                HydratedConversationItemContent.McpToolCall(
                    content.v1.copy(progressMessages = updatedProgress)
                )
            }
            else -> null
        }
    }

    private fun insertionIndexForItem(
        items: List<HydratedConversationItem>,
        item: HydratedConversationItem,
    ): Int {
        val targetTurn = item.sourceTurnIndex?.toInt() ?: return items.size
        val lastSameTurn = items.indexOfLast { it.sourceTurnIndex?.toInt() == targetTurn }
        if (lastSameTurn >= 0) return lastSameTurn + 1

        val nextTurn = items.indexOfFirst {
            val sourceTurn = it.sourceTurnIndex?.toInt()
            sourceTurn != null && sourceTurn > targetTurn
        }
        return if (nextTurn >= 0) nextTurn else items.size
    }

    private fun hasAuthoritativePermissions(thread: AppThreadSnapshot): Boolean =
        threadPermissionsAreAuthoritative(
            approvalPolicy = thread.effectiveApprovalPolicy,
            sandboxPolicy = thread.effectiveSandboxPolicy,
        )

    private fun removeThreadSnapshot(
        key: ThreadKey,
        agentDirectoryVersion: ULong? = null,
        clearCache: Boolean = true,
    ) {
        val current = _snapshot.value ?: return
        _snapshot.value = current.copy(
            threads = current.threads.filterNot { it.key == key },
            sessionSummaries = current.sessionSummaries.filterNot { it.key == key },
            agentDirectoryVersion = agentDirectoryVersion ?: current.agentDirectoryVersion,
            activeThread = if (current.activeThread == key) null else current.activeThread,
        )
        if (clearCache) {
            cachedThreadSnapshots.remove(key)
        }
    }

    private fun updateActiveThread(key: ThreadKey?) {
        val current = _snapshot.value ?: return
        _snapshot.value = current.copy(activeThread = key)
    }

    fun threadSnapshot(key: ThreadKey): AppThreadSnapshot? =
        _snapshot.value?.threads?.firstOrNull { it.key == key } ?: cachedThreadSnapshots[key]

    private fun hasFreshConversationMetadata(serverId: String): Boolean {
        val server = snapshot.value?.servers?.firstOrNull { it.serverId == serverId } ?: return false
        val hasModels = server.availableModels != null
        val hasRateLimits = server.account == null || server.rateLimits != null
        if (hasModels && hasRateLimits) return true

        val lastLoad = recentConversationMetadataLoads[serverId] ?: return false
        return System.currentTimeMillis() - lastLoad < 10_000L
    }

    private fun restoreCachedThreadSnapshotIfNeeded(key: ThreadKey?) {
        if (key == null) return
        if (_snapshot.value?.threads?.any { it.key == key } == true) return
        val cached = cachedThreadSnapshots[key] ?: return
        applyThreadSnapshot(cached)
    }

    private fun cacheThreadSnapshot(thread: AppThreadSnapshot) {
        cachedThreadSnapshots[thread.key] = thread
    }

    private fun mergedThreadSnapshotPreservingHydratedItems(thread: AppThreadSnapshot): AppThreadSnapshot {
        if (thread.hydratedConversationItems.isNotEmpty()) return thread
        val cached = cachedThreadSnapshots[thread.key] ?: return thread
        if (cached.hydratedConversationItems.isEmpty()) return thread
        return thread.copy(hydratedConversationItems = cached.hydratedConversationItems)
    }

    private fun mergeCachedThreadSnapshots(snapshot: AppSnapshotRecord): AppSnapshotRecord {
        val mergedThreads = snapshot.threads
            .map(::mergedThreadSnapshotPreservingHydratedItems)
            .toMutableList()

        cachedThreadSnapshots.forEach { (key, cached) ->
            val alreadyPresent = mergedThreads.any { it.key == key }
            val shouldInclude = snapshot.activeThread == key || snapshot.sessionSummaries.any { it.key == key }
            if (!alreadyPresent && shouldInclude) {
                mergedThreads += cached
            }
        }

        return snapshot.copy(threads = mergedThreads)
    }
}

/**
 * CLI tools we ship as ELF executables under `app/src/main/jniLibs/<abi>/lib<tool>.so`.
 * Android packs these into `nativeLibraryDir`, which is the only execute-allowed
 * directory in an app sandbox on Android 10+. Tools not present here fall through
 * to PATH-based lookup (which finds `/system/bin/{ls,cat,grep,sed,awk,...}`).
 */
private val BUNDLED_CLI_TOOLS = listOf("git", "curl", "wget")

private fun registerBundledCliTools(context: android.content.Context) {
    val nativeDir = context.applicationInfo.nativeLibraryDir ?: return
    val tools = HashMap<String, String>()
    for (tool in BUNDLED_CLI_TOOLS) {
        val candidate = java.io.File(nativeDir, "lib$tool.so")
        if (candidate.exists() && candidate.canExecute()) {
            tools[tool] = candidate.absolutePath
        }
    }
    try {
        registerAndroidTools(tools)
        android.util.Log.i(
            "AppModel",
            "Registered ${tools.size} bundled CLI tools: ${tools.keys}",
        )
    } catch (e: Throwable) {
        android.util.Log.w("AppModel", "registerAndroidTools failed: ${e.message}")
    }
}
