package com.litter.android.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp

/**
 * Text scaling system matching iOS ConversationTextSize.
 * 7-level scale from tiny (0.65x) to huge (1.8x), default large (1.2x).
 * All conversation text sizes are multiplied by this scale.
 */
enum class ConversationTextSize(val step: Int, val scale: Float, val label: String) {
    TINY(0, 0.65f, "Tiny"),
    SMALL(1, 0.8f, "Small"),
    MEDIUM(2, 1.0f, "Medium"),
    LARGE(3, 1.2f, "Large"),
    LARGER(4, 1.4f, "XL"),
    X_LARGE(5, 1.6f, "XXL"),
    HUGE(6, 1.8f, "Huge");

    companion object {
        val DEFAULT = LARGE

        fun fromStep(step: Int): ConversationTextSize =
            entries.firstOrNull { it.step == step } ?: DEFAULT
    }
}

/**
 * CompositionLocal providing the current text scale factor.
 * Read this in any composable to scale text: `fontSize = 14.scaled`
 */
val LocalTextScale = compositionLocalOf { ConversationTextSize.DEFAULT.scale }

/** Scale a base sp value by the current text scale. */
val Int.scaled: TextUnit
    @Composable get() = (this * LocalTextScale.current).sp

val Float.scaled: TextUnit
    @Composable get() = (this * LocalTextScale.current).sp

/**
 * Semantic text sizes matching iOS conventions.
 * All are base sizes that get multiplied by [LocalTextScale].
 */
object LitterTextStyle {
    /** Main message body text — 14sp base */
    const val body = 14f
    /** User bubble text — 14sp base */
    const val callout = 14f
    /** Secondary title — 15sp base */
    const val subheadline = 15f
    /** Section headers, small titles — 13sp base */
    const val footnote = 13f
    /** Small labels, timestamps — 12sp base */
    const val caption = 12f
    /** Very small labels — 11sp base */
    const val caption2 = 11f
    /** Code in messages — 13sp base */
    const val code = 13f
    /** Large headings — 17sp base */
    const val headline = 17f
}

/**
 * Persistent storage for text size preference.
 */
object TextSizePrefs {
    private const val PREFS = "litter_ui_prefs"
    private const val KEY = "conversationTextSizeStep"

    var currentStep by mutableIntStateOf(ConversationTextSize.DEFAULT.step)
        private set

    val currentScale: Float
        get() = ConversationTextSize.fromStep(currentStep).scale

    fun initialize(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        currentStep = prefs.getInt(KEY, ConversationTextSize.DEFAULT.step)
    }

    fun setStep(context: Context, step: Int) {
        val clamped = step.coerceIn(0, ConversationTextSize.entries.size - 1)
        currentStep = clamped
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putInt(KEY, clamped).apply()
    }
}

/**
 * Persistent conversation UI preferences that are shared across screens.
 */
object ConversationPrefs {
    private const val PREFS = "litter_ui_prefs"
    private const val KEY_COLLAPSE_TURNS = "collapseTurns"

    var collapseTurns by mutableIntStateOf(0)
        private set

    fun initialize(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        collapseTurns = if (prefs.getBoolean(KEY_COLLAPSE_TURNS, false)) 1 else 0
    }

    fun setCollapseTurns(context: Context, enabled: Boolean) {
        collapseTurns = if (enabled) 1 else 0
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_COLLAPSE_TURNS, enabled).apply()
    }

    val areTurnsCollapsed: Boolean
        get() = collapseTurns != 0
}
