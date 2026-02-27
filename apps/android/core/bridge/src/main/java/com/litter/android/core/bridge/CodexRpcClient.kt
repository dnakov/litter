package com.litter.android.core.bridge

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicInteger

// This client exists for on-device bridge bootstrap and legacy callsites.
// App runtime message/session flows use app/state/BridgeRpcTransport.
class CodexRpcClient {
    private var activePort: Int? = null
    private var serverUrl: String? = null
    private var activeThreadId: String? = null
    private var rpcClient: JsonRpcWebSocketClient? = null
    private var initialized = false
    private var initializeResponse: InitializeResponse? = null

    private val listenerCounter = AtomicInteger(1)
    private val notificationListeners = mutableMapOf<Int, (String, JSONObject) -> Unit>()
    private val websocketListenerIds = mutableMapOf<Int, Int>()

    suspend fun connect(timeoutSeconds: Long = 15): Int = connectBlocking(timeoutSeconds)

    suspend fun initialize(): InitializeResponse = initializeBlocking()

    suspend fun connectAndInitialize(timeoutSeconds: Long = 15): Int {
        connectBlocking(timeoutSeconds)
        initializeBlocking()
        return activePort ?: throw IllegalStateException("Codex bridge server port unavailable")
    }

    suspend fun listThreads(
        cwd: String? = null,
        cursor: String? = null,
        limit: Int? = 20,
    ): ThreadListResponse = listThreadsBlocking(cwd = cwd, cursor = cursor, limit = limit)

    suspend fun startThread(
        cwd: String,
        model: String? = null,
    ): ThreadStartResponse = startThreadBlocking(cwd = cwd, model = model)

    suspend fun resumeThread(
        threadId: String,
        cwd: String,
    ): ThreadResumeResponse = resumeThreadBlocking(threadId = threadId, cwd = cwd)

    suspend fun sendTurn(
        threadId: String,
        text: String,
        model: String? = null,
        effort: String? = null,
    ): TurnStartResponse = sendTurnBlocking(threadId = threadId, text = text, model = model, effort = effort)

    suspend fun interrupt(threadId: String) {
        interruptBlocking(threadId)
    }

    suspend fun listModels(
        cursor: String? = null,
        limit: Int? = 50,
        includeHidden: Boolean = false,
    ): ModelListResponse = listModelsBlocking(cursor = cursor, limit = limit, includeHidden = includeHidden)

    suspend fun executeCommand(
        command: List<String>,
        cwd: String? = null,
        timeoutMs: Int? = null,
    ): CommandExecResponse = executeCommandBlocking(command = command, cwd = cwd, timeoutMs = timeoutMs)

    @Synchronized
    fun addNotificationListener(listener: (String, JSONObject) -> Unit): Int {
        val listenerId = listenerCounter.getAndIncrement()
        notificationListeners[listenerId] = listener
        rpcClient?.let { client ->
            websocketListenerIds[listenerId] = client.addNotificationListener(listener)
        }
        return listenerId
    }

    @Synchronized
    fun removeNotificationListener(listenerId: Int) {
        notificationListeners.remove(listenerId)
        val websocketId = websocketListenerIds.remove(listenerId)
        val client = rpcClient
        if (client != null && websocketId != null) {
            client.removeNotificationListener(websocketId)
        }
    }

    // Legacy compatibility for current Android callers.
    fun ensureServerStarted(): Int = connectAndInitializeBlocking()

    // Legacy compatibility for current Android callers.
    fun listSessions(): List<SessionSummary> {
        val response = listThreadsBlocking(cwd = null, cursor = null, limit = 20)
        return response.data.map { summary ->
            SessionSummary(
                id = summary.id,
                title = summary.preview.ifBlank { "Session ${summary.id}" },
            )
        }
    }

    // Legacy compatibility for current Android callers.
    fun startTurn(prompt: String): String {
        val threadId = ensureLegacyThreadStarted()
        val turnResult = sendTurnBlocking(threadId = threadId, text = prompt, model = null, effort = null)
        val url = synchronized(this) { serverUrl } ?: "ws://127.0.0.1:${activePort ?: "?"}"
        val turnId = turnResult.turnId
        return if (turnId.isNullOrBlank()) {
            "threadId='$threadId' via $url"
        } else {
            "turnId='$turnId' threadId='$threadId' via $url"
        }
    }

