package com.litter.android.ui.conversation

import android.annotation.SuppressLint
import android.content.Intent
import com.sigkitten.litter.android.R
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import android.graphics.BitmapFactory
import android.net.Uri
import android.text.method.LinkMovementMethod
import android.util.Base64
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.TextView
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.BerkeleyMono
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalTextScale
import com.litter.android.ui.scaled
import com.litter.android.state.AppModel
import io.noties.markwon.Markwon
import io.noties.markwon.syntax.SyntaxHighlightPlugin
import io.noties.prism4j.Prism4j
import org.json.JSONArray
import org.json.JSONObject
import uniffi.codex_mobile_client.AppMessageRenderBlock
import uniffi.codex_mobile_client.AppOperationStatus
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.HydratedPlanStepStatus
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * Renders a single [HydratedConversationItem] by matching on its content type.
 * Uses Rust-provided types directly — no intermediate model conversion.
 */
@Composable
fun ConversationTimelineItem(
    item: HydratedConversationItem,
    serverId: String,
    agentDirectoryVersion: ULong,
    latestCommandExecutionItemId: String? = null,
    isLiveTurn: Boolean = false,
    isStreamingMessage: Boolean = false,
    onStreamingSnapshotRendered: (() -> Unit)? = null,
    onEditMessage: ((UInt) -> Unit)? = null,
    onForkFromMessage: ((UInt) -> Unit)? = null,
) {
    val shouldNotifyLiveContentRendered = remember(item.content, isLiveTurn) {
        isLiveTurn && item.content.shouldAutoFollowRenderedContent()
    }

    LaunchedEffect(item.id, item.hashCode(), shouldNotifyLiveContentRendered) {
        if (!shouldNotifyLiveContentRendered) return@LaunchedEffect
        delay(32)
        onStreamingSnapshotRendered?.invoke()
    }

    when (val content = item.content) {
        is HydratedConversationItemContent.User -> UserMessageRow(
            data = content.v1,
            turnIndex = item.sourceTurnIndex ?: 0u,
            onEdit = onEditMessage,
            onFork = onForkFromMessage,
        )

        is HydratedConversationItemContent.Assistant -> AssistantMessageRow(
            itemId = item.id,
            data = content.v1,
            serverId = serverId,
            agentDirectoryVersion = agentDirectoryVersion,
            isStreamingMessage = isStreamingMessage,
            onStreamingSnapshotRendered = onStreamingSnapshotRendered,
        )

        is HydratedConversationItemContent.CodeReview -> CodeReviewRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.Reasoning -> ReasoningRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.CommandExecution -> CommandExecutionRow(
            data = content.v1,
            keepExpanded = item.id == latestCommandExecutionItemId ||
                content.v1.status == AppOperationStatus.PENDING ||
                content.v1.status == AppOperationStatus.IN_PROGRESS,
        )

        is HydratedConversationItemContent.FileChange -> FileChangeRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.TurnDiff -> TurnDiffRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.TodoList -> TodoListRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.ProposedPlan -> ProposedPlanRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.McpToolCall -> {
            val cu = content.v1.computerUse
            if (cu != null) {
                ComputerUseToolCallRow(data = content.v1, view = cu)
            } else {
                McpToolCallRow(data = content.v1)
            }
        }

        is HydratedConversationItemContent.DynamicToolCall -> DynamicToolCallRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.MultiAgentAction -> {
            SubagentCard(data = content.v1, serverId = serverId)
        }

        is HydratedConversationItemContent.WebSearch -> WebSearchRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.ImageView -> ImageViewRow(
            data = content.v1,
            serverId = serverId,
        )

        is HydratedConversationItemContent.ImageGeneration -> ImageGenerationRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.Widget -> WidgetRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.UserInputResponse -> UserInputResponseRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.Divider -> DividerRow(
            data = content.v1,
            isLiveTurn = isLiveTurn,
        )

        is HydratedConversationItemContent.Error -> ErrorRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.Note -> NoteRow(
            data = content.v1,
        )
    }
}

private fun HydratedConversationItemContent.shouldAutoFollowRenderedContent(): Boolean {
    return when (this) {
        is HydratedConversationItemContent.Reasoning,
        is HydratedConversationItemContent.CommandExecution,
        is HydratedConversationItemContent.FileChange,
        is HydratedConversationItemContent.TurnDiff,
        is HydratedConversationItemContent.McpToolCall,
        is HydratedConversationItemContent.DynamicToolCall,
        is HydratedConversationItemContent.MultiAgentAction,
        is HydratedConversationItemContent.WebSearch,
        is HydratedConversationItemContent.ImageView,
        is HydratedConversationItemContent.ImageGeneration,
        is HydratedConversationItemContent.Widget -> true
        else -> false
    }
}

// ── User Message ─────────────────────────────────────────────────────────────

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun UserMessageRow(
    data: uniffi.codex_mobile_client.HydratedUserMessageData,
    turnIndex: UInt,
    onEdit: ((UInt) -> Unit)?,
    onFork: ((UInt) -> Unit)?,
) {
    var showMenu by remember { mutableStateOf(false) }

    // Right-aligned user bubble, matching iOS `UserBubble`. The bubble caps at
    // 85% of row width so long messages still wrap nicely without becoming a
    // full-width block that reads as assistant text.
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.End,
    ) {
        Box {
            Column(
                modifier = Modifier
                    .fillMaxWidth(0.85f)
                    .background(LitterTheme.surface.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
                    .then(
                        if (onEdit != null || onFork != null) {
                            Modifier.combinedClickable(
                                onClick = {},
                                onLongClick = { showMenu = true },
                            )
                        } else {
                            Modifier
                        }
                    )
                    .padding(10.dp),
            ) {
                com.litter.android.ui.common.FormattedText(
                    text = data.text,
                    color = LitterTheme.textPrimary,
                    fontSize = LitterTextStyle.callout.scaled,
                )
                // Inline images from data URIs
                for (uri in data.imageDataUris) {
                    val bitmap = remember(uri) {
                        try {
                            val base64Part = uri.substringAfter("base64,", "")
                            if (base64Part.isNotEmpty()) {
                                val bytes = Base64.decode(base64Part, Base64.DEFAULT)
                                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                            } else null
                        } catch (_: Exception) { null }
                    }
                    bitmap?.let {
                        Image(
                            bitmap = it.asImageBitmap(),
                            contentDescription = "Attached image",
                            modifier = Modifier
                                .padding(top = 4.dp)
                                .heightIn(max = 200.dp)
                                .clip(RoundedCornerShape(8.dp)),
                        )
                    }
                }
            }

            // Long-press context menu
            androidx.compose.material3.DropdownMenu(
                expanded = showMenu,
                onDismissRequest = { showMenu = false },
            ) {
                if (onEdit != null) {
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text("Edit Message") },
                        onClick = { showMenu = false; onEdit(turnIndex) },
                    )
                }
                if (onFork != null) {
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text("Fork From Here") },
                        onClick = { showMenu = false; onFork(turnIndex) },
                    )
                }
            }
        }
    }
}

