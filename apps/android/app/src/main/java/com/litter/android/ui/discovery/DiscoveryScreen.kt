package com.litter.android.ui.discovery

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.DesktopWindows
import androidx.compose.material.icons.outlined.DeveloperBoard
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Lan
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.SavedServer
import com.litter.android.state.SavedServerStore
import com.litter.android.state.SavedSshCredential
import com.litter.android.state.SshAuthMethod
import com.litter.android.state.SshCredentialStore
import com.litter.android.state.connectionProgressDetail
import com.litter.android.state.isIpcConnected
import com.litter.android.state.isConnected
import com.litter.android.state.statusColor
import com.litter.android.state.statusLabel
import com.litter.android.ui.ExperimentalFeatures
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.util.LLog
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppDiscoveredServer

/**
 * Server discovery and connection screen.
 * Displays discovered + saved servers merged.
 */
@Composable
fun DiscoveryScreen(
    discoveredServers: List<AppDiscoveredServer>,
    isScanning: Boolean,
    scanProgress: Float = 0f,
    scanProgressLabel: String? = null,
    onRefresh: () -> Unit,
    onDismiss: () -> Unit,
) {
    val logTag = "DiscoveryScreen"
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val sshCredentialStore = remember(context) { SshCredentialStore(context.applicationContext) }

    var showManualEntry by remember { mutableStateOf(false) }
    var pendingManualSshServer by remember { mutableStateOf<SavedServer?>(null) }
    var sshServer by remember { mutableStateOf<SavedServer?>(null) }
    var connectionChoiceServer by remember { mutableStateOf<SavedServer?>(null) }
    var pendingAutoNavigateServerId by remember { mutableStateOf<String?>(null) }
    var wakingServerId by remember { mutableStateOf<String?>(null) }
    var connectError by remember { mutableStateOf<String?>(null) }
    var renameTarget by remember { mutableStateOf<SavedServer?>(null) }

    var savedServers by remember { mutableStateOf(SavedServerStore.load(context)) }
    LaunchedEffect(Unit) {
        savedServers = SavedServerStore.load(context)
    }

    LaunchedEffect(showManualEntry, pendingManualSshServer) {
        if (!showManualEntry && pendingManualSshServer != null) {
            sshServer = pendingManualSshServer
            pendingManualSshServer = null
        }
    }

    LaunchedEffect(snapshot, pendingAutoNavigateServerId) {
        val pendingServerId = pendingAutoNavigateServerId ?: return@LaunchedEffect
        val serverSnapshot = snapshot?.servers?.firstOrNull { it.serverId == pendingServerId } ?: return@LaunchedEffect
        if (serverSnapshot.isConnected) {
            pendingAutoNavigateServerId = null
            onDismiss()
        } else if (serverSnapshot.health == AppServerHealth.DISCONNECTED) {
            serverSnapshot.connectionProgress?.terminalMessage?.let { message ->
                pendingAutoNavigateServerId = null
                connectError = message
            }
        }
    }

    val merged = remember(discoveredServers, savedServers) {
        mergeServers(discoveredServers, savedServers)
    }

    suspend fun reloadSavedServers() {
        savedServers = SavedServerStore.load(context)
    }

    suspend fun prepareServerForSelection(entry: SavedServer): SavedServer {
        if (entry.source == "local" || entry.websocketURL != null) {
            return entry
        }

        wakingServerId = entry.id
        try {
            return when (
                val wakeResult = waitForWakeSignal(
                    host = entry.hostname,
                    preferredCodexPort = entry.directCodexPort ?: entry.availableDirectCodexPorts.firstOrNull(),
                    preferredSshPort = entry.sshPort ?: if (entry.canConnectViaSsh) entry.resolvedSshPort else null,
                    timeoutMillis = if (entry.hasCodexServer) 12_000L else 18_000L,
                    wakeMac = entry.wakeMAC,
                )
            ) {
                is WakeSignalResult.Codex -> entry.copy(
                    port = wakeResult.port,
                    codexPorts = listOf(wakeResult.port) + entry.availableDirectCodexPorts.filter { it != wakeResult.port },
                    hasCodexServer = true,
                    preferredConnectionMode = entry.preferredConnectionMode,
                    preferredCodexPort = wakeResult.port,
                ).normalizedForPersistence()

                is WakeSignalResult.Ssh -> entry.copy(
                    port = wakeResult.port,
                    sshPort = wakeResult.port,
                    hasCodexServer = false,
                    preferredConnectionMode = "ssh",
                    preferredCodexPort = null,
                ).normalizedForPersistence()

                WakeSignalResult.None -> entry
            }
        } finally {
            wakingServerId = null
        }
    }

    suspend fun connectSelectedServer(entry: SavedServer) {
        if (wakingServerId != null && wakingServerId != entry.id) {
            return
        }

        try {
            val connected = connectedSnapshot(entry, snapshot?.servers ?: emptyList())
            if (connected?.isConnected == true) {
                LLog.t(logTag, "server already connected", fields = mapOf("serverId" to entry.id))
                onDismiss()
                return
            }

            val prepared = prepareServerForSelection(entry)
            when {
                prepared.source == "local" -> {
                    appModel.serverBridge.connectLocalServer(
                        prepared.id,
                        prepared.name,
                        prepared.hostname,
                        prepared.port.toUShort(),
                    )
                    appModel.restoreStoredLocalChatGptAuth(prepared.id)
                    SavedServerStore.upsert(context, prepared.normalizedForPersistence())
                    reloadSavedServers()
                    appModel.refreshSnapshot()
                    onDismiss()
                }

                prepared.websocketURL != null -> {
                    appModel.serverBridge.connectRemoteUrlServer(
                        prepared.id,
                        prepared.name,
                        prepared.websocketURL,
                    )
                    SavedServerStore.upsert(context, prepared.normalizedForPersistence())
                    reloadSavedServers()
                    appModel.refreshSnapshot()
                    onDismiss()
                }

                prepared.requiresConnectionChoice -> {
                    connectionChoiceServer = prepared
                }

                prepared.prefersSshConnection || (!prepared.hasCodexServer && prepared.canConnectViaSsh) -> {
                    sshServer = prepared.withPreferredConnection("ssh")
                }

                prepared.directCodexPort != null -> {
                    appModel.serverBridge.connectRemoteServer(
                        prepared.id,
                        prepared.name,
                        prepared.hostname,
                        prepared.directCodexPort!!.toUShort(),
                    )
                    SavedServerStore.upsert(
                        context,
                        prepared.withPreferredConnection("directCodex", prepared.directCodexPort),
                    )
                    reloadSavedServers()
                    appModel.refreshSnapshot()
                    onDismiss()
                }

                else -> {
                    connectError = "Server did not respond after wake attempt. Enable Wake for network access on the Mac."
                }
            }
        } catch (e: Exception) {
            LLog.e(
                logTag,
                "server connect failed",
                e,
                fields = mapOf(
                    "serverId" to entry.id,
                    "host" to entry.hostname,
                    "preferredConnectionMode" to entry.preferredConnectionMode,
                ),
            )
            connectError = e.message ?: "Unable to connect."
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                text = "Connect Server",
                color = LitterTheme.textPrimary,
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            if (isScanning) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                    color = LitterTheme.accent,
                )
                Spacer(Modifier.width(8.dp))
            }
            IconButton(onClick = onRefresh) {
                Icon(Icons.Default.Refresh, "Refresh", tint = LitterTheme.textSecondary)
            }
            IconButton(onClick = { showManualEntry = true }) {
                Icon(Icons.Default.Add, "Add Server", tint = LitterTheme.textSecondary)
            }
        }

        if (isScanning) {
            if (scanProgressLabel != null) {
                Spacer(Modifier.height(4.dp))
                Row(modifier = Modifier.fillMaxWidth()) {
                    Spacer(Modifier.weight(1f))
                    Text(
                        text = scanProgressLabel,
                        color = LitterTheme.textMuted,
                        fontSize = 10.sp,
                    )
                }
            }
            Spacer(Modifier.height(4.dp))
            val animatedProgress by animateFloatAsState(
                targetValue = scanProgress,
                animationSpec = tween(durationMillis = 250),
                label = "scanProgress",
            )
            LinearProgressIndicator(
                progress = { animatedProgress },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(3.dp),
                color = LitterTheme.accent,
                trackColor = LitterTheme.surface,
            )
        }

        Spacer(Modifier.height(12.dp))

        LazyColumn(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(merged, key = { it.id }) { entry ->
                ServerRow(
                    entry = entry,
                    connectedServer = connectedSnapshot(entry, snapshot?.servers ?: emptyList()),
                    isWaking = wakingServerId == entry.id,
                    enabled = wakingServerId == null || wakingServerId == entry.id,
                    onClick = { scope.launch { connectSelectedServer(entry) } },
                    onRename = if (entry.source != "local") {
                        { renameTarget = entry }
                    } else {
                        null
                    },
                )
            }

            if (merged.isEmpty()) {
                item {
                    if (isScanning) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(vertical = 16.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(14.dp),
                                strokeWidth = 2.dp,
                                color = LitterTheme.accent,
                            )
                            Text(
                                text = "Scanning…",
                                color = LitterTheme.textMuted,
                                fontSize = 13.sp,
                            )
                        }
                    } else {
                        Text(
                            text = "No servers found. Try Add Server.",
                            color = LitterTheme.textMuted,
                            fontSize = 13.sp,
                            modifier = Modifier.padding(vertical = 16.dp),
                        )
                    }
                }
            }
        }
    }

    if (showManualEntry) {
        ManualEntryDialog(
            onDismiss = { showManualEntry = false },
            onSubmit = { action ->
                when (action) {
                    is ManualEntryAction.Connect -> {
                        showManualEntry = false
                        scope.launch { connectSelectedServer(action.server) }
                    }

                    is ManualEntryAction.ContinueWithSsh -> {
                        pendingManualSshServer = action.server
                        showManualEntry = false
                    }
                }
            },
        )
    }

    connectionChoiceServer?.let { server ->
        AlertDialog(
            onDismissRequest = { connectionChoiceServer = null },
            title = { Text("Connect ${server.name.ifBlank { server.hostname }}") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        connectionChoiceMessage(server),
                        color = LitterTheme.textSecondary,
                    )
                    server.availableDirectCodexPorts.forEach { port ->
                        TextButton(
                            onClick = {
                                connectionChoiceServer = null
                                scope.launch {
                                    try {
                                        appModel.serverBridge.connectRemoteServer(
                                            server.id,
                                            server.name,
                                            server.hostname,
                                            port.toUShort(),
                                        )
                                        SavedServerStore.upsert(
                                            context,
                                            server.withPreferredConnection("directCodex", port),
                                        )
                                        reloadSavedServers()
                                        appModel.refreshSnapshot()
                                        onDismiss()
                                    } catch (e: Exception) {
                                        LLog.e(
                                            logTag,
                                            "direct codex connect failed",
                                            e,
                                            fields = mapOf(
                                                "serverId" to server.id,
                                                "host" to server.hostname,
                                                "codexPort" to port,
                                                "os" to server.os,
                                            ),
                                        )
                                        connectError = e.message ?: "Unable to connect."
                                    }
                                }
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("Use Codex ($port)")
                        }
                    }
                    if (server.canConnectViaSsh) {
                        TextButton(
                            onClick = {
                                SavedServerStore.upsert(
                                    context,
                                    server.withPreferredConnection("ssh"),
                                )
                                scope.launch { reloadSavedServers() }
                                sshServer = server.withPreferredConnection("ssh")
                                connectionChoiceServer = null
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("Connect via SSH", color = LitterTheme.accent)
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { connectionChoiceServer = null }) {
                    Text("Cancel")
                }
            },
            dismissButton = {},
        )
    }

    sshServer?.let { server ->
        SSHLoginDialog(
            server = server,
            initialCredential = sshCredentialStore.load(server.hostname, server.resolvedSshPort),
            onDismiss = { sshServer = null },
            onConnect = { credential, rememberCredentials ->
                try {
                    LLog.t(
                        logTag,
                        "starting guided SSH connect",
                        fields = mapOf(
                            "serverId" to server.id,
                            "host" to server.hostname,
                            "sshPort" to server.resolvedSshPort,
                            "authMethod" to credential.method.name,
                            "os" to server.os,
                        ),
                    )
                    when (credential.method) {
                        SshAuthMethod.PASSWORD -> {
                            appModel.ssh.sshStartRemoteServerConnect(
                                serverId = server.id,
                                displayName = server.name,
                                host = server.hostname,
                                port = server.resolvedSshPort.toUShort(),
                                username = credential.username,
                                password = credential.password,
                                privateKeyPem = null,
                                passphrase = null,
                                acceptUnknownHost = true,
                                workingDir = null,
                                ipcSocketPathOverride = ExperimentalFeatures.ipcSocketPathOverride(),
                            )
                        }

                        SshAuthMethod.KEY -> {
                            appModel.ssh.sshStartRemoteServerConnect(
                                serverId = server.id,
                                displayName = server.name,
                                host = server.hostname,
                                port = server.resolvedSshPort.toUShort(),
                                username = credential.username,
                                password = null,
                                privateKeyPem = credential.privateKey,
                                passphrase = credential.passphrase,
                                acceptUnknownHost = true,
                                workingDir = null,
                                ipcSocketPathOverride = ExperimentalFeatures.ipcSocketPathOverride(),
                            )
                        }
                    }
                    if (rememberCredentials) {
                        sshCredentialStore.save(server.hostname, server.resolvedSshPort, credential)
                    } else {
                        sshCredentialStore.delete(server.hostname, server.resolvedSshPort)
                    }
                    SavedServerStore.upsert(
                        context,
                        server.withPreferredConnection("ssh"),
                    )
                    reloadSavedServers()
                    appModel.refreshSnapshot()
                    pendingAutoNavigateServerId = server.id
                    LLog.t(
                        logTag,
                        "guided SSH bootstrap started",
                        fields = mapOf(
                            "serverId" to server.id,
                            "host" to server.hostname,
                            "sshPort" to server.resolvedSshPort,
                        ),
                    )
                    sshServer = null
                    null
                } catch (e: Exception) {
                    LLog.e(
                        logTag,
                        "guided SSH connect failed",
                        e,
                        fields = mapOf(
                            "serverId" to server.id,
                            "host" to server.hostname,
                            "sshPort" to server.resolvedSshPort,
                            "authMethod" to credential.method.name,
                            "os" to server.os,
                        ),
                    )
                    e.message ?: "Unable to connect over SSH."
                }
            },
        )
    }

    renameTarget?.let { server ->
        RenameServerDialog(
            server = server,
            onDismiss = { renameTarget = null },
            onRename = { newName ->
                scope.launch {
                    SavedServerStore.upsert(
                        context,
                        server.copy(name = newName.ifBlank { server.hostname }).normalizedForPersistence(),
                    )
                    reloadSavedServers()
                    appModel.refreshSnapshot()
                }
                renameTarget = null
            },
        )
    }

    snapshot?.servers?.firstOrNull { it.connectionProgress?.pendingInstall == true }?.let { serverSnapshot ->
        AlertDialog(
            onDismissRequest = {},
            title = { Text("Install Codex?") },
            text = {
                Text(
                    serverSnapshot.connectionProgressDetail
                        ?: "Codex was not found on the remote host. Install the latest stable release into ~/.litter?",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        scope.launch {
                            LLog.t(
                                logTag,
                                "responding to install prompt",
                                fields = mapOf(
                                    "serverId" to serverSnapshot.serverId,
                                    "install" to true,
                                    "detail" to serverSnapshot.connectionProgressDetail,
                                ),
                            )
                            appModel.ssh.sshRespondToInstallPrompt(serverSnapshot.serverId, true)
                        }
                    },
                ) {
                    Text("Install")
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        scope.launch {
                            LLog.t(
                                logTag,
                                "responding to install prompt",
                                fields = mapOf(
                                    "serverId" to serverSnapshot.serverId,
                                    "install" to false,
                                    "detail" to serverSnapshot.connectionProgressDetail,
                                ),
                            )
                            appModel.ssh.sshRespondToInstallPrompt(serverSnapshot.serverId, false)
                        }
                    },
                ) {
                    Text("Cancel")
                }
            },
        )
    }

    connectError?.let { message ->
        AlertDialog(
            onDismissRequest = { connectError = null },
            title = { Text("Connection Failed") },
            text = { Text(message) },
            confirmButton = {
                TextButton(onClick = { connectError = null }) {
                    Text("OK")
                }
            },
        )
    }
}

