package com.litter.android.ui.voice

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.Canvas
import com.litter.android.ui.LitterTheme
import uniffi.codex_mobile_client.AppVoiceSessionPhase
import kotlin.math.abs
import kotlin.math.max

@Composable
fun InlineVoiceButton(
    phase: AppVoiceSessionPhase?,
    inputLevel: Float,
    isAvailable: Boolean,
    onStart: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (!isAvailable) return

    val isActive = phase != null && phase != AppVoiceSessionPhase.ERROR

    val buttonSize by animateDpAsState(
        targetValue = if (isActive) 56.dp else 36.dp,
        animationSpec = spring(dampingRatio = 0.75f, stiffness = 400f),
        label = "inlineVoiceSize",
    )

    val iconColor = when (phase) {
        AppVoiceSessionPhase.CONNECTING,
        AppVoiceSessionPhase.LISTENING,
        -> LitterTheme.accent
        AppVoiceSessionPhase.SPEAKING,
        AppVoiceSessionPhase.THINKING,
        AppVoiceSessionPhase.HANDOFF,
        -> LitterTheme.warning
        AppVoiceSessionPhase.ERROR -> LitterTheme.danger
        else -> LitterTheme.textSecondary
    }

    val iconSize by animateDpAsState(
        targetValue = if (isActive) 22.dp else 16.dp,
        animationSpec = spring(dampingRatio = 0.75f, stiffness = 400f),
        label = "inlineVoiceIconSize",
    )

    Box(
        modifier = modifier
            .size(buttonSize)
            .clip(CircleShape)
            .background(if (isActive) iconColor else LitterTheme.surfaceLight, CircleShape)
            .clickable(onClick = if (isActive) onStop else onStart),
        contentAlignment = Alignment.Center,
    ) {
        if (phase == AppVoiceSessionPhase.CONNECTING) {
            CircularProgressIndicator(
                modifier = Modifier.size(iconSize * 0.9f),
                strokeWidth = 2.dp,
                color = Color.White,
            )
        } else {
            val waveformLevel by animateFloatAsState(
                targetValue = if (isActive) inputLevel else 0f,
                animationSpec = spring(dampingRatio = 0.7f, stiffness = 300f),
                label = "inlineWaveformLevel",
            )
            val barCount = if (isActive) 5 else 3
            val tint = if (isActive) Color.White else iconColor

            WaveformBars(
                level = waveformLevel,
                barCount = barCount,
                tint = tint,
                modifier = Modifier.size(
                    width = iconSize,
                    height = iconSize * 0.8f,
                ),
            )
        }
    }
}

@Composable
private fun WaveformBars(
    level: Float,
    barCount: Int,
    tint: Color,
    modifier: Modifier = Modifier,
) {
    Canvas(modifier = modifier) {
        val barWidth = 2.5.dp.toPx()
        val totalWidth = barWidth * barCount
        val gap = if (barCount > 1) {
            (size.width - totalWidth) / (barCount - 1)
        } else {
            0f
        }
        val midY = size.height / 2f
        val center = (barCount - 1) / 2f

        for (index in 0 until barCount) {
            val distance = abs(index - center) / max(center, 1f)
            val base = 1f - distance * 0.6f
            val activeLevel = max(0.25f, level)
            val barHeight = max(0.18f, base * activeLevel) * size.height
            val x = index * (barWidth + gap)
            val cornerRadius = 1.2.dp.toPx()

            val rect = Rect(
                left = x,
                top = midY - barHeight / 2f,
                right = x + barWidth,
                bottom = midY + barHeight / 2f,
            )
            drawPath(
                path = Path().apply { addRoundRect(
                    androidx.compose.ui.geometry.RoundRect(
                        rect = rect,
                        radiusX = cornerRadius,
                        radiusY = cornerRadius,
                    )
                ) },
                color = tint,
                style = Fill,
            )
        }
    }
}
