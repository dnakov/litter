package com.litter.android.ui.sessions

import com.litter.android.state.backendLabel
import com.litter.android.state.canBrowseDirectories
import com.litter.android.state.connectionPathLabel
import com.litter.android.state.defaultModelLabel
import com.litter.android.state.modelCatalogCountLabel
import com.litter.android.state.serverSubtitle
import com.litter.android.state.statusLabel
import com.litter.android.state.transportLabel
import uniffi.codex_mobile_client.AppServerBackendKind
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.ThreadKey

data class ServerPickerOption(
    val id: String,
    val name: String,
    val backendKind: AppServerBackendKind,
    val backendLabel: String,
    val transportLabel: String,
    val connectionPathLabel: String,
    val statusLabel: String,
    val subtitle: String,
    val lastUsedDirectoryHint: String?,
    val defaultModelLabel: String?,
    val modelCatalogCountLabel: String,
    val knownDirectories: List<String>,
    val canBrowseDirectories: Boolean,
)

object SessionLaunchSupport {
    fun defaultConnectedServerId(
        connectedServerIds: List<String>,
        activeThreadKey: ThreadKey?,
        preferredServerId: String? = null,
    ): String? {
        if (connectedServerIds.isEmpty()) return null
        val trimmedPreferred = preferredServerId?.trim().orEmpty()
        if (trimmedPreferred.isNotEmpty() && connectedServerIds.contains(trimmedPreferred)) {
            return trimmedPreferred
        }
        val activeServerId = activeThreadKey?.serverId?.trim().orEmpty()
        if (activeServerId.isNotEmpty() && connectedServerIds.contains(activeServerId)) {
            return activeServerId
        }
        return connectedServerIds.first()
    }

    fun serverPickerOptions(servers: List<AppServerSnapshot>): List<ServerPickerOption> =
        servers.map { server ->
            ServerPickerOption(
                id = server.serverId,
                name = server.displayName,
                backendKind = server.backendKind,
                backendLabel = server.backendLabel,
                transportLabel = server.transportLabel,
                connectionPathLabel = server.connectionPathLabel,
                statusLabel = server.statusLabel,
                subtitle = server.serverSubtitle,
                lastUsedDirectoryHint = server.lastUsedDirectoryHint?.takeIf { it.isNotBlank() },
                defaultModelLabel = server.defaultModelLabel,
                modelCatalogCountLabel = server.modelCatalogCountLabel,
                knownDirectories = server.knownDirectories,
                canBrowseDirectories = server.canBrowseDirectories,
            )
        }
}
