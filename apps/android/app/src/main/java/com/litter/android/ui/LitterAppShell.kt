package com.litter.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Typeface
import android.net.Uri
import android.text.format.DateUtils
import android.util.Base64
import android.util.Log
import android.widget.TextView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.BackHandler
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.core.RepeatMode
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
import androidx.compose.foundation.layout.height
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
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Tune
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
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
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
import com.litter.android.state.SkillMentionInput
import com.litter.android.state.SkillMetadata
import com.litter.android.state.ThreadKey
import com.litter.android.state.ThreadState
import com.sigkitten.litter.android.BuildConfig
import com.sigkitten.litter.android.R
import io.noties.markwon.Markwon
import io.noties.markwon.syntax.Prism4jThemeDarkula
import io.noties.markwon.syntax.SyntaxHighlightPlugin
import io.noties.prism4j.GrammarLocator
import io.noties.prism4j.Prism4j
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.LinkedHashMap
import java.util.Locale

private const val PERF_LOG_TAG = "LitterComposePerf"

private fun Context.monospaceTypeface(): Typeface = Typeface.MONOSPACE

@Composable
private fun DebugRecomposeCheckpoint(name: String) {
    if (!BuildConfig.DEBUG) {
        return
    }
    val counter = remember(name) { mutableIntStateOf(0) }
    SideEffect {
        counter.intValue += 1
        if (counter.intValue == 1 || counter.intValue % 25 == 0) {
            Log.d(PERF_LOG_TAG, "$name recomposed ${counter.intValue}x")
        }
    }
}

@Composable
fun LitterAppShell(
    appState: LitterAppState,
    modifier: Modifier = Modifier,
) {
    val uiState by appState.uiState.collectAsStateWithLifecycle()
    DebugRecomposeCheckpoint(name = "LitterAppShell")
    val drawerWidth = 350.dp

    Box(modifier = modifier.fillMaxSize().background(LitterTheme.backgroundBrush)) {
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
                    onForkConversation = appState::forkConversation,
                    onEditMessage = appState::editMessage,
                    onForkFromMessage = appState::forkConversationFromMessage,
                    onSend = { payloadDraft, skillMentions ->
                        appState.updateDraft(payloadDraft)
                        appState.sendDraft(skillMentions)
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

        AnimatedVisibility(
            visible = uiState.isSidebarOpen,
            enter = slideInHorizontally(animationSpec = tween(durationMillis = 220)) { fullWidth -> -fullWidth } + fadeIn(animationSpec = tween(durationMillis = 220)),
            exit = slideOutHorizontally(animationSpec = tween(durationMillis = 200)) { fullWidth -> -fullWidth } + fadeOut(animationSpec = tween(durationMillis = 200)),
        ) {
            SessionSidebar(
                modifier =
                    Modifier
                        .fillMaxHeight()
                        .width(drawerWidth),
                connectionStatus = uiState.connectionStatus,
                connectedServers = uiState.connectedServers,
                sessions = uiState.sessions,
                isSidebarOpen = uiState.isSidebarOpen,
                sessionSearchQuery = uiState.sessionSearchQuery,
                selectedServerFilterId = uiState.sessionServerFilterId,
                showOnlyForks = uiState.sessionShowOnlyForks,
                workspaceSortModeRaw = uiState.sessionWorkspaceSortModeRaw,
                activeThreadKey = uiState.activeThreadKey,
                onSessionSelected = appState::selectSession,
                onSessionSearchQueryChange = appState::updateSessionSearchQuery,
                onSessionServerFilterChange = appState::updateSessionServerFilter,
                onSessionShowOnlyForksChange = appState::updateSessionShowOnlyForks,
                onSessionWorkspaceSortModeChange = appState::updateSessionWorkspaceSortMode,
                onClearSessionFilters = appState::clearSessionFilters,
                onNewSession = {
                    appState.dismissSidebar()
                    appState.openNewSessionPicker()
                },
                onRefresh = appState::refreshSessions,
                onForkConversation = appState::forkConversation,
                onForkSession = appState::forkSession,
                onRenameSession = appState::renameSession,
                onArchiveSession = appState::archiveSession,
                onOpenDiscovery = {
                    appState.dismissSidebar()
                    appState.openDiscovery()
                },
                onOpenSettings = {
                    appState.dismissSidebar()
                    appState.openSettings()
                },
            )
        }

        if (uiState.directoryPicker.isVisible) {
            DirectoryPickerSheet(
                connectedServers = uiState.connectedServers,
                selectedServerId = uiState.directoryPicker.selectedServerId,
                path = uiState.directoryPicker.currentPath,
                entries = uiState.directoryPicker.entries,
                recentDirectories = uiState.directoryPicker.recentDirectories,
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
                onNavigateToPath = appState::navigateDirectoryToPath,
                onSelect = appState::confirmStartSessionFromPicker,
                onSelectRecent = appState::startSessionFromRecent,
                onRemoveRecentDirectory = appState::removeRecentDirectory,
                onClearRecentDirectories = appState::clearRecentDirectories,
                onRetry = appState::reloadDirectoryPicker,
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
                onCopyBundledLogs = appState::copyBundledLogs,
                onOpenDiscovery = appState::openDiscovery,
                onRemoveServer = appState::removeServer,
            )
        }

        if (uiState.showAccount) {
            val activeServer = uiState.connectedServers.firstOrNull { it.id == uiState.activeServerId }
            AccountSheet(
                accountState = uiState.accountState,
                activeServerSource = activeServer?.source,
                apiKeyDraft = uiState.apiKeyDraft,
                isWorking = uiState.isAuthWorking,
                onDismiss = appState::dismissAccount,
                onApiKeyDraftChanged = appState::updateApiKeyDraft,
                onLoginWithChatGpt = appState::loginWithChatGpt,
                onLoginWithApiKey = appState::loginWithApiKey,
                onLogout = appState::logoutAccount,
                onCancelLogin = appState::cancelLogin,
                onCopyBundledLogs = appState::copyBundledLogs,
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
            ServerConnectionStatus.CONNECTING -> LitterTheme.statusConnecting
            ServerConnectionStatus.READY -> LitterTheme.statusReady
            ServerConnectionStatus.ERROR -> LitterTheme.statusError
            ServerConnectionStatus.DISCONNECTED -> LitterTheme.statusDisconnected
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
                    Text(stringResource(R.string.connect_to_server), color = LitterTheme.accent)
                }
            }
        }
    }
}

