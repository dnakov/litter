package com.litter.android.state

import androidx.compose.ui.graphics.Color
import uniffi.codex_mobile_client.AppServerBackendKind
import uniffi.codex_mobile_client.AppServerConnectionPath
import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppServerIpcState
import uniffi.codex_mobile_client.AppServerModelCatalogState
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppServerStatusKind
import uniffi.codex_mobile_client.AppServerTransportState
import uniffi.codex_mobile_client.AppServerTransportKind
import uniffi.codex_mobile_client.AppSessionSummary
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

val AppServerTransportState.displayLabel: String
    get() = when (this) {
        AppServerTransportState.CONNECTED -> "Connected"
        AppServerTransportState.CONNECTING -> "Connecting\u2026"
        AppServerTransportState.UNRESPONSIVE -> "Unresponsive"
        AppServerTransportState.DISCONNECTED -> "Disconnected"
        AppServerTransportState.UNKNOWN -> "Unknown"
    }

val AppServerTransportState.accentColor: Color
    get() = when (this) {
        AppServerTransportState.CONNECTED -> AccentGreen
        AppServerTransportState.CONNECTING, AppServerTransportState.UNRESPONSIVE -> WarningOrange
        AppServerTransportState.DISCONNECTED, AppServerTransportState.UNKNOWN -> SecondaryGray
    }

val AppServerBackendKind.displayLabel: String
    get() = when (this) {
        AppServerBackendKind.CODEX -> "Codex"
        AppServerBackendKind.OPEN_CODE -> "OpenCode"
    }

val AppServerTransportKind.displayLabel: String
    get() = when (this) {
        AppServerTransportKind.LOCAL -> "local"
        AppServerTransportKind.SSH -> "SSH"
        AppServerTransportKind.WEBSOCKET -> "WebSocket"
        AppServerTransportKind.HTTP -> "HTTP"
        AppServerTransportKind.HTTPS -> "HTTPS"
        AppServerTransportKind.TAILSCALE_HTTPS -> "HTTPS/Tailscale"
        AppServerTransportKind.UNKNOWN -> "unknown"
    }

val AppServerConnectionPath.displayLabel: String
    get() = when (this) {
        AppServerConnectionPath.LOCAL -> "local"
        AppServerConnectionPath.LAN -> "LAN"
        AppServerConnectionPath.TAILSCALE -> "Tailscale"
        AppServerConnectionPath.SSH -> "SSH"
        AppServerConnectionPath.UNKNOWN -> "unknown"
    }

val AppServerStatusKind.displayLabel: String
    get() = when (this) {
        AppServerStatusKind.CONNECTED -> "Connected"
        AppServerStatusKind.RECONNECTING -> "Reconnecting…"
        AppServerStatusKind.AUTH_REQUIRED -> "Auth required"
        AppServerStatusKind.DISCONNECTED -> "Disconnected"
        AppServerStatusKind.UNRESPONSIVE -> "Unresponsive"
        AppServerStatusKind.UNKNOWN -> "Unknown"
    }

val AppServerStatusKind.accentColor: Color
    get() = when (this) {
        AppServerStatusKind.CONNECTED -> AccentGreen
        AppServerStatusKind.RECONNECTING, AppServerStatusKind.AUTH_REQUIRED, AppServerStatusKind.UNRESPONSIVE -> WarningOrange
        AppServerStatusKind.DISCONNECTED, AppServerStatusKind.UNKNOWN -> SecondaryGray
    }

// --- AppServerSnapshot extensions --------------------------------------------

val AppServerSnapshot.isConnected: Boolean
    get() = transportState == AppServerTransportState.CONNECTED

val AppServerSnapshot.isIpcConnected: Boolean
    get() = ipcState == AppServerIpcState.READY

val AppServerSnapshot.canUseTransportActions: Boolean
    get() = capabilities.canUseTransportActions

val AppServerSnapshot.canBrowseDirectories: Boolean
    get() = capabilities.canBrowseDirectories

val AppServerSnapshot.canResumeViaIpc: Boolean
    get() = capabilities.canResumeViaIpc

val AppServerSnapshot.connectionModeLabel: String
    get() = "${backendKind.displayLabel} • ${transportKind.displayLabel}"

val AppServerSnapshot.backendLabel: String
    get() = backendKind.displayLabel

val AppServerSnapshot.transportLabel: String
    get() = transportKind.displayLabel

val AppServerSnapshot.connectionPathLabel: String
    get() = connectionPath.displayLabel

val AppServerSnapshot.serverSubtitle: String
    get() = listOf(backendLabel, transportLabel, connectionPathLabel)
        .distinct()
        .joinToString(" • ")

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
        else -> statusKind.displayLabel
    }

val AppServerSnapshot.statusColor: Color
    get() = when {
        currentConnectionStep?.state == AppConnectionStepState.FAILED -> Color(0xFFFF6B6B)
        currentConnectionStep?.state == AppConnectionStepState.AWAITING_USER_INPUT -> WarningOrange
        connectionProgressLabel != null -> AccentGreen
        else -> statusKind.accentColor
    }

val AppServerSnapshot.defaultModelLabel: String?
    get() = modelCatalog.defaultModelDisplayName?.takeIf { it.isNotBlank() }
        ?: modelCatalog.defaultModelId?.takeIf { it.isNotBlank() }

val AppServerSnapshot.hasLoadedModelCatalog: Boolean
    get() = modelCatalog.state == AppServerModelCatalogState.LOADED

val AppServerSnapshot.modelCatalogCountLabel: String
    get() = when (modelCatalog.state) {
        AppServerModelCatalogState.UNAVAILABLE -> "Unavailable"
        AppServerModelCatalogState.IDLE -> "Not loaded"
        AppServerModelCatalogState.LOADING -> "Loading…"
        AppServerModelCatalogState.LOADED -> "${modelCatalog.availableModelCount} models"
    }

// --- AppThreadSnapshot extensions --------------------------------------------

val ThreadSummaryStatus.isActiveStatus: Boolean
    get() = this == ThreadSummaryStatus.ACTIVE

val AppThreadSnapshot.hasActiveTurn: Boolean
    get() = activeTurnId?.trim()?.isNotEmpty() == true || info.status.isActiveStatus

val AppThreadSnapshot.resolvedModel: String
    get() = model ?: info.model ?: ""

val AppThreadSnapshot.displayTitle: String
    get() = info.preview?.takeIf { it.isNotBlank() }
        ?: info.title?.takeIf { it.isNotBlank() }
        ?: "Untitled session"

val AppThreadSnapshot.resolvedPreview: String
    get() = displayTitle

val AppSessionSummary.displayTitle: String
    get() = preview?.takeIf { it.isNotBlank() }
        ?: title?.takeIf { it.isNotBlank() }
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
            } else if (content is HydratedConversationItemContent.CodeReview) {
                val title = content.v1.findings.firstOrNull()?.title
                if (!title.isNullOrBlank()) {
                    return if (title.length > 120) title.take(120) else title
                }
            }
        }
        return null
    }
