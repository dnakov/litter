package com.litter.android.ui.home

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LitterThemeManager
import com.litter.android.ui.LocalTextScale
import uniffi.codex_mobile_client.AppOperationStatus
import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppSnapshotRecord
import uniffi.codex_mobile_client.Account
import uniffi.codex_mobile_client.HydratedCommandActionKind
import uniffi.codex_mobile_client.HydratedCommandExecutionData
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent

/**
 * TextStyle matching the conversation body size at the current text scale,
 * using the user's selected markdown font (mono when mono is enabled,
 * platform default otherwise) at [FontWeight.Medium].
 *
 * Mirrors iOS `MarkdownMatchedTitleFont` so home dashboard titles render at
 * the same size as conversation message bodies — making row headings visually
 * match what appears inside a conversation.
 *
 * Swift reference: HomeDashboardView.swift MarkdownMatchedTitleFont (L1203-1213).
 */
@Composable
@ReadOnlyComposable
fun markdownMatchedTitleStyle(): TextStyle {
    val scale = LocalTextScale.current
    val family = if (LitterThemeManager.monoFontEnabled) LitterTheme.monoFont else FontFamily.Default
    return TextStyle(
        fontFamily = family,
        fontWeight = FontWeight.Medium,
        fontSize = (LitterTextStyle.body * scale).sp,
    )
}

/**
 * Pure functions for deriving home dashboard data from Rust snapshots.
 * No business logic duplication — just UI-specific sorting/filtering.
 */
object HomeDashboardSupport {

    /**
     * Connected servers sorted by: active server first, then alphabetical.
     * Deduplicates by normalized host.
     */
    fun sortedConnectedServers(snapshot: AppSnapshotRecord): List<AppServerSnapshot> {
        val seen = mutableSetOf<String>()
        return snapshot.servers
            .filter { it.health != AppServerHealth.DISCONNECTED || it.connectionProgress != null }
            .sortedWith(compareBy<AppServerSnapshot> {
                // Active server (has active thread on it) sorts first
                val activeServerId = snapshot.activeThread?.let { key ->
                    key.serverId
                }
                if (it.serverId == activeServerId) 0 else 1
            }.thenBy { it.displayName.lowercase() })
            .filter { server ->
                val hostKey = "${server.host.lowercase()}:${server.port}"
                seen.add(hostKey)
            }
    }

    /**
     * Most recent sessions from connected servers, limited to [limit].
     * Uses pre-computed fields from Rust's AppSessionSummary.
     */
    fun recentSessions(
        snapshot: AppSnapshotRecord,
        limit: Int = 10,
    ): List<AppSessionSummary> {
        val connectedServerIds = snapshot.servers
            .filter { it.health == AppServerHealth.CONNECTED }
            .map { it.serverId }
            .toSet()

        return snapshot.sessionSummaries
            .filter { it.key.serverId in connectedServerIds }
            .filter { !it.isSubagent }
            .distinctBy { it.key.serverId to it.key.threadId }
            .sortedByDescending { it.updatedAt ?: 0L }
            .take(limit)
    }

    /**
     * Extracts the last path component as a workspace label.
     */
    fun workspaceLabel(cwd: String?): String {
        if (cwd.isNullOrBlank()) return "~"
        val trimmed = cwd.trimEnd('/')
        if (trimmed.isEmpty()) return "/"
        return trimmed.substringAfterLast('/')
    }

    /**
     * Format a relative timestamp from epoch seconds.
     */
    fun relativeTime(epochSeconds: Long?): String {
        if (epochSeconds == null || epochSeconds <= 0L) return ""
        val now = System.currentTimeMillis() / 1000
        val delta = now - epochSeconds
        return when {
            delta < 60 -> "just now"
            delta < 3600 -> "${delta / 60}m ago"
            delta < 86400 -> "${delta / 3600}h ago"
            delta < 604800 -> "${delta / 86400}d ago"
            else -> "${delta / 604800}w ago"
        }
    }

    fun maskedAccountLabel(server: AppServerSnapshot): String = when (val account = server.account) {
        is Account.Chatgpt -> maskEmail(account.email).ifEmpty { "ChatGPT" }
        is Account.ApiKey -> "API Key"
        else -> "Not logged in"
    }

    private fun maskEmail(email: String): String {
        val trimmed = email.trim()
        if (trimmed.isEmpty()) return ""

        val parts = trimmed.split("@", limit = 2)
        if (parts.size != 2) return maskToken(trimmed, keepPrefix = 2, keepSuffix = 0)

        val localPart = parts[0]
        val domainPart = parts[1]
        val domainPieces = domainPart.split(".")

        val maskedLocal = maskToken(localPart, keepPrefix = 2, keepSuffix = 1)
        val maskedDomain = if (domainPieces.size >= 2) {
            val suffix = domainPieces.last()
            val host = domainPieces.dropLast(1).joinToString(".")
            "${maskToken(host, keepPrefix = 1, keepSuffix = 0)}.$suffix"
        } else {
            maskToken(domainPart, keepPrefix = 1, keepSuffix = 0)
        }

        return "$maskedLocal@$maskedDomain"
    }

