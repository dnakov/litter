package com.litter.android.ui

import android.graphics.Typeface
import android.text.format.DateUtils
import android.widget.TextView
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.litter.android.core.network.DiscoverySource
import com.litter.android.state.AccountState
import com.litter.android.state.AuthStatus
import com.litter.android.state.ChatMessage
import com.litter.android.state.MessageRole
import com.litter.android.state.ModelOption
import com.litter.android.state.ServerConfig
import com.litter.android.state.ServerConnectionStatus
import com.litter.android.state.ServerSource
import com.litter.android.state.ThreadKey
import com.litter.android.state.ThreadState
import io.noties.markwon.Markwon

@Composable
fun LitterAppShell(appState: LitterAppState) {
    val uiState by appState.uiState.collectAsStateWithLifecycle()
    val drawerWidth = 304.dp
    val drawerOffset by
        animateDpAsState(
            targetValue = if (uiState.isSidebarOpen) 0.dp else -drawerWidth,
            animationSpec = tween(durationMillis = 220),
            label = "sidebar_offset",
        )

    Box(modifier = Modifier.fillMaxSize().background(LitterTheme.backgroundBrush)) {
        Column(
            modifier = Modifier.fillMaxSize().statusBarsPadding(),
        ) {
            HeaderBar(
                models = uiState.models,
                selectedModelId = uiState.selectedModelId,
                selectedReasoningEffort = uiState.selectedReasoningEffort,
                connectionStatus = uiState.connectionStatus,
                onToggleSidebar = appState::toggleSidebar,
                onSelectModel = appState::selectModel,
                onSelectReasoningEffort = appState::selectReasoningEffort,
            )

            if (uiState.activeThreadKey == null) {
                EmptyState()
            } else {
                ConversationPanel(
                    messages = uiState.messages,
                    draft = uiState.draft,
                    isSending = uiState.isSending,
                    onDraftChange = appState::updateDraft,
                    onSend = appState::sendDraft,
                    onInterrupt = appState::interrupt,
                )
            }
        }

        if (uiState.isSidebarOpen) {
            Box(
                modifier =
                    Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.5f))
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = appState::dismissSidebar,
                        ),
            )
        }

        SessionSidebar(
            modifier =
                Modifier
                    .fillMaxHeight()
                    .width(drawerWidth)
                    .offset(x = drawerOffset),
            connectionStatus = uiState.connectionStatus,
            serverCount = uiState.serverCount,
            sessions = uiState.sessions,
            activeThreadKey = uiState.activeThreadKey,
            onSessionSelected = appState::selectSession,
            onNewSession = appState::openNewSessionPicker,
            onRefresh = appState::refreshSessions,
            onOpenDiscovery = {
                appState.dismissSidebar()
                appState.openDiscovery()
            },
            onOpenSettings = {
                appState.dismissSidebar()
                appState.openSettings()
            },
        )

        if (uiState.directoryPicker.isVisible) {
            DirectoryPickerSheet(
                path = uiState.directoryPicker.currentPath,
                entries = uiState.directoryPicker.entries,
                isLoading = uiState.directoryPicker.isLoading,
                error = uiState.directoryPicker.errorMessage,
                onDismiss = appState::dismissDirectoryPicker,
                onNavigateUp = appState::navigateDirectoryUp,
                onNavigateInto = appState::navigateDirectoryInto,
                onSelect = appState::confirmStartSessionFromPicker,
            )
        }

        if (uiState.discovery.isVisible) {
            DiscoverySheet(
                state = uiState.discovery,
                onDismiss = appState::dismissDiscovery,
                onRefresh = appState::refreshDiscovery,
                onConnectDiscovered = appState::connectDiscoveredServer,
                onManualHostChanged = appState::updateManualHost,
                onManualPortChanged = appState::updateManualPort,
                onConnectManual = appState::connectManualServer,
            )
        }

        if (uiState.showSettings) {
            SettingsSheet(
                accountState = uiState.accountState,
                connectedServers = uiState.connectedServers,
                onDismiss = appState::dismissSettings,
                onOpenAccount = appState::openAccount,
                onOpenDiscovery = appState::openDiscovery,
                onRemoveServer = appState::removeServer,
            )
        }

        if (uiState.showAccount) {
            AccountSheet(
                accountState = uiState.accountState,
                apiKeyDraft = uiState.apiKeyDraft,
                isWorking = uiState.isAuthWorking,
                onDismiss = appState::dismissAccount,
                onApiKeyDraftChanged = appState::updateApiKeyDraft,
                onLoginWithChatGpt = appState::loginWithChatGpt,
                onLoginWithApiKey = appState::loginWithApiKey,
                onLogout = appState::logoutAccount,
                onCancelLogin = appState::cancelLogin,
            )
        }

        if (uiState.uiError != null) {
            AlertDialog(
                onDismissRequest = appState::clearUiError,
                title = { Text("Error") },
                text = { Text(uiState.uiError ?: "Unknown error") },
                confirmButton = {
                    TextButton(onClick = appState::clearUiError) {
                        Text("OK")
                    }
                },
            )
        }
    }
}

