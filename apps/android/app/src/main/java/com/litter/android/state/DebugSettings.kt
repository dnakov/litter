package com.litter.android.state

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * SharedPreferences-backed observable debug settings.
 * Gate access behind [enabled] — when false, all flags read as their defaults.
 */
object DebugSettings {
    private const val PREFS = "litter_debug_prefs"
    private const val KEY_ENABLED = "debug.enabled"
    private const val KEY_SHOW_TURN_METRICS = "debug.showTurnMetrics"
    private const val KEY_DISABLE_MARKDOWN = "debug.disableMarkdown"

    var enabled by mutableStateOf(false)
        private set
    var showTurnMetrics by mutableStateOf(false)
        private set
    var disableMarkdown by mutableStateOf(false)
        private set

    fun initialize(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        enabled = prefs.getBoolean(KEY_ENABLED, false)
        showTurnMetrics = prefs.getBoolean(KEY_SHOW_TURN_METRICS, false)
        disableMarkdown = prefs.getBoolean(KEY_DISABLE_MARKDOWN, false)
    }

    fun setEnabled(context: Context, value: Boolean) {
        enabled = value
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_ENABLED, value).apply()
    }

    fun setShowTurnMetrics(context: Context, value: Boolean) {
        showTurnMetrics = value
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_SHOW_TURN_METRICS, value).apply()
    }

    fun setDisableMarkdown(context: Context, value: Boolean) {
        disableMarkdown = value
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_DISABLE_MARKDOWN, value).apply()
    }
}
