package com.litter.android.state

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.litter.android.core.bridge.CodexRpcClient
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.util.LinkedHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class ServerManager(
    context: Context? = null,
    private val codexRpcClient: CodexRpcClient = CodexRpcClient(),
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "Litter-ServerManager").apply { isDaemon = true }
    },
) : Closeable {
    private val listeners = CopyOnWriteArrayList<(AppState) -> Unit>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val threadsByKey = LinkedHashMap<ThreadKey, ThreadState>()
    private val transportsByServerId = LinkedHashMap<String, BridgeRpcTransport>()
    private val serversById = LinkedHashMap<String, ServerConfig>()
    private val accountByServerId = LinkedHashMap<String, AccountState>()

    private val appContext = context?.applicationContext
    private val savedServersPreferences by lazy {
        appContext?.getSharedPreferences("litter_saved_servers", Context.MODE_PRIVATE)
    }
    private val savedServersKey = "servers"

    @Volatile
    private var state: AppState = AppState(savedServers = loadSavedServersInternal())

    @Volatile
    private var closed = false

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

    fun loginWithChatGpt(onComplete: ((Result<AccountState>) -> Unit)? = null) {
        submit {
            val result = runCatching {
                val serverId = resolveServerIdForActiveOperations()
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
                val serverId = resolveServerIdForActiveOperations()
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

    fun resolveHomeDirectory(onComplete: ((Result<String>) -> Unit)? = null) {
        submit {
            val result = runCatching { resolveHomeDirectoryInternal() }
            deliver(onComplete, result)
        }
    }

    fun listDirectories(
        path: String,
        onComplete: ((Result<List<String>>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { listDirectoriesInternal(path) }
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

    fun startThread(
        cwd: String = defaultWorkingDirectory(),
        modelSelection: ModelSelection? = null,
        onComplete: ((Result<ThreadKey>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching { startThreadInternal(cwd, modelSelection) }
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
        onComplete: ((Result<Unit>) -> Unit)? = null,
    ) {
        submit {
            val result = runCatching {
                sendMessageInternal(
                    text = text,
                    cwd = cwd ?: state.currentCwd,
                    modelSelection = modelSelection ?: state.selectedModel,
                    localImagePath = localImagePath,
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

    override fun close() {
        if (closed) {
            return
        }
        closed = true
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
            if (server.source == ServerSource.LOCAL && server.port <= 0) {
                ServerConfig.local(codexRpcClient.ensureServerStarted())
            } else {
                server
            }

        val transport = BridgeRpcTransport(
            url = websocketUrl(normalizedServer),
            onNotification = { method, params ->
                submit {
                    handleNotification(normalizedServer.id, method, params)
                }
            },
        )

        try {
            transport.connect(timeoutSeconds = 15)
            sendInitialize(transport)
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
            it.copy(
                connectionStatus = ServerConnectionStatus.READY,
                connectionError = null,
                activeServerId = normalizedServer.id,
            )
        }

        return normalizedServer
    }

    private fun disconnectInternal(serverId: String?) {
        if (serverId == null) {
            transportsByServerId.values.forEach { runCatching { it.close() } }
            transportsByServerId.clear()
            serversById.clear()
            accountByServerId.clear()
            threadsByKey.clear()
            runCatching { codexRpcClient.stop() }
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

        if (removedServer?.source == ServerSource.LOCAL && serversById.values.none { it.source == ServerSource.LOCAL }) {
            runCatching { codexRpcClient.stop() }
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

    private fun websocketUrl(server: ServerConfig): String {
        val host = server.host.trim().ifEmpty { "127.0.0.1" }
        val normalizedHost =
            if (host.contains(':') && !host.startsWith("[") && !host.endsWith("]")) {
                "[$host]"
            } else {
                host
            }
        return "ws://$normalizedHost:${server.port}"
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
                    existing?.preview ?: "Session $threadId"
                }
                val cwd = item.optString("cwd").trim().ifBlank { existing?.cwd ?: state.currentCwd }
                val updatedAtRaw =
                    item.opt("updatedAt").asLongOrNull()
                        ?: item.opt("updated_at").asLongOrNull()
                        ?: System.currentTimeMillis()
                val updatedAtEpochMillis = normalizeEpochMillis(updatedAtRaw)

                threadsByKey[key] =
                    ThreadState(
                        key = key,
                        serverName = server.name,
                        serverSource = server.source,
                        status = existing?.status ?: ThreadStatus.READY,
                        messages = existing?.messages ?: emptyList(),
                        preview = preview,
                        cwd = cwd,
                        updatedAtEpochMillis = maxOf(updatedAtEpochMillis, existing?.updatedAtEpochMillis ?: 0L),
                        activeTurnId = existing?.activeTurnId,
                        lastError = existing?.lastError,
                    )
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

    private fun loginWithChatGptInternal(serverId: String): AccountState {
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

    private fun loginWithApiKeyInternal(
        serverId: String,
        apiKey: String,
    ): AccountState {
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

    private fun resolveHomeDirectoryInternal(): String {
        if (transportsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val serverId = resolveServerIdForActiveOperations()
        return runCatching {
            val result = executeCommandInternal(
                serverId = serverId,
                command = listOf("/bin/sh", "-lc", "printf %s \"${'$'}HOME\""),
                cwd = "/tmp",
            )
            val exitCode = result.optInt("exitCode", 0)
            val stdout = result.optString("stdout", "").trim()
            if (exitCode == 0 && stdout.isNotEmpty()) {
                stdout
            } else {
                "/"
            }
        }.getOrDefault("/")
    }

    private fun listDirectoriesInternal(path: String): List<String> {
        if (transportsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val serverId = resolveServerIdForActiveOperations()
        val normalized = path.trim().ifEmpty { "/" }
        val result = executeCommandInternal(
            serverId = serverId,
            command = listOf("/bin/ls", "-1ap", normalized),
            cwd = normalized,
        )
        val exitCode = result.optInt("exitCode", 0)
        if (exitCode != 0) {
            val stderr = result.optString("stderr", "").trim()
            if (stderr.isNotEmpty()) {
                throw IllegalStateException(stderr)
            }
            throw IllegalStateException("ls failed with code $exitCode")
        }

        val stdout = result.optString("stdout", "")
        return stdout
            .lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .filter { it.endsWith("/") && it != "./" && it != "../" }
            .map { it.removeSuffix("/") }
            .sorted()
            .toList()
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
    ): ThreadKey {
        if (transportsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }
        val serverId = resolveServerIdForActiveOperations()
        val server = ensureConnectedServer(serverId)
        val model = modelSelection?.modelId ?: state.selectedModel.modelId
        val response = startThreadWithFallback(serverId = serverId, cwd = cwd, model = model)
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
        threadsByKey[key] =
            ThreadState(
                key = key,
                serverName = server.name,
                serverSource = server.source,
                status = ThreadStatus.READY,
                messages = existing?.messages ?: emptyList(),
                preview = existing?.preview ?: "",
                cwd = cwd,
                updatedAtEpochMillis = now,
                activeTurnId = null,
                lastError = null,
            )

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
        return try {
            startThreadWithSandbox(serverId, cwd, model, sandbox = "workspace-write")
        } catch (error: Throwable) {
            if (!shouldRetryWithoutLinuxSandbox(error)) {
                throw error
            }
            startThreadWithSandbox(serverId, cwd, model, sandbox = "danger-full-access")
        }
    }

    private fun startThreadWithSandbox(
        serverId: String,
        cwd: String,
        model: String?,
        sandbox: String,
    ): JSONObject {
        val params =
            JSONObject()
                .put("model", model ?: JSONObject.NULL)
                .put("cwd", cwd)
                .put("approvalPolicy", "never")
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
            threadsByKey[key] =
                ThreadState(
                    key = key,
                    serverName = server.name,
                    serverSource = server.source,
                    status = ThreadStatus.READY,
                    messages = restored,
                    preview = derivePreview(restored, existing?.preview),
                    cwd = cwd,
                    updatedAtEpochMillis = now,
                    activeTurnId = null,
                    lastError = null,
                )
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
        return try {
            resumeThreadWithSandbox(serverId, threadId, cwd, sandbox = "workspace-write")
        } catch (error: Throwable) {
            if (!shouldRetryWithoutLinuxSandbox(error)) {
                throw error
            }
            resumeThreadWithSandbox(serverId, threadId, cwd, sandbox = "danger-full-access")
        }
    }

    private fun resumeThreadWithSandbox(
        serverId: String,
        threadId: String,
        cwd: String,
        sandbox: String,
    ): JSONObject {
        val params =
            JSONObject()
                .put("threadId", threadId)
                .put("cwd", cwd)
                .put("approvalPolicy", "never")
                .put("sandbox", sandbox)
        return requireTransport(serverId).request("thread/resume", params)
    }

    private fun sendMessageInternal(
        text: String,
        cwd: String,
        modelSelection: ModelSelection,
        localImagePath: String? = null,
    ) {
        val (cleanedText, embeddedLocalImagePath) = extractLocalImageMarker(text)
        val normalizedLocalImagePath =
            localImagePath?.trim()?.takeIf { it.isNotEmpty() }
                ?: embeddedLocalImagePath?.trim()?.takeIf { it.isNotEmpty() }
        val trimmed = cleanedText.trim()
        if (trimmed.isEmpty() && normalizedLocalImagePath == null) {
            return
        }

        if (transportsByServerId.isEmpty()) {
            connectLocalDefaultServerInternal()
        }

        val key = state.activeThreadKey ?: startThreadInternal(cwd, modelSelection)
        val serverId = key.serverId
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
                messages = existing.messages + ChatMessage(role = MessageRole.USER, text = userVisibleText),
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
        if (normalizedLocalImagePath != null) {
            input.put(
                JSONObject()
                    .put("type", "localImage")
                    .put("path", normalizedLocalImagePath),
            )
        }

        val params =
            JSONObject()
                .put("threadId", key.threadId)
                .put("input", input)
                .put("model", modelSelection.modelId ?: JSONObject.NULL)
                .put("effort", modelSelection.reasoningEffort ?: JSONObject.NULL)

        try {
            val response = requireTransport(serverId).request("turn/start", params)
            val turnId = response.optString("turnId").trim().takeIf { it.isNotEmpty() }
            val latest = threadsByKey[key] ?: return
            threadsByKey[key] =
                latest.copy(
                    status = ThreadStatus.THINKING,
                    activeTurnId = turnId,
                    updatedAtEpochMillis = System.currentTimeMillis(),
                )
            updateState { it }
        } catch (error: Throwable) {
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

    private fun interruptInternal() {
        val key = state.activeThreadKey ?: return
        val params = JSONObject().put("threadId", key.threadId)
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

    private fun handleNotification(
        serverId: String,
        method: String,
        params: JSONObject?,
    ) {
        when (method) {
            "account/login/completed" -> {
                val success = params?.optBoolean("success", false) ?: false
                if (success) {
                    val current = accountByServerId[serverId] ?: AccountState()
                    accountByServerId[serverId] = current.copy(oauthUrl = null, pendingLoginId = null, lastError = null)
                    runCatching { refreshAccountStateInternal(serverId) }
                } else {
                    val message = params?.optString("error")?.trim().orEmpty().ifBlank { "Login failed" }
                    val current = accountByServerId[serverId] ?: AccountState()
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

            "turn/started" -> {
                val threadId = params.optThreadId()
                val key = resolveThreadKey(serverId, threadId) ?: return
                val existing = ensureThreadState(key)
                val turnId = params?.optString("turnId")?.trim().takeIf { !it.isNullOrEmpty() } ?: existing.activeTurnId
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

            "item/completed" -> {
                val item = params?.optJSONObject("item") ?: return
                val key = resolveThreadKey(serverId, params.optThreadId()) ?: return
                val existing = ensureThreadState(key)
                val itemType = item.optString("type")

                if (itemType == "agentMessage" || itemType == "userMessage") {
                    return
                }

                val message = chatMessageFromItem(item) ?: return
                val updatedMessages = existing.messages + message
                threadsByKey[key] =
                    existing.copy(
                        messages = updatedMessages,
                        preview = derivePreview(updatedMessages, existing.preview),
                        updatedAtEpochMillis = System.currentTimeMillis(),
                    )
                updateState { it.copy(activeThreadKey = key, activeServerId = key.serverId) }
            }

            "turn/completed",
            "codex/event/task_complete" -> {
                val explicitThreadId = params.optThreadId()
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
                    }
                }
                updateState { it }
            }
        }
    }

    private fun restoreMessages(threadObject: JSONObject): List<ChatMessage> {
        val restored = ArrayList<ChatMessage>()
        val turns = threadObject.optJSONArray("turns")
        if (turns != null) {
            for (index in 0 until turns.length()) {
                val turn = turns.optJSONObject(index) ?: continue
                val items = turn.optJSONArray("items") ?: continue
                parseItemsInto(restored, items)
            }
            return restored
        }

        val legacyItems = threadObject.optJSONArray("items")
        if (legacyItems != null) {
            parseItemsInto(restored, legacyItems)
        }
        return restored
    }

    private fun parseItemsInto(
        out: MutableList<ChatMessage>,
        items: JSONArray,
    ) {
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            val message = chatMessageFromItem(item) ?: continue
            out += message
        }
    }

    private fun chatMessageFromItem(item: JSONObject): ChatMessage? {
        return when (item.optString("type")) {
            "userMessage" -> {
                val content = item.optJSONArray("content")
                val text = parseUserMessageText(content, item.optString("text"))
                if (text.isBlank()) null else ChatMessage(role = MessageRole.USER, text = text)
            }

            "agentMessage",
            "assistantMessage" -> {
                val text = item.optString("text").trim()
                if (text.isEmpty()) null else ChatMessage(role = MessageRole.ASSISTANT, text = text)
            }

            "plan" -> {
                val text = item.optString("text").trim()
                if (text.isEmpty()) null else systemMessage("Plan", text)
            }

            "reasoning" -> {
                val summary = readStringArray(item.opt("summary"))
                val content = readStringArray(item.opt("content"))
                val body = (summary + content).joinToString(separator = "\n\n").trim()
                if (body.isEmpty()) null else ChatMessage(role = MessageRole.REASONING, text = body)
            }

            "commandExecution" -> parseCommandExecutionMessage(item)
            "fileChange" -> parseFileChangeMessage(item)
            "mcpToolCall" -> parseMcpToolCallMessage(item)
            "collabAgentToolCall" -> parseCollabMessage(item)
            "webSearch" -> parseWebSearchMessage(item)
            "imageView" -> {
                val path = item.optString("path").trim()
                if (path.isEmpty()) null else systemMessage("Image View", "Path: $path")
            }

            "enteredReviewMode" -> {
                val review = item.optString("review").trim()
                systemMessage("Review Mode", "Entered review: $review")
            }

            "exitedReviewMode" -> {
                val review = item.optString("review").trim()
                systemMessage("Review Mode", "Exited review: $review")
            }

            "contextCompaction" -> systemMessage("Context", "Context compaction occurred.")
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
            val kind = change.optString("kind").trim()
            val diff = change.optString("diff").trim()
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
            val host = item.optString("host").trim()
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

private fun normalizeEpochMillis(raw: Long): Long {
    return if (raw < 1_000_000_000_000L) raw * 1000L else raw
}

private fun JSONObject?.optThreadId(): String? {
    if (this == null) {
        return null
    }
    val value = opt("threadId")
    val threadId = value.asLongOrNull()?.toString() ?: value?.toString()
    return threadId?.trim()?.takeIf { it.isNotEmpty() }
}