    @Synchronized
    fun stop() {
        rpcClient?.close()
        rpcClient = null
        activeThreadId = null
        serverUrl = null
        initialized = false
        initializeResponse = null
        websocketListenerIds.clear()
        NativeCodexBridge.stopServer()
        activePort = null
    }

    private fun listThreadsBlocking(
        cwd: String?,
        cursor: String?,
        limit: Int?,
    ): ThreadListResponse {
        val result = request(
            method = "thread/list",
            params =
                JSONObject()
                    .put("cursor", cursor ?: JSONObject.NULL)
                    .put("limit", limit ?: JSONObject.NULL)
                    .put("sortKey", "updated_at")
                    .put("cwd", cwd ?: JSONObject.NULL)
        )

        val summaries = mutableListOf<ThreadSummary>()
        val items = result.optJSONArray("data")
        if (items != null) {
            for (index in 0 until items.length()) {
                val item = items.optJSONObject(index) ?: continue
                val id = item.stringOrNull("id") ?: continue
                summaries +=
                    ThreadSummary(
                        id = id,
                        preview = item.stringOrNull("preview").orEmpty(),
                        modelProvider = item.stringOrNull("modelProvider").orEmpty(),
                        createdAt = item.longOrDefault("createdAt", 0L),
                        updatedAt = item.longOrDefault("updatedAt", 0L),
                        cwd = item.stringOrNull("cwd").orEmpty(),
                        cliVersion = item.stringOrNull("cliVersion").orEmpty(),
                    )
            }
        }
        return ThreadListResponse(data = summaries, nextCursor = result.stringOrNull("nextCursor"))
    }

    private fun startThreadBlocking(
        cwd: String,
        model: String?,
    ): ThreadStartResponse {
        val response =
            runCatching { startThreadWithSandbox(cwd = cwd, model = model, sandbox = DEFAULT_SANDBOX_MODE) }
                .getOrElse { error ->
                    if (!shouldRetryWithoutLinuxSandbox(error)) {
                        throw error
                    }
                    startThreadWithSandbox(cwd = cwd, model = model, sandbox = FALLBACK_SANDBOX_MODE)
                }
        synchronized(this) {
            activeThreadId = response.thread.id
        }
        return response
    }

    private fun resumeThreadBlocking(
        threadId: String,
        cwd: String,
    ): ThreadResumeResponse {
        val response =
            runCatching { resumeThreadWithSandbox(threadId = threadId, cwd = cwd, sandbox = DEFAULT_SANDBOX_MODE) }
                .getOrElse { error ->
                    if (!shouldRetryWithoutLinuxSandbox(error)) {
                        throw error
                    }
                    resumeThreadWithSandbox(threadId = threadId, cwd = cwd, sandbox = FALLBACK_SANDBOX_MODE)
                }
        synchronized(this) {
            activeThreadId = response.thread.id
        }
        return response
    }

    private fun sendTurnBlocking(
        threadId: String,
        text: String,
        model: String?,
        effort: String?,
    ): TurnStartResponse {
        val result = request(
            method = "turn/start",
            params =
                JSONObject()
                    .put("threadId", threadId)
                    .put(
                        "input",
                        JSONArray().put(
                            JSONObject()
                                .put("type", "text")
                                .put("text", text)
                        )
                    )
                    .put("model", model ?: JSONObject.NULL)
                    .put("effort", effort ?: JSONObject.NULL)
        )
        return TurnStartResponse(turnId = result.stringOrNull("turnId"))
    }

    private fun interruptBlocking(threadId: String) {
        request(
            method = "turn/interrupt",
            params = JSONObject().put("threadId", threadId),
        )
    }

