package com.litter.android.state

import androidx.compose.ui.graphics.Color
import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.AppConnectionStepKind
import uniffi.codex_mobile_client.AppConnectionStepSnapshot
import uniffi.codex_mobile_client.AppConnectionStepState
import uniffi.codex_mobile_client.ThreadSummaryStatus

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

val AppServerSnapshot.currentConnectionStep: AppConnectionStepSnapshot?
    get() = connectionProgress?.steps?.firstOrNull {
        it.state == AppConnectionStepState.AWAITING_USER_INPUT ||
            it.state == AppConnectionStepState.IN_PROGRESS
    } ?: connectionProgress?.steps?.lastOrNull {
        it.state == AppConnectionStepState.FAILED ||
            it.state == AppConnectionStepState.COMPLETED
    }

val AppServerSnapshot.connectionProgressLabel: String?
    get() = when (currentConnectionStep?.kind) {
        AppConnectionStepKind.CONNECTING_TO_SSH -> "connecting"
        AppConnectionStepKind.FINDING_CODEX -> "finding codex"
        AppConnectionStepKind.INSTALLING_CODEX -> "installing"
        AppConnectionStepKind.STARTING_APP_SERVER -> "starting"
        AppConnectionStepKind.OPENING_TUNNEL -> "tunneling"
        AppConnectionStepKind.CONNECTED -> "connected"
        null -> null
    }

val AppServerSnapshot.connectionProgressDetail: String?
    get() = currentConnectionStep?.detail ?: connectionProgress?.terminalMessage

val AppServerSnapshot.statusLabel: String
    get() = when {
        connectionProgressLabel != null -> connectionProgressLabel!!
        health == AppServerHealth.CONNECTED && !isLocal && account == null -> "Sign in required"
        else -> health.displayLabel
    }

val AppServerSnapshot.statusColor: Color
    get() = when {
        currentConnectionStep?.state == AppConnectionStepState.FAILED -> Color(0xFFFF6B6B)
        currentConnectionStep?.state == AppConnectionStepState.AWAITING_USER_INPUT -> WarningOrange
        connectionProgressLabel != null -> AccentGreen
        health == AppServerHealth.CONNECTED && !isLocal && account == null -> WarningOrange
        else -> health.accentColor
    }

// --- AppThreadSnapshot extensions --------------------------------------------

val ThreadSummaryStatus.isActiveStatus: Boolean
    get() = this == ThreadSummaryStatus.ACTIVE

val AppThreadSnapshot.hasActiveTurn: Boolean
    get() = activeTurnId?.trim()?.isNotEmpty() == true || info.status.isActiveStatus

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
