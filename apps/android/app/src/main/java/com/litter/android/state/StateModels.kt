package com.litter.android.state

import java.util.UUID

enum class MessageRole {
    USER,
    ASSISTANT,
    SYSTEM,
    REASONING,
}

enum class ThreadStatus {
    IDLE,
    CONNECTING,
    READY,
    THINKING,
    ERROR,
}

enum class ServerConnectionStatus {
    DISCONNECTED,
    CONNECTING,
    READY,
    ERROR,
}

enum class ServerSource {
    LOCAL,
    BONJOUR,
    SSH,
    TAILSCALE,
    MANUAL,
    REMOTE,
    ;

    fun rawValue(): String =
        when (this) {
            LOCAL -> "local"
            BONJOUR -> "bonjour"
            SSH -> "ssh"
            TAILSCALE -> "tailscale"
            MANUAL -> "manual"
            REMOTE -> "remote"
        }

    companion object {
        fun from(raw: String?): ServerSource =
            when (raw?.trim()?.lowercase()) {
                "local" -> LOCAL
                "bonjour" -> BONJOUR
                "ssh" -> SSH
                "tailscale" -> TAILSCALE
                "manual" -> MANUAL
                "remote" -> REMOTE
                else -> MANUAL
            }
    }
}

enum class AuthStatus {
    UNKNOWN,
    NOT_LOGGED_IN,
    API_KEY,
    CHATGPT,
}

data class ThreadKey(
    val serverId: String,
    val threadId: String,
)

data class ServerConfig(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val source: ServerSource,
    val hasCodexServer: Boolean = true,
) {
    companion object {
        fun local(port: Int): ServerConfig =
            ServerConfig(
                id = "local",
                name = "On Device",
                host = "127.0.0.1",
                port = port,
                source = ServerSource.LOCAL,
                hasCodexServer = true,
            )
    }
}

data class SavedServer(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val source: String,
    val hasCodexServer: Boolean,
) {
    fun toServerConfig(): ServerConfig =
        ServerConfig(
            id = id,
            name = name,
            host = host,
            port = port,
            source = ServerSource.from(source),
            hasCodexServer = hasCodexServer,
        )

    companion object {
        fun from(server: ServerConfig): SavedServer =
            SavedServer(
                id = server.id,
                name = server.name,
                host = server.host,
                port = server.port,
                source = server.source.rawValue(),
                hasCodexServer = server.hasCodexServer,
            )
    }
}

data class AccountState(
    val status: AuthStatus = AuthStatus.UNKNOWN,
    val email: String = "",
    val oauthUrl: String? = null,
    val pendingLoginId: String? = null,
    val lastError: String? = null,
) {
    val summaryTitle: String
        get() =
            when (status) {
                AuthStatus.CHATGPT -> if (email.isBlank()) "ChatGPT" else email
                AuthStatus.API_KEY -> "API Key"
                AuthStatus.NOT_LOGGED_IN -> "Not logged in"
                AuthStatus.UNKNOWN -> "Checking..."
            }

    val summarySubtitle: String?
        get() =
            when (status) {
                AuthStatus.CHATGPT -> "ChatGPT account"
                AuthStatus.API_KEY -> "OpenAI API key"
                else -> null
            }
}

data class ReasoningEffortOption(
    val effort: String,
    val description: String,
)

data class ModelOption(
    val id: String,
    val displayName: String,
    val description: String,
    val defaultReasoningEffort: String?,
    val supportedReasoningEfforts: List<ReasoningEffortOption>,
    val isDefault: Boolean,
)

data class ModelSelection(
    val modelId: String? = null,
    val reasoningEffort: String? = "medium",
)

data class ExperimentalFeature(
    val name: String,
    val stage: String,
    val displayName: String?,
    val description: String?,
    val announcement: String?,
    val enabled: Boolean,
    val defaultEnabled: Boolean,
)

data class SkillMetadata(
    val name: String,
    val description: String,
    val path: String,
    val scope: String,
    val enabled: Boolean,
)

data class ChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: MessageRole,
    val text: String,
    val timestampEpochMillis: Long = System.currentTimeMillis(),
    val isStreaming: Boolean = false,
)

data class ThreadState(
    val key: ThreadKey,
    val serverName: String,
    val serverSource: ServerSource,
    val status: ThreadStatus = ThreadStatus.READY,
    val messages: List<ChatMessage> = emptyList(),
    val preview: String = "",
    val cwd: String = "",
    val updatedAtEpochMillis: Long = System.currentTimeMillis(),
    val activeTurnId: String? = null,
    val lastError: String? = null,
) {
    val hasTurnActive: Boolean
        get() = status == ThreadStatus.THINKING
}

data class AppState(
    val connectionStatus: ServerConnectionStatus = ServerConnectionStatus.DISCONNECTED,
    val connectionError: String? = null,
    val servers: List<ServerConfig> = emptyList(),
    val savedServers: List<SavedServer> = emptyList(),
    val activeServerId: String? = null,
    val threads: List<ThreadState> = emptyList(),
    val activeThreadKey: ThreadKey? = null,
    val selectedModel: ModelSelection = ModelSelection(),
    val availableModels: List<ModelOption> = emptyList(),
    val accountByServerId: Map<String, AccountState> = emptyMap(),
    val currentCwd: String = defaultWorkingDirectory(),
) {
    val activeThread: ThreadState?
        get() = activeThreadKey?.let { key ->
            threads.firstOrNull { it.key == key }
        }

    val activeAccount: AccountState
        get() =
            activeServerId
                ?.let { accountByServerId[it] }
                ?: AccountState()
}

internal fun defaultWorkingDirectory(): String =
    (System.getProperty("java.io.tmpdir") ?: "/data/local/tmp").trim().ifEmpty { "/data/local/tmp" }