    private fun listModelsBlocking(
        cursor: String?,
        limit: Int?,
        includeHidden: Boolean,
    ): ModelListResponse {
        val result = request(
            method = "model/list",
            params =
                JSONObject()
                    .put("cursor", cursor ?: JSONObject.NULL)
                    .put("limit", limit ?: JSONObject.NULL)
                    .put("includeHidden", includeHidden)
        )

        val models = mutableListOf<CodexModel>()
        val items = result.optJSONArray("data")
        if (items != null) {
            for (index in 0 until items.length()) {
                val item = items.optJSONObject(index) ?: continue
                val modelId = item.stringOrNull("id") ?: item.stringOrNull("model") ?: continue
                val reasoningEfforts = parseReasoningEfforts(item)
                val defaultReasoningEffort =
                    item.stringOrNull("defaultReasoningEffort")
                        ?: reasoningEfforts.firstOrNull()?.reasoningEffort
                        ?: ""
                val inputModalities = item.stringArrayOrNull("inputModalities")
                val supportsPersonality =
                    if (item.has("supportsPersonality") && !item.isNull("supportsPersonality")) {
                        item.booleanOrDefault("supportsPersonality", false)
                    } else {
                        null
                    }
                models +=
                    CodexModel(
                        id = modelId,
                        model = item.stringOrNull("model") ?: modelId,
                        upgrade = item.stringOrNull("upgrade"),
                        displayName = item.stringOrNull("displayName") ?: modelId,
                        description = item.stringOrNull("description").orEmpty(),
                        hidden = item.booleanOrDefault("hidden", false),
                        supportedReasoningEfforts = reasoningEfforts,
                        defaultReasoningEffort = defaultReasoningEffort,
                        inputModalities = inputModalities,
                        supportsPersonality = supportsPersonality,
                        isDefault = item.booleanOrDefault("isDefault", false),
                    )
            }
        }
        return ModelListResponse(data = models, nextCursor = result.stringOrNull("nextCursor"))
    }

    private fun executeCommandBlocking(
        command: List<String>,
        cwd: String?,
        timeoutMs: Int?,
    ): CommandExecResponse {
        val commandArray = JSONArray()
        command.forEach { commandArray.put(it) }
        val result = request(
            method = "command/exec",
            params =
                JSONObject()
                    .put("command", commandArray)
                    .put("timeoutMs", timeoutMs ?: JSONObject.NULL)
                    .put("cwd", cwd ?: JSONObject.NULL)
        )

        return CommandExecResponse(
            exitCode = result.intOrDefault("exitCode", 0),
            stdout = result.stringOrNull("stdout").orEmpty(),
            stderr = result.stringOrNull("stderr").orEmpty(),
        )
    }

    private fun parseReasoningEfforts(item: JSONObject): List<ReasoningEffortOption> {
        val out = mutableListOf<ReasoningEffortOption>()
        val efforts = item.optJSONArray("supportedReasoningEfforts") ?: return out
        for (index in 0 until efforts.length()) {
            val effortObject = efforts.optJSONObject(index)
            if (effortObject != null) {
                val reasoningEffort = effortObject.stringOrNull("reasoningEffort") ?: continue
                out +=
                    ReasoningEffortOption(
                        reasoningEffort = reasoningEffort,
                        description = effortObject.stringOrNull("description").orEmpty(),
                    )
                continue
            }
            val scalar = efforts.opt(index)?.toString()?.trim().orEmpty()
            if (scalar.isNotEmpty()) {
                out += ReasoningEffortOption(reasoningEffort = scalar, description = "")
            }
        }
        return out
    }

    private fun startThreadWithSandbox(
        cwd: String,
        model: String?,
        sandbox: String,
    ): ThreadStartResponse {
        val response = request(
            method = "thread/start",
            params =
                JSONObject()
                    .put("model", model ?: JSONObject.NULL)
                    .put("cwd", cwd)
                    .put("approvalPolicy", "never")
                    .put("sandbox", sandbox)
        )

        val thread = response.optJSONObject("thread") ?: JSONObject()
        val threadId = thread.stringOrNull("id")
            ?: throw IllegalStateException("thread/start returned no thread id")
        return ThreadStartResponse(
            thread = ThreadInfo(id = threadId),
            model = response.stringOrNull("model"),
            cwd = response.stringOrNull("cwd"),
        )
    }

    private fun resumeThreadWithSandbox(
        threadId: String,
        cwd: String,
        sandbox: String,
    ): ThreadResumeResponse {
        val response = request(
            method = "thread/resume",
            params =
                JSONObject()
                    .put("threadId", threadId)
                    .put("cwd", cwd)
                    .put("approvalPolicy", "never")
                    .put("sandbox", sandbox)
        )

        val threadObject = response.optJSONObject("thread") ?: JSONObject()
        val resumedThreadId = threadObject.stringOrNull("id") ?: threadId
        val turns = parseTurns(threadObject)
        return ThreadResumeResponse(
            thread = ResumedThread(id = resumedThreadId, turns = turns),
            model = response.stringOrNull("model"),
            cwd = response.stringOrNull("cwd"),
        )
    }

