package com.litter.android.ui.conversation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.contextPercent
import com.litter.android.state.hasActiveTurn
import com.litter.android.state.isIpcConnected
import com.litter.android.ui.ChatWallpaperBackground
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.TurnInterruptParams

/**
 * Main conversation screen with turn grouping, scroll-to-bottom FAB,
 * pinned context strip, gradient fade, and inline user input.
 */
@Composable
fun ConversationScreen(
    threadKey: ThreadKey,
    onBack: () -> Unit,
    onNavigateToSessions: (() -> Unit)? = null,
    onShowDirectoryPicker: (() -> Unit)? = null,
) {
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()

    val thread = remember(snapshot, threadKey) {
        snapshot?.threads?.find { it.key == threadKey }
    }
    val items = thread?.hydratedConversationItems ?: emptyList()
    val isThinking = thread?.hasActiveTurn == true
    val timelineEntries = remember(items, isThinking) { buildTimelineEntries(items, isThinking) }

    // Load thread content on first open — resume it so Rust hydrates conversation items
    LaunchedEffect(threadKey) {
        try {
            appModel.store.setActiveThread(threadKey)
            val server = appModel.snapshot.value?.servers?.find { it.serverId == threadKey.serverId }
            if (server?.isIpcConnected == true) {
                try {
                    appModel.externalResumeThread(threadKey)
                } catch (_: Exception) {
                    appModel.rpc.threadResume(
                        threadKey.serverId,
                        com.litter.android.state.AppThreadLaunchConfig().toThreadResumeParams(threadKey.threadId),
                    )
                }
            } else {
                appModel.rpc.threadResume(
                    threadKey.serverId,
                    com.litter.android.state.AppThreadLaunchConfig().toThreadResumeParams(threadKey.threadId),
                )
            }
            appModel.refreshSnapshot()
        } catch (_: Exception) {}
    }

    // Header model selector toggle
    var showModelSelector by remember { mutableStateOf(false) }

    // Pending user input for this thread
    val pendingInput = remember(snapshot, threadKey) {
        snapshot?.pendingUserInputs?.firstOrNull { it.threadId == threadKey.threadId }
    }

    // Pinned context: latest TODO progress + file change summary
    val pinnedContext = remember(items) {
        var todoProgress: String? = null
        var diffSummary: String? = null
        for (i in items.indices.reversed()) {
            when (val c = items[i].content) {
                is HydratedConversationItemContent.TodoList -> {
                    if (todoProgress == null) {
                        val done = c.v1.steps.count {
                            it.status == uniffi.codex_mobile_client.HydratedPlanStepStatus.COMPLETED
                        }
                        todoProgress = "$done/${c.v1.steps.size}"
                    }
                }
                is HydratedConversationItemContent.FileChange -> {
                    if (diffSummary == null) {
                        val adds = c.v1.changes.count { it.kind.contains("create", true) || it.kind.contains("edit", true) }
                        val dels = c.v1.changes.count { it.kind.contains("delete", true) }
                        if (adds > 0 || dels > 0) diffSummary = "+$adds -$dels"
                    }
                }
                else -> {}
            }
            if (todoProgress != null && diffSummary != null) break
        }
        if (todoProgress != null || diffSummary != null) Pair(todoProgress, diffSummary) else null
    }

    // Auto-scroll state
    val listState = rememberLazyListState()
    val isAtBottom by remember {
        derivedStateOf {
            val info = listState.layoutInfo
            if (info.totalItemsCount == 0) true
            else {
                val lastVisible = info.visibleItemsInfo.lastOrNull()
                lastVisible != null && lastVisible.index >= info.totalItemsCount - 2
            }
        }
    }

    LaunchedEffect(timelineEntries.size, isAtBottom) {
        if (isAtBottom && timelineEntries.isNotEmpty()) {
            listState.animateScrollToItem(timelineEntries.size)
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        ChatWallpaperBackground()

        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            HeaderBar(
                thread = thread,
                onBack = onBack,
            )

            // Message list with gradient fade and scroll FAB
            Box(modifier = Modifier.weight(1f)) {
                if (thread == null) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = LitterTheme.accent)
                    }
                } else {
                    LazyColumn(
                        state = listState,
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = 16.dp)
                            .drawWithContent {
                                drawContent()
                                // Top gradient fade
                                drawRect(
                                    brush = Brush.verticalGradient(
                                        colors = listOf(LitterTheme.background, Color.Transparent),
                                        startY = 0f,
                                        endY = 48f,
                                    ),
                                )
                            },
                    ) {
                        item { Spacer(Modifier.height(16.dp)) }

                        items(
                            items = timelineEntries,
                            key = { entry ->
                                when (entry) {
                                    is TimelineEntry.Single -> entry.item.id
                                    is TimelineEntry.Exploration -> entry.group.id
                                }
                            },
                        ) { entry ->
                            when (entry) {
                                is TimelineEntry.Single -> {
                                    ConversationTimelineItem(
                                        item = entry.item,
                                        isLiveTurn = isThinking,
                                        onEditMessage = { turnIndex ->
                                            scope.launch {
                                                val prefill = appModel.store.editMessage(threadKey, turnIndex)
                                                appModel.queueComposerPrefill(prefill)
                                            }
                                        },
                                        onForkFromMessage = { turnIndex ->
                                            scope.launch {
                                                try {
                                                    val config = com.litter.android.state.AppThreadLaunchConfig(model = thread.model)
                                                    val cwd = thread.info.cwd ?: "~"
                                                    val newKey = appModel.store.forkThreadFromMessage(
                                                        threadKey, turnIndex, config.toThreadForkParams(threadKey.threadId, cwd),
                                                    )
                                                    appModel.store.setActiveThread(newKey)
                                                    appModel.refreshSnapshot()
                                                } catch (_: Exception) {}
                                            }
                                        },
                                    )
                                }

                                is TimelineEntry.Exploration -> {
                                    ExplorationGroupRow(group = entry.group)
                                }
                            }
                            Spacer(Modifier.height(4.dp))
                        }

                        // Streaming cursor
                        if (isThinking) {
                            item {
                                StreamingCursor()
                            }
                        }

                        item { Spacer(Modifier.height(80.dp)) }
                    }
                }

                // Scroll-to-bottom FAB
                if (!isAtBottom && timelineEntries.isNotEmpty()) {
                    SmallFloatingActionButton(
                        onClick = {
                            scope.launch {
                                listState.animateScrollToItem(timelineEntries.size)
                            }
                        },
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = 8.dp),
                        containerColor = LitterTheme.surface,
                        contentColor = LitterTheme.textPrimary,
                    ) {
                        Icon(Icons.Default.KeyboardArrowDown, "Scroll to bottom", modifier = Modifier.size(20.dp))
                    }
                }

                // Interrupt FAB
                if (isThinking) {
                    FloatingActionButton(
                        onClick = {
                            scope.launch {
                                val turnId = thread?.activeTurnId ?: return@launch
                                appModel.rpc.turnInterrupt(
                                    threadKey.serverId,
                                    TurnInterruptParams(threadId = threadKey.threadId, turnId = turnId),
                                )
                            }
                        },
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(16.dp),
                        containerColor = LitterTheme.danger,
                        contentColor = Color.White,
                        elevation = FloatingActionButtonDefaults.elevation(0.dp),
                    ) {
                        Icon(Icons.Default.Stop, contentDescription = "Interrupt")
                    }
                }
            }

            // Pinned context strip
            if (pinnedContext != null) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(LitterTheme.codeBackground)
                        .padding(horizontal = 16.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    pinnedContext.first?.let { todo ->
                        Text("Plan $todo", color = LitterTheme.accent, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                    }
                    pinnedContext.second?.let { diff ->
                        Text(diff, color = LitterTheme.toolCallFileChange, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                    }
                }
            }

            // Composer bar
            ComposerBar(
                threadKey = threadKey,
                contextPercent = thread?.contextPercent ?: 0,
                isThinking = isThinking,
                rateLimits = remember(snapshot, threadKey) {
                    snapshot?.servers?.firstOrNull { it.serverId == threadKey.serverId }?.rateLimits
                },
                onToggleModelSelector = { showModelSelector = !showModelSelector },
                onNavigateToSessions = onNavigateToSessions,
                onShowDirectoryPicker = onShowDirectoryPicker,
                pendingUserInput = pendingInput,
            )
        }
    }
}

/**
 * Blinking cursor shown at the end of streaming assistant text.
 */
@Composable
private fun StreamingCursor() {
    val transition = rememberInfiniteTransition(label = "cursor")
    val alpha by transition.animateFloat(
        initialValue = 1f,
        targetValue = 0f,
        animationSpec = infiniteRepeatable(
            animation = tween(500),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "cursorAlpha",
    )
    Text(
        text = "▊",
        color = LitterTheme.accent.copy(alpha = alpha),
        fontSize = 14.sp,
    )
}
