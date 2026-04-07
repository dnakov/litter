package com.litter.android.state

import android.content.Context
import com.litter.android.ui.ExperimentalFeatures
import com.litter.android.util.LLog
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import uniffi.codex_mobile_client.AppRefreshAccountRequest
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.AppServerHealth

/**
 * Handles app lifecycle events: server reconnection on resume,
 * background turn tracking on pause, and push notification handling.
 */
class AppLifecycleController {
    companion object {
        internal fun reconnectCandidates(
            savedServers: List<SavedServer>,
            activeServerIds: Set<String>,
        ): List<SavedServer> =
            savedServers.filter { server ->
                server.source != "local" && server.id !in activeServerIds
            }
    }

    private val reconnectMutex = Mutex()

    /** Threads that were active when the app went to background. */
    private val backgroundedTurnKeys = mutableSetOf<ThreadKey>()

    /** FCM device push token. */
    var devicePushToken: String? = null
        private set

    fun setDevicePushToken(token: String) {
        devicePushToken = token
    }

    /**
     * Reconnects all saved servers on app launch or resume.
     */
    suspend fun reconnectSavedServers(context: Context, appModel: AppModel) {
        if (!reconnectMutex.tryLock()) {
            LLog.t("AppLifecycleController", "reconnect already in progress; skipping")
            return
        }
        try {
            ExperimentalFeatures.initialize(context.applicationContext)
            val sshCredentials = SshCredentialStore(context)
            val activeServerIds = appModel.store.snapshot()
                .servers
                .filter { it.health != AppServerHealth.DISCONNECTED }
                .mapTo(mutableSetOf()) { it.serverId }
            val saved = reconnectCandidates(
                savedServers = SavedServerStore.remembered(context),
                activeServerIds = activeServerIds,
            )
            coroutineScope {
                saved.map { server ->
                    async {
                        try {
                            reconnectSavedServer(appModel, server, sshCredentials)
                        } catch (e: Exception) {
                            // Best-effort reconnection — server may be offline
                            LLog.e(
                                "AppLifecycleController",
                                "saved server reconnect failed",
                                e,
                                fields = mapOf("serverId" to server.id, "host" to server.hostname, "os" to server.os),
                            )
                        }
                    }
                }.awaitAll()
            }
            appModel.refreshSnapshot()
        } finally {
            reconnectMutex.unlock()
        }
    }

    suspend fun reconnectServer(context: Context, appModel: AppModel, serverId: String) {
        val currentServer = appModel.store.snapshot().servers.firstOrNull { it.serverId == serverId }
        if (currentServer?.isLocal == true || serverId == "local") {
            appModel.restartLocalServer()
            return
        }

        val sshCredentials = SshCredentialStore(context)
        val savedServer = SavedServerStore.load(context).firstOrNull { it.id == serverId }
        if (savedServer != null) {
            appModel.sshSessionStore.close(serverId)
            runCatching { appModel.serverBridge.disconnectServer(serverId) }
            try {
                reconnectSavedServer(appModel, savedServer, sshCredentials)
            } catch (e: Exception) {
                LLog.e(
                    "AppLifecycleController",
                    "manual reconnect failed",
                    e,
                    fields = mapOf("serverId" to serverId),
                )
            }
            appModel.refreshSnapshot()
            return
        }

        if (currentServer != null) {
            appModel.sshSessionStore.close(serverId)
            runCatching { appModel.serverBridge.disconnectServer(serverId) }
            try {
                appModel.serverBridge.connectRemoteServer(
                    serverId = currentServer.serverId,
                    displayName = currentServer.displayName,
                    host = currentServer.host,
                    port = currentServer.port,
                )
            } catch (e: Exception) {
                LLog.e(
                    "AppLifecycleController",
                    "manual reconnect fallback failed",
                    e,
                    fields = mapOf("serverId" to serverId),
                )
            }
            appModel.refreshSnapshot()
        }
    }

