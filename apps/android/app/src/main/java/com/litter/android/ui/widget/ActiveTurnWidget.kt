package com.litter.android.ui.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.litter.android.state.AppModel
import com.litter.android.state.contextPercent
import com.litter.android.state.hasActiveTurn
import com.litter.android.state.resolvedModel
import com.litter.android.state.resolvedPreview
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.HydratedConversationItemContent

class ActiveTurnWidget : GlanceAppWidget() {

    companion object {
        /** Call from TurnForegroundService to trigger widget refresh. */
        suspend fun triggerUpdate(context: Context) {
            val manager = GlanceAppWidgetManager(context)
            val ids = manager.getGlanceIds(ActiveTurnWidget::class.java)
            val widget = ActiveTurnWidget()
            for (id in ids) {
                widget.update(context, id)
            }
        }
    }

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val appModel = runCatching { AppModel.init(context) }.getOrNull()
        val snapshot = appModel?.snapshot?.value
        val activeThreads = snapshot?.threads?.filter { it.hasActiveTurn } ?: emptyList()

        val best = if (activeThreads.isNotEmpty()) {
            activeThreads.firstOrNull { it.key == snapshot?.activeThread }
                ?: activeThreads.first()
        } else {
            null
        }

        provideContent {
            GlanceTheme {
                if (best != null) {
                    ActiveTurnContent(
                        thread = best,
                        activeCount = activeThreads.size,
                    )
                } else {
                    IdlePlaceholder()
                }
            }
        }
    }
}

private val BgColor = ColorProvider(androidx.compose.ui.graphics.Color.Black)
private val PrimaryText = ColorProvider(androidx.compose.ui.graphics.Color.White)
private val SecondaryText = ColorProvider(androidx.compose.ui.graphics.Color(0xFF8E8E93))
private val AccentGreen = ColorProvider(androidx.compose.ui.graphics.Color(0xFF00FF9C))
private val WarningOrange = ColorProvider(androidx.compose.ui.graphics.Color(0xFFFF9500))
private val DangerRed = ColorProvider(androidx.compose.ui.graphics.Color(0xFFFF6B6B))

@Composable
private fun ActiveTurnContent(
    thread: AppThreadSnapshot,
    activeCount: Int,
) {
    val model = thread.resolvedModel
    val prompt = thread.resolvedPreview
    val contextPct = thread.contextPercent
    val phase = resolvePhase(thread)
    val toolCount = countToolCalls(thread)

    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(BgColor)
            .padding(12.dp),
    ) {
        // Row 1: prompt + active count
        Row(
            modifier = GlanceModifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "Codex",
                style = TextStyle(
                    color = AccentGreen,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
            Spacer(modifier = GlanceModifier.width(8.dp))
            Text(
                text = if (prompt.length > 50) prompt.take(47) + "\u2026" else prompt,
                style = TextStyle(
                    color = PrimaryText,
                    fontSize = 12.sp,
                ),
                maxLines = 1,
            )
            if (activeCount > 1) {
                Spacer(modifier = GlanceModifier.width(6.dp))
                Text(
                    text = "+${activeCount - 1}",
                    style = TextStyle(
                        color = SecondaryText,
                        fontSize = 10.sp,
                    ),
                )
            }
        }

        Spacer(modifier = GlanceModifier.height(6.dp))

        // Row 2: phase + model + ctx% + tool count
        Row(
            modifier = GlanceModifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = phase.label,
                style = TextStyle(
                    color = phase.colorProvider,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                ),
            )
            Spacer(modifier = GlanceModifier.width(8.dp))
            Text(
                text = model.ifEmpty { "unknown" },
                style = TextStyle(
                    color = SecondaryText,
                    fontSize = 10.sp,
                ),
                maxLines = 1,
            )
            if (toolCount > 0) {
                Spacer(modifier = GlanceModifier.width(8.dp))
                Text(
                    text = "$toolCount tools",
                    style = TextStyle(
                        color = SecondaryText,
                        fontSize = 10.sp,
                    ),
                )
            }
            if (contextPct > 0) {
                Spacer(modifier = GlanceModifier.width(8.dp))
                val ctxColor = when {
                    contextPct >= 80 -> DangerRed
                    contextPct >= 60 -> WarningOrange
                    else -> SecondaryText
                }
                Text(
                    text = "ctx $contextPct%",
                    style = TextStyle(
                        color = ctxColor,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Medium,
                    ),
                )
            }
        }
    }
}

@Composable
private fun IdlePlaceholder() {
    Box(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(BgColor)
            .padding(12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = "Codex",
                style = TextStyle(
                    color = AccentGreen,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                ),
            )
            Spacer(modifier = GlanceModifier.height(4.dp))
            Text(
                text = "No active turns",
                style = TextStyle(
                    color = SecondaryText,
                    fontSize = 12.sp,
                ),
            )
        }
    }
}

private enum class WidgetPhase(val label: String, val colorProvider: ColorProvider) {
    THINKING("thinking", WarningOrange),
    TOOL_CALL("running tool", WarningOrange),
    COMPLETED("done", SecondaryText),
    FAILED("failed", DangerRed),
}

private fun resolvePhase(thread: AppThreadSnapshot): WidgetPhase {
    val items = thread.hydratedConversationItems
    if (items.isEmpty()) return WidgetPhase.THINKING
    for (i in items.indices.reversed()) {
        return when (items[i].content) {
            is HydratedConversationItemContent.CommandExecution -> WidgetPhase.TOOL_CALL
            is HydratedConversationItemContent.McpToolCall -> WidgetPhase.TOOL_CALL
            is HydratedConversationItemContent.DynamicToolCall -> WidgetPhase.TOOL_CALL
            is HydratedConversationItemContent.WebSearch -> WidgetPhase.TOOL_CALL
            is HydratedConversationItemContent.Assistant -> WidgetPhase.THINKING
            is HydratedConversationItemContent.Reasoning -> WidgetPhase.THINKING
            else -> continue
        }
    }
    return WidgetPhase.THINKING
}

private fun countToolCalls(thread: AppThreadSnapshot): Int {
    return thread.hydratedConversationItems.count { item ->
        when (item.content) {
            is HydratedConversationItemContent.CommandExecution,
            is HydratedConversationItemContent.McpToolCall,
            is HydratedConversationItemContent.DynamicToolCall,
            is HydratedConversationItemContent.FileChange,
            is HydratedConversationItemContent.WebSearch,
            -> true
            else -> false
        }
    }
}