// ── Assistant Message ────────────────────────────────────────────────────────

@Composable
private fun AssistantMessageRow(
    itemId: String,
    data: uniffi.codex_mobile_client.HydratedAssistantMessageData,
    serverId: String,
    agentDirectoryVersion: ULong,
    isStreamingMessage: Boolean,
    onStreamingSnapshotRendered: (() -> Unit)?,
) {
    val appModel = LocalAppModel.current
    val renderBlocks = remember(itemId, data.text, serverId, agentDirectoryVersion, isStreamingMessage) {
        if (isStreamingMessage) {
            emptyList()
        } else {
            MessageRenderCache.getRenderBlocks(
                key = MessageRenderCache.CacheKey(
                    itemId = itemId,
                    revisionToken = data.text.hashCode(),
                    serverId = serverId,
                    agentDirectoryVersion = agentDirectoryVersion,
                ),
                parser = appModel.parser,
                text = data.text,
            )
        }
    }
    var renderedText by remember(itemId) { mutableStateOf(data.text) }
    var pendingText by remember(itemId) { mutableStateOf<String?>(null) }

    LaunchedEffect(itemId) {
        renderedText = data.text
        pendingText = null
        if (isStreamingMessage) {
            onStreamingSnapshotRendered?.invoke()
        }
    }

    LaunchedEffect(data.text, isStreamingMessage) {
        if (!isStreamingMessage) {
            renderedText = data.text
            pendingText = null
            StreamingTextCoordinator.evict(itemId)
            return@LaunchedEffect
        }
        if (data.text == renderedText) return@LaunchedEffect
        if (renderedText.isEmpty()) {
            renderedText = data.text
            onStreamingSnapshotRendered?.invoke()
        } else {
            pendingText = data.text
        }
    }

    LaunchedEffect(pendingText, isStreamingMessage) {
        val nextText = pendingText ?: return@LaunchedEffect
        if (!isStreamingMessage) return@LaunchedEffect
        delay(60)
        renderedText = nextText
        pendingText = null
        onStreamingSnapshotRendered?.invoke()
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        // Agent badge
        if (data.agentNickname != null || data.agentRole != null) {
            val label = buildString {
                data.agentNickname?.let { append(it) }
                data.agentRole?.let {
                    if (isNotEmpty()) append(" ")
                    append("[$it]")
                }
            }
            Text(
                text = label,
                color = LitterTheme.accent,
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.Medium,
            )
            Spacer(Modifier.height(2.dp))
        }

        if (isStreamingMessage) {
            StreamingMarkdownView(
                text = renderedText,
                itemId = itemId,
                onRendered = onStreamingSnapshotRendered,
            )
        } else {
            AssistantRenderBlocks(
                blocks = renderBlocks,
                fallbackText = renderedText,
            )
        }
    }
}

