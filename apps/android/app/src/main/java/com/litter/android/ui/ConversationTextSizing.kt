package com.litter.android.ui

object ConversationTextSizing {
    const val MIN_STEP = 0
    const val MAX_STEP = 4
    const val DEFAULT_STEP = 2

    fun clampStep(step: Int): Int = step.coerceIn(MIN_STEP, MAX_STEP)

    fun scaleForStep(step: Int): Float =
        when (clampStep(step)) {
            0 -> 0.86f
            1 -> 0.93f
            2 -> 1.0f
            3 -> 1.1f
            else -> 1.22f
        }

    fun pinchDeltaForScale(scale: Float): Int =
        when {
            scale >= 1.18f -> 2
            scale >= 1.03f -> 1
            scale <= 0.86f -> -2
            scale <= 0.97f -> -1
            else -> 0
        }
}
