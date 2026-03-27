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
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicLong
import uniffi.codex_mobile_client.AppServerRpc
import uniffi.codex_mobile_client.AppSnapshotRecord
import uniffi.codex_mobile_client.AppStore
import uniffi.codex_mobile_client.AppStoreSubscription
import uniffi.codex_mobile_client.AppStoreUpdateRecord
import uniffi.codex_mobile_client.DiscoveryBridge
import uniffi.codex_mobile_client.HandoffManager
import uniffi.codex_mobile_client.MessageParser
import uniffi.codex_mobile_client.ModelListParams
import uniffi.codex_mobile_client.ServerBridge
import uniffi.codex_mobile_client.SshBridge
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.ThreadListParams

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
    val rpc: AppServerRpc
    val discovery: DiscoveryBridge
    val serverBridge: ServerBridge
    val ssh: SshBridge
    val sshSessionStore: SshSessionStore
    val parser: MessageParser
    val launchState: AppLaunchState
    val appContext: android.content.Context = context

    init {
        UniffiInit.ensure(context)
        LLog.bootstrap(context)
        store = AppStore()
        rpc = AppServerRpc()
        discovery = DiscoveryBridge()
        serverBridge = ServerBridge()
        ssh = SshBridge()
        sshSessionStore = SshSessionStore(ssh)
        parser = MessageParser()
        launchState = AppLaunchState(context)
    }

    // --- Observable state ----------------------------------------------------

    private val _snapshot = MutableStateFlow<AppSnapshotRecord?>(null)
    val snapshot: StateFlow<AppSnapshotRecord?> = _snapshot.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()
    private val loadingModelServerIds = mutableSetOf<String>()
    private val loadingRateLimitServerIds = mutableSetOf<String>()
    private val sessionListMutex = Mutex()

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
                refreshSnapshot()
                val subscription: AppStoreSubscription = store.subscribeUpdates()
                while (true) {
                    try {
                        val update: AppStoreUpdateRecord = subscription.nextUpdate()
                        LLog.d("AppModel", "AppStore update", fields = mapOf("update" to update::class.simpleName))
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
    }

    // --- Snapshot refresh -----------------------------------------------------

    suspend fun refreshSnapshot() {
        try {
            val snap = applySavedServerNames(store.snapshot())
            _snapshot.value = snap
            _lastError.value = null
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

    private fun applySavedServerNames(snapshot: AppSnapshotRecord): AppSnapshotRecord {
        val nameByServerId = SavedServerStore.load(appContext)
            .mapNotNull { server ->
                val trimmed = server.name.trim()
                if (trimmed.isEmpty()) null else server.id to trimmed
            }
            .toMap()
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
                    rpc.threadList(
                        serverId,
                        ThreadListParams(
                            cursor = null,
                            limit = null,
                            sortKey = null,
                            modelProviders = null,
                            sourceKinds = null,
                            archived = null,
                            cwd = null,
                            searchTerm = null,
                        ),
                    )
                }
                refreshSnapshot()
                _lastError.value = null
            } catch (e: Exception) {
                _lastError.value = e.message
                throw e
            }
        }
    }

    suspend fun loadConversationMetadataIfNeeded(serverId: String) {
        loadAvailableModelsIfNeeded(serverId)
        loadRateLimitsIfNeeded(serverId)
    }

    suspend fun loadAvailableModelsIfNeeded(serverId: String) {
        val server = snapshot.value?.servers?.firstOrNull { it.serverId == serverId } ?: return
        if (!server.isConnected) return
        if (server.availableModels != null) return
        if (!loadingModelServerIds.add(serverId)) return
        try {
            rpc.modelList(
                serverId,
                ModelListParams(cursor = null, limit = null, includeHidden = false),
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
            rpc.getAccountRateLimits(serverId)
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
            rpc.loginAccount(
                serverId,
                uniffi.codex_mobile_client.LoginAccountParams.ChatgptAuthTokens(
                    accessToken = tokens.accessToken,
                    chatgptAccountId = tokens.accountId,
                    chatgptPlanType = tokens.planType,
                ),
            )
        }.onFailure { error ->
            _lastError.value = error.message
        }
    }

    suspend fun startTurn(
        key: ThreadKey,
        payload: AppComposerPayload,
    ) {
        try {
            store.startTurn(key, payload.toTurnStartParams(key.threadId))
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

    // --- Internal event handling ----------------------------------------------

    private suspend fun handleUpdate(update: AppStoreUpdateRecord) {
        // All update types trigger a snapshot refresh.
        // Rust's AppStore handles fine-grained state management internally.
        // We could optimize to only refresh affected parts, but snapshot()
        // is cheap since Rust builds it from in-memory state.
        refreshSnapshot()
    }
}