    private fun parseTurns(threadObject: JSONObject): List<ResumedTurn> {
        val turnsArray = threadObject.optJSONArray("turns")
        if (turnsArray != null) {
            val turns = mutableListOf<ResumedTurn>()
            for (index in 0 until turnsArray.length()) {
                val turnObject = turnsArray.optJSONObject(index) ?: continue
                val turnId = turnObject.stringOrNull("id") ?: "turn-$index"
                turns += ResumedTurn(id = turnId, items = parseItems(turnObject.optJSONArray("items")))
            }
            return turns
        }

        val flatItems = parseItems(threadObject.optJSONArray("items"))
        if (flatItems.isNotEmpty()) {
            return listOf(ResumedTurn(id = "legacy-turn", items = flatItems))
        }
        return emptyList()
    }

    private fun parseItems(items: JSONArray?): List<JSONObject> {
        if (items == null) return emptyList()
        val out = mutableListOf<JSONObject>()
        for (index in 0 until items.length()) {
            when (val value = items.opt(index)) {
                is JSONObject -> out += value
                null, JSONObject.NULL -> {}
                else -> out += JSONObject().put("value", value)
            }
        }
        return out
    }

    private fun ensureLegacyThreadStarted(): String {
        synchronized(this) {
            activeThreadId?.let { return it }
        }
        val cwd = ((System.getProperty("java.io.tmpdir") ?: "/data/local/tmp")).trim().ifBlank { "/data/local/tmp" }
        File(cwd).mkdirs()
        val started = startThreadBlocking(cwd = cwd, model = null)
        synchronized(this) {
            activeThreadId = started.thread.id
            return started.thread.id
        }
    }

    private fun request(
        method: String,
        params: JSONObject? = null,
    ): JSONObject {
        return runCatching {
            rpc().request(method = method, params = params)
        }.getOrElse { error ->
            if (!isRecoverableTransportFailure(error)) {
                throw error
            }
            synchronized(this) {
                recoverTransportAfterFailure(error)
            }
            rpc().request(method = method, params = params)
        }
    }

    @Synchronized
    private fun rpc(): JsonRpcWebSocketClient {
        connectAndInitializeBlocking()
        return rpcClient ?: throw IllegalStateException("Codex bridge RPC client unavailable")
    }

    @Synchronized
    private fun connectAndInitializeBlocking(timeoutSeconds: Long = 15): Int {
        connectBlocking(timeoutSeconds = timeoutSeconds)
        initializeBlocking()
        return activePort ?: throw IllegalStateException("Codex bridge server port unavailable")
    }

    @Synchronized
    private fun connectBlocking(timeoutSeconds: Long = 15): Int {
        val port = activePort ?: startLocalBridgeServer()
        val url = serverUrl ?: "$LOCAL_BRIDGE_URL_PREFIX$port"
        val currentClient = rpcClient
        if (currentClient == null) {
            val connectedClient = connectWithRestartFallback(url = url, timeoutSeconds = timeoutSeconds)
            rpcClient = connectedClient
            resetInitializeState()
            attachNotificationListeners(connectedClient)
            return port
        }

        try {
            val reconnected = currentClient.connect(timeoutSeconds = timeoutSeconds)
            if (reconnected) {
                resetInitializeState()
            }
        } catch (error: Throwable) {
            currentClient.close()
            val connectedClient = connectWithRestartFallback(url = url, timeoutSeconds = timeoutSeconds)
            rpcClient = connectedClient
            resetInitializeState()
            attachNotificationListeners(connectedClient)
        }
        return activePort ?: port
    }