    private suspend fun reconnectSshServer(
        appModel: AppModel,
        server: SavedServer,
        credential: SavedSshCredential,
    ) {
        LLog.t(
            "AppLifecycleController",
            "reconnecting saved SSH server",
            fields = mapOf(
                "serverId" to server.id,
                "host" to server.hostname,
                "sshPort" to server.resolvedSshPort,
                "authMethod" to credential.method.name,
                "os" to server.os,
            ),
        )
        val isPiMono = server.source == "pi-mono"
        val ipcSocketPathOverride = ExperimentalFeatures.ipcSocketPathOverride()
        when (credential.method) {
            SshAuthMethod.PASSWORD -> {
                if (isPiMono) {
                    appModel.ssh.sshConnectPiMono(
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
                        provider = null,
                        model = null,
                    )
                } else {
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
                        ipcSocketPathOverride = ipcSocketPathOverride,
                    )
                }
            }
            SshAuthMethod.KEY -> {
                if (isPiMono) {
                    appModel.ssh.sshConnectPiMono(
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
                        provider = null,
                        model = null,
                    )
                } else {
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
                        ipcSocketPathOverride = ipcSocketPathOverride,
                    )
                }
            }
        }
    }

    private suspend fun reconnectSavedServer(
        appModel: AppModel,
        server: SavedServer,
        sshCredentials: SshCredentialStore,
    ) {
        val directCodexPort = server.directCodexPort
        when {
            server.websocketURL != null -> {
                appModel.serverBridge.connectRemoteUrlServer(
                    serverId = server.id,
                    displayName = server.name,
                    websocketUrl = server.websocketURL,
                )
            }
            server.resolvedPreferredConnectionMode == "ssh" -> {
                val credential = sshCredentials.load(server.hostname, server.resolvedSshPort) ?: return
                reconnectSshServer(appModel, server, credential)
            }
            directCodexPort != null -> {
                appModel.serverBridge.connectRemoteServer(
                    serverId = server.id,
                    displayName = server.name,
                    host = server.hostname,
                    port = directCodexPort.toUShort(),
                )
            }
            else -> {
                LLog.t(
                    "AppLifecycleController",
                    "skipping reconnect; no valid saved transport",
                    fields = mapOf("serverId" to server.id),
                )
            }
        }
    }

    private suspend fun ensureLocalServerConnected(appModel: AppModel) {
        val currentLocal = appModel.store.snapshot()
            .servers
            .firstOrNull { it.isLocal && it.health != AppServerHealth.DISCONNECTED }
        if (currentLocal != null) {
            return
        }

        try {
            appModel.serverBridge.connectLocalServer(
                serverId = "local",
                displayName = "This Device",
                host = "127.0.0.1",
                port = 0u,
            )
            appModel.restoreStoredLocalChatGptAuth("local")
            appModel.refreshSessions(listOf("local"))
            appModel.refreshSnapshot()
            LLog.i("AppLifecycleController", "Local in-process server connected")
        } catch (e: Exception) {
            LLog.w(
                "AppLifecycleController",
                "local server reconnect failed",
                fields = mapOf("error" to e.message),
            )
        }
    }

    private suspend fun reconnectActiveSshServers(
        context: Context,
        appModel: AppModel,
        serverIds: Set<String>,
    ) {
        if (serverIds.isEmpty()) {
            return
        }

        val sshCredentials = SshCredentialStore(context)
        val savedServers = SavedServerStore.remembered(context)
            .filter { it.resolvedPreferredConnectionMode == "ssh" && it.id in serverIds }

        coroutineScope {
            savedServers.map { server ->
                async {
                    val credential = sshCredentials.load(server.hostname, server.resolvedSshPort) ?: return@async
                    try {
                        reconnectSshServer(appModel, server, credential)
                    } catch (e: Exception) {
                        LLog.w(
                            "AppLifecycleController",
                            "active SSH server reconnect failed",
                            fields = mapOf("serverId" to server.id, "error" to e.message),
                        )
                    }
                }
            }.awaitAll()
        }

        appModel.refreshSnapshot()
    }

    private suspend fun probeActiveRemoteServers(appModel: AppModel) {
        val serverIds = appModel.store.snapshot()
            .servers
            .filter { !it.isLocal && it.health == AppServerHealth.CONNECTED }
            .map { it.serverId }
            .distinct()

        if (serverIds.isEmpty()) {
            return
        }

        for (serverId in serverIds) {
            try {
                appModel.client.refreshAccount(
                    serverId,
                    AppRefreshAccountRequest(refreshToken = false),
                )
            } catch (e: Exception) {
                LLog.w(
                    "AppLifecycleController",
                    "active remote server probe failed",
                    fields = mapOf("serverId" to serverId, "error" to e.message),
                )
            }
        }

        appModel.refreshSnapshot()
    }

    /**
     * Called when the app enters the foreground.
     */
    suspend fun onResume(context: Context, appModel: AppModel) {
        ensureLocalServerConnected(appModel)
        reconnectSavedServers(context, appModel)
        probeActiveRemoteServers(appModel)
        backgroundedTurnKeys.clear()
    }

    /**
     * Called when the app goes to background.
     * Tracks active turns for notification on completion.
     */
    fun onPause(appModel: AppModel) {
        backgroundedTurnKeys.clear()
        val snap = appModel.snapshot.value ?: return
        for (thread in snap.threads) {
            if (thread.activeTurnId != null) {
                backgroundedTurnKeys.add(thread.key)
            }
        }
    }

    /**
     * Returns the set of threads that were active when the app was backgrounded.
     * Used by foreground service / push handler to know what to track.
     */
    fun getBackgroundedTurnKeys(): Set<ThreadKey> = backgroundedTurnKeys.toSet()
}
