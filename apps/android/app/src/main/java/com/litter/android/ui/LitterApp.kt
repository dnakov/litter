package com.litter.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.litter.android.state.AppModel
import com.litter.android.state.NetworkDiscovery
import com.litter.android.state.VoiceRuntimeController
import com.litter.android.state.connectionModeLabel
import kotlinx.coroutines.launch
import com.litter.android.ui.conversation.ApprovalOverlay
import com.litter.android.ui.conversation.ConversationInfoScreen
import com.litter.android.ui.conversation.ConversationScreen
import com.litter.android.ui.discovery.DiscoveryScreen
import com.litter.android.ui.home.HomeDashboardScreen
import com.litter.android.ui.home.HomeDashboardSupport
import com.litter.android.ui.settings.AccountSheet
import com.litter.android.ui.settings.SettingsSheet
import com.litter.android.ui.sessions.DirectoryPickerServerOption
import com.litter.android.ui.sessions.DirectoryPickerSheet
import com.litter.android.ui.sessions.SessionLaunchSupport
import com.litter.android.ui.sessions.SessionsUiState
import uniffi.codex_mobile_client.ThreadKey

/**
 * CompositionLocal for accessing [AppModel] from any composable.
 */
val LocalAppModel = staticCompositionLocalOf<AppModel> {
    error("AppModel not provided")
}

