package com.litter.android.state

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.zip.ZipInputStream
import kotlin.concurrent.Volatile
import kotlin.concurrent.thread

class BundledCodexService : Service() {

    companion object {
        const val PORT = 4500
        private const val PROXY_PORT = 8080
        private const val STARTUP_TIMEOUT_MS = 60_000L
        private const val LOG_FILE_NAME = "bundled-codex.log"
        private const val MAX_LOG_FILE_BYTES = 1_000_000L

        @Volatile
        var isRunning = false
            private set

        @Volatile
        var isReady = false
            private set

        @Volatile
        var lastError: String? = null
            private set

        fun bundledHomeDir(context: Context): File = File(context.filesDir, "env")

        fun logFile(context: Context): File = File(context.filesDir, LOG_FILE_NAME)

        fun readLogTail(
            context: Context,
            maxChars: Int = 32_000,
        ): String {
            val file = logFile(context)
            if (!file.exists()) {
                return "No bundled logs yet."
            }
            val text = runCatching { file.readText() }.getOrElse { error ->
                return "Failed to read bundled logs: ${error.message}"
            }
            return if (text.length <= maxChars) {
                text
            } else {
                text.takeLast(maxChars)
            }
        }

        @Synchronized
        private fun appendLogLine(
            context: Context,
            line: String,
        ) {
            val file = logFile(context)
            runCatching {
                file.parentFile?.mkdirs()
                if (file.exists() && file.length() > MAX_LOG_FILE_BYTES) {
                    val tail = file.readText().takeLast((MAX_LOG_FILE_BYTES / 2).toInt())
                    file.writeText(tail)
                }
                file.appendText(line + "\n")
            }
        }
    }

    private var codexProcess: Process? = null
    private var localProxy: LocalConnectProxy? = null
    private var nodeProxyProcess: Process? = null

    private fun serviceLog(
        level: String,
        message: String,
        throwable: Throwable? = null,
    ) {
        val rendered = "[${System.currentTimeMillis()}][$level] $message"
        when (level) {
            "E" -> Log.e("BundledCodexService", message, throwable)
            "W" -> Log.w("BundledCodexService", message, throwable)
            else -> Log.i("BundledCodexService", message)
        }
        appendLogLine(applicationContext, rendered + (throwable?.let { " :: ${it.message}" } ?: ""))
    }

