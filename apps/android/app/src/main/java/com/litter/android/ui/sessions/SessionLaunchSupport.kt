package com.litter.android.ui.sessions

import uniffi.codex_mobile_client.ThreadKey

data class DirectoryPickerServerOption(
    val id: String,
    val name: String,
    val sourceLabel: String,
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
}
