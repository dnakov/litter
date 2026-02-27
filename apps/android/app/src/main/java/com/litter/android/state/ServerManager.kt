package com.litter.android.state

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.net.Uri
import com.litter.android.core.bridge.CodexRpcClient
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.net.URL
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.LinkedHashMap
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

data class FuzzyFileSearchResult(
    val root: String,
    val path: String,
    val fileName: String,
    val score: Int,
    val indices: List<Int> = emptyList(),
)

class ServerManager(
    context: Context? = null,
    private val codexRpcClient: CodexRpcClient = CodexRpcClient(),
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "Litter-ServerManager").apply { isDaemon = true }
    },
) : Closeable {
    companion object {
        private const val OPENAI_AUTH_ISSUER = "https://auth.openai.com"
        private const val OPENAI_CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
        private const val RUNTIME_PREFERENCES = "litter_runtime"
        private const val BACKGROUND_CONNECTION_ENABLED_KEY = "background_connection_enabled"
    }
    private val listeners = CopyOnWriteArrayList<(AppState) -> Unit>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val threadsByKey = LinkedHashMap<ThreadKey, ThreadState>()
    private val transportsByServerId = LinkedHashMap<String, BridgeRpcTransport>()
    private val serversById = LinkedHashMap<String, ServerConfig>()
    private val accountByServerId = LinkedHashMap<String, AccountState>()
    private val liveItemMessageIndices = LinkedHashMap<ThreadKey, MutableMap<String, Int>>()
    private val liveTurnDiffMessageIndices = LinkedHashMap<ThreadKey, MutableMap<String, Int>>()
    private val serversUsingItemNotifications = HashSet<String>()
    private val threadTurnCounts = LinkedHashMap<ThreadKey, Int>()

    private val appContext = context?.applicationContext
    private val bundledAuthStore: BundledAuthStore? =
        appContext?.let { ctx -> runCatching { BundledAuthStore(ctx) }.getOrNull() }
    private val savedServersPreferences by lazy {
        appContext?.getSharedPreferences("litter_saved_servers", Context.MODE_PRIVATE)
    }
    private val runtimePreferences by lazy {
        appContext?.getSharedPreferences(RUNTIME_PREFERENCES, Context.MODE_PRIVATE)
    }
    private val savedServersKey = "servers"
    private val backgroundConnectionEnabledDefault =
        runtimePreferences?.getBoolean(BACKGROUND_CONNECTION_ENABLED_KEY, false) ?: false
    private val awayNotifier = appContext?.let { AwayNotificationHelper(it) }

    @Volatile
    private var appInForeground = true

    @Volatile
    private var backgroundConnectionEnabled = backgroundConnectionEnabledDefault

    @Volatile
    private var state: AppState =
        AppState(
            savedServers = loadSavedServersInternal(),
            backgroundConnectionEnabled = backgroundConnectionEnabledDefault,
        )

    @Volatile
    private var closed = false

    @Volatile
    private var composerApprovalPolicy: String = "never"

    @Volatile
    private var composerSandboxMode: String = "workspace-write"

    fun observe(listener: (AppState) -> Unit): Closeable {
        listeners += listener
        val snapshot = state
        mainHandler.post { listener(snapshot) }
        return Closeable { listeners.remove(listener) }
    }

    fun snapshot(): AppState = state

    fun connectLocalDefaultServer(onComplete: ((Result<ServerConfig>) -> Unit)? = null) {
        submit {
            updateState {
                it.copy(
                    connectionStatus = ServerConnectionStatus.CONNECTING,
                    connectionError = null,
                )
            }

            val result = runCatching {
                val server = connectLocalDefaultServerInternal()
                refreshSessionsInternal(server.id)
                loadModelsInternal(server.id)
                refreshAccountStateInternal(server.id)
                server
            }

            result.exceptionOrNull()?.let { error ->
                updateState {
                    it.copy(
                        connectionStatus = ServerConnectionStatus.ERROR,
                        connectionError = error.message ?: "Failed to connect",
                    )
                }
            }
            deliver(onComplete, result)
        }
    }

    fun connectServer(
        server: ServerConfig,
        onComplete: ((Result<ServerConfig>) -> Unit)? = null,
    ) {
        submit {
            updateState {
                it.copy(
                    connectionStatus = ServerConnectionStatus.CONNECTING,
                    connectionError = null,
                )
            }

            val result = runCatching {
                val connected = connectServerInternal(server)
                refreshSessionsInternal(connected.id)
                loadModelsInternal(connected.id)
                refreshAccountStateInternal(connected.id)
                connected
            }

            result.exceptionOrNull()?.let { error ->
                updateState {
                    it.copy(
                        connectionStatus = ServerConnectionStatus.ERROR,
                        connectionError = error.message ?: "Failed to connect",
                    )
                }
            }
            deliver(onComplete, result)
        }
    }

    fun reconnectSavedServers(onComplete: ((Result<List<ServerConfig>>) -> Unit)? = null) {
        submit {
            val result = runCatching {
                val saved = loadSavedServersInternal()
                val connected = mutableListOf<ServerConfig>()
                for (savedServer in saved) {
                    runCatching {
                        val cfg = savedServer.toServerConfig()
                        val connectedServer = connectServerInternal(cfg)
                        refreshSessionsInternal(connectedServer.id)
                        refreshAccountStateInternal(connectedServer.id)
                        connected += connectedServer
                    }
                }
                if (connected.isNotEmpty()) {
                    loadModelsInternal(connected.first().id)
                }
                connected
            }
            deliver(onComplete, result)
        }
    }

    fun disconnect(serverId: String? = null) {
        submit {
            disconnectInternal(serverId)
        }
    }

    fun removeServer(serverId: String) {
        disconnect(serverId)
    }

    fun refreshSessions(onComplete: ((Result<List<ThreadState>>) -> Unit)? = null) {
        submit {
            val result = runCatching { refreshSessionsInternal() }
            result.exceptionOrNull()?.let { error ->
                updateState {
                    it.copy(
                        connectionStatus = ServerConnectionStatus.ERROR,
                        connectionError = error.message ?: "Failed to refresh sessions",
                    )
                }
            }
            deliver(onComplete, result)
        }
    }

    fun syncActiveThreadFromServer(onComplete: ((Result<Unit>) -> Unit)? = null) {
        submit {
            val result = runCatching { syncActiveThreadFromServerInternal() }
            deliver(onComplete, result)
        }
    }

    fun loadModels(onComplete: ((Result<List<ModelOption>>) -> Unit)? = null) {
        submit {
            val result = runCatching { loadModelsInternal() }
            deliver(onComplete, result)
        }
    }

    fun refreshAccountState(onComplete: ((Result<AccountState>) -> Unit)? = null) {
        submit {
            val result = runCatching {
                val serverId = resolveServerIdForActiveOperations()
                refreshAccountStateInternal(serverId)
            }
            deliver(onComplete, result)
        }
    }

    fun readBundledLogs(onComplete: ((Result<String>) -> Unit)? = null) {
        submit {
            val result = runCatching { readBundledLogsInternal() }
            deliver(onComplete, result)
        }
    }

    fun loginWithChatGpt(onComplete: ((Result<AccountState>) -> Unit)? = null) {
        submit {
            val result = runCatching {
                val serverId = resolveServerIdForAuthOperations()
                loginWithChatGptInternal(serverId)
            }
            deliver(onComplete, result)
        }
    }

    fun loginWithApiKey(
        apiKey: String,
        onComplete: ((Result<AccountState>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching {
                val serverId = resolveServerIdForAuthOperations()
                loginWithApiKeyInternal(serverId, apiKey)
            }
            deliver(onComplete, result)
        }
    }

    fun logoutAccount(onComplete: ((Result<AccountState>) -> Unit)? = null) {
        submit {
            val result = runCatching {
                val serverId = resolveServerIdForActiveOperations()
                logoutAccountInternal(serverId)
            }
            deliver(onComplete, result)
        }
    }

    fun cancelLogin(onComplete: ((Result<AccountState>) -> Unit)? = null) {
        submit {
            val result = runCatching {
                val serverId = resolveServerIdForActiveOperations()
                cancelLoginInternal(serverId)
            }
            deliver(onComplete, result)
        }
    }

    fun resolveHomeDirectory(
        serverId: String? = null,
        onComplete: ((Result<String>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { resolveHomeDirectoryInternal(serverId) }
            deliver(onComplete, result)
        }
    }

    fun listDirectories(
        path: String,
        serverId: String? = null,
        onComplete: ((Result<List<String>>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { listDirectoriesInternal(path, serverId) }
            deliver(onComplete, result)
        }
    }

    fun fuzzyFileSearch(
        query: String,
        roots: List<String>,
        cancellationToken: String? = null,
        onComplete: ((Result<List<FuzzyFileSearchResult>>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { fuzzyFileSearchInternal(query, roots, cancellationToken) }
            deliver(onComplete, result)
        }
    }

    fun updateModelSelection(
        modelId: String? = null,
        reasoningEffort: String? = null,
    ) {
        submit {
            updateState { current ->
                val next = current.selectedModel.copy(
                    modelId = modelId ?: current.selectedModel.modelId,
                    reasoningEffort = reasoningEffort ?: current.selectedModel.reasoningEffort,
                )
                current.copy(selectedModel = next)
            }
        }
    }

    fun updateComposerPermissions(
        approvalPolicy: String,
        sandboxMode: String,
    ) {
        submit {
            composerApprovalPolicy = approvalPolicy.trim().ifEmpty { "never" }
            composerSandboxMode = sandboxMode.trim().ifEmpty { "workspace-write" }
        }
    }

    fun setBackgroundConnectionEnabled(enabled: Boolean) {
        submit {
            backgroundConnectionEnabled = enabled
            runtimePreferences?.edit()?.putBoolean(BACKGROUND_CONNECTION_ENABLED_KEY, enabled)?.apply()
            if (enabled) {
                startRealtimeConnectionServiceIfNeeded()
            } else {
                stopRealtimeConnectionService()
                if (!appInForeground) {
                    suspendRealtimeConnectionsInternal()
                }
            }
            updateState { current -> current.copy(backgroundConnectionEnabled = enabled) }
        }
    }

    fun onAppForegrounded() {
        submit {
            appInForeground = true
            stopRealtimeConnectionService()
            runCatching { resumeRealtimeConnectionsInternal() }
            runCatching { syncAllThreadsFromServerInternal() }
        }
    }

    fun onAppBackgrounded() {
        submit {
            appInForeground = false
            if (backgroundConnectionEnabled) {
                startRealtimeConnectionServiceIfNeeded()
            } else {
                runCatching { suspendRealtimeConnectionsInternal() }
            }
        }
    }

    fun startThread(
        cwd: String = defaultWorkingDirectory(),
        modelSelection: ModelSelection? = null,
        serverId: String? = null,
        onComplete: ((Result<ThreadKey>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { startThreadInternal(cwd, modelSelection, serverId) }
            deliver(onComplete, result)
        }
    }

    fun resumeThread(
        threadId: String,
        cwd: String = defaultWorkingDirectory(),
        onComplete: ((Result<ThreadKey>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching {
                val serverId = resolveServerIdForActiveOperations()
                resumeThreadInternal(serverId = serverId, threadId = threadId, cwd = cwd)
            }
            deliver(onComplete, result)
        }
    }

    fun selectThread(
        threadKey: ThreadKey,
        cwdForLazyResume: String? = null,
        onComplete: ((Result<ThreadKey>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching {
                val existing = threadsByKey[threadKey]
                    ?: throw IllegalStateException("Unknown thread: ${threadKey.threadId}")
                if (existing.messages.isEmpty() && !cwdForLazyResume.isNullOrBlank()) {
                    resumeThreadInternal(threadKey.serverId, threadKey.threadId, cwdForLazyResume)
                } else {
                    updateState {
                        it.copy(
                            activeThreadKey = threadKey,
                            activeServerId = threadKey.serverId,
                        )
                    }
                    threadKey
                }
            }
            deliver(onComplete, result)
        }
    }

    fun sendMessage(
        text: String,
        cwd: String? = null,
        modelSelection: ModelSelection? = null,
        localImagePath: String? = null,
        skillMentions: List<SkillMentionInput> = emptyList(),
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching {
                sendMessageInternal(
                    text = text,
                    cwd = cwd ?: state.currentCwd,
                    modelSelection = modelSelection ?: state.selectedModel,
                    localImagePath = localImagePath,
                    skillMentions = skillMentions,
                )
            }
            deliver(onComplete, result)
        }
    }

    fun interrupt(onComplete: ((Result<Unit>) -> Unit)? = null) {
        submit {
            val result = runCatching { interruptInternal() }
            deliver(onComplete, result)
        }
    }

    fun startReviewOnActiveThread(onComplete: ((Result<Unit>) -> Unit)? = null) {
        submit {
            val result = runCatching { startReviewOnActiveThreadInternal() }
            deliver(onComplete, result)
        }
    }

    fun renameActiveThread(
        name: String,
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { renameActiveThreadInternal(name) }
            deliver(onComplete, result)
        }
    }

    fun renameThread(
        threadKey: ThreadKey,
        name: String,
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { renameThreadInternal(threadKey, name) }
            deliver(onComplete, result)
        }
    }

    fun editMessage(
        messageId: String,
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { editMessageInternal(messageId) }
            deliver(onComplete, result)
        }
    }

    fun forkConversation(
        onComplete: ((Result<ThreadKey>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { forkConversationInternal() }
            deliver(onComplete, result)
        }
    }

    fun forkThread(
        threadKey: ThreadKey,
        onComplete: ((Result<ThreadKey>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { forkThreadByKeyInternal(threadKey) }
            deliver(onComplete, result)
        }
    }

    fun forkConversationFromMessage(
        messageId: String,
        onComplete: ((Result<ThreadKey>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { forkConversationFromMessageInternal(messageId) }
            deliver(onComplete, result)
        }
    }

    fun archiveThread(
        threadKey: ThreadKey,
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { archiveThreadInternal(threadKey) }
            deliver(onComplete, result)
        }
    }

    fun listExperimentalFeatures(
        limit: Int = 200,
        onComplete: ((Result<List<ExperimentalFeature>>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { listExperimentalFeaturesInternal(limit) }
            deliver(onComplete, result)
        }
    }

    fun setExperimentalFeatureEnabled(
        featureName: String,
        enabled: Boolean,
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { setExperimentalFeatureEnabledInternal(featureName, enabled) }
            deliver(onComplete, result)
        }
    }

    fun listSkills(
        cwds: List<String>? = null,
        forceReload: Boolean = false,
        onComplete: ((Result<List<SkillMetadata>>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { listSkillsInternal(cwds, forceReload) }
            deliver(onComplete, result)
        }
    }

    override fun close() {
        if (closed) {
            return
        }
        closed = true
        stopRealtimeConnectionService()
        runCatching {
            transportsByServerId.values.forEach { it.close() }
            transportsByServerId.clear()
        }
        runCatching { codexRpcClient.stop() }
        runCatching { worker.shutdownNow() }
    }

    private fun connectLocalDefaultServerInternal(): ServerConfig {
        val port = codexRpcClient.ensureServerStarted()
        val local = ServerConfig.local(port)
        return connectServerInternal(local)
    }

    private fun connectServerInternal(server: ServerConfig): ServerConfig {
        val existingServer = serversById[server.id]
        val existingTransport = transportsByServerId[server.id]
        if (existingServer != null && existingTransport != null) {
            updateState {
                it.copy(
                    activeServerId = server.id,
                    connectionStatus = ServerConnectionStatus.READY,
                    connectionError = null,
                )
            }
            return existingServer
        }

        val normalizedServer =
            if (server.source == ServerSource.LOCAL) {
                // Always resolve the active on-device bridge port instead of trusting discovery defaults.
                ServerConfig.local(codexRpcClient.ensureServerStarted())
            } else if (server.source == ServerSource.BUNDLED) {
                ensureBundledServiceReady()
                ServerConfig.bundled(BundledCodexService.PORT)
            } else {
                server.copy(host = normalizeServerHost(server.host))
            }

        val transport = BridgeRpcTransport(
            url = websocketUrl(normalizedServer),
            onNotification = { method, params ->
                submit {
                    handleNotification(normalizedServer.id, method, params)
                }
            },
            onServerRequest = { method, params ->
                handleServerRequestInternal(normalizedServer.id, method, params)
            },
        )

        try {
            transport.connect(timeoutSeconds = 15)
            sendInitialize(transport)
            if (normalizedServer.source == ServerSource.BUNDLED) {
                restoreBundledAuthIfAvailableInternal(serverId = normalizedServer.id, transport = transport)
            }
        } catch (error: Throwable) {
            transport.close()
            throw error
        }

        transportsByServerId[normalizedServer.id]?.close()
        transportsByServerId[normalizedServer.id] = transport
        serversById[normalizedServer.id] = normalizedServer
        accountByServerId.putIfAbsent(normalizedServer.id, AccountState())
        persistSavedServersInternal()

        updateState {
            val preferredCwd =
                if (normalizedServer.source == ServerSource.BUNDLED) {
                    preferredDirectoryRootForServer(normalizedServer.id)
                } else {
                    it.currentCwd
                }
            it.copy(
                connectionStatus = ServerConnectionStatus.READY,
                connectionError = null,
                activeServerId = normalizedServer.id,
                currentCwd = preferredCwd,
                )
        }
        startRealtimeConnectionServiceIfNeeded()

        return normalizedServer
    }

    private fun disconnectInternal(serverId: String?) {
        if (serverId == null) {
            stopRealtimeConnectionService()
            transportsByServerId.values.forEach { runCatching { it.close() } }
            transportsByServerId.clear()
            serversById.clear()
            accountByServerId.clear()
            threadsByKey.clear()
            liveItemMessageIndices.clear()
            liveTurnDiffMessageIndices.clear()
            serversUsingItemNotifications.clear()
            threadTurnCounts.clear()
            runCatching { codexRpcClient.stop() }
            runCatching { appContext?.stopService(android.content.Intent(appContext, BundledCodexService::class.java)) }
            commitState(
                state.copy(
                    connectionStatus = ServerConnectionStatus.DISCONNECTED,
                    connectionError = null,
                    activeServerId = null,
                    activeThreadKey = null,
                    availableModels = emptyList(),
                    accountByServerId = emptyMap(),
                ),
            )
            persistSavedServersInternal()
            return
        }

        runCatching { transportsByServerId.remove(serverId)?.close() }
        val removedServer = serversById.remove(serverId)
        accountByServerId.remove(serverId)
        threadsByKey.entries.removeAll { it.key.serverId == serverId }
        liveItemMessageIndices.keys.removeAll { it.serverId == serverId }
        liveTurnDiffMessageIndices.keys.removeAll { it.serverId == serverId }
        serversUsingItemNotifications.remove(serverId)
        threadTurnCounts.keys.removeAll { it.serverId == serverId }

        if (removedServer?.source == ServerSource.LOCAL && serversById.values.none { it.source == ServerSource.LOCAL }) {
            runCatching { codexRpcClient.stop() }
        }

        if (removedServer?.source == ServerSource.BUNDLED && serversById.values.none { it.source == ServerSource.BUNDLED }) {
            runCatching { appContext?.stopService(android.content.Intent(appContext, BundledCodexService::class.java)) }
        }
        if (serversById.isEmpty()) {
            stopRealtimeConnectionService()
        }

        val nextActiveThread =
            if (state.activeThreadKey?.serverId == serverId) {
                threadsByKey.keys.firstOrNull()
            } else {
                state.activeThreadKey
            }
        val nextActiveServer =
            when {
                state.activeServerId == serverId -> nextActiveThread?.serverId ?: serversById.keys.firstOrNull()
                else -> state.activeServerId?.takeIf { serversById.containsKey(it) } ?: serversById.keys.firstOrNull()
            }

        val nextConnectionStatus =
            if (serversById.isEmpty()) {
                ServerConnectionStatus.DISCONNECTED
            } else {
                ServerConnectionStatus.READY
            }

        commitState(
            state.copy(
                connectionStatus = nextConnectionStatus,
                connectionError = null,
                activeServerId = nextActiveServer,
                activeThreadKey = nextActiveThread,
                availableModels = if (serversById.isEmpty()) emptyList() else state.availableModels,
                accountByServerId = LinkedHashMap(accountByServerId),
            ),
        )
        persistSavedServersInternal()
    }

    private fun startRealtimeConnectionServiceIfNeeded() {
        val context = appContext ?: return
        if (appInForeground || !backgroundConnectionEnabled || serversById.isEmpty()) {
            return
        }
        val intent = Intent(context, RealtimeConnectionService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    private fun stopRealtimeConnectionService() {
        val context = appContext ?: return
        runCatching { context.stopService(Intent(context, RealtimeConnectionService::class.java)) }
    }

    private fun websocketUrl(server: ServerConfig): String {
        val host = normalizeServerHost(server.host)
        val normalizedHost =
            if (host.contains(':') && !host.startsWith("[") && !host.endsWith("]")) {
                "[$host]"
            } else {
                host
            }
        return "ws://$normalizedHost:${server.port}"
    }

    private fun normalizeServerHost(rawHost: String): String {
        var host = rawHost.trim()
        if (host.isEmpty()) {
            return "127.0.0.1"
        }

        if (host.contains("://")) {
            host =
                runCatching {
                    val parsed = URI(host)
                    parsed.host?.trim()
                        ?: parsed.path?.trim()?.trimStart('/')
                        ?: host
                }.getOrDefault(host)
        }

        host = host.trim().trimStart('/').trimEnd('/')
        return host.ifEmpty { "127.0.0.1" }
    }

    private fun sendInitialize(transport: BridgeRpcTransport) {
        val params = JSONObject()
            .put(
                "clientInfo",
                JSONObject()
                    .put("name", "Litter Android")
                    .put("version", "1.0")
                    .put("title", JSONObject.NULL),
            )
            .put(
                "capabilities",
                JSONObject()
                    .put("experimentalApi", true),
            )
        transport.request(method = "initialize", params = params)
    }

    private fun refreshSessionsInternal(serverId: String? = null): List<ThreadState> {
        val targetServers =
            if (serverId != null) {
                listOfNotNull(serversById[serverId])
            } else {
                serversById.values.toList()
            }

        for (server in targetServers) {
            val transport = requireTransport(server.id)
            val response = transport.request(
                method = "thread/list",
                params = JSONObject()
                    .put("cursor", JSONObject.NULL)
                    .put("limit", 50)
                    .put("sortKey", "updated_at")
                    .put("cwd", JSONObject.NULL),
            )

            val data = response.optJSONArray("data") ?: JSONArray()
            for (index in 0 until data.length()) {
                val item = data.optJSONObject(index) ?: continue
                val threadId = item.optString("id").trim()
                if (threadId.isEmpty()) {
                    continue
                }
                val key = ThreadKey(server.id, threadId)
                val existing = threadsByKey[key]
                val preview = item.optString("preview").trim().ifBlank {
                    item.optString("name").trim().ifBlank {
                        existing?.preview ?: "Session $threadId"
                    }
                }
                val cwd = item.optString("cwd").trim().ifBlank { existing?.cwd ?: state.currentCwd }
                val modelProvider = parseModelProvider(item).ifBlank { existing?.modelProvider.orEmpty() }
                val parentThreadId = parseParentThreadId(item) ?: existing?.parentThreadId
                val rootThreadId = parseRootThreadId(item) ?: existing?.rootThreadId
                val updatedAtRaw =
                    item.opt("updatedAt").asLongOrNull()
                        ?: item.opt("updated_at").asLongOrNull()
                        ?: System.currentTimeMillis()
                val updatedAtEpochMillis = normalizeEpochMillis(updatedAtRaw)
                val remoteStatus = item.optString("status").trim().lowercase(Locale.ROOT)
                val resolvedStatus =
                    when (remoteStatus) {
                        "inprogress", "in_progress", "running", "busy" -> ThreadStatus.THINKING
                        "failed", "error" -> ThreadStatus.ERROR
                        else -> existing?.status ?: ThreadStatus.READY
                    }

                threadsByKey[key] =
                    ThreadState(
                        key = key,
                        serverName = server.name,
                        serverSource = server.source,
                        status = resolvedStatus,
                        messages = existing?.messages ?: emptyList(),
                        preview = preview,
                        cwd = cwd,
                        modelProvider = modelProvider,
                        parentThreadId = parentThreadId,
                        rootThreadId = rootThreadId,
                        updatedAtEpochMillis = maxOf(updatedAtEpochMillis, existing?.updatedAtEpochMillis ?: 0L),
                        activeTurnId = existing?.activeTurnId,
                        lastError = existing?.lastError,
                    )
                threadTurnCounts[key] = threadTurnCounts[key] ?: inferredTurnCountFromMessages(existing?.messages.orEmpty())
            }
        }

        updateState {
            it.copy(
                connectionStatus = if (serversById.isEmpty()) ServerConnectionStatus.DISCONNECTED else ServerConnectionStatus.READY,
                connectionError = null,
            )
        }
        return state.threads
    }

    private fun loadModelsInternal(serverId: String? = null): List<ModelOption> {
        val targetServerId = serverId ?: resolveServerIdForActiveOperations()
        val transport = requireTransport(targetServerId)
        val response = transport.request(
            method = "model/list",
            params = JSONObject()
                .put("cursor", JSONObject.NULL)
                .put("limit", 50)
                .put("includeHidden", false),
        )

        val data = response.optJSONArray("data") ?: JSONArray()
        val parsed = ArrayList<ModelOption>(data.length())
        for (index in 0 until data.length()) {
            val item = data.optJSONObject(index) ?: continue
            val modelId =
                item.optString("model").trim().ifBlank {
                    item.optString("id").trim()
                }
            if (modelId.isEmpty()) {
                continue
            }
            val displayName =
                item.optString("displayName").trim().ifBlank {
                    item.optString("display_name").trim().ifBlank { modelId }
                }
            val description = item.optString("description").trim()
            val defaultEffort =
                item.optString("defaultReasoningEffort").trim().takeIf { it.isNotEmpty() }
                    ?: item.optString("default_reasoning_effort").trim().takeIf { it.isNotEmpty() }
            val supportedEfforts =
                parseReasoningEfforts(item.optJSONArray("supportedReasoningEfforts"))
                    .ifEmpty { parseReasoningEfforts(item.optJSONArray("supported_reasoning_efforts")) }
            val isDefault =
                item.optBoolean("isDefault", false) ||
                    item.optBoolean("is_default", false)

            parsed +=
                ModelOption(
                    id = modelId,
                    displayName = displayName,
                    description = description,
                    defaultReasoningEffort = defaultEffort,
                    supportedReasoningEfforts = supportedEfforts,
                    isDefault = isDefault,
                )
        }

        updateState { current ->
            val selectedModel = chooseModelSelection(current.selectedModel, parsed)
            current.copy(
                availableModels = parsed,
                selectedModel = selectedModel,
                activeServerId = targetServerId,
            )
        }
        return parsed
    }

    private fun refreshAccountStateInternal(serverId: String): AccountState {
        val response =
            requireTransport(serverId).request(
                method = "account/read",
                params = JSONObject().put("refreshToken", false),
            )

        val account = response.optJSONObject("account")
        val accountState =
            if (account == null || account == JSONObject.NULL) {
                AccountState(status = AuthStatus.NOT_LOGGED_IN)
            } else {
                when (account.optString("type")) {
                    "chatgpt" -> {
                        AccountState(
                            status = AuthStatus.CHATGPT,
                            email = account.optString("email").trim(),
                            oauthUrl = accountByServerId[serverId]?.oauthUrl,
                            pendingLoginId = accountByServerId[serverId]?.pendingLoginId,
                        )
                    }

                    "apiKey" -> {
                        AccountState(
                            status = AuthStatus.API_KEY,
                            oauthUrl = null,
                            pendingLoginId = null,
                        )
                    }

                    else -> AccountState(status = AuthStatus.NOT_LOGGED_IN)
                }
            }

        accountByServerId[serverId] = accountState
        updateState {
            it.copy(
                accountByServerId = LinkedHashMap(accountByServerId),
                activeServerId = serverId,
            )
        }
        return accountState
    }

    private fun readBundledLogsInternal(): String {
        val context = appContext ?: throw IllegalStateException("Android context is unavailable")
        val activeServerId = state.activeServerId
        val activeSource = activeServerId?.let { serversById[it]?.source }
        val diagnostics =
            buildString {
                appendLine("Bundled Diagnostics")
                appendLine("activeServerId=${activeServerId ?: "none"}")
                appendLine("activeSource=${activeSource ?: "unknown"}")
                appendLine("connectionStatus=${state.connectionStatus}")
                appendLine("connectionError=${state.connectionError ?: ""}")
                appendLine("accountStatus=${state.activeAccount.status}")
                appendLine("---")
            }
        return diagnostics + BundledCodexService.readLogTail(context)
    }

    private fun restoreBundledAuthIfAvailableInternal(
        serverId: String,
        transport: BridgeRpcTransport,
    ) {
        val tokens = bundledAuthStore?.load() ?: return
        runCatching {
            loginWithBundledTokens(
                transport = transport,
                accessToken = tokens.accessToken,
                chatgptAccountId = tokens.chatgptAccountId,
                chatgptPlanType = tokens.chatgptPlanType,
            )
        }.onFailure {
            bundledAuthStore?.clear()
            accountByServerId[serverId] =
                (accountByServerId[serverId] ?: AccountState(status = AuthStatus.NOT_LOGGED_IN)).copy(
                    status = AuthStatus.NOT_LOGGED_IN,
                    oauthUrl = null,
                    pendingLoginId = null,
                    lastError = "Session expired. Please log in again.",
                )
        }
    }

    private fun handleServerRequestInternal(
        serverId: String,
        method: String,
        params: JSONObject?,
    ): JSONObject? {
        when (method) {
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval" -> {
                val threadId =
                    extractString(
                        params,
                        "threadId",
                        "thread_id",
                        "conversationId",
                        "conversation_id",
                    )
                val itemId = extractString(params, "itemId", "item_id", "callId", "call_id")
                val reason = extractString(params, "reason")
                val fallbackTitle = "Codex Approval Required"
                val title =
                    if (!threadId.isNullOrBlank()) {
                        approvalNotificationTitle(ThreadKey(serverId, threadId))
                    } else {
                        fallbackTitle
                    }
                notifyAwayIfNeeded(
                    dedupeKey = "approval:$serverId:${threadId ?: "none"}:${itemId ?: "request"}",
                    title = title,
                    body = reason ?: "Approval required for a tool action.",
                )
                return JSONObject().put("decision", "accept")
            }

            "account/chatgptAuthTokens/refresh" -> {
                // Continue below with existing refresh-token path.
            }

            else -> return null
        }
        if (serversById[serverId]?.source != ServerSource.BUNDLED) {
            throw IllegalStateException("External token refresh is only supported for bundled auth")
        }

        return runCatching {
            val existing = bundledAuthStore?.load() ?: throw IllegalStateException("No stored bundled auth tokens")
            val refreshToken = existing.refreshToken ?: throw IllegalStateException("No refresh token available")
            val refreshed = exchangeRefreshToken(refreshToken)
            val idClaims = decodeJwtClaims(refreshed.idToken)
            val accessClaims = decodeJwtClaims(refreshed.accessToken)
            val info = resolveBundledAccountInfo(idClaims, accessClaims)
            val previousAccountId = params?.optString("previousAccountId")?.trim().orEmpty().ifEmpty { null }
            if (previousAccountId != null && previousAccountId != info.accountId) {
                throw IllegalStateException("Refreshed token account mismatch")
            }

            bundledAuthStore?.save(
                BundledAuthTokens(
                    accessToken = refreshed.accessToken,
                    idToken = refreshed.idToken,
                    refreshToken = refreshed.refreshToken ?: refreshToken,
                    chatgptAccountId = info.accountId,
                    chatgptPlanType = info.planType,
                ),
            )

            JSONObject()
                .put("accessToken", refreshed.accessToken)
                .put("chatgptAccountId", info.accountId)
                .put("chatgptPlanType", info.planType ?: JSONObject.NULL)
        }.getOrElse { error ->
            bundledAuthStore?.clear()
            accountByServerId[serverId] =
                (accountByServerId[serverId] ?: AccountState(status = AuthStatus.NOT_LOGGED_IN)).copy(
                    status = AuthStatus.NOT_LOGGED_IN,
                    oauthUrl = null,
                    pendingLoginId = null,
                    lastError = "Session expired. Please log in again.",
                )
            updateState {
                it.copy(
                    accountByServerId = LinkedHashMap(accountByServerId),
                    activeServerId = serverId,
                    connectionError = "Session expired. Please log in again.",
                )
            }
            throw IllegalStateException(error.message ?: "Failed to refresh ChatGPT tokens")
        }
    }

    private fun loginWithChatGptInternal(serverId: String): AccountState {
        if (serversById[serverId]?.source == ServerSource.BUNDLED) {
            return loginWithChatGptViaAndroidOauthInternal(serverId)
        }

        val existing = accountByServerId[serverId]
        val existingPendingId = existing?.pendingLoginId?.trim().takeIf { !it.isNullOrEmpty() }
        val existingOauthUrl = existing?.oauthUrl?.trim().takeIf { !it.isNullOrEmpty() }
        if (existingPendingId != null && existingOauthUrl != null) {
            return existing ?: AccountState()
        }

        val response =
            requireTransport(serverId).request(
                method = "account/login/start",
                params = JSONObject().put("type", "chatgpt"),
            )

        val next =
            accountByServerId[serverId]
                ?.copy(
                    oauthUrl = response.optString("authUrl").trim().ifBlank { null },
                    pendingLoginId = response.optString("loginId").trim().ifBlank { null },
                    lastError = null,
                ) ?: AccountState(
                status = AuthStatus.UNKNOWN,
                oauthUrl = response.optString("authUrl").trim().ifBlank { null },
                pendingLoginId = response.optString("loginId").trim().ifBlank { null },
            )

        accountByServerId[serverId] = next
        updateState {
            it.copy(accountByServerId = LinkedHashMap(accountByServerId), activeServerId = serverId)
        }
        return next
    }

    private fun loginWithChatGptViaAndroidOauthInternal(serverId: String): AccountState {
        val context = appContext ?: throw IllegalStateException("Android context is unavailable")
        val callbackPort = 1455
        val redirectUri = "http://localhost:$callbackPort/auth/callback"
        val stateToken = UUID.randomUUID().toString()
        val codeVerifier = generatePkceCodeVerifier()
        val codeChallenge = generatePkceCodeChallenge(codeVerifier)
        val scopes = "openid profile email offline_access"

        val authUrl =
            Uri.parse("$OPENAI_AUTH_ISSUER/oauth/authorize").buildUpon()
                .appendQueryParameter("response_type", "code")
                .appendQueryParameter("client_id", OPENAI_CODEX_CLIENT_ID)
                .appendQueryParameter("redirect_uri", redirectUri)
                .appendQueryParameter("scope", scopes)
                .appendQueryParameter("code_challenge", codeChallenge)
                .appendQueryParameter("code_challenge_method", "S256")
                .appendQueryParameter("state", stateToken)
                .appendQueryParameter("id_token_add_organizations", "true")
                .appendQueryParameter("codex_cli_simplified_flow", "true")
                .build()
                .toString()

        accountByServerId[serverId] =
            (accountByServerId[serverId] ?: AccountState()).copy(
                oauthUrl = authUrl,
                pendingLoginId = "android-oauth",
                lastError = null,
            )
        updateState {
            it.copy(accountByServerId = LinkedHashMap(accountByServerId), activeServerId = serverId)
        }

        openBrowserForUrl(context, authUrl)

        val callback = awaitOAuthCallback(callbackPort = callbackPort, expectedState = stateToken, timeoutMs = 10 * 60 * 1000L)
        if (callback.error != null) {
            throw IllegalStateException(callback.error)
        }
        val code = callback.code ?: throw IllegalStateException("Missing authorization code")

        val tokenResponse = exchangeAuthorizationCode(code = code, codeVerifier = codeVerifier, redirectUri = redirectUri)
        val idClaims = decodeJwtClaims(tokenResponse.idToken)
        val accessClaims = decodeJwtClaims(tokenResponse.accessToken)
        val accountInfo = resolveBundledAccountInfo(idClaims, accessClaims)
        loginWithBundledTokens(
            transport = requireTransport(serverId),
            accessToken = tokenResponse.accessToken,
            chatgptAccountId = accountInfo.accountId,
            chatgptPlanType = accountInfo.planType,
        )
        bundledAuthStore?.save(
            BundledAuthTokens(
                accessToken = tokenResponse.accessToken,
                idToken = tokenResponse.idToken,
                refreshToken = tokenResponse.refreshToken,
                chatgptAccountId = accountInfo.accountId,
                chatgptPlanType = accountInfo.planType,
            ),
        )

        accountByServerId[serverId] =
            (accountByServerId[serverId] ?: AccountState()).copy(
                oauthUrl = null,
                pendingLoginId = null,
                lastError = null,
            )
        updateState {
            it.copy(accountByServerId = LinkedHashMap(accountByServerId), activeServerId = serverId)
        }
        return refreshAccountStateInternal(serverId)
    }

    private fun openBrowserForUrl(context: Context, url: String) {
        val intent =
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        context.startActivity(intent)
    }

    private data class OAuthCallbackResult(
        val code: String?,
        val error: String?,
    )

    private fun awaitOAuthCallback(
        callbackPort: Int,
        expectedState: String,
        timeoutMs: Long,
    ): OAuthCallbackResult {
        val server = ServerSocket()
        server.reuseAddress = true
        server.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), callbackPort))
        server.soTimeout = timeoutMs.toInt().coerceAtMost(Int.MAX_VALUE)
        return server.use { socketServer ->
            val socket = socketServer.accept()
            socket.use { client ->
                val input = client.getInputStream().bufferedReader()
                val requestLine = input.readLine().orEmpty()
                val pathWithQuery = requestLine.substringAfter(' ', "").substringBefore(' ')
                val query = pathWithQuery.substringAfter('?', "")
                val params = parseQueryParams(query)
                val responseBody = "<html><body><h3>Login complete</h3><p>You can return to Litter.</p></body></html>"
                client.getOutputStream().bufferedWriter().use { writer ->
                    writer.write("HTTP/1.1 200 OK\r\n")
                    writer.write("Content-Type: text/html; charset=UTF-8\r\n")
                    writer.write("Connection: close\r\n")
                    writer.write("Content-Length: ${responseBody.toByteArray(StandardCharsets.UTF_8).size}\r\n")
                    writer.write("\r\n")
                    writer.write(responseBody)
                    writer.flush()
                }

                val returnedState = params["state"].orEmpty()
                if (returnedState != expectedState) {
                    return OAuthCallbackResult(code = null, error = "OAuth state mismatch")
                }
                val error = params["error"]?.ifBlank { null }
                if (error != null) {
                    val description = params["error_description"]?.ifBlank { null }
                    return OAuthCallbackResult(code = null, error = "OAuth error: ${description ?: error}")
                }
                val code = params["code"]?.ifBlank { null }
                return OAuthCallbackResult(code = code, error = if (code == null) "Missing authorization code" else null)
            }
        }
    }

    private fun parseQueryParams(query: String): Map<String, String> {
        if (query.isBlank()) {
            return emptyMap()
        }
        val out = LinkedHashMap<String, String>()
        query.split('&').forEach { pair ->
            val key = pair.substringBefore('=', "").trim()
            if (key.isBlank()) return@forEach
            val value = pair.substringAfter('=', "")
            out[URLDecoder.decode(key, StandardCharsets.UTF_8)] =
                URLDecoder.decode(value, StandardCharsets.UTF_8)
        }
        return out
    }

    private data class OAuthTokenResponse(
        val accessToken: String,
        val idToken: String,
        val refreshToken: String?,
    )

    private fun exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        redirectUri: String,
    ): OAuthTokenResponse {
        val body =
            "grant_type=authorization_code" +
                "&code=${urlEncode(code)}" +
                "&redirect_uri=${urlEncode(redirectUri)}" +
                "&client_id=${urlEncode(OPENAI_CODEX_CLIENT_ID)}" +
                "&code_verifier=${urlEncode(codeVerifier)}"

        val connection = (URL("$OPENAI_AUTH_ISSUER/oauth/token").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = 20_000
            readTimeout = 20_000
            setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        }
        try {
            OutputStreamWriter(connection.outputStream, StandardCharsets.UTF_8).use { writer ->
                writer.write(body)
                writer.flush()
            }

            val status = connection.responseCode
            val responseText =
                runCatching {
                    val stream = if (status in 200..299) connection.inputStream else connection.errorStream
                    stream?.bufferedReader()?.use { it.readText() }.orEmpty()
                }.getOrDefault("")
            if (status !in 200..299) {
                throw IllegalStateException("OAuth token exchange failed ($status): ${responseText.take(300)}")
            }
            val json = JSONObject(responseText)
            val accessToken = json.optString("access_token").trim()
            val idToken = json.optString("id_token").trim()
            if (accessToken.isBlank() || idToken.isBlank()) {
                throw IllegalStateException("OAuth token exchange returned missing tokens")
            }
            return OAuthTokenResponse(
                accessToken = accessToken,
                idToken = idToken,
                refreshToken = json.optString("refresh_token").trim().ifBlank { null },
            )
        } finally {
            connection.disconnect()
        }
    }

    private fun exchangeRefreshToken(refreshToken: String): OAuthTokenResponse {
        val body =
            "grant_type=refresh_token" +
                "&refresh_token=${urlEncode(refreshToken)}" +
                "&client_id=${urlEncode(OPENAI_CODEX_CLIENT_ID)}"

        val connection = (URL("$OPENAI_AUTH_ISSUER/oauth/token").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = 20_000
            readTimeout = 20_000
            setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        }
        try {
            OutputStreamWriter(connection.outputStream, StandardCharsets.UTF_8).use { writer ->
                writer.write(body)
                writer.flush()
            }
            val status = connection.responseCode
            val responseText =
                runCatching {
                    val stream = if (status in 200..299) connection.inputStream else connection.errorStream
                    stream?.bufferedReader()?.use { it.readText() }.orEmpty()
                }.getOrDefault("")
            if (status !in 200..299) {
                throw IllegalStateException("OAuth refresh failed ($status): ${responseText.take(300)}")
            }
            val json = JSONObject(responseText)
            val accessToken = json.optString("access_token").trim()
            val idToken = json.optString("id_token").trim()
            if (accessToken.isBlank() || idToken.isBlank()) {
                throw IllegalStateException("OAuth refresh returned missing tokens")
            }
            return OAuthTokenResponse(
                accessToken = accessToken,
                idToken = idToken,
                refreshToken = json.optString("refresh_token").trim().ifBlank { null },
            )
        } finally {
            connection.disconnect()
        }
    }

    private data class BundledAccountInfo(
        val accountId: String,
        val planType: String?,
    )

    private fun resolveBundledAccountInfo(
        idClaims: JSONObject,
        accessClaims: JSONObject,
    ): BundledAccountInfo {
        val accountId =
            idClaims.optString("chatgpt_account_id").trim().ifBlank {
                accessClaims.optString("chatgpt_account_id").trim().ifBlank {
                    idClaims.optString("organization_id").trim().ifBlank {
                        accessClaims.optString("organization_id").trim().ifBlank {
                            throw IllegalStateException("OAuth token missing chatgpt_account_id claim")
                        }
                    }
                }
            }
        val planType =
            accessClaims.optString("chatgpt_plan_type").trim().ifBlank {
                idClaims.optString("chatgpt_plan_type").trim().ifBlank { null }
            }
        return BundledAccountInfo(accountId = accountId, planType = planType)
    }

    private fun loginWithBundledTokens(
        transport: BridgeRpcTransport,
        accessToken: String,
        chatgptAccountId: String,
        chatgptPlanType: String?,
    ) {
        transport.request(
            method = "account/login/start",
            params =
                JSONObject()
                    .put("type", "chatgptAuthTokens")
                    .put("accessToken", accessToken)
                    .put("chatgptAccountId", chatgptAccountId)
                    .put("chatgptPlanType", chatgptPlanType ?: JSONObject.NULL),
        )
    }

    private fun decodeJwtClaims(jwt: String): JSONObject {
        val payload = jwt.split('.').getOrNull(1) ?: return JSONObject()
        val decoded = Base64.decode(payload, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        val jsonText = String(decoded, StandardCharsets.UTF_8)
        val root = runCatching { JSONObject(jsonText) }.getOrDefault(JSONObject())
        val authClaims = root.optJSONObject("https://api.openai.com/auth")
        return authClaims ?: root
    }

    private fun generatePkceCodeVerifier(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private fun generatePkceCodeChallenge(codeVerifier: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(codeVerifier.toByteArray(StandardCharsets.UTF_8))
        return Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private fun urlEncode(value: String): String = java.net.URLEncoder.encode(value, StandardCharsets.UTF_8.toString())

    private fun loginWithApiKeyInternal(
        serverId: String,
        apiKey: String,
    ): AccountState {
        if (serversById[serverId]?.source == ServerSource.BUNDLED) {
            bundledAuthStore?.clear()
        }
        requireTransport(serverId).request(
            method = "account/login/start",
            params = JSONObject().put("type", "apiKey").put("apiKey", apiKey),
        )
        return refreshAccountStateInternal(serverId)
    }

    private fun logoutAccountInternal(serverId: String): AccountState {
        requireTransport(serverId).request(
            method = "account/logout",
            params = JSONObject(),
        )
        if (serversById[serverId]?.source == ServerSource.BUNDLED) {
            bundledAuthStore?.clear()
        }
        val next = AccountState(status = AuthStatus.NOT_LOGGED_IN)
        accountByServerId[serverId] = next
        updateState {
            it.copy(accountByServerId = LinkedHashMap(accountByServerId), activeServerId = serverId)
        }
        return next
    }

    private fun cancelLoginInternal(serverId: String): AccountState {
        val pendingLoginId = accountByServerId[serverId]?.pendingLoginId
        if (!pendingLoginId.isNullOrBlank()) {
            requireTransport(serverId).request(
                method = "account/login/cancel",
                params = JSONObject().put("loginId", pendingLoginId),
            )
        }

        val next = accountByServerId[serverId]?.copy(oauthUrl = null, pendingLoginId = null)
            ?: AccountState(status = AuthStatus.UNKNOWN)
        accountByServerId[serverId] = next
        updateState {
            it.copy(accountByServerId = LinkedHashMap(accountByServerId), activeServerId = serverId)
        }
        return next
    }

    private fun resolveHomeDirectoryInternal(serverId: String? = null): String {
        if (transportsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val targetServerId = resolveServerIdForRequestedOperation(serverId)
        if (serversById[targetServerId]?.source == ServerSource.BUNDLED) {
            return preferredDirectoryRootForServer(targetServerId)
        }
        val shellCandidates = shellCommandCandidatesForServer(targetServerId)
        val fallbackHome = preferredDirectoryRootForServer(targetServerId)

        return runCatching {
            for (shell in shellCandidates) {
                val result =
                    executeCommandInternal(
                        serverId = targetServerId,
                        command = listOf(shell, "-lc", "printf %s \"${'$'}HOME\""),
                        cwd = fallbackHome,
                    )
                val exitCode = result.optInt("exitCode", 0)
                val stdout = result.optString("stdout", "").trim()
                if (exitCode == 0 && stdout.isNotEmpty()) {
                    return@runCatching stdout
                }
                val stderr = result.optString("stderr", "").trim()
                if (!isMissingExecutable(exitCode, stderr)) {
                    break
                }
            }
            fallbackHome
        }.getOrDefault(fallbackHome)
    }

    private fun listDirectoriesInternal(
        path: String,
        serverId: String? = null,
    ): List<String> {
        if (transportsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val targetServerId = resolveServerIdForRequestedOperation(serverId)
        val fallbackRoot = preferredDirectoryRootForServer(targetServerId)
        if (serversById[targetServerId]?.source == ServerSource.BUNDLED) {
            return listLocalDirectoriesInternal(path = path, fallbackRoot = fallbackRoot)
        }
        val rawPath = path.trim()
        val normalized =
            when {
                rawPath.isEmpty() -> fallbackRoot
                rawPath == "/" && isLocalOrBundledServer(targetServerId) -> fallbackRoot
                else -> rawPath
            }
        val execCwd = if (normalized == "/") fallbackRoot else normalized
        val listCandidates = listCommandCandidatesForServer(targetServerId)
        var fallbackError: String? = null

        for (binary in listCandidates) {
            val result =
                executeCommandInternal(
                    serverId = targetServerId,
                    command = listOf(binary, "-1ap", normalized),
                    cwd = execCwd,
                )
            val exitCode = result.optInt("exitCode", 0)
            if (exitCode == 0) {
                val stdout = result.optString("stdout", "")
                return stdout
                    .lineSequence()
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                    .filter { it.endsWith("/") && it != "./" && it != "../" }
                    .map { it.removeSuffix("/") }
                    .sortedWith(compareBy<String> { it.lowercase(Locale.ROOT) }.thenBy { it })
                    .toList()
            }
            val stderr = result.optString("stderr", "").trim()
            if (isMissingExecutable(exitCode, stderr)) {
                continue
            }
            fallbackError = if (stderr.isNotEmpty()) stderr else "ls failed with code $exitCode"
            break
        }

        throw IllegalStateException(fallbackError ?: "ls executable is unavailable on the selected server")
    }

    private fun fuzzyFileSearchInternal(
        query: String,
        roots: List<String>,
        cancellationToken: String?,
    ): List<FuzzyFileSearchResult> {
        if (transportsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val serverId = resolveServerIdForActiveOperations()
        val normalizedRoots =
            roots
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .ifEmpty { listOf(state.currentCwd.ifBlank { "/" }) }

        val rootsJson = JSONArray()
        normalizedRoots.forEach { rootsJson.put(it) }

        val params =
            JSONObject()
                .put("query", query)
                .put("roots", rootsJson)
        val token = cancellationToken?.trim().orEmpty()
        if (token.isNotEmpty()) {
            params.put("cancellationToken", token)
        }

        val response = requireTransport(serverId).request(method = "fuzzyFileSearch", params = params)
        val files = response.optJSONArray("files") ?: JSONArray()
        val parsed = ArrayList<FuzzyFileSearchResult>(files.length())
        for (index in 0 until files.length()) {
            val item = files.optJSONObject(index) ?: continue
            val path = item.optString("path").trim()
            if (path.isEmpty()) {
                continue
            }
            val root = item.optString("root").trim()
            val fileName =
                item
                    .optString("file_name")
                    .trim()
                    .ifBlank { item.optString("fileName").trim() }
                    .ifBlank { path.substringAfterLast('/') }
            val score = item.optInt("score", 0)
            val indicesArray = item.optJSONArray("indices")
            val indices = ArrayList<Int>()
            if (indicesArray != null) {
                for (indicesIndex in 0 until indicesArray.length()) {
                    val parsedIndex = indicesArray.optInt(indicesIndex, Int.MIN_VALUE)
                    if (parsedIndex != Int.MIN_VALUE) {
                        indices += parsedIndex
                    }
                }
            }
            parsed +=
                FuzzyFileSearchResult(
                    root = root,
                    path = path,
                    fileName = fileName,
                    score = score,
                    indices = indices,
                )
        }
        return parsed
    }

    private fun chooseModelSelection(
        current: ModelSelection,
        available: List<ModelOption>,
    ): ModelSelection {
        if (available.isEmpty()) {
            return current
        }
        val existing = available.firstOrNull { it.id == current.modelId }
        if (existing != null) {
            val effort = current.reasoningEffort ?: existing.defaultReasoningEffort
            return current.copy(reasoningEffort = effort)
        }
        val fallback = available.firstOrNull { it.isDefault } ?: available.first()
        return ModelSelection(
            modelId = fallback.id,
            reasoningEffort = fallback.defaultReasoningEffort ?: current.reasoningEffort,
        )
    }

    private fun startThreadInternal(
        cwd: String,
        modelSelection: ModelSelection?,
        serverId: String? = null,
    ): ThreadKey {
        if (transportsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val targetServerId = resolveServerIdForRequestedOperation(serverId)
        val server = ensureConnectedServer(targetServerId)
        val model = modelSelection?.modelId ?: state.selectedModel.modelId
        val response = startThreadWithFallback(serverId = targetServerId, cwd = cwd, model = model)
        val threadId =
            response
                .optJSONObject("thread")
                ?.optString("id")
                ?.trim()
                .orEmpty()

        if (threadId.isEmpty()) {
            throw IllegalStateException("thread/start returned no thread id")
        }

        val key = ThreadKey(server.id, threadId)
        val existing = threadsByKey[key]
        val now = System.currentTimeMillis()
        val responseModelProvider = parseModelProvider(response)
        val threadObj = response.optJSONObject("thread")
        threadsByKey[key] =
            ThreadState(
                key = key,
                serverName = server.name,
                serverSource = server.source,
                status = ThreadStatus.READY,
                messages = existing?.messages ?: emptyList(),
                preview = existing?.preview ?: "",
                cwd = cwd,
                modelProvider = responseModelProvider.ifBlank { existing?.modelProvider.orEmpty() },
                parentThreadId = parseParentThreadId(threadObj) ?: existing?.parentThreadId,
                rootThreadId = parseRootThreadId(threadObj) ?: existing?.rootThreadId,
                updatedAtEpochMillis = now,
                activeTurnId = null,
                lastError = null,
            )
        threadTurnCounts[key] = 0
        liveItemMessageIndices.remove(key)
        liveTurnDiffMessageIndices.remove(key)

        updateState {
            it.copy(
                activeThreadKey = key,
                activeServerId = server.id,
                currentCwd = cwd,
                connectionStatus = ServerConnectionStatus.READY,
                connectionError = null,
            )
        }
        return key
    }

    private fun startThreadWithFallback(
        serverId: String,
        cwd: String,
        model: String?,
    ): JSONObject {
        val approvalPolicy = composerApprovalPolicy
        val sandbox = composerSandboxMode
        if (sandbox != "workspace-write") {
            return startThreadWithSandbox(serverId, cwd, model, approvalPolicy, sandbox)
        }
        return try {
            startThreadWithSandbox(serverId, cwd, model, approvalPolicy, sandbox = "workspace-write")
        } catch (error: Throwable) {
            if (!shouldRetryWithoutLinuxSandbox(error)) {
                throw error
            }
            startThreadWithSandbox(serverId, cwd, model, approvalPolicy, sandbox = "danger-full-access")
        }
    }

    private fun startThreadWithSandbox(
        serverId: String,
        cwd: String,
        model: String?,
        approvalPolicy: String,
        sandbox: String,
    ): JSONObject {
        val params =
            JSONObject()
                .put("model", model ?: JSONObject.NULL)
                .put("cwd", cwd)
                .put("approvalPolicy", approvalPolicy)
                .put("sandbox", sandbox)
        return requireTransport(serverId).request("thread/start", params)
    }

    private fun resumeThreadInternal(
        serverId: String,
        threadId: String,
        cwd: String,
    ): ThreadKey {
        if (transportsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val server = ensureConnectedServer(serverId)
        val key = ThreadKey(server.id, threadId)
        val existing = threadsByKey[key]
        threadsByKey[key] =
            ThreadState(
                key = key,
                serverName = server.name,
                serverSource = server.source,
                status = ThreadStatus.CONNECTING,
                messages = existing?.messages ?: emptyList(),
                preview = existing?.preview ?: "",
                cwd = cwd,
                updatedAtEpochMillis = System.currentTimeMillis(),
                activeTurnId = existing?.activeTurnId,
                lastError = null,
            )
        updateState { it.copy(activeThreadKey = key, activeServerId = serverId, currentCwd = cwd) }

        try {
            val response = resumeThreadWithFallback(serverId = serverId, threadId = threadId, cwd = cwd)
            val threadObj = response.optJSONObject("thread") ?: JSONObject()
            val restored = restoreMessages(threadObj)
            val now = System.currentTimeMillis()
            val responseModelProvider = parseModelProvider(response)
            val threadModelProvider = parseModelProvider(threadObj)
            threadsByKey[key] =
                ThreadState(
                    key = key,
                    serverName = server.name,
                    serverSource = server.source,
                    status = ThreadStatus.READY,
                    messages = restored.messages,
                    preview = derivePreview(restored.messages, existing?.preview),
                    cwd = cwd,
                    modelProvider = responseModelProvider.ifBlank { threadModelProvider.ifBlank { existing?.modelProvider.orEmpty() } },
                    parentThreadId = parseParentThreadId(threadObj) ?: existing?.parentThreadId,
                    rootThreadId = parseRootThreadId(threadObj) ?: existing?.rootThreadId,
                    updatedAtEpochMillis = now,
                    activeTurnId = null,
                    lastError = null,
                )
            threadTurnCounts[key] = restored.turnCount
            liveItemMessageIndices.remove(key)
            liveTurnDiffMessageIndices.remove(key)
            updateState {
                it.copy(
                    activeThreadKey = key,
                    activeServerId = server.id,
                    currentCwd = cwd,
                )
            }
            return key
        } catch (error: Throwable) {
            val errored = threadsByKey[key] ?: return key
            threadsByKey[key] =
                errored.copy(
                    status = ThreadStatus.ERROR,
                    lastError = error.message ?: "Failed to resume thread",
                    updatedAtEpochMillis = System.currentTimeMillis(),
                )
            updateState {
                it.copy(connectionError = error.message ?: "Failed to resume thread")
            }
            throw error
        }
    }

    private fun resumeThreadWithFallback(
        serverId: String,
        threadId: String,
        cwd: String,
    ): JSONObject {
        val approvalPolicy = composerApprovalPolicy
        val sandbox = composerSandboxMode
        if (sandbox != "workspace-write") {
            return resumeThreadWithSandbox(serverId, threadId, cwd, approvalPolicy, sandbox)
        }
        return try {
            resumeThreadWithSandbox(serverId, threadId, cwd, approvalPolicy, sandbox = "workspace-write")
        } catch (error: Throwable) {
            if (!shouldRetryWithoutLinuxSandbox(error)) {
                throw error
            }
            resumeThreadWithSandbox(serverId, threadId, cwd, approvalPolicy, sandbox = "danger-full-access")
        }
    }

    private fun resumeThreadWithSandbox(
        serverId: String,
        threadId: String,
        cwd: String,
        approvalPolicy: String,
        sandbox: String,
    ): JSONObject {
        val params =
            JSONObject()
                .put("threadId", threadId)
                .put("cwd", cwd)
                .put("approvalPolicy", approvalPolicy)
                .put("sandbox", sandbox)
        return requireTransport(serverId).request("thread/resume", params)
    }

    private fun startReviewOnActiveThreadInternal() {
        val key = state.activeThreadKey ?: throw IllegalStateException("No active thread")
        requireTransport(key.serverId).request(
            method = "review/start",
            params = JSONObject()
                .put("threadId", key.threadId)
                .put("target", JSONObject().put("type", "uncommittedChanges"))
                .put("delivery", "inline"),
        )
    }

    private fun renameActiveThreadInternal(name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) {
            throw IllegalArgumentException("Thread name is required")
        }
        val key = state.activeThreadKey ?: throw IllegalStateException("No active thread")
        renameThreadInternal(key, trimmed)
    }

    private fun renameThreadInternal(
        key: ThreadKey,
        name: String,
    ) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) {
            throw IllegalArgumentException("Thread name is required")
        }
        requireTransport(key.serverId).request(
            method = "thread/name/set",
            params = JSONObject().put("threadId", key.threadId).put("name", trimmed),
        )

        val existing = threadsByKey[key] ?: return
        threadsByKey[key] =
            existing.copy(
                preview = trimmed.take(120),
                updatedAtEpochMillis = System.currentTimeMillis(),
            )
        updateState { it }
    }

    private fun editMessageInternal(messageId: String) {
        val key = state.activeThreadKey ?: throw IllegalStateException("No active thread")
        val thread = threadsByKey[key] ?: throw IllegalStateException("Unable to resolve active thread")
        if (thread.hasTurnActive) {
            throw IllegalStateException("Wait for the active turn to finish before editing")
        }
        val message = thread.messages.firstOrNull { it.id == messageId }
            ?: throw IllegalArgumentException("Selected message was not found")
        if (message.role != MessageRole.USER || !message.isFromUserTurnBoundary) {
            throw IllegalArgumentException("Only user messages can be edited")
        }

        val rollbackDepth = rollbackDepthForMessage(key, message)
        if (rollbackDepth > 0) {
            rollbackThreadAndApply(key, rollbackDepth)
        }
    }

    private fun forkConversationInternal(): ThreadKey {
        val key = state.activeThreadKey ?: throw IllegalStateException("No active thread")
        val thread = threadsByKey[key] ?: throw IllegalStateException("Unable to resolve active thread")
        if (thread.hasTurnActive) {
            throw IllegalStateException("Wait for the active turn to finish before forking")
        }
        return forkThreadInternal(key, thread)
    }

    private fun forkThreadByKeyInternal(threadKey: ThreadKey): ThreadKey {
        val thread = threadsByKey[threadKey] ?: throw IllegalStateException("Unable to resolve thread")
        if (thread.hasTurnActive) {
            throw IllegalStateException("Wait for the active turn to finish before forking")
        }
        return forkThreadInternal(threadKey, thread)
    }

    private fun forkConversationFromMessageInternal(messageId: String): ThreadKey {
        val sourceKey = state.activeThreadKey ?: throw IllegalStateException("No active thread")
        val sourceThread = threadsByKey[sourceKey] ?: throw IllegalStateException("Unable to resolve active thread")
        if (sourceThread.hasTurnActive) {
            throw IllegalStateException("Wait for the active turn to finish before forking")
        }
        val message = sourceThread.messages.firstOrNull { it.id == messageId }
            ?: throw IllegalArgumentException("Selected message was not found")
        if (message.role != MessageRole.USER || !message.isFromUserTurnBoundary) {
            throw IllegalArgumentException("Fork from here is only supported for user messages")
        }

        val rollbackDepth = rollbackDepthForMessage(sourceKey, message)
        val forkKey = forkThreadInternal(sourceKey, sourceThread)
        if (rollbackDepth > 0) {
            rollbackThreadAndApply(forkKey, rollbackDepth)
        }
        return forkKey
    }

    private fun forkThreadInternal(
        sourceKey: ThreadKey,
        sourceThread: ThreadState,
    ): ThreadKey {
        val server = ensureConnectedServer(sourceKey.serverId)
        val sourceCwd = sourceThread.cwd.ifBlank { defaultWorkingDirectory() }
        val response = forkThreadWithFallback(server.id, sourceKey.threadId, sourceCwd)
        val threadObj = response.optJSONObject("thread") ?: JSONObject()
        val forkedThreadId = threadObj.optString("id").trim()
        if (forkedThreadId.isEmpty()) {
            throw IllegalStateException("thread/fork returned no thread id")
        }

        val restored = restoreMessages(threadObj)
        val forkedKey = ThreadKey(server.id, forkedThreadId)
        val now = System.currentTimeMillis()
        val resolvedCwd = response.optString("cwd").trim().ifEmpty { sourceCwd }
        val responseModelProvider = parseModelProvider(response)
        val threadModelProvider = parseModelProvider(threadObj)
        val lineageParentId = parseParentThreadId(threadObj)
        val lineageRootId = parseRootThreadId(threadObj)
        threadsByKey[forkedKey] =
            ThreadState(
                key = forkedKey,
                serverName = server.name,
                serverSource = server.source,
                status = ThreadStatus.READY,
                messages = restored.messages,
                preview = derivePreview(restored.messages, sourceThread.preview),
                cwd = resolvedCwd,
                modelProvider = responseModelProvider.ifBlank { threadModelProvider.ifBlank { sourceThread.modelProvider } },
                parentThreadId = lineageParentId ?: sourceKey.threadId,
                rootThreadId = lineageRootId ?: sourceThread.rootThreadId ?: sourceThread.parentThreadId ?: sourceKey.threadId,
                updatedAtEpochMillis = now,
                activeTurnId = null,
                lastError = null,
            )
        threadTurnCounts[forkedKey] = restored.turnCount
        liveItemMessageIndices.remove(forkedKey)
        liveTurnDiffMessageIndices.remove(forkedKey)
        updateState {
            it.copy(
                activeThreadKey = forkedKey,
                activeServerId = server.id,
                currentCwd = resolvedCwd,
                connectionError = null,
            )
        }
        return forkedKey
    }

    private fun archiveThreadInternal(threadKey: ThreadKey) {
        requireTransport(threadKey.serverId).request(
            method = "thread/archive",
            params = JSONObject().put("threadId", threadKey.threadId),
        )
        threadsByKey.remove(threadKey)
        threadTurnCounts.remove(threadKey)
        liveItemMessageIndices.remove(threadKey)
        liveTurnDiffMessageIndices.remove(threadKey)
        updateState {
            val sortedRemainingThreads = threadsByKey.values.sortedByDescending { thread -> thread.updatedAtEpochMillis }
            val resolvedActiveKey =
                it.activeThreadKey?.takeIf { key -> threadsByKey.containsKey(key) }
                    ?: sortedRemainingThreads.firstOrNull()?.key
            val resolvedCwd =
                resolvedActiveKey
                    ?.let { key -> threadsByKey[key]?.cwd?.trim().orEmpty() }
                    .orEmpty()
            it.copy(
                activeThreadKey = resolvedActiveKey,
                activeServerId = resolvedActiveKey?.serverId ?: it.activeServerId,
                connectionError = null,
                currentCwd = resolvedCwd,
            )
        }
    }

    private fun forkThreadWithFallback(
        serverId: String,
        threadId: String,
        cwd: String,
    ): JSONObject {
        val approvalPolicy = composerApprovalPolicy
        val sandbox = composerSandboxMode
        if (sandbox != "workspace-write") {
            return forkThreadWithSandbox(serverId, threadId, cwd, approvalPolicy, sandbox)
        }
        return try {
            forkThreadWithSandbox(serverId, threadId, cwd, approvalPolicy, sandbox = "workspace-write")
        } catch (error: Throwable) {
            if (!shouldRetryWithoutLinuxSandbox(error)) {
                throw error
            }
            forkThreadWithSandbox(serverId, threadId, cwd, approvalPolicy, sandbox = "danger-full-access")
        }
    }

    private fun forkThreadWithSandbox(
        serverId: String,
        threadId: String,
        cwd: String,
        approvalPolicy: String,
        sandbox: String,
    ): JSONObject {
        val params =
            JSONObject()
                .put("threadId", threadId)
                .put("cwd", cwd)
                .put("approvalPolicy", approvalPolicy)
                .put("sandbox", sandbox)
        return requireTransport(serverId).request("thread/fork", params)
    }

    private fun rollbackThreadAndApply(
        key: ThreadKey,
        numTurns: Int,
    ) {
        if (numTurns <= 0) {
            return
        }
        val response =
            requireTransport(key.serverId).request(
                method = "thread/rollback",
                params = JSONObject().put("threadId", key.threadId).put("numTurns", numTurns),
            )
        val threadObj = response.optJSONObject("thread") ?: JSONObject()
        val restored = restoreMessages(threadObj)
        val existing = threadsByKey[key] ?: throw IllegalStateException("Unable to resolve thread")
        threadsByKey[key] =
            existing.copy(
                status = ThreadStatus.READY,
                activeTurnId = null,
                messages = restored.messages,
                preview = derivePreview(restored.messages, existing.preview),
                updatedAtEpochMillis = System.currentTimeMillis(),
                lastError = null,
            )
        threadTurnCounts[key] = restored.turnCount
        liveItemMessageIndices.remove(key)
        liveTurnDiffMessageIndices.remove(key)
        updateState {
            it.copy(
                activeThreadKey = key,
                activeServerId = key.serverId,
                currentCwd = threadsByKey[key]?.cwd ?: it.currentCwd,
                connectionError = null,
            )
        }
    }

    private fun rollbackDepthForMessage(
        key: ThreadKey,
        message: ChatMessage,
    ): Int {
        val selectedTurnIndex = message.sourceTurnIndex
            ?: throw IllegalArgumentException("Message is missing turn metadata")
        val totalTurns = threadTurnCounts[key] ?: inferredTurnCountFromMessages(threadsByKey[key]?.messages.orEmpty())
        if (totalTurns <= 0) {
            throw IllegalStateException("No turn history available")
        }
        if (selectedTurnIndex !in 0 until totalTurns) {
            throw IllegalStateException("Message is outside available turn history")
        }
        return maxOf(totalTurns - selectedTurnIndex - 1, 0)
    }

    private fun inferredTurnCountFromMessages(messages: List<ChatMessage>): Int {
        val maxTurn = messages.mapNotNull { it.sourceTurnIndex }.maxOrNull()
        if (maxTurn != null) {
            return maxTurn + 1
        }
        return messages.count { it.role == MessageRole.USER && it.isFromUserTurnBoundary }
    }

    private fun listExperimentalFeaturesInternal(limit: Int): List<ExperimentalFeature> {
        val serverId = resolveServerIdForActiveOperations()
        val response =
            requireTransport(serverId).request(
                method = "experimentalFeature/list",
                params = JSONObject().put("cursor", JSONObject.NULL).put("limit", limit),
            )
        val data = response.optJSONArray("data") ?: JSONArray()
        val parsed = ArrayList<ExperimentalFeature>(data.length())
        for (index in 0 until data.length()) {
            val item = data.optJSONObject(index) ?: continue
            val name = item.sanitizedOptString("name") ?: continue
            val stage = item.sanitizedOptString("stage").orEmpty()
            val displayName =
                item.sanitizedOptString("displayName")
                    ?: item.sanitizedOptString("display_name")
            val description = item.sanitizedOptString("description")
            val announcement = item.sanitizedOptString("announcement")
            val defaultEnabled =
                item.opt("defaultEnabled").asBooleanOrNull()
                    ?: item.opt("default_enabled").asBooleanOrNull()
                    ?: false
            val enabled = item.opt("enabled").asBooleanOrNull() ?: defaultEnabled
            parsed +=
                ExperimentalFeature(
                    name = name,
                    stage = stage,
                    displayName = displayName,
                    description = description,
                    announcement = announcement,
                    enabled = enabled,
                    defaultEnabled = defaultEnabled,
                )
        }
        return parsed
    }

    private fun setExperimentalFeatureEnabledInternal(
        featureName: String,
        enabled: Boolean,
    ) {
        val name = featureName.trim()
        if (name.isEmpty()) {
            throw IllegalArgumentException("Feature name is required")
        }
        val serverId = resolveServerIdForActiveOperations()
        requireTransport(serverId).request(
            method = "config/value/write",
            params =
                JSONObject()
                    .put("keyPath", "features.$name")
                    .put("value", enabled)
                    .put("mergeStrategy", "upsert")
                    .put("filePath", JSONObject.NULL)
                    .put("expectedVersion", JSONObject.NULL),
        )
    }

    private fun listSkillsInternal(
        cwds: List<String>?,
        forceReload: Boolean,
    ): List<SkillMetadata> {
        val serverId = resolveServerIdForActiveOperations()
        val params = JSONObject().put("forceReload", forceReload)
        val normalizedCwds =
            cwds
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                .orEmpty()
        if (normalizedCwds.isNotEmpty()) {
            val cwdsJson = JSONArray()
            normalizedCwds.forEach { cwd -> cwdsJson.put(cwd) }
            params.put("cwds", cwdsJson)
        } else {
            params.put("cwds", JSONObject.NULL)
        }

        val response = requireTransport(serverId).request(method = "skills/list", params = params)
        val data = response.optJSONArray("data") ?: JSONArray()
        val parsed = ArrayList<SkillMetadata>()
        for (entryIndex in 0 until data.length()) {
            val entry = data.optJSONObject(entryIndex) ?: continue
            val skills = entry.optJSONArray("skills") ?: continue
            for (skillIndex in 0 until skills.length()) {
                val item = skills.optJSONObject(skillIndex) ?: continue
                val name = item.sanitizedOptString("name") ?: continue
                val path = item.sanitizedOptString("path") ?: continue
                parsed +=
                    SkillMetadata(
                        name = name,
                        description = item.sanitizedOptString("description").orEmpty(),
                        path = path,
                        scope = item.sanitizedOptString("scope").orEmpty(),
                        enabled = item.optBoolean("enabled", true),
                    )
            }
        }
        return parsed
    }

    private fun sendMessageInternal(
        text: String,
        cwd: String,
        modelSelection: ModelSelection,
        localImagePath: String? = null,
        skillMentions: List<SkillMentionInput> = emptyList(),
    ) {
        val (cleanedText, embeddedLocalImagePath) = extractLocalImageMarker(text)
        val normalizedLocalImagePath =
            localImagePath?.trim()?.takeIf { it.isNotEmpty() }
                ?: embeddedLocalImagePath?.trim()?.takeIf { it.isNotEmpty() }
        val localImageDataUrl = normalizedLocalImagePath?.let(::encodeLocalImageAsDataUrl)
        val trimmed = cleanedText.trim()
        if (trimmed.isEmpty() && normalizedLocalImagePath == null && localImageDataUrl == null) {
            return
        }

        if (transportsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }

        val key = state.activeThreadKey ?: startThreadInternal(cwd, modelSelection)
        val serverId = key.serverId
        ensureAuthenticatedForTurns(serverId)
        val existing = threadsByKey[key] ?: throw IllegalStateException("Unable to resolve active thread")
        val now = System.currentTimeMillis()
        val localImageName = normalizedLocalImagePath?.let { File(it).name }.orEmpty()
        val userVisibleText =
            when {
                trimmed.isNotEmpty() && normalizedLocalImagePath != null ->
                    "$trimmed\n[Image] ${if (localImageName.isNotEmpty()) localImageName else normalizedLocalImagePath}"

                trimmed.isNotEmpty() -> trimmed
                normalizedLocalImagePath != null ->
                    "[Image] ${if (localImageName.isNotEmpty()) localImageName else normalizedLocalImagePath}"

                else -> ""
            }

        val withUserMessage =
            existing.copy(
                status = ThreadStatus.THINKING,
                messages = existing.messages + ChatMessage(role = MessageRole.USER, text = userVisibleText, isFromUserTurnBoundary = true),
                preview = userVisibleText.take(120),
                cwd = cwd,
                updatedAtEpochMillis = now,
                lastError = null,
            )
        threadsByKey[key] = withUserMessage
        updateState {
            it.copy(
                activeThreadKey = key,
                activeServerId = serverId,
                currentCwd = cwd,
                connectionError = null,
            )
        }

        val input = JSONArray()
        if (trimmed.isNotEmpty()) {
            input.put(
                JSONObject()
                    .put("type", "text")
                    .put("text", trimmed),
            )
        }
        if (localImageDataUrl != null) {
            input.put(
                JSONObject()
                    .put("type", "image")
                    .put("url", localImageDataUrl),
            )
        } else if (normalizedLocalImagePath != null) {
            // Fallback for cases where we cannot read/encode the local file.
            input.put(
                JSONObject()
                    .put("type", "localImage")
                    .put("path", normalizedLocalImagePath),
            )
        }
        for (mention in skillMentions) {
            val name = mention.name.trim()
            val path = mention.path.trim()
            if (name.isEmpty() || path.isEmpty()) {
                continue
            }
            input.put(
                JSONObject()
                    .put("type", "skill")
                    .put("name", name)
                    .put("path", path),
            )
        }

        fun buildTurnStartParams(threadId: String): JSONObject =
            JSONObject()
                .put("threadId", threadId)
                .put("threadID", threadId)
                .put("input", input)
                .put("model", modelSelection.modelId ?: JSONObject.NULL)
                .put("effort", modelSelection.reasoningEffort ?: JSONObject.NULL)

        try {
            val response = requireTransport(serverId).request("turn/start", buildTurnStartParams(key.threadId))
            val turnId =
                response.optJSONObject("turn")?.optString("id")?.trim().takeIf { !it.isNullOrEmpty() }
                    ?: response.optString("turnId").trim().takeIf { it.isNotEmpty() }
                    ?: response.optString("turnID").trim().takeIf { it.isNotEmpty() }
            val latest = threadsByKey[key] ?: return
            threadsByKey[key] =
                latest.copy(
                    status = ThreadStatus.THINKING,
                    activeTurnId = turnId,
                    updatedAtEpochMillis = System.currentTimeMillis(),
                )
            updateState { it }
        } catch (error: Throwable) {
            if (isMissingRolloutForThread(error)) {
                val replacementKey = startThreadInternal(cwd, modelSelection, serverId = serverId)
                val replacementBase = threadsByKey[replacementKey]
                if (replacementBase != null) {
                    threadsByKey[replacementKey] =
                        replacementBase.copy(
                            status = ThreadStatus.THINKING,
                            messages = withUserMessage.messages,
                            preview = withUserMessage.preview,
                            cwd = cwd,
                            updatedAtEpochMillis = System.currentTimeMillis(),
                            lastError = null,
                        )
                    if (replacementKey != key) {
                        threadsByKey.remove(key)
                        liveItemMessageIndices.remove(key)
                        liveTurnDiffMessageIndices.remove(key)
                    }
                    updateState {
                        it.copy(
                            activeThreadKey = replacementKey,
                            activeServerId = serverId,
                            currentCwd = cwd,
                            connectionError = null,
                        )
                    }
                    val retryResponse =
                        requireTransport(serverId).request(
                            "turn/start",
                            buildTurnStartParams(replacementKey.threadId),
                        )
                    val retryTurnId =
                        retryResponse.optJSONObject("turn")?.optString("id")?.trim().takeIf { !it.isNullOrEmpty() }
                            ?: retryResponse.optString("turnId").trim().takeIf { it.isNotEmpty() }
                            ?: retryResponse.optString("turnID").trim().takeIf { it.isNotEmpty() }
                    val latestReplacement = threadsByKey[replacementKey] ?: return
                    threadsByKey[replacementKey] =
                        latestReplacement.copy(
                            status = ThreadStatus.THINKING,
                            activeTurnId = retryTurnId,
                            updatedAtEpochMillis = System.currentTimeMillis(),
                        )
                    updateState { it }
                    return
                }
            }

            val latest = threadsByKey[key] ?: return
            threadsByKey[key] =
                latest.copy(
                    status = ThreadStatus.ERROR,
                    lastError = error.message ?: "Failed to send turn",
                    activeTurnId = null,
                    updatedAtEpochMillis = System.currentTimeMillis(),
                    messages = finalizeStreaming(latest.messages),
                )
            updateState {
                it.copy(connectionError = error.message ?: "Failed to send turn")
            }
            throw error
        }
    }

    private fun isMissingRolloutForThread(error: Throwable): Boolean {
        var current: Throwable? = error
        while (current != null) {
            val message = current.message?.lowercase(Locale.ROOT).orEmpty()
            if (message.contains("no rollout found for thread id") || message.contains("no rollout found")) {
                return true
            }
            current = current.cause
        }
        return false
    }

    private fun ensureAuthenticatedForTurns(serverId: String) {
        val source = serversById[serverId]?.source
        val status =
            if (source == ServerSource.BUNDLED) {
                accountByServerId[serverId]?.status ?: AuthStatus.UNKNOWN
            } else {
                runCatching { refreshAccountStateInternal(serverId).status }
                    .getOrElse { accountByServerId[serverId]?.status ?: AuthStatus.UNKNOWN }
            }

        if (status == AuthStatus.NOT_LOGGED_IN) {
            throw IllegalStateException("Bundled server requires login. Open Settings > Account and sign in (ChatGPT or API key).")
        }
    }

    private fun interruptInternal() {
        val key = state.activeThreadKey ?: return
        val activeTurnId = threadsByKey[key]?.activeTurnId?.trim().takeIf { !it.isNullOrEmpty() }
        val params =
            JSONObject()
                .put("threadId", key.threadId)
                .put("threadID", key.threadId)
                .put("turnId", activeTurnId ?: JSONObject.NULL)
                .put("turnID", activeTurnId ?: JSONObject.NULL)
        requireTransport(key.serverId).request("turn/interrupt", params)
        val existing = threadsByKey[key] ?: return
        threadsByKey[key] =
            existing.copy(
                status = ThreadStatus.READY,
                activeTurnId = null,
                updatedAtEpochMillis = System.currentTimeMillis(),
                messages = finalizeStreaming(existing.messages),
            )
        updateState { it }
    }

    private fun extractLocalImageMarker(text: String): Pair<String, String?> {
        var markerPath: String? = null
        val withoutMarkers =
            LOCAL_IMAGE_MARKER_REGEX.replace(text) { matchResult ->
                if (markerPath == null) {
                    markerPath = matchResult.groupValues.getOrNull(1)?.trim()?.takeIf { it.isNotEmpty() }
                }
                ""
            }
        return withoutMarkers.trim() to markerPath
    }

    private fun encodeLocalImageAsDataUrl(path: String): String? {
        val file = File(path)
        if (!file.exists() || !file.isFile) {
            return null
        }
        val mimeType =
            when (file.extension.lowercase(Locale.US)) {
                "png" -> "image/png"
                "webp" -> "image/webp"
                "gif" -> "image/gif"
                "jpg", "jpeg" -> "image/jpeg"
                else -> "image/jpeg"
            }
        return runCatching {
            val bytes = file.readBytes()
            if (bytes.isEmpty()) {
                return null
            }
            val encoded = Base64.encodeToString(bytes, Base64.NO_WRAP)
            "data:$mimeType;base64,$encoded"
        }.getOrNull()
    }

    private fun handleNotification(
        serverId: String,
        method: String,
        params: JSONObject?,
    ) {
        when (method) {
            "account/login/completed" -> {
                val current = accountByServerId[serverId] ?: AccountState()
                val currentPendingId = current.pendingLoginId?.trim().takeIf { !it.isNullOrEmpty() }
                val notificationLoginId =
                    params?.optString("loginId")?.trim().takeIf { !it.isNullOrEmpty() }
                        ?: params?.optString("login_id")?.trim().takeIf { !it.isNullOrEmpty() }

                if (
                    notificationLoginId != null &&
                    currentPendingId != null &&
                    notificationLoginId != currentPendingId
                ) {
                    return
                }

                val success = params?.optBoolean("success", false) ?: false
                if (success) {
                    accountByServerId[serverId] = current.copy(oauthUrl = null, pendingLoginId = null, lastError = null)
                    runCatching { refreshAccountStateInternal(serverId) }
                } else {
                    val message = params?.optString("error")?.trim().orEmpty().ifBlank { "Login failed" }
                    accountByServerId[serverId] = current.copy(lastError = message)
                    updateState {
                        it.copy(
                            accountByServerId = LinkedHashMap(accountByServerId),
                            connectionError = message,
                        )
                    }
                }
            }

            "account/updated" -> {
                runCatching { refreshAccountStateInternal(serverId) }
            }

            "sessionConfigured" -> {
                val threadId =
                    extractString(
                        params,
                        "sessionId",
                        "session_id",
                        "threadId",
                        "thread_id",
                    ) ?: return
                val key = ThreadKey(serverId = serverId, threadId = threadId)
                val existing = ensureThreadState(key)
                threadsByKey[key] =
                    existing.copy(
                        preview =
                            extractString(params, "threadName", "thread_name")
                                ?.take(120)
                                ?.ifBlank { existing.preview }
                                ?: existing.preview,
                        modelProvider = parseModelProvider(params).ifBlank { existing.modelProvider },
                        parentThreadId = parseParentThreadId(params) ?: existing.parentThreadId,
                        rootThreadId = parseRootThreadId(params) ?: existing.rootThreadId,
                    )
                updateState { it }
            }

            "turn/started" -> {
                val threadId = params.optThreadId()
                val key = resolveThreadKey(serverId, threadId) ?: return
                val existing = ensureThreadState(key)
                val turnId =
                    params?.optJSONObject("turn")?.optString("id")?.trim().takeIf { !it.isNullOrEmpty() }
                        ?: params?.optString("turnId")?.trim().takeIf { !it.isNullOrEmpty() }
                        ?: params?.optString("turnID")?.trim().takeIf { !it.isNullOrEmpty() }
                        ?: existing.activeTurnId
                threadsByKey[key] =
                    existing.copy(
                        status = ThreadStatus.THINKING,
                        activeTurnId = turnId,
                        updatedAtEpochMillis = System.currentTimeMillis(),
                        lastError = null,
                    )
                updateState { it.copy(activeThreadKey = key, activeServerId = key.serverId) }
            }

            "item/agentMessage/delta" -> {
                val delta = params?.optString("delta")?.takeIf { it.isNotBlank() } ?: return
                if (delta.isBlank()) {
                    return
                }
                val key = resolveThreadKey(serverId, params.optThreadId()) ?: return
                val existing = ensureThreadState(key)
                val mergedMessages = appendAssistantDelta(existing.messages, delta)
                threadsByKey[key] =
                    existing.copy(
                        status = ThreadStatus.THINKING,
                        messages = mergedMessages,
                        preview = derivePreview(mergedMessages, existing.preview),
                        updatedAtEpochMillis = System.currentTimeMillis(),
                    )
                updateState { it.copy(activeThreadKey = key, activeServerId = key.serverId) }
            }

            "item/started",
            "item/completed" -> {
                serversUsingItemNotifications += serverId
                handleItemLifecycleNotification(serverId = serverId, method = method, params = params)
            }

            "item/commandExecution/outputDelta" -> {
                serversUsingItemNotifications += serverId
                handleCommandOutputDeltaNotification(serverId = serverId, params = params)
            }

            "item/mcpToolCall/progress" -> {
                serversUsingItemNotifications += serverId
                handleMcpProgressNotification(serverId = serverId, params = params)
            }

            "turn/completed",
            "codex/event/task_complete" -> {
                val completedTurnId =
                    params?.optJSONObject("turn")?.optString("id")?.trim().takeIf { !it.isNullOrEmpty() }
                        ?: params?.optString("turnId")?.trim().takeIf { !it.isNullOrEmpty() }
                        ?: params?.optString("turn_id")?.trim().takeIf { !it.isNullOrEmpty() }
                        ?: params?.optString("id")?.trim().takeIf { !it.isNullOrEmpty() }
                var activeCompletedKey: ThreadKey? = null
                val explicitThreadId = extractThreadId(params)
                if (!explicitThreadId.isNullOrBlank()) {
                    val key = resolveThreadKey(serverId, explicitThreadId) ?: return
                    val existing = ensureThreadState(key)
                    val finalized = finalizeStreaming(existing.messages)
                    threadsByKey[key] =
                        existing.copy(
                            status = ThreadStatus.READY,
                            activeTurnId = null,
                            messages = finalized,
                            preview = derivePreview(finalized, existing.preview),
                            updatedAtEpochMillis = System.currentTimeMillis(),
                        )
                    liveItemMessageIndices.remove(key)
                    liveTurnDiffMessageIndices.remove(key)
                    notifyAwayIfNeeded(
                        dedupeKey = "final:$serverId:${key.threadId}:${completedTurnId ?: "unknown"}",
                        title = approvalNotificationTitle(key),
                        body = assistantPreview(key),
                    )
                    if (state.activeThreadKey == key) {
                        activeCompletedKey = key
                    }
                } else {
                    val keys =
                        threadsByKey.values
                            .filter { it.key.serverId == serverId && it.hasTurnActive }
                            .map { it.key }
                    for (key in keys) {
                        val existing = threadsByKey[key] ?: continue
                        val finalized = finalizeStreaming(existing.messages)
                        threadsByKey[key] =
                            existing.copy(
                                status = ThreadStatus.READY,
                                activeTurnId = null,
                                messages = finalized,
                                preview = derivePreview(finalized, existing.preview),
                                updatedAtEpochMillis = System.currentTimeMillis(),
                            )
                        liveItemMessageIndices.remove(key)
                        liveTurnDiffMessageIndices.remove(key)
                        notifyAwayIfNeeded(
                            dedupeKey = "final:$serverId:${key.threadId}:${completedTurnId ?: "unknown"}",
                            title = approvalNotificationTitle(key),
                            body = assistantPreview(key),
                        )
                        if (state.activeThreadKey == key) {
                            activeCompletedKey = key
                        }
                    }
                }
                val fallbackKey =
                    activeCompletedKey
                        ?: state.activeThreadKey?.takeIf { it.serverId == serverId }
                        ?: threadsByKey.values.firstOrNull { it.key.serverId == serverId }?.key
                fallbackKey?.let { syncThreadFromServerInternal(it) }
                updateState { it }
            }

            "turn/diff/updated" -> {
                handleTurnDiffNotification(serverId = serverId, params = params)
            }

            "error" -> {
                val errorObj = params?.optJSONObject("error")
                val message = errorObj?.optString("message")?.takeIf { it.isNotBlank() } ?: "An error occurred"
                val threadId = extractThreadId(params)
                if (!threadId.isNullOrBlank()) {
                    val key = resolveThreadKey(serverId, threadId) ?: return
                    val existing = ensureThreadState(key)
                    val finalized = finalizeStreaming(existing.messages)
                    threadsByKey[key] =
                        existing.copy(
                            status = ThreadStatus.ERROR,
                            lastError = message,
                            activeTurnId = null,
                            messages = finalized,
                            updatedAtEpochMillis = System.currentTimeMillis()
                        )
                    notifyAwayIfNeeded(
                        dedupeKey = "error:$serverId:$threadId",
                        title = approvalNotificationTitle(key),
                        body = message,
                    )
                    updateState { it.copy(activeThreadKey = key, activeServerId = key.serverId, connectionError = message) }
                } else {
                    notifyAwayIfNeeded(
                        dedupeKey = "error:$serverId:global:${System.currentTimeMillis() / 60000}",
                        title = "Codex Error",
                        body = message,
                    )
                    updateState { it.copy(connectionError = message) }
                }
            }

            "codex/event/turn_diff" -> {
                handleLegacyCodexEventNotification(serverId = serverId, method = method, params = params)
            }

            else -> {
                if (method.startsWith("item/")) {
                    serversUsingItemNotifications += serverId
                } else if ((method == "codex/event" || method.startsWith("codex/event/")) &&
                    !serversUsingItemNotifications.contains(serverId)
                ) {
                    handleLegacyCodexEventNotification(serverId = serverId, method = method, params = params)
                }
            }
        }
    }

    private fun handleItemLifecycleNotification(
        serverId: String,
        method: String,
        params: JSONObject?,
    ) {
        val item = params?.optJSONObject("item") ?: return
        val key = resolveThreadKey(serverId, extractThreadId(params)) ?: return
        val existing = ensureThreadState(key)
        val itemType = item.optString("type").trim()
        if (itemType == "userMessage") {
            return
        }
        if (itemType == "agentMessage" && method == "item/started") {
            return
        }

        val message = chatMessageFromItem(item, sourceTurnId = null, sourceTurnIndex = null) ?: return
        val itemId = extractString(item, "id")
        val updatedMessages =
            when {
                method == "item/started" && itemId != null ->
                    upsertLiveItemMessage(existing.messages, message, itemId, key)

                method == "item/completed" && itemId != null ->
                    completeLiveItemMessage(existing.messages, message, itemId, key)

                else -> existing.messages + message
            }

        threadsByKey[key] =
            existing.copy(
                messages = updatedMessages,
                preview = derivePreview(updatedMessages, existing.preview),
                updatedAtEpochMillis = System.currentTimeMillis(),
            )
        updateState { it.copy(activeThreadKey = key, activeServerId = key.serverId) }
    }

    private fun handleCommandOutputDeltaNotification(
        serverId: String,
        params: JSONObject?,
    ) {
        val delta = extractString(params, "delta") ?: return
        if (delta.isBlank()) {
            return
        }
        val key = resolveThreadKey(serverId, extractThreadId(params)) ?: return
        val existing = ensureThreadState(key)
        val itemId = extractString(params, "itemId", "item_id")

        val updatedMessages =
            if (itemId != null) {
                appendCommandOutputDelta(existing.messages, delta, itemId, key)
                    ?: (existing.messages + (systemMessage("Command Output", "```text\n$delta\n```") ?: return))
            } else {
                existing.messages + (systemMessage("Command Output", "```text\n$delta\n```") ?: return)
            }

        threadsByKey[key] =
            existing.copy(
                messages = updatedMessages,
                preview = derivePreview(updatedMessages, existing.preview),
                updatedAtEpochMillis = System.currentTimeMillis(),
            )
        updateState { it.copy(activeThreadKey = key, activeServerId = key.serverId) }
    }

    private fun handleMcpProgressNotification(
        serverId: String,
        params: JSONObject?,
    ) {
        val progress = extractString(params, "message") ?: return
        if (progress.isBlank()) {
            return
        }
        val key = resolveThreadKey(serverId, extractThreadId(params)) ?: return
        val existing = ensureThreadState(key)
        val itemId = extractString(params, "itemId", "item_id")

        val updatedMessages =
            if (itemId != null) {
                appendMcpProgress(existing.messages, progress, itemId, key)
                    ?: (existing.messages + (systemMessage("MCP Tool Progress", progress) ?: return))
            } else {
                existing.messages + (systemMessage("MCP Tool Progress", progress) ?: return)
            }

        threadsByKey[key] =
            existing.copy(
                messages = updatedMessages,
                preview = derivePreview(updatedMessages, existing.preview),
                updatedAtEpochMillis = System.currentTimeMillis(),
            )
        updateState { it.copy(activeThreadKey = key, activeServerId = key.serverId) }
    }

    private fun handleTurnDiffNotification(
        serverId: String,
        params: JSONObject?,
    ) {
        val diff = extractString(params, "diff")?.trim().orEmpty()
        if (diff.isEmpty()) {
            return
        }
        val key = resolveThreadKey(serverId, extractThreadId(params)) ?: return
        val existing = ensureThreadState(key)
        val message = systemMessage("File Diff", "```diff\n$diff\n```") ?: return
        val turnId = extractString(params, "turnId", "turn_id")
        val updatedMessages =
            if (!turnId.isNullOrBlank()) {
                upsertLiveTurnDiffMessage(existing.messages, message, turnId, key)
            } else {
                existing.messages + message
            }

        threadsByKey[key] =
            existing.copy(
                messages = updatedMessages,
                preview = derivePreview(updatedMessages, existing.preview),
                updatedAtEpochMillis = System.currentTimeMillis(),
            )
        updateState { it.copy(activeThreadKey = key, activeServerId = key.serverId) }
    }

    private fun handleLegacyCodexEventNotification(
        serverId: String,
        method: String,
        params: JSONObject?,
    ) {
        val eventPayload: JSONObject
        val eventType: String

        if (method == "codex/event") {
            val msg = params?.optJSONObject("msg") ?: return
            eventPayload = msg
            eventType = extractString(msg, "type").orEmpty()
        } else {
            eventPayload = params?.optJSONObject("msg") ?: params ?: return
            eventType = method.removePrefix("codex/event/")
        }
        if (eventType.isBlank()) {
            return
        }

        val threadId =
            extractString(params, "threadId", "thread_id", "conversationId", "conversation_id")
                ?: extractString(eventPayload, "threadId", "thread_id", "conversationId", "conversation_id")
        val key = resolveThreadKey(serverId, threadId) ?: return
        val existing = ensureThreadState(key)

        val updatedMessages: List<ChatMessage> =
            when (eventType) {
                "exec_command_begin" -> {
                    val itemId = extractString(eventPayload, "call_id", "callId")
                    val command = extractCommandText(eventPayload)
                    val cwd = extractString(eventPayload, "cwd").orEmpty()
                    val lines = ArrayList<String>()
                    lines += "Status: inProgress"
                    if (cwd.isNotEmpty()) lines += "Directory: $cwd"
                    val body =
                        buildString {
                            append(lines.joinToString(separator = "\n"))
                            if (command.isNotEmpty()) {
                                append("\n\nCommand:\n```bash\n")
                                append(command)
                                append("\n```")
                            }
                        }
                    val message = systemMessage("Command Execution", body) ?: return
                    if (itemId != null) {
                        upsertLiveItemMessage(existing.messages, message, itemId, key)
                    } else {
                        existing.messages + message
                    }
                }

                "exec_command_output_delta" -> {
                    val delta = extractString(eventPayload, "chunk").orEmpty()
                    if (delta.isBlank()) return
                    val itemId = extractString(eventPayload, "call_id", "callId")
                    if (itemId != null) {
                        appendCommandOutputDelta(existing.messages, delta, itemId, key)
                            ?: (existing.messages + (systemMessage("Command Output", "```text\n$delta\n```") ?: return))
                    } else {
                        existing.messages + (systemMessage("Command Output", "```text\n$delta\n```") ?: return)
                    }
                }

                "exec_command_end" -> {
                    val itemId = extractString(eventPayload, "call_id", "callId")
                    val command = extractCommandText(eventPayload)
                    val cwd = extractString(eventPayload, "cwd").orEmpty()
                    val status = extractString(eventPayload, "status").orEmpty().ifBlank { "completed" }
                    val exitCode = extractString(eventPayload, "exit_code", "exitCode")
                    val durationMs = durationMillis(eventPayload.opt("duration"))
                    val output = extractCommandOutput(eventPayload)
                    val lines = ArrayList<String>()
                    lines += "Status: $status"
                    if (cwd.isNotEmpty()) lines += "Directory: $cwd"
                    if (!exitCode.isNullOrBlank()) lines += "Exit code: $exitCode"
                    if (durationMs != null) lines += "Duration: $durationMs ms"
                    val body =
                        buildString {
                            append(lines.joinToString(separator = "\n"))
                            if (command.isNotEmpty()) {
                                append("\n\nCommand:\n```bash\n")
                                append(command)
                                append("\n```")
                            }
                            if (output.isNotEmpty()) {
                                append("\n\nOutput:\n```text\n")
                                append(output)
                                append("\n```")
                            }
                        }
                    val message = systemMessage("Command Execution", body) ?: return
                    if (itemId != null) {
                        completeLiveItemMessage(existing.messages, message, itemId, key)
                    } else {
                        existing.messages + message
                    }
                }

                "mcp_tool_call_begin" -> {
                    val itemId = extractString(eventPayload, "call_id", "callId")
                    val invocation = eventPayload.optJSONObject("invocation")
                    val server = extractString(invocation, "server").orEmpty()
                    val tool = extractString(invocation, "tool").orEmpty()
                    val lines = ArrayList<String>()
                    lines += "Status: inProgress"
                    if (server.isNotEmpty() || tool.isNotEmpty()) {
                        lines += "Tool: ${if (server.isEmpty()) tool else "$server/$tool"}"
                    }
                    val body =
                        buildString {
                            append(lines.joinToString(separator = "\n"))
                            val args = invocation?.opt("arguments")
                            val prettyArgs = prettyJson(args)
                            if (!prettyArgs.isNullOrBlank()) {
                                append("\n\nArguments:\n```json\n")
                                append(prettyArgs)
                                append("\n```")
                            }
                        }
                    val message = systemMessage("MCP Tool Call", body) ?: return
                    if (itemId != null) {
                        upsertLiveItemMessage(existing.messages, message, itemId, key)
                    } else {
                        existing.messages + message
                    }
                }

                "mcp_tool_call_end" -> {
                    val itemId = extractString(eventPayload, "call_id", "callId")
                    val invocation = eventPayload.optJSONObject("invocation")
                    val server = extractString(invocation, "server").orEmpty()
                    val tool = extractString(invocation, "tool").orEmpty()
                    val durationMs = durationMillis(eventPayload.opt("duration"))
                    val result = eventPayload.opt("result")
                    var status = "completed"
                    if (result is JSONObject && result.has("Err")) {
                        status = "failed"
                    }
                    val lines = ArrayList<String>()
                    lines += "Status: $status"
                    if (server.isNotEmpty() || tool.isNotEmpty()) {
                        lines += "Tool: ${if (server.isEmpty()) tool else "$server/$tool"}"
                    }
                    if (durationMs != null) {
                        lines += "Duration: $durationMs ms"
                    }
                    val body =
                        buildString {
                            append(lines.joinToString(separator = "\n"))
                            val prettyResult = prettyJson(result)
                            if (!prettyResult.isNullOrBlank()) {
                                append("\n\nResult:\n```json\n")
                                append(prettyResult)
                                append("\n```")
                            }
                        }
                    val message = systemMessage("MCP Tool Call", body) ?: return
                    if (itemId != null) {
                        completeLiveItemMessage(existing.messages, message, itemId, key)
                    } else {
                        existing.messages + message
                    }
                }

                "patch_apply_begin" -> {
                    val itemId = extractString(eventPayload, "call_id", "callId")
                    val changeSummary = legacyPatchChangeBody(eventPayload.opt("changes"))
                    val autoApproved = eventPayload.optBoolean("auto_approved", false)
                    val body =
                        buildString {
                            append("Status: inProgress")
                            append("\nApproval: ${if (autoApproved) "auto" else "requested"}")
                            if (changeSummary.isNotBlank()) {
                                append("\n\n")
                                append(changeSummary)
                            }
                        }
                    val message = systemMessage("File Change", body) ?: return
                    if (itemId != null) {
                        upsertLiveItemMessage(existing.messages, message, itemId, key)
                    } else {
                        existing.messages + message
                    }
                }

                "patch_apply_end" -> {
                    val itemId = extractString(eventPayload, "call_id", "callId")
                    val status =
                        extractString(eventPayload, "status")
                            ?: if (eventPayload.optBoolean("success", false)) "completed" else "failed"
                    val stdout = extractString(eventPayload, "stdout").orEmpty().trim()
                    val stderr = extractString(eventPayload, "stderr").orEmpty().trim()
                    val changeSummary = legacyPatchChangeBody(eventPayload.opt("changes"))
                    val body =
                        buildString {
                            append("Status: $status")
                            if (changeSummary.isNotBlank()) {
                                append("\n\n")
                                append(changeSummary)
                            }
                            if (stdout.isNotBlank()) {
                                append("\n\nOutput:\n```text\n")
                                append(stdout)
                                append("\n```")
                            }
                            if (stderr.isNotBlank()) {
                                append("\n\nError:\n```text\n")
                                append(stderr)
                                append("\n```")
                            }
                        }
                    val message = systemMessage("File Change", body) ?: return
                    if (itemId != null) {
                        completeLiveItemMessage(existing.messages, message, itemId, key)
                    } else {
                        existing.messages + message
                    }
                }

                "turn_diff" -> {
                    val turnId =
                        extractString(params, "id", "turnId", "turn_id")
                            ?: extractString(eventPayload, "id", "turnId", "turn_id")
                    val diff = extractString(eventPayload, "unified_diff").orEmpty().trim()
                    if (diff.isBlank()) {
                        return
                    }
                    val message = systemMessage("File Diff", "```diff\n$diff\n```") ?: return
                    if (!turnId.isNullOrBlank()) {
                        upsertLiveTurnDiffMessage(existing.messages, message, turnId, key)
                    } else {
                        existing.messages + message
                    }
                }

                else -> return
            }

        threadsByKey[key] =
            existing.copy(
                messages = updatedMessages,
                preview = derivePreview(updatedMessages, existing.preview),
                updatedAtEpochMillis = System.currentTimeMillis(),
            )
        updateState { it.copy(activeThreadKey = key, activeServerId = key.serverId) }
    }

    private fun upsertLiveItemMessage(
        messages: List<ChatMessage>,
        message: ChatMessage,
        itemId: String,
        key: ThreadKey,
    ): List<ChatMessage> {
        val indices = liveItemMessageIndices.getOrPut(key) { LinkedHashMap() }
        val existingIndex = indices[itemId]
        val updated = messages.toMutableList()
        if (existingIndex != null && existingIndex in updated.indices) {
            updated[existingIndex] = message
        } else {
            indices[itemId] = updated.size
            updated += message
        }
        return updated
    }

    private fun completeLiveItemMessage(
        messages: List<ChatMessage>,
        message: ChatMessage,
        itemId: String,
        key: ThreadKey,
    ): List<ChatMessage> {
        val indices = liveItemMessageIndices.getOrPut(key) { LinkedHashMap() }
        val existingIndex = indices[itemId]
        val updated = messages.toMutableList()
        if (existingIndex != null && existingIndex in updated.indices) {
            updated[existingIndex] = message
        } else {
            updated += message
        }
        indices.remove(itemId)
        return updated
    }

    private fun appendCommandOutputDelta(
        messages: List<ChatMessage>,
        delta: String,
        itemId: String,
        key: ThreadKey,
    ): List<ChatMessage>? {
        val index = liveItemMessageIndices[key]?.get(itemId) ?: return null
        if (index !in messages.indices) {
            return null
        }
        val updated = messages.toMutableList()
        val current = updated[index]
        updated[index] = current.copy(text = mergeCommandOutput(current.text, delta))
        return updated
    }

    private fun appendMcpProgress(
        messages: List<ChatMessage>,
        progress: String,
        itemId: String,
        key: ThreadKey,
    ): List<ChatMessage>? {
        val index = liveItemMessageIndices[key]?.get(itemId) ?: return null
        if (index !in messages.indices) {
            return null
        }
        val updated = messages.toMutableList()
        val current = updated[index]
        updated[index] = current.copy(text = mergeProgress(current.text, progress))
        return updated
    }

    private fun mergeCommandOutput(
        current: String,
        delta: String,
    ): String {
        val outputPrefix = "\n\nOutput:\n```text\n"
        val closingFence = "\n```"
        val outputStart = current.indexOf(outputPrefix)
        if (outputStart >= 0) {
            val closeStart = current.lastIndexOf(closingFence)
            if (closeStart >= outputStart + outputPrefix.length) {
                return buildString {
                    append(current.substring(0, closeStart))
                    append(delta)
                    append(current.substring(closeStart))
                }
            }
        }
        val chunk = if (delta.endsWith("\n")) delta else "$delta\n"
        return current + outputPrefix + chunk + "```"
    }

    private fun mergeProgress(
        current: String,
        progress: String,
    ): String {
        return if (current.contains("\n\nProgress:\n")) {
            "$current\n$progress"
        } else {
            "$current\n\nProgress:\n$progress"
        }
    }

    private fun upsertLiveTurnDiffMessage(
        messages: List<ChatMessage>,
        message: ChatMessage,
        turnId: String,
        key: ThreadKey,
    ): List<ChatMessage> {
        val indices = liveTurnDiffMessageIndices.getOrPut(key) { LinkedHashMap() }
        val existingIndex = indices[turnId]
        val updated = messages.toMutableList()
        if (existingIndex != null && existingIndex in updated.indices) {
            updated[existingIndex] = message
        } else {
            indices[turnId] = updated.size
            updated += message
        }
        return updated
    }

    private fun extractCommandText(eventPayload: JSONObject): String {
        val command = eventPayload.opt("command")
        return when (command) {
            is JSONArray -> {
                val parts = ArrayList<String>(command.length())
                for (index in 0 until command.length()) {
                    val token = command.opt(index)?.toString()?.trim().orEmpty()
                    if (token.isNotEmpty()) {
                        parts += token
                    }
                }
                parts.joinToString(separator = " ")
            }

            is String -> command.trim()
            else -> ""
        }
    }

    private fun extractCommandOutput(eventPayload: JSONObject): String {
        val candidates =
            listOf(
                extractString(eventPayload, "aggregated_output"),
                extractString(eventPayload, "formatted_output"),
                extractString(eventPayload, "stdout"),
                extractString(eventPayload, "stderr"),
            )
        return candidates
            .mapNotNull { it?.trim()?.takeIf { text -> text.isNotEmpty() } }
            .joinToString(separator = "\n")
    }

    private fun durationMillis(rawDuration: Any?): Long? {
        return when (rawDuration) {
            null, JSONObject.NULL -> null
            is Number -> rawDuration.toLong()
            is JSONObject -> {
                val secs = rawDuration.opt("secs").asLongOrNull() ?: return null
                val nanos = rawDuration.opt("nanos").asLongOrNull() ?: 0L
                secs * 1000L + nanos / 1_000_000L
            }

            else -> rawDuration.toString().trim().toLongOrNull()
        }
    }

    private fun legacyPatchChangeBody(rawChanges: Any?): String {
        val changes = rawChanges as? JSONObject ?: return ""
        val keys = changes.keys().asSequence().toList().sorted()
        if (keys.isEmpty()) {
            return ""
        }

        val sections = ArrayList<String>()
        for (path in keys) {
            val change = changes.optJSONObject(path) ?: continue
            val kind = extractString(change, "type").orEmpty().ifBlank { "update" }
            val section =
                buildString {
                    append("Path: $path\n")
                    append("Kind: $kind")
                    val diff = extractString(change, "unified_diff").orEmpty().trim()
                    if (kind == "update" && diff.isNotEmpty()) {
                        append("\n\n```diff\n")
                        append(diff)
                        append("\n```")
                    } else if ((kind == "add" || kind == "delete")) {
                        val content = extractString(change, "content").orEmpty().trim()
                        if (content.isNotEmpty()) {
                            append("\n\n```text\n")
                            append(content)
                            append("\n```")
                        }
                    }
                }.trim()
            if (section.isNotEmpty()) {
                sections += section
            }
        }
        return sections.joinToString(separator = "\n\n---\n\n")
    }

    private fun extractString(
        obj: JSONObject?,
        vararg keys: String,
    ): String? {
        if (obj == null) {
            return null
        }
        for (key in keys) {
            if (!obj.has(key)) {
                continue
            }
            val value = obj.opt(key)
            val text =
                when (value) {
                    null, JSONObject.NULL -> null
                    is Number -> value.toString()
                    is String -> value
                    else -> value.toString()
                }?.trim()
            if (!text.isNullOrEmpty()) {
                return text
            }
        }
        return null
    }

    private fun parseModelProvider(obj: JSONObject?): String {
        return extractString(
            obj,
            "modelProvider",
            "model_provider",
            "modelProviderId",
            "model_provider_id",
            "model",
        ).orEmpty()
    }

    private fun parseParentThreadId(obj: JSONObject?): String? {
        val direct =
            extractString(
                obj,
                "parentThreadId",
                "parent_thread_id",
                "forkedFromId",
                "forked_from_id",
            )
        if (!direct.isNullOrBlank()) {
            return direct
        }
        val source = obj?.opt("source")
        if (source !is JSONObject) {
            return null
        }
        val subAgent = source.opt("subAgent") as? JSONObject ?: return null
        val threadSpawn = subAgent.opt("thread_spawn") as? JSONObject ?: return null
        return extractString(threadSpawn, "parent_thread_id", "parentThreadId")
    }

    private fun parseRootThreadId(obj: JSONObject?): String? {
        return extractString(obj, "rootThreadId", "root_thread_id")
    }

    private fun prettyJson(value: Any?): String? {
        return when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> value.toString(2)
            is JSONArray -> value.toString(2)
            else -> value.toString()
        }?.trim()?.ifEmpty { null }
    }

    private fun extractThreadId(params: JSONObject?): String? {
        return extractString(
            params,
            "threadId",
            "threadID",
            "thread_id",
            "conversationId",
            "conversationID",
            "conversation_id",
        )
    }

    private fun approvalNotificationTitle(key: ThreadKey): String {
        val thread = threadsByKey[key]
        val serverName = thread?.serverName?.takeIf { it.isNotBlank() } ?: "Codex"
        val preview = thread?.preview?.takeIf { it.isNotBlank() } ?: "Thread update"
        return "$serverName: $preview"
    }

    private fun assistantPreview(key: ThreadKey): String {
        val thread = threadsByKey[key] ?: return "Assistant replied."
        val latest = thread.messages.lastOrNull { it.role == MessageRole.ASSISTANT }?.text?.trim().orEmpty()
        return if (latest.isNotEmpty()) latest.take(180) else "Assistant replied."
    }

    private fun notifyAwayIfNeeded(
        dedupeKey: String,
        title: String,
        body: String,
    ) {
        if (appInForeground) {
            return
        }
        awayNotifier?.notify(dedupeKey = dedupeKey, title = title, body = body)
    }

    private fun syncActiveThreadFromServerInternal() {
        val key = state.activeThreadKey ?: return
        val changed = runCatching { syncThreadFromServerInternal(key) }.getOrDefault(false)
        if (changed) {
            updateState { it }
        }
    }

    private fun syncAllThreadsFromServerInternal() {
        val keys = threadsByKey.keys.toList()
        var changed = false
        for (key in keys) {
            val synced = runCatching { syncThreadFromServerInternal(key) }.getOrDefault(false)
            changed = synced || changed
        }
        if (changed) {
            updateState { it }
        }
    }

    private fun suspendRealtimeConnectionsInternal() {
        val threadKeys = threadsByKey.keys.toList()
        for (key in threadKeys) {
            val transport = transportsByServerId[key.serverId] ?: continue
            runCatching {
                transport.request(
                    method = "thread/unsubscribe",
                    params = JSONObject().put("threadId", key.threadId),
                    timeoutSeconds = 5,
                )
            }
        }
        transportsByServerId.values.forEach { transport ->
            runCatching { transport.close() }
        }
        transportsByServerId.clear()
        updateState { current ->
            current.copy(
                connectionStatus = ServerConnectionStatus.DISCONNECTED,
                connectionError = null,
            )
        }
    }

    private fun resumeRealtimeConnectionsInternal() {
        if (serversById.isEmpty()) {
            return
        }
        updateState { it.copy(connectionStatus = ServerConnectionStatus.CONNECTING, connectionError = null) }
        val reconnectTargets = serversById.values.toList()
        for (server in reconnectTargets) {
            runCatching { connectServerInternal(server) }
        }
        updateState {
            it.copy(
                connectionStatus = if (transportsByServerId.isEmpty()) ServerConnectionStatus.ERROR else ServerConnectionStatus.READY,
                connectionError = if (transportsByServerId.isEmpty()) "Failed to reconnect background sockets" else null,
            )
        }
    }

    private fun syncThreadFromServerInternal(key: ThreadKey): Boolean {
        val thread = threadsByKey[key] ?: return false
        if (thread.hasTurnActive) {
            return false
        }

        val cwd = thread.cwd.ifBlank { defaultWorkingDirectory() }
        val response = runCatching { resumeThreadWithFallback(key.serverId, key.threadId, cwd) }.getOrNull() ?: return false
        val threadObj = response.optJSONObject("thread") ?: return false
        val restored = restoreMessages(threadObj)
        val responseModelProvider = parseModelProvider(response)
        val threadModelProvider = parseModelProvider(threadObj)
        if (messagesEquivalent(thread.messages, restored.messages)) {
            return false
        }
        if (shouldPreferLocalMessages(thread.messages, restored.messages)) {
            return false
        }

        threadsByKey[key] =
            thread.copy(
                status = ThreadStatus.READY,
                activeTurnId = null,
                messages = restored.messages,
                preview = derivePreview(restored.messages, thread.preview),
                modelProvider = responseModelProvider.ifBlank { threadModelProvider.ifBlank { thread.modelProvider } },
                parentThreadId = parseParentThreadId(threadObj) ?: thread.parentThreadId,
                rootThreadId = parseRootThreadId(threadObj) ?: thread.rootThreadId,
                updatedAtEpochMillis = System.currentTimeMillis(),
                lastError = null,
            )
        threadTurnCounts[key] = restored.turnCount
        liveItemMessageIndices.remove(key)
        liveTurnDiffMessageIndices.remove(key)
        return true
    }

    private fun messagesEquivalent(
        left: List<ChatMessage>,
        right: List<ChatMessage>,
    ): Boolean {
        if (left.size != right.size) {
            return false
        }
        for (index in left.indices) {
            val lhs = left[index]
            val rhs = right[index]
            if (lhs.role != rhs.role || lhs.text != rhs.text) {
                return false
            }
            if (lhs.sourceTurnId != rhs.sourceTurnId) {
                return false
            }
            if (lhs.sourceTurnIndex != rhs.sourceTurnIndex) {
                return false
            }
            if (lhs.isFromUserTurnBoundary != rhs.isFromUserTurnBoundary) {
                return false
            }
        }
        return true
    }

    private fun shouldPreferLocalMessages(
        current: List<ChatMessage>,
        restored: List<ChatMessage>,
    ): Boolean {
        val currentToolCount = current.count { isToolSystemMessage(it) }
        val restoredToolCount = restored.count { isToolSystemMessage(it) }
        return currentToolCount > restoredToolCount && restored.size <= current.size
    }

    private fun isToolSystemMessage(message: ChatMessage): Boolean {
        if (message.role != MessageRole.SYSTEM) {
            return false
        }
        val title = extractSystemTitle(message.text)?.lowercase().orEmpty()
        return title.contains("command") ||
            title.contains("file") ||
            title.contains("mcp") ||
            title.contains("web") ||
            title.contains("collab") ||
            title.contains("image")
    }

    private fun extractSystemTitle(text: String): String? {
        val trimmed = text.trim()
        if (!trimmed.startsWith("### ")) {
            return null
        }
        val firstLine = trimmed.lineSequence().firstOrNull().orEmpty()
        return firstLine.removePrefix("### ").trim().ifEmpty { null }
    }

    private data class RestoredMessages(
        val messages: List<ChatMessage>,
        val turnCount: Int,
    )

    private fun restoreMessages(threadObject: JSONObject): RestoredMessages {
        val restored = ArrayList<ChatMessage>()
        val turns = threadObject.optJSONArray("turns")
        if (turns != null) {
            for (index in 0 until turns.length()) {
                val turn = turns.optJSONObject(index) ?: continue
                val turnId = turn.optString("id").trim().ifEmpty { null }
                val items = turn.optJSONArray("items") ?: continue
                parseItemsInto(
                    out = restored,
                    items = items,
                    sourceTurnId = turnId,
                    sourceTurnIndex = index,
                )
            }
            return RestoredMessages(messages = restored, turnCount = turns.length())
        }

        val legacyItems = threadObject.optJSONArray("items")
        if (legacyItems != null) {
            parseItemsInto(
                out = restored,
                items = legacyItems,
                sourceTurnId = null,
                sourceTurnIndex = null,
            )
        }
        return RestoredMessages(
            messages = restored,
            turnCount = inferredTurnCountFromMessages(restored),
        )
    }

    private fun parseItemsInto(
        out: MutableList<ChatMessage>,
        items: JSONArray,
        sourceTurnId: String?,
        sourceTurnIndex: Int?,
    ) {
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            val message = chatMessageFromItem(item, sourceTurnId, sourceTurnIndex) ?: continue
            out += message
        }
    }

    private fun chatMessageFromItem(
        item: JSONObject,
        sourceTurnId: String?,
        sourceTurnIndex: Int?,
    ): ChatMessage? {
        return when (item.optString("type")) {
            "userMessage" -> {
                val content = item.optJSONArray("content")
                val text = parseUserMessageText(content, item.optString("text"))
                if (text.isBlank()) {
                    null
                } else {
                    ChatMessage(
                        role = MessageRole.USER,
                        text = text,
                        sourceTurnId = sourceTurnId,
                        sourceTurnIndex = sourceTurnIndex,
                        isFromUserTurnBoundary = true,
                    )
                }
            }

            "agentMessage",
            "assistantMessage" -> {
                val text = parseAgentMessageText(item)
                if (text.isEmpty()) {
                    null
                } else {
                    ChatMessage(
                        role = MessageRole.ASSISTANT,
                        text = text,
                        sourceTurnId = sourceTurnId,
                        sourceTurnIndex = sourceTurnIndex,
                    )
                }
            }

            "plan" -> {
                val text = item.optString("text").trim()
                withTurnMetadata(
                    if (text.isEmpty()) null else systemMessage("Plan", text),
                    sourceTurnId = sourceTurnId,
                    sourceTurnIndex = sourceTurnIndex,
                )
            }

            "reasoning" -> {
                val summary = readStringArray(item.opt("summary"))
                val content = readStringArray(item.opt("content"))
                val body = (summary + content).joinToString(separator = "\n\n").trim()
                if (body.isEmpty()) {
                    null
                } else {
                    ChatMessage(
                        role = MessageRole.REASONING,
                        text = body,
                        sourceTurnId = sourceTurnId,
                        sourceTurnIndex = sourceTurnIndex,
                    )
                }
            }

            "commandExecution" -> withTurnMetadata(parseCommandExecutionMessage(item), sourceTurnId, sourceTurnIndex)
            "fileChange" -> withTurnMetadata(parseFileChangeMessage(item), sourceTurnId, sourceTurnIndex)
            "mcpToolCall" -> withTurnMetadata(parseMcpToolCallMessage(item), sourceTurnId, sourceTurnIndex)
            "collabAgentToolCall" -> withTurnMetadata(parseCollabMessage(item), sourceTurnId, sourceTurnIndex)
            "webSearch" -> withTurnMetadata(parseWebSearchMessage(item), sourceTurnId, sourceTurnIndex)
            "imageView" -> {
                val path = item.optString("path").trim()
                withTurnMetadata(
                    if (path.isEmpty()) null else systemMessage("Image View", "Path: $path"),
                    sourceTurnId = sourceTurnId,
                    sourceTurnIndex = sourceTurnIndex,
                )
            }

            "enteredReviewMode" -> {
                val review = item.optString("review").trim()
                withTurnMetadata(
                    systemMessage("Review Mode", "Entered review: $review"),
                    sourceTurnId = sourceTurnId,
                    sourceTurnIndex = sourceTurnIndex,
                )
            }

            "exitedReviewMode" -> {
                val review = item.optString("review").trim()
                withTurnMetadata(
                    systemMessage("Review Mode", "Exited review: $review"),
                    sourceTurnId = sourceTurnId,
                    sourceTurnIndex = sourceTurnIndex,
                )
            }

            "contextCompaction" -> withTurnMetadata(
                systemMessage("Context", "Context compaction occurred."),
                sourceTurnId = sourceTurnId,
                sourceTurnIndex = sourceTurnIndex,
            )
            else -> null
        }
    }

    private fun parseCommandExecutionMessage(item: JSONObject): ChatMessage? {
        val status = item.optString("status").trim()
        val cwd = item.optString("cwd").trim()
        val output =
            item.optString("output")
                .trim()
                .ifEmpty { item.optString("stdout").trim() }
        val exitCode = item.opt("exitCode")
        val durationMs = item.opt("durationMs")
        val command =
            when (val commandValue = item.opt("command")) {
                is JSONArray -> {
                    val parts = ArrayList<String>(commandValue.length())
                    for (idx in 0 until commandValue.length()) {
                        val token = commandValue.opt(idx)?.toString()?.trim().orEmpty()
                        if (token.isNotEmpty()) {
                            parts += token
                        }
                    }
                    parts.joinToString(separator = " ")
                }

                is String -> commandValue.trim()
                else -> ""
            }

        val lines = ArrayList<String>()
        if (status.isNotEmpty()) {
            lines += "Status: $status"
        }
        if (cwd.isNotEmpty()) {
            lines += "Directory: $cwd"
        }
        val numericExitCode = (exitCode as? Number)?.toInt() ?: exitCode?.toString()?.trim()?.toIntOrNull()
        if (numericExitCode != null) {
            lines += "Exit code: $numericExitCode"
        }
        val numericDuration = (durationMs as? Number)?.toLong() ?: durationMs?.toString()?.trim()?.toLongOrNull()
        if (numericDuration != null) {
            lines += "Duration: $numericDuration ms"
        }

        val body =
            buildString {
                append(lines.joinToString(separator = "\n"))
                if (command.isNotEmpty()) {
                    if (isNotEmpty()) append("\n\n")
                    append("Command:\n```bash\n")
                    append(command)
                    append("\n```")
                }
                if (output.isNotEmpty()) {
                    if (isNotEmpty()) append("\n\n")
                    append("Output:\n```text\n")
                    append(output)
                    append("\n```")
                }
            }.trim()

        return if (body.isEmpty()) null else systemMessage("Command Execution", body)
    }

    private fun parseFileChangeMessage(item: JSONObject): ChatMessage? {
        val status = item.optString("status").trim()
        val changes = item.optJSONArray("changes") ?: JSONArray()
        if (changes.length() == 0) {
            return systemMessage("File Change", "Status: $status")
        }

        val parts = ArrayList<String>()
        for (idx in 0 until changes.length()) {
            val change = changes.optJSONObject(idx) ?: continue
            val path = change.optString("path").trim()
            val kind =
                when (val kindValue = change.opt("kind")) {
                    is JSONObject -> kindValue.optString("type").trim()
                    else -> kindValue?.toString()?.trim().orEmpty()
                }.ifBlank { "update" }
            val diff =
                extractString(change, "diff", "unified_diff")
                    .orEmpty()
                    .trim()
            val piece =
                buildString {
                    if (path.isNotEmpty()) append("Path: $path\n")
                    if (kind.isNotEmpty()) append("Kind: $kind")
                    if (diff.isNotEmpty()) {
                        if (isNotEmpty()) append("\n\n")
                        append("```diff\n")
                        append(diff)
                        append("\n```")
                    }
                }.trim()
            if (piece.isNotEmpty()) {
                parts += piece
            }
        }
        val body =
            buildString {
                append("Status: $status")
                if (parts.isNotEmpty()) {
                    append("\n\n")
                    append(parts.joinToString(separator = "\n\n---\n\n"))
                }
            }
        return systemMessage("File Change", body)
    }

    private fun parseMcpToolCallMessage(item: JSONObject): ChatMessage? {
        val status = item.optString("status").trim()
        val server = item.optString("server").trim()
        val tool = item.optString("tool").trim()
        val duration = item.opt("durationMs")?.toString()?.trim().orEmpty()
        val errorObject = item.optJSONObject("error")
        val errorMessage = errorObject?.optString("message")?.trim().orEmpty()

        val lines = ArrayList<String>()
        if (status.isNotEmpty()) lines += "Status: $status"
        if (server.isNotEmpty() || tool.isNotEmpty()) {
            val combined = if (server.isEmpty()) tool else "$server/$tool"
            lines += "Tool: $combined"
        }
        if (duration.isNotEmpty()) lines += "Duration: $duration ms"
        if (errorMessage.isNotEmpty()) lines += "Error: $errorMessage"
        val body = lines.joinToString(separator = "\n")
        return if (body.isEmpty()) null else systemMessage("MCP Tool Call", body)
    }

    private fun parseCollabMessage(item: JSONObject): ChatMessage? {
        val status = item.optString("status").trim()
        val tool = item.optString("tool").trim()
        val prompt = item.optString("prompt").trim()
        val receivers = item.optJSONArray("receiverThreadIds")

        val lines = ArrayList<String>()
        if (status.isNotEmpty()) lines += "Status: $status"
        if (tool.isNotEmpty()) lines += "Tool: $tool"
        if (receivers != null && receivers.length() > 0) {
            val ids = ArrayList<String>()
            for (idx in 0 until receivers.length()) {
                val id = receivers.opt(idx)?.toString()?.trim().orEmpty()
                if (id.isNotEmpty()) ids += id
            }
            if (ids.isNotEmpty()) lines += "Targets: ${ids.joinToString(separator = ", ")}"
        }
        if (prompt.isNotEmpty()) {
            lines += ""
            lines += "Prompt:"
            lines += prompt
        }
        val body = lines.joinToString(separator = "\n").trim()
        return if (body.isEmpty()) null else systemMessage("Collaboration", body)
    }

    private fun parseWebSearchMessage(item: JSONObject): ChatMessage? {
        val query = item.optString("query").trim()
        val action = item.opt("action")
        val body =
            buildString {
                if (query.isNotEmpty()) {
                    append("Query: $query")
                }
                if (action != null && action != JSONObject.NULL) {
                    if (isNotEmpty()) append("\n\n")
                    append("Action:\n```json\n")
                    append(action.toString())
                    append("\n```")
                }
            }.trim()
        return if (body.isEmpty()) null else systemMessage("Web Search", body)
    }

    private fun systemMessage(
        title: String,
        body: String,
    ): ChatMessage? {
        val trimmed = body.trim()
        if (trimmed.isEmpty()) {
            return null
        }
        return ChatMessage(role = MessageRole.SYSTEM, text = "### $title\n$trimmed")
    }

    private fun withTurnMetadata(
        message: ChatMessage?,
        sourceTurnId: String?,
        sourceTurnIndex: Int?,
    ): ChatMessage? {
        if (message == null) {
            return null
        }
        return message.copy(
            sourceTurnId = sourceTurnId,
            sourceTurnIndex = sourceTurnIndex,
        )
    }

    private fun parseUserMessageText(
        content: JSONArray?,
        fallback: String,
    ): String {
        if (content == null) {
            return fallback.trim()
        }
        val parts = ArrayList<String>()
        for (index in 0 until content.length()) {
            val piece = content.optJSONObject(index) ?: continue
            when (piece.optString("type")) {
                "text" -> {
                    val text = piece.optString("text").trim()
                    if (text.isNotEmpty()) {
                        parts += text
                    }
                }

                "image" -> {
                    val url = piece.optString("url").trim()
                    if (url.startsWith("data:image/", ignoreCase = true)) {
                        parts += "[Image] inline"
                    } else if (url.isNotEmpty()) {
                        parts += "[Image] $url"
                    }
                }

                "localImage" -> {
                    val path = piece.optString("path").trim()
                    if (path.isNotEmpty()) {
                        val name = File(path).name.ifEmpty { path }
                        parts += "[Image] $name"
                    }
                }

                "skill" -> {
                    val name = piece.optString("name").trim()
                    val path = piece.optString("path").trim()
                    when {
                        name.isNotEmpty() && path.isNotEmpty() -> parts += "[Skill] $name ($path)"
                        name.isNotEmpty() -> parts += "[Skill] $name"
                        path.isNotEmpty() -> parts += "[Skill] $path"
                    }
                }

                "mention" -> {
                    val name = piece.optString("name").trim()
                    val path = piece.optString("path").trim()
                    when {
                        name.isNotEmpty() && path.isNotEmpty() -> parts += "[Mention] $name ($path)"
                        name.isNotEmpty() -> parts += "[Mention] $name"
                        path.isNotEmpty() -> parts += "[Mention] $path"
                    }
                }
            }
        }
        if (parts.isEmpty()) {
            return fallback.trim()
        }
        return parts.joinToString(separator = "\n")
    }

    private fun parseAgentMessageText(item: JSONObject): String {
        val direct = item.optString("text").trim()
        if (direct.isNotEmpty()) {
            return direct
        }
        val content = item.optJSONArray("content") ?: return ""
        val parts = ArrayList<String>()
        for (index in 0 until content.length()) {
            val piece = content.optJSONObject(index) ?: continue
            when (piece.optString("type")) {
                "text", "output_text" -> {
                    val text = piece.optString("text").trim()
                    if (text.isNotEmpty()) {
                        parts += text
                    }
                }

                "image", "output_image" -> {
                    parts += "[Image]"
                }
            }
        }
        return parts.joinToString(separator = "\n").trim()
    }

    private fun parseReasoningEfforts(array: JSONArray?): List<ReasoningEffortOption> {
        if (array == null) {
            return emptyList()
        }
        val options = ArrayList<ReasoningEffortOption>(array.length())
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val effort =
                item.optString("reasoningEffort").trim().ifBlank {
                    item.optString("reasoning_effort").trim()
                }
            if (effort.isEmpty()) {
                continue
            }
            val description = item.optString("description").trim()
            options += ReasoningEffortOption(effort = effort, description = description)
        }
        return options
    }

    private fun ensureThreadState(key: ThreadKey): ThreadState {
        val existing = threadsByKey[key]
        if (existing != null) {
            return existing
        }
        val server = serversById[key.serverId] ?: ServerConfig.local(port = 0)
        val created =
            ThreadState(
                key = key,
                serverName = server.name,
                serverSource = server.source,
                status = ThreadStatus.READY,
            )
        threadsByKey[key] = created
        threadTurnCounts[key] = threadTurnCounts[key] ?: 0
        return created
    }

    private fun resolveThreadKey(
        serverId: String,
        threadId: String?,
    ): ThreadKey? {
        if (!threadId.isNullOrBlank()) {
            return ThreadKey(serverId = serverId, threadId = threadId)
        }
        val active = state.activeThreadKey
        if (active?.serverId == serverId) {
            return active
        }
        return threadsByKey.values.firstOrNull { it.key.serverId == serverId && it.hasTurnActive }?.key
            ?: threadsByKey.values.firstOrNull { it.key.serverId == serverId }?.key
    }

    private fun appendAssistantDelta(
        messages: List<ChatMessage>,
        delta: String,
    ): List<ChatMessage> {
        if (delta.isEmpty()) {
            return messages
        }
        if (messages.isEmpty()) {
            return listOf(ChatMessage(role = MessageRole.ASSISTANT, text = delta, isStreaming = true))
        }
        val last = messages.last()
        return if (last.role == MessageRole.ASSISTANT && last.isStreaming) {
            val updated = messages.toMutableList()
            updated[updated.lastIndex] =
                last.copy(text = last.text + delta, timestampEpochMillis = System.currentTimeMillis())
            updated
        } else {
            messages + ChatMessage(role = MessageRole.ASSISTANT, text = delta, isStreaming = true)
        }
    }

    private fun finalizeStreaming(messages: List<ChatMessage>): List<ChatMessage> {
        if (messages.isEmpty()) {
            return messages
        }
        val last = messages.last()
        if (last.role != MessageRole.ASSISTANT || !last.isStreaming) {
            return messages
        }
        val updated = messages.toMutableList()
        updated[updated.lastIndex] =
            last.copy(isStreaming = false, timestampEpochMillis = System.currentTimeMillis())
        return updated
    }

    private fun derivePreview(
        messages: List<ChatMessage>,
        fallback: String?,
    ): String {
        val candidate =
            messages
                .asReversed()
                .firstOrNull { it.role == MessageRole.ASSISTANT || it.role == MessageRole.USER }
                ?.text
                ?.trim()
                .orEmpty()
        if (candidate.isNotEmpty()) {
            return candidate.take(120)
        }
        return fallback.orEmpty()
    }

    private fun readStringArray(value: Any?): List<String> {
        return when (value) {
            null, JSONObject.NULL -> emptyList()
            is String -> listOf(value)
            is JSONArray -> {
                val out = ArrayList<String>(value.length())
                for (index in 0 until value.length()) {
                    val element = value.opt(index)
                    val text = stringify(element)
                    if (!text.isNullOrBlank()) {
                        out += text.trim()
                    }
                }
                out
            }

            else -> {
                val text = stringify(value)
                if (text.isNullOrBlank()) {
                    emptyList()
                } else {
                    listOf(text.trim())
                }
            }
        }
    }

    private fun stringify(value: Any?): String? {
        return when (value) {
            null, JSONObject.NULL -> null
            is String -> value
            is Number -> value.toString()
            is Boolean -> value.toString()
            is JSONObject -> value.toString()
            is JSONArray -> value.toString()
            else -> value.toString()
        }
    }

    private fun shouldRetryWithoutLinuxSandbox(error: Throwable): Boolean {
        val lower = error.message?.lowercase().orEmpty()
        return lower.contains("codex-linux-sandbox was required but not provided") ||
            lower.contains("missing codex-linux-sandbox executable path")
    }

    private fun executeCommandInternal(
        serverId: String,
        command: List<String>,
        cwd: String? = null,
    ): JSONObject {
        val commandArray = JSONArray()
        command.forEach { commandArray.put(it) }
        return requireTransport(serverId).request(
            method = "command/exec",
            params = JSONObject()
                .put("command", commandArray)
                .put("cwd", cwd ?: JSONObject.NULL),
        )
    }

    private fun ensureBundledServiceReady() {
        val context = appContext ?: throw IllegalStateException("Bundled server requires Android application context")
        val intent = Intent(context, BundledCodexService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }

        val deadline = SystemClock.elapsedRealtime() + 60_000L
        while (SystemClock.elapsedRealtime() < deadline) {
            if (isLocalPortReachable(BundledCodexService.PORT)) {
                return
            }
            val serviceError = BundledCodexService.lastError?.takeIf { it.isNotBlank() }
            if (serviceError != null) {
                throw IllegalStateException(serviceError)
            }
            Thread.sleep(150L)
        }

        val serviceError = BundledCodexService.lastError?.takeIf { it.isNotBlank() }
        throw IllegalStateException(
            serviceError
                ?: "Bundled server did not become ready on ws://127.0.0.1:${BundledCodexService.PORT}",
        )
    }

    private fun isLocalPortReachable(
        port: Int,
        timeoutMs: Int = 250,
    ): Boolean {
        return runCatching {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), timeoutMs)
            }
            true
        }.getOrDefault(false)
    }

    private fun shellCommandCandidatesForServer(serverId: String): List<String> {
        val source = serversById[serverId]?.source
        return when (source) {
            ServerSource.LOCAL, ServerSource.BUNDLED -> listOf("/system/bin/sh", "/bin/sh", "sh")
            else -> listOf("/bin/sh", "/usr/bin/sh", "sh")
        }
    }

    private fun listCommandCandidatesForServer(serverId: String): List<String> {
        val source = serversById[serverId]?.source
        return when (source) {
            ServerSource.LOCAL, ServerSource.BUNDLED -> listOf("/system/bin/ls", "/bin/ls", "ls")
            else -> listOf("/bin/ls", "/usr/bin/ls", "ls")
        }
    }

    private fun preferredDirectoryRootForServer(serverId: String): String {
        val source = serversById[serverId]?.source
        return when (source) {
            ServerSource.BUNDLED -> {
                appContext?.let(::bundledWorkspaceDir)?.absolutePath?.trim().orEmpty().ifEmpty { defaultWorkingDirectory() }
            }
            ServerSource.LOCAL -> {
                appContext?.filesDir?.absolutePath?.trim().orEmpty().ifEmpty { defaultWorkingDirectory() }
            }
            else -> "/"
        }
    }

    private fun bundledWorkspaceDir(context: Context): File {
        val dir = File(context.filesDir, "workspace")
        dir.mkdirs()
        return dir
    }

    private fun listLocalDirectoriesInternal(
        path: String,
        fallbackRoot: String,
    ): List<String> {
        val rawPath = path.trim()
        val normalized =
            when {
                rawPath.isEmpty() -> fallbackRoot
                rawPath == "/" -> fallbackRoot
                else -> rawPath
            }
        val rootFile = File(fallbackRoot).canonicalFile
        val target = runCatching { File(normalized).canonicalFile }.getOrElse { rootFile }
        val safeTarget =
            if (target.path.startsWith(rootFile.path)) {
                target
            } else {
                rootFile
            }
        if (!safeTarget.exists()) {
            return emptyList()
        }
        return safeTarget
            .listFiles()
            .orEmpty()
            .filter { it.isDirectory }
            .map { it.name }
            .sortedWith(compareBy<String> { it.lowercase(Locale.ROOT) }.thenBy { it })
    }

    private fun isLocalOrBundledServer(serverId: String): Boolean {
        return when (serversById[serverId]?.source) {
            ServerSource.LOCAL, ServerSource.BUNDLED -> true
            else -> false
        }
    }

    private fun isMissingExecutable(
        exitCode: Int,
        stderr: String,
    ): Boolean {
        if (exitCode == 127) {
            return true
        }
        val lower = stderr.lowercase(Locale.ROOT)
        return lower.contains("not found") || lower.contains("no such file or directory")
    }

    private fun requireTransport(serverId: String): BridgeRpcTransport =
        transportsByServerId[serverId]
            ?: throw IllegalStateException("Codex bridge transport is not connected for server '$serverId'")

    private fun ensureConnectedServer(serverId: String): ServerConfig =
        serversById[serverId] ?: throw IllegalStateException("No connected server '$serverId'")

    private fun resolveServerIdForActiveOperations(): String {
        return state.activeThreadKey?.serverId
            ?: state.activeServerId
            ?: serversById.keys.firstOrNull()
            ?: throw IllegalStateException("No connected server")
    }

    private fun resolveServerIdForAuthOperations(): String {
        val activeServer = state.activeServerId?.let { serversById[it] }
        if (activeServer?.source == ServerSource.BUNDLED) {
            return activeServer.id
        }

        val connectedBundled = serversById.values.firstOrNull { it.source == ServerSource.BUNDLED }
        if (connectedBundled != null) {
            updateState { it.copy(activeServerId = connectedBundled.id) }
            return connectedBundled.id
        }

        val context = appContext
        if (context != null) {
            val bundledServer =
                runCatching {
                    val connected = connectServerInternal(ServerConfig.bundled(BundledCodexService.PORT))
                    refreshSessionsInternal(connected.id)
                    loadModelsInternal(connected.id)
                    refreshAccountStateInternal(connected.id)
                    connected
                }.getOrNull()
            if (bundledServer != null) {
                return bundledServer.id
            }
        }

        return resolveServerIdForActiveOperations()
    }

    private fun resolveServerIdForRequestedOperation(serverId: String?): String {
        val explicitServerId = serverId?.trim().orEmpty()
        if (explicitServerId.isNotEmpty()) {
            ensureConnectedServer(explicitServerId)
            return explicitServerId
        }
        return resolveServerIdForActiveOperations()
    }

    private fun updateState(transform: (AppState) -> AppState) {
        commitState(transform(state))
    }

    private fun commitState(base: AppState) {
        val sortedThreads = threadsByKey.values.sortedByDescending { it.updatedAtEpochMillis }
        val activeKey =
            when {
                base.activeThreadKey != null && threadsByKey.containsKey(base.activeThreadKey) -> base.activeThreadKey
                sortedThreads.isNotEmpty() -> sortedThreads.first().key
                else -> null
            }
        val activeServerId =
            when {
                base.activeServerId != null && serversById.containsKey(base.activeServerId) -> base.activeServerId
                activeKey != null -> activeKey.serverId
                serversById.isNotEmpty() -> serversById.keys.first()
                else -> null
            }
        val nextConnectionStatus =
            when {
                serversById.isEmpty() -> {
                    if (base.connectionStatus == ServerConnectionStatus.ERROR) ServerConnectionStatus.ERROR
                    else ServerConnectionStatus.DISCONNECTED
                }

                base.connectionStatus == ServerConnectionStatus.CONNECTING -> ServerConnectionStatus.CONNECTING
                base.connectionStatus == ServerConnectionStatus.ERROR -> ServerConnectionStatus.ERROR
                else -> ServerConnectionStatus.READY
            }

        val next =
            base.copy(
                connectionStatus = nextConnectionStatus,
                servers = serversById.values.toList(),
                savedServers = loadSavedServersInternal(),
                accountByServerId = LinkedHashMap(accountByServerId),
                activeServerId = activeServerId,
                threads = sortedThreads,
                activeThreadKey = activeKey,
            )
        state = next
        publish(next)
    }

    private fun publish(next: AppState) {
        for (listener in listeners) {
            mainHandler.post { listener(next) }
        }
    }

    private fun <T> deliver(
        callback: ((Result<T>) -> Unit)?,
        result: Result<T>,
    ) {
        if (callback == null) {
            return
        }
        mainHandler.post { callback(result) }
    }

    private fun submit(task: () -> Unit) {
        if (closed) {
            return
        }
        worker.execute {
            if (closed) {
                return@execute
            }
            task()
        }
    }

    private fun persistSavedServersInternal() {
        val payload = JSONArray()
        for (server in serversById.values) {
            val saved = SavedServer.from(server)
            payload.put(
                JSONObject()
                    .put("id", saved.id)
                    .put("name", saved.name)
                    .put("host", saved.host)
                    .put("port", saved.port)
                    .put("source", saved.source)
                    .put("hasCodexServer", saved.hasCodexServer),
            )
        }
        savedServersPreferences
            ?.edit()
            ?.putString(savedServersKey, payload.toString())
            ?.apply()
    }

    private fun loadSavedServersInternal(): List<SavedServer> {
        val raw = savedServersPreferences?.getString(savedServersKey, null) ?: return emptyList()
        val parsed = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        val out = mutableListOf<SavedServer>()
        for (index in 0 until parsed.length()) {
            val item = parsed.optJSONObject(index) ?: continue
            val id = item.optString("id").trim()
            val name = item.optString("name").trim()
            val host = normalizeServerHost(item.optString("host"))
            val port = item.optInt("port", 0)
            val source = item.optString("source").trim()
            val hasCodexServer = item.optBoolean("hasCodexServer", true)
            if (id.isEmpty() || host.isEmpty() || port <= 0) {
                continue
            }
            out +=
                SavedServer(
                    id = id,
                    name = if (name.isEmpty()) host else name,
                    host = host,
                    port = port,
                    source = source,
                    hasCodexServer = hasCodexServer,
                )
        }
        return out
    }
}

private val LOCAL_IMAGE_MARKER_REGEX = Regex("\\[\\[litter_local_image:([^\\]]+)]]")

private fun Any?.asLongOrNull(): Long? {
    return when (this) {
        null, JSONObject.NULL -> null
        is Number -> this.toLong()
        is String -> this.trim().toLongOrNull()
        else -> null
    }
}

private fun Any?.asBooleanOrNull(): Boolean? {
    return when (this) {
        null, JSONObject.NULL -> null
        is Boolean -> this
        is Number -> this.toInt() != 0
        is String -> {
            when (this.trim().lowercase(Locale.ROOT)) {
                "true", "1", "yes", "on" -> true
                "false", "0", "no", "off" -> false
                else -> null
            }
        }

        else -> null
    }
}

private fun JSONObject.sanitizedOptString(key: String): String? {
    if (!has(key)) {
        return null
    }
    val raw = opt(key)
    return when (raw) {
        null, JSONObject.NULL -> null
        else -> raw.toString().trim().takeIf { text -> text.isNotEmpty() && !text.equals("null", ignoreCase = true) }
    }
}

private fun normalizeEpochMillis(raw: Long): Long {
    return if (raw < 1_000_000_000_000L) raw * 1000L else raw
}

private fun JSONObject?.optThreadId(): String? {
    if (this == null) {
        return null
    }
    val keys = arrayOf("threadId", "threadID", "thread_id", "conversationId", "conversationID", "conversation_id")
    for (key in keys) {
        if (!has(key)) {
            continue
        }
        val value = opt(key)
        val threadId = value.asLongOrNull()?.toString() ?: value?.toString()
        val trimmed = threadId?.trim()
        if (!trimmed.isNullOrEmpty()) {
            return trimmed
        }
    }
    return null
}
