package com.litter.android.state

import android.content.Context

class ServerModelPreferenceStore(context: Context) {
    private val prefs = context.getSharedPreferences("litter.serverModelPrefs", Context.MODE_PRIVATE)

    fun pinnedModels(serverId: String): List<String> =
        prefs.getStringSet(key(serverId), emptySet())
            ?.toList()
            ?.sorted()
            ?: emptyList()

    fun togglePinnedModel(serverId: String, modelId: String): List<String> {
        val existing = prefs.getStringSet(key(serverId), emptySet()).orEmpty().toMutableSet()
        if (!existing.add(modelId)) {
            existing.remove(modelId)
        }
        prefs.edit().putStringSet(key(serverId), existing).apply()
        return existing.toList().sorted()
    }

    private fun key(serverId: String): String = "pinned:$serverId"
}
