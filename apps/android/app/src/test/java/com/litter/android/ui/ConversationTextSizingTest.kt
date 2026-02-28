package com.litter.android.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class ConversationTextSizingTest {
    @Test
    fun clampBoundsStepRange() {
        assertEquals(ConversationTextSizing.MIN_STEP, ConversationTextSizing.clampStep(-7))
        assertEquals(ConversationTextSizing.MAX_STEP, ConversationTextSizing.clampStep(99))
    }

    @Test
    fun returnsExpectedScaleValues() {
        assertEquals(0.86f, ConversationTextSizing.scaleForStep(0), 0.0001f)
        assertEquals(0.93f, ConversationTextSizing.scaleForStep(1), 0.0001f)
        assertEquals(1.0f, ConversationTextSizing.scaleForStep(2), 0.0001f)
        assertEquals(1.1f, ConversationTextSizing.scaleForStep(3), 0.0001f)
        assertEquals(1.22f, ConversationTextSizing.scaleForStep(4), 0.0001f)
    }

    @Test
    fun pinchDeltaThresholdsMatchConversationBehavior() {
        assertEquals(2, ConversationTextSizing.pinchDeltaForScale(1.2f))
        assertEquals(1, ConversationTextSizing.pinchDeltaForScale(1.05f))
        assertEquals(0, ConversationTextSizing.pinchDeltaForScale(1.0f))
        assertEquals(-1, ConversationTextSizing.pinchDeltaForScale(0.95f))
        assertEquals(-2, ConversationTextSizing.pinchDeltaForScale(0.8f))
    }
}