/**
 * Root composable for the app. Manages navigation stack and global overlays.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LitterApp(appModel: AppModel) {
    val context = LocalContext.current

    // Initialize text size preference
    LaunchedEffect(Unit) {
        TextSizePrefs.initialize(context)
        ConversationPrefs.initialize(context)
        ExperimentalFeatures.initialize(context)
    }

    CompositionLocalProvider(
        LocalAppModel provides appModel,
        LocalTextScale provides TextSizePrefs.currentScale,
    ) {
        val snapshot by appModel.snapshot.collectAsState()
        val scope = androidx.compose.runtime.rememberCoroutineScope()

        // Navigation state
        var navStack by remember { mutableStateOf<List<Route>>(listOf(Route.Home)) }
        val currentRoute = navStack.lastOrNull() ?: Route.Home
        val sessionsUiState = remember { SessionsUiState() }

        // Global sheet state
        var showDiscovery by remember { mutableStateOf(false) }
        var showSettings by remember { mutableStateOf(false) }
        var showAccountForServer by remember { mutableStateOf<String?>(null) }
        var directoryPickerServerId by remember { mutableStateOf<String?>(null) }

        // Network discovery
        val networkDiscovery = remember { NetworkDiscovery(appModel.discovery) }
        val voiceController = remember { VoiceRuntimeController.shared }

        // Navigate helpers
        val navigate = remember {
            { route: Route -> navStack = navStack + route }
        }
        val navigateBack = remember {
            { if (navStack.size > 1) navStack = navStack.dropLast(1) }
        }
        val navigateToConversation = remember {
            { key: ThreadKey -> navStack = listOf(Route.Home, Route.Conversation(key)) }
        }
        val connectedServerOptions = remember(snapshot) {
            snapshot?.let { snap ->
                HomeDashboardSupport.sortedConnectedServers(snap).map { server ->
                    DirectoryPickerServerOption(
                        id = server.serverId,
                        name = server.displayName,
                        sourceLabel = server.connectionModeLabel,
                    )
                }
            } ?: emptyList()
        }

        suspend fun startNewSession(serverId: String, cwd: String) {
            val startedKey = appModel.client.startThread(
                serverId,
                appModel.launchState.threadStartRequest(cwd),
            )
            appModel.store.setActiveThread(startedKey)
            appModel.refreshSnapshot()
            val resolvedKey = appModel.ensureThreadLoaded(startedKey)
                ?: appModel.snapshot.value?.threads?.firstOrNull { it.key == startedKey }?.key
                ?: startedKey
            navigateToConversation(resolvedKey)
        }

        fun openDirectoryPicker(preferredServerId: String? = null) {
            val targetServerId = SessionLaunchSupport.defaultConnectedServerId(
                connectedServerIds = connectedServerOptions.map { it.id },
                activeThreadKey = snapshot?.activeThread,
                preferredServerId = preferredServerId,
            )
            if (targetServerId == null) {
                showDiscovery = true
            } else {
                directoryPickerServerId = targetServerId
            }
        }

        // Auto-navigate to active thread when it changes
        LaunchedEffect(snapshot?.activeThread) {
            val activeKey = snapshot?.activeThread ?: return@LaunchedEffect
            val alreadyShowing = when (val route = currentRoute) {
                is Route.Conversation -> route.key == activeKey
                is Route.RealtimeVoice -> route.key == activeKey
                else -> false
            }
            if (!alreadyShowing) {
                navStack = listOf(Route.Home, Route.Conversation(activeKey))
            }
        }

        val rootModifier = if (currentRoute is Route.Conversation) {
            Modifier
                .fillMaxSize()
                .background(LitterTheme.background)
        } else {
            Modifier
                .fillMaxSize()
                .background(LitterTheme.background)
                .systemBarsPadding()
        }

        Box(modifier = rootModifier) {
            when (val route = currentRoute) {
                is Route.Home -> {
                    HomeDashboardScreen(
                        onOpenConversation = navigateToConversation,
                        onOpenSessions = { serverId, title ->
                            navigate(Route.Sessions(serverId, title))
                        },
                        onNewSession = { openDirectoryPicker() },
                        onShowDiscovery = { showDiscovery = true },
                        onShowSettings = { showSettings = true },
                        onStartVoice = {
                            scope.launch {
                                val launchState = appModel.launchState.snapshot.value
                                val threadKey = voiceController.preparePinnedLocalVoiceThread(
                                    appModel = appModel,
                                    cwd = launchState.currentCwd.ifBlank { "~" },
                                    model = launchState.selectedModel.ifBlank { null },
                                )
                                if (threadKey != null) {
                                    navigate(Route.RealtimeVoice(threadKey))
                                }
                            }
                        },
                    )
                }

                is Route.Sessions -> {
                    com.litter.android.ui.sessions.SessionsScreen(
                        serverId = route.serverId,
                        title = route.title,
                        sessionsUiState = sessionsUiState,
                        onOpenConversation = navigateToConversation,
                        onNewSession = { openDirectoryPicker(route.serverId) },
                        onBack = navigateBack,
                        onInfo = { navigate(Route.ServerInfo(route.serverId)) },
                    )
                }

                is Route.Conversation -> {
                    ConversationScreen(
                        threadKey = route.key,
                        onBack = navigateBack,
                        onInfo = { navigate(Route.ConversationInfo(route.key)) },
                        onShowDirectoryPicker = { openDirectoryPicker(route.key.serverId) },
                    )
                }

                is Route.ConversationInfo -> {
                    ConversationInfoScreen(
                        threadKey = route.key,
                        onBack = navigateBack,
                        onChangeWallpaper = { navigate(Route.WallpaperSelection(route.key)) },
                    )
                }

                is Route.WallpaperSelection -> {
                    com.litter.android.ui.settings.WallpaperSelectionScreen(
                        threadKey = route.key,
                        onBack = navigateBack,
                        onAdjust = { navigate(Route.WallpaperAdjust(route.key)) },
                    )
                }

                is Route.WallpaperAdjust -> {
                    com.litter.android.ui.settings.WallpaperAdjustScreen(
                        threadKey = route.key,
                        onBack = navigateBack,
                        onApplied = {
                            // Pop back to conversation info (keep it on the stack)
                            navStack = navStack.filter {
                                it !is Route.WallpaperSelection &&
                                    it !is Route.WallpaperAdjust
                            }
                        },
                    )
                }

                is Route.ServerInfo -> {
                    ConversationInfoScreen(
                        threadKey = null,
                        serverId = route.serverId,
                        onBack = navigateBack,
                        onChangeWallpaper = { navigate(Route.ServerWallpaperSelection(route.serverId)) },
                    )
                }

                is Route.ServerWallpaperSelection -> {
                    com.litter.android.ui.settings.WallpaperSelectionScreen(
                        threadKey = null,
                        serverId = route.serverId,
                        onBack = navigateBack,
                        onAdjust = { navigate(Route.ServerWallpaperAdjust(route.serverId)) },
                    )
                }

                is Route.ServerWallpaperAdjust -> {
                    com.litter.android.ui.settings.WallpaperAdjustScreen(
                        threadKey = null,
                        serverId = route.serverId,
                        onBack = navigateBack,
                        onApplied = {
                            navStack = navStack.filter {
                                it !is Route.ServerWallpaperSelection &&
                                    it !is Route.ServerWallpaperAdjust
                            }
                        },
                    )
                }

                is Route.RealtimeVoice -> {
                    com.litter.android.ui.voice.RealtimeVoiceScreen(
                        threadKey = route.key,
                        onBack = navigateBack,
                    )
                }
            }

            // Global approval overlay
            val approvals = snapshot?.pendingApprovals.orEmpty()
            val userInputs = snapshot?.pendingUserInputs.orEmpty()
            if (approvals.isNotEmpty() || userInputs.isNotEmpty()) {
                ApprovalOverlay(
                    approvals = approvals,
                    userInputs = userInputs,
                    appStore = appModel.store,
                )
            }
        }

        // Discovery bottom sheet
        if (showDiscovery) {
            val discoveredServers by networkDiscovery.servers.collectAsState()
            val isScanning by networkDiscovery.isScanning.collectAsState()
            val scanProgress by networkDiscovery.scanProgress.collectAsState()
            val scanProgressLabel by networkDiscovery.scanProgressLabel.collectAsState()
            val context = LocalContext.current

            // Start scanning when discovery sheet opens
            LaunchedEffect(showDiscovery) {
                networkDiscovery.startScanning(context)
            }

            ModalBottomSheet(
                onDismissRequest = {
                    showDiscovery = false
                    networkDiscovery.stopScanning()
                },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                DiscoveryScreen(
                    discoveredServers = discoveredServers,
                    isScanning = isScanning,
                    scanProgress = scanProgress,
                    scanProgressLabel = scanProgressLabel,
                    onRefresh = { networkDiscovery.startScanning(context) },
                    onDismiss = {
                        showDiscovery = false
                        networkDiscovery.stopScanning()
                    },
                )
            }
        }

        // Settings bottom sheet
        if (showSettings) {
            ModalBottomSheet(
                onDismissRequest = { showSettings = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                SettingsSheet(
                    onDismiss = { showSettings = false },
                    onOpenAccount = { serverId ->
                        showSettings = false
                        showAccountForServer = serverId
                    },
                )
            }
        }

        if (directoryPickerServerId != null) {
            ModalBottomSheet(
                onDismissRequest = { directoryPickerServerId = null },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                DirectoryPickerSheet(
                    servers = connectedServerOptions,
                    initialServerId = directoryPickerServerId!!,
                    onSelect = { serverId, cwd ->
                        directoryPickerServerId = null
                        scope.launch {
                            runCatching { startNewSession(serverId, cwd) }
                        }
                    },
                    onDismiss = { directoryPickerServerId = null },
                )
            }
        }

        // Account bottom sheet
        showAccountForServer?.let { serverId ->
            ModalBottomSheet(
                onDismissRequest = { showAccountForServer = null },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                AccountSheet(
                    serverId = serverId,
                    onDismiss = { showAccountForServer = null },
                )
            }
        }
    }
}
