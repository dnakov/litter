package com.litter.android.state

import com.litter.android.core.bridge.UniffiInit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppServerRpc
import uniffi.codex_mobile_client.AppSnapshotRecord
import uniffi.codex_mobile_client.AppStore
import uniffi.codex_mobile_client.AppStoreSubscription
import uniffi.codex_mobile_client.AppStoreUpdateRecord
import uniffi.codex_mobile_client.DiscoveryBridge
import uniffi.codex_mobile_client.HandoffManager
import uniffi.codex_mobile_client.MessageParser
import uniffi.codex_mobile_client.ServerBridge
import uniffi.codex_mobile_client.SshBridge
import uniffi.codex_mobile_client.ThreadKey

/**
 * Central app state singleton. Thin wrapper over Rust [AppStore] — all business
 * logic, reconciliation, and state management lives in Rust.
 *
 * Exposes a [snapshot] StateFlow that the UI observes. Updated automatically
 * via the Rust subscription stream.
 */
class AppModel private constructor(context: android.content.Context) {

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
    val parser: MessageParser
    val appContext: android.content.Context = context

    init {
        UniffiInit.ensure(context)
        store = AppStore()
        rpc = AppServerRpc()
        discovery = DiscoveryBridge()
        serverBridge = ServerBridge()
        ssh = SshBridge()
        parser = MessageParser()
    }

    // --- Observable state ----------------------------------------------------

    private val _snapshot = MutableStateFlow<AppSnapshotRecord?>(null)
    val snapshot: StateFlow<AppSnapshotRecord?> = _snapshot.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    // --- Composer prefill queue (for edit message / slash commands) -----------

    private var pendingPrefill: String? = null

    fun queueComposerPrefill(text: String) {
        pendingPrefill = text
    }

    fun clearComposerPrefill(): String? {
        val text = pendingPrefill
        pendingPrefill = null
        return text
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
                        android.util.Log.d("AppModel", "AppStore update: ${update::class.simpleName}")
                        handleUpdate(update)
                    } catch (e: Exception) {
                        android.util.Log.e("AppModel", "AppStore subscription loop failed", e)
                        throw e
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("AppModel", "AppModel.start() subscription failed", e)
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
            val snap = store.snapshot()
            _snapshot.value = snap
            _lastError.value = null
            val serverSummary = snap.servers.joinToString(separator = " | ") { server ->
                "${server.serverId}:${server.displayName}:${server.host}:${server.port}:${server.health}"
            }
            android.util.Log.d("AppModel", "snapshot servers=${snap.servers.size} [$serverSummary]")
        } catch (e: Exception) {
            _lastError.value = e.message
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