@Composable
private fun AssistantRenderBlocks(
    blocks: List<AppMessageRenderBlock>,
    fallbackText: String,
) {
    if (blocks.isEmpty()) {
        MarkdownText(text = fallbackText)
        return
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        blocks.forEachIndexed { index, block ->
            when (block) {
                is AppMessageRenderBlock.Markdown -> MarkdownText(text = block.markdown)
                is AppMessageRenderBlock.CodeBlock -> CodeBlockSegment(
                    language = block.language,
                    code = block.code,
                )
                is AppMessageRenderBlock.InlineImage -> {
                    val bitmap = remember(block.data) {
                        BitmapFactory.decodeByteArray(block.data, 0, block.data.size)
                    }
                    bitmap?.let {
                        Image(
                            bitmap = it.asImageBitmap(),
                            contentDescription = "Assistant image ${index + 1}",
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 300.dp)
                                .clip(RoundedCornerShape(10.dp)),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CodeReviewRow(
    data: uniffi.codex_mobile_client.HydratedCodeReviewData,
) {
    var dismissedIndices by remember(data.findings) { mutableStateOf(setOf<Int>()) }
    val visibleFindings = remember(data.findings, dismissedIndices) {
        data.findings.mapIndexedNotNull { index, finding ->
            if (dismissedIndices.contains(index)) null else index to finding
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        visibleFindings.forEach { (index, finding) ->
            CodeReviewFindingCard(
                finding = finding,
                onDismiss = { dismissedIndices = dismissedIndices + index },
            )
        }
    }
}

@Composable
private fun CodeReviewFindingCard(
    finding: uniffi.codex_mobile_client.HydratedCodeReviewFindingData,
    onDismiss: () -> Unit,
) {
    val priorityTint = when (finding.priority?.toInt()) {
        0, 1 -> LitterTheme.danger
        2 -> LitterTheme.warning
        3 -> LitterTheme.textSecondary
        else -> LitterTheme.textSecondary
    }
    val locationText = remember(finding.codeLocation) {
        val location = finding.codeLocation ?: return@remember null
        val range = location.lineRange
        when {
            range == null -> location.absoluteFilePath
            range.start == range.end -> "${location.absoluteFilePath}:${range.start}"
            else -> "${location.absoluteFilePath}:${range.start}-${range.end}"
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(22.dp))
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            finding.priority?.let { priority ->
                Text(
                    text = "P${priority.toInt()}",
                    color = priorityTint,
                    fontSize = LitterTextStyle.caption2.scaled,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier
                        .background(priorityTint.copy(alpha = 0.12f), RoundedCornerShape(999.dp))
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                )
                Spacer(Modifier.width(10.dp))
            }

            Text(
                text = finding.title,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.callout.scaled,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )

            Text(
                text = "Dismiss",
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.callout.scaled,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.clickable(onClick = onDismiss),
            )
        }

        MarkdownText(text = finding.body)

        locationText?.takeIf { it.isNotBlank() }?.let { location ->
            Text(
                text = location,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.footnote.scaled,
                fontFamily = LitterTheme.monoFont,
            )
        }
    }
}

// ── Reasoning ────────────────────────────────────────────────────────────────

@Composable
private fun ReasoningRow(
    data: uniffi.codex_mobile_client.HydratedReasoningData,
) {
    val reasoningText = remember(data.summary, data.content) {
        (data.summary + data.content)
            .filter { it.isNotBlank() }
            .joinToString(separator = "\n\n")
    }

    if (reasoningText.isBlank()) return

    Text(
        text = reasoningText,
        color = LitterTheme.textSecondary,
        fontSize = LitterTextStyle.body.scaled,
        fontFamily = LitterTheme.monoFont,
        fontStyle = FontStyle.Italic,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    )
}

// ── Command Execution ────────────────────────────────────────────────────────

@Composable
private fun CommandExecutionRow(
    data: uniffi.codex_mobile_client.HydratedCommandExecutionData,
    keepExpanded: Boolean,
) {
    var expanded by remember(data.command) { mutableStateOf(keepExpanded) }
    val outputScrollState = rememberScrollState()
    val outputText =
        data.output
            ?.trim('\n')
            ?.takeIf { it.isNotBlank() }
            ?: if (data.status == AppOperationStatus.PENDING || data.status == AppOperationStatus.IN_PROGRESS) {
                "Waiting for output…"
            } else {
                "No output"
            }
    val displayedCommand = remember(data.command) { displayCommandText(data.command) }
    val collapsedCommand = remember(data.command) { collapseCommandText(data.command) }

    LaunchedEffect(keepExpanded) {
        expanded = keepExpanded
    }

    LaunchedEffect(outputText, outputScrollState.maxValue, expanded) {
        if (!expanded) return@LaunchedEffect
        if (outputScrollState.maxValue <= 0) return@LaunchedEffect
        outputScrollState.animateScrollTo(outputScrollState.maxValue)
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 1.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "$",
                color = LitterTheme.warning,
                fontFamily = LitterTheme.monoFont,
                fontSize = LitterTextStyle.caption.scaled,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = if (expanded) displayedCommand else collapsedCommand,
                color = LitterTheme.textSystem,
                fontFamily = LitterTheme.monoFont,
                fontSize = LitterTextStyle.body.scaled,
                maxLines = if (expanded) Int.MAX_VALUE else 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            data.durationMs?.takeIf { it > 0 }?.let { ms ->
                Spacer(Modifier.width(6.dp))
                Text(
                    text = formatDuration(ms),
                    color = statusTint(data.status),
                    fontSize = LitterTextStyle.caption2.scaled,
                )
            }
            Spacer(Modifier.width(8.dp))
            Text(
                text = if (expanded) "▲" else "▼",
                color = LitterTheme.warning,
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.Bold,
            )
        }

        if (expanded) {
            Spacer(Modifier.height(6.dp))
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 56.dp, max = 116.dp)
                    .background(LitterTheme.codeBackground, RoundedCornerShape(10.dp))
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            ) {
                Text(
                    text = outputText,
                    color = LitterTheme.textSecondary,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = LitterTextStyle.body.scaled,
                    modifier = Modifier
                        .fillMaxWidth()
                        .verticalScroll(outputScrollState),
                )
            }
        }
    }
}

// ── File Change ──────────────────────────────────────────────────────────────

@Composable
private fun FileChangeRow(
    data: uniffi.codex_mobile_client.HydratedFileChangeData,
) {
    val summary = remember(data.changes) {
        buildFileChangeSummary(data)
    }
    val diffChanges = remember(data.changes) {
        data.changes.filter { it.diff.isNotBlank() }
    }

    ToolCardShell(
        summary = summary.plainText,
        summaryAnnotated = summary.annotatedText,
        accent = LitterTheme.toolCallFileChange,
        status = data.status,
    ) {
        if (diffChanges.isEmpty() && data.changes.isNotEmpty()) {
            ListSection("Files", data.changes.map { workspaceTitle(it.path) })
        }
        diffChanges.forEach { change ->
            DiffSection(
                label = if (diffChanges.size > 1) workspaceTitle(change.path) else "",
                content = change.diff,
            )
        }
    }
}

private data class FileChangeSummary(
    val plainText: String,
    val annotatedText: AnnotatedString,
)

private fun buildFileChangeSummary(
    data: uniffi.codex_mobile_client.HydratedFileChangeData,
): FileChangeSummary {
    if (data.changes.isEmpty()) {
        return FileChangeSummary(
            plainText = "File changes",
            annotatedText = AnnotatedString("File changes"),
        )
    }

    val additions = data.changes.sumOf { it.additions.toInt() }
    val deletions = data.changes.sumOf { it.deletions.toInt() }
    val hasCountSummary = additions > 0 || deletions > 0

    if (data.changes.size == 1) {
        val change = data.changes.first()
        val verb = fileChangeVerb(change.kind)
        val filename = workspaceTitle(change.path)
        if (!hasCountSummary) {
            return FileChangeSummary(
                plainText = "$verb $filename",
                annotatedText = AnnotatedString("$verb $filename"),
            )
        }
        val plainText = "$verb $filename +$additions -$deletions"
        val annotatedText = buildAnnotatedString {
            withStyle(SpanStyle(color = LitterTheme.textSecondary)) {
                append("$verb ")
            }
            withStyle(SpanStyle(color = LitterTheme.accent)) {
                append(filename)
            }
            withStyle(SpanStyle(color = LitterTheme.success)) {
                append(" +$additions")
            }
            withStyle(SpanStyle(color = LitterTheme.danger)) {
                append(" -$deletions")
            }
        }
        return FileChangeSummary(plainText = plainText, annotatedText = annotatedText)
    }

    if (!hasCountSummary) {
        return FileChangeSummary(
            plainText = "Changed ${data.changes.size} files",
            annotatedText = AnnotatedString("Changed ${data.changes.size} files"),
        )
    }

    val plainText = "Changed ${data.changes.size} files +$additions -$deletions"
    val annotatedText = buildAnnotatedString {
        append("Changed ${data.changes.size} files")
        withStyle(SpanStyle(color = LitterTheme.success)) {
            append(" +$additions")
        }
        withStyle(SpanStyle(color = LitterTheme.danger)) {
            append(" -$deletions")
        }
    }
    return FileChangeSummary(plainText = plainText, annotatedText = annotatedText)
}

private fun fileChangeVerb(kind: String): String = when (kind.lowercase()) {
    "add" -> "Added"
    "delete" -> "Deleted"
    "update" -> "Edited"
    else -> "Changed"
}

// ── Todo List ────────────────────────────────────────────────────────────────

@Composable
private fun TodoListRow(
    data: uniffi.codex_mobile_client.HydratedTodoListData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
    ) {
        for (step in data.steps) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(vertical = 1.dp),
            ) {
                val icon = when (step.status) {
                    HydratedPlanStepStatus.COMPLETED -> "✓"
                    HydratedPlanStepStatus.IN_PROGRESS -> "●"
                    HydratedPlanStepStatus.PENDING -> "○"
                }
                val color = when (step.status) {
                    HydratedPlanStepStatus.COMPLETED -> LitterTheme.success
                    HydratedPlanStepStatus.IN_PROGRESS -> LitterTheme.accent
                    HydratedPlanStepStatus.PENDING -> LitterTheme.textMuted
                }
                Text(text = icon, color = color, fontSize = LitterTextStyle.footnote.scaled)
                Spacer(Modifier.width(6.dp))
                Text(
                    text = step.step,
                    color = LitterTheme.textBody,
                    fontSize = LitterTextStyle.body.scaled,
                )
            }
        }
    }
}