@Composable
private fun ServerRow(
    entry: SavedServer,
    connectedServer: AppServerSnapshot?,
    isWaking: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    onRename: (() -> Unit)?,
) {
    val displayHost = connectedServer?.host ?: entry.hostname
    val subtitle = connectedServer?.connectionProgressDetail
        ?: buildString {
            append(displayHost)
            if (entry.os != null) {
                append(" - ")
                append(entry.os)
            }
            if (entry.availableDirectCodexPorts.isNotEmpty()) {
                append(" - codex ")
                append(entry.availableDirectCodexPorts.joinToString(", "))
            }
            if (entry.canConnectViaSsh) {
                append(" - ssh ")
                append(entry.resolvedSshPort)
            }
            if (entry.wakeMAC != null) {
                append(" - wake")
            }
        }
    val serverIcon = serverIconForEntry(entry)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(10.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = serverIcon,
            contentDescription = entry.os ?: entry.source,
            tint = if (entry.hasCodexServer) LitterTheme.accent else LitterTheme.textMuted,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(entry.name.ifBlank { entry.hostname }, color = LitterTheme.textPrimary, fontSize = 14.sp)
            Text(subtitle, color = LitterTheme.textSecondary, fontSize = 11.sp)
        }
        val (sourceColor, sourceLabel) = when (entry.source) {
            "bonjour" -> LitterTheme.info to "Bonjour"
            "tailscale" -> Color(0xFFC797D8) to "Tailscale"
            "lanProbe" -> LitterTheme.accent to "LAN"
            "arpScan" -> LitterTheme.textSecondary to "ARP"
            "ssh" -> Color(0xFFFF9500) to "SSH"
            "local" -> LitterTheme.accent to "Local"
            else -> LitterTheme.textMuted to "Manual"
        }
        Text(
            text = sourceLabel,
            color = sourceColor,
            fontSize = 10.sp,
            modifier = Modifier
                .background(sourceColor.copy(alpha = 0.12f), RoundedCornerShape(4.dp))
                .padding(horizontal = 6.dp, vertical = 2.dp),
        )
        if (connectedServer != null && connectedServer.health != AppServerHealth.DISCONNECTED) {
            Spacer(Modifier.width(6.dp))
            Text(
                text = connectedServer.statusLabel,
                color = connectedServer.statusColor,
                fontSize = 10.sp,
                modifier = Modifier
                    .background(connectedServer.statusColor.copy(alpha = 0.12f), RoundedCornerShape(4.dp))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
        if (connectedServer?.isIpcConnected == true) {
            Spacer(Modifier.width(6.dp))
            Text(
                text = "IPC",
                color = LitterTheme.accentStrong,
                fontSize = 10.sp,
                modifier = Modifier
                    .background(LitterTheme.accentStrong.copy(alpha = 0.14f), RoundedCornerShape(4.dp))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        } else if (isWaking) {
            Spacer(Modifier.width(6.dp))
            CircularProgressIndicator(
                modifier = Modifier.size(14.dp),
                strokeWidth = 2.dp,
                color = LitterTheme.accent,
            )
        }
        if (onRename != null) {
            Spacer(Modifier.width(2.dp))
            IconButton(
                onClick = onRename,
                enabled = enabled,
                modifier = Modifier.size(28.dp),
            ) {
                Icon(
                    imageVector = Icons.Outlined.Edit,
                    contentDescription = "Rename server",
                    tint = LitterTheme.textMuted,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

@Composable
private fun ManualEntryDialog(
    onDismiss: () -> Unit,
    onSubmit: (ManualEntryAction) -> Unit,
) {
    var mode by remember { mutableStateOf(ManualConnectionMode.SSH) }
    var codexUrl by remember { mutableStateOf("") }
    var host by remember { mutableStateOf("") }
    var sshPort by remember { mutableStateOf("22") }
    var wakeMac by remember { mutableStateOf("") }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add Server") },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = mode == ManualConnectionMode.CODEX,
                        onClick = { mode = ManualConnectionMode.CODEX },
                        label = { Text(ManualConnectionMode.CODEX.label) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = LitterTheme.accent.copy(alpha = 0.18f),
                            selectedLabelColor = LitterTheme.textPrimary,
                        ),
                    )
                    FilterChip(
                        selected = mode == ManualConnectionMode.SSH,
                        onClick = { mode = ManualConnectionMode.SSH },
                        label = { Text(ManualConnectionMode.SSH.label) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = LitterTheme.accent.copy(alpha = 0.18f),
                            selectedLabelColor = LitterTheme.textPrimary,
                        ),
                    )
                }

                if (mode == ManualConnectionMode.CODEX) {
                    OutlinedTextField(
                        value = codexUrl,
                        onValueChange = {
                            codexUrl = it
                            errorMessage = null
                        },
                        label = { Text("Codex URL") },
                        placeholder = { Text("ws://host:8390 or host:8390") },
                        singleLine = true,
                    )
                    Text(
                        text = "Run: codex app-server --listen ws://0.0.0.0:8390",
                        color = LitterTheme.textMuted,
                        fontSize = 11.sp,
                    )
                } else {
                    OutlinedTextField(
                        value = host,
                        onValueChange = {
                            host = it
                            errorMessage = null
                        },
                        label = { Text("SSH host") },
                        placeholder = { Text("hostname or IP") },
                        singleLine = true,
                    )
                    OutlinedTextField(
                        value = sshPort,
                        onValueChange = {
                            sshPort = it
                            errorMessage = null
                        },
                        label = { Text("SSH port") },
                        singleLine = true,
                    )
                    OutlinedTextField(
                        value = wakeMac,
                        onValueChange = {
                            wakeMac = it
                            errorMessage = null
                        },
                        label = { Text("Wake MAC (optional)") },
                        placeholder = { Text("aa:bb:cc:dd:ee:ff") },
                        singleLine = true,
                    )
                }

                if (errorMessage != null) {
                    Text(
                        text = errorMessage!!,
                        color = LitterTheme.danger,
                        fontSize = 12.sp,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    errorMessage = when (val action = buildManualEntryAction(mode, codexUrl, host, sshPort, wakeMac)) {
                        is ManualEntryBuild.Action -> {
                            onSubmit(action.action)
                            null
                        }

                        is ManualEntryBuild.Error -> action.message
                    }
                },
            ) {
                Text(mode.primaryButtonTitle)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        },
    )
}

@Composable
private fun RenameServerDialog(
    server: SavedServer,
    onDismiss: () -> Unit,
    onRename: (String) -> Unit,
) {
    var newName by remember(server.id) {
        mutableStateOf(server.name.ifBlank { server.hostname })
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename Server") },
        text = {
            OutlinedTextField(
                value = newName,
                onValueChange = { newName = it },
                label = { Text("Name") },
                singleLine = true,
            )
        },
        confirmButton = {
            TextButton(onClick = { onRename(newName.trim()) }) {
                Text("Save")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        },
    )
}

@Composable
private fun SSHLoginDialog(
    server: SavedServer,
    initialCredential: SavedSshCredential?,
    onDismiss: () -> Unit,
    onConnect: suspend (SavedSshCredential, Boolean) -> String?,
) {
    val scope = rememberCoroutineScope()
    var username by remember(server.id) { mutableStateOf(initialCredential?.username ?: "") }
    var authMethod by remember(server.id) { mutableStateOf(initialCredential?.method ?: SshAuthMethod.PASSWORD) }
    var password by remember(server.id) { mutableStateOf(initialCredential?.password ?: "") }
    var privateKey by remember(server.id) { mutableStateOf(initialCredential?.privateKey ?: "") }
    var passphrase by remember(server.id) { mutableStateOf(initialCredential?.passphrase ?: "") }
    var rememberCredentials by remember(server.id) { mutableStateOf(initialCredential != null) }
    var isConnecting by remember(server.id) { mutableStateOf(false) }
    var errorMessage by remember(server.id) { mutableStateOf<String?>(null) }
    val hostDisplay = if (server.resolvedSshPort == 22) {
        server.hostname
    } else {
        "${server.hostname}:${server.resolvedSshPort}"
    }

    AlertDialog(
        onDismissRequest = { if (!isConnecting) onDismiss() },
        title = { Text("SSH Login") },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                Text(
                    text = "${server.name.ifBlank { server.hostname }}\n$hostDisplay",
                    color = LitterTheme.textPrimary,
                    fontSize = 13.sp,
                )
                OutlinedTextField(
                    value = username,
                    onValueChange = { username = it },
                    label = { Text("Username") },
                    singleLine = true,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(
                        onClick = { authMethod = SshAuthMethod.PASSWORD },
                        enabled = !isConnecting,
                    ) {
                        Text(if (authMethod == SshAuthMethod.PASSWORD) "Password *" else "Password")
                    }
                    TextButton(
                        onClick = { authMethod = SshAuthMethod.KEY },
                        enabled = !isConnecting,
                    ) {
                        Text(if (authMethod == SshAuthMethod.KEY) "SSH Key *" else "SSH Key")
                    }
                }
                if (authMethod == SshAuthMethod.PASSWORD) {
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it },
                        label = { Text("Password") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                    )
                } else {
                    OutlinedTextField(
                        value = privateKey,
                        onValueChange = { privateKey = it },
                        label = { Text("Private Key") },
                        minLines = 5,
                    )
                    OutlinedTextField(
                        value = passphrase,
                        onValueChange = { passphrase = it },
                        label = { Text("Passphrase (optional)") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                    )
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Switch(
                        checked = rememberCredentials,
                        onCheckedChange = { rememberCredentials = it },
                        enabled = !isConnecting,
                    )
                    Text(
                        text = "Remember credentials on this device",
                        color = LitterTheme.textSecondary,
                        fontSize = 12.sp,
                    )
                }
                if (errorMessage != null) {
                    Text(
                        text = errorMessage!!,
                        color = LitterTheme.danger,
                        fontSize = 12.sp,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !isConnecting && username.isNotBlank() && when (authMethod) {
                    SshAuthMethod.PASSWORD -> password.isNotBlank()
                    SshAuthMethod.KEY -> privateKey.isNotBlank()
                },
                onClick = {
                    val credential = when (authMethod) {
                        SshAuthMethod.PASSWORD -> SavedSshCredential(
                            username = username.trim(),
                            method = SshAuthMethod.PASSWORD,
                            password = password,
                        )

                        SshAuthMethod.KEY -> SavedSshCredential(
                            username = username.trim(),
                            method = SshAuthMethod.KEY,
                            privateKey = privateKey,
                            passphrase = passphrase.ifBlank { null },
                        )
                    }
                    scope.launch {
                        isConnecting = true
                        errorMessage = onConnect(credential, rememberCredentials)
                        isConnecting = false
                    }
                },
            ) {
                if (isConnecting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        strokeWidth = 2.dp,
                        color = LitterTheme.accent,
                    )
                } else {
                    Text("Connect")
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !isConnecting) {
                Text("Cancel")
            }
        },
    )
}

private fun serverIconForEntry(entry: SavedServer): androidx.compose.ui.graphics.vector.ImageVector {
    if (entry.source == "local") return Icons.Outlined.PhoneAndroid
    val os = entry.os?.lowercase()
    if (os != null) {
        if (os.contains("windows")) return Icons.Outlined.DesktopWindows
        if (os.contains("raspbian")) return Icons.Outlined.DeveloperBoard
        if (
            os.contains("ubuntu") ||
            os.contains("debian") ||
            os.contains("fedora") ||
            os.contains("red hat") ||
            os.contains("freebsd") ||
            os.contains("linux")
        ) {
            return Icons.Outlined.Dns
        }
    }
    return when (entry.source) {
        "bonjour" -> Icons.Outlined.Laptop
        "tailscale" -> Icons.Outlined.Lan
        "ssh" -> Icons.Outlined.Terminal
        else -> Icons.Outlined.Dns
    }
}

private fun connectedSnapshot(
    entry: SavedServer,
    servers: List<AppServerSnapshot>,
): AppServerSnapshot? = servers.firstOrNull { it.serverId == entry.id }
    ?: servers.firstOrNull { it.host.lowercase().trim().trimStart('[').trimEnd(']') == entry.deduplicationKey }

private fun mergeServers(
    discovered: List<AppDiscoveredServer>,
    saved: List<SavedServer>,
): List<SavedServer> {
    val merged = linkedMapOf<String, SavedServer>()

    fun sourceRank(source: String): Int = when (source) {
        "bonjour" -> 0
        "tailscale" -> 1
        "lanProbe" -> 2
        "arpScan" -> 3
        "ssh" -> 4
        "manual" -> 5
        "local" -> 6
        else -> 7
    }

    fun mergeCandidate(existing: SavedServer, candidate: SavedServer): SavedServer {
        val betterSource = sourceRank(candidate.source) < sourceRank(existing.source)
        val hasCodexUpgrade = candidate.hasCodexServer && !existing.hasCodexServer
        val betterCodexPort = candidate.availableDirectCodexPorts.any { it !in existing.availableDirectCodexPorts }
        val betterName = existing.name == existing.hostname && candidate.name != candidate.hostname
        val preferCandidate = betterSource || hasCodexUpgrade || betterCodexPort || betterName

        val mergedCodexPorts = buildList {
            addAll(existing.availableDirectCodexPorts)
            addAll(candidate.availableDirectCodexPorts)
        }.distinct()

        val mergedOs = if (candidate.sshBanner != null) candidate.os else (candidate.os ?: existing.os)
        val mergedBanner = candidate.sshBanner ?: existing.sshBanner

        val mergedServer = if (preferCandidate) {
            candidate.copy(
                id = existing.id,
                codexPorts = mergedCodexPorts,
                wakeMAC = candidate.wakeMAC ?: existing.wakeMAC,
                preferredConnectionMode = existing.resolvedPreferredConnectionMode ?: candidate.resolvedPreferredConnectionMode,
                preferredCodexPort = existing.resolvedPreferredCodexPort ?: candidate.resolvedPreferredCodexPort,
                sshPortForwardingEnabled = null,
                websocketURL = candidate.websocketURL ?: existing.websocketURL,
                os = mergedOs,
                sshBanner = mergedBanner,
            )
        } else {
            existing.copy(
                codexPorts = mergedCodexPorts,
                sshPort = existing.sshPort ?: candidate.sshPort,
                wakeMAC = existing.wakeMAC ?: candidate.wakeMAC,
                preferredConnectionMode = existing.resolvedPreferredConnectionMode ?: candidate.resolvedPreferredConnectionMode,
                preferredCodexPort = existing.resolvedPreferredCodexPort ?: candidate.resolvedPreferredCodexPort,
                sshPortForwardingEnabled = null,
                websocketURL = existing.websocketURL ?: candidate.websocketURL,
                os = mergedOs,
                sshBanner = mergedBanner,
            )
        }

        return mergedServer.normalizedForPersistence()
    }

    for (server in saved) {
        merged[server.deduplicationKey] = server
    }

    for (server in discovered.map(SavedServer::from)) {
        val key = server.deduplicationKey
        merged[key] = merged[key]?.let { existing -> mergeCandidate(existing, server) } ?: server
    }

    return merged.values.sortedWith(
        compareBy<SavedServer> { sourceRank(it.source) }.thenBy { it.name.lowercase() },
    )
}

private fun connectionChoiceMessage(server: SavedServer): String {
    val directPorts = server.availableDirectCodexPorts.map(Int::toString)
    if (directPorts.isEmpty()) {
        return "Use SSH to bootstrap Codex on ${server.hostname}."
    }
    if (server.canConnectViaSsh) {
        return "Codex is available on ports ${directPorts.joinToString(", ")} and SSH is also available on port ${server.resolvedSshPort}."
    }
    return "Choose a Codex app-server port on ${server.hostname}."
}

private sealed interface ManualEntryAction {
    data class Connect(val server: SavedServer) : ManualEntryAction
    data class ContinueWithSsh(val server: SavedServer) : ManualEntryAction
}

private sealed interface ManualEntryBuild {
    data class Action(val action: ManualEntryAction) : ManualEntryBuild
    data class Error(val message: String) : ManualEntryBuild
}

private enum class ManualConnectionMode(
    val label: String,
    val primaryButtonTitle: String,
) {
    CODEX("Codex", "Connect"),
    SSH("SSH", "Continue to SSH Login"),
}

private fun buildManualEntryAction(
    mode: ManualConnectionMode,
    codexUrl: String,
    host: String,
    sshPort: String,
    wakeMac: String,
): ManualEntryBuild = when (mode) {
    ManualConnectionMode.CODEX -> buildManualCodexEntry(codexUrl)
    ManualConnectionMode.SSH -> buildManualSshEntry(host, sshPort, wakeMac)
}

private fun buildManualCodexEntry(rawInput: String): ManualEntryBuild {
    val raw = rawInput.trim()
    if (raw.isEmpty()) {
        return ManualEntryBuild.Error("Enter a ws:// URL or host:port.")
    }

    runCatching { URI(raw) }
        .getOrNull()
        ?.let { uri ->
            val scheme = uri.scheme?.lowercase()
            val host = uri.host?.takeIf { it.isNotBlank() }
            if ((scheme == "ws" || scheme == "wss") && host != null) {
                val port = uri.port.takeIf { it > 0 }
                return ManualEntryBuild.Action(
                    ManualEntryAction.Connect(
                        SavedServer(
                            id = "manual-url-$raw",
                            name = host,
                            hostname = host,
                            port = port ?: 0,
                            codexPorts = port?.let(::listOf) ?: emptyList(),
                            source = "manual",
                            hasCodexServer = true,
                            preferredConnectionMode = "directCodex",
                            preferredCodexPort = port,
                            websocketURL = raw,
                        ).normalizedForPersistence(),
                    ),
                )
            }
        }

    val (host, port) = parseBareHostAndPort(raw) ?: return ManualEntryBuild.Error("Enter a ws:// URL or host:port.")
    if (host.isBlank()) {
        return ManualEntryBuild.Error("Enter a hostname or IP address.")
    }

    return ManualEntryBuild.Action(
        ManualEntryAction.Connect(
            SavedServer(
                id = "manual-$host:$port",
                name = host,
                hostname = host,
                port = port,
                codexPorts = listOf(port),
                source = "manual",
                hasCodexServer = true,
                preferredConnectionMode = "directCodex",
                preferredCodexPort = port,
            ).normalizedForPersistence(),
        ),
    )
}

private fun buildManualSshEntry(
    hostInput: String,
    sshPortInput: String,
    wakeMacInput: String,
): ManualEntryBuild {
    val host = hostInput.trim()
    if (host.isEmpty()) {
        return ManualEntryBuild.Error("Enter a hostname or IP address.")
    }

    val sshPort = sshPortInput.trim().toIntOrNull()
    if (sshPort == null || sshPort !in 1..65535) {
        return ManualEntryBuild.Error("SSH port must be a valid number.")
    }

    val wakeInput = wakeMacInput.trim()
    val normalizedWakeMac = SavedServer.normalizeWakeMac(wakeInput)
    if (wakeInput.isNotEmpty() && normalizedWakeMac == null) {
        return ManualEntryBuild.Error("Wake MAC must look like aa:bb:cc:dd:ee:ff.")
    }

    return ManualEntryBuild.Action(
        ManualEntryAction.ContinueWithSsh(
            SavedServer(
                id = "manual-ssh-$host:$sshPort",
                name = host,
                hostname = host,
                port = sshPort,
                sshPort = sshPort,
                source = "manual",
                hasCodexServer = false,
                wakeMAC = normalizedWakeMac,
                preferredConnectionMode = "ssh",
            ).normalizedForPersistence(),
        ),
    )
}

private fun parseBareHostAndPort(raw: String): Pair<String, Int>? {
    if (raw.startsWith("[")) {
        val closing = raw.indexOf(']')
        if (closing > 1) {
            val host = raw.substring(1, closing)
            val portPart = raw.substring(closing + 1)
            val port = when {
                portPart.isEmpty() -> 8390
                portPart.startsWith(":") -> portPart.drop(1).toIntOrNull() ?: return null
                else -> return null
            }
            return host to port
        }
    }

    val colonCount = raw.count { it == ':' }
    if (colonCount == 1) {
        val index = raw.lastIndexOf(':')
        val host = raw.substring(0, index)
        val port = raw.substring(index + 1).toIntOrNull() ?: return null
        return host to port
    }

    return raw to 8390
}

private sealed interface WakeSignalResult {
    data class Codex(val port: Int) : WakeSignalResult
    data class Ssh(val port: Int) : WakeSignalResult
    data object None : WakeSignalResult
}

private suspend fun waitForWakeSignal(
    host: String,
    preferredCodexPort: Int?,
    preferredSshPort: Int?,
    timeoutMillis: Long,
    wakeMac: String?,
): WakeSignalResult = withContext(Dispatchers.IO) {
    val codexPorts = orderedCodexPorts(preferredCodexPort)
    val sshPorts = orderedSshPorts(preferredSshPort)
    val deadline = System.currentTimeMillis() + maxOf(timeoutMillis, 500L)
    var lastWakePacketAt = 0L

    while (System.currentTimeMillis() < deadline) {
        val now = System.currentTimeMillis()
        if (!wakeMac.isNullOrBlank() && now - lastWakePacketAt >= 2_000L) {
            sendWakeMagicPacket(wakeMac, host)
            lastWakePacketAt = now
        }

        for (port in codexPorts) {
            if (isPortOpen(host, port, 700)) {
                return@withContext WakeSignalResult.Codex(port)
            }
        }

        for (port in sshPorts) {
            if (isPortOpen(host, port, 700)) {
                return@withContext WakeSignalResult.Ssh(port)
            }
        }

        delay(350)
    }

    WakeSignalResult.None
}

private fun orderedCodexPorts(preferred: Int?): List<Int> = buildList {
    preferred?.let(::add)
    addAll(listOf(8390, 9234, 4222))
}.filter { it in 1..65535 }.distinct()

private fun orderedSshPorts(preferred: Int?): List<Int> = buildList {
    preferred?.let(::add)
    add(22)
}.filter { it in 1..65535 }.distinct()

private fun sendWakeMagicPacket(wakeMac: String, hostHint: String) {
    val mac = SavedServer.normalizeWakeMac(wakeMac) ?: return
    val macBytes = mac.split(':').mapNotNull { it.toIntOrNull(16)?.toByte() }
    if (macBytes.size != 6) {
        return
    }

    val packet = ByteArray(6 + 16 * macBytes.size)
    repeat(6) { packet[it] = 0xFF.toByte() }
    for (index in 0 until 16) {
        macBytes.forEachIndexed { byteIndex, value ->
            packet[6 + index * macBytes.size + byteIndex] = value
        }
    }

    wakeBroadcastTargets(hostHint).forEach { target ->
        sendBroadcastUdp(packet, target, 9)
        sendBroadcastUdp(packet, target, 7)
    }
}

private fun wakeBroadcastTargets(host: String): Set<String> {
    val targets = linkedSetOf("255.255.255.255")
    val ipv4Parts = host.split('.')
    if (ipv4Parts.size == 4 && ipv4Parts.all { it.toIntOrNull() != null }) {
        targets += "${ipv4Parts[0]}.${ipv4Parts[1]}.${ipv4Parts[2]}.255"
    }
    return targets
}

private fun sendBroadcastUdp(packet: ByteArray, host: String, port: Int) {
    runCatching {
        DatagramSocket().use { socket ->
            socket.broadcast = true
            val address = InetAddress.getByName(host)
            socket.send(DatagramPacket(packet, packet.size, address, port))
        }
    }
}

private fun isPortOpen(host: String, port: Int, timeoutMillis: Int): Boolean =
    runCatching {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, port), timeoutMillis)
            true
        }
    }.getOrDefault(false)
