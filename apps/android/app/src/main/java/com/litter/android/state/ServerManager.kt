package com.litter.android.state

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import com.google.firebase.messaging.FirebaseMessaging
import com.litter.android.core.bridge.CodexRpcClient
import com.litter.android.push.PushProxyClient
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
        private const val OPEN_CODE_LOG_TAG = "LitterOpenCode"
        private const val OPEN_CODE_POLL_INTERVAL_MS = 1_000L
        private const val OPEN_CODE_POLL_MAX_ATTEMPTS = 30
    }
    private val listeners = CopyOnWriteArrayList<(AppState) -> Unit>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val threadsByKey = LinkedHashMap<ThreadKey, ThreadState>()
    private val transportsByServerId = LinkedHashMap<String, BridgeRpcTransport>()
    private val openCodeClientsByServerId = LinkedHashMap<String, OpenCodeClient>()
    private val serversById = LinkedHashMap<String, ServerConfig>()
    private val accountByServerId = LinkedHashMap<String, AccountState>()
    private val capabilitiesByServerId = LinkedHashMap<String, BackendCapabilities>()
    private val availableModelsByServerId = LinkedHashMap<String, List<ModelOption>>()
    private val selectedModelByServerId = LinkedHashMap<String, ModelSelection>()
    private val slashByServerId = LinkedHashMap<String, List<SlashEntry>>()
    private val agentOptionsByServerId = LinkedHashMap<String, List<OpenCodeAgentOption>>()
    private val selectedAgentByServerId = LinkedHashMap<String, String?>()
    private val liveItemMessageIndices = LinkedHashMap<ThreadKey, MutableMap<String, Int>>()
    private val liveTurnDiffMessageIndices = LinkedHashMap<ThreadKey, MutableMap<String, Int>>()
    private val openCodePollingKeys = HashSet<ThreadKey>()
    private val openCodeInterruptedKeys = HashSet<ThreadKey>()
    private val serversUsingItemNotifications = HashSet<String>()
    private val threadTurnCounts = LinkedHashMap<ThreadKey, Int>()
    private val pendingApprovalsById = LinkedHashMap<String, PendingApproval>()
    private val pendingQuestionsById = LinkedHashMap<String, PendingQuestion>()
    private val agentDirectory = AgentDirectory()

    private val appContext = context?.applicationContext
    private val bundledAuthStore: BundledAuthStore? =
        appContext?.let { ctx -> runCatching { BundledAuthStore(ctx) }.getOrNull() }
    private val savedServerCredentialStore: SavedServerCredentialStore? =
        appContext?.let(::SavedServerCredentialStore)
    private val savedServersPreferences by lazy {
        appContext?.getSharedPreferences("litter_saved_servers", Context.MODE_PRIVATE)
    }
    private val savedServersKey = "servers"
    private val pushRegistrationsByThreadKey = LinkedHashMap<ThreadKey, String>()
    private val pushProxyClient = PushProxyClient()

    @Volatile
    private var state: AppState = AppState(savedServers = loadSavedServersInternal())

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
                refreshOpenCodeMetadataInternal(server.id)
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
                refreshOpenCodeMetadataInternal(connected.id)
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
                val errors = mutableListOf<Throwable>()
                for (savedServer in saved) {
                    runCatching {
                        val cfg = savedServer.toServerConfig()
                        val connectedServer = connectServerInternal(cfg)
                        refreshSessionsInternal(connectedServer.id)
                        refreshOpenCodeMetadataInternal(connectedServer.id)
                        refreshAccountStateInternal(connectedServer.id)
                        connected += connectedServer
                    }.onFailure { errors += it }
                }
                if (connected.isNotEmpty()) {
                    loadModelsInternal(connected.first().id)
                } else if (saved.isNotEmpty() && errors.isNotEmpty()) {
                    // Had saved servers but none connected — mark as error so UI shows offline state
                    updateState {
                        it.copy(
                            connectionStatus = ServerConnectionStatus.ERROR,
                            connectionError = errors.firstOrNull()?.message ?: "Server unreachable",
                        )
                    }
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

    fun removeSavedServer(serverId: String) {
        submit {
            // Remove from in-memory maps if present
            runCatching { transportsByServerId.remove(serverId)?.close() }
            runCatching { openCodeClientsByServerId.remove(serverId)?.close() }
            serversById.remove(serverId)
            accountByServerId.remove(serverId)
            capabilitiesByServerId.remove(serverId)
            slashByServerId.remove(serverId)
            agentOptionsByServerId.remove(serverId)
            selectedAgentByServerId.remove(serverId)
            threadsByKey.entries.removeAll { it.key.serverId == serverId }
            // Persist the updated list (explicitly removing this server ID)
            persistSavedServersInternal(removedServerIds = setOf(serverId))
            updateState { it }
        }
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
                val serverId = current.activeServerId
                val next = current.selectedModel.copy(
                    modelId = modelId ?: current.selectedModel.modelId,
                    reasoningEffort = reasoningEffort ?: current.selectedModel.reasoningEffort,
                )
                if (serverId != null) {
                    selectedModelByServerId[serverId] = next
                }
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

    fun respondToPendingApproval(
        approvalId: String,
        decision: ApprovalDecision,
    ) {
        submit {
            val pending = pendingApprovalsById.remove(approvalId) ?: return@submit
            val server = serversById[pending.serverId]
            if (server?.backendKind == BackendKind.OPENCODE) {
                val reply =
                    when (decision) {
                        ApprovalDecision.ACCEPT -> "once"
                        ApprovalDecision.ACCEPT_FOR_SESSION -> "always"
                        ApprovalDecision.DECLINE, ApprovalDecision.CANCEL -> "reject"
                    }
                requireOpenCodeClient(pending.serverId).replyPermission(pending.requestId, reply)
                commitState(state.copy(connectionError = null))
                return@submit
            }
            val decisionValue = approvalDecisionValue(method = pending.method, decision = decision)
            val transport = transportsByServerId[pending.serverId]
            if (transport != null) {
                transport.respondToServerRequest(
                    requestId = pending.requestId,
                    result = JSONObject().put("decision", decisionValue),
                )
            }
            updateState { it.copy(connectionError = null) }
        }
    }

    fun respondToPendingQuestion(
        questionId: String,
        answers: List<List<String>>,
    ) {
        submit {
            val pending = pendingQuestionsById.remove(questionId) ?: return@submit
            requireOpenCodeClient(pending.serverId).replyQuestion(pending.requestId, answers)
            updateState { it.copy(connectionError = null) }
        }
    }

    fun rejectPendingQuestion(questionId: String) {
        submit {
            val pending = pendingQuestionsById.remove(questionId) ?: return@submit
            requireOpenCodeClient(pending.serverId).rejectQuestion(pending.requestId)
            updateState { it.copy(connectionError = null) }
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
                val resumeCwd = normalizeCwd(cwdForLazyResume) ?: normalizeCwd(existing.cwd)
                if (existing.messages.isEmpty() && resumeCwd != null) {
                    try {
                        resumeThreadInternal(threadKey.serverId, threadKey.threadId, resumeCwd)
                    } catch (error: Throwable) {
                        if (!isMissingRolloutForThread(error)) {
                            throw error
                        }
                        val latest = threadsByKey[threadKey] ?: existing
                        threadsByKey[threadKey] =
                            latest.copy(
                                status = ThreadStatus.READY,
                                lastError = null,
                                updatedAtEpochMillis = System.currentTimeMillis(),
                            )
                        updateState {
                            it.copy(
                                activeThreadKey = threadKey,
                                activeServerId = threadKey.serverId,
                                currentCwd = resumeCwd,
                                connectionError = null,
                            )
                        }
                        threadKey
                    }
                } else {
                    val selectedCwd = normalizeCwd(existing.cwd)
                    updateState {
                        it.copy(
                            activeThreadKey = threadKey,
                            activeServerId = threadKey.serverId,
                            currentCwd = selectedCwd ?: it.currentCwd,
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
                val resolvedCwd = resolveMessageCwd(cwd)
                sendMessageInternal(
                    text = text,
                    cwd = resolvedCwd,
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

    fun selectOpenCodeAgent(
        name: String?,
        serverId: String? = null,
    ) {
        submit {
            val resolvedServerId = resolveServerIdForRequestedOperation(serverId)
            if (serversById[resolvedServerId]?.backendKind != BackendKind.OPENCODE) {
                return@submit
            }
            selectedAgentByServerId[resolvedServerId] = name?.trim()?.takeIf { it.isNotEmpty() }
            updateState { it }
        }
    }

    fun shareActiveThread(onComplete: ((Result<Unit>) -> Unit)? = null) {
        submit {
            val result = runCatching { shareActiveThreadInternal() }
            deliver(onComplete, result)
        }
    }

    fun unshareActiveThread(onComplete: ((Result<Unit>) -> Unit)? = null) {
        submit {
            val result = runCatching { unshareActiveThreadInternal() }
            deliver(onComplete, result)
        }
    }

    fun compactActiveThread(onComplete: ((Result<Unit>) -> Unit)? = null) {
        submit {
            val result = runCatching { compactActiveThreadInternal() }
            deliver(onComplete, result)
        }
    }

    fun undoActiveThread(onComplete: ((Result<Unit>) -> Unit)? = null) {
        submit {
            val result = runCatching { undoActiveThreadInternal() }
            deliver(onComplete, result)
        }
    }

    fun redoActiveThread(onComplete: ((Result<Unit>) -> Unit)? = null) {
        submit {
            val result = runCatching { redoActiveThreadInternal() }
            deliver(onComplete, result)
        }
    }

    fun executeOpenCodeCommand(
        command: String,
        arguments: String,
        cwd: String? = null,
        modelSelection: ModelSelection? = null,
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching {
                val resolvedCwd = resolveMessageCwd(cwd)
                executeOpenCodeCommandInternal(
                    command = command,
                    arguments = arguments,
                    cwd = resolvedCwd,
                    modelSelection = modelSelection ?: state.selectedModel,
                )
            }
            deliver(onComplete, result)
        }
    }

    fun loadOpenCodeMcpStatus(onComplete: ((Result<List<OpenCodeMcpServer>>) -> Unit)? = null) {
        submit {
            val result = runCatching { loadOpenCodeMcpStatusInternal() }
            deliver(onComplete, result)
        }
    }

    fun loadOpenCodeStatus(onComplete: ((Result<OpenCodeStatusSnapshot>) -> Unit)? = null) {
        submit {
            val result = runCatching { loadOpenCodeStatusInternal() }
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

    fun onAppBackground() {
        submit {
            val client = pushProxyClient
            val activeThreads = threadsByKey.filter { (_, thread) -> thread.hasTurnActive }
            if (activeThreads.isEmpty()) return@submit
            val fcmToken = runCatching {
                com.google.android.gms.tasks.Tasks.await(FirebaseMessaging.getInstance().token)
            }.getOrNull() ?: return@submit
            for ((key, thread) in activeThreads) {
                if (pushRegistrationsByThreadKey.containsKey(key)) continue
                val contentState = mapOf<String, Any>(
                    "phase" to "thinking",
                    "turn_id" to (thread.activeTurnId ?: ""),
                    "thread_id" to key.threadId,
                )
                val regId = runCatching {
                    client.register(
                        platform = "fcm",
                        pushToken = fcmToken,
                        contentState = contentState,
                        startTimestamp = System.currentTimeMillis() / 1000,
                    )
                }.getOrNull() ?: continue
                pushRegistrationsByThreadKey[key] = regId
            }
        }
    }

    fun onAppForeground() {
        submit {
            val client = pushProxyClient
            for ((_, regId) in pushRegistrationsByThreadKey) {
                runCatching { client.deregister(regId) }
            }
            pushRegistrationsByThreadKey.clear()
        }
    }

    override fun close() {
        if (closed) {
            return
        }
        closed = true
        runCatching {
            transportsByServerId.values.forEach { it.close() }
            transportsByServerId.clear()
        }
        runCatching {
            openCodeClientsByServerId.values.forEach { it.close() }
            openCodeClientsByServerId.clear()
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
        val normalizedServer =
            if (server.source == ServerSource.LOCAL) {
                // Always resolve the active on-device bridge port instead of trusting discovery defaults.
                ServerConfig.local(codexRpcClient.ensureServerStarted())
            } else if (server.source == ServerSource.BUNDLED) {
                ensureBundledServiceReady()
                ServerConfig.bundled(BundledCodexService.PORT)
            } else {
                server.copy(
                    host =
                        normalizeServerHost(
                            server.host,
                            preserveScheme = server.backendKind == BackendKind.OPENCODE,
                        ),
                )
            }
        val existingServer = serversById[normalizedServer.id]
        val isConnected =
            when (normalizedServer.backendKind) {
                BackendKind.CODEX -> transportsByServerId[normalizedServer.id] != null
                BackendKind.OPENCODE -> openCodeClientsByServerId[normalizedServer.id] != null
            }
        val reset = existingServer != null && isConnected && !sameServer(existingServer, normalizedServer)
        if (existingServer != null && isConnected && !reset) {
            updateState {
                it.copy(
                    activeServerId = normalizedServer.id,
                    connectionStatus = ServerConnectionStatus.READY,
                    connectionError = null,
                )
            }
            return existingServer
        }
        if (reset) {
            clearServer(normalizedServer.id)
        }

        val connectedServer =
            when (normalizedServer.backendKind) {
                BackendKind.CODEX -> {
                    val transport = BridgeRpcTransport(
                        url = websocketUrl(normalizedServer),
                        onNotification = { method, params ->
                            submit {
                                handleNotification(normalizedServer.id, method, params)
                            }
                        },
                        onServerRequest = { requestId, method, params ->
                            handleServerRequestInternal(
                                serverId = normalizedServer.id,
                                requestId = requestId,
                                method = method,
                                params = params,
                            )
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
                    capabilitiesByServerId[normalizedServer.id] =
                        BackendCapabilities(
                            supportsAuthManagement = true,
                            supportsExperimentalFeatures = true,
                            supportsSkillListing = true,
                            supportsDirectoryBrowser = true,
                            supportsQuestions = false,
                        )
                    normalizedServer
                }

                BackendKind.OPENCODE -> {
                    val initialClient = OpenCodeClient(normalizedServer)
                    initialClient.connect()
                    val directory = normalizedServer.directory ?: initialClient.currentDirectory()
                    initialClient.close()
                    val scopedServer = normalizedServer.copy(directory = directory)
                    Log.d(
                        OPEN_CODE_LOG_TAG,
                        "connect server=${scopedServer.id} host=${scopedServer.host}:${scopedServer.port} directory=${scopedServer.directory.orEmpty()}",
                    )
                    val client = OpenCodeClient(scopedServer)
                    client.connect()
                    client.subscribeEvents { event ->
                        submit {
                            handleOpenCodeEvent(scopedServer.id, event)
                        }
                    }
                    openCodeClientsByServerId[scopedServer.id]?.close()
                    openCodeClientsByServerId[scopedServer.id] = client
                    capabilitiesByServerId[scopedServer.id] =
                        BackendCapabilities(
                            supportsAuthManagement = false,
                            supportsExperimentalFeatures = false,
                            supportsSkillListing = true,
                            supportsDirectoryBrowser = false,
                            supportsQuestions = true,
                        )
                    scopedServer
                }
            }

        serversById[connectedServer.id] = connectedServer
        accountByServerId.putIfAbsent(connectedServer.id, AccountState())
        persistSavedServersInternal()

        updateState {
            val preferredCwd =
                if (connectedServer.source == ServerSource.BUNDLED) {
                    preferredDirectoryRootForServer(connectedServer.id)
                } else if (connectedServer.backendKind == BackendKind.OPENCODE) {
                    connectedServer.directory ?: it.currentCwd
                } else {
                    it.currentCwd
                }
            it.copy(
                connectionStatus = ServerConnectionStatus.READY,
                connectionError = null,
                activeServerId = connectedServer.id,
                activeThreadKey =
                    if (reset) {
                        null
                    } else {
                        it.activeThreadKey?.takeIf { key -> key.serverId == connectedServer.id }
                    },
                currentCwd = preferredCwd,
            )
        }

        return connectedServer
    }

    private fun disconnectInternal(serverId: String?) {
        if (serverId == null) {
            transportsByServerId.values.forEach { runCatching { it.close() } }
            transportsByServerId.clear()
            openCodeClientsByServerId.values.forEach { runCatching { it.close() } }
            openCodeClientsByServerId.clear()
            serversById.clear()
            accountByServerId.clear()
            capabilitiesByServerId.clear()
            availableModelsByServerId.clear()
            selectedModelByServerId.clear()
            slashByServerId.clear()
            agentOptionsByServerId.clear()
            selectedAgentByServerId.clear()
            threadsByKey.clear()
            liveItemMessageIndices.clear()
            liveTurnDiffMessageIndices.clear()
            serversUsingItemNotifications.clear()
            threadTurnCounts.clear()
            pendingApprovalsById.clear()
            pendingQuestionsById.clear()
            agentDirectory.clear()
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
        runCatching { openCodeClientsByServerId.remove(serverId)?.close() }
        val removedServer = serversById.remove(serverId)
        accountByServerId.remove(serverId)
        capabilitiesByServerId.remove(serverId)
        availableModelsByServerId.remove(serverId)
        selectedModelByServerId.remove(serverId)
        slashByServerId.remove(serverId)
        agentOptionsByServerId.remove(serverId)
        selectedAgentByServerId.remove(serverId)
        threadsByKey.entries.removeAll { it.key.serverId == serverId }
        liveItemMessageIndices.keys.removeAll { it.serverId == serverId }
        liveTurnDiffMessageIndices.keys.removeAll { it.serverId == serverId }
        serversUsingItemNotifications.remove(serverId)
        threadTurnCounts.keys.removeAll { it.serverId == serverId }
        pendingApprovalsById.values.removeAll { it.serverId == serverId }
        pendingQuestionsById.values.removeAll { it.serverId == serverId }
        agentDirectory.removeServer(serverId)

        if (removedServer?.source == ServerSource.LOCAL && serversById.values.none { it.source == ServerSource.LOCAL }) {
            runCatching { codexRpcClient.stop() }
        }

        if (removedServer?.source == ServerSource.BUNDLED && serversById.values.none { it.source == ServerSource.BUNDLED }) {
            runCatching { appContext?.stopService(android.content.Intent(appContext, BundledCodexService::class.java)) }
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
        persistSavedServersInternal(removedServerIds = setOf(serverId))
    }

    private fun clearServer(serverId: String): ServerConfig? {
        runCatching { transportsByServerId.remove(serverId)?.close() }
        runCatching { openCodeClientsByServerId.remove(serverId)?.close() }
        val removed = serversById.remove(serverId)
        accountByServerId.remove(serverId)
        capabilitiesByServerId.remove(serverId)
        availableModelsByServerId.remove(serverId)
        selectedModelByServerId.remove(serverId)
        slashByServerId.remove(serverId)
        agentOptionsByServerId.remove(serverId)
        selectedAgentByServerId.remove(serverId)
        threadsByKey.entries.removeAll { it.key.serverId == serverId }
        liveItemMessageIndices.keys.removeAll { it.serverId == serverId }
        liveTurnDiffMessageIndices.keys.removeAll { it.serverId == serverId }
        serversUsingItemNotifications.remove(serverId)
        threadTurnCounts.keys.removeAll { it.serverId == serverId }
        pendingApprovalsById.values.removeAll { it.serverId == serverId }
        pendingQuestionsById.values.removeAll { it.serverId == serverId }
        agentDirectory.removeServer(serverId)
        return removed
    }

    private fun sameServer(
        left: ServerConfig,
        right: ServerConfig,
    ): Boolean {
        return left.host == right.host &&
            left.port == right.port &&
            left.source == right.source &&
            left.backendKind == right.backendKind &&
            left.hasCodexServer == right.hasCodexServer &&
            left.username == right.username &&
            left.password == right.password &&
            left.directory == right.directory &&
            left.websocketUrl == right.websocketUrl
    }

    private fun websocketUrl(server: ServerConfig): String {
        server.websocketUrl?.let { return it }
        val host = normalizeServerHost(server.host)
        val normalizedHost =
            if (host.contains(':') && !host.startsWith("[") && !host.endsWith("]")) {
                "[$host]"
            } else {
                host
            }
        return "ws://$normalizedHost:${server.port}"
    }

    private fun normalizeServerHost(
        rawHost: String,
        preserveScheme: Boolean = false,
    ): String {
        var host = rawHost.trim()
        if (host.isEmpty()) {
            return "127.0.0.1"
        }

        if (preserveScheme && host.contains("://")) {
            return runCatching {
                val uri = URI(host)
                val scheme = uri.scheme?.trim()?.lowercase().orEmpty().ifEmpty { "http" }
                val authority =
                    uri.rawAuthority?.trim()?.takeIf { it.isNotEmpty() }
                        ?: uri.host?.trim()
                        ?: host.substringAfter("://", host).substringBefore('/').trim()
                val path =
                    uri.rawPath
                        ?.trim()
                        ?.trimEnd('/')
                        ?.takeIf { it.isNotEmpty() && it != "/" }
                        .orEmpty()
                if (authority.isEmpty()) {
                    host.trimEnd('/')
                } else {
                    "$scheme://$authority$path"
                }
            }.getOrDefault(host.trimEnd('/'))
        }

        if (host.contains("://")) {
            host =
                runCatching {
                    val parsed = URI(host)
                    val parsedHost = parsed.host?.trim()
                    val port = parsed.port.takeIf { it > 0 }?.let { ":$it" }.orEmpty()
                    val authority =
                        when {
                            !parsedHost.isNullOrEmpty() -> parsedHost + port
                            else -> parsed.path?.trim()?.trimStart('/')
                        }
                    authority
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
            if (server.backendKind == BackendKind.OPENCODE) {
                refreshOpenCodeSessions(server)
                continue
            }
            val transport = requireTransport(server.id)
            val authoritativeKeys = LinkedHashSet<ThreadKey>()
            val missingRemoteCwdKeys = LinkedHashSet<ThreadKey>()
            var cursor: String? = null
            val seenCursors = LinkedHashSet<String>()
            while (true) {
                val response = transport.request(
                    method = "thread/list",
                    params = JSONObject()
                        .put("cursor", cursor ?: JSONObject.NULL)
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
                    authoritativeKeys += key
                    val existing = threadsByKey[key]
                    val remoteCwd = parseThreadCwd(item)
                    val preview = item.optString("preview").trim().ifBlank {
                        item.optString("name").trim().ifBlank {
                            existing?.preview ?: "Session $threadId"
                        }
                    }
                    val parentThreadId = parseParentThreadId(item) ?: existing?.parentThreadId
                    val rootThreadId = parseRootThreadId(item) ?: existing?.rootThreadId
                    val cwd =
                        resolveThreadCwd(
                            serverId = server.id,
                            threadId = threadId,
                            responseCwd = remoteCwd,
                            existing = existing,
                            parentThreadId = parentThreadId,
                            rootThreadId = rootThreadId,
                        )
                    if (remoteCwd.isNullOrBlank()) {
                        missingRemoteCwdKeys += key
                    }
                    val modelProvider = parseModelProvider(item).ifBlank { existing?.modelProvider.orEmpty() }
                    val agentId = parseAgentId(item)
                    val resolvedAgent =
                        upsertAgentIdentity(
                            serverId = server.id,
                            threadId = threadId,
                            agentId = agentId,
                            nickname = parseAgentNickname(item) ?: existing?.agentNickname,
                            role = parseAgentRole(item) ?: existing?.agentRole,
                        )
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
                            agentNickname = resolvedAgent?.nickname ?: existing?.agentNickname,
                            agentRole = resolvedAgent?.role ?: existing?.agentRole,
                            updatedAtEpochMillis = maxOf(updatedAtEpochMillis, existing?.updatedAtEpochMillis ?: 0L),
                            activeTurnId = existing?.activeTurnId,
                            lastError = existing?.lastError,
                        )
                    threadTurnCounts[key] = threadTurnCounts[key] ?: inferredTurnCountFromMessages(existing?.messages.orEmpty())
                }

                val nextCursor = extractString(response, "nextCursor", "next_cursor")
                if (nextCursor.isNullOrBlank() || !seenCursors.add(nextCursor)) {
                    break
                }
                cursor = nextCursor
            }

            if (missingRemoteCwdKeys.isNotEmpty()) {
                var changed: Boolean
                do {
                    changed = false
                    for (key in missingRemoteCwdKeys) {
                        val thread = threadsByKey[key] ?: continue
                        val parentCwd =
                            thread.parentThreadId
                                ?.let { parentId -> normalizeCwd(threadsByKey[ThreadKey(serverId = server.id, threadId = parentId)]?.cwd) }
                        val rootCwd =
                            thread.rootThreadId
                                ?.takeIf { rootId -> rootId != key.threadId }
                                ?.let { rootId -> normalizeCwd(threadsByKey[ThreadKey(serverId = server.id, threadId = rootId)]?.cwd) }
                        val inheritedCwd = parentCwd ?: rootCwd
                        if (inheritedCwd != null && inheritedCwd != thread.cwd) {
                            threadsByKey[key] = thread.copy(cwd = inheritedCwd)
                            changed = true
                        }
                    }
                } while (changed)
            }

            val placeholderKeysToPrune =
                computePlaceholderKeysToPrune(
                    serverId = server.id,
                    authoritativeKeys = authoritativeKeys,
                    activeThreadKey = state.activeThreadKey,
                    threadsByKey = threadsByKey,
                )
            placeholderKeysToPrune.forEach { key ->
                threadsByKey.remove(key)
                threadTurnCounts.remove(key)
                liveItemMessageIndices.remove(key)
                liveTurnDiffMessageIndices.remove(key)
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
        if (serversById[targetServerId]?.backendKind == BackendKind.OPENCODE) {
            val parsed = loadOpenCodeModelsInternal(targetServerId)
            updateState { current ->
                val selectedModel = chooseModelSelection(selectedModelByServerId[targetServerId] ?: current.selectedModel, parsed)
                availableModelsByServerId[targetServerId] = parsed
                selectedModelByServerId[targetServerId] = selectedModel
                current.copy(
                    availableModels = parsed,
                    selectedModel = selectedModel,
                    activeServerId = targetServerId,
                )
            }
            return parsed
        }
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
            val selectedModel = chooseModelSelection(selectedModelByServerId[targetServerId] ?: current.selectedModel, parsed)
            availableModelsByServerId[targetServerId] = parsed
            selectedModelByServerId[targetServerId] = selectedModel
            current.copy(
                availableModels = parsed,
                selectedModel = selectedModel,
                activeServerId = targetServerId,
            )
        }
        return parsed
    }

    private fun refreshAccountStateInternal(serverId: String): AccountState {
        if (serversById[serverId]?.backendKind == BackendKind.OPENCODE) {
            val accountState = AccountState(status = AuthStatus.NOT_LOGGED_IN)
            accountByServerId[serverId] = accountState
            updateState {
                it.copy(
                    accountByServerId = LinkedHashMap(accountByServerId),
                    activeServerId = serverId,
                )
            }
            return accountState
        }
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
        requestId: String,
        method: String,
        params: JSONObject?,
    ): ServerRequestHandlingResult {
        val pendingApproval = parsePendingApprovalRequest(serverId, requestId, method, params)
        if (pendingApproval != null) {
            pendingApprovalsById[pendingApproval.id] = pendingApproval
            updateState { it.copy(connectionError = null) }
            return ServerRequestHandlingResult.Deferred
        }

        if (method != "account/chatgptAuthTokens/refresh") {
            return ServerRequestHandlingResult.Unhandled
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

            ServerRequestHandlingResult.Immediate(
                JSONObject()
                    .put("accessToken", refreshed.accessToken)
                    .put("chatgptAccountId", info.accountId)
                    .put("chatgptPlanType", info.planType ?: JSONObject.NULL),
            )
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

    private fun parsePendingApprovalRequest(
        serverId: String,
        requestId: String,
        method: String,
        params: JSONObject?,
    ): PendingApproval? {
        val approvalId = "$serverId:$requestId"
        return when (method) {
            "item/commandExecution/requestApproval" -> {
                val threadId = extractThreadIdForIdentity(params, "threadId", "thread_id", "conversationId", "conversation_id")
                val requester = resolveAgentIdentity(serverId = serverId, threadId = threadId, params = params)
                PendingApproval(
                    id = approvalId,
                    requestId = requestId,
                    serverId = serverId,
                    method = method,
                    kind = ApprovalKind.COMMAND_EXECUTION,
                    threadId = threadId,
                    turnId = extractString(params, "turnId", "turn_id"),
                    itemId = extractString(params, "itemId", "item_id", "callId", "call_id", "cmdId", "cmd_id"),
                    command = commandTextFromApprovalParams(params),
                    cwd = extractString(params, "cwd"),
                    reason = extractString(params, "reason"),
                    grantRoot = null,
                    requesterAgentNickname = requester.nickname,
                    requesterAgentRole = requester.role,
                )
            }

            "item/fileChange/requestApproval" -> {
                val threadId = extractThreadIdForIdentity(params, "threadId", "thread_id", "conversationId", "conversation_id")
                val requester = resolveAgentIdentity(serverId = serverId, threadId = threadId, params = params)
                PendingApproval(
                    id = approvalId,
                    requestId = requestId,
                    serverId = serverId,
                    method = method,
                    kind = ApprovalKind.FILE_CHANGE,
                    threadId = threadId,
                    turnId = extractString(params, "turnId", "turn_id"),
                    itemId = extractString(params, "itemId", "item_id", "callId", "call_id", "patchId", "patch_id"),
                    command = null,
                    cwd = null,
                    reason = extractString(params, "reason"),
                    grantRoot = extractString(params, "grantRoot", "grant_root"),
                    requesterAgentNickname = requester.nickname,
                    requesterAgentRole = requester.role,
                )
            }

            "execCommandApproval" -> {
                val threadId = extractThreadIdForIdentity(params, "conversationId", "conversation_id", "threadId", "thread_id")
                val requester = resolveAgentIdentity(serverId = serverId, threadId = threadId, params = params)
                PendingApproval(
                    id = approvalId,
                    requestId = requestId,
                    serverId = serverId,
                    method = method,
                    kind = ApprovalKind.COMMAND_EXECUTION,
                    threadId = threadId,
                    turnId = null,
                    itemId = extractString(params, "approvalId", "callId", "cmdId"),
                    command = commandTextFromApprovalParams(params),
                    cwd = extractString(params, "cwd"),
                    reason = extractString(params, "reason"),
                    grantRoot = null,
                    requesterAgentNickname = requester.nickname,
                    requesterAgentRole = requester.role,
                )
            }

            "applyPatchApproval" -> {
                val threadId = extractThreadIdForIdentity(params, "conversationId", "conversation_id", "threadId", "thread_id")
                val requester = resolveAgentIdentity(serverId = serverId, threadId = threadId, params = params)
                PendingApproval(
                    id = approvalId,
                    requestId = requestId,
                    serverId = serverId,
                    method = method,
                    kind = ApprovalKind.FILE_CHANGE,
                    threadId = threadId,
                    turnId = null,
                    itemId = extractString(params, "callId", "patchId"),
                    command = null,
                    cwd = null,
                    reason = extractString(params, "reason"),
                    grantRoot = extractString(params, "grantRoot", "grant_root"),
                    requesterAgentNickname = requester.nickname,
                    requesterAgentRole = requester.role,
                )
            }

            else -> null
        }
    }

    private fun commandTextFromApprovalParams(params: JSONObject?): String? {
        val direct = extractString(params, "command")
        if (!direct.isNullOrEmpty()) {
            return direct
        }
        val command = params?.opt("command")
        return when (command) {
            is JSONArray -> {
                val parts = ArrayList<String>(command.length())
                for (index in 0 until command.length()) {
                    val token = command.opt(index)?.toString()?.trim().orEmpty()
                    if (token.isNotEmpty()) {
                        parts += token
                    }
                }
                parts.joinToString(separator = " ").ifEmpty { null }
            }

            else -> null
        }
    }

    private fun approvalDecisionValue(
        method: String,
        decision: ApprovalDecision,
    ): String {
        return when (method) {
            "execCommandApproval", "applyPatchApproval" -> {
                when (decision) {
                    ApprovalDecision.ACCEPT -> "approved"
                    ApprovalDecision.ACCEPT_FOR_SESSION -> "approved_for_session"
                    ApprovalDecision.DECLINE -> "denied"
                    ApprovalDecision.CANCEL -> "abort"
                }
            }

            else -> {
                when (decision) {
                    ApprovalDecision.ACCEPT -> "accept"
                    ApprovalDecision.ACCEPT_FOR_SESSION -> "acceptForSession"
                    ApprovalDecision.DECLINE -> "decline"
                    ApprovalDecision.CANCEL -> "cancel"
                }
            }
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
            out[decodeUrlComponent(key)] =
                decodeUrlComponent(value)
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

    private fun decodeUrlComponent(value: String): String =
        URLDecoder.decode(value, StandardCharsets.UTF_8.toString())

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
        if (transportsByServerId.isEmpty() && openCodeClientsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val targetServerId = resolveServerIdForRequestedOperation(serverId)
        val targetServer = ensureConnectedServer(targetServerId)
        if (targetServer.backendKind == BackendKind.OPENCODE) {
            return targetServer.directory?.trim()?.ifBlank { null }
                ?: state.currentCwd.ifBlank { "/" }
        }
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
        if (transportsByServerId.isEmpty() && openCodeClientsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val targetServerId = resolveServerIdForRequestedOperation(serverId)
        val targetServer = ensureConnectedServer(targetServerId)
        if (targetServer.backendKind == BackendKind.OPENCODE) {
            throw IllegalStateException("Directory browsing is not supported for OpenCode servers")
        }
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
        if (transportsByServerId.isEmpty() && openCodeClientsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val serverId = resolveServerIdForActiveOperations()
        if (ensureConnectedServer(serverId).backendKind == BackendKind.OPENCODE) {
            throw IllegalStateException("File search is not supported for OpenCode servers")
        }
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
        if (transportsByServerId.isEmpty() && openCodeClientsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val targetServerId = resolveServerIdForRequestedOperation(serverId)
        val server = ensureConnectedServer(targetServerId)
        if (server.backendKind == BackendKind.OPENCODE) {
            val created = requireOpenCodeClient(targetServerId).createSession()
            val threadId = created.optString("id").trim()
            if (threadId.isEmpty()) {
                throw IllegalStateException("OpenCode session/create returned no session id")
            }
            val key = ThreadKey(server.id, threadId)
            threadsByKey[key] =
                ThreadState(
                    key = key,
                    serverName = server.name,
                    serverSource = server.source,
                    status = ThreadStatus.READY,
                    messages = emptyList(),
                    preview = created.optString("title").trim(),
                    cwd = server.directory ?: cwd,
                    modelProvider = "",
                    parentThreadId = created.optString("parentID").trim().ifBlank { null },
                    rootThreadId = null,
                    updatedAtEpochMillis = parseOpenCodeUpdatedAt(created),
                    activeTurnId = null,
                    lastError = null,
                )
            threadTurnCounts[key] = 0
            updateState {
                it.copy(
                    activeThreadKey = key,
                    activeServerId = server.id,
                    currentCwd = server.directory ?: cwd,
                    connectionStatus = ServerConnectionStatus.READY,
                    connectionError = null,
                )
            }
            return key
        }
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
        val resolvedAgent =
            upsertAgentIdentity(
                serverId = server.id,
                threadId = threadId,
                agentId = parseAgentId(threadObj),
                nickname = parseAgentNickname(threadObj) ?: existing?.agentNickname,
                role = parseAgentRole(threadObj) ?: existing?.agentRole,
            )
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
                agentNickname = resolvedAgent?.nickname ?: existing?.agentNickname,
                agentRole = resolvedAgent?.role ?: existing?.agentRole,
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
        if (transportsByServerId.isEmpty() && openCodeClientsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val server = ensureConnectedServer(serverId)
        val key = ThreadKey(server.id, threadId)
        val existing = threadsByKey[key]
        if (server.backendKind == BackendKind.OPENCODE) {
            val messages = mapOpenCodeMessages(requireOpenCodeClient(serverId).loadMessages(threadId))
            val now = System.currentTimeMillis()
            threadsByKey[key] =
                ThreadState(
                    key = key,
                    serverName = server.name,
                    serverSource = server.source,
                    status = ThreadStatus.READY,
                    messages = messages,
                    preview = derivePreview(messages, existing?.preview),
                    cwd = server.directory ?: cwd,
                    modelProvider = existing?.modelProvider.orEmpty(),
                    parentThreadId = existing?.parentThreadId,
                    rootThreadId = existing?.rootThreadId,
                    updatedAtEpochMillis = now,
                    activeTurnId = null,
                    lastError = null,
                )
            threadTurnCounts[key] = inferredTurnCountFromMessages(messages)
            updateState {
                it.copy(
                    activeThreadKey = key,
                    activeServerId = server.id,
                    currentCwd = server.directory ?: cwd,
                )
            }
            return key
        }
        threadsByKey[key] =
            ThreadState(
                key = key,
                serverName = server.name,
                serverSource = server.source,
                status = ThreadStatus.CONNECTING,
                messages = existing?.messages ?: emptyList(),
                preview = existing?.preview ?: "",
                cwd = cwd,
                modelProvider = existing?.modelProvider.orEmpty(),
                parentThreadId = existing?.parentThreadId,
                rootThreadId = existing?.rootThreadId,
                agentNickname = existing?.agentNickname,
                agentRole = existing?.agentRole,
                updatedAtEpochMillis = System.currentTimeMillis(),
                activeTurnId = existing?.activeTurnId,
                lastError = null,
            )
        updateState { it.copy(activeThreadKey = key, activeServerId = serverId, currentCwd = cwd) }

        try {
            val response = resumeThreadWithFallback(serverId = serverId, threadId = threadId, cwd = cwd)
            val threadObj = response.optJSONObject("thread") ?: JSONObject()
            val resolvedAgent =
                upsertAgentIdentity(
                    serverId = server.id,
                    threadId = threadId,
                    agentId = parseAgentId(threadObj),
                    nickname = parseAgentNickname(threadObj) ?: existing?.agentNickname,
                    role = parseAgentRole(threadObj) ?: existing?.agentRole,
                )
            val restored =
                restoreMessages(
                    threadObject = threadObj,
                    serverId = serverId,
                    defaultAgentNickname = resolvedAgent?.nickname ?: existing?.agentNickname,
                    defaultAgentRole = resolvedAgent?.role ?: existing?.agentRole,
                )
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
                    agentNickname = resolvedAgent?.nickname ?: existing?.agentNickname,
                    agentRole = resolvedAgent?.role ?: existing?.agentRole,
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
        if (serversById[key.serverId]?.backendKind == BackendKind.OPENCODE) {
            throw IllegalStateException("Review is not supported for OpenCode servers")
        }
        requireTransport(key.serverId).request(
            method = "review/start",
            params = JSONObject()
                .put("threadId", key.threadId)
                .put("target", JSONObject().put("type", "uncommittedChanges"))
                .put("delivery", "inline"),
        )
    }

    private fun shareActiveThreadInternal() {
        val key = state.activeThreadKey ?: throw IllegalStateException("No active thread")
        val server = ensureConnectedServer(key.serverId)
        if (server.backendKind != BackendKind.OPENCODE) {
            throw IllegalStateException("Share is only supported for OpenCode servers")
        }
        requireOpenCodeClient(key.serverId).shareSession(key.threadId)
        refreshSessionsInternal(key.serverId)
    }

    private fun unshareActiveThreadInternal() {
        val key = state.activeThreadKey ?: throw IllegalStateException("No active thread")
        val server = ensureConnectedServer(key.serverId)
        if (server.backendKind != BackendKind.OPENCODE) {
            throw IllegalStateException("Unshare is only supported for OpenCode servers")
        }
        requireOpenCodeClient(key.serverId).unshareSession(key.threadId)
        refreshSessionsInternal(key.serverId)
    }

    private fun compactActiveThreadInternal() {
        val key = state.activeThreadKey ?: throw IllegalStateException("No active thread")
        val server = ensureConnectedServer(key.serverId)
        if (server.backendKind != BackendKind.OPENCODE) {
            throw IllegalStateException("Compact is only supported for OpenCode servers")
        }
        val model = parseOpenCodeModel(state.selectedModel.modelId)
            ?: throw IllegalStateException("Select an OpenCode model before compacting the session")
        requireOpenCodeClient(key.serverId).summarizeSession(
            sessionId = key.threadId,
            providerId = model.first,
            modelId = model.second,
        )
        refreshSessionsInternal(key.serverId)
    }

    private fun undoActiveThreadInternal() {
        val key = state.activeThreadKey ?: throw IllegalStateException("No active thread")
        val server = ensureConnectedServer(key.serverId)
        if (server.backendKind != BackendKind.OPENCODE) {
            throw IllegalStateException("Undo is only supported for OpenCode servers")
        }
        val messages = requireOpenCodeClient(key.serverId).loadMessages(key.threadId)
        var targetId: String? = null
        for (index in messages.length() - 1 downTo 0) {
            val item = messages.optJSONObject(index) ?: continue
            val info = item.optJSONObject("info") ?: continue
            if (info.optString("role").trim() != "user") {
                continue
            }
            targetId = info.optString("id").trim().ifEmpty { null }
            if (targetId != null) {
                break
            }
        }
        val messageId = targetId ?: throw IllegalStateException("No user message available to undo")
        requireOpenCodeClient(key.serverId).revertSession(key.threadId, messageId)
        val existing = threadsByKey[key]
        if (existing != null) {
            threadsByKey[key] =
                existing.copy(
                    status = ThreadStatus.READY,
                    activeTurnId = null,
                    updatedAtEpochMillis = System.currentTimeMillis(),
                )
        }
        syncActiveThreadFromServerInternal()
    }

    private fun redoActiveThreadInternal() {
        val key = state.activeThreadKey ?: throw IllegalStateException("No active thread")
        val server = ensureConnectedServer(key.serverId)
        if (server.backendKind != BackendKind.OPENCODE) {
            throw IllegalStateException("Redo is only supported for OpenCode servers")
        }
        requireOpenCodeClient(key.serverId).unrevertSession(key.threadId)
        syncActiveThreadFromServerInternal()
    }

    private fun executeOpenCodeCommandInternal(
        command: String,
        arguments: String,
        cwd: String,
        modelSelection: ModelSelection,
    ) {
        if (openCodeClientsByServerId.isEmpty() && transportsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val key = state.activeThreadKey ?: startThreadInternal(cwd, modelSelection)
        val server = ensureConnectedServer(key.serverId)
        if (server.backendKind != BackendKind.OPENCODE) {
            throw IllegalStateException("OpenCode slash commands require an OpenCode server")
        }
        val cleanCommand = command.trim().removePrefix("/")
        if (cleanCommand.isEmpty()) {
            throw IllegalArgumentException("Command name is required")
        }
        val cleanArguments = arguments.trim()
        val preview = buildString {
            append('/')
            append(cleanCommand)
            if (cleanArguments.isNotEmpty()) {
                append(' ')
                append(cleanArguments)
            }
        }
        val existing = threadsByKey[key] ?: throw IllegalStateException("Unable to resolve active thread")
        threadsByKey[key] =
            existing.copy(
                status = ThreadStatus.THINKING,
                messages = existing.messages + ChatMessage(role = MessageRole.USER, text = preview, isFromUserTurnBoundary = true),
                preview = preview.take(120),
                cwd = cwd,
                updatedAtEpochMillis = System.currentTimeMillis(),
                lastError = null,
            )
        updateState { it.copy(activeThreadKey = key, activeServerId = key.serverId, currentCwd = cwd, connectionError = null) }
        val model = modelSelection.modelId ?: state.selectedModel.modelId
        val agent = selectedAgentByServerId[key.serverId]?.trim()?.takeIf { it.isNotEmpty() }
        try {
            requireOpenCodeClient(key.serverId).executeCommand(
                sessionId = key.threadId,
                command = cleanCommand,
                arguments = cleanArguments,
                model = model,
                agent = agent,
            )
            refreshOpenCodeInteractions(key.serverId)
        } catch (error: Throwable) {
            val latest = threadsByKey[key]
            if (latest != null) {
                threadsByKey[key] =
                    latest.copy(
                        status = ThreadStatus.ERROR,
                        lastError = error.message ?: "Failed to run slash command",
                        updatedAtEpochMillis = System.currentTimeMillis(),
                    )
            }
            updateState { it.copy(connectionError = error.message ?: "Failed to run slash command") }
            throw error
        }
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
        if (serversById[key.serverId]?.backendKind == BackendKind.OPENCODE) {
            requireOpenCodeClient(key.serverId).renameSession(key.threadId, trimmed)
        } else {
            requireTransport(key.serverId).request(
                method = "thread/name/set",
                params = JSONObject().put("threadId", key.threadId).put("name", trimmed),
            )
        }

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
        if (server.backendKind == BackendKind.OPENCODE) {
            val forked = requireOpenCodeClient(server.id).forkSession(sourceKey.threadId)
            val forkedThreadId = forked.optString("id").trim()
            if (forkedThreadId.isEmpty()) {
                throw IllegalStateException("OpenCode session/fork returned no session id")
            }
            val forkedKey = ThreadKey(server.id, forkedThreadId)
            threadsByKey[forkedKey] =
                ThreadState(
                    key = forkedKey,
                    serverName = server.name,
                    serverSource = server.source,
                    status = ThreadStatus.READY,
                    messages = emptyList(),
                    preview = forked.optString("title").trim().ifBlank { sourceThread.preview },
                    cwd = server.directory ?: sourceThread.cwd,
                    modelProvider = sourceThread.modelProvider,
                    parentThreadId = forked.optString("parentID").trim().ifBlank { sourceKey.threadId },
                    rootThreadId = sourceThread.rootThreadId ?: sourceThread.parentThreadId ?: sourceKey.threadId,
                    updatedAtEpochMillis = parseOpenCodeUpdatedAt(forked),
                    activeTurnId = null,
                    lastError = null,
                )
            threadTurnCounts[forkedKey] = 0
            updateState {
                it.copy(
                    activeThreadKey = forkedKey,
                    activeServerId = server.id,
                    currentCwd = server.directory ?: sourceThread.cwd,
                    connectionError = null,
                )
            }
            return forkedKey
        }
        val sourceCwd = sourceThread.cwd.ifBlank { defaultWorkingDirectory() }
        val response = forkThreadWithFallback(server.id, sourceKey.threadId, sourceCwd)
        val threadObj = response.optJSONObject("thread") ?: JSONObject()
        val forkedThreadId = threadObj.optString("id").trim()
        if (forkedThreadId.isEmpty()) {
            throw IllegalStateException("thread/fork returned no thread id")
        }
        val resolvedAgent =
            upsertAgentIdentity(
                serverId = server.id,
                threadId = forkedThreadId,
                agentId = parseAgentId(threadObj),
                nickname = parseAgentNickname(threadObj) ?: sourceThread.agentNickname,
                role = parseAgentRole(threadObj) ?: sourceThread.agentRole,
            )

        val restored =
            restoreMessages(
                threadObject = threadObj,
                serverId = sourceKey.serverId,
                defaultAgentNickname = resolvedAgent?.nickname ?: sourceThread.agentNickname,
                defaultAgentRole = resolvedAgent?.role ?: sourceThread.agentRole,
            )
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
                agentNickname = resolvedAgent?.nickname ?: sourceThread.agentNickname,
                agentRole = resolvedAgent?.role ?: sourceThread.agentRole,
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
        if (serversById[threadKey.serverId]?.backendKind == BackendKind.OPENCODE) {
            requireOpenCodeClient(threadKey.serverId).archiveSession(threadKey.threadId, archived = true)
        } else {
            requireTransport(threadKey.serverId).request(
                method = "thread/archive",
                params = JSONObject().put("threadId", threadKey.threadId),
            )
        }
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
                    ?.let { key -> normalizeCwd(threadsByKey[key]?.cwd) }
                    ?: normalizeCwd(it.currentCwd)
                    ?: defaultWorkingDirectory()
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
        val existing = threadsByKey[key] ?: throw IllegalStateException("Unable to resolve thread")
        val restored =
            restoreMessages(
                threadObject = threadObj,
                serverId = key.serverId,
                defaultAgentNickname = parseAgentNickname(threadObj) ?: existing.agentNickname,
                defaultAgentRole = parseAgentRole(threadObj) ?: existing.agentRole,
            )
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
        if (serversById[serverId]?.backendKind == BackendKind.OPENCODE) {
            throw IllegalStateException("Experimental features are not supported for OpenCode servers")
        }
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
        if (serversById[serverId]?.backendKind == BackendKind.OPENCODE) {
            throw IllegalStateException("Experimental features are not supported for OpenCode servers")
        }
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
        if (serversById[serverId]?.backendKind == BackendKind.OPENCODE) {
            val items = requireOpenCodeClient(serverId).listSkills()
            val parsed = ArrayList<SkillMetadata>(items.length())
            for (index in 0 until items.length()) {
                val item = items.optJSONObject(index) ?: continue
                val name = item.optString("name").trim()
                val path = item.optString("location").trim()
                if (name.isEmpty() || path.isEmpty()) {
                    continue
                }
                parsed +=
                    SkillMetadata(
                        name = name,
                        description = item.optString("description").trim(),
                        path = path,
                        scope = "opencode",
                        enabled = true,
                    )
            }
            return parsed
        }
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

        if (transportsByServerId.isEmpty() && openCodeClientsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }

        val key = state.activeThreadKey ?: startThreadInternal(cwd, modelSelection)
        val serverId = key.serverId
        if (serversById[serverId]?.backendKind == BackendKind.OPENCODE) {
            sendOpenCodeMessageInternal(
                key = key,
                parts = buildOpenCodePromptParts(
                    text = trimmed,
                    localImageDataUrl = localImageDataUrl,
                    localImagePath = normalizedLocalImagePath,
                ),
                cwd = cwd,
                userVisibleText = userVisibleText,
                modelSelection = modelSelection,
            )
            return
        }
        ensureAuthenticatedForTurns(serverId)
        val existing = threadsByKey[key] ?: throw IllegalStateException("Unable to resolve active thread")
        val now = System.currentTimeMillis()

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
        if (serversById[key.serverId]?.backendKind == BackendKind.OPENCODE) {
            openCodeInterruptedKeys.add(key)
            openCodePollingKeys.remove(key)
            requireOpenCodeClient(key.serverId).abort(key.threadId)
            val existing = threadsByKey[key] ?: return
            threadsByKey[key] =
                existing.copy(
                    status = ThreadStatus.READY,
                    activeTurnId = null,
                    updatedAtEpochMillis = System.currentTimeMillis(),
                    messages = finalizeStreaming(existing.messages),
                    lastError = null,
                )
            updateState { it.copy(connectionError = null) }
            return
        }
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
        val mimeType = localImageMimeType(path)
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
                val resolvedAgent =
                    upsertAgentIdentity(
                        serverId = serverId,
                        threadId = threadId,
                        agentId = parseAgentId(params),
                        nickname = parseAgentNickname(params) ?: existing.agentNickname,
                        role = parseAgentRole(params) ?: existing.agentRole,
                    )
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
                        agentNickname = resolvedAgent?.nickname ?: existing.agentNickname,
                        agentRole = resolvedAgent?.role ?: existing.agentRole,
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
                val eventThreadId = extractThreadIdForIdentity(params) ?: params.optThreadId()
                val key = resolveThreadKey(serverId, eventThreadId) ?: return
                val existing = ensureThreadState(key)
                val eventAgentId = extractAgentIdForIdentity(params)
                val identityThreadId = eventThreadId ?: if (eventAgentId.isNullOrBlank()) key.threadId else null
                val resolvedAgent =
                    resolveAgentIdentity(
                        serverId = serverId,
                        threadId = identityThreadId,
                        agentId = eventAgentId,
                        params = params,
                    )
                val agentNickname = resolvedAgent.nickname ?: existing.agentNickname
                val agentRole = resolvedAgent.role ?: existing.agentRole
                val mergedMessages =
                    appendAssistantDelta(
                        messages = existing.messages,
                        delta = delta,
                        agentNickname = agentNickname,
                        agentRole = agentRole,
                    )
                threadsByKey[key] =
                    existing.copy(
                        status = ThreadStatus.THINKING,
                        messages = mergedMessages,
                        preview = derivePreview(mergedMessages, existing.preview),
                        agentNickname = agentNickname,
                        agentRole = agentRole,
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
                    updateState { it.copy(activeThreadKey = key, activeServerId = key.serverId, connectionError = message) }
                } else {
                    updateState { it.copy(connectionError = message) }
                }
            }

            "codex/event/turn_diff" -> {
                handleLegacyCodexEventNotification(serverId = serverId, method = method, params = params)
            }

            else -> {
                if (method.startsWith("item/")) {
                    serversUsingItemNotifications += serverId
                } else if (method == "codex/event" || method.startsWith("codex/event/")) {
                    ingestCodexEventAgentMetadata(serverId = serverId, method = method, params = params)
                    if (!serversUsingItemNotifications.contains(serverId)) {
                        handleLegacyCodexEventNotification(serverId = serverId, method = method, params = params)
                    }
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

        val message =
            chatMessageFromItem(
                item = item,
                sourceTurnId = null,
                sourceTurnIndex = null,
                serverId = serverId,
                defaultAgentNickname = existing.agentNickname,
                defaultAgentRole = existing.agentRole,
            ) ?: return
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

    private fun extractString(value: Any?): String? {
        val text =
            when (value) {
                null, JSONObject.NULL -> null
                is String -> value
                is Number -> value.toString()
                else -> value.toString()
            }?.trim()
        return text?.takeIf { it.isNotEmpty() }
    }

    private fun extractStringList(
        obj: JSONObject?,
        vararg keys: String,
    ): List<String> {
        if (obj == null) {
            return emptyList()
        }
        for (key in keys) {
            if (!obj.has(key)) {
                continue
            }
            when (val value = obj.opt(key)) {
                is JSONArray -> {
                    val items = ArrayList<String>(value.length())
                    for (index in 0 until value.length()) {
                        val text = extractString(value.opt(index))
                        if (!text.isNullOrBlank()) {
                            items += text
                        }
                    }
                    if (items.isNotEmpty()) {
                        return items
                    }
                }

                is Collection<*> -> {
                    val items =
                        value
                            .mapNotNull { extractString(it) }
                            .filter { it.isNotBlank() }
                    if (items.isNotEmpty()) {
                        return items
                    }
                }

                else -> {
                    val text = extractString(value)
                    if (!text.isNullOrBlank()) {
                        return listOf(text)
                    }
                }
            }
        }
        return emptyList()
    }

    private data class ParsedCodexEvent(
        val eventType: String,
        val payload: JSONObject,
    )

    private fun parseCodexEvent(
        method: String,
        params: JSONObject?,
    ): ParsedCodexEvent? {
        val payload =
            when (val rawMsg = params?.opt("msg")) {
                is JSONObject -> rawMsg
                else -> params
            } ?: return null
        val eventType =
            if (method == "codex/event") {
                extractString(payload, "type") ?: "codex/event"
            } else {
                method.removePrefix("codex/event/")
            }
        return ParsedCodexEvent(eventType = eventType, payload = payload)
    }

    private fun ingestCodexEventAgentMetadata(
        serverId: String,
        method: String,
        params: JSONObject?,
    ) {
        val parsed = parseCodexEvent(method = method, params = params) ?: return
        val payload = parsed.payload
        var threadStateUpdated = false

        fun upsertIdentity(
            threadId: String?,
            agentId: String?,
            nickname: String?,
            role: String?,
            metadata: JSONObject? = null,
        ) {
            val cleanThreadId = threadId?.trim()?.takeIf { it.isNotEmpty() }
            val cleanAgentId = agentId?.trim()?.takeIf { it.isNotEmpty() }
            val cleanNickname = nickname?.trim()?.takeIf { it.isNotEmpty() }
            val cleanRole = role?.trim()?.takeIf { it.isNotEmpty() }
            if (cleanThreadId == null && cleanAgentId == null && cleanNickname == null && cleanRole == null) {
                return
            }
            upsertAgentIdentity(
                serverId = serverId,
                threadId = cleanThreadId,
                agentId = cleanAgentId,
                nickname = cleanNickname,
                role = cleanRole,
            )
            val shouldHydrateThread =
                cleanThreadId != null &&
                    (metadata != null || threadsByKey.containsKey(ThreadKey(serverId = serverId, threadId = cleanThreadId)))
            if (shouldHydrateThread && upsertThreadMetadataFromEvent(serverId = serverId, threadId = cleanThreadId, source = metadata)) {
                threadStateUpdated = true
            }
        }

        val senderThreadId =
            extractThreadIdForIdentity(payload, "sender_thread_id", "senderThreadId")
                ?: extractThreadIdForIdentity(params)
        upsertIdentity(
            threadId = senderThreadId,
            agentId = extractString(payload, "sender_agent_id", "senderAgentId") ?: extractAgentIdForIdentity(payload),
            nickname = extractAgentNicknameForIdentity(payload),
            role = extractAgentRoleForIdentity(payload),
            metadata = payload,
        )

        upsertIdentity(
            threadId = extractString(payload, "new_thread_id", "newThreadId"),
            agentId = extractString(payload, "new_agent_id", "newAgentId"),
            nickname = extractString(payload, "new_agent_nickname", "newAgentNickname"),
            role = extractString(payload, "new_agent_role", "newAgentRole"),
            metadata = payload,
        )

        upsertIdentity(
            threadId = extractString(payload, "receiver_thread_id", "receiverThreadId"),
            agentId = extractString(payload, "receiver_agent_id", "receiverAgentId"),
            nickname = extractString(payload, "receiver_agent_nickname", "receiverAgentNickname"),
            role = extractString(payload, "receiver_agent_role", "receiverAgentRole"),
            metadata = payload,
        )

        val receiverThreadIds = extractStringList(payload, "receiver_thread_ids", "receiverThreadIds")
        val receiverAgentsRaw = payload.optJSONArray("receiver_agents") ?: payload.optJSONArray("receiverAgents")
        receiverThreadIds.forEachIndexed { index, threadId ->
            val aligned = receiverAgentsRaw?.optJSONObject(index)
            upsertIdentity(
                threadId = threadId,
                agentId = aligned?.let { extractString(it, "agent_id", "agentId", "id") },
                nickname = aligned?.let { extractString(it, "agent_nickname", "agentNickname", "nickname", "name") },
                role = aligned?.let { extractString(it, "agent_role", "agentRole", "agent_type", "agentType", "role", "type") },
                metadata = aligned ?: payload,
            )
        }

        if (receiverAgentsRaw != null) {
            for (index in 0 until receiverAgentsRaw.length()) {
                val rawReceiver = receiverAgentsRaw.opt(index)
                val receiver = rawReceiver as? JSONObject
                if (receiver != null) {
                    upsertIdentity(
                        threadId = extractThreadIdForIdentity(receiver),
                        agentId = extractAgentIdForIdentity(receiver),
                        nickname = extractAgentNicknameForIdentity(receiver),
                        role = extractAgentRoleForIdentity(receiver),
                        metadata = receiver,
                    )
                } else {
                    upsertIdentity(
                        threadId = extractString(rawReceiver),
                        agentId = null,
                        nickname = null,
                        role = null,
                    )
                }
            }
        }

        payload.optJSONObject("statuses")?.let { statuses ->
            val iterator = statuses.keys()
            while (iterator.hasNext()) {
                val threadId = iterator.next()
                val statusObj = statuses.optJSONObject(threadId)
                upsertIdentity(
                    threadId = threadId,
                    agentId = statusObj?.let { extractString(it, "agent_id", "agentId") },
                    nickname = statusObj?.let { extractString(it, "agent_nickname", "agentNickname", "receiver_agent_nickname", "receiverAgentNickname") },
                    role = statusObj?.let { extractString(it, "agent_role", "agentRole", "receiver_agent_role", "receiverAgentRole", "agent_type", "agentType") },
                    metadata = statusObj ?: payload,
                )
            }
        }

        val statusEntries = payload.optJSONArray("agent_statuses") ?: payload.optJSONArray("agentStatuses")
        if (statusEntries != null) {
            for (index in 0 until statusEntries.length()) {
                val entry = statusEntries.optJSONObject(index) ?: continue
                upsertIdentity(
                    threadId = extractString(entry, "thread_id", "threadId", "receiver_thread_id", "receiverThreadId"),
                    agentId = extractString(entry, "agent_id", "agentId"),
                    nickname = extractString(entry, "agent_nickname", "agentNickname", "receiver_agent_nickname", "receiverAgentNickname"),
                    role = extractString(entry, "agent_role", "agentRole", "receiver_agent_role", "receiverAgentRole", "agent_type", "agentType"),
                    metadata = entry,
                )
            }
        }

        if (threadStateUpdated) {
            updateState { it }
        }
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

    private fun parseOpenCodeModel(value: String?): Pair<String, String>? {
        val model = value?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val providerId = model.substringBefore('/').trim()
        val modelId = model.substringAfter('/', "").trim()
        if (providerId.isEmpty() || modelId.isEmpty()) {
            return null
        }
        return providerId to modelId
    }

    private fun openCodePromptModel(value: String?): JSONObject? {
        val model = parseOpenCodeModel(value) ?: return null
        return JSONObject()
            .put("providerID", model.first)
            .put("modelID", model.second)
    }

    private fun JSONArray.jsonStrings(): List<String> {
        val values = ArrayList<String>(length())
        for (index in 0 until length()) {
            val value = optString(index).trim()
            if (value.isNotEmpty()) {
                values += value
            }
        }
        return values
    }

    private fun summarizeJson(value: Any?): String {
        return when (value) {
            null, JSONObject.NULL -> ""
            is JSONObject -> {
                val lines = jsonLines(value)
                if (lines.isEmpty()) "" else lines.joinToString(" • ")
            }
            is JSONArray -> {
                val lines = jsonLines(value)
                if (lines.isEmpty()) "" else lines.joinToString(" • ")
            }
            else -> value.toString().trim()
        }
    }

    private fun jsonLines(value: Any?): List<String> {
        return when (value) {
            null, JSONObject.NULL -> emptyList()
            is JSONObject -> {
                val keys = value.keys()
                val lines = ArrayList<String>()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val item = value.opt(key)
                    val summary = summarizeJson(item)
                    lines += if (summary.isNotEmpty()) "$key: $summary" else key
                }
                lines
            }
            is JSONArray -> {
                val lines = ArrayList<String>(value.length())
                for (index in 0 until value.length()) {
                    val summary = summarizeJson(value.opt(index))
                    if (summary.isNotEmpty()) {
                        lines += summary
                    }
                }
                lines
            }
            else -> listOf(value.toString())
        }
    }

    private fun normalizeCwd(cwd: String?): String? = cwd?.trim()?.takeIf { it.isNotEmpty() }

    private fun parseThreadCwd(obj: JSONObject?): String? {
        val direct =
            extractString(
                obj,
                "cwd",
                "workingDirectory",
                "working_directory",
            )
        if (!direct.isNullOrBlank()) {
            return direct
        }
        return extractString(
            threadSpawnObject(obj),
            "cwd",
            "workingDirectory",
            "working_directory",
        )
    }

    private fun resolveThreadCwd(
        serverId: String,
        threadId: String,
        responseCwd: String?,
        existing: ThreadState?,
        parentThreadId: String?,
        rootThreadId: String?,
    ): String {
        normalizeCwd(responseCwd)?.let { return it }

        parentThreadId?.let { parentId ->
            normalizeCwd(threadsByKey[ThreadKey(serverId = serverId, threadId = parentId)]?.cwd)?.let { return it }
        }
        rootThreadId?.takeIf { it != threadId }?.let { rootId ->
            normalizeCwd(threadsByKey[ThreadKey(serverId = serverId, threadId = rootId)]?.cwd)?.let { return it }
        }
        normalizeCwd(existing?.cwd)?.let { return it }

        val activeKey = state.activeThreadKey
        if (activeKey?.serverId == serverId) {
            val activeCwd = normalizeCwd(threadsByKey[activeKey]?.cwd) ?: normalizeCwd(state.currentCwd)
            if (activeCwd != null) {
                val threadMatchesActiveTree =
                    activeKey.threadId == threadId ||
                        activeKey.threadId == parentThreadId ||
                        activeKey.threadId == rootThreadId
                if (threadMatchesActiveTree) {
                    return activeCwd
                }
            }
        }

        return defaultWorkingDirectory()
    }

    private fun resolveMessageCwd(cwd: String?): String {
        normalizeCwd(cwd)?.let { return it }
        val activeKey = state.activeThreadKey
        if (activeKey != null) {
            normalizeCwd(threadsByKey[activeKey]?.cwd)?.let { return it }
        }
        normalizeCwd(state.currentCwd)?.let { return it }
        return defaultWorkingDirectory()
    }

    private fun upsertThreadMetadataFromEvent(
        serverId: String,
        threadId: String?,
        source: JSONObject?,
    ): Boolean {
        val cleanThreadId = threadId?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val key = ThreadKey(serverId = serverId, threadId = cleanThreadId)
        val existing = threadsByKey[key] ?: ensureThreadState(key)

        val parentThreadId = parseParentThreadId(source) ?: existing.parentThreadId
        val rootThreadId = parseRootThreadId(source) ?: existing.rootThreadId
        val nextCwd =
            normalizeCwd(parseThreadCwd(source))
                ?: parentThreadId?.let { parentId ->
                    normalizeCwd(threadsByKey[ThreadKey(serverId = serverId, threadId = parentId)]?.cwd)
                }
                ?: rootThreadId?.let { rootId ->
                    normalizeCwd(threadsByKey[ThreadKey(serverId = serverId, threadId = rootId)]?.cwd)
                }
                ?: normalizeCwd(existing.cwd)

        if (parentThreadId == existing.parentThreadId && rootThreadId == existing.rootThreadId && (nextCwd == null || nextCwd == existing.cwd)) {
            return false
        }

        threadsByKey[key] =
            existing.copy(
                parentThreadId = parentThreadId,
                rootThreadId = rootThreadId,
                cwd = nextCwd ?: existing.cwd,
            )
        return true
    }

    private fun sourceObject(obj: JSONObject?): JSONObject? = obj?.opt("source") as? JSONObject

    private fun threadSpawnObject(obj: JSONObject?): JSONObject? {
        val source = sourceObject(obj) ?: return null
        val subAgent = (source.opt("subAgent") as? JSONObject) ?: (source.opt("sub_agent") as? JSONObject) ?: return null
        return (subAgent.opt("thread_spawn") as? JSONObject) ?: (subAgent.opt("threadSpawn") as? JSONObject)
    }

    private fun extractThreadIdForIdentity(
        obj: JSONObject?,
        vararg directKeys: String,
    ): String? {
        val keys = ArrayList<String>(directKeys.size + 8)
        directKeys.forEach { keys += it }
        keys +=
            listOf(
                "threadId",
                "threadID",
                "thread_id",
                "conversationId",
                "conversationID",
                "conversation_id",
                "receiverThreadId",
                "receiver_thread_id",
            )
        val direct = extractString(obj, *keys.toTypedArray())
        if (!direct.isNullOrBlank()) {
            return direct
        }
        val threadSpawn = threadSpawnObject(obj)
        return extractString(threadSpawn, "thread_id", "threadId", "conversation_id", "conversationId")
    }

    private fun extractAgentNicknameForIdentity(obj: JSONObject?): String? {
        val direct = parseAgentNickname(obj)
        if (!direct.isNullOrBlank()) {
            return direct
        }
        val nestedAgent = obj?.opt("agent") as? JSONObject
        return extractString(
            nestedAgent,
            "agentNickname",
            "agent_nickname",
            "nickname",
            "name",
        ) ?: extractString(obj, "nickname")
    }

    private fun extractAgentRoleForIdentity(obj: JSONObject?): String? {
        val direct = parseAgentRole(obj)
        if (!direct.isNullOrBlank()) {
            return direct
        }
        val nestedAgent = obj?.opt("agent") as? JSONObject
        return extractString(
            nestedAgent,
            "agentRole",
            "agent_role",
            "agentType",
            "agent_type",
            "role",
            "type",
        ) ?: extractString(obj, "role", "agentType", "agent_type")
    }

    private fun extractAgentIdForIdentity(obj: JSONObject?): String? {
        val direct =
            extractString(
                obj,
                "agentId",
                "agent_id",
                "senderAgentId",
                "sender_agent_id",
                "receiverAgentId",
                "receiver_agent_id",
            )
        if (!direct.isNullOrBlank()) {
            return direct
        }
        val fromThreadSpawn = extractString(threadSpawnObject(obj), "agent_id", "agentId", "id")
        if (!fromThreadSpawn.isNullOrBlank()) {
            return fromThreadSpawn
        }
        val nestedAgent = obj?.opt("agent") as? JSONObject
        return extractString(nestedAgent, "agentId", "agent_id", "id")
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
        return extractString(threadSpawnObject(obj), "parent_thread_id", "parentThreadId")
    }

    private fun parseRootThreadId(obj: JSONObject?): String? {
        val direct = extractString(obj, "rootThreadId", "root_thread_id")
        if (!direct.isNullOrBlank()) {
            return direct
        }
        return extractString(threadSpawnObject(obj), "root_thread_id", "rootThreadId")
    }

    private fun parseAgentNickname(obj: JSONObject?): String? {
        val direct = extractString(obj, "agentNickname", "agent_nickname")
        if (!direct.isNullOrBlank()) {
            return direct
        }
        return extractString(threadSpawnObject(obj), "agent_nickname", "agentNickname")
    }

    private fun parseAgentRole(obj: JSONObject?): String? {
        val direct = extractString(obj, "agentRole", "agent_role", "agentType", "agent_type")
        if (!direct.isNullOrBlank()) {
            return direct
        }
        return extractString(threadSpawnObject(obj), "agent_role", "agentRole", "agent_type", "agentType")
    }

    private fun parseAgentId(obj: JSONObject?): String? {
        val direct = extractString(obj, "agentId", "agent_id")
        if (!direct.isNullOrBlank()) {
            return direct
        }
        return extractString(threadSpawnObject(obj), "agent_id", "agentId")
    }

    private fun formatAgentLabel(
        nickname: String?,
        role: String?,
        threadId: String? = null,
    ): String {
        val cleanNickname = nickname?.trim().orEmpty()
        val cleanRole = role?.trim().orEmpty()
        return when {
            cleanNickname.isNotEmpty() && cleanRole.isNotEmpty() -> "$cleanNickname [$cleanRole]"
            cleanNickname.isNotEmpty() -> cleanNickname
            cleanRole.isNotEmpty() -> "[$cleanRole]"
            !threadId.isNullOrBlank() -> threadId
            else -> "Agent"
        }
    }

    private data class AgentIdentity(
        val nickname: String?,
        val role: String?,
    )

    private data class AgentLookup(
        val identity: AgentIdentity?,
        val threadHit: Boolean,
        val agentHit: Boolean,
    )

    private data class ReceiverAddressing(
        val threadId: String?,
        val agentId: String?,
        val fallbackId: String?,
    ) {
        fun candidateIds(): List<String> =
            listOf(threadId, agentId, fallbackId)
                .mapNotNull { id -> id?.trim()?.takeIf { it.isNotEmpty() } }
                .distinct()
    }

    private fun parseReceiverAddressing(value: Any?): ReceiverAddressing? {
        return when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> parseReceiverAddressingObject(value)
            else -> {
                val id = value.toString().trim()
                if (id.isEmpty()) null else ReceiverAddressing(threadId = id, agentId = id, fallbackId = id)
            }
        }
    }

    private fun parseReceiverAddressingObject(obj: JSONObject): ReceiverAddressing {
        var threadId = extractThreadIdForIdentity(obj)
        var agentId = extractAgentIdForIdentity(obj)
        var fallbackId = extractString(obj, "id", "receiverId", "receiver_id", "targetId", "target_id", "addressingId", "addressing_id")

        val nestedFields = listOf("address", "receiver", "target", "ref")
        for (field in nestedFields) {
            when (val nested = obj.opt(field)) {
                is JSONObject -> {
                    val nestedAddressing = parseReceiverAddressingObject(nested)
                    if (threadId.isNullOrBlank()) {
                        threadId = nestedAddressing.threadId
                    }
                    if (agentId.isNullOrBlank()) {
                        agentId = nestedAddressing.agentId
                    }
                    if (fallbackId.isNullOrBlank()) {
                        fallbackId = nestedAddressing.fallbackId
                    }
                }

                is String -> {
                    if (fallbackId.isNullOrBlank()) {
                        fallbackId = nested.trim().ifEmpty { null }
                    }
                }
            }
        }

        val cleanThreadId = threadId?.trim()?.takeIf { it.isNotEmpty() }
        val cleanAgentId = agentId?.trim()?.takeIf { it.isNotEmpty() }
        val cleanFallback =
            fallbackId
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: cleanThreadId
                ?: cleanAgentId
        return ReceiverAddressing(
            threadId = cleanThreadId,
            agentId = cleanAgentId,
            fallbackId = cleanFallback,
        )
    }

    private class AgentDirectory {
        private val byThreadId = LinkedHashMap<String, AgentIdentity>()
        private val byAgentId = LinkedHashMap<String, AgentIdentity>()
        private val agentIdByThreadId = LinkedHashMap<String, String>()
        private val threadIdByAgentId = LinkedHashMap<String, String>()

        fun clear() {
            byThreadId.clear()
            byAgentId.clear()
            agentIdByThreadId.clear()
            threadIdByAgentId.clear()
        }

        fun removeServer(serverId: String) {
            val prefix = "$serverId:"
            byThreadId.keys.removeAll { it.startsWith(prefix) }
            byAgentId.keys.removeAll { it.startsWith(prefix) }
            agentIdByThreadId.entries.removeAll { it.key.startsWith(prefix) || it.value.startsWith(prefix) }
            threadIdByAgentId.entries.removeAll { it.key.startsWith(prefix) || it.value.startsWith(prefix) }
        }

        fun resolveLookup(
            serverId: String,
            threadId: String?,
            agentId: String?,
        ): AgentLookup {
            val threadKey = threadId?.trim()?.takeIf { it.isNotEmpty() }?.let { key(serverId, it) }
            val agentKey = agentId?.trim()?.takeIf { it.isNotEmpty() }?.let { key(serverId, it) }
            val directThread = threadKey?.let { byThreadId[it] }
            val directAgent = agentKey?.let { byAgentId[it] }
            val linkedAgent = threadKey?.let { scopedThread -> agentIdByThreadId[scopedThread] }?.let { scopedAgent -> byAgentId[scopedAgent] }
            val linkedThread = agentKey?.let { scopedAgent -> threadIdByAgentId[scopedAgent] }?.let { scopedThread -> byThreadId[scopedThread] }
            val merged =
                mergeIdentity(
                    mergeIdentity(directThread, directAgent),
                    mergeIdentity(linkedThread, linkedAgent),
                )
            return AgentLookup(
                identity = merged,
                threadHit = directThread != null || linkedThread != null,
                agentHit = directAgent != null || linkedAgent != null,
            )
        }

        fun resolve(
            serverId: String,
            threadId: String?,
            agentId: String?,
        ): AgentIdentity? {
            return resolveLookup(serverId = serverId, threadId = threadId, agentId = agentId).identity
        }

        fun upsert(
            serverId: String,
            threadId: String?,
            agentId: String?,
            nickname: String?,
            role: String?,
        ): AgentIdentity? {
            val cleanThreadId = threadId?.trim()?.takeIf { it.isNotEmpty() }
            val cleanAgentId = agentId?.trim()?.takeIf { it.isNotEmpty() }
            val threadKey = cleanThreadId?.let { key(serverId, it) }
            val agentKey = cleanAgentId?.let { key(serverId, it) }
            if (threadKey != null && agentKey != null) {
                agentIdByThreadId[threadKey] = agentKey
                threadIdByAgentId[agentKey] = threadKey
            }
            val explicit = normalizeIdentity(AgentIdentity(nickname = nickname, role = role))
            val existing = resolveLookup(serverId = serverId, threadId = cleanThreadId, agentId = cleanAgentId).identity
            val resolved = mergeIdentity(explicit, existing) ?: existing
            if (resolved != null) {
                threadKey?.let { scopedThread ->
                    byThreadId[scopedThread] = resolved
                    agentIdByThreadId[scopedThread]?.let { scopedAgent ->
                        byAgentId[scopedAgent] = mergeIdentity(resolved, byAgentId[scopedAgent]) ?: resolved
                    }
                }
                agentKey?.let { scopedAgent ->
                    byAgentId[scopedAgent] = resolved
                    threadIdByAgentId[scopedAgent]?.let { scopedThread ->
                        byThreadId[scopedThread] = mergeIdentity(resolved, byThreadId[scopedThread]) ?: resolved
                    }
                }
            }
            return resolved
        }

        fun snapshotIdentitiesById(serverId: String): Map<String, AgentIdentity> {
            val prefix = "$serverId:"
            val snapshot = LinkedHashMap<String, AgentIdentity>()
            byThreadId.forEach { (scopedId, identity) ->
                if (!scopedId.startsWith(prefix)) {
                    return@forEach
                }
                val id = scopedId.removePrefix(prefix)
                if (id.isEmpty()) {
                    return@forEach
                }
                snapshot[id] = mergeIdentity(identity, snapshot[id]) ?: identity
            }
            byAgentId.forEach { (scopedId, identity) ->
                if (!scopedId.startsWith(prefix)) {
                    return@forEach
                }
                val id = scopedId.removePrefix(prefix)
                if (id.isEmpty()) {
                    return@forEach
                }
                snapshot[id] = mergeIdentity(identity, snapshot[id]) ?: identity
            }
            return snapshot
        }

        private fun key(
            serverId: String,
            id: String,
        ): String = "$serverId:$id"

        private fun normalizeIdentity(identity: AgentIdentity?): AgentIdentity? {
            if (identity == null) {
                return null
            }
            val nickname = identity.nickname?.trim()?.takeIf { it.isNotEmpty() }
            val role = identity.role?.trim()?.takeIf { it.isNotEmpty() }
            return if (nickname == null && role == null) {
                null
            } else {
                AgentIdentity(nickname = nickname, role = role)
            }
        }

        private fun mergeIdentity(
            primary: AgentIdentity?,
            secondary: AgentIdentity?,
        ): AgentIdentity? {
            val normalizedPrimary = normalizeIdentity(primary)
            val normalizedSecondary = normalizeIdentity(secondary)
            val nickname = normalizedPrimary?.nickname ?: normalizedSecondary?.nickname
            val role = normalizedPrimary?.role ?: normalizedSecondary?.role
            return if (nickname == null && role == null) {
                null
            } else {
                AgentIdentity(nickname = nickname, role = role)
            }
        }
    }

    private fun upsertAgentIdentity(
        serverId: String,
        threadId: String?,
        agentId: String?,
        nickname: String?,
        role: String?,
    ): AgentIdentity? {
        val cleanThreadId = threadId?.trim()?.takeIf { it.isNotEmpty() }
        val cleanAgentId = agentId?.trim()?.takeIf { it.isNotEmpty() }
        val resolved =
            agentDirectory.upsert(
                serverId = serverId,
                threadId = cleanThreadId,
                agentId = cleanAgentId,
                nickname = nickname,
                role = role,
            )
        if (resolved != null && cleanThreadId != null) {
            val key = ThreadKey(serverId = serverId, threadId = cleanThreadId)
            val existing = threadsByKey[key]
            if (existing != null) {
                val nextNickname = resolved.nickname ?: existing.agentNickname
                val nextRole = resolved.role ?: existing.agentRole
                if (nextNickname != existing.agentNickname || nextRole != existing.agentRole) {
                    threadsByKey[key] =
                        existing.copy(
                            agentNickname = nextNickname,
                            agentRole = nextRole,
                        )
                }
            }
        }
        return resolved
    }

    private fun resolveAgentIdentity(
        serverId: String,
        threadId: String?,
        agentId: String? = null,
        params: JSONObject? = null,
    ): AgentIdentity {
        val resolvedThreadId = threadId?.trim()?.takeIf { it.isNotEmpty() } ?: extractThreadIdForIdentity(params)
        val resolvedAgentId = agentId?.trim()?.takeIf { it.isNotEmpty() } ?: extractAgentIdForIdentity(params)
        val resolvedNickname = extractAgentNicknameForIdentity(params)
        val resolvedRole = extractAgentRoleForIdentity(params)
        val resolved =
            upsertAgentIdentity(
                serverId = serverId,
                threadId = resolvedThreadId,
                agentId = resolvedAgentId,
                nickname = resolvedNickname,
                role = resolvedRole,
            ) ?: agentDirectory.resolve(
                serverId = serverId,
                threadId = resolvedThreadId,
                agentId = resolvedAgentId,
            )
        if (resolved != null) {
            return resolved
        }
        val cleanThreadId = resolvedThreadId.orEmpty()
        val thread =
            if (cleanThreadId.isEmpty()) {
                null
            } else {
                threadsByKey[ThreadKey(serverId = serverId, threadId = cleanThreadId)]
                    ?: threadsByKey.values.firstOrNull { it.key.serverId == serverId && it.key.threadId == cleanThreadId }
            }
        return AgentIdentity(
            nickname = thread?.agentNickname,
            role = thread?.agentRole,
        )
    }

    private fun resolveAgentIdentityByAnyId(
        serverId: String,
        id: String,
    ): AgentIdentity {
        val cleanId = id.trim()
        if (cleanId.isEmpty()) {
            return AgentIdentity(nickname = null, role = null)
        }
        val lookup = agentDirectory.resolveLookup(serverId = serverId, threadId = cleanId, agentId = cleanId)
        if (lookup.identity != null) {
            return lookup.identity
        }
        val thread = threadsByKey[ThreadKey(serverId = serverId, threadId = cleanId)]
            ?: threadsByKey.values.firstOrNull { it.key.serverId == serverId && it.key.threadId == cleanId }
        val fallback =
            AgentIdentity(
                nickname = thread?.agentNickname,
                role = thread?.agentRole,
            )
        return fallback
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
        return extractThreadIdForIdentity(params)
    }

    private fun syncActiveThreadFromServerInternal() {
        val key = state.activeThreadKey ?: return
        val changed = syncThreadFromServerInternal(key)
        if (changed) {
            updateState { it }
        }
    }

    private fun syncThreadFromServerInternal(key: ThreadKey): Boolean {
        val thread = threadsByKey[key] ?: return false
        if (thread.hasTurnActive) {
            return false
        }
        if (serversById[key.serverId]?.backendKind == BackendKind.OPENCODE) {
            val restoredMessages = mapOpenCodeMessages(requireOpenCodeClient(key.serverId).loadMessages(key.threadId))
            if (messagesEquivalent(thread.messages, restoredMessages)) {
                return false
            }
            threadsByKey[key] =
                thread.copy(
                    status = thread.status,
                    activeTurnId = null,
                    messages = restoredMessages,
                    preview = derivePreview(restoredMessages, thread.preview),
                    updatedAtEpochMillis = System.currentTimeMillis(),
                    lastError = null,
                )
            threadTurnCounts[key] = inferredTurnCountFromMessages(restoredMessages)
            return true
        }

        val cwd = thread.cwd.ifBlank { defaultWorkingDirectory() }
        val response = runCatching { resumeThreadWithFallback(key.serverId, key.threadId, cwd) }.getOrNull() ?: return false
        val threadObj = response.optJSONObject("thread") ?: return false
        val resolvedAgent =
            upsertAgentIdentity(
                serverId = key.serverId,
                threadId = key.threadId,
                agentId = parseAgentId(threadObj),
                nickname = parseAgentNickname(threadObj) ?: thread.agentNickname,
                role = parseAgentRole(threadObj) ?: thread.agentRole,
            )
        val restored =
            restoreMessages(
                threadObject = threadObj,
                serverId = key.serverId,
                defaultAgentNickname = resolvedAgent?.nickname ?: thread.agentNickname,
                defaultAgentRole = resolvedAgent?.role ?: thread.agentRole,
            )
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
                agentNickname = resolvedAgent?.nickname ?: thread.agentNickname,
                agentRole = resolvedAgent?.role ?: thread.agentRole,
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
            if (lhs.agentNickname != rhs.agentNickname || lhs.agentRole != rhs.agentRole) {
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

    private fun restoreMessages(
        threadObject: JSONObject,
        serverId: String,
        defaultAgentNickname: String? = null,
        defaultAgentRole: String? = null,
    ): RestoredMessages {
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
                    serverId = serverId,
                    defaultAgentNickname = defaultAgentNickname,
                    defaultAgentRole = defaultAgentRole,
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
                serverId = serverId,
                defaultAgentNickname = defaultAgentNickname,
                defaultAgentRole = defaultAgentRole,
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
        serverId: String,
        defaultAgentNickname: String?,
        defaultAgentRole: String?,
    ) {
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            val message =
                chatMessageFromItem(
                    item = item,
                    sourceTurnId = sourceTurnId,
                    sourceTurnIndex = sourceTurnIndex,
                    serverId = serverId,
                    defaultAgentNickname = defaultAgentNickname,
                    defaultAgentRole = defaultAgentRole,
                ) ?: continue
            out += message
        }
    }

    private fun chatMessageFromItem(
        item: JSONObject,
        sourceTurnId: String?,
        sourceTurnIndex: Int?,
        serverId: String?,
        defaultAgentNickname: String? = null,
        defaultAgentRole: String? = null,
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
                    val itemAgentNickname = extractString(item, "agentNickname", "agent_nickname")
                    val itemAgentRole = extractString(item, "agentRole", "agent_role", "agentType", "agent_type")
                    ChatMessage(
                        role = MessageRole.ASSISTANT,
                        text = text,
                        sourceTurnId = sourceTurnId,
                        sourceTurnIndex = sourceTurnIndex,
                        agentNickname = itemAgentNickname ?: defaultAgentNickname,
                        agentRole = itemAgentRole ?: defaultAgentRole,
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
            "collabAgentToolCall" -> withTurnMetadata(parseCollabMessage(item, serverId), sourceTurnId, sourceTurnIndex)
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

    private fun parseCollabMessage(
        item: JSONObject,
        serverId: String?,
    ): ChatMessage? {
        val status = item.optString("status").trim()
        val tool = item.optString("tool").trim()
        val prompt = item.optString("prompt").trim()
        val receivers = item.optJSONArray("receiverThreadIds") ?: item.optJSONArray("receiver_thread_ids")
        val receiverAgentsRaw = item.optJSONArray("receiverAgents") ?: item.optJSONArray("receiver_agents")
        val receiverAgentOverridesById = LinkedHashMap<String, AgentIdentity>()
        val receiverAgentAddressingByIndex = LinkedHashMap<Int, ReceiverAddressing>()
        val receiverAgentOverridesByIndex = LinkedHashMap<Int, AgentIdentity>()
        if (receiverAgentsRaw != null) {
            for (idx in 0 until receiverAgentsRaw.length()) {
                val rawReceiver = receiverAgentsRaw.opt(idx)
                val receiver = rawReceiver as? JSONObject
                val addressing = parseReceiverAddressing(rawReceiver)
                if (addressing != null) {
                    receiverAgentAddressingByIndex[idx] = addressing
                }

                val identity =
                    AgentIdentity(
                        nickname = extractAgentNicknameForIdentity(receiver),
                        role = extractAgentRoleForIdentity(receiver),
                    )
                val hasIdentity = !identity.nickname.isNullOrBlank() || !identity.role.isNullOrBlank()
                if (hasIdentity) {
                    receiverAgentOverridesByIndex[idx] = identity
                    addressing?.candidateIds()?.forEach { candidateId ->
                        receiverAgentOverridesById[candidateId] = identity
                    }
                }

                if (serverId != null) {
                    upsertAgentIdentity(
                        serverId = serverId,
                        threadId = addressing?.threadId,
                        agentId = addressing?.agentId,
                        nickname = identity.nickname,
                        role = identity.role,
                    )
                }
            }
        }

        val lines = ArrayList<String>()
        if (status.isNotEmpty()) lines += "Status: $status"
        if (tool.isNotEmpty()) lines += "Tool: $tool"
        val receiverIndices =
            when {
                receivers != null && receivers.length() > 0 -> (0 until receivers.length()).toList()
                receiverAgentAddressingByIndex.isNotEmpty() -> receiverAgentAddressingByIndex.keys.sorted()
                else -> emptyList()
            }
        if (receiverIndices.isNotEmpty()) {
            val labels = ArrayList<String>()
            for (idx in receiverIndices) {
                val receiverAddressing =
                    parseReceiverAddressing(receivers?.opt(idx))
                        ?: receiverAgentAddressingByIndex[idx]
                        ?: continue
                val alignedAddressing = receiverAgentAddressingByIndex[idx]
                val candidateIds =
                    LinkedHashSet<String>().apply {
                        receiverAddressing.candidateIds().forEach { add(it) }
                        alignedAddressing?.candidateIds()?.forEach { add(it) }
                    }
                if (candidateIds.isEmpty()) {
                    continue
                }

                var overrideById: AgentIdentity? = null
                for (candidateId in candidateIds) {
                    val match = receiverAgentOverridesById[candidateId]
                    if (match != null) {
                        overrideById = match
                        break
                    }
                }
                val indexAlignedOverride = receiverAgentOverridesByIndex[idx]
                val overrideIdentity =
                    when {
                        overrideById != null && indexAlignedOverride != null ->
                            AgentIdentity(
                                nickname = overrideById.nickname ?: indexAlignedOverride.nickname,
                                role = overrideById.role ?: indexAlignedOverride.role,
                            )
                        overrideById != null -> overrideById
                        else -> indexAlignedOverride
                    }

                var directoryIdentity: AgentIdentity? = null
                if (serverId != null) {
                    for (candidateId in candidateIds) {
                        val resolved = resolveAgentIdentityByAnyId(serverId = serverId, id = candidateId)
                        if (!resolved.nickname.isNullOrBlank() || !resolved.role.isNullOrBlank()) {
                            directoryIdentity = resolved
                            break
                        }
                    }
                }

                val resolved =
                    when {
                        overrideIdentity != null && directoryIdentity != null ->
                            AgentIdentity(
                                nickname = overrideIdentity.nickname ?: directoryIdentity.nickname,
                                role = overrideIdentity.role ?: directoryIdentity.role,
                            )
                        overrideIdentity != null -> overrideIdentity
                        directoryIdentity != null -> directoryIdentity
                        else -> AgentIdentity(nickname = null, role = null)
                    }

                labels +=
                    formatAgentLabel(
                        nickname = resolved.nickname,
                        role = resolved.role,
                        threadId = candidateIds.firstOrNull(),
                    )
            }
            if (labels.isNotEmpty()) lines += "Targets: ${labels.joinToString(separator = ", ")}"
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
        val activeKey = state.activeThreadKey
        val inferredCwd =
            if (activeKey?.serverId == key.serverId) {
                normalizeCwd(threadsByKey[activeKey]?.cwd) ?: normalizeCwd(state.currentCwd)
            } else {
                null
            } ?: defaultWorkingDirectory()
        val created =
            ThreadState(
                key = key,
                serverName = server.name,
                serverSource = server.source,
                status = ThreadStatus.READY,
                cwd = inferredCwd,
                isPlaceholder = true,
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
        agentNickname: String? = null,
        agentRole: String? = null,
    ): List<ChatMessage> {
        if (delta.isEmpty()) {
            return messages
        }
        if (messages.isEmpty()) {
            return listOf(
                ChatMessage(
                    role = MessageRole.ASSISTANT,
                    text = delta,
                    isStreaming = true,
                    agentNickname = agentNickname,
                    agentRole = agentRole,
                ),
            )
        }
        val last = messages.last()
        return if (last.role == MessageRole.ASSISTANT && last.isStreaming) {
            val updated = messages.toMutableList()
            updated[updated.lastIndex] =
                last.copy(
                    text = last.text + delta,
                    agentNickname = last.agentNickname ?: agentNickname,
                    agentRole = last.agentRole ?: agentRole,
                    timestampEpochMillis = System.currentTimeMillis(),
                )
            updated
        } else {
            messages +
                ChatMessage(
                    role = MessageRole.ASSISTANT,
                    text = delta,
                    isStreaming = true,
                    agentNickname = agentNickname,
                    agentRole = agentRole,
                )
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

    private fun handleOpenCodeEvent(
        serverId: String,
        event: JSONObject,
    ) {
        val payload = event.optJSONObject("payload") ?: event
        val type = payload.optString("type")
        Log.d(OPEN_CODE_LOG_TAG, "handle event server=$serverId type=$type")
        if (type == "server.connected" || type == "server.heartbeat") {
            return
        }
        if (type == "session.status") {
            val props = payload.optJSONObject("properties")
            val threadId = props?.optString("sessionID")?.trim().orEmpty()
            val status = props?.opt("status").asOpenCodeStatusObject()
            Log.d(
                OPEN_CODE_LOG_TAG,
                "session status server=$serverId thread=$threadId status=${status?.optString("type").orEmpty()} interrupted=${openCodeInterruptedKeys.contains(ThreadKey(serverId, threadId))}",
            )
            if (threadId.isNotEmpty()) {
                val key = ThreadKey(serverId, threadId)
                val thread = threadsByKey[key]
                if (thread != null) {
                    val (nextStatus, statusMessage) = resolveOpenCodeThreadUiState(key, status)
                    threadsByKey[key] =
                        thread.copy(
                            status = nextStatus,
                            lastError = statusMessage,
                            updatedAtEpochMillis = System.currentTimeMillis(),
                        )
                    updateState { current ->
                        current.copy(
                            connectionError =
                                if (current.activeThreadKey == key) {
                                    statusMessage
                                } else {
                                    current.connectionError
                                },
                        )
                    }
                }
            }
        }
        refreshSessionsInternal(serverId)
        syncActiveThreadFromServerInternal()
    }

    private fun refreshOpenCodeSessions(server: ServerConfig) {
        val client = requireOpenCodeClient(server.id)
        val sessions = client.listSessions()
        val statuses = client.listStatuses()
        val authoritativeKeys = LinkedHashSet<ThreadKey>()
        for (index in 0 until sessions.length()) {
            val item = sessions.optJSONObject(index) ?: continue
            val threadId = item.optString("id").trim()
            if (threadId.isEmpty()) continue
            val key = ThreadKey(server.id, threadId)
            authoritativeKeys += key
            val existing = threadsByKey[key]
            val status = statuses.optJSONObject(threadId)
            val (nextStatus, statusMessage) = resolveOpenCodeThreadUiState(key, status)
            threadsByKey[key] =
                ThreadState(
                    key = key,
                    serverName = server.name,
                    serverSource = server.source,
                    status = nextStatus,
                    messages = existing?.messages ?: emptyList(),
                    preview = item.optString("title").trim().ifBlank { existing?.preview.orEmpty() },
                    cwd = server.directory ?: existing?.cwd.orEmpty(),
                    modelProvider = existing?.modelProvider.orEmpty(),
                    parentThreadId = item.optString("parentID").trim().ifBlank { null },
                    rootThreadId = existing?.rootThreadId,
                    updatedAtEpochMillis = parseOpenCodeUpdatedAt(item),
                    activeTurnId = null,
                    lastError = statusMessage,
                )
        }
        refreshOpenCodeMetadataInternal(server.id)
        refreshOpenCodeInteractions(server.id)
        computePlaceholderKeysToPrune(server.id, authoritativeKeys, state.activeThreadKey, threadsByKey).forEach { key ->
            threadsByKey.remove(key)
        }
    }

    private fun refreshOpenCodeInteractions(serverId: String) {
        val client = requireOpenCodeClient(serverId)
        pendingApprovalsById.entries.removeAll { it.value.serverId == serverId }
        pendingQuestionsById.entries.removeAll { it.value.serverId == serverId }

        val permissions = client.listPermissions()
        for (index in 0 until permissions.length()) {
            val item = permissions.optJSONObject(index) ?: continue
            val requestId = item.optString("id").trim()
            if (requestId.isEmpty()) continue
            pendingApprovalsById[requestId] =
                PendingApproval(
                    id = requestId,
                    requestId = requestId,
                    serverId = serverId,
                    method = "permission.reply",
                    kind = ApprovalKind.COMMAND_EXECUTION,
                    threadId = item.optString("sessionID").trim().ifBlank { null },
                    turnId = null,
                    itemId = item.optJSONObject("tool")?.optString("callID")?.trim(),
                    command = item.optJSONArray("patterns")?.join(" ")?.trim(),
                    cwd = null,
                    reason = item.optString("permission").trim().ifBlank { "Permission requested" },
                    grantRoot = null,
                )
        }

        val questions = client.listQuestions()
        for (index in 0 until questions.length()) {
            val item = questions.optJSONObject(index) ?: continue
            val requestId = item.optString("id").trim()
            if (requestId.isEmpty()) continue
            val prompts = ArrayList<PendingQuestionPrompt>()
            val questionItems = item.optJSONArray("questions") ?: JSONArray()
            for (questionIndex in 0 until questionItems.length()) {
                val prompt = questionItems.optJSONObject(questionIndex) ?: continue
                val options = ArrayList<PendingQuestionOption>()
                val optionItems = prompt.optJSONArray("options") ?: JSONArray()
                for (optionIndex in 0 until optionItems.length()) {
                    val option = optionItems.optJSONObject(optionIndex) ?: continue
                    options += PendingQuestionOption(label = option.optString("label"), description = option.optString("description"))
                }
                prompts +=
                    PendingQuestionPrompt(
                        header = prompt.optString("header"),
                        question = prompt.optString("question"),
                        options = options,
                        multiple = prompt.optBoolean("multiple", false),
                        custom = !prompt.has("custom") || prompt.optBoolean("custom", true),
                    )
            }
            pendingQuestionsById[requestId] =
                PendingQuestion(
                    id = requestId,
                    requestId = requestId,
                    serverId = serverId,
                    threadId = item.optString("sessionID").trim().ifBlank { null },
                    prompts = prompts,
                )
        }
    }

    private fun refreshOpenCodeMetadataInternal(serverId: String) {
        val server = serversById[serverId] ?: return
        if (server.backendKind != BackendKind.OPENCODE) {
            return
        }
        slashByServerId[serverId] = loadOpenCodeSlashEntriesInternal(serverId)
        val agents = loadOpenCodeAgentOptionsInternal(serverId)
        agentOptionsByServerId[serverId] = agents
        val selected = selectedAgentByServerId[serverId]?.trim()?.takeIf { it.isNotEmpty() }
        if (selected != null && agents.none { it.name == selected && !it.hidden }) {
            selectedAgentByServerId[serverId] = null
        }
    }

    private fun loadOpenCodeSlashEntriesInternal(serverId: String): List<SlashEntry> {
        val items = requireOpenCodeClient(serverId).listSlashes()
        val parsed = ArrayList<SlashEntry>(items.length())
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            val id = item.optString("id").trim()
            val name = item.optString("name").trim()
            if (id.isEmpty() || name.isEmpty()) {
                continue
            }
            val rawKind = item.optString("kind").trim().lowercase(Locale.ROOT)
            val kind =
                if (rawKind == "action") {
                    SlashKind.ACTION
                } else if (rawKind == "command") {
                    SlashKind.COMMAND
                } else {
                    continue
                }
            parsed +=
                SlashEntry(
                    id = id,
                    kind = kind,
                    name = name,
                    aliases = item.optJSONArray("aliases")?.jsonStrings().orEmpty(),
                    description = item.optString("description").trim(),
                    category = item.optString("category").trim(),
                    displayName = item.optString("displayName").trim().ifBlank { "/$name" },
                    actionId = item.optString("actionID").trim().ifBlank { null },
                    source = item.optString("source").trim().ifBlank { null },
                )
        }
        return mergeOpenCodeSlashEntries(parsed)
    }

    private fun loadOpenCodeAgentOptionsInternal(serverId: String): List<OpenCodeAgentOption> {
        val items = requireOpenCodeClient(serverId).listAgents()
        val parsed = ArrayList<OpenCodeAgentOption>(items.length())
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            val name = item.optString("name").trim()
            if (name.isEmpty()) {
                continue
            }
            parsed +=
                OpenCodeAgentOption(
                    name = name,
                    description = item.optString("description").trim(),
                    mode = item.optString("mode").trim(),
                    hidden = item.optBoolean("hidden", false),
                )
        }
        return parsed
            .filterNot { it.hidden }
            .sortedBy { it.name.lowercase(Locale.ROOT) }
    }

    private fun loadOpenCodeModelsInternal(serverId: String): List<ModelOption> {
        val client = requireOpenCodeClient(serverId)
        val config = runCatching { client.listConfigProviders() }.getOrNull()
        val providers = config?.optJSONArray("providers")
        if (providers != null && providers.length() > 0) {
            return parseOpenCodeModels(
                providers = providers,
                defaults = config.optJSONObject("default") ?: JSONObject(),
            )
        }
        val fallback = client.listProviders()
        return parseOpenCodeModels(
            providers = fallback.optJSONArray("all") ?: JSONArray(),
            defaults = fallback.optJSONObject("default") ?: JSONObject(),
        )
    }

    private fun parseOpenCodeModels(
        providers: JSONArray,
        defaults: JSONObject,
    ): List<ModelOption> {
        val parsed = ArrayList<ModelOption>()
        for (providerIndex in 0 until providers.length()) {
            val provider = providers.optJSONObject(providerIndex) ?: continue
            val providerId = provider.optString("id").trim()
            if (providerId.isEmpty()) {
                continue
            }
            val providerName = provider.optString("name").trim().ifBlank { providerId }
            val models = provider.optJSONObject("models") ?: continue
            val defaultModel = defaults.optString(providerId).trim()
            val keys = models.keys()
            while (keys.hasNext()) {
                val modelId = keys.next().trim()
                if (modelId.isEmpty()) {
                    continue
                }
                val info = models.optJSONObject(modelId) ?: JSONObject()
                val displayName = info.optString("name").trim().ifBlank { modelId }
                val description =
                    buildString {
                        append(providerName)
                        val family = info.optString("family").trim()
                        if (family.isNotEmpty()) {
                            append(" • ")
                            append(family)
                        }
                    }
                parsed +=
                    ModelOption(
                        id = "$providerId/$modelId",
                        displayName = displayName,
                        description = description,
                        defaultReasoningEffort = null,
                        supportedReasoningEfforts = emptyList(),
                        isDefault = modelId == defaultModel,
                    )
            }
        }
        return parsed.sortedWith(compareByDescending<ModelOption> { it.isDefault }.thenBy { it.id.lowercase(Locale.ROOT) })
    }

    private fun loadOpenCodeMcpStatusInternal(): List<OpenCodeMcpServer> {
        val serverId = resolveServerIdForActiveOperations()
        val server = ensureConnectedServer(serverId)
        if (server.backendKind != BackendKind.OPENCODE) {
            throw IllegalStateException("MCP status is only available for OpenCode servers")
        }
        val items = requireOpenCodeClient(serverId).listMcpStatus()
        val parsed = ArrayList<OpenCodeMcpServer>()
        val keys = items.keys()
        while (keys.hasNext()) {
            val name = keys.next()
            val value = items.optJSONObject(name) ?: JSONObject()
            parsed +=
                OpenCodeMcpServer(
                    name = name,
                    status = extractString(value, "status", "state", "connection").orEmpty().ifBlank { "unknown" },
                    summary = summarizeJson(value),
                )
        }
        return parsed.sortedBy { it.name.lowercase(Locale.ROOT) }
    }

    private fun loadOpenCodeStatusInternal(): OpenCodeStatusSnapshot {
        val serverId = resolveServerIdForActiveOperations()
        val server = ensureConnectedServer(serverId)
        if (server.backendKind != BackendKind.OPENCODE) {
            throw IllegalStateException("Status is only available for OpenCode servers")
        }
        val client = requireOpenCodeClient(serverId)
        val path = client.pathInfo()
        val vcs = client.vcsInfo()
        val mcp = client.listMcpStatus()
        val lsp = client.lspStatus()
        val formatter = client.formatterStatus()
        return OpenCodeStatusSnapshot(
            sections =
                listOf(
                    OpenCodeStatusSection(
                        title = "Paths",
                        lines =
                            listOfNotNull(
                                path.optString("directory").trim().takeIf { it.isNotEmpty() }?.let { "Directory: $it" },
                                path.optString("worktree").trim().takeIf { it.isNotEmpty() }?.let { "Worktree: $it" },
                                path.optString("config").trim().takeIf { it.isNotEmpty() }?.let { "Config: $it" },
                            ),
                    ),
                    OpenCodeStatusSection(
                        title = "VCS",
                        lines = jsonLines(vcs),
                    ),
                    OpenCodeStatusSection(
                        title = "MCP",
                        lines = jsonLines(mcp),
                    ),
                    OpenCodeStatusSection(
                        title = "LSP",
                        lines = jsonLines(lsp),
                    ),
                    OpenCodeStatusSection(
                        title = "Formatter",
                        lines = jsonLines(formatter),
                    ),
                ).filter { it.lines.isNotEmpty() },
        )
    }

    private fun mapOpenCodeMessages(messages: JSONArray): List<ChatMessage> {
        val parsed = mutableListOf<ChatMessage>()
        var turnIndex = 0
        for (index in 0 until messages.length()) {
            val item = messages.optJSONObject(index) ?: continue
            val info = item.optJSONObject("info") ?: continue
            val messageId = info.optString("id").trim().ifBlank { UUID.randomUUID().toString() }
            val createdAt = info.optJSONObject("time")?.optLong("created") ?: System.currentTimeMillis()
            val role = info.optString("role")
            val parts = item.optJSONArray("parts") ?: JSONArray()
            if (role == "user") {
                val text = buildString {
                    for (partIndex in 0 until parts.length()) {
                        val part = parts.optJSONObject(partIndex) ?: continue
                        when (part.optString("type")) {
                            "text" -> appendLine(part.optString("text"))
                            "file" -> appendLine("[Attachment] ${part.optString("filename").ifBlank { part.optString("mime") }}")
                        }
                    }
                }.trim()
                parsed += ChatMessage(id = messageId, role = MessageRole.USER, text = text, timestampEpochMillis = createdAt, isFromUserTurnBoundary = true, sourceTurnIndex = turnIndex)
                turnIndex += 1
                continue
            }
            val text = StringBuilder()
            val reasoning = StringBuilder()
            for (partIndex in 0 until parts.length()) {
                val part = parts.optJSONObject(partIndex) ?: continue
                when (part.optString("type")) {
                    "text" -> text.append(part.optString("text"))
                    "reasoning" -> reasoning.append(part.optString("text"))
                    "file" -> {
                        if (text.isNotEmpty()) {
                            text.append('\n')
                        }
                        text.append("[Attachment] ").append(part.optString("filename").ifBlank { part.optString("mime") })
                    }
                    "tool" -> {
                        if (text.isNotEmpty()) {
                            text.append('\n')
                        }
                        text.append("[").append(part.optString("tool")).append(": ").append(part.optJSONObject("state")?.optString("status")).append("]")
                    }
                    "step-start", "step-finish" -> Unit
                    else -> Unit
                }
            }
            if (reasoning.isNotBlank()) {
                parsed += ChatMessage(id = "$messageId-reasoning", role = MessageRole.REASONING, text = reasoning.toString().trim(), timestampEpochMillis = createdAt, sourceTurnIndex = maxOf(turnIndex - 1, 0))
            }
            val fallbackError = info.optJSONObject("error")?.optString("message").orEmpty()
            val assistantText = text.toString().trim().ifBlank { fallbackError }
            if (assistantText.isNotBlank()) {
                parsed += ChatMessage(id = messageId, role = MessageRole.ASSISTANT, text = assistantText, timestampEpochMillis = createdAt, sourceTurnIndex = maxOf(turnIndex - 1, 0))
            }
        }
        return parsed
    }

    private fun sendOpenCodeMessageInternal(
        key: ThreadKey,
        parts: JSONArray,
        cwd: String,
        userVisibleText: String,
        modelSelection: ModelSelection,
    ) {
        val existing = threadsByKey[key] ?: throw IllegalStateException("Unable to resolve active thread")
        threadsByKey[key] =
            existing.copy(
                status = ThreadStatus.THINKING,
                messages = existing.messages + ChatMessage(role = MessageRole.USER, text = userVisibleText, isFromUserTurnBoundary = true),
                preview = userVisibleText.take(120),
                cwd = cwd,
                updatedAtEpochMillis = System.currentTimeMillis(),
                lastError = null,
            )
        updateState { it.copy(activeThreadKey = key, activeServerId = key.serverId, currentCwd = cwd, connectionError = null) }
        val model = openCodePromptModel(modelSelection.modelId ?: state.selectedModel.modelId)
        val agent = selectedAgentByServerId[key.serverId]?.trim()?.takeIf { it.isNotEmpty() }
        openCodeInterruptedKeys.remove(key)
        try {
            Log.d(
                OPEN_CODE_LOG_TAG,
                "send prompt server=${key.serverId} thread=${key.threadId} parts=${parts.length()} model=${model?.toString().orEmpty()} agent=${agent.orEmpty()}",
            )
            requireOpenCodeClient(key.serverId).sendPrompt(key.threadId, parts, model = model, agent = agent)
        } catch (error: Throwable) {
            Log.e(
                OPEN_CODE_LOG_TAG,
                "send prompt failed server=${key.serverId} thread=${key.threadId}: ${error.message}",
                error,
            )
            val latest = threadsByKey[key] ?: return
            threadsByKey[key] =
                latest.copy(
                    status = ThreadStatus.ERROR,
                    lastError = error.message ?: "Failed to send prompt",
                    activeTurnId = null,
                    updatedAtEpochMillis = System.currentTimeMillis(),
                    messages = finalizeStreaming(latest.messages),
                )
            updateState {
                it.copy(connectionError = error.message ?: "Failed to send prompt")
            }
            throw error
        }
        Log.d(OPEN_CODE_LOG_TAG, "send prompt accepted server=${key.serverId} thread=${key.threadId}")
        runCatching { refreshOpenCodeInteractions(key.serverId) }
        startOpenCodePolling(key)
    }

    private fun parseOpenCodeUpdatedAt(item: JSONObject): Long {
        val time = item.optJSONObject("time")
        return time?.optLong("updated")
            ?: time?.optLong("created")
            ?: System.currentTimeMillis()
    }

    private fun mapOpenCodeThreadStatus(status: JSONObject?): ThreadStatus {
        return when (status?.optString("type")?.lowercase(Locale.ROOT)) {
            "busy", "running", "pending", "retry" -> ThreadStatus.THINKING
            "error", "failed" -> ThreadStatus.ERROR
            else -> ThreadStatus.READY
        }
    }

    private fun Any?.asOpenCodeStatusObject(): JSONObject? {
        return when (this) {
            is JSONObject -> this
            is String -> this.trim().takeIf { it.isNotEmpty() }?.let { JSONObject().put("type", it) }
            else -> null
        }
    }

    private fun resolveOpenCodeThreadUiState(
        key: ThreadKey,
        status: JSONObject?,
    ): Pair<ThreadStatus, String?> {
        val nextStatus = mapOpenCodeThreadStatus(status)
        val statusMessage = openCodeStatusMessage(status)
        if (nextStatus == ThreadStatus.THINKING && openCodeInterruptedKeys.contains(key)) {
            return ThreadStatus.READY to null
        }
        if (nextStatus != ThreadStatus.THINKING) {
            openCodeInterruptedKeys.remove(key)
        }
        return nextStatus to statusMessage
    }

    private fun openCodeStatusMessage(status: JSONObject?): String? {
        val type = status?.optString("type")?.trim()?.lowercase(Locale.ROOT).orEmpty()
        val message =
            status?.optString("message")
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
                ?: status?.optString("error")
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
        return when (type) {
            "busy", "running", "pending" -> message ?: "Generating response..."
            "retry" -> {
                val attempt = status?.optInt("attempt", 0)?.takeIf { it > 0 }
                val prefix = if (attempt != null) "Retrying request ($attempt)" else "Retrying request"
                message?.let { "$prefix: $it" } ?: prefix
            }
            "error", "failed" -> message ?: "OpenCode request failed"
            else -> null
        }
    }

    private fun startOpenCodePolling(
        key: ThreadKey,
        remainingAttempts: Int = OPEN_CODE_POLL_MAX_ATTEMPTS,
    ) {
        if (!openCodePollingKeys.add(key)) {
            return
        }
        scheduleOpenCodePoll(key, remainingAttempts)
    }

    private fun scheduleOpenCodePoll(
        key: ThreadKey,
        remainingAttempts: Int,
    ) {
        if (remainingAttempts <= 0 || closed) {
            openCodePollingKeys.remove(key)
            return
        }
        mainHandler.postDelayed(
            {
                if (closed) {
                    openCodePollingKeys.remove(key)
                    return@postDelayed
                }
                submit {
                    val continuePolling = pollOpenCodeThreadStateInternal(key)
                    if (continuePolling && openCodePollingKeys.contains(key)) {
                        scheduleOpenCodePoll(key, remainingAttempts - 1)
                    } else {
                        openCodePollingKeys.remove(key)
                    }
                }
            },
            OPEN_CODE_POLL_INTERVAL_MS,
        )
    }

    private fun pollOpenCodeThreadStateInternal(key: ThreadKey): Boolean {
        val thread = threadsByKey[key] ?: return false
        if (serversById[key.serverId]?.backendKind != BackendKind.OPENCODE) {
            return false
        }
        val client =
            runCatching { requireOpenCodeClient(key.serverId) }
                .getOrElse { error ->
                    Log.w(OPEN_CODE_LOG_TAG, "poll skipped server=${key.serverId} thread=${key.threadId}: ${error.message}")
                    return false
                }

        return runCatching {
            val statuses = client.listStatuses()
            val status = statuses.optJSONObject(key.threadId)
            val restoredMessages = mapOpenCodeMessages(client.loadMessages(key.threadId))
            val (nextStatus, statusMessage) = resolveOpenCodeThreadUiState(key, status)
            val latest = threadsByKey[key] ?: return@runCatching false
            val changedMessages = !messagesEquivalent(latest.messages, restoredMessages)
            val statusChanged = latest.status != nextStatus || latest.lastError != statusMessage
            if (changedMessages || statusChanged) {
                threadsByKey[key] =
                    latest.copy(
                        status = nextStatus,
                        activeTurnId = null,
                        messages = if (changedMessages) restoredMessages else latest.messages,
                        preview = derivePreview(if (changedMessages) restoredMessages else latest.messages, latest.preview),
                        updatedAtEpochMillis = System.currentTimeMillis(),
                        lastError = statusMessage,
                    )
                updateState { current ->
                    current.copy(
                        connectionError =
                            if (current.activeThreadKey == key) {
                                statusMessage
                            } else {
                                current.connectionError
                            },
                    )
                }
                Log.d(
                    OPEN_CODE_LOG_TAG,
                    "poll update server=${key.serverId} thread=${key.threadId} status=${status?.optString("type").orEmpty()} messages=${restoredMessages.size}",
                )
            }
            nextStatus == ThreadStatus.THINKING
        }.getOrElse { error ->
            Log.w(
                OPEN_CODE_LOG_TAG,
                "poll failed server=${key.serverId} thread=${key.threadId}: ${error.message}",
                error,
            )
            true
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
        runCatching { context.startService(intent) }
            .getOrElse { error ->
                throw IllegalStateException(
                    "Bundled runtime can only be started while the app is in the foreground.",
                    error,
                )
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

    private fun requireOpenCodeClient(serverId: String): OpenCodeClient =
        openCodeClientsByServerId[serverId]
            ?: throw IllegalStateException("OpenCode client is not connected for server '$serverId'")

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

    private fun buildToolTargetLabelsById(activeServerId: String?): Map<String, String> {
        val serverId = activeServerId?.trim()?.takeIf { it.isNotEmpty() } ?: return emptyMap()
        val labelsById = LinkedHashMap<String, String>()

        agentDirectory.snapshotIdentitiesById(serverId).forEach { (id, identity) ->
            labelsById[id] = formatAgentLabel(identity.nickname, identity.role, threadId = id)
        }

        threadsByKey.values
            .asSequence()
            .filter { thread -> thread.key.serverId == serverId }
            .forEach { thread ->
                val threadId = thread.key.threadId.trim()
                if (threadId.isEmpty() || labelsById.containsKey(threadId)) {
                    return@forEach
                }
                labelsById[threadId] = formatAgentLabel(thread.agentNickname, thread.agentRole, threadId = threadId)
            }

        return labelsById
    }

    private fun commitState(base: AppState) {
        val sortedThreads = threadsByKey.values.sortedByDescending { it.updatedAtEpochMillis }
        val preferredServerId =
            base.activeServerId?.takeIf { serversById.containsKey(it) }
        val activeKey =
            when {
                base.activeThreadKey != null && threadsByKey.containsKey(base.activeThreadKey) -> base.activeThreadKey
                preferredServerId != null -> sortedThreads.firstOrNull { it.key.serverId == preferredServerId }?.key
                sortedThreads.isNotEmpty() -> sortedThreads.first().key
                else -> null
            }
        val activeServerId =
            when {
                activeKey != null -> activeKey.serverId
                preferredServerId != null -> preferredServerId
                serversById.isNotEmpty() -> serversById.keys.first()
                else -> null
            }
        val toolTargetLabelsById = buildToolTargetLabelsById(activeServerId)
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
        val availableModels = activeServerId?.let { availableModelsByServerId[it] }.orEmpty()
        val selectedModel = activeServerId?.let { selectedModelByServerId[it] } ?: base.selectedModel

        val next =
            base.copy(
                connectionStatus = nextConnectionStatus,
                servers = serversById.values.toList(),
                savedServers = loadSavedServersInternal(),
                accountByServerId = LinkedHashMap(accountByServerId),
                capabilitiesByServerId = LinkedHashMap(capabilitiesByServerId),
                slashByServerId = LinkedHashMap(slashByServerId),
                agentOptionsByServerId = LinkedHashMap(agentOptionsByServerId),
                selectedAgentByServerId = LinkedHashMap(selectedAgentByServerId),
                activeServerId = activeServerId,
                availableModels = availableModels,
                selectedModel = selectedModel,
                threads = sortedThreads,
                activeThreadKey = activeKey,
                pendingInteractions =
                    (pendingApprovalsById.values.map { approval ->
                        PendingInteraction(
                            id = approval.id,
                            serverId = approval.serverId,
                            kind = PendingInteractionKind.APPROVAL,
                            approval = approval,
                            createdAtEpochMillis = approval.createdAtEpochMillis,
                        )
                    } + pendingQuestionsById.values.map { question ->
                        PendingInteraction(
                            id = question.id,
                            serverId = question.serverId,
                            kind = PendingInteractionKind.QUESTION,
                            question = question,
                            createdAtEpochMillis = question.createdAtEpochMillis,
                        )
                    }).sortedBy { it.createdAtEpochMillis },
                toolTargetLabelsById = toolTargetLabelsById,
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

    private fun persistSavedServersInternal(removedServerIds: Set<String> = emptySet()) {
        // Merge: start with existing saved servers (preserving offline ones), then overlay connected servers
        val existing = loadSavedServersInternal().associateBy { it.id }.toMutableMap()
        // Remove explicitly deleted servers
        removedServerIds.forEach {
            existing.remove(it)
            savedServerCredentialStore?.delete(it)
        }
        // Overlay currently connected servers (they may have updated fields like directory)
        for (server in serversById.values) {
            val saved = SavedServer.from(server)
            existing[saved.id] = saved
            persistSavedServerCredentials(saved)
        }
        writeSavedServersPayload(existing.values)
    }

    private fun loadSavedServersInternal(): List<SavedServer> {
        val raw = savedServersPreferences?.getString(savedServersKey, null) ?: return emptyList()
        val parsed = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        val out = LinkedHashMap<String, SavedServer>()
        var migratedLegacyCredentials = false
        for (index in 0 until parsed.length()) {
            val item = parsed.optJSONObject(index) ?: continue
            val name = item.optString("name").trim()
            val backendKind = item.optString("backendKind").trim()
            val kind = BackendKind.from(backendKind)
            val host =
                normalizeServerHost(
                    item.optString("host"),
                    preserveScheme = kind == BackendKind.OPENCODE,
                )
            val port = item.optInt("port", 0)
            val source = item.optString("source").trim()
            val hasCodexServer = item.optBoolean("hasCodexServer", true)
            val id =
                if (ServerSource.from(source) == ServerSource.MANUAL) {
                    manualServerId(kind, host, port)
                } else {
                    item.optString("id").trim()
                }
            if (id.isEmpty() || host.isEmpty() || port <= 0) {
                continue
            }
            val legacyCredentials =
                SavedServerCredentials(
                    username = nullableString(item, "username"),
                    password = nullableString(item, "password"),
                )
            val storedCredentials = savedServerCredentialStore?.load(id)
            val mergedCredentials =
                SavedServerCredentials(
                    username = storedCredentials?.username ?: legacyCredentials.username,
                    password = storedCredentials?.password ?: legacyCredentials.password,
                )
            if (savedServerCredentialStore?.isAvailable == true && !legacyCredentials.isEmpty() && mergedCredentials != storedCredentials) {
                savedServerCredentialStore?.save(id, mergedCredentials)
                migratedLegacyCredentials = true
            }
            out.remove(id)
            out[id] =
                SavedServer(
                    id = id,
                    name = if (name.isEmpty()) host else name,
                    host = host,
                    port = port,
                    source = source,
                    backendKind = backendKind,
                    hasCodexServer = hasCodexServer,
                    username = mergedCredentials.username,
                    password = mergedCredentials.password,
                    directory = nullableString(item, "directory"),
                    websocketUrl = nullableString(item, "websocketUrl"),
                )
        }
        if (migratedLegacyCredentials) {
            writeSavedServersPayload(out.values)
        }
        return out.values.toList()
    }

    private fun persistSavedServerCredentials(saved: SavedServer) {
        val credentials =
            SavedServerCredentials(
                username = saved.username,
                password = saved.password,
            )
        if (credentials.isEmpty()) {
            savedServerCredentialStore?.delete(saved.id)
            return
        }
        savedServerCredentialStore?.save(saved.id, credentials)
    }

    private fun writeSavedServersPayload(savedServers: Collection<SavedServer>) {
        val includeFallbackCredentials = savedServerCredentialStore?.isAvailable != true
        savedServersPreferences
            ?.edit()
            ?.putString(savedServersKey, buildSavedServersPersistencePayload(savedServers, includeFallbackCredentials).toString())
            ?.apply()
    }
}

private fun nullableString(
    item: JSONObject,
    key: String,
): String? {
    if (item.isNull(key)) {
        return null
    }
    val value = item.optString(key).trim()
    if (value.isEmpty() || value.equals("null", ignoreCase = true)) {
        return null
    }
    return value
}

internal fun computePlaceholderKeysToPrune(
    serverId: String,
    authoritativeKeys: Set<ThreadKey>,
    activeThreadKey: ThreadKey?,
    threadsByKey: Map<ThreadKey, ThreadState>,
): Set<ThreadKey> {
    if (threadsByKey.isEmpty()) {
        return emptySet()
    }
    return threadsByKey
        .asSequence()
        .filter { (key, thread) ->
            key.serverId == serverId &&
                thread.isPlaceholder &&
                key != activeThreadKey &&
                !authoritativeKeys.contains(key)
        }.map { (key, _) -> key }
        .toSet()
}

private val LOCAL_IMAGE_MARKER_REGEX = Regex("\\[\\[litter_local_image:([^\\]]+)]]")

internal fun buildOpenCodePromptParts(
    text: String,
    localImageDataUrl: String? = null,
    localImagePath: String? = null,
): JSONArray {
    val parts = JSONArray()
    val trimmedText = text.trim()
    if (trimmedText.isNotEmpty()) {
        parts.put(
            JSONObject()
                .put("type", "text")
                .put("text", trimmedText),
        )
    }
    val normalizedLocalImagePath = localImagePath?.trim()?.takeIf { it.isNotEmpty() }
    if (localImageDataUrl != null && normalizedLocalImagePath != null) {
        val file = File(normalizedLocalImagePath)
        parts.put(
            JSONObject()
                .put("type", "file")
                .put("mime", dataUrlMimeType(localImageDataUrl) ?: localImageMimeType(normalizedLocalImagePath))
                .put("filename", file.name.ifEmpty { normalizedLocalImagePath })
                .put("url", localImageDataUrl),
        )
    } else if (normalizedLocalImagePath != null) {
        val file = File(normalizedLocalImagePath)
        parts.put(
            JSONObject()
                .put("type", "file")
                .put("mime", localImageMimeType(normalizedLocalImagePath))
                .put("filename", file.name.ifEmpty { normalizedLocalImagePath })
                .put("url", file.toURI().toASCIIString()),
        )
    }
    return parts
}

internal fun buildSavedServersPersistencePayload(
    savedServers: Collection<SavedServer>,
    includeCredentials: Boolean = false,
): JSONArray {
    val payload = JSONArray()
    for (saved in savedServers) {
        val encoded =
            JSONObject()
                .put("id", saved.id)
                .put("name", saved.name)
                .put("host", saved.host)
                .put("port", saved.port)
                .put("source", saved.source)
                .put("backendKind", saved.backendKind)
                .put("hasCodexServer", saved.hasCodexServer)
                .put("directory", saved.directory ?: JSONObject.NULL)
                .put("websocketUrl", saved.websocketUrl ?: JSONObject.NULL)
        if (includeCredentials) {
            encoded
                .put("username", saved.username ?: JSONObject.NULL)
                .put("password", saved.password ?: JSONObject.NULL)
        }
        payload.put(encoded)
    }
    return payload
}

internal fun localImageMimeType(path: String): String =
    when (File(path).extension.lowercase(Locale.US)) {
        "png" -> "image/png"
        "webp" -> "image/webp"
        "gif" -> "image/gif"
        "jpg", "jpeg" -> "image/jpeg"
        else -> "image/jpeg"
    }

private fun dataUrlMimeType(dataUrl: String): String? {
    val trimmed = dataUrl.trim()
    if (!trimmed.startsWith("data:", ignoreCase = true)) {
        return null
    }
    return trimmed
        .removePrefix("data:")
        .substringBefore(';')
        .trim()
        .takeIf { it.isNotEmpty() }
}

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
    val source = opt("source") as? JSONObject
    val subAgent = (source?.opt("subAgent") as? JSONObject) ?: (source?.opt("sub_agent") as? JSONObject)
    val threadSpawn = (subAgent?.opt("thread_spawn") as? JSONObject) ?: (subAgent?.opt("threadSpawn") as? JSONObject)
    val fallbackKeys = arrayOf("thread_id", "threadId", "conversation_id", "conversationId")
    for (key in fallbackKeys) {
        if (!(threadSpawn?.has(key) == true)) {
            continue
        }
        val value = threadSpawn?.opt(key)
        val threadId = value.asLongOrNull()?.toString() ?: value?.toString()
        val trimmed = threadId?.trim()
        if (!trimmed.isNullOrEmpty()) {
            return trimmed
        }
    }
    return null
}
