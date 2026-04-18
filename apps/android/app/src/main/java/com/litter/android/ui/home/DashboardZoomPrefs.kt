package com.litter.android.ui.home

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Persistent storage for the home dashboard zoom level.
 *
 * Levels 1..4 map to increasingly detailed canvas rows, matching iOS:
 *   1 = scan (title + status dot only)
 *   2 = glance (title + metaLine)
 *   3 = read (+ modelBadgeLine, userMessage, tool log, response preview capped at 25% screen)
 *   4 = deep (expanded title, response preview capped at 50%, full tool log)
 * Default is level 2. Mirrors the iOS dashboard zoom control on
 * HomeDashboardView.swift `@AppStorage("homeZoomLevel")`.
 */
object DashboardZoomPrefs {
    private const val PREFS = "litter_ui_prefs"
    private const val KEY = "dashboardZoomStep"

    const val MIN_LEVEL = 1
    const val MAX_LEVEL = 4
    const val DEFAULT_LEVEL = 2

    private val _currentLevel = MutableStateFlow(DEFAULT_LEVEL)
    val currentLevel: StateFlow<Int> = _currentLevel.asStateFlow()

    fun initialize(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = prefs.getInt(KEY, DEFAULT_LEVEL)
        _currentLevel.value = stored.coerceIn(MIN_LEVEL, MAX_LEVEL)
    }

    fun setLevel(context: Context, level: Int) {
        val clamped = level.coerceIn(MIN_LEVEL, MAX_LEVEL)
        if (clamped == _currentLevel.value) return
        _currentLevel.value = clamped
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putInt(KEY, clamped).apply()
    }
}
