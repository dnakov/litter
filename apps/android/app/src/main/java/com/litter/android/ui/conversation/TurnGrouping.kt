package com.litter.android.ui.conversation

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalTextScale
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppOperationStatus
import uniffi.codex_mobile_client.HydratedCommandActionKind
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.MessagePhase

/**
 * A group of conversation items belonging to the same turn.
 */
data class TranscriptTurn(
    val id: String,
    val turnId: String?,
    val items: List<HydratedConversationItem>,
    val isActiveTurn: Boolean,
    val isCollapsedByDefault: Boolean,
) {
    val userPrompt: String?
        get() = items.firstOrNull { it.content is HydratedConversationItemContent.User }
            ?.let { (it.content as HydratedConversationItemContent.User).v1.text }

    val assistantSnippet: String?
        get() = (
            items.firstOrNull {
                val assistant = (it.content as? HydratedConversationItemContent.Assistant)?.v1
                assistant?.phase == MessagePhase.FINAL_ANSWER
            }
                ?: items.lastOrNull { it.content is HydratedConversationItemContent.Assistant }
            )
            ?.let { (it.content as HydratedConversationItemContent.Assistant).v1.text }
            ?.take(120)

    val commandCount: Int
        get() = items.count { it.content is HydratedConversationItemContent.CommandExecution }

    val fileChangeCount: Int
        get() = items.count { it.content is HydratedConversationItemContent.FileChange }

    val totalDurationMs: Long
        get() = items.sumOf {
            when (val c = it.content) {
                is HydratedConversationItemContent.CommandExecution -> c.v1.durationMs ?: 0L
                else -> 0L
            }
        }
}

/**
 * Groups a flat list of hydrated items into UI turns with the same boundary rules
 * as iOS: explicit user turn boundaries split turns, and streaming tails merge
 * back into the live turn instead of rendering as separate groups.
 */
fun buildTranscriptTurns(
    items: List<HydratedConversationItem>,
    activeTurnId: String?,
    isStreaming: Boolean,
    expandedRecentTurnCount: Int,
): List<TranscriptTurn> {
    if (items.isEmpty()) return emptyList()

    val groupedItems = mergeTrailingStreamingGroups(groupItems(items), isStreaming)
    val collapseBoundary = maxOf(0, groupedItems.size - expandedRecentTurnCount)
    val lastIndex = groupedItems.lastIndex

    return groupedItems.mapIndexed { index, turnItems ->
        val turnId = turnItems.firstNotNullOfOrNull { it.sourceTurnId }
        TranscriptTurn(
            id = turnIdentifier(turnItems, index),
            turnId = turnId,
            items = turnItems,
            isActiveTurn = (isStreaming && index == lastIndex) || turnId == activeTurnId,
            isCollapsedByDefault = index < collapseBoundary,
        )
    }
}

private fun groupItems(items: List<HydratedConversationItem>): List<List<HydratedConversationItem>> {
    val groups = mutableListOf<List<HydratedConversationItem>>()
    var current = mutableListOf<HydratedConversationItem>()
    var currentSourceTurnId: String? = null
    for (item in items) {
        val startsNewTurn =
            current.isNotEmpty() && (
                item.isFromUserTurnBoundary ||
                    (
                        item.sourceTurnId != null &&
                            currentSourceTurnId != null &&
                            item.sourceTurnId != currentSourceTurnId
                        )
                )

        if (startsNewTurn) {
            groups += current.toList()
            current = mutableListOf()
        }
        current += item

        currentSourceTurnId = when {
            currentSourceTurnId == null -> item.sourceTurnId
            current.size == 1 -> current.firstOrNull()?.sourceTurnId
            else -> currentSourceTurnId
        }
    }

    if (current.isNotEmpty()) {
        groups += current.toList()
    }

    return groups
}

private fun mergeTrailingStreamingGroups(
    groups: List<List<HydratedConversationItem>>,
    isStreaming: Boolean,
): List<List<HydratedConversationItem>> {
    if (!isStreaming || groups.size <= 1) return groups

    val liveTurnStartIndex = groups.indexOfLast { containsLiveTurnBoundary(it) }
    if (liveTurnStartIndex == -1 || liveTurnStartIndex >= groups.lastIndex) return groups

    val mergedLiveTurn = groups.subList(liveTurnStartIndex, groups.size).flatten()
    return buildList {
        addAll(groups.subList(0, liveTurnStartIndex))
        add(mergedLiveTurn)
    }
}