@Composable
private fun HeaderBar(
    models: List<ModelOption>,
    selectedModelId: String?,
    selectedReasoningEffort: String?,
    connectionStatus: ServerConnectionStatus,
    onToggleSidebar: () -> Unit,
    onSelectModel: (String) -> Unit,
    onSelectReasoningEffort: (String) -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = Color(0xFF0D0D0D),
        tonalElevation = 0.dp,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            IconButton(onClick = onToggleSidebar) {
                Icon(Icons.Default.Menu, contentDescription = "Toggle sidebar", tint = LitterTheme.textSecondary)
            }

            ModelSelector(
                models = models,
                selectedModelId = selectedModelId,
                selectedReasoningEffort = selectedReasoningEffort,
                onSelectModel = onSelectModel,
                onSelectReasoningEffort = onSelectReasoningEffort,
            )

            Spacer(modifier = Modifier.weight(1f))

            StatusDot(connectionStatus = connectionStatus)
        }
    }
}

@Composable
private fun ModelSelector(
    models: List<ModelOption>,
    selectedModelId: String?,
    selectedReasoningEffort: String?,
    onSelectModel: (String) -> Unit,
    onSelectReasoningEffort: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val selectedModel = models.firstOrNull { it.id == selectedModelId } ?: models.firstOrNull()
    val shortModel =
        (selectedModel?.id ?: "")
            .replace("gpt-", "")
            .replace("-codex", "")
            .ifBlank { "litter" }

    Box {
        OutlinedButton(
            onClick = { expanded = true },
            border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
            shape = RoundedCornerShape(22.dp),
        ) {
            Text(shortModel, color = LitterTheme.textPrimary)
            Icon(
                imageVector = Icons.Default.ArrowDropDown,
                contentDescription = "Select model",
                modifier = Modifier.size(16.dp),
                tint = LitterTheme.textSecondary,
            )
        }

        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            models.forEach { model ->
                DropdownMenuItem(
                    text = {
                        Text(
                            if (model.isDefault) "${model.displayName} (default)" else model.displayName,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                    onClick = {
                        onSelectModel(model.id)
                        if (model.defaultReasoningEffort != null) {
                            onSelectReasoningEffort(model.defaultReasoningEffort)
                        }
                        expanded = false
                    },
                )
            }

            val efforts = selectedModel?.supportedReasoningEfforts.orEmpty()
            if (efforts.isNotEmpty()) {
                DropdownMenuItem(
                    text = { Text("Reasoning", color = LitterTheme.textSecondary) },
                    onClick = {},
                    enabled = false,
                )
                efforts.forEach { effort ->
                    DropdownMenuItem(
                        text = {
                            val label =
                                if (effort.effort == selectedReasoningEffort) {
                                    "* ${effort.effort}"
                                } else {
                                    effort.effort
                                }
                            Text(label)
                        },
                        onClick = {
                            onSelectReasoningEffort(effort.effort)
                            expanded = false
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun StatusDot(connectionStatus: ServerConnectionStatus) {
    val color =
        when (connectionStatus) {
            ServerConnectionStatus.CONNECTING -> Color(0xFFE2A644)
            ServerConnectionStatus.READY -> LitterTheme.accent
            ServerConnectionStatus.ERROR -> Color(0xFFFF5C5C)
            ServerConnectionStatus.DISCONNECTED -> LitterTheme.textMuted
        }
    Box(
        modifier =
            Modifier
                .size(9.dp)
                .clip(CircleShape)
                .background(color),
    )
}

@Composable
private fun EmptyState() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "Start a new session",
            style = MaterialTheme.typography.bodyMedium,
            color = LitterTheme.textMuted,
        )
    }
}

@Composable
private fun SessionSidebar(
    modifier: Modifier,
    connectionStatus: ServerConnectionStatus,
    serverCount: Int,
    sessions: List<ThreadState>,
    activeThreadKey: ThreadKey?,
    onSessionSelected: (ThreadKey) -> Unit,
    onNewSession: () -> Unit,
    onRefresh: () -> Unit,
    onOpenDiscovery: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    Surface(
        modifier = modifier,
        color = Color(0xFF0E0E0E),
        border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
    ) {
        Column(
            modifier = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Button(
                onClick = onNewSession,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(8.dp),
            ) {
                Text("New Session")
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text =
                        if (connectionStatus == ServerConnectionStatus.READY) {
                            "$serverCount server${if (serverCount == 1) "" else "s"}"
                        } else {
                            "Not connected"
                        },
                    color = LitterTheme.textSecondary,
                    style = MaterialTheme.typography.labelLarge,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton(onClick = onOpenDiscovery) {
                        Text(if (connectionStatus == ServerConnectionStatus.READY) "Add" else "Connect")
                    }
                    TextButton(onClick = onRefresh) {
                        Text("Refresh")
                    }
                }
            }

            if (sessions.isEmpty()) {
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    text = "No sessions yet",
                    color = LitterTheme.textMuted,
                    modifier = Modifier.align(Alignment.CenterHorizontally),
                )
                Spacer(modifier = Modifier.weight(1f))
            } else {
                LazyColumn(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(items = sessions, key = { "${it.key.serverId}:${it.key.threadId}" }) { thread ->
                        val isActive = thread.key == activeThreadKey
                        Surface(
                            modifier = Modifier.fillMaxWidth().clickable { onSessionSelected(thread.key) },
                            color = if (isActive) Color(0xFF1A1A1A) else Color(0xFF131313),
                            shape = RoundedCornerShape(8.dp),
                            border =
                                androidx.compose.foundation.BorderStroke(
                                    1.dp,
                                    if (isActive) LitterTheme.accent else LitterTheme.border,
                                ),
                        ) {
                            Column(
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 9.dp),
                                verticalArrangement = Arrangement.spacedBy(4.dp),
                            ) {
                                Text(
                                    text = thread.preview.ifBlank { "Untitled session" },
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis,
                                    color = LitterTheme.textPrimary,
                                    style = MaterialTheme.typography.bodyMedium,
                                )
                                Text(
                                    text = "${relativeDate(thread.updatedAtEpochMillis)} * ${thread.cwd.ifBlank { "/" }}",
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    color = LitterTheme.textSecondary,
                                    style = MaterialTheme.typography.labelLarge,
                                )
                            }
                        }
                    }
                }
            }

            TextButton(
                onClick = onOpenSettings,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Settings", color = LitterTheme.textSecondary)
            }
        }
    }
}

@Composable
private fun ConversationPanel(
    messages: List<ChatMessage>,
    draft: String,
    isSending: Boolean,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onInterrupt: () -> Unit,
) {
    val listState = rememberLazyListState()

    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.lastIndex)
        }
    }

    Column(
        modifier = Modifier.fillMaxSize().imePadding(),
    ) {
        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
        ) {
            items(items = messages, key = { it.id }) { message ->
                MessageRow(message)
            }
        }

        InputBar(
            draft = draft,
            isSending = isSending,
            onDraftChange = onDraftChange,
            onSend = onSend,
            onInterrupt = onInterrupt,
        )
    }
}

