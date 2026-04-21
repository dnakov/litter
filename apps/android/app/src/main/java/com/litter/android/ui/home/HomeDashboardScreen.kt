package com.litter.android.ui.home

import com.sigkitten.litter.android.BuildConfig
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pets
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.ViewAgenda
import androidx.compose.material.icons.outlined.ViewList
import androidx.compose.material.icons.outlined.ViewQuilt
import androidx.compose.material.icons.outlined.ViewStream
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt
import com.litter.android.state.AppLifecycleController
import com.litter.android.state.DebugSettings
import com.litter.android.state.SavedProjectStore
import com.litter.android.state.SavedServerStore
import com.litter.android.state.SavedThreadsStore
import com.litter.android.state.connectionModeLabel
import com.litter.android.state.displayTitle
import com.litter.android.state.isIpcConnected
import com.litter.android.state.statusColor
import com.litter.android.state.statusLabel
import com.litter.android.ui.ExperimentalFeatures
import com.litter.android.ui.LitterFeature
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.scaled
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppProject
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.PinnedThreadKey
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.deriveProjects
import uniffi.codex_mobile_client.projectIdFor

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun HomeDashboardScreen(
    onOpenConversation: (ThreadKey) -> Unit,
    onShowDiscovery: () -> Unit,
    onShowSettings: () -> Unit,
    onOpenProjectPicker: () -> Unit,
    selectedProject: AppProject?,
    selectedServerId: String?,
    onSelectServer: (AppServerSnapshot) -> Unit,
    onThreadCreated: (ThreadKey) -> Unit,
    onStartVoice: (() -> Unit)? = null,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    val voiceController = remember { com.litter.android.state.VoiceRuntimeController.shared }
    val lifecycleController = remember { AppLifecycleController() }

    var showTipJar by remember { mutableStateOf(false) }
    var renameTarget by remember { mutableStateOf<AppServerSnapshot?>(null) }
    var renameText by remember { mutableStateOf("") }
    val appVersionLabel = remember { "v${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})" }

    val snap = snapshot
    val servers = remember(snap) {
        snap?.let { HomeDashboardSupport.sortedConnectedServers(it) } ?: emptyList()
    }
    // Every session across connected servers — unlimited, used by the search
    // view so the user can pin any thread.
    val allSessions = remember(snap) {
        snap?.let { HomeDashboardSupport.recentSessions(it, limit = Int.MAX_VALUE) } ?: emptyList()
    }

    // Pinned + hidden state. Refreshed when the user mutates via the UI.
    var pinnedKeys by remember { mutableStateOf(SavedThreadsStore.pinnedKeys(context)) }
    var hiddenKeys by remember { mutableStateOf(SavedThreadsStore.hiddenKeys(context)) }

    // Home list = pinned first (preserving pin order). If nothing is pinned,
    // show the 10 most-recent sessions. Hidden threads are excluded from
    // both halves.
    val homeSessions = remember(pinnedKeys, hiddenKeys, allSessions) {
        mergeHomeSessions(pinnedKeys, hiddenKeys, allSessions)
    }

    val scopedServerId = selectedProject?.serverId ?: selectedServerId
    val recentSessions = remember(homeSessions, scopedServerId) {
        if (scopedServerId.isNullOrEmpty()) homeSessions
        else homeSessions.filter { it.key.serverId == scopedServerId }
    }

    var confirmAction by remember { mutableStateOf<ConfirmAction?>(null) }
    var isComposerActive by remember { mutableStateOf(false) }
    // When the user taps a composer chip (model / project), a modal sheet
    // opens and the IME dismisses — which would otherwise cascade through
    // `HomeComposerBar.onActiveChange(false)` and collapse the composer
    // back to the `+` button. This flag lets us suppress collapse while a
    // chip sheet is likely mid-interaction.
    var suppressComposerCollapse by remember { mutableStateOf(false) }
    var isSearchExpanded by remember { mutableStateOf(false) }
    var searchQuery by remember { mutableStateOf("") }
    val requestedHydrationKeys = remember { mutableSetOf<String>() }

    // Dashboard zoom state. `zoomLevel` observes DashboardZoomPrefs; the
    // toolbar button cycles 1→2→3→4→3→2→1 via a direction flip at the
    // bounds, mirroring iOS HomeDashboardView.swift:186-203. SessionCanvasRow
    // (task #4) owns its own per-row `animateFloatAsState` off this value.
    val zoomLevel by DashboardZoomPrefs.currentLevel.collectAsState()
    var zoomDirection by remember { mutableIntStateOf(1) }
    var pinchBaseZoom by remember { mutableStateOf<Int?>(null) }
    var pinchAccumulator by remember { mutableStateOf(1f) }
    val haptics = LocalHapticFeedback.current

    fun zoomIconFor(level: Int): ImageVector = when (level) {
        // Matches iOS semantics: 1 = most compact (scan), 4 = most detail (deep).
        1 -> Icons.Outlined.ViewQuilt
        2 -> Icons.Outlined.ViewList
        3 -> Icons.Outlined.ViewAgenda
        else -> Icons.Outlined.ViewStream
    }

    // Auto-hydrate any visible session that doesn't have stats yet. Runs on
    // first composition and whenever the visible set changes. We resume
    // rather than read: `externalResumeThread` attaches a server-side
    // conversation listener for this connection so the card receives live
    // `TurnStarted` / `ItemStarted` / `MessageDelta` / `TurnCompleted` events
    // without the user opening the thread. Mirrors iOS `hydrateThread` in
    // `LitterApp.swift:990-1006` after commit 52ff299d. The store short-
    // circuits when a listener is already attached, so warm paths stay cheap.
    val visibleIds = recentSessions.map { "${it.key.serverId}/${it.key.threadId}" }
    LaunchedEffect(visibleIds) {
        for (session in recentSessions) {
            if (session.stats != null) continue
            val id = "${session.key.serverId}/${session.key.threadId}"
            if (!requestedHydrationKeys.add(id)) continue
            scope.launch {
                runCatching { appModel.externalResumeThread(session.key) }
                appModel.refreshSnapshot()
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        // Sessions list fills the whole screen, with top/bottom content padding
        // so items don't sit under the floating chrome.
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    // Pinch-to-zoom. `detectTransformGestures(panZoomLock = true)`
                    // lets single-finger vertical drags still reach the
                    // LazyColumn scroll, and only begins consuming when a
                    // true pinch is in progress. We accumulate the
                    // multiplicative zoom factor across the gesture so a
                    // slow pinch composes the same as a fast one, then
                    // round to a discrete level delta (same 0.4 threshold
                    // iOS uses at HomeDashboardView.swift:334-363). The
                    // outer while-loop resets accumulator state when the
                    // gesture ends and detectTransformGestures returns.
                    while (true) {
                        pinchBaseZoom = null
                        pinchAccumulator = 1f
                        detectTransformGestures(panZoomLock = true) { _, _, zoom, _ ->
                            if (zoom == 1f) return@detectTransformGestures
                            val base = pinchBaseZoom ?: zoomLevel.also { pinchBaseZoom = it }
                            pinchAccumulator *= zoom
                            val delta = ((pinchAccumulator - 1f) / 0.4f).roundToInt()
                            val next = (base + delta).coerceIn(
                                DashboardZoomPrefs.MIN_LEVEL,
                                DashboardZoomPrefs.MAX_LEVEL,
                            )
                            if (next != zoomLevel) {
                                DashboardZoomPrefs.setLevel(context, next)
                                haptics.performHapticFeedback(
                                    HapticFeedbackType.TextHandleMove,
                                )
                            }
                        }
                    }
                },
            contentPadding = run {
                // Respect system bars so list content can scroll under the
                // translucent top/bottom chrome *and* past the status/nav bar
                // insets (edge-to-edge). The fixed dp offsets cover the
                // floating chrome (server pills on top, composer buttons on
                // bottom) so the first/last items aren't hidden behind them.
                val sysInsets = WindowInsets.systemBars.asPaddingValues()
                androidx.compose.foundation.layout.PaddingValues(
                    top = 72.dp + sysInsets.calculateTopPadding(),
                    bottom = 72.dp + sysInsets.calculateBottomPadding(),
                )
            },
        ) {
            if (recentSessions.isNotEmpty()) {
                items(recentSessions, key = { "${it.key.serverId}/${it.key.threadId}" }) { session ->
                    val id = "${session.key.serverId}/${session.key.threadId}"
                    val isHydrating = session.stats == null && id in requestedHydrationKeys
                    // Row hosts both gestures through one swipe handler:
                    // left-swipe (trailing) hides; right-swipe (leading) opens
                    // QuickReplySheet. Nesting `SwipeToHideRow` inside
                    // `SessionReplySwipe` would have the two pointer handlers
                    // fighting over the same drag stream.
                    SessionReplySwipe(
                        session = session,
                        appModel = appModel,
                        trailingAction = com.litter.android.ui.common.SwipeAction(
                            icon = Icons.Default.MoreVert,
                            label = "hide",
                            tint = LitterTheme.textMuted,
                            onTrigger = {
                                val key = PinnedThreadKey(
                                    serverId = session.key.serverId,
                                    threadId = session.key.threadId,
                                )
                                SavedThreadsStore.hide(context, key)
                                hiddenKeys = SavedThreadsStore.hiddenKeys(context)
                                pinnedKeys = SavedThreadsStore.pinnedKeys(context)
                            },
                        ),
                        onError = { msg ->
                            confirmAction = ConfirmAction.ReplyError(msg)
                        },
                        modifier = Modifier.animateItem(),
                    ) {
                        SessionCanvasRow(
                            session = session,
                            zoomLevel = zoomLevel,
                            isHydrating = isHydrating,
                            onClick = {
                                appModel.launchState.updateCurrentCwd(session.cwd)
                                onOpenConversation(session.key)
                            },
                            onDelete = {
                                confirmAction = ConfirmAction.ArchiveSession(session)
                            },
                        )
                    }
                }
            } else {
                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 48.dp, bottom = 8.dp, start = 16.dp, end = 16.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            text = "No sessions yet",
                            color = LitterTheme.textSecondary,
                            fontSize = LitterTextStyle.body.scaled,
                            fontWeight = FontWeight.Medium,
                        )
                        Text(
                            text = if (servers.isEmpty())
                                "Connect a server to start your first session."
                            else
                                "Pick a project and send a message to start one.",
                            color = LitterTheme.textMuted,
                            fontSize = LitterTextStyle.caption.scaled,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        )
                    }
                }
            }
        }

        // Top chrome: header + server pill row, floating over the list with a
        // gradient scrim (matches iOS translucent bar). Top edge is fully
        // opaque so the status bar area stays legible, fading to transparent
        // so list content is visibly scrolling behind the chrome.
        Column(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .background(
                    androidx.compose.ui.graphics.Brush.verticalGradient(
                        colors = listOf(
                            LitterTheme.background.copy(alpha = 0.55f),
                            LitterTheme.background.copy(alpha = 0.4f),
                            androidx.compose.ui.graphics.Color.Transparent,
                        ),
                    ),
                )
                .statusBarsPadding(),
        ) {
            Spacer(Modifier.height(16.dp))
            val tierIcons by com.litter.android.state.TipJarSupporterState.tierIcons
            LaunchedEffect(Unit) {
                com.litter.android.state.TipJarSupporterState.refresh(context)
            }
            val leftKitties = tierIcons.take(2).filterNotNull()
            val rightKitties = tierIcons.drop(2).filterNotNull()
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onShowSettings, modifier = Modifier.size(32.dp)) {
                    Icon(
                        Icons.Default.Settings,
                        contentDescription = "Settings",
                        tint = LitterTheme.textSecondary,
                        modifier = Modifier.size(20.dp),
                    )
                }
                Spacer(Modifier.weight(1f))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    leftKitties.forEach { iconRes ->
                        androidx.compose.foundation.Image(
                            painter = androidx.compose.ui.res.painterResource(iconRes),
                            contentDescription = "Supporter",
                            modifier = Modifier
                                .size(28.dp)
                                .clickable { showTipJar = true },
                        )
                    }
                    if (leftKitties.isNotEmpty()) Spacer(Modifier.width(4.dp))
                    com.litter.android.ui.AnimatedLogo(size = 64.dp)
                    if (rightKitties.isNotEmpty()) Spacer(Modifier.width(4.dp))
                    rightKitties.forEach { iconRes ->
                        androidx.compose.foundation.Image(
                            painter = androidx.compose.ui.res.painterResource(iconRes),
                            contentDescription = "Supporter",
                            modifier = Modifier
                                .size(28.dp)
                                .clickable { showTipJar = true },
                        )
                    }
                }
                Spacer(Modifier.weight(1f))
                // Zoom cycle button. Cycles 1→2→3→4→3→2→1 via direction flip at
                // the bounds. Mirrors iOS HomeDashboardView.swift:186-203.
                IconButton(
                    onClick = {
                        var next = zoomLevel + zoomDirection
                        if (next > DashboardZoomPrefs.MAX_LEVEL) {
                            zoomDirection = -1
                            next = zoomLevel + zoomDirection
                        } else if (next < DashboardZoomPrefs.MIN_LEVEL) {
                            zoomDirection = 1
                            next = zoomLevel + zoomDirection
                        }
                        DashboardZoomPrefs.setLevel(context, next)
                    },
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(
                        imageVector = zoomIconFor(zoomLevel),
                        contentDescription = "Dashboard zoom",
                        tint = LitterTheme.textSecondary,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
            Spacer(Modifier.height(8.dp))

            ServerPillRow(
                servers = servers,
                selectedServerId = selectedProject?.serverId ?: selectedServerId,
                onTap = onSelectServer,
                onReconnect = { server ->
                    scope.launch {
                        lifecycleController.reconnectServer(context, appModel, server.serverId)
                    }
                },
                onRename = { server ->
                    renameText = server.displayName
                    renameTarget = server
                },
                onRemove = { server ->
                    confirmAction = ConfirmAction.DisconnectServer(server)
                },
                onAdd = onShowDiscovery,
            )

            // Short fade at the bottom of the top scrim for a soft transition.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(16.dp)
                    .background(
                        androidx.compose.ui.graphics.Brush.verticalGradient(
                            colors = listOf(
                                LitterTheme.background.copy(alpha = 0.7f),
                                androidx.compose.ui.graphics.Color.Transparent,
                            ),
                        ),
                    ),
            )
        }

        // Full-screen search overlay (mirrors iOS) — search bar pinned at top
        // with a close affordance; results fill the rest of the screen on an
        // opaque background. Replaces the prior inline-in-bottom-chrome layout.
        if (isSearchExpanded) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .background(LitterTheme.background)
                    .statusBarsPadding()
                    .imePadding(),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(modifier = Modifier.weight(1f)) {
                        ThreadSearchBar(
                            query = searchQuery,
                            isExpanded = true,
                            onQueryChange = { searchQuery = it },
                            onExpandChange = { expanded ->
                                isSearchExpanded = expanded
                                if (!expanded) searchQuery = ""
                            },
                        )
                    }
                    androidx.compose.material3.IconButton(
                        onClick = {
                            isSearchExpanded = false
                            searchQuery = ""
                        },
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            imageVector = androidx.compose.material.icons.Icons.Default.Close,
                            contentDescription = "Close search",
                            tint = LitterTheme.textSecondary,
                        )
                    }
                }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .padding(horizontal = 12.dp),
                ) {
                    ThreadSearchResults(
                        sessions = allSessions,
                        pinnedKeys = pinnedKeys.toSet(),
                        query = searchQuery,
                        onPin = { session ->
                            val key = PinnedThreadKey(
                                serverId = session.key.serverId,
                                threadId = session.key.threadId,
                            )
                            SavedThreadsStore.add(context, key)
                            pinnedKeys = SavedThreadsStore.pinnedKeys(context)
                        },
                        onUnpin = { session ->
                            val key = PinnedThreadKey(
                                serverId = session.key.serverId,
                                threadId = session.key.threadId,
                            )
                            SavedThreadsStore.remove(context, key)
                            pinnedKeys = SavedThreadsStore.pinnedKeys(context)
                        },
                    )
                }
            }
        }

        // Bottom chrome: collapsed by default into two icon buttons
        // (`+` and search); each expands its corresponding row inline when
        // tapped. Mirrors iOS `HomeBottomBar` collapsed/composer/search modes.
        // Scrim fades from transparent to translucent background so the list
        // visibly scrolls behind the chrome (matches iOS translucent bar).
        // Hidden entirely while the full-screen search overlay is open.
        if (!isSearchExpanded) Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .imePadding(),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(32.dp)
                    .background(
                        androidx.compose.ui.graphics.Brush.verticalGradient(
                            colors = listOf(
                                androidx.compose.ui.graphics.Color.Transparent,
                                LitterTheme.background.copy(alpha = 0.4f),
                            ),
                        ),
                    ),
            )
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(LitterTheme.background.copy(alpha = 0.4f)),
            ) {
                when {
                    // Full-screen search overlay above handles the search UI;
                    // suppress the bottom chrome entirely while it's open so
                    // there isn't a duplicate search bar at the bottom.
                    isSearchExpanded -> {}
                    isComposerActive -> {
                        // Model + project chips sit above the composer input,
                        // mirroring iOS `HomeDashboardView.swift:273-288`. The
                        // model chip opens a bottom sheet with model/effort
                        // selection; the project chip opens the project
                        // picker.
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 14.dp, vertical = 4.dp),
                            horizontalArrangement = Arrangement.spacedBy(
                                8.dp,
                                Alignment.End,
                            ),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            val serverForModels = selectedProject?.serverId
                                ?: selectedServerId
                            HomeModelChip(
                                serverId = serverForModels,
                                disabled = serverForModels.isNullOrBlank(),
                                onSheetStateChange = { open ->
                                    suppressComposerCollapse = open
                                },
                            )
                            ProjectChip(
                                project = selectedProject,
                                disabled = servers.isEmpty(),
                                onTap = {
                                    // Hold the composer open through the
                                    // project-picker navigation so the user
                                    // returns to an expanded composer. The
                                    // flag self-resets after a short delay.
                                    suppressComposerCollapse = true
                                    onOpenProjectPicker()
                                },
                            )
                        }
                        // Drop the collapse suppression a moment after the
                        // last chip interaction, once any transient focus
                        // churn has settled.
                        LaunchedEffect(suppressComposerCollapse) {
                            if (suppressComposerCollapse) {
                                kotlinx.coroutines.delay(1500)
                                suppressComposerCollapse = false
                            }
                        }
                        HomeComposerBar(
                            project = selectedProject,
                            onThreadCreated = onThreadCreated,
                            onActiveChange = { active ->
                                if (active) {
                                    isComposerActive = true
                                } else if (!suppressComposerCollapse) {
                                    isComposerActive = false
                                }
                            },
                        )
                    }
                    else -> {
                        // Collapsed: realtime voice pill on the left, + and search
                        // pills on the right. All three share the same 44dp
                        // circular glass style; only the mic pill's icon tint
                        // reflects live voice state.
                        val realtimeAvailable = remember {
                            ExperimentalFeatures.isEnabled(LitterFeature.REALTIME_VOICE)
                        }
                        val voicePhase = snapshot?.voiceSession?.phase
                        val voiceIconTint = when (voicePhase) {
                            uniffi.codex_mobile_client.AppVoiceSessionPhase.CONNECTING,
                            uniffi.codex_mobile_client.AppVoiceSessionPhase.LISTENING,
                            -> LitterTheme.accent
                            uniffi.codex_mobile_client.AppVoiceSessionPhase.SPEAKING,
                            uniffi.codex_mobile_client.AppVoiceSessionPhase.THINKING,
                            uniffi.codex_mobile_client.AppVoiceSessionPhase.HANDOFF,
                            -> LitterTheme.warning
                            uniffi.codex_mobile_client.AppVoiceSessionPhase.ERROR -> LitterTheme.danger
                            null -> LitterTheme.textSecondary
                        }

                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(start = 14.dp, end = 14.dp, top = 6.dp, bottom = 20.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (realtimeAvailable && onStartVoice != null) {
                                androidx.compose.material3.IconButton(
                                    onClick = { onStartVoice() },
                                    modifier = Modifier
                                        .size(44.dp)
                                        .background(
                                            LitterTheme.surface.copy(alpha = 0.9f),
                                            CircleShape,
                                        ),
                                ) {
                                    Icon(
                                        imageVector = androidx.compose.material.icons.Icons.Default.Mic,
                                        contentDescription = "Start realtime voice",
                                        tint = voiceIconTint,
                                        modifier = Modifier.size(20.dp),
                                    )
                                }
                            }
                            Spacer(Modifier.weight(1f))
                            androidx.compose.material3.IconButton(
                                onClick = { isComposerActive = true },
                                modifier = Modifier
                                    .size(44.dp)
                                    .background(
                                        LitterTheme.surface.copy(alpha = 0.9f),
                                        CircleShape,
                                    ),
                            ) {
                                Icon(
                                    imageVector = androidx.compose.material.icons.Icons.Default.Add,
                                    contentDescription = "New message",
                                    tint = LitterTheme.textPrimary,
                                    modifier = Modifier.size(22.dp),
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                            androidx.compose.material3.IconButton(
                                onClick = { isSearchExpanded = true },
                                modifier = Modifier
                                    .size(44.dp)
                                    .background(
                                        LitterTheme.surface.copy(alpha = 0.9f),
                                        CircleShape,
                                    ),
                            ) {
                                Icon(
                                    imageVector = androidx.compose.material.icons.Icons.Outlined.Search,
                                    contentDescription = "Search threads",
                                    tint = LitterTheme.textSecondary,
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        }
                    }
                }
            }
        }

    }

    confirmAction?.let { action ->
        AlertDialog(
            onDismissRequest = { confirmAction = null },
            title = { Text(action.title) },
            text = { Text(action.message) },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        when (action) {
                            is ConfirmAction.ArchiveSession -> {
                                voiceController.stopVoiceSessionIfActive(appModel, action.session.key)
                                voiceController.clearPinnedLocalVoiceThreadIfMatches(appModel, action.session.key)
                                if (appModel.snapshot.value?.activeThread == action.session.key) {
                                    appModel.store.setActiveThread(null)
                                }
                                try {
                                    appModel.client.archiveThread(
                                        action.session.key.serverId,
                                        uniffi.codex_mobile_client.AppArchiveThreadRequest(
                                            threadId = action.session.key.threadId,
                                        ),
                                    )
                                } catch (_: Exception) {}
                                kotlinx.coroutines.delay(400L)
                                appModel.refreshSnapshot()
                            }
                            is ConfirmAction.DisconnectServer -> {
                                SavedServerStore.remove(context, action.server.serverId)
                                appModel.sshSessionStore.close(action.server.serverId)
                                appModel.serverBridge.disconnectServer(action.server.serverId)
                                appModel.refreshSnapshot()
                            }
                            is ConfirmAction.ReplyError -> {
                                // Informational dialog only — "Confirm" just dismisses.
                            }
                        }
                    }
                    confirmAction = null
                }) {
                    Text("Confirm", color = LitterTheme.danger)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmAction = null }) {
                    Text("Cancel")
                }
            },
        )
    }
    renameTarget?.let { server ->
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            title = { Text("Rename Server") },
            text = {
                OutlinedTextField(
                    value = renameText,
                    onValueChange = { renameText = it },
                    label = { Text("Name") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    val trimmed = renameText.trim()
                    if (trimmed.isEmpty()) return@TextButton
                    scope.launch {
                        SavedServerStore.rename(context, server.serverId, trimmed)
                        appModel.refreshSnapshot()
                    }
                    renameTarget = null
                }) {
                    Text("Save")
                }
            },
            dismissButton = {
                TextButton(onClick = { renameTarget = null }) {
                    Text("Cancel")
                }
            },
        )
    }
    if (showTipJar) {
        ModalBottomSheet(
            onDismissRequest = { showTipJar = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = LitterTheme.background,
        ) {
            com.litter.android.ui.settings.TipJarScreen(onBack = { showTipJar = false })
        }
    }
}