    private fun maskToken(value: String, keepPrefix: Int, keepSuffix: Int): String {
        if (value.isEmpty()) return ""

        val prefixCount = keepPrefix.coerceAtMost(value.length)
        val suffixCount = keepSuffix.coerceAtMost((value.length - prefixCount).coerceAtLeast(0))
        val maskCount = (value.length - prefixCount - suffixCount).coerceAtLeast(0)

        val prefix = value.take(prefixCount)
        val suffix = if (suffixCount > 0) value.takeLast(suffixCount) else ""
        val mask = if (maskCount > 0) "*".repeat(maskCount) else ""

        return prefix + mask + suffix
    }
}

// ─────────────────────────────────────────────────────────
// Hydrated conversation walks for home session cards
// ─────────────────────────────────────────────────────────
//
// All pure functions — no reducer logic. Each walks `List<HydratedConversationItem>`
// (the typed uniffi record) and returns render-ready data. Swift reference is
// `apps/ios/Sources/Litter/Views/HomeDashboardView.swift` — line refs inline.

private val AppOperationStatus.isPendingOrInProgress: Boolean
    get() = this == AppOperationStatus.PENDING || this == AppOperationStatus.IN_PROGRESS

/**
 * True only when the most recent tool-capable item is actually in-progress.
 * Walks in reverse and returns on the first matching content kind.
 *
 * Ref: HomeDashboardView.swift:543-559 (`isToolCallRunning`).
 */
fun isToolCallRunning(items: List<HydratedConversationItem>): Boolean {
    for (item in items.asReversed()) {
        when (val c = item.content) {
            is HydratedConversationItemContent.CommandExecution ->
                return c.v1.status == AppOperationStatus.IN_PROGRESS
            is HydratedConversationItemContent.McpToolCall ->
                return c.v1.status == AppOperationStatus.IN_PROGRESS
            is HydratedConversationItemContent.DynamicToolCall ->
                return c.v1.status == AppOperationStatus.IN_PROGRESS
            is HydratedConversationItemContent.FileChange ->
                return c.v1.status.isPendingOrInProgress
            else -> continue
        }
    }
    return false
}

/**
 * Start/end bounds of the most recent turn, derived from item timestamps.
 * `end == null` signals an in-progress turn (when [isActive]).
 *
 * Ref: HomeDashboardView.swift:567-577 (`lastTurnBounds`).
 */
data class TurnBounds(val startSeconds: Double, val endSeconds: Double?)

fun lastTurnBounds(
    items: List<HydratedConversationItem>,
    isActive: Boolean,
): TurnBounds? {
    val lastTurnId = items.asReversed()
        .firstNotNullOfOrNull { it.sourceTurnId }
        ?: return null
    val turnTimestamps = items
        .filter { it.sourceTurnId == lastTurnId }
        .mapNotNull { it.timestamp }
    val start = turnTimestamps.minOrNull() ?: return null
    if (isActive) return TurnBounds(startSeconds = start, endSeconds = null)
    val end = turnTimestamps.maxOrNull() ?: start
    return TurnBounds(startSeconds = start, endSeconds = end)
}

/**
 * A single row in the home card's tool log. Either a single exploration
 * summary (`Explored 3 files, 2 searches`) or a one-line tool invocation.
 */
sealed class HomeToolRow {
    abstract val id: String

    data class Exploration(override val id: String, val summary: String) : HomeToolRow()
    data class Tool(override val id: String, val icon: String, val detail: String) : HomeToolRow()
}

/**
 * Derive a grouped tool log from [items]. Consecutive exploration command
 * items collapse into a single summary row; everything else becomes a
 * standalone single-line row. Returns the *last* [limit] rows.
 *
 * Ref: HomeDashboardView.swift:941-1024 (`hydratedToolRows`).
 */
fun hydratedToolRows(
    items: List<HydratedConversationItem>,
    limit: Int,
): List<HomeToolRow> {
    if (items.isEmpty()) return emptyList()
    val rows = mutableListOf<HomeToolRow>()
    val buffer = mutableListOf<HydratedConversationItem>()

    fun flushExploration() {
        if (buffer.isEmpty()) return
        val anyInProgress = buffer.any { item ->
            val c = item.content
            c is HydratedConversationItemContent.CommandExecution &&
                c.v1.status == AppOperationStatus.IN_PROGRESS
        }
        val prefix = if (anyInProgress) "Exploring" else "Explored"
        val summary = explorationSummary(buffer, prefix)
        val seed = buffer.first().id
        rows += HomeToolRow.Exploration(id = "exploration-$seed", summary = summary)
        buffer.clear()
    }

    for (item in items) {
        if (item.isExplorationCommandItem()) {
            buffer += item
            continue
        }
        flushExploration()
        toolRowFor(item)?.let { rows += it }
    }
    flushExploration()

    if (rows.size <= limit) return rows
    return rows.takeLast(limit)
}