@Composable
private fun MessageRow(message: ChatMessage) {
    when (message.role) {
        MessageRole.USER -> {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                Surface(
                    shape = RoundedCornerShape(14.dp),
                    color = Color(0xFF2A2A2A),
                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                ) {
                    Text(
                        text = message.text,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                        color = LitterTheme.textPrimary,
                    )
                }
            }
        }

        MessageRole.ASSISTANT -> {
            AssistantMarkdown(
                markdown = message.text,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp),
            )
        }

        MessageRole.SYSTEM -> {
            Surface(
                shape = RoundedCornerShape(10.dp),
                color = Color(0xFF171717),
                border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                modifier = Modifier.fillMaxWidth(),
            ) {
                AssistantMarkdown(
                    markdown = message.text,
                    modifier = Modifier.fillMaxWidth().padding(10.dp),
                )
            }
        }

        MessageRole.REASONING -> {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(
                    imageVector = Icons.Default.Psychology,
                    contentDescription = null,
                    tint = LitterTheme.textSecondary,
                    modifier = Modifier.size(16.dp).padding(top = 2.dp),
                )
                Text(
                    text = message.text,
                    color = LitterTheme.textSecondary,
                    fontStyle = FontStyle.Italic,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }
}

@Composable
private fun AssistantMarkdown(
    markdown: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val markwon = remember(context) { Markwon.create(context) }

    AndroidView(
        modifier = modifier,
        factory = {
            TextView(it).apply {
                typeface = Typeface.MONOSPACE
                textSize = 14f
                setTextColor(android.graphics.Color.parseColor("#E0E0E0"))
                setLineSpacing(0f, 1.2f)
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
            }
        },
        update = { markwon.setMarkdown(it, markdown) },
    )
}

