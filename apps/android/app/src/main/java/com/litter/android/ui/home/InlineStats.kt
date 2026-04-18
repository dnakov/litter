package com.litter.android.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.SubdirectoryArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.HydratedConversationItem

/**
 * Compact right-aligned stat chip row: turn count / tool count / diff /
 * stopwatch / token usage. Meant to live on the same line as the model
 * badge at zoom 3+, taking just enough width so left-side text (which
 * carries `weight(1f)`) truncates before these chips compress.
 *
 * Ref: HomeDashboardView.swift:820-855 (`inlineStats`).
 */
@Composable
fun InlineStats(
    session: AppSessionSummary,
    items: List<HydratedConversationItem>,
    isActive: Boolean,
    modifier: Modifier = Modifier,
) {
    val stats = session.stats
    val turnCount = stats?.turnCount?.toInt() ?: 0
    val toolCallCount = stats?.toolCallCount?.toInt() ?: 0
    val additions = stats?.diffAdditions?.toInt() ?: 0
    val deletions = stats?.diffDeletions?.toInt() ?: 0
    val bounds = lastTurnBounds(items, isActive = isActive)
    val tokenUsage = session.tokenUsage

    Row(
        modifier = modifier.wrapContentWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (turnCount > 0) {
            IconCountChip(
                icon = { size ->
                    Icon(
                        imageVector = Icons.Outlined.SubdirectoryArrowRight,
                        contentDescription = null,
                        tint = LitterTheme.textMuted.copy(alpha = 0.7f),
                        modifier = Modifier.size(size),
                    )
                },
                count = turnCount,
            )
        }
        if (toolCallCount > 0) {
            IconCountChip(
                icon = { size ->
                    Icon(
                        imageVector = Icons.Outlined.Code,
                        contentDescription = null,
                        tint = LitterTheme.textMuted.copy(alpha = 0.7f),
                        modifier = Modifier.size(size),
                    )
                },
                count = toolCallCount,
            )
        }
        if (additions > 0 || deletions > 0) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = "+$additions",
                    color = LitterTheme.accent.copy(alpha = 0.7f),
                    fontFamily = LitterTheme.monoFont,
                    fontSize = CHIP_FONT_SP.scaled,
                )
                Text(
                    text = "-$deletions",
                    color = LitterTheme.danger.copy(alpha = 0.6f),
                    fontFamily = LitterTheme.monoFont,
                    fontSize = CHIP_FONT_SP.scaled,
                )
            }
        }
        if (bounds != null) {
            TurnStopwatchChip(
                startSeconds = bounds.startSeconds,
                endSeconds = bounds.endSeconds,
            )
        }
        val window = tokenUsage?.contextWindow
        if (tokenUsage != null && window != null && window > 0L) {
            val pct = ((tokenUsage.totalTokens.toDouble() / window.toDouble()) * 100.0).toInt()
            val color = if (pct > 80) {
                LitterTheme.warning.copy(alpha = 0.8f)
            } else {
                LitterTheme.textMuted.copy(alpha = 0.7f)
            }
            Text(
                text = "$pct%",
                color = color,
                fontFamily = LitterTheme.monoFont,
                fontSize = CHIP_FONT_SP.scaled,
            )
        }
    }
}

@Composable
private fun IconCountChip(
    icon: @Composable (size: androidx.compose.ui.unit.Dp) -> Unit,
    count: Int,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        icon(10.dp)
        Text(
            text = "$count",
            color = LitterTheme.textMuted.copy(alpha = 0.7f),
            fontFamily = LitterTheme.monoFont,
            fontSize = CHIP_FONT_SP.scaled,
        )
    }
}

private const val CHIP_FONT_SP = 10f
