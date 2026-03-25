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
import kotlinx.coroutines.launch
import com.litter.android.ui.conversation.ApprovalOverlay
import com.litter.android.ui.conversation.ConversationScreen
import com.litter.android.ui.discovery.DiscoveryScreen
import com.litter.android.ui.home.HomeDashboardScreen
import com.litter.android.ui.settings.AccountSheet
import com.litter.android.ui.settings.SettingsSheet
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
    LaunchedEffect(Unit) { TextSizePrefs.initialize(context) }

    CompositionLocalProvider(
        LocalAppModel provides appModel,
        LocalTextScale provides TextSizePrefs.currentScale,
    ) {
        val snapshot by appModel.snapshot.collectAsState()
        val scope = androidx.compose.runtime.rememberCoroutineScope()

        // Navigation state
        var navStack by remember { mutableStateOf<List<Route>>(listOf(Route.Home)) }
        val currentRoute = navStack.lastOrNull() ?: Route.Home

        // Global sheet state
        var showDiscovery by remember { mutableStateOf(false) }
        var showSettings by remember { mutableStateOf(false) }
        var showAccountForServer by remember { mutableStateOf<String?>(null) }

        // Network discovery
        val networkDiscovery = remember { NetworkDiscovery(appModel.discovery) }

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

        // Auto-navigate to active thread when it changes
        LaunchedEffect(snapshot?.activeThread) {
            val activeKey = snapshot?.activeThread ?: return@LaunchedEffect
            val alreadyShowing = currentRoute is Route.Conversation &&
                (currentRoute as Route.Conversation).key == activeKey
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
                        onShowDiscovery = { showDiscovery = true },
                        onShowSettings = { showSettings = true },
                        onStartVoice = {
                            scope.launch {
                                try {
                                    // Ensure local server is connected
                                    val snap = appModel.snapshot.value
                                    var localServer = snap?.servers?.firstOrNull { it.isLocal }
                                    if (localServer == null) {
                                        appModel.serverBridge.connectLocalServer("local", "Local", "127.0.0.1", 0u)
                                        appModel.refreshSnapshot()
                                        localServer = appModel.snapshot.value?.servers?.firstOrNull { it.isLocal }
                                    }
                                    if (localServer != null) {
                                        // Create a thread, then navigate to voice screen
                                        // The voice screen handles auth check and starting the realtime session
                                        val config = com.litter.android.state.AppThreadLaunchConfig()
                                        val resp = appModel.rpc.threadStart(localServer.serverId, config.toThreadStartParams("~"))
                                        val threadKey = ThreadKey(serverId = localServer.serverId, threadId = resp.thread.id)
                                        navigate(Route.RealtimeVoice(threadKey))
                                    }
                                } catch (_: Exception) {}
                            }
                        },
                    )
                }

                is Route.Sessions -> {
                    com.litter.android.ui.sessions.SessionsScreen(
                        serverId = route.serverId,
                        title = route.title,
                        onOpenConversation = navigateToConversation,
                        onBack = navigateBack,
                    )
                }

                is Route.Conversation -> {
                    ConversationScreen(
                        threadKey = route.key,
                        onBack = navigateBack,
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
                        showAccountForServer = serverId
                    },
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