@Composable
private fun SessionSidebar(
    modifier: Modifier = Modifier,
    connectionStatus: ServerConnectionStatus,
    connectedServers: List<ServerConfig>,
    sessions: List<ThreadState>,
    isSidebarOpen: Boolean,
    sessionSearchQuery: String,
    selectedServerFilterId: String?,
    showOnlyForks: Boolean,
    workspaceSortModeRaw: String,
    activeThreadKey: ThreadKey?,
    onSessionSelected: (ThreadKey) -> Unit,
    onSessionSearchQueryChange: (String) -> Unit,
    onSessionServerFilterChange: (String?) -> Unit,
    onSessionShowOnlyForksChange: (Boolean) -> Unit,
    onSessionWorkspaceSortModeChange: (String) -> Unit,
    onClearSessionFilters: () -> Unit,
    onNewSession: () -> Unit,
    onRefresh: () -> Unit,
    onForkConversation: () -> Unit,
    onForkSession: (ThreadKey) -> Unit,
    onRenameSession: (ThreadKey, String, (Result<Unit>) -> Unit) -> Unit,
    onArchiveSession: (ThreadKey) -> Unit,
    onOpenDiscovery: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    DebugRecomposeCheckpoint(name = "SessionSidebar")
    var isServerFilterMenuOpen by remember { mutableStateOf(false) }
    var isSortMenuOpen by remember { mutableStateOf(false) }
    val workspaceSortMode = remember(workspaceSortModeRaw) { WorkspaceSortMode.fromRaw(workspaceSortModeRaw) }
    val collapsedWorkspaceIdsSaver =
        remember {
            listSaver<Set<String>, String>(
                save = { it.toList() },
                restore = { restored -> restored.toSet() },
            )
        }
    var collapsedWorkspaceGroupIds by rememberSaveable(stateSaver = collapsedWorkspaceIdsSaver) { mutableStateOf(setOf<String>()) }
    val collapsedSessionNodeIdsSaver =
        remember {
            listSaver<Set<String>, String>(
                save = { it.toList() },
                restore = { restored -> restored.toSet() },
            )
        }
    var collapsedSessionNodeIds by rememberSaveable(stateSaver = collapsedSessionNodeIdsSaver) { mutableStateOf(setOf<String>()) }
    var rowMenuThreadKey by remember { mutableStateOf<ThreadKey?>(null) }
    var renameTargetThread by remember { mutableStateOf<ThreadState?>(null) }
    var renameDraft by remember { mutableStateOf("") }
    var renameError by remember { mutableStateOf<String?>(null) }
    var archiveTargetThread by remember { mutableStateOf<ThreadState?>(null) }
    val sessionListState = rememberLazyListState()
    var pendingActiveSessionScroll by remember { mutableStateOf(false) }

    LaunchedEffect(isSidebarOpen) {
        pendingActiveSessionScroll = isSidebarOpen
    }

    LaunchedEffect(connectedServers, selectedServerFilterId) {
        if (selectedServerFilterId != null && connectedServers.none { it.id == selectedServerFilterId }) {
            onSessionServerFilterChange(null)
        }
    }

    val lineageIndex = remember(sessions) { buildThreadLineageIndex(sessions) }
    val normalizedQuery by remember(sessionSearchQuery) {
        derivedStateOf { sessionSearchQuery.trim().lowercase(Locale.ROOT) }
    }
    val filteredSessions by
        remember(sessions, selectedServerFilterId, showOnlyForks, normalizedQuery, lineageIndex.searchableTextByKey) {
            derivedStateOf {
                sessions
                    .asSequence()
                    .filter { thread ->
                        val serverMatches = selectedServerFilterId == null || thread.key.serverId == selectedServerFilterId
                        val forkMatches = !showOnlyForks || thread.isFork
                        val searchMatches =
                            normalizedQuery.isEmpty() ||
                                matchesSessionSearch(
                                    thread = thread,
                                    normalizedQuery = normalizedQuery,
                                    searchableTextByKey = lineageIndex.searchableTextByKey,
                                )
                        serverMatches && forkMatches && searchMatches
                    }.toList()
            }
        }
    val workspaceGroups by
        remember(filteredSessions, workspaceSortMode) {
            derivedStateOf { groupSessionsByWorkspace(filteredSessions, workspaceSortMode) }
        }
    val workspaceSections by
        remember(workspaceGroups, workspaceSortMode) {
            derivedStateOf { buildWorkspaceSections(workspaceGroups, workspaceSortMode) }
        }
    val activeWorkspaceGroupId by
        remember(workspaceGroups, activeThreadKey) {
            derivedStateOf {
                val targetKey = activeThreadKey ?: return@derivedStateOf null
                workspaceGroups.firstOrNull { group -> group.threads.any { it.key == targetKey } }?.id
            }
        }
    val activeSessionItemIndex by
        remember(workspaceSections, collapsedWorkspaceGroupIds, collapsedSessionNodeIds, activeThreadKey, lineageIndex.parentByKey) {
            derivedStateOf {
                val targetKey = activeThreadKey ?: return@derivedStateOf null
                var runningIndex = 0
                for (section in workspaceSections) {
                    if (section.title != null) {
                        runningIndex += 1 // date section label row
                    }
                    for (group in section.groups) {
                        runningIndex += 1 // workspace header row
                        if (collapsedWorkspaceGroupIds.contains(group.id)) {
                            continue
                        }
                        val visibleRows =
                            buildVisibleSessionTreeRows(
                                groupThreads = group.threads,
                                parentByKey = lineageIndex.parentByKey,
                                collapsedNodeIds = collapsedSessionNodeIds,
                            )
                        val threadIndex = visibleRows.indexOfFirst { it.thread.key == targetKey }
                        if (threadIndex >= 0) {
                            return@derivedStateOf runningIndex + threadIndex
                        }
                        runningIndex += visibleRows.size
                    }
                }
                null
            }
        }
    val collapsedAncestorNodeId by
        remember(activeThreadKey, collapsedSessionNodeIds, lineageIndex.parentByKey) {
            derivedStateOf {
                val targetKey = activeThreadKey ?: return@derivedStateOf null
                ancestorThreadKeys(targetKey, lineageIndex.parentByKey)
                    .asReversed()
                    .map(::threadNodeId)
                    .firstOrNull { collapsedSessionNodeIds.contains(it) }
            }
        }
    val serverNameById =
        remember(connectedServers) {
            connectedServers.associate { it.id to it.name }
        }

    LaunchedEffect(workspaceGroups) {
        val validIds = workspaceGroups.map { it.id }.toSet()
        collapsedWorkspaceGroupIds = collapsedWorkspaceGroupIds.intersect(validIds)
    }

    LaunchedEffect(sessions) {
        val validIds = sessions.map { thread -> threadNodeId(thread.key) }.toSet()
        collapsedSessionNodeIds = collapsedSessionNodeIds.intersect(validIds)
    }

    LaunchedEffect(
        pendingActiveSessionScroll,
        isSidebarOpen,
        activeThreadKey,
        activeWorkspaceGroupId,
        activeSessionItemIndex,
        collapsedWorkspaceGroupIds,
        collapsedAncestorNodeId,
    ) {
        if (!pendingActiveSessionScroll || !isSidebarOpen) {
            return@LaunchedEffect
        }
        if (activeThreadKey == null) {
            pendingActiveSessionScroll = false
            return@LaunchedEffect
        }
        val targetGroupId = activeWorkspaceGroupId
        if (targetGroupId == null) {
            pendingActiveSessionScroll = false
            return@LaunchedEffect
        }
        if (collapsedWorkspaceGroupIds.contains(targetGroupId)) {
            collapsedWorkspaceGroupIds = collapsedWorkspaceGroupIds - targetGroupId
            return@LaunchedEffect
        }
        val ancestorNodeId = collapsedAncestorNodeId
        if (ancestorNodeId != null) {
            collapsedSessionNodeIds = collapsedSessionNodeIds - ancestorNodeId
            return@LaunchedEffect
        }
        val targetIndex = activeSessionItemIndex
        if (targetIndex == null) {
            pendingActiveSessionScroll = false
            return@LaunchedEffect
        }

        pendingActiveSessionScroll = false
        sessionListState.scrollToItem(targetIndex)
    }

    Surface(
        modifier = modifier,
        color = LitterTheme.surface.copy(alpha = 0.88f),
        border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
    ) {
        Column(
            modifier = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
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
                val activeSession = sessions.firstOrNull { it.key == activeThreadKey }
                Text(
                    text =
                        if (connectionStatus == ServerConnectionStatus.READY) {
                            "${connectedServers.size} server${if (connectedServers.size == 1) "" else "s"}"
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
                    if (activeSession != null) {
                        TextButton(
                            enabled = !activeSession.hasTurnActive,
                            onClick = onForkConversation,
                        ) {
                            Text("Fork")
                        }
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

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val selectedServerName =
                        selectedServerFilterId
                            ?.let { id -> serverNameById[id] }
                            ?: "All servers"

                    Box {
                        OutlinedButton(
                            onClick = { isServerFilterMenuOpen = true },
                            shape = RoundedCornerShape(8.dp),
                        ) {
                            Text(selectedServerName, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        DropdownMenu(
                            expanded = isServerFilterMenuOpen,
                            onDismissRequest = { isServerFilterMenuOpen = false },
                        ) {
                            DropdownMenuItem(
                                text = { Text("All servers") },
                                onClick = {
                                    onSessionServerFilterChange(null)
                                    isServerFilterMenuOpen = false
                                },
                            )
                            connectedServers.forEach { server ->
                                DropdownMenuItem(
                                    text = { Text(server.name) },
                                    onClick = {
                                        onSessionServerFilterChange(server.id)
                                        isServerFilterMenuOpen = false
                                    },
                                )
                            }
                        }
                    }

                    OutlinedButton(
                        onClick = { onSessionShowOnlyForksChange(!showOnlyForks) },
                        shape = RoundedCornerShape(8.dp),
                    ) {
                        Text(if (showOnlyForks) "Forks only" else "Forks")
                    }

                    Box {
                        OutlinedButton(
                            onClick = { isSortMenuOpen = true },
                            shape = RoundedCornerShape(8.dp),
                            modifier = Modifier.size(40.dp),
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
                        ) {
                            Icon(
                                imageVector = workspaceSortModeIcon(),
                                contentDescription = "Sort sessions by ${workspaceSortMode.title}",
                                tint = LitterTheme.textSecondary,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                        DropdownMenu(
                            expanded = isSortMenuOpen,
                            onDismissRequest = { isSortMenuOpen = false },
                        ) {
                            WorkspaceSortMode.entries.forEach { mode ->
                                DropdownMenuItem(
                                    text = { Text(mode.title) },
                                    onClick = {
                                        onSessionWorkspaceSortModeChange(mode.name)
                                        isSortMenuOpen = false
                                    },
                                )
                            }
                        }
                    }

                    if (selectedServerFilterId != null || showOnlyForks) {
                        TextButton(
                            onClick = onClearSessionFilters,
                        ) {
                            Text("Clear")
                        }
                    }
                }

                if (filteredSessions.isEmpty()) {
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        text = if (normalizedQuery.isEmpty()) "No sessions match the active filters" else "No matches for \"$normalizedQuery\"",
                        color = LitterTheme.textMuted,
                        modifier = Modifier.align(Alignment.CenterHorizontally),
                    )
                    Spacer(modifier = Modifier.weight(1f))
                } else {
                    LazyColumn(
                        state = sessionListState,
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(1.dp),
                    ) {
                        workspaceSections.forEach { section ->
                            section.title?.let { title ->
                                item(key = "workspace-section-${section.id}") {
                                    Text(
                                        text = title,
                                        color = LitterTheme.textMuted,
                                        style = MaterialTheme.typography.labelSmall,
                                        modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp),
                                    )
                                }
                            }

                            section.groups.forEach { group ->
                                val isCollapsed = collapsedWorkspaceGroupIds.contains(group.id)
                                item(key = "workspace-${group.id}") {
                                    WorkspaceSessionGroupHeader(
                                        group = group,
                                        isCollapsed = isCollapsed,
                                        onToggle = {
                                            collapsedWorkspaceGroupIds =
                                                if (isCollapsed) {
                                                    collapsedWorkspaceGroupIds - group.id
                                                } else {
                                                    collapsedWorkspaceGroupIds + group.id
                                                }
                                        },
                                    )
                                }

                                if (!isCollapsed) {
                                    val visibleRows =
                                        buildVisibleSessionTreeRows(
                                            groupThreads = group.threads,
                                            parentByKey = lineageIndex.parentByKey,
                                            collapsedNodeIds = collapsedSessionNodeIds,
                                        )
                                    items(items = visibleRows, key = { threadNodeId(it.thread.key) }) { row ->
                                        val thread = row.thread
                                        val isActive = thread.key == activeThreadKey
                                        val isNodeCollapsed = collapsedSessionNodeIds.contains(threadNodeId(thread.key))
                                        val parent = lineageIndex.parentByKey[thread.key]
                                        val siblings = lineageIndex.siblingsByKey[thread.key].orEmpty()
                                        val children = lineageIndex.childrenByParentKey[thread.key].orEmpty()
                                        val hasLineage = parent != null || siblings.isNotEmpty() || children.isNotEmpty()

                                        Column(
                                            modifier =
                                                Modifier
                                                    .fillMaxWidth()
                                        ) {
                                            Column(
                                                modifier =
                                                    Modifier
                                                        .fillMaxWidth()
                                                        .clip(RoundedCornerShape(6.dp))
                                                        .clickable { onSessionSelected(thread.key) }
                                                        .background(
                                                            if (isActive) {
                                                                LitterTheme.surfaceLight.copy(alpha = 0.55f)
                                                            } else {
                                                                Color.Transparent
                                                            },
                                                        )
                                                        .padding(start = 1.dp, end = 8.dp, top = 5.dp, bottom = 5.dp),
                                                verticalArrangement = Arrangement.spacedBy(2.dp),
                                            ) {
                                                Row(
                                                    verticalAlignment = Alignment.Top,
                                                ) {
                                                    SessionTreePrefix(
                                                        depth = row.depth,
                                                        hasChildren = row.hasChildren,
                                                        isCollapsed = isNodeCollapsed,
                                                        onToggle = {
                                                            if (row.hasChildren) {
                                                                collapsedSessionNodeIds =
                                                                    if (isNodeCollapsed) {
                                                                        collapsedSessionNodeIds - threadNodeId(thread.key)
                                                                    } else {
                                                                        collapsedSessionNodeIds + threadNodeId(thread.key)
                                                                    }
                                                            }
                                                        },
                                                    )

                                                    Text(
                                                        text = thread.preview.ifBlank { "Untitled session" },
                                                        maxLines = 2,
                                                        overflow = TextOverflow.Ellipsis,
                                                        color = LitterTheme.textPrimary,
                                                        style = MaterialTheme.typography.bodyMedium,
                                                        modifier = Modifier.weight(1f),
                                                    )

                                                    if (thread.isFork) {
                                                        Surface(
                                                            color = LitterTheme.accent,
                                                            shape = RoundedCornerShape(4.dp),
                                                        ) {
                                                            Text(
                                                                text = "Fork",
                                                                color = Color.Black,
                                                                style = MaterialTheme.typography.labelSmall,
                                                                modifier = Modifier.padding(horizontal = 5.dp, vertical = 2.dp),
                                                            )
                                                        }
                                                    }

                                                    Box {
                                                        IconButton(
                                                            modifier = Modifier.size(20.dp),
                                                            onClick = { rowMenuThreadKey = thread.key },
                                                        ) {
                                                            Icon(
                                                                imageVector = Icons.Default.MoreVert,
                                                                contentDescription = "Session actions",
                                                                tint = LitterTheme.textSecondary,
                                                                modifier = Modifier.size(14.dp),
                                                            )
                                                        }
                                                        DropdownMenu(
                                                            expanded = rowMenuThreadKey == thread.key,
                                                            onDismissRequest = { rowMenuThreadKey = null },
                                                        ) {
                                                            DropdownMenuItem(
                                                                text = { Text("Rename") },
                                                                onClick = {
                                                                    renameTargetThread = thread
                                                                    renameDraft = ""
                                                                    renameError = null
                                                                    rowMenuThreadKey = null
                                                                },
                                                            )
                                                            DropdownMenuItem(
                                                                text = { Text("Fork") },
                                                                onClick = {
                                                                    onForkSession(thread.key)
                                                                    rowMenuThreadKey = null
                                                                },
                                                            )
                                                            DropdownMenuItem(
                                                                text = { Text("Delete") },
                                                                onClick = {
                                                                    archiveTargetThread = thread
                                                                    rowMenuThreadKey = null
                                                                },
                                                            )
                                                        }
                                                    }
                                                }

                                                Text(
                                                    text = sessionMetaLine(thread),
                                                    maxLines = 1,
                                                    overflow = TextOverflow.Ellipsis,
                                                    color = LitterTheme.textSecondary,
                                                    style = MaterialTheme.typography.labelLarge,
                                                )

                                                parent?.let {
                                                    Text(
                                                        text = "from ${it.preview.ifBlank { "Untitled session" }}",
                                                        maxLines = 1,
                                                        overflow = TextOverflow.Ellipsis,
                                                        color = LitterTheme.textMuted,
                                                        style = MaterialTheme.typography.labelSmall,
                                                    )
                                                }

                                                if (thread.cwd.isNotBlank()) {
                                                    Text(
                                                        text = thread.cwd,
                                                        maxLines = 1,
                                                        overflow = TextOverflow.Ellipsis,
                                                        color = LitterTheme.textMuted,
                                                        style = MaterialTheme.typography.labelSmall,
                                                    )
                                                }

                                                if (isActive && hasLineage) {
                                                    Row(
                                                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                                                        verticalAlignment = Alignment.CenterVertically,
                                                    ) {
                                                        parent?.let {
                                                            SessionLineageChip(
                                                                title = "Parent",
                                                                count = 1,
                                                                onClick = { onSessionSelected(it.key) },
                                                            )
                                                        }
                                                        if (siblings.isNotEmpty()) {
                                                            SessionLineageChip(
                                                                title = "Siblings",
                                                                count = siblings.size,
                                                                onClick = { siblings.firstOrNull()?.let { sibling -> onSessionSelected(sibling.key) } },
                                                            )
                                                        }
                                                        if (children.isNotEmpty()) {
                                                            SessionLineageChip(
                                                                title = "Children",
                                                                count = children.size,
                                                                onClick = { children.firstOrNull()?.let { child -> onSessionSelected(child.key) } },
                                                            )
                                                        }
                                                    }
                                                }
                                            }
                                            HorizontalDivider(
                                                modifier = Modifier.padding(start = 24.dp),
                                                color = LitterTheme.border.copy(alpha = 0.65f),
                                                thickness = 1.dp,
                                            )
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

    renameTargetThread?.let { thread ->
        AlertDialog(
            onDismissRequest = {
                renameTargetThread = null
                renameDraft = ""
                renameError = null
            },
            title = { Text("Rename Session") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = thread.preview.ifBlank { "Untitled session" },
                        color = LitterTheme.textSecondary,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    OutlinedTextField(
                        value = renameDraft,
                        onValueChange = {
                            renameDraft = it
                            renameError = null
                        },
                        singleLine = true,
                        label = { Text("New title") },
                        placeholder = { Text("New session title") },
                    )
                    renameError?.let {
                        Text(
                            text = it,
                            color = LitterTheme.danger,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        renameTargetThread = null
                        renameDraft = ""
                        renameError = null
                    },
                ) {
                    Text("Cancel")
                }
            },
            confirmButton = {
                TextButton(
                    enabled = renameDraft.trim().isNotEmpty(),
                    onClick = {
                        onRenameSession(thread.key, renameDraft) { result ->
                            result.onFailure { error ->
                                renameError = error.message ?: "Failed to rename session"
                            }
                            result.onSuccess {
                                renameTargetThread = null
                                renameDraft = ""
                                renameError = null
                            }
                        }
                    },
                ) {
                    Text("Save")
                }
            },
        )
    }

    archiveTargetThread?.let { thread ->
        AlertDialog(
            onDismissRequest = { archiveTargetThread = null },
            title = { Text("Delete Session") },
            text = { Text("Remove \"${thread.preview.ifBlank { "Untitled session" }}\" from the sidebar?") },
            dismissButton = {
                TextButton(onClick = { archiveTargetThread = null }) {
                    Text("Cancel")
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onArchiveSession(thread.key)
                        archiveTargetThread = null
                    },
                ) {
                    Text("Delete", color = LitterTheme.danger)
                }
            },
        )
    }
}

@Composable
private fun WorkspaceSessionGroupHeader(
    group: WorkspaceSessionGroup,
    isCollapsed: Boolean,
    onToggle: () -> Unit,
) {
    val sessionCountLabel = if (group.threads.size == 1) "1 session" else "${group.threads.size} sessions"
    val detailLine =
        if (group.workspacePath == group.workspaceTitle) {
            "${group.serverName} • $sessionCountLabel"
        } else {
            "${group.serverName} • ${group.workspacePath} • $sessionCountLabel"
        }
    Column(
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onToggle)
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                imageVector = if (isCollapsed) Icons.Default.ExpandMore else Icons.Default.ExpandLess,
                contentDescription = null,
                tint = LitterTheme.textSecondary,
                modifier = Modifier.size(14.dp),
            )
            Icon(
                imageVector = Icons.Default.Folder,
                contentDescription = null,
                tint = LitterTheme.accent,
                modifier = Modifier.size(13.dp),
            )
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = group.workspaceTitle,
                    color = LitterTheme.textPrimary,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = detailLine,
                    color = LitterTheme.textMuted,
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        HorizontalDivider(
            color = LitterTheme.border.copy(alpha = 0.75f),
            thickness = 1.dp,
        )
    }
}

@Composable
private fun SessionTreePrefix(
    depth: Int,
    hasChildren: Boolean,
    isCollapsed: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        modifier = Modifier.padding(top = 1.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (depth > 0) {
            Spacer(modifier = Modifier.width((depth * 8).dp))
        }
        if (hasChildren) {
            Box(
                modifier =
                    Modifier
                        .size(12.dp)
                        .clickable(onClick = onToggle),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = if (isCollapsed) Icons.AutoMirrored.Filled.KeyboardArrowRight else Icons.Default.KeyboardArrowDown,
                    contentDescription = if (isCollapsed) "Expand" else "Collapse",
                    tint = LitterTheme.textSecondary,
                    modifier = Modifier.size(10.dp),
                )
            }
        }
    }
}

@Composable
private fun SessionLineageChip(
    title: String,
    count: Int,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier.clickable(onClick = onClick),
        color = LitterTheme.surface.copy(alpha = 0.7f),
        shape = RoundedCornerShape(5.dp),
        border =
            androidx.compose.foundation.BorderStroke(
                1.dp,
                LitterTheme.accent.copy(alpha = 0.45f),
            ),
    ) {
        Text(
            text = "$title $count",
            color = LitterTheme.accent,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 4.dp),
        )
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF000000)
@Composable
private fun SessionLineageChipPreview() {
    LitterAppTheme {
        SessionLineageChip(
            title = "Children",
            count = 3,
            onClick = {},
        )
    }
}

private fun sessionMetaLine(thread: ThreadState): String {
    val modelLabel = thread.modelProvider.ifBlank { "default" }
    return "${relativeDate(thread.updatedAtEpochMillis)} • ${thread.serverName} • $modelLabel"
}

private fun threadNodeId(key: ThreadKey): String = "${key.serverId}:${key.threadId}"

private data class SessionTreeRow(
    val thread: ThreadState,
    val depth: Int,
    val hasChildren: Boolean,
)

private fun buildVisibleSessionTreeRows(
    groupThreads: List<ThreadState>,
    parentByKey: Map<ThreadKey, ThreadState>,
    collapsedNodeIds: Set<String>,
): List<SessionTreeRow> {
    if (groupThreads.isEmpty()) {
        return emptyList()
    }

    val threadsByKey = groupThreads.associateBy { thread -> thread.key }
    val childrenByParentKey = LinkedHashMap<ThreadKey, MutableList<ThreadState>>()
    groupThreads.forEach { thread ->
        val parent = parentByKey[thread.key] ?: return@forEach
        if (!threadsByKey.containsKey(parent.key)) {
            return@forEach
        }
        childrenByParentKey.getOrPut(parent.key) { mutableListOf() }.add(thread)
    }

    val sortedChildrenByParentKey =
        childrenByParentKey.mapValues { (_, children) ->
            children.sortedByDescending { it.updatedAtEpochMillis }
        }

    val roots =
        groupThreads.filter { thread ->
            val parent = parentByKey[thread.key] ?: return@filter true
            !threadsByKey.containsKey(parent.key)
        }

    val rows = mutableListOf<SessionTreeRow>()
    val emitted = mutableSetOf<ThreadKey>()

    fun appendThread(thread: ThreadState, depth: Int, path: MutableSet<ThreadKey>) {
        if (!emitted.add(thread.key) || !path.add(thread.key)) {
            return
        }
        val children = sortedChildrenByParentKey[thread.key].orEmpty()
        rows += SessionTreeRow(thread = thread, depth = depth, hasChildren = children.isNotEmpty())
        if (!collapsedNodeIds.contains(threadNodeId(thread.key))) {
            children.forEach { child ->
                appendThread(child, depth + 1, path)
            }
        }
        path.remove(thread.key)
    }

    roots.forEach { root ->
        appendThread(root, depth = 0, path = mutableSetOf())
    }
    groupThreads.forEach { thread ->
        if (!emitted.contains(thread.key)) {
            appendThread(thread, depth = 0, path = mutableSetOf())
        }
    }

    return rows
}

private fun ancestorThreadKeys(
    targetKey: ThreadKey,
    parentByKey: Map<ThreadKey, ThreadState>,
): List<ThreadKey> {
    val ancestors = mutableListOf<ThreadKey>()
    val visited = mutableSetOf<ThreadKey>()
    var cursor: ThreadState? = parentByKey[targetKey]
    while (cursor != null && visited.add(cursor.key)) {
        ancestors += cursor.key
        cursor = parentByKey[cursor.key]
    }
    return ancestors
}

private data class ThreadLineageIndex(
    val parentByKey: Map<ThreadKey, ThreadState>,
    val siblingsByKey: Map<ThreadKey, List<ThreadState>>,
    val childrenByParentKey: Map<ThreadKey, List<ThreadState>>,
    val searchableTextByKey: Map<ThreadKey, String>,
)

private fun buildThreadLineageIndex(allThreads: List<ThreadState>): ThreadLineageIndex {
    val threadByKey =
        allThreads.associateBy { thread ->
            thread.key
        }
    val childrenByParentKey = LinkedHashMap<ThreadKey, MutableList<ThreadState>>()
    val parentByKey = LinkedHashMap<ThreadKey, ThreadState>()

    allThreads.forEach { thread ->
        val parentId = thread.parentThreadId?.trim().orEmpty()
        if (parentId.isEmpty()) {
            return@forEach
        }
        val parentKey = ThreadKey(serverId = thread.key.serverId, threadId = parentId)
        val parentThread = threadByKey[parentKey] ?: return@forEach
        parentByKey[thread.key] = parentThread
        childrenByParentKey.getOrPut(parentKey) { mutableListOf() }.add(thread)
    }

    val sortedChildrenByParentKey =
        childrenByParentKey.mapValues { (_, children) ->
            children.sortedByDescending { it.updatedAtEpochMillis }
        }

    val siblingsByKey = LinkedHashMap<ThreadKey, List<ThreadState>>()
    sortedChildrenByParentKey.values.forEach { siblingsGroup ->
        if (siblingsGroup.isEmpty()) {
            return@forEach
        }
        siblingsGroup.forEachIndexed { index, thread ->
            val siblings =
                if (siblingsGroup.size <= 1) {
                    emptyList()
                } else {
                    buildList(siblingsGroup.size - 1) {
                        for (siblingIndex in siblingsGroup.indices) {
                            if (siblingIndex != index) {
                                add(siblingsGroup[siblingIndex])
                            }
                        }
                    }
                }
            siblingsByKey[thread.key] = siblings
        }
    }

    val searchableTextByKey =
        allThreads.associate { thread ->
            val parentPreview = parentByKey[thread.key]?.preview.orEmpty()
            thread.key to
                listOf(
                    thread.preview,
                    thread.cwd,
                    thread.serverName,
                    thread.modelProvider,
                    parentPreview,
                ).joinToString(separator = "\n")
                    .lowercase(Locale.ROOT)
        }

    return ThreadLineageIndex(
        parentByKey = parentByKey,
        siblingsByKey = siblingsByKey,
        childrenByParentKey = sortedChildrenByParentKey,
        searchableTextByKey = searchableTextByKey,
    )
}

private fun matchesSessionSearch(
    thread: ThreadState,
    normalizedQuery: String,
    searchableTextByKey: Map<ThreadKey, String>,
): Boolean {
    if (normalizedQuery.isBlank()) {
        return true
    }
    return searchableTextByKey[thread.key]?.contains(normalizedQuery) == true
}

private data class WorkspaceSessionGroup(
    val id: String,
    val serverName: String,
    val workspacePath: String,
    val workspaceTitle: String,
    val latestUpdatedAtEpochMillis: Long,
    val threads: List<ThreadState>,
)

private enum class WorkspaceSortMode(
    val title: String,
) {
    MOST_RECENT("Most Recent"),
    NAME("Name"),
    DATE("Date"),
    ;

    companion object {
        fun fromRaw(value: String?): WorkspaceSortMode =
            entries.firstOrNull { it.name == value } ?: MOST_RECENT
    }
}

private fun workspaceSortModeIcon(): ImageVector = Icons.Filled.SwapVert

private data class WorkspaceGroupSection(
    val id: String,
    val title: String?,
    val groups: List<WorkspaceSessionGroup>,
)

private fun groupSessionsByWorkspace(
    threads: List<ThreadState>,
    sortMode: WorkspaceSortMode,
): List<WorkspaceSessionGroup> {
    val grouped = LinkedHashMap<String, MutableList<ThreadState>>()
    threads.forEach { thread ->
        val workspacePath = normalizeFolderPath(thread.cwd)
        val groupId = "${thread.key.serverId}:$workspacePath"
        grouped.getOrPut(groupId) { mutableListOf() }.add(thread)
    }
    return grouped
        .mapNotNull { (groupId, groupThreads) ->
            val sortedThreads = groupThreads.sortedByDescending { it.updatedAtEpochMillis }
            val first = sortedThreads.firstOrNull() ?: return@mapNotNull null
            val workspacePath = normalizeFolderPath(first.cwd)
            WorkspaceSessionGroup(
                id = groupId,
                serverName = first.serverName,
                workspacePath = workspacePath,
                workspaceTitle = cwdLeaf(workspacePath),
                latestUpdatedAtEpochMillis = first.updatedAtEpochMillis,
                threads = sortedThreads,
            )
        }.let { unsorted -> sortWorkspaceGroups(unsorted, sortMode) }
}

private fun sortWorkspaceGroups(
    groups: List<WorkspaceSessionGroup>,
    sortMode: WorkspaceSortMode,
): List<WorkspaceSessionGroup> {
    return groups.sortedWith { lhs, rhs ->
        when (sortMode) {
            WorkspaceSortMode.MOST_RECENT -> {
                when {
                    lhs.latestUpdatedAtEpochMillis != rhs.latestUpdatedAtEpochMillis ->
                        rhs.latestUpdatedAtEpochMillis.compareTo(lhs.latestUpdatedAtEpochMillis)
                    else -> lhs.workspaceTitle.lowercase(Locale.ROOT).compareTo(rhs.workspaceTitle.lowercase(Locale.ROOT))
                }
            }

            WorkspaceSortMode.NAME -> {
                val titleOrder = lhs.workspaceTitle.lowercase(Locale.ROOT).compareTo(rhs.workspaceTitle.lowercase(Locale.ROOT))
                if (titleOrder != 0) {
                    return@sortedWith titleOrder
                }
                val pathOrder = lhs.workspacePath.lowercase(Locale.ROOT).compareTo(rhs.workspacePath.lowercase(Locale.ROOT))
                if (pathOrder != 0) {
                    return@sortedWith pathOrder
                }
                val serverOrder = lhs.serverName.lowercase(Locale.ROOT).compareTo(rhs.serverName.lowercase(Locale.ROOT))
                if (serverOrder != 0) {
                    return@sortedWith serverOrder
                }
                rhs.latestUpdatedAtEpochMillis.compareTo(lhs.latestUpdatedAtEpochMillis)
            }

            WorkspaceSortMode.DATE -> {
                when {
                    lhs.latestUpdatedAtEpochMillis != rhs.latestUpdatedAtEpochMillis ->
                        rhs.latestUpdatedAtEpochMillis.compareTo(lhs.latestUpdatedAtEpochMillis)
                    else -> lhs.workspaceTitle.lowercase(Locale.ROOT).compareTo(rhs.workspaceTitle.lowercase(Locale.ROOT))
                }
            }
        }
    }
}

private fun buildWorkspaceSections(
    groups: List<WorkspaceSessionGroup>,
    sortMode: WorkspaceSortMode,
): List<WorkspaceGroupSection> {
    if (groups.isEmpty()) {
        return emptyList()
    }
    if (sortMode != WorkspaceSortMode.DATE) {
        return listOf(WorkspaceGroupSection(id = "all", title = null, groups = groups))
    }

    val nowDayStart = dayStartMillis(System.currentTimeMillis())
    val groupsByDay = LinkedHashMap<Long, MutableList<WorkspaceSessionGroup>>()
    groups.forEach { group ->
        val dayStart = dayStartMillis(group.latestUpdatedAtEpochMillis)
        groupsByDay.getOrPut(dayStart) { mutableListOf() }.add(group)
    }

    return groupsByDay.entries.map { (dayStart, dayGroups) ->
        WorkspaceGroupSection(
            id = "workspace-day-$dayStart",
            title = workspaceDateSectionLabel(dayStart, nowDayStart),
            groups = dayGroups,
        )
    }
}

private fun dayStartMillis(epochMillis: Long): Long {
    val calendar = Calendar.getInstance()
    calendar.timeInMillis = epochMillis
    calendar.set(Calendar.HOUR_OF_DAY, 0)
    calendar.set(Calendar.MINUTE, 0)
    calendar.set(Calendar.SECOND, 0)
    calendar.set(Calendar.MILLISECOND, 0)
    return calendar.timeInMillis
}

private fun workspaceDateSectionLabel(
    dayStartMillis: Long,
    nowDayStartMillis: Long,
): String {
    val dayDelta = ((nowDayStartMillis - dayStartMillis) / DateUtils.DAY_IN_MILLIS).toInt().coerceAtLeast(0)
    return when {
        dayDelta == 0 -> "Today"
        dayDelta == 1 -> "Yesterday"
        dayDelta in 2..6 -> "$dayDelta days ago"
        else -> SimpleDateFormat("MMM d, yyyy", Locale.getDefault()).format(Date(dayStartMillis))
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
    onForkConversation: () -> Unit,
    onEditMessage: (ChatMessage) -> Unit,
    onForkFromMessage: (ChatMessage) -> Unit,
    onSend: (String, List<SkillMentionInput>) -> Unit,
    onInterrupt: () -> Unit,
) {
    DebugRecomposeCheckpoint(name = "ConversationPanel")
    val context = LocalContext.current
    val markdownMarkwon = remember(context) { Markwon.create(context) }
    val syntaxMarkwon = remember(context) { createSyntaxHighlightMarkwon(context) }
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
                MessageRow(
                    message = message,
                    markdownMarkwon = markdownMarkwon,
                    syntaxMarkwon = syntaxMarkwon,
                    messageActionsEnabled = !isSending,
                    onEditMessage = onEditMessage,
                    onForkFromMessage = onForkFromMessage,
                )
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
            onForkConversation = onForkConversation,
            onAttachImage = { attachmentLauncher.launch("image/*") },
            onCaptureImage = { cameraLauncher.launch(null) },
            onClearAttachment = {
                attachedImagePath = null
                attachmentError = null
            },
            onSend = { text, skillMentions ->
                onSend(encodeDraftWithLocalImageAttachment(text, attachedImagePath), skillMentions)
                attachedImagePath = null
                attachmentError = null
            },
            onInterrupt = onInterrupt,
        )
    }
}

@Composable
private fun MessageRow(
    message: ChatMessage,
    markdownMarkwon: Markwon,
    syntaxMarkwon: Markwon,
    messageActionsEnabled: Boolean,
    onEditMessage: (ChatMessage) -> Unit,
    onForkFromMessage: (ChatMessage) -> Unit,
) {
    when (message.role) {
        MessageRole.USER -> {
            val supportsActions = message.isFromUserTurnBoundary && message.sourceTurnIndex != null
            var menuExpanded by remember(message.id) { mutableStateOf(false) }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (supportsActions) {
                    Box {
                        IconButton(
                            enabled = messageActionsEnabled,
                            onClick = { menuExpanded = true },
                            modifier = Modifier.size(28.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Default.ArrowDropDown,
                                contentDescription = "Message actions",
                                tint = if (messageActionsEnabled) LitterTheme.textSecondary else LitterTheme.textMuted,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                        DropdownMenu(
                            expanded = menuExpanded,
                            onDismissRequest = { menuExpanded = false },
                            containerColor = LitterTheme.surfaceLight,
                        ) {
                            DropdownMenuItem(
                                text = { Text("Edit message", color = LitterTheme.textPrimary) },
                                enabled = messageActionsEnabled,
                                onClick = {
                                    menuExpanded = false
                                    onEditMessage(message)
                                },
                            )
                            DropdownMenuItem(
                                text = { Text("Fork from here", color = LitterTheme.textPrimary) },
                                enabled = messageActionsEnabled,
                                onClick = {
                                    menuExpanded = false
                                    onForkFromMessage(message)
                                },
                            )
                        }
                    }
                }
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
                markdownMarkwon = markdownMarkwon,
                syntaxMarkwon = syntaxMarkwon,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 2.dp),
            )
        }

        MessageRole.SYSTEM -> {
            SystemMessageCard(
                message = message,
                markdownMarkwon = markdownMarkwon,
                syntaxMarkwon = syntaxMarkwon,
            )
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
    markdownMarkwon: Markwon,
    syntaxMarkwon: Markwon,
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
                is MarkdownBlock.Text ->
                    InlineMediaMarkdown(
                        markdown = block.markdown,
                        markdownMarkwon = markdownMarkwon,
                        textColor = textColor,
                    )
                is MarkdownBlock.Code ->
                    CodeBlockCard(
                        language = block.language,
                        code = block.code,
                        syntaxMarkwon = syntaxMarkwon,
                    )
            }
        }
    }
}

@Composable
private fun InlineMediaMarkdown(
    markdown: String,
    markdownMarkwon: Markwon,
    textColor: Color,
) {
    val segments = remember(markdown) { extractInlineSegments(markdown) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        segments.forEach { segment ->
            when (segment) {
                is InlineSegment.Text ->
                    AssistantMarkdownText(
                        markdown = segment.value,
                        markwon = markdownMarkwon,
                        textColor = textColor,
                    )
                is InlineSegment.ImageBytes -> {
                    val bitmap by
                        produceState<Bitmap?>(initialValue = null, key1 = segment.bytes) {
                            value =
                                withContext(Dispatchers.IO) {
                                    BitmapFactory.decodeByteArray(segment.bytes, 0, segment.bytes.size)
                                }
                        }
                    InlineBitmapImage(bitmap = bitmap, contentDescription = "Inline image")
                }

                is InlineSegment.LocalImagePath -> {
                    val bitmap by
                        produceState<Bitmap?>(initialValue = null, key1 = segment.path) {
                            value = withContext(Dispatchers.IO) { BitmapFactory.decodeFile(segment.path) }
                        }
                    InlineBitmapImage(bitmap = bitmap, contentDescription = "Local image")
                }
            }
        }
    }
}

@Composable
private fun InlineBitmapImage(
    bitmap: Bitmap?,
    contentDescription: String,
    modifier: Modifier = Modifier,
) {
    if (bitmap == null) {
        return
    }
    Image(
        bitmap = bitmap.asImageBitmap(),
        contentDescription = contentDescription,
        modifier = modifier.fillMaxWidth().heightIn(max = 320.dp).clip(RoundedCornerShape(8.dp)),
        contentScale = ContentScale.Fit,
    )
}

@Composable
private fun AssistantMarkdownText(
    markdown: String,
    markwon: Markwon,
    textColor: Color,
    modifier: Modifier = Modifier,
) {
    AndroidView(
        modifier = modifier,
        factory = { context ->
            TextView(context).apply {
                typeface = context.monospaceTypeface()
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
    syntaxMarkwon: Markwon,
    modifier: Modifier = Modifier,
) {
    val clipboard = LocalClipboardManager.current
    val markdown =
        remember(language, code) {
            buildString {
                append("```")
                append(language.trim().ifEmpty { "text" })
                append("\n")
                append(code)
                if (!code.endsWith('\n')) {
                    append("\n")
                }
                append("```")
            }
        }
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
                AndroidView(
                    factory = { context ->
                        TextView(context).apply {
                            typeface = context.monospaceTypeface()
                            textSize = 12f
                            setLineSpacing(0f, 1.2f)
                            setTextColor(LitterTheme.textBody.toArgb())
                            setBackgroundColor(android.graphics.Color.TRANSPARENT)
                            setHorizontallyScrolling(true)
                            setTextIsSelectable(true)
                        }
                    },
                    update = { syntaxMarkwon.setMarkdown(it, markdown) },
                )
            }
        }
    }
}

private fun createSyntaxHighlightMarkwon(context: Context): Markwon {
    val builder = Markwon.builder(context)
    createPrism4jLocator()?.let { locator ->
        val prism4j = Prism4j(locator)
        builder.usePlugin(SyntaxHighlightPlugin.create(prism4j, Prism4jThemeDarkula.create()))
    }
    return builder.build()
}

private fun createPrism4jLocator(): GrammarLocator? {
    val candidates =
        listOf(
            "com.litter.android.ui.Prism4jGrammarLocator",
            "io.noties.prism4j.bundler.Prism4jGrammarLocator",
            "io.noties.prism4j.GrammarLocatorDef",
            "GrammarLocatorDef",
        )
    for (candidate in candidates) {
        val locator =
            runCatching {
                Class.forName(candidate).getDeclaredConstructor().newInstance()
            }.getOrNull()
        if (locator is GrammarLocator) {
            return locator
        }
    }
    return null
}

@Composable
private fun SystemMessageCard(
    message: ChatMessage,
    markdownMarkwon: Markwon,
    syntaxMarkwon: Markwon,
) {
    val parseResult = remember(message.text) { ToolCallMessageParser.parse(message) }
    when (parseResult) {
        is ToolCallParseResult.Recognized ->
            StructuredToolCallCard(
                messageId = message.id,
                model = parseResult.model,
                syntaxMarkwon = syntaxMarkwon,
            )
        ToolCallParseResult.Unrecognized ->
            GenericSystemMessageCard(
                message = message,
                markdownMarkwon = markdownMarkwon,
                syntaxMarkwon = syntaxMarkwon,
            )
    }
}

@Composable
private fun GenericSystemMessageCard(
    message: ChatMessage,
    markdownMarkwon: Markwon,
    syntaxMarkwon: Markwon,
) {
    val (title, body) = remember(message.text) { extractSystemTitleAndBody(message.text) }
    val displayTitle = title ?: "System"
    val markdown = if (title == null) message.text else body

    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
        color = LitterTheme.surface.copy(alpha = 0.85f),
        border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(
                    imageVector = Icons.Default.Info,
                    contentDescription = null,
                    tint = LitterTheme.accent,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    text = displayTitle.uppercase(Locale.US),
                    color = LitterTheme.accent,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
            }

            if (markdown.isNotBlank()) {
                MessageMarkdownContent(
                    markdown = markdown,
                    markdownMarkwon = markdownMarkwon,
                    syntaxMarkwon = syntaxMarkwon,
                    modifier = Modifier.fillMaxWidth(),
                    textColor = LitterTheme.textSystem,
                )
            }
        }
    }
}

@Composable
private fun StructuredToolCallCard(
    messageId: String,
    model: ToolCallCardModel,
    syntaxMarkwon: Markwon,
) {
    var expanded by remember(messageId, model.defaultExpanded) { mutableStateOf(model.defaultExpanded) }
    LaunchedEffect(model.status) {
        if (model.status == ToolCallStatus.FAILED) {
            expanded = true
        }
    }

    Surface(
        modifier = Modifier.fillMaxWidth().animateContentSize(),
        shape = RoundedCornerShape(10.dp),
        color = LitterTheme.surface.copy(alpha = 0.85f),
        border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(
                    imageVector = toolCallKindIcon(model.kind),
                    contentDescription = null,
                    tint = toolCallKindAccent(model.kind),
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    text = model.summary,
                    color = LitterTheme.textSecondary,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                ToolCallStatusChip(status = model.status)
                if (!model.duration.isNullOrBlank()) {
                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = LitterTheme.surfaceLight.copy(alpha = 0.72f),
                    ) {
                        Text(
                            text = model.duration,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                            color = LitterTheme.textSecondary,
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                }
                Icon(
                    imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = if (expanded) "Collapse" else "Expand",
                    tint = LitterTheme.textMuted,
                    modifier = Modifier.size(16.dp),
                )
            }

            if (expanded) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    model.sections.forEach { section ->
                        ToolCallSectionView(
                            section = section,
                            syntaxMarkwon = syntaxMarkwon,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ToolCallStatusChip(status: ToolCallStatus) {
    val (background, foreground) =
        when (status) {
            ToolCallStatus.COMPLETED -> LitterTheme.success.copy(alpha = 0.24f) to LitterTheme.success
            ToolCallStatus.IN_PROGRESS -> LitterTheme.warning.copy(alpha = 0.24f) to LitterTheme.warning
            ToolCallStatus.FAILED -> LitterTheme.danger.copy(alpha = 0.24f) to LitterTheme.danger
            ToolCallStatus.UNKNOWN -> LitterTheme.surfaceLight.copy(alpha = 0.72f) to LitterTheme.textSecondary
        }

    Surface(
        shape = RoundedCornerShape(10.dp),
        color = background,
    ) {
        Text(
            text = status.label,
            modifier = Modifier.padding(horizontal = 7.dp, vertical = 3.dp),
            color = foreground,
            style = MaterialTheme.typography.labelSmall,
        )
    }
}

@Composable
private fun ToolCallSectionView(
    section: ToolCallSection,
    syntaxMarkwon: Markwon,
) {
    when (section) {
        is ToolCallSection.KeyValue -> {
            if (section.entries.isEmpty()) return
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = section.label.uppercase(Locale.US),
                    color = LitterTheme.textSecondary,
                    style = MaterialTheme.typography.labelSmall,
                )
                Surface(
                    shape = RoundedCornerShape(8.dp),
                            color = LitterTheme.surface.copy(alpha = 0.6f),
                ) {
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 7.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        section.entries.forEach { entry ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Text(
                                    text = "${entry.key}:",
                                    color = LitterTheme.textSecondary,
                                    style = MaterialTheme.typography.labelSmall,
                                )
                                Text(
                                    text = entry.value,
                                    color = LitterTheme.textSystem,
                                    style = MaterialTheme.typography.bodySmall,
                                    modifier = Modifier.weight(1f),
                                )
                            }
                        }
                    }
                }
            }
        }

        is ToolCallSection.Code -> {
            ToolCallCodeLikeSection(
                label = section.label,
                language = section.language,
                content = section.content,
                syntaxMarkwon = syntaxMarkwon,
            )
        }

        is ToolCallSection.Json -> {
            ToolCallCodeLikeSection(
                label = section.label,
                language = "json",
                content = section.content,
                syntaxMarkwon = syntaxMarkwon,
            )
        }

        is ToolCallSection.Diff -> {
            ToolCallCodeLikeSection(
                label = section.label,
                language = "diff",
                content = section.content,
                syntaxMarkwon = syntaxMarkwon,
            )
        }

        is ToolCallSection.Text -> {
            ToolCallCodeLikeSection(
                label = section.label,
                language = "text",
                content = section.content,
                syntaxMarkwon = syntaxMarkwon,
            )
        }

        is ToolCallSection.ListSection -> {
            if (section.items.isEmpty()) return
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = section.label.uppercase(Locale.US),
                    color = LitterTheme.textSecondary,
                    style = MaterialTheme.typography.labelSmall,
                )
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = LitterTheme.surface.copy(alpha = 0.6f),
                ) {
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 7.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        section.items.forEach { item ->
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text("•", color = LitterTheme.textSecondary, style = MaterialTheme.typography.bodySmall)
                                Text(
                                    text = item,
                                    color = LitterTheme.textSystem,
                                    style = MaterialTheme.typography.bodySmall,
                                    modifier = Modifier.weight(1f),
                                )
                            }
                        }
                    }
                }
            }
        }

        is ToolCallSection.Progress -> {
            if (section.items.isEmpty()) return
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = section.label.uppercase(Locale.US),
                    color = LitterTheme.textSecondary,
                    style = MaterialTheme.typography.labelSmall,
                )
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = LitterTheme.surface.copy(alpha = 0.6f),
                ) {
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 7.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        section.items.forEachIndexed { index, item ->
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.Top,
                            ) {
                                Box(
                                    modifier =
                                        Modifier
                                            .padding(top = 5.dp)
                                            .size(6.dp)
                                            .clip(CircleShape)
                                            .background(
                                                if (index == section.items.lastIndex) LitterTheme.warning else LitterTheme.textMuted,
                                            ),
                                )
                                Text(
                                    text = item,
                                    color = LitterTheme.textSystem,
                                    style = MaterialTheme.typography.bodySmall,
                                    modifier = Modifier.weight(1f),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ToolCallCodeLikeSection(
    label: String,
    language: String,
    content: String,
    syntaxMarkwon: Markwon,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            text = label.uppercase(Locale.US),
            color = LitterTheme.textSecondary,
            style = MaterialTheme.typography.labelSmall,
        )
        CodeBlockCard(language = language, code = content, syntaxMarkwon = syntaxMarkwon)
    }
}

private fun toolCallKindIcon(kind: ToolCallKind) =
    when (kind) {
        ToolCallKind.COMMAND_EXECUTION -> Icons.Default.Menu
        ToolCallKind.COMMAND_OUTPUT -> Icons.Default.Menu
        ToolCallKind.FILE_CHANGE -> Icons.Default.Folder
        ToolCallKind.FILE_DIFF -> Icons.Default.Folder
        ToolCallKind.MCP_TOOL_CALL -> Icons.Default.Settings
        ToolCallKind.MCP_TOOL_PROGRESS -> Icons.Default.Settings
        ToolCallKind.WEB_SEARCH -> Icons.Default.ArrowUpward
        ToolCallKind.COLLABORATION -> Icons.Default.Psychology
        ToolCallKind.IMAGE_VIEW -> Icons.Default.Image
    }

private fun toolCallKindAccent(kind: ToolCallKind) =
    when (kind) {
        ToolCallKind.COMMAND_EXECUTION, ToolCallKind.COMMAND_OUTPUT -> LitterTheme.toolCallCommand
        ToolCallKind.FILE_CHANGE -> LitterTheme.toolCallFileChange
        ToolCallKind.FILE_DIFF -> LitterTheme.toolCallFileDiff
        ToolCallKind.MCP_TOOL_CALL -> LitterTheme.toolCallMcpCall
        ToolCallKind.MCP_TOOL_PROGRESS -> LitterTheme.toolCallMcpProgress
        ToolCallKind.WEB_SEARCH -> LitterTheme.toolCallWebSearch
        ToolCallKind.COLLABORATION -> LitterTheme.toolCallCollaboration
        ToolCallKind.IMAGE_VIEW -> LitterTheme.toolCallImage
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
    onForkConversation: () -> Unit,
    onAttachImage: () -> Unit,
    onCaptureImage: () -> Unit,
    onClearAttachment: () -> Unit,
    onSend: (String, List<SkillMentionInput>) -> Unit,
    onInterrupt: () -> Unit,
) {
    DebugRecomposeCheckpoint(name = "InputBar")
    var composerValue by
        remember {
            mutableStateOf(
                TextFieldValue(
                    text = draft,
                    selection = TextRange(draft.length),
                ),
            )
        }
    var lastCommittedDraft by remember { mutableStateOf(draft) }
    var showSlashPopup by remember { mutableStateOf(false) }
    var activeSlashToken by remember { mutableStateOf<ComposerSlashQueryContext?>(null) }
    var slashSuggestions by remember { mutableStateOf<List<ComposerSlashCommand>>(emptyList()) }

    var showFilePopup by remember { mutableStateOf(false) }
    var activeAtToken by remember { mutableStateOf<ComposerTokenContext?>(null) }
    var showSkillPopup by remember { mutableStateOf(false) }
    var activeDollarToken by remember { mutableStateOf<ComposerTokenContext?>(null) }
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
    var renameCurrentTitle by remember { mutableStateOf("") }
    var renameDraft by remember { mutableStateOf("") }
    var slashErrorMessage by remember { mutableStateOf<String?>(null) }
    var experimentalFeatures by remember { mutableStateOf<List<ExperimentalFeature>>(emptyList()) }
    var experimentalFeaturesLoading by remember { mutableStateOf(false) }
    var skills by remember { mutableStateOf<List<SkillMetadata>>(emptyList()) }
    var skillsLoading by remember { mutableStateOf(false) }
    var showAttachmentMenu by remember { mutableStateOf(false) }
    var mentionSkillPathsByName by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var hasAttemptedSkillMentionLoad by remember { mutableStateOf(false) }

    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current

    fun commitDraftIfNeeded(nextDraft: String) {
        if (nextDraft == lastCommittedDraft) {
            return
        }
        onDraftChange(nextDraft)
        lastCommittedDraft = nextDraft
    }

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
        showSkillPopup = false
        activeDollarToken = null
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

    fun loadSkillsForMentions() {
        skillsLoading = true
        onListSkills(currentCwd, false) { result ->
            skillsLoading = false
            result.onSuccess { loaded ->
                val sortedSkills = loaded.sortedBy { it.name.lowercase(Locale.ROOT) }
                skills = sortedSkills
                val validPaths = sortedSkills.mapTo(HashSet()) { it.path }
                mentionSkillPathsByName = mentionSkillPathsByName.filterValues { path -> validPaths.contains(path) }
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
            showSkillPopup = false
            activeDollarToken = null
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

        val dollarToken =
            currentPrefixedToken(
                text = nextValue.text,
                cursor = nextValue.selection.start,
                prefix = '$',
                allowEmpty = true,
            )
        if (dollarToken != null && isMentionQueryValid(dollarToken.value)) {
            showSlashPopup = false
            activeSlashToken = null
            slashSuggestions = emptyList()
            showSkillPopup = true
            if (activeDollarToken != dollarToken) {
                activeDollarToken = dollarToken
            }
            if (!hasAttemptedSkillMentionLoad && !skillsLoading) {
                hasAttemptedSkillMentionLoad = true
                loadSkillsForMentions()
            }
            return
        }

        showSkillPopup = false
        activeDollarToken = null

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

    fun loadSkills(forceReload: Boolean = false, showErrors: Boolean = true) {
        skillsLoading = true
        onListSkills(currentCwd, forceReload) { result ->
            skillsLoading = false
            result.onFailure { error ->
                if (showErrors) {
                    slashErrorMessage = error.message ?: "Failed to load skills"
                }
            }
            result.onSuccess { loaded ->
                val sortedSkills = loaded.sortedBy { it.name.lowercase(Locale.ROOT) }
                skills = sortedSkills
                val validPaths = sortedSkills.mapTo(HashSet()) { it.path }
                mentionSkillPathsByName = mentionSkillPathsByName.filterValues { path -> validPaths.contains(path) }
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
                    renameCurrentTitle = activeThreadPreview.ifBlank { "Untitled thread" }
                    renameDraft = ""
                    showRenameDialog = true
                }
            }

            ComposerSlashCommand.NEW -> {
                onOpenNewSessionPicker()
            }

            ComposerSlashCommand.FORK -> {
                onForkConversation()
            }

            ComposerSlashCommand.RESUME -> {
                onOpenSidebar()
            }
        }
    }

    fun applySlashSuggestion(command: ComposerSlashCommand) {
        composerValue = TextFieldValue(text = "", selection = TextRange(0))
        commitDraftIfNeeded("")
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
        commitDraftIfNeeded(updatedText)
        showFilePopup = false
        activeAtToken = null
        clearFileSearchState()
    }

    fun applySkillSuggestion(skill: SkillMetadata) {
        val token = activeDollarToken ?: return
        val replacement = "\$${skill.name} "
        val updatedText =
            composerValue.text.replaceRange(
                startIndex = token.range.start,
                endIndex = token.range.end,
                replacement = replacement,
            )
        val nextCursor = token.range.start + replacement.length
        composerValue = TextFieldValue(text = updatedText, selection = TextRange(nextCursor))
        commitDraftIfNeeded(updatedText)
        mentionSkillPathsByName =
            mentionSkillPathsByName + mapOf(skill.name.lowercase(Locale.ROOT) to skill.path)
        showSkillPopup = false
        activeDollarToken = null
    }

    fun collectSkillMentionsForSubmission(text: String): List<SkillMentionInput> {
        if (skills.isEmpty()) {
            return emptyList()
        }
        val mentionNames = extractMentionNames(text)
        if (mentionNames.isEmpty()) {
            return emptyList()
        }

        val skillsByName = skills.groupBy { it.name.lowercase(Locale.ROOT) }
        val skillsByPath = skills.groupBy { it.path }
        val seenPaths = HashSet<String>()
        val resolved = ArrayList<SkillMentionInput>()
        for (name in mentionNames) {
            val normalizedName = name.lowercase(Locale.ROOT)
            val selectedPath = mentionSkillPathsByName[normalizedName]
            if (!selectedPath.isNullOrBlank()) {
                val selectedSkill = skillsByPath[selectedPath]?.firstOrNull()
                if (selectedSkill != null) {
                    if (seenPaths.add(selectedPath)) {
                        resolved += SkillMentionInput(name = selectedSkill.name, path = selectedPath)
                    }
                    continue
                }
                mentionSkillPathsByName = mentionSkillPathsByName - normalizedName
            }

            val candidates = skillsByName[normalizedName] ?: continue
            if (candidates.size != 1) {
                continue
            }
            val match = candidates.first()
            if (seenPaths.add(match.path)) {
                resolved += SkillMentionInput(name = match.name, path = match.path)
            }
        }
        return resolved
    }

    val skillSuggestions: List<SkillMetadata> =
        remember(activeDollarToken, skills) {
            val token = activeDollarToken ?: return@remember emptyList()
            filterSkillSuggestions(skills, token.value)
        }

    LaunchedEffect(draft) {
        if (draft != lastCommittedDraft) {
            lastCommittedDraft = draft
        }
        if (draft != composerValue.text && draft == lastCommittedDraft) {
            val cursor = composerValue.selection.start.coerceIn(0, draft.length)
            val synced = TextFieldValue(text = draft, selection = TextRange(cursor))
            composerValue = synced
            refreshComposerPopups(synced)
        }
    }

    LaunchedEffect(composerValue.text) {
        val pendingDraft = composerValue.text
        delay(180L)
        if (pendingDraft == composerValue.text) {
            commitDraftIfNeeded(pendingDraft)
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
            onDismissRequest = {
                showRenameDialog = false
                renameCurrentTitle = ""
                renameDraft = ""
            },
            title = { Text("Rename Thread") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = renameCurrentTitle,
                        color = LitterTheme.textSecondary,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    OutlinedTextField(
                        value = renameDraft,
                        onValueChange = { renameDraft = it },
                        label = { Text("New thread title") },
                        placeholder = { Text("Enter new thread title") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = renameDraft.trim().isNotEmpty(),
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
                                renameCurrentTitle = ""
                                renameDraft = ""
                            }
                        }
                    },
                ) {
                    Text("Rename")
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        showRenameDialog = false
                        renameCurrentTitle = ""
                        renameDraft = ""
                    },
                ) {
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
                                    color = LitterTheme.success,
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

            if (showSkillPopup) {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    color = LitterTheme.surfaceLight.copy(alpha = 0.98f),
                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                ) {
                    when {
                        skillsLoading && skillSuggestions.isEmpty() -> {
                            Text(
                                text = "Loading skills...",
                                color = LitterTheme.textSecondary,
                                style = MaterialTheme.typography.labelLarge,
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                            )
                        }

                        skillSuggestions.isEmpty() -> {
                            Text(
                                text = "No skills found",
                                color = LitterTheme.textSecondary,
                                style = MaterialTheme.typography.labelLarge,
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
                            )
                        }

                        else -> {
                            val visibleSuggestions = skillSuggestions.take(8)
                            Column {
                                visibleSuggestions.forEachIndexed { index, skill ->
                                    Row(
                                        modifier =
                                            Modifier
                                                .fillMaxWidth()
                                                .clickable { applySkillSuggestion(skill) }
                                                .padding(horizontal = 14.dp, vertical = 10.dp),
                                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Text(
                                            text = "\$${skill.name}",
                                            color = LitterTheme.success,
                                            style = MaterialTheme.typography.bodyMedium,
                                        )
                                        Text(
                                            text = skill.description,
                                            color = LitterTheme.textSecondary,
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
                                        commitDraftIfNeeded("")
                                        hideComposerPopups()
                                        focusManager.clearFocus(force = true)
                                        keyboardController?.hide()
                                        executeSlashCommand(invocation.command, invocation.args)
                                        return@clickable
                                    }
                                }
                                focusManager.clearFocus(force = true)
                                keyboardController?.hide()
                                commitDraftIfNeeded(composerValue.text)
                                val skillMentions = collectSkillMentionsForSubmission(composerValue.text)
                                onSend(composerValue.text, skillMentions)
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
    FORK(rawValue = "fork", description = "fork the current conversation into a new session"),
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

private fun filterSkillSuggestions(
    skills: List<SkillMetadata>,
    query: String,
): List<SkillMetadata> {
    if (skills.isEmpty()) {
        return emptyList()
    }
    if (query.isBlank()) {
        return skills.sortedBy { it.name.lowercase(Locale.ROOT) }
    }

    return skills
        .mapNotNull { skill ->
            val scoreFromName = fuzzyScore(candidate = skill.name, query = query)
            val scoreFromDescription = fuzzyScore(candidate = skill.description, query = query)
            val score = maxOf(scoreFromName ?: Int.MIN_VALUE, scoreFromDescription ?: Int.MIN_VALUE)
            if (score == Int.MIN_VALUE) {
                null
            } else {
                skill to score
            }
        }
        .sortedWith(
            compareByDescending<Pair<SkillMetadata, Int>> { it.second }
                .thenBy { it.first.name.lowercase(Locale.ROOT) },
        )
        .map { it.first }
}

private fun isMentionNameChar(char: Char): Boolean = char.isLetterOrDigit() || char == '_' || char == '-'

private fun isMentionQueryValid(query: String): Boolean = query.all(::isMentionNameChar)

private fun extractMentionNames(text: String): List<String> {
    if (text.isEmpty()) {
        return emptyList()
    }

    val mentions = ArrayList<String>()
    var index = 0
    while (index < text.length) {
        if (text[index] != '$') {
            index += 1
            continue
        }
        if (index > 0 && isMentionNameChar(text[index - 1])) {
            index += 1
            continue
        }

        val nameStart = index + 1
        if (nameStart >= text.length || !isMentionNameChar(text[nameStart])) {
            index += 1
            continue
        }

        var nameEnd = nameStart + 1
        while (nameEnd < text.length && isMentionNameChar(text[nameEnd])) {
            nameEnd += 1
        }
        mentions += text.substring(nameStart, nameEnd)
        index = nameEnd
    }
    return mentions
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
    recentDirectories: List<RecentDirectoryUiState>,
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
    onNavigateToPath: (String) -> Unit,
    onSelect: () -> Unit,
    onSelectRecent: (String) -> Unit,
    onRemoveRecentDirectory: (String) -> Unit,
    onClearRecentDirectories: () -> Unit,
    onRetry: () -> Unit,
) {
    DebugRecomposeCheckpoint(name = "DirectoryPickerSheet")
    val configuration = LocalConfiguration.current
    val useLargeScreenDialog =
        configuration.screenWidthDp >= 900 || configuration.smallestScreenWidthDp >= 600

    BackHandler(enabled = true) { onDismiss() }

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
                    DirectoryPickerSheetContent(
                        connectedServers = connectedServers,
                        selectedServerId = selectedServerId,
                        path = path,
                        entries = entries,
                        recentDirectories = recentDirectories,
                        isLoading = isLoading,
                        error = error,
                        searchQuery = searchQuery,
                        showHiddenDirectories = showHiddenDirectories,
                        onDismiss = onDismiss,
                        onServerSelected = onServerSelected,
                        onSearchQueryChange = onSearchQueryChange,
                        onShowHiddenDirectoriesChange = onShowHiddenDirectoriesChange,
                        onNavigateUp = onNavigateUp,
                        onNavigateInto = onNavigateInto,
                        onNavigateToPath = onNavigateToPath,
                        onSelect = onSelect,
                        onSelectRecent = onSelectRecent,
                        onRemoveRecentDirectory = onRemoveRecentDirectory,
                        onClearRecentDirectories = onClearRecentDirectories,
                        onRetry = onRetry,
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
        DirectoryPickerSheetContent(
            connectedServers = connectedServers,
            selectedServerId = selectedServerId,
            path = path,
            entries = entries,
            recentDirectories = recentDirectories,
            isLoading = isLoading,
            error = error,
            searchQuery = searchQuery,
            showHiddenDirectories = showHiddenDirectories,
            onDismiss = onDismiss,
            onServerSelected = onServerSelected,
            onSearchQueryChange = onSearchQueryChange,
            onShowHiddenDirectoriesChange = onShowHiddenDirectoriesChange,
            onNavigateUp = onNavigateUp,
            onNavigateInto = onNavigateInto,
            onNavigateToPath = onNavigateToPath,
            onSelect = onSelect,
            onSelectRecent = onSelectRecent,
            onRemoveRecentDirectory = onRemoveRecentDirectory,
            onClearRecentDirectories = onClearRecentDirectories,
            onRetry = onRetry,
            modifier =
                Modifier
                    .fillMaxWidth()
                    .fillMaxHeight(0.92f)
                    .padding(horizontal = 12.dp, vertical = 8.dp),
        )
    }
}

@Composable
private fun DirectoryPickerSheetContent(
    connectedServers: List<ServerConfig>,
    selectedServerId: String?,
    path: String,
    entries: List<String>,
    recentDirectories: List<RecentDirectoryUiState>,
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
    onNavigateToPath: (String) -> Unit,
    onSelect: () -> Unit,
    onSelectRecent: (String) -> Unit,
    onRemoveRecentDirectory: (String) -> Unit,
    onClearRecentDirectories: () -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var serverMenuExpanded by rememberSaveable { mutableStateOf(false) }
    var recentsMenuExpanded by rememberSaveable { mutableStateOf(false) }
    var showClearRecentsConfirmation by rememberSaveable { mutableStateOf(false) }
    val selectedServer = connectedServers.firstOrNull { it.id == selectedServerId }
    val selectedServerLabel = selectedServer?.let { "${it.name} • ${serverSourceLabel(it.source)}" } ?: stringResource(R.string.directory_picker_select_server)
    val selectedPath = path.ifBlank { "/" }
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
            stringResource(R.string.directory_picker_no_subdirectories)
        } else {
            stringResource(R.string.directory_picker_no_matches, trimmedQuery)
        }
    val showRecentDirectories = trimmedQuery.isEmpty() && recentDirectories.isNotEmpty()
    val canSelect = selectedServer != null && selectedPath.isNotBlank() && !isLoading
    val canGoUp = selectedServer != null && selectedPath != "/"
    val continueRecent = remember(recentDirectories, trimmedQuery) { recentDirectories.firstOrNull()?.takeIf { trimmedQuery.isEmpty() } }
    val selectedPathLabel = remember(selectedPath) { middleEllipsize(selectedPath, maxChars = 56) }
    val pathSegments = remember(selectedPath) { directoryPathSegments(selectedPath) }
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(stringResource(R.string.directory_picker_title), style = MaterialTheme.typography.titleMedium)

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Surface(
                modifier = Modifier.weight(1f),
                color = LitterTheme.surface.copy(alpha = 0.65f),
                shape = RoundedCornerShape(20.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
            ) {
                Text(
                    text = stringResource(R.string.directory_picker_connected_server, selectedServerLabel),
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
                    style = MaterialTheme.typography.labelLarge,
                    color = LitterTheme.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Box {
                TextButton(
                    onClick = { serverMenuExpanded = true },
                    enabled = connectedServers.isNotEmpty(),
                ) {
                    Text(stringResource(R.string.directory_picker_change_server))
                }
                DropdownMenu(
                    expanded = serverMenuExpanded,
                    onDismissRequest = { serverMenuExpanded = false },
                ) {
                    connectedServers.forEach { server ->
                        DropdownMenuItem(
                            text = {
                                Text(
                                    "${server.name} • ${serverSourceLabel(server.source)}",
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

        OutlinedTextField(
            value = searchQuery,
            onValueChange = onSearchQueryChange,
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text(stringResource(R.string.directory_picker_search_folders)) },
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
            Text(
                text = stringResource(R.string.directory_picker_show_hidden_folders),
                color = LitterTheme.textSecondary,
                style = MaterialTheme.typography.bodySmall,
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedButton(
                onClick = onNavigateUp,
                enabled = canGoUp,
            ) {
                Icon(Icons.Default.ArrowUpward, contentDescription = null, modifier = Modifier.size(14.dp))
                Spacer(modifier = Modifier.width(4.dp))
                Text(stringResource(R.string.directory_picker_up_one_level))
            }
            pathSegments.forEach { segment ->
                Surface(
                    modifier = Modifier.clickable { onNavigateToPath(segment.path) },
                    color = if (segment.path == selectedPath) LitterTheme.surfaceLight else LitterTheme.surface.copy(alpha = 0.65f),
                    shape = RoundedCornerShape(16.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, if (segment.path == selectedPath) LitterTheme.accent else LitterTheme.border),
                ) {
                    Text(
                        text = segment.label,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                        style = MaterialTheme.typography.labelLarge,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }

        Surface(
            modifier = Modifier.weight(1f).fillMaxWidth(),
            color = LitterTheme.surface.copy(alpha = 0.4f),
            shape = RoundedCornerShape(10.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
        ) {
            when {
                isLoading -> {
                    Box(
                        modifier = Modifier.fillMaxSize(),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = stringResource(R.string.directory_picker_loading),
                            color = LitterTheme.textMuted,
                        )
                    }
                }

                error != null -> {
                    Column(
                        modifier = Modifier.fillMaxSize().padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(
                            text = stringResource(R.string.directory_picker_load_error),
                            color = LitterTheme.danger,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        Spacer(modifier = Modifier.height(6.dp))
                        Text(
                            text = error,
                            color = LitterTheme.textSecondary,
                            style = MaterialTheme.typography.bodySmall,
                        )
                        Spacer(modifier = Modifier.height(10.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(onClick = onRetry) {
                                Text(stringResource(R.string.directory_picker_retry))
                            }
                            TextButton(onClick = { serverMenuExpanded = true }) {
                                Text(stringResource(R.string.directory_picker_change_server))
                            }
                        }
                    }
                }

                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize().padding(8.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        continueRecent?.let { recent ->
                            item(key = "continue-recent") {
                                Button(
                                    onClick = { onSelectRecent(recent.path) },
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    Text(
                                        text = stringResource(R.string.directory_picker_continue_in_folder, cwdLeaf(recent.path)),
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }

                        if (showRecentDirectories) {
                            item(key = "recents-header") {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text(
                                        text = stringResource(R.string.directory_picker_recent_directories),
                                        color = LitterTheme.textSecondary,
                                        style = MaterialTheme.typography.labelLarge,
                                    )
                                    Box {
                                        IconButton(onClick = { recentsMenuExpanded = true }) {
                                            Icon(Icons.Default.MoreVert, contentDescription = null, tint = LitterTheme.textSecondary)
                                        }
                                        DropdownMenu(
                                            expanded = recentsMenuExpanded,
                                            onDismissRequest = { recentsMenuExpanded = false },
                                        ) {
                                            DropdownMenuItem(
                                                text = { Text(stringResource(R.string.directory_picker_clear_recent_directories)) },
                                                onClick = {
                                                    recentsMenuExpanded = false
                                                    showClearRecentsConfirmation = true
                                                },
                                            )
                                        }
                                    }
                                }
                            }

                            items(recentDirectories, key = { "recent-${it.path}" }) { recent ->
                                Surface(
                                    modifier = Modifier.fillMaxWidth().clickable { onSelectRecent(recent.path) },
                                    color = LitterTheme.surfaceLight.copy(alpha = 0.5f),
                                    shape = RoundedCornerShape(8.dp),
                                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                                ) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    ) {
                                        Icon(
                                            Icons.Default.Folder,
                                            contentDescription = null,
                                            tint = LitterTheme.textSecondary,
                                        )
                                        Column(
                                            modifier = Modifier.weight(1f),
                                            verticalArrangement = Arrangement.spacedBy(2.dp),
                                        ) {
                                            Text(
                                                recent.path,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis,
                                                style = MaterialTheme.typography.bodySmall,
                                            )
                                            val relativeDate =
                                                DateUtils
                                                    .getRelativeTimeSpanString(
                                                        recent.lastUsedAtEpochMillis,
                                                        System.currentTimeMillis(),
                                                        DateUtils.MINUTE_IN_MILLIS,
                                                    ).toString()
                                            Text(
                                                "$relativeDate • ${recent.useCount} uses",
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis,
                                                color = LitterTheme.textSecondary,
                                                style = MaterialTheme.typography.labelSmall,
                                            )
                                        }
                                        IconButton(onClick = { onRemoveRecentDirectory(recent.path) }) {
                                            Icon(
                                                Icons.Default.Close,
                                                contentDescription = stringResource(R.string.directory_picker_remove_recent),
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        if (canGoUp) {
                            item(key = "up") {
                                Surface(
                                    modifier = Modifier.fillMaxWidth().clickable(onClick = onNavigateUp),
                                    color = LitterTheme.surface.copy(alpha = 0.6f),
                                    shape = RoundedCornerShape(8.dp),
                                    border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
                                ) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    ) {
                                        Icon(Icons.Default.ArrowUpward, contentDescription = null, tint = LitterTheme.textSecondary)
                                        Text(
                                            text = stringResource(R.string.directory_picker_up_one_level),
                                            color = LitterTheme.textSecondary,
                                            style = MaterialTheme.typography.bodySmall,
                                        )
                                    }
                                }
                            }
                        }

                        if (visibleEntries.isEmpty()) {
                            item(key = "empty") {
                                Text(
                                    text = emptyMessage,
                                    color = LitterTheme.textMuted,
                                    style = MaterialTheme.typography.bodySmall,
                                    modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 12.dp),
                                )
                            }
                        } else {
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

        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (selectedPath.isNotBlank()) {
                Text(
                    text = selectedPathLabel,
                    color = LitterTheme.textMuted,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                )
            } else if (!canSelect) {
                Text(
                    text = stringResource(R.string.directory_picker_choose_folder_helper),
                    color = LitterTheme.textSecondary,
                    style = MaterialTheme.typography.labelLarge,
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onDismiss) {
                    Text(stringResource(R.string.directory_picker_cancel))
                }
                TextButton(
                    onClick = onSelect,
                    enabled = canSelect,
                ) {
                    Text(stringResource(R.string.directory_picker_select_folder))
                }
            }
        }
    }

    if (showClearRecentsConfirmation) {
        AlertDialog(
            onDismissRequest = { showClearRecentsConfirmation = false },
            title = { Text(stringResource(R.string.directory_picker_clear_recent_title)) },
            text = { Text(stringResource(R.string.directory_picker_clear_recent_message)) },
            dismissButton = {
                TextButton(onClick = { showClearRecentsConfirmation = false }) {
                    Text(stringResource(R.string.directory_picker_cancel))
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showClearRecentsConfirmation = false
                        onClearRecentDirectories()
                    },
                ) {
                    Text(stringResource(R.string.directory_picker_clear))
                }
            },
        )
    }
}

private data class DirectoryPathSegment(
    val label: String,
    val path: String,
)

private fun directoryPathSegments(path: String): List<DirectoryPathSegment> {
    val normalized = path.trim().ifEmpty { "/" }
    if (normalized == "/") {
        return listOf(DirectoryPathSegment(label = "/", path = "/"))
    }
    val segments = mutableListOf(DirectoryPathSegment(label = "/", path = "/"))
    var runningPath = ""
    normalized
        .trim('/')
        .split('/')
        .filter { it.isNotBlank() }
        .forEach { segment ->
            runningPath = if (runningPath.isEmpty()) "/$segment" else "$runningPath/$segment"
            segments += DirectoryPathSegment(label = segment, path = runningPath)
        }
    return segments
}

private fun middleEllipsize(
    value: String,
    maxChars: Int,
): String {
    if (maxChars < 5 || value.length <= maxChars) {
        return value
    }
    val headCount = (maxChars - 1) / 2
    val tailCount = maxChars - 1 - headCount
    return "${value.take(headCount)}…${value.takeLast(tailCount)}"
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
    onCopyBundledLogs: () -> Unit,
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
                        onCopyBundledLogs = onCopyBundledLogs,
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
            onCopyBundledLogs = onCopyBundledLogs,
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
    onCopyBundledLogs: () -> Unit,
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

        OutlinedButton(
            onClick = onCopyBundledLogs,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Bundled Debug")
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

        Text("Typography", color = LitterTheme.textSecondary, style = MaterialTheme.typography.labelLarge)
        Surface(
            modifier = Modifier.fillMaxWidth(),
            color = LitterTheme.surface.copy(alpha = 0.6f),
            shape = RoundedCornerShape(8.dp),
            border = androidx.compose.foundation.BorderStroke(1.dp, LitterTheme.border),
        ) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text("Custom Font", color = LitterTheme.textPrimary)
                Text(
                    "Berkeley Mono is not bundled. Please upload your own licensed .otf or .ttf monospace font.",
                    color = LitterTheme.textSecondary,
                    style = MaterialTheme.typography.labelLarge,
                )
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
    activeServerSource: ServerSource?,
    apiKeyDraft: String,
    isWorking: Boolean,
    onDismiss: () -> Unit,
    onApiKeyDraftChanged: (String) -> Unit,
    onLoginWithChatGpt: () -> Unit,
    onLoginWithApiKey: () -> Unit,
    onLogout: () -> Unit,
    onCancelLogin: () -> Unit,
    onCopyBundledLogs: () -> Unit,
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
                        val sourceLabel = activeServerSource?.let { serverSourceLabel(it) } ?: "none"
                        Text("Server: $sourceLabel", color = LitterTheme.textMuted, style = MaterialTheme.typography.labelLarge)
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

            OutlinedButton(
                onClick = onCopyBundledLogs,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Copy Bundled Logs")
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
        AuthStatus.API_KEY -> LitterTheme.info
        AuthStatus.NOT_LOGGED_IN -> LitterTheme.textMuted
        AuthStatus.UNKNOWN -> LitterTheme.textMuted
    }

private fun serverSourceLabel(source: ServerSource): String =
    when (source) {
        ServerSource.LOCAL -> "local"
        ServerSource.BUNDLED -> "bundled"
        ServerSource.BONJOUR -> "bonjour"
        ServerSource.SSH -> "ssh"
        ServerSource.TAILSCALE -> "tailscale"
        ServerSource.MANUAL -> "manual"
        ServerSource.REMOTE -> "remote"
    }

private fun serverSourceAccentColor(source: ServerSource): Color =
    when (source) {
        ServerSource.LOCAL -> LitterTheme.accent
        ServerSource.BUNDLED -> LitterTheme.accent
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
        DiscoverySource.BUNDLED -> "bundled"
        DiscoverySource.BONJOUR -> "bonjour"
        DiscoverySource.SSH -> "ssh"
        DiscoverySource.TAILSCALE -> "tailscale"
        DiscoverySource.MANUAL -> "manual"
        DiscoverySource.LAN -> "lan"
    }