    override fun onCreate() {
        super.onCreate()
        runCatching {
            val file = logFile(applicationContext)
            if (file.exists() && file.length() > MAX_LOG_FILE_BYTES) {
                file.writeText("")
            }
            appendLogLine(applicationContext, "")
            appendLogLine(applicationContext, "========== BundledCodexService start @ ${System.currentTimeMillis()} ==========")
        }
        isRunning = true
        isReady = false
        lastError = null
        thread(name = "BundledCodexService", isDaemon = true) {
            try {
                setupAndRun()
            } catch (e: Exception) {
                lastError = e.message ?: "Bundled Codex setup failed"
                serviceLog("E", "Startup failed", e)
                stopSelf()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        isRunning = false
        isReady = false
        localProxy?.stop()
        localProxy = null
        stopNodeProxy()
        stopProcess(codexProcess)
        codexProcess = null
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun setupAndRun() {
        val envDir = bundledHomeDir(this)
        prepareEnvironment(envDir)

        val proxyStarted = startNodeProxy(envDir)
        if (!proxyStarted) {
            serviceLog("W", "Failed to start node proxy, attempting fallback local proxy")
            startProxy()
        }

        val codex = startCodex(envDir, enableProxy = true)
        codexProcess = codex
        streamProcessLogs(prefix = "CODEX", process = codex)

        if (!waitForLocalPort(PORT, STARTUP_TIMEOUT_MS)) {
            throw IllegalStateException("Bundled Codex did not open ws://127.0.0.1:$PORT")
        }

        isReady = true
        lastError = null
        serviceLog("I", "Bundled Codex is ready on ws://127.0.0.1:$PORT")

        thread(name = "BundledCodexService-codex-watch", isDaemon = true) {
            val exitCode = runCatching { codex.waitFor() }.getOrDefault(-1)
            if (isRunning) {
                lastError = "Bundled Codex exited with code $exitCode"
                serviceLog("W", "Codex exited with code $exitCode")
                stopSelf()
            }
        }
    }

    private fun prepareEnvironment(envDir: File) {
        envDir.mkdirs()

        val assetVersion = readBundledAssetVersion()
        val stampFile = File(envDir, ".bundled_asset_version")
        val currentVersion = stampFile.takeIf { it.exists() }?.readText()?.trim()
        val shouldRefresh = currentVersion != assetVersion

        if (shouldRefresh) {
            envDir.deleteRecursively()
            envDir.mkdirs()
        }

        copyAssetIfPresent("bundled_env/codex", File(envDir, "codex"))
        copyAssetIfPresent("bundled_env/proxy.js", File(envDir, "proxy.js"))
        copyAssetIfPresent("bundled_env/config.toml", File(envDir, "config.toml"))
        copyAssetIfPresent("bundled_env/version.txt", File(envDir, "version.txt"))
        copyAssetIfPresent("bundled_env/bin/node", File(envDir, "bin/node"))
        copyAssetIfPresent("bundled_env/bin/rg", File(envDir, "bin/rg"))

        val bootstrapAsset = "bundled_env/termux-bootstrap.zip"
        if (shouldRefresh || !File(envDir, "bin/sh").exists()) {
            if (assetExists(bootstrapAsset)) {
                extractZipAsset(bootstrapAsset, envDir)
            }
        }

        val codexConfigDir = File(envDir, ".codex")
        codexConfigDir.mkdirs()
        val configFile = File(envDir, "config.toml")
        if (configFile.exists()) {
            configFile.copyTo(File(codexConfigDir, "config.toml"), overwrite = true)
        }

        File(envDir, "tmp").mkdirs()

        setExecutableIfPresent(File(envDir, "codex"))
        setExecutableIfPresent(File(envDir, "bin/node"))
        setExecutableIfPresent(File(envDir, "bin/sh"))
        setExecutableIfPresent(File(envDir, "bin/rg"))
        File(envDir, "bin").listFiles()?.forEach { binary ->
            if (binary.isFile) {
                binary.setExecutable(true, false)
            }
        }

        stampFile.writeText(assetVersion)
    }

    private fun startNodeProxy(envDir: File): Boolean {
        stopNodeProxy()
        val nodeBinary = File(envDir, "bin/node")
        val proxyScript = File(envDir, "proxy.js")
        if (!nodeBinary.exists() || !proxyScript.exists()) {
            serviceLog("W", "Node or proxy.js not found, cannot start node proxy")
            return false
        }
        serviceLog("I", "Starting Node proxy")
        val processBuilder = ProcessBuilder(
            nodeBinary.absolutePath,
            proxyScript.absolutePath
        ).apply {
            directory(envDir)
            redirectErrorStream(true)
            environment()["HOME"] = envDir.absolutePath
            environment()["PATH"] = "${envDir.absolutePath}/bin:${System.getenv("PATH").orEmpty()}"
        }
        val process = runCatching { processBuilder.start() }.getOrNull()
        if (process == null) {
            serviceLog("E", "Failed to start node proxy process")
            return false
        }
        nodeProxyProcess = process
        streamProcessLogs("PROXY", process)
        return waitForLocalPort(PROXY_PORT, 5_000L)
    }

    private fun stopNodeProxy() {
        stopProcess(nodeProxyProcess)
        nodeProxyProcess = null
    }

    private fun startProxy(): Boolean {
        localProxy?.stop()
        val proxy = LocalConnectProxy(PROXY_PORT)
        val started = proxy.start()
        if (!started) {
            serviceLog("E", "Failed to start local CONNECT proxy on 127.0.0.1:$PROXY_PORT")
            return false
        }
        localProxy = proxy
        return waitForLocalPort(PROXY_PORT, timeoutMs = 5_000L)
    }

    private fun startCodex(
        envDir: File,
        enableProxy: Boolean,
    ): Process {
        val codexBinary = resolveCodexBinary(envDir)
        if (!codexBinary.exists()) {
            throw IllegalStateException("Codex binary not found at ${codexBinary.absolutePath}")
        }
        serviceLog("I", "Launching Codex binary from ${codexBinary.absolutePath}")

        val processBuilder =
            ProcessBuilder(
                codexBinary.absolutePath,
                "app-server",
                "--listen",
                "ws://127.0.0.1:$PORT",
            ).apply {
                directory(envDir)
                redirectErrorStream(true)
                environment()["HOME"] = envDir.absolutePath
                environment()["PATH"] = "${envDir.absolutePath}/bin:${System.getenv("PATH").orEmpty()}"
                environment()["TMPDIR"] = File(envDir, "tmp").absolutePath
                environment()["RUST_BACKTRACE"] = "1"
                environment()["RUST_LOG"] = "codex_app_server=info,reqwest=debug,rustls=debug"
                val certFile = File(envDir, "etc/tls/cert.pem")
                val certDir = File(envDir, "etc/tls/certs")
                if (certFile.exists()) {
                    environment()["SSL_CERT_FILE"] = certFile.absolutePath
                    environment()["CURL_CA_BUNDLE"] = certFile.absolutePath
                    environment()["REQUESTS_CA_BUNDLE"] = certFile.absolutePath
                }
                if (certDir.exists()) {
                    environment()["SSL_CERT_DIR"] = certDir.absolutePath
                }
                if (enableProxy) {
                    val proxyUrl = "http://127.0.0.1:$PROXY_PORT"
                    environment()["HTTP_PROXY"] = proxyUrl
                    environment()["HTTPS_PROXY"] = proxyUrl
                    environment()["http_proxy"] = proxyUrl
                    environment()["https_proxy"] = proxyUrl
                    // Keep localhost callback traffic direct.
                    val noProxyHosts = "localhost,127.0.0.1,::1"
                    environment()["NO_PROXY"] = noProxyHosts
                    environment()["no_proxy"] = noProxyHosts
                } else {
                    environment().remove("HTTP_PROXY")
                    environment().remove("HTTPS_PROXY")
                    environment().remove("ALL_PROXY")
                    environment().remove("http_proxy")
                    environment().remove("https_proxy")
                    environment().remove("all_proxy")
                }
            }
        return processBuilder.start()
    }

    private fun resolveCodexBinary(envDir: File): File {
        val nativeLibDir = applicationInfo?.nativeLibraryDir?.takeIf { it.isNotBlank() }
        serviceLog("I", "nativeLibraryDir=${nativeLibDir ?: "none"}")
        if (nativeLibDir != null) {
            val nativeBinary = File(nativeLibDir, "libcodex.so")
            serviceLog("I", "native lib candidate=${nativeBinary.absolutePath}, exists=${nativeBinary.exists()}")
            if (nativeBinary.exists()) {
                nativeBinary.setExecutable(true, false)
                return nativeBinary
            }
        }
        val fallback = File(envDir, "codex")
        fallback.setExecutable(true, false)
        return fallback
    }

    private fun readBundledAssetVersion(): String {
        return runCatching {
            assets.open("bundled_env/version.txt").bufferedReader().use { it.readText() }
        }.getOrNull()?.trim().takeUnless { it.isNullOrEmpty() } ?: "unknown"
    }

    private fun copyAssetIfPresent(
        assetPath: String,
        target: File,
    ): Boolean {
        return runCatching {
            assets.open(assetPath).use { inputStream ->
                target.parentFile?.mkdirs()
                FileOutputStream(target).use { outputStream ->
                    inputStream.copyTo(outputStream)
                }
            }
        }.isSuccess
    }

    private fun extractZipAsset(
        assetPath: String,
        targetDir: File,
    ) {
        val root = targetDir.canonicalFile
        assets.open(assetPath).use { zipStream ->
            ZipInputStream(zipStream).use { zis ->
                var entry = zis.nextEntry
                while (entry != null) {
                    val outFile = File(targetDir, entry.name)
                    val canonicalOut = outFile.canonicalFile
                    if (!canonicalOut.path.startsWith(root.path + File.separator) && canonicalOut != root) {
                        throw IllegalStateException("Invalid archive entry: ${entry.name}")
                    }
                    if (entry.isDirectory) {
                        canonicalOut.mkdirs()
                    } else {
                        canonicalOut.parentFile?.mkdirs()
                        FileOutputStream(canonicalOut).use { outputStream ->
                            zis.copyTo(outputStream)
                        }
                    }
                    zis.closeEntry()
                    entry = zis.nextEntry
                }
            }
        }
    }

    private fun streamProcessLogs(
        prefix: String,
        process: Process,
    ) {
        thread(name = "BundledCodexService-$prefix-log", isDaemon = true) {
            runCatching {
                process.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        serviceLog("I", "$prefix: $line")
                    }
                }
            }
        }
    }

    private fun waitForLocalPort(
        port: Int,
        timeoutMs: Long,
    ): Boolean {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            val connected =
                runCatching {
                    Socket().use { socket ->
                        socket.connect(InetSocketAddress("127.0.0.1", port), 250)
                    }
                    true
                }.getOrDefault(false)
            if (connected) {
                return true
            }
            Thread.sleep(150L)
        }
        return false
    }