// ── Proposed Plan ────────────────────────────────────────────────────────────

@Composable
private fun ProposedPlanRow(
    data: uniffi.codex_mobile_client.HydratedProposedPlanData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
    ) {
        Text(
            text = "Plan",
            color = LitterTheme.accent,
            fontSize = LitterTextStyle.caption.scaled,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        MarkdownText(text = data.content)
    }
}

// ── MCP Tool Call ────────────────────────────────────────────────────────────

@Composable
private fun McpToolCallRow(
    data: uniffi.codex_mobile_client.HydratedMcpToolCallData,
) {
    val summary = if (data.server.isBlank()) data.tool else "${data.server}.${data.tool}"
    ToolCardShell(
        summary = summary,
        accent = LitterTheme.toolCallMcpCall,
        status = data.status,
        durationMs = data.durationMs,
    ) {
        data.argumentsJson?.takeIf { it.isNotBlank() }?.let { CodeSection("Arguments", it) }
        data.contentSummary?.takeIf { it.isNotBlank() }?.let { InlineTextSection("Result", it) }
        data.structuredContentJson?.takeIf { it.isNotBlank() }?.let { CodeSection("Structured", it) }
        data.rawOutputJson?.takeIf { it.isNotBlank() }?.let { CodeSection("Raw Output", it) }
        if (data.progressMessages.isNotEmpty()) {
            ProgressSection("Progress", data.progressMessages)
        }
        data.errorMessage?.takeIf { it.isNotBlank() }?.let { InlineTextSection("Error", it, tone = LitterTheme.danger) }
    }
}

// ── Computer Use Tool Call (computer-use MCP) ───────────────────────────────

@Composable
private fun ComputerUseToolCallRow(
    data: uniffi.codex_mobile_client.HydratedMcpToolCallData,
    view: uniffi.codex_mobile_client.ComputerUseView,
) {
    ToolCardShell(
        summary = view.summary,
        accent = LitterTheme.toolCallMcpCall,
        status = data.status,
        durationMs = data.durationMs,
    ) {
        view.screenshotPng?.let { bytes ->
            ScreenshotPreview(bytes)
        }
        data.errorMessage?.takeIf { it.isNotBlank() }?.let {
            InlineTextSection("Error", it, tone = LitterTheme.danger)
        }
        view.accessibilityText?.takeIf { it.isNotBlank() }?.let {
            AccessibilityTreeSection(it)
        }
    }
}

@Composable
private fun ScreenshotPreview(bytes: ByteArray) {
    val bitmap = remember(bytes) {
        try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
        } catch (_: Throwable) {
            null
        }
    }
    if (bitmap == null) {
        InlineTextSection("Screenshot", "Unavailable", tone = LitterTheme.textMuted)
        return
    }
    Column {
        Text(
            text = "SCREENSHOT",
            color = LitterTheme.textSecondary,
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(4.dp))
        Image(
            bitmap = bitmap,
            contentDescription = "Computer Use screenshot",
            contentScale = ContentScale.Fit,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(LitterTheme.codeBackground),
        )
    }
}

@Composable
private fun AccessibilityTreeSection(text: String) {
    var expanded by remember(text) { mutableStateOf(false) }
    val lines = remember(text) { text.split('\n') }
    val previewLineCount = 6
    val display = if (expanded || lines.size <= previewLineCount) {
        text
    } else {
        lines.take(previewLineCount).joinToString("\n") + "\n… (${lines.size - previewLineCount} more lines)"
    }

    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "ACCESSIBILITY TREE",
                color = LitterTheme.textSecondary,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f),
            )
            if (lines.size > previewLineCount) {
                Text(
                    text = if (expanded) "Collapse" else "Expand",
                    color = LitterTheme.accent,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.clickable { expanded = !expanded },
                )
            }
        }
        Spacer(Modifier.height(4.dp))
        Text(
            text = display,
            color = LitterTheme.textSecondary,
            fontSize = 11.sp,
            fontFamily = BerkeleyMono,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(LitterTheme.codeBackground)
                .padding(10.dp),
        )
    }
}

// ── Dynamic Tool Call ────────────────────────────────────────────────────────

