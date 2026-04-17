package com.litter.android.ui.home

import com.sigkitten.litter.android.BuildConfig
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pets
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import com.sigkitten.litter.android.R
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.AppThreadLaunchConfig
import com.litter.android.state.AppLifecycleController
import com.litter.android.state.DebugSettings
import com.litter.android.state.SavedServerStore
import com.litter.android.state.connectionModeLabel
import com.litter.android.state.displayTitle
import com.litter.android.state.isConnected
import com.litter.android.state.isIpcConnected
import com.litter.android.state.statusColor
import com.litter.android.state.statusLabel
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.ExperimentalFeatures
import com.litter.android.ui.LitterFeature
import com.litter.android.ui.LitterTheme
import androidx.compose.ui.platform.LocalConfiguration
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.ThreadKey

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun HomeDashboardScreen(
    onOpenConversation: (ThreadKey) -> Unit,
    onOpenSessions: (serverId: String, title: String) -> Unit,
    onNewSession: () -> Unit,
    onShowDiscovery: () -> Unit,
    onShowSettings: () -> Unit,
    onStartVoice: (() -> Unit)? = null,
) {
    val appModel = LocalAppModel.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    val voiceController = remember { com.litter.android.state.VoiceRuntimeController.shared }
    val lifecycleController = remember { AppLifecycleController() }

    var showTipJar by remember { mutableStateOf(false) }
    var renameTarget by remember { mutableStateOf<AppServerSnapshot?>(null) }
    var renameText by remember { mutableStateOf("") }
    val appVersionLabel = remember { "v${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})" }

    val screenHeightDp = LocalConfiguration.current.screenHeightDp
    val recentLimit = maxOf(3, (screenHeightDp - 300) / 82)

    val snap = snapshot
    val servers = remember(snap) {
        snap?.let { HomeDashboardSupport.sortedConnectedServers(it) } ?: emptyList()
    }
    val recentSessions = remember(snap, recentLimit) {
        snap?.let { HomeDashboardSupport.recentSessions(it, limit = recentLimit) } ?: emptyList()
    }

    // Confirmation dialog state
    var confirmAction by remember { mutableStateOf<ConfirmAction?>(null) }

    Box(modifier = Modifier.fillMaxSize()) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Header with logo and settings
        item {
            Spacer(Modifier.height(16.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Settings button (left)
                IconButton(onClick = onShowSettings, modifier = Modifier.size(32.dp)) {
                    Icon(
                        Icons.Default.Settings,
                        contentDescription = "Settings",
                        tint = LitterTheme.textSecondary,
                        modifier = Modifier.size(20.dp),
                    )
                }
                Spacer(Modifier.weight(1f))
                // Animated logo (center)
                com.litter.android.ui.AnimatedLogo(size = 64.dp)
                Spacer(Modifier.weight(1f))
                // Tip jar badge
                IconButton(onClick = { showTipJar = true }, modifier = Modifier.size(32.dp)) {
                    Icon(
                        Icons.Default.Pets,
                        contentDescription = "Tip the Kitty",
                        tint = LitterTheme.textMuted,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
            Spacer(Modifier.height(16.dp))
        }

        // Action buttons
        item {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Button(
                    onClick = onNewSession,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = LitterTheme.accent,
                        contentColor = Color.Black,
                    ),
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("New Session")
                }
                Button(
                    onClick = onShowDiscovery,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = LitterTheme.surface,
                        contentColor = LitterTheme.textPrimary,
                    ),
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Default.Dns, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Connect Server")
                }
            }
        }

        // Recent sessions section
        if (recentSessions.isNotEmpty()) {
            item {
                Spacer(Modifier.height(8.dp))
                Text(
                    text = "Recent Sessions",
                    color = LitterTheme.textSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                )
            }
            items(recentSessions, key = { "${it.key.serverId}/${it.key.threadId}" }) { session ->
                SessionCard(
                    session = session,
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

        // Connected servers section
        if (servers.isNotEmpty()) {
            item {
                Spacer(Modifier.height(8.dp))
                Text(
                    text = "Servers",
                    color = LitterTheme.textSecondary,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                )
            }
            items(servers, key = { it.serverId }) { server ->
                ServerCard(
                    server = server,
                    onClick = { onOpenSessions(server.serverId, server.displayName) },
                    onReconnect = {
                        scope.launch {
                            lifecycleController.reconnectServer(context, appModel, server.serverId)
                        }
                    },
                    onRename = {
                        renameText = server.displayName
                        renameTarget = server
                    },
                    onDisconnect = {
                        confirmAction = ConfirmAction.DisconnectServer(server)
                    },
                )
            }
        }

        // Empty state
        if (servers.isEmpty() && recentSessions.isEmpty()) {
            item {
                Spacer(Modifier.height(48.dp))
                Text(
                    text = "No servers connected",
                    color = LitterTheme.textSecondary,
                    fontSize = 14.sp,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        item { Spacer(Modifier.height(100.dp)) } // space for voice orb
    }

    // Voice orb FAB
    if (
        onStartVoice != null &&
            servers.isNotEmpty() &&
            ExperimentalFeatures.isEnabled(LitterFeature.REALTIME_VOICE)
    ) {
        val voiceController = remember { com.litter.android.state.VoiceRuntimeController.shared }
        val voiceSession by voiceController.activeVoiceSession.collectAsState()
        val snapshot by appModel.snapshot.collectAsState()
        val isActive = voiceSession != null
        val voicePhase = snapshot?.voiceSession?.phase

        val orbColor = when (voicePhase) {
            uniffi.codex_mobile_client.AppVoiceSessionPhase.CONNECTING,
            uniffi.codex_mobile_client.AppVoiceSessionPhase.LISTENING,
            -> LitterTheme.accentStrong
            uniffi.codex_mobile_client.AppVoiceSessionPhase.SPEAKING,
            uniffi.codex_mobile_client.AppVoiceSessionPhase.THINKING,
            uniffi.codex_mobile_client.AppVoiceSessionPhase.HANDOFF,
            -> LitterTheme.warning
            uniffi.codex_mobile_client.AppVoiceSessionPhase.ERROR -> LitterTheme.danger
            else -> LitterTheme.accentStrong
        }

        val inputLevel = voiceSession?.inputLevel ?: 0f
        val pulseScale by androidx.compose.animation.core.animateFloatAsState(
            targetValue = if (isActive) 1f + inputLevel * 0.12f else 1f,
            animationSpec = androidx.compose.animation.core.tween(durationMillis = 150),
            label = "orbPulse",
        )

        val buttonDiameter = if (isActive) 68.dp else 60.dp

        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 24.dp)
                .size(buttonDiameter * pulseScale)
                .clip(CircleShape)
                .background(
                    brush = androidx.compose.ui.graphics.Brush.verticalGradient(
                        colors = listOf(
                            orbColor.copy(alpha = 0.96f),
                            orbColor.copy(alpha = 0.58f),
                            LitterTheme.surface.copy(alpha = 0.92f),
                        ),
                    ),
                    shape = CircleShape,
                )
                .border(
                    width = 1.dp,
                    color = Color.White.copy(alpha = if (isActive) 0.24f else 0.14f),
                    shape = CircleShape,
                )
                .clickable(onClick = onStartVoice),
            contentAlignment = Alignment.Center,
        ) {
            when (voicePhase) {
                uniffi.codex_mobile_client.AppVoiceSessionPhase.CONNECTING -> {
                    CircularProgressIndicator(
                        modifier = Modifier.size(22.dp),
                        strokeWidth = 2.dp,
                        color = Color.White,
                    )
                }
                else -> {
                    Icon(
                        Icons.Default.Mic,
                        contentDescription = if (isActive) "Voice active" else "Start voice",
                        tint = Color.White,
                        modifier = Modifier.size(if (isActive) 24.dp else 22.dp),
                    )
                }
            }
        }
    }
        Text(
            text = appVersionLabel,
            color = if (DebugSettings.enabled) LitterTheme.accent.copy(alpha = 0.6f) else LitterTheme.textMuted.copy(alpha = 0.8f),
            fontSize = 11.sp,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 2.dp)
                .combinedClickable(
                    onClick = {},
                    onLongClick = {
                        DebugSettings.setEnabled(context, !DebugSettings.enabled)
                    },
                ),
        )
    } // close Box

    // Confirmation dialogs
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
                                // Wait for the ThreadArchived broadcast to be processed by the
                                // event loop before refreshing, otherwise the session still appears.
                                kotlinx.coroutines.delay(400L)
                                appModel.refreshSnapshot()
                            }
                            is ConfirmAction.DisconnectServer -> {
                                SavedServerStore.remove(context, action.server.serverId)
                                appModel.sshSessionStore.close(action.server.serverId)
                                appModel.serverBridge.disconnectServer(action.server.serverId)
                                appModel.refreshSnapshot()
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

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionCard(
    session: AppSessionSummary,
    onClick: () -> Unit,
    onDelete: () -> Unit,
) {
    var showMenu by remember { mutableStateOf(false) }

    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface, RoundedCornerShape(10.dp))
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = { showMenu = true },
                )
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Active turn indicator
            if (session.hasActiveTurn) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(LitterTheme.accent),
                )
                Spacer(Modifier.width(8.dp))
            }

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = session.displayTitle,
                    color = LitterTheme.textPrimary,
                    fontSize = 14.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        text = session.serverDisplayName,
                        color = LitterTheme.textSecondary,
                        fontSize = 11.sp,
                    )
                    session.cwd?.let { cwd ->
                        Text(
                            text = HomeDashboardSupport.workspaceLabel(cwd),
                            color = LitterTheme.textMuted,
                            fontSize = 11.sp,
                        )
                    }
                }
            }

            Column(horizontalAlignment = Alignment.End) {
                Text(
                    text = HomeDashboardSupport.relativeTime(session.updatedAt),
                    color = LitterTheme.textMuted,
                    fontSize = 11.sp,
                )
                if (session.hasActiveTurn) {
                    Text(
                        text = "Thinking",
                        color = LitterTheme.accent,
                        fontSize = 10.sp,
                    )
                }
            }

            Spacer(Modifier.width(4.dp))
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
                DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
                    DropdownMenuItem(
                        text = { Text("Delete") },
                        onClick = { showMenu = false; onDelete() },
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ServerCard(
    server: AppServerSnapshot,
    onClick: () -> Unit,
    onReconnect: () -> Unit,
    onRename: (() -> Unit)?,
    onDisconnect: () -> Unit,
) {
    var showMenu by remember { mutableStateOf(false) }

    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface, RoundedCornerShape(10.dp))
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = { showMenu = true },
                )
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(server.statusColor),
            )
            Spacer(Modifier.width(10.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = server.displayName,
                    color = LitterTheme.textPrimary,
                    fontSize = 14.sp,
                )
                Text(
                    text = "${server.host}:${server.port} · ${server.connectionModeLabel}",
                    color = LitterTheme.textSecondary,
                    fontSize = 11.sp,
                )
                Text(
                    text = HomeDashboardSupport.maskedAccountLabel(server),
                    color = LitterTheme.textMuted,
                    fontSize = 10.sp,
                )
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                if (server.isIpcConnected) {
                    Text(
                        text = "IPC",
                        color = LitterTheme.accentStrong,
                        fontSize = 10.sp,
                        modifier = Modifier
                            .background(
                                LitterTheme.accentStrong.copy(alpha = 0.14f),
                                RoundedCornerShape(4.dp),
                            )
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                }
                Text(
                    text = server.statusLabel,
                    color = server.statusColor,
                    fontSize = 11.sp,
                )
                Spacer(Modifier.width(4.dp))
                Box {
                    IconButton(
                        onClick = { showMenu = true },
                        modifier = Modifier.size(28.dp),
                    ) {
                        Icon(
                            Icons.Default.MoreVert,
                            contentDescription = "Server actions",
                            tint = LitterTheme.textSecondary,
                        )
                    }
                    DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
                        DropdownMenuItem(
                            text = { Text("Reconnect") },
                            onClick = {
                                showMenu = false
                                onReconnect()
                            },
                        )
                        if (!server.isLocal && onRename != null) {
                            DropdownMenuItem(
                                text = { Text("Rename") },
                                onClick = {
                                    showMenu = false
                                    onRename()
                                },
                            )
                        }
                        DropdownMenuItem(
                            text = { Text("Disconnect") },
                            onClick = {
                                showMenu = false
                                onDisconnect()
                            },
                        )
                    }
                }
            }
        }
    }
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
}
