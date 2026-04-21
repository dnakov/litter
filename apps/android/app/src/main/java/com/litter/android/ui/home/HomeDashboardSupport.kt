package com.litter.android.ui.home

import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppSnapshotRecord
import uniffi.codex_mobile_client.Account

/**
 * Pure functions for deriving home dashboard data from Rust snapshots.
 * No business logic duplication — just UI-specific sorting/filtering.
 */
object HomeDashboardSupport {

    /**
     * Connected servers sorted by: active server first, then alphabetical.
     */
    fun sortedConnectedServers(snapshot: AppSnapshotRecord): List<AppServerSnapshot> {
        return snapshot.servers
            .filter { it.health != AppServerHealth.DISCONNECTED || it.connectionProgress != null }
            .sortedWith(compareBy<AppServerSnapshot> {
                // Active server (has active thread on it) sorts first
                val activeServerId = snapshot.activeThread?.let { key ->
                    key.serverId
                }
                if (it.serverId == activeServerId) 0 else 1
            }.thenBy { it.backendKind.name }.thenBy { it.displayName.lowercase() })
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