@Composable
private fun DynamicToolCallRow(
    data: uniffi.codex_mobile_client.HydratedDynamicToolCallData,
) {
    val richPayload = remember(data.tool, data.contentSummary) {
        decodeRichDynamicToolPayload(data.tool, data.contentSummary)
    }
    if (richPayload != null) {
        RichDynamicToolResult(payload = richPayload)
        return
    }

    ToolCardShell(
        summary = data.tool,
        accent = LitterTheme.toolCallMcpCall,
        status = data.status,
        durationMs = data.durationMs,
    ) {
        data.success?.let { success ->
            KeyValueSection(
                label = "Metadata",
                entries = listOf("Success" to success.toString()),
            )
        }
        data.argumentsJson?.takeIf { it.isNotBlank() }?.let { CodeSection("Arguments", it) }
        data.contentSummary?.takeIf { it.isNotBlank() }?.let { InlineTextSection("Result", it) }
    }
}

// ── Web Search ───────────────────────────────────────────────────────────────

@Composable
private fun WebSearchRow(
    data: uniffi.codex_mobile_client.HydratedWebSearchData,
) {
    ToolCardShell(
        summary = if (data.query.isBlank()) "Web search" else "Web search for ${data.query}",
        accent = LitterTheme.toolCallWebSearch,
        status = if (data.isInProgress) AppOperationStatus.IN_PROGRESS else AppOperationStatus.COMPLETED,
    ) {
        if (data.query.isNotBlank()) {
            InlineTextSection("Query", data.query)
        }
        data.actionJson?.takeIf { it.isNotBlank() }?.let { CodeSection("Action", it) }
    }
}

@Composable
private fun ImageViewRow(
    data: uniffi.codex_mobile_client.HydratedImageViewData,
    serverId: String,
) {
    ToolCardShell(
        summary = workspaceTitle(data.path),
        accent = LitterTheme.warning,
        status = AppOperationStatus.COMPLETED,
        defaultExpanded = true,
    ) {
        ImageResultSection(path = data.path, serverId = serverId)
        KeyValueSection("Metadata", listOf("Path" to data.path))
    }
}

@Composable
private fun ImageGenerationRow(
    data: uniffi.codex_mobile_client.HydratedImageGenerationData,
) {
    val summary = when (data.status) {
        AppOperationStatus.COMPLETED -> "Generated image"
        AppOperationStatus.FAILED -> "Image generation failed"
        else -> "Generating image…"
    }
    ToolCardShell(
        summary = summary,
        accent = LitterTheme.accent,
        status = data.status,
        defaultExpanded = true,
    ) {
        GeneratedImageSection(data = data)
        data.revisedPrompt?.takeIf { it.isNotBlank() }?.let { prompt ->
            RevisedPromptSection(prompt)
        }
        data.savedPath?.takeIf { it.isNotBlank() }?.let { path ->
            KeyValueSection("Metadata", listOf("Saved to" to path))
        }
    }
}

@Composable
private fun GeneratedImageSection(
    data: uniffi.codex_mobile_client.HydratedImageGenerationData,
) {
    val bitmap = remember(data.imagePng) {
        val bytes = data.imagePng ?: return@remember null
        try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
        } catch (_: Throwable) {
            null
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel("Image")
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(10.dp))
                .padding(horizontal = 10.dp, vertical = 8.dp),
            contentAlignment = Alignment.Center,
        ) {
            when {
                bitmap != null -> {
                    Image(
                        bitmap = bitmap,
                        contentDescription = "Generated image",
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 360.dp)
                            .clip(RoundedCornerShape(8.dp)),
                    )
                }
                data.status == AppOperationStatus.IN_PROGRESS ||
                    data.status == AppOperationStatus.PENDING -> {
                    CircularProgressIndicator(
                        color = LitterTheme.accent,
                        strokeWidth = 2.dp,
                        modifier = Modifier.padding(vertical = 24.dp),
                    )
                }
                else -> {
                    Text(
                        text = "Image unavailable",
                        color = LitterTheme.textMuted,
                        fontSize = LitterTextStyle.caption.scaled,
                        modifier = Modifier.padding(vertical = 20.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun RevisedPromptSection(prompt: String) {
    var expanded by remember(prompt) { mutableStateOf(false) }
    val isLong = prompt.length > 220 || prompt.count { it == '\n' } >= 4
    val display = if (expanded || !isLong) prompt else prompt.take(220).trimEnd() + "…"

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionLabel("Revised Prompt")
            Spacer(Modifier.weight(1f))
            if (isLong) {
                Text(
                    text = if (expanded) "Collapse" else "Expand",
                    color = LitterTheme.accent,
                    fontSize = LitterTextStyle.caption2.scaled,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.clickable { expanded = !expanded },
                )
            }
        }
        Text(
            text = display,
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.body.scaled,
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp))
                .padding(10.dp),
        )
    }
}

private sealed interface ToolImageLoadState {
    data object Loading : ToolImageLoadState
    data class Loaded(val bitmap: android.graphics.Bitmap) : ToolImageLoadState
    data class Failed(val message: String) : ToolImageLoadState
}

@Composable
private fun ImageResultSection(
    path: String,
    serverId: String,
) {
    val appModel = LocalAppModel.current
    val loadState by produceState<ToolImageLoadState>(
        initialValue = ToolImageLoadState.Loading,
        path,
        serverId,
    ) {
        value = ToolImageLoadState.Loading
        value = loadToolImage(appModel, path, serverId)
    }

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel("Image")
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(10.dp))
                .padding(horizontal = 10.dp, vertical = 8.dp),
            contentAlignment = Alignment.Center,
        ) {
            when (val state = loadState) {
                ToolImageLoadState.Loading -> {
                    CircularProgressIndicator(
                        color = LitterTheme.accent,
                        strokeWidth = 2.dp,
                        modifier = Modifier.padding(vertical = 24.dp),
                    )
                }

                is ToolImageLoadState.Loaded -> {
                    Image(
                        bitmap = state.bitmap.asImageBitmap(),
                        contentDescription = workspaceTitle(path),
                        contentScale = ContentScale.Fit,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 320.dp)
                            .clip(RoundedCornerShape(8.dp)),
                    )
                }

                is ToolImageLoadState.Failed -> {
                    Text(
                        text = state.message,
                        color = LitterTheme.danger,
                        fontSize = LitterTextStyle.caption.scaled,
                        modifier = Modifier.padding(vertical = 20.dp),
                    )
                }
            }
        }
    }
}

