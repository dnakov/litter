package com.litter.android.ui.home

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.scaled
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Swipe-left-to-hide wrapper. Reveals a full-row red "hide" action whose
 * opacity tracks how far the user has dragged. Releasing past the commit
 * threshold invokes `onHide`; the caller is expected to remove the row from
 * its list so the exit animation plays.
 */
@Composable
fun SwipeToHideRow(
    onHide: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    val commitDistancePx = with(density) { 120.dp.toPx() }
    val maxRevealPx = with(density) { 160.dp.toPx() }

    var offsetX by remember { mutableFloatStateOf(0f) }
    var committed by remember { mutableStateOf(false) }

    // Spring back to 0 when released without committing; slide fully off when committed.
    val animatedOffset by animateFloatAsState(
        targetValue = offsetX,
        label = "swipe-offset",
    )

    LaunchedEffect(committed) {
        if (committed) {
            onHide()
        }
    }

    val revealProgress = min(1f, kotlin.math.abs(animatedOffset) / commitDistancePx)

    Box(modifier = modifier.fillMaxWidth()) {
        // Full-row red background, opacity follows drag progress.
        Box(
            modifier = Modifier
                .matchParentSize()
                .alpha(revealProgress)
                .background(Color(0xFFB91C1C)),
            contentAlignment = Alignment.CenterEnd,
        ) {
            Row(
                modifier = Modifier.padding(end = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Default.VisibilityOff,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    text = "hide",
                    color = Color.White,
                    fontSize = LitterTextStyle.footnote.scaled,
                )
            }
        }

        // The content follows the drag.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .offset { IntOffset(animatedOffset.roundToInt(), 0) }
                .pointerInput(Unit) {
                    detectHorizontalDragGestures(
                        onHorizontalDrag = { change, dragAmount ->
                            if (committed) return@detectHorizontalDragGestures
                            val next = (offsetX + dragAmount).coerceIn(-maxRevealPx, 0f)
                            offsetX = next
                            change.consume()
                        },
                        onDragEnd = {
                            if (offsetX < -commitDistancePx) {
                                offsetX = -2000f
                                committed = true
                            } else {
                                offsetX = 0f
                            }
                        },
                        onDragCancel = {
                            offsetX = 0f
                        },
                    )
                },
        ) {
            content()
        }
    }
}
