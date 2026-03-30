package com.litter.android.ui.conversation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.LinearEasing
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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.contextPercent
import com.litter.android.state.hasActiveTurn
import com.litter.android.state.isIpcConnected
import com.litter.android.state.isActiveStatus
import com.litter.android.ui.BerkeleyMono
import com.litter.android.ui.ChatWallpaperBackground
import com.litter.android.ui.ConversationPrefs
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.WallpaperManager
import com.litter.android.ui.WallpaperType
import com.litter.android.ui.isNearListBottom
import com.litter.android.ui.rememberStickyFollowTail
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.AppRenameThreadRequest
import uniffi.codex_mobile_client.ThreadKey

/**
 * Main conversation screen with turn grouping, scroll-to-bottom FAB,
 * pinned context strip, gradient fade, and inline user input.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationScreen(
    threadKey: ThreadKey,
    onBack: () -> Unit,
    onInfo: (() -> Unit)? = null,
    onNavigateToSessions: (() -> Unit)? = null,
    onShowDirectoryPicker: (() -> Unit)? = null,
) {
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()

    val thread = remember(snapshot, threadKey) {
        snapshot?.threads?.find { it.key == threadKey }
    }
    val server = remember(snapshot, threadKey) {
        snapshot?.servers?.find { it.serverId == threadKey.serverId }
    }
    val items = thread?.hydratedConversationItems ?: emptyList()
    val normalizedActiveTurnId = thread?.activeTurnId?.trim()?.takeIf { it.isNotEmpty() }
    val isThinking = thread?.info?.status?.isActiveStatus == true
    val collapseTurns = ConversationPrefs.areTurnsCollapsed
    val agentDirectoryVersion = snapshot?.agentDirectoryVersion ?: 0uL
    val transcriptTurns = remember(items, thread?.info?.status, isThinking, collapseTurns) {
        buildTranscriptTurns(
            items = items,
            isStreaming = isThinking,
            expandedRecentTurnCount = if (collapseTurns) 1 else Int.MAX_VALUE,
        )
    }
    val transcriptTailSignature = remember(items, normalizedActiveTurnId, isThinking) {
        var hash = 17
        items.takeLast(4).forEach { item ->
            hash = 31 * hash + item.hashCode()
        }
        hash = 31 * hash + items.size
        hash = 31 * hash + (normalizedActiveTurnId?.hashCode() ?: 0)
        hash = 31 * hash + if (isThinking) 1 else 0
        hash
    }
    var expandedTurnIds by remember(threadKey, collapseTurns) { mutableStateOf(setOf<String>()) }
    var streamingRenderTick by remember(threadKey) { mutableStateOf(0) }
    var followScrollToken by remember(threadKey) { mutableStateOf(0) }
    var lastObservedUpdatedAt by remember(threadKey) { mutableStateOf<Long?>(null) }
    LaunchedEffect(transcriptTurns.map { it.id to it.isCollapsedByDefault }) {
        val validIds = transcriptTurns.mapTo(mutableSetOf()) { it.id }
        expandedTurnIds = expandedTurnIds.intersect(validIds)
    }
    LaunchedEffect(thread?.info?.updatedAt, isThinking) {
        val updatedAt = thread?.info?.updatedAt
        if (updatedAt != null && updatedAt != lastObservedUpdatedAt && isThinking) {
            followScrollToken += 1
        }
        lastObservedUpdatedAt = updatedAt
    }

    // Load thread content on first open — resume it so Rust hydrates conversation items
    LaunchedEffect(threadKey) {
        try {
            appModel.store.setActiveThread(threadKey)
            val server = appModel.snapshot.value?.servers?.find { it.serverId == threadKey.serverId }
            val cwdOverride = thread?.info?.cwd
            if (server?.isIpcConnected == true) {
                try {
                    appModel.externalResumeThread(threadKey)
                } catch (_: Exception) {
                    appModel.client.resumeThread(
                        threadKey.serverId,
                        appModel.launchState.threadResumeRequest(
                            threadKey.threadId,
                            cwdOverride = cwdOverride,
                        ),
                    )
                }
            } else {
                appModel.client.resumeThread(
                    threadKey.serverId,
                    appModel.launchState.threadResumeRequest(
                        threadKey.threadId,
                        cwdOverride = cwdOverride,
                    ),
                )
            }
            appModel.refreshSnapshot()
        } catch (_: Exception) {}
    }

    LaunchedEffect(thread?.info?.cwd) {
        appModel.launchState.syncFromThread(thread)
    }

    var showModelSelector by remember { mutableStateOf(false) }
    var showRenameDialog by remember { mutableStateOf(false) }
    var renameDraft by remember(threadKey) { mutableStateOf("") }
    var showPermissionsSheet by remember { mutableStateOf(false) }
    var showExperimentalSheet by remember { mutableStateOf(false) }
    var showSkillsSheet by remember { mutableStateOf(false) }
    var slashErrorMessage by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(showModelSelector, server?.health, server?.account, server?.availableModels, server?.rateLimits) {
        if (showModelSelector || (server?.account != null && server.rateLimits == null)) {
            appModel.loadConversationMetadataIfNeeded(threadKey.serverId)
        }
    }

    // Pending user input for this thread
    val pendingInput = remember(snapshot, threadKey) {
        snapshot?.pendingUserInputs?.firstOrNull { it.threadId == threadKey.threadId }
    }

    // Pinned context: latest TODO progress + file change summary
    val pinnedContext = remember(items) {
        var todoProgress: String? = null
        var diffSummary: DiffSummary? = null
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
                        var additions = 0
                        var deletions = 0
                        var sawDiff = false
                        c.v1.changes.forEach { change ->
                            sawDiff = true
                            val stats = summarizeDiff(change.diff)
                            additions += stats.additions
                            deletions += stats.deletions
                        }
                        if (sawDiff) {
                            diffSummary = DiffSummary(additions = additions, deletions = deletions)
                        }
                    }
                }
                else -> {}
            }
            if (todoProgress != null && diffSummary != null) break
        }
        if (todoProgress != null || diffSummary != null) {
            PinnedContextData(todoProgress = todoProgress, diffSummary = diffSummary)
        } else {
            null
        }
    }

    // Auto-scroll state
    val listState = rememberLazyListState()
    val shouldFollowTail = rememberStickyFollowTail(
        listState = listState,
        resetKey = threadKey,
    )
    val isAtBottom by remember {
        derivedStateOf {
            listState.isNearListBottom()
        }
    }

    LaunchedEffect(threadKey, transcriptTurns.size) {
        if (shouldFollowTail && transcriptTurns.isNotEmpty()) {
            listState.animateScrollToItem(conversationBottomAnchorIndex(transcriptTurns.size))
        }
    }

    LaunchedEffect(threadKey, transcriptTailSignature, followScrollToken, streamingRenderTick) {
        if (shouldFollowTail && transcriptTurns.isNotEmpty()) {
            listState.scrollToItem(conversationBottomAnchorIndex(transcriptTurns.size))
        }
    }

    val wallpaperVersion = WallpaperManager.version
    val hasWallpaper = remember(threadKey, wallpaperVersion) {
        WallpaperManager.resolvedConfig(threadKey)?.type?.let { it != WallpaperType.NONE } == true
    }
    val headerScrimColor = if (hasWallpaper) LitterTheme.surface.copy(alpha = 0.75f) else LitterTheme.surface

    Box(modifier = Modifier.fillMaxSize()) {
        // Wallpaper fills the entire screen edge-to-edge (behind status + nav bars)
        ChatWallpaperBackground(threadKey = threadKey)

        Column(
            modifier = Modifier.fillMaxSize(),
        ) {
            // Header with status bar inset built-in — extends behind status bar with scrim
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(headerScrimColor),
            ) {
                Spacer(Modifier.statusBarsPadding())
                HeaderBar(
                    thread = thread,
                    onBack = onBack,
                    onInfo = onInfo,
                    showModelSelector = showModelSelector,
                    onToggleModelSelector = { showModelSelector = !showModelSelector },
                    transparentBackground = hasWallpaper,
                )
            }

            // Message list with gradient fade and scroll FAB
            Box(modifier = Modifier.weight(1f)) {
                if (thread == null) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = LitterTheme.accent)
                    }
                } else {
                    // Use transparent gradient when wallpaper is set
                    val fadeColor = if (hasWallpaper) Color.Transparent else LitterTheme.background

                    LazyColumn(
                        state = listState,
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = 16.dp)
                            .then(
                                if (!hasWallpaper) {
                                    Modifier.drawWithContent {
                                        drawContent()
                                        drawRect(
                                            brush = Brush.verticalGradient(
                                                colors = listOf(LitterTheme.background, Color.Transparent),
                                                startY = 0f,
                                                endY = 48f,
                                            ),
                                        )
                                    }
                                } else Modifier.drawWithContent { drawContent() }
                            ),
                    ) {
                        item { Spacer(Modifier.height(16.dp)) }

                        items(
                            items = transcriptTurns,
                            key = { it.id },
                        ) { turn ->
                            val isExpanded = !turn.isCollapsedByDefault || expandedTurnIds.contains(turn.id)
                            val streamingAssistantItemId = remember(turn.items, turn.isActiveTurn) {
                                if (!turn.isActiveTurn) {
                                    null
                                } else {
                                    turn.items.lastOrNull {
                                        it.content is HydratedConversationItemContent.Assistant
                                    }?.id
                                }
                            }
                            if (isExpanded) {
                                val timelineEntries = remember(turn.items, turn.isActiveTurn) {
                                    buildTimelineEntries(turn.items, turn.isActiveTurn)
                                }
                                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    timelineEntries.forEach { entry ->
                                        when (entry) {
                                            is TimelineEntry.Single -> {
                                                ConversationTimelineItem(
                                                    item = entry.item,
                                                    serverId = threadKey.serverId,
                                                    agentDirectoryVersion = agentDirectoryVersion,
                                                    isLiveTurn = turn.isActiveTurn,
                                                    isStreamingMessage = entry.item.id == streamingAssistantItemId,
                                                    onStreamingSnapshotRendered = if (entry.item.id == streamingAssistantItemId) {
                                                        { streamingRenderTick += 1 }
                                                    } else {
                                                        null
                                                    },
                                                    onEditMessage = { turnIndex ->
                                                        scope.launch {
                                                            val prefill = appModel.store.editMessage(threadKey, turnIndex)
                                                            appModel.queueComposerPrefill(threadKey, prefill)
                                                        }
                                                    },
                                                    onForkFromMessage = { turnIndex ->
                                                        scope.launch {
                                                            try {
                                                                val newKey = appModel.store.forkThreadFromMessage(
                                                                    threadKey,
                                                                    turnIndex,
                                                                    appModel.launchState.forkThreadFromMessageRequest(
                                                                        cwdOverride = thread.info.cwd,
                                                                    ),
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
                                    }

                                    if (turn.isActiveTurn) {
                                        StreamingCursor()
                                    }

                                    if (turn.isCollapsedByDefault) {
                                        Text(
                                            text = "Show less",
                                            color = LitterTheme.textMuted,
                                            fontSize = 11.sp,
                                            fontWeight = FontWeight.Medium,
                                            modifier = Modifier
                                                .clickable {
                                                    expandedTurnIds = expandedTurnIds - turn.id
                                                }
                                                .padding(top = 2.dp),
                                        )
                                    }
                                }
                            } else {
                                CollapsedTurnCard(turn = turn) {
                                    expandedTurnIds = expandedTurnIds + turn.id
                                }
                            }
                            Spacer(Modifier.height(6.dp))
                        }

                        item { Spacer(Modifier.height(80.dp)) }
                    }
                }

                // Scroll-to-bottom FAB
                if (!isAtBottom && transcriptTurns.isNotEmpty()) {
                    SmallFloatingActionButton(
                        onClick = {
                            scope.launch {
                                listState.animateScrollToItem(conversationBottomAnchorIndex(transcriptTurns.size))
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
            }

            // Bottom area: gradient fade + pinned context + composer + nav bar inset
            Column(modifier = Modifier.fillMaxWidth()) {
                // Gradient fade from transparent to scrim
                if (hasWallpaper) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(24.dp)
                            .background(
                                Brush.verticalGradient(
                                    colors = listOf(Color.Transparent, headerScrimColor),
                                ),
                            ),
                    )
                }

                // Solid scrim area for controls
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(headerScrimColor),
                ) {
                    // Pinned context strip
                    if (pinnedContext != null) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.codeBackground.copy(alpha = if (hasWallpaper) 0.75f else 1f))
                                .padding(horizontal = 16.dp, vertical = 4.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            pinnedContext.todoProgress?.let { todo ->
                                PlanContextBadge(progress = todo)
                            }
                            pinnedContext.diffSummary?.let { diff ->
                                DiffSummaryBadge(summary = diff)
                            }
                        }
                    }

                    // Composer bar
                    ComposerBar(
                        threadKey = threadKey,
                        activeTurnId = thread?.activeTurnId,
                        contextPercent = thread?.composerContextPercent(),
                        isThinking = isThinking,
                        queuedFollowUps = thread?.queuedFollowUps ?: emptyList(),
                        rateLimits = server?.rateLimits,
                        onToggleModelSelector = { showModelSelector = !showModelSelector },
                        onNavigateToSessions = onNavigateToSessions,
                        onShowDirectoryPicker = onShowDirectoryPicker,
                        onShowRenameDialog = { initialName ->
                            val trimmed = initialName?.trim().orEmpty()
                            if (trimmed.isNotEmpty()) {
                                scope.launch {
                                    try {
                                        appModel.client.renameThread(
                                            threadKey.serverId,
                                            AppRenameThreadRequest(
                                                threadId = threadKey.threadId,
                                                name = trimmed,
                                            ),
                                        )
                                        appModel.refreshSnapshot()
                                    } catch (e: Exception) {
                                        slashErrorMessage = e.message ?: "Failed to rename conversation"
                                    }
                                }
                            } else {
                                renameDraft = thread?.info?.title?.takeIf { it.isNotBlank() }.orEmpty()
                                showRenameDialog = true
                            }
                        },
                        onShowPermissionsSheet = { showPermissionsSheet = true },
                        onShowExperimentalSheet = { showExperimentalSheet = true },
                        onShowSkillsSheet = { showSkillsSheet = true },
                        onSlashError = { slashErrorMessage = it },
                        pendingUserInput = pendingInput,
                    )

                    Spacer(Modifier.navigationBarsPadding())
                }
            }
        }

        if (showPermissionsSheet) {
            ModalBottomSheet(
                onDismissRequest = { showPermissionsSheet = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                ComposerPermissionsSheet(
                    onDismiss = { showPermissionsSheet = false },
                )
            }
        }

        if (showExperimentalSheet) {
            ModalBottomSheet(
                onDismissRequest = { showExperimentalSheet = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                ComposerExperimentalSheet(
                    serverId = threadKey.serverId,
                    onDismiss = { showExperimentalSheet = false },
                    onError = { slashErrorMessage = it },
                )
            }
        }

        if (showSkillsSheet) {
            ModalBottomSheet(
                onDismissRequest = { showSkillsSheet = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                ComposerSkillsSheet(
                    serverId = threadKey.serverId,
                    cwd = thread?.info?.cwd ?: appModel.launchState.snapshot.value.currentCwd.ifBlank { "/" },
                    onDismiss = { showSkillsSheet = false },
                    onError = { slashErrorMessage = it },
                )
            }
        }

        if (showRenameDialog) {
            AlertDialog(
                onDismissRequest = { showRenameDialog = false },
                title = { Text("Rename Thread") },
                text = {
                    OutlinedTextField(
                        value = renameDraft,
                        onValueChange = { renameDraft = it },
                        label = { Text("New thread title") },
                        singleLine = true,
                    )
                },
                confirmButton = {
                    TextButton(
                        onClick = {
                            val nextTitle = renameDraft.trim()
                            if (nextTitle.isEmpty()) {
                                showRenameDialog = false
                                return@TextButton
                            }
                            showRenameDialog = false
                            scope.launch {
                                try {
                                    appModel.client.renameThread(
                                        threadKey.serverId,
                                        AppRenameThreadRequest(
                                            threadId = threadKey.threadId,
                                            name = nextTitle,
                                        ),
                                    )
                                    appModel.refreshSnapshot()
                                } catch (e: Exception) {
                                    slashErrorMessage = e.message ?: "Failed to rename conversation"
                                }
                            }
                        },
                    ) {
                        Text("Rename")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showRenameDialog = false }) {
                        Text("Cancel")
                    }
                },
            )
        }

        slashErrorMessage?.let { message ->
            AlertDialog(
                onDismissRequest = { slashErrorMessage = null },
                title = { Text("Slash Command Error") },
                text = { Text(message) },
                confirmButton = {
                    TextButton(onClick = { slashErrorMessage = null }) {
                        Text("OK")
                    }
                },
            )
        }
    }
}

private data class PinnedContextData(
    val todoProgress: String?,
    val diffSummary: DiffSummary?,
)

private data class DiffSummary(
    val additions: Int,
    val deletions: Int,
) {
    val hasChanges: Boolean
        get() = additions > 0 || deletions > 0
}

private fun summarizeDiff(diff: String): DiffSummary {
    var additions = 0
    var deletions = 0
    diff.lineSequence().forEach { line ->
        when {
            line.startsWith("+") && !line.startsWith("+++") -> additions += 1
            line.startsWith("-") && !line.startsWith("---") -> deletions += 1
        }
    }
    return DiffSummary(additions = additions, deletions = deletions)
}

private fun uniffi.codex_mobile_client.AppThreadSnapshot.composerContextPercent(): Int? {
    if (contextTokensUsed == null && modelContextWindow == null) return null
    val contextWindow = modelContextWindow?.toLong()
    val baseline = 12_000L
    if (contextWindow == null || contextWindow <= baseline) {
        return contextPercent.coerceIn(0, 100)
    }
    val totalTokens = contextTokensUsed?.toLong() ?: baseline
    val effectiveWindow = contextWindow - baseline
    val usedTokens = (totalTokens - baseline).coerceAtLeast(0)
    val remainingTokens = (effectiveWindow - usedTokens).coerceAtLeast(0)
    return ((remainingTokens.toDouble() / effectiveWindow.toDouble()) * 100.0)
        .toInt()
        .coerceIn(0, 100)
}

private fun conversationBottomAnchorIndex(turnCount: Int): Int = turnCount + 1

@Composable
private fun PlanContextBadge(progress: String) {
    Text(
        text = "Plan $progress",
        color = LitterTheme.accent,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        modifier = Modifier
            .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(999.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
    )
}

@Composable
private fun DiffSummaryBadge(summary: DiffSummary) {
    Row(
        modifier = Modifier
            .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(999.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "\u2194",
            color = LitterTheme.accent,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
        )
        if (summary.hasChanges) {
            Text(
                text = "+${summary.additions}",
                color = LitterTheme.success,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = BerkeleyMono,
            )
            Text(
                text = "-${summary.deletions}",
                color = LitterTheme.danger,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = BerkeleyMono,
            )
        } else {
            Text(
                text = "Diff",
                color = LitterTheme.textSecondary,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

/**
 * Shimmering "Thinking..." text shown while the assistant is working.
 */
@Composable
private fun StreamingCursor() {
    val transition = rememberInfiniteTransition(label = "shimmer")
    val shimmerOffset by transition.animateFloat(
        initialValue = -1f,
        targetValue = 2f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1500, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "shimmerOffset",
    )
    val shimmerBrush = Brush.linearGradient(
        colors = listOf(
            LitterTheme.textSecondary.copy(alpha = 0.4f),
            LitterTheme.accent,
            LitterTheme.textSecondary.copy(alpha = 0.4f),
        ),
        start = Offset(shimmerOffset * 200f, 0f),
        end = Offset((shimmerOffset + 0.6f) * 200f, 0f),
    )
    Text(
        text = "Thinking...",
        fontSize = 14.sp,
        fontWeight = FontWeight.Medium,
        style = TextStyle(brush = shimmerBrush),
    )
}