@Composable
private fun InputBar(
    draft: String,
    isSending: Boolean,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
    onInterrupt: () -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxWidth().navigationBarsPadding(),
        color = Color(0xFF0D0D0D),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(
                value = draft,
                onValueChange = onDraftChange,
                modifier = Modifier.weight(1f),
                placeholder = { Text("Message litter...") },
                minLines = 1,
                maxLines = 5,
            )

            Button(onClick = onSend, enabled = draft.isNotBlank() && !isSending) {
                Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send", modifier = Modifier.size(16.dp))
            }

            OutlinedButton(onClick = onInterrupt, enabled = isSending) {
                Icon(Icons.Default.Stop, contentDescription = "Interrupt", modifier = Modifier.size(16.dp))
            }
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun DirectoryPickerSheet(
    path: String,
    entries: List<String>,
    isLoading: Boolean,
    error: String?,
    onDismiss: () -> Unit,
    onNavigateUp: () -> Unit,
    onNavigateInto: (String) -> Unit,
    onSelect: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Choose Directory", style = MaterialTheme.typography.titleMedium)
            Text(path.ifBlank { "/" }, color = LitterTheme.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onNavigateUp) {
                    Icon(Icons.Default.ArrowUpward, contentDescription = null, modifier = Modifier.size(14.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("Up")
                }
                Button(onClick = onSelect) {
                    Text("Select")
                }
                TextButton(onClick = onDismiss) {
                    Icon(Icons.Default.Close, contentDescription = null, modifier = Modifier.size(14.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("Cancel")
                }
            }

            when {
                isLoading -> {
                    Text("Loading...", color = LitterTheme.textMuted)
                }

                error != null -> {
                    Text(error, color = Color(0xFFFF7A7A))
                }

                entries.isEmpty() -> {
                    Text("No subdirectories", color = LitterTheme.textMuted)
                }

                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxWidth().fillMaxHeight(0.55f),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        items(entries, key = { it }) { entry ->
                            Surface(
                                modifier = Modifier.fillMaxWidth().clickable { onNavigateInto(entry) },
                                color = Color(0xFF131313),
                                shape = RoundedCornerShape(8.dp),
                                border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    Icon(Icons.Default.Folder, contentDescription = null, tint = LitterTheme.textSecondary)
                                    Text(entry, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun DiscoverySheet(
    state: DiscoveryUiState,
    onDismiss: () -> Unit,
    onRefresh: () -> Unit,
    onConnectDiscovered: (String) -> Unit,
    onManualHostChanged: (String) -> Unit,
    onManualPortChanged: (String) -> Unit,
    onConnectManual: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("Connect Server", style = MaterialTheme.typography.titleMedium)
                TextButton(onClick = onRefresh) {
                    Text("Refresh")
                }
            }

            if (state.isLoading) {
                Text("Scanning local network and tailscale...", color = LitterTheme.textSecondary)
            }

            if (state.errorMessage != null) {
                Text(state.errorMessage, color = Color(0xFFFF7A7A))
            }

            if (state.servers.isEmpty() && !state.isLoading) {
                Text("No servers discovered", color = LitterTheme.textMuted)
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxWidth().fillMaxHeight(0.4f),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    items(state.servers, key = { it.id }) { server ->
                        Surface(
                            modifier = Modifier.fillMaxWidth().clickable { onConnectDiscovered(server.id) },
                            color = Color(0xFF131313),
                            shape = RoundedCornerShape(8.dp),
                            border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                        ) {
                            Column(
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
                                verticalArrangement = Arrangement.spacedBy(3.dp),
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text(
                                        server.name,
                                        color = LitterTheme.textPrimary,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    Text(
                                        discoverySourceLabel(server.source),
                                        style = MaterialTheme.typography.labelLarge,
                                        color = LitterTheme.textSecondary,
                                    )
                                }
                                Text(
                                    "${server.host}:${server.port}",
                                    color = LitterTheme.textSecondary,
                                    style = MaterialTheme.typography.labelLarge,
                                )
                                Text(
                                    if (server.hasCodexServer) "codex running" else "ssh only",
                                    style = MaterialTheme.typography.labelLarge,
                                    color = if (server.hasCodexServer) LitterTheme.accent else LitterTheme.textMuted,
                                )
                            }
                        }
                    }
                }
            }

            Text("Manual", style = MaterialTheme.typography.titleMedium)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    value = state.manualHost,
                    onValueChange = onManualHostChanged,
                    label = { Text("Host") },
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                )
                OutlinedTextField(
                    value = state.manualPort,
                    onValueChange = onManualPortChanged,
                    label = { Text("Port") },
                    modifier = Modifier.width(110.dp),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                )
            }

            Button(
                onClick = onConnectManual,
                modifier = Modifier.fillMaxWidth(),
                enabled = state.manualHost.isNotBlank() && state.manualPort.isNotBlank(),
            ) {
                Text("Connect Manual Server")
            }
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun SettingsSheet(
    accountState: AccountState,
    connectedServers: List<ServerConfig>,
    onDismiss: () -> Unit,
    onOpenAccount: () -> Unit,
    onOpenDiscovery: () -> Unit,
    onRemoveServer: (String) -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Settings", style = MaterialTheme.typography.titleMedium)

            Text("Authentication", color = LitterTheme.textSecondary, style = MaterialTheme.typography.labelLarge)
            Surface(
                modifier = Modifier.fillMaxWidth().clickable { onOpenAccount() },
                color = Color(0xFF131313),
                shape = RoundedCornerShape(8.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Account", color = LitterTheme.textPrimary)
                        Text(accountState.summaryTitle, color = LitterTheme.textSecondary, style = MaterialTheme.typography.labelLarge)
                    }
                    Text("Open", color = LitterTheme.accent, style = MaterialTheme.typography.labelLarge)
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("Servers", color = LitterTheme.textSecondary, style = MaterialTheme.typography.labelLarge)
                TextButton(onClick = onOpenDiscovery) {
                    Text("Add Server")
                }
            }

            if (connectedServers.isEmpty()) {
                Text("No servers connected", color = LitterTheme.textMuted)
            } else {
                connectedServers.forEach { server ->
                    Surface(
                        modifier = Modifier.fillMaxWidth(),
                        color = Color(0xFF131313),
                        shape = RoundedCornerShape(8.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(server.name, color = LitterTheme.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(
                                    "${server.host}:${server.port} * ${serverSourceLabel(server.source)}",
                                    color = LitterTheme.textSecondary,
                                    style = MaterialTheme.typography.labelLarge,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            TextButton(onClick = { onRemoveServer(server.id) }) {
                                Text("Remove", color = Color(0xFFFF7A7A))
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun AccountSheet(
    accountState: AccountState,
    apiKeyDraft: String,
    isWorking: Boolean,
    onDismiss: () -> Unit,
    onApiKeyDraftChanged: (String) -> Unit,
    onLoginWithChatGpt: () -> Unit,
    onLoginWithApiKey: () -> Unit,
    onLogout: () -> Unit,
    onCancelLogin: () -> Unit,
) {
    val uriHandler = LocalUriHandler.current

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Account", style = MaterialTheme.typography.titleMedium)

            Surface(
                modifier = Modifier.fillMaxWidth(),
                color = Color(0xFF131313),
                shape = RoundedCornerShape(8.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Box(
                        modifier =
                            Modifier
                                .size(10.dp)
                                .clip(CircleShape)
                                .background(accountStatusColor(accountState.status)),
                    )
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(accountState.summaryTitle, color = LitterTheme.textPrimary)
                        val subtitle = accountState.summarySubtitle
                        if (subtitle != null) {
                            Text(subtitle, color = LitterTheme.textSecondary, style = MaterialTheme.typography.labelLarge)
                        }
                    }
                    if (accountState.status == AuthStatus.API_KEY || accountState.status == AuthStatus.CHATGPT) {
                        TextButton(onClick = onLogout, enabled = !isWorking) {
                            Text("Logout", color = Color(0xFFFF7A7A))
                        }
                    }
                }
            }

            Button(
                onClick = onLoginWithChatGpt,
                modifier = Modifier.fillMaxWidth(),
                enabled = !isWorking,
            ) {
                Text(if (isWorking) "Working..." else "Login with ChatGPT")
            }

            if (accountState.oauthUrl != null) {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = Color(0xFF131313),
                    shape = RoundedCornerShape(8.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                ) {
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 10.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text("Finish login in browser", color = LitterTheme.textSecondary)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { uriHandler.openUri(accountState.oauthUrl) }) {
                                Text("Open Browser")
                            }
                            TextButton(onClick = onCancelLogin) {
                                Text("Cancel", color = Color(0xFFFF7A7A))
                            }
                        }
                    }
                }
            }

            OutlinedTextField(
                value = apiKeyDraft,
                onValueChange = onApiKeyDraftChanged,
                modifier = Modifier.fillMaxWidth(),
                label = { Text("API Key") },
                placeholder = { Text("sk-...") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                singleLine = true,
            )

            OutlinedButton(
                onClick = onLoginWithApiKey,
                modifier = Modifier.fillMaxWidth(),
                enabled = apiKeyDraft.isNotBlank() && !isWorking,
            ) {
                Text("Save API Key")
            }

            if (accountState.lastError != null) {
                Text(accountState.lastError, color = Color(0xFFFF7A7A), style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}

private fun relativeDate(timestamp: Long): String {
    return DateUtils.getRelativeTimeSpanString(
        timestamp,
        System.currentTimeMillis(),
        DateUtils.MINUTE_IN_MILLIS,
        DateUtils.FORMAT_ABBREV_RELATIVE,
    ).toString()
}

private fun accountStatusColor(status: AuthStatus): Color =
    when (status) {
        AuthStatus.CHATGPT -> LitterTheme.accent
        AuthStatus.API_KEY -> Color(0xFF00AAFF)
        AuthStatus.NOT_LOGGED_IN -> LitterTheme.textMuted
        AuthStatus.UNKNOWN -> LitterTheme.textMuted
    }

private fun serverSourceLabel(source: ServerSource): String =
    when (source) {
        ServerSource.LOCAL -> "local"
        ServerSource.BONJOUR -> "bonjour"
        ServerSource.SSH -> "ssh"
        ServerSource.TAILSCALE -> "tailscale"
        ServerSource.MANUAL -> "manual"
        ServerSource.REMOTE -> "remote"
    }

private fun discoverySourceLabel(source: DiscoverySource): String =
    when (source) {
        DiscoverySource.LOCAL -> "local"
        DiscoverySource.BONJOUR -> "bonjour"
        DiscoverySource.SSH -> "ssh"
        DiscoverySource.TAILSCALE -> "tailscale"
        DiscoverySource.MANUAL -> "manual"
        DiscoverySource.LAN -> "lan"
    }