    private fun setExecutableIfPresent(file: File) {
            if (file.exists()) {
                file.setExecutable(true, false)
            }
        }

    private fun stopProcess(process: Process?) {
        if (process == null) {
            return
        }
        process.destroy()
        if (process.isAlive) {
            process.destroyForcibly()
        }
    }

    private fun assetExists(assetPath: String): Boolean {
        return runCatching {
            assets.open(assetPath).close()
            true
        }.getOrDefault(false)
    }

    private inner class LocalConnectProxy(
        private val port: Int,
    ) {
        @Volatile
        private var running = false
        private var serverSocket: ServerSocket? = null
        private var acceptThread: Thread? = null

        fun start(): Boolean {
            if (running) return true
            return try {
                val socket = ServerSocket()
                socket.reuseAddress = true
                socket.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port))
                serverSocket = socket
                running = true
                acceptThread =
                    thread(name = "BundledCodexProxy-Accept", isDaemon = true) {
                        while (running) {
                            val client = runCatching { socket.accept() }.getOrNull() ?: break
                            thread(name = "BundledCodexProxy-Client", isDaemon = true) {
                                handleClient(client)
                            }
                        }
                    }
                true
            } catch (error: Exception) {
                serviceLog("E", "Proxy start failed", error)
                stop()
                false
            }
        }

        fun stop() {
            running = false
            runCatching { serverSocket?.close() }
            serverSocket = null
            acceptThread = null
        }

        private fun handleClient(client: Socket) {
            client.tcpNoDelay = true
            client.soTimeout = 15_000
            runCatching {
                val clientIn = client.getInputStream()
                val clientOut = client.getOutputStream()
                val headerBytes = readRequestHeader(clientIn) ?: return
                val headerText = String(headerBytes, Charsets.ISO_8859_1)
                val requestLine = headerText.lineSequence().firstOrNull()?.trim().orEmpty()
                if (requestLine.isEmpty()) {
                    return
                }

                val parts = requestLine.split(" ")
                if (parts.size < 2) {
                    clientOut.write("HTTP/1.1 400 Bad Request\r\n\r\n".toByteArray())
                    return
                }
                val method = parts[0].uppercase()
                val target = parts[1]
                if (method != "CONNECT") {
                    clientOut.write("HTTP/1.1 405 Method Not Allowed\r\n\r\n".toByteArray())
                    return
                }

                val host = target.substringBefore(':').trim()
                val port = target.substringAfter(':', "443").toIntOrNull() ?: 443
                serviceLog("I", "Proxy CONNECT $host:$port")
                Socket().use { upstream ->
                    upstream.tcpNoDelay = true
                    upstream.connect(InetSocketAddress(host, port), 10_000)
                    serviceLog("I", "Proxy connected upstream $host:$port")
                    clientOut.write(
                        "HTTP/1.1 200 Connection Established\r\nProxy-Agent: LitterProxy\r\n\r\n".toByteArray(),
                    )
                    val upIn = upstream.getInputStream()
                    val upOut = upstream.getOutputStream()

                    val t1 = thread(isDaemon = true) { copyStream(clientIn, upOut) }
                    val t2 = thread(isDaemon = true) { copyStream(upIn, clientOut) }
                    t1.join()
                    t2.join()
                }
            }.onFailure { error ->
                serviceLog("W", "Proxy client error: ${error.message}")
            }
            runCatching { client.close() }
        }

        private fun readRequestHeader(input: InputStream): ByteArray? {
            val out = ArrayList<Byte>(1024)
            var matched = 0
            val terminator = byteArrayOf('\r'.code.toByte(), '\n'.code.toByte(), '\r'.code.toByte(), '\n'.code.toByte())
            while (out.size < 32 * 1024) {
                val next = input.read()
                if (next < 0) {
                    return null
                }
                val b = next.toByte()
                out += b
                if (b == terminator[matched]) {
                    matched += 1
                        if (matched == terminator.size) {
                            break
                        }
                } else {
                    matched = if (b == terminator[0]) 1 else 0
                }
            }
            return out.toByteArray()
        }

        private fun copyStream(
            input: InputStream,
            output: OutputStream,
        ) {
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val read = runCatching { input.read(buffer) }.getOrDefault(-1)
                if (read <= 0) break
                val wrote = runCatching {
                    output.write(buffer, 0, read)
                    output.flush()
                    true
                }.getOrDefault(false)
                if (!wrote) {
                    break
                }
            }
        }
    }
}
