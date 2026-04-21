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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import com.litter.android.ui.common.FormattedText
import com.litter.android.ui.common.StatusDot
import com.litter.android.ui.common.StatusDotState
import com.litter.android.ui.scaled
import com.litter.android.ui.LitterTextStyle
import uniffi.codex_mobile_client.AppOperationStatus
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppToolLogEntry

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
    // Rust's reducer already derives every field this card displays — last
    // response text, recent tool log, last-turn bounds — into `session`.
    // Reading `appModel.threadSnapshot(session.key)` here used to create a
    // per-card subscription to the global snapshot observable; every
    // streaming-delta bumped that observable and re-invalidated all cards
    // even though most had nothing to redraw. Using only `session` props
    // keeps the card's AttributeGraph footprint at one edge per row.
    val isActive = session.hasActiveTurn
    val toolRunning = remember(session.recentToolLog) {
        session.recentToolLog.lastOrNull()?.status?.let { status ->
            status == "inprogress" || status == "pending"
        } ?: false
    }

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

    // Vertical padding per zoom matches iOS `[3, 6, 10, 12][zoomLevel-1]`
    // (HomeDashboardView.swift:661). Horizontal kept at 14dp to match iOS.
    val rowVerticalPadding = when (zoomLevel) {
        1 -> 3.dp
        2 -> 6.dp
        3 -> 10.dp
        else -> 12.dp
    }

    Box(modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = { showMenu = true },
                )
                .padding(horizontal = 14.dp, vertical = rowVerticalPadding),
            verticalAlignment = Alignment.Top,
        ) {
            // Mirrors iOS `HomeDashboardView.swift:602-604`:
            //   .frame(width: markerWidth (14), height: 16)
            //   .padding(.top, zoomLevel == 1 ? 0 : 2)
            // 10pt dot centered in a 14×16 slot with a 2pt top nudge puts
            // the dot center at y≈10 from the row top, which lines up with
            // the midline of the title's first line (17pt body, line
            // height ≈20pt). At zoom 1 (pad=0) the dot sits ~2pt higher to
            // match iOS's slightly terser compact layout.
            // Top offset is larger than iOS's 2pt because Compose `Text`
            // applies `includeFontPadding = true` by default, which shifts
            // the visible glyphs down inside the line box. Tuned so the
            // dot center lines up with the cap-height midline of the
            // 17.dp body-size title at zoom ≥ 2.
            Box(
                modifier = Modifier
                    .padding(top = if (zoomLevel == 1) 2.dp else 5.dp)
                    .width(14.dp)
                    .height(16.dp),
                contentAlignment = Alignment.Center,
            ) {
                StatusDot(
                    state = dotState,
                    size = 10.dp,
                )
            }
            Spacer(Modifier.width(8.dp))

            Column(modifier = Modifier.weight(1f)) {
                FormattedText(
                    text = session.displayTitle,
                    color = if (isActive) LitterTheme.accent else LitterTheme.textPrimary,
                    fontSize = LitterTextStyle.body.scaled,
                    maxLines = if (zoomLevel >= 4) 4 else 1,
                    modifier = Modifier.fillMaxWidth(),
                )

                // MetaLine is shown ONLY at zoom 2 (iOS `if zoomLevel == 2`).
                // At zoom 3+, modelBadgeLine replaces it with the richer,
                // single-line model/time/server row.
                AnimatedVisibility(
                    visible = zoomLevel == 2,
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
                            isActive = isActive,
                        )
                        RecentUserMessageLine(session = session)
                        ToolLogColumn(
                            entries = session.recentToolLog,
                            maxEntries = if (zoomLevel >= 4) 3 else 1,
                        )
                        val text = session.lastResponsePreview?.trim().orEmpty()
                        // Key on the assistant message's source_turn_id so
                        // the crossfade only fires when a new assistant
                        // reply arrives. Keying on `stats.turnCount` would
                        // bump the id the moment the user submits a new
                        // prompt — before any new assistant text — so the
                        // preview would fade out (and back in with the
                        // same prior text) on every send.
                        val blockId = session.lastResponseTurnId ?: "empty"
                        if (text.isNotEmpty()) {
                            ResponsePreview(
                                text = text,
                                blockId = blockId,
                                zoomLevel = zoomLevel,
                            )
                        }
                    }
                }

                // Working directory line at zoom 4 only, matches iOS
                // HomeDashboardView.swift:645-652.
                AnimatedVisibility(
                    visible = zoomLevel >= 4 && !session.cwd.isNullOrBlank(),
                    enter = fadeIn(tween(200)) + expandVertically(animationSpec = layerSpring),
                    exit = fadeOut(tween(120)) + shrinkVertically(animationSpec = layerSpring),
                ) {
                    Text(
                        text = session.cwd.orEmpty(),
                        color = LitterTheme.textMuted.copy(alpha = 0.7f),
                        fontFamily = LitterTheme.monoFont,
                        fontSize = 10f.scaled,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }

            // Long-press on the row opens the action menu — replaces the
            // former 3-dot IconButton. Menu is anchored here so it pops
            // near the trailing edge.
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
        Row(
            modifier = Modifier.weight(1f),
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

        // Inline stat chips on the trailing edge of the meta line. iOS
        // HomeDashboardView.swift:713,722-749 renders these at zoom 2.
        InlineStats(
            session = session,
            isActive = isActive,
        )
    }
}

@Composable
private fun ToolLogColumn(
    entries: List<AppToolLogEntry>,
    maxEntries: Int,
) {
    // Rust-side `recent_tool_log` is newest-last; take the tail to mirror the
    // old `hydratedToolRows` behavior. Replaces a per-card iteration over
    // hydrated items.
    val rows = remember(entries, maxEntries) { entries.takeLast(maxEntries) }
    if (rows.isEmpty()) return
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 6.dp, bottom = 2.dp),
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        rows.forEach { entry ->
            HomeToolRowView(entry = entry)
        }
    }
}

private const val META_FONT_SP = 11f