private suspend fun loadToolImage(
    appModel: AppModel,
    path: String,
    serverId: String,
): ToolImageLoadState {
    return try {
        val resolved = withContext(Dispatchers.IO) {
            appModel.client.resolveImageView(serverId, path)
        }
        val bitmap = BitmapFactory.decodeByteArray(resolved.bytes, 0, resolved.bytes.size)
        if (bitmap != null) {
            ToolImageLoadState.Loaded(bitmap)
        } else {
            ToolImageLoadState.Failed("Could not decode the image.")
        }
    } catch (error: Exception) {
        val message = error.message?.trim().orEmpty()
        ToolImageLoadState.Failed(
            if (message.isNotEmpty()) message else "Image unavailable",
        )
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun WidgetRow(
    data: uniffi.codex_mobile_client.HydratedWidgetData,
) {
    val document = remember(data.widgetHtml) { wrapWidgetHtml(data.widgetHtml) }
    val widgetHeight = remember(data.height) {
        data.height.coerceIn(200.0, 720.0).roundToInt().dp
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(12.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = data.title.ifBlank { "Widget" },
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.footnote.scaled,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = data.status,
                color = statusTint(
                    when (data.status.lowercase()) {
                        "completed" -> AppOperationStatus.COMPLETED
                        "failed" -> AppOperationStatus.FAILED
                        else -> AppOperationStatus.IN_PROGRESS
                    }
                ),
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.Medium,
            )
        }

        AndroidView(
            factory = { ctx ->
                WebView(ctx).apply {
                    setBackgroundColor(android.graphics.Color.TRANSPARENT)
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    settings.loadsImagesAutomatically = true
                    overScrollMode = WebView.OVER_SCROLL_NEVER
                    webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(
                            view: WebView?,
                            request: WebResourceRequest?,
                        ): Boolean {
                            val url = request?.url?.toString().orEmpty()
                            if (url.isBlank() || url.startsWith("about:")) {
                                return false
                            }
                            return try {
                                ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                                true
                            } catch (_: Exception) {
                                false
                            }
                        }
                    }
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .height(widgetHeight)
                .clip(RoundedCornerShape(10.dp)),
            update = { webView ->
                val previous = webView.getTag(R.id.widget_webview_document) as? String
                if (previous != document) {
                    webView.setTag(R.id.widget_webview_document, document)
                    webView.loadDataWithBaseURL(
                        "https://widget.local/",
                        document,
                        "text/html",
                        "utf-8",
                        null,
                    )
                }
            },
        )
    }
}

@Composable
private fun UserInputResponseRow(
    data: uniffi.codex_mobile_client.HydratedUserInputResponseData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(12.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = "Requested Input",
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.body.scaled,
            fontWeight = FontWeight.SemiBold,
        )

        data.questions.forEach { question ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                question.header?.takeIf { it.isNotBlank() }?.let { header ->
                    Text(
                        text = header.uppercase(),
                        color = LitterTheme.textMuted,
                        fontSize = LitterTextStyle.caption2.scaled,
                        fontWeight = FontWeight.Bold,
                    )
                }
                Text(
                    text = question.question,
                    color = LitterTheme.textPrimary,
                    fontSize = LitterTextStyle.body.scaled,
                    fontWeight = FontWeight.Medium,
                )
                Text(
                    text = question.answer.ifBlank { "No answer provided" },
                    color = LitterTheme.textSecondary,
                    fontSize = LitterTextStyle.body.scaled,
                )
            }
        }
    }
}

// ── Divider ──────────────────────────────────────────────────────────────────

@Composable
private fun TurnDiffRow(
    data: uniffi.codex_mobile_client.HydratedTurnDiffData,
) {
    ToolCardShell(
        summary = "Turn Diff",
        accent = LitterTheme.toolCallFileChange,
        status = AppOperationStatus.COMPLETED,
    ) {
        DiffSection(label = "Diff", content = data.diff)
    }
}

@Composable
private fun DividerRow(
    data: uniffi.codex_mobile_client.HydratedDividerData,
    isLiveTurn: Boolean,
) {
    val label = when (data) {
        is uniffi.codex_mobile_client.HydratedDividerData.ContextCompaction ->
            if (data.isComplete && !isLiveTurn) "Context compacted" else "Compacting context\u2026"
        is uniffi.codex_mobile_client.HydratedDividerData.ModelRerouted -> {
            val route = data.fromModel?.takeIf { it.isNotBlank() }?.let { "$it -> ${data.toModel}" }
                ?: "Routed to ${data.toModel}"
            val reason = data.reason?.takeIf { it.isNotBlank() }
            if (reason != null) "$route | $reason" else route
        }
        is uniffi.codex_mobile_client.HydratedDividerData.ReviewEntered -> "Review started"
        is uniffi.codex_mobile_client.HydratedDividerData.ReviewExited -> "Review ended"
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HorizontalDivider(
            modifier = Modifier.weight(1f),
            color = LitterTheme.divider,
        )
        Text(
            text = "  $label  ",
            color = LitterTheme.textMuted,
            fontSize = LitterTextStyle.caption2.scaled,
        )
        HorizontalDivider(
            modifier = Modifier.weight(1f),
            color = LitterTheme.divider,
        )
    }
}

// ── Note ─────────────────────────────────────────────────────────────────────