/**
 * Merge rule: pinned threads first (preserving pin order — newest-pinned at
 * top), then fill from recent sessions (dedup) to reach 10 total. If the
 * user has pinned more than 10 we show every pin and skip the fill.
 */
private fun mergeHomeSessions(
    pinned: List<PinnedThreadKey>,
    hidden: List<PinnedThreadKey>,
    allSessions: List<AppSessionSummary>,
): List<AppSessionSummary> {
    val hiddenSet = hidden.toSet()
    val candidates = allSessions.filter {
        PinnedThreadKey(serverId = it.key.serverId, threadId = it.key.threadId) !in hiddenSet
    }
    val byKey = candidates.associateBy {
        PinnedThreadKey(serverId = it.key.serverId, threadId = it.key.threadId)
    }
    val pinnedSessions = pinned.mapNotNull { byKey[it] }
    if (pinnedSessions.size >= 10) return pinnedSessions

    val pinnedSet = pinned.toSet()
    val fill = candidates
        .asSequence()
        .filter {
            PinnedThreadKey(serverId = it.key.serverId, threadId = it.key.threadId) !in pinnedSet
        }
        .take(10 - pinnedSessions.size)
        .toList()
    return pinnedSessions + fill
}

private sealed class ConfirmAction {
    abstract val title: String
    abstract val message: String

    data class ArchiveSession(val session: AppSessionSummary) : ConfirmAction() {
        override val title = "Delete Session"
        override val message = "Are you sure you want to delete this session?"
    }

    data class DisconnectServer(val server: AppServerSnapshot) : ConfirmAction() {
        override val title = "Disconnect Server"
        override val message = "Disconnect from ${server.displayName}?"
    }

    data class ReplyError(val reason: String) : ConfirmAction() {
        override val title = "Reply Failed"
        override val message = reason
    }
}