    @Synchronized
    private fun initializeBlocking(): InitializeResponse {
        if (initialized) {
            return initializeResponse ?: InitializeResponse()
        }
        val client = rpcClient ?: throw IllegalStateException("Codex bridge RPC client unavailable")
        val result = runCatching {
            client.request(
                method = "initialize",
                params =
                    JSONObject().put(
                        "clientInfo",
                        JSONObject()
                            .put("name", "Litter")
                            .put("version", "1.0")
                            .put("title", JSONObject.NULL)
                    ).put(
                        "capabilities",
                        JSONObject()
                            .put("experimentalApi", true)
                    )
            )
        }.getOrElse { error ->
            if (!isRecoverableTransportFailure(error)) {
                throw error
            }
            recoverTransportAfterFailure(error)
            val recoveredClient = rpcClient ?: connectWithRestartFallback(
                url = serverUrl ?: "$LOCAL_BRIDGE_URL_PREFIX${startLocalBridgeServer()}",
                timeoutSeconds = 15,
            ).also { connectedClient ->
                rpcClient = connectedClient
                attachNotificationListeners(connectedClient)
            }
            recoveredClient.request(
                method = "initialize",
                params =
                    JSONObject().put(
                        "clientInfo",
                        JSONObject()
                            .put("name", "Litter")
                            .put("version", "1.0")
                            .put("title", JSONObject.NULL)
                    ).put(
                        "capabilities",
                        JSONObject()
                            .put("experimentalApi", true)
                    )
            )
        }
        val response = InitializeResponse(userAgent = result.stringOrNull("userAgent"))
        initialized = true
        initializeResponse = response
        return response
    }

    @Synchronized
    private fun attachNotificationListeners(client: JsonRpcWebSocketClient) {
        websocketListenerIds.clear()
        for ((listenerId, listener) in notificationListeners) {
            websocketListenerIds[listenerId] = client.addNotificationListener(listener)
        }
    }

    private fun shouldRetryWithoutLinuxSandbox(error: Throwable): Boolean {
        val lower = error.message?.lowercase().orEmpty()
        return lower.contains("codex-linux-sandbox was required but not provided") ||
            lower.contains("missing codex-linux-sandbox executable path")
    }

    private fun isRecoverableTransportFailure(error: Throwable): Boolean {
        if (error is IOException) {
            return true
        }
        val lower = error.message?.lowercase().orEmpty()
        if (lower.contains("websocket") || lower.contains("codex bridge request failed")) {
            return true
        }
        return error.cause?.let(::isRecoverableTransportFailure) ?: false
    }

    @Synchronized
    private fun recoverTransportAfterFailure(_cause: Throwable) {
        rpcClient?.close()
        rpcClient = null
        websocketListenerIds.clear()
        resetInitializeState()

        if (activePort != null && shouldStartOnDeviceBridge()) {
            runCatching { NativeCodexBridge.stopServer() }
            activePort = null
            serverUrl = null
        }
    }

    @Synchronized
    private fun resetInitializeState() {
        initialized = false
        initializeResponse = null
    }

    private fun shouldStartOnDeviceBridge(): Boolean = CodexRuntimeStartupPolicy.onDeviceBridgeEnabled()

    @Synchronized
    private fun startLocalBridgeServer(): Int {
        if (!shouldStartOnDeviceBridge()) {
            throw IllegalStateException(
                "On-device Codex bridge startup is disabled (mode=${CodexRuntimeStartupPolicy.runtimeMode()}). " +
                    "Connect to a remote server in this build flavor.",
            )
        }
        val startResult = NativeCodexBridge.startServerPort()
        if (startResult <= 0) {
            throw IllegalStateException("Failed to start Codex bridge server (status=$startResult)")
        }
        activePort = startResult
        serverUrl = "$LOCAL_BRIDGE_URL_PREFIX$startResult"
        return startResult
    }

    private fun connectWithRetry(
        url: String,
        timeoutSeconds: Long,
    ): JsonRpcWebSocketClient {
        var lastError: Throwable? = null
        repeat(3) { attempt ->
            val client = JsonRpcWebSocketClient(url)
            try {
                client.connect(timeoutSeconds = timeoutSeconds)
                return client
            } catch (error: Throwable) {
                lastError = error
                client.close()
                if (attempt < 2) {
                    Thread.sleep(350)
                }
            }
        }
        throw IllegalStateException("Failed to connect to Codex bridge at $url", lastError)
    }

