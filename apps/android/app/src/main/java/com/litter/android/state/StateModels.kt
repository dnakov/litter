package com.litter.android.state

import java.net.URI
import java.util.Locale
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
    BUNDLED,
    BONJOUR,
    SSH,
    TAILSCALE,
    MANUAL,
    REMOTE,
    ;

    fun rawValue(): String =
        when (this) {
            LOCAL -> "local"
            BUNDLED -> "bundled"
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
                "bundled" -> BUNDLED
                "bonjour" -> BONJOUR
                "ssh" -> SSH
                "tailscale" -> TAILSCALE
                "manual" -> MANUAL
                "remote" -> REMOTE
                else -> MANUAL
            }
    }
}

enum class BackendKind {
    CODEX,
    OPENCODE,
    ;

    fun rawValue(): String =
        when (this) {
            CODEX -> "codex"
            OPENCODE -> "opencode"
        }

    companion object {
        fun from(raw: String?): BackendKind =
            when (raw?.trim()?.lowercase()) {
                "opencode" -> OPENCODE
                else -> CODEX
            }
    }
}

enum class AuthStatus {
    UNKNOWN,
    NOT_LOGGED_IN,
    API_KEY,
    CHATGPT,
}

enum class ApprovalKind {
    COMMAND_EXECUTION,
    FILE_CHANGE,
}

