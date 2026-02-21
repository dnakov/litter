package com.litter.android.state

import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

sealed class SshCredentials {
    data class Password(
        val username: String,
        val password: String,
    ) : SshCredentials()

    data class Key(
        val username: String,
        val privateKeyPem: String,
        val passphrase: String?,
    ) : SshCredentials()
}

class SshException(
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

class SshSessionManager {
    private val defaultRemotePort = 8390

    private val lock = Any()
    private var session: Session? = null
    private var connectedHost: String? = null

    suspend fun connect(
        host: String,
        port: Int = 22,
        credentials: SshCredentials,
    ) = withContext(Dispatchers.IO) {
        val normalizedHost = normalizeHost(host)

        runCatching { disconnectBlocking() }

        val jsch = JSch()
        val username =
            when (credentials) {
                is SshCredentials.Password -> credentials.username
                is SshCredentials.Key -> credentials.username
            }

        if (credentials is SshCredentials.Key) {
            val privateKey = credentials.privateKeyPem.toByteArray(Charsets.UTF_8)
            val passphrase = credentials.passphrase?.toByteArray(Charsets.UTF_8)
            jsch.addIdentity("litter-ssh", privateKey, null, passphrase)
        }

        val createdSession =
            jsch.getSession(username, normalizedHost, port).apply {
                setConfig("StrictHostKeyChecking", "no")
                setConfig("PreferredAuthentications", "publickey,password,keyboard-interactive")
                timeout = 15_000
                if (credentials is SshCredentials.Password) {
                    setPassword(credentials.password)
                }
            }

        try {
            createdSession.connect(15_000)
        } catch (error: Throwable) {
            runCatching { createdSession.disconnect() }
            throw SshException("Could not connect to $normalizedHost:$port. Check SSH reachability and credentials.", error)
        }

        synchronized(lock) {
            session = createdSession
            connectedHost = normalizedHost
        }
    }

    suspend fun startRemoteServer(): Int =
        withContext(Dispatchers.IO) {
            val command = resolveServerLaunchCommand() ?: throw SshException(
                "Remote host is missing codex/codex-app-server in PATH.",
            )
            val wantsIpv6 = synchronized(lock) { connectedHost?.contains(':') == true }

            var lastFailure = "Timed out waiting for remote server to start."
            for (port in candidatePorts()) {
                val listenAddr = if (wantsIpv6) "[::]:$port" else "0.0.0.0:$port"
                val logPath = "/tmp/litter-android-app-server-$port.log"

                if (isPortListening(port)) {
                    return@withContext port
                }

                val launchResult = exec(startServerCommand(command, listenAddr, logPath), timeoutMs = 20_000)
                val launchedPid = launchResult.stdout.trim().toIntOrNull()

                var usedNextPort = false
                repeat(60) { attempt ->
                    if (isPortListening(port)) {
                        return@withContext port
                    }

                    if (launchedPid != null && !isProcessAlive(launchedPid)) {
                        val detail = fetchServerLogTail(logPath)
                        if (detail.contains("address already in use", ignoreCase = true)) {
                            lastFailure = detail
                            usedNextPort = true
                            return@repeat
                        }
                        throw SshException(
                            if (detail.isBlank()) "Server process exited immediately." else detail,
                        )
                    }

                    if (attempt >= 8 && launchedPid != null && isProcessAlive(launchedPid)) {
                        return@withContext port
                    }

                    delay(500)
                }

                if (usedNextPort) {
                    continue
                }

                val detail = fetchServerLogTail(logPath)
                if (detail.contains("address already in use", ignoreCase = true)) {
                    lastFailure = detail
                    continue
                }

                lastFailure = detail.ifBlank { lastFailure }
                break
            }

            throw SshException(lastFailure)
        }

    suspend fun disconnect() =
        withContext(Dispatchers.IO) {
            disconnectBlocking()
        }

    private fun disconnectBlocking() {
        synchronized(lock) {
            runCatching { session?.disconnect() }
            session = null
            connectedHost = null
        }
    }

    private fun resolveServerLaunchCommand(): ServerLaunchCommand? {
        val script =
            """
            for f in "${'$'}HOME/.profile" "${'$'}HOME/.bash_profile" "${'$'}HOME/.bashrc" "${'$'}HOME/.zprofile" "${'$'}HOME/.zshrc"; do
              [ -f "${'$'}f" ] && . "${'$'}f" 2>/dev/null
            done
            if command -v codex >/dev/null 2>&1; then
              printf 'codex:%s' "${'$'}(command -v codex)"
            elif [ -x "${'$'}HOME/.volta/bin/codex" ]; then
              printf 'codex:%s' "${'$'}HOME/.volta/bin/codex"
            elif [ -x "${'$'}HOME/.cargo/bin/codex" ]; then
              printf 'codex:%s' "${'$'}HOME/.cargo/bin/codex"
            elif command -v codex-app-server >/dev/null 2>&1; then
              printf 'codex-app-server:%s' "${'$'}(command -v codex-app-server)"
            elif [ -x "${'$'}HOME/.cargo/bin/codex-app-server" ]; then
              printf 'codex-app-server:%s' "${'$'}HOME/.cargo/bin/codex-app-server"
            fi
            """.trimIndent()

        val out = exec(script).stdout.trim()
        if (out.isBlank()) {
            return null
        }

        val parts = out.split(':', limit = 2)
        if (parts.size != 2) {
            return null
        }

        return when (parts[0]) {
            "codex" -> ServerLaunchCommand.Codex(parts[1])
            "codex-app-server" -> ServerLaunchCommand.CodexAppServer(parts[1])
            else -> null
        }
    }

    private fun startServerCommand(
        command: ServerLaunchCommand,
        listenAddr: String,
        logPath: String,
    ): String {
        val listenArg = shellQuote("ws://$listenAddr")
        val launch =
            when (command) {
                is ServerLaunchCommand.Codex -> "${shellQuote(command.executable)} app-server --listen $listenArg"
                is ServerLaunchCommand.CodexAppServer -> "${shellQuote(command.executable)} --listen $listenArg"
            }

        val profileInit =
            "for f in \"${'$'}HOME/.profile\" \"${'$'}HOME/.bash_profile\" \"${'$'}HOME/.bashrc\" \"${'$'}HOME/.zprofile\" \"${'$'}HOME/.zshrc\"; do [ -f \"${'$'}f\" ] && . \"${'$'}f\" 2>/dev/null; done;"

        return "$profileInit nohup $launch </dev/null >${shellQuote(logPath)} 2>&1 & echo ${'$'}!"
    }

    private fun isPortListening(port: Int): Boolean {
        val checkCmd =
            """
            if command -v lsof >/dev/null 2>&1; then
              lsof -nP -iTCP:$port -sTCP:LISTEN -t 2>/dev/null | head -n 1
            elif command -v ss >/dev/null 2>&1; then
              ss -ltn "sport = :$port" 2>/dev/null | tail -n +2 | head -n 1
            elif command -v netstat >/dev/null 2>&1; then
              netstat -ltn 2>/dev/null | awk '{print $4}' | grep -E '[:.]$port$' | head -n 1
            fi
            """.trimIndent()

        return exec(checkCmd).stdout.trim().isNotEmpty()
    }

    private fun isProcessAlive(pid: Int): Boolean {
        val out = exec("kill -0 $pid >/dev/null 2>&1 && echo alive || echo dead").stdout.trim()
        return out == "alive"
    }

    private fun fetchServerLogTail(logPath: String): String {
        return exec("tail -n 25 ${shellQuote(logPath)} 2>/dev/null").stdout.trim()
    }

    private fun exec(
        command: String,
        timeoutMs: Int = 15_000,
    ): CommandResult {
        val activeSession = synchronized(lock) { session } ?: throw SshException("SSH not connected.")
        val channel = (activeSession.openChannel("exec") as ChannelExec)

        val stdout = ByteArrayOutputStream()
        val stderr = ByteArrayOutputStream()

        try {
            channel.setCommand(command)
            channel.inputStream = null
            channel.setErrStream(stderr, true)

            val inStream = channel.inputStream
            channel.connect(timeoutMs)

            val buffer = ByteArray(4096)
            val started = System.currentTimeMillis()
            while (true) {
                while (inStream.available() > 0) {
                    val read = inStream.read(buffer)
                    if (read < 0) {
                        break
                    }
                    stdout.write(buffer, 0, read)
                }

                if (channel.isClosed) {
                    if (inStream.available() <= 0) {
                        break
                    }
                }

                if (System.currentTimeMillis() - started > timeoutMs) {
                    throw SshException("SSH command timed out")
                }

                Thread.sleep(50)
            }

            return CommandResult(
                stdout = stdout.toString(Charsets.UTF_8.name()),
                stderr = stderr.toString(Charsets.UTF_8.name()),
                exitCode = channel.exitStatus,
            )
        } finally {
            runCatching { channel.disconnect() }
        }
    }

    private fun candidatePorts(): List<Int> {
        val ports = ArrayList<Int>(21)
        ports += defaultRemotePort
        for (offset in 1..20) {
            ports += defaultRemotePort + offset
        }
        return ports
    }

    private fun shellQuote(value: String): String {
        return "'${value.replace("'", "'\"'\"'")}'"
    }

    private fun normalizeHost(host: String): String {
        var normalized = host.trim().trim('[').trim(']').replace("%25", "%")
        if (!normalized.contains(':')) {
            val percent = normalized.indexOf('%')
            if (percent >= 0) {
                normalized = normalized.substring(0, percent)
            }
        }
        return normalized
    }

    private sealed class ServerLaunchCommand {
        data class Codex(
            val executable: String,
        ) : ServerLaunchCommand()

        data class CodexAppServer(
            val executable: String,
        ) : ServerLaunchCommand()
    }

    private data class CommandResult(
        val stdout: String,
        val stderr: String,
        val exitCode: Int,
    )
}
