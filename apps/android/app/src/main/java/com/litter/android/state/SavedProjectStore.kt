package com.litter.android.state

import android.content.Context
import uniffi.codex_mobile_client.HomeSelection
import uniffi.codex_mobile_client.preferencesLoad
import uniffi.codex_mobile_client.preferencesSetHomeSelection

/**
 * Last-used server / project selection for the home screen. Backed by the
 * shared Rust preferences store so this state can sync alongside pinned
 * threads once a cloud sync backend lands.
 */
object SavedProjectStore {
    fun selectedServerId(context: Context): String? =
        loadSelection(context).selectedServerId

    fun setSelectedServerId(context: Context, serverId: String?) {
        val current = loadSelection(context)
        writeSelection(
            context,
            current.copy(selectedServerId = serverId),
        )
    }

    fun selectedProjectId(context: Context): String? =
        loadSelection(context).selectedProjectId

    fun setSelectedProjectId(context: Context, projectId: String?) {
        val current = loadSelection(context)
        writeSelection(
            context,
            current.copy(selectedProjectId = projectId),
        )
    }

    private fun loadSelection(context: Context): HomeSelection =
        preferencesLoad(MobilePreferencesDirectory.path(context)).homeSelection

    private fun writeSelection(context: Context, selection: HomeSelection) {
        preferencesSetHomeSelection(MobilePreferencesDirectory.path(context), selection)
    }
}
