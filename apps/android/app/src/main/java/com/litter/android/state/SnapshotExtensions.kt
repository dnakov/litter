package com.litter.android.state

import androidx.compose.ui.graphics.Color
import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.HydratedConversationItemContent

/** Accent green matching iOS theme. */
private val AccentGreen = Color(0xFF00FF9C)
private val WarningOrange = Color(0xFFFF9500)
private val SecondaryGray = Color(0xFF8E8E93)

// --- AppServerHealth extensions ----------------------------------------------

val AppServerHealth.displayLabel: String
    get() = when (this) {
        AppServerHealth.CONNECTED -> "Connected"
        AppServerHealth.CONNECTING -> "Connecting\u2026"
        AppServerHealth.UNRESPONSIVE -> "Unresponsive"
        AppServerHealth.DISCONNECTED -> "Disconnected"
        AppServerHealth.UNKNOWN -> "Unknown"
    }

val AppServerHealth.accentColor: Color
    get() = when (this) {
        AppServerHealth.CONNECTED -> AccentGreen
        AppServerHealth.CONNECTING, AppServerHealth.UNRESPONSIVE -> WarningOrange
        AppServerHealth.DISCONNECTED, AppServerHealth.UNKNOWN -> SecondaryGray
    }

// --- AppServerSnapshot extensions --------------------------------------------

val AppServerSnapshot.isConnected: Boolean
    get() = health == AppServerHealth.CONNECTED

val AppServerSnapshot.isIpcConnected: Boolean
    get() = hasIpc && !isLocal && isConnected

val AppServerSnapshot.connectionModeLabel: String
    get() = when {
        isLocal -> "local"
        else -> "remote"
    }

val AppServerSnapshot.statusLabel: String
    get() = when {
        health == AppServerHealth.CONNECTED && !isLocal && account == null -> "Sign in required"
        else -> health.displayLabel
    }

val AppServerSnapshot.statusColor: Color
    get() = when {
        health == AppServerHealth.CONNECTED && !isLocal && account == null -> WarningOrange
        else -> health.accentColor
    }

// --- AppThreadSnapshot extensions --------------------------------------------

val AppThreadSnapshot.hasActiveTurn: Boolean
    get() = activeTurnId != null

val AppThreadSnapshot.resolvedModel: String
    get() = model ?: info.model ?: ""

val AppThreadSnapshot.resolvedPreview: String
    get() = info.title?.takeIf { it.isNotBlank() }
        ?: info.preview?.takeIf { it.isNotBlank() }
        ?: "Untitled session"

val AppThreadSnapshot.contextPercent: Int
    get() {
        val window = modelContextWindow?.toLong() ?: return 0
        if (window <= 0L) return 0
        val used = contextTokensUsed?.toLong() ?: return 0
        return ((used * 100) / window).toInt().coerceIn(0, 100)
    }

val AppThreadSnapshot.latestAssistantSnippet: String?
    get() {
        val items = hydratedConversationItems
        for (i in items.indices.reversed()) {
            val content = items[i].content
            if (content is HydratedConversationItemContent.Assistant) {
                val text = content.v1.text
                if (text.isNotBlank()) {
                    return if (text.length > 120) text.takeLast(120) else text
                }
            }
        }
        return null
    }