@Composable
private fun NoteRow(
    data: uniffi.codex_mobile_client.HydratedNoteData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .padding(8.dp),
    ) {
        Text(
            text = data.title,
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.body.scaled,
            fontWeight = FontWeight.Medium,
        )
        if (data.body.isNotBlank()) {
            Text(
                text = data.body,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.body.scaled,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

@Composable
private fun ErrorRow(
    data: uniffi.codex_mobile_client.HydratedErrorData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
            .padding(8.dp),
    ) {
        Text(
            text = data.title.ifBlank { "Error" },
            color = LitterTheme.danger,
            fontSize = LitterTextStyle.body.scaled,
            fontWeight = FontWeight.Medium,
        )
        Text(
            text = data.message,
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.body.scaled,
            modifier = Modifier.padding(top = 2.dp),
        )
        data.details?.takeIf { it.isNotBlank() }?.let { details ->
            Text(
                text = details,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.body.scaled,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

// ── Markdown Rendering ───────────────────────────────────────────────────

@Composable
private fun MarkdownText(
    text: String,
    modifier: Modifier = Modifier,
) {
    if (com.litter.android.state.DebugSettings.enabled && com.litter.android.state.DebugSettings.disableMarkdown) {
        Text(
            text = text,
            color = LitterTheme.textBody,
            fontFamily = FontFamily.Monospace,
            fontSize = LitterTextStyle.body.scaled,
            modifier = modifier.fillMaxWidth(),
        )
        return
    }

    val context = LocalContext.current
    val textScale = LocalTextScale.current
    val markwon = remember(context) {
        try {
            val prism4j = Prism4j(com.litter.android.ui.Prism4jGrammarLocator())
            Markwon.builder(context)
                .usePlugin(SyntaxHighlightPlugin.create(prism4j, io.noties.markwon.syntax.Prism4jThemeDarkula.create()))
                .build()
        } catch (_: Exception) {
            Markwon.create(context)
        }
    }

    AndroidView(
        factory = { ctx ->
            TextView(ctx).apply {
                setTextColor(LitterTheme.textBody.toArgb())
                textSize = LitterTextStyle.body * textScale
                movementMethod = LinkMovementMethod.getInstance()
                setLinkTextColor(LitterTheme.accent.toArgb())
            }
        },
        update = { tv ->
            tv.setTextColor(LitterTheme.textBody.toArgb())
            tv.textSize = LitterTextStyle.body * textScale
            markwon.setMarkdown(tv, text)
        },
        modifier = modifier.fillMaxWidth(),
    )
}

private fun wrapWidgetHtml(widgetHtml: String): String {
    val body = widgetHtml.trim()
    return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              background: #000000;
              color: #F3F3F3;
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            }
            #widget-root {
              width: 100%;
              min-height: 100%;
            }
            svg {
              display: block;
              max-width: 100%;
              height: auto;
            }
          </style>
        </head>
        <body>
          <div id="widget-root">$body</div>
        </body>
        </html>
    """.trimIndent()
}

private fun workspaceTitle(path: String): String {
    return path
        .trimEnd('/')
        .substringAfterLast('/')
        .ifBlank { path }
}

@Composable
private fun CodeBlockSegment(
    language: String?,
    code: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        language?.takeIf { it.isNotBlank() }?.let {
            Text(
                text = it.uppercase(),
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.Bold,
            )
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp))
                .padding(10.dp),
        ) {
            Text(
                text = code,
                color = LitterTheme.textBody,
                fontFamily = LitterTheme.monoFont,
                fontSize = LitterTextStyle.body.scaled,
                modifier = Modifier.horizontalScroll(rememberScrollState()),
            )
        }
    }
}

@Composable
private fun ToolCardShell(
    summary: String,
    summaryAnnotated: AnnotatedString? = null,
    accent: Color,
    status: AppOperationStatus,
    durationMs: Long? = null,
    defaultExpanded: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    var expanded by remember(summary, status) {
        mutableStateOf(defaultExpanded || status == AppOperationStatus.FAILED)
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(10.dp))
            .clickable { expanded = !expanded }
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusIcon(status)
            Spacer(Modifier.width(8.dp))
            Text(
                text = summaryAnnotated ?: AnnotatedString(summary),
                color = LitterTheme.textSystem,
                fontSize = LitterTextStyle.body.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            durationMs?.takeIf { it > 0 }?.let { ms ->
                Spacer(Modifier.width(8.dp))
                Text(
                    text = formatDuration(ms),
                    color = statusTint(status),
                    fontSize = LitterTextStyle.caption2.scaled,
                )
            }
            Spacer(Modifier.width(8.dp))
            Text(
                text = if (expanded) "▲" else "▼",
                color = accent,
                fontSize = LitterTextStyle.caption2.scaled,
                fontWeight = FontWeight.Bold,
            )
        }

        if (expanded) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 6.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
                content = content,
            )
        }
    }
}

private fun displayCommandText(command: String): String {
    val trimmed = command.trim()
    return if (trimmed.isEmpty()) "command" else trimmed
}

private fun collapseCommandText(command: String): String {
    val collapsed = displayCommandText(command)
        .replace(Regex("\\s+"), " ")
        .trim()
    return if (collapsed.isEmpty()) "command" else collapsed
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        color = LitterTheme.textSecondary,
        fontSize = LitterTextStyle.caption2.scaled,
        fontWeight = FontWeight.Bold,
    )
}

@Composable
private fun CodeSection(
    label: String,
    content: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel(label)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp))
                .padding(10.dp),
        ) {
            Text(
                text = content,
                color = LitterTheme.textBody,
                fontFamily = LitterTheme.monoFont,
                fontSize = LitterTextStyle.body.scaled,
                modifier = Modifier.horizontalScroll(rememberScrollState()),
            )
        }
    }
}

@Composable
private fun InlineTextSection(
    label: String,
    content: String,
    tone: Color = LitterTheme.textBody,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel(label)
        Text(
            text = content,
            color = tone,
            fontFamily = LitterTheme.monoFont,
            fontSize = LitterTextStyle.body.scaled,
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp))
                .padding(horizontal = 10.dp, vertical = 8.dp),
        )
    }
}

@Composable
private fun KeyValueSection(
    label: String,
    entries: List<Pair<String, String>>,
) {
    if (entries.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel(label)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(8.dp))
                .padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            entries.forEach { (key, value) ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "$key:",
                        color = LitterTheme.textSecondary,
                        fontSize = LitterTextStyle.body.scaled,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = value,
                        color = LitterTheme.textSystem,
                        fontSize = LitterTextStyle.body.scaled,
                    )
                }
            }
        }
    }
}

@Composable
private fun ListSection(
    label: String,
    items: List<String>,
) {
    if (items.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel(label)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(8.dp))
                .padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            items.forEach { item ->
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("•", color = LitterTheme.textSecondary, fontSize = LitterTextStyle.body.scaled)
                    Text(
                        text = item,
                        color = LitterTheme.textSystem,
                        fontSize = LitterTextStyle.body.scaled,
                    )
                }
            }
        }
    }
}

@Composable
private fun ProgressSection(
    label: String,
    items: List<String>,
) {
    if (items.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel(label)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(8.dp))
                .padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            items.forEachIndexed { index, item ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "•",
                        color = if (index == items.lastIndex) LitterTheme.accentStrong else LitterTheme.textMuted,
                        fontSize = LitterTextStyle.body.scaled,
                    )
                    Text(
                        text = item,
                        color = LitterTheme.textSystem,
                        fontSize = LitterTextStyle.body.scaled,
                    )
                }
            }
        }
    }
}

@Composable
private fun DiffSection(
    label: String,
    content: String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (label.isNotEmpty()) {
            SectionLabel(label)
        }
        SyntaxHighlightedDiffBlock(
            diff = content,
            titleHint = label.ifEmpty { null },
            fontSize = 12.sp,
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp))
                .padding(horizontal = 10.dp, vertical = 6.dp),
        )
    }
}

@Composable
private fun RichDynamicToolResult(
    payload: RichDynamicToolPayload,
) {
    when (payload) {
        is RichDynamicToolPayload.Servers -> {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                payload.items.forEach { item ->
                    SessionServerCard(
                        icon = {
                            Icon(
                                if (item.isLocal) Icons.Default.PhoneAndroid else Icons.Default.Dns,
                                contentDescription = null,
                                tint = LitterTheme.accent,
                                modifier = Modifier.size(18.dp),
                            )
                        },
                        title = item.name,
                        subtitle = item.hostname,
                        trailing = if (item.isConnected) "Connected" else "Offline",
                        statusDotColor = if (item.isConnected) LitterTheme.success else LitterTheme.textMuted,
                    )
                }
            }
        }
        is RichDynamicToolPayload.Sessions -> {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                payload.items.forEach { item ->
                    val subtitle = listOfNotNull(
                        item.serverName?.takeIf { it.isNotBlank() },
                        item.model?.takeIf { it.isNotBlank() },
                    ).joinToString(" \u00b7 ")
                    SessionServerCard(
                        icon = {
                            Icon(
                                Icons.Default.Chat,
                                contentDescription = null,
                                tint = LitterTheme.accent,
                                modifier = Modifier.size(18.dp),
                            )
                        },
                        title = item.title.ifBlank { "Untitled session" },
                        subtitle = subtitle,
                        trailing = null,
                        statusDotColor = null,
                    )
                }
            }
        }
    }
}

@Composable
private fun SessionServerCard(
    icon: @Composable () -> Unit,
    title: String,
    subtitle: String,
    trailing: String?,
    statusDotColor: Color?,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(14.dp))
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(32.dp)
                .background(LitterTheme.accent.copy(alpha = 0.12f), RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            icon()
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.subheadline.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (subtitle.isNotBlank()) {
                Text(
                    text = subtitle,
                    color = LitterTheme.textMuted,
                    fontSize = LitterTextStyle.caption.scaled,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (statusDotColor != null || trailing != null) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                statusDotColor?.let { dotColor ->
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(dotColor),
                    )
                }
                trailing?.let {
                    Text(
                        text = it,
                        color = LitterTheme.textMuted,
                        fontSize = LitterTextStyle.caption.scaled,
                    )
                }
            }
        }
    }
}

private sealed class RichDynamicToolPayload {
    data class Servers(val items: List<ServerItem>) : RichDynamicToolPayload()
    data class Sessions(val items: List<SessionItem>) : RichDynamicToolPayload()
}

private data class ServerItem(
    val name: String,
    val hostname: String,
    val isConnected: Boolean,
    val isLocal: Boolean,
)

private data class SessionItem(
    val title: String,
    val serverName: String?,
    val model: String?,
)

private fun decodeRichDynamicToolPayload(
    tool: String,
    contentSummary: String?,
): RichDynamicToolPayload? {
    if (contentSummary.isNullOrBlank()) return null
    if (tool != "list_servers" && tool != "list_sessions") return null
    return try {
        val root = JSONObject(contentSummary)
        when (root.optString("type")) {
            "servers" -> {
                val items = root.optJSONArray("items") ?: JSONArray()
                RichDynamicToolPayload.Servers(
                    List(items.length()) { index ->
                        val item = items.optJSONObject(index) ?: JSONObject()
                        ServerItem(
                            name = item.optString("name"),
                            hostname = item.optString("hostname"),
                            isConnected = item.optBoolean("isConnected"),
                            isLocal = item.optBoolean("isLocal"),
                        )
                    },
                )
            }
            "sessions" -> {
                val items = root.optJSONArray("items") ?: JSONArray()
                RichDynamicToolPayload.Sessions(
                    List(items.length()) { index ->
                        val item = items.optJSONObject(index) ?: JSONObject()
                        SessionItem(
                            title = item.optString("preview"),
                            serverName = item.optString("serverName").takeIf { it.isNotBlank() },
                            model = item.optString("modelProvider").ifBlank {
                                item.optString("model_provider")
                            }.takeIf { it.isNotBlank() },
                        )
                    },
                )
            }
            else -> null
        }
    } catch (_: Exception) {
        null
    }
}

// ── Shared Helpers ───────────────────────────────────────────────────────────

@Composable
internal fun StatusIcon(status: AppOperationStatus) {
    when (status) {
        AppOperationStatus.IN_PROGRESS -> {
            CircularProgressIndicator(
                modifier = Modifier.size(14.dp),
                strokeWidth = 2.dp,
                color = LitterTheme.accent,
            )
        }
        AppOperationStatus.COMPLETED -> {
            Icon(
                Icons.Default.CheckCircle,
                contentDescription = "Completed",
                tint = LitterTheme.success,
                modifier = Modifier.size(14.dp),
            )
        }
        AppOperationStatus.FAILED -> {
            Icon(
                Icons.Default.Error,
                contentDescription = "Failed",
                tint = LitterTheme.danger,
                modifier = Modifier.size(14.dp),
            )
        }
        else -> {
            Icon(
                Icons.Default.HourglassEmpty,
                contentDescription = "Unknown",
                tint = LitterTheme.textMuted,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

private fun statusTint(status: AppOperationStatus): Color {
    return when (status) {
        AppOperationStatus.COMPLETED -> LitterTheme.success
        AppOperationStatus.IN_PROGRESS -> LitterTheme.warning
        AppOperationStatus.FAILED -> LitterTheme.danger
        else -> LitterTheme.textMuted
    }
}

private fun formatDuration(ms: Long): String {
    return when {
        ms < 1000 -> "${ms}ms"
        ms < 60_000 -> "%.1fs".format(ms / 1000.0)
        else -> "${ms / 60_000}m ${(ms % 60_000) / 1000}s"
    }
}