/**
 * Count read/search/list/fallback actions across exploration command items
 * and format a human-readable summary (e.g. `"Explored 3 files, 2 searches"`).
 *
 * Ref: HomeDashboardView.swift:998-1024 (`explorationSummary`).
 */
fun explorationSummary(
    items: List<HydratedConversationItem>,
    prefix: String,
): String {
    var readCount = 0
    var searchCount = 0
    var listingCount = 0
    var fallbackCount = 0
    for (item in items) {
        val data = (item.content as? HydratedConversationItemContent.CommandExecution)?.v1 ?: continue
        if (data.actions.isEmpty()) {
            fallbackCount += 1
            continue
        }
        for (action in data.actions) {
            when (action.kind) {
                HydratedCommandActionKind.READ -> readCount += 1
                HydratedCommandActionKind.SEARCH -> searchCount += 1
                HydratedCommandActionKind.LIST_FILES -> listingCount += 1
                HydratedCommandActionKind.UNKNOWN -> fallbackCount += 1
            }
        }
    }
    val parts = mutableListOf<String>()
    if (readCount > 0) parts += "$readCount ${if (readCount == 1) "file" else "files"}"
    if (searchCount > 0) parts += "$searchCount ${if (searchCount == 1) "search" else "searches"}"
    if (listingCount > 0) parts += "$listingCount ${if (listingCount == 1) "listing" else "listings"}"
    if (fallbackCount > 0) parts += "$fallbackCount ${if (fallbackCount == 1) "step" else "steps"}"
    if (parts.isEmpty()) {
        val n = items.size
        return "$prefix $n ${if (n == 1) "step" else "steps"}"
    }
    return "$prefix ${parts.joinToString(", ")}"
}

/**
 * Map the Rust-derived tool name (`"Bash"`, `"Edit"`, etc.) to the short
 * single-character/phrase display used in the home list.
 *
 * Ref: HomeDashboardView.swift:1028-1036 (`toolIconForName`).
 */
fun toolIconForName(name: String): String = when (name) {
    "Bash" -> "$"
    "Edit" -> "✎"
    "MCP" -> "mcp"
    "Tool" -> "tool"
    else -> name
}

/**
 * Last non-empty assistant message on this thread. New turns create an
 * empty assistant item that fills as deltas arrive — this walks back to
 * the most recent non-empty assistant block so the card doesn't blank
 * mid-turn. Consumers drive crossfade via the returned [id].
 *
 * Ref: HomeDashboardView.swift:526-537 (`displayedAssistantMessage`).
 */
data class DisplayedAssistantMessage(val id: String, val text: String)

fun displayedAssistantMessage(items: List<HydratedConversationItem>): DisplayedAssistantMessage? {
    for (item in items.asReversed()) {
        val data = (item.content as? HydratedConversationItemContent.Assistant)?.v1 ?: continue
        val trimmed = data.text.trim()
        if (trimmed.isNotEmpty()) {
            return DisplayedAssistantMessage(id = item.id, text = data.text)
        }
    }
    return null
}

// ─────── private helpers ───────

private fun HydratedConversationItem.isExplorationCommandItem(): Boolean {
    val data = (content as? HydratedConversationItemContent.CommandExecution)?.v1 ?: return false
    return data.isPureExploration()
}

private fun HydratedCommandExecutionData.isPureExploration(): Boolean {
    if (actions.isEmpty()) return false
    return actions.all { action ->
        when (action.kind) {
            HydratedCommandActionKind.READ,
            HydratedCommandActionKind.SEARCH,
            HydratedCommandActionKind.LIST_FILES -> true
            HydratedCommandActionKind.UNKNOWN -> false
        }
    }
}

private fun toolRowFor(item: HydratedConversationItem): HomeToolRow? {
    return when (val c = item.content) {
        is HydratedConversationItemContent.CommandExecution -> {
            val cmd = c.v1.command.lineSequence().firstOrNull()?.trim().orEmpty()
            HomeToolRow.Tool(id = "cmd-${item.id}", icon = "$", detail = cmd)
        }
        is HydratedConversationItemContent.FileChange -> {
            val changes = c.v1.changes
            val paths = changes.take(3).map { it.path.substringAfterLast('/') }
            val tail = if (changes.size > 3) " +${changes.size - 3}" else ""
            HomeToolRow.Tool(
                id = "edit-${item.id}",
                icon = "✎",
                detail = paths.joinToString(", ") + tail,
            )
        }
        is HydratedConversationItemContent.McpToolCall ->
            HomeToolRow.Tool(id = "mcp-${item.id}", icon = "mcp", detail = c.v1.tool)
        is HydratedConversationItemContent.DynamicToolCall ->
            HomeToolRow.Tool(id = "dyn-${item.id}", icon = "tool", detail = c.v1.tool)
        is HydratedConversationItemContent.WebSearch -> {
            val detail = c.v1.query.ifBlank { "search" }
            HomeToolRow.Tool(id = "web-${item.id}", icon = "⌕", detail = detail)
        }
        else -> null
    }
}
