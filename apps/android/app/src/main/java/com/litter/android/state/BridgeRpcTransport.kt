package com.litter.android.state

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

// Canonical app-runtime websocket transport used by ServerManager for user-facing RPC flows.
// The core bridge module has a separate websocket client for on-device bridge bootstrap only.
internal class BridgeRpcTransport(
    private val url: String,
    private val onNotification: (method: String, params: JSONObject?) -> Unit,
    private val onServerRequest: ((method: String, params: JSONObject?) -> JSONObject?)? = null,
) : Closeable {
    private val requestCounter = AtomicInteger(1)
    private val connectionEpochCounter = AtomicInteger(0)
    private val pending = ConcurrentHashMap<String, PendingRequest>()
    private val outputLock = Any()
    private val lifecycleLock = Any()
    private val random = SecureRandom()

    @Volatile
    private var socket: Socket? = null

    @Volatile
    private var input: InputStream? = null

    @Volatile
    private var output: OutputStream? = null

    @Volatile
    private var connected = false

    @Volatile
    private var connectedEpoch = 0

    @Volatile
    private var initializedEpoch = 0

    @Volatile
    private var readerThread: Thread? = null

    fun connect(timeoutSeconds: Long = 8): Boolean {
        synchronized(lifecycleLock) {
            if (!BridgeTransportReliabilityPolicy.shouldReconnect(
                    connected = connected,
                    socketConnected = socket?.isConnected == true,
                    socketClosed = socket?.isClosed ?: true,
                    hasInput = input != null,
                    hasOutput = output != null,
                    readerAlive = readerThread?.isAlive == true,
                )
            ) {
                return false
            }

            closeSocketLocked()

            val uri = URI(url)
            val host = uri.host ?: throw IllegalStateException("Invalid websocket host for URL: $url")
            val port = if (uri.port > 0) uri.port else 80
            val path = buildPath(uri)

            val sock = Socket()
            try {
                sock.connect(InetSocketAddress(host, port), (timeoutSeconds * 1000L).toInt())
                sock.soTimeout = (timeoutSeconds * 1000L).toInt()
                val inStream = sock.getInputStream()
                val outStream = sock.getOutputStream()

                performHandshake(
                    socket = sock,
                    input = inStream,
                    output = outStream,
                    host = host,
                    port = port,
                    path = path,
                )

                sock.soTimeout = 0
                socket = sock
                input = inStream
                output = outStream
                connected = true
                connectedEpoch = connectionEpochCounter.incrementAndGet()
                initializedEpoch = 0
                startReaderLocked(connectedEpoch)
                return true
            } catch (error: Throwable) {
                runCatching { sock.close() }
                throw IllegalStateException("Failed websocket connect/handshake at $url", error)
            }
        }
    }

    fun request(
        method: String,
        params: JSONObject? = null,
        timeoutSeconds: Long = 20,
    ): JSONObject {
        connect()
        if (method != INITIALIZE_METHOD) {
            ensureInitialized(timeoutSeconds)
        }

        val result = requestInternal(method = method, params = params, timeoutSeconds = timeoutSeconds)
        if (method == INITIALIZE_METHOD) {
            synchronized(lifecycleLock) {
                if (connected) {
                    initializedEpoch = connectedEpoch
                }
            }
        }
        return result
    }

    override fun close() {
        runCatching { sendFrame(0x8, ByteArray(0)) }
        markDisconnected(IOException("WebSocket disconnected"), expectedEpoch = null)
    }

    private fun ensureInitialized(timeoutSeconds: Long) {
        val epoch = connectedEpoch
        if (epoch == 0 || initializedEpoch == epoch) {
            return
        }

        requestInternal(
            method = INITIALIZE_METHOD,
            params = defaultInitializeParams(),
            timeoutSeconds = maxOf(timeoutSeconds, 8),
        )

        synchronized(lifecycleLock) {
            if (connectedEpoch == epoch && connected) {
                initializedEpoch = epoch
            }
        }
    }

    private fun requestInternal(
        method: String,
        params: JSONObject?,
        timeoutSeconds: Long,
    ): JSONObject {
        val id = requestCounter.getAndIncrement().toString()
        val payload = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", id)
            .put("method", method)
        if (params != null) {
            payload.put("params", params)
        }

        val pendingRequest = PendingRequest()
        pending[id] = pendingRequest

        try {
            sendFrame(0x1, payload.toString().toByteArray(StandardCharsets.UTF_8))
        } catch (error: Throwable) {
            pending.remove(id)
            throw IllegalStateException("Failed to send JSON-RPC request: $method", error)
        }

        if (!pendingRequest.latch.await(timeoutSeconds, TimeUnit.SECONDS)) {
            pending.remove(id)
            throw IllegalStateException("Timed out waiting for JSON-RPC response: $method")
        }
        pendingRequest.error?.let { throw it }
        return pendingRequest.result ?: JSONObject()
    }

    private fun startReaderLocked(expectedEpoch: Int) {
        val inStream = input ?: throw IllegalStateException("WebSocket input stream unavailable")
        readerThread = Thread {
            var disconnectCause: Throwable? = null
            try {
                while (connected && connectedEpoch == expectedEpoch) {
                    val frame = readFrame(inStream)
                    when (frame.opcode) {
                        0x1 -> {
                            val text = String(frame.payload, StandardCharsets.UTF_8)
                            handleMessage(text)
                        }

                        0x8 -> {
                            disconnectCause = IOException("WebSocket closed by peer")
                            break
                        }

                        0x9 -> sendFrame(0xA, frame.payload)
                        0xA -> {
                            // no-op for pong
                        }
                    }
                }
            } catch (error: Throwable) {
                disconnectCause = error
            } finally {
                markDisconnected(
                    cause = disconnectCause ?: IOException("WebSocket disconnected"),
                    expectedEpoch = expectedEpoch,
                )
            }
        }.apply {
            name = "Litter-BridgeRpcTransport-Reader"
            isDaemon = true
            start()
        }
    }

    private fun markDisconnected(
        cause: Throwable,
        expectedEpoch: Int?,
    ) {
        var shouldFailPending = false
        var socketToClose: Socket? = null

        synchronized(lifecycleLock) {
            if (expectedEpoch != null && connectedEpoch != expectedEpoch) {
                return
            }

            shouldFailPending = connected || socket != null || input != null || output != null
            connected = false
            initializedEpoch = 0
            readerThread = null

            socketToClose = socket
            socket = null
            input = null
            output = null
        }

        runCatching { socketToClose?.close() }
        if (shouldFailPending) {
            failPending(cause)
        }
    }

    private fun closeSocketLocked() {
        connected = false
        initializedEpoch = 0
        readerThread = null
        val sock = socket
        socket = null
        input = null
        output = null
        runCatching { sock?.close() }
    }

    private fun defaultInitializeParams(): JSONObject =
        JSONObject()
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

    private fun performHandshake(
        socket: Socket,
        input: InputStream,
        output: OutputStream,
        host: String,
        port: Int,
        path: String,
    ) {
        val keyBytes = ByteArray(16)
        random.nextBytes(keyBytes)
        val key = Base64.getEncoder().encodeToString(keyBytes)
        val hostHeader = if (port == 80) host else "$host:$port"
        val request = buildString {
            append("GET $path HTTP/1.1\r\n")
            append("Host: $hostHeader\r\n")
            append("Upgrade: websocket\r\n")
            append("Connection: Upgrade\r\n")
            append("Sec-WebSocket-Key: $key\r\n")
            append("Sec-WebSocket-Version: 13\r\n")
            append("\r\n")
        }

        output.write(request.toByteArray(StandardCharsets.UTF_8))
        output.flush()

        val headerBytes = readHttpHeaders(input)
        val headerText = String(headerBytes, StandardCharsets.UTF_8)
        val lines = headerText.split("\r\n")
        val status = lines.firstOrNull().orEmpty()
        if (!status.contains(" 101 ")) {
            throw IllegalStateException("Unexpected websocket handshake response: $status")
        }

        val headers = mutableMapOf<String, String>()
        for (line in lines.drop(1)) {
            val idx = line.indexOf(':')
            if (idx <= 0) {
                continue
            }
            val name = line.substring(0, idx).trim().lowercase()
            val value = line.substring(idx + 1).trim()
            headers[name] = value
        }

        val acceptExpected = websocketAccept(key)
        val acceptActual = headers["sec-websocket-accept"].orEmpty()
        if (acceptActual != acceptExpected) {
            throw IllegalStateException("Invalid websocket accept key")
        }
    }

    private fun websocketAccept(key: String): String {
        val value = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        val sha1 = MessageDigest.getInstance("SHA-1")
        val digest = sha1.digest(value.toByteArray(StandardCharsets.UTF_8))
        return Base64.getEncoder().encodeToString(digest)
    }

    private fun readHttpHeaders(input: InputStream): ByteArray {
        val out = ByteArrayOutputStream()
        var matched = 0
        val pattern = byteArrayOf('\r'.code.toByte(), '\n'.code.toByte(), '\r'.code.toByte(), '\n'.code.toByte())

        while (true) {
            val b = input.read()
            if (b < 0) {
                throw IOException("Socket closed while reading websocket handshake")
            }
            out.write(b)
            if (b.toByte() == pattern[matched]) {
                matched += 1
                if (matched == pattern.size) {
                    return out.toByteArray()
                }
            } else {
                matched = if (b.toByte() == pattern[0]) 1 else 0
            }

            if (out.size() > 64 * 1024) {
                throw IOException("Websocket handshake headers too large")
            }
        }
    }

    private fun sendFrame(opcode: Int, payload: ByteArray) {
        val out = output ?: throw IllegalStateException("WebSocket output unavailable")
        val epoch = connectedEpoch
        synchronized(outputLock) {
            try {
                val frame = ByteArrayOutputStream()
                frame.write(0x80 or (opcode and 0x0F))

                val maskBit = 0x80
                val len = payload.size
                when {
                    len < 126 -> frame.write(maskBit or len)
                    len <= 0xFFFF -> {
                        frame.write(maskBit or 126)
                        frame.write((len ushr 8) and 0xFF)
                        frame.write(len and 0xFF)
                    }

                    else -> {
                        frame.write(maskBit or 127)
                        var value = len.toLong()
                        val bytes = ByteArray(8)
                        for (index in 7 downTo 0) {
                            bytes[index] = (value and 0xFF).toByte()
                            value = value ushr 8
                        }
                        frame.write(bytes)
                    }
                }

                val mask = ByteArray(4)
                random.nextBytes(mask)
                frame.write(mask)

                for (index in payload.indices) {
                    frame.write(payload[index].toInt() xor mask[index % 4].toInt())
                }

                out.write(frame.toByteArray())
                out.flush()
            } catch (error: Throwable) {
                markDisconnected(
                    cause = IOException("WebSocket send failed", error),
                    expectedEpoch = epoch,
                )
                throw error
            }
        }
    }

    private fun readFrame(input: InputStream): Frame {
        val b0 = readByte(input)
        val b1 = readByte(input)
        val opcode = b0 and 0x0F
        val masked = (b1 and 0x80) != 0
        var payloadLen = (b1 and 0x7F).toLong()

        if (payloadLen == 126L) {
            val ext = readBytes(input, 2)
            payloadLen = ((ext[0].toInt() and 0xFF) shl 8 or (ext[1].toInt() and 0xFF)).toLong()
        } else if (payloadLen == 127L) {
            val ext = readBytes(input, 8)
            payloadLen = 0
            for (b in ext) {
                payloadLen = (payloadLen shl 8) or (b.toLong() and 0xFF)
            }
        }

        if (payloadLen > Int.MAX_VALUE.toLong()) {
            throw IOException("WebSocket frame too large")
        }

        val mask = if (masked) readBytes(input, 4) else null
        val payload = readBytes(input, payloadLen.toInt())
        if (mask != null) {
            for (index in payload.indices) {
                payload[index] = (payload[index].toInt() xor mask[index % 4].toInt()).toByte()
            }
        }
        return Frame(opcode = opcode, payload = payload)
    }

    private fun readByte(input: InputStream): Int {
        val value = input.read()
        if (value < 0) {
            throw IOException("WebSocket closed while reading frame")
        }
        return value
    }

    private fun readBytes(input: InputStream, length: Int): ByteArray {
        val out = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val count = input.read(out, offset, length - offset)
            if (count < 0) {
                throw IOException("WebSocket closed while reading frame payload")
            }
            offset += count
        }
        return out
    }

    private fun handleMessage(text: String) {
        val envelope = try {
            JSONObject(text)
        } catch (_: Throwable) {
            return
        }

        val hasId = envelope.has("id")
        val hasMethod = envelope.has("method")
        val hasResultOrError = envelope.has("result") || envelope.has("error")

        if (hasId && hasMethod && !hasResultOrError) {
            handleServerRequest(envelope)
            return
        }

        if (hasId) {
            handleResponse(envelope)
            return
        }

        if (hasMethod) {
            val method = envelope.optString("method")
            val params = envelope.opt("params")
            val paramsObject = when (params) {
                null, JSONObject.NULL -> null
                is JSONObject -> params
                else -> JSONObject().put("value", params)
            }
            onNotification(method, paramsObject)
        }
    }

    private fun handleResponse(envelope: JSONObject) {
        val id = envelope.opt("id")?.toString() ?: return
        val request = pending.remove(id) ?: return
        if (envelope.has("error")) {
            val error = envelope.optJSONObject("error")
            val code = error?.optInt("code") ?: 0
            val message = error?.optString("message").orEmpty().ifBlank { "Unknown JSON-RPC error" }
            request.error = IllegalStateException("RPC error ($code): $message")
            request.latch.countDown()
            return
        }

        request.result = when (val result = envelope.opt("result")) {
            null, JSONObject.NULL -> JSONObject()
            is JSONObject -> result
            else -> JSONObject().put("value", result)
        }
        request.latch.countDown()
    }

    private fun handleServerRequest(envelope: JSONObject) {
        val idValue = envelope.opt("id") ?: return
        val method = envelope.optString("method")
        val params = envelope.opt("params")
        val paramsObject = when (params) {
            null, JSONObject.NULL -> null
            is JSONObject -> params
            else -> JSONObject().put("value", params)
        }
        val result = when (method) {
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval" -> JSONObject().put("decision", "accept")
            else -> onServerRequest?.invoke(method, paramsObject) ?: JSONObject()
        }

        val response = JSONObject()
            .put("jsonrpc", "2.0")
            .put("id", idValue)
            .put("result", result)

        runCatching {
            sendFrame(0x1, response.toString().toByteArray(StandardCharsets.UTF_8))
        }
    }

    private fun failPending(cause: Throwable) {
        val error = IllegalStateException("Codex bridge request failed", cause)
        val iterator = pending.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            entry.value.error = error
            entry.value.latch.countDown()
            iterator.remove()
        }
    }

    private fun buildPath(uri: URI): String {
        val base = if (uri.path.isNullOrEmpty()) "/" else uri.path
        val query = uri.rawQuery
        return if (query.isNullOrEmpty()) base else "$base?$query"
    }

    private data class Frame(
        val opcode: Int,
        val payload: ByteArray,
    )

    private class PendingRequest {
        val latch = CountDownLatch(1)
        var result: JSONObject? = null
        var error: IllegalStateException? = null
    }

    private companion object {
        private const val INITIALIZE_METHOD = "initialize"
    }
}

internal object BridgeTransportReliabilityPolicy {
    fun shouldReconnect(
        connected: Boolean,
        socketConnected: Boolean,
        socketClosed: Boolean,
        hasInput: Boolean,
        hasOutput: Boolean,
        readerAlive: Boolean,
    ): Boolean = !isHealthy(
        connected = connected,
        socketConnected = socketConnected,
        socketClosed = socketClosed,
        hasInput = hasInput,
        hasOutput = hasOutput,
        readerAlive = readerAlive,
    )

    fun isHealthy(
        connected: Boolean,
        socketConnected: Boolean,
        socketClosed: Boolean,
        hasInput: Boolean,
        hasOutput: Boolean,
        readerAlive: Boolean,
    ): Boolean = connected && socketConnected && !socketClosed && hasInput && hasOutput && readerAlive
}
