package com.litter.android.state

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.Closeable
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean

internal class OpenCodeClient(
    private val server: ServerConfig,
) : Closeable {
    private companion object {
        private const val DEFAULT_READ_TIMEOUT_MS = 20_000
        private const val LOG_TAG = "LitterOpenCode"
    }

    private val closed = AtomicBoolean(false)
    private var eventThread: Thread? = null
    private var eventConnection: HttpURLConnection? = null

    fun connect() {
        Log.d(LOG_TAG, "health check start server=${server.id} host=${server.host}:${server.port}")
        val response = request("GET", "/global/health")
        if (!response.optBoolean("healthy", false)) {
            throw IllegalStateException("OpenCode server is not healthy")
        }
        Log.d(LOG_TAG, "health check ok server=${server.id}")
    }

    fun currentDirectory(): String? =
        runCatching { request("GET", "/path").optString("directory").trim().ifBlank { null } }.getOrNull()

    fun listSessions(): JSONArray {
        val directory = scopedDirectory()
        val query = if (directory != null) "?directory=${urlEncode(directory)}" else ""
        return requestArray("GET", "/session$query")
    }

    fun listStatuses(): JSONObject =
        request("GET", "/session/status")

    fun loadMessages(sessionId: String): JSONArray =
        requestArray("GET", "/session/$sessionId/message")

    fun createSession(): JSONObject =
        request("POST", "/session", JSONObject())

    fun listSlashes(): JSONArray =
        runCatching { requestArray("GET", "/slash") }
            .getOrElse {
                val commands = requestArray("GET", "/command")
                JSONArray().also { items ->
                    for (index in 0 until commands.length()) {
                        val item = commands.optJSONObject(index) ?: continue
                        val source = item.optString("source").trim().ifBlank { null }
                        if (source == "skill") {
                            continue
                        }
                        val name = item.optString("name").trim()
                        if (name.isEmpty()) {
                            continue
                        }
                        items.put(
                            JSONObject()
                                .put("id", "command:$name")
                                .put("kind", "command")
                                .put("name", name)
                                .put("aliases", JSONArray())
                                .put("description", item.optString("description").trim())
                                .put("category", if (source == "mcp") "MCP" else "Prompt")
                                .put("source", source ?: JSONObject.NULL)
                                .put("displayName", "/$name${if (source == "mcp") ":mcp" else ""}"),
                        )
                    }
                }
            }

    fun listSkills(): JSONArray =
        requestArray("GET", "/skill")

    fun listAgents(): JSONArray =
        requestArray("GET", "/agent")

    fun listMcpStatus(): JSONObject =
        request("GET", "/mcp")

    fun listProviders(): JSONObject =
        request("GET", "/provider")

    fun listConfigProviders(): JSONObject =
        request("GET", "/config/providers")

    fun pathInfo(): JSONObject =
        request("GET", "/path")

    fun vcsInfo(): JSONObject =
        request("GET", "/vcs")

    fun lspStatus(): JSONArray =
        requestArray("GET", "/lsp")

    fun formatterStatus(): JSONArray =
        requestArray("GET", "/formatter")

    fun sendPrompt(
        sessionId: String,
        parts: JSONArray,
        model: JSONObject? = null,
        agent: String? = null,
    ) {
        val body =
            JSONObject()
                .put("parts", parts)
                .apply {
                    putOpt("model", model)
                    putOpt("agent", agent?.trim()?.ifEmpty { null })
                }
        requestEmpty(
            "POST",
            "/session/$sessionId/prompt_async",
            body,
            expectedStatus = 204,
        )
    }

    fun executeCommand(
        sessionId: String,
        command: String,
        arguments: String,
        model: String? = null,
        agent: String? = null,
        parts: JSONArray? = null,
    ): JSONObject =
        request(
            "POST",
            "/session/$sessionId/command",
            JSONObject()
                .put("command", command)
                .put("arguments", arguments)
                .apply {
                    putOpt("model", model?.trim()?.ifEmpty { null })
                    putOpt("agent", agent?.trim()?.ifEmpty { null })
                    putOpt("parts", parts)
                },
        )

    fun abort(sessionId: String) {
        requestRaw("POST", "/session/$sessionId/abort", JSONObject(), expectedStatus = null)
    }

    fun shareSession(sessionId: String): JSONObject =
        request("POST", "/session/$sessionId/share", JSONObject())

    fun unshareSession(sessionId: String): JSONObject =
        request("DELETE", "/session/$sessionId/share")

    fun summarizeSession(
        sessionId: String,
        providerId: String,
        modelId: String,
    ): JSONObject =
        request(
            "POST",
            "/session/$sessionId/summarize",
            JSONObject()
                .put("providerID", providerId)
                .put("modelID", modelId),
        )

    fun revertSession(
        sessionId: String,
        messageId: String,
    ): JSONObject =
        request(
            "POST",
            "/session/$sessionId/revert",
            JSONObject().put("messageID", messageId),
        )

    fun unrevertSession(sessionId: String): JSONObject =
        request("POST", "/session/$sessionId/unrevert", JSONObject())

    fun renameSession(
        sessionId: String,
        title: String,
    ) {
        request("PATCH", "/session/$sessionId", JSONObject().put("title", title))
    }

    fun archiveSession(
        sessionId: String,
        archived: Boolean,
    ) {
        val time = if (archived) System.currentTimeMillis() else JSONObject.NULL
        request("PATCH", "/session/$sessionId", JSONObject().put("time", JSONObject().put("archived", time)))
    }

    fun forkSession(sessionId: String): JSONObject =
        request("POST", "/session/$sessionId/fork", JSONObject())

    fun listPermissions(): JSONArray =
        requestArray("GET", "/permission")

    fun replyPermission(
        requestId: String,
        reply: String,
    ) {
        request("POST", "/permission/$requestId/reply", JSONObject().put("reply", reply))
    }

    fun listQuestions(): JSONArray =
        requestArray("GET", "/question")

    fun replyQuestion(
        requestId: String,
        answers: List<List<String>>,
    ) {
        val encodedAnswers = JSONArray()
        answers.forEach { answer ->
            val values = JSONArray()
            answer.forEach(values::put)
            encodedAnswers.put(values)
        }
        request("POST", "/question/$requestId/reply", JSONObject().put("answers", encodedAnswers))
    }

    fun rejectQuestion(requestId: String) {
        request("POST", "/question/$requestId/reject", JSONObject())
    }

    fun subscribeEvents(onEvent: (JSONObject) -> Unit) {
        closeEventStream()
        eventThread =
            Thread {
                while (!closed.get()) {
                    var connection: HttpURLConnection? = null
                    try {
                        connection = openConnection("/event", "GET", readTimeoutMs = 0)
                        connection.setRequestProperty("Accept", "text/event-stream")
                        connection.connect()
                        if (connection.responseCode !in 200..299) {
                            throw IllegalStateException("OpenCode event stream failed with HTTP ${connection.responseCode}")
                        }
                        Log.d(LOG_TAG, "event stream connected server=${server.id}")
                        eventConnection = connection
                        val reader =
                            BufferedReader(
                                InputStreamReader(connection.inputStream, StandardCharsets.UTF_8),
                            )
                        val data = StringBuilder()
                        while (!closed.get()) {
                            val line = reader.readLine() ?: break
                            if (line.isEmpty()) {
                                if (data.isNotEmpty()) {
                                    val payload = data.toString().trim()
                                    if (payload.isNotEmpty()) {
                                        val json = JSONObject(payload)
                                        val eventPayload = json.optJSONObject("payload") ?: json
                                        val eventType = eventPayload.optString("type").ifBlank { "unknown" }
                                        Log.d(LOG_TAG, "event server=${server.id} type=$eventType")
                                        onEvent(json)
                                    }
                                    data.setLength(0)
                                }
                                continue
                            }
                            if (line.startsWith("data:")) {
                                data.append(line.removePrefix("data:").trim()).append('\n')
                            }
                        }
                    } catch (_: Throwable) {
                        if (closed.get()) {
                            return@Thread
                        }
                        Log.w(LOG_TAG, "event stream disconnected server=${server.id}, retrying")
                        Thread.sleep(500L)
                    } finally {
                        connection?.disconnect()
                        eventConnection = null
                    }
                }
            }.apply {
                name = "Litter-OpenCode-Events-${server.id}"
                isDaemon = true
                start()
            }
    }

    override fun close() {
        closed.set(true)
        closeEventStream()
        eventThread?.interrupt()
        eventThread = null
    }

    private fun closeEventStream() {
        eventConnection?.disconnect()
        eventConnection = null
    }

    private fun scopedDirectory(): String? =
        server.directory?.trim()?.ifBlank { null }

    private fun request(
        method: String,
        path: String,
        body: JSONObject? = null,
    ): JSONObject {
        val response = requestRaw(method, path, body, expectedStatus = null)
        return if (response.isBlank()) JSONObject() else JSONObject(response)
    }

    private fun requestArray(
        method: String,
        path: String,
    ): JSONArray {
        val response = requestRaw(method, path, null, expectedStatus = null)
        return if (response.isBlank()) JSONArray() else JSONArray(response)
    }

    private fun requestEmpty(
        method: String,
        path: String,
        body: JSONObject? = null,
        expectedStatus: Int,
    ) {
        requestRaw(method, path, body, expectedStatus = expectedStatus)
    }

    private fun requestRaw(
        method: String,
        path: String,
        body: JSONObject?,
        expectedStatus: Int?,
    ): String {
        Log.d(LOG_TAG, "request start server=${server.id} method=$method path=$path")
        val connection = openConnection(path, method)
        return try {
            if (body != null) {
                connection.doOutput = true
                OutputStreamWriter(connection.outputStream, StandardCharsets.UTF_8).use { writer ->
                    writer.write(body.toString())
                }
            }
            val status = connection.responseCode
            if (expectedStatus != null) {
                if (status != expectedStatus) {
                    Log.w(LOG_TAG, "request failed server=${server.id} method=$method path=$path status=$status")
                    throw IllegalStateException(readError(connection, status))
                }
            } else if (status !in 200..299) {
                Log.w(LOG_TAG, "request failed server=${server.id} method=$method path=$path status=$status")
                throw IllegalStateException(readError(connection, status))
            }
            Log.d(LOG_TAG, "request ok server=${server.id} method=$method path=$path status=$status")
            BufferedReader(InputStreamReader(connection.inputStream, StandardCharsets.UTF_8)).use { reader ->
                reader.readText()
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun readError(
        connection: HttpURLConnection,
        status: Int,
    ): String {
        val text =
            runCatching {
                connection.errorStream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }
            }.getOrNull()
        return "OpenCode request failed with HTTP $status${if (text.isNullOrBlank()) "" else ": $text"}"
    }

    private fun openConnection(
        path: String,
        method: String,
        readTimeoutMs: Int = DEFAULT_READ_TIMEOUT_MS,
    ): HttpURLConnection {
        val baseUrl =
            if (server.host.contains("://")) {
                val parsed = URL(server.host)
                val port = if (parsed.port > 0) parsed.port else server.port
                URL(parsed.protocol, parsed.host, port, openCodePath(parsed.path, path))
            } else {
                val normalizedHost =
                    if (server.host.contains(':') && !server.host.startsWith("[") && !server.host.endsWith("]")) {
                        "[${server.host}]"
                    } else {
                        server.host
                    }
                URL("http://$normalizedHost:${server.port}$path")
            }
        return (baseUrl.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 8_000
            readTimeout = readTimeoutMs
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Content-Type", "application/json")
            server.username
                ?.takeIf { server.password != null }
                ?.let { username ->
                    setRequestProperty("Authorization", basicAuth(username, server.password.orEmpty()))
                }
                ?: server.password?.let { password ->
                    setRequestProperty("Authorization", basicAuth("opencode", password))
                }
            scopedDirectory()?.let { directory ->
                setRequestProperty("x-opencode-directory", urlEncode(directory))
            }
        }
    }

    private fun basicAuth(
        username: String,
        password: String,
    ): String {
        val raw = "$username:$password".toByteArray(StandardCharsets.UTF_8)
        return "Basic ${Base64.getEncoder().encodeToString(raw)}"
    }

    private fun urlEncode(value: String): String =
        java.net.URLEncoder.encode(value, StandardCharsets.UTF_8.toString())
}

internal fun openCodePath(
    base: String?,
    path: String,
): String {
    val prefix = base?.trim().orEmpty().trimEnd('/').ifEmpty { "/" }
    val suffix = path.trim().ifEmpty { "/" }
    if (prefix == "/") {
        return if (suffix.startsWith("/")) suffix else "/$suffix"
    }
    return buildString {
        append(prefix)
        if (!suffix.startsWith("/")) {
            append('/')
        }
        append(suffix)
    }
}
