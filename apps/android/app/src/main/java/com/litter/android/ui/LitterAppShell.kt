package com.litter.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Typeface
import android.net.Uri
import android.text.format.DateUtils
import android.util.Base64
import android.widget.TextView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.BackHandler
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.litter.android.core.network.DiscoverySource
import com.litter.android.state.AccountState
import com.litter.android.state.AuthStatus
import com.litter.android.state.ChatMessage
import com.litter.android.state.ExperimentalFeature
import com.litter.android.state.FuzzyFileSearchResult
import com.litter.android.state.MessageRole
import com.litter.android.state.ModelOption
import com.litter.android.state.ServerConfig
import com.litter.android.state.ServerConnectionStatus
import com.litter.android.state.ServerSource
import com.litter.android.state.SkillMetadata
import com.litter.android.state.ThreadKey
import com.litter.android.state.ThreadState
import com.sigkitten.litter.android.R
import io.noties.markwon.Markwon
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream
import java.util.LinkedHashMap
import java.util.Locale

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
            modifier = Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding(),
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
            HorizontalDivider(color = LitterTheme.divider)

            if (uiState.activeThreadKey == null) {
                EmptyState(
                    connectionStatus = uiState.connectionStatus,
                    connectedServers = uiState.connectedServers,
                    onOpenDiscovery = appState::openDiscovery,
                )
            } else {
                ConversationPanel(
                    messages = uiState.messages,
                    draft = uiState.draft,
                    isSending = uiState.isSending,
                    models = uiState.models,
                    selectedModelId = uiState.selectedModelId,
                    selectedReasoningEffort = uiState.selectedReasoningEffort,
                    approvalPolicy = uiState.approvalPolicy,
                    sandboxMode = uiState.sandboxMode,
                    currentCwd = uiState.currentCwd,
                    activeThreadPreview = uiState.sessions.firstOrNull { it.key == uiState.activeThreadKey }?.preview.orEmpty(),
                    onDraftChange = appState::updateDraft,
                    onFileSearch = appState::searchComposerFiles,
                    onSelectModel = appState::selectModel,
                    onSelectReasoningEffort = appState::selectReasoningEffort,
                    onUpdateComposerPermissions = appState::updateComposerPermissions,
                    onOpenNewSessionPicker = appState::openNewSessionPicker,
                    onOpenSidebar = appState::openSidebar,
                    onStartReview = appState::startReview,
                    onRenameActiveThread = appState::renameActiveThread,
                    onListExperimentalFeatures = appState::listExperimentalFeatures,
                    onSetExperimentalFeatureEnabled = appState::setExperimentalFeatureEnabled,
                    onListSkills = appState::listSkills,
                    onSend = { payloadDraft ->
                        appState.updateDraft(payloadDraft)
                        appState.sendDraft()
                    },
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
            sessionSearchQuery = uiState.sessionSearchQuery,
            collapsedSessionFolders = uiState.collapsedSessionFolders,
            activeThreadKey = uiState.activeThreadKey,
            onSessionSelected = appState::selectSession,
            onSessionSearchQueryChange = appState::updateSessionSearchQuery,
            onToggleSessionFolder = appState::toggleSessionFolder,
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
                connectedServers = uiState.connectedServers,
                selectedServerId = uiState.directoryPicker.selectedServerId,
                path = uiState.directoryPicker.currentPath,
                entries = uiState.directoryPicker.entries,
                isLoading = uiState.directoryPicker.isLoading,
                error = uiState.directoryPicker.errorMessage,
                searchQuery = uiState.directoryPicker.searchQuery,
                showHiddenDirectories = uiState.directoryPicker.showHiddenDirectories,
                onDismiss = appState::dismissDirectoryPicker,
                onServerSelected = appState::updateDirectoryPickerServer,
                onSearchQueryChange = appState::updateDirectorySearchQuery,
                onShowHiddenDirectoriesChange = appState::updateShowHiddenDirectories,
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

        if (uiState.sshLogin.isVisible) {
            SshLoginSheet(
                state = uiState.sshLogin,
                onDismiss = appState::dismissSshLogin,
                onUsernameChanged = appState::updateSshUsername,
                onPasswordChanged = appState::updateSshPassword,
                onUseKeyChanged = appState::updateSshUseKey,
                onPrivateKeyChanged = appState::updateSshPrivateKey,
                onPassphraseChanged = appState::updateSshPassphrase,
                onRememberChanged = appState::updateSshRememberCredentials,
                onForgetSaved = appState::forgetSshCredentials,
                onConnect = appState::connectSshServer,
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
        color = Color.Transparent,
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
    val selectedModelName = (selectedModel?.id ?: "").ifBlank { "litter" }

    Box {
        OutlinedButton(
            onClick = { expanded = true },
            border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
            shape = RoundedCornerShape(22.dp),
        ) {
            Text(
                selectedModelName,
                color = LitterTheme.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
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
            ServerConnectionStatus.ERROR -> LitterTheme.danger
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
private fun EmptyState(
    connectionStatus: ServerConnectionStatus,
    connectedServers: List<ServerConfig>,
    onOpenDiscovery: () -> Unit,
) {
    val canConnect =
        connectionStatus == ServerConnectionStatus.DISCONNECTED ||
            connectionStatus == ServerConnectionStatus.ERROR
    val connectedServerLabels =
        remember(connectedServers) {
            connectedServers
                .sortedBy { it.name.lowercase(Locale.ROOT) }
                .map { server ->
                    val name = server.name.ifBlank { "server" }
                    "$name * ${serverSourceLabel(server.source)}"
                }
        }
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            BrandLogo(size = 112.dp)
            Text(
                text = "Open the sidebar to start a session",
                style = MaterialTheme.typography.bodyMedium,
                color = LitterTheme.textMuted,
            )
            if (connectedServerLabels.isNotEmpty()) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = "Connected Servers",
                        style = MaterialTheme.typography.labelLarge,
                        color = LitterTheme.textSecondary,
                    )
                    connectedServerLabels.forEach { label ->
                        Text(
                            text = label,
                            style = MaterialTheme.typography.labelLarge,
                            color = LitterTheme.accent,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            if (canConnect) {
                OutlinedButton(onClick = onOpenDiscovery) {
                    Text("Connect to Server", color = LitterTheme.accent)
                }
            }
        }
    }
}

@Composable
private fun SessionSidebar(
    modifier: Modifier,
    connectionStatus: ServerConnectionStatus,
    serverCount: Int,
    sessions: List<ThreadState>,
    sessionSearchQuery: String,
    collapsedSessionFolders: Set<String>,
    activeThreadKey: ThreadKey?,
    onSessionSelected: (ThreadKey) -> Unit,
    onSessionSearchQueryChange: (String) -> Unit,
    onToggleSessionFolder: (String) -> Unit,
    onNewSession: () -> Unit,
    onRefresh: () -> Unit,
    onOpenDiscovery: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    val normalizedQuery = sessionSearchQuery.trim()
    val filteredSessions =
        if (normalizedQuery.isEmpty()) {
            sessions
        } else {
            sessions.filter { matchesSessionSearch(it, normalizedQuery) }
        }
    val groupedSessions = remember(filteredSessions) { groupSessionsByFolder(filteredSessions) }
    val isFilteringSessions = normalizedQuery.isNotEmpty()

    Surface(
        modifier = modifier,
        color = LitterTheme.surface.copy(alpha = 0.88f),
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
                OutlinedTextField(
                    value = sessionSearchQuery,
                    onValueChange = onSessionSearchQueryChange,
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("Search sessions") },
                    singleLine = true,
                )

                if (filteredSessions.isEmpty()) {
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        text = "No matches for \"$normalizedQuery\"",
                        color = LitterTheme.textMuted,
                        modifier = Modifier.align(Alignment.CenterHorizontally),
                    )
                    Spacer(modifier = Modifier.weight(1f))
                } else {
                    LazyColumn(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        groupedSessions.forEach { group ->
                            val isExpanded = isFilteringSessions || !collapsedSessionFolders.contains(group.folderPath)
                            item(key = "folder-${group.folderPath}") {
                                FolderGroupHeader(
                                    folderPath = group.folderPath,
                                    isExpanded = isExpanded,
                                    canToggle = !isFilteringSessions,
                                    onToggle = { onToggleSessionFolder(group.folderPath) },
                                )
                            }

                            if (isExpanded) {
                                items(items = group.threads, key = { "${it.key.serverId}:${it.key.threadId}" }) { thread ->
                                    val isActive = thread.key == activeThreadKey
                                    Surface(
                                        modifier = Modifier.fillMaxWidth().clickable { onSessionSelected(thread.key) },
                                        color =
                                            if (isActive) {
                                                LitterTheme.surfaceLight.copy(alpha = 0.58f)
                                            } else {
                                                LitterTheme.surface.copy(alpha = 0.58f)
                                            },
                                        shape = RoundedCornerShape(8.dp),
                                        border =
                                            androidx.compose.foundation.BorderStroke(
                                                1.dp,
                                                if (isActive) LitterTheme.accent else LitterTheme.border,
                                            ),
                                    ) {
                                        Row(
                                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 9.dp),
                                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                                            verticalAlignment = Alignment.Top,
                                        ) {
                                            if (thread.hasTurnActive) {
                                                ActiveTurnPulseDot(modifier = Modifier.padding(top = 3.dp))
                                            } else {
                                                Spacer(modifier = Modifier.size(8.dp))
                                            }
                                            Column(
                                                modifier = Modifier.weight(1f),
                                                verticalArrangement = Arrangement.spacedBy(4.dp),
                                            ) {
                                                Text(
                                                    text = thread.preview.ifBlank { "Untitled session" },
                                                    maxLines = 2,
                                                    overflow = TextOverflow.Ellipsis,
                                                    color = LitterTheme.textPrimary,
                                                    style = MaterialTheme.typography.bodyMedium,
                                                )
                                                Row(
                                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                                    verticalAlignment = Alignment.CenterVertically,
                                                ) {
                                                    Text(
                                                        text = relativeDate(thread.updatedAtEpochMillis),
                                                        maxLines = 1,
                                                        overflow = TextOverflow.Ellipsis,
                                                        color = LitterTheme.textSecondary,
                                                        style = MaterialTheme.typography.labelLarge,
                                                    )
                                                    ServerSourceBadge(
                                                        source = thread.serverSource,
                                                        serverName = thread.serverName,
                                                    )
                                                    Text(
                                                        text = cwdLeaf(thread.cwd),
                                                        maxLines = 1,
                                                        overflow = TextOverflow.Ellipsis,
                                                        color = LitterTheme.textMuted,
                                                        style = MaterialTheme.typography.labelLarge,
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Surface(
                modifier = Modifier.fillMaxWidth().clickable { onOpenSettings() },
                color = LitterTheme.surface.copy(alpha = 0.58f),
                shape = RoundedCornerShape(8.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(
                        imageVector = Icons.Default.Settings,
                        contentDescription = null,
                        tint = LitterTheme.textSecondary,
                        modifier = Modifier.size(14.dp),
                    )
                    Text("Settings", color = LitterTheme.textSecondary, style = MaterialTheme.typography.bodyMedium)
                    Spacer(modifier = Modifier.weight(1f))
                    Text("Open", color = LitterTheme.accent, style = MaterialTheme.typography.labelLarge)
                }
            }
        }
    }
}

@Composable
private fun FolderGroupHeader(
    folderPath: String,
    isExpanded: Boolean,
    canToggle: Boolean,
    onToggle: () -> Unit,
) {
    val folderName = cwdLeaf(folderPath)
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(top = 6.dp, bottom = 2.dp)
                .clickable(enabled = canToggle, onClick = onToggle),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            imageVector = if (isExpanded) Icons.Default.KeyboardArrowDown else Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = if (isExpanded) "Collapse workspace folder" else "Expand workspace folder",
            modifier = Modifier.size(14.dp),
            tint = LitterTheme.textSecondary,
        )
        Icon(
            imageVector = Icons.Default.Folder,
            contentDescription = null,
            modifier = Modifier.size(12.dp),
            tint = LitterTheme.textSecondary,
        )
        Text(
            text = folderName,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            color = LitterTheme.textSecondary,
            style = MaterialTheme.typography.labelLarge,
        )
        Spacer(modifier = Modifier.weight(1f))
        if (folderName != folderPath) {
            Text(
                text = folderPath,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                color = LitterTheme.textMuted,
                style = MaterialTheme.typography.labelSmall,
            )
        }
    }
}

private fun matchesSessionSearch(
    thread: ThreadState,
    query: String,
): Boolean {
    val normalizedQuery = query.lowercase(Locale.ROOT)
    return thread.preview.lowercase(Locale.ROOT).contains(normalizedQuery) ||
        thread.cwd.lowercase(Locale.ROOT).contains(normalizedQuery) ||
        thread.serverName.lowercase(Locale.ROOT).contains(normalizedQuery)
}

private data class FolderSessionGroup(
    val folderPath: String,
    val threads: List<ThreadState>,
)

private fun groupSessionsByFolder(threads: List<ThreadState>): List<FolderSessionGroup> {
    val grouped = LinkedHashMap<String, MutableList<ThreadState>>()
    threads.forEach { thread ->
        val folderPath = normalizeFolderPath(thread.cwd)
        grouped.getOrPut(folderPath) { mutableListOf() }.add(thread)
    }
    return grouped.map { (folderPath, groupThreads) ->
        FolderSessionGroup(folderPath = folderPath, threads = groupThreads)
    }
}

@Composable
private fun BrandLogo(
    size: androidx.compose.ui.unit.Dp,
    modifier: Modifier = Modifier,
) {
    Image(
        painter = painterResource(id = R.drawable.brand_logo),
        contentDescription = null,
        modifier = modifier.size(size),
        contentScale = ContentScale.Fit,
    )
}

@Composable
private fun ActiveTurnPulseDot(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "active_turn_pulse")
    val pulse by
        transition.animateFloat(
            initialValue = 0.82f,
            targetValue = 1.24f,
            animationSpec =
                infiniteRepeatable(
                    animation = tween(durationMillis = 900),
                    repeatMode = RepeatMode.Reverse,
                ),
            label = "active_turn_pulse_scale",
        )
    Box(
        modifier =
            modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(LitterTheme.accent.copy(alpha = pulse.coerceIn(0.45f, 1f))),
    )
}

@Composable
private fun ServerSourceBadge(
    source: ServerSource,
    serverName: String,
) {
    val accent = serverSourceAccentColor(source)
    Surface(
        color = accent.copy(alpha = 0.13f),
        shape = RoundedCornerShape(4.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, accent.copy(alpha = 0.35f)),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 5.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Box(
                modifier =
                    Modifier
                        .size(5.dp)
                        .clip(CircleShape)
                        .background(accent),
            )
            Text(
                text = "${serverSourceLabel(source)}:${serverName.ifBlank { "server" }}",
                color = accent,
                style = MaterialTheme.typography.labelLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun ConversationPanel(
    messages: List<ChatMessage>,
    draft: String,
    isSending: Boolean,
    models: List<ModelOption>,
    selectedModelId: String?,
    selectedReasoningEffort: String?,
    approvalPolicy: String,
    sandboxMode: String,
    currentCwd: String,
    activeThreadPreview: String,
    onDraftChange: (String) -> Unit,
    onFileSearch: (String, (Result<List<FuzzyFileSearchResult>>) -> Unit) -> Unit,
    onSelectModel: (String) -> Unit,
    onSelectReasoningEffort: (String) -> Unit,
    onUpdateComposerPermissions: (String, String) -> Unit,
    onOpenNewSessionPicker: () -> Unit,
    onOpenSidebar: () -> Unit,
    onStartReview: ((Result<Unit>) -> Unit) -> Unit,
    onRenameActiveThread: (String, (Result<Unit>) -> Unit) -> Unit,
    onListExperimentalFeatures: ((Result<List<ExperimentalFeature>>) -> Unit) -> Unit,
    onSetExperimentalFeatureEnabled: (String, Boolean, (Result<Unit>) -> Unit) -> Unit,
    onListSkills: (String?, Boolean, (Result<List<SkillMetadata>>) -> Unit) -> Unit,
    onSend: (String) -> Unit,
    onInterrupt: () -> Unit,
) {
    val context = LocalContext.current
    var attachedImagePath by remember { mutableStateOf<String?>(null) }
    var attachmentError by remember { mutableStateOf<String?>(null) }
    val listState = rememberLazyListState()
    val attachmentLauncher =
        rememberLauncherForActivityResult(
            contract = ActivityResultContracts.GetContent(),
        ) { uri ->
            if (uri == null) {
                return@rememberLauncherForActivityResult
            }
            val cachedPath = runCatching { cacheAttachmentImage(context, uri) }.getOrNull()
            if (cachedPath != null) {
                attachedImagePath = cachedPath
                attachmentError = null
            } else {
                attachmentError = "Unable to attach image from picker"
            }
        }
    val cameraLauncher =
        rememberLauncherForActivityResult(
            contract = ActivityResultContracts.TakePicturePreview(),
        ) { bitmap ->
            if (bitmap == null) {
                return@rememberLauncherForActivityResult
            }
            val cachedPath = runCatching { cacheAttachmentBitmap(context, bitmap) }.getOrNull()
            if (cachedPath != null) {
                attachedImagePath = cachedPath
                attachmentError = null
            } else {
                attachmentError = "Unable to attach image from camera"
            }
        }

    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.lastIndex)
        }
    }

    Column(
        modifier = Modifier.fillMaxSize(),
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
            modifier = Modifier.imePadding(),
            draft = draft,
            attachedImagePath = attachedImagePath,
            attachmentError = attachmentError,
            isSending = isSending,
            models = models,
            selectedModelId = selectedModelId,
            selectedReasoningEffort = selectedReasoningEffort,
            approvalPolicy = approvalPolicy,
            sandboxMode = sandboxMode,
            currentCwd = currentCwd,
            activeThreadPreview = activeThreadPreview,
            onDraftChange = onDraftChange,
            onFileSearch = onFileSearch,
            onSelectModel = onSelectModel,
            onSelectReasoningEffort = onSelectReasoningEffort,
            onUpdateComposerPermissions = onUpdateComposerPermissions,
            onOpenNewSessionPicker = onOpenNewSessionPicker,
            onOpenSidebar = onOpenSidebar,
            onStartReview = onStartReview,
            onRenameActiveThread = onRenameActiveThread,
            onListExperimentalFeatures = onListExperimentalFeatures,
            onSetExperimentalFeatureEnabled = onSetExperimentalFeatureEnabled,
            onListSkills = onListSkills,
            onAttachImage = { attachmentLauncher.launch("image/*") },
            onCaptureImage = { cameraLauncher.launch(null) },
            onClearAttachment = {
                attachedImagePath = null
                attachmentError = null
            },
            onSend = { text ->
                onSend(encodeDraftWithLocalImageAttachment(text, attachedImagePath))
                attachedImagePath = null
                attachmentError = null
            },
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
                    color = LitterTheme.surfaceLight,
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
            MessageMarkdownContent(
                markdown = message.text,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp),
            )
        }

        MessageRole.SYSTEM -> {
            SystemMessageCard(message = message)
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
private fun MessageMarkdownContent(
    markdown: String,
    modifier: Modifier = Modifier,
    textColor: Color = LitterTheme.textBody,
) {
    val blocks = remember(markdown) { splitMarkdownCodeBlocks(markdown) }
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        blocks.forEach { block ->
            when (block) {
                is MarkdownBlock.Text -> InlineMediaMarkdown(markdown = block.markdown, textColor = textColor)
                is MarkdownBlock.Code -> CodeBlockCard(language = block.language, code = block.code)
            }
        }
    }
}

@Composable
private fun InlineMediaMarkdown(
    markdown: String,
    textColor: Color,
) {
    val segments = remember(markdown) { extractInlineSegments(markdown) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        segments.forEach { segment ->
            when (segment) {
                is InlineSegment.Text -> AssistantMarkdownText(markdown = segment.value, textColor = textColor)
                is InlineSegment.ImageBytes -> {
                    val bitmap =
                        remember(segment.bytes) {
                            BitmapFactory.decodeByteArray(segment.bytes, 0, segment.bytes.size)
                        }
                    if (bitmap != null) {
                        Image(
                            bitmap = bitmap.asImageBitmap(),
                            contentDescription = "Inline image",
                            modifier = Modifier.fillMaxWidth().heightIn(max = 320.dp).clip(RoundedCornerShape(8.dp)),
                            contentScale = ContentScale.Fit,
                        )
                    }
                }

                is InlineSegment.LocalImagePath -> {
                    val bitmap = remember(segment.path) { BitmapFactory.decodeFile(segment.path) }
                    if (bitmap != null) {
                        Image(
                            bitmap = bitmap.asImageBitmap(),
                            contentDescription = "Local image",
                            modifier = Modifier.fillMaxWidth().heightIn(max = 320.dp).clip(RoundedCornerShape(8.dp)),
                            contentScale = ContentScale.Fit,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AssistantMarkdownText(
    markdown: String,
    textColor: Color,
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
                setTextColor(textColor.toArgb())
                setLineSpacing(0f, 1.2f)
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
            }
        },
        update = { markwon.setMarkdown(it, markdown) },
    )
}

@Composable
private fun CodeBlockCard(
    language: String,
    code: String,
    modifier: Modifier = Modifier,
) {
    val clipboard = LocalClipboardManager.current
    var copied by remember(code) { mutableStateOf(false) }
    val horizontalScroll = rememberScrollState()

    LaunchedEffect(copied) {
        if (copied) {
            delay(1400L)
            copied = false
        }
    }

    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        color = LitterTheme.surface.copy(alpha = 0.8f),
        border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
    ) {
        Column {
            Row(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .background(LitterTheme.surface.copy(alpha = 0.96f))
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (language.isNotBlank()) {
                    Surface(
                        shape = RoundedCornerShape(4.dp),
                        color = LitterTheme.surfaceLight,
                    ) {
                        Text(
                            text = language,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 3.dp),
                            color = LitterTheme.textSecondary,
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                }
                Spacer(modifier = Modifier.weight(1f))
                TextButton(
                    onClick = {
                        clipboard.setText(AnnotatedString(code))
                        copied = true
                    },
                ) {
                    Icon(
                        imageVector = if (copied) Icons.Default.Check else Icons.Default.ContentCopy,
                        contentDescription = if (copied) "Copied" else "Copy code",
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(if (copied) "Copied" else "Copy")
                }
            }

            Row(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .horizontalScroll(horizontalScroll)
                        .padding(horizontal = 12.dp, vertical = 10.dp),
            ) {
                Text(
                    text = code,
                    color = LitterTheme.textBody,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
    }
}

@Composable
private fun SystemMessageCard(message: ChatMessage) {
    val (title, body) = remember(message.text) { extractSystemTitleAndBody(message.text) }
    val toolCall = remember(title) { isToolCallTitle(title) }
    val theme = remember(title) { systemCardTheme(title) }
    val summary = remember(title, body, toolCall) { compactSystemSummary(title, body, toolCall) }
    var expanded by remember(message.id) { mutableStateOf(!toolCall) }

    Surface(
        modifier = Modifier.fillMaxWidth().animateContentSize(),
        shape = RoundedCornerShape(10.dp),
        color = LitterTheme.surface.copy(alpha = 0.85f),
        border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
        ) {
            Row(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .let { base ->
                            if (toolCall) {
                                base.clickable { expanded = !expanded }
                            } else {
                                base
                            }
                        },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Box(
                    modifier =
                        Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(theme.accent),
                )
                Text(
                    text = summary,
                    color = LitterTheme.textSecondary,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (toolCall) {
                    Icon(
                        imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                        contentDescription = if (expanded) "Collapse" else "Expand",
                        tint = LitterTheme.textMuted,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }

            if (!toolCall || expanded) {
                val markdown = if (toolCall) body else message.text
                if (markdown.isNotBlank()) {
                    MessageMarkdownContent(
                        markdown = markdown,
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                        textColor = LitterTheme.textSystem,
                    )
                }
            }
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun InputBar(
    modifier: Modifier = Modifier,
    draft: String,
    attachedImagePath: String?,
    attachmentError: String?,
    isSending: Boolean,
    models: List<ModelOption>,
    selectedModelId: String?,
    selectedReasoningEffort: String?,
    approvalPolicy: String,
    sandboxMode: String,
    currentCwd: String,
    activeThreadPreview: String,
    onDraftChange: (String) -> Unit,
    onFileSearch: (String, (Result<List<FuzzyFileSearchResult>>) -> Unit) -> Unit,
    onSelectModel: (String) -> Unit,
    onSelectReasoningEffort: (String) -> Unit,
    onUpdateComposerPermissions: (String, String) -> Unit,
    onOpenNewSessionPicker: () -> Unit,
    onOpenSidebar: () -> Unit,
    onStartReview: ((Result<Unit>) -> Unit) -> Unit,
    onRenameActiveThread: (String, (Result<Unit>) -> Unit) -> Unit,
    onListExperimentalFeatures: ((Result<List<ExperimentalFeature>>) -> Unit) -> Unit,
    onSetExperimentalFeatureEnabled: (String, Boolean, (Result<Unit>) -> Unit) -> Unit,
    onListSkills: (String?, Boolean, (Result<List<SkillMetadata>>) -> Unit) -> Unit,
    onAttachImage: () -> Unit,
    onCaptureImage: () -> Unit,
    onClearAttachment: () -> Unit,
    onSend: (String) -> Unit,
    onInterrupt: () -> Unit,
) {
    var composerValue by
        remember {
            mutableStateOf(
                TextFieldValue(
                    text = draft,
                    selection = TextRange(draft.length),
                ),
            )
        }
    var showSlashPopup by remember { mutableStateOf(false) }
    var activeSlashToken by remember { mutableStateOf<ComposerSlashQueryContext?>(null) }
    var slashSuggestions by remember { mutableStateOf<List<ComposerSlashCommand>>(emptyList()) }

    var showFilePopup by remember { mutableStateOf(false) }
    var activeAtToken by remember { mutableStateOf<ComposerTokenContext?>(null) }
    var fileSearchLoading by remember { mutableStateOf(false) }
    var fileSearchError by remember { mutableStateOf<String?>(null) }
    var fileSuggestions by remember { mutableStateOf<List<FuzzyFileSearchResult>>(emptyList()) }
    var fileSearchGeneration by remember { mutableStateOf(0) }
    var fileSearchJob by remember { mutableStateOf<Job?>(null) }

    var showModelSheet by remember { mutableStateOf(false) }
    var showPermissionsSheet by remember { mutableStateOf(false) }
    var showExperimentalSheet by remember { mutableStateOf(false) }
    var showSkillsSheet by remember { mutableStateOf(false) }
    var showRenameDialog by remember { mutableStateOf(false) }
    var renameDraft by remember { mutableStateOf("") }
    var slashErrorMessage by remember { mutableStateOf<String?>(null) }
    var experimentalFeatures by remember { mutableStateOf<List<ExperimentalFeature>>(emptyList()) }
    var experimentalFeaturesLoading by remember { mutableStateOf(false) }
    var skills by remember { mutableStateOf<List<SkillMetadata>>(emptyList()) }
    var skillsLoading by remember { mutableStateOf(false) }
    var showAttachmentMenu by remember { mutableStateOf(false) }

    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current

    fun clearFileSearchState() {
        fileSearchJob?.cancel()
        fileSearchJob = null
        fileSearchGeneration += 1
        fileSearchLoading = false
        fileSearchError = null
        fileSuggestions = emptyList()
    }

    fun hideComposerPopups() {
        showSlashPopup = false
        activeSlashToken = null
        slashSuggestions = emptyList()
        showFilePopup = false
        activeAtToken = null
        clearFileSearchState()
    }

    fun startFileSearch(query: String) {
        fileSearchJob?.cancel()
        fileSearchJob = null
        val requestId = fileSearchGeneration + 1
        fileSearchGeneration = requestId
        fileSearchLoading = true
        fileSearchError = null
        fileSuggestions = emptyList()
        fileSearchJob =
            scope.launch {
                delay(140)
                if (activeAtToken?.value != query) {
                    return@launch
                }
                onFileSearch(query) { result ->
                    if (requestId != fileSearchGeneration || activeAtToken?.value != query) {
                        return@onFileSearch
                    }
                    result.onFailure { error ->
                        fileSuggestions = emptyList()
                        fileSearchLoading = false
                        fileSearchError = error.message ?: "File search failed"
                    }
                    result.onSuccess { matches ->
                        fileSuggestions = matches
                        fileSearchLoading = false
                        fileSearchError = null
                    }
                }
            }
    }

    fun refreshComposerPopups(nextValue: TextFieldValue) {
        val atToken =
            currentPrefixedToken(
                text = nextValue.text,
                cursor = nextValue.selection.start,
                prefix = '@',
                allowEmpty = true,
            )
        if (atToken != null) {
            showSlashPopup = false
            activeSlashToken = null
            slashSuggestions = emptyList()
            showFilePopup = true
            if (activeAtToken != atToken) {
                activeAtToken = atToken
                startFileSearch(atToken.value)
            }
            return
        }

        activeAtToken = null
        showFilePopup = false
        clearFileSearchState()

        val slashToken =
            currentSlashQueryContext(
                text = nextValue.text,
                cursor = nextValue.selection.start,
            )
        if (slashToken == null) {
            showSlashPopup = false
            activeSlashToken = null
            slashSuggestions = emptyList()
            return
        }

        activeSlashToken = slashToken
        slashSuggestions = filterSlashCommands(slashToken.query)
        showSlashPopup = slashSuggestions.isNotEmpty()
    }

    fun loadExperimentalFeatures() {
        experimentalFeaturesLoading = true
        onListExperimentalFeatures { result ->
            experimentalFeaturesLoading = false
            result.onFailure { error ->
                slashErrorMessage = error.message ?: "Failed to load experimental features"
            }
            result.onSuccess { features ->
                experimentalFeatures = features.sortedBy { (it.displayName ?: it.name).lowercase(Locale.ROOT) }
            }
        }
    }

    fun loadSkills(forceReload: Boolean = false) {
        skillsLoading = true
        onListSkills(currentCwd, forceReload) { result ->
            skillsLoading = false
            result.onFailure { error ->
                slashErrorMessage = error.message ?: "Failed to load skills"
            }
            result.onSuccess { loaded ->
                skills = loaded.sortedBy { it.name.lowercase(Locale.ROOT) }
            }
        }
    }

    fun executeSlashCommand(
        command: ComposerSlashCommand,
        args: String?,
    ) {
        when (command) {
            ComposerSlashCommand.MODEL -> {
                showModelSheet = true
            }

            ComposerSlashCommand.PERMISSIONS -> {
                showPermissionsSheet = true
            }

            ComposerSlashCommand.EXPERIMENTAL -> {
                showExperimentalSheet = true
                loadExperimentalFeatures()
            }

            ComposerSlashCommand.SKILLS -> {
                showSkillsSheet = true
                loadSkills(forceReload = false)
            }

            ComposerSlashCommand.REVIEW -> {
                onStartReview { result ->
                    result.onFailure { error ->
                        slashErrorMessage = error.message ?: "Failed to start review"
                    }
                }
            }

            ComposerSlashCommand.RENAME -> {
                val initialName = args?.trim().orEmpty()
                if (initialName.isNotEmpty()) {
                    onRenameActiveThread(initialName) { result ->
                        result.onFailure { error ->
                            slashErrorMessage = error.message ?: "Failed to rename thread"
                        }
                    }
                } else {
                    renameDraft = activeThreadPreview
                    showRenameDialog = true
                }
            }

            ComposerSlashCommand.NEW -> {
                onOpenNewSessionPicker()
            }

            ComposerSlashCommand.RESUME -> {
                onOpenSidebar()
            }
        }
    }

    fun applySlashSuggestion(command: ComposerSlashCommand) {
        composerValue = TextFieldValue(text = "", selection = TextRange(0))
        onDraftChange("")
        hideComposerPopups()
        executeSlashCommand(command, args = null)
    }

    fun applyFileSuggestion(match: FuzzyFileSearchResult) {
        val token = activeAtToken ?: return
        val quotedPath =
            if (match.path.contains(" ") && !match.path.contains("\"")) {
                "\"${match.path}\""
            } else {
                match.path
            }
        val replacement = "$quotedPath "
        val updatedText =
            composerValue.text.replaceRange(
                startIndex = token.range.start,
                endIndex = token.range.end,
                replacement = replacement,
            )
        val nextCursor = token.range.start + replacement.length
        composerValue = TextFieldValue(text = updatedText, selection = TextRange(nextCursor))
        onDraftChange(updatedText)
        showFilePopup = false
        activeAtToken = null
        clearFileSearchState()
    }

    LaunchedEffect(draft) {
        if (draft != composerValue.text) {
            val cursor = composerValue.selection.start.coerceIn(0, draft.length)
            val synced = TextFieldValue(text = draft, selection = TextRange(cursor))
            composerValue = synced
            refreshComposerPopups(synced)
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            fileSearchJob?.cancel()
        }
    }

    if (showModelSheet) {
        val selectedModel = models.firstOrNull { it.id == selectedModelId } ?: models.firstOrNull()
        ModalBottomSheet(onDismissRequest = { showModelSheet = false }) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text("Model", style = MaterialTheme.typography.titleMedium)
                if (models.isEmpty()) {
                    Text("No models available", color = LitterTheme.textMuted)
                } else {
                    LazyColumn(
                        modifier = Modifier.fillMaxWidth().fillMaxHeight(0.4f),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        items(models, key = { it.id }) { model ->
                            Surface(
                                modifier = Modifier.fillMaxWidth().clickable { onSelectModel(model.id) },
                                color = LitterTheme.surface.copy(alpha = 0.6f),
                                shape = RoundedCornerShape(8.dp),
                                border = androidx.compose.foundation.BorderStroke(1.dp, if (model.id == selectedModelId) LitterTheme.accent else LitterTheme.border),
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                        Text(model.displayName, color = LitterTheme.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        if (model.description.isNotBlank()) {
                                            Text(
                                                model.description,
                                                color = LitterTheme.textSecondary,
                                                style = MaterialTheme.typography.labelLarge,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis,
                                            )
                                        }
                                    }
                                    if (model.id == selectedModelId) {
                                        Icon(Icons.Default.Check, contentDescription = null, tint = LitterTheme.accent, modifier = Modifier.size(16.dp))
                                    }
                                }
                            }
                        }
                    }
                }

                val efforts = selectedModel?.supportedReasoningEfforts.orEmpty()
                if (efforts.isNotEmpty()) {
                    Text("Reasoning Effort", color = LitterTheme.textSecondary, style = MaterialTheme.typography.labelLarge)
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        efforts.forEach { effort ->
                            Surface(
                                modifier = Modifier.fillMaxWidth().clickable { onSelectReasoningEffort(effort.effort) },
                                color = LitterTheme.surface.copy(alpha = 0.6f),
                                shape = RoundedCornerShape(8.dp),
                                border =
                                    androidx.compose.foundation.BorderStroke(
                                        1.dp,
                                        if (effort.effort == selectedReasoningEffort) LitterTheme.accent else LitterTheme.border,
                                    ),
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                ) {
                                    Text(effort.effort, color = LitterTheme.textPrimary, style = MaterialTheme.typography.bodyMedium)
                                    if (effort.effort == selectedReasoningEffort) {
                                        Icon(Icons.Default.Check, contentDescription = null, tint = LitterTheme.accent, modifier = Modifier.size(16.dp))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (showPermissionsSheet) {
        ModalBottomSheet(onDismissRequest = { showPermissionsSheet = false }) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text("Permissions", style = MaterialTheme.typography.titleMedium)
                ComposerPermissionPreset.values().forEach { preset ->
                    val isSelected = preset.approvalPolicy == approvalPolicy && preset.sandboxMode == sandboxMode
                    Surface(
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                .clickable {
                                    onUpdateComposerPermissions(preset.approvalPolicy, preset.sandboxMode)
                                    showPermissionsSheet = false
                                },
                        color = LitterTheme.surface.copy(alpha = 0.6f),
                        shape = RoundedCornerShape(8.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, if (isSelected) LitterTheme.accent else LitterTheme.border),
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
                                Text(preset.title, color = LitterTheme.textPrimary, style = MaterialTheme.typography.bodyMedium)
                                if (isSelected) {
                                    Icon(Icons.Default.Check, contentDescription = null, tint = LitterTheme.accent, modifier = Modifier.size(16.dp))
                                }
                            }
                            Text(preset.description, color = LitterTheme.textSecondary, style = MaterialTheme.typography.labelLarge)
                        }
                    }
                }
            }
        }
    }

    if (showExperimentalSheet) {
        ModalBottomSheet(onDismissRequest = { showExperimentalSheet = false }) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Experimental", style = MaterialTheme.typography.titleMedium)
                    TextButton(onClick = { loadExperimentalFeatures() }) { Text("Reload") }
                }

                when {
                    experimentalFeaturesLoading -> {
                        Text("Loading...", color = LitterTheme.textMuted)
                    }

                    experimentalFeatures.isEmpty() -> {
                        Text("No experimental features available", color = LitterTheme.textMuted)
                    }

                    else -> {
                        LazyColumn(
                            modifier = Modifier.fillMaxWidth().fillMaxHeight(0.6f),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            items(experimentalFeatures, key = { it.name }) { feature ->
                                Surface(
                                    modifier = Modifier.fillMaxWidth(),
                                    color = LitterTheme.surface.copy(alpha = 0.6f),
                                    shape = RoundedCornerShape(8.dp),
                                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                                ) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
                                        horizontalArrangement = Arrangement.SpaceBetween,
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Column(
                                            modifier = Modifier.weight(1f),
                                            verticalArrangement = Arrangement.spacedBy(2.dp),
                                        ) {
                                            Text(
                                                feature.displayName ?: feature.name,
                                                color = LitterTheme.textPrimary,
                                                style = MaterialTheme.typography.bodyMedium,
                                            )
                                            Text(
                                                feature.description ?: feature.stage,
                                                color = LitterTheme.textSecondary,
                                                style = MaterialTheme.typography.labelLarge,
                                            )
                                        }
                                        Checkbox(
                                            checked = feature.enabled,
                                            onCheckedChange = { checked ->
                                                onSetExperimentalFeatureEnabled(feature.name, checked) { result ->
                                                    result.onFailure { error ->
                                                        slashErrorMessage = error.message ?: "Failed to update feature"
                                                    }
                                                    result.onSuccess {
                                                        experimentalFeatures =
                                                            experimentalFeatures.map { existing ->
                                                                if (existing.name == feature.name) {
                                                                    existing.copy(enabled = checked)
                                                                } else {
                                                                    existing
                                                                }
                                                            }
                                                    }
                                                }
                                            },
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (showSkillsSheet) {
        ModalBottomSheet(onDismissRequest = { showSkillsSheet = false }) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Skills", style = MaterialTheme.typography.titleMedium)
                    TextButton(onClick = { loadSkills(forceReload = true) }) { Text("Reload") }
                }

                when {
                    skillsLoading -> {
                        Text("Loading...", color = LitterTheme.textMuted)
                    }

                    skills.isEmpty() -> {
                        Text("No skills available for this workspace", color = LitterTheme.textMuted)
                    }

                    else -> {
                        LazyColumn(
                            modifier = Modifier.fillMaxWidth().fillMaxHeight(0.6f),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            items(skills, key = { "${it.path}#${it.name}" }) { skill ->
                                Surface(
                                    modifier = Modifier.fillMaxWidth(),
                                    color = LitterTheme.surface.copy(alpha = 0.6f),
                                    shape = RoundedCornerShape(8.dp),
                                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                                ) {
                                    Column(
                                        modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
                                        verticalArrangement = Arrangement.spacedBy(2.dp),
                                    ) {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                            verticalAlignment = Alignment.CenterVertically,
                                        ) {
                                            Text(skill.name, color = LitterTheme.textPrimary, style = MaterialTheme.typography.bodyMedium)
                                            if (skill.enabled) {
                                                Text("enabled", color = LitterTheme.accent, style = MaterialTheme.typography.labelLarge)
                                            }
                                        }
                                        if (skill.description.isNotBlank()) {
                                            Text(skill.description, color = LitterTheme.textSecondary, style = MaterialTheme.typography.labelLarge)
                                        }
                                        Text(skill.path, color = LitterTheme.textMuted, style = MaterialTheme.typography.labelLarge)
                                    }
                                }
                            }
                        }
                    }
                }
            }
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
                    label = { Text("Thread name") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val nextName = renameDraft.trim()
                        if (nextName.isEmpty()) {
                            return@TextButton
                        }
                        onRenameActiveThread(nextName) { result ->
                            result.onFailure { error ->
                                slashErrorMessage = error.message ?: "Failed to rename thread"
                            }
                            result.onSuccess {
                                showRenameDialog = false
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

    if (!slashErrorMessage.isNullOrBlank()) {
        AlertDialog(
            onDismissRequest = { slashErrorMessage = null },
            title = { Text("Slash Command Error") },
            text = { Text(slashErrorMessage.orEmpty()) },
            confirmButton = {
                TextButton(onClick = { slashErrorMessage = null }) {
                    Text("OK")
                }
            },
        )
    }

    Column(
        modifier = modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 16.dp, top = 4.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
            if (attachedImagePath != null) {
                Surface(
                    shape = RoundedCornerShape(12.dp),
                    color = LitterTheme.surfaceLight,
                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                    modifier = Modifier.padding(bottom = 2.dp)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Default.Image,
                            contentDescription = null,
                            tint = LitterTheme.accent,
                            modifier = Modifier.size(16.dp),
                        )
                        Text(
                            text = attachedImagePath.substringAfterLast('/'),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            color = LitterTheme.textPrimary,
                            style = MaterialTheme.typography.labelLarge,
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(
                            onClick = onClearAttachment, 
                            enabled = !isSending,
                            modifier = Modifier.size(24.dp)
                        ) {
                            Icon(Icons.Default.Close, contentDescription = "Remove attachment", modifier = Modifier.size(14.dp), tint = LitterTheme.textSecondary)
                        }
                    }
                }
            }

            if (!attachmentError.isNullOrBlank()) {
                Text(
                    text = attachmentError,
                    color = LitterTheme.danger,
                    style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.padding(horizontal = 4.dp)
                )
            }

            if (showSlashPopup) {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    color = LitterTheme.surfaceLight.copy(alpha = 0.98f),
                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                ) {
                    Column {
                        slashSuggestions.forEachIndexed { index, command ->
                            Row(
                                modifier =
                                    Modifier
                                        .fillMaxWidth()
                                        .clickable { applySlashSuggestion(command) }
                                        .padding(horizontal = 14.dp, vertical = 10.dp),
                                horizontalArrangement = Arrangement.spacedBy(12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = "/${command.rawValue}",
                                    color = Color(0xFF6EA676),
                                    style = MaterialTheme.typography.bodyMedium,
                                )
                                Text(
                                    text = command.description,
                                    color = LitterTheme.textSecondary,
                                    style = MaterialTheme.typography.bodyMedium,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f),
                                )
                            }
                            if (index < slashSuggestions.lastIndex) {
                                HorizontalDivider(color = LitterTheme.border, thickness = 0.5.dp)
                            }
                        }
                    }
                }
            }

            if (showFilePopup) {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    color = LitterTheme.surfaceLight.copy(alpha = 0.98f),
                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                ) {
                    when {
                        fileSearchLoading -> {
                            Text(
                                text = "Searching files...",
                                color = LitterTheme.textSecondary,
                                style = MaterialTheme.typography.labelLarge,
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                            )
                        }

                        !fileSearchError.isNullOrBlank() -> {
                            Text(
                                text = fileSearchError.orEmpty(),
                                color = LitterTheme.danger,
                                style = MaterialTheme.typography.labelLarge,
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                            )
                        }

                        fileSuggestions.isEmpty() -> {
                            Text(
                                text = "No matches",
                                color = LitterTheme.textSecondary,
                                style = MaterialTheme.typography.labelLarge,
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                            )
                        }

                        else -> {
                            val visibleSuggestions = fileSuggestions.take(8)
                            Column {
                                visibleSuggestions.forEachIndexed { index, suggestion ->
                                    Row(
                                        modifier =
                                            Modifier
                                                .fillMaxWidth()
                                                .clickable { applyFileSuggestion(suggestion) }
                                                .padding(horizontal = 14.dp, vertical = 10.dp),
                                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Icon(
                                            imageVector = Icons.Default.Folder,
                                            contentDescription = null,
                                            tint = LitterTheme.textSecondary,
                                            modifier = Modifier.size(16.dp),
                                        )
                                        Text(
                                            text = suggestion.path,
                                            color = LitterTheme.textPrimary,
                                            style = MaterialTheme.typography.labelLarge,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                            modifier = Modifier.weight(1f),
                                        )
                                    }
                                    if (index < visibleSuggestions.lastIndex) {
                                        HorizontalDivider(color = LitterTheme.border, thickness = 0.5.dp)
                                    }
                                }
                            }
                        }
                    }
                }
            }

        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(26.dp),
            color = LitterTheme.surfaceLight,
            border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
        ) {
            val actionButtonSize = 36.dp
            val actionIconSize = 18.dp
            Row(
                modifier = Modifier.padding(horizontal = 6.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box {
                    Box(
                        modifier = Modifier
                            .size(actionButtonSize)
                            .clip(CircleShape)
                            .background(LitterTheme.surface)
                            .clickable(enabled = !isSending) { showAttachmentMenu = true },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Default.Add,
                            contentDescription = "Attachments",
                            modifier = Modifier.size(actionIconSize),
                            tint = LitterTheme.textPrimary
                        )
                    }

                    DropdownMenu(
                        expanded = showAttachmentMenu,
                        onDismissRequest = { showAttachmentMenu = false },
                        containerColor = LitterTheme.surfaceLight,
                    ) {
                        DropdownMenuItem(
                            text = { Text("Upload File", color = LitterTheme.textPrimary, style = MaterialTheme.typography.bodyMedium) },
                            onClick = {
                                showAttachmentMenu = false
                                onAttachImage()
                            },
                            leadingIcon = { Icon(Icons.Default.AttachFile, contentDescription = null, modifier = Modifier.size(18.dp), tint = LitterTheme.textSecondary) }
                        )
                        DropdownMenuItem(
                            text = { Text("Camera", color = LitterTheme.textPrimary, style = MaterialTheme.typography.bodyMedium) },
                            onClick = {
                                showAttachmentMenu = false
                                onCaptureImage()
                            },
                            leadingIcon = { Icon(Icons.Default.CameraAlt, contentDescription = null, modifier = Modifier.size(18.dp), tint = LitterTheme.textSecondary) }
                        )
                    }
                }

                Spacer(modifier = Modifier.width(4.dp))

                Box(
                    modifier = Modifier
                        .weight(1f)
                        .padding(vertical = 4.dp, horizontal = 4.dp),
                    contentAlignment = Alignment.CenterStart
                ) {
                    if (composerValue.text.isEmpty()) {
                        Text(
                            text = "Message litter...",
                            color = LitterTheme.textMuted,
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                    BasicTextField(
                        value = composerValue,
                        onValueChange = { nextValue ->
                            composerValue = nextValue
                            onDraftChange(nextValue.text)
                            refreshComposerPopups(nextValue)
                        },
                        modifier = Modifier.fillMaxWidth(),
                        textStyle = MaterialTheme.typography.bodyMedium.copy(color = LitterTheme.textPrimary),
                        cursorBrush = SolidColor(LitterTheme.accent),
                        maxLines = 5,
                    )
                }

                Spacer(modifier = Modifier.width(4.dp))

                if (isSending) {
                    Box(
                        modifier = Modifier
                            .size(actionButtonSize)
                            .clip(CircleShape)
                            .background(LitterTheme.surface)
                            .clickable { onInterrupt() },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Default.Stop,
                            contentDescription = "Interrupt",
                            modifier = Modifier.size(actionIconSize),
                            tint = LitterTheme.danger
                        )
                    }
                } else {
                    val canSend = (composerValue.text.isNotBlank() || attachedImagePath != null)
                    Box(
                        modifier = Modifier
                            .size(actionButtonSize)
                            .clip(CircleShape)
                            .background(if (canSend) LitterTheme.accent else Color.Transparent)
                            .clickable(enabled = canSend) {
                                val trimmed = composerValue.text.trim()
                                if (attachedImagePath == null) {
                                    val invocation = parseSlashCommandInvocation(trimmed)
                                    if (invocation != null) {
                                        composerValue = TextFieldValue(text = "", selection = TextRange(0))
                                        onDraftChange("")
                                        hideComposerPopups()
                                        focusManager.clearFocus(force = true)
                                        keyboardController?.hide()
                                        executeSlashCommand(invocation.command, invocation.args)
                                        return@clickable
                                    }
                                }
                                focusManager.clearFocus(force = true)
                                keyboardController?.hide()
                                onSend(composerValue.text)
                                hideComposerPopups()
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.AutoMirrored.Filled.Send,
                            contentDescription = "Send",
                            modifier = Modifier.size(actionIconSize),
                            tint = if (canSend) LitterTheme.surface else LitterTheme.textMuted
                        )
                    }
                }
        }
        }
    }
}

private const val LOCAL_IMAGE_MARKER_PREFIX = "[[litter_local_image:"
private const val LOCAL_IMAGE_MARKER_SUFFIX = "]]"

private enum class ComposerSlashCommand(
    val rawValue: String,
    val description: String,
) {
    MODEL(rawValue = "model", description = "choose what model and reasoning effort to use"),
    PERMISSIONS(rawValue = "permissions", description = "choose what Codex is allowed to do"),
    EXPERIMENTAL(rawValue = "experimental", description = "toggle experimental features"),
    SKILLS(rawValue = "skills", description = "use skills to improve how Codex performs specific tasks"),
    REVIEW(rawValue = "review", description = "review my current changes and find issues"),
    RENAME(rawValue = "rename", description = "rename the current thread"),
    NEW(rawValue = "new", description = "start a new chat during a conversation"),
    RESUME(rawValue = "resume", description = "resume a saved chat"),

    ;

    companion object {
        fun fromRawCommand(value: String): ComposerSlashCommand? =
            values().firstOrNull { it.rawValue == value.trim().lowercase(Locale.ROOT) }
    }
}

private enum class ComposerPermissionPreset(
    val title: String,
    val description: String,
    val approvalPolicy: String,
    val sandboxMode: String,
) {
    READ_ONLY(
        title = "Read Only",
        description = "Ask before commands and run in read-only sandbox",
        approvalPolicy = "on-request",
        sandboxMode = "read-only",
    ),
    AUTO(
        title = "Auto",
        description = "No prompts and workspace-write sandbox",
        approvalPolicy = "never",
        sandboxMode = "workspace-write",
    ),
    FULL_ACCESS(
        title = "Full Access",
        description = "No prompts and danger-full-access sandbox",
        approvalPolicy = "never",
        sandboxMode = "danger-full-access",
    ),
}

private data class ComposerTokenContext(
    val value: String,
    val range: TextRange,
)

private data class ComposerSlashQueryContext(
    val query: String,
    val range: TextRange,
)

private data class ComposerSlashInvocation(
    val command: ComposerSlashCommand,
    val args: String?,
)

private fun filterSlashCommands(query: String): List<ComposerSlashCommand> {
    if (query.isEmpty()) {
        return ComposerSlashCommand.values().toList()
    }
    return ComposerSlashCommand.values()
        .mapNotNull { command ->
            val score = fuzzyScore(candidate = command.rawValue, query = query) ?: return@mapNotNull null
            command to score
        }
        .sortedWith(
            compareByDescending<Pair<ComposerSlashCommand, Int>> { it.second }
                .thenBy { it.first.rawValue },
        )
        .map { it.first }
}

private fun fuzzyScore(
    candidate: String,
    query: String,
): Int? {
    val normalizedCandidate = candidate.lowercase(Locale.ROOT)
    val normalizedQuery = query.lowercase(Locale.ROOT)

    if (normalizedCandidate == normalizedQuery) {
        return 1000
    }
    if (normalizedCandidate.startsWith(normalizedQuery)) {
        return 900 - (normalizedCandidate.length - normalizedQuery.length)
    }
    if (normalizedCandidate.contains(normalizedQuery)) {
        return 700 - (normalizedCandidate.length - normalizedQuery.length)
    }

    var score = 0
    var queryIndex = 0
    var candidateIndex = 0
    while (queryIndex < normalizedQuery.length && candidateIndex < normalizedCandidate.length) {
        if (normalizedQuery[queryIndex] == normalizedCandidate[candidateIndex]) {
            score += 10
            queryIndex += 1
        }
        candidateIndex += 1
    }
    return if (queryIndex == normalizedQuery.length) score else null
}

private fun parseSlashCommandInvocation(text: String): ComposerSlashInvocation? {
    val firstLine = text.lineSequence().firstOrNull()?.trim().orEmpty()
    if (!firstLine.startsWith("/")) {
        return null
    }
    val body = firstLine.drop(1)
    if (body.isEmpty()) {
        return null
    }
    val commandName = body.substringBefore(' ').trim()
    if (commandName.isEmpty()) {
        return null
    }
    val command = ComposerSlashCommand.fromRawCommand(commandName) ?: return null
    val args = body.substringAfter(' ', "").trim().ifEmpty { null }
    return ComposerSlashInvocation(command = command, args = args)
}

private fun currentPrefixedToken(
    text: String,
    cursor: Int,
    prefix: Char,
    allowEmpty: Boolean,
): ComposerTokenContext? {
    val tokenRange = tokenRangeAroundCursor(text = text, cursor = cursor) ?: return null
    val token = text.substring(tokenRange.start, tokenRange.end)
    if (!token.startsWith(prefix)) {
        return null
    }
    val value = token.drop(1)
    if (value.isEmpty() && !allowEmpty) {
        return null
    }
    return ComposerTokenContext(value = value, range = tokenRange)
}

private fun currentSlashQueryContext(
    text: String,
    cursor: Int,
): ComposerSlashQueryContext? {
    val safeCursor = cursor.coerceIn(0, text.length)
    val firstLineEnd = text.indexOf('\n').takeIf { it >= 0 } ?: text.length
    if (safeCursor > firstLineEnd || firstLineEnd <= 0) {
        return null
    }

    val firstLine = text.substring(0, firstLineEnd)
    if (!firstLine.startsWith("/")) {
        return null
    }

    var commandEnd = 1
    while (commandEnd < firstLine.length && !firstLine[commandEnd].isWhitespace()) {
        commandEnd += 1
    }
    if (safeCursor > commandEnd) {
        return null
    }

    val query = if (commandEnd > 1) firstLine.substring(1, commandEnd) else ""
    val rest = if (commandEnd < firstLine.length) firstLine.substring(commandEnd).trim() else ""

    if (query.isEmpty()) {
        if (rest.isNotEmpty()) {
            return null
        }
    } else if (query.contains('/')) {
        return null
    }

    return ComposerSlashQueryContext(query = query, range = TextRange(0, commandEnd))
}

private fun tokenRangeAroundCursor(
    text: String,
    cursor: Int,
): TextRange? {
    if (text.isEmpty()) {
        return null
    }

    val safeCursor = cursor.coerceIn(0, text.length)
    if (safeCursor < text.length && text[safeCursor].isWhitespace()) {
        var index = safeCursor
        while (index < text.length && text[index].isWhitespace()) {
            index += 1
        }
        if (index < text.length) {
            var end = index
            while (end < text.length && !text[end].isWhitespace()) {
                end += 1
            }
            return TextRange(index, end)
        }
    }

    var start = safeCursor
    while (start > 0 && !text[start - 1].isWhitespace()) {
        start -= 1
    }

    var end = safeCursor
    while (end < text.length && !text[end].isWhitespace()) {
        end += 1
    }

    if (end <= start) {
        return null
    }
    return TextRange(start, end)
}

private data class SystemCardTheme(
    val accent: Color,
)

private sealed interface MarkdownBlock {
    data class Text(
        val markdown: String,
    ) : MarkdownBlock

    data class Code(
        val language: String,
        val code: String,
    ) : MarkdownBlock
}

private sealed interface InlineSegment {
    data class Text(
        val value: String,
    ) : InlineSegment

    data class ImageBytes(
        val bytes: ByteArray,
    ) : InlineSegment

    data class LocalImagePath(
        val path: String,
    ) : InlineSegment
}

private fun splitMarkdownCodeBlocks(markdown: String): List<MarkdownBlock> {
    val pattern = Regex("```([A-Za-z0-9_+\\-.#]*)\\n([\\s\\S]*?)```")
    val blocks = ArrayList<MarkdownBlock>()
    var cursor = 0
    pattern.findAll(markdown).forEach { match ->
        if (match.range.first > cursor) {
            val text = markdown.substring(cursor, match.range.first)
            if (text.isNotBlank()) {
                blocks += MarkdownBlock.Text(text)
            }
        }
        val language = match.groups[1]?.value?.trim().orEmpty()
        val code = match.groups[2]?.value?.trimEnd('\n').orEmpty()
        blocks += MarkdownBlock.Code(language = language, code = code)
        cursor = match.range.last + 1
    }
    if (cursor < markdown.length) {
        val trailing = markdown.substring(cursor)
        if (trailing.isNotBlank()) {
            blocks += MarkdownBlock.Text(trailing)
        }
    }
    return if (blocks.isEmpty()) listOf(MarkdownBlock.Text(markdown)) else blocks
}

private fun extractInlineSegments(markdown: String): List<InlineSegment> {
    val pattern =
        Regex(
            "!\\[[^\\]]*\\]\\(([^)]+)\\)|(?<![\\(])(data:image/[^;]+;base64,[A-Za-z0-9+/=\\s]+)",
        )
    val segments = ArrayList<InlineSegment>()
    var cursor = 0
    pattern.findAll(markdown).forEach { match ->
        val range = match.range
        if (range.first > cursor) {
            val text = markdown.substring(cursor, range.first)
            if (text.isNotBlank()) {
                segments += InlineSegment.Text(text)
            }
        }

        val full = match.value
        val markdownImageUrl = match.groups[1]?.value
        val bareDataUri = match.groups[2]?.value
        var handled = false

        if (!markdownImageUrl.isNullOrBlank()) {
            val fromDataUri = decodeBase64DataUri(markdownImageUrl)
            if (fromDataUri != null) {
                segments += InlineSegment.ImageBytes(fromDataUri)
                handled = true
            } else {
                val localPath = resolveLocalImagePath(markdownImageUrl)
                if (localPath != null && File(localPath).exists()) {
                    segments += InlineSegment.LocalImagePath(localPath)
                    handled = true
                }
            }
        } else if (!bareDataUri.isNullOrBlank()) {
            val decoded = decodeBase64DataUri(bareDataUri)
            if (decoded != null) {
                segments += InlineSegment.ImageBytes(decoded)
                handled = true
            }
        }

        if (!handled && full.isNotBlank()) {
            segments += InlineSegment.Text(full)
        }
        cursor = range.last + 1
    }

    if (cursor < markdown.length) {
        val tail = markdown.substring(cursor)
        if (tail.isNotBlank()) {
            segments += InlineSegment.Text(tail)
        }
    }

    if (segments.isEmpty()) {
        return listOf(InlineSegment.Text(markdown))
    }
    return mergeAdjacentTextSegments(segments)
}

private fun mergeAdjacentTextSegments(segments: List<InlineSegment>): List<InlineSegment> {
    if (segments.size < 2) {
        return segments
    }
    val merged = ArrayList<InlineSegment>(segments.size)
    var textBuffer: StringBuilder? = null

    fun flushText() {
        val text = textBuffer?.toString()?.trim()
        if (!text.isNullOrEmpty()) {
            merged += InlineSegment.Text(text)
        }
        textBuffer = null
    }

    for (segment in segments) {
        when (segment) {
            is InlineSegment.Text -> {
                val buffer = textBuffer ?: StringBuilder().also { textBuffer = it }
                if (buffer.isNotEmpty()) {
                    buffer.append('\n')
                }
                buffer.append(segment.value)
            }

            else -> {
                flushText()
                merged += segment
            }
        }
    }
    flushText()
    return merged
}

private fun decodeBase64DataUri(uri: String): ByteArray? {
    val trimmed = uri.trim()
    if (!trimmed.startsWith("data:image/", ignoreCase = true)) {
        return null
    }
    val commaIndex = trimmed.indexOf(',')
    if (commaIndex <= 0 || commaIndex >= trimmed.lastIndex) {
        return null
    }
    val base64 = trimmed.substring(commaIndex + 1).replace("\\s".toRegex(), "")
    return runCatching { Base64.decode(base64, Base64.DEFAULT) }.getOrNull()
}

private fun resolveLocalImagePath(rawUrl: String): String? {
    val trimmed = rawUrl.trim().removePrefix("<").removeSuffix(">")
    if (trimmed.startsWith("file://")) {
        return Uri.parse(trimmed).path?.trim()?.takeIf { it.isNotEmpty() }
    }
    if (trimmed.startsWith("/")) {
        return trimmed
    }
    return null
}

private fun extractSystemTitleAndBody(text: String): Pair<String?, String> {
    val trimmed = text.trim()
    if (!trimmed.startsWith("### ")) {
        return null to trimmed
    }
    val lines = trimmed.lines()
    if (lines.isEmpty()) {
        return null to ""
    }
    val title = lines.first().removePrefix("### ").trim().ifEmpty { null }
    val body = lines.drop(1).joinToString(separator = "\n").trim()
    return title to body
}

private fun isToolCallTitle(title: String?): Boolean {
    val lower = title?.lowercase().orEmpty()
    return lower.contains("command") ||
        lower.contains("file") ||
        lower.contains("mcp") ||
        lower.contains("web") ||
        lower.contains("collab") ||
        lower.contains("image")
}

private fun compactSystemSummary(
    title: String?,
    body: String,
    toolCall: Boolean,
): String {
    if (!toolCall) {
        return title ?: "System"
    }

    val lower = title?.lowercase().orEmpty()
    val lines = body.lines().map { it.trim() }

    if (lower.contains("command")) {
        val commandStart = lines.indexOfFirst { it.startsWith("Command:") }
        if (commandStart >= 0 && commandStart + 2 < lines.size) {
            val raw = lines[commandStart + 2]
            val command =
                raw
                    .replace("/bin/zsh -lc '", "")
                    .replace("/bin/bash -lc '", "")
                    .removeSuffix("'")
                    .trim()
            val status =
                lines
                    .firstOrNull { it.startsWith("Status:") }
                    ?.removePrefix("Status:")
                    ?.trim()
                    .orEmpty()
            val duration =
                lines
                    .firstOrNull { it.startsWith("Duration:") }
                    ?.removePrefix("Duration:")
                    ?.trim()
                    .orEmpty()
            val statusSuffix =
                when {
                    status == "completed" -> " ✓"
                    status.isNotEmpty() -> " ($status)"
                    else -> ""
                }
            val durationSuffix = if (duration.isNotEmpty()) " $duration" else ""
            return "$command$statusSuffix$durationSuffix".trim()
        }
    }

    if (lower.contains("file")) {
        val paths = lines.filter { it.startsWith("Path: ") }.map { it.removePrefix("Path: ").trim() }
        if (paths.isNotEmpty()) {
            val first = paths.first().substringAfterLast('/').ifBlank { paths.first() }
            if (paths.size > 1) {
                return "$first +${paths.size - 1} files"
            }
            return first
        }
    }

    if (lower.contains("mcp")) {
        val tool = lines.firstOrNull { it.startsWith("Tool: ") }?.removePrefix("Tool: ")?.trim()
        val status = lines.firstOrNull { it.startsWith("Status: ") }?.removePrefix("Status: ")?.trim()
        if (!tool.isNullOrBlank()) {
            if (status == "completed") {
                return "$tool ✓"
            }
            if (!status.isNullOrBlank()) {
                return "$tool ($status)"
            }
            return tool
        }
    }

    if (lower.contains("web")) {
        val query = lines.firstOrNull { it.startsWith("Query: ") }?.removePrefix("Query: ")?.trim()
        if (!query.isNullOrBlank()) {
            return query
        }
    }

    if (lower.contains("image")) {
        val path = lines.firstOrNull { it.startsWith("Path: ") }?.removePrefix("Path: ")?.trim()
        if (!path.isNullOrBlank()) {
            return path.substringAfterLast('/').ifBlank { path }
        }
    }

    return title ?: "Tool Call"
}

private fun systemCardTheme(title: String?): SystemCardTheme {
    val lower = title?.lowercase().orEmpty()
    return when {
        lower.contains("command") -> SystemCardTheme(accent = Color(0xFFC7B072))
        lower.contains("file") -> SystemCardTheme(accent = Color(0xFF7CAFD9))
        lower.contains("mcp") -> SystemCardTheme(accent = Color(0xFFC797D8))
        lower.contains("web") -> SystemCardTheme(accent = Color(0xFF88C6C7))
        lower.contains("collab") -> SystemCardTheme(accent = Color(0xFF9BCF8E))
        lower.contains("image") -> SystemCardTheme(accent = Color(0xFFE3A66F))
        else -> SystemCardTheme(accent = LitterTheme.accent)
    }
}

private fun encodeDraftWithLocalImageAttachment(
    draft: String,
    localImagePath: String?,
): String {
    val trimmedPath = localImagePath?.trim().orEmpty()
    if (trimmedPath.isEmpty()) {
        return draft
    }
    return buildString {
        append(draft)
        if (isNotEmpty()) {
            append("\n\n")
        }
        append(LOCAL_IMAGE_MARKER_PREFIX)
        append(trimmedPath)
        append(LOCAL_IMAGE_MARKER_SUFFIX)
    }
}

private fun cacheAttachmentImage(
    context: Context,
    uri: Uri,
): String? {
    val resolver = context.contentResolver
    val mimeType = resolver.getType(uri).orEmpty().lowercase(Locale.US)
    val extension =
        when {
            mimeType.contains("png") -> "png"
            mimeType.contains("webp") -> "webp"
            else -> "jpg"
        }
    val targetDirectory = File(context.cacheDir, "litter-attachments")
    if (!targetDirectory.exists() && !targetDirectory.mkdirs()) {
        return null
    }
    val target = File(targetDirectory, "attachment_${System.currentTimeMillis()}.$extension")
    resolver.openInputStream(uri)?.use { input ->
        FileOutputStream(target).use { output ->
            input.copyTo(output)
        }
    } ?: return null
    return target.absolutePath
}

private fun cacheAttachmentBitmap(
    context: Context,
    bitmap: Bitmap,
): String? {
    val targetDirectory = File(context.cacheDir, "litter-attachments")
    if (!targetDirectory.exists() && !targetDirectory.mkdirs()) {
        return null
    }
    val target = File(targetDirectory, "capture_${System.currentTimeMillis()}.jpg")
    return runCatching {
        FileOutputStream(target).use { output ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, output)
        }
        target.absolutePath
    }.getOrNull()
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun DirectoryPickerSheet(
    connectedServers: List<ServerConfig>,
    selectedServerId: String?,
    path: String,
    entries: List<String>,
    isLoading: Boolean,
    error: String?,
    searchQuery: String,
    showHiddenDirectories: Boolean,
    onDismiss: () -> Unit,
    onServerSelected: (String) -> Unit,
    onSearchQueryChange: (String) -> Unit,
    onShowHiddenDirectoriesChange: (Boolean) -> Unit,
    onNavigateUp: () -> Unit,
    onNavigateInto: (String) -> Unit,
    onSelect: () -> Unit,
) {
    var serverMenuExpanded by remember { mutableStateOf(false) }
    val selectedServer = connectedServers.firstOrNull { it.id == selectedServerId }
    val selectedServerLabel =
        selectedServer?.let { "${it.name} * ${serverSourceLabel(it.source)}" } ?: "Select server"
    val trimmedQuery = searchQuery.trim()
    val visibleEntries =
        remember(entries, trimmedQuery, showHiddenDirectories) {
            entries
                .asSequence()
                .filter { showHiddenDirectories || !it.startsWith(".") }
                .filter { trimmedQuery.isEmpty() || it.contains(trimmedQuery, ignoreCase = true) }
                .sortedWith(compareBy<String> { it.lowercase(Locale.ROOT) }.thenBy { it })
                .toList()
        }
    val emptyMessage =
        if (trimmedQuery.isEmpty()) {
            "No subdirectories"
        } else {
            "No matches for \"$trimmedQuery\""
        }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Choose Directory", style = MaterialTheme.typography.titleMedium)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Server", color = LitterTheme.textSecondary, style = MaterialTheme.typography.labelLarge)
                Box {
                    OutlinedButton(
                        onClick = { serverMenuExpanded = true },
                        enabled = connectedServers.isNotEmpty(),
                    ) {
                        Text(
                            selectedServerLabel,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            style = MaterialTheme.typography.labelLarge,
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Icon(Icons.Default.ArrowDropDown, contentDescription = null, modifier = Modifier.size(14.dp))
                    }
                    DropdownMenu(
                        expanded = serverMenuExpanded,
                        onDismissRequest = { serverMenuExpanded = false },
                    ) {
                        connectedServers.forEach { server ->
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        "${server.name} * ${serverSourceLabel(server.source)}",
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                },
                                onClick = {
                                    serverMenuExpanded = false
                                    onServerSelected(server.id)
                                },
                            )
                        }
                    }
                }
            }
            Text(path.ifBlank { "/" }, color = LitterTheme.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)

            val canSelect = selectedServer != null && path.isNotBlank() && !isLoading
            val canGoUp = selectedServer != null && path.isNotBlank()
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onNavigateUp, enabled = canGoUp) {
                    Icon(Icons.Default.ArrowUpward, contentDescription = null, modifier = Modifier.size(14.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("Up")
                }
                Button(onClick = onSelect, enabled = canSelect) {
                    Text("Select")
                }
                TextButton(onClick = onDismiss) {
                    Icon(Icons.Default.Close, contentDescription = null, modifier = Modifier.size(14.dp))
                    Spacer(modifier = Modifier.width(4.dp))
                    Text("Cancel")
                }
            }

            OutlinedTextField(
                value = searchQuery,
                onValueChange = onSearchQueryChange,
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("Search folders") },
                singleLine = true,
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(
                    checked = showHiddenDirectories,
                    onCheckedChange = { checked ->
                        onShowHiddenDirectoriesChange(checked)
                    },
                )
                Text("Show hidden folders", color = LitterTheme.textSecondary)
            }

            when {
                isLoading -> {
                    Text("Loading...", color = LitterTheme.textMuted)
                }

                error != null -> {
                    Text(error, color = LitterTheme.danger)
                }

                visibleEntries.isEmpty() -> {
                    Text(emptyMessage, color = LitterTheme.textMuted)
                }

                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxWidth().fillMaxHeight(0.55f),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        items(visibleEntries, key = { it }) { entry ->
                            Surface(
                                modifier = Modifier.fillMaxWidth().clickable { onNavigateInto(entry) },
                                color = LitterTheme.surface.copy(alpha = 0.6f),
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

private enum class ManualField {
    HOST,
    PORT,
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
    val configuration = LocalConfiguration.current
    val useLargeScreenDialog =
        configuration.screenWidthDp >= 900 || configuration.smallestScreenWidthDp >= 600

    if (useLargeScreenDialog) {
        val discoveredRowFocusRequester = remember { FocusRequester() }
        val manualHostFocusRequester = remember { FocusRequester() }
        val manualPortFocusRequester = remember { FocusRequester() }
        val manualInlineEditorFocusRequester = remember { FocusRequester() }
        val manualInlineDoneFocusRequester = remember { FocusRequester() }
        val manualConnectFocusRequester = remember { FocusRequester() }
        var editingField by remember { mutableStateOf<ManualField?>(null) }
        var editingValue by remember { mutableStateOf("") }
        val canConnect = state.manualHost.isNotBlank() && state.manualPort.isNotBlank()
        val firstServerId = state.servers.firstOrNull()?.id

        BackHandler(enabled = editingField != null) {
            editingField = null
        }

        LaunchedEffect(editingField) {
            if (editingField != null) {
                // Avoid auto-opening the on-screen keyboard on TV; users can move up into the field to type.
                manualInlineDoneFocusRequester.requestFocus()
            }
        }

        Dialog(
            onDismissRequest = onDismiss,
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Box(
                modifier = Modifier.fillMaxSize().navigationBarsPadding().padding(24.dp),
                contentAlignment = Alignment.Center,
            ) {
                Surface(
                    modifier = Modifier.fillMaxWidth(0.9f).fillMaxHeight(0.9f),
                    color = LitterTheme.surface,
                    shape = RoundedCornerShape(14.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                ) {
                    Column(
                        modifier = Modifier.fillMaxSize().padding(horizontal = 18.dp, vertical = 14.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text("Connect Server", style = MaterialTheme.typography.titleLarge)
                                Text(
                                    "Pick a discovered server or enter one manually",
                                    color = LitterTheme.textSecondary,
                                    style = MaterialTheme.typography.labelLarge,
                                )
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                TextButton(onClick = onRefresh) {
                                    Text("Refresh")
                                }
                                TextButton(onClick = onDismiss) {
                                    Text("Close", color = LitterTheme.danger)
                                }
                            }
                        }

                        if (state.errorMessage != null) {
                            Text(state.errorMessage, color = LitterTheme.danger)
                        }

                        Row(
                            modifier = Modifier.fillMaxSize(),
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                            verticalAlignment = Alignment.Top,
                        ) {
                            Column(
                                modifier = Modifier.weight(1.35f).fillMaxHeight(),
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Text("Discovered", style = MaterialTheme.typography.titleMedium)
                                if (state.isLoading) {
                                    Text("Scanning local network and tailscale...", color = LitterTheme.textSecondary)
                                }

                                Surface(
                                    modifier = Modifier.fillMaxSize(),
                                    color = LitterTheme.surface.copy(alpha = 0.6f),
                                    shape = RoundedCornerShape(10.dp),
                                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                                ) {
                                    if (state.servers.isEmpty() && !state.isLoading) {
                                        Box(
                                            modifier = Modifier.fillMaxSize().padding(16.dp),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Text("No servers discovered", color = LitterTheme.textMuted)
                                        }
                                    } else {
                                        LazyColumn(
                                            modifier = Modifier.fillMaxSize().padding(8.dp),
                                            verticalArrangement = Arrangement.spacedBy(8.dp),
                                        ) {
                                            items(state.servers, key = { it.id }) { server ->
                                                Surface(
                                                    modifier =
                                                        Modifier
                                                            .fillMaxWidth()
                                                            .then(
                                                                if (server.id == firstServerId) {
                                                                    Modifier.focusRequester(discoveredRowFocusRequester)
                                                                } else {
                                                                    Modifier
                                                                },
                                                            )
                                                            .focusProperties {
                                                                right = manualHostFocusRequester
                                                            }.clickable { onConnectDiscovered(server.id) },
                                                    color = LitterTheme.surfaceLight.copy(alpha = 0.45f),
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
                                }
                            }

                            Column(
                                modifier = Modifier.weight(1f).fillMaxHeight(),
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Text("Manual", style = MaterialTheme.typography.titleMedium)
                                Surface(
                                    modifier = Modifier.fillMaxWidth(),
                                    color = LitterTheme.surface.copy(alpha = 0.6f),
                                    shape = RoundedCornerShape(10.dp),
                                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                                ) {
                                    Column(
                                        modifier = Modifier.fillMaxWidth().padding(12.dp),
                                        verticalArrangement = Arrangement.spacedBy(10.dp),
                                    ) {
                                        if (editingField == ManualField.HOST) {
                                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                                OutlinedTextField(
                                                    value = editingValue,
                                                    onValueChange = {
                                                        editingValue = it
                                                        onManualHostChanged(it.trim())
                                                    },
                                                    modifier =
                                                        Modifier
                                                            .fillMaxWidth()
                                                            .focusRequester(manualInlineEditorFocusRequester)
                                                            .focusProperties {
                                                                down = manualInlineDoneFocusRequester
                                                                if (state.servers.isNotEmpty()) {
                                                                    up = discoveredRowFocusRequester
                                                                }
                                                            }
                                                            .onPreviewKeyEvent { event ->
                                                                if (event.type != KeyEventType.KeyDown) {
                                                                    return@onPreviewKeyEvent false
                                                                }
                                                                when (event.key) {
                                                                    Key.Back, Key.Escape -> {
                                                                        editingField = null
                                                                        true
                                                                    }

                                                                    Key.DirectionDown -> {
                                                                        manualInlineDoneFocusRequester.requestFocus()
                                                                        true
                                                                    }

                                                                    Key.DirectionUp -> {
                                                                        if (state.servers.isNotEmpty()) {
                                                                            discoveredRowFocusRequester.requestFocus()
                                                                            true
                                                                        } else {
                                                                            false
                                                                        }
                                                                    }

                                                                    else -> false
                                                                }
                                                            },
                                                    singleLine = true,
                                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                                                    label = { Text("Host") },
                                                )
                                                Row(
                                                    modifier = Modifier.fillMaxWidth(),
                                                    horizontalArrangement = Arrangement.SpaceBetween,
                                                    verticalAlignment = Alignment.CenterVertically,
                                                ) {
                                                    Text(
                                                        "Editing host",
                                                        color = LitterTheme.textMuted,
                                                        style = MaterialTheme.typography.labelLarge,
                                                    )
                                                    TextButton(
                                                        onClick = { editingField = null },
                                                        modifier =
                                                            Modifier
                                                                .focusRequester(manualInlineDoneFocusRequester)
                                                                .focusProperties {
                                                                    up = manualInlineEditorFocusRequester
                                                                    down = manualPortFocusRequester
                                                                },
                                                    ) {
                                                        Text("Done")
                                                    }
                                                }
                                            }
                                        } else {
                                            Surface(
                                                modifier =
                                                    Modifier
                                                        .fillMaxWidth()
                                                        .focusRequester(manualHostFocusRequester)
                                                        .focusProperties {
                                                            if (state.servers.isNotEmpty()) {
                                                                up = discoveredRowFocusRequester
                                                            }
                                                            down = manualPortFocusRequester
                                                        }.clickable {
                                                            editingField = ManualField.HOST
                                                            editingValue = state.manualHost
                                                        },
                                                color = LitterTheme.surfaceLight.copy(alpha = 0.65f),
                                                shape = RoundedCornerShape(8.dp),
                                                border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                                            ) {
                                                Column(
                                                    modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
                                                    verticalArrangement = Arrangement.spacedBy(2.dp),
                                                ) {
                                                    Text("Host", color = LitterTheme.textSecondary, style = MaterialTheme.typography.labelLarge)
                                                    Text(
                                                        if (state.manualHost.isBlank()) "Set host" else state.manualHost,
                                                        color = if (state.manualHost.isBlank()) LitterTheme.textMuted else LitterTheme.textPrimary,
                                                        maxLines = 1,
                                                        overflow = TextOverflow.Ellipsis,
                                                    )
                                                }
                                            }
                                        }

                                        if (editingField == ManualField.PORT) {
                                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                                OutlinedTextField(
                                                    value = editingValue,
                                                    onValueChange = {
                                                        val digitsOnly = it.filter { ch -> ch.isDigit() }
                                                        editingValue = digitsOnly
                                                        onManualPortChanged(digitsOnly)
                                                    },
                                                    modifier =
                                                        Modifier
                                                            .fillMaxWidth()
                                                            .focusRequester(manualInlineEditorFocusRequester)
                                                            .focusProperties {
                                                                up = manualHostFocusRequester
                                                                down = manualInlineDoneFocusRequester
                                                            }
                                                            .onPreviewKeyEvent { event ->
                                                                if (event.type != KeyEventType.KeyDown) {
                                                                    return@onPreviewKeyEvent false
                                                                }
                                                                when (event.key) {
                                                                    Key.Back, Key.Escape -> {
                                                                        editingField = null
                                                                        true
                                                                    }

                                                                    Key.DirectionDown -> {
                                                                        manualInlineDoneFocusRequester.requestFocus()
                                                                        true
                                                                    }

                                                                    Key.DirectionUp -> {
                                                                        manualHostFocusRequester.requestFocus()
                                                                        true
                                                                    }

                                                                    else -> false
                                                                }
                                                            },
                                                    singleLine = true,
                                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                                    label = { Text("Port") },
                                                )
                                                Row(
                                                    modifier = Modifier.fillMaxWidth(),
                                                    horizontalArrangement = Arrangement.SpaceBetween,
                                                    verticalAlignment = Alignment.CenterVertically,
                                                ) {
                                                    Text(
                                                        "Editing port",
                                                        color = LitterTheme.textMuted,
                                                        style = MaterialTheme.typography.labelLarge,
                                                    )
                                                    TextButton(
                                                        onClick = { editingField = null },
                                                        modifier =
                                                            Modifier
                                                                .focusRequester(manualInlineDoneFocusRequester)
                                                                .focusProperties {
                                                                    up = manualInlineEditorFocusRequester
                                                                    down = if (canConnect) manualConnectFocusRequester else manualHostFocusRequester
                                                                },
                                                    ) {
                                                        Text("Done")
                                                    }
                                                }
                                            }
                                        } else {
                                            Surface(
                                                modifier =
                                                    Modifier
                                                        .fillMaxWidth()
                                                        .focusRequester(manualPortFocusRequester)
                                                        .focusProperties {
                                                            up = manualHostFocusRequester
                                                            down = if (canConnect) manualConnectFocusRequester else manualHostFocusRequester
                                                        }.clickable {
                                                            editingField = ManualField.PORT
                                                            editingValue = state.manualPort
                                                        },
                                                color = LitterTheme.surfaceLight.copy(alpha = 0.65f),
                                                shape = RoundedCornerShape(8.dp),
                                                border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                                            ) {
                                                Column(
                                                    modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
                                                    verticalArrangement = Arrangement.spacedBy(2.dp),
                                                ) {
                                                    Text("Port", color = LitterTheme.textSecondary, style = MaterialTheme.typography.labelLarge)
                                                    Text(
                                                        if (state.manualPort.isBlank()) "Set port" else state.manualPort,
                                                        color = if (state.manualPort.isBlank()) LitterTheme.textMuted else LitterTheme.textPrimary,
                                                        maxLines = 1,
                                                        overflow = TextOverflow.Ellipsis,
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                                Spacer(modifier = Modifier.weight(1f))
                                Button(
                                    onClick = onConnectManual,
                                    modifier =
                                        Modifier
                                            .fillMaxWidth()
                                            .focusRequester(manualConnectFocusRequester)
                                            .focusProperties {
                                                up = if (editingField != null) manualInlineEditorFocusRequester else manualPortFocusRequester
                                            },
                                    enabled = canConnect,
                                ) {
                                    Text("Connect Manual Server")
                                }
                            }
                        }
                    }
                }
            }
        }
        return
    }

    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().fillMaxHeight(0.9f).padding(horizontal = 12.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.Center,
            ) {
                BrandLogo(size = 86.dp)
            }
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
                Text(state.errorMessage, color = LitterTheme.danger)
            }

            if (state.servers.isEmpty() && !state.isLoading) {
                Text("No servers discovered", color = LitterTheme.textMuted)
            } else {
                LazyColumn(
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .weight(1f, fill = false)
                            .heightIn(min = 140.dp, max = 320.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    items(state.servers, key = { it.id }) { server ->
                        Surface(
                            modifier = Modifier.fillMaxWidth().clickable { onConnectDiscovered(server.id) },
                            color = LitterTheme.surface.copy(alpha = 0.6f),
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

            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
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
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun SshLoginSheet(
    state: SshLoginUiState,
    onDismiss: () -> Unit,
    onUsernameChanged: (String) -> Unit,
    onPasswordChanged: (String) -> Unit,
    onUseKeyChanged: (Boolean) -> Unit,
    onPrivateKeyChanged: (String) -> Unit,
    onPassphraseChanged: (String) -> Unit,
    onRememberChanged: (Boolean) -> Unit,
    onForgetSaved: () -> Unit,
    onConnect: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("SSH Login", style = MaterialTheme.typography.titleMedium)
            Text(
                "${state.serverName.ifBlank { state.host }} (${state.host}:${state.port})",
                color = LitterTheme.textSecondary,
                style = MaterialTheme.typography.labelLarge,
            )

            OutlinedTextField(
                value = state.username,
                onValueChange = onUsernameChanged,
                label = { Text("Username") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedButton(
                    onClick = { onUseKeyChanged(false) },
                    modifier = Modifier.weight(1f),
                    border = androidx.compose.foundation.BorderStroke(1.dp, if (!state.useKey) LitterTheme.accent else LitterTheme.border),
                ) {
                    Text("Password")
                }
                OutlinedButton(
                    onClick = { onUseKeyChanged(true) },
                    modifier = Modifier.weight(1f),
                    border = androidx.compose.foundation.BorderStroke(1.dp, if (state.useKey) LitterTheme.accent else LitterTheme.border),
                ) {
                    Text("SSH Key")
                }
            }

            if (state.useKey) {
                OutlinedTextField(
                    value = state.privateKey,
                    onValueChange = onPrivateKeyChanged,
                    label = { Text("Private Key") },
                    placeholder = { Text("Paste private key PEM...") },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 5,
                    maxLines = 10,
                )
                OutlinedTextField(
                    value = state.passphrase,
                    onValueChange = onPassphraseChanged,
                    label = { Text("Passphrase (optional)") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
            } else {
                OutlinedTextField(
                    value = state.password,
                    onValueChange = onPasswordChanged,
                    label = { Text("Password") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(
                        checked = state.rememberCredentials,
                        onCheckedChange = onRememberChanged,
                    )
                    Text("Remember on this device", color = LitterTheme.textSecondary)
                }
                if (state.hasSavedCredentials) {
                    TextButton(onClick = onForgetSaved) {
                        Text("Forget Saved", color = LitterTheme.danger)
                    }
                }
            }

            if (state.errorMessage != null) {
                Text(state.errorMessage, color = LitterTheme.danger, style = MaterialTheme.typography.labelLarge)
            }

            Button(
                onClick = onConnect,
                modifier = Modifier.fillMaxWidth(),
                enabled =
                    !state.isConnecting &&
                        state.username.isNotBlank() &&
                        if (state.useKey) state.privateKey.isNotBlank() else state.password.isNotBlank(),
            ) {
                Text(if (state.isConnecting) "Connecting..." else "Connect")
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
    val configuration = LocalConfiguration.current
    val useLargeScreenDialog =
        configuration.screenWidthDp >= 900 || configuration.smallestScreenWidthDp >= 600

    if (useLargeScreenDialog) {
        Dialog(
            onDismissRequest = onDismiss,
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Box(
                modifier = Modifier.fillMaxSize().navigationBarsPadding().padding(24.dp),
                contentAlignment = Alignment.Center,
            ) {
                Surface(
                    modifier = Modifier.fillMaxWidth(0.9f).fillMaxHeight(0.9f),
                    color = LitterTheme.surface,
                    shape = RoundedCornerShape(14.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                ) {
                    SettingsSheetContent(
                        accountState = accountState,
                        connectedServers = connectedServers,
                        onDismiss = onDismiss,
                        onOpenAccount = onOpenAccount,
                        onOpenDiscovery = onOpenDiscovery,
                        onRemoveServer = onRemoveServer,
                        modifier = Modifier.fillMaxSize().padding(horizontal = 18.dp, vertical = 14.dp),
                    )
                }
            }
        }
        return
    }

    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
    ) {
        SettingsSheetContent(
            accountState = accountState,
            connectedServers = connectedServers,
            onDismiss = null,
            onOpenAccount = onOpenAccount,
            onOpenDiscovery = onOpenDiscovery,
            onRemoveServer = onRemoveServer,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
        )
    }
}

@Composable
private fun SettingsSheetContent(
    accountState: AccountState,
    connectedServers: List<ServerConfig>,
    onDismiss: (() -> Unit)?,
    onOpenAccount: () -> Unit,
    onOpenDiscovery: () -> Unit,
    onRemoveServer: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (onDismiss == null) {
            Text("Settings", style = MaterialTheme.typography.titleMedium)
        } else {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text("Settings", style = MaterialTheme.typography.titleMedium)
                TextButton(onClick = onDismiss) {
                    Text("Close", color = LitterTheme.danger)
                }
            }
        }

        Text("Authentication", color = LitterTheme.textSecondary, style = MaterialTheme.typography.labelLarge)
        Surface(
            modifier = Modifier.fillMaxWidth().clickable { onOpenAccount() },
            color = LitterTheme.surface.copy(alpha = 0.6f),
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
                    color = LitterTheme.surface.copy(alpha = 0.6f),
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
                            Text("Remove", color = LitterTheme.danger)
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
                color = LitterTheme.surface.copy(alpha = 0.6f),
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
                            Text("Logout", color = LitterTheme.danger)
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
                    color = LitterTheme.surface.copy(alpha = 0.6f),
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
                                Text("Cancel", color = LitterTheme.danger)
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
                Text(accountState.lastError, color = LitterTheme.danger, style = MaterialTheme.typography.labelLarge)
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

private fun serverSourceAccentColor(source: ServerSource): Color =
    when (source) {
        ServerSource.LOCAL -> LitterTheme.accent
        ServerSource.BONJOUR -> LitterTheme.accent
        ServerSource.SSH -> LitterTheme.accent
        ServerSource.TAILSCALE -> LitterTheme.accent
        ServerSource.MANUAL -> LitterTheme.accent
        ServerSource.REMOTE -> LitterTheme.accent
    }

private fun cwdLeaf(path: String): String {
    val trimmed = normalizeFolderPath(path)
    if (trimmed == "/") {
        return "/"
    }
    return trimmed.substringAfterLast('/')
}

private fun normalizeFolderPath(path: String): String {
    val trimmed = path.trim()
    if (trimmed.isEmpty()) {
        return "/"
    }

    var normalized = trimmed.replace(Regex("/+"), "/")
    while (normalized.length > 1 && normalized.endsWith("/")) {
        normalized = normalized.dropLast(1)
    }
    return if (normalized.isEmpty()) "/" else normalized
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