enum class ApprovalDecision {
    ACCEPT,
    ACCEPT_FOR_SESSION,
    DECLINE,
    CANCEL,
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
    val backendKind: BackendKind = BackendKind.CODEX,
    val hasCodexServer: Boolean = true,
    val username: String? = null,
    val password: String? = null,
    val directory: String? = null,
    val websocketUrl: String? = null,
) {
    companion object {
        fun local(port: Int): ServerConfig =
            ServerConfig(
                id = "local",
                name = "On Device",
                host = "127.0.0.1",
                port = port,
                source = ServerSource.LOCAL,
                backendKind = BackendKind.CODEX,
                hasCodexServer = true,
            )

        fun bundled(port: Int): ServerConfig =
            ServerConfig(
                id = "bundled",
                name = "Bundled Server",
                host = "127.0.0.1",
                port = port,
                source = ServerSource.BUNDLED,
                backendKind = BackendKind.CODEX,
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
    val backendKind: String = BackendKind.CODEX.rawValue(),
    val hasCodexServer: Boolean,
    val username: String? = null,
    val password: String? = null,
    val directory: String? = null,
    val websocketUrl: String? = null,
) {
    fun toServerConfig(): ServerConfig =
        ServerConfig(
            id = id,
            name = name,
            host = host,
            port = port,
            source = ServerSource.from(source),
            backendKind = BackendKind.from(backendKind),
            hasCodexServer = hasCodexServer,
            username = username,
            password = password,
            directory = directory,
            websocketUrl = websocketUrl,
        )

    companion object {
        fun from(server: ServerConfig): SavedServer =
            SavedServer(
                id = server.id,
                name = server.name,
                host = server.host,
                port = server.port,
                source = server.source.rawValue(),
                backendKind = server.backendKind.rawValue(),
                hasCodexServer = server.hasCodexServer,
                username = server.username,
                password = server.password,
                directory = server.directory,
                websocketUrl = server.websocketUrl,
            )
    }
}

data class BackendCapabilities(
    val supportsAuthManagement: Boolean = true,
    val supportsExperimentalFeatures: Boolean = true,
    val supportsSkillListing: Boolean = true,
    val supportsDirectoryBrowser: Boolean = true,
    val supportsQuestions: Boolean = false,
)

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

data class SkillMentionInput(
    val name: String,
    val path: String,
)

enum class SlashKind {
    ACTION,
    COMMAND,
}

data class SlashEntry(
    val id: String,
    val kind: SlashKind,
    val name: String,
    val aliases: List<String> = emptyList(),
    val description: String = "",
    val category: String = "",
    val displayName: String = "",
    val actionId: String? = null,
    val source: String? = null,
)

data class OpenCodeAgentOption(
    val name: String,
    val description: String = "",
    val mode: String = "",
    val hidden: Boolean = false,
)

data class OpenCodeMcpServer(
    val name: String,
    val status: String,
    val summary: String = "",
)

data class OpenCodeStatusSection(
    val title: String,
    val lines: List<String>,
)

data class OpenCodeStatusSnapshot(
    val sections: List<OpenCodeStatusSection>,
)

data class ChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: MessageRole,
    val text: String,
    val timestampEpochMillis: Long = System.currentTimeMillis(),
    val isStreaming: Boolean = false,
    val sourceTurnId: String? = null,
    val sourceTurnIndex: Int? = null,
    val isFromUserTurnBoundary: Boolean = false,
    val agentNickname: String? = null,
    val agentRole: String? = null,
)

data class PendingApproval(
    val id: String,
    val requestId: String,
    val serverId: String,
    val method: String,
    val kind: ApprovalKind,
    val threadId: String?,
    val turnId: String?,
    val itemId: String?,
    val command: String?,
    val cwd: String?,
    val reason: String?,
    val grantRoot: String?,
    val requesterAgentNickname: String? = null,
    val requesterAgentRole: String? = null,
    val createdAtEpochMillis: Long = System.currentTimeMillis(),
)

enum class PendingInteractionKind {
    APPROVAL,
    QUESTION,
}

data class PendingQuestionOption(
    val label: String,
    val description: String,
)

data class PendingQuestionPrompt(
    val header: String,
    val question: String,
    val options: List<PendingQuestionOption>,
    val multiple: Boolean = false,
    val custom: Boolean = true,
)

data class PendingQuestion(
    val id: String,
    val requestId: String,
    val serverId: String,
    val threadId: String?,
    val prompts: List<PendingQuestionPrompt>,
    val createdAtEpochMillis: Long = System.currentTimeMillis(),
)

data class PendingInteraction(
    val id: String,
    val serverId: String,
    val kind: PendingInteractionKind,
    val approval: PendingApproval? = null,
    val question: PendingQuestion? = null,
    val createdAtEpochMillis: Long = System.currentTimeMillis(),
)

data class ThreadState(
    val key: ThreadKey,
    val serverName: String,
    val serverSource: ServerSource,
    val status: ThreadStatus = ThreadStatus.READY,
    val messages: List<ChatMessage> = emptyList(),
    val preview: String = "",
    val cwd: String = "",
    val modelProvider: String = "",
    val parentThreadId: String? = null,
    val rootThreadId: String? = null,
    val agentNickname: String? = null,
    val agentRole: String? = null,
    val updatedAtEpochMillis: Long = System.currentTimeMillis(),
    val activeTurnId: String? = null,
    val lastError: String? = null,
    val isPlaceholder: Boolean = false,
) {
    val hasTurnActive: Boolean
        get() = status == ThreadStatus.THINKING

    val isFork: Boolean
        get() = !parentThreadId.isNullOrBlank()
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
    val slashByServerId: Map<String, List<SlashEntry>> = emptyMap(),
    val agentOptionsByServerId: Map<String, List<OpenCodeAgentOption>> = emptyMap(),
    val selectedAgentByServerId: Map<String, String?> = emptyMap(),
    val accountByServerId: Map<String, AccountState> = emptyMap(),
    val capabilitiesByServerId: Map<String, BackendCapabilities> = emptyMap(),
    val currentCwd: String = defaultWorkingDirectory(),
    val pendingInteractions: List<PendingInteraction> = emptyList(),
    val toolTargetLabelsById: Map<String, String> = emptyMap(),
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

    val activeCapabilities: BackendCapabilities
        get() =
            activeServerId
                ?.let { capabilitiesByServerId[it] }
                ?: BackendCapabilities()

    val activeSlashEntries: List<SlashEntry>
        get() =
            activeServerId
                ?.let { slashByServerId[it] }
                .orEmpty()

    val activeAgentOptions: List<OpenCodeAgentOption>
        get() =
            activeServerId
                ?.let { agentOptionsByServerId[it] }
                .orEmpty()

    val activeAgentName: String?
        get() =
            activeServerId
                ?.let { selectedAgentByServerId[it] }

    val activePendingApproval: PendingApproval?
        get() = pendingInteractions.firstOrNull()?.approval

    val activePendingInteraction: PendingInteraction?
        get() = pendingInteractions.firstOrNull()
}

internal fun defaultWorkingDirectory(): String =
    (System.getProperty("java.io.tmpdir") ?: "/data/local/tmp").trim().ifEmpty { "/data/local/tmp" }

internal fun openCodeMobileSlashEntries(): List<SlashEntry> =
    listOf(
        SlashEntry(
            id = "action:session.new",
            kind = SlashKind.ACTION,
            name = "new",
            aliases = listOf("clear"),
            description = "Start a new session",
            category = "Session",
            displayName = "/new",
            actionId = "session.new",
        ),
        SlashEntry(
            id = "action:session.list",
            kind = SlashKind.ACTION,
            name = "sessions",
            aliases = listOf("resume", "continue"),
            description = "Switch sessions",
            category = "Session",
            displayName = "/sessions",
            actionId = "session.list",
        ),
        SlashEntry(
            id = "action:session.fork",
            kind = SlashKind.ACTION,
            name = "fork",
            description = "Fork the current session",
            category = "Session",
            displayName = "/fork",
            actionId = "session.fork",
        ),
        SlashEntry(
            id = "action:session.rename",
            kind = SlashKind.ACTION,
            name = "rename",
            description = "Rename the current session",
            category = "Session",
            displayName = "/rename",
            actionId = "session.rename",
        ),
        SlashEntry(
            id = "action:session.share",
            kind = SlashKind.ACTION,
            name = "share",
            description = "Share the current session",
            category = "Session",
            displayName = "/share",
            actionId = "session.share",
        ),
        SlashEntry(
            id = "action:session.unshare",
            kind = SlashKind.ACTION,
            name = "unshare",
            description = "Stop sharing the current session",
            category = "Session",
            displayName = "/unshare",
            actionId = "session.unshare",
        ),
        SlashEntry(
            id = "action:session.compact",
            kind = SlashKind.ACTION,
            name = "compact",
            aliases = listOf("summarize"),
            description = "Summarize the current session",
            category = "Session",
            displayName = "/compact",
            actionId = "session.compact",
        ),
        SlashEntry(
            id = "action:session.undo",
            kind = SlashKind.ACTION,
            name = "undo",
            description = "Undo the last change",
            category = "Session",
            displayName = "/undo",
            actionId = "session.undo",
        ),
        SlashEntry(
            id = "action:session.redo",
            kind = SlashKind.ACTION,
            name = "redo",
            description = "Redo the last reverted change",
            category = "Session",
            displayName = "/redo",
            actionId = "session.redo",
        ),
        SlashEntry(
            id = "action:model.list",
            kind = SlashKind.ACTION,
            name = "models",
            description = "Choose a model",
            category = "Agent",
            displayName = "/models",
            actionId = "model.list",
        ),
        SlashEntry(
            id = "action:prompt.skills",
            kind = SlashKind.ACTION,
            name = "skills",
            description = "Browse skills",
            category = "Prompt",
            displayName = "/skills",
            actionId = "prompt.skills",
        ),
        SlashEntry(
            id = "action:agent.list",
            kind = SlashKind.ACTION,
            name = "agents",
            description = "Choose an agent",
            category = "Agent",
            displayName = "/agents",
            actionId = "agent.list",
        ),
        SlashEntry(
            id = "action:mcp.list",
            kind = SlashKind.ACTION,
            name = "mcps",
            description = "Inspect MCP servers",
            category = "Agent",
            displayName = "/mcps",
            actionId = "mcp.list",
        ),
        SlashEntry(
            id = "action:opencode.status",
            kind = SlashKind.ACTION,
            name = "status",
            description = "View OpenCode status",
            category = "System",
            displayName = "/status",
            actionId = "opencode.status",
        ),
        SlashEntry(
            id = "action:help.show",
            kind = SlashKind.ACTION,
            name = "help",
            description = "List slash commands",
            category = "System",
            displayName = "/help",
            actionId = "help.show",
        ),
    )

internal fun mergeOpenCodeSlashEntries(
    remote: List<SlashEntry>,
    local: List<SlashEntry> = openCodeMobileSlashEntries(),
): List<SlashEntry> {
    val merged = ArrayList<SlashEntry>(remote.size + local.size)
    val names = HashSet<String>()
    val actions = HashSet<String>()

    fun add(entry: SlashEntry) {
        val key = entry.name.trim().lowercase(Locale.ROOT)
        if (key.isEmpty()) {
            return
        }
        if (!names.add(key)) {
            return
        }
        if (entry.kind == SlashKind.ACTION) {
            val action = entry.actionId?.trim().orEmpty()
            if (action.isEmpty() || !actions.add(action)) {
                names.remove(key)
                return
            }
        }
        merged += entry
    }

    remote.forEach(::add)
    local.forEach(::add)
    return merged.sortedBy { it.displayName.lowercase(Locale.ROOT) }
}

internal fun manualServerId(
    kind: BackendKind,
    host: String,
    port: Int,
): String {
    val raw = host.trim().trimEnd('/')
    val key =
        if (kind != BackendKind.OPENCODE) {
            raw.substringAfter("://", raw).trimStart('/')
        } else {
            runCatching {
                val uri = if (raw.contains("://")) URI(raw) else null
                val scheme = uri?.scheme?.trim()?.lowercase()
                val path =
                    uri?.rawPath
                        ?.trim()
                        ?.trimEnd('/')
                        ?.takeIf { it.isNotEmpty() && it != "/" }
                        .orEmpty()
                val value =
                    (uri?.rawAuthority?.trim()?.takeIf { it.isNotEmpty() }
                        ?: uri?.host?.trim()
                        ?: uri?.authority?.substringBefore('@')?.trim())
                        ?: raw.substringAfter("://", raw).trimStart('/')
                if (scheme.isNullOrBlank() || scheme == "http") "$value$path" else "$scheme://$value$path"
            }.getOrDefault(raw)
        }.ifEmpty { "127.0.0.1" }
    return "manual-${kind.rawValue()}-$key:$port"
}