    @Synchronized
    private fun connectWithRestartFallback(
        url: String,
        timeoutSeconds: Long,
    ): JsonRpcWebSocketClient {
        return runCatching {
            connectWithRetry(url = url, timeoutSeconds = timeoutSeconds)
        }.getOrElse { firstError ->
            if (!url.startsWith(LOCAL_BRIDGE_URL_PREFIX) || !shouldStartOnDeviceBridge()) {
                throw firstError
            }
            recoverTransportAfterFailure(firstError)
            val restartedPort = startLocalBridgeServer()
            connectWithRetry(
                url = "$LOCAL_BRIDGE_URL_PREFIX$restartedPort",
                timeoutSeconds = timeoutSeconds,
            )
        }
    }

    companion object {
        private const val DEFAULT_SANDBOX_MODE = "workspace-write"
        private const val FALLBACK_SANDBOX_MODE = "danger-full-access"
        private const val LOCAL_BRIDGE_URL_PREFIX = "ws://127.0.0.1:"
    }
}

object CodexRuntimeStartupPolicy {
    private const val APP_BUILD_CONFIG_CLASS = "com.sigkitten.litter.android.BuildConfig"
    private const val BUILD_CONFIG_FLAG = "ENABLE_ON_DEVICE_BRIDGE"
    private const val SYSTEM_PROPERTY = "litter.android.on_device_bridge.enabled"
    private const val ENV_VARIABLE = "LITTER_ANDROID_ON_DEVICE_BRIDGE_ENABLED"

    fun onDeviceBridgeEnabled(
        buildConfigValue: Boolean? = readBuildConfigFlag(),
        systemPropertyValue: String? = System.getProperty(SYSTEM_PROPERTY),
        environmentValue: String? = System.getenv(ENV_VARIABLE),
    ): Boolean {
        val fromSystemProperty = parseBooleanFlag(systemPropertyValue)
        if (fromSystemProperty != null) {
            return fromSystemProperty
        }
        val fromEnvironment = parseBooleanFlag(environmentValue)
        if (fromEnvironment != null) {
            return fromEnvironment
        }
        return buildConfigValue ?: true
    }

    fun runtimeMode(): String = if (onDeviceBridgeEnabled()) "hybrid" else "remote_only"

    fun parseBooleanFlag(raw: String?): Boolean? {
        val normalized = raw?.trim()?.lowercase() ?: return null
        return when (normalized) {
            "1", "true", "yes", "on" -> true
            "0", "false", "no", "off" -> false
            else -> null
        }
    }

    fun readBuildConfigFlag(
        className: String = APP_BUILD_CONFIG_CLASS,
        fieldName: String = BUILD_CONFIG_FLAG,
    ): Boolean? {
        return runCatching {
            val clazz = Class.forName(className)
            val field = clazz.getDeclaredField(fieldName)
            val value = field.get(null)
            value as? Boolean
        }.getOrNull()
    }
}

private fun JSONObject.stringOrNull(key: String): String? {
    if (!has(key) || isNull(key)) return null
    return opt(key)?.toString()?.trim()?.ifEmpty { null }
}

private fun JSONObject.longOrDefault(
    key: String,
    default: Long,
): Long {
    val value = opt(key)
    return when (value) {
        is Number -> value.toLong()
        is String -> value.toLongOrNull() ?: default
        else -> default
    }
}

private fun JSONObject.intOrDefault(
    key: String,
    default: Int,
): Int {
    val value = opt(key)
    return when (value) {
        is Number -> value.toInt()
        is String -> value.toIntOrNull() ?: default
        else -> default
    }
}

private fun JSONObject.booleanOrDefault(
    key: String,
    default: Boolean,
): Boolean {
    if (!has(key) || isNull(key)) return default
    val value = opt(key)
    return when (value) {
        is Boolean -> value
        is Number -> value.toInt() != 0
        is String -> value.equals("true", ignoreCase = true) || value == "1"
        else -> default
    }
}

private fun JSONObject.stringArrayOrNull(key: String): List<String>? {
    if (!has(key) || isNull(key)) return null
    val array = optJSONArray(key) ?: return null
    val out = mutableListOf<String>()
    for (index in 0 until array.length()) {
        val value = array.opt(index)?.toString()?.trim().orEmpty()
        if (value.isNotEmpty()) {
            out += value
        }
    }
    return out
}
