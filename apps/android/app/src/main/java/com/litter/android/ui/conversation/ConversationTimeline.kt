package com.litter.android.ui.conversation

import android.annotation.SuppressLint
import android.content.Intent
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
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.BerkeleyMono
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalTextScale
import com.litter.android.ui.scaled
import io.noties.markwon.Markwon
import io.noties.markwon.syntax.SyntaxHighlightPlugin
import io.noties.prism4j.Prism4j
import org.json.JSONArray
import org.json.JSONObject
import uniffi.codex_mobile_client.AppOperationStatus
import uniffi.codex_mobile_client.FfiMessageSegment
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.HydratedPlanStepStatus
import kotlin.math.roundToInt

/**
 * Renders a single [HydratedConversationItem] by matching on its content type.
 * Uses Rust-provided types directly — no intermediate model conversion.
 */
@Composable
fun ConversationTimelineItem(
    item: HydratedConversationItem,
    serverId: String,
    agentDirectoryVersion: ULong,
    isLiveTurn: Boolean = false,
    onEditMessage: ((UInt) -> Unit)? = null,
    onForkFromMessage: ((UInt) -> Unit)? = null,
) {
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
        )

        is HydratedConversationItemContent.Reasoning -> ReasoningRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.CommandExecution -> CommandExecutionRow(
            data = content.v1,
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

        is HydratedConversationItemContent.McpToolCall -> McpToolCallRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.DynamicToolCall -> DynamicToolCallRow(
            data = content.v1,
        )

        is HydratedConversationItemContent.MultiAgentAction -> {
            SubagentCard(data = content.v1, serverId = serverId)
        }

        is HydratedConversationItemContent.WebSearch -> WebSearchRow(
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

    Box {
        Column(
            modifier = Modifier
                .fillMaxWidth()
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
            Text(
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

// ── Assistant Message ────────────────────────────────────────────────────────

@Composable
private fun AssistantMessageRow(
    itemId: String,
    data: uniffi.codex_mobile_client.HydratedAssistantMessageData,
    serverId: String,
    agentDirectoryVersion: ULong,
) {
    val appModel = LocalAppModel.current
    val segments = remember(itemId, data.text, serverId, agentDirectoryVersion) {
        MessageRenderCache.getSegments(
            key = MessageRenderCache.CacheKey(
                itemId = itemId,
                serverId = serverId,
                agentDirectoryVersion = agentDirectoryVersion,
            ),
            parser = appModel.parser,
            text = data.text,
        )
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

        if (segments.isEmpty()) {
            MarkdownText(text = data.text)
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                segments.forEachIndexed { index, segment ->
                    when (segment) {
                        is FfiMessageSegment.Text -> MarkdownText(text = segment.text)
                        is FfiMessageSegment.CodeBlock -> CodeBlockSegment(
                            language = segment.language,
                            code = segment.code,
                        )
                        is FfiMessageSegment.InlineImage -> {
                            val bitmap = remember(segment.data) {
                                BitmapFactory.decodeByteArray(segment.data, 0, segment.data.size)
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
        fontSize = LitterTextStyle.footnote.scaled,
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
) {
    val outputText =
        data.output
            ?.trim('\n')
            ?.takeIf { it.isNotBlank() }
            ?: if (data.status == AppOperationStatus.PENDING || data.status == AppOperationStatus.IN_PROGRESS) {
                "Waiting for output…"
            } else {
                "No output"
            }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
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
                text = data.command,
                color = LitterTheme.textSystem,
                fontFamily = LitterTheme.monoFont,
                fontSize = LitterTextStyle.caption.scaled,
                modifier = Modifier.weight(1f),
            )
            data.durationMs?.takeIf { it > 0 }?.let { ms ->
                Spacer(Modifier.width(6.dp))
                Text(
                    text = formatDuration(ms),
                    color = statusTint(data.status),
                    fontSize = 10.sp,
                )
            }
        }

        Spacer(Modifier.height(8.dp))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp, max = 116.dp)
                .background(LitterTheme.codeBackground, RoundedCornerShape(10.dp))
                .padding(horizontal = 10.dp, vertical = 8.dp),
        ) {
            Text(
                text = outputText,
                color = LitterTheme.textBody,
                fontFamily = LitterTheme.monoFont,
                fontSize = LitterTextStyle.caption2.scaled,
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState()),
            )
        }
    }
}

// ── File Change ──────────────────────────────────────────────────────────────

@Composable
private fun FileChangeRow(
    data: uniffi.codex_mobile_client.HydratedFileChangeData,
) {
    val summary = remember(data.changes) {
        val firstPath = data.changes.firstOrNull()?.path?.let(::workspaceTitle)
        when {
            firstPath != null && data.changes.size == 1 -> "Changed $firstPath"
            data.changes.isNotEmpty() -> "Changed ${data.changes.size} files"
            else -> "File changes"
        }
    }

    ToolCardShell(
        summary = summary,
        accent = LitterTheme.toolCallFileChange,
        status = data.status,
    ) {
        if (data.changes.isNotEmpty()) {
            ListSection("Files", data.changes.map { workspaceTitle(it.path) })
        }
        data.changes.forEach { change ->
            if (change.diff.isNotBlank()) {
                DiffSection(label = workspaceTitle(change.path), content = change.diff)
            }
        }
    }
}

// ── Todo List ────────────────────────────────────────────────────────────────

@Composable
private fun TodoListRow(
    data: uniffi.codex_mobile_client.HydratedTodoListData,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
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
                    fontSize = LitterTextStyle.footnote.scaled,
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
        Spacer(Modifier.height(6.dp))
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
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
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
                val previous = webView.getTag(android.R.id.content) as? String
                if (previous != document) {
                    webView.setTag(android.R.id.content, document)
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
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = "Requested Input",
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.footnote.scaled,
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
                    fontSize = LitterTextStyle.caption.scaled,
                    fontWeight = FontWeight.Medium,
                )
                Text(
                    text = question.answer.ifBlank { "No answer provided" },
                    color = LitterTheme.textSecondary,
                    fontSize = LitterTextStyle.caption.scaled,
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
            fontSize = 10.sp,
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
            fontSize = LitterTextStyle.footnote.scaled,
            fontWeight = FontWeight.Medium,
        )
        if (data.body.isNotBlank()) {
            Text(
                text = data.body,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption.scaled,
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
            fontSize = LitterTextStyle.footnote.scaled,
            fontWeight = FontWeight.Medium,
        )
        Text(
            text = data.message,
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.caption.scaled,
            modifier = Modifier.padding(top = 2.dp),
        )
        data.details?.takeIf { it.isNotBlank() }?.let { details ->
            Text(
                text = details,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption2.scaled,
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
                setTextColor(LitterTheme.textBody.hashCode())
                textSize = LitterTextStyle.body * textScale
                movementMethod = LinkMovementMethod.getInstance()
                setLinkTextColor(LitterTheme.accent.hashCode())
            }
        },
        update = { tv ->
            markwon.setMarkdown(tv, text)
            tv.setTextColor(android.graphics.Color.parseColor("#E0E0E0"))
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
                fontSize = 10.sp,
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
                fontSize = LitterTextStyle.caption2.scaled,
                modifier = Modifier.horizontalScroll(rememberScrollState()),
            )
        }
    }
}

@Composable
private fun ToolCardShell(
    summary: String,
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
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusIcon(status)
            Spacer(Modifier.width(8.dp))
            Text(
                text = summary,
                color = LitterTheme.textSystem,
                fontSize = LitterTextStyle.caption.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            durationMs?.takeIf { it > 0 }?.let { ms ->
                Spacer(Modifier.width(8.dp))
                Text(
                    text = formatDuration(ms),
                    color = statusTint(status),
                    fontSize = 10.sp,
                )
            }
            Spacer(Modifier.width(8.dp))
            Text(
                text = if (expanded) "▲" else "▼",
                color = accent,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
            )
        }

        if (expanded) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                content = content,
            )
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        color = LitterTheme.textSecondary,
        fontSize = 10.sp,
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
                fontSize = LitterTextStyle.caption2.scaled,
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
            fontSize = LitterTextStyle.caption.scaled,
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
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = value,
                        color = LitterTheme.textSystem,
                        fontSize = 10.sp,
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
                    Text("•", color = LitterTheme.textSecondary, fontSize = LitterTextStyle.caption.scaled)
                    Text(
                        text = item,
                        color = LitterTheme.textSystem,
                        fontSize = LitterTextStyle.caption.scaled,
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
                        fontSize = LitterTextStyle.caption.scaled,
                    )
                    Text(
                        text = item,
                        color = LitterTheme.textSystem,
                        fontSize = LitterTextStyle.caption.scaled,
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
        SectionLabel(label)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            content.lines().forEach { line ->
                Text(
                    text = if (line.isEmpty()) " " else line,
                    color = when {
                        line.startsWith("+") && !line.startsWith("+++") -> LitterTheme.success
                        line.startsWith("-") && !line.startsWith("---") -> LitterTheme.danger
                        line.startsWith("@@") -> LitterTheme.accentStrong
                        else -> LitterTheme.textBody
                    },
                    fontFamily = LitterTheme.monoFont,
                    fontSize = LitterTextStyle.caption2.scaled,
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(
                            when {
                                line.startsWith("+") && !line.startsWith("+++") -> LitterTheme.success.copy(alpha = 0.12f)
                                line.startsWith("-") && !line.startsWith("---") -> LitterTheme.danger.copy(alpha = 0.12f)
                                line.startsWith("@@") -> LitterTheme.accentStrong.copy(alpha = 0.12f)
                                else -> LitterTheme.codeBackground.copy(alpha = 0.72f)
                            },
                            RoundedCornerShape(8.dp),
                        )
                        .padding(horizontal = 10.dp, vertical = 4.dp),
                )
            }
        }
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
                        icon = if (item.isLocal) "⌁" else "◫",
                        title = item.name,
                        subtitle = item.hostname,
                        trailing = if (item.isConnected) "Connected" else "Offline",
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
                    ).joinToString(" · ")
                    SessionServerCard(
                        icon = "◌",
                        title = item.title.ifBlank { "Untitled session" },
                        subtitle = subtitle,
                        trailing = null,
                    )
                }
            }
        }
    }
}

@Composable
private fun SessionServerCard(
    icon: String,
    title: String,
    subtitle: String,
    trailing: String?,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(14.dp))
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = icon,
            color = LitterTheme.accent,
            fontSize = 16.sp,
            fontWeight = FontWeight.Medium,
        )
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
        trailing?.let {
            Text(
                text = it,
                color = LitterTheme.textMuted,
                fontSize = LitterTextStyle.caption.scaled,
            )
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
