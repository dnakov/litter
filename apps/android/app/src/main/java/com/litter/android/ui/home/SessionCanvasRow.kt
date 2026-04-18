package com.litter.android.ui.home

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.litter.android.state.displayTitle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.common.FormattedText
import com.litter.android.ui.common.StatusDot
import com.litter.android.ui.common.StatusDotState
import com.litter.android.ui.scaled
import com.litter.android.ui.LitterTextStyle
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.HydratedConversationItem

/**
 * Zoom-aware session card, replacing the flat `SessionCard` used previously
 * in the home dashboard. Layers reveal progressively:
 *   1  SCAN    — title + status dot only.
 *   2  GLANCE  — + time · server · workspace meta line (tool-activity label
 *                 when an active thread is running a tool).
 *   3  READ    — + modelBadgeLine (server/model + inline stats + stopwatch),
 *                 user message quote, compact tool log, short response preview.
 *   4  DEEP    — tool log expanded (3 rows), larger response preview cap.
 *
 * Each layer is wrapped in `AnimatedVisibility` so zoom transitions ripple
 * in, matching the iOS animation feel.
 *
 * Ref: HomeDashboardView.swift:591-680 (`body`) and zoom-gated rendering
 * at L620-652.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SessionCanvasRow(
    session: AppSessionSummary,
    zoomLevel: Int,
    isHydrating: Boolean,
    onClick: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val appModel = LocalAppModel.current
    val threadSnapshot = remember(session.key, zoomLevel) {
        appModel.threadSnapshot(session.key)
    }
    val hydratedItems: List<HydratedConversationItem> =
        threadSnapshot?.hydratedConversationItems.orEmpty()
    val isActive = session.hasActiveTurn
    val toolRunning = remember(hydratedItems) { isToolCallRunning(hydratedItems) }

    val dotState = when {
        isActive -> StatusDotState.ACTIVE
        isHydrating -> StatusDotState.PENDING
        session.stats != null -> StatusDotState.OK
        else -> StatusDotState.IDLE
    }

    var showMenu by remember { mutableStateOf(false) }
    val layerSpring = remember {
        spring<androidx.compose.ui.unit.IntSize>(
            stiffness = 400f,
            dampingRatio = 0.78f,
        )
    }

    Box(modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = { showMenu = true },
                )
                .padding(horizontal = 4.dp, vertical = 6.dp),
            verticalAlignment = Alignment.Top,
        ) {
            StatusDot(
                state = dotState,
                size = 8.dp,
                modifier = Modifier.padding(top = if (zoomLevel == 1) 2.dp else 4.dp),
            )
            Spacer(Modifier.width(8.dp))

            Column(modifier = Modifier.weight(1f)) {
                FormattedText(
                    text = session.displayTitle,
                    color = if (isActive) LitterTheme.accent else LitterTheme.textPrimary,
                    fontSize = LitterTextStyle.body.scaled,
                    maxLines = if (zoomLevel >= 4) 4 else 1,
                    modifier = Modifier.fillMaxWidth(),
                )

                AnimatedVisibility(
                    visible = zoomLevel >= 2,
                    enter = fadeIn(tween(200)) + expandVertically(animationSpec = layerSpring),
                    exit = fadeOut(tween(120)) + shrinkVertically(animationSpec = layerSpring),
                ) {
                    MetaLine(
                        session = session,
                        isActive = isActive,
                        toolRunning = toolRunning,
                    )
                }

                AnimatedVisibility(
                    visible = zoomLevel >= 3,
                    enter = fadeIn(tween(200)) + expandVertically(animationSpec = layerSpring),
                    exit = fadeOut(tween(120)) + shrinkVertically(animationSpec = layerSpring),
                ) {
                    Column {
                        ModelBadgeLine(
                            session = session,
                            items = hydratedItems,
                            isActive = isActive,
                        )
                        RecentUserMessageLine(session = session)
                        ToolLogColumn(
                            items = hydratedItems,
                            maxEntries = if (zoomLevel >= 4) 3 else 1,
                        )
                        val assistant = remember(hydratedItems) {
                            displayedAssistantMessage(hydratedItems)
                        }
                        val fallback = session.lastResponsePreview?.trim().orEmpty()
                        val text = assistant?.text?.takeIf { it.trim().isNotEmpty() } ?: fallback
                        val blockId = assistant?.id ?: "fallback"
                        if (text.trim().isNotEmpty()) {
                            ResponsePreview(
                                text = text,
                                blockId = blockId,
                                zoomLevel = zoomLevel,
                            )
                        }
                    }
                }
            }

            Box {
                IconButton(
                    onClick = { showMenu = true },
                    modifier = Modifier.size(28.dp),
                ) {
                    Icon(
                        Icons.Default.MoreVert,
                        contentDescription = "Session actions",
                        tint = LitterTheme.textSecondary,
                    )
                }
                DropdownMenu(
                    expanded = showMenu,
                    onDismissRequest = { showMenu = false },
                ) {
                    DropdownMenuItem(
                        text = { Text("Delete") },
                        onClick = {
                            showMenu = false
                            onDelete()
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun MetaLine(
    session: AppSessionSummary,
    isActive: Boolean,
    toolRunning: Boolean,
) {
    val showActivity = isActive && toolRunning
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (showActivity) {
            Text(
                text = "running tool…",
                color = LitterTheme.accent,
                fontFamily = LitterTheme.monoFont,
                fontSize = META_FONT_SP.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        } else {
            val relative = HomeDashboardSupport.relativeTime(session.updatedAt)
            if (relative.isNotEmpty()) {
                Text(
                    text = relative,
                    color = LitterTheme.textMuted,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = META_FONT_SP.scaled,
                )
            }
            Text(
                text = session.serverDisplayName,
                color = LitterTheme.textSecondary,
                fontFamily = LitterTheme.monoFont,
                fontSize = META_FONT_SP.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = HomeDashboardSupport.workspaceLabel(session.cwd),
                color = LitterTheme.textMuted,
                fontFamily = LitterTheme.monoFont,
                fontSize = META_FONT_SP.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (isActive) {
                Text(
                    text = "thinking",
                    color = LitterTheme.accent,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = META_FONT_SP.scaled,
                )
            }
        }
    }
}

@Composable
private fun ToolLogColumn(
    items: List<HydratedConversationItem>,
    maxEntries: Int,
) {
    val rows = remember(items, maxEntries) { hydratedToolRows(items, maxEntries) }
    if (rows.isEmpty()) return
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 6.dp, bottom = 2.dp),
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        rows.forEach { row ->
            HomeToolRowView(row = row)
        }
    }
}

private const val META_FONT_SP = 11f
