package com.litter.android.ui.common

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Describes one swipe-revealed action slot. The caller supplies icon, label,
 * tint, and an `onTrigger` callback that fires once the gesture commits.
 */
data class SwipeAction(
    val icon: ImageVector,
    val label: String,
    val tint: Color,
    val onTrigger: () -> Unit,
)

/**
 * Generalized swipe wrapper: leading swipe (drag right) and/or trailing
 * swipe (drag left) reveal action slots behind the row. Releasing past the
 * commit threshold fires the action with a haptic; otherwise the row
 * springs back.
 *
 * This is a configurable generalization of [com.litter.android.ui.home.SwipeToHideRow].
 * Both coexist; use this one when you need a reply affordance or both-sided swipes.
 */
@Composable
fun SwipeableRow(
    leadingAction: SwipeAction? = null,
    trailingAction: SwipeAction? = null,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()

    // Commit threshold and max reveal mirror iOS: commit at ~35% of 260dp ≈ 90dp,
    // with extra reveal room up to 140dp.
    val commitDistancePx = with(density) { 90.dp.toPx() }
    val maxRevealPx = with(density) { 140.dp.toPx() }
    val activationDistancePx = with(density) { 8.dp.toPx() }

    val offsetX = remember { Animatable(0f) }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .clipToBounds(),
    ) {
        // Leading (right-swipe) reveal — visible on the left edge.
        if (leadingAction != null) {
            val progress = (offsetX.value / commitDistancePx).coerceIn(0f, 1f)
            ActionSlot(
                action = leadingAction,
                alignment = Alignment.CenterStart,
                progress = progress,
                modifier = Modifier
                    .matchParentSize()
                    .padding(start = 16.dp),
            )
        }

        // Trailing (left-swipe) reveal — visible on the right edge.
        if (trailingAction != null) {
            val progress = (-offsetX.value / commitDistancePx).coerceIn(0f, 1f)
            ActionSlot(
                action = trailingAction,
                alignment = Alignment.CenterEnd,
                progress = progress,
                modifier = Modifier
                    .matchParentSize()
                    .padding(end = 16.dp),
            )
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .offset { IntOffset(offsetX.value.roundToInt(), 0) }
                .pointerInput(leadingAction, trailingAction) {
                    var activated = false

                    detectHorizontalDragGestures(
                        onDragStart = { activated = false },
                        onDragEnd = {
                            val dx = offsetX.value
                            val trigger: SwipeAction? = when {
                                dx >= commitDistancePx && leadingAction != null -> leadingAction
                                dx <= -commitDistancePx && trailingAction != null -> trailingAction
                                else -> null
                            }
                            if (trigger != null) {
                                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                trigger.onTrigger()
                            }
                            scope.launch {
                                offsetX.animateTo(
                                    targetValue = 0f,
                                    animationSpec = spring(
                                        dampingRatio = Spring.DampingRatioMediumBouncy,
                                        stiffness = Spring.StiffnessMediumLow,
                                    ),
                                )
                            }
                        },
                        onDragCancel = {
                            scope.launch {
                                offsetX.animateTo(
                                    0f,
                                    animationSpec = tween(durationMillis = 180),
                                )
                            }
                        },
                        onHorizontalDrag = { change, dragAmount ->
                            if (!activated && abs(dragAmount) < activationDistancePx) return@detectHorizontalDragGestures
                            activated = true

                            val proposed = offsetX.value + dragAmount
                            val clamped = when {
                                proposed > 0f && leadingAction == null -> 0f
                                proposed < 0f && trailingAction == null -> 0f
                                else -> proposed.coerceIn(-maxRevealPx, maxRevealPx)
                            }
                            scope.launch { offsetX.snapTo(clamped) }
                            if (clamped != proposed) return@detectHorizontalDragGestures
                            change.consume()
                        },
                    )
                },
        ) {
            content()
        }
    }
}

@Composable
private fun BoxScope.ActionSlot(
    action: SwipeAction,
    alignment: Alignment,
    progress: Float,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .background(action.tint.copy(alpha = 0.18f * progress)),
        contentAlignment = alignment,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.alpha(progress),
        ) {
            Icon(
                imageVector = action.icon,
                contentDescription = action.label,
                tint = action.tint,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = action.label,
                color = action.tint,
                fontSize = 12.sp,
            )
        }
    }
}