private fun containsLiveTurnBoundary(items: List<HydratedConversationItem>): Boolean {
    return items.any { item ->
        item.isFromUserTurnBoundary || item.content is HydratedConversationItemContent.User
    }
}

private fun turnIdentifier(items: List<HydratedConversationItem>, ordinal: Int): String {
    val first = items.firstOrNull() ?: return "turn-$ordinal"
    val sourceTurnId = items.firstNotNullOfOrNull { it.sourceTurnId }
    return if (sourceTurnId != null) {
        "turn-$sourceTurnId-${first.id}"
    } else {
        "turn-${first.id}"
    }
}

/**
 * Renders a collapsed turn card with preview and metadata.
 * Tap to expand and show all items.
 */
@Composable
fun CollapsedTurnCard(
    turn: TranscriptTurn,
    onExpand: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(10.dp))
            .clickable(onClick = onExpand)
            .padding(10.dp),
    ) {
        // User prompt preview
        turn.userPrompt?.let { prompt ->
            Text(
                text = prompt,
                color = LitterTheme.textPrimary,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        // Assistant snippet
        turn.assistantSnippet?.let { snippet ->
            Text(
                text = snippet,
                color = LitterTheme.textSecondary,
                fontSize = 12.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 2.dp),
            )
        }

        // Metadata footer
        Row(
            modifier = Modifier.padding(top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (turn.commandCount > 0) {
                MetadataBadge("${turn.commandCount} cmd", LitterTheme.toolCallCommand)
            }
            if (turn.fileChangeCount > 0) {
                MetadataBadge("${turn.fileChangeCount} files", LitterTheme.toolCallFileChange)
            }
            if (turn.totalDurationMs > 0) {
                val dur = if (turn.totalDurationMs < 1000) "${turn.totalDurationMs}ms"
                else "%.1fs".format(turn.totalDurationMs / 1000.0)
                MetadataBadge(dur, LitterTheme.textMuted)
            }
            Spacer(Modifier.weight(1f))
            Text("Tap to expand", color = LitterTheme.textMuted, fontSize = 10.sp)
        }
    }
}

@Composable
private fun MetadataBadge(text: String, color: androidx.compose.ui.graphics.Color) {
    Text(
        text = text,
        color = color,
        fontSize = 10.sp,
        fontWeight = FontWeight.Medium,
    )
}

/**
 * Groups consecutive CommandExecution items with empty/null output
 * into a collapsed "Explored N locations" row.
 */
data class ExplorationGroup(
    val id: String,
    val items: List<HydratedConversationItem>,
)

/**
 * Detects exploration groups in a list of items within a single turn.
 * Returns a mixed list of either individual items or exploration groups.
 */
sealed class TimelineEntry {
    data class Single(val item: HydratedConversationItem) : TimelineEntry()
    data class Exploration(val group: ExplorationGroup) : TimelineEntry()
}

fun buildTimelineEntries(
    items: List<HydratedConversationItem>,
    isLive: Boolean,
): List<TimelineEntry> {
    val result = mutableListOf<TimelineEntry>()
    var explorationRun = mutableListOf<HydratedConversationItem>()

    fun flushExploration() {
        if (explorationRun.isEmpty()) return
        if (isLive || explorationRun.size > 1) {
            val id = explorationRun.firstOrNull()?.id ?: "exploration"
            result.add(TimelineEntry.Exploration(ExplorationGroup(id = "exploration-$id", items = explorationRun.toList())))
        } else {
            explorationRun.forEach { result.add(TimelineEntry.Single(it)) }
        }
        explorationRun = mutableListOf()
    }

    for (item in items) {
        val content = item.content
        if (content is HydratedConversationItemContent.CommandExecution &&
            content.v1.isPureExploration()
        ) {
            explorationRun.add(item)
        } else {
            flushExploration()
            result.add(TimelineEntry.Single(item))
        }
    }
    flushExploration()
    return result
}

/**
 * Renders an exploration group as a collapsible summary.
 */
@Composable
fun ExplorationGroupRow(group: ExplorationGroup) {
    val textScale = LocalTextScale.current
    var expanded by remember { mutableStateOf(false) }
    val isActive = remember(group.items) { group.items.any { it.isInProgressExplorationItem() } }
    val shimmerProgress by rememberInfiniteTransition(label = "exploration-header-shimmer").animateFloat(
        initialValue = -1f,
        targetValue = 2f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1500, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "exploration-header-shimmer-progress",
    )
    val bulletSize = (6f * textScale).dp
    val bulletTopPadding = (5f * textScale).dp

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .animateContentSize(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                .clickable { expanded = !expanded }
                .padding(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = if (expanded) "▼" else "▶",
                color = LitterTheme.textMuted,
                fontSize = LitterTextStyle.caption.scaled,
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = if (isActive) "Exploring ${group.items.size} locations" else "Explored ${group.items.size} locations",
                color = if (isActive) LitterTheme.textPrimary else LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption.scaled,
                modifier = Modifier
                    .weight(1f)
                    .explorationHeaderShimmer(active = isActive, progress = shimmerProgress),
            )
        }

        if (expanded) {
            for (item in group.items) {
                val cmd = (item.content as HydratedConversationItemContent.CommandExecution).v1
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 24.dp, top = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Spacer(
                        modifier = Modifier
                            .padding(top = bulletTopPadding)
                            .width(bulletSize)
                            .height(bulletSize)
                            .background(
                                color = if (cmd.status == AppOperationStatus.PENDING || cmd.status == AppOperationStatus.IN_PROGRESS) {
                                    LitterTheme.warning
                                } else {
                                    LitterTheme.textMuted
                                },
                                shape = RoundedCornerShape(percent = 50),
                            ),
                    )
                    Text(
                        text = explorationLabel(cmd),
                        color = LitterTheme.textSecondary,
                        fontSize = LitterTextStyle.caption.scaled,
                        maxLines = Int.MAX_VALUE,
                        overflow = TextOverflow.Clip,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

private fun uniffi.codex_mobile_client.HydratedCommandExecutionData.isPureExploration(): Boolean {
    if (actions.isEmpty()) return false
    return actions.all { action ->
        when (action.kind) {
            HydratedCommandActionKind.READ,
            HydratedCommandActionKind.SEARCH,
            HydratedCommandActionKind.LIST_FILES,
            -> true

            HydratedCommandActionKind.UNKNOWN -> false
        }
    }
}

private fun HydratedConversationItem.isInProgressExplorationItem(): Boolean {
    val content = content as? HydratedConversationItemContent.CommandExecution ?: return false
    return content.v1.status == AppOperationStatus.PENDING || content.v1.status == AppOperationStatus.IN_PROGRESS
}

private fun explorationLabel(data: uniffi.codex_mobile_client.HydratedCommandExecutionData): String {
    val action = data.actions.firstOrNull() ?: return data.command
    return when (action.kind) {
        HydratedCommandActionKind.READ -> {
            action.path?.let { "Read ${workspaceTitle(it)}" } ?: action.command
        }

        HydratedCommandActionKind.SEARCH -> {
            when {
                !action.query.isNullOrBlank() && !action.path.isNullOrBlank() ->
                    "Searched for ${action.query} in ${workspaceTitle(action.path!!)}"
                !action.query.isNullOrBlank() ->
                    "Searched for ${action.query}"
                else -> action.command
            }
        }

        HydratedCommandActionKind.LIST_FILES -> {
            action.path?.let { "Listed files in ${workspaceTitle(it)}" } ?: action.command
        }

        HydratedCommandActionKind.UNKNOWN -> data.command
    }
}

private fun workspaceTitle(path: String): String {
    val normalized = path.replace('\\', '/').trimEnd('/')
    val lastSegment = normalized.substringAfterLast('/', normalized)
    return if (lastSegment.isBlank()) path else lastSegment
}

private fun Modifier.explorationHeaderShimmer(active: Boolean, progress: Float): Modifier {
    if (!active) return this
    return drawWithContent {
        drawContent()
        val width = size.width
        val shimmerWidth = width * 0.35f
        val startX = (width + shimmerWidth) * progress - shimmerWidth
        drawRect(
            brush = Brush.horizontalGradient(
                colors = listOf(
                    Color.Transparent,
                    Color.White.copy(alpha = 0.3f),
                    Color.Transparent,
                ),
                startX = startX,
                endX = startX + shimmerWidth,
            ),
            topLeft = Offset.Zero,
            size = size,
            blendMode = BlendMode.SrcAtop,
        )
    }
}
